// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*IRNativePSPEvent)(unsigned event, const char *message);
#define IR_NATIVE_EXPORT __attribute__((visibility("default")))
// Main-thread entry points. Returned UIViewController has one retained reference.
IR_NATIVE_EXPORT uint32_t ir_native_psp_abi(void);
IR_NATIVE_EXPORT void *ir_native_psp_create(const char *game, const char *memory_stick, const char *assets,
                          bool jit_verified, IRNativePSPEvent event);
IR_NATIVE_EXPORT void ir_native_psp_pause(void);
IR_NATIVE_EXPORT void ir_native_psp_resume(void);
IR_NATIVE_EXPORT void ir_native_psp_menu(void);
IR_NATIVE_EXPORT void ir_native_psp_stop(void);
IR_NATIVE_EXPORT void ir_native_psp_restart(void);
bool ir_native_psp_jit_available(void);
IR_NATIVE_EXPORT uint64_t ir_native_psp_frames(void);
// Platform hooks are internal; engine code and serialized state are unchanged.
void ir_native_psp_platform_init(void);
void ir_native_psp_frame(void);
void ir_native_psp_renderer_ready(void);
void ir_native_psp_renderer_failed(void);
bool ir_native_psp_codec_check(void);
void ir_native_psp_capture_controller(void *controller);
bool ir_native_psp_should_render(void);
#ifdef __cplusplus
}
#endif
