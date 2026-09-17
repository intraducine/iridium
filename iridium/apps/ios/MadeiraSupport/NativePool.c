// Iridium integration, 2026-09-08. The production translator lives in
// Madeira's xtajit64.dll. Its separate native FEX smoke-test UI is not linked.
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

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

/* The historical 65b596 runtime predates this app-side reservation API.
 * Keep it optional only on this diagnostic branch; newer Winios still owns
 * its reservation and its failure result must be propagated unchanged. */
extern int winios_reserve_fex_memory(void) __attribute__((weak_import));

/* Host arena policy: reserve translator memory AND verify guest headroom. */
static vm_address_t iridium_fex_reserved;

static int iridium_release_fex_probe(vm_address_t base, vm_size_t size)
{
    kern_return_t kr = vm_deallocate(mach_task_self(), base, size);
    if (kr == KERN_SUCCESS) return 1;
    fprintf(stderr, "[fex-arena] probe cleanup failed kr=%d; refusing to launch\n", kr);
    return 0;
}

static int iridium_publish_fex_arena(vm_address_t base, vm_size_t size,
                                     vm_address_t kernel_limit, vm_size_t guest_headroom)
{
    char base_text[32], size_text[32];
    snprintf(base_text, sizeof(base_text), "%llx", (unsigned long long)base);
    snprintf(size_text, sizeof(size_text), "%llx", (unsigned long long)size);
    if (setenv("WINE_IOS_FEX_ARENA_BASE", base_text, 1) ||
        setenv("WINE_IOS_FEX_ARENA_SIZE", size_text, 1)) {
        unsetenv("WINE_IOS_FEX_ARENA_BASE");
        unsetenv("WINE_IOS_FEX_ARENA_SIZE");
        iridium_release_fex_probe(base, size);
        return 0;
    }
    iridium_fex_reserved = base;
    fprintf(stderr,
            "[fex-arena] reserved base=0x%s size=0x%s kernel-limit=0x%llx "
            "mode=guest-budgeted guest-headroom=0x%llx\n",
            base_text, size_text, (unsigned long long)kernel_limit,
            (unsigned long long)guest_headroom);
    return 1;
}

/* Returns 1 on success, 0 when no hole fits, -1 after a setup/cleanup error. */
static int iridium_try_budgeted_fex_range(vm_address_t kernel_limit,
                                          vm_address_t floor, vm_size_t size)
{
    const vm_address_t step = 0x10000000ULL; /* 256 MB scan stride. */
    const vm_size_t minimum_guest = 4ULL << 30;
    vm_size_t guest_headroom = size * 3;
    if (guest_headroom < minimum_guest) guest_headroom = minimum_guest;
    vm_size_t total = guest_headroom + size;
    if (kernel_limit < floor || kernel_limit - floor < total) return 0;

    /* A Mach map walk can advertise holes beyond the task's permitted range,
     * or inside a CPU-inaccessible carveout. A FIXED allocation WITHOUT
     * OVERWRITE proves this entire interval is actually usable and unoccupied.
     * No pages are touched. Retain only the upper FEX portion and release the
     * lower portion for Wine images, guest heaps, stacks and reservations.
     * This is a startup headroom check, not a promise about future allocations. */
    vm_address_t candidate = (kernel_limit - total) & ~0xffffULL;
    for (;;) {
        vm_address_t probe = candidate;
        if (vm_allocate(mach_task_self(), &probe, total, VM_FLAGS_FIXED) == KERN_SUCCESS) {
            if (probe != candidate) {
                if (!iridium_release_fex_probe(probe, total)) return -1;
            } else if (vm_protect(mach_task_self(), probe, total, FALSE, VM_PROT_NONE) != KERN_SUCCESS) {
                iridium_release_fex_probe(probe, total);
                fprintf(stderr, "[fex-arena] cannot protect reservation; refusing to launch\n");
                return -1;
            } else {
                vm_address_t base = probe + guest_headroom;
                if (vm_deallocate(mach_task_self(), probe, guest_headroom) != KERN_SUCCESS) {
                    iridium_release_fex_probe(probe, total);
                    fprintf(stderr, "[fex-arena] cannot release guest headroom; refusing to launch\n");
                    return -1;
                }
                return iridium_publish_fex_arena(base, size, kernel_limit, guest_headroom) ? 1 : -1;
            }
        }
        if (candidate < floor + step) break;
        candidate -= step;
    }
    return 0;
}

int iridium_reserve_fex_memory(void)
{
#if defined(__APPLE__) && TARGET_OS_IPHONE
    if (!winios_reserve_fex_memory) {
        /* 65b596 FEX selects its own band. Do not reserve an unconsumed arena. */
        unsetenv("WINE_IOS_FEX_ARENA_BASE");
        unsetenv("WINE_IOS_FEX_ARENA_SIZE");
        fprintf(stderr, "[hybrid-native] 65b596 reservation API absent; FEX selects its own band\n");
        return 1;
    }
    /* Restore the device-tested launch behavior that existed before 1f7706d.
     * That commit replaced Madeira's Winios reservation with this experimental
     * allocator; subsequent device logs showed 4 GiB guest starvation, then
     * 1 GiB translator starvation, while disabling the reservation entirely
     * left FEX with no usable band. Keep the wrapper for source compatibility,
     * but use the original Madeira/Winios reservation policy on device. */
    fprintf(stderr, "[fex-arena] using restored Madeira/Winios reservation policy\n");
    return winios_reserve_fex_memory();
#endif

    if (iridium_fex_reserved) return 1;
    /* Inherited strings are not proof that this process owns a reservation. */
    unsetenv("WINE_IOS_FEX_ARENA_BASE");
    unsetenv("WINE_IOS_FEX_ARENA_SIZE");

    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        fprintf(stderr, "[fex-arena] cannot read task VM limit; refusing to launch\n");
        return 0;
    }
    const vm_address_t floor = 1ULL << 32;
    const vm_size_t preferred_sizes[] = {
        16ULL << 30, 8ULL << 30, 4ULL << 30, 2ULL << 30, 1ULL << 30
    };
    /* Largest-hole-only selection starved the guest: in a 6 GB usable window,
     * the old direct 4 GB reservation left about 2 GB for everything else.
     * Keep at least 3x the FEX size (and at least 4 GB) available below the arena.
     * This policy uses actual allocation success, never a model/game/OS check. */
    for (unsigned i = 0; i < sizeof(preferred_sizes) / sizeof(*preferred_sizes); ++i) {
        int result = iridium_try_budgeted_fex_range(info.max_address, floor, preferred_sizes[i]);
        if (result != 0) return result > 0;
    }
    /* The old fallback has no guest budget and would undo this safety check. */
    fprintf(stderr, "[fex-arena] no reservation with sufficient guest headroom; refusing to launch\n");
    return 0;
}
