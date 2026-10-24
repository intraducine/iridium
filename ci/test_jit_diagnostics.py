"""Execute journal durability/failure boundaries without a phone or live debugger."""
from host_tests import module_cache
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'


@unittest.skipUnless(shutil.which('clang'), 'C compiler required')
class JITDiagnosticTests(unittest.TestCase):
    @unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'Darwin Swift required')
    def test_observation_failure_and_terminal_reason_are_durable_and_exported(self):
        fixture = r'''
import Foundation
@main struct Check {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let diagnostic: IridiumJITDiagnostic? = await withCheckedContinuation { continuation in
            IridiumJITDiagnostic.create(directory: directory, identity: "source=fixture build=1") {
                continuation.resume(returning: $0)
            }
        }
        precondition(diagnostic != nil)
        let observed: Bool = await withCheckedContinuation { continuation in
            diagnostic!.mark(IR_JIT_OBSERVATION_FAILED, pass: UInt32(IR_PSP_OBSERVATION_HOST_ROUTES.rawValue),
                             value: 14, error: 4) { continuation.resume(returning: $0) }
        }
        let terminal: Bool = await withCheckedContinuation { continuation in
            diagnostic!.mark(IR_JIT_FALLBACK, value: 1) { continuation.resume(returning: $0) }
        }
        precondition(observed && terminal)
        let original = try Data(contentsOf: directory.appendingPathComponent("iridium-psp-jit-stages.log"))
        let raw = String(decoding: original, as: UTF8.self)
        precondition(raw.contains("stage=observation.failed pass=5 value=14 error=4"))
        precondition(raw.contains("stage=fallback pass=0 value=1 error=0"))
        precondition(raw.range(of: "observation.failed")!.lowerBound < raw.range(of: "stage=fallback")!.lowerBound)
        let exported = try RuntimeDiagnosticLogFiles.export(in: directory, destination: directory)
        let text = try String(contentsOf: exported, encoding: .utf8)
        precondition(text.contains("stage=observation.failed pass=5 value=14 error=4"))
        precondition(text.contains("stage=fallback pass=0 value=1 error=0"))
        let after = try Data(contentsOf: directory.appendingPathComponent("iridium-psp-jit-stages.log"))
        precondition(after == original)
        precondition(!text.contains("stage=activation.enter") && !text.contains("stage=exec.enter"))
        print("PASS real Swift-to-C durable observation/fallback records and normal sanitized export; original preserved")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); data = root / 'logs'; data.mkdir()
            bridge = root / 'bridge.o'
            subprocess.run(['clang', '-c', str(BRIDGE / 'IRPSPNativeBridge.c'), '-o', str(bridge)], check=True)
            audio = root / 'audio.o'
            subprocess.run(['clang', '-c', str(BRIDGE / 'IRAudioVolume.c'), '-o', str(audio)], check=True)
            main = root / 'check.swift'; main.write_text(fixture)
            runtime = root / 'RuntimeDiagnosticLogFiles.swift'
            runtime.write_text((ROOT / 'iridium/apps/ios/Iridium/RuntimeDiagnosticLogFiles.swift').read_text().replace(
                'consoleSink = RuntimeConsoleLogSink()',
                'consoleSink = RuntimeConsoleLogSink(directory: URL(fileURLWithPath: CommandLine.arguments[1]))'))
            binary = root / 'check'
            command = ['swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', module_cache('macosx'),
                       '-import-objc-header', str(BRIDGE / 'IRPSPNativeBridge.h'),
                       str(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumJITDiagnostic.swift'),
                       str(runtime), str(main), str(bridge), str(audio), '-o', str(binary)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            subprocess.run([str(binary), str(data)], check=True, timeout=20)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_production_watchdog_retains_owner_and_ignores_returned_or_stale_worker(self):
        launch = (ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumPSPExecutableLaunch.swift').read_text()
        start = launch.index('DispatchQueue.main.asyncAfter(deadline: .now() + 5)')
        timer = launch[start:launch.index('\n        }\n    }', start)].replace('DispatchQueue.main.asyncAfter', 'clock.asyncAfter')
        fixture = r'''
