// SPDX-License-Identifier: AGPL-3.0-only
#include "IridiumCoreBridge.h"
#include "SameBoyNamespace.h"
#include "libretro.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define MAX_WIDTH 640
#define MAX_HEIGHT 576
#define MAX_AUDIO_FRAMES 16384
#define MAX_ROM_BYTES (8 * 1024 * 1024)

static struct {
    bool opened, failed, input_active, input_polled;
    unsigned width, height;
    uint16_t buttons;
    uint32_t pixels[MAX_WIDTH * MAX_HEIGHT];
    int16_t samples[MAX_AUDIO_FRAMES * 2];
    size_t sample_frames;
    char directory[4096];
    void *rom;
    double fps, rate;
} core;

static void core_log(enum retro_log_level level, const char *format, ...)
{
    // Upstream diagnostics may contain user ROM/system paths. Do not expose
    // them through the app's exportable log; public phase errors come from UI.
    (void)level; (void)format;
}

static bool environment(unsigned command, void *data)
{
    switch (command) {
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            if (!data) return false;
            ((struct retro_log_callback *)data)->log = core_log; return true;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            return data && *(enum retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            if (!data) return false;
            *(const char **)data = core.directory; return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            if (!data) return false;
            *(bool *)data = false; return true;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            if (!data) return false;
            *(bool *)data = true; return true;
        case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
            return true;
        case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
            if (!data) return false;
            *(unsigned *)data = 0; return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            if (!data) return false;
            struct retro_variable *variable = data;
            // Auto selects the actual cartridge model. No external firmware,
            // SGB border, link cable, real camera, or filesystem-selected BIOS.
            variable->value = NULL;
            return false;
        }
        case RETRO_ENVIRONMENT_SET_GEOMETRY:
        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
        case RETRO_ENVIRONMENT_SET_VARIABLES:
        case RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO:
        case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
            return true;
        case RETRO_ENVIRONMENT_SHUTDOWN:
            core.failed = true; return true;
        default:
            return false; // In particular, never promise JIT or hardware rendering.
    }
}

static void video(const void *pixels, unsigned width, unsigned height, size_t pitch)
{
    if (!pixels) return; // Duplicate previous frame.
    if (pixels == RETRO_HW_FRAME_BUFFER_VALID || !width || !height ||
        width > MAX_WIDTH || height > MAX_HEIGHT || pitch < width * sizeof(uint32_t) ||
        pitch > MAX_WIDTH * sizeof(uint32_t)) {
        core.failed = true; return;
    }
    for (unsigned y = 0; y < height; y++)
        memcpy(core.pixels + y * width, (const uint8_t *)pixels + y * pitch, width * sizeof(uint32_t));
    core.width = width; core.height = height;
}

static size_t audio(const int16_t *samples, size_t frames)
{
    size_t remaining = MAX_AUDIO_FRAMES - core.sample_frames;
    size_t copy = frames < remaining ? frames : remaining;
    if (samples && copy) memcpy(core.samples + core.sample_frames * 2, samples, copy * 2 * sizeof(int16_t));
    core.sample_frames += copy;
    // SameBoy retries unconsumed samples in a loop. Overflow is dropped, never
    // returned as zero, so a slow audio device cannot stall the emulator.
    return frames;
}

static void poll(void)
{
    if (core.input_active) core.input_polled = true;
}
static int16_t input(unsigned port, unsigned device, unsigned index, unsigned id)
{
    if (port || device != RETRO_DEVICE_JOYPAD || index) return 0;
    if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)core.buttons;
    return id < 16 && (core.buttons & (1u << id)) ? 1 : 0;
}

bool ir_core_open(const void *rom, size_t length, const char *system_directory)
{
    if (core.opened || !rom || length < 0x150 || length > MAX_ROM_BYTES ||
        !system_directory || strlen(system_directory) >= sizeof(core.directory)) return false;
    memset(&core, 0, sizeof(core));
    core.rom = malloc(length);
    if (!core.rom) return false;
    memcpy(core.rom, rom, length);
    strcpy(core.directory, system_directory);
    retro_set_environment(environment);
    retro_set_video_refresh(video);
    retro_set_audio_sample_batch(audio);
    retro_set_input_poll(poll);
    retro_set_input_state(input);
    retro_init();
    struct retro_game_info game = { .data = core.rom, .size = length };
    if (!retro_load_game(&game)) {
        retro_deinit(); free(core.rom); core.rom = NULL; return false;
    }
    core.opened = true;
    struct retro_system_av_info av = {0};
    retro_get_system_av_info(&av);
    core.fps = av.timing.fps; core.rate = av.timing.sample_rate;
    if (!isfinite(core.fps) || core.fps < 1 || core.fps > 240 ||
        !isfinite(core.rate) || core.rate < 8000 || core.rate > 768000) {
        ir_core_close(); return false;
    }
    return true;
}

bool ir_core_step(uint16_t buttons, IRCoreFrame *frame)
{
    if (frame) memset(frame, 0, sizeof(*frame));
    if (!core.opened || core.failed || !frame) return false;
    core.buttons = buttons; core.sample_frames = 0;
    core.input_polled = false; core.input_active = true;
    retro_run();
    core.input_active = false;
    *frame = (IRCoreFrame){ core.pixels, core.width, core.height, core.samples,
                           core.sample_frames, core.fps, core.rate, core.input_polled };
    return !core.failed;
}

size_t ir_core_save_size(bool clock)
{
    if (!core.opened) return 0;
    return retro_get_memory_size(clock ? RETRO_MEMORY_RTC : RETRO_MEMORY_SAVE_RAM);
}

bool ir_core_read_save(bool clock, void *bytes, size_t length)
{
    size_t expected = ir_core_save_size(clock);
    if (!core.opened || expected != length || (length && !bytes)) return false;
    void *source = retro_get_memory_data(clock ? RETRO_MEMORY_RTC : RETRO_MEMORY_SAVE_RAM);
    if (length && !source) return false;
    if (length) memcpy(bytes, source, length);
    return true;
}

bool ir_core_write_save(bool clock, const void *bytes, size_t length)
{
    size_t expected = ir_core_save_size(clock);
    if (!core.opened || expected != length || (length && !bytes)) return false;
    void *destination = retro_get_memory_data(clock ? RETRO_MEMORY_RTC : RETRO_MEMORY_SAVE_RAM);
    if (length && !destination) return false;
    if (length) memcpy(destination, bytes, length);
    return true;
}

void ir_core_close(void)
{
    if (!core.opened) return;
    retro_unload_game(); retro_deinit();
    free(core.rom);
    memset(&core, 0, sizeof(core));
}
