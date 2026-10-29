"""Execute the launch continuation and bounded native execution probe."""
from host_tests import module_cache
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PSPJITTests(unittest.TestCase):
    @unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64' and shutil.which('clang'),
                         'Apple Silicon host required for generated ARM64 execution')
    def test_probe_coexists_with_resident_wine_signal_handlers(self):
        fixture = r'''
#include "IRJITExecutionProbe.h"
#include <assert.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>
static volatile sig_atomic_t calls, extra_masked, self_masked, on_stack, replace_handler;
static void replacement(int signal, siginfo_t *info, void *context) {
    (void)signal; (void)info; (void)context;
}
static void resident(int signal, siginfo_t *info, void *context) {
    assert(signal == SIGILL && info && context);
    sigset_t mask; stack_t stack;
    assert(!sigprocmask(SIG_BLOCK, NULL, &mask));
    assert(!sigaltstack(NULL, &stack));
    calls++; extra_masked = sigismember(&mask, SIGUSR1);
    self_masked = sigismember(&mask, SIGILL); on_stack = !!(stack.ss_flags & SS_ONSTACK);
    if (replace_handler) {
        struct sigaction next = {0}; next.sa_sigaction = replacement; next.sa_flags = SA_SIGINFO;
        sigemptyset(&next.sa_mask); assert(!sigaction(SIGILL, &next, NULL));
    }
}
static int64_t outside_fault(void) { raise(SIGILL); return 42; }
static void same(const struct sigaction *expected, int signal) {
    struct sigaction current; assert(!sigaction(signal, NULL, &current));
    assert(current.sa_sigaction == expected->sa_sigaction && current.sa_flags == expected->sa_flags);
    for (int s = 1; s < NSIG; ++s)
        assert(sigismember(&current.sa_mask, s) == sigismember(&expected->sa_mask, s));
}
int main(void) {
    size_t size = (size_t)getpagesize();
    void *page = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(page != MAP_FAILED);
    uint32_t code[] = {0xd2800540, 0xd65f03c0};
    memcpy(page, code, sizeof code); sys_icache_invalidate(page, size);
    assert(!mprotect(page, size, PROT_READ | PROT_EXEC));
    stack_t stack = {.ss_size = SIGSTKSZ * 2}, old_stack;
    stack.ss_sp = malloc(stack.ss_size); assert(stack.ss_sp && !sigaltstack(&stack, &old_stack));
    int signals[] = {SIGSEGV, SIGBUS, SIGILL}; struct sigaction old[3], saved[3];
    for (int i = 0; i < 3; ++i) assert(!sigaction(signals[i], NULL, &old[i]));
    // Wine installs SA_SIGINFO | SA_RESTART | SA_ONSTACK and a nonempty mask.
    for (int nodefer = 0; nodefer < 2; ++nodefer) {
        for (int masked = 0; masked < 2; ++masked) {
            struct sigaction action = {0}; action.sa_sigaction = resident;
            action.sa_flags = SA_SIGINFO | SA_RESTART | SA_ONSTACK | (nodefer ? SA_NODEFER : 0);
            sigemptyset(&action.sa_mask); sigaddset(&action.sa_mask, SIGUSR1);
            if (masked) sigaddset(&action.sa_mask, SIGILL);
            for (int i = 0; i < 3; ++i) {
                assert(!sigaction(signals[i], &action, NULL));
                assert(!sigaction(signals[i], NULL, &saved[i]));
            }
            for (int run = 0; run < 50; ++run) {
                assert(ir_jit_probe_execute(page, sizeof code, 42));
                assert(!ir_jit_probe_execute(page, sizeof code, 7));
                calls = 0;
                assert(ir_jit_probe_execute((void *)outside_fault, 1, 42));
                assert(calls == 1 && extra_masked && on_stack && self_masked == (masked || !nodefer));
                for (int i = 0; i < 3; ++i) same(&saved[i], signals[i]);
            }
        }
    }
    // Guarded faults still recover instead of reaching the resident handler.
    assert(!mprotect(page, size, PROT_READ | PROT_WRITE)); calls = 0;
    assert(!ir_jit_probe_execute(page, sizeof code, 42) && calls == 0);
    memset(page, 0, sizeof code); sys_icache_invalidate(page, size);
    assert(!mprotect(page, size, PROT_READ | PROT_EXEC));
    assert(!ir_jit_probe_execute(page, sizeof code, 42) && calls == 0);
    for (int i = 0; i < 3; ++i) same(&saved[i], signals[i]);
    // Do not overwrite a handler installed while an outside signal was forwarded.
    replace_handler = 1;
    assert(!ir_jit_probe_execute((void *)outside_fault, 1, 42));
    struct sigaction current; assert(!sigaction(SIGILL, NULL, &current));
    assert(current.sa_sigaction == replacement);
    same(&saved[0], SIGSEGV); same(&saved[1], SIGBUS);
    for (int i = 0; i < 3; ++i) assert(!sigaction(signals[i], &old[i], NULL));
    // Darwin validates the buffer size even when disabling the alternate stack.
    if (old_stack.ss_flags & SS_DISABLE) { old_stack.ss_sp = stack.ss_sp; old_stack.ss_size = stack.ss_size; }
    assert(!sigaltstack(&old_stack, NULL)); free(stack.ss_sp); assert(!munmap(page, size));
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); main = folder / 'main.c'; main.write_text(fixture)
            bridge = ROOT / 'iridium/apps/ios/RuntimeBridge'; binary = folder / 'check'
            subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(bridge),
                            str(main), str(bridge / 'IRJITExecutionProbe.c'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=20)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_activation_validation_cancellation_and_stale_results(self):
        fixture = r'''