import Foundation
@MainActor final class FixtureClock {
    var scheduled: [() -> Void] = []
    func asyncAfter(deadline: DispatchTime, execute: @escaping () -> Void) { scheduled.append(execute) }
    func fire() {
        let callbacks = scheduled; scheduled.removeAll()
        for callback in callbacks { callback() }
    }
}
@MainActor final class Session {
    enum Phase { case starting, stopping, restartRequired }
    enum Outcome { case restart(String) }
    var lease = 1, phase = Phase.starting, error: String?, finished = false
    var diagnostic: IridiumJITDiagnostic!
    var cleanups = 0, launches = 0
    let admission: UInt64 = 1
    let clock: FixtureClock
    init(_ clock: FixtureClock) { self.clock = clock }
    func cancel() {}
    func finish(_ outcome: Outcome) { finished = true; phase = .restartRequired; if case .restart(let message) = outcome { error = message } }
    func watch(_ diagnostic: IridiumJITDiagnostic, returned: Bool) {
        self.diagnostic = diagnostic
        let worker = IridiumJITWorkerReceipt(); worker.returned = returned
        TIMER
    }
}
@main struct Checks {
    @MainActor static func main() async {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let diagnostic: IridiumJITDiagnostic? = await withCheckedContinuation { continuation in
            IridiumJITDiagnostic.create(directory: directory, identity: "source=fixture build=1") { continuation.resume(returning: $0) }
        }
        precondition(diagnostic != nil)
        let clock = FixtureClock()
        let stopped = Session(clock), returned = Session(clock), stale = Session(clock), stopping = Session(clock)
        stopped.watch(diagnostic!, returned: false)
        returned.watch(diagnostic!, returned: true)
        stale.watch(diagnostic!, returned: false); stale.finished = true
        stopping.watch(diagnostic!, returned: false); stopping.phase = .stopping
        // Drive every production callback, then await the real serial journal.
        // Sleeping cannot prove that utility-queue writes have reached disk.
        precondition(clock.scheduled.count == 4)
        clock.fire()
        let persisted: Bool = await withCheckedContinuation { continuation in
            diagnostic!.mark(IR_JIT_CANCEL) { continuation.resume(returning: $0) }
        }
        precondition(persisted)
        precondition(stopped.phase == .restartRequired && stopped.lease == 1 && stopped.error != nil)
        precondition(stopped.cleanups == 0 && stopped.launches == 0)
        precondition(returned.phase == .starting && returned.error == nil)
        precondition(stale.phase == .starting && stale.error == nil && stopping.phase == .restartRequired)
        let text = try! String(contentsOf: directory.appendingPathComponent("iridium-psp-jit-stages.log"), encoding: .utf8)
        precondition(text.components(separatedBy: "stage=timeout").count == 3)
        print("PASS production watchdog retains ownership for a live/stopping worker and ignores returned/completed workers")
    }
}
'''.replace('TIMER', timer)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); data = root / 'logs'; data.mkdir()
            bridge = root / 'bridge.o'
            subprocess.run(['clang', '-c', str(BRIDGE / 'IRPSPNativeBridge.c'), '-o', str(bridge)], check=True)
            audio = root / 'audio.o'
            subprocess.run(['clang', '-c', str(BRIDGE / 'IRAudioVolume.c'), '-o', str(audio)], check=True)
            main = root / 'checks.swift'; main.write_text(fixture); binary = root / 'check'
            support = ROOT / 'iridium/apps/ios/RuntimeSupport'
            subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', module_cache('macosx'),
                            '-import-objc-header', str(BRIDGE / 'IRPSPNativeBridge.h'),
                            str(support / 'IridiumJITDiagnostic.swift'), str(support / 'IridiumJITRequest.swift'),
                            str(main), str(bridge), str(audio), '-o', str(binary)], check=True)
            subprocess.run([str(binary), str(data)], check=True, timeout=20)

    def test_production_preflight_failure_stages_and_no_false_capability(self):
        native = (BRIDGE / 'IRPPSSPPNative.mm').read_text()
        logs = native[native.index('static thread_local const IRJITDiagnosticSink *preflightLogSink;'):native.index('@implementation IRPPSSPPContainer')]
        check = native[native.index('int ir_native_psp_check_jit(void)'):native.index('uint32_t ir_native_psp_abi(void)')]
        fixture = r'''
