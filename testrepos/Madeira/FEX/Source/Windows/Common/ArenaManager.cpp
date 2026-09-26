// SPDX-License-Identifier: GPL-3.0-or-later
//
// ⛔ NOT BUILT. Superseded by Wine's reserved-area machinery (ml799-ml802).
//
// The shipping arena is a FEX_ONLY reserved area owned by ntdll-unix: Wine holds
// the range natively as PROT_NONE, carves views from it for address-constrained
// requests only, and restores PROT_NONE on free. That is task-wide by
// construction, which this manager is not -- its tables are static inside the
// FEX image, and pseudo-processes carry separate libarm64ecfex mappings, so two
// x64 processes would have kept independent hole tables for one reservation.
//
// Kept as a tested reference (37 host checks in research/arena-tests), not as a
// second owner. Adopting it again would reintroduce the two-owner bug the arena
// exists to remove.
#include "ArenaManager.h"

#include <FEXCore/Utils/LogManager.h>

#include <atomic>
#include <mutex>
#include <windows.h>

namespace FEX {
namespace Windows {
namespace Arena {

namespace {

constexpr size_t GRAN = 0x10000; /* 64K: the placeholder split granularity */

/* Fixed capacity, statically stored. See the header: growing a container here
 * would re-enter Alloc through the heap and deadlock under our own lock. */
constexpr unsigned MAX_HOLES = 4096;
constexpr unsigned MAX_LIVE = 8192;

struct Span {
  uintptr_t Base;
  size_t Size;
};

std::mutex Lock;
uintptr_t ArenaBase = 0;
uintptr_t ArenaEnd = 0;

Span Holes[MAX_HOLES]; /* sorted by Base, disjoint, coalesced */
unsigned HoleCount = 0;
Span Live[MAX_LIVE]; /* live carves, sorted by Base */
unsigned LiveCount = 0;

Inject InjectMode = Inject::None;
unsigned InjectAt = 0;
std::atomic<unsigned> InjectCounter {0};

bool ShouldInject(Inject Want) {
  if (InjectMode != Want) {
    return false;
  }
  return (++InjectCounter == InjectAt);
}

size_t RoundUp(size_t V, size_t A) {
  return (V + A - 1) & ~(A - 1);
}

/* --- fixed-table helpers. All callers hold Lock. --- */

bool HoleInsert(unsigned At, uintptr_t B, size_t S) {
  if (HoleCount >= MAX_HOLES) {
    return false;
  }
  for (unsigned i = HoleCount; i > At; --i) {
    Holes[i] = Holes[i - 1];
  }
  Holes[At] = {B, S};
  ++HoleCount;
  return true;
}

void HoleErase(unsigned At) {
  for (unsigned i = At; i + 1 < HoleCount; ++i) {
    Holes[i] = Holes[i + 1];
  }
  --HoleCount;
}

unsigned HoleLowerBound(uintptr_t B) {
  unsigned Lo = 0, Hi = HoleCount;
  while (Lo < Hi) {
    unsigned Mid = (Lo + Hi) / 2;
    if (Holes[Mid].Base < B) {
      Lo = Mid + 1;
    } else {
      Hi = Mid;
    }
  }
  return Lo;
}

unsigned LiveFind(uintptr_t B) {
  unsigned Lo = 0, Hi = LiveCount;
  while (Lo < Hi) {
    unsigned Mid = (Lo + Hi) / 2;
    if (Live[Mid].Base < B) {
      Lo = Mid + 1;
    } else {
      Hi = Mid;
    }
  }
  return Lo;
}

bool LiveInsert(uintptr_t B, size_t S) {
  if (LiveCount >= MAX_LIVE) {
    return false;
  }
  unsigned At = LiveFind(B);
  for (unsigned i = LiveCount; i > At; --i) {
    Live[i] = Live[i - 1];
  }
  Live[At] = {B, S};
  ++LiveCount;
  return true;
}

void LiveErase(unsigned At) {
  for (unsigned i = At; i + 1 < LiveCount; ++i) {
    Live[i] = Live[i + 1];
  }
  --LiveCount;
}

/* --- kernel placeholder operations --- */

bool SplitPlaceholder(uintptr_t B, size_t S) {
  if (ShouldInject(Inject::SplitFails)) {
    LogMan::Msg::EFmt("[arena] INJECTED split failure at {:#x} size={:#x}", B, S);
    return false;
  }
  return ::VirtualFree(reinterpret_cast<void*>(B), S, MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER) != 0;
}

/* Merge neighbouring placeholders IN THE KERNEL. Coalescing only the
 * bookkeeping leaves the kernel with separate placeholders, and a later
 * allocation spanning the boundary then fails for no visible reason. */
bool CoalescePlaceholders(uintptr_t B, size_t S) {
  return ::VirtualFree(reinterpret_cast<void*>(B), S, MEM_RELEASE | MEM_COALESCE_PLACEHOLDERS) != 0;
}

} // namespace

bool IsActive() {
  return ArenaBase != 0;
}
uintptr_t Base() {
  return ArenaBase;
}
uintptr_t End() {
  return ArenaEnd;
}

void SetInject(Inject I, unsigned NthCall) {
  std::lock_guard<std::mutex> G {Lock};
  InjectMode = I;
  InjectAt = NthCall;
  InjectCounter = 0;
}

bool Adopt(uintptr_t base, uintptr_t end) {
  std::lock_guard<std::mutex> G {Lock};
  if (!base || end <= base || (base & (GRAN - 1)) || (end & (GRAN - 1))) {
    LogMan::Msg::EFmt("[arena] REJECTED publication [{:#x},{:#x}) -- unaligned, empty or inverted; "
                      "refusing to run with a range we cannot own",
                      base, end);
    return false;
  }
  ArenaBase = base;
  ArenaEnd = end;
  HoleCount = 0;
  LiveCount = 0;
  HoleInsert(0, base, static_cast<size_t>(end - base));
  LogMan::Msg::EFmt("[arena] ADOPTED [{:#x},{:#x}) size={:#x} -- one hole, placeholder backed", base, end,
                    static_cast<size_t>(end - base));
  return true;
}

void* Alloc(size_t Size, size_t Alignment, Policy P) {
  if (!ArenaBase || !Size) {
    return nullptr;
  }
  if (Alignment < GRAN) {
    Alignment = GRAN;
  }
  const size_t Want = RoundUp(Size, GRAN);
  if (Want < Size) { /* overflow */
    return nullptr;
  }

  std::lock_guard<std::mutex> G {Lock};
  for (unsigned i = 0; i < HoleCount; ++i) {
    const uintptr_t HB = Holes[i].Base;
    const size_t HS = Holes[i].Size;
    const uintptr_t Aligned = (HB + Alignment - 1) & ~(uintptr_t)(Alignment - 1);
    if (Aligned < HB) {
      continue;
    }
    const size_t Lead = Aligned - HB;
    if (HS < Lead || HS - Lead < Want) {
      continue;
    }
    const size_t Trail = HS - Lead - Want;

    /* Split only when the carve does not consume the hole exactly. */
    const bool NeedSplit = (Lead || Trail);
    if (NeedSplit && !SplitPlaceholder(Aligned, Want)) {
      LogMan::Msg::EFmt("[arena] split refused at {:#x} size={:#x} -- hole left intact", Aligned, Want);
      continue;
    }

    ULONG Type = MEM_RESERVE | MEM_REPLACE_PLACEHOLDER;
    ULONG Prot = PAGE_NOACCESS;
    if (P == Policy::CommittedRW) {
      Type |= MEM_COMMIT;
      Prot = PAGE_READWRITE;
    }

    void* Got = nullptr;
    if (!ShouldInject(Inject::ReplaceFails)) {
      Got = ::VirtualAlloc(reinterpret_cast<void*>(Aligned), Want, Type, Prot);
    } else {
      LogMan::Msg::EFmt("[arena] INJECTED replace failure at {:#x} size={:#x}", Aligned, Want);
    }

    if (!Got) {
      /* ROLL BACK THE SPLIT. The kernel has already divided the placeholder,
       * so simply keeping the old logical hole would describe a state that no
       * longer exists -- a later carve spanning the boundary would then fail
       * inexplicably. Put the pieces back together before giving up. */
      if (NeedSplit) {
        if (!CoalescePlaceholders(HB, HS)) {
          /* Cannot restore the original shape: record the pieces truthfully
           * rather than claim a hole that is no longer whole. */
          LogMan::Msg::EFmt("[arena] replace failed at {:#x} AND the split could not be rolled back "
                            "-- recording {} fragment(s) instead of one hole",
                            Aligned, (Lead ? 1 : 0) + 1 + (Trail ? 1 : 0));
          HoleErase(i);
          unsigned At = i;
          if (Lead) {
            HoleInsert(At++, HB, Lead);
          }
          HoleInsert(At++, Aligned, Want);
          if (Trail) {
            HoleInsert(At, Aligned + Want, Trail);
          }
          return nullptr;
        }
      }
      LogMan::Msg::EFmt("[arena] replace refused at {:#x} size={:#x} -- rolled back", Aligned, Want);
      continue;
    }

    if (P == Policy::GuardedRW) {
      /* Commit everything but the first and last page, which must fault. */
      if (Want > 2 * GRAN) {
        ::VirtualAlloc(reinterpret_cast<void*>(Aligned + GRAN), Want - 2 * GRAN, MEM_COMMIT, PAGE_READWRITE);
      }
    }

    if (!LiveInsert(Aligned, Want)) {
      /* Without a live record Free() cannot validate, and an unvalidated free
       * corrupts the placeholder map. Refuse the allocation instead. */
      LogMan::Msg::EFmt("[arena] live table full ({} entries) -- refusing the carve at {:#x}", MAX_LIVE, Aligned);
      ::VirtualFree(reinterpret_cast<void*>(Aligned), Want, MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER);
      if (NeedSplit) {
        CoalescePlaceholders(HB, HS);
      }
      return nullptr;
    }

    /* The hole shrinks to its lead and trail. */
    HoleErase(i);
    unsigned At = i;
    if (Lead) {
      HoleInsert(At++, HB, Lead);
    }
    if (Trail) {
      HoleInsert(At, Aligned + Want, Trail);
    }
    return Got;
  }
  return nullptr;
}

bool Free(void* Ptr, size_t Size) {
  if (!ArenaBase) {
    return false;
  }
  const uintptr_t P = reinterpret_cast<uintptr_t>(Ptr);
  if (!Ptr || !Size) {
    LogMan::Msg::EFmt("[arena] Free({:#x},{:#x}) rejected -- null pointer or zero size", P, Size);
    return false;
  }
  if (P & (GRAN - 1)) {
    LogMan::Msg::EFmt("[arena] Free({:#x}) rejected -- not 64K aligned", P);
    return false;
  }
  const size_t Want = RoundUp(Size, GRAN);
  if (Want < Size || P + Want < P) {
    LogMan::Msg::EFmt("[arena] Free({:#x},{:#x}) rejected -- size overflows", P, Size);
    return false;
  }
  if (P < ArenaBase || P + Want > ArenaEnd) {
    LogMan::Msg::EFmt("[arena] Free({:#x},{:#x}) rejected -- outside [{:#x},{:#x})", P, Want, ArenaBase, ArenaEnd);
    return false;
  }

  std::lock_guard<std::mutex> G {Lock};

  /* Must match a live carve EXACTLY. A partial or double free would hand the
   * kernel a placeholder operation describing a range we do not own. */
  const unsigned At = LiveFind(P);
  if (At >= LiveCount || Live[At].Base != P) {
    LogMan::Msg::EFmt("[arena] Free({:#x},{:#x}) rejected -- not a live carve (double free, or a "
                      "pointer into the middle of one)",
                      P, Want);
    return false;
  }
  if (Live[At].Size != Want) {
    LogMan::Msg::EFmt("[arena] Free({:#x},{:#x}) rejected -- live size is {:#x}", P, Want, Live[At].Size);
    return false;
  }

  bool Preserved;
  if (ShouldInject(Inject::PreserveFails)) {
    LogMan::Msg::EFmt("[arena] INJECTED preserve failure at {:#x}", P);
    Preserved = false;
  } else {
    Preserved = ::VirtualFree(Ptr, Want, MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER) != 0;
  }
  if (!Preserved) {
    LogMan::Msg::EFmt("[arena] Free({:#x},{:#x}) could not preserve the placeholder -- that address "
                      "space is now at risk of being taken by something else; keeping it live",
                      P, Want);
    return false;
  }

  LiveErase(At);

  unsigned Pos = HoleLowerBound(P);
  if (!HoleInsert(Pos, P, Want)) {
    LogMan::Msg::EFmt("[arena] hole table full -- {:#x} is placeholder-backed but untracked", P);
    return false;
  }

  /* Coalesce with both neighbours, in the kernel as well as here. Without this
   * a create/destroy churn leaves the arena in ever smaller pieces and capacity
   * shrinks though nothing leaked -- exactly what the churn test looks for. */
  if (Pos + 1 < HoleCount && Holes[Pos].Base + Holes[Pos].Size == Holes[Pos + 1].Base) {
    const size_t Merged = Holes[Pos].Size + Holes[Pos + 1].Size;
    if (CoalescePlaceholders(Holes[Pos].Base, Merged)) {
      Holes[Pos].Size = Merged;
      HoleErase(Pos + 1);
    }
  }
  if (Pos > 0 && Holes[Pos - 1].Base + Holes[Pos - 1].Size == Holes[Pos].Base) {
    const size_t Merged = Holes[Pos - 1].Size + Holes[Pos].Size;
    if (CoalescePlaceholders(Holes[Pos - 1].Base, Merged)) {
      Holes[Pos - 1].Size = Merged;
      HoleErase(Pos);
    }
  }
  return true;
}

void Stats(size_t* LargestHole, size_t* TotalFree, unsigned* FreeSlices, unsigned* LiveOut) {
  std::lock_guard<std::mutex> G {Lock};
  size_t Largest = 0, Total = 0;
  for (unsigned i = 0; i < HoleCount; ++i) {
    if (Holes[i].Size > Largest) {
      Largest = Holes[i].Size;
    }
    Total += Holes[i].Size;
  }
  if (LargestHole) {
    *LargestHole = Largest;
  }
  if (TotalFree) {
    *TotalFree = Total;
  }
  if (FreeSlices) {
    *FreeSlices = HoleCount;
  }
  if (LiveOut) {
    *LiveOut = LiveCount;
  }
}

} // namespace Arena
} // namespace Windows
} // namespace FEX
