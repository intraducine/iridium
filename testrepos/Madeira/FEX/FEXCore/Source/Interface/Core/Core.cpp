// SPDX-License-Identifier: MIT
/*
$info$
category: glue ~ Logic that binds various parts together
meta: glue|driver ~ Emulation mainloop related glue logic
tags: glue|driver
desc: Glues Frontend, OpDispatcher and IR Opts & Compilation, LookupCache, Dispatcher and provides the Execution loop entrypoint
$end_info$
*/

#include <cstdint>
#ifdef ZYDIS_DISASSEMBLER
#include <Zydis/Zydis.h>
#endif
#include "Interface/Core/ArchHelpers/Arm64Emitter.h"
#include "Interface/Core/LookupCache.h"
#include "Interface/Core/CPUBackend.h"
#include "Interface/Core/CPUID.h"
#include "Interface/Core/Frontend.h"
#include "Interface/Core/OpcodeDispatcher.h"
#include "Interface/Core/JIT/JITClass.h"
#include "Interface/Core/Dispatcher/Dispatcher.h"
#include "Interface/Core/X86Tables/X86Tables.h"
#include <Interface/GDBJIT/GDBJIT.h>
#include "Interface/IR/IR.h"
#include "Interface/IR/IREmitter.h"
#include "Interface/IR/Passes/RegisterAllocationPass.h"
#include "Interface/IR/Passes.h"
#include "Interface/IR/PassManager.h"
#include "Interface/IR/RegisterAllocationData.h"
#include "Utils/Allocator.h"
#include "Utils/Allocator/HostAllocator.h"
#include <FEXCore/Utils/SpinWaitLock.h>
#include "Utils/variable_length_integer.h"

#include <FEXCore/Config/Config.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Core/SignalDelegator.h>
#include <FEXCore/Core/Thunks.h>
#include <FEXCore/Core/X86Enums.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/HLE/SyscallHandler.h>
#include <FEXCore/HLE/SourcecodeResolver.h>
#include <FEXCore/Utils/Allocator.h>
#include <FEXCore/Utils/Event.h>
#include <FEXCore/Utils/File.h>
#include <FEXCore/Utils/LogManager.h>
#include "FEXCore/Utils/SignalScopeGuards.h"
#include <FEXCore/Utils/Threads.h>
#include <FEXCore/Utils/Profiler.h>
#include <FEXCore/Utils/SHMStats.h>
#include <FEXCore/fextl/fmt.h>
#include <FEXCore/fextl/memory.h>
#include <FEXCore/fextl/set.h>
#include <FEXCore/fextl/sstream.h>
#include <FEXCore/fextl/vector.h>
#include <FEXHeaderUtils/Syscalls.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>

/* iOS-Madeira ml622: mirror of rpmalloc's POD snapshot (rpmalloc.c). Declared here
 * rather than in a shared header because rpmalloc is C and vendored; keep the two
 * definitions in sync — the drain below is the only consumer. */
extern "C" {
struct rpm_cas_snapshot {
  unsigned long long page_addr, block_addr, heap_addr, owner_teb;
  unsigned long long prev_token, cur_token, ret_addr, atomic_addr;
  unsigned int size_class, page_type, block_index, list_size;
  unsigned int fail_changed, fail_unchanged, fail_invalid, quarantined;
  unsigned int block_count, block_used, is_full, which_loop;
};
int rpm_cas_snapshot_take(struct rpm_cas_snapshot* out);
}
#include <condition_variable>
#include <fcntl.h>
#include <functional>
#include <mutex>
#include <queue>
#include <shared_mutex>
#include <signal.h>
#include <stdio.h>
#include <string_view>
#include <sys/stat.h>
#include <type_traits>
#include <unistd.h>
#include <unordered_map>
#include <utility>
#include <xxhash.h>

/* iOS-Madeira HOTRIP telemetry — plain globals (no constructors/guard vars).
 * 2026-05-14: per-thread callret tracking (GPT diagnosis: FMOD worker
 * thread leaks callret entries; need to confirm WHICH thread leaks and
 * separate game-thread vs render-thread vs FMOD-worker activity). 4 thread
 * slots hashed by Frame pointer. */
static volatile uint64_t g_madeira_hot_count[12] = {0,0,0,0,0,0,0,0,0,0,0,0};
static volatile uint64_t g_madeira_max_alloc_size = 0;
static volatile uint64_t g_madeira_last_str = 0;
static volatile uint64_t g_madeira_last_vt = 0;
static volatile uint64_t g_madeira_last_vt2 = 0;
static volatile uint64_t g_madeira_callret_max = 0;
static volatile uint64_t g_madeira_callret_min = ~(uint64_t)0;
static volatile uint64_t g_madeira_callret_last = 0;

/* Per-thread tracking (4 slots). Key = Frame ptr (unique per FEX thread).
 * Records callret_sp range, block-dispatch count, and last guest RIP seen
 * to localize WHICH thread is leaking callret entries. */
static volatile uint64_t g_madeira_thr_key[4] = {0,0,0,0};
static volatile uint64_t g_madeira_thr_crsp_min[4] = {~(uint64_t)0, ~(uint64_t)0, ~(uint64_t)0, ~(uint64_t)0};
static volatile uint64_t g_madeira_thr_crsp_max[4] = {0,0,0,0};
static volatile uint64_t g_madeira_thr_crsp_last[4] = {0,0,0,0};
static volatile uint64_t g_madeira_thr_count[4] = {0,0,0,0};
static volatile uint64_t g_madeira_thr_last_rip[4] = {0,0,0,0};

/* iOS-Madeira 2026-05-18 low-noise CompileBlock instrumentation counters. */
static volatile uint64_t g_cb_total = 0;
static volatile uint64_t g_cb_real_compiles = 0;

#if defined(FEX_IOS_HOST) && defined(_WIN32)
/* iOS-Madeira ml460 (#75): pool-tail sweeper, implemented by the ARM64EC
 * frontend (Module.cpp) which owns the thread registry. extern "C" so the
 * cross-layer reference has no namespace in its linkage name. */
extern "C" void IosMaybeSweepCodeBuffers(FEXCore::Core::InternalThreadState* CallerThread);
#endif

