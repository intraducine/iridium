// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include "IRPhase3.h"
#ifdef __cplusplus
extern "C" {
#endif
bool ir_phase3_core_prepare_jit(IRPhase3JITPrepare prepare);
void *ir_shared_jit_allocate(size_t size, void **write_pointer);
void *ir_shared_jit_write(void *code);
void ir_shared_jit_release(void *code);
#ifdef __cplusplus
}
#endif
