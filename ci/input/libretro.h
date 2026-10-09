// SPDX-License-Identifier: AGPL-3.0-only
#ifndef IRIDIUM_INPUT_TEST_LIBRETRO_H
#define IRIDIUM_INPUT_TEST_LIBRETRO_H

// Original, deliberately minimal declarations for host-only bridge fixtures.
// This is not an upstream header or a production ABI compatibility check. Only
// these tests add this directory to the include path; no emulator is linked.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define RETRO_API_VERSION 1
#define RETRO_HW_FRAME_BUFFER_VALID ((void *)(intptr_t)-1)
#define RETRO_DEVICE_JOYPAD 1
#define RETRO_DEVICE_ANALOG 5
#define RETRO_DEVICE_INDEX_ANALOG_LEFT 0
#define RETRO_DEVICE_ID_ANALOG_X 0
#define RETRO_DEVICE_ID_ANALOG_Y 1
#define RETRO_DEVICE_ID_JOYPAD_MASK 256
#define RETRO_MEMORY_SAVE_RAM 0
#define RETRO_MEMORY_RTC 1
#define RETRO_LANGUAGE_ENGLISH 0
#define RETRO_HW_CONTEXT_NONE 0

// Only distinct command identities matter to the controlled fake core.
enum {
    RETRO_ENVIRONMENT_SHUTDOWN,
    RETRO_ENVIRONMENT_GET_INPUT_BITMASKS,
    RETRO_ENVIRONMENT_GET_LOG_INTERFACE,
    RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION,
    RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2,
    RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL,
    RETRO_ENVIRONMENT_GET_VARIABLE,
    RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE,
    RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY,
    RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY,
    RETRO_ENVIRONMENT_GET_LANGUAGE,
    RETRO_ENVIRONMENT_SET_PIXEL_FORMAT,
    RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER,
    RETRO_ENVIRONMENT_GET_JIT_CAPABLE,
    RETRO_ENVIRONMENT_GET_CAN_DUPE,
    RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO,
    RETRO_ENVIRONMENT_SET_GEOMETRY,
    RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS,
    RETRO_ENVIRONMENT_SET_CONTROLLER_INFO,
    RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY,
    RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK,
    RETRO_ENVIRONMENT_SET_VARIABLES,
    RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO,
    RETRO_ENVIRONMENT_SET_MEMORY_MAPS
};

enum retro_pixel_format { RETRO_PIXEL_FORMAT_XRGB8888 = 1 };
enum retro_log_level { RETRO_LOG_DEBUG, RETRO_LOG_INFO, RETRO_LOG_WARN, RETRO_LOG_ERROR };
struct retro_log_callback { void (*log)(enum retro_log_level, const char *, ...); };
struct retro_variable { const char *key, *value; };
struct retro_game_info { const char *path; const void *data; size_t size; const char *meta; };
struct retro_game_geometry {
    unsigned base_width, base_height, max_width, max_height;
    float aspect_ratio;
};
struct retro_system_timing { double fps, sample_rate; };
struct retro_system_av_info {
    struct retro_game_geometry geometry;
    struct retro_system_timing timing;
};
struct retro_core_option_value { const char *value, *label; };
struct retro_core_option_v2_definition {
    const char *key, *desc, *desc_categorized, *info, *info_categorized, *category_key;
    struct retro_core_option_value values[128];
    const char *default_value;
};
struct retro_core_options_v2 {
    void *categories;
    struct retro_core_option_v2_definition *definitions;
};
struct retro_core_options_v2_intl { struct retro_core_options_v2 *us, *local; };

typedef bool (*retro_environment_t)(unsigned, void *);
typedef void (*retro_video_refresh_t)(const void *, unsigned, unsigned, size_t);
typedef size_t (*retro_audio_sample_batch_t)(const int16_t *, size_t);
typedef void (*retro_input_poll_t)(void);
typedef int16_t (*retro_input_state_t)(unsigned, unsigned, unsigned, unsigned);

unsigned retro_api_version(void);
void retro_set_environment(retro_environment_t);
void retro_set_video_refresh(retro_video_refresh_t);
void retro_set_audio_sample_batch(retro_audio_sample_batch_t);
void retro_set_input_poll(retro_input_poll_t);
void retro_set_input_state(retro_input_state_t);
void retro_init(void);
bool retro_load_game(const struct retro_game_info *);
void retro_run(void);
void retro_get_system_av_info(struct retro_system_av_info *);
void retro_unload_game(void);
void retro_deinit(void);
size_t retro_get_memory_size(unsigned);
void *retro_get_memory_data(unsigned);

#endif
