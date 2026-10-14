// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef void (*IRPSPNativeEvent)(unsigned event, const char *message);
// All operations are owned by Iridium's main thread; the dylib stays loaded.
void *ir_psp_native_open(const char *component, const char *game, const char *memory_stick,
                         const char *assets, bool jit_verified, IRPSPNativeEvent event);
void ir_psp_native_pause(void);
void ir_psp_native_resume(void);
void ir_psp_native_menu(void);
void ir_psp_native_stop(void);
uint64_t ir_psp_native_frames(void);
