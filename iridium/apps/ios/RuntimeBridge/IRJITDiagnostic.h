// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>

#ifdef __cplusplus
extern "C" {
#endif

// Fixed codes only: no game paths, pairing records or arbitrary native text.
typedef enum {
    IR_JIT_ACTIVATION_ENTER = 1, IR_JIT_ACTIVATION_RETURN,
    IR_JIT_WORKER_ENTER, IR_JIT_LOAD_ENTER, IR_JIT_LOAD_RETURN,
    IR_JIT_SYMBOL, IR_JIT_ABI, IR_JIT_IMAGE_UUID_HIGH, IR_JIT_IMAGE_UUID_LOW,
    IR_JIT_NATIVE_ENTER, IR_JIT_CSOPS, IR_JIT_ALLOC_ENTER, IR_JIT_ALLOC_RETURN,
    IR_JIT_RW_ENTER, IR_JIT_RW_RETURN, IR_JIT_EMIT_ENTER, IR_JIT_EMIT_RETURN,
    IR_JIT_CACHE_ENTER, IR_JIT_CACHE_RETURN, IR_JIT_RX_ENTER, IR_JIT_RX_RETURN,
    IR_JIT_GUARD_ENTER, IR_JIT_GUARD_DECLINED, IR_JIT_GUARD_READY,
    IR_JIT_EXEC_ENTER, IR_JIT_EXEC_RETURN, IR_JIT_RECOVERED_SIGNAL,
    IR_JIT_SIGNAL_OFFSET, IR_JIT_HANDLERS_RESTORED, IR_JIT_FREE_ENTER,
    IR_JIT_FREE_RETURN, IR_JIT_NATIVE_RETURN, IR_JIT_WORKER_RETURN,
    IR_JIT_MAIN_RESULT, IR_JIT_RESTORE_ENTER, IR_JIT_RESTORE_RETURN,
    IR_JIT_COMPLETION, IR_JIT_PLAYER_ENTER, IR_JIT_PLAYER_RETURN,
    IR_JIT_CANCEL, IR_JIT_TIMEOUT, IR_JIT_OWNER_RELEASE,
    IR_JIT_ALLOC_ERROR, IR_JIT_PROTECT_ERROR, IR_JIT_NATIVE_ERROR,
    IR_JIT_SYMBOL_ENTER, IR_JIT_ABI_ENTER, IR_JIT_HANDLERS_RESTORE_ENTER,
    IR_JIT_CODE_LENGTH, IR_JIT_CODE_WORD_0, IR_JIT_CODE_WORD_1,
    IR_JIT_CODE_WORD_2, IR_JIT_CODE_WORD_3, IR_JIT_CALL_ENTER,
    IR_JIT_PROBE_BASE, IR_JIT_IMAGE_BASE, IR_JIT_APP_IMAGE_BASE,
    IR_JIT_APP_IMAGE_UUID_HIGH, IR_JIT_APP_IMAGE_UUID_LOW,
    // Append only: preserve all stage numbers used by existing native components.
    // observation.failed: pass=failure kind, value=bounded count, error=numeric code.
    // fallback: value=the launch owner's fixed terminal reason.
    IR_JIT_OBSERVATION_FAILED, IR_JIT_FALLBACK,
    IR_JIT_PREPARE_ENTER, IR_JIT_PREPARE_REJECT, IR_JIT_ARENA_ENTER,
    IR_JIT_ARENA_ERROR, IR_JIT_ARENA_RETURN, IR_JIT_PREPARE_RETURN,
    IR_JIT_ARENA_VIEW
} IRJITDiagnosticStage;

// The app owns this callback/context for the entire synchronous native call.
// Never invoke it from a signal handler. error=-1 means errno is unavailable.
typedef struct {
    void *context;
    bool (*mark)(void *, IRJITDiagnosticStage, uint32_t pass, int64_t value, int error);
} IRJITDiagnosticSink;

static inline bool ir_jit_diagnostic_mark(const IRJITDiagnosticSink *sink,
    IRJITDiagnosticStage stage, uint32_t pass, int64_t value, int error) {
    int saved = errno;
    bool result = !sink || (sink->mark && sink->mark(sink->context, stage, pass, value, error));
    errno = saved;
    return result;
}

#ifdef __cplusplus
}
#endif
