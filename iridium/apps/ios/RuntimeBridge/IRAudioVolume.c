// SPDX-License-Identifier: AGPL-3.0-only
#include "IRAudioVolume.h"
#include <dlfcn.h>
#include <math.h>
#ifdef __cplusplus
#include <atomic>
static std::atomic<float> gain{1};
#else
#include <stdatomic.h>
static _Atomic(float) gain = 1;
#endif
static void (*engine_volume)(float);

float ir_audio_volume_get(void) { return gain; }
void ir_audio_volume_set(float value) {
    value = isfinite(value) ? fminf(1, fmaxf(0, value)) : 0;
    gain = value;
    if (engine_volume) engine_volume(value);
}
bool ir_audio_volume_bind(void *image, const char *symbol) {
    engine_volume = NULL;
    if (!image) return true;
    if (!symbol) return false;
    engine_volume = (void (*)(float))dlsym(image, symbol);
    if (!engine_volume) return false;
    engine_volume(ir_audio_volume_get());
    return true;
}
void ir_audio_volume_apply_i16(int16_t *samples, size_t count) {
    float level = ir_audio_volume_get();
    if (!samples || level == 1) return;
    for (size_t i = 0; i < count; ++i) samples[i] = (int16_t)(samples[i] * level);
}
void ir_audio_volume_apply_float(float *samples, size_t count) {
    float level = ir_audio_volume_get();
    if (!samples || level == 1) return;
    for (size_t i = 0; i < count; ++i) samples[i] = level == 0 ? 0 : samples[i] * level;
}
