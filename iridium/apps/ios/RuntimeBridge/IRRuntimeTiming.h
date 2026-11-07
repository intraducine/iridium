// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>

// A coalesced timer is a wakeup, not one emulated frame. Bound catch-up after stalls.
struct IRFramePacer {
    double next = 0;
    bool initialized = false;
    uint64_t late = 0, discarded = 0;
    void reset() { initialized = false; }
    unsigned steps(double now, double fps) {
        if (!std::isfinite(now) || !std::isfinite(fps) || fps <= 0) return 0;
        if (!initialized) { next = now; initialized = true; }
        if (now + 0.000001 < next) return 0;
        unsigned owed = 1 + (unsigned)std::min(999999.0, std::max(0.0, (now - next) * fps));
        unsigned count = std::min(3u, owed);
        if (owed > 1) ++late;
        if (owed > count) { discarded += owed - count; next = now + 1 / fps; }
        else next += count / fps;
        return count;
    }
};

// Consumer-only state. Prefill and re-prime without changing pitch or game speed.
struct IRAudioPrefill {
    bool primed = false;
    std::atomic<uint64_t> underruns{0};
    uint32_t frames(uint32_t queued, uint32_t requested, double rate, bool muted) {
        if (muted) { primed = false; return 0; }
        if (!primed && queued < std::ceil(rate * 0.05)) return 0;
        primed = true;
        uint32_t count = std::min(queued, requested);
        if (count < requested) { primed = false; ++underruns; }
        return count;
    }
};