#include "IRJITDiagnostic.h"
#include "IRPSPExecutableMemory.h"
#include <atomic>
#include <cassert>
#include <cstring>
#include <cstdio>
#include <string>
#include <vector>
#include <unistd.h>
#define TARGET_OS_SIMULATOR 0
#define PPSSPP_ARCH(x) 1
enum class LogLevel { LERROR = 2 };
enum class LogOutput { None = 0, ExternalCallback = 1 };
struct LogMessage { std::string msg; LogLevel level; const char *log; };
struct LogManager {
    LogOutput output = LogOutput::None;
    void (*callback)(const LogMessage &, void *) = nullptr;
    LogOutput GetOutputsEnabled() { return output; }
    void SetOutputsEnabled(LogOutput value) { output = value; }
    void EnableOutput(LogOutput value) { output = value; }
    void SetExternalLogCallback(void (*value)(const LogMessage &, void *), void *) { callback = value; }
} g_logManager;
static unsigned forwarded;
static void event(unsigned, const char *) { ++forwarded; }
LOGS
static std::atomic<bool> jitProbeVerified;
static bool container;
static int mode, allocations, frees, protections, emissions, executions;
static unsigned char allocation[8];
static int csops(int, int, void *flags, size_t) { *(uint32_t *)flags = mode == 1 ? 0 : 0x10000000; return 0; }
static void *AllocateExecutableMemory(size_t size) {
    assert(size == 16 * 1024 * 1024); ++allocations;
    if (mode == 2) { g_logManager.callback({"Failed to allocate executable memory (16777216) errno=12", LogLevel::LERROR, "MemMap"}, nullptr); return nullptr; }
    return allocation;
}
static void FreeExecutableMemory(void *p, size_t) { assert(p == allocation); ++frees; }
static size_t GetMemoryProtectPageSize() { return 16384; }
enum { MEM_PROT_READ=1, MEM_PROT_WRITE=2, MEM_PROT_EXEC=4 };
static bool ProtectMemoryPages(void *, size_t, int) {
    ++protections;
    if ((mode == 3 && protections == 1) || (mode == 4 && protections == 2)) {
        g_logManager.callback({"mprotect failed (private-address)! errno=13 (Permission denied)", LogLevel::LERROR, "MemMap"}, nullptr); return false;
    }
    return true;
}
namespace Arm64Gen {
enum { W0 };
struct ARM64CodeBlock {
    unsigned char *base = nullptr, *ptr = nullptr;
    size_t size = 0, estimate = 0;
    ~ARM64CodeBlock() { if (base) FreeCodeSpace(); }
    void AllocCodeSpace(size_t bytes, unsigned = 0) { size = bytes; base = ptr = (unsigned char *)AllocateExecutableMemory(size); }
    unsigned char *GetBasePtr() { return base; }
    unsigned char *GetWritablePtrFromCodePtr(const unsigned char *p) { return base + (p - base); }
    void ResetCodePtr(size_t offset) { assert(base); ptr = base + offset; }
    bool BeginWrite(size_t bytes) { estimate = bytes; return ProtectMemoryPages(base, estimate, MEM_PROT_READ | MEM_PROT_WRITE); }
    bool EndWrite() { return ProtectMemoryPages(base, estimate, MEM_PROT_READ | MEM_PROT_EXEC); }
    void FreeCodeSpace() {
        ProtectMemoryPages(base, size, MEM_PROT_READ | MEM_PROT_WRITE);
        FreeExecutableMemory(base, size); base = ptr = nullptr;
    }
    void MOVI2R(int, int value) { ++emissions; uint32_t word = 0x52800000u | (value << 5); memcpy(ptr, &word, 4); ptr += 4; }
    void RET() { uint32_t word = 0xd65f03c0; memcpy(ptr, &word, 4); ptr += 4; }
    const unsigned char *GetCodePointer() { return ptr; }
    void FlushIcache() {}
};
}
static bool ir_jit_probe_execute_diagnostic(void *, size_t, int value, const IRJITDiagnosticSink *, uint32_t pass) {
    ++executions; assert(value == (pass == 1 ? 42 : 7)); return mode != 5;
}
int ir_native_psp_check_jit_diagnostic(const IRJITDiagnosticSink *);
CHECK
struct Record { IRJITDiagnosticStage stage; unsigned pass; int64_t value; int error; };
static std::vector<Record> records;
static IRJITDiagnosticStage refused;
static bool healthy;
static bool mark(void *, IRJITDiagnosticStage stage, uint32_t pass, int64_t value, int error) {
    records.push_back({stage, pass, value, error}); if (stage == refused) healthy = false; return healthy;
}
int main() {
    IRJITDiagnosticSink sink = {nullptr, mark};
    int expected[] = {1, -4, -2, -3, -3, 0, -6, -6, -6};
    for (mode = 0; mode < 9; ++mode) {
        allocations = frees = protections = emissions = executions = 0;
        records.clear(); healthy = true;
        refused = mode == 6 ? IR_JIT_EMIT_ENTER : mode == 7 ? IR_JIT_CODE_WORD_0 : mode == 8 ? IR_JIT_PROBE_BASE : (IRJITDiagnosticStage)0;
        jitProbeVerified = true;
        assert(ir_native_psp_check_jit_diagnostic(&sink) == expected[mode]);
        assert(jitProbeVerified == (mode == 0));
        assert(g_logManager.output == LogOutput::None && preflightLogSink == nullptr && forwarded == 0);
        assert(records.front().stage == IR_JIT_NATIVE_ENTER && records.back().stage == IR_JIT_NATIVE_RETURN);
        assert(records.back().value == expected[mode]);
        assert(frees == (mode == 1 || mode == 2 ? 0 : 1));
        if (mode == 0) {
            assert(allocations == 1 && protections == 5 && executions == 2 && emissions == 2);
            unsigned lengths = 0, words = 0, bases = 0;
            bool cached = false, rx = false;
            for (auto record : records) {
                if (record.stage == IR_JIT_PROBE_BASE) { ++bases; assert(record.value == (int64_t)(uintptr_t)allocation); }
                if (record.stage == IR_JIT_CACHE_ENTER) { cached = true; rx = false; }
                if (record.stage == IR_JIT_RX_ENTER) { assert(cached); rx = true; cached = false; }
                if (record.stage == IR_JIT_RX_RETURN) assert(rx);
                if (record.stage == IR_JIT_CODE_LENGTH) { ++lengths; assert(record.value == 8); }
                if (record.stage == IR_JIT_CODE_WORD_0) { ++words; assert(record.value == (record.pass == 1 ? 0x52800540u : 0x528000e0u)); }
                if (record.stage == IR_JIT_CODE_WORD_1) { ++words; assert(record.value == 0xd65f03c0u); }
                assert(record.stage != IR_JIT_CODE_WORD_2 && record.stage != IR_JIT_CODE_WORD_3);
            }
            assert(lengths == 2 && words == 4 && bases == 1);
        }
        if (mode == 3 || mode == 4 || mode == 6 || mode == 7 || mode == 8) assert(executions == 0);
        if (mode == 6 || mode == 8) assert(emissions == 0);
        if (mode == 8) assert(protections == 1); // Upstream release restores RW before freeing.
        if (mode == 2 || mode == 3 || mode == 4) {
            bool found = false;
            for (auto record : records) if (record.stage == (mode == 2 ? IR_JIT_ALLOC_ERROR : IR_JIT_PROTECT_ERROR)) {
                found = true; assert(record.error == (mode == 2 ? 12 : 13));
            }
            assert(found);
        }
    }
    puts("PASS production preflight stages: csops/alloc/RW/RX/probe/journal failures, pass 1/2, early error sink, cleanup, restored outputs and no false capability");
}
'''.replace('LOGS', logs).replace('CHECK', check)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'preflight.cpp'; source.write_text(fixture); binary = root / 'check'
            subprocess.run(['clang++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-I', str(BRIDGE),
                            str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=10)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_swift_cancelled_worker_retains_journal_until_cleanup(self):
        component = r'''
