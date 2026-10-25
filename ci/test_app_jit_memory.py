"""Run the app-owned allocator and PSP memory lifecycle through real Mach aliases."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'


@unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64' and shutil.which('clang++'), 'Apple arm64 required')
class AppJITMemoryTests(unittest.TestCase):
    def test_one_preparation_multiple_cores_and_1100_psp_sessions(self):
        source = r'''
#include "IRJITMemory.h"
#include "IRPSPExecutableMemory.h"
#include "IRSharedJITMemory.h"
#include <cassert>
#include <cstring>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
extern "C" bool ir_phase3_core_prepare_memory(const IRJITMemoryAPI *);
static unsigned preparations;
static void *prepare(void *p, size_t bytes) {
    assert(!p); ++preparations;
    return mmap(nullptr, bytes, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
}
static void emit(void *rx, void *rw, unsigned value) {
    const unsigned words[] = {0xd2800000u | (value << 5), 0xd65f03c0u};
    memcpy(rw, words, sizeof words);
    sys_dcache_flush(rw, sizeof words); sys_icache_invalidate(rx, sizeof words);
    assert(((unsigned (*)())rx)() == value);
}
int main() {
    const auto *api = ir_jit_memory_api(); void *rx, *rw;
    assert(!api->allocate(8, &rx, &rw));
    assert(!ir_jit_memory_prepare(nullptr));
    assert(ir_jit_memory_prepare(prepare) && ir_jit_memory_ready());
    assert(ir_jit_memory_prepare(prepare) && preparations == 1);
    assert(!api->allocate(0, &rx, &rw) && !api->allocate(SIZE_MAX, &rx, &rw));
    assert(!api->allocate(1, nullptr, &rw));
    assert(api->allocate(512u * 1024 * 1024, &rx, &rw)); // Dolphin's retained arena.
    auto dolphin = rx;
    assert(rx != rw && *(unsigned *)rw == 0);
    emit(rx, rw, 42); emit(rx, rw, 7);
    assert(!api->release(rw, 512u * 1024 * 1024));
    assert(!api->release((char *)rx + 16384, 16384));
    assert(!api->release(rx, 16384));
    assert(!api->allocate(257u * 1024 * 1024, &rx, &rw));
    assert(api->allocate(128u * 1024 * 1024, &rx, &rw)); // Azahar cache.
    emit(rx, rw, 42); assert(api->release(rx, 128u * 1024 * 1024));
    assert(api->allocate(128u * 1024 * 1024, &rx, &rw) && *(unsigned *)rw == 0);
    assert(api->release(rx, 128u * 1024 * 1024));
    auto bad = *api; bad.version = 2;
    assert(!ir_phase3_core_prepare_memory(&bad));
    assert(ir_phase3_core_prepare_memory(api));
    IRPSPExecClaim stale = 0;
    for (unsigned session = 1; session <= 1100; ++session) {
        assert(ir_native_psp_exec_prepare_shared(session, api, nullptr) == IR_PSP_EXEC_OK);
        auto probe = ir_psp_exec_claim(IR_PSP_EXEC_CPU, 16 * 1024 * 1024, &rx, &rw);
        assert(probe && !ir_psp_exec_release(stale));
        assert(ir_psp_exec_begin_write(probe, rx, 8));
        emit(rx, rw, 42); emit(rx, rw, 7);
        assert(ir_psp_exec_end_write(probe, rx, 8));
        assert(ir_psp_exec_release(probe)); stale = probe;
        ir_psp_exec_probe_proven(true);
        auto previous = ir_psp_exec_generation();
        assert(ir_native_psp_exec_advance(session, previous, previous + 1) == 0);
        auto live = ir_psp_exec_claim(IR_PSP_EXEC_VERTEX, 256 * 1024, &rx, &rw);
        assert(live && ir_native_psp_exec_end(session) == IR_PSP_EXEC_UNCERTAIN);
        assert(ir_psp_exec_release(live));
        assert(ir_psp_exec_reuse_native(session) == 0);
        void *write;
        auto code = ir_shared_jit_allocate(8, &write); // Play/Flycast.
        assert(code && write); emit(code, write, 42); ir_shared_jit_release(code);
    }
    assert(ir_native_psp_exec_end(1100) == 0);
    assert(api->release(dolphin, 512u * 1024 * 1024));
    assert(ir_jit_memory_ready() && preparations == 1);
}
'''
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            (folder / 'main.cpp').write_text(source)
            subprocess.run(['clang', '-std=c11', '-I', str(BRIDGE), '-c', str(BRIDGE / 'IRJITMemory.c'), '-o', str(folder / 'pool.o')], check=True, timeout=30)
            subprocess.run(['clang++', '-std=c++17', '-I', str(BRIDGE), str(folder / 'main.cpp'),
                            str(BRIDGE / 'IRPSPExecutableMemory.cpp'), str(BRIDGE / 'IRSharedJITMemory.cpp'),
                            str(folder / 'pool.o'), '-o', str(folder / 'check')], check=True, timeout=60)
            subprocess.run([str(folder / 'check')], check=True, timeout=90)


class AppJITCoordinatorTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_preparation_detach_reuse_and_failed_cleanup(self):
        from host_tests import module_cache
        text = (ROOT / 'iridium/apps/ios/App/JIT/JITSetup.swift').read_text()
        body = text[text.index('    private var consoleMemoryFailed'):text.index('    func enable(requiresAttachedDebugger:')]
        fixture = r'''
import Foundation
final class Memory: @unchecked Sendable {
    static let shared = Memory()
    let lock = NSLock()
    var ready = false, succeeds = true
    var allocations = 0
    func prepared() -> Bool { lock.lock(); defer { lock.unlock() }; allocations += 1; ready = succeeds; return ready }
    func isReady() -> Bool { lock.lock(); defer { lock.unlock() }; return ready }
}
func ir_jit_memory_ready() -> Bool { Memory.shared.isReady() }
func ir_jit_memory_prepare(_ callback: Int) -> Bool { Memory.shared.prepared() }
let jit26_prepare_region = 1
func isDebuggerAttached() -> Bool { true }
@MainActor final class Host {
    enum CoordinatorError: Error { case setupRequired(String) }
    var enableRequest: UUID?, busy = false, status: String?, error: String?
    var builtInHelper: UUID? = UUID(), builtInHelperReleased: Bool?
    var enables = 0, detaches = 0, clean = true
BODY
    func enable(requiresAttachedDebugger: Bool, completion: (Result<Void, Error>) -> Void) {
        precondition(requiresAttachedDebugger); enables += 1; completion(.success(()))
    }
    func releaseAttachedDebugger(completion: (Bool) -> Void) { detaches += 1; completion(clean) }
    func prepare() async -> Bool {
        await withCheckedContinuation { c in prepareConsoleMemory { c.resume(returning: (try? $0.get()) != nil) } }
    }
}
@main struct Check {
    @MainActor static func main() async {
        let host = Host()
        precondition(await host.prepare())
        for _ in 0..<100 { precondition(await host.prepare()) }
        precondition(host.enables == 1 && host.detaches == 1 && Memory.shared.allocations == 1)
        Memory.shared.ready = false; Memory.shared.succeeds = false
        precondition(!(await host.prepare()) && !host.consoleMemoryRequiresRestart)
        Memory.shared.succeeds = true; host.clean = false
        precondition(!(await host.prepare()) && host.consoleMemoryRequiresRestart && host.error != nil)
        let attempts = host.enables
        precondition(!(await host.prepare()) && host.enables == attempts)
    }
}
'''.replace('BODY', body)
        # Swift's precondition autoclosure cannot await.
        fixture = fixture.replace('precondition(await host.prepare())', 'let ready = await host.prepare(); precondition(ready)')
        fixture = fixture.replace('precondition(!(await host.prepare()) &&', 'let failed = await host.prepare(); precondition(!failed &&', 1)
        fixture = fixture.replace('precondition(!(await host.prepare()) &&', 'let uncertain = await host.prepare(); precondition(!uncertain &&', 1)
        fixture = fixture.replace('precondition(!(await host.prepare()) &&', 'let rejected = await host.prepare(); precondition(!rejected &&', 1)
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            (folder / 'main.swift').write_text(fixture)
            subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', module_cache(),
                            str(folder / 'main.swift'), '-o', str(folder / 'check')], check=True, timeout=90)
            subprocess.run([str(folder / 'check')], check=True, timeout=15)
