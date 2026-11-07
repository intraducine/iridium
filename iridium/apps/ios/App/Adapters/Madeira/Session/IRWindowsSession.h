// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

enum { IR_WINDOWS_SESSION_MAGIC = 0x49525731, IR_WINDOWS_SESSION_VERSION = 1 };
enum IRWindowsSessionPhase { IR_WINDOWS_IDLE, IR_WINDOWS_RUNNING, IR_WINDOWS_DRAINING,
    IR_WINDOWS_EXITED, IR_WINDOWS_FAILED };
typedef struct {
    uint32_t magic, version;
    uint8_t token[16];
    uint16_t executable[1024], arguments[4096], directory[1024], environment[32768];
} IRWindowsLaunch;
typedef struct {
    uint32_t magic, version;
    uint8_t token[16];
    uint32_t phase, result;
} IRWindowsStatus;

static inline bool ir_windows_string_valid(const uint16_t *text, size_t capacity, bool required) {
    if (required && !*text) return false;
    for (size_t i = 0; i < capacity; ++i) {
        uint16_t c = text[i];
        if (!c) return true;
        if (c < 32 || c == 127) return false;
        if (c >= 0xd800 && c <= 0xdbff) {
            if (++i == capacity || text[i] < 0xdc00 || text[i] > 0xdfff) return false;
        } else if (c >= 0xdc00 && c <= 0xdfff) return false;
    }
    return false;
}
static inline bool ir_windows_launch_valid(const IRWindowsLaunch *request) {
    unsigned token = 0;
    for (size_t i = 0; i < sizeof(request->token); ++i) token |= request->token[i];
    return request->magic == IR_WINDOWS_SESSION_MAGIC && request->version == IR_WINDOWS_SESSION_VERSION && token &&
        ir_windows_string_valid(request->executable, 1024, true) &&
        ir_windows_string_valid(request->arguments, 4096, false) &&
        ir_windows_string_valid(request->directory, 1024, true) &&
        request->environment[32766] == 0 && request->environment[32767] == 0;
}
_Static_assert(sizeof(IRWindowsLaunch) == 77848, "Windows request ABI");
_Static_assert(sizeof(IRWindowsStatus) == 32, "Windows status ABI");