#include "IRJITDiagnostic.h"
#include <unistd.h>
uint32_t ir_native_psp_abi(void) { return 3; }
int ir_native_psp_check_jit(void) { return 1; }
int ir_native_psp_check_jit_diagnostic(const IRJITDiagnosticSink *sink) {
    if (!ir_jit_diagnostic_mark(sink, IR_JIT_NATIVE_ENTER, 0, 0, 0)) return -6;
    usleep(500000);
    return ir_jit_diagnostic_mark(sink, IR_JIT_NATIVE_RETURN, 0, 1, 0) ? 1 : -6;
}
void *ir_native_psp_create(void) { return 0; }
void ir_native_psp_pause(void) {}
void ir_native_psp_resume(void) {}
int ir_native_psp_request(void) { return 0; }
int ir_native_psp_resolution(void) { return 2; }
void ir_native_psp_stop(void) {}
uint64_t ir_native_psp_frames(void) { return 0; }
'''
        fixture = r'''
import Foundation
@main struct Checks {
    @MainActor static func main() async {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let component = CommandLine.arguments[2]
        let log = directory.appendingPathComponent("iridium-psp-jit-stages.log")
        func open() async -> IridiumJITDiagnostic? {
            await withCheckedContinuation { continuation in
                IridiumJITDiagnostic.create(directory: directory, identity: "source=fixture build=1") { continuation.resume(returning: $0) }
            }
        }
        func contents() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
        var owner = await open(); precondition(owner != nil)
        weak var retained = owner
        let request = IridiumJITRequest()
        var launches = 0, workerReturned = false, restored = false
        request.start(requested: true, activate: { $0(.success(())) }, validate: { completion in
            let workerOwner = owner!
            DispatchQueue.global().async {
                let result = workerOwner.check(component: component)
                DispatchQueue.main.async {
                    precondition(result == 1 && contents().contains("stage=worker.return"))
                    workerReturned = true; completion(.success(()))
                }
            }
        }, cleanup: { [cleanupOwner = owner!] done in
            precondition(workerReturned)
            cleanupOwner.mark(IR_JIT_RESTORE_RETURN) { persisted in
                precondition(persisted && contents().contains("stage=restore.return"))
                restored = true; done()
            }
        }, completed: { _ in launches += 1 })
        while !contents().contains("stage=native.enter") { try! await Task.sleep(nanoseconds: 1000000) }
        request.cancel()
        owner?.mark(IR_JIT_CANCEL)
        owner = nil
        precondition(retained != nil)
        let overlapping = await open(); precondition(overlapping == nil)
        while !restored { try! await Task.sleep(nanoseconds: 1000000) }
        precondition(launches == 0 && workerReturned)
        while retained != nil { try! await Task.sleep(nanoseconds: 1000000) }
        let text = contents()
        precondition(text.contains("stage=cancel") && text.contains("stage=worker.return"))
        let later = await open(); precondition(later != nil)
        precondition(FileManager.default.fileExists(atPath: directory.appendingPathComponent("iridium-psp-jit-stages.previous.log").path))
        let saved = await withCheckedContinuation { continuation in
            later!.mark(IR_JIT_MAIN_RESULT, value: -3) { continuation.resume(returning: $0) }
        }
        precondition(saved && contents().contains("stage=main.result pass=0 value=-3"))
        print("PASS cancellation retains worker/journal, stale result cannot launch, cleanup is durable before callback, overlap declines and later rotation succeeds")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); data = root / 'logs'; data.mkdir()
            source = root / 'component.c'; source.write_text(component); library = root / 'component.dylib'
            subprocess.run(['clang', '-shared', '-fPIC', '-I', str(BRIDGE), str(source), '-o', str(library)], check=True)
            bridge = root / 'bridge.o'
            subprocess.run(['clang', '-c', str(BRIDGE / 'IRPSPNativeBridge.c'), '-o', str(bridge)], check=True)
            audio = root / 'audio.o'
            subprocess.run(['clang', '-c', str(BRIDGE / 'IRAudioVolume.c'), '-o', str(audio)], check=True)
            main = root / 'main.swift'; main.write_text(fixture); binary = root / 'check'
            support = ROOT / 'iridium/apps/ios/RuntimeSupport'
            subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '5', '-module-cache-path', module_cache('macosx'),
                            '-import-objc-header', str(BRIDGE / 'IRPSPNativeBridge.h'),
                            str(support / 'IridiumJITDiagnostic.swift'), str(support / 'IridiumJITRequest.swift'),
                            str(main), str(bridge), str(audio), '-o', str(binary)], check=True)
            subprocess.run([str(binary), str(data), str(library)], check=True, timeout=20)

    @unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Apple Silicon host required')
    def test_probe_stage_order_recovery_and_refused_execution(self):
        fixture = r'''
#include "IRJITExecutionProbe.c"
#include <assert.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>
static IRJITDiagnosticStage stages[64], refused;
static unsigned count, expected_pass;
static int calls;
static bool mark(void *context, IRJITDiagnosticStage stage, uint32_t pass, int64_t value, int error) {
    (void)context; (void)error;
    assert(!executing && pass == expected_pass && count < 64);
    sigset_t mask; assert(!sigprocmask(SIG_BLOCK, NULL, &mask));
    // A callback before siglongjmp in our handler would still have its fault
    // signal blocked. Recovery callbacks must run after the saved mask returns.
    for (int i = 0; i < 3; ++i) assert(sigismember(&mask, signals[i]) == 0);
    if (stage == IR_JIT_RECOVERED_SIGNAL) assert(value == SIGILL || value == SIGBUS || value == SIGSEGV);
    if (stage == IR_JIT_SIGNAL_OFFSET) assert(value == 0);
    if (stage == IR_JIT_HANDLERS_RESTORED) assert(value == 1);
    stages[count++] = stage;
    return stage != refused;
}
static int64_t should_not_execute(void) { ++calls; return 42; }
static void verify(bool recovered) {
    assert(stages[0] == IR_JIT_GUARD_ENTER && stages[1] == IR_JIT_GUARD_READY && stages[2] == IR_JIT_EXEC_ENTER);
    assert(stages[3] == IR_JIT_CALL_ENTER);
    assert(stages[4] == (recovered ? IR_JIT_RECOVERED_SIGNAL : IR_JIT_EXEC_RETURN));
    if (recovered) assert(stages[5] == IR_JIT_SIGNAL_OFFSET);
    assert(stages[count - 2] == IR_JIT_HANDLERS_RESTORE_ENTER && stages[count - 1] == IR_JIT_HANDLERS_RESTORED);
}
int main(void) {
    size_t size = (size_t)getpagesize();
    void *page = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); assert(page != MAP_FAILED);
    uint32_t code[] = {0xd2800540, 0xd65f03c0}; memcpy(page, code, sizeof code);
    IRJITDiagnosticSink sink = {NULL, mark};
    expected_pass = 1;
    assert(!ir_jit_probe_execute_diagnostic(page, size, 42, &sink, 1)); verify(true);
    assert(!mprotect(page, size, PROT_READ | PROT_EXEC)); sys_icache_invalidate(page, size);
    count = 0; assert(ir_jit_probe_execute_diagnostic(page, size, 42, &sink, 1)); verify(false);
    assert(!mprotect(page, size, PROT_READ | PROT_WRITE)); code[0] = 0xd28000e0; memcpy(page, code, sizeof code);
    sys_icache_invalidate(page, size); assert(!mprotect(page, size, PROT_READ | PROT_EXEC));
    expected_pass = 2; count = 0;
    assert(ir_jit_probe_execute_diagnostic(page, size, 7, &sink, 2)); verify(false);
    assert(!mprotect(page, size, PROT_READ | PROT_WRITE)); memset(page, 0, sizeof code);
    sys_icache_invalidate(page, size); assert(!mprotect(page, size, PROT_READ | PROT_EXEC));
    count = 0; assert(!ir_jit_probe_execute_diagnostic(page, size, 7, &sink, 2)); verify(true);
    count = 0; refused = IR_JIT_EXEC_ENTER;
    assert(!ir_jit_probe_execute_diagnostic((void *)should_not_execute, 1, 42, &sink, 2));
    assert(!calls && stages[count - 1] == IR_JIT_HANDLERS_RESTORED);
    count = 0; refused = IR_JIT_CALL_ENTER;
    assert(!ir_jit_probe_execute_diagnostic((void *)should_not_execute, 1, 42, &sink, 2));
    assert(!calls && stages[count - 1] == IR_JIT_HANDLERS_RESTORED);
    assert(!munmap(page, size));
    puts("PASS ordered pass 1/2, NX/SIGILL recovery in normal context, restoration, refused durable boundary prevents execution");
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); source = root / 'probe.c'; source.write_text(fixture)
            binary = root / 'probe'
            subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(BRIDGE),
                            str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=20)

    def test_bounded_durable_records_rotation_and_io_failure(self):
        fixture = r'''
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
static int fault, writes, syncs;
static ssize_t fixture_write(int fd, const void *p, size_t n) {
    ++writes;
    if (fault == 1) { fault = 2; errno = EINTR; return -1; }
    if (fault == 2) { fault = 0; return write(fd, p, n / 2); }
    if (fault == 3) { errno = ENOSPC; return -1; }
    return write(fd, p, n);
}
static int fixture_sync(int fd) { ++syncs; if (fault == 4) { errno = EIO; return -1; } return fsync(fd); }
#define write fixture_write
#define fsync fixture_sync
#include "IRPSPNativeBridge.c"
#undef write
#undef fsync
_Static_assert(IR_JIT_APP_IMAGE_UUID_LOW == 59, "Existing diagnostic ABI must not move");
_Static_assert(IR_JIT_OBSERVATION_FAILED == 60 && IR_JIT_FALLBACK == 61, "Append new stages only");
int main(int argc, char **argv) {
    assert(argc == 2);
    // No close/deinit/shutdown hook: the already-synchronized boundary survives exit.
    pid_t child = fork(); assert(child >= 0);
    if (!child) {
        IRPSPJITDiagnostic *j = ir_psp_jit_diagnostic_open(argv[1], "source=fixture build=1");
        assert(j);
        fault = 1; errno = EDOM;
        assert(ir_psp_jit_diagnostic_mark(j, IR_JIT_EXEC_ENTER, 2, 7, 0));
        assert(errno == EDOM && writes >= 4 && syncs == 2);
        _exit(77);
    }
    int status; assert(waitpid(child, &status, 0) == child && WEXITSTATUS(status) == 77);
    char path[4096], bytes[32769];
    snprintf(path, sizeof path, "%s/iridium-psp-jit-stages.log", argv[1]);
    int fd = open(path, O_RDONLY); assert(fd >= 0);
    ssize_t count = read(fd, bytes, sizeof bytes - 1); assert(count > 0); bytes[count] = 0; close(fd);
    assert(strstr(bytes, "stage=exec.enter pass=2 value=7 error=0"));
    assert(!strstr(bytes, "exec.return"));
    IRPSPJITDiagnostic *j = ir_psp_jit_diagnostic_open(argv[1], "source=fixture build=2"); assert(j);
    // A cancelled callback/worker may still retain the old descriptor. A new
    // attempt must decline rather than rotate or unlink that live journal.
    assert(!ir_psp_jit_diagnostic_open(argv[1], "source=fixture build=overlap"));
    assert(ir_psp_jit_diagnostic_mark(j, IR_JIT_CANCEL, 0, 0, 0));
    snprintf(path, sizeof path, "%s/iridium-psp-jit-stages.previous.log", argv[1]);
    fd = open(path, O_RDONLY); assert(fd >= 0); close(fd);
    fault = 4;
    assert(!ir_psp_jit_diagnostic_mark(j, IR_JIT_ALLOC_ENTER, 0, 16, 0));
    fault = 0;
    assert(!ir_psp_jit_diagnostic_healthy(j));
    assert(!ir_psp_jit_diagnostic_mark(j, IR_JIT_EXEC_ENTER, 0, 42, 0));
    ir_psp_jit_diagnostic_close(j);
    j = ir_psp_jit_diagnostic_open(argv[1], "source=fixture build=3"); assert(j);
    fault = 3; assert(!ir_psp_jit_diagnostic_mark(j, IR_JIT_RW_ENTER, 1, 0, 0));
    fault = 0; ir_psp_jit_diagnostic_close(j);
    j = ir_psp_jit_diagnostic_open(argv[1], "source=fixture build=4"); assert(j);
    unsigned records = 0;
    while (ir_psp_jit_diagnostic_mark(j, IR_JIT_MAIN_RESULT, 0, 1, 0)) { assert(++records < 1000); }
    assert(j->bytes <= 32768 && !ir_psp_jit_diagnostic_healthy(j));
    ir_psp_jit_diagnostic_close(j);
    assert(!ir_psp_jit_diagnostic_open(argv[1], "private/path or token\n"));
    puts("PASS synchronized exit boundary, short writes/EINTR, write/fsync failure, bounded journal, rotation and identity validation");
}
'''
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); data = root / 'logs'; data.mkdir()
            source = root / 'check.c'; source.write_text(fixture)
            binary = root / 'check'
            subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(BRIDGE),
                            str(source), str(BRIDGE / 'IRAudioVolume.c'), '-lpthread', '-ldl', '-o', str(binary)], check=True)
            subprocess.run([str(binary), str(data)], check=True, timeout=20)

    def test_prepared_api_version_mismatch_never_calls_old_component(self):
        component = r'''
