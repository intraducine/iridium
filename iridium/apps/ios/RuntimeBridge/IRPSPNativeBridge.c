// SPDX-License-Identifier: AGPL-3.0-only
#include "IRPSPNativeBridge.h"
#include <dlfcn.h>
#include <stddef.h>

static void *handle;
static bool loaded;
static struct {
    uint32_t (*abi)(void);
    void *(*create)(const char *, const char *, const char *, bool, IRPSPNativeEvent, IRPSPNativeInput);
    void (*pause)(void), (*resume)(void), (*stop)(void);
    uint64_t (*frames)(void);
    bool (*request)(unsigned, int);
    int (*resolution)(void);
} api;

void *ir_psp_native_open(const char *component, const char *game, const char *memory_stick,
                         const char *assets, bool jit, IRPSPNativeEvent event, IRPSPNativeInput input)
{
    if (!component || !game || !memory_stick || !assets || !event || !input) return NULL;
    if (!loaded) {
        if (!handle) handle = dlopen(component, RTLD_NOW | RTLD_LOCAL);
        if (!handle) return NULL;
#define LOAD(name) api.name = (__typeof__(api.name))dlsym(handle, "ir_native_psp_" #name); if (!api.name) return NULL;
        LOAD(abi) LOAD(create) LOAD(pause) LOAD(resume) LOAD(request) LOAD(resolution) LOAD(stop) LOAD(frames)
#undef LOAD
        loaded = true;
    }
    if (!api.abi || api.abi() != 2 || !api.create || !api.stop || !api.frames) return NULL;
    // Objective-C classes and native globals cannot safely be unloaded with dlclose.
    return api.create(game, memory_stick, assets, jit, event, input);
}
void ir_psp_native_pause(void) { if (api.pause) api.pause(); }
void ir_psp_native_resume(void) { if (api.resume) api.resume(); }
bool ir_psp_native_request(unsigned operation, int value) { return api.request && api.request(operation, value); }
int ir_psp_native_resolution(void) { return api.resolution ? api.resolution() : 2; }
void ir_psp_native_stop(void) { if (api.stop) api.stop(); }
uint64_t ir_psp_native_frames(void) { return api.frames ? api.frames() : 0; }
