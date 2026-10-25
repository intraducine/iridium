// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "IRJITDiagnostic.h"
#include "IRPSPExecutableMemory.h"
#include "IRPSPTeardownObservation.h"
typedef struct IRPSPJITDiagnostic IRPSPJITDiagnostic;
// Off-main-thread journal operations. The caller retains ownership until all
// worker and restoration callbacks finish; cancellation never closes it early.
IRPSPJITDiagnostic *ir_psp_jit_diagnostic_open(const char *directory, const char *identity);
bool ir_psp_jit_diagnostic_mark(IRPSPJITDiagnostic *, IRJITDiagnosticStage, uint32_t pass, int64_t value, int error);
bool ir_psp_jit_diagnostic_healthy(IRPSPJITDiagnostic *);
void ir_psp_jit_diagnostic_close(IRPSPJITDiagnostic *);
int ir_psp_native_check_jit_diagnostic(const char *component, IRPSPJITDiagnostic *);
int ir_psp_native_exec_prepare(const char *component, const IRPSPExecHost *, IRPSPJITDiagnostic *);
bool ir_psp_native_exec_supports_shared(const char *component);
int ir_psp_native_exec_prepare_shared(const char *component, uint64_t admission, const IRJITMemoryAPI *, IRPSPJITDiagnostic *);
int ir_psp_native_exec_detach(uint64_t admission);
int ir_psp_native_exec_shutdown(const IRPSPExecShutdown *);
int ir_psp_native_exec_restored(uint64_t admission, bool success);
int ir_psp_native_exec_restored_diagnostic(uint64_t admission, bool success, IRPSPJITDiagnostic *);
void ir_psp_native_exec_cancel(uint64_t admission);
int ir_psp_native_exec_end(uint64_t admission);
typedef void (*IRPSPNativeEvent)(unsigned event, const char *message);
typedef void (*IRPSPNativeInput)(uint16_t *buttons, int16_t *x, int16_t *y);
// Called on the console's serial owner before opening any native player.
int ir_psp_native_check_jit(const char *component);
// All operations are owned by Iridium's main thread; the dylib stays loaded.
void *ir_psp_native_open(const char *component, const char *game, const char *memory_stick,
                         const char *assets, bool jit_verified, IRPSPNativeEvent event, IRPSPNativeInput input);
void ir_psp_native_pause(void);
void ir_psp_native_resume(void);
bool ir_psp_native_request(unsigned operation, int value);
int ir_psp_native_resolution(void);
void ir_psp_native_stop(void);
uint64_t ir_psp_native_frames(void);
