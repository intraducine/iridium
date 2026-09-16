// Iridium integration, 2026-09-08. The production translator lives in
// Madeira's xtajit64.dll. Its separate native FEX smoke-test UI is not linked.
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>

// From Madeira FEXBridge.mm, GPL-3.0-or-later; adapted to C.
void __clear_cache(void *start, void *end) {
    sys_icache_invalidate(start, (size_t)((char *)end - (char *)start));
}

int64_t fex_get_jit_write_offset(void) {
    const char *rx = getenv("WINE_IOS_JIT_RX");
    const char *rw = getenv("WINE_IOS_JIT_RW");
    if (!rx || !rw) return 0;
    return (int64_t)(strtoull(rw, NULL, 16) - strtoull(rx, NULL, 16));
}

#include <stdatomic.h>
#include <time.h>
static _Atomic int combat_profile_enabled;
static _Atomic uint64_t combat_last_frame, combat_peak_gap;
void iridium_profile_enable(int enabled) {
    atomic_store(&combat_last_frame, 0);
    atomic_store(&combat_peak_gap, 0);
    atomic_store(&combat_profile_enabled, enabled);
}
void iridium_profile_record(uint64_t now) {
    uint64_t previous = atomic_exchange(&combat_last_frame, now);
    if (!previous || now <= previous) return;
    uint64_t gap = now - previous, peak = atomic_load(&combat_peak_gap);
    while (gap > peak && !atomic_compare_exchange_weak(&combat_peak_gap, &peak, gap)) {}
}
void iridium_profile_present(void) {
    if (!atomic_load(&combat_profile_enabled)) return;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    iridium_profile_record((uint64_t)now.tv_sec * 1000000000 + now.tv_nsec);
}
uint64_t iridium_profile_take_gap(void) { return atomic_exchange(&combat_peak_gap, 0); }

/* Winios keeps the conservative legacy reservation as a fallback. */
extern int winios_reserve_fex_memory(void);

static vm_address_t iridium_fex_reserved;

static int iridium_publish_fex_arena(vm_address_t base, vm_size_t size,
                                     vm_address_t kernel_limit)
{
    char base_text[32], size_text[32];
    snprintf(base_text, sizeof(base_text), "%llx", (unsigned long long)base);
    snprintf(size_text, sizeof(size_text), "%llx", (unsigned long long)size);
    if (setenv("WINE_IOS_FEX_ARENA_BASE", base_text, 1) ||
        setenv("WINE_IOS_FEX_ARENA_SIZE", size_text, 1)) {
        unsetenv("WINE_IOS_FEX_ARENA_BASE");
        unsetenv("WINE_IOS_FEX_ARENA_SIZE");
        vm_deallocate(mach_task_self(), base, size);
        return 0;
    }
    iridium_fex_reserved = base;
    fprintf(stderr,
            "[fex-arena] reserved base=0x%s size=0x%s kernel-limit=0x%llx mode=direct\n",
            base_text, size_text, (unsigned long long)kernel_limit);
    return 1;
}

static int iridium_try_direct_fex_range(vm_address_t kernel_limit,
                                        vm_address_t floor, vm_size_t size)
{
    const vm_address_t step = 0x10000000ULL; /* 256 MB, matches the legacy scan. */
    if (kernel_limit < floor || kernel_limit - floor < size) return 0;

    vm_address_t candidate = (kernel_limit - size) & ~0xffffULL;
    for (;;) {
        vm_address_t base = candidate;
        if (vm_allocate(mach_task_self(), &base, size, VM_FLAGS_FIXED) == KERN_SUCCESS) {
            if (base != candidate) {
                vm_deallocate(mach_task_self(), base, size);
            } else if (vm_protect(mach_task_self(), base, size, FALSE, VM_PROT_NONE) == KERN_SUCCESS) {
                if (iridium_publish_fex_arena(base, size, kernel_limit)) return 1;
            } else {
                vm_deallocate(mach_task_self(), base, size);
            }
        }
        if (candidate < floor + step) break;
        candidate -= step;
    }
    return 0;
}

int iridium_reserve_fex_memory(void)
{
    if (iridium_fex_reserved) return 1;
    if (getenv("WINE_IOS_FEX_ARENA_BASE") && getenv("WINE_IOS_FEX_ARENA_SIZE")) return 1;

    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        const vm_address_t floor = 1ULL << 32; /* Preserve the 32-bit guest range. */
        const vm_size_t preferred_sizes[] = { 16ULL << 30, 8ULL << 30, 4ULL << 30 };

        /* The legacy allocator requires a 2*N contiguous hole to retain an N-byte
         * upper-half arena. That turned a known-working 16 GB Hollow Knight arena
         * into 2 GB under a more fragmented LiveContainer VM map. Reserving the
         * final upper range directly preserves the working geometry when it is free.
         * Wine adopts these published bounds and excludes them from normal views. */
        for (unsigned i = 0; i < sizeof(preferred_sizes) / sizeof(*preferred_sizes); ++i)
            if (iridium_try_direct_fex_range(info.max_address, floor, preferred_sizes[i])) return 1;
    }

    return winios_reserve_fex_memory();
}
