// Iridium integration, 2026-09-08. The production translator lives in
// Madeira's xtajit64.dll. Its separate native FEX smoke-test UI is not linked.
#include <stdint.h>
#include <stdlib.h>
#include <libkern/OSCacheControl.h>

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