import Foundation
@main struct Checks {
@MainActor static func main() {
    let request = IridiumJITRequest()
    var activation: ((Result<Void, Error>) -> Void)?
    var validation: ((Result<Void, Error>) -> Void)?
    var starts = 0, probes = 0
    var launches: [Bool] = []
    let activate: (@escaping (Result<Void, Error>) -> Void) -> Void = { starts += 1; activation = $0 }
    let validate: (@escaping (Result<Void, Error>) -> Void) -> Void = { probes += 1; validation = $0 }
    func start(_ enabled: Bool) {
        request.start(requested: enabled, activate: activate, validate: validate) { launches.append($0) }
    }
    start(false)
    precondition(starts == 0 && probes == 0 && launches == [false] && request.state == .off)
    start(true)
    start(true)
    precondition(starts == 1 && request.state == .activating)
    let oldActivation = activation!
    oldActivation(.success(()))
    oldActivation(.success(()))
    precondition(probes == 1 && request.state == .validating)
    let oldValidation = validation!
    oldValidation(.success(()))
    oldValidation(.success(()))
    precondition(launches == [false, true] && request.state == .ready)
    start(true)
    let cancelledActivation = activation!
    request.cancel()
    cancelledActivation(.success(()))
    precondition(probes == 1 && launches.count == 2)
    start(true)
    let failure = NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "not available"])
    activation?(.failure(failure))
    precondition(launches == [false, true, false] && request.state == .fallback("not available"))
    start(true)
    activation?(.success(()))
    let cancelledValidation = validation!
    request.cancel()
    start(true)
    cancelledValidation(.success(()))
    oldValidation(.success(()))
    precondition(request.state == .activating && launches.count == 3)
    activation?(.success(()))
    validation?(.failure(failure))
    precondition(launches == [false, true, false, false] && request.state == .fallback("not available"))
    print("PASS default-off, single flight, activation failure, backend failure, cancel during activation/probe, stale/double results")
}
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            main = folder / 'checks.swift'; main.write_text(fixture)
            binary = folder / 'checks'
            subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', module_cache('macosx'),
                            str(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumJITRequest.swift'),
                            str(main), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=20)

    @unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64' and shutil.which('clang'),
                         'Apple Silicon host required for generated ARM64 execution')
    def test_native_fault_recovery_rewrite_and_handler_restoration(self):
        fixture = r'''
#include "IRJITExecutionProbe.h"
#include <assert.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>
static volatile sig_atomic_t called, extra_masked, self_masked, reset, executed;
static void handler(int signal) {
    assert(signal == SIGILL);
    sigset_t mask; struct sigaction action;
    assert(!sigprocmask(SIG_BLOCK, NULL, &mask));
    assert(!sigaction(SIGILL, NULL, &action));
    called++;
    extra_masked = sigismember(&mask, SIGUSR1);
    self_masked = sigismember(&mask, SIGILL);
    reset = action.sa_handler == SIG_DFL;
}
static int64_t outside_fault(void) { executed++; raise(SIGILL); return 42; }
int main(void) {
    size_t size = (size_t)getpagesize();
    void *page = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(page != MAP_FAILED);
    uint32_t code[] = {0xd2800540, 0xd65f03c0}; // mov x0,42; ret
    struct sigaction old[3], after, custom = {0};
    int signals[] = {SIGSEGV, SIGBUS, SIGILL};
    for (int i = 0; i < 3; ++i) assert(!sigaction(signals[i], NULL, &old[i]));
    memcpy(page, code, sizeof code);
    // Allocation and protection may succeed while execution is denied.
    assert(!ir_jit_probe_execute(page, size, 42));
    assert(!mprotect(page, size, PROT_READ | PROT_EXEC));
    sys_icache_invalidate(page, size);
    assert(ir_jit_probe_execute(page, size, 42));
    assert(!ir_jit_probe_execute(page, size, 7));
    assert(!mprotect(page, size, PROT_READ | PROT_WRITE));
    code[0] = 0xd28000e0; // mov x0,7
    memcpy(page, code, sizeof code);
    sys_icache_invalidate(page, size);
    assert(!mprotect(page, size, PROT_READ | PROT_EXEC));
    assert(ir_jit_probe_execute(page, size, 7));
    assert(!mprotect(page, size, PROT_READ | PROT_WRITE));
    memset(page, 0, sizeof code); // undefined ARM64 instruction
    sys_icache_invalidate(page, size);
    assert(!mprotect(page, size, PROT_READ | PROT_EXEC));
    assert(!ir_jit_probe_execute(page, size, 7));
    for (int i = 0; i < 3; ++i) {
        assert(!sigaction(signals[i], NULL, &after));
        assert(after.sa_handler == old[i].sa_handler && after.sa_flags == old[i].sa_flags);
    }
    // Reproduce the reviewer's mask/nodefer/reset example. The guard must
    // decline without executing the function or touching ANY disposition.
    custom.sa_handler = handler;
    custom.sa_flags = SA_RESETHAND | SA_NODEFER | SA_ONSTACK;
    sigemptyset(&custom.sa_mask); sigaddset(&custom.sa_mask, SIGUSR1);
    assert(!sigaction(SIGILL, &custom, NULL));
    assert(!sigaction(SIGILL, NULL, &custom)); // kernel-normalized flags
    // Record native reset behavior (POSIX permits SIGILL not to reset).
    assert(outside_fault() == 42);
    assert(called == 1 && extra_masked == 1 && self_masked == 0);
    sig_atomic_t direct_reset = reset;
    struct sigaction direct_after;
    assert(!sigaction(SIGILL, NULL, &direct_after));
    assert(!sigaction(SIGILL, &custom, NULL));
    called = executed = extra_masked = self_masked = reset = 0;
    assert(!ir_jit_probe_execute((void *)outside_fault, 1, 42));
    assert(called == 0 && executed == 0);
    for (int i = 0; i < 3; ++i) {
        assert(!sigaction(signals[i], NULL, &after));
        const struct sigaction *expected = i == 2 ? &custom : &old[i];
        assert(after.sa_handler == expected->sa_handler && after.sa_flags == expected->sa_flags);
        for (int s = 1; s < NSIG; ++s)
            assert(sigismember(&after.sa_mask, s) == sigismember(&expected->sa_mask, s));
    }
    assert(outside_fault() == 42);
    assert(called == 1 && executed == 1 && extra_masked == 1 && self_masked == 0 && reset == direct_reset);
    assert(!sigaction(SIGILL, NULL, &after) && after.sa_handler == direct_after.sa_handler);
    assert(!ir_jit_probe_execute(NULL, size, 0));
    assert(!ir_jit_probe_execute(page, 0, 0));
    assert(!munmap(page, size));
    assert(!sigaction(SIGILL, &old[2], NULL));
    puts("PASS ARM64 execute/rewrite, NX/SIGILL recovery, decline custom dispositions without execution/mutation; original mask/nodefer/reset preserved");
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); main = folder / 'main.c'; main.write_text(fixture)
            bridge = ROOT / 'iridium/apps/ios/RuntimeBridge'
            binary = folder / 'check'
            subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(bridge),
                            str(main), str(bridge / 'IRJITExecutionProbe.c'), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == '__main__':
    unittest.main()
