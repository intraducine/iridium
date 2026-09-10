// SPDX-License-Identifier: MIT
#pragma once

#include <cstdint>

/* iOS-Madeira ml611: WATCH SPECIFIC HEAP BUFFERS FOR FREE/REUSE WHILE STILL LIVE.
 *
 * ml610 died because DFE's predecessor vectors came back holding the low 32 bits
 * of FEX-arena pointers (block "id" 918357056 = 0x36BD0000, in a vector whose own
 * data was 0x7c36bd0020). That is the shape of an allocator freelist pointer
 * written into storage that was freed or handed out again — not a random wild
 * write.
 *
 * A canary CANNOT settle this: rpmalloc writes its freelist link into the freed
 * block's CONTENTS, leaving any surrounding guard bytes perfectly intact. The
 * decisive question is instead "was this exact allocation freed or re-issued
 * while the CFG still referenced it", which only the allocator can answer.
 *
 * ⚠️ CONSTRAINT THAT SHAPES THIS ENTIRE FILE: the hot path runs INSIDE
 * malloc/free. It must never allocate, never take a lock, and never format a
 * string — doing any of those would re-enter rpmalloc and could manufacture the
 * very corruption we are chasing. So:
 *   - the watch set is a fixed-size, direct-mapped table (no probing, no growth),
 *   - events go into a fixed ring of PODs (raw pointer/size/event/tag/thread/seq),
 *   - nothing is formatted until ReportAndDisarm(), which runs from the DFE pass
 *     AFTER control has left the allocator.
 * Collisions and ring overflow are COUNTED and reported, so a quiet log means
 * "nothing happened", never "the probe silently dropped it".
 *
 * ⚠️ KNOWN LIMITS — read these before drawing a conclusion from a quiet log:
 *   - The table is PROCESS-GLOBAL while DFE runs on many threads at once, so one
 *     thread's Clear() can drop another's watches. That can only cause MISSED
 *     events, never invented ones; slot_collisions in the report bounds it.
 *   - Only the predecessor vectors are watched. The worklist deque's backing
 *     blocks are NOT (std::deque exposes no way to name them), so a corrupted
 *     worklist entry is reported with its slot address but without alloc history.
 *   - Arming costs every rpmalloc/rpfree in the process one hash+load+compare.
 *     That is a few cycles against ~50-100 for the allocation itself, but it is
 *     not free, and CEF allocates heavily.
 */

extern "C" {
// Hot-path gate. Zero until something is actually being watched, so the cost in
// the common case is one predictable load. Read directly by rpmalloc.
extern volatile int FEX_AllocWatch_Armed;

// Called from rpmalloc's allocate/free paths. Does nothing unless Ptr is watched.
void FEX_AllocWatch_Event(const void* Ptr, uint32_t Event);
}

namespace FEXCore::Utils::AllocWatch {
enum : uint32_t {
  EV_ALLOC = 1,   // allocator handed this address out
  EV_FREE = 2,    // allocator took this address back
  EV_WATCH = 3,   // we started watching it
  EV_UNWATCH = 4, // we stopped watching it
};

// Start/stop watching one allocation. Tag is caller-defined (DFE uses the block id).
void Watch(const void* Ptr, uint64_t Size, uint32_t Tag);
void Unwatch(const void* Ptr);

// Drop every watch without reporting (normal, uneventful teardown).
void Clear();

// Dump the ring, then disarm and clear. MUST be called from outside the
// allocator — it formats with LogMan. Prints nothing if no events were recorded,
// beyond a one-line census so silence is never ambiguous.
void ReportAndDisarm(const char* Site);
} // namespace FEXCore::Utils::AllocWatch
