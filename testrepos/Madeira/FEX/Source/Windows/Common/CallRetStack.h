// SPDX-License-Identifier: MIT
#pragma once

#include <FEXCore/Core/Context.h>
#include <FEXCore/Utils/Allocator.h>
#include <FEXCore/Utils/LogManager.h>
#include <FEXCore/Debug/InternalThreadState.h>

/* iOS-Madeira ml706: the one VA-layout profile, selected in rpmalloc's os_mmap
 * (the earliest allocator in the process) and followed here. C linkage: it is
 * chosen from C. */
extern "C" {
extern uintptr_t ios_fex_band_base;
extern uintptr_t ios_fex_band_end;
}

namespace FEX::Windows::CallRetStack {
struct CallRetStackInfo {
  uint64_t AllocationBase;
  uint64_t AllocationEnd;
  uint64_t DefaultLocation;
};

CallRetStackInfo GetInfoThread(FEXCore::Core::InternalThreadState* Thread) {
  uint64_t Base = reinterpret_cast<uint64_t>(Thread->CallRetStackBase);
  // Leave some room from the base for the default location to allow for underflows without constant exceptions
  return {Base - FEXCore::Utils::FEX_PAGE_SIZE, Base + FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE + FEXCore::Utils::FEX_PAGE_SIZE,
          Base + FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE / 4};
}

void InitializeThread(FEXCore::Core::InternalThreadState* Thread) {
  // Allocate the call-ret stack with guard pages on both sides
  const size_t CallRetStackAllocSize = FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE + 2 * FEXCore::Utils::FEX_PAGE_SIZE;
  const void* CallRetStackAlloc = nullptr;
#ifdef FEX_IOS_HOST
  /* iOS-Madeira ml324: steer the call-ret stack out of the guest VA band.
   *
   * This calls ::VirtualAlloc directly rather than FEXCore::Allocator::VirtualAlloc,
   * so ml321's steering missed it -- ml323 confirmed every other FEXMem_* region moved
   * to 0x74xx while FEXMem_CallRetStacks stayed at 0x73dx, interleaved with guest
   * allocations. This is the worst region to leave there: each 16-byte frame holds a
   * HOST code label (the intra-block adr(&l_CallReturn)), so a guest over-read lands on
   * exactly the kind of value that has been showing up as a bogus branch target
   * ("loaded from guest memory", ml316). Same window and same fallback discipline as
   * AllocatorHooks.h -- see the ml325 correction there for why the band must stay
   * clear of [0x7400000000, 0x7c00000000) (CEF's four 16GB PartitionAlloc pools). */
  {
    MEM_ADDRESS_REQUIREMENTS AddrReq {};
    MEM_EXTENDED_PARAMETER AddrParam {};
    /* ml706: follow the band rpmalloc selected, do not hardcode it. */
    AddrReq.LowestStartingAddress = reinterpret_cast<void*>(ios_fex_band_base);
    AddrReq.HighestEndingAddress = reinterpret_cast<void*>(ios_fex_band_end);
    AddrParam.Type = MemExtendedParameterAddressRequirements;
    AddrParam.Pointer = &AddrReq;
    if (ios_fex_band_base) {
      CallRetStackAlloc = ::VirtualAlloc2(nullptr, nullptr, CallRetStackAllocSize, MEM_RESERVE, PAGE_NOACCESS, &AddrParam, 1);
    }
  }
  /* ml706: NO unconstrained fallback here. Each 16-byte frame holds a HOST
   * code label, so a guest over-read yields exactly the bogus branch targets
   * of ml316 -- guest-band placement is worse than failing outright. */
#else
  if (!CallRetStackAlloc) {
    CallRetStackAlloc = ::VirtualAlloc(nullptr, CallRetStackAllocSize, MEM_RESERVE | MEM_TOP_DOWN, PAGE_NOACCESS);
  }
#endif

  FEXCore::Allocator::VirtualName("FEXMem_CallRetStacks", CallRetStackAlloc,
                                  FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE + 2 * FEXCore::Utils::FEX_PAGE_SIZE);
  FEXCore::Allocator::VirtualTHPControl(CallRetStackAlloc, FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE + 2 * FEXCore::Utils::FEX_PAGE_SIZE,
                                        FEXCore::Allocator::THPControl::Disable);

  Thread->CallRetStackBase = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(CallRetStackAlloc) + FEXCore::Utils::FEX_PAGE_SIZE);
  ::VirtualAlloc(Thread->CallRetStackBase, FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE, MEM_COMMIT, PAGE_READWRITE);

