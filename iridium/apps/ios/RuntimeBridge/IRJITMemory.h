// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// The app owns the prepared pages. Cores own leases and never unmap these views.
typedef struct {
    uint32_t size, version;
    bool (*allocate)(size_t bytes, void **rx, void **rw);
    bool (*release)(void *rx, size_t bytes);
} IRJITMemoryAPI;
bool ir_jit_memory_prepare(void *(*prepare)(void *, size_t));
bool ir_jit_memory_ready(void);
const IRJITMemoryAPI *ir_jit_memory_api(void);
#ifdef __cplusplus
}
#endif
