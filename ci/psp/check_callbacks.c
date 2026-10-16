// SPDX-License-Identifier: AGPL-3.0-only
#include "IRPSPBridge.c"
#include <assert.h>
#include <stdio.h>
int main(void) {
    struct retro_game_geometry g = {480, 272, 0, 0, 0};
    assert(environment(RETRO_ENVIRONMENT_SET_GEOMETRY, &g));
    struct retro_system_av_info av = {.geometry={480,272,480,272,0}, .timing={60,44100}};
    assert(environment(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO, &av));
    assert(core.fps == 60 && core.rate == 44100);
    av.timing.fps = NAN;
    assert(!environment(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO, &av) && core.failure);
    release();
    uint32_t pixels[480 * 272] = {0};
    pixels[0] = 0x123456; pixels[480 * 272 - 1] = 0xabcdef;
    video(pixels, 480, 272, 1920);
    assert(core.width == 480 && core.height == 272);
    assert(core.pixels[0] == 0x123456 && core.pixels[480 * 272 - 1] == 0xabcdef);
    video(NULL, 480, 272, 1920);
    assert(core.pixels[0] == 0x123456);
    video(RETRO_HW_FRAME_BUFFER_VALID, 480, 272, 1920);
    assert(core.failure); release();
    video(pixels, 480, 272, 1919); assert(core.failure); release();
    int16_t samples[8194] = {42};
    assert(audio(samples,4097) == 4097 && core.frames == 4096 && core.audio[0] == 42);
    assert(audio(samples,4097) == 4097 && core.frames == 4096);
    release(); audio(NULL, 1); assert(core.failure); release();
    core.buttons = 0xffff; core.x = -32768; core.y = 32767;
    for (unsigned bit = 0; bit < 16; ++bit) assert(input(0,RETRO_DEVICE_JOYPAD,0,bit) == 1);
    assert(input(0,RETRO_DEVICE_ANALOG,RETRO_DEVICE_INDEX_ANALOG_LEFT,RETRO_DEVICE_ID_ANALOG_X) == -32768);
    assert(input(0,RETRO_DEVICE_ANALOG,RETRO_DEVICE_INDEX_ANALOG_LEFT,RETRO_DEVICE_ID_ANALOG_Y) == 32767);
    assert(input(1,RETRO_DEVICE_JOYPAD,0,0) == 0);
    core.stop = true;
    assert(input(0,RETRO_DEVICE_JOYPAD,0,0) == 0);
    assert(input(0,RETRO_DEVICE_ANALOG,0,0) == 0);
    release();
    puts("PASS: geometry contract, timing rejection, bounded copied video/audio, digital and analog callbacks");
}
