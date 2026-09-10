// SPDX-License-Identifier: MIT
/*
$info$
tags: glue|block-database
desc: Stores information about blocks, and provides C++ implementations to lookup the blocks
$end_info$
*/

#include <FEXCore/Utils/Allocator.h>
#include <FEXCore/Utils/LogManager.h>
#include <FEXCore/HLE/SyscallHandler.h>

#include "Interface/Context/Context.h"
#include "Interface/Core/LookupCache.h"

#ifdef FEX_IOS_HOST
#include <atomic>
#include <cstring>
#endif

namespace FEXCore {
GuestToHostMap::GuestToHostMap()
  : BlockLinks_mbr {"FEXMem_BlockLinks"} {
  BlockLinks_pma = fextl::make_unique<std::pmr::polymorphic_allocator<std::byte>>(&BlockLinks_mbr);
  // Setup our PMR map.
  BlockLinks = BlockLinks_pma->new_object<BlockLinksMapType>();
}

// iOS-Madeira ml606: live/cumulative census for the L1-only A/B. `live` is what
// matters — footprints must be compared at equal live-cache counts, not at equal
// elapsed time, because caches are created and destroyed throughout a run.
static std::atomic<uint64_t> LookupCacheLive {0};
static std::atomic<uint64_t> LookupCacheCumulative {0};
static std::atomic<uint64_t> LookupCacheBytesLive {0};

LookupCache::LookupCache(FEXCore::Context::ContextImpl* CTX)
  : ctx {CTX} {

  // Snapshot ONCE, from the same FEX_CONFIG_OPT accessor every other L2 path in
  // this class uses, so the object is internally consistent for its lifetime.
  //
  // Residual hazard worth knowing: Dispatcher.cpp samples DisableL2Cache through
  // its own FEX_CONFIG_OPT. Both read the same underlying config and it is not
  // mutated at runtime, but if they ever disagreed the JIT would emit an L2
  // lookup against an L1-only allocation. The [lookup-cache] line below prints
  // the mode actually chosen, so a mismatch is visible rather than silent.
  L2Enabled = !DisableL2Cache();

  const size_t L2TableSize = ctx->Config.VirtualMemSize / FEXCore::Utils::FEX_PAGE_SIZE * 8;
  TotalCacheSize = L2TableSize + CODE_SIZE + MAX_L1_SIZE;

  // Block cache ends up looking like this
  // PageMemoryMap[VirtualMemoryRegion >> 12]
  //       |
  //       v
  // PageMemory[Memory & (VIRTUAL_PAGE_SIZE - 1)]
  //       |
  //       v
  // Pointer to Code
  //
  // Allocate a region of memory that we can use to back our block pointers
  // We need one pointer per page of virtual memory
  // At 64GB of virtual memory this will allocate 128MB of virtual memory space
  if (!L2Enabled) {
    // ml606: L1-ONLY. Skip the 16MB L2 table and the 32MB backing arena
    // entirely — with DisableL2Cache the JIT never emits a lookup against them.
    AllocationSize = MAX_L1_SIZE;
#ifdef FEX_IOS_HOST
    AllocationBase = reinterpret_cast<uintptr_t>(FEXCore::Allocator::VirtualAlloc(AllocationSize, false, true));
#else
    AllocationBase = reinterpret_cast<uintptr_t>(FEXCore::Allocator::VirtualAlloc(AllocationSize, false, false));
#endif
    LOGMAN_THROW_A_FMT(AllocationBase != -1ULL, "Failed to allocate L1-only LookupCache");

    // No L2 regions exist. Leave these pointing at nothing usable so a stray
    // consumer faults immediately instead of scribbling on the L1 array.
    PagePointer = 0;
    PageMemory = 0;
  } else {
    AllocationSize = TotalCacheSize;
#ifdef FEX_IOS_HOST
    /* iOS-Madeira: commit upfront. The auto-commit-on-access-violation path
     * (OvercommitTracker.HandleAccessViolation) doesn't take effect cleanly
     * on iOS — pages stay faulting after VirtualAlloc(MEM_COMMIT) returns.
     * Pre-commit the whole region; physical pages are still demand-faulted
     * by the kernel. */
    LogMan::Msg::EFmt("[TI-IC] lookupcache-alloc size=0x{:x}", TotalCacheSize);
    AllocationBase = reinterpret_cast<uintptr_t>(FEXCore::Allocator::VirtualAlloc(TotalCacheSize, false, true));
    LogMan::Msg::EFmt("[TI-IC] lookupcache-alloc -> 0x{:x}", AllocationBase);
#else
    AllocationBase = reinterpret_cast<uintptr_t>(FEXCore::Allocator::VirtualAlloc(TotalCacheSize, false, false));
#endif
    LOGMAN_THROW_A_FMT(AllocationBase != -1ULL, "Failed to allocate PagePointer");
    PagePointer = AllocationBase;
  }

  // Disable THP on whatever we actually mapped.
  FEXCore::Allocator::VirtualTHPControl(reinterpret_cast<const void*>(AllocationBase), AllocationSize,
                                        FEXCore::Allocator::THPControl::Disable);
  CTX->SyscallHandler->MarkOvercommitRange(AllocationBase, AllocationSize);

  if (L2Enabled) {
    FEXCore::Allocator::VirtualName("FEXMem_Lookup", reinterpret_cast<void*>(PagePointer), L2TableSize + CODE_SIZE);

    // Allocate our memory backing our pages
    // We need 32KB per guest page (One pointer per byte)
    // XXX: We can drop down to 16KB if we store 4byte offsets from the code base
    // We currently limit to 128MB of real memory for caching for the total cache size.
    // Can end up being inefficient if we compile a small number of blocks per page
    PageMemory = PagePointer + L2TableSize;

    // L1 Cache
    L1Pointer = PageMemory + CODE_SIZE;
  } else {
    // ml606: the allocation IS the L1 array.
    L1Pointer = AllocationBase;
  }
  FEXCore::Allocator::VirtualName("FEXMem_Lookup_L1", reinterpret_cast<void*>(L1Pointer), MAX_L1_SIZE);

  {
    const uint64_t Live = LookupCacheLive.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint64_t Cum = LookupCacheCumulative.fetch_add(1, std::memory_order_relaxed) + 1;
    const uint64_t Bytes = LookupCacheBytesLive.fetch_add(AllocationSize, std::memory_order_relaxed) + AllocationSize;
    LogMan::Msg::EFmt("[lookup-cache] ml606 mode={} alloc={}MB live={} cumulative={} fleet_live={}MB "
                      "(full-layout would be {}MB/cache)",
                      L2Enabled ? "full-l2" : "l1-only", AllocationSize >> 20, Live, Cum, Bytes >> 20, TotalCacheSize >> 20);
  }

  VirtualMemSize = ctx->Config.VirtualMemSize;

  if (DynamicL1Cache()) {
    // Start at minimum size when dynamic.
    L1PointerMask = MIN_L1_ENTRIES - 1;
  } else {
    // Start at maximum instead.
    L1PointerMask = MAX_L1_ENTRIES - 1;
  }

#ifdef FEX_IOS_HOST
  /* iOS-Madeira: L2/L1 must start all-zero — nonzero stale bytes (the 0x69
   * pattern observed during JIT-pool dumps, or recycled-arena content) make
   * the dispatcher's cbz miss and BR to garbage. The original fix was two
   * unconditional memsets, but those commit 32MB of private-dirty pages per
   * guest thread — ~1.3GB at 40 threads (ml361 [phys-map]), against a 4096MB
   * jetsam limit. ZeroScrub verifies by read (untouched anon pages map the
   * shared zero page, no footprint) and memsets only stale pages. The stale
   * counts double as the probe for whether the hazard still exists at all. */
  size_t StaleL2 = L2Enabled ? FEXCore::Allocator::ZeroScrub(reinterpret_cast<void*>(PageMemory), L2TableSize) : 0;
  size_t StaleL1 = FEXCore::Allocator::ZeroScrub(reinterpret_cast<void*>(L1Pointer), MAX_L1_SIZE);
  LogMan::Msg::EFmt("[TI-IC] zero-scrub rev=ml606 l2-stale=0x{:x} l1-stale=0x{:x}", StaleL2, StaleL1);
#endif
}

LookupCache::~LookupCache() {
  // ml606: free what was actually mapped. PagePointer/TotalCacheSize only
  // describe the full layout and are wrong (PagePointer is 0) in L1-only mode.
  FEXCore::Allocator::VirtualFree(reinterpret_cast<void*>(AllocationBase), AllocationSize);
  ctx->SyscallHandler->UnmarkOvercommitRange(AllocationBase, AllocationSize);

  LookupCacheLive.fetch_sub(1, std::memory_order_relaxed);
  LookupCacheBytesLive.fetch_sub(AllocationSize, std::memory_order_relaxed);

  // No need to free BlockLinks map.
  // These will get freed when their memory allocators are deallocated.
}

void LookupCache::ClearL2Cache(const FEXCore::LookupCacheBaseLockToken& lk) {
  // ml606: nothing to clear in L1-only mode — the L2 regions were never mapped.
  // Without this the VirtualDontNeed below would run against PagePointer == 0.
  if (!L2Enabled) {
    LOGMAN_THROW_A_FMT(PagePointer == 0, "L2 disabled but PagePointer is set");
    AllocateOffset = 0;
    return;
  }

  // Clear out the page memory
  // PagePointer and PageMemory are sequential with each other. Clear both at once.
  FEXCore::Allocator::VirtualDontNeed(reinterpret_cast<void*>(PagePointer),
                                      ctx->Config.VirtualMemSize / FEXCore::Utils::FEX_PAGE_SIZE * 8 + CODE_SIZE, false);
  AllocateOffset = 0;
}

void LookupCache::ClearThreadLocalCaches(const LookupCacheWriteLockToken&) {
  // TODO: Preserve code cache entries?
  // ml606: clear exactly what is mapped. In L1-only mode that is the L1 array
  // alone; using TotalCacheSize here would decommit 48MB we never allocated.
  FEXCore::Allocator::VirtualDontNeed(reinterpret_cast<void*>(AllocationBase), AllocationSize, false);

  // TODO: Rename this member to avoid confusion with code caching
  CachedCodePages.clear();
}

void LookupCache::ClearCache(const LookupCacheWriteLockToken& lk) {
  // Clear L1 and L2 by clearing the full cache.
  ClearThreadLocalCaches(lk);
  Shared->ClearCache(lk);
}

void GuestToHostMap::ClearCache(const LookupCacheWriteLockToken&) {
  // Allocate a new pointer from the BlockLinks pma again.
  BlockLinks = BlockLinks_pma->new_object<BlockLinksMapType>();
  // All code is gone, clear the block list
  BlockList.clear();
}

} // namespace FEXCore
