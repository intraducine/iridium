// SPDX-License-Identifier: MIT
// iOS-Madeira ml611 — see AllocWatch.h for why this exists and why it is shaped
// the way it is (the hot path runs inside malloc/free, so it must not allocate,
// lock, or format).

#include "Utils/AllocWatch.h"

#include <FEXCore/Utils/LogManager.h>

#include <atomic>
#include <cstring>

extern "C" {
volatile int FEX_AllocWatch_Armed = 0;
}

namespace FEXCore::Utils::AllocWatch {
namespace {

  // Direct-mapped, no probing: a collision simply loses the older watch. That is
  // acceptable for a diagnostic AND it is counted, so the report can say how much
  // it might have missed instead of implying full coverage.
  constexpr uint32_t WatchSlots = 512;
  constexpr uint32_t RingSlots = 512;

  struct WatchEntry {
    std::atomic<uint64_t> Ptr;
    uint64_t Size;
    uint64_t Owner; // ml615: registering thread, so Clear() retires only its own
    uint32_t Tag;
  };

  struct Record {
    uint64_t Ptr;
    uint64_t Size;
    uint32_t Event;
    uint32_t Tag;
    uint64_t Thread;
  };

  WatchEntry WatchTable[WatchSlots] {};
  Record Ring[RingSlots] {};

  std::atomic<uint64_t> RingSeq {0};
  std::atomic<uint32_t> LiveWatches {0};
  std::atomic<uint32_t> Collisions {0};

  inline uint32_t SlotFor(const void* Ptr) {
    // rpmalloc hands out 16-byte-aligned blocks, so drop the dead low bits before
    // folding, or every watch would land in a handful of slots.
    const uint64_t V = reinterpret_cast<uint64_t>(Ptr) >> 4;
    return static_cast<uint32_t>((V ^ (V >> 9) ^ (V >> 18)) & (WatchSlots - 1));
  }

  uint64_t CurrentThreadId() {
    // Cheap, allocation-free thread identity: the address of a TLS byte. Only used
    // to tell "same thread" from "different thread", never to name a thread.
    static thread_local char Anchor {};
    return reinterpret_cast<uint64_t>(&Anchor);
  }

  const char* EventName(uint32_t Event) {
    switch (Event) {
    case EV_ALLOC: return "ALLOC";
    case EV_FREE: return "FREE";
    case EV_WATCH: return "watch";
    case EV_UNWATCH: return "unwatch";
    default: return "?";
    }
  }

