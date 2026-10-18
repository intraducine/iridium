// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "IRJITDiagnostic.h"
#ifdef __cplusplus
extern "C" {
#endif
// Catches faults only at this thread's generated leaf function. All other
// signals retain their previous disposition. No handlers survive this call.
bool ir_jit_probe_execute(void *code, size_t length, int64_t expected);
bool ir_jit_probe_execute_diagnostic(void *code, size_t length, int64_t expected,
    const IRJITDiagnosticSink *sink, uint32_t pass);
#ifdef __cplusplus
}
#endif
