// SPDX-License-Identifier: AGPL-3.0-only
#include "IRJITExecutionProbe.h"
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <string.h>
#include <sys/ucontext.h>
#include <limits.h>

static pthread_mutex_t probe_lock = PTHREAD_MUTEX_INITIALIZER;
static const int signals[] = { SIGSEGV, SIGBUS, SIGILL };
static struct sigaction previous[3];
static _Thread_local sigjmp_buf recovery;
static _Thread_local volatile sig_atomic_t executing;
static _Thread_local uintptr_t start, end;
static _Thread_local volatile sig_atomic_t fault_signal, fault_offset;

static void probe_signal(int signal, siginfo_t *info, void *context) {
    (void)info;
    uintptr_t pc = 0;
#if defined(__APPLE__) && defined(__aarch64__)
    pc = ((ucontext_t *)context)->uc_mcontext->__ss.__pc;
#elif defined(__APPLE__) && defined(__x86_64__)
    pc = ((ucontext_t *)context)->uc_mcontext->__ss.__rip;
#endif
    if (executing && pc >= start && pc < end) {
        fault_signal = signal;
        fault_offset = pc - start <= INT_MAX ? (sig_atomic_t)(pc - start) : -1;
        executing = 0;
        siglongjmp(recovery, 1);
    }
    for (size_t i = 0; i < 3; ++i) if (signals[i] == signal) {
        if (previous[i].sa_handler == SIG_IGN) return;
        if (previous[i].sa_handler == SIG_DFL) {
            sigaction(signal, &previous[i], NULL);
            raise(signal);
        }
        return;
    }
}

bool ir_jit_probe_execute(void *code, size_t length, int64_t expected) {
    return ir_jit_probe_execute_diagnostic(code, length, expected, NULL, 0);
}
bool ir_jit_probe_execute_diagnostic(void *code, size_t length, int64_t expected,
    const IRJITDiagnosticSink *sink, uint32_t pass) {
    if (!ir_jit_diagnostic_mark(sink, IR_JIT_GUARD_ENTER, pass, 0, 0)) return false;
    if (!code || !length || (uintptr_t)code > UINTPTR_MAX - length) return false;
    if (pthread_mutex_trylock(&probe_lock)) return false;
    // Calling a foreign handler directly cannot preserve its signal mask,
    // alternate stack, reset or nodefer semantics. Decline before changing any
    // disposition or executing code if another subsystem owns one of them.
    for (size_t i = 0; i < 3; ++i) {
        if (sigaction(signals[i], NULL, &previous[i]) ||
            (previous[i].sa_handler != SIG_DFL && previous[i].sa_handler != SIG_IGN)) {
            ir_jit_diagnostic_mark(sink, IR_JIT_GUARD_DECLINED, pass, signals[i], -1);
            pthread_mutex_unlock(&probe_lock);
            return false;
        }
    }
    struct sigaction action;
    memset(&action, 0, sizeof action);
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_SIGINFO;
    action.sa_sigaction = probe_signal;
    size_t installed = 0;
    for (; installed < 3; ++installed) {
        if (sigaction(signals[installed], &action, NULL)) break;
    }
    bool result = false;
    if (installed == 3) {
        start = (uintptr_t)code; end = start + length;
        fault_signal = fault_offset = 0;
        if (sigsetjmp(recovery, 1) == 0) {
            if (ir_jit_diagnostic_mark(sink, IR_JIT_GUARD_READY, pass, 0, 0) &&
                ir_jit_diagnostic_mark(sink, IR_JIT_EXEC_ENTER, pass, expected, 0)) {
                // Resolve and touch TLS before the final normal-context mark.
                // Keep its address across the call; the callback runs unarmed.
                volatile sig_atomic_t *active = &executing;
                *active = 0;
                if (ir_jit_diagnostic_mark(sink, IR_JIT_CALL_ENTER, pass, expected, 0)) {
                    *active = 1;
                    int64_t value = ((int64_t (*)(void))code)();
                    *active = 0;
                    result = ir_jit_diagnostic_mark(sink, IR_JIT_EXEC_RETURN, pass, value, 0) && value == expected;
                }
            }
        } else {
            // Ordinary C flow after recovery: no I/O, callbacks or locks in the handler.
            ir_jit_diagnostic_mark(sink, IR_JIT_RECOVERED_SIGNAL, pass, fault_signal, 0);
            ir_jit_diagnostic_mark(sink, IR_JIT_SIGNAL_OFFSET, pass, fault_offset, 0);
        }
    }
    executing = 0; start = end = 0;
    if (!ir_jit_diagnostic_mark(sink, IR_JIT_HANDLERS_RESTORE_ENTER, pass, 0, 0)) result = false;
    bool restored = true;
    while (installed) {
        --installed;
        if (sigaction(signals[installed], &previous[installed], NULL)) { result = false; restored = false; }
    }
    if (!ir_jit_diagnostic_mark(sink, IR_JIT_HANDLERS_RESTORED, pass, restored, restored ? 0 : -1)) result = false;
    pthread_mutex_unlock(&probe_lock);
    return result;
}