  void Push(const void* Ptr, uint64_t Size, uint32_t Event, uint32_t Tag) {
    const uint64_t Seq = RingSeq.fetch_add(1, std::memory_order_relaxed);
    Record& R = Ring[Seq & (RingSlots - 1)];
    R.Ptr = reinterpret_cast<uint64_t>(Ptr);
    R.Size = Size;
    R.Event = Event;
    R.Tag = Tag;
    R.Thread = CurrentThreadId();
  }

} // namespace

void Watch(const void* Ptr, uint64_t Size, uint32_t Tag) {
  if (!Ptr) {
    return;
  }
  WatchEntry& E = WatchTable[SlotFor(Ptr)];
  const uint64_t Prev = E.Ptr.load(std::memory_order_relaxed);
  const uint64_t Want = reinterpret_cast<uint64_t>(Ptr);
  if (Prev == Want) {
    return; // already watched (a vector re-push with unchanged data())
  }
  if (Prev != 0) {
    Collisions.fetch_add(1, std::memory_order_relaxed);
  } else {
    LiveWatches.fetch_add(1, std::memory_order_relaxed);
  }
  E.Size = Size;
  E.Tag = Tag;
  E.Owner = CurrentThreadId();
  E.Ptr.store(Want, std::memory_order_release);
  Push(Ptr, Size, EV_WATCH, Tag);
  FEX_AllocWatch_Armed = 1;
}

void Unwatch(const void* Ptr) {
  if (!Ptr) {
    return;
  }
  WatchEntry& E = WatchTable[SlotFor(Ptr)];
  if (E.Ptr.load(std::memory_order_relaxed) != reinterpret_cast<uint64_t>(Ptr)) {
    return;
  }
  Push(Ptr, E.Size, EV_UNWATCH, E.Tag);
  E.Ptr.store(0, std::memory_order_release);
  LiveWatches.fetch_sub(1, std::memory_order_relaxed);
}

/* ml615: CLEAR ONLY THIS THREAD'S WATCHES.
 *
 * The ml614 run reported `live_watches=0` for a CFG that had registered 124
 * predecessor vectors, which I took at face value. It was wrong: DFE runs
 * concurrently on many threads, Clear() wiped the WHOLE table, and any one
 * uneventful pass erased every other pass's watches. An `events=0` census from
 * that build proves nothing about whether those buffers were touched.
 *
 * Ownership is per-slot now, so a pass only retires what it registered. */
void Clear() {
  const uint64_t Self = CurrentThreadId();
  uint32_t Removed = 0;
  for (auto& E : WatchTable) {
    if (E.Ptr.load(std::memory_order_relaxed) && E.Owner == Self) {
      E.Ptr.store(0, std::memory_order_release);
      ++Removed;
    }
  }
  if (Removed) {
    LiveWatches.fetch_sub(Removed, std::memory_order_relaxed);
  }
  /* Disarm only when nothing anywhere is still watched. */
  if (LiveWatches.load(std::memory_order_relaxed) == 0) {
    FEX_AllocWatch_Armed = 0;
  }
}

void ReportAndDisarm(const char* Site) {
  // Disarm FIRST so nothing new lands in the ring while we walk it.
  FEX_AllocWatch_Armed = 0;

  const uint64_t Seq = RingSeq.load(std::memory_order_acquire);
  const uint32_t Coll = Collisions.load(std::memory_order_relaxed);
  const uint32_t Live = LiveWatches.load(std::memory_order_relaxed);
  const bool Overflowed = Seq > RingSlots;
  const uint64_t First = Overflowed ? (Seq - RingSlots) : 0;

  // Always print the census, even when empty: silence must mean "no allocator
  // activity touched a watched buffer", never "the probe was not running".
  LogMan::Msg::EFmt("[alloc-watch] ml611 site={} events={} live_watches={} slot_collisions={}{}", Site, Seq, Live, Coll,
                    Overflowed ? " (RING OVERFLOWED — oldest events lost)" : "");

  /* ⛔⛔ ml621: THE PER-RECORD DRAIN IS GONE. DO NOT REINSTATE IT.
   *
   * ml620 died here. This loop emitted 512 formatted lines through LogMan from
   * inside DFE's corruption path; the exception record came out holding this
   * file's own format-string text and the process terminated on
   *   Unhandled exception code 3d736469   ("ids=" — from the [dfe-cfg] message)
   * That is the ml571 fixed-size-formatter family that IO.cpp already documents:
   * "a fixed-size formatter here has now cost more than it ever explained."
   *
   * The census below is retained because it is one line and it is what revealed
   * the probe's own pathology: events=71,906,680 with slot_collisions=17,174,920
   * in a 512-slot table, and live_watches=816 — more than the table holds, so
   * even that counter was wrong. Across every run this probe produced ZERO
   * findings about the corruption it was built for.
   *
   * If buffer lifetime ever needs watching again, do it OUTSIDE any fault or
   * corruption path and bound it by construction, not by a cap. */
  (void)First;

  Clear();
}

} // namespace FEXCore::Utils::AllocWatch

extern "C" void FEX_AllocWatch_Event(const void* Ptr, uint32_t Event) {
  using namespace FEXCore::Utils::AllocWatch;
  // Hot path: one hash, one load, one compare. No allocation, no lock, no format.
  WatchEntry& E = WatchTable[SlotFor(Ptr)];
  if (E.Ptr.load(std::memory_order_acquire) != reinterpret_cast<uint64_t>(Ptr)) {
    return;
  }
  Push(Ptr, E.Size, Event, E.Tag);
}
