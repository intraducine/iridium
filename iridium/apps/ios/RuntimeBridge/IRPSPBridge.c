// SPDX-License-Identifier: AGPL-3.0-only
#define _XOPEN_SOURCE 700
#define _DEFAULT_SOURCE
#include "IRPSPBridge.h"
#include "IridiumPSPAPI.h"
#include <dlfcn.h>
#include <math.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>

#define API_FUNCTIONS(X) \
    X(retro_api_version) X(retro_set_environment) X(retro_set_video_refresh) \
    X(retro_set_audio_sample_batch) X(retro_set_input_poll) X(retro_set_input_state) \
    X(retro_init) X(retro_load_game) X(retro_run) X(retro_get_system_av_info) \
    X(retro_unload_game) X(retro_deinit)
#define DECLARE(n) __typeof__(n) *n;
static struct { API_FUNCTIONS(DECLARE) bool (*pending)(void); } api;
#undef DECLARE

static struct {
    void *handle;
    IRPSPPhase phase;
    bool initialized, loaded, format_accepted, stop, failure;
    bool input_active, input_polled;
    char *game, *system, *save;
    struct { char *key, *value; } options[512];
    unsigned option_count, width, height;
    uint16_t buttons;
    int16_t x, y;
    uint32_t pixels[480 * 272];
    int16_t audio[4096 * 2];
    size_t frames;
    double fps, rate;
    bool video_refreshed, image_changed;
    uint64_t steps, video_callbacks, video_frames, changed_frames, input_polls;
} core;

static IRPSPLogCallback log_callback;
void ir_psp_set_log_callback(IRPSPLogCallback callback) { log_callback = callback; }
static void private_log(enum retro_log_level level, const char *format, ...)
{
    if (!log_callback || !format) return;
    char message[2048];
    va_list arguments; va_start(arguments, format);
    vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);
    log_callback((unsigned)level, message);
}

static bool geometry(const struct retro_game_geometry *g, bool include_maximum)
{
    return g && g->base_width == 480 && g->base_height == 272 &&
        (!include_maximum || (g->max_width == 480 && g->max_height == 272));
}
static bool timing(const struct retro_system_av_info *av)
{
    if (!geometry(&av->geometry, true) || !isfinite(av->timing.fps) ||
        av->timing.fps < 1 || av->timing.fps > 240 ||
        !isfinite(av->timing.sample_rate) || av->timing.sample_rate < 8000 ||
        av->timing.sample_rate > 192000) { core.failure = true; return false; }
    core.fps = av->timing.fps; core.rate = av->timing.sample_rate; return true;
}

static void option(const char *key, const char *value)
{
    if (!key || !value) { core.failure = true; return; }
    for (unsigned i = 0; i < core.option_count; ++i) {
        if (!strcmp(core.options[i].key, key)) {
            char *copy = strdup(value);
            if (!copy) { core.failure = true; return; }
            free(core.options[i].value); core.options[i].value = copy; return;
        }
    }
    if (core.option_count == 512) { core.failure = true; return; }
    char *k = strdup(key), *v = strdup(value);
    if (!k || !v) { free(k); free(v); core.failure = true; return; }
    core.options[core.option_count].key = k;
    core.options[core.option_count++].value = v;
}

static bool options(const struct retro_core_options_v2 *definitions)
{
    if (!definitions || !definitions->definitions) return false;
    for (const struct retro_core_option_v2_definition *d = definitions->definitions;
         d->key; ++d) option(d->key, d->default_value ? d->default_value : d->values[0].value);
    const char *overrides[][2] = {
        {"ppsspp_backend", "none"}, {"ppsspp_cpu_core", "IR JIT"},
        {"ppsspp_software_rendering", "enabled"}, {"ppsspp_internal_resolution", "480x272"},
        {"ppsspp_cropto16x9", "disabled"}, {"ppsspp_frameskip", "0"},
        {"ppsspp_auto_frameskip", "disabled"}, {"ppsspp_frame_duplication", "disabled"},
        {"ppsspp_detect_vsync_swap_interval", "disabled"}, {"ppsspp_fast_memory", "disabled"},
        {"ppsspp_ignore_bad_memory_access", "disabled"}, {"ppsspp_force_lag_sync", "disabled"},
        {"ppsspp_enable_wlan", "disabled"},
        {"ppsspp_analog_deadzone", "0.0"}, {"ppsspp_analog_sensitivity", "1.0"},
    };
    for (unsigned i = 0; i < sizeof(overrides) / sizeof(*overrides); ++i)
        option(overrides[i][0], overrides[i][1]);
    return !core.failure;
}

