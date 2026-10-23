// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Set/bind on the main thread. Audio callbacks only read the atomic gain.
__attribute__((visibility("hidden"))) void ir_audio_volume_set(float);
__attribute__((visibility("hidden"))) float ir_audio_volume_get(void);
// A null image clears the previous engine. Never unload the retained image.
__attribute__((visibility("hidden"))) bool ir_audio_volume_bind(void *image, const char *symbol);
__attribute__((visibility("hidden"))) void ir_audio_volume_apply_i16(int16_t *, size_t);
__attribute__((visibility("hidden"))) void ir_audio_volume_apply_float(float *, size_t);
#ifdef __cplusplus
}
#endif
