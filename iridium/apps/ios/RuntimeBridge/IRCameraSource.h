// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct {
    unsigned version;
    void *context;
    void (*request)(void *, unsigned camera, bool active);
    bool (*read)(void *, uint32_t *pixels, size_t capacity, unsigned *width, unsigned *height);
} IRCameraSource;
