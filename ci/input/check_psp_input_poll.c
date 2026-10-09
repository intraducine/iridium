// SPDX-License-Identifier: AGPL-3.0-only
// Compile the unchanged production source. Only API callbacks and lifecycle
// state are controlled here; the emulator and its asynchronous loader are absent.
#include "IRPSPBridge.c"
#include <assert.h>
#include <stdio.h>

static unsigned runs, run_polls;
static bool boot_pending, poll_in_pending, fail_in_run;
static uint16_t expected_buttons;
static int16_t expected_x, expected_y;

static void check_snapshot(void)
{
    uint16_t buttons = core.stop ? 0 : expected_buttons;
    int16_t x = core.stop ? 0 : expected_x;
    int16_t y = core.stop ? 0 : expected_y;
    for (unsigned repeat = 0; repeat < 4; ++repeat) {
        assert((uint16_t)input(0, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_MASK) == buttons);
        for (unsigned bit = 0; bit < 16; ++bit)
            assert(input(0, RETRO_DEVICE_JOYPAD, 0, bit) == ((buttons >> bit) & 1));
        assert(input(0, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_LEFT,
                     RETRO_DEVICE_ID_ANALOG_X) == x);
        assert(input(0, RETRO_DEVICE_ANALOG, RETRO_DEVICE_INDEX_ANALOG_LEFT,
                     RETRO_DEVICE_ID_ANALOG_Y) == y);
        assert(input(1, RETRO_DEVICE_JOYPAD, 0, 0) == 0);
        assert(input(0, RETRO_DEVICE_JOYPAD, 1, 0) == 0);
        assert(input(0, RETRO_DEVICE_JOYPAD, 0, 16) == 0);
        assert(input(0, RETRO_DEVICE_ANALOG, 1, 0) == 0);
        assert(input(0, RETRO_DEVICE_ANALOG, 0, 2) == 0);
        assert(input(0, 99, 0, 0) == 0);
    }
}

static void fake_run(void)
{
    ++runs;
    check_snapshot(); // Merely reading input_state must not acknowledge input.
    for (unsigned count = 0; count < run_polls; ++count) {
        poll();
        check_snapshot(); // Multiple polls and reads must retain the same sample.
    }
    if (fail_in_run) assert(environment(RETRO_ENVIRONMENT_SHUTDOWN, NULL));
}

static bool fake_pending(void)
{
    if (poll_in_pending) poll(); // Outside retro_run, even when inside step.
    return boot_pending;
}

static void reset(IRPSPPhase phase)
{
    assert(release());
    core.phase = phase;
    core.fps = 60; core.rate = 44100;
    api.retro_run = fake_run;
    api.pending = fake_pending;
    runs = run_polls = 0;
    boot_pending = poll_in_pending = fail_in_run = false;
}

static IRPSPPhase step(uint16_t buttons, int16_t x, int16_t y, IRPSPFrame *frame)
{
    expected_buttons = buttons; expected_x = x; expected_y = y;
    frame->input_polled = true; // Every return must overwrite stale acknowledgment.
    return ir_psp_step(buttons, x, y, frame);
}

int main(void)
{
    IRPSPFrame frame = {0};
    reset(IR_PSP_CLOSED);
    poll();
    assert(!core.input_polled);
    assert(step(1, 2, 3, &frame) == IR_PSP_CLOSED);
    assert(!frame.input_polled && runs == 0);

    reset(IR_PSP_RESTART_REQUIRED);
    assert(step(1, 2, 3, &frame) == IR_PSP_RESTART_REQUIRED);
    assert(!frame.input_polled && runs == 0);

    reset(IR_PSP_FAILED);
    core.failure = true;
    assert(step(1, 2, 3, &frame) == IR_PSP_FAILED);
    assert(!frame.input_polled && runs == 0);

    reset(IR_PSP_BOOTING);
    boot_pending = true;
    assert(step(0xA55A, INT16_MIN, INT16_MAX, &frame) == IR_PSP_BOOTING);
    assert(!frame.input_polled && runs == 1);
    poll();
    assert(!core.input_polled); // No acknowledgment after retro_run has returned.
    poll_in_pending = true;
    assert(step(0xA55A, INT16_MIN, INT16_MAX, &frame) == IR_PSP_BOOTING);
    assert(!frame.input_polled && !core.input_polled);

    // A booting core can genuinely poll even before it presents a frame.
    run_polls = 3;
    assert(step(0xA55A, INT16_MIN, INT16_MAX, &frame) == IR_PSP_BOOTING);
    assert(frame.input_polled && frame.width == 0 && frame.height == 0);
    boot_pending = false;
    assert(step(0x5AA5, 12345, -23456, &frame) == IR_PSP_RUNNING);
    assert(frame.input_polled); // The next step sees the new complete snapshot.
    run_polls = 0;
    assert(step(0, 0, 0, &frame) == IR_PSP_RUNNING);
    assert(!frame.input_polled && !core.input_polled); // No stale previous poll.
    run_polls = 1;
    assert(step(0x8001, -1, 1, &frame) == IR_PSP_RUNNING);
    assert(frame.input_polled);

    fail_in_run = true;
    assert(step(0x8001, -1, 1, &frame) == IR_PSP_FAILED);
    assert(frame.input_polled); // Preserve a real poll when that run then fails.
    unsigned previous_runs = runs;
    assert(step(0, 0, 0, &frame) == IR_PSP_FAILED);
    assert(!frame.input_polled && runs == previous_runs);

    reset(IR_PSP_RUNNING);
    ir_psp_request_stop();
    assert(step(0xFFFF, INT16_MAX, INT16_MIN, &frame) == IR_PSP_CLOSED);
    assert(!frame.input_polled && runs == 0); // Immediate stop, no drain run.

    reset(IR_PSP_BOOTING);
    boot_pending = true; run_polls = 3; poll_in_pending = true;
    ir_psp_request_stop();
    assert(step(0xFFFF, INT16_MAX, INT16_MIN, &frame) == IR_PSP_STOPPING);
    assert(!frame.input_polled && !core.input_polled && runs == 1);
    boot_pending = false;
    assert(step(0xFFFF, INT16_MAX, INT16_MIN, &frame) == IR_PSP_CLOSED);
    assert(!frame.input_polled && runs == 1);

    reset(IR_PSP_CLOSED);
    puts("PASS: check_psp_input_poll (boot, failure, stop, poll scope, stable digital/analog snapshots)");
    return 0;
}
