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
#pragma once
/*
 * The single owner of the published arena.
 *
 * The host process reserves one contiguous range as a PLACEHOLDER and publishes
 * it. Every emulator allocation that must live inside that range carves from
 * here -- allocator spans, thread state, call/return stacks -- rather than each
 * growing its own suballocator. That is the point: the previous arrangement had
 * two parties choosing address space independently and they chose differently.
 * A second independent carver inside the arena would reproduce the same class
 * of bug one level down.
 *
 * Why placeholders rather than plain reservation: a placeholder can be SPLIT,
 * so a slice can be handed out as real memory while the rest of the range stays
 * reserved and unavailable to anything else. On free the slice returns as a
 * placeholder (MEM_RELEASE | MEM_PRESERVE_PLACEHOLDER) instead of becoming free
 * address space that guest modules could take, and neighbouring placeholders
 * are coalesced IN THE KERNEL (MEM_COALESCE_PLACEHOLDERS) -- merging only the
 * bookkeeping would leave a later allocation unable to span the boundary.
 *
 * ⛔ NOTHING HERE MAY ALLOCATE FROM THE HEAP.
 *
 * The heap in this DLL ultimately reaches the allocator that calls into this
 * manager, so a container growing while the lock is held would re-enter Alloc
 * and deadlock. All state is fixed-capacity and statically stored. Running out
 * of table entries is reported as an allocation failure, which callers already
 * handle, rather than grown into.
 */

#include <cstddef>
#include <cstdint>

namespace FEX {
namespace Windows {
namespace Arena {

/* What a carve is for. The manager reserves address space identically for all
 * of them; the difference is what gets committed and with what protection,
 * which is the caller's business and not something one RW default can serve. */
enum class Policy {
  /* Whole slice committed read-write. */
  CommittedRW,
  /* Reserved only. The caller commits and protects what it needs -- JIT
   * regions and anything wanting RX/RW aliasing. */
  ReserveOnly,
  /* Committed read-write EXCEPT the first and last page, which stay
   * inaccessible. Call/return stacks need the guard pages to fault. */
  GuardedRW,
};

/* Half-open [Base, End). Zero Base means no arena was published. */
bool IsActive();
uintptr_t Base();
uintptr_t End();

/* Adopt a published range. Returns false if it does not validate, in which case
 * the caller must FAIL rather than fall back to selecting its own band. */
bool Adopt(uintptr_t base, uintptr_t end);

/* Carve Size bytes at the given alignment. Returns nullptr when no hole is
 * large enough or the tables are full -- an ordinary outcome once a title
 * creates enough threads, so callers must report it, not dereference it. */
void* Alloc(size_t Size, size_t Alignment, Policy P);

/* Return a slice. Address and size must match a live carve exactly; anything
 * else is refused and reported rather than acted on. */
bool Free(void* Ptr, size_t Size);

/* Largest contiguous hole, total free bytes, free-slice count, live count.
 * The churn test compares these before and after, so they must be exact. */
void Stats(size_t* LargestHole, size_t* TotalFree, unsigned* FreeSlices, unsigned* Live);

/* Deterministic failure injection for the paths that only occur under
 * exhaustion or kernel refusal, which no ordinary run reaches. */
enum class Inject {
  None,
  SplitFails,   /* the placeholder split refuses */
  ReplaceFails, /* the split succeeds, the replacement refuses -- the rollback path */
  PreserveFails /* free cannot preserve the placeholder */
};
void SetInject(Inject I, unsigned NthCall);

/* Exercise the carver against the REAL placeholder implementation, under its
 * own flag (MADEIRA_ARENA_TEST). Separate from the feature switch on purpose:
 * a test that only runs when the feature is on cannot decide whether to turn
 * the feature on. No-op unless the flag is set. */
void SelfTest();

} // namespace Arena
} // namespace Windows
} // namespace FEX
