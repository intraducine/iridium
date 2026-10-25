// SPDX-License-Identifier: AGPL-3.0-only
#include "IRPhase3.h"
#include "IRAudioVolume.h"
#include "IRDolphinAPI.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef void *(*Create)(const char *, const char *, const char *, const char *, const char *, bool, uint64_t, IRPhase3Event, IRPhase3Poll);
static Create create;
static void (*pause_player)(bool), (*stop_player)(void);
static uint64_t (*frames)(void);
static const IRDolphinAPI *dolphin;
static bool (*prepare_jit)(IRPhase3JITPrepare);
// Loaded images deliberately remain resident. Clean shutdown releases the
// session, never executable code that an upstream worker might still reference.
static const char *binary(const char *engine) {
    if (!strcmp(engine, "azahar")) return "azahar_libretro.dylib";
    if (!strcmp(engine, "play")) return "play_libretro_ios.dylib";
    if (!strcmp(engine, "flycast")) return "flycast_libretro.dylib";
    if (!strcmp(engine, "dolphin")) return "libIridiumDolphin.dylib";
    return NULL;
}
static bool path(char *out, size_t size, const char *root, const char *name) {
    int n = snprintf(out, size, "%s/%s", root, name);
    return n > 0 && (size_t)n < size;
}
bool ir_phase3_available(const char *engine, const char *root) {
    const char *name = engine ? binary(engine) : NULL;
    char file[4096];
    if (!name || !root || !path(file, sizeof file, root, name)) return false;
    // Presence is only packaging readiness; open validates the full ABI.
    FILE *stream = fopen(file, "rb");
    if (!stream) return false;
    fclose(stream); return true;
}
void *ir_phase3_open(const char *engine, const char *root, const char *game,
    const char *save, const char *assets, bool jit, uint64_t generation, IRPhase3Event event, IRPhase3Poll input) {
    const char *name = engine ? binary(engine) : NULL;
    char host[4096], core[4096];
    if (!name || !root || !game || !save || !assets || !event || !input ||
        !path(core, sizeof core, root, name) ||
        !path(host, sizeof host, root, !strcmp(engine, "dolphin") ? name : "libIridiumRetroPlayer.dylib")) return NULL;
    void *image = dlopen(host, RTLD_NOW | RTLD_LOCAL);
    if (!image) { event(generation, 3, "The bundled engine player could not be loaded."); return NULL; }
    unsigned (*abi)(void) = (unsigned (*)(void))dlsym(image, "ir_native_engine_abi");
    Create next = (Create)dlsym(image, "ir_native_engine_create");
    void (*p)(bool) = (void (*)(bool))dlsym(image, "ir_native_engine_pause");
    void (*s)(void) = (void (*)(void))dlsym(image, "ir_native_engine_stop");
    uint64_t (*f)(void) = (uint64_t (*)(void))dlsym(image, "ir_native_engine_frames");
    if (!abi || abi() != 1 || !next || !p || !s || !f) {
        event(generation, 3, "The bundled engine player has an incompatible interface."); return NULL;
    }
    create = next; pause_player = p; stop_player = s; frames = f;
    dolphin = NULL;
    prepare_jit = NULL;
    if (strcmp(engine, "dolphin")) {
        void *core_image = dlopen(core, RTLD_NOW | RTLD_LOCAL);
        if (core_image) prepare_jit = (bool (*)(IRPhase3JITPrepare))dlsym(core_image, "ir_phase3_core_prepare_jit");
        if (!prepare_jit) {
            event(generation, 3, "The bundled core does not support shared JIT. Reinstall Iridium."); return NULL;
        }
    }
    if (!strcmp(engine, "dolphin")) {
        const IRDolphinAPI *(*api)(void) = (const IRDolphinAPI *(*)(void))dlsym(image, "ir_dolphin_api");
        if (api) dolphin = api();
        if (!dolphin || dolphin->version != 1) {
            event(generation, 3, "The bundled Dolphin interface is incomplete."); return NULL;
        }
    }
    if (!ir_audio_volume_bind(image, "ir_native_engine_set_volume")) {
        event(generation, 3, "The bundled player does not support game volume. Reinstall Iridium."); return NULL;
    }
    return create(engine, core, game, save, assets, jit, generation, event, input);
}
void ir_phase3_pause(bool paused) { if (pause_player) pause_player(paused); }
void ir_phase3_stop(void) { if (stop_player) stop_player(); }
uint64_t ir_phase3_frames(void) { return frames ? frames() : 0; }
bool ir_phase3_configure_jit(IRPhase3JITPrepare prepare) {
    return prepare && prepare_jit && prepare_jit(prepare);
}
bool ir_phase3_dolphin_configure(IRDolphinOptions options, IRDolphinPoll poll, IRDolphinJITPrepare prepare) {
    if (!dolphin || !poll) return false;
    dolphin->configure(options, poll, prepare); return true;
}
void ir_phase3_dolphin_settings(IRDolphinOptions options) { if (dolphin) dolphin->settings(options); }
IRDolphinStats ir_phase3_dolphin_stats(void) { return dolphin ? dolphin->stats() : (IRDolphinStats){0}; }
void ir_phase3_dolphin_state(bool load, unsigned slot) { if (dolphin) dolphin->state(load, slot); }
bool ir_phase3_dolphin_install_wad(const char *root, const char *save, const char *wad, IRDolphinCompletion completion) {
    char file[4096];
    if (!root || !save || !wad || !completion || !path(file, sizeof file, root, "libIridiumDolphin.dylib")) return false;
    void *image = dlopen(file, RTLD_NOW | RTLD_LOCAL);
    if (!image) return false;
    const IRDolphinAPI *(*get_api)(void) = (const IRDolphinAPI *(*)(void))dlsym(image, "ir_dolphin_api");
    const IRDolphinAPI *api = get_api ? get_api() : NULL;
    if (!api || api->version != 1 || !api->install_wad) return false;
    api->install_wad(save, wad, completion); return true;
}
