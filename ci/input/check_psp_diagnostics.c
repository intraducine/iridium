// SPDX-License-Identifier: AGPL-3.0-only
// Real bridge callbacks with a synthetic core; no game data or emulator needed.
#include "IRPSPBridge.c"
#include <assert.h>

static uint32_t image[480 * 272];
static unsigned action;
static bool pending;
static char captured[2048];
static unsigned captured_level;
static void log_entry(unsigned level, const char *message)
{ captured_level = level; snprintf(captured, sizeof(captured), "%s", message); }
static bool boot_pending(void) { return pending; }
static void run(void)
{
    if (action == 1) video(image, 480, 272, 480 * 4);
    if (action == 2) video(NULL, 480, 272, 480 * 4);
    if (action == 3) { image[1024]++; video(image, 480, 272, 480 * 4); }
    poll();
}

int main(void)
{
    api.retro_run = run; api.pending = boot_pending;
    core.phase = IR_PSP_BOOTING; core.fps = 60; core.rate = 44100;
    pending = true;
    IRPSPFrame frame;
    assert(ir_psp_step(0, 0, 0, &frame) == IR_PSP_BOOTING);
    assert(frame.steps == 1 && frame.input_polls == 1 && frame.video_frames == 0);
    assert(!frame.video_refreshed && !frame.image_changed && !frame.pixels);
    pending = false; action = 1;
    assert(ir_psp_step(0, 0, 0, &frame) == IR_PSP_RUNNING);
    assert(frame.steps == 2 && frame.video_callbacks == 1 && frame.video_frames == 1);
    assert(frame.video_refreshed && frame.image_changed && frame.changed_frames == 1);
    // The core submits the exact same image: fresh callback, no image change.
    assert(ir_psp_step(0, 0, 0, &frame) == IR_PSP_RUNNING);
    assert(frame.video_refreshed && !frame.image_changed);
    assert(frame.video_frames == 2 && frame.changed_frames == 1);
    action = 0;
    assert(ir_psp_step(0, 0, 0, &frame) == IR_PSP_RUNNING);
    assert(frame.pixels && frame.width == 480); // The old display remains usable.
    assert(!frame.video_refreshed && !frame.image_changed && frame.video_frames == 2);
    action = 2;
    assert(ir_psp_step(0, 0, 0, &frame) == IR_PSP_RUNNING);
    assert(frame.video_callbacks == 3 && frame.video_frames == 2 && !frame.video_refreshed);
    action = 3;
    assert(ir_psp_step(0, 0, 0, &frame) == IR_PSP_RUNNING);
    assert(frame.video_refreshed && frame.image_changed && frame.changed_frames == 2);
    ir_psp_set_log_callback(log_entry);
    private_log(RETRO_LOG_WARN, "loading warning %d %s", 7, "context");
    assert(captured_level == RETRO_LOG_WARN && !strcmp(captured, "loading warning 7 context"));
    char long_message[4096]; memset(long_message, 'x', sizeof(long_message) - 1); long_message[4095] = 0;
    private_log(RETRO_LOG_ERROR, "%s", long_message);
    assert(strlen(captured) == 2047);
    ir_psp_set_log_callback(NULL);
    assert(release());
    puts("PASS: PSP completed steps, input polls, fresh/duplicate/changed images and bounded core logs remain distinct");
    return 0;
}
