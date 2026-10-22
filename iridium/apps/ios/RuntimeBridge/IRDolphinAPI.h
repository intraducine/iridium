// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include "IRPhase3.h"
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    int resolution; // 1 = native resolution
    int aspect; // 0 = auto, 1 = 16:9, 2 = 4:3
    int remote; // 0 = sideways, 1 = Nunchuk, 2 = Classic
    int players; // 1...4
    bool dual_core;
    bool use_jit; // requires the shared JIT service and native execution probe
    bool muted;
} IRDolphinOptions;
typedef struct {
    IRPhase3Input controls;
    float left_trigger, right_trigger;
    float acceleration[3]; // Wii coordinates, metres per second squared
    float rotation[3]; // Wii coordinates, radians per second
} IRDolphinInput;
typedef void (*IRDolphinPoll)(unsigned player, IRDolphinInput *);
typedef void *(*IRDolphinJITPrepare)(void *address, size_t bytes);
typedef void (*IRDolphinCompletion)(bool success, bool restart_required, const char *message);
typedef struct {
    double fps, vps, speed;
    uint64_t frames, input_samples;
    bool jit;
} IRDolphinStats;
// Optional Dolphin extension. Other native engines keep their existing ABI.
typedef struct {
    unsigned version;
    void (*configure)(IRDolphinOptions, IRDolphinPoll, IRDolphinJITPrepare);
    void (*settings)(IRDolphinOptions);
    IRDolphinStats (*stats)(void);
    void (*state)(bool load, unsigned slot);
    void (*install_wad)(const char *save_root, const char *wad, IRDolphinCompletion);
} IRDolphinAPI;
bool ir_phase3_dolphin_configure(IRDolphinOptions, IRDolphinPoll, IRDolphinJITPrepare);
void ir_phase3_dolphin_settings(IRDolphinOptions);
IRDolphinStats ir_phase3_dolphin_stats(void);
void ir_phase3_dolphin_state(bool load, unsigned slot);
bool ir_phase3_dolphin_install_wad(const char *frameworks, const char *save_root,
    const char *wad, IRDolphinCompletion);
#ifdef __cplusplus
}
#endif
