// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif
bool ir_jit_verify_aliases(void *rx, void *rw);
bool ir_jit_verify_console_memory(void);
#ifdef __cplusplus
}
#endif