static bool environment(unsigned command, void *data)
{
    if (command == RETRO_ENVIRONMENT_SHUTDOWN) { core.failure = true; return true; }
    if (command == RETRO_ENVIRONMENT_GET_INPUT_BITMASKS) return true;
    if (!data) return false;
    switch (command) {
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            ((struct retro_log_callback *)data)->log = private_log; return true;
        case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION: *(unsigned *)data = 2; return true;
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2: return options(data);
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
            return options(((struct retro_core_options_v2_intl *)data)->us);
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            struct retro_variable *v = data; v->value = NULL;
            if (!v->key) return false;
            for (unsigned i = 0; i < core.option_count; ++i)
                if (!strcmp(v->key, core.options[i].key)) {
                    v->value = core.options[i].value; return true;
                }
            return false;
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: *(bool *)data = false; return true;
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: *(const char **)data = core.system; return true;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: *(const char **)data = core.save; return true;
        case RETRO_ENVIRONMENT_GET_LANGUAGE: *(unsigned *)data = RETRO_LANGUAGE_ENGLISH; return true;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            core.format_accepted = *(enum retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;
            return core.format_accepted;
        case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
            *(unsigned *)data = RETRO_HW_CONTEXT_NONE; return true;
        case RETRO_ENVIRONMENT_GET_JIT_CAPABLE: *(bool *)data = false; return true;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE: *(bool *)data = true; return true;
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: return timing(data);
        case RETRO_ENVIRONMENT_SET_GEOMETRY:
            if (!geometry(data, false)) { core.failure = true; return false; } return true;
        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
        case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK: return true;
        default: return false;
    }
}

static void video(const void *data, unsigned width, unsigned height, size_t pitch)
{
    ++core.video_callbacks;
    if (core.stop || !data) return;
    if (data == RETRO_HW_FRAME_BUFFER_VALID || width != 480 || height != 272 ||
        pitch < width * 4 || pitch > 4096) { core.failure = true; return; }
    bool changed = core.width != width || core.height != height;
    for (unsigned y = 0; y < height; ++y) {
        if (!changed && memcmp(core.pixels + y * width, (const unsigned char *)data + y * pitch, width * 4)) changed = true;
        memcpy(core.pixels + y * width, (const unsigned char *)data + y * pitch, width * 4);
    }
    core.width = width; core.height = height;
    core.video_refreshed = true; core.image_changed |= changed;
    ++core.video_frames;
    if (changed) ++core.changed_frames;
}

static size_t audio(const int16_t *data, size_t frames)
{
    if (core.stop) return frames;
    if (!data && frames) { core.failure = true; return frames; }
    size_t copy = frames < 4096 - core.frames ? frames : 4096 - core.frames;
    if (copy) memcpy(core.audio + core.frames * 2, data, copy * 4);
    core.frames += copy;
    return frames; // Drop bounded overflow rather than blocking the core.
}
static void poll(void)
{
    if (core.input_active && !core.stop) { core.input_polled = true; ++core.input_polls; }
}
static int16_t input(unsigned port, unsigned device, unsigned index, unsigned id)
{
    if (port || core.stop) return 0;
    if (device == RETRO_DEVICE_JOYPAD && index == 0) {
        if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)core.buttons;
        return id < 16 && (core.buttons & (1u << id)) ? 1 : 0;
    }
    if (device == RETRO_DEVICE_ANALOG && index == RETRO_DEVICE_INDEX_ANALOG_LEFT)
        return id == RETRO_DEVICE_ID_ANALOG_X ? core.x : id == RETRO_DEVICE_ID_ANALOG_Y ? core.y : 0;
    return 0;
}

static bool release(void)
{
    // Only call before initialization or after the loading thread has joined.
    bool restore_owner = core.initialized;
    stack_t restore = {0};
    // A serial DispatchQueue can migrate between OS threads. Snapshot this
    // teardown call's thread, never the thread that happened to call open.
    if (restore_owner && (sigaltstack(NULL, &restore) != 0 || (restore.ss_flags & SS_ONSTACK))) {
        core.phase = IR_PSP_RESTART_REQUIRED; return false;
    }
    if (core.loaded) api.retro_unload_game();
    if (core.initialized) api.retro_deinit();
    core.loaded = false; core.initialized = false;
    // Upstream installs its alternate stack on ExecLoader but restores that
    // thread's prior stack on this owner during unload. Preserve our owner's
    // state at the integration boundary, without changing emulator code.
    if (restore_owner) {
#ifdef __APPLE__
        if ((restore.ss_flags & SS_DISABLE) && restore.ss_size < MINSIGSTKSZ)
            restore.ss_size = MINSIGSTKSZ;
#endif
        if (sigaltstack(&restore, NULL) != 0) {
            core.phase = IR_PSP_RESTART_REQUIRED;
            return false; // Never grant a new runtime ownership after failed restoration.
        }
    }
    for (unsigned i = 0; i < core.option_count; ++i) {
        free(core.options[i].key); free(core.options[i].value);
    }
    free(core.game); free(core.system); free(core.save);
    if (core.handle) dlclose(core.handle);
    memset(&core, 0, sizeof(core)); memset(&api, 0, sizeof(api));
    return true;
}

