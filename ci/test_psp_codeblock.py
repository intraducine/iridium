"""Execute the shipping probe with the actual pinned CodeBlock and emitter."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest
import ppsspp_native_overlay as overlay

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'vendor/PPSSPP'


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('clang++'), 'Darwin C++ compiler required')
class CodeBlockProbeTests(unittest.TestCase):
    def test_actual_probe_status_rewrites_failures_and_exactly_once_cleanup(self):
        source = (ROOT / 'iridium/apps/ios/RuntimeBridge/IRPPSSPPNative.mm').read_text()
        method = source[source.index('int ir_native_psp_check_jit_diagnostic('):source.index('\nuint32_t ir_native_psp_abi(')]
        fixture = r'''
#include "Common/Arm64Emitter.h"
#include "Common/Log.h"
#include "IRJITExecutionProbe.h"
#include <atomic>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <vector>
#include <unistd.h>
#define TARGET_OS_SIMULATOR 0
bool HandleAssert(bool, const char *, const char *, int, const char *, const char *, ...) { abort(); }
void GenericLog(Log, LogLevel, const char *, int, const char *, ...) {}
static bool logEnabled = true;
bool *g_bLogEnabledSetting = &logEnabled;
LogChannel g_log[(size_t)Log::NUMBER_OF_LOGS];
enum class LogOutput { Stdio, ExternalCallback };
static void forwardNativeLog(int, void *) {}
struct LogManager {
    LogOutput output = LogOutput::Stdio;
    LogOutput GetOutputsEnabled() { return output; }
    void SetExternalLogCallback(void (*)(int, void *), void *) {}
    void EnableOutput(LogOutput value) { output = value; }
    void SetOutputsEnabled(LogOutput value) { output = value; }
} g_logManager;
static thread_local const IRJITDiagnosticSink *preflightLogSink;
static thread_local uint32_t preflightPass;
static thread_local int preflightErrno = -1;
static void *container;
static std::atomic<bool> jitProbeVerified;
struct Protection { size_t bytes; uint32_t flags; };
struct Mark { IRJITDiagnosticStage stage; uint32_t pass; int64_t value; int error; };
static std::vector<Protection> protections;
static std::vector<Mark> marks;
static size_t allocated;
static int allocations, frees, executions, allocationCalls, failProtection, failMark;
static bool failAllocation, failExecution, wx = true;
static uint32_t csFlags = 0x10000000u;
static int csResult;
bool PlatformIsWXExclusive() { return wx; }
int GetMemoryProtectPageSize() { return 16384; }
void *AllocateExecutableMemory(size_t size) {
    allocationCalls++; allocated = size;
    if (failAllocation) return nullptr;
    allocations++;
    void *p = malloc(size); assert(p); memset(p, 0xee, size); return p;
}
void FreeExecutableMemory(void *p, size_t size) {
    assert(p && size == allocated);
    assert(preflightLogSink && g_logManager.output == LogOutput::ExternalCallback);
    frees++; assert(frees == allocations); free(p);
}
bool ProtectMemoryPages(const void *, size_t bytes, uint32_t flags) {
    protections.push_back({bytes, flags});
    if ((int)protections.size() == failProtection) { preflightErrno = 13; return false; }
    return true;
}
int csops(pid_t, unsigned, void *flags, size_t size) {
    assert(size == sizeof csFlags); memcpy(flags, &csFlags, size); return csResult;
}
extern "C" bool ir_jit_probe_execute_diagnostic(void *code, size_t length, int64_t expected,
                                               const IRJITDiagnosticSink *, uint32_t) {
    assert(length == 16 * 1024 * 1024);
    uint32_t words[2]; memcpy(words, code, sizeof words);
    assert(words[0] == (expected == 42 ? 0x52800540u : 0x528000e0u));
    assert(words[1] == 0xd65f03c0u);
    executions++; return !failExecution;
}
PRODUCTION_PROBE
static bool mark(void *, IRJITDiagnosticStage stage, uint32_t pass, int64_t value, int error) {
    marks.push_back({stage, pass, value, error});
    return (int)marks.size() != failMark;
}
static IRJITDiagnosticSink sink{nullptr, mark};
static void reset() {
    protections.clear(); marks.clear(); allocated = 0;
    allocations = frees = executions = allocationCalls = failProtection = failMark = 0;
    failAllocation = failExecution = false; csFlags = 0x10000000u; csResult = 0;
    container = nullptr; wx = true; jitProbeVerified = true;
}
static int probe() {
    int result = ir_native_psp_check_jit_diagnostic(&sink);
    assert(frees == allocations && preflightLogSink == nullptr);
    assert(g_logManager.output == LogOutput::Stdio);
    assert(jitProbeVerified == (result == 1));
    return result;
}
static int count(IRJITDiagnosticStage stage) {
    int total = 0; for (const auto &m : marks) if (m.stage == stage) total++; return total;
}
int main() {
    reset(); assert(probe() == 1);
    assert(allocated == 16*1024*1024 && allocations == 1 && frees == 1 && executions == 2);
    assert(protections.size() == 5);
    for (int i = 0; i < 4; i++) {
        assert(protections[i].bytes == 16384);
        assert(protections[i].flags == (i % 2 ? 5u : 3u));
    }
    assert(protections.back().bytes == allocated && protections.back().flags == 3);
    for (const auto &m : marks) {
        if (m.stage == IR_JIT_RW_ENTER || m.stage == IR_JIT_RX_ENTER) assert(m.value == 16384);
        if (m.stage == IR_JIT_CODE_LENGTH) assert(m.value == 8);
    }
    const int successfulMarks = marks.size();
    // Fail every production breadcrumb once, including allocation/base and cleanup.
    for (int failure = 1; failure <= successfulMarks; failure++) {
        reset(); failMark = failure; assert(probe() == -6);
    }
    reset(); failAllocation = true;
    assert(probe() == -2 && allocations == 0 && protections.empty() && executions == 0);
    for (int failure = 1; failure <= 4; failure++) {
        reset(); failProtection = failure; assert(probe() == -3);
        assert(executions == (failure > 2 ? 1 : 0));
        assert(protections.size() == (size_t)failure + 1); // failure then upstream cleanup only
        assert(protections.back().bytes == allocated && protections.back().flags == 3);
        if (failure == 1) assert(count(IR_JIT_EMIT_ENTER) == 0); // No write after failed BeginWrite.
    }
    reset(); failExecution = true; assert(probe() == 0 && executions == 1);
    reset(); csFlags = 0; assert(probe() == -4 && allocationCalls == 0);
    reset(); csResult = -1; assert(probe() == -4 && allocationCalls == 0);
    reset(); container = (void *)1; assert(probe() == -5 && allocationCalls == 0);
    // Directly verify failed EndWrite clears writeStart_ before a later BeginWrite.
    reset(); preflightLogSink = &sink; g_logManager.output = LogOutput::ExternalCallback;
    {
        Arm64Gen::ARM64CodeBlock block; block.AllocCodeSpace(16384);
        assert(block.GetBasePtr()); assert(block.BeginWrite(16384));
        block.MOVI2R(Arm64Gen::W0, 42); block.RET();
        failProtection = 2; assert(!block.EndWrite()); failProtection = 0;
        block.ResetCodePtr(0); assert(block.BeginWrite(16384));
        block.MOVI2R(Arm64Gen::W0, 7); block.RET(); assert(block.EndWrite());
    }
    assert(allocations == 1 && frees == 1);
    // Non-W^X callers retain the no-transition success path.
    reset(); wx = false; preflightLogSink = &sink; g_logManager.output = LogOutput::ExternalCallback;
    {
        Arm64Gen::ARM64CodeBlock block; block.AllocCodeSpace(16384);
        assert(block.BeginWrite()); assert(block.EndWrite()); assert(protections.empty());
    }
    assert(frees == 1);
    printf("PASS actual production probe + pinned CodeBlock/emitter: two rewrites, allocation/RW/RX failure, %d journal failures, exactly-once cleanup, EndWrite state reset and non-W^X status. No generated code executed.\n", successfulMarks);
}
'''.replace('PRODUCTION_PROBE', method)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); common = folder / 'Common'; common.mkdir()
            header = (UPSTREAM / 'Common/CodeBlock.h').read_text()
            (common / 'CodeBlock.h').write_text(overlay.apply('Common/CodeBlock.h', header))
            with self.assertRaisesRegex(ValueError, 'embedding hook changed'):
                overlay.apply('Common/CodeBlock.h', header.replace('void EndWrite()', 'void FinishWrite()'))
            emitter = folder / 'emitter.cpp'
            emitter.write_text(overlay.apply('Common/Arm64Emitter.cpp', (UPSTREAM / 'Common/Arm64Emitter.cpp').read_text()))
            main = folder / 'probe.cpp'; main.write_text(fixture); binary = folder / 'probe'
            subprocess.run(['clang++', '-std=c++17', '-O1', '-D_DEBUG', '-ffunction-sections', '-fdata-sections',
                            '-Wl,-dead_strip', '-I', str(folder), '-I', str(UPSTREAM),
                            '-I', str(ROOT / 'iridium/apps/ios/RuntimeBridge'), str(emitter), str(main),
                            '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
