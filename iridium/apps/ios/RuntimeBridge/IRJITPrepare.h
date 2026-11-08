// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *ir_jit_prepare_region(void *address, size_t bytes);
// Zero requests the default console capacity.
bool ir_jit_memory_has_capacity(size_t bytes);
bool ir_jit_memory_prepare_sized(void *(*prepare)(void *, size_t), size_t bytes);
#ifdef __cplusplus
}
#endif