#include "IRPSPExecutableMemory.h"
uint32_t ir_native_psp_abi(void){return 3;}
int ir_native_psp_check_jit(void){return 0;}
void *ir_native_psp_create(void){return 0;}
void ir_native_psp_pause(void){} void ir_native_psp_resume(void){}
int ir_native_psp_request(void){return 0;} int ir_native_psp_resolution(void){return 2;}
void ir_native_psp_stop(void){} uint64_t ir_native_psp_frames(void){return 0;}
uint32_t ir_native_psp_exec_version(void){return VERSION;}
int ir_native_psp_exec_prepare(const IRPSPExecHost *h){return h->version==IR_PSP_EXEC_VERSION?73:74;}
int ir_native_psp_exec_prepare_diagnostic(const IRPSPExecHost *h,const IRJITDiagnosticSink *s){(void)s;return ir_native_psp_exec_prepare(h);}
int ir_native_psp_exec_detach(uint64_t a){return 75;}
int ir_native_psp_exec_accept_shutdown(const IRPSPExecShutdown *r){return 75;}
int ir_native_psp_exec_restored(uint64_t a,bool b){return 75;}
int ir_native_psp_exec_restored_diagnostic(uint64_t a,bool b,const IRJITDiagnosticSink *s){return 75;}
int ir_native_psp_exec_end(uint64_t a){return 75;}
void ir_native_psp_exec_cancel(uint64_t a){}
'''
        main = r'''
