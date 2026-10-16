// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef __OBJC__
@class UIViewController;
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*IRNativePSPEvent)(unsigned event, const char *message);
typedef void (*IRNativePSPInput)(uint16_t *buttons, int16_t *x, int16_t *y);
#define IR_NATIVE_EXPORT __attribute__((visibility("default")))
// Main-thread entry points. Returned UIViewController has one retained reference.
// Input runs only on the emulation sampling thread. Events other than log (0)
// arrive on the main thread. Requests: 1 resolution (1–4), 2 save / 3 load (slot 0–4).
// Event 8 reports the effective CPU mode when game boot completes.
IR_NATIVE_EXPORT uint32_t ir_native_psp_abi(void);
IR_NATIVE_EXPORT void *ir_native_psp_create(const char *game, const char *memory_stick, const char *assets,
                          bool jit_verified, IRNativePSPEvent event, IRNativePSPInput input);
IR_NATIVE_EXPORT void ir_native_psp_pause(void);
IR_NATIVE_EXPORT void ir_native_psp_resume(void);
IR_NATIVE_EXPORT bool ir_native_psp_request(unsigned operation, int value);
IR_NATIVE_EXPORT int ir_native_psp_resolution(void);
IR_NATIVE_EXPORT void ir_native_psp_stop(void);
IR_NATIVE_EXPORT void ir_native_psp_restart(void);
bool ir_native_psp_jit_available(void);
IR_NATIVE_EXPORT uint64_t ir_native_psp_frames(void);
void ir_native_psp_poll_input(void);
void ir_native_psp_frontend_frame(void);
void ir_native_psp_frontend_event(unsigned kind, const char *message);
// Platform hooks are internal; engine code and serialized state are unchanged.
void ir_native_psp_platform_init(void);
void ir_native_psp_frame(void);
void ir_native_psp_renderer_ready(void);
void ir_native_psp_renderer_failed(void);
bool ir_native_psp_codec_check(void);
void ir_native_psp_capture_controller(void *controller);
bool ir_native_psp_should_render(void);
bool ir_native_psp_is_current_player(void *player);
uint64_t ir_native_psp_generation(void);
bool ir_native_psp_generation_current(uint64_t owner);
#ifdef __OBJC__
void ir_native_psp_present(UIViewController *controller, void (^cancel)(void));
void ir_native_psp_presentation_finished(UIViewController *controller);
void ir_native_psp_rotation_changed(int rotation);
#endif
#ifdef __cplusplus
}
#endif
