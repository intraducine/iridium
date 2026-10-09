// SPDX-License-Identifier: AGPL-3.0-only
// Compile the unchanged production bridge against controlled local retro_* calls.
#include "IridiumCoreBridge.c"
#include <assert.h>
#include <stdio.h>

static retro_environment_t fake_environment;
static retro_input_poll_t fake_poll;
static retro_input_state_t fake_input;
static unsigned runs, run_polls;
static bool accept_game = true, fail_in_run;
static uint16_t expected_buttons;

void retro_set_environment(retro_environment_t callback) { fake_environment = callback; }
void retro_set_video_refresh(retro_video_refresh_t callback) { (void)callback; }
void retro_set_audio_sample_batch(retro_audio_sample_batch_t callback) { (void)callback; }
void retro_set_input_poll(retro_input_poll_t callback) { fake_poll = callback; }
void retro_set_input_state(retro_input_state_t callback) { fake_input = callback; }
void retro_init(void) { fake_poll(); }
bool retro_load_game(const struct retro_game_info *game)
{
    assert(game->data && game->size == 0x150);
    fake_poll(); // Initialization callbacks must not acknowledge a step.
    return accept_game;
}
void retro_get_system_av_info(struct retro_system_av_info *av)
{
    fake_poll();
    av->timing.fps = 60; av->timing.sample_rate = 48000;
}
void retro_unload_game(void) { fake_poll(); }
void retro_deinit(void) { fake_poll(); }
size_t retro_get_memory_size(unsigned id) { (void)id; fake_poll(); return 0; }
void *retro_get_memory_data(unsigned id)
{
    static uint8_t unused_save;
    (void)id;
    return &unused_save;
}

static void check_snapshot(void)
{
    for (unsigned repeat = 0; repeat < 4; ++repeat) {
        assert((uint16_t)fake_input(0, RETRO_DEVICE_JOYPAD, 0,
                                   RETRO_DEVICE_ID_JOYPAD_MASK) == expected_buttons);
        for (unsigned bit = 0; bit < 16; ++bit)
            assert(fake_input(0, RETRO_DEVICE_JOYPAD, 0, bit) == ((expected_buttons >> bit) & 1));
        assert(fake_input(1, RETRO_DEVICE_JOYPAD, 0, 0) == 0);
        assert(fake_input(0, RETRO_DEVICE_JOYPAD, 1, 0) == 0);
        assert(fake_input(0, RETRO_DEVICE_JOYPAD, 0, 16) == 0);
        assert(fake_input(0, RETRO_DEVICE_ANALOG, 0, 0) == 0);
        assert(fake_input(0, 99, 0, 0) == 0);
    }
}

void retro_run(void)
{
    ++runs;
    check_snapshot(); // Repeated input_state reads alone do not count as a poll.
    for (unsigned count = 0; count < run_polls; ++count) {
        fake_poll();
        check_snapshot();
    }
    if (fail_in_run) assert(fake_environment(RETRO_ENVIRONMENT_SHUTDOWN, NULL));
}

static bool step(uint16_t buttons, IRCoreFrame *frame)
{
    expected_buttons = buttons;
    frame->input_polled = true;
    return ir_core_step(buttons, frame);
}

int main(void)
{
    uint8_t rom[0x150] = {0}; // Synthetic bytes, interpreted only by our fake core.
    IRCoreFrame frame = {0};
    assert(!step(1, &frame));
    assert(!frame.input_polled && runs == 0);
    accept_game = false;
    assert(!ir_core_open(rom, sizeof(rom), "/fixture"));
    assert(!core.input_polled);
    assert(!step(1, &frame));
    assert(!frame.input_polled && runs == 0);

    accept_game = true;
    assert(ir_core_open(rom, sizeof(rom), "/fixture"));
    assert(!core.input_polled); // Polls in init/load/AV callbacks do not count.
    assert(!ir_core_step(1, NULL) && runs == 0);
    assert(step(0xA55A, &frame));
    assert(!frame.input_polled && runs == 1);
    fake_poll();
    assert(!core.input_polled);
    assert(ir_core_save_size(false) == 0);
    assert(!core.input_polled); // Poll from another API call is also outside run.

    run_polls = 3;
    assert(step(0xA55A, &frame) && frame.input_polled);
    assert(step(0x5AA5, &frame) && frame.input_polled);
    run_polls = 0;
    assert(step(0, &frame) && !frame.input_polled); // Reset acknowledgment each step.
    run_polls = 1;
    assert(step(0x8001, &frame) && frame.input_polled);
    fail_in_run = true;
    assert(!step(0x8001, &frame) && frame.input_polled);
    unsigned previous_runs = runs;
    assert(!step(0, &frame));
    assert(!frame.input_polled && runs == previous_runs);

    ir_core_close();
    assert(!step(0, &frame));
    assert(!frame.input_polled && runs == previous_runs);
    fail_in_run = false; run_polls = 0;
    assert(ir_core_open(rom, sizeof(rom), "/fixture"));
    assert(!core.input_polled);
    assert(step(0, &frame) && !frame.input_polled);
    ir_core_close();

    puts("PASS: check_core_input_poll (open, failure, close, poll scope, stable digital snapshots)");
    return 0;
}