#include "IRPSPNativeBridge.h"
#include <assert.h>
int main(int argc,char **argv){
    assert(argc==3);IRPSPJITDiagnostic *j=ir_psp_jit_diagnostic_open(argv[2],"source=fixture build=2");assert(j);
    IRPSPExecHost h={0};h.version=IR_PSP_EXEC_VERSION;
    assert(ir_psp_native_exec_prepare(argv[1],&h,j)==EXPECTED);
    assert(ir_psp_native_exec_end(1)==END_RESULT);ir_psp_jit_diagnostic_close(j);
}
'''
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'component.c').write_text(component);(root/'main.c').write_text(main)
            for version,expected,end in [(1,'IR_PSP_EXEC_UNAVAILABLE',0),(2,'IR_PSP_EXEC_UNAVAILABLE',0),(3,'73',75)]:
                lib=root/f'version{version}.dylib';exe=root/f'check{version}';logs=root/f'logs{version}';logs.mkdir()
                subprocess.run(['clang','-shared','-fPIC','-I',str(BRIDGE),f'-DVERSION={version}',str(root/'component.c'),'-o',str(lib)],check=True)
                subprocess.run(['clang','-I',str(BRIDGE),f'-DEXPECTED={expected}',f'-DEND_RESULT={end}',str(root/'main.c'),str(BRIDGE/'IRPSPNativeBridge.c'),str(BRIDGE/'IRAudioVolume.c'),'-o',str(exe)],check=True)
                subprocess.run([str(exe),str(lib),str(logs)],check=True,timeout=15)
        print('PASS real loader: v1/v2 rejected without invoking cached old callbacks; allocation API v3 negotiated')

    def test_loader_stage_order_and_missing_diagnostic_declines(self):
        fixture = r'''
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
static const char *refused;
static bool refuse_sync;
static ssize_t fixture_write(int fd, const void *bytes, size_t count) {
    if (refused && count < 192) {
        char line[192]; memcpy(line, bytes, count); line[count] = 0;
        if (strstr(line, refused)) refuse_sync = true;
    }
    return write(fd, bytes, count);
}
static int fixture_sync(int fd) { if (refuse_sync) { errno = EIO; return -1; } return fsync(fd); }
#define write fixture_write
#define fsync fixture_sync
#include "IRPSPNativeBridge.c"
#undef write
#undef fsync
int main(int argc, char **argv) {
    assert(argc == 4);
    if (strcmp(argv[3], "none")) refused = argv[3];
    IRPSPJITDiagnostic *j = ir_psp_jit_diagnostic_open(argv[2], "source=fixture build=1"); assert(j);
    int result = ir_psp_native_check_jit_diagnostic(argv[1], j);
    assert(result == (refused ? -6 : EXPECTED));
    assert(ir_psp_jit_diagnostic_healthy(j) == !refused);
    ir_psp_jit_diagnostic_close(j);
}
'''
        component = r'''
