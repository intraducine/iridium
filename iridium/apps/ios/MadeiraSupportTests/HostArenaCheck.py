#!/usr/bin/env python3
"""Exercise Iridium's robust FEX arena reservation without Apple headers."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "MadeiraSupport/NativePool.c").read_text()
start = source.index("extern int winios_reserve_fex_memory(void);")
function = source[start:]

harness = r'''
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
typedef uint64_t vm_address_t;
typedef uint64_t vm_size_t;
typedef int kern_return_t;
typedef int mach_msg_type_number_t;
typedef void *task_info_t;
typedef struct { uint64_t max_address; } task_vm_info_data_t;
#define TASK_VM_INFO_COUNT 1
#define TASK_VM_INFO 1
#define KERN_SUCCESS 0
#define VM_FLAGS_FIXED 0
#define VM_PROT_NONE 0
#define FALSE 0
#define G (1ULL<<30)
static uint64_t ceiling, largest_hole;
static int info_fails, protect_fails, fallback_calls, allocations;
static int mach_task_self(void) { return 1; }
static int task_info(int t, int f, task_info_t i, int *n) {
    (void)t; (void)f; (void)n;
    if (info_fails) return 1;
    ((task_vm_info_data_t *)i)->max_address = ceiling;
    return 0;
}
static int vm_allocate(int t, uint64_t *base, uint64_t size, int flags) {
    (void)t; (void)flags;
    allocations++;
    if (size > largest_hole || *base < 4*G || *base + size > ceiling) return 1;
    return 0;
}
static int vm_protect(int t, uint64_t b, uint64_t s, int max, int p) {
    (void)t; (void)b; (void)s; (void)max; (void)p;
    return protect_fails ? 1 : 0;
}
static int vm_deallocate(int t, uint64_t b, uint64_t s) {
    (void)t; (void)b; (void)s; return 0;
}
int winios_reserve_fex_memory(void) {
    fallback_calls++;
    setenv("WINE_IOS_FEX_ARENA_BASE", "7100000000", 1);
    setenv("WINE_IOS_FEX_ARENA_SIZE", "80000000", 1);
    return 1;
}
'''

main = r'''
int main(int argc, char **argv) {
    (void)argc;
    int mode = atoi(argv[1]);
    ceiling = mode == 0 ? 0x8000000000ULL : 0x7180000000ULL;
    largest_hole = mode == 0 ? 16*G : mode == 1 ? 4*G : mode == 2 ? 8*G : 0;
    info_fails = mode == 3;
    protect_fails = mode == 4;
    if (mode == 4) largest_hole = 16*G;
    if (mode == 5) {
        setenv("WINE_IOS_FEX_ARENA_BASE", "123400000", 1);
        setenv("WINE_IOS_FEX_ARENA_SIZE", "100000000", 1);
    }

    assert(iridium_reserve_fex_memory());
    uint64_t base = strtoull(getenv("WINE_IOS_FEX_ARENA_BASE"), 0, 16);
    uint64_t size = strtoull(getenv("WINE_IOS_FEX_ARENA_SIZE"), 0, 16);
    if (mode == 0) {
        assert(base == 0x7c00000000ULL); /* Same final range as the known-working launch. */
        assert(size == 16*G && fallback_calls == 0);
    } else if (mode == 1) {
        assert(base == 0x7080000000ULL); /* Fragmented 0x718... host now gets 4 GB, not 2 GB. */
        assert(size == 4*G && fallback_calls == 0);
    } else if (mode == 2) {
        assert(size == 8*G && fallback_calls == 0);
    } else if (mode == 3 || mode == 4) {
        assert(size == 2*G && fallback_calls == 1);
    } else if (mode == 5) {
        assert(base == 0x123400000ULL && size == 4*G);
        assert(allocations == 0 && fallback_calls == 0);
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / "arena.c"
    exe = Path(tmp) / "arena"
    src.write_text(harness + function + main)
    subprocess.run(
        ["cc", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Werror", str(src), "-o", str(exe)],
        check=True,
    )
    clean_env = {k: v for k, v in os.environ.items()
                 if k not in {"WINE_IOS_FEX_ARENA_BASE", "WINE_IOS_FEX_ARENA_SIZE"}}
    for mode in range(6):
        subprocess.run([str(exe), str(mode)], check=True, env=clean_env)

print("Host arena reservation: robust direct 16/8/4 GB and legacy fallback passed")
