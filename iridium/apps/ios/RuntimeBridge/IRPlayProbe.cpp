// SPDX-License-Identifier: AGPL-3.0-only
#include <cstddef>
#include "MemoryFunction.h"
#include "IRJITExecutionProbe.h"
#include <cstring>
#include <string>
static std::string save_root;
extern "C" const char *ir_play_save_root() { return save_root.c_str(); }
extern "C" bool ir_phase3_core_prepare(const char *save) {
    if (!save || !*save || !save_root.empty()) return false;
    save_root = save; return true;
}
extern "C" bool ir_phase3_core_check_jit() {
#if defined(__aarch64__)
    // Actual upstream CMemoryFunction allocation, W^X, cache invalidation and
    // modification path. No replacement allocator and no foreign detach RPC.
    try {
        const uint32_t first[] = {0xd2800540, 0xd65f03c0};
        CMemoryFunction code(first, sizeof first);
        if (!ir_jit_probe_execute(code.GetCode(), sizeof first, 42)) return false;
        code.BeginModify();
        const uint32_t second[] = {0xd28000e0, 0xd65f03c0};
        memcpy(code.GetCode(), second, sizeof second); code.EndModify();
        return ir_jit_probe_execute(code.GetCode(), sizeof second, 7);
    } catch (...) { return false; }
#else
    return false;
#endif
}
