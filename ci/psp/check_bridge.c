// SPDX-License-Identifier: AGPL-3.0-only
#define _DEFAULT_SOURCE
#include "IRPSPBridge.h"
#include <assert.h>
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void close_core(void)
{
    ir_psp_request_stop();
    for (unsigned i = 0; i < 2000 && ir_psp_phase() != IR_PSP_CLOSED; ++i) {
        IRPSPFrame frame;
        IRPSPPhase phase = ir_psp_step(0xffff, 32767, -32767, &frame);
        assert(phase == IR_PSP_STOPPING || phase == IR_PSP_CLOSED);
        assert(!frame.pixels && !frame.audio && !frame.audio_frames);
        usleep(1000);
    }
    assert(ir_psp_phase() == IR_PSP_CLOSED);
    ir_psp_request_stop();
    assert(ir_psp_step(0, 0, 0, NULL) == IR_PSP_CLOSED);
}

int main(int argc, char **argv)
{
    assert(argc == 6 || (argc == 7 && !strcmp(argv[6], "--altstack")));
    stack_t previous, installed = {.ss_sp = NULL, .ss_size = 65536, .ss_flags = 0};
    if (argc == 7) {
        installed.ss_sp = malloc(installed.ss_size);
        assert(installed.ss_sp && sigaltstack(&installed, &previous) == 0);
    } // component, valid ELF, invalid ELF, system root, save root
    assert(!ir_psp_open("/missing/component", argv[2], argv[4], argv[5]));
    assert(ir_psp_phase() == IR_PSP_CLOSED);
    for (unsigned cycle = 0; cycle < 3; ++cycle) {
        assert(ir_psp_open(argv[1], argv[2], argv[4], argv[5]));
        assert(ir_psp_phase() == IR_PSP_BOOTING);
        assert(!ir_psp_open(argv[1], argv[2], argv[4], argv[5]));
        unsigned frames = 0; size_t nonzero = 0; IRPSPFrame frame = {0};
        for (unsigned i = 0; i < 1000; ++i) {
            IRPSPPhase phase = ir_psp_step(0, 0, 0, &frame);
            assert(phase == IR_PSP_BOOTING || phase == IR_PSP_RUNNING);
            if (phase == IR_PSP_BOOTING) {
                assert(!frame.pixels && !frame.audio);
                usleep(1000); continue;
            }
            assert(frame.sample_rate == 44100 && frame.fps > 59 && frame.fps < 61);
            assert(frame.audio_frames <= 4096);
            for (size_t s = 0; s < frame.audio_frames * 2; ++s) nonzero += frame.audio[s] != 0;
            if (frame.width == 480 && frame.height == 272 &&
                (frame.pixels[32 * 480 + 32] & 0xffffff) == 0xff0000 &&
                (frame.pixels[240 * 480 + 32] & 0xffffff) == 0x0000ff) ++frames;
            if (frames >= 10 && nonzero > 1000) break;
        }
        assert(frames >= 10 && nonzero > 1000);
        for (unsigned i = 0; i < 20; ++i) assert(ir_psp_step(1, 0, 0, &frame) == IR_PSP_RUNNING);
        assert((frame.pixels[24 * 480 + 24] & 0xffffff) == 0x00ff00);
        for (unsigned i = 0; i < 20; ++i) assert(ir_psp_step(0, 0, 0, &frame) == IR_PSP_RUNNING);
        assert((frame.pixels[24 * 480 + 24] & 0xffffff) == 0xff0000);
        close_core();
        if (installed.ss_sp) {
            stack_t after; assert(sigaltstack(NULL, &after) == 0);
            assert(after.ss_sp == installed.ss_sp && after.ss_size == installed.ss_size && after.ss_flags == 0);
        }
    }
    for (unsigned cycle = 0; cycle < 3; ++cycle) {
        assert(ir_psp_open(argv[1], argv[2], argv[4], argv[5]));
        close_core();
        if (installed.ss_sp) {
            stack_t after; assert(sigaltstack(NULL, &after) == 0);
            assert(after.ss_sp == installed.ss_sp && after.ss_size == installed.ss_size && after.ss_flags == 0);
        } // Cancellation before the first boot pump.
    }
    assert(ir_psp_open(argv[1], argv[3], argv[4], argv[5]));
    for (unsigned i = 0; i < 2000 && ir_psp_phase() != IR_PSP_FAILED; ++i) {
        ir_psp_step(0, 0, 0, NULL); usleep(1000);
    }
    assert(ir_psp_phase() == IR_PSP_FAILED);
    close_core();
    if (installed.ss_sp) {
        stack_t after; assert(sigaltstack(NULL, &after) == 0);
        assert(after.ss_sp == installed.ss_sp && after.ss_size == installed.ss_size && after.ss_flags == 0);
#ifdef __APPLE__
        if ((previous.ss_flags & SS_DISABLE) && previous.ss_size < MINSIGSTKSZ)
            previous.ss_size = MINSIGSTKSZ;
#endif
        assert(sigaltstack(&previous, NULL) == 0);
        free(installed.ss_sp);
    }
    puts("PASS: bridge repeat playback/audio/input, ownership exclusion, immediate boot cancellation, async failure and safe teardown");
}
