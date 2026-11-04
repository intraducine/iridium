// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *ir_jit_prepare_region(void *address, size_t bytes);
#ifdef __cplusplus
}
#endif