namespace FEXCore::Context {
ContextImpl::ContextImpl(const FEXCore::HostFeatures& Features)
  : HostFeatures {Features}
  , CPUID {this}
  , CodeCache {*this} {
  if (!Config.Is64BitMode()) {
    // When operating in 32-bit mode, the virtual memory we care about is only the lower 32-bits.
    Config.VirtualMemSize = 1ULL << 32;
  }
#ifdef FEX_IOS_HOST
  /* iOS-Madeira: shrink the per-thread LookupCache L2 page table from 128MB
   * (64GB VirtualMemSize) to 16MB (8GB). Every thread's LookupCache commits
   * its full arena upfront on iOS (commit-on-fault doesn't work — see
   * LookupCache.cpp), so ~264MB × ~19 game threads ≈ 5GB was killing the
   * process when Thumper's loading screen spawned workers (silent death
   * inside the LookupCache ctor, bisected via [TI-IC] markers). 8GB covers
   * everything the L2 usefully serves anyway: the exe at 0x140000000 (5GB)
   * and low mappings. DLL code at ~0x7EExxxxxxxxx aliased in L2 even at
   * 64GB and is served by the dispatcher's loop-top L1 probe instead. */
  Config.VirtualMemSize = 1ULL << 33;
#endif

  if (Config.BlockJITNaming() || Config.GlobalJITNaming() || Config.LibraryJITNaming()) {
    // Only initialize symbols file if enabled. Ensures we don't pollute /tmp with empty files.
    Symbols.InitFile();
  }

  uint64_t FrequencyCounter = FEXCore::GetCycleCounterFrequency();
  if (FrequencyCounter && FrequencyCounter < FEXCore::Context::TSC_SCALE_MAXIMUM && Config.SmallTSCScale()) {
    // Scale TSC until it is at the minimum required.
    while (FrequencyCounter < FEXCore::Context::TSC_SCALE_MAXIMUM) {
      FrequencyCounter <<= 1;
      ++Config.TSCScale;
    }
  }

  // Track atomic TSO emulation configuration.
  UpdateAtomicTSOEmulationConfig();
}

struct GetFrameBlockInfoResult {
  const CPU::CPUBackend::JITCodeHeader* InlineHeader;
  const CPU::CPUBackend::JITCodeTail* InlineTail;
};
static GetFrameBlockInfoResult GetFrameBlockInfo(FEXCore::Core::CpuStateFrame* Frame) {
  const uint64_t BlockBegin = Frame->State.InlineJITBlockHeader;
  auto InlineHeader = reinterpret_cast<const CPU::CPUBackend::JITCodeHeader*>(BlockBegin);

  if (InlineHeader) {
    auto InlineTail = reinterpret_cast<const CPU::CPUBackend::JITCodeTail*>(Frame->State.InlineJITBlockHeader + InlineHeader->OffsetToBlockTail);
    return {InlineHeader, InlineTail};
  }

  return {InlineHeader, nullptr};
}

bool ContextImpl::IsAddressInCurrentBlock(FEXCore::Core::InternalThreadState* Thread, uint64_t Address, uint64_t Size) {
  auto [_, InlineTail] = GetFrameBlockInfo(Thread->CurrentFrame);
  return InlineTail && (Address + Size > InlineTail->RIP && Address < InlineTail->RIP + InlineTail->GuestSize);
}

bool ContextImpl::IsCurrentBlockSingleInst(FEXCore::Core::InternalThreadState* Thread) {
  auto [_, InlineTail] = GetFrameBlockInfo(Thread->CurrentFrame);
  return InlineTail && InlineTail->SingleInst;
}

uint64_t ContextImpl::GetGuestBlockEntry(FEXCore::Core::InternalThreadState* Thread) {
  auto [_, InlineTail] = GetFrameBlockInfo(Thread->CurrentFrame);
  return InlineTail ? InlineTail->RIP : 0;
}

uint64_t ContextImpl::RestoreRIPFromHostPC(FEXCore::Core::InternalThreadState* Thread, uint64_t HostPC) {
  const auto Frame = Thread->CurrentFrame;
  const uint64_t BlockBegin = Frame->State.InlineJITBlockHeader;
  auto [InlineHeader, InlineTail] = GetFrameBlockInfo(Thread->CurrentFrame);

  if (InlineHeader) {
    // Check if the host PC is currently within a code block.
    // If it is then RIP can be reconstructed from the beginning of the code block.
    // This is currently as close as FEX can get RIP reconstructions.
    if (HostPC >= reinterpret_cast<uint64_t>(BlockBegin) && HostPC < reinterpret_cast<uint64_t>(BlockBegin + InlineTail->Size)) {

      auto RIPEntry =
        reinterpret_cast<const uint8_t*>(Frame->State.InlineJITBlockHeader + InlineHeader->OffsetToBlockTail + InlineTail->OffsetToRIPEntries);

      // Reconstruct RIP from JIT entries for this block.
      uint64_t StartingHostPC = BlockBegin;
      uint64_t StartingGuestRIP = InlineTail->RIP;

      for (uint32_t i = 0; i < InlineTail->NumberOfRIPEntries; ++i) {
        auto Offset = FEXCore::Utils::vl64pair::Decode(RIPEntry);
        RIPEntry += Offset.Size;
        if (HostPC >= (StartingHostPC + Offset.IntegerARMPC)) {
          // We are beyond this entry, keep going forward.
          StartingHostPC += Offset.IntegerARMPC;
          StartingGuestRIP += Offset.IntegerX86RIP;
        } else {
          // Passed where the Host PC is at. Break now.
          break;
        }
      }
      return StartingGuestRIP;
    }
  }

  // Fallback to what is stored in the RIP currently.
  return Frame->State.rip;
}

/* iOS-Madeira ml549: EXACT guest RIP from a host PC, callable from C.
 *
 * WHY: our fault probes (srcwatch, the bus/segv handlers) read the guest RIP out of
 * CpuStateFrame+0x18, which FEX only syncs at BLOCK boundaries. That names the calling
 * block, never the instruction that actually executed — ml548 disassembled such a RIP
 * and found `movq %rbp,%rcx; callq` (call setup), not the store we were hunting. Every
 * "which instruction wrote this pixel" question dies on that imprecision.
 *
 * FEX already carries the answer: each JIT block appends a host-PC -> guest-RIP table
 * (JIT.cpp writes it as vl64pair entries in the block tail), and RestoreRIPFromHostPC
 * walks it for exception reconstruction. This is the same walk, minus the Thread
 * dependency, exported as plain C so ntdll-unix can call it with values it already has:
 * the block header pointer lives at CPUState offset 0 (== x28+0), and the host PC comes
 * straight from the Mach thread state.
 *
 * Zero runtime cost: no instrumentation, no extra faults, just a table walk at fault
 * time using data FEX maintains anyway. Returns 0 when the PC is outside the block or
 * the header is unusable, so the caller can tell "no answer" from a real RIP. */
extern "C" uint64_t ios_fex_rip_from_hostpc(uint64_t BlockBegin, uint64_t HostPC) {
  if (!BlockBegin) {
    return 0;
  }
  const auto* InlineHeader = reinterpret_cast<const CPU::CPUBackend::JITCodeHeader*>(BlockBegin);
  const auto* InlineTail = reinterpret_cast<const CPU::CPUBackend::JITCodeTail*>(BlockBegin + InlineHeader->OffsetToBlockTail);

  if (HostPC < BlockBegin || HostPC >= (BlockBegin + InlineTail->Size)) {
    return 0;
  }

  const auto* RIPEntry = reinterpret_cast<const uint8_t*>(BlockBegin + InlineHeader->OffsetToBlockTail + InlineTail->OffsetToRIPEntries);
  uint64_t StartingHostPC = BlockBegin;
  uint64_t StartingGuestRIP = InlineTail->RIP;

  for (uint32_t i = 0; i < InlineTail->NumberOfRIPEntries; ++i) {
    auto Offset = FEXCore::Utils::vl64pair::Decode(RIPEntry);
    RIPEntry += Offset.Size;
    if (HostPC >= (StartingHostPC + Offset.IntegerARMPC)) {
      StartingHostPC += Offset.IntegerARMPC;
      StartingGuestRIP += Offset.IntegerX86RIP;
    } else {
      break;
    }
  }
  return StartingGuestRIP;
}

uint32_t ContextImpl::ReconstructCompactedEFLAGS(FEXCore::Core::InternalThreadState* Thread, bool WasInJIT, const uint64_t* HostGPRs,
                                                 uint64_t PSTATE) {
  const auto Frame = Thread->CurrentFrame;
  uint32_t EFLAGS {};

  // Currently these flags just map 1:1 inside of the resulting value.
  for (size_t i = 0; i < FEXCore::Core::CPUState::NUM_EFLAG_BITS; ++i) {
    switch (i) {
    case X86State::RFLAG_CF_RAW_LOC:
    case X86State::RFLAG_PF_RAW_LOC:
    case X86State::RFLAG_AF_RAW_LOC:
    case X86State::RFLAG_TF_RAW_LOC:
    case X86State::RFLAG_ZF_RAW_LOC:
    case X86State::RFLAG_SF_RAW_LOC:
    case X86State::RFLAG_OF_RAW_LOC:
    case X86State::RFLAG_DF_RAW_LOC:
      // Intentionally do nothing.
      // These contain multiple bits which can corrupt other members when compacted.
      break;
    default: EFLAGS |= uint32_t {Frame->State.flags[i]} << i; break;
    }
  }

  uint32_t Packed_NZCV {};
  if (WasInJIT) {
    // If we were in the JIT then NZCV is in the CPU's PSTATE object.
    // Packed in to the same bit locations as RFLAG_NZCV_LOC.
    Packed_NZCV = PSTATE;

    // If we were in the JIT then PF and AF are in registers.
    // Move them to the CPUState frame now.
    Frame->State.pf_raw = HostGPRs[CPU::REG_PF.Idx()];
    Frame->State.af_raw = HostGPRs[CPU::REG_AF.Idx()];
  } else {
    // If we were not in the JIT then the NZCV state is stored in the CPUState RFLAG_NZCV_LOC.
    // SF/ZF/CF/OF are packed in a 32-bit value in RFLAG_NZCV_LOC.
    memcpy(&Packed_NZCV, &Frame->State.flags[X86State::RFLAG_NZCV_LOC], sizeof(Packed_NZCV));
  }

  uint32_t OF = (Packed_NZCV >> IR::OpDispatchBuilder::IndexNZCV(X86State::RFLAG_OF_RAW_LOC)) & 1;
  uint32_t CF = (Packed_NZCV >> IR::OpDispatchBuilder::IndexNZCV(X86State::RFLAG_CF_RAW_LOC)) & 1;
  uint32_t ZF = (Packed_NZCV >> IR::OpDispatchBuilder::IndexNZCV(X86State::RFLAG_ZF_RAW_LOC)) & 1;
  uint32_t SF = (Packed_NZCV >> IR::OpDispatchBuilder::IndexNZCV(X86State::RFLAG_SF_RAW_LOC)) & 1;

  // CF is inverted in our representation, undo the invert here.
  CF ^= 1;

  // Pack in to EFLAGS
  EFLAGS |= OF << X86State::RFLAG_OF_RAW_LOC;
  EFLAGS |= CF << X86State::RFLAG_CF_RAW_LOC;
  EFLAGS |= ZF << X86State::RFLAG_ZF_RAW_LOC;
  EFLAGS |= SF << X86State::RFLAG_SF_RAW_LOC;

  // PF calculation is deferred, calculate it now.
  // Popcount the 8-bit flag and then extract the lower bit.
  uint32_t PFByte = Frame->State.pf_raw & 0xff;
  uint32_t PF = std::popcount(PFByte ^ 1) & 1;
  EFLAGS |= PF << X86State::RFLAG_PF_RAW_LOC;

  // AF calculation is deferred, calculate it now.
  // XOR with PF byte and extract bit 4.
  uint32_t AF = ((Frame->State.af_raw ^ PFByte) & (1 << 4)) ? 1 : 0;
  EFLAGS |= AF << X86State::RFLAG_AF_RAW_LOC;

  uint8_t TFByte = Frame->State.flags[X86State::RFLAG_TF_RAW_LOC];
  EFLAGS |= (TFByte & 1) << X86State::RFLAG_TF_RAW_LOC;

  // DF is pretransformed, undo the transform from 1/-1 back to 0/1
  uint8_t DFByte = Frame->State.flags[X86State::RFLAG_DF_RAW_LOC];
  if (DFByte & 0x80) {
    EFLAGS |= 1 << X86State::RFLAG_DF_RAW_LOC;
  }

  return EFLAGS;
}

void ContextImpl::ReconstructXMMRegisters(const FEXCore::Core::InternalThreadState* Thread, __uint128_t* XMM_Low, __uint128_t* YMM_High) {
  const size_t MaximumRegisters = Config.Is64BitMode ? FEXCore::Core::CPUState::NUM_XMMS : 8;

  if (YMM_High != nullptr && HostFeatures.SupportsAVX) {
    const bool SupportsConvergedRegisters = HostFeatures.SupportsSVE256;

    if (SupportsConvergedRegisters) {
      ///< Output wants to de-interleave
      for (size_t i = 0; i < MaximumRegisters; ++i) {
        memcpy(&XMM_Low[i], &Thread->CurrentFrame->State.xmm.avx.data[i][0], sizeof(__uint128_t));
        memcpy(&YMM_High[i], &Thread->CurrentFrame->State.xmm.avx.data[i][2], sizeof(__uint128_t));
      }
    } else {
      ///< Matches what FEX wants with non-converged registers
      for (size_t i = 0; i < MaximumRegisters; ++i) {
        memcpy(&XMM_Low[i], &Thread->CurrentFrame->State.xmm.sse.data[i][0], sizeof(__uint128_t));
        memcpy(&YMM_High[i], &Thread->CurrentFrame->State.avx_high[i][0], sizeof(__uint128_t));
      }
    }
  } else {
    // Only support SSE, no AVX here, even if requested.
    memcpy(XMM_Low, Thread->CurrentFrame->State.xmm.sse.data, MaximumRegisters * sizeof(__uint128_t));
  }
}

void ContextImpl::SetXMMRegistersFromState(FEXCore::Core::InternalThreadState* Thread, const __uint128_t* XMM_Low, const __uint128_t* YMM_High) {
  const size_t MaximumRegisters = Config.Is64BitMode ? FEXCore::Core::CPUState::NUM_XMMS : 8;
  if (YMM_High != nullptr && HostFeatures.SupportsAVX) {
    const bool SupportsConvergedRegisters = HostFeatures.SupportsSVE256;

    if (SupportsConvergedRegisters) {
      ///< Output wants to de-interleave
      for (size_t i = 0; i < MaximumRegisters; ++i) {
        memcpy(&Thread->CurrentFrame->State.xmm.avx.data[i][0], &XMM_Low[i], sizeof(__uint128_t));
        memcpy(&Thread->CurrentFrame->State.xmm.avx.data[i][2], &YMM_High[i], sizeof(__uint128_t));
      }
    } else {
      ///< Matches what FEX wants with non-converged registers
      for (size_t i = 0; i < MaximumRegisters; ++i) {
        memcpy(&Thread->CurrentFrame->State.xmm.sse.data[i][0], &XMM_Low[i], sizeof(__uint128_t));
        memcpy(&Thread->CurrentFrame->State.avx_high[i][0], &YMM_High[i], sizeof(__uint128_t));
      }
    }
  } else {
    // Only support SSE, no AVX here, even if requested.
    memcpy(Thread->CurrentFrame->State.xmm.sse.data, XMM_Low, MaximumRegisters * sizeof(__uint128_t));
  }
}

void ContextImpl::SetFlagsFromCompactedEFLAGS(FEXCore::Core::InternalThreadState* Thread, uint32_t EFLAGS) {
  const auto Frame = Thread->CurrentFrame;
  for (size_t i = 0; i < FEXCore::Core::CPUState::NUM_EFLAG_BITS; ++i) {
    switch (i) {
    case X86State::RFLAG_OF_RAW_LOC:
    case X86State::RFLAG_CF_RAW_LOC:
    case X86State::RFLAG_ZF_RAW_LOC:
    case X86State::RFLAG_SF_RAW_LOC:
      // Intentionally do nothing.
      break;
    case X86State::RFLAG_AF_RAW_LOC:
      // AF stored in bit 4 in our internal representation. It is also
      // XORed with byte 4 of the PF byte, but we write that as zero here so
      // we don't need any special handling for that.
      Frame->State.af_raw = (EFLAGS & (1U << i)) ? (1 << 4) : 0;
      break;
    case X86State::RFLAG_PF_RAW_LOC:
      // PF is inverted in our internal representation.
      Frame->State.pf_raw = (EFLAGS & (1U << i)) ? 0 : 1;
      break;
    case X86State::RFLAG_DF_RAW_LOC:
      // DF is encoded as 1/-1
      Frame->State.flags[i] = (EFLAGS & (1U << i)) ? 0xff : 1;
      break;
    default: Frame->State.flags[i] = (EFLAGS & (1U << i)) ? 1 : 0; break;
    }
  }

  // Calculate packed NZCV. Note CF is inverted.
  uint32_t Packed_NZCV {};
  Packed_NZCV |= (EFLAGS & (1U << X86State::RFLAG_OF_RAW_LOC)) ? 1U << IR::OpDispatchBuilder::IndexNZCV(X86State::RFLAG_OF_RAW_LOC) : 0;
  Packed_NZCV |= (EFLAGS & (1U << X86State::RFLAG_CF_RAW_LOC)) ? 0 : 1U << IR::OpDispatchBuilder::IndexNZCV(X86State::RFLAG_CF_RAW_LOC);
  Packed_NZCV |= (EFLAGS & (1U << X86State::RFLAG_ZF_RAW_LOC)) ? 1U << IR::OpDispatchBuilder::IndexNZCV(X86State::RFLAG_ZF_RAW_LOC) : 0;
  Packed_NZCV |= (EFLAGS & (1U << X86State::RFLAG_SF_RAW_LOC)) ? 1U << IR::OpDispatchBuilder::IndexNZCV(X86State::RFLAG_SF_RAW_LOC) : 0;
  memcpy(&Frame->State.flags[X86State::RFLAG_NZCV_LOC], &Packed_NZCV, sizeof(Packed_NZCV));

  // Reserved, Read-As-1, Write-as-1
  Frame->State.flags[X86State::RFLAG_RESERVED_LOC] = 1;
  // Interrupt Flag. Can't be written by CPL-3 userland.
  Frame->State.flags[X86State::RFLAG_IF_LOC] = 1;
}

bool ContextImpl::InitCore() {
  // Initialize the CPU core signal handlers & DispatcherConfig
  Dispatcher = FEXCore::CPU::Dispatcher::Create(this);

  // Set up the SignalDelegator config since core is initialized.
  SignalDelegation->SetConfig(Dispatcher->MakeSignalDelegatorConfig());

#if defined(_WIN32) && !defined(ARCHITECTURE_arm64ec)
  // WOW64 always needs the interrupt fault check to be enabled.
  Config.NeedsPendingInterruptFaultCheck = true;
#endif

  if (Config.GdbServer) {
    // If gdbserver is enabled then this needs to be enabled.
    Config.NeedsPendingInterruptFaultCheck = true;
  }

  if constexpr (BLOCK_DEBUGGING) {
    // If the developer wants to do any single-stepping points or watch points.
    // Add them here.
    //
    // eg:
    // BlockDebuggerTracker.AllTargetSingleStep();
    // BlockDebuggerTracker.AddSingleStepTarget(0x14000'0000ULL);
    // BlockDebuggerTracker.AddWriteWatchPoint(0x420BA5ED);
  }

  return true;
}

void ContextImpl::HandleCallback(FEXCore::Core::InternalThreadState* Thread, uint64_t RIP) {
  static_cast<ContextImpl*>(Thread->CTX)->Dispatcher->ExecuteJITCallback(Thread->CurrentFrame, RIP);
}

void ContextImpl::ExecuteThread(FEXCore::Core::InternalThreadState* Thread) {
  // Update the thread pointer for Thunk return to the latest.
  Thread->CurrentFrame->Pointers.ThunkCallbackRet = SignalDelegation->GetThunkCallbackRET();

  Dispatcher->ExecuteDispatch(Thread->CurrentFrame);

  // If it is the parent thread that died then just leave
  // TODO: This doesn't make sense when the parent thread doesn't outlive its children
}

void ContextImpl::InitializeCompiler(FEXCore::Core::InternalThreadState* Thread) {
  Thread->OpDispatcher = fextl::make_unique<FEXCore::IR::OpDispatchBuilder>(this, Thread);
  Thread->OpDispatcher->SetMultiblock(Config.Multiblock);
  LogMan::Msg::EFmt("[TI-IC] lookupcache");
  Thread->LookupCache = fextl::make_unique<FEXCore::LookupCache>(this);
  LogMan::Msg::EFmt("[TI-IC] decoder");
  Thread->FrontendDecoder = fextl::make_unique<FEXCore::Frontend::Decoder>(Thread);
  Thread->PassManager = fextl::make_unique<FEXCore::IR::PassManager>();
  LogMan::Msg::EFmt("[TI-IC] passmanager");

  Thread->CurrentFrame->State.L1Pointer = Thread->LookupCache->GetL1Pointer();
  Thread->CurrentFrame->State.L1Mask = Thread->LookupCache->GetScaledL1PointerMask();

  Thread->CurrentFrame->Pointers.L2Pointer = Thread->LookupCache->GetPagePointer();

  Dispatcher->InitThreadPointers(Thread);

  Thread->PassManager->AddDefaultPasses(this);
  Thread->PassManager->AddDefaultValidationPasses();

  Thread->PassManager->RegisterSyscallHandler(SyscallHandler);

  // Create CPU backend
  Thread->PassManager->InsertRegisterAllocationPass(this);
  LogMan::Msg::EFmt("[TI-IC] jitcore");
  Thread->CPUBackend = FEXCore::CPU::CreateArm64JITCore(this, Thread);
  LogMan::Msg::EFmt("[TI-IC] jitcore-done");

  Thread->PassManager->Finalize();
}

FEXCore::Core::InternalThreadState*
ContextImpl::CreateThread(uint64_t InitialRIP, uint64_t StackPointer, const FEXCore::Core::CPUState* NewThreadState) {
  LogMan::Msg::EFmt("[TI-IC] createthread-enter");
  FEXCore::Core::InternalThreadState* Thread = new FEXCore::Core::InternalThreadState {
    .CTX = this,
  };
  LogMan::Msg::EFmt("[TI-IC] threadstate-alloc");
  FEXCore::Allocator::VirtualName("FEXMem_ThreadState", Thread, sizeof(*Thread));

  Thread->CurrentFrame->State.gregs[X86State::REG_RSP] = StackPointer;
  Thread->CurrentFrame->State.rip = InitialRIP;

  // Copy over the new thread state to the new object
  if (NewThreadState) {
    memcpy(&Thread->CurrentFrame->State, NewThreadState, sizeof(FEXCore::Core::CPUState));
  }

  // Set up the thread manager state
  Thread->CurrentFrame->Thread = Thread;

  InitializeCompiler(Thread);

  Thread->CurrentFrame->State.DeferredSignalRefCount.Store(0);

  if (Config.BlockJITNaming() || Config.GlobalJITNaming() || Config.LibraryJITNaming()) {
    // Allocate a JIT symbol buffer only if enabled.
    Thread->SymbolBuffer = JITSymbols::AllocateBuffer();
  }

  return Thread;
}

void ContextImpl::DestroyThread(FEXCore::Core::InternalThreadState* Thread) {
  FEXCore::Allocator::VirtualProtect(&Thread->InterruptFaultPage, sizeof(Thread->InterruptFaultPage),
                                     Allocator::ProtectOptions::Read | Allocator::ProtectOptions::Write);
  delete Thread;
}

#ifndef _WIN32
void ContextImpl::UnlockAfterFork(FEXCore::Core::InternalThreadState* LiveThread, bool Child) {
  Allocator::UnlockAfterFork(LiveThread, Child);

  Profiler::PostForkAction(Child);
  if (Child) {
    if (CodeMapWriter) {
      CodeMapWriter->ResetAfterFork();
    }

    CodeInvalidationMutex.StealAndDropActiveLocks();
    if (Config.StrictInProcessSplitLocks) {
      StrictSplitLockMutex = 0;
    }
  } else {
    CodeInvalidationMutex.unlock();
    if (Config.StrictInProcessSplitLocks) {
      FEXCore::Utils::SpinWaitLock::unlock(&StrictSplitLockMutex);
    }
  }
}

void ContextImpl::LockBeforeFork(FEXCore::Core::InternalThreadState* Thread) {
  CodeInvalidationMutex.lock();
  Allocator::LockBeforeFork(Thread);
  if (Config.StrictInProcessSplitLocks) {
    FEXCore::Utils::SpinWaitLock::lock(&StrictSplitLockMutex);
  }
}
#endif

void ContextImpl::OnCodeBufferAllocated(const fextl::shared_ptr<CPU::CodeBuffer>& Buffer) {
  if (Config.GlobalJITNaming()) {
    Symbols.RegisterJITSpace(Buffer->Ptr, Buffer->AllocatedSize);
  }

  {
    std::scoped_lock lk {CodeBufferListLock};
    CodeBufferList.emplace_back(Buffer);
  }
}

void ContextImpl::ClearCodeCache(FEXCore::Core::InternalThreadState* Thread, bool NewCodeBuffer) {
  FEXCORE_PROFILE_INSTANT("ClearCodeCache");

  if (NewCodeBuffer) {
    // Allocate new CodeBuffer + L3 LookupCache and clear L1+L2 caches
    Thread->CPUBackend->ClearCache();
  } else {
    // Clear L1+L2 cache of this thread, and clear L3 cache across any threads using it
    auto lk = Thread->LookupCache->AcquireWriteLock();
    Thread->LookupCache->ClearCache(lk);
  }
  FEXCore::Core::ResetCallRetStack(Thread, "core");
}

/* iOS-Madeira ml610: THE ONLY place the callret predictor is reset.
 *
 * ml609 clipped this to the [base+2MB, base+6MB) window on the theory that the
 * rest of the 16MB was unreachable, so decommitting it was pure waste. Both
 * halves of that premise were wrong and the build regressed (+388MB of `fex`
 * band at a matched cycle), so the full clear is restored here.
 *
 *  1. "UNREACHABLE" IS FALSE. BranchOps.cpp's CALL/RET guard does bound sp to
 *     [base+2MB, base+6MB) (`add 0x200000` then `lsr #22`), but the JITCallback
 *     sentinel push in Dispatcher.cpp only tests (sp - base) >> 24 -- the WHOLE
 *     16MB reservation. The callback path can therefore push outside the window
 *     the other path enforces. (How MUCH of the 16MB it actually touches is not
 *     established; that is what the unix-side census below measures.)
 *
 *  2. THE CLEAR RECLAIMS -- IT DOES NOT DIRTY. VirtualDontNeed() here is
 *     VirtualFree(MEM_DECOMMIT) + VirtualAlloc(MEM_COMMIT). This stack is not
 *     pool-aliased, so wine's decommit_pages() (virtual_ios.c) takes the
 *     anon_mmap_fixed() branch: a fresh MAP_ANON|MAP_FIXED over the range, which
 *     DROPS the old physical pages and installs zero-fill-on-demand. The
 *     MEM_COMMIT that follows only restores access; it does not touch pages.
 *     So the full clear was RETURNING up to 16MB per reset, and ml609's 4MB
 *     version left the rest of each stack resident.
 *
 * Resetting the predictor costs prediction quality only, never correctness: a
 * zeroed entry fails the `sub TMP1, TMP1, RipReg` compare and falls through to
 * the L1 lookup, which is always right.
 *
 * The counters stay, and now carry the one real finding ml609 did produce --
 * the expensive axis is FREQUENCY (10,240 resets, every one from
 * site=cpubackend). They break down by site and by CodeBuffer generation so a
 * later frequency fix has a baseline to beat, and so a redundant migration
 * (same thread cleared twice for one generation) becomes visible rather than
 * assumed absent.
 *
 * How many bytes a clear actually RETURNS is deliberately NOT measured here:
 * this TU compiles into an arm64ec PE under llvm-mingw, where __APPLE__ is
 * undefined and mincore/mach_vm_region/task_info do not exist. That
 * measurement lives at the reclaim site itself -- [dc-census] in
 * decommit_pages(), build/ntdll-unix/virtual_ios.c.
 */
} // namespace (ml609: reopened below)
namespace FEXCore::Core {
namespace {
  // Keep in sync with the literals passed by the three call sites.
  constexpr const char* CallRetSiteNames[] = {"core", "cpubackend", "jit-rollover"};
  constexpr size_t CallRetSiteCount = sizeof(CallRetSiteNames) / sizeof(CallRetSiteNames[0]);
} // namespace

static std::atomic<uint64_t> CallRetResets {0};
static std::atomic<uint64_t> CallRetBytesReset {0};
static std::atomic<uint64_t> CallRetResetsBySite[CallRetSiteCount] {};

#ifdef FEX_IOS_HOST
/* Per-generation attribution. A plain spin lock is enough: ~10k resets across a
 * whole run, and the critical section is a bounded scan of a 256-entry table.
 * Nothing is logged while holding it -- the sweeper calls this with the
 * code-buffer migration gate active, so the section stays as short as possible.
 */
static std::atomic<uint32_t> CallRetGenLock {0};
static constexpr uint32_t CallRetGenSeenSlots = 256;
static uint64_t CallRetGenCur {~0ULL};
static uint64_t CallRetGenResets {0};
static uint64_t CallRetGenerations {0};
static uint32_t CallRetGenThreads {0};
static bool CallRetGenSaturated {false};
static void* CallRetGenSeen[CallRetGenSeenSlots] {};
#endif

void ResetCallRetStack(FEXCore::Core::InternalThreadState* Thread, const char* Site) {
  if (!Thread || !Thread->CallRetStackBase) {
    return;
  }
  using TS = FEXCore::Core::InternalThreadState;

  // The FULL reservation -- see the note above. This decommit is what returns
  // the pages; clipping it strands the remainder resident.
  FEXCore::Allocator::VirtualDontNeed(Thread->CallRetStackBase, TS::CALLRET_STACK_SIZE);

  for (size_t i = 0; i < CallRetSiteCount; ++i) {
    if (Site && strcmp(Site, CallRetSiteNames[i]) == 0) {
      CallRetResetsBySite[i].fetch_add(1, std::memory_order_relaxed);
      break;
    }
  }

  const uint64_t N = CallRetResets.fetch_add(1, std::memory_order_relaxed) + 1;
  const uint64_t B = CallRetBytesReset.fetch_add(TS::CALLRET_STACK_SIZE, std::memory_order_relaxed) + TS::CALLRET_STACK_SIZE;

#ifdef FEX_IOS_HOST
  // Closing summary for the generation we just left, filled under the lock and
  // emitted after releasing it.
  bool ClosedGen = false;
  uint64_t ClosedGenId = 0, ClosedGenResets = 0;
  uint32_t ClosedGenThreads = 0;
  bool ClosedGenSaturated = false;
  {
    const uint64_t Gen = FEXCore::CPU::IosCodeBufferGeneration();
    uint32_t Expected = 0;
    while (!CallRetGenLock.compare_exchange_weak(Expected, 1, std::memory_order_acquire, std::memory_order_relaxed)) {
      Expected = 0;
    }

    if (Gen != CallRetGenCur) {
      if (CallRetGenCur != ~0ULL) {
        ClosedGen = true;
        ClosedGenId = CallRetGenCur;
        ClosedGenResets = CallRetGenResets;
        ClosedGenThreads = CallRetGenThreads;
        ClosedGenSaturated = CallRetGenSaturated;
      }
      CallRetGenCur = Gen;
      CallRetGenResets = 0;
      CallRetGenThreads = 0;
      CallRetGenSaturated = false;
      memset(CallRetGenSeen, 0, sizeof(CallRetGenSeen));
      ++CallRetGenerations;
    }
    ++CallRetGenResets;

    /* Open-addressed set of threads already cleared for this generation.
     * CPUBackend's `KeepAlive == LatestBuf` early-out should make a repeat
     * impossible, so resets > unique_threads is the signal that it isn't
     * holding -- and ml609 had no way to see that either way. */
    const uintptr_t H = reinterpret_cast<uintptr_t>(Thread) >> 12;
    bool Found = false, Inserted = false;
    for (uint32_t Probe = 0; Probe < CallRetGenSeenSlots; ++Probe) {
      const uint32_t Slot = static_cast<uint32_t>(H + Probe) & (CallRetGenSeenSlots - 1);
      if (CallRetGenSeen[Slot] == Thread) {
        Found = true;
        break;
      }
      if (CallRetGenSeen[Slot] == nullptr) {
        CallRetGenSeen[Slot] = Thread;
        Inserted = true;
        break;
      }
    }
    if (Inserted) {
      ++CallRetGenThreads;
    } else if (!Found) {
      // Table full: unique-thread count is now a floor, so say so rather than
      // letting the number quietly under-report.
      CallRetGenSaturated = true;
    }

    CallRetGenLock.store(0, std::memory_order_release);
  }

  if (ClosedGen) {
    LogMan::Msg::EFmt("[callret-gen] ml610 gen={} resets={} unique_threads={}{} redundant={}", ClosedGenId, ClosedGenResets,
                      ClosedGenThreads, ClosedGenSaturated ? "+ (table saturated)" : "",
                      ClosedGenResets > ClosedGenThreads ? ClosedGenResets - ClosedGenThreads : 0);
  }
#endif

  if ((N & 0x3ff) == 0) {
    LogMan::Msg::EFmt("[callret] ml610 resets={} bytes={}MB per_reset={}KB site={} by_site core={} cpubackend={} jit-rollover={}", N,
                      B >> 20, TS::CALLRET_STACK_SIZE >> 10, Site, CallRetResetsBySite[0].load(std::memory_order_relaxed),
                      CallRetResetsBySite[1].load(std::memory_order_relaxed), CallRetResetsBySite[2].load(std::memory_order_relaxed));
  }
}
} // namespace FEXCore::Core
namespace FEXCore::Context {

static void IRDumper(FEXCore::Core::InternalThreadState* Thread, IR::IREmitter* IREmitter, uint64_t GuestRIP) {
  FEXCore::File::File FD = FEXCore::File::File::GetStdERR();
  fextl::stringstream out;
  auto NewIR = IREmitter->ViewIR();
  FEXCore::IR::Dump(&out, &NewIR);
  fextl::fmt::print(FD, "IR-ShouldDump-{} 0x{:x}:\n{}\n@@@@@\n", NewIR.PostRA() ? "post" : "pre", GuestRIP, out.str());
};

bool ContextImpl::CheckIfBlockIsCacheable(FEXCore::Core::InternalThreadState& Thread, uint64_t GuestRIP, uint64_t MaxInst) {
  return Thread.FrontendDecoder->CheckIfCacheable(Thread, reinterpret_cast<const uint8_t*>(GuestRIP), GuestRIP, MaxInst);
}

/* iOS-Madeira ml623: targeted IR capture (PassManager.cpp). FEX_MadeiraIRCapTarget is the
 * absolute guest address of the ONE instruction under investigation, published by the
 * Windows-side InvalidationTracker at module load. The decode loop below marks the
 * compile when the block CONTAINS that address -- containment, not entry RIP, because
 * with multiblock a block routinely starts hundreds of bytes earlier. */
extern "C" uint64_t FEX_MadeiraIRCapTarget;
extern "C" void FEX_MadeiraIRCapMark(uint64_t GuestRIP);
extern "C" void FEX_MadeiraIRCapClear();
extern "C" uint64_t FEX_MadeiraIRCapCurrentRIP();

ContextImpl::GenerateIRResult
ContextImpl::GenerateIR(FEXCore::Core::InternalThreadState* Thread, uint64_t GuestRIP, bool ExtendedDebugInfo, uint64_t MaxInst) {
  FEXCORE_PROFILE_SCOPED("GenerateIR");
  FEX_MadeiraIRCapClear(); // ml623: never inherit a previous compile's mark

  /* iOS-Madeira ml250: Thread->OpDispatcher has been observed NULL here, faulting as
   * `str xzr,[x0,#0x378]` with x0=0 inside IREmitter::ResetWorkingList and killing the
   * process (unhandled c0000005, ml247 via chromehtml.dll -> tier0_s64).
   *
   * It is not a missing init: the faulting thread logged the FULL [TI-IC] sequence, so
   * InitializeCompiler ran and created the OpDispatcher. That leaves a stale/foreign
   * InternalThreadState -- the same class as #33, where a CEF child was wired to the wrong
   * JIT-pool ntdll copy, and pseudo-processes get CLONED .data.
   *
   * The caller already handles an empty IRView ("OpDispatcher IR already released"), so
   * bail cleanly instead of dereferencing NULL, and report enough state to identify whose
   * thread object this is. */
  if (!Thread || !Thread->OpDispatcher) {
    static int NullN = 0;
    if (NullN++ < 12) {
      LogMan::Msg::EFmt("[ir-null] Thread={} OpDispatcher={} LookupCache={} FrontendDecoder={} "
                        "CurrentFrame={} GuestRIP={:#x} -- bailing instead of faulting",
                        static_cast<void*>(Thread),
                        Thread ? static_cast<void*>(Thread->OpDispatcher.get()) : nullptr,
                        Thread ? static_cast<void*>(Thread->LookupCache.get()) : nullptr,
                        Thread ? static_cast<void*>(Thread->FrontendDecoder.get()) : nullptr,
                        Thread ? static_cast<void*>(Thread->CurrentFrame) : nullptr, GuestRIP);
    }
    return {};
  }

  Thread->OpDispatcher->ResetWorkingList();

  uint64_t TotalInstructions {0};
  uint64_t TotalInstructionsLength {0};

  bool HasCustomIR {};

  if (HasCustomIRHandlers.load(std::memory_order_relaxed)) {
    std::shared_lock lk(CustomIRMutex);
    auto Handler = CustomIRHandlers.find(GuestRIP);
    if (Handler != CustomIRHandlers.end()) {
      TotalInstructions = 1;
      TotalInstructionsLength = 1;
      Handler->second.Handler(GuestRIP, Thread->OpDispatcher.get());
      HasCustomIR = true;
    }
  }

  if (!HasCustomIR) {
    const uint8_t* GuestCode {};
    GuestCode = reinterpret_cast<const uint8_t*>(GuestRIP);

    /* perf-silenced GenerateIR GuestCode log */

    bool HadDispatchError {false};
    bool HadInvalidInst {false};

    /* perf-silenced */ // LogMan::Msg::IFmt("[iOS] GenerateIR: Calling DecodeInstructionsAtEntry...");
    Thread->FrontendDecoder->DecodeInstructionsAtEntry(Thread, GuestCode, GuestRIP, MaxInst);
    /* perf-silenced */ // LogMan::Msg::IFmt("[iOS] GenerateIR: DecodeInstructionsAtEntry returned");

    auto BlockInfo = Thread->FrontendDecoder->GetDecodedBlockInfo();
    auto CodeBlocks = &BlockInfo->Blocks;

    /* perf-silenced GenerateIR Blocks log */

    Thread->OpDispatcher->BeginFunction(GuestRIP, CodeBlocks, BlockInfo->TotalInstructionCount, BlockInfo->Is64BitMode,
                                        AreMonoHacksActive() && MonoBackpatcherBlock.load(std::memory_order_relaxed) == GuestRIP);

    const auto GPRSize = Thread->OpDispatcher->GetGPROpSize();

#ifdef ZYDIS_DISASSEMBLER
    const auto ZydisMachineMode = Config.Is64BitMode ? ZYDIS_MACHINE_MODE_LONG_64 : ZYDIS_MACHINE_MODE_LEGACY_32;
    if (FEXCore::Config::Get_X86DISASSEMBLE()) {
      const uint64_t DecodedMin = Thread->FrontendDecoder->DecodedMinAddress;
      const uint64_t DecodedMax = Thread->FrontendDecoder->DecodedMaxAddress;
      LogMan::Msg::IFmt("Guest x86 Begin (RIP={:#x}, {:#x}-{:#x})", GuestRIP, DecodedMin, DecodedMax);
    }
#endif

    for (size_t j = 0; j < CodeBlocks->size(); ++j) {
      const FEXCore::Frontend::Decoder::DecodedBlocks& Block = CodeBlocks->at(j);

#ifdef ZYDIS_DISASSEMBLER
      if (FEXCore::Config::Get_X86DISASSEMBLE() && CodeBlocks->size() > 1) {
        LogMan::Msg::IFmt("  Block {} Entry={:#x} NumInsts={}", j, Block.Entry, Block.NumInstructions);
      }
#endif

      bool BlockInForceTSOValidRange = false;
      auto InstForceTSOIt = ForceTSOInstructions.end();
      if (ForceTSOValidRanges.Contains({Block.Entry, Block.Entry + Block.Size})) {
        if (auto It = ForceTSOInstructions.lower_bound(Block.Entry); *It < Block.Entry + Block.Size) {
          InstForceTSOIt = It;
          BlockInForceTSOValidRange = true;
        }
      }

      // Set the block entry point
      Thread->OpDispatcher->SetNewBlockIfChanged(Block.Entry);

      uint64_t BlockInstructionsLength {};

      // Reset any block-specific state
      Thread->OpDispatcher->StartNewBlock();

      uint64_t InstsInBlock = Block.NumInstructions;

      if (InstsInBlock == 0) {
        // Special case for an empty instruction block.
        Thread->OpDispatcher->ExitFunction(Thread->OpDispatcher->_InlineEntrypointOffset(GPRSize, Block.Entry - GuestRIP));
      }

      for (size_t i = 0; i < InstsInBlock; ++i) {
        uint64_t InstAddress = Block.Entry + BlockInstructionsLength;

        // ml623: does THIS block contain the instruction under investigation?
        if (FEX_MadeiraIRCapTarget && InstAddress == FEX_MadeiraIRCapTarget) {
          FEX_MadeiraIRCapMark(GuestRIP);
        }
        const FEXCore::X86Tables::X86InstInfo* TableInfo {nullptr};
        const FEXCore::X86Tables::DecodedInst* DecodedInfo {nullptr};

        TableInfo = Block.DecodedInstructions[i].TableInfo;
        DecodedInfo = &Block.DecodedInstructions[i];

#ifdef ZYDIS_DISASSEMBLER
        if (FEXCore::Config::Get_X86DISASSEMBLE()) {
          const uint8_t* InstBytes = reinterpret_cast<const uint8_t*>(InstAddress);
          ZydisDisassembledInstruction ZydisInst;
          if (ZYAN_SUCCESS(ZydisDisassembleIntel(ZydisMachineMode, InstAddress, InstBytes, DecodedInfo->InstSize, &ZydisInst))) {
            LogMan::Msg::IFmt("    {:#x}: {}", InstAddress, ZydisInst.text);
          } else {
            LogMan::Msg::IFmt("    {:#x}: (decode failed, {} bytes)", InstAddress, DecodedInfo->InstSize);
          }
        }
#endif

        bool IsLocked = DecodedInfo->Flags & FEXCore::X86Tables::DecodeFlags::FLAG_LOCK;

        // Do a partial register cache flush before every instruction. This
        // prevents cross-instruction static register caching, while allowing
        // context load/stores to be optimized within a block. Theoretically,
        // this flush is not required for correctness, all mandatory flushes are
        // included in instruction-specific handlers. Instead, this is a blunt
        // heuristic to make the register cache less aggressive, as the current
        // RA generates bad code in common cases with tied registers otherwise.
        //
        // However, it makes our exception handling behaviour more predictable.
        // It is potentially correctness bearing in that sense, but that is a
        // side effect here and (if that behaviour is required) we should handle
        // that more explicitly later.
        Thread->OpDispatcher->FlushRegisterCache(true);

        if (ExtendedDebugInfo || Thread->OpDispatcher->CanHaveSideEffects(TableInfo, DecodedInfo)) {
          Thread->OpDispatcher->_GuestOpcode(InstAddress - GuestRIP);
        }

        if (Config.SMCChecks == FEXCore::Config::CONFIG_SMC_FULL || Block.ForceFullSMCDetection) {
          auto ExistingCodePtr = reinterpret_cast<uint8_t*>(Block.Entry + BlockInstructionsLength);
          auto InstAddressReg = Thread->OpDispatcher->_EntrypointOffset(GPRSize, InstAddress - GuestRIP);
          std::array<uint8_t, 0x10> CodeOriginal;
          memcpy(CodeOriginal.data(), ExistingCodePtr, DecodedInfo->InstSize);
          auto CodeChanged = Thread->OpDispatcher->_ValidateCode(CodeOriginal, InstAddressReg, DecodedInfo->InstSize);

          auto InvalidateCodeCond = Thread->OpDispatcher->CondJump(CodeChanged);

          auto CurrentBlock = Thread->OpDispatcher->GetCurrentBlock();
          auto CodeWasChangedBlock = Thread->OpDispatcher->CreateNewCodeBlockAtEnd();
          Thread->OpDispatcher->SetTrueJumpTarget(InvalidateCodeCond, CodeWasChangedBlock);

          Thread->OpDispatcher->SetCurrentCodeBlock(CodeWasChangedBlock);
          Thread->OpDispatcher->StartNewBlock();
          Thread->OpDispatcher->_ThreadRemoveCodeEntry();
          Thread->OpDispatcher->ExitFunction(Thread->OpDispatcher->_InlineEntrypointOffset(GPRSize, InstAddress - GuestRIP));

          auto NextOpBlock = Thread->OpDispatcher->CreateNewCodeBlockAfter(CurrentBlock);

          Thread->OpDispatcher->SetFalseJumpTarget(InvalidateCodeCond, NextOpBlock);
          Thread->OpDispatcher->SetCurrentCodeBlock(NextOpBlock);
          Thread->OpDispatcher->StartNewBlock();
        }

        if (TableInfo && TableInfo->OpcodeDispatcher.OpDispatch) {
          auto Fn = TableInfo->OpcodeDispatcher.OpDispatch;
          Thread->OpDispatcher->ResetHandledLock();
          Thread->OpDispatcher->ResetDecodeFailure();
          IR::ForceTSOMode ForceTSO = IR::ForceTSOMode::NoOverride;
          if (BlockInForceTSOValidRange) {
            if (InstForceTSOIt != ForceTSOInstructions.end() && *InstForceTSOIt == InstAddress) {
              ForceTSO = IR::ForceTSOMode::ForceEnabled;
            } else {
              ForceTSO = IR::ForceTSOMode::ForceDisabled;
            }
          } else if (DecodedInfo->Flags & X86Tables::DecodeFlags::FLAG_FORCE_TSO) {
            ForceTSO = IR::ForceTSOMode::ForceEnabled;
          }

          Thread->OpDispatcher->SetForceTSO(ForceTSO);
          std::invoke(Fn, Thread->OpDispatcher, DecodedInfo);
          if (Thread->OpDispatcher->HadDecodeFailure()) {
            HadDispatchError = true;
          } else {
            if (Thread->OpDispatcher->HasHandledLock() != IsLocked) {
              HadDispatchError = true;
              LogMan::Msg::EFmt("Missing LOCK HANDLER at 0x{:x}{{'{}'}}", InstAddress, TableInfo->Name ?: "UND");
            }
            BlockInstructionsLength += DecodedInfo->InstSize;
            TotalInstructionsLength += DecodedInfo->InstSize;
            ++TotalInstructions;

            // Walk InstForceTSOIt forward past the handled instruction
            InstForceTSOIt =
              std::find_if(InstForceTSOIt, ForceTSOInstructions.end(), [&](auto Val) { return Val >= Block.Entry + BlockInstructionsLength; });
          }
        } else {
          // Invalid instruction
          if (!BlockInstructionsLength) {
            // SMC can modify block contents and patch invalid instructions to valid ones inline.
            // End blocks upon encountering them and only emit an invalid opcode exception if there are no prior instructions in the block (that could have modified it to be valid).

            if (TableInfo) {
              LogMan::Msg::EFmt("Invalid or Unknown instruction: {} 0x{:x}", TableInfo->Name ?: "UND", Block.Entry - GuestRIP);
            }

            if (Block.BlockStatus == Frontend::Decoder::DecodedBlockStatus::INVALID_INST ||
                Block.BlockStatus == Frontend::Decoder::DecodedBlockStatus::BAD_RELOCATION) {
              Thread->OpDispatcher->InvalidOp(DecodedInfo);
            } else if (Block.BlockStatus == Frontend::Decoder::DecodedBlockStatus::UNIMPLEMENTED_INST) {
              Thread->OpDispatcher->UnimplementedOp(DecodedInfo);
            } else {
              /* iOS-Madeira ml196: name the decode failure. The pre-existing
               * "Invalid or Unknown instruction" message above cannot fire for this path
               * because DecodeInstruction sets TableInfo = nullptr on exactly these
               * errors. This branch (NOEXEC_INST / PARTIAL_DECODE_INST) is what raises
               * FAULT_SIGSEGV -> GuestSignal_SIGSEGV -> the deliberate read of address 0
               * that has been killing webhelper threads. Log which address failed and
               * which status, so the guest RIP is stated rather than inferred. */
              /* iOS-Madeira ml486 (#89): this log was UNBOUNDED. ml485's run wrote
               * 1,117,783 copies of the SAME line for ONE address (0x7ED30A0080,
               * inside the FEX host band) — a 148MB log, 2.26M lines, from line
               * 16,648 to the end. NoExecOp raises SIGSEGV, the guest resumes at
               * the same RIP, and nothing breaks the cycle; the retry loop's
               * allocations drove phys 3276 -> 4074MB and iOS jetsam-killed the
               * app at its 4096MB limit. So the "memory wall" was really a
               * runaway. Bound the log and name the runaway once; no
               * thread_local here (banned in xtajit64), so use atomics. */
              {
                static std::atomic<uint64_t> LastNoExecRIP {};
                static std::atomic<uint32_t> NoExecRepeat {};
                uint32_t n;
                if (LastNoExecRIP.load(std::memory_order_relaxed) == GuestRIP) {
                  n = NoExecRepeat.fetch_add(1, std::memory_order_relaxed) + 1;
                } else {
                  LastNoExecRIP.store(GuestRIP, std::memory_order_relaxed);
                  NoExecRepeat.store(1, std::memory_order_relaxed);
                  n = 1;
                }
                if (n <= 32 || n == 1024 || n == 65536) {
                  LogMan::Msg::EFmt("[iOS-noexec] status={} BlockEntry={:#x} GuestRIP={:#x} repeat={} rev=ml486",
                                    Block.BlockStatus == Frontend::Decoder::DecodedBlockStatus::NOEXEC_INST ?
                                      "NOEXEC" : "PARTIAL",
                                    Block.Entry, GuestRIP, n);
                }
                if (n == 1024) {
                  LogMan::Msg::EFmt("[iOS-noexec] RUNAWAY: {:#x} has failed to decode 1024 times — the guest is not "
                                    "making progress (wild control transfer); further identical lines suppressed rev=ml486",
                                    GuestRIP);
                }
              }
              Thread->OpDispatcher->NoExecOp(DecodedInfo);
            }
          }

          HadInvalidInst = true;
        }

        const bool NeedsBlockEnd = (HadDispatchError && TotalInstructions > 0) ||
                                   (Thread->OpDispatcher->NeedsBlockEnder() && i + 1 == InstsInBlock) || HadInvalidInst;

        // If we had a dispatch error then leave early
        if (HadDispatchError && TotalInstructions == 0) {
          // Couldn't handle any instruction in op dispatcher
          Thread->OpDispatcher->DelayedDisownBuffer();
          return {std::nullopt, 0, 0, 0, 0};
        }

        if (NeedsBlockEnd) {
          // We had some instructions. Early exit
          Thread->OpDispatcher->ExitFunction(
            Thread->OpDispatcher->_InlineEntrypointOffset(GPRSize, Block.Entry + BlockInstructionsLength - GuestRIP));
          break;
        }


        if (Thread->OpDispatcher->FinishOp(DecodedInfo->PC + DecodedInfo->InstSize, i + 1 == InstsInBlock)) {
          break;
        }
      }
    }

#ifdef ZYDIS_DISASSEMBLER
    if (FEXCore::Config::Get_X86DISASSEMBLE()) {
      LogMan::Msg::IFmt("Guest x86 End");
    }
#endif

    Thread->OpDispatcher->Finalize();

    Thread->FrontendDecoder->DelayedDisownBuffer();
  }

  IR::IREmitter* IREmitter = Thread->OpDispatcher.get();

  auto ShouldDump = Thread->OpDispatcher->ShouldDumpIR();
  // Debug
  if (ShouldDump) {
    IRDumper(Thread, IREmitter, GuestRIP);
  }

  // Run the passmanager over the IR from the dispatcher
  Thread->PassManager->Run(IREmitter);

  // Debug
  if (ShouldDump) {
    IRDumper(Thread, IREmitter, GuestRIP);
  }

  return {
    .IRView = IREmitter->ViewIR(),
    .TotalInstructions = TotalInstructions,
    .TotalInstructionsLength = TotalInstructionsLength,
    .StartAddr = Thread->FrontendDecoder->DecodedMinAddress,
    .Length = Thread->FrontendDecoder->DecodedMaxAddress - Thread->FrontendDecoder->DecodedMinAddress,
    .NeedsAddGuestCodeRanges = !HasCustomIR,
  };
}

ContextImpl::CompileCodeResult ContextImpl::CompileCode(FEXCore::Core::InternalThreadState* Thread, uint64_t GuestRIP, uint64_t MaxInst) {
  // [iOS-Madeira] verbose CompileCode logs suppressed — flooding log faster than splash

  if (SourcecodeResolver && Config.GDBSymbols()) {
    auto MappedSection = SyscallHandler->LookupExecutableFileSection(Thread, GuestRIP);
    if (MappedSection) {
      MappedSection->FileInfo.SourcecodeMap =
        SourcecodeResolver->GenerateMap(MappedSection->FileInfo.Filename, CodeMap::GetBaseFilename(MappedSection->FileInfo, false));
    }
  }

  // Generate IR + Meta Info
  auto [IRView, TotalInstructions, TotalInstructionsLength, StartAddr, Length, NeedsAddGuestCodeRanges] =
    GenerateIR(Thread, GuestRIP, Config.GDBSymbols(), MaxInst);
  if (!IRView) {
    // OpDispatcher IR already released in this case.
    FEX_MadeiraIRCapClear(); // ml623
    return {{}, nullptr, 0, 0, false};
  }

  // Attempt to get the CPU backend to compile this code
  // Re-check if another thread raced us in compiling this block.
  // We could lock CodeBufferWriteMutex earlier to prevent this from happening,
  // but this would increase lock contention. Redundant frontend runs aren't
  // as expensive and are easily reverted.
  /* ml455 (#74): skip the recheck under a delivery compile — FindBlock takes
   * the lookup read lock our interrupted frame may write-own. */
  if (MaxInst != 1 && !FEXCore::Utils::WritePriorityMutex::IosUnpublishedCompileActive()) {
    if (auto Block = Thread->LookupCache->FindBlock(Thread, GuestRIP)) {
      // Raced to compile, release the OpDispatcher IR.
      FEX_MadeiraIRCapClear(); // ml623
      Thread->OpDispatcher->DelayedDisownBuffer();
      return {.CompiledCode = {.BlockBegin = reinterpret_cast<uint8_t*>(Block), .EntryPoints = {{GuestRIP, reinterpret_cast<uint8_t*>(Block)}}},
              .DebugData = nullptr,
              .StartAddr = 0,
              .Length = 0,
              .NeedsAddGuestCodeRanges = false};
    }
  }

  auto DebugData = fextl::make_unique<FEXCore::Core::DebugData>();

  // If the trap flag is set we generate single instruction blocks that each check to generate a single step exception.
  bool TFSet = Thread->CurrentFrame->State.flags[X86State::RFLAG_TF_RAW_LOC];

  auto CompiledCode = Thread->CPUBackend->CompileCode(GuestRIP, Length, TotalInstructions == 1, &*IRView, DebugData.get(), TFSet);

  /* ml623: the final arm of the capture -- the host bytes actually emitted for the
   * target instruction, bounded to [its HostEntryOffset, the next one). This is the
   * arm that separates "the emitter dropped it" from "SMC/cache/alias lifetime rewrote
   * it later": the hash printed here is of the bytes AT COMPILE TIME, so a runtime
   * disassembly that disagrees convicts something after codegen. */
  if (const uint64_t CapRIP = FEX_MadeiraIRCapCurrentRIP()) {
    const uint64_t Target = FEX_MadeiraIRCapTarget;
    if (Target >= CapRIP && CompiledCode.BlockBegin && DebugData) {
      const uint64_t WantOffset = Target - CapRIP;
      const auto& GO = DebugData->GuestOpcodes;
      size_t Idx = GO.size();
      for (size_t i = 0; i < GO.size(); ++i) {
        if (GO[i].GuestEntryOffset == WantOffset) {
          Idx = i;
          break;
        }
      }
      if (Idx == GO.size()) {
        LogMan::Msg::EFmt("[ircap] ml623 HOST: no GuestOpcode entry for offset {:#x} among {} entries "
                          "(rip={:#x} hostsize={})",
                          WantOffset, GO.size(), CapRIP, DebugData->HostCodeSize);
      } else {
        const ptrdiff_t HostFrom = GO[Idx].HostEntryOffset;
        const ptrdiff_t HostTo = (Idx + 1 < GO.size()) ? GO[Idx + 1].HostEntryOffset : static_cast<ptrdiff_t>(DebugData->HostCodeSize);
        // Neighbours give the `or al,0x44` that shares the clobbered register.
        for (size_t i = (Idx > 1 ? Idx - 2 : 0); i < GO.size() && i <= Idx + 1; ++i) {
          LogMan::Msg::EFmt("[ircap] ml623 HOST map guest+{:#x} -> host+{:#x}{}", GO[i].GuestEntryOffset, GO[i].HostEntryOffset,
                            i == Idx ? "   <== TARGET" : "");
        }
        if (HostTo > HostFrom && (HostTo - HostFrom) < 4096) {
          const uint32_t* Words = reinterpret_cast<const uint32_t*>(CompiledCode.BlockBegin + HostFrom);
          const size_t NumWords = static_cast<size_t>(HostTo - HostFrom) / 4;
          uint64_t Hash = 1469598103934665603ull; // FNV-1a
          for (size_t i = 0; i < NumWords; ++i) {
            for (int b = 0; b < 4; ++b) {
              Hash = (Hash ^ ((Words[i] >> (b * 8)) & 0xff)) * 1099511628211ull;
            }
          }
          LogMan::Msg::EFmt("[ircap] ml623 HOST bytes blockbegin={} host+{:#x}..{:#x} words={} fnv1a={:#x}",
                            static_cast<void*>(CompiledCode.BlockBegin), HostFrom, HostTo, NumWords, Hash);
          for (size_t i = 0; i < NumWords; ++i) {
            LogMan::Msg::EFmt("[ircap]   +{:#06x}  {:08x}", HostFrom + static_cast<ptrdiff_t>(i * 4), Words[i]);
          }
        } else {
          LogMan::Msg::EFmt("[ircap] ml623 HOST bytes SKIPPED: implausible range host+{:#x}..{:#x}", HostFrom, HostTo);
        }
      }
    }
    FEX_MadeiraIRCapClear();
  }

  // Release the IR
  Thread->OpDispatcher->DelayedDisownBuffer();

  return {
    .CompiledCode = std::move(CompiledCode),
    .DebugData = std::move(DebugData),
    .StartAddr = StartAddr,
    .Length = Length,
    .NeedsAddGuestCodeRanges = NeedsAddGuestCodeRanges,
  };
}

#ifdef FEX_IOS_HOST
/* iOS-Madeira ml306 (task #51): CallbackPtr entry-state capture buffer, defined in Dispatcher.cpp
 * and written by emitted code at CallbackPtr entry. Read by the [cb-entry] reporter below. */
extern "C" uint64_t IosCbEntryLog[8];
/* iOS-Madeira ml315 (#52): alias-table walk from IosJitAlias.cpp (same DLL link). Maps a
 * module-pool-copy address back to its PE VA; returns the input unchanged on no match. */
extern "C" uint64_t IosJitReverseTranslate(uint64_t Addr);
/* iOS-Madeira ml316: ExitToX64's FFS-bypass counters, defined in Module.cpp and written by
 * the bypass asm in Module.S. Reported below the same way as [cb-entry]. */
extern "C" uint64_t IosFfsBypassLog[4];
#endif

#ifdef FEX_IOS_HOST
/* ml648: publish the struct offsets the native Mach handler needs.
 *
 * NEVER hardcoded on the native side. It reads CpuStateFrame and the JIT block
 * header/tail from inside a fault handler, so a silent field reshuffle here
 * would turn that into a wild read at the worst possible moment. Publishing
 * makes the capture self-calibrating: zero offsets mean "not published", and
 * the native side then declines to capture at all.
 *
 * mono_base/mono_end are deliberately NOT set here — Mono is not loaded at FEX
 * startup. InvalidationTracker publishes them when it recognises the module,
 * and capture stays inert until it does. */
extern "C" void ios_fex_mono_bridge_publish(void* BridgeRaw) {
  struct BridgeHead {
    uint32_t abi_version, off_frame_hdr, off_block_tail, off_tail_rip;
  };
  auto* B = reinterpret_cast<BridgeHead*>(BridgeRaw);
  B->off_frame_hdr = static_cast<uint32_t>(offsetof(FEXCore::Core::CpuStateFrame, State) +
                                           offsetof(FEXCore::Core::CPUState, InlineJITBlockHeader));
  B->off_block_tail = static_cast<uint32_t>(offsetof(FEXCore::CPU::CPUBackend::JITCodeHeader, OffsetToBlockTail));
  B->off_tail_rip = static_cast<uint32_t>(offsetof(FEXCore::CPU::CPUBackend::JITCodeTail, RIP));
  LogMan::Msg::EFmt("[mono-bridge] ml648 OFFSETS PUBLISHED bridge={} frame_hdr={} block_tail={} tail_rip={}"
                    " -- capture still inert until Mono is armed",
                    BridgeRaw, B->off_frame_hdr, B->off_block_tail, B->off_tail_rip);
}

extern "C" uint64_t IosMonoResolveRW(uint64_t GuestAddr, uint64_t Size);
extern "C" void ios_fex_mono_count_helper(int Miss);
extern "C" int ios_fex_mono_take_pending(uint64_t* BlockBegin, uint64_t* HostPC, uint64_t* FaultAddr);
extern "C" void ios_fex_mono_count_activated();
extern "C" uint64_t ios_fex_mono_captured_count();
extern "C" int ios_fex_mono_bridge_armed();

/* Liveness line 3 of 3. Lives here because LogMan is not available in the
 * ARM64EC alias TU. */
extern "C" void ios_fex_mono_report_armed(uint64_t Base, uint64_t End) {
  LogMan::Msg::EFmt("[mono-bridge] ml648 MONO ARMED base={:#x} end={:#x} -- native capture is now live", Base, End);
}

/* ml648: consume a pending Mono-backpatcher event.
 *
 * ⚠️ THE TWO RIPs ARE NOT INTERCHANGEABLE, and getting them the wrong way round
 * makes the whole optimisation compile, ship, and silently do nothing:
 *   ios_fex_rip_from_hostpc() -> the EXACT instruction RIP. Used ONLY to prove
 *       the faulting instruction is inside Mono and really is an XCHG (0x87).
 *   JITCodeTail.RIP           -> the BLOCK ENTRY. This is what
 *       MarkMonoBackpatcherBlock() must receive, because FEX compares it against
 *       the compilation's starting GuestRIP.
 *
 * Use the standalone ios_fex_rip_from_hostpc(BlockBegin, HostPC), never
 * RestoreRIPFromHostPC(Thread, HostPC) — the latter reads the thread's CURRENT
 * block header, which may have moved on since the fault was recorded. */
static inline bool MonoBackpatcherBridgeArmed() {
  return ios_fex_mono_bridge_armed() != 0;
}

static void IosMonoTryActivate(ContextImpl* CTX, FEXCore::Core::InternalThreadState* Thread) {
  uint64_t BlockBegin = 0, HostPC = 0, FaultAddr = 0;
  if (!ios_fex_mono_take_pending(&BlockBegin, &HostPC, &FaultAddr)) {
    return;
  }

  const uint64_t InsnRIP = ios_fex_rip_from_hostpc(BlockBegin, HostPC);
  auto* Header = reinterpret_cast<const FEXCore::CPU::CPUBackend::JITCodeHeader*>(BlockBegin);
  auto* Tail = reinterpret_cast<const FEXCore::CPU::CPUBackend::JITCodeTail*>(BlockBegin + Header->OffsetToBlockTail);
  const uint64_t BlockEntry = Tail->RIP;

  LogMan::Msg::EFmt("[mono-bridge] ml648 PENDING block_begin={:#x} host_pc={:#x} fault={:#x} "
                    "insn_rip={:#x} block_entry={:#x} captured={}",
                    BlockBegin, HostPC, FaultAddr, InsnRIP, BlockEntry, ios_fex_mono_captured_count());

  if (!InsnRIP || !BlockEntry) {
    LogMan::Msg::EFmt("[mono-bridge] ml648 REJECT: rip reconstruction failed");
    return;
  }
  static constexpr uint8_t XChgOp = 0x87;
  const uint8_t* Code = reinterpret_cast<const uint8_t*>(InsnRIP);
  if (Code[0] != XChgOp && Code[1] != XChgOp) {
    LogMan::Msg::EFmt("[mono-bridge] ml648 REJECT: not an XCHG at {:#x} ({:#x} {:#x})", InsnRIP, Code[0], Code[1]);
    return;
  }

  {
    std::scoped_lock CodeLock(CTX->GetCodeInvalidationMutex());
    CTX->MarkMonoBackpatcherBlock(BlockEntry);
  }
  CTX->SyscallHandler->InvalidateGuestCodeRange(Thread, BlockEntry, FEXCore::Utils::FEX_PAGE_SIZE);
  ios_fex_mono_count_activated();
  LogMan::Msg::EFmt("[mono-bridge] ml648 ACTIVATED mono backpatcher block {:#x} -- SWPAL storm should collapse", BlockEntry);
}
#endif

uintptr_t ContextImpl::CompileBlock(FEXCore::Core::CpuStateFrame* Frame, uint64_t GuestRIP, uint64_t MaxInst) {
  if constexpr (BLOCK_DEBUGGING) {
    // Block debugging logic is hand-written and needs to be handled with care.
    // Force MaxInst to only be one in this case.
    MaxInst = 1;

    // If the entrypoint is part of the single step targets then single step it.
    if (BlockDebuggerTracker.IsSingleStepTarget(GuestRIP)) {
      return CompileSingleStep(Frame, GuestRIP);
    }
  }

  auto Thread = Frame->Thread;
  FEXCORE_PROFILE_SCOPED("CompileBlock");
  FEXCORE_PROFILE_ACCUMULATION(Thread, AccumulatedJITTime);

#ifdef FEX_IOS_HOST
  /* ml648: consume any pending Mono-backpatcher event.
   *
   * ⚠️ HONEST LIMITATION. Sol asked for a safe point guaranteed on the NEXT block
   * transition. There isn't a free one: the per-block LookupCache probe is
   * emitted assembly, and ExitFunctionLink only runs on an edge's FIRST
   * traversal, so the only zero-cost C++ hooks are compile-time. Adding a check
   * to the dispatcher's emitted path would tax every block transition forever to
   * save a one-shot activation.
   *
   * Why CompileBlock is nonetheless prompt here: the capture happens the first
   * time Mono PATCHES code, which is precisely when Mono is also EMITTING code,
   * so compiles are dense at exactly that moment (179,415 in the ml647 run).
   * Capture and compilation are correlated by construction, not by luck.
   *
   * This is measurable rather than assumed — the [mono-bridge] PENDING line
   * prints n_captured at activation, so the number of faults paid while waiting
   * is in the log. If that gap is large, the answer is a dispatcher hook and the
   * log will say so outright. */
  if (MonoBackpatcherBridgeArmed()) {
    IosMonoTryActivate(this, Thread);
  }
#endif

  /* iOS-Madeira ml304 (task #51): REPORT CallbackPtr ENTRY ON ITS OWN, not via the bogus-RIP path.
   *
   * ml302 proved the JITCallback prologue writes the bad State.rip, and ml303 added an LR witness --
   * but gated the report on a later bogus-RIP hit, which only occurs in roughly half of runs. That
   * repeats the mistake of gating a probe on the rare downstream event instead of the thing being
   * measured. Entry into CallbackPtr is itself the anomaly: on ARM64EC that block should be
   * unreachable (ExecuteJITCallback is only called from ContextImpl::HandleCallback, whose sole
   * caller is LinuxEmulation/Thunks.cpp which is not built for this target, and the emitted code
   * before it ends in hlt(0) so fall-through is impossible).
   *
   * So report the first few entries directly. CompileBlock runs often enough to notice promptly and
   * is not hot enough for a load+branch to matter. If nothing prints, CallbackPtr genuinely is not
   * being entered in that run -- which is equally informative, and is a real negative rather than
   * silence from an unexercised probe. */
  /* ml306 GATE FIX: the ml304 version keyed on Frame->IosLastCallbackLR != 0, and ml306's hit
   * showed the real entries arrive with LR == 0 -- so the gate was blind to exactly the case it
   * existed for ([cb-entry] printed 0 in the same run whose [bogus-writer] proved a CallbackPtr
   * entry happened). Key on the entry COUNTER in the static capture buffer instead, and print the
   * full captured entry state; x16/x17 are the interesting ones since a `br` through an IP register
   * is the most plausible way to arrive with LR=0. */
  /* iOS-Madeira ml316: report ExitToX64 FFS bypasses (native short-circuit of an EC target
   * reached via its x64 fast-forward sequence -- preserves the x4/x5 varargs contract that
   * the emulation round trip destroys; see Module.S). Same change-detection pattern as
   * [cb-entry] below: CompileBlock runs often enough to notice promptly. */
#ifdef FEX_IOS_HOST
  {
    static uint64_t FfsLastCount = 0;
    static uint32_t FfsReports = 0;
    const uint64_t FfsCount = IosFfsBypassLog[0] + IosFfsBypassLog[2];
    if (FfsCount != FfsLastCount && FfsReports < 12) {
      FfsLastCount = FfsCount;
      FfsReports++;
      LogMan::Msg::EFmt("[ffs-bypass] taken={} (last EC target {:#x} called natively, x4/x5 preserved) "
                        "rejected={} (last non-EC target {:#x} emulated normally)",
                        IosFfsBypassLog[0], IosFfsBypassLog[1], IosFfsBypassLog[2], IosFfsBypassLog[3]);
    }
  }

  {
    static uint64_t CBLastCount = 0;
    static uint32_t CBReports = 0;
    const uint64_t CBCount = IosCbEntryLog[6];
    if (CBCount != CBLastCount && CBReports < 8) {
      CBLastCount = CBCount;
      CBReports++;
      LogMan::Msg::EFmt("[cb-entry] CallbackPtr entered (count={}) -- unreachable by design on ARM64EC: "
                        "x0(Frame)={:#x} x1(RIP)={:#x} x16={:#x} x17={:#x} x30={:#x} nsp={:#x} guestRSP(x23)={:#x}",
                        CBCount, IosCbEntryLog[0], IosCbEntryLog[1], IosCbEntryLog[2], IosCbEntryLog[3],
                        IosCbEntryLog[4], IosCbEntryLog[5], IosCbEntryLog[7]);
    }
  }

#endif

  /* iOS-Madeira: refuse to compile obviously-invalid guest RIPs. After a
   * NULL-vtable virtual call (`call [rax+8]` with rax=0), control flow
   * lands at RIP=0x8, which then loops compiling thousands of garbage
   * blocks before SEH unwinds. Returning 0 here raises C0000005 to the
   * guest immediately so the first AV is the only AV. */
  if (GuestRIP < 0x10000) {
    LogMan::Msg::IFmt("[iOS] CompileBlock: REFUSING low/invalid RIP={:#x}", GuestRIP);
    return 0;
  }

#ifdef FEX_IOS_HOST
  /* iOS-Madeira ml315 (#52 root cause, ml314): a guest RIP inside a module's JIT-POOL COPY
   * must be reverse-translated to its PE VA and re-classified -- NEVER compiled.
   *
   * The EcCodeBitMap is populated per-module at its PE-space mapping (wine's
   * arm64ec_update_hybrid_metadata), but on iOS native code executes from pool copies at
   * unrelated VAs. Both the dispatcher loop-top EC check and Module.S check_target_ec test
   * the RAW target address, so a pool-alias target always reads bit=0 and lands here, where
   * the frontend decodes native ARM64 machine code as x86:
   *   ml314 #1: PSAPI.DLL DllMain (EC .text +0x10020) via its pool alias -> "Invalid
   *             instruction in entry block" at the very first call after load
   *   ml314 #3: rpcrt4 +0x4ae58 (CodeMap type-1 ARM64EC) via a translated pointer consumed
   *             by guest RPC code -> 419k-deep callret garbage, SEGV at NULL+0x10
   *   (ml299's ntdll+0x7488c x3422 was the same class.)
   *
   * Discriminator: the alias table, NOT a pool-band range test -- guest PE images map inside
   * the pool band too (ml198: steamexe.exe at 0x15c800000, 17 false positives), and FEX's
   * own code buffer is not in the table, so the existing [iOS-bogusrip] gates below still
   * catch genuine host-PC leaks.
   *
   * Fix: rewrite State.rip to the PE VA and return the dispatcher loop-top as the "block".
   * The caller does FillStaticRegs() + br on our return value, so control re-enters the loop,
   * reloads the corrected RIP, and the EC bitmap check now classifies correctly: type-1 EC ->
   * ExitFunctionEC (whose alias xlate maps PE->pool for the native jump), type-2 x64 ->
   * compiled here at the correct guest VA. No block is ever created for the alias address,
   * so the block caches can never hit on one. */
  {
    const uint64_t PeRIP = IosJitReverseTranslate(GuestRIP);
    if (PeRIP != GuestRIP) {
      static std::atomic<uint32_t> PoolRipFixes {0};
      const uint32_t N = PoolRipFixes.fetch_add(1, std::memory_order_relaxed);
      if (N < 24) {
        LogMan::Msg::EFmt("[pool-rip-fix] #{} guest RIP {:#x} is a module POOL-COPY alias of PE {:#x} "
                          "-- redirecting to PE VA and re-entering the dispatcher",
                          N + 1, GuestRIP, PeRIP);
      }
      Frame->State.rip = PeRIP;
      return Frame->Pointers.DispatcherLoopTop;
    }
  }
#endif

  /* iOS-Madeira ml197: NAME THE PRODUCER OF A HOST-ADDRESS "GUEST RIP".
   *
   * [iOS-noexec] showed FEX being asked to decode x86 at addresses that are not guest
   * code at all:
   *   GuestRIP=0x133f39a14   -> a JIT-POOL address (host code / module copies)
   *   GuestRIP=0x7c600e0080  -> inside a steered 512MB FEX arena, at +0x0e0080 — the
   *                             SAME offset seen in three runs across three arenas
   * Decoding those yields NOEXEC/PARTIAL, which raises FAULT_SIGSEGV -> the
   * GuestSignal_SIGSEGV trampoline -> the deliberate read of 0 that kills the thread.
   * So the memory was never the problem; the POINTER is.
   *
   * ml198 CORRECTION: the first cut also flagged 0x1xxxxxxxx as "JIT pool", which was
   * WRONG — guest PE IMAGES live in that band too (e.g. steamexe.exe maps at 0x15c800000,
   * whose pool copy is at 0x127566000). That produced 17 false positives of perfectly
   * legitimate RIPs. Only >= 0x7400000000 is unambiguous: that is steered-arena space and
   * no guest image is ever placed there. Keep the check to that band only.
   *
   * Log the host return address (which lands in the dispatcher stub that supplied the
   * RIP) plus State.rip, so the PRODUCER is named instead of the consumer. */
  /* iOS-Madeira ml296: ALSO CATCH HOST-PC-IN-GUEST-RIP INSIDE FEX'S OWN CODE BUFFER.
   *
   * ml292/294/295 showed a SECOND leak, distinct from the 0x7c-0x7f host-heap one above and now
   * the DOMINANT killer (3 of the last 4 runs, and it fires EARLIER -- ~24.6k calls vs ~36.4k --
   * so it terminates the webhelper before the other one is ever reached; runs regressed from
   * ~36,700 calls / 237 modules to ~24,600 / 216 for exactly this reason).
   *
   * ml295 signature: State.rip = 0x156219e14, which the [jit-pool] records place inside
   * `tail EC_CODE rx=0x155ff8000 size=0x1000000` -- FEX'S OWN EMITTED CODE. x16 (IP0, the
   * register the dispatcher `br`s through) held the same value, so a host branch target was
   * written into the guest RIP field. x28 was a valid ThreadState (<arena>+0x1140, matching
   * [vname]), so this is not a bad state pointer.
   *
   * The 0x7400000000 gate cannot see it, and the ml198 note in this file explains why the gate
   * was left narrow: guest PE IMAGES also live in the 0x1xxxxxxxx band, and treating that band
   * as "pool" produced 17 false positives. IsAddressInCodeBuffer is the exact discriminator that
   * was missing -- FEX knows its own code-buffer bounds, so a guest RIP inside them is
   * unambiguously a host-PC leak with no possibility of a guest-image false positive. */
  const bool RIPInFEXCodeBuffer = IsAddressInCodeBuffer(Thread, GuestRIP);

  /* iOS-Madeira ml300 (task #52): ALSO catch pool MODULE-COPY addresses, not just FEX's code buffer.
   *
   * ml299 hit a third variant of the same leak and the gate missed all 3,422 occurrences of it:
   *   [fault_rip] cnt=3422 rip=0x13b2b888c
   *   [rip-leak] guest RIP 0x13b2b888c IS POOL addr = PE 0x73d0ba488c (ntdll base 0x73d0b30000 rva 0x7488c)
   * That is a JIT-pool copy of a PE module -- a host address, but NOT inside FEX's code buffer, so
   * IsAddressInCodeBuffer returns false and [bogus-writer] never got a chance to name the writer.
   *
   * The ml198 note in this file warns that the 0x1xxxxxxxx BAND cannot be used as the test, because
   * guest PE images live there too and flagging the whole band produced 17 false positives. But the
   * POOL is a specific interval, [WINE_IOS_JIT_RX, +WINE_IOS_JIT_SIZE), and no guest image is ever
   * placed inside it -- ios_jit_add_mapping owns that range. Testing the interval instead of the
   * band is exact, and it subsumes the code-buffer case since the EC_CODE tail lives in the pool
   * too (verified: pool [0x11e400000,0x156400000) contains both the 0x155ff8000 EC_CODE tail and
   * ml299's 0x13b2b888c module copy).
   *
   * ml300 RETRACTION: the pool-interval gate added above was WRONG and manufactured 18 false
   * positives in one run. Being inside the pool is NOT sufficient, because an ARM64EC module's
   * CHPE CodeMap contains type-2 (X64) ranges -- real x64 entry/fast-forward thunks -- and the
   * marking loop in virtual_ios.c deliberately leaves those unmarked precisely so FEX WILL
   * emulate them. Compiling x86 at those pool addresses is correct behaviour. All five sampled
   * ml300 hits classified as X64(type2): shcore+0x19516, winhttp+0x2ec63, ws2_32+0x234c6,
   * ntdll+0x7e067, sechost+0x1e5c2. The "CONFIRMED: EnterEC wrote this" verdicts they produced
   * are therefore NOT evidence of a bug -- EnterEC storing an x64 target in State.rip is its job.
   *
   * The genuine pool variant does exist (ml299: ntdll rva 0x7488c, 3,422 hits, classified
   * ARM64EC(type1) -- native code fed to the x86 decoder), but distinguishing it needs the EC code
   * bitmap, not a range test, and the ntdll-side [rip-leak] probe already reports exactly that case
   * with a reverse-translate to module+rva. So detection of that variant belongs there, not here.
   *
   * Back to IsAddressInCodeBuffer alone, which is sound with no discrimination needed: FEX's own
   * emitted code is never guest code under any classification. */
  if (GuestRIP >= 0x7400000000ULL || RIPInFEXCodeBuffer) {
    static uint32_t BogusRIPCount = 0;
    if (BogusRIPCount < 16) {
      BogusRIPCount++;
      LogMan::Msg::EFmt("[iOS-bogusrip] band={} GuestRIP={:#x} State.rip={:#x} host_ret={} callret_sp={:#x}",
                        RIPInFEXCodeBuffer ? "FEX-CODE-BUFFER(host PC leak)" : "host-heap(0x7c-0x7f)",
                        GuestRIP, Frame ? Frame->State.rip : 0, __builtin_return_address(0),
                        Frame ? Frame->State.callret_sp : 0);

      /* iOS-Madeira ml295 (task #51): IS THE BAD RIP A GUEST VALUE OR A FEX-SYNTHESISED ONE?
       *
       * ml294 established, offline, that the guest CANNOT have computed this address. At fault
       * time the guest is inside chrome_elf.dll's memset (r10 = exact image base, r11 = exact
       * image_base+0xb440e, r9 = 0x30 -- reproduced across ml285/290/291), and that memset
       * dispatches through a 32-bit jump table at RVA 0x112de0 whose entries span only
       * 0xb40e1..0xb414a. target = image_base + a 32-bit entry therefore cannot exceed
       * image_base + 0xffffffff, and the observed RIPs (e.g. 0x7e600f0080 against an image base
       * of 0x73cd3d0000) lie far outside that window. The target is also UNNAMED memory inside
       * FEX's own 512MB host reservations -- ml294's [vname] map shows FEXMem_ThreadState is the
       * only named region in that band, occupying just <arena>+0x1000..+0x3000.
       *
       * (Earlier comments here called those arenas "PartitionAlloc"; that was wrong. All 23
       * [bigres] 512MB requests carry guest rsp=0/rip=0, i.e. no guest context, and are issued
       * two-per-thread at FEX thread init. They are FEX's own heap.)
       *
       * So the prediction is that the value is NOT in any guest GPR. Print all sixteen and say
       * so explicitly either way -- if it DOES appear in a register the arithmetic proof above is
       * wrong and that is the single most important thing to learn; if it does not, the value was
       * synthesised on FEX's side and the dispatcher dump below is where to look. */
      if (Frame) {
        static const char* GPRNames[16] = {"rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
                                           "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15"};
        int FoundIn = -1;
        for (int i = 0; i < 16; ++i) {
          if (Frame->State.gregs[i] == GuestRIP) {
            FoundIn = i;
            break;
          }
        }
        LogMan::Msg::EFmt("[bogus-regs] rax={:#x} rcx={:#x} rdx={:#x} rbx={:#x} rsp={:#x} rbp={:#x} rsi={:#x} rdi={:#x}",
                          Frame->State.gregs[0], Frame->State.gregs[1], Frame->State.gregs[2], Frame->State.gregs[3],
                          Frame->State.gregs[4], Frame->State.gregs[5], Frame->State.gregs[6], Frame->State.gregs[7]);
        LogMan::Msg::EFmt("[bogus-regs] r8={:#x} r9={:#x} r10={:#x} r11={:#x} r12={:#x} r13={:#x} r14={:#x} r15={:#x}",
                          Frame->State.gregs[8], Frame->State.gregs[9], Frame->State.gregs[10], Frame->State.gregs[11],
                          Frame->State.gregs[12], Frame->State.gregs[13], Frame->State.gregs[14], Frame->State.gregs[15]);
        if (FoundIn >= 0) {
          LogMan::Msg::EFmt("[bogus-regs] *** value IS in guest {} -- guest DID hold it, ml294 arithmetic "
                            "proof is WRONG, re-derive",
                            GPRNames[FoundIn]);
        } else {
          LogMan::Msg::EFmt("[bogus-regs] value is in NO guest GPR -- FEX-synthesised, as predicted");
        }

        /* ml298 (task #52): the FEX-side state that separates the candidate writers.
         *
         * InlineJITBlockHeader is what RestoreRIPFromHostPC uses to reverse-map a host PC back to
         * a guest RIP; its fallback is `return State.rip`, so if the header is stale or zero the
         * reconstruction silently propagates whatever State.rip already held instead of repairing
         * it. Printing it says whether reconstruction COULD have worked.
         *
         * callret_sp vs callret_sp_base gives the live depth against the inline guard window
         * [base+0x200000, base+0x600000): ml297 showed sp-base = 0x2c7e70 (~2.9MB, ~80,000 leaked
         * entries) -- inside the window, so the guard never fired and #42 is still live. Whether
         * that is true again on the run that catches the write matters, because the suspected
         * writer sits in the same EnterEC machinery that manages this stack. */
        LogMan::Msg::EFmt("[bogus-state] InlineJITBlockHeader={:#x} callret_sp={:#x} base={:#x} "
                          "depth=(sp-base)={:#x} guard_window=[+0x200000,+0x600000)",
                          Frame->State.InlineJITBlockHeader, Frame->State.callret_sp, Frame->State.callret_sp_base,
                          Frame->State.callret_sp - Frame->State.callret_sp_base);

        /* ml299 (task #52): NAME THE WRITER, do not infer it. */
        if (Frame->IosLastEnterECRip == GuestRIP) {
          LogMan::Msg::EFmt("[bogus-writer] *** CONFIRMED: EnterEC wrote this value "
                            "(IosLastEnterECRip={:#x} == GuestRIP) -- the str(EC_CALL_CHECKER_PC_REG, "
                            "State.rip) at AbsoluteLoopTopAddressEnterEC is the leak",
                            Frame->IosLastEnterECRip);
        } else if (Frame->IosLastCallbackRip == GuestRIP) {
          LogMan::Msg::EFmt("[bogus-writer] *** JITCallback wrote this value "
                            "(IosLastCallbackRip={:#x} == GuestRIP) -- a host->guest callback was "
                            "handed a host address. Entered with LR={:#x} -- on ARM64EC this block "
                            "should be UNREACHABLE (only LinuxEmulation calls HandleCallback, and the "
                            "preceding emitted code ends in hlt(0)), so that LR names the errant branch",
                            Frame->IosLastCallbackRip, Frame->IosLastCallbackLR);
        } else {
          LogMan::Msg::EFmt("[bogus-writer] BY ELIMINATION: BranchOps' L1-miss store "
                            "(EnterEC={:#x}, Callback={:#x}, neither == GuestRIP={:#x}) -- the guest "
                            "branch target itself is the bad value, i.e. it was LOADED from guest "
                            "memory rather than synthesised by the dispatcher",
                            Frame->IosLastEnterECRip, Frame->IosLastCallbackRip, GuestRIP);
        }
      }

      /* ml295: DUMP THE FEX-EMITTED CODE THAT SUPPLIED THE RIP.
       *
       * host_ret is the return address into the dispatcher stub / emitted block that called
       * CompileBlock, and in ml291 it was 0x162bf83c0 -- inside the pool's tail EC_CODE area.
       * Dumping the words around it lets the sequence be disassembled offline (free) to see
       * whether the RIP came from an L1/L2 lookup, a callret prediction (#42 territory), or a
       * clobbered register.
       *
       * Bounded to the JIT pool via the same env vars the atomic-alias helper uses, so an
       * unexpected host_ret can never turn this probe into a fault of its own. */
      {
        const char* RxEnv = getenv("WINE_IOS_JIT_RX");
        const char* SzEnv = getenv("WINE_IOS_JIT_SIZE");
        const uint64_t RxBase = RxEnv ? strtoull(RxEnv, nullptr, 16) : 0;
        const uint64_t RxSize = SzEnv ? strtoull(SzEnv, nullptr, 16) : 0;
        const uint64_t HostRet = reinterpret_cast<uint64_t>(__builtin_return_address(0));
        /* ml298: widened from -0x30 to -0xA8. The ml297 window ended at `mov x2, x12`, proving the
         * guest RIP passed to CompileBlock comes from x12 but NOT where x12 was loaded -- the
         * answer is further back, and a window that stops just short of the answer is a wasted
         * run. 0xA8 back plus 0x20 forward still sits well inside the 64-byte-margin bounds check
         * below, so widening cannot make the probe fault. */
        if (RxBase && RxSize && HostRet >= RxBase + 0x200 && HostRet + 0x200 < RxBase + RxSize) {
          const uint32_t* W = reinterpret_cast<const uint32_t*>(HostRet & ~3ULL);
          for (int Row = -7; Row <= 1; ++Row) {
            LogMan::Msg::EFmt("[bogus-host] {:+#6x} {:08x} {:08x} {:08x} {:08x} {:08x} {:08x}", Row * 24, W[Row * 6 + 0],
                              W[Row * 6 + 1], W[Row * 6 + 2], W[Row * 6 + 3], W[Row * 6 + 4], W[Row * 6 + 5]);
          }
          LogMan::Msg::EFmt("[bogus-host] host_ret={:#x} pooloff={:#x}", HostRet, HostRet - RxBase);
        } else {
          LogMan::Msg::EFmt("[bogus-host] host_ret={:#x} NOT in JIT pool [{:#x},{:#x}) -- not dumped", HostRet, RxBase,
                            RxBase + RxSize);
        }
      }

      /* iOS-Madeira ml292: NAME THE GUEST CALLER of the bogus RIP.
       *
       * Offline analysis of nine runs showed every bogus RIP has the form
       *   <steered 512MB PA arena base> + {0xd0080, 0xe0080, 0xf0080}
       * (0x7c00/0x7c20/0x7c60/0x7ca0/0x7e20/0x7e60/0x7ea0 all appear verbatim in the
       * [steer] log, and NO module is mapped above 0x7400000000). So a committed RW
       * PartitionAlloc heap address is being CALLed as code, always at one of only three
       * offsets -- the same heap object each time. The producer is a guest function
       * pointer, and the one thing still missing is WHO dereferenced it.
       *
       * BranchOps.cpp pushes `stp CallReturnAddr, HostLabel, [x17, #-0x10]!` on every
       * guest CALL, so entry 0 at [callret_sp] is the guest return address *in the
       * caller* -- the instruction right after the offending call. Walking up gives the
       * guest call chain, innermost first; those are guest VAs that map directly onto the
       * `[jit-pool] image <base>+<size> (name.dll)` lines already in the log.
       *
       * Reads are bounded to the real [base, base+CALLRET_STACK_SIZE) window before any
       * dereference, so a garbage callret_sp cannot turn this probe into a second fault.
       * Both outcomes are reportable: a live chain names the caller, while all-zero or
       * out-of-window says the predictor stack was reset and no chain exists. */
      const uint64_t CRBase = Frame ? Frame->State.callret_sp_base : 0;
      const uint64_t CRSp = Frame ? Frame->State.callret_sp : 0;
      const uint64_t CREnd = CRBase + FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE;
      if (!CRBase || CRSp < CRBase || CRSp >= CREnd) {
        LogMan::Msg::EFmt("[callret-chain] UNAVAILABLE sp={:#x} outside [{:#x},{:#x}) -- no chain", CRSp, CRBase, CREnd);
      } else {
        uint32_t NonZero = 0;
        for (uint32_t i = 0; i < 12; ++i) {
          const uint64_t Slot = CRSp + (uint64_t)i * 0x10;
          if (Slot + 0x10 > CREnd) {
            break;
          }
          const uint64_t GuestRet = *reinterpret_cast<const uint64_t*>(Slot);
          const uint64_t HostRet = *reinterpret_cast<const uint64_t*>(Slot + 8);
          if (GuestRet || HostRet) {
            NonZero++;
          }
          LogMan::Msg::EFmt("[callret-chain] #{:<2} guest_ret={:#x} host={:#x}", i, GuestRet, HostRet);
        }
        LogMan::Msg::EFmt("[callret-chain] depth_used={:#x} nonzero={} (sp={:#x} base={:#x})", CRBase + FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE / 4 - CRSp,
                          NonZero, CRSp, CRBase);
      }
    }
  }

  /* iOS-Madeira 2026-05-18: CALLRET_SP bounds-validation + RESET.
   *
   * Initial diagnostic showed callret_sp going 0x10..0x70 BELOW
   * Thread->CallRetStackBase — underflow of the FEX prediction stack into
   * the lower guard page. On iOS, Wine's VirtualAlloc(MEM_RESERVE,
   * PAGE_NOACCESS) doesn't actually enforce NOACCESS on the guard, so the
   * guard-page SEGV that would normally trigger CallRetStack::HandleAccessViolation
   * never fires, and the existing reset-to-DefaultLocation logic doesn't kick
   * in. Result: the stack drifts further into "guard" memory each iteration
   * of Thumper's hot dispatch loop.
   *
   * GPT's Tier-1 fix: replicate HandleAccessViolation's reset proactively
   * in C++, triggered at CompileBlock entry whenever we detect callret_sp
   * outside the real [base, base+SIZE) range. The callret stack is a
   * prediction/fast-return cache, not architectural state — resetting it
   * degrades to slower lookup, doesn't change x86 semantics.
   *
   * Stack direction (per GPT): CALL push uses `stp [sp, -0x10]!`, so
   * sp decreases. RET pop uses `ldp [sp], 0x10`, so sp increases.
   * sp < base = too many CALL pushes (likely ARM64EC return paths that
   * push via the dispatcher sentinel but bypass the FEX RET pop path).
   * sp >= end = too many RET pops. Both reset to DefaultLocation. */
  {
    auto *Thread = Frame ? Frame->Thread : nullptr;
    uint64_t crsp = Frame ? Frame->State.callret_sp : 0;
    uint64_t crbase = Thread ? reinterpret_cast<uint64_t>(Thread->CallRetStackBase) : 0;
    uint64_t crend = crbase + FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE;
    if (crbase != 0 && (crsp < crbase || crsp >= crend)) {
      static volatile uint32_t oob_cnt = 0;
      uint32_t n = __sync_add_and_fetch(&oob_cnt, 1);
      uint64_t default_loc = crbase + FEXCore::Core::InternalThreadState::CALLRET_STACK_SIZE / 4;
      const char *kind = (crsp < crbase) ? "UNDERFLOW" : "OVERFLOW";
      if (n <= 16) {
        LogMan::Msg::EFmt("[CALLRET_OOB #{}] {} callret_sp=0x{:x}  "
                          "base=0x{:x} end=0x{:x} delta=0x{:x}  "
                          "GuestRIP=0x{:x} State.rip=0x{:x} Frame=0x{:x}  "
                          "RESET→0x{:x}",
                          n, kind, crsp, crbase, crend,
                          (crsp < crbase) ? (crbase - crsp) : (crsp - crend),
                          GuestRIP, Frame->State.rip,
                          reinterpret_cast<uintptr_t>(Frame),
                          default_loc);
        /* Dump top 4 pseudo-entries before reset (mostly stale; useful to
         * see if anyone wrote real callret pairs into the guard page). */
        if (crsp >= 0x10000) {
          for (int i = 0; i < 4; i++) {
            uint64_t *pair = reinterpret_cast<uint64_t*>(crsp + i * 0x10);
            LogMan::Msg::EFmt("[CALLRET_OOB #{}]   [+0x{:x}] = {{0x{:x}, 0x{:x}}}",
                              n, i * 0x10, pair[0], pair[1]);
          }
        }
      }
      /* Tier-1 reset to DefaultLocation, matching CallRetStack::HandleAccessViolation. */
      Frame->State.callret_sp = default_loc;
    }
  }

  /* iOS-Madeira 2026-05-15: JIT-pool RIP detector — LOG-ONLY.
   *
   * Earlier attempt to "recover" by setting State.rip = callret[0].pc and
   * compiling that as guest x86 produced a livelock: the recovered code
   * (e.g. FMOD at 0xeaa2f060d, `mov [rbx+0xc0], rdi`) faulted on RBX=0
   * because callret pairs are {guest_pc, host_jit_ret_target}, NOT CPU
   * register snapshots. Setting RIP without restoring RBX/RSP/flags is
   * not equivalent to ARM64EC opportunistic-return.
   *
   * Going forward: log occurrences so we can see when host PCs leak into
   * State.rip, but do NOT mutate state. The real fix belongs in the
   * dispatcher's EnterEC path. */
  {
    /* JIT pool observed at RX=0x11cc00000+0x10000000 across runs. Tighten
     * the detector to the actual pool range so we don't false-positive on
     * other 0x1XXXXXXXX guest addresses. ASLR jitter is ~16MB so widen by
     * 32MB on each side. */
    constexpr uint64_t pool_lo = 0x11c000000ULL;
    constexpr uint64_t pool_hi = 0x12e000000ULL;
    if (GuestRIP >= pool_lo && GuestRIP < pool_hi) {
      uint64_t crsp = Frame ? Frame->State.callret_sp : 0;
      static volatile uint32_t jit_rip_dump_count = 0;
      uint32_t dn = __sync_add_and_fetch(&jit_rip_dump_count, 1);
      if (dn <= 8) {
        LogMan::Msg::EFmt("[JITPOOL_RIP #{}] GuestRIP=0x{:x} (HOST PC LEAKED INTO STATE.RIP)  "
                          "State.rip=0x{:x} callret_sp=0x{:x} Frame=0x{:x}  "
                          "pool=0x{:x}..0x{:x}",
                          dn, GuestRIP,
                          Frame ? Frame->State.rip : 0, crsp,
                          reinterpret_cast<uintptr_t>(Frame),
                          pool_lo, pool_hi);
        if (crsp != 0 && crsp >= 0x10000) {
          for (int i = 0; i < 8; i++) {
            uint64_t *pair = reinterpret_cast<uint64_t*>(crsp + i * 0x10);
            LogMan::Msg::EFmt("[JITPOOL_RIP #{}]   callret[+0x{:x}] = {{pc=0x{:x}, ret=0x{:x}}}",
                              dn, i * 0x10, pair[0], pair[1]);
          }
        }
      }
      /* Log-only — no state mutation. Fall through to normal compile path.
       * If FEX subsequently faults trying to decode the JIT pool bytes as
       * x86, we'll see that in the Mach handler — at least we know the
       * exact RIP that leaked. */
    }
  }

  /* iOS-Madeira 2026-05-18 low-noise summary. Replaces per-call log (which
   * was producing ~180K lines/run for hot RIP 0x140028d46 alone, each
   * amplified ~6× by Wine's file trace). Counters: g_cb_total bumped
   * every CompileBlock call; g_cb_real_compiles bumped after cache miss
   * proves we actually compile (see below at LookupCache fallthrough).
   * Boyer-Moore-style 1-slot hot-RIP estimator. Summary every 16K calls. */
  {
    static volatile uint64_t g_cb_last_summary_total = 0;
    static volatile uint64_t g_cb_hot_rip = 0;
    static volatile uint64_t g_cb_hot_rip_count = 0;
    if (GuestRIP == g_cb_hot_rip) {
      __sync_add_and_fetch(&g_cb_hot_rip_count, 1);
    } else if (g_cb_hot_rip_count == 0) {
      g_cb_hot_rip = GuestRIP;
      __sync_add_and_fetch(&g_cb_hot_rip_count, 1);
    } else {
      __sync_sub_and_fetch(&g_cb_hot_rip_count, 1);
    }
    uint64_t total = __sync_add_and_fetch(&g_cb_total, 1);
    if ((total - g_cb_last_summary_total) >= 16384) {
      g_cb_last_summary_total = total;
      uint64_t reals = g_cb_real_compiles;
      /* iOS-Madeira 2026-07-03 perf hunt: also print the JIT-visible L1
       * lookup fields. The emitted dispatcher L1 probe reads
       * State.L1Pointer/L1Mask; the measured ~15K CompileBlock calls per
       * frame (~60us each = the whole frame time) with 99% cache hits mean
       * that probe is missing for blocks the C++ path finds instantly. If
       * State.L1Pointer here is 0 (or differs from the LookupCache's own
       * pointer), the emitted probe reads the iOS-emulated zero page and
       * silently misses every time — no crash, pure 60us tax per lookup. */
      auto* T = Frame ? Frame->Thread : nullptr;
      LogMan::Msg::EFmt("[CB_SUMMARY] total={} real_compiles={} cache_hits={} "
                        "hit_rate={}%  hottest_rip≈0x{:x} repeats~{} "
                        "L1ptr=0x{:x} L1mask=0x{:x} cacheL1=0x{:x}",
                        total, reals,
                        total - reals,
                        (total > 0) ? (100 * (total - reals) / total) : 0,
                        g_cb_hot_rip, g_cb_hot_rip_count,
                        Frame ? Frame->State.L1Pointer : 0,
                        Frame ? Frame->State.L1Mask : 0,
                        (T && T->LookupCache) ? T->LookupCache->GetL1Pointer() : 0);

      /* iOS-Madeira ml622: drain the rpmalloc remote-free CAS snapshot HERE —
       * outside rpmalloc, where formatting is safe. The allocator side only ever
       * copies scalars into a POD and sets a flag; it must never format, because
       * LogMan/fmt can allocate and re-enter the very allocator that is stuck
       * (that is how ml620 killed itself).
       *
       * Read the counters, not the total: fail_changed vs fail_unchanged is the
       * discriminator, and fail_invalid outranks both. ⚠️ A changed token is NOT
       * automatically healthy contention — it can equally be page reuse or a
       * foreign writer, so check block_index/list_size against block_count before
       * concluding anything. */
      {
        rpm_cas_snapshot Snap;
        if (rpm_cas_snapshot_take(&Snap)) {
          LogMan::Msg::EFmt("[rpm-cas] ml622 loop={} {} page=0x{:x} block=0x{:x} heap=0x{:x} atomic=0x{:x} "
                            "teb=0x{:x} ret=0x{:x} class={} ptype={} idx={}/{} list_size={} used={} is_full={} "
                            "prev_token=0x{:x} cur_token=0x{:x} | fail changed={} unchanged={} invalid={}",
                            Snap.which_loop, Snap.quarantined ? "QUARANTINED (block leaked, spin abandoned)" : "spinning",
                            Snap.page_addr, Snap.block_addr, Snap.heap_addr, Snap.atomic_addr, Snap.owner_teb,
                            Snap.ret_addr, Snap.size_class, Snap.page_type, Snap.block_index, Snap.block_count,
                            Snap.list_size, Snap.block_used, Snap.is_full, Snap.prev_token, Snap.cur_token,
                            Snap.fail_changed, Snap.fail_unchanged, Snap.fail_invalid);
        }
      }
    }
  }

  /* iOS-Madeira 2026-05-14: per-thread callret tracking (runs for EVERY
   * block dispatch, not just hot RIPs). 4-slot hash table keyed by Frame
   * pointer (unique per FEX thread). Identifies WHICH thread is leaking
   * callret entries vs healthy. */
  {
    uintptr_t fk = reinterpret_cast<uintptr_t>(Frame);
    int slot = (int)((fk >> 6) & 3);
    /* Claim the slot if empty, or use if matches; ignore on collision. */
    if (g_madeira_thr_key[slot] == 0 || g_madeira_thr_key[slot] == fk) {
      g_madeira_thr_key[slot] = fk;
      uint64_t crsp = Frame->State.callret_sp;
      g_madeira_thr_crsp_last[slot] = crsp;
      g_madeira_thr_last_rip[slot] = GuestRIP;
      g_madeira_thr_count[slot]++;
      if (crsp != 0) {
        if (crsp < g_madeira_thr_crsp_min[slot]) g_madeira_thr_crsp_min[slot] = crsp;
        if (crsp > g_madeira_thr_crsp_max[slot]) g_madeira_thr_crsp_max[slot] = crsp;
      }
    }
  }

  /* iOS-Madeira 2026-05-13 lightweight HOTRIP instrumentation (v3): use
   * plain volatile globals to avoid __cxa_guard_acquire on static-local
   * initialization, which appears to trip a stack-cookie check on
   * ARM64EC mingw. POD types only — no constructors. Atomicity isn't
   * critical for telemetry; occasional torn reads are fine. */
  {
    /* RIPs depend on FMOD's mapped base (0xeaa1d0000 in current runs).
     * The two critsection wrappers GPT identified live at fmod+0xba27a
     * and fmod+0xba2fa. Match on the FMOD-relative range rather than
     * absolute address so this works across ASLR runs. */
    int idx = -1;
    uint64_t fmod_off = GuestRIP - 0xeaa1d0000ull;
    switch (GuestRIP) {
      case 0x140006fe6ull: idx = 0; break;
      case 0x140006febull: idx = 1; break;
      case 0x140028d20ull: idx = 2; break;
      case 0x140028d41ull: idx = 3; break;
      case 0x140028d46ull: idx = 4; break;
      case 0x1400687f0ull: idx = 5; break;
      case 0x140068816ull: idx = 6; break;
      default:
        /* FMOD critsection wrappers — relative to current fmod64 base. */
        if (GuestRIP == 0xeaa28a27aull) idx = 7;       /* EnterCriticalSection wrapper */
        else if (GuestRIP == 0xeaa28a2faull) idx = 8;  /* LeaveCriticalSection wrapper */
        else if (GuestRIP == 0xeaa28a9d4ull) idx = 9;  /* GPT-mentioned wrapper */
        else if (GuestRIP == 0xeaa28a9e3ull) idx = 10; /* GPT-mentioned wrapper */
        else if (fmod_off >= 0xba000 && fmod_off < 0xbb000) idx = 11; /* any other near these */
        break;
    }
    if (idx >= 0) {
      uint64_t n = ++g_madeira_hot_count[idx];

      /* Track callret_sp range — answers "leak (monotonic) vs boundary (oscillating)". */
      uint64_t crsp = Frame->State.callret_sp;
      g_madeira_callret_last = crsp;
      if (crsp > g_madeira_callret_max) g_madeira_callret_max = crsp;
      if (crsp != 0 && crsp < g_madeira_callret_min) g_madeira_callret_min = crsp;

      if (idx == 5 || idx == 6) {
        uint64_t sz = Frame->State.gregs[FEXCore::X86State::REG_RDI];
        if (sz > g_madeira_max_alloc_size) g_madeira_max_alloc_size = sz;
      }

      if (idx == 1) {
        uint64_t rbx = Frame->State.gregs[FEXCore::X86State::REG_RBX];
        uint64_t rcx = Frame->State.gregs[FEXCore::X86State::REG_RCX];
        if (rbx >= 0x10000ull && rbx < 0x800000000000ull) {
          uint64_t rbx_0 = *reinterpret_cast<uint64_t*>(rbx);
          if (rbx_0 >= 0x10000ull && rbx_0 < 0x800000000000ull) {
            uint64_t vt = *reinterpret_cast<uint64_t*>(rbx_0);
            if (vt >= 0x10000ull && vt < 0x800000000000ull) {
              g_madeira_last_vt = vt;
              g_madeira_last_vt2 = *reinterpret_cast<uint64_t*>(vt + 0x10);
            }
          }
        }
        if (rcx >= 0x10000ull && rcx < 0x800000000000ull) {
          uint64_t bytes = *reinterpret_cast<uint64_t*>(rcx);
          uint8_t b0 = bytes & 0xff;
          if (b0 >= 0x20 && b0 <= 0x7e) g_madeira_last_str = bytes;
        }
      }

      if ((n & 0xFFF) == 0) {
        /* Wall-clock elapsed since first HOT sum — answers "is the game
         * still alive at minute N?" Uses time(NULL) for second resolution. */
        static volatile uint64_t s_start_secs = 0;
        uint64_t now = (uint64_t)time(NULL);
        if (s_start_secs == 0) s_start_secs = now;
        uint64_t elapsed = now - s_start_secs;
        LogMan::Msg::EFmt("[HOT sum t={}s] 6fe6={} 6feb={} 28d20={} 28d41={} 28d46={} 687f0={} 68816={} "
                           "fmod27a={} fmod2fa={} fmod9d4={} fmod9e3={} fmodNear={} "
                           "max_alloc=0x{:x} crsp[min..last..max]=0x{:x}..0x{:x}..0x{:x} "
                           "last_vt=0x{:x} vt2=0x{:x} last_str=0x{:x}",
                           elapsed,
                           g_madeira_hot_count[0], g_madeira_hot_count[1], g_madeira_hot_count[2],
                           g_madeira_hot_count[3], g_madeira_hot_count[4], g_madeira_hot_count[5],
                           g_madeira_hot_count[6],
                           g_madeira_hot_count[7], g_madeira_hot_count[8],
                           g_madeira_hot_count[9], g_madeira_hot_count[10], g_madeira_hot_count[11],
                           g_madeira_max_alloc_size,
                           g_madeira_callret_min, g_madeira_callret_last, g_madeira_callret_max,
                           g_madeira_last_vt, g_madeira_last_vt2, g_madeira_last_str);
        /* Per-thread breakdown — dump all 4 slots so we can see which
         * thread is leaking callret entries. Distance min→last is the
         * "depth below high-water" — for the leaking thread this grows. */
        for (int s = 0; s < 4; s++) {
          if (g_madeira_thr_key[s] == 0) continue;
          uint64_t mn = g_madeira_thr_crsp_min[s];
          uint64_t la = g_madeira_thr_crsp_last[s];
          uint64_t mx = g_madeira_thr_crsp_max[s];
          uint64_t span = (la <= mx) ? (mx - la) : 0;
          LogMan::Msg::EFmt("[HOT thr{} t={}s] frame=0x{:x} blocks={} "
                             "crsp[min..last..max]=0x{:x}..0x{:x}..0x{:x} "
                             "leak_depth=0x{:x} last_rip=0x{:x}",
                             s, elapsed, g_madeira_thr_key[s],
                             g_madeira_thr_count[s], mn, la, mx, span,
                             g_madeira_thr_last_rip[s]);
        }
      }
    }
  }

  static_cast<ContextImpl*>(Thread->CTX)->SyscallHandler->PreCompile();

#ifdef FEX_IOS_HOST
  /* iOS-Madeira ml455 (#74 delivery-under-locks): if an interrupted frame on
   * THIS thread already holds emission locks, this call can only be guest SEH
   * delivery re-entering the compiler asynchronously.  Re-taking the
   * invalidation shared lock risks the write-priority recursive-read park,
   * FindBlock takes the lookup lock the frame below may write-own, and
   * publication would do the same — so compile WITHOUT locks or publication
   * and hand the block back for a one-shot execute.  It is re-compiled and
   * published normally on the next synchronous miss.  CompileSingleStep
   * proves the dispatcher happily consumes an unpublished pointer. */
  const bool IosUnpublished = FEXCore::Utils::WritePriorityMutex::IosEmissionLocksHeldBySelf();
  std::shared_lock<std::remove_reference_t<decltype(CodeInvalidationMutex)>> lk;
  if (IosUnpublished) {
    static std::atomic<int> UnpubLogCount {0};
    if (UnpubLogCount.fetch_add(1, std::memory_order_relaxed) < 40) {
      LogMan::Msg::EFmt("[fexlock] UNPUB-COMPILE rip=0x{:x} rev=ml455", GuestRIP);
    }
  } else {
    // Invalidate might take a unique lock on this, to guarantee that during invalidation no code gets compiled
    lk = std::shared_lock {CodeInvalidationMutex};

    // Is the code in the cache?
    // The backends only check L1 and L2, not L3
    if (auto HostCode = Thread->LookupCache->FindBlock(Thread, GuestRIP)) {
      return HostCode;
    }
  }
#else
  // Invalidate might take a unique lock on this, to guarantee that during invalidation no code gets compiled
  auto lk = GuardSignalDeferringSection<std::shared_lock>(CodeInvalidationMutex, Thread);

  // Is the code in the cache?
  // The backends only check L1 and L2, not L3
  if (auto HostCode = Thread->LookupCache->FindBlock(Thread, GuestRIP)) {
    return HostCode;
  }
#endif

  // iOS-Madeira: cache miss reached — count as true compile.
  __sync_add_and_fetch(&g_cb_real_compiles, 1);

  // Accumulate a JIT count now, as even if another thread raced us, it should count as a compile.
  FEXCORE_PROFILE_INSTANT_INCREMENT(Thread, AccumulatedJITCount, 1);

#ifdef FEX_IOS_HOST
  /* ml455: depth (not a flag) — a doubly-nested delivery must not clear the
   * outer level's mode on its way out. */
  if (IosUnpublished) {
    FEXCore::Utils::WritePriorityMutex::IosAdjustUnpublishedCompileDepth(1);
  }
#endif
  auto [CompiledCode, DebugData, StartAddr, Length, NeedsAddGuestCodeRanges] = CompileCode(Thread, GuestRIP, MaxInst);
#ifdef FEX_IOS_HOST
  if (IosUnpublished) {
    FEXCore::Utils::WritePriorityMutex::IosAdjustUnpublishedCompileDepth(-1);
  }
#endif
  auto CodePtr = CompiledCode.EntryPoints[GuestRIP];
  /* iOS-Madeira diag (Thumper desktop ILL 2026-07-06): three crashes branched
   * to BlockTail+0x18 instead of a code entry — the published entry itself
   * was wrong. Validate every entry against the block layout at publication
   * time: an entry must land in [BlockBegin, Tail) and must not decode as
   * the NOP prefill. */
  if (CodePtr && CompiledCode.BlockBegin) {
    uint32_t TailOff = *reinterpret_cast<uint32_t*>(CompiledCode.BlockBegin);
    uint8_t* Tail = CompiledCode.BlockBegin + TailOff;
    uint32_t FirstInsn = *reinterpret_cast<uint32_t*>(CodePtr);
    if (reinterpret_cast<uint8_t*>(CodePtr) < CompiledCode.BlockBegin ||
        reinterpret_cast<uint8_t*>(CodePtr) >= Tail || FirstInsn == 0xd503201fu) {
      LogMan::Msg::EFmt("[fex-entry] BAD ENTRY at publication: rip=0x{:x} entry=0x{:x} "
                        "block=0x{:x} tail_off=0x{:x} first_insn=0x{:08x}",
                        GuestRIP, reinterpret_cast<uintptr_t>(CodePtr),
                        reinterpret_cast<uintptr_t>(CompiledCode.BlockBegin), TailOff, FirstInsn);
    }
  }
  if (CodePtr == nullptr) {
    return 0;
  } else if (!DebugData) {
    // DebugData wasn't populated, indicating another thread raced us for compiling this block
    return reinterpret_cast<uintptr_t>(CodePtr);
  }

  // The core managed to compile the code.
  if (Config.BlockJITNaming()) {
    auto FragmentBasePtr = CompiledCode.BlockBegin;

    auto GuestRIPLookup = SyscallHandler->LookupExecutableFileSection(Thread, GuestRIP);

    if (DebugData->Subblocks.size()) {
      for (auto& Subblock : DebugData->Subblocks) {
        auto BlockBasePtr = FragmentBasePtr + Subblock.HostCodeOffset;
        if (GuestRIPLookup) {
          Symbols.Register(Thread->SymbolBuffer.get(), BlockBasePtr, CompiledCode.Size, GuestRIPLookup->FileInfo.Filename,
                           GuestRIP - GuestRIPLookup->FileStartVA);
        } else {
          Symbols.Register(Thread->SymbolBuffer.get(), BlockBasePtr, GuestRIP, Subblock.HostCodeSize);
        }
      }
    } else {
      if (GuestRIPLookup) {
        Symbols.Register(Thread->SymbolBuffer.get(), FragmentBasePtr, CompiledCode.Size, GuestRIPLookup->FileInfo.Filename,
                         GuestRIP - GuestRIPLookup->FileStartVA);
      } else {
        Symbols.Register(Thread->SymbolBuffer.get(), FragmentBasePtr, GuestRIP, CompiledCode.Size);
      }
    }
  }

  if (Config.LibraryJITNaming() || Config.GDBSymbols()) {
    auto MappedSection = SyscallHandler->LookupExecutableFileSection(Thread, GuestRIP);
    if (MappedSection) {
      if (Config.LibraryJITNaming()) {
        Symbols.RegisterNamedRegion(Thread->SymbolBuffer.get(), CodePtr, DebugData->HostCodeSize, MappedSection->FileInfo.Filename);
      }

      if (Config.GDBSymbols()) {
        GDBJITRegister(MappedSection->FileInfo, MappedSection->FileStartVA, GuestRIP, (uintptr_t)CodePtr, *DebugData);
      }
    }
  }

  // Clear any relocations that might have been generated
  if (!CodeCache.IsGeneratingCache) {
    Thread->CPUBackend->ClearRelocations();
  }

#ifdef FEX_IOS_HOST
  /* ml455: delivery-mode block — return for one-shot execution WITHOUT any
   * publication.  Guest-range registration, the lookup insert and the codemap
   * all take locks an interrupted frame below may own. */
  if (IosUnpublished) {
    return (uintptr_t)CodePtr;
  }
#endif

  fextl::vector<uint64_t> CodePages;

  if (NeedsAddGuestCodeRanges) {
    // Track in the guest to host map all entrypoints for all pages the compiled block touches, if any page didn't previously
    // contain code, inform the frontend so it can setup SMC detection.
    auto BlockInfo = Thread->FrontendDecoder->GetDecodedBlockInfo();
    CodePages.reserve(BlockInfo->CodePages.size());
    CodePages.insert(CodePages.end(), BlockInfo->CodePages.begin(), BlockInfo->CodePages.end());
    for (auto CodePage : BlockInfo->CodePages) {
      if (Thread->LookupCache->AddBlockExecutableRange(Thread, BlockInfo->EntryPoints, CodePage, FEXCore::Utils::FEX_PAGE_SIZE)) {
        SyscallHandler->MarkGuestExecutableRange(Thread, CodePage, FEXCore::Utils::FEX_PAGE_SIZE);
      }
    }
  }

  // Insert to lookup cache

  for (auto [GuestAddr, HostAddr] : CompiledCode.EntryPoints) {
    Thread->LookupCache->AddBlockMapping(Thread, GuestAddr, CodePages, HostAddr);
  }

  if (CodeMapWriter) {
    auto Region = SyscallHandler->LookupExecutableFileSection(Thread, GuestRIP);
    if (Region && Region->FileStartVA != 0) {
      CodeMapWriter->AppendBlock(*Region, GuestRIP);
    }
  }

#if defined(FEX_IOS_HOST) && defined(_WIN32)
  /* iOS-Madeira ml460 (#75): deferred pool-tail sweep. A generation swap makes
   * every parked thread's CurrentCodeBuffer ref a dead pin (ml459: 13 16MB
   * generations live where steady state needs ~2). The frontend sweeper walks
   * its thread registry and remote-migrates threads that are outside emitted
   * code. Triggered here — a synchronous compile, past emission, holding only
   * the shared CodeInvalidationMutex (sweep order WPM-shared -> map-write ->
   * migrate-spin matches every other taker). Never from a delivery compile. */
  if (!IosUnpublished) {
    IosMaybeSweepCodeBuffers(Thread);
  }
#endif

  return (uintptr_t)CodePtr;
}

uintptr_t ContextImpl::CompileSingleStep(FEXCore::Core::CpuStateFrame* Frame, uint64_t GuestRIP) {
  FEXCORE_PROFILE_SCOPED("CompileSingleStep");
  auto Thread = Frame->Thread;

  static_cast<ContextImpl*>(Thread->CTX)->SyscallHandler->PreCompile();

  // Invalidate might take a unique lock on this, to guarantee that during invalidation no code gets compiled
  auto lk = GuardSignalDeferringSection<std::shared_lock>(CodeInvalidationMutex, Thread);

  auto [CompiledCode, DebugData, StartAddr, Length, _] = CompileCode(Thread, GuestRIP, 1);
  auto CodePtr = CompiledCode.EntryPoints[GuestRIP];
  if (CodePtr == nullptr) {
    return 0;
  }

  // Clear any relocations that might have been generated
  Thread->CPUBackend->ClearRelocations();

  return (uintptr_t)CodePtr;
}

void ContextImpl::InvalidateCodeBuffersCodeRange(uint64_t Start, uint64_t Length) {
  FEXCORE_PROFILE_SCOPED("InvalidateCodeBuffersCodeRange");

  LOGMAN_THROW_A_FMT(CodeInvalidationMutex.try_lock() == false, "CodeInvalidationMutex needs to be unique_locked here");
  std::scoped_lock lk {CodeBufferListLock};
  auto it = CodeBufferList.begin();
  while (it != CodeBufferList.end()) {
    if (auto Strong = it->lock()) {
      Strong->LookupCache->InvalidateRange(Start, Length);
      it++;
    } else {
      it = CodeBufferList.erase(it);
    }
  }
}

void ContextImpl::InvalidateThreadCachedCodeRange(FEXCore::Core::InternalThreadState* Thread, uint64_t Start, uint64_t Length) {
  LOGMAN_THROW_A_FMT(CodeInvalidationMutex.try_lock() == false, "CodeInvalidationMutex needs to be unique_locked here");

  // Ensures now-modified mappings aren't cached as being in their previous non-executable state.
  // Accessing FrontendDecoder is safe as the thread's code invalidation mutex must be locked here.
  Thread->FrontendDecoder->ResetExecutableRangeCache();

  if (Thread->LookupCache->InvalidateCacheRange(Start, Length)) {
    FEXCORE_PROFILE_SCOPED("InvalidateCallRet");

    // This may cause access violations in the thread on Windows as zeroing is not atomic, this is handled by the frontend
    FEXCore::Core::ResetCallRetStack(Thread, "core");
  }
}

void ContextImpl::ThreadRemoveCodeEntryFromJit(FEXCore::Core::CpuStateFrame* Frame, uint64_t GuestRIP) {
  static_cast<ContextImpl*>(Frame->Thread->CTX)->SyscallHandler->InvalidateGuestCodeRange(Frame->Thread, GuestRIP, 1);
}

std::optional<CustomIRResult>
ContextImpl::AddCustomIREntrypoint(uintptr_t Entrypoint, CustomIREntrypointHandler Handler, void* Creator, void* Data) {
  LOGMAN_THROW_A_FMT(Config.Is64BitMode || !(Entrypoint >> 32), "64-bit Entrypoint in 32-bit mode {:x}", Entrypoint);

  std::unique_lock lk(CustomIRMutex);

  auto InsertedIterator = CustomIRHandlers.emplace(Entrypoint, CustomIRHandlerEntry {Handler, Creator, Data});
  HasCustomIRHandlers = true;

  if (!InsertedIterator.second) {
    const auto& [fn, Creator, Data] = InsertedIterator.first->second;
    return CustomIRResult(Creator, Data);
  }

  return std::nullopt;
}

void ContextImpl::AddThunkTrampolineIRHandler(uintptr_t Entrypoint, uintptr_t GuestThunkEntrypoint) {
  LOGMAN_THROW_A_FMT(Entrypoint, "Tried to link null pointer address to guest function");
  LOGMAN_THROW_A_FMT(GuestThunkEntrypoint, "Tried to link address to null pointer guest function");
  if (!Config.Is64BitMode) {
    LOGMAN_THROW_A_FMT((Entrypoint >> 32) == 0, "Tried to link 64-bit address in 32-bit mode");
    LOGMAN_THROW_A_FMT((GuestThunkEntrypoint >> 32) == 0, "Tried to link 64-bit address in 32-bit mode");
  }

  LogMan::Msg::DFmt("Thunks: Adding guest trampoline from address {:#x} to guest function {:#x}", Entrypoint, GuestThunkEntrypoint);

  auto Result = AddCustomIREntrypoint(
    Entrypoint,
    [this, GuestThunkEntrypoint](uintptr_t Entrypoint, FEXCore::IR::IREmitter* emit) {
      auto IRHeader = emit->_IRHeader(emit->Invalid(), Entrypoint, 0, 0, 0, 0);
      auto Block = emit->CreateCodeNode(true, 0);
      IRHeader.first->Blocks = emit->WrapNode(Block);
      emit->SetCurrentCodeBlock(Block);

      const auto GPRSize = this->Config.Is64BitMode ? IR::OpSize::i64Bit : IR::OpSize::i32Bit;

      // Thunk entry-points don't get cached, don't need to be padded.
      if (GPRSize == IR::OpSize::i64Bit) {
        IR::Ref R = emit->_StoreRegister(emit->Constant(Entrypoint), GPRSize);
        R->Reg = IR::PhysicalRegister(IR::RegClass::GPRFixed, X86State::REG_R11).Raw;
      } else {
        emit->_StoreContextFPR(GPRSize, emit->_VCastFromGPR(IR::OpSize::i64Bit, IR::OpSize::i64Bit, emit->Constant(Entrypoint)),
                               offsetof(Core::CPUState, mm[0][0]));
      }
      emit->_ExitFunction(IR::OpSize::i64Bit, emit->Constant(GuestThunkEntrypoint), IR::BranchHint::None, emit->Invalid(), emit->Invalid());
    },
    ThunkHandler, (void*)GuestThunkEntrypoint);

  if (Result.has_value()) {
    if (Result->Creator != ThunkHandler) {
      ERROR_AND_DIE_FMT("Input address for AddThunkTrampoline is already linked by another module");
    }
    if (Result->Data != (void*)GuestThunkEntrypoint) {
      // NOTE: This may happen in Vulkan thunks if the Vulkan driver resolves two different symbols
      //       to the same function (e.g. vkGetPhysicalDeviceFeatures2/vkGetPhysicalDeviceFeatures2KHR)
      LogMan::Msg::EFmt("Input address for AddThunkTrampoline is already linked elsewhere");
    }
  }
}

void ContextImpl::AddForceTSOInformation(const IntervalList<uint64_t>& ValidRanges, fextl::set<uint64_t>&& Instructions) {
  LogMan::Throw::AFmt(CodeInvalidationMutex.try_lock() == false, "CodeInvalidationMutex needs to be unique_locked here");
  ForceTSOValidRanges.Insert(ValidRanges);
  ForceTSOInstructions.merge(std::move(Instructions));
}

void ContextImpl::RemoveForceTSOInformation(uint64_t Address, uint64_t Size) {
  LogMan::Throw::AFmt(CodeInvalidationMutex.try_lock() == false, "CodeInvalidationMutex needs to be unique_locked here");

  ForceTSOValidRanges.Remove({Address, Address + Size});
  ForceTSOInstructions.erase(ForceTSOInstructions.lower_bound(Address), ForceTSOInstructions.upper_bound(Address + Size));
}

void ContextImpl::MarkMonoBackpatcherBlock(uint64_t BlockEntry) {
  MonoBackpatcherBlock.store(BlockEntry, std::memory_order_relaxed);
}

void ContextImpl::RemoveCustomIREntrypoint(FEXCore::Core::InternalThreadState* Thread, uintptr_t Entrypoint) {
  LOGMAN_THROW_A_FMT(Config.Is64BitMode || !(Entrypoint >> 32), "64-bit Entrypoint in 32-bit mode {:x}", Entrypoint);

  std::scoped_lock lk(CustomIRMutex);

  CustomIRHandlers.erase(Entrypoint);
  HasCustomIRHandlers = !CustomIRHandlers.empty();
  SyscallHandler->InvalidateGuestCodeRange(Thread, Entrypoint, 1);
}


void ContextImpl::MonoBackpatcherWrite(FEXCore::Core::CpuStateFrame* Frame, uint8_t Size, uint64_t Address, uint64_t Value) {
  auto Thread = Frame->Thread;
  auto CTX = static_cast<ContextImpl*>(Thread->CTX);
  {
    auto lk = GuardSignalDeferringSection(CTX->CodeInvalidationMutex, Thread);

    uint64_t Dest = Address;
#ifdef FEX_IOS_HOST
    /* ml648: THE STORE MUST GO TO THE WRITABLE ALIAS.
     *
     * The whole point of this helper is to replace a faulting write with a
     * direct one. On iOS the guest VA is R+X only -- iOS will not grant RWX --
     * so a plain store to `Address` Mach-faults straight back and we would have
     * swapped one fault for another, gaining nothing. Resolve through the
     * anonymous alias table (NOT IosAliasEntries) and write the RW view.
     *
     * A miss is counted and falls through to the direct store, which faults and
     * is emulated as before: degraded, never wrong. */
    const uint64_t RW = IosMonoResolveRW(Address, Size);
    if (RW) {
      Dest = RW;
    }
    ios_fex_mono_count_helper(RW ? 0 : 1);
#endif

    if (Size == 8) {
      *reinterpret_cast<uint64_t*>(Dest) = Value;
    } else if (Size == 4) {
      *reinterpret_cast<uint32_t*>(Dest) = Value;
    } else {
      ERROR_AND_DIE_FMT("Unexpected write size for backpatcher: {}", Size);
    }
  }

  CTX->SyscallHandler->InvalidateGuestCodeRange(Thread, Address, Size);
}

void ContextImpl::ConfigureAOTGen(FEXCore::Core::InternalThreadState* Thread, fextl::set<uint64_t>* ExternalBranches, uint64_t SectionMaxAddress) {
  Thread->FrontendDecoder->SetExternalBranches(ExternalBranches);
}
} // namespace FEXCore::Context
