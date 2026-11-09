// SPDX-License-Identifier: AGPL-3.0-only
#include "IRJITReadiness.h"
#include "IRJITExecutionProbe.h"
#include "IRJITPrepare.h"
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <TargetConditionals.h>

bool ir_jit_verify_aliases(void *rx, void *rw) {
#if defined(__aarch64__) && !TARGET_OS_SIMULATOR
    if (!rx || !rw || rx == rw) return false;
    uint32_t original[2], executable[2], code[] = {0xd2800540, 0xd65f03c0}; // return 42
    vm_size_t size = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)rw, sizeof original,
                          (vm_address_t)original, &size) != KERN_SUCCESS || size != sizeof original ||
        vm_read_overwrite(mach_task_self(), (vm_address_t)rx, sizeof executable,
                          (vm_address_t)executable, &size) != KERN_SUCCESS || size != sizeof executable)
        return false;
    int expected = 42;
    if (!memcmp(executable, code, sizeof code)) { code[0] = 0xd28000e0; expected = 7; }
    if (vm_write(mach_task_self(), (vm_address_t)rw, (vm_offset_t)code, sizeof code) != KERN_SUCCESS)
        return false;
    sys_dcache_flush(rw, sizeof code);
    sys_icache_invalidate(rx, sizeof code);
    bool coherent = vm_read_overwrite(mach_task_self(), (vm_address_t)rx, sizeof executable,
                                 (vm_address_t)executable, &size) == KERN_SUCCESS &&
        size == sizeof executable && !memcmp(executable, code, sizeof code);
    bool ran = coherent && ir_jit_probe_execute(rx, sizeof code, expected);
    bool restored = vm_write(mach_task_self(), (vm_address_t)rw, (vm_offset_t)original, sizeof original) == KERN_SUCCESS;
    if (restored) {
        sys_dcache_flush(rw, sizeof original);
        sys_icache_invalidate(rx, sizeof original);
    }
    if (!ran || !restored)
        fprintf(stderr, "[JIT memory] probe coherent=%d executed=%d restored=%d\n", coherent, ran, restored);
    return ran && restored;
#else
    return false;
#endif
}

bool ir_jit_verify_console_memory(void) {
    return ir_jit_memory_verify(ir_jit_verify_aliases);
}
