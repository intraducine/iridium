// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "IRCoreOptions.h"
#include "IRCheats.h"

// All calls belong to one serial runtime queue. The bridge owns one core; a
// second open fails without disturbing the running game. Buffers remain valid
// only until the next step/close, and callers must copy before returning.
typedef struct {
    const uint32_t *pixels;
    unsigned width, height;
    const int16_t *audio;
    size_t audio_frames;
    double frames_per_second, samples_per_second;
    // True only if this step reached the core's input-poll callback.
    bool input_polled;
} IRCoreFrame;

bool ir_core_open(const void *rom, size_t length, const char *system_directory);
bool ir_core_step(uint16_t buttons, IRCoreFrame *frame);
uint64_t ir_core_audio_dropped_frames(void);
const char *ir_core_model(void);
const char *ir_core_version(void);
size_t ir_core_save_size(bool clock);
bool ir_core_read_save(bool clock, void *bytes, size_t length);
bool ir_core_write_save(bool clock, const void *bytes, size_t length);
void ir_core_close(void);
void ir_core_reset_options(void);
bool ir_core_set_option(const char *key, const char *value);
void ir_core_visit_options(IRCoreOptionVisitor, void *context);
size_t ir_core_state_size(void);
bool ir_core_read_state(void *bytes, size_t length);
bool ir_core_write_state(const void *bytes, size_t length);
bool ir_core_set_cheats(const IRCheat *items, size_t count);
