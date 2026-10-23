// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint16_t buttons;
    int16_t left_x, left_y, right_x, right_y;
    int16_t pointer_x, pointer_y;
    bool pointer_down;
} IRPhase3Input;
// Events: 0 fixed diagnostic, 1 first produced/presented video frame,
// 2 confirmed teardown, 3 failure, 4 pause requested by audio interruption,
// 5 upstream executable-memory probe passed (not a guest JIT assertion).
// Dolphin: 6 completed state operation, 7 recoverable operation failure.
// Events may arrive on the engine owner queue.
typedef void (*IRPhase3Event)(uint64_t generation, unsigned, const char *);
typedef void (*IRPhase3Poll)(IRPhase3Input *);
typedef void *(*IRPhase3JITPrepare)(void *, size_t);
void *ir_phase3_open(const char *engine, const char *frameworks, const char *game,
    const char *save, const char *assets, bool jit, uint64_t generation, IRPhase3Event, IRPhase3Poll);
void ir_phase3_pause(bool);
void ir_phase3_stop(void);
uint64_t ir_phase3_frames(void);
bool ir_phase3_available(const char *engine, const char *frameworks);
bool ir_phase3_azahar_configure_jit(IRPhase3JITPrepare);
#ifdef __cplusplus
}
#endif