#include "IRJITDiagnostic.h"
#include <stdint.h>
uint32_t ir_native_psp_abi(void) { return 3; }
int ir_native_psp_check_jit(void) { return 1; }
void *ir_native_psp_create(void) { return 0; }
void ir_native_psp_pause(void) {}
void ir_native_psp_resume(void) {}
int ir_native_psp_request(void) { return 0; }
int ir_native_psp_resolution(void) { return 2; }
void ir_native_psp_stop(void) {}
uint64_t ir_native_psp_frames(void) { return 0; }
DIAGNOSTIC
'''
        method = '''int ir_native_psp_check_jit_diagnostic(const IRJITDiagnosticSink *sink) {
    if (!ir_jit_diagnostic_mark(sink, IR_JIT_NATIVE_ENTER, 0, 0, 0)) return -6;
    if (!ir_jit_diagnostic_mark(sink, IR_JIT_NATIVE_RETURN, 0, -3, 0)) return -6;
    return -3;
}'''
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name, body, expected in [('present', method, -3), ('absent', '', -6)]:
                data = root / name; data.mkdir()
                unit = data / 'component.c'; unit.write_text(component.replace('DIAGNOSTIC', body))
                lib = data / 'component.dylib'
                subprocess.run(['clang', '-shared', '-fPIC', '-I', str(BRIDGE), str(unit), '-o', str(lib)], check=True)
                refusals = ['none']
                if expected == -3 and platform.system() == 'Darwin':
                    refusals += ['stage=' + stage + ' ' for stage in
                        ['app.image.base', 'app.image.uuid.high', 'app.image.uuid.low',
                         'image.base', 'image.uuid.high', 'image.uuid.low']]
                for index, refused in enumerate(refusals):
                    logs = data / ('logs-' + str(index)); logs.mkdir()
                    source = data / 'main.c'; source.write_text(fixture.replace('EXPECTED', str(expected)))
                    binary = data / 'check'
                    subprocess.run(['clang', '-I', str(BRIDGE), str(source), str(BRIDGE / 'IRAudioVolume.c'),
                                    '-ldl', '-lpthread', '-o', str(binary)], check=True)
                    subprocess.run([str(binary), str(lib), str(logs), refused], check=True, timeout=10)
                    text = (logs / 'iridium-psp-jit-stages.log').read_text()
                    stages = [line.split('stage=')[1].split()[0] for line in text.splitlines() if 'stage=' in line]
                    self.assertLess(stages.index('load.enter'), stages.index('load.return'))
                    self.assertLess(stages.index('load.return'), stages.index('abi'))
                    if expected == -3 and refused == 'none':
                        self.assertLess(stages.index('abi'), stages.index('native.enter'))
                        self.assertTrue(text.rstrip().endswith('stage=native.return pass=0 value=-3 error=0'))
                        if platform.system() == 'Darwin':
                            values = {line.split('stage=')[1].split()[0]: int(line.split('value=')[1].split()[0])
                                      for line in text.splitlines() if 'stage=' in line}
                            for prefix, image in [('app.', binary), ('', lib)]:
                                self.assertGreater(values[prefix + 'image.base'], 0)
                                self.assertLess(stages.index(prefix + 'image.base'), stages.index('native.enter'))
                                uuid = subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(image)], text=True).split()[1]
                                raw = bytes.fromhex(uuid.replace('-', ''))
                                for name, offset in [('high', 0), ('low', 8)]:
                                    self.assertEqual(values[prefix + 'image.uuid.' + name],
                                                     int.from_bytes(raw[offset:offset + 8], 'little', signed=True))
                    else: self.assertNotIn('native.enter', stages)
                print('PASS loader anchors match actual image UUIDs; refusing any durable image anchor prevents native execution')


if __name__ == '__main__': unittest.main()
