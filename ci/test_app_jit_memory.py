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
#include "IRJITPrepare.h"
#include "IRJITReadiness.h"
#include "IRPSPExecutableMemory.h"
#include "IRSharedJITMemory.h"
#include <cassert>
#include <atomic>
#include <cstring>
#include <initializer_list>
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>
extern "C" bool ir_phase3_core_prepare_memory(const IRJITMemoryAPI *);
DOLPHIN_ADAPTER
static unsigned preparations;
static size_t lastPrepared;
static void *prepare(void *p, size_t bytes) {
    assert(!p); ++preparations; lastPrepared = bytes;
    void *rx = mmap((void *)0x7000000000ULL, bytes, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    assert((uintptr_t)rx >= (1ULL << 36)); // Same high placement observed on the phone.
    return rx;
}
static void emit(void *rx, void *rw, unsigned value) {
    const unsigned words[] = {0xd2800000u | (value << 5), 0xd65f03c0u};
    memcpy(rw, words, sizeof words);
    sys_dcache_flush(rw, sizeof words); sys_icache_invalidate(rx, sizeof words);
    assert(((unsigned (*)())rx)() == value);
}
static void shared() {
    const size_t page = getpagesize();
    IRJITWindowsRegion region[2];
    for (auto &r : region) {
        r.bytes = 4 * page;
        r.bootstrap = &r == region;
        r.rx = prepare(nullptr, r.bytes);
        vm_address_t alias = 0;
        vm_prot_t current, maximum;
        assert(vm_remap(mach_task_self(), &alias, r.bytes, 0, VM_FLAGS_ANYWHERE,
            mach_task_self(), (vm_address_t)r.rx, false, &current, &maximum, VM_INHERIT_NONE) == KERN_SUCCESS);
        assert(vm_protect(mach_task_self(), alias, r.bytes, false, VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS);
        r.rw = (void *)alias;
    }
    assert(ir_jit_memory_register_windows(region, 2));
    const size_t service = 16 * 1024 * 1024;
    assert(ir_jit_memory_prepare_sized(prepare, 8 * page) && preparations == 3 && lastPrepared == service);
    assert(ir_jit_memory_prepare_sized(prepare, service + 12 * page) && preparations == 4 && lastPrepared == 4 * page);
    static unsigned probes;
    assert(ir_jit_memory_verify([](void *rx, void *rw) -> bool {
        ++probes;
        return ir_jit_verify_aliases(rx, rw);
    }) && probes == 5);
    const auto *api = ir_jit_memory_api();
    auto wRX = (char *)region[1].rx + 3 * page;
    auto wRW = (char *)region[1].rw + 3 * page;
    void *rx, *rw, *reserve, *reserveWrite;
    assert(api->allocate(service + 4 * page, &reserve, &reserveWrite));
    assert(api->allocate(page, &rx, &rw));
    emit(rx, rw, 42);
    assert(((unsigned (*)())wRX)() == 42);
    assert(!ir_jit_windows_claim(wRX, page, true));
    assert(api->release(rx, page));
    assert(ir_jit_windows_claim(wRX, page, true));
    emit(wRX, wRW, 7);
    void *otherRX, *otherRW;
    assert(api->allocate(page, &otherRX, &otherRW) && otherRX != rx);
    assert(((unsigned (*)())rx)() == 7);
    ir_jit_windows_release_code(wRX, page);
    assert(api->allocate(page, &otherRX, &otherRW) && otherRX == rx && *(unsigned *)otherRW == 0);
    assert(api->release(rx, page));
    assert(ir_jit_windows_claim(wRX, page, false));
    ir_jit_windows_release_code(wRX, page);
    assert(api->allocate(page, &otherRX, &otherRW) && otherRX != rx);
}
int main(int argc, char **) {
    if (argc > 1) { shared(); return 0; }
    const auto *api = ir_jit_memory_api(); void *rx, *rw;
    assert(!api->allocate(8, &rx, &rw));
    assert(!ir_jit_memory_prepare(nullptr));
    const size_t switchPool = 544u * 1024 * 1024;
    assert(!ir_jit_memory_prepare_sized(prepare, switchPool + 1));
    assert(ir_jit_memory_prepare_sized(prepare, switchPool) && ir_jit_memory_ready());
    assert(ir_jit_memory_has_capacity(switchPool) && !ir_jit_memory_has_capacity(0));
    assert(!api->allocate(switchPool + 16384, &rx, &rw));
    assert(api->allocate(512u * 1024 * 1024, &rx, &rw));
    assert(!ir_jit_memory_prepare(prepare) && preparations == 1);
    emit(rx, rw, 42);
    assert(api->release(rx, 512u * 1024 * 1024));
    assert(!ir_jit_memory_prepare([](void *, size_t) -> void * { return nullptr; }));
    assert(ir_jit_memory_has_capacity(switchPool) && !ir_jit_memory_has_capacity(0));
    assert(ir_jit_memory_prepare(prepare) && ir_jit_memory_has_capacity(0));
    assert(ir_jit_memory_prepare_sized(prepare, switchPool) && preparations == 2);
    assert(ir_jit_verify_console_memory());
    void *otherRX, *otherRW;
    assert(api->allocate(8, &rx, &rw) && api->allocate(8, &otherRX, &otherRW));
    emit(rx, rw, 42);
    assert(!ir_jit_verify_aliases(rx, otherRW)); // The original code already returns 42.
    assert(*(uint64_t *)otherRW == 0 && ((unsigned (*)())rx)() == 42);
    assert(ir_jit_verify_aliases(rx, rw) && ((unsigned (*)())rx)() == 42);
    assert(api->release(rx, 8) && api->release(otherRX, 8));
    assert(!api->allocate(0, &rx, &rw) && !api->allocate(SIZE_MAX, &rx, &rw));
    assert(!api->allocate(1, nullptr, &rw));
    assert(ir_phase3_core_prepare_memory(api));
    void *smallA = ir_dolphin_jit_allocate(4096), *smallB = ir_dolphin_jit_allocate(4096);
    for (auto small : {smallA, smallB}) {
        assert(small && !((uintptr_t)small & (getpagesize() - 1)));
        assert(mprotect(small, 4096, PROT_READ | PROT_EXEC) == 0);
        emit(small, ir_shared_jit_write(small), 42);
        ir_dolphin_jit_release(small);
    }
    void *cacheWrite;
    void *cache = ir_shared_jit_allocate(256u * 1024 * 1024, &cacheWrite); // Dolphin's actual ARM64 cache.
    assert(cache && cacheWrite);
    emit(cache, cacheWrite, 42); emit(cache, cacheWrite, 7);
    ir_shared_jit_release(cache);
    assert(!ir_shared_jit_allocate(SIZE_MAX, &cacheWrite));
    assert(!ir_shared_jit_allocate(1153u * 1024 * 1024, &cacheWrite));
    void *contexts[8];
    for (auto &context : contexts) {
        assert(api->allocate(128u * 1024 * 1024, &context, &rw));
        emit(context, rw, 42);
    }
    void *shader;
    assert(api->allocate(32u * 1024 * 1024, &shader, &rw));
    emit(shader, rw, 7);
    assert(api->release(shader, 32u * 1024 * 1024));
    for (auto context : contexts) assert(api->release(context, 128u * 1024 * 1024));
    assert(api->allocate(512u * 1024 * 1024, &rx, &rw)); // Keep a large lease beside the other cores.
    assert((uintptr_t)rx >= (1ULL << 36));
    auto large = rx;
    assert(rx != rw && *(unsigned *)rw == 0);
    emit(rx, rw, 42); emit(rx, rw, 7);
    assert(!api->release(rw, 512u * 1024 * 1024));
    assert(!api->release((char *)rx + 16384, 16384));
    assert(!api->release(rx, 16384));
    assert(!api->allocate(641u * 1024 * 1024, &rx, &rw));
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
    assert(api->release(large, 512u * 1024 * 1024));
    assert(ir_jit_memory_ready() && preparations == 2);
}
'''
        dolphin = (BRIDGE / 'IRDolphin.mm').read_text()
        adapter = dolphin[dolphin.index('static std::atomic<ptrdiff_t> sharedDifference'):dolphin.index('static bool dolphinAlert')]
        source = source.replace('DOLPHIN_ADAPTER', adapter)
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            (folder / 'main.cpp').write_text(source)
            objects = []
            for name in ('IRJITMemory', 'IRJITReadiness', 'IRJITExecutionProbe'):
                obj = str(folder / (name + '.o'))
                subprocess.run(['clang', '-std=c11', '-I', str(BRIDGE), '-c',
                                str(BRIDGE / (name + '.c')), '-o', obj], check=True, timeout=30)
                objects.append(obj)
            subprocess.run(['clang++', '-std=c++17', '-I', str(BRIDGE), str(folder / 'main.cpp'),
                            str(BRIDGE / 'IRPSPExecutableMemory.cpp'), str(BRIDGE / 'IRSharedJITMemory.cpp'),
                            *objects, '-o', str(folder / 'check')], check=True, timeout=60)
            subprocess.run([str(folder / 'check'), 'shared'], check=True, timeout=30)
            subprocess.run([str(folder / 'check')], check=True, timeout=90)


class AppJITCoordinatorTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_windows_arena_retry_and_process_lifetime_reuse(self):
        from host_tests import module_cache
        text = (ROOT / 'iridium/apps/ios/App/JIT/StikJITHelper.swift').read_text()
        body = text[text.index('    struct PreparedPool'):text.index('    private static func createPool(')]
        fixture = """import Foundation
        func ir_jit_verify_aliases(_ rx: UnsafeMutableRawPointer, _ rw: UnsafeMutableRawPointer) -> Bool {
            let address = Int(bitPattern: rx)
            Pool.verifiedAddresses.append(address)
            return Int(bitPattern: rw) - address == 4096 && address != Pool.failedAddress
        }
        enum Pool {
            static var calls=0
            static var verifiedAddresses: [Int] = []
            static var failedAddress = 4224
            static func createPool(poolSize: Int) -> PreparedPool? {
                calls += 1
                if calls == 1{return nil}
                return PreparedPool(rx: UnsafeMutableRawPointer(bitPattern: 4096)!,
                                    rw: UnsafeMutableRawPointer(bitPattern: 8192)!,
                                    firstRegionBytes: 32, additionalRegions: [64..<96, 128..<poolSize],
                                    low: (2048, 512))
            }
        BODY
        }
        precondition(Pool.allocatePool(poolSize:128) == nil && Pool.calls==1)
        let first=Pool.allocatePool(poolSize:256)!
        for _ in 0..<1000{
            let next=Pool.allocatePool(poolSize:512)!
            precondition(next.rx==first.rx && next.rw==first.rw && next.size==256)
            precondition(next.holes == [32..<64, 96..<128] && next.low?.rx == 2048 && next.low?.size == 512)
        }
        precondition(Pool.calls==2 && !Pool.poolExecutionVerified)
        precondition(!Pool.verifyPreparedPool() && !Pool.poolExecutionVerified)
        Pool.verifiedAddresses.removeAll()
        Pool.failedAddress = 0
        precondition(Pool.verifyPreparedPool() && Pool.poolExecutionVerified)
        precondition(Pool.verifiedAddresses == [4096, 4160, 4224, 2048])
        let adjacent = Pool.PreparedPool(rx: first.rx, rw: first.rw, firstRegionBytes: 32,
                                         additionalRegions: [32..<96, 128..<256], low: nil)
        precondition(adjacent.holes == [96..<128] && adjacent.executableOffsets == [0, 32, 128])
        """.replace('BODY', body)
        with tempfile.TemporaryDirectory() as folder:
            folder=Path(folder);(folder/'main.swift').write_text(fixture)
            subprocess.run(['swiftc','-module-cache-path',module_cache(),str(folder/'main.swift'),'-o',str(folder/'check')],check=True,timeout=45)
            subprocess.run([str(folder/'check')],check=True,timeout=10)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_preparation_detach_reuse_and_failed_cleanup(self):
        from host_tests import module_cache
        text = (ROOT / 'iridium/apps/ios/App/JIT/JITSetup.swift').read_text()
        body = text[text.index('    private enum MemoryTarget'):text.index('    func enable(requiresAttachedDebugger:')]
        fixture = r'''
import Foundation
import Combine
final class Memory: @unchecked Sendable {
    static let shared = Memory()
    let lock = NSLock()
    var ready = false, windowsReady = false, windowsVerified = false, succeeds = true
    var attached = false, consoleCheckPasses = true
    var allocations = 0, windowsAllocations = 0, lastConsoleBytes: Int?
    var capacity: Int { lastConsoleBytes == 0 ? Int.max : lastConsoleBytes ?? 0 }
    func prepared(bytes: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        lastConsoleBytes = bytes
        allocations += 1; ready = succeeds; return ready
    }
    func isReady(_ bytes: Int = 16 * 1024) -> Bool {
        lock.lock(); defer { lock.unlock() }; return ready && (bytes == 0 ? capacity == Int.max : capacity >= bytes)
    }
    func windows() -> Bool { lock.lock(); defer { lock.unlock() }; windowsAllocations += 1; windowsReady = succeeds; return windowsReady }
    func isWindowsReady() -> Bool { lock.lock(); defer { lock.unlock() }; return windowsReady }
    func verifyWindows() -> Bool {
        precondition(!attached)
        windowsVerified = isWindowsReady()
        return windowsVerified
    }
}
func ir_jit_memory_has_capacity(_ bytes: Int) -> Bool { Memory.shared.isReady(bytes) }
func ir_jit_memory_prepare_sized(_ callback: Int, _ bytes: Int) -> Bool { Memory.shared.prepared(bytes: bytes) }
enum IridiumMadeiraRuntime {
    static func prepareJITMemory() -> Bool { Memory.shared.windows() }
    static let shared = Idle()
    struct Idle { let isBusy = false }
    static var jitMemoryPrepared: Bool { Memory.shared.isWindowsReady() }
    static var jitMemoryReady: Bool { Memory.shared.windowsVerified }
    static func verifyJITMemory() -> Bool { Memory.shared.verifyWindows() }
}
let ir_jit_prepare_region = 1
func isDebuggerAttached() -> Bool { Memory.shared.attached }
func ir_jit_verify_console_memory() -> Bool {
    precondition(!isDebuggerAttached())
    return Memory.shared.isReady() && Memory.shared.consoleCheckPasses
}
enum IridiumConsoleSession { static let shared = Idle(); struct Idle { let isActive = false } }
@MainActor enum LogStore { static let shared = Logger(); struct Logger { func log(_ text: String) {} } }
@MainActor final class RuntimePerformanceDiagnostics {
    static let shared = RuntimePerformanceDiagnostics()
    var phases: [String] = []
    func record(_ phase: String) { phases.append(phase) }
}
@MainActor final class Host {
    enum CoordinatorError: Error { case setupRequired(String) }
    var enableRequest: UUID?, busy = false, status: String?, error: String?, connectionProblem: String?
    var builtInHelper: UUID? = UUID(), builtInHelperReleased: Bool?
    var enables = 0, detaches = 0, clean = true
BODY
    func enable(requiresAttachedDebugger: Bool, builtInOnly: Bool, completion: (Result<Void, Error>) -> Void) {
        precondition(requiresAttachedDebugger && builtInOnly); enables += 1
        Memory.shared.attached = true
        completion(.success(()))
    }
    func releaseAttachedDebugger(completion: (Bool) -> Void) {
        detaches += 1
        if clean { Memory.shared.attached = false }
        completion(clean)
    }
    func offline() async -> Bool {
        await withCheckedContinuation { c in prepareOfflineMemory { c.resume(returning: (try? $0.get()) != nil) } }
    }
    func windows() async -> Bool {
        await withCheckedContinuation { c in prepareWindowsMemory { c.resume(returning: (try? $0.get()) != nil) } }
    }
    func prepare(bytes: Int = 0) async -> Bool {
        await withCheckedContinuation { c in
            prepareConsoleMemory(minimumBytes: bytes) { c.resume(returning: (try? $0.get()) != nil) }
        }
    }
}
@main struct Check {
    @MainActor static func main() async {
        let host = Host()
        let windows = await host.windows(); precondition(windows)
        precondition(Memory.shared.windowsAllocations == 1 && Memory.shared.allocations == 1)
        for _ in 0..<100 { let reused = await host.windows(); precondition(reused) }
        precondition(host.enables == 1 && host.detaches == 1)
        precondition(await host.prepare())
        for _ in 0..<100 { precondition(await host.prepare()) }
        precondition(host.enables == 2 && host.detaches == 2 && Memory.shared.allocations == 2)
        precondition(Memory.shared.windowsAllocations == 1)
        precondition(RuntimePerformanceDiagnostics.shared.phases == [
            "jit-windows-attach", "jit-windows-prepare", "jit-windows-ready",
            "jit-console-attach", "jit-console-prepare", "jit-console-ready",
        ])
        Memory.shared.ready = false; Memory.shared.succeeds = false
        precondition(!(await host.prepare()) && !host.consoleMemoryRequiresRestart)
        Memory.shared.succeeds = true; host.clean = false
        precondition(!(await host.prepare()) && host.consoleMemoryRequiresRestart && host.error != nil)
        let attempts = host.enables
        precondition(!(await host.prepare()) && host.enables == attempts)
        Memory.shared.ready = false; Memory.shared.windowsReady = false; Memory.shared.windowsVerified = false
        Memory.shared.attached = false
        let consoleFirst = Host()
        let minimumBytes = 544 * 1024 * 1024
        let consoleReady = await consoleFirst.prepare(bytes: minimumBytes); precondition(consoleReady)
        precondition(Memory.shared.windowsAllocations == 2 && Memory.shared.lastConsoleBytes == minimumBytes)
        let windowsReady = await consoleFirst.windows(); precondition(windowsReady)
        precondition(consoleFirst.enables == 1 && consoleFirst.detaches == 1)
        precondition(Memory.shared.windowsAllocations == 2)
        Memory.shared.ready = false; Memory.shared.windowsReady = false; Memory.shared.windowsVerified = false
        Memory.shared.consoleCheckPasses = false
        let offline = Host()
        let partial = await offline.offline()
        precondition(!partial && !offline.offlineMemoryReady && !offline.consoleMemoryRequiresRestart)
        precondition(Memory.shared.lastConsoleBytes == 0)
        precondition(offline.enables == 1 && offline.detaches == 1 && Memory.shared.windowsVerified)
        Memory.shared.consoleCheckPasses = true
        let verified = await offline.offline()
        precondition(verified && offline.offlineMemoryReady)
        let windowsAfterConsole = await offline.windows()
        let consoleAfterWindows = await offline.prepare()
        precondition(windowsAfterConsole && consoleAfterWindows && offline.enables == 1 && offline.detaches == 1)
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