bool ir_psp_open(const char *component, const char *game, const char *system, const char *save)
{
    if (core.phase != IR_PSP_CLOSED || !component || !game || !system || !save) return false;
    core.handle = dlopen(component, RTLD_NOW | RTLD_LOCAL);
    if (!core.handle) return false;
#define LOAD(n) api.n = (__typeof__(api.n))dlsym(core.handle, #n); if (!api.n) { release(); return false; }
    API_FUNCTIONS(LOAD)
#undef LOAD
    api.pending = (bool (*)(void))dlsym(core.handle, "ir_ppsspp_boot_pending");
    if (!api.pending || api.retro_api_version() != RETRO_API_VERSION) { release(); return false; }
    core.game = strdup(game); core.system = strdup(system); core.save = strdup(save);
    if (!core.game || !core.system || !core.save) { release(); return false; }
    core.phase = IR_PSP_BOOTING;
    api.retro_set_environment(environment); api.retro_set_video_refresh(video);
    api.retro_set_audio_sample_batch(audio); api.retro_set_input_poll(poll); api.retro_set_input_state(input);
    if (core.failure) { release(); return false; }
    api.retro_init(); core.initialized = true;
    struct retro_game_info info = { .path = core.game };
    bool accepted = api.retro_load_game(&info);
    // At this exact upstream pin, after format acceptance load allocates ctx
    // before InitStart can fail. That failed path still needs unload cleanup.
    core.loaded = core.format_accepted;
    if (!accepted) core.failure = true;
    if (!core.failure) {
        struct retro_system_av_info av = {0}; api.retro_get_system_av_info(&av);
        timing(&av);
    }
    if (core.failure) core.phase = IR_PSP_FAILED;
    return true;
}

IRPSPPhase ir_psp_phase(void) { return core.phase; }
void ir_psp_request_stop(void)
{
    if (core.phase != IR_PSP_CLOSED && core.phase != IR_PSP_RESTART_REQUIRED) {
        core.stop = true; core.phase = IR_PSP_STOPPING;
    }
}
IRPSPPhase ir_psp_step(uint16_t buttons, int16_t analog_x, int16_t analog_y, IRPSPFrame *frame)
{
    if (frame) memset(frame, 0, sizeof(*frame));
    if (core.phase == IR_PSP_CLOSED || core.phase == IR_PSP_RESTART_REQUIRED) return core.phase;
    if (core.stop && !api.pending()) { release(); return core.phase; }
    if (core.failure && !core.stop) return IR_PSP_FAILED;
    core.buttons = buttons; core.x = analog_x; core.y = analog_y; core.frames = 0;
    // One immutable snapshot for every input_state call in this retro_run.
    // Repeated polls may observe that same held state, but acknowledge it once.
    core.input_polled = false; core.input_active = true;
    core.video_refreshed = false; core.image_changed = false;
    api.retro_run();
    ++core.steps;
    core.input_active = false;
    if (frame) {
        frame->input_polled = core.input_polled;
        frame->video_refreshed = core.video_refreshed; frame->image_changed = core.image_changed;
        frame->steps = core.steps; frame->video_callbacks = core.video_callbacks;
        frame->video_frames = core.video_frames; frame->changed_frames = core.changed_frames;
        frame->input_polls = core.input_polls;
    }
    if (core.stop) {
        if (!api.pending()) { release(); return core.phase; }
        return IR_PSP_STOPPING;
    }
    core.phase = core.failure ? IR_PSP_FAILED : api.pending() ? IR_PSP_BOOTING : IR_PSP_RUNNING;
    if (frame && core.phase == IR_PSP_RUNNING) {
        frame->pixels = core.pixels; frame->width = core.width; frame->height = core.height;
        frame->audio = core.audio; frame->audio_frames = core.frames;
        frame->fps = core.fps; frame->sample_rate = core.rate;
    }
    return core.phase;
}
