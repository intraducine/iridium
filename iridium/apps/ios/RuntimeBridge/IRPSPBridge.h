// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum { IR_PSP_CLOSED, IR_PSP_BOOTING, IR_PSP_RUNNING,
               IR_PSP_STOPPING, IR_PSP_FAILED, IR_PSP_RESTART_REQUIRED } IRPSPPhase;
typedef struct {
    const uint32_t *pixels;
    unsigned width, height;
    const int16_t *audio;
    size_t audio_frames;
    double fps, sample_rate;
    // True only when this step reached the core's input-poll callback. A boot
    // pump, early return or stop drain is not an input acknowledgment.
    bool input_polled;
    // Counters describe bridge observations, never game loading progress.
    bool video_refreshed, image_changed;
    uint64_t steps, video_callbacks, video_frames, changed_frames, input_polls;
} IRPSPFrame;

typedef void (*IRPSPLogCallback)(unsigned level, const char *message);
// Install before open, on the serial owner. Core logging may arrive from its
// loader thread; the callback must be thread-safe and retain no core pointers.
void ir_psp_set_log_callback(IRPSPLogCallback callback);

// Frame buffers are bridge-owned and change at the next operation. Copy them
// before returning control to the serial owner. RUNNING can precede the first
// displayable frame; a zero width/height means there is no image yet.

// One serial owner, including callbacks, throughout the complete lifetime.
// Paths must be prevalidated app-owned paths, never remote/downloaded code.
// True transfers ownership, even when subsequent asynchronous boot fails.
bool ir_psp_open(const char *component, const char *game,
                 const char *system, const char *save);
IRPSPPhase ir_psp_phase(void);
IRPSPPhase ir_psp_step(uint16_t buttons, int16_t analog_x, int16_t analog_y,
                       IRPSPFrame *frame);
// Requesting stop is nonblocking. Keep calling step until CLOSED or
// RESTART_REQUIRED. If a caller's
// watchdog expires, retain ownership and require restart; never forcibly unload.
void ir_psp_request_stop(void);