  /* iOS-Madeira: VirtualAlloc(MEM_COMMIT) on a previously-MEM_RESERVE'd
   * PAGE_NOACCESS region might not zero-initialize the pages on iOS. The
   * dispatcher uses callret_sp to BLR via stored values; uninit content
   * (e.g. 0x55 poison from prior wine activity) would BLR to garbage.
   * ml362: the unconditional memset committed the full 16MB as private-dirty
   * per thread (~670MB at 40 threads, ml361 [phys-map] showed these regions
   * fully dirty). ZeroScrub keeps the zero guarantee but only dirties pages
   * that actually hold stale bytes; the stale count is the probe for whether
   * wine's commit really hands back nonzero pages. */
#ifdef FEX_IOS_HOST
  {
    size_t Stale = FEXCore::Allocator::ZeroScrub(Thread->CallRetStackBase, FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE);
    LogMan::Msg::EFmt("[callret] zero-scrub rev=ml362 stale=0x{:x}", Stale);
  }
#endif

  Thread->CurrentFrame->State.callret_sp = GetInfoThread(Thread).DefaultLocation;
  // iOS-Madeira 2026-05-18: mirror CallRetStackBase into CpuStateFrame so JIT
  // code can emit inline bounds checks. Needed because iOS Wine doesn't honor
  // PAGE_NOACCESS on the guard pages, so the SEH-driven HandleAccessViolation
  // never fires — JIT code has to detect-and-reset proactively.
  Thread->CurrentFrame->State.callret_sp_base = reinterpret_cast<uint64_t>(Thread->CallRetStackBase);

#ifdef FEX_IOS_HOST
  /* iOS-Madeira ml263: print the geometry ONCE per process. Two jobs:
   * (1) a verifiable content marker for the JIT-side guard change in BranchOps.cpp
   *     (an emitter constant leaves no string in the binary, so there is otherwise
   *     nothing to grep in the installed bundle);
   * (2) states the window the inline guard now enforces, so a [callret] dump in a
   *     later crash can be read against it without re-deriving the arithmetic. */
  {
    static bool reported = false;
    if (!reported) {
      reported = true;
      auto Info = GetInfoThread(Thread);
      LogMan::Msg::EFmt("[callret-geom] base={:#x} default={:#x} size={:#x} "
                        "guard-window=[base+0x200000, base+0x600000) grows-DOWN",
                        reinterpret_cast<uint64_t>(Thread->CallRetStackBase), Info.DefaultLocation,
                        FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE);
      /* iOS-Madeira ml271: print the REAL CpuStateFrame offsets once.
       *
       * The ntdll-unix side reads these fields out of x28 in signal handlers using
       * hand-derived constants, and ml271 showed why that is unsafe: [rsp-forensics]
       * reported gregs[RSP]=0 using a GUESSED 0x28, when RSP is gregs[4] (0x20 into
       * gregs) and gregs itself is not at 0. A wrong offset reads a neighbouring field
       * and invents a bug. Emit the authoritative values so the unix-side probes can be
       * checked against them instead of re-derived by hand. */
      LogMan::Msg::EFmt("[state-offsets] rip={:#x} gregs={:#x} gregs[RSP]={:#x} "
                        "callret_sp={:#x} callret_sp_base={:#x} flags={:#x} sizeof(CPUState)={:#x}",
                        offsetof(FEXCore::Core::CpuStateFrame, State.rip),
                        offsetof(FEXCore::Core::CpuStateFrame, State.gregs),
                        offsetof(FEXCore::Core::CpuStateFrame, State.gregs[FEXCore::X86State::REG_RSP]),
                        offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp),
                        offsetof(FEXCore::Core::CpuStateFrame, State.callret_sp_base),
                        offsetof(FEXCore::Core::CpuStateFrame, State.flags),
                        sizeof(FEXCore::Core::CPUState));
    }
  }
#endif
}

void DestroyThread(FEXCore::Core::InternalThreadState* Thread) {
  auto CallRetStackInfo = GetInfoThread(Thread);
  ::VirtualFree(reinterpret_cast<void*>(CallRetStackInfo.AllocationBase), 0, MEM_RELEASE);
}

bool HandleAccessViolation(FEXCore::Core::InternalThreadState* Thread, uint64_t Address, uint64_t& CallRetSPReg) {
  auto CallRetStackInfo = GetInfoThread(Thread);
  if (Address >= CallRetStackInfo.AllocationBase && Address < CallRetStackInfo.AllocationEnd) {
    LogMan::Msg::DFmt("Call-ret stack inbalance: {:X}", Address);
    CallRetSPReg = CallRetStackInfo.DefaultLocation;
    return true;
  }
  return false;
}
} // namespace FEX::Windows::CallRetStack
