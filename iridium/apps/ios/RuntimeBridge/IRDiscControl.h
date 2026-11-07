// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include "libretro.h"
#include <array>
#include <cstring>

enum class IRDiscResult : unsigned { Failed, Changed, RestoreFailed };
static IRDiscResult irDiscReplace(const retro_disk_control_ext_callback& discs, const char* path) {
    if (!path || !discs.get_image_path || !discs.get_image_index || !discs.get_eject_state ||
        !discs.set_eject_state || !discs.replace_image_index) return IRDiscResult::Failed;
    const unsigned index = discs.get_image_index();
    const bool open = discs.get_eject_state();
    std::array<char, 4097> previous{};
    if (!discs.get_image_path(index, previous.data(), previous.size()) || !previous[0] ||
        strnlen(previous.data(), previous.size()) >= previous.size() - 1) return IRDiscResult::Failed;
    retro_game_info next{}; next.path = path;
    try {
        if (discs.set_eject_state(true) && discs.replace_image_index(index, &next) && discs.set_eject_state(false))
            return IRDiscResult::Changed;
    } catch (...) {}
    retro_game_info old{}; old.path = previous.data();
    // Restore the entry before closing the tray; insertion can fail after replacement.
    try {
        bool restored = discs.set_eject_state(true);
        restored = discs.replace_image_index(index, &old) && restored;
        restored = discs.set_eject_state(open) && restored;
        return restored ? IRDiscResult::Failed : IRDiscResult::RestoreFailed;
    } catch (...) { return IRDiscResult::RestoreFailed; }
}
