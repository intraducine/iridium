// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *ir_jit_prepare_region(void *address, size_t bytes);
typedef struct {
    void *rx, *rw;
    size_t bytes;
    bool bootstrap;
} IRJITWindowsRegion;
bool ir_jit_memory_register_windows(const IRJITWindowsRegion *regions, size_t count);
bool ir_jit_windows_claim(void *rx, size_t bytes, bool code);
void ir_jit_windows_release_code(void *rx, size_t bytes);
void ir_jit_memory_set_windows_reclaimer(void (*reclaim)(void));
bool ir_jit_memory_intersects(const void *address, size_t bytes);
bool ir_jit_memory_verified(void);
bool ir_jit_memory_verify(bool (*probe)(void *, void *));
// Zero requests the full shared capacity.
bool ir_jit_memory_has_capacity(size_t bytes);
bool ir_jit_memory_prepare_sized(void *(*prepare)(void *, size_t), size_t bytes);
#ifdef __cplusplus
}
#endif
