// SPDX-License-Identifier: MIT

#include "Interface/Core/CPUBackend.h"
#include "Interface/Context/Context.h"
#include <FEXCore/Utils/SpinWaitLock.h>

#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/Utils/EnumUtils.h>
#include <FEXCore/Utils/LogManager.h>
#include <FEXCore/Utils/Telemetry.h>
#include <FEXCore/Utils/ArchHelpers/Arm64.h>
#include <FEXCore/Utils/DualMap.h>

#include <atomic>
#include <cstdint>
#include <cstdlib>

namespace FEXCore::ArchHelpers::Arm64 {
constexpr uint32_t CASPAL_MASK = 0xBF'E0'FC'00;
constexpr uint32_t CASPAL_INST = 0x08'60'FC'00;

constexpr uint32_t CASAL_MASK = 0x3F'E0'FC'00;
constexpr uint32_t CASAL_INST = 0x08'E0'FC'00;

constexpr uint32_t ATOMIC_MEM_MASK = 0x3B200C00;
constexpr uint32_t ATOMIC_MEM_INST = 0x38200000;

constexpr uint32_t RCPC2_MASK = 0x3F'E0'0C'00;
constexpr uint32_t LDAPUR_INST = 0x19'40'00'00;
constexpr uint32_t STLUR_INST = 0x19'00'00'00;

constexpr uint32_t LDAXP_MASK = 0xBF'FF'80'00;
constexpr uint32_t LDAXP_INST = 0x88'7F'80'00;

constexpr uint32_t STLXP_MASK = 0xBF'E0'80'00;
constexpr uint32_t STLXP_INST = 0x88'20'80'00;

constexpr uint32_t LDAXR_MASK = 0x3F'FF'FC'00;
constexpr uint32_t LDAXR_INST = 0x08'5F'FC'00;
constexpr uint32_t LDAR_INST = 0x08'DF'FC'00;
constexpr uint32_t LDAPR_INST = 0x38'BF'C0'00;
constexpr uint32_t STLR_INST = 0x08'9F'FC'00;

constexpr uint32_t STLXR_MASK = 0x3F'E0'FC'00;
constexpr uint32_t STLXR_INST = 0x08'00'FC'00;

// Load/store register (register offset) (Rm encoded as xzr)
constexpr uint32_t LDSTREGISTER_MASK = 0b0011'1111'1111'1111'1111'1100'0000'0000;
constexpr uint32_t LDR_INST = 0b0011'1000'0111'1111'0110'1000'0000'0000;
constexpr uint32_t STR_INST = 0b0011'1000'0011'1111'0110'1000'0000'0000;

constexpr uint32_t LDSTUNSCALED_MASK = 0b0011'1011'1110'0000'0000'1100'0000'0000;
constexpr uint32_t LDUR_INST = 0b0011'1000'0100'0000'0000'0000'0000'0000;
constexpr uint32_t STUR_INST = 0b0011'1000'0000'0000'0000'0000'0000'0000;

constexpr uint32_t LDSTP_MASK = 0b0011'1011'1000'0000'0000'0000'0000'0000;
constexpr uint32_t STP_INST = 0b0010'1001'0000'0000'0000'0000'0000'0000;

constexpr uint32_t CBNZ_MASK = 0x7F'00'00'00;
constexpr uint32_t CBNZ_INST = 0x35'00'00'00;

constexpr uint32_t ALU_OP_MASK = 0x7F'20'00'00;
constexpr uint32_t ADD_INST = 0x0B'00'00'00;
constexpr uint32_t SUB_INST = 0x4B'00'00'00;
constexpr uint32_t ADD_SHIFT_INST = 0x0B'20'00'00;
constexpr uint32_t SUB_SHIFT_INST = 0x4B'20'00'00;
constexpr uint32_t CMP_INST = 0x6B'00'00'00;
constexpr uint32_t CMP_SHIFT_INST = 0x6B'20'00'00;
constexpr uint32_t AND_INST = 0x0A'00'00'00;
constexpr uint32_t BIC_INST = 0x0A'20'00'00;
constexpr uint32_t OR_INST = 0x2A'00'00'00;
constexpr uint32_t ORN_INST = 0x2A'20'00'00;
constexpr uint32_t EOR_INST = 0x4A'00'00'00;
constexpr uint32_t EON_INST = 0x4A'20'00'00;

constexpr uint32_t CCMP_MASK = 0x7F'E0'0C'10;
constexpr uint32_t CCMP_INST = 0x7A'40'00'00;

constexpr uint32_t CLREX_MASK = 0xFF'FF'F0'FF;
constexpr uint32_t CLREX_INST = 0xD5'03'30'5F;

enum ExclusiveAtomicPairType {
  TYPE_SWAP,
  TYPE_ADD,
  TYPE_SUB,
  TYPE_AND,
  TYPE_BIC,
  TYPE_OR,
  TYPE_ORN,
  TYPE_EOR,
  TYPE_EON,
  TYPE_NEG, // This is just a sub with zero. Need to know the differences
};

// Load ops are 4 bits
// Acquire and release bits are independent on the instruction
constexpr uint32_t ATOMIC_ADD_OP = 0b0000;
constexpr uint32_t ATOMIC_CLR_OP = 0b0001;
constexpr uint32_t ATOMIC_EOR_OP = 0b0010;
constexpr uint32_t ATOMIC_SET_OP = 0b0011;
constexpr uint32_t ATOMIC_SWAP_OP = 0b1000;

constexpr uint32_t REGISTER_MASK = 0b11111;
constexpr uint32_t RD_OFFSET = 0;
constexpr uint32_t RN_OFFSET = 5;
constexpr uint32_t RM_OFFSET = 16;

constexpr uint32_t DMB = 0b1101'0101'0000'0011'0011'0000'1011'1111 | 0b1011'0000'0000; // Inner shareable all

constexpr uint32_t DMB_LD = 0b1101'0101'0000'0011'0011'0000'1011'1111 | 0b1101'0000'0000; // Inner shareable load

static constexpr uint32_t GetRdReg(uint32_t Instr) {
  return (Instr >> RD_OFFSET) & REGISTER_MASK;
}

static constexpr uint32_t GetRnReg(uint32_t Instr) {
  return (Instr >> RN_OFFSET) & REGISTER_MASK;
}

static constexpr uint32_t GetRmReg(uint32_t Instr) {
  return (Instr >> RM_OFFSET) & REGISTER_MASK;
}

static void ClearICache(void* Begin, std::size_t Length) {
  __builtin___clear_cache(static_cast<char*>(Begin), static_cast<char*>(Begin) + Length);
}

static __uint128_t LoadAcquire128(uint64_t Addr) {
  __uint128_t Result {};
  uint64_t Lower;
  uint64_t Upper;
  // This specifically avoids using std::atomic<__uint128_t>
  // std::atomic helper does a ldaxp + stxp pair that crashes when the page is only mapped readable
  __asm volatile(
    R"(
  ldaxp %[ResultLower], %[ResultUpper], [%[Addr]];
  clrex;
)"
    : [ResultLower] "=r"(Lower), [ResultUpper] "=r"(Upper)
    : [Addr] "r"(Addr)
    : "memory");
  Result = Upper;
  Result <<= 64;
  Result |= Lower;
  return Result;
}

static uint64_t LoadAcquire64(uint64_t Addr) {
  auto Atom = std::atomic_ref<uint64_t>(*reinterpret_cast<uint64_t*>(Addr));
  return Atom.load(std::memory_order_acquire);
}

static bool StoreCAS64(uint64_t& Expected, uint64_t Val, uint64_t Addr) {
  auto Atom = std::atomic_ref<uint64_t>(*reinterpret_cast<uint64_t*>(Addr));
  return Atom.compare_exchange_strong(Expected, Val);
}

static uint32_t LoadAcquire32(uint64_t Addr) {
  auto Atom = std::atomic_ref<uint32_t>(*reinterpret_cast<uint32_t*>(Addr));
  return Atom.load(std::memory_order_acquire);
}

static bool StoreCAS32(uint32_t& Expected, uint32_t Val, uint64_t Addr) {
  auto Atom = std::atomic_ref<uint32_t>(*reinterpret_cast<uint32_t*>(Addr));
  return Atom.compare_exchange_strong(Expected, Val);
}

static uint8_t LoadAcquire8(uint64_t Addr) {
  auto Atom = std::atomic_ref<uint8_t>(*reinterpret_cast<uint8_t*>(Addr));
  return Atom.load(std::memory_order_acquire);
}

static bool StoreCAS8(uint8_t& Expected, uint8_t Val, uint64_t Addr) {
  auto Atom = std::atomic_ref<uint8_t>(*reinterpret_cast<uint8_t*>(Addr));
  return Atom.compare_exchange_strong(Expected, Val);
}

static uint16_t DoLoad16(uint64_t Addr) {
  uint64_t AlignmentMask = 0b1111;
  if ((Addr & AlignmentMask) == 15) {
    // Address crosses over 16byte or 64byte threshold
    // Needs two loads
    uint64_t AddrUpper = Addr + 1;
    uint8_t ActualUpper {};
    uint8_t ActualLower {};
    // Careful ordering here
    ActualUpper = LoadAcquire8(AddrUpper);
    ActualLower = LoadAcquire8(Addr);

    uint16_t Result = ActualUpper;
    Result <<= 8;
    Result |= ActualLower;
    return Result;
  } else {
    AlignmentMask = 0b111;
    if ((Addr & AlignmentMask) == 7) {
      // Crosses 8byte boundary
      // Needs 128bit load
      // Fits within a 16byte region
      uint64_t Alignment = Addr & 0b1111;
      Addr &= ~0b1111ULL;

      __uint128_t TmpResult = LoadAcquire128(Addr);

      // Zexts the result
      uint16_t Result = TmpResult >> (Alignment * 8);
      return Result;
    } else {
      AlignmentMask = 0b11;
      if ((Addr & AlignmentMask) == 3) {
        // Crosses 4byte boundary
        // Needs 64bit Load
        uint64_t Alignment = Addr & AlignmentMask;
        Addr &= ~AlignmentMask;

        auto Atomic = std::atomic_ref<uint64_t>(*reinterpret_cast<uint64_t*>(Addr));
        uint64_t TmpResult = Atomic.load();

        // Zexts the result
        uint16_t Result = TmpResult >> (Alignment * 8);
        return Result;
      } else {
        // Fits within 4byte boundary
        // Only needs 32bit Load
        // Only alignment offset will be 1 here
        uint64_t Alignment = Addr & AlignmentMask;
        Addr &= ~AlignmentMask;

        auto Atomic = std::atomic_ref<uint32_t>(*reinterpret_cast<uint32_t*>(Addr));
        uint32_t TmpResult = Atomic.load();

        // Zexts the result
        uint16_t Result = TmpResult >> (Alignment * 8);
        return Result;
      }
    }
  }
}

static uint32_t DoLoad32(uint64_t Addr) {
  uint64_t AlignmentMask = 0b1111;
  if ((Addr & AlignmentMask) > 12) {
    // Address crosses over 16byte threshold
    // Needs dual 32bit load
    uint64_t Alignment = Addr & 0b11;
    Addr &= ~0b11ULL;

    uint64_t AddrUpper = Addr + 4;

    // Careful ordering here
    uint32_t ActualUpper = LoadAcquire32(AddrUpper);
    uint32_t ActualLower = LoadAcquire32(Addr);

    uint64_t Result = ActualUpper;
    Result <<= 32;
    Result |= ActualLower;
    return Result >> (Alignment * 8);
  } else {
    AlignmentMask = 0b111;
    if ((Addr & AlignmentMask) >= 5) {
      // Crosses 8byte boundary
      // Needs 128bit load
      // Fits within a 16byte region
      uint64_t Alignment = Addr & 0b1111;
      Addr &= ~0b1111ULL;

      __uint128_t TmpResult = LoadAcquire128(Addr);

      return TmpResult >> (Alignment * 8);
    } else {
      // Fits within 8byte boundary
      // Only needs 64bit CAS
      // Alignments can be [1,5)
      uint64_t Alignment = Addr & AlignmentMask;
      Addr &= ~AlignmentMask;

      auto Atomic = std::atomic_ref<uint64_t>(*reinterpret_cast<uint64_t*>(Addr));
      uint64_t TmpResult = Atomic.load();

      return TmpResult >> (Alignment * 8);
    }
  }
}

static uint64_t DoLoad64(uint64_t Addr) {
  uint64_t AlignmentMask = 0b1111;
  if ((Addr & AlignmentMask) > 8) {
    uint64_t Alignment = Addr & 0b111;
    Addr &= ~0b111ULL;
    uint64_t AddrUpper = Addr + 8;

    // Crosses a 16byte boundary
    // Needs two 8 byte loads
    uint64_t ActualUpper {};
    uint64_t ActualLower {};
    // Careful ordering here
    ActualUpper = LoadAcquire64(AddrUpper);
    ActualLower = LoadAcquire64(Addr);

    __uint128_t Result = ActualUpper;
    Result <<= 64;
    Result |= ActualLower;
    return Result >> (Alignment * 8);
  } else {
    // Fits within a 16byte region
    uint64_t Alignment = Addr & AlignmentMask;
    Addr &= ~AlignmentMask;
    __uint128_t TmpResult = LoadAcquire128(Addr);
    uint64_t Result = TmpResult >> (Alignment * 8);
    return Result;
  }
}

static __uint128_t DoLoad128(uint64_t Addr) {
  // Any misalignment here means we cross a 16byte boundary
  // So we need two 128bit loads
  uint64_t Alignment = Addr & 0b1111;
  Addr &= ~0b1111ULL;
  uint64_t AddrUpper = Addr + 16;

  union AlignedData {
    struct {
      __uint128_t Lower;
      __uint128_t Upper;
    } Large;
    struct {
      uint8_t Data[32];
    } Bytes;
  };

  AlignedData* Data = reinterpret_cast<AlignedData*>(alloca(sizeof(AlignedData)));
  Data->Large.Upper = LoadAcquire128(AddrUpper);
  Data->Large.Lower = LoadAcquire128(Addr);

  __uint128_t Result {};
  memcpy(&Result, &Data->Bytes.Data[Alignment], sizeof(Result));
  return Result;
}

#ifdef FEX_IOS_HOST
/* iOS-Madeira ml275: route an emulated ATOMIC to the JIT pool's WRITABLE alias.
 *
 * Guest PE images are COPIED into the JIT pool so they can execute, and the copy
 * includes their .data. The pool's execute alias is mapped READ|EXECUTE with no write
 * bit, so a guest that atomically updates one of its own globals lands a STORE on a
 * non-writable page. Plain stores already survive this -- the Mach STR/STLR emulator
 * redirects RX-alias stores to the RW alias -- but the atomic helpers were never taught
 * the same trick, so they re-issue the CAS at the RX address and fault again inside
 * themselves. Measured in ml275 (webhelper thread, 60 consecutive faults, sole blocker
 * of that run):
 *   [atomic-mem] addr=0x15261beb0 JIT-POOL-RX (dual-mapped) pooloff=0x3621beb0
 *                region=0x152618000+0x4000 prot=5 max=7 share_mode=5 user_tag=0
 *   BUS: unhandled store insn=0x4866fe6a (CASPAL) x57, plus CAS 32/64 at the same addr
 * prot=5 is READ|EXECUTE -- no WRITE bit. The 0x80000002
 * (STATUS_DATATYPE_MISALIGNMENT) label was a red herring; the address is 16-byte
 * aligned. An exclusive store to a non-writable aliased page reports as SIGBUS.
 *
 * SELF-VALIDATING BY CONSTRUCTION: redirect only when the target is genuinely
 * non-writable AND target+WriteOffset genuinely IS writable. If either check fails the
 * address is returned untouched, so behaviour outside this exact situation cannot
 * change. Both aliases map the same physical memory, and ARM64 exclusive monitors track
 * physical addresses, so the atomic stays correct through either view. Cost is one
 * VirtualQuery on an already-faulted slow path, never on the fast path. */
/* ml656: ANONYMOUS JIT ALIASES ARE THE OTHER HALF OF THIS.
 *
 * The pool-bounds test below only knows the FIXED 896MB JIT pool. Anonymous
 * RX/RW aliases — Mono's, and Unity 2018's job-system arenas — live outside it,
 * so this returned the address untouched and the atomic was re-issued against
 * the non-writable RX view, faulting inside the recovery helper forever.
 *
 * Book of the Dead died exactly this way: a genuinely unaligned
 * `SWPAL x25,x25,[x6]` at ...0056 is correctly REFUSED by the Mach emulator (it
 * cannot be faked non-atomically), FEX's unaligned-atomic recovery takes over
 * and implements it with aligned CASPAL over the surrounding region, and those
 * CASPALs then hit the RX view — 1,999 identical redeliveries until the guard
 * killed the process.
 *
 * The table to consult already exists: every anonymous alias is published into
 * the generation-safe table added for the Mono bridge, so this is alias
 * COVERAGE, not new atomic machinery. Size is passed so the resolver can reject
 * an access that would straddle the end of an alias. */
extern "C" uint64_t IosMonoResolveRW(uint64_t GuestAddr, uint64_t Size);

static uint64_t IosAtomicWritableAlias(uint64_t Addr, uint64_t Size = 16) {
  const int64_t WriteOffset = FEXCore::DualMap::WriteOffset;
  if (!WriteOffset || !Addr) {
    return Addr;
  }

  /* ml276 CORRECTION: the first version used VirtualQuery to decide whether Addr was
   * writable. That CANNOT work here -- VirtualQuery reports WINE's view, and Wine has no
   * view of the JIT pool at all (pool addresses come back MEM_RESERVE/PAGE_NOACCESS with
   * AllocationBase=0). So the `State != MEM_COMMIT` guard bailed on the very first check
   * every single time: [atomic-alias] logged 0 and the fault counts were byte-identical
   * to the previous run (60/60/10). Same trap that made [guest-rip] report
   * "NOT COMMITTED" for pool addresses.
   *
   * Use the pool bounds instead, from the SAME env vars ProcessInit uses to compute
   * WriteOffset (WINE_IOS_JIT_RX / WINE_IOS_JIT_SIZE, published by ContentView.swift and
   * forwarded because they are WINE-prefixed). Read once. */
  static uint64_t RxBase = 0;
  static uint64_t RxSize = 0;
  static bool Probed = false;
  if (!Probed) {
    Probed = true;
    const char* RxEnv = getenv("WINE_IOS_JIT_RX");
    const char* SzEnv = getenv("WINE_IOS_JIT_SIZE");
    RxBase = RxEnv ? strtoull(RxEnv, nullptr, 16) : 0;
    RxSize = SzEnv ? strtoull(SzEnv, nullptr, 16) : 0;
  }
  /* ml656: not the fixed pool -> try the anonymous alias table before giving up. */
  if (!RxBase || !RxSize || Addr < RxBase || Addr >= RxBase + RxSize) {
    const uint64_t Rw = IosMonoResolveRW(Addr, Size ? Size : 16);
    if (Rw) {
      static unsigned n;
      if (n < 16) {
        LogMan::Msg::EFmt("[atomic-anon] ml656 #{} anon RX->RW {:#x} -> {:#x} size={} align={}", ++n, Addr, Rw,
                          Size, (Addr & (Size ? Size - 1 : 15)) == 0 ? "ok" : "UNALIGNED");
      }
      return Rw;
    }
    return Addr; // neither the pool nor a live anonymous alias -- leave it alone
  }

  /* Inside the pool's RX alias. The RW alias maps the same physical memory, and ARM64
   * exclusive monitors track physical addresses, so performing the atomic through the
   * writable view is equivalent and is the only view that can accept a store. */
  const uint64_t Alias = static_cast<uint64_t>(static_cast<int64_t>(Addr) + WriteOffset);
  static int reported = 0;
  if (reported++ < 8) {
    LogMan::Msg::EFmt("[atomic-alias] atomic on pool RX {:#x} (pooloff {:#x}) -> RW alias {:#x}", Addr,
                      Addr - RxBase, Alias);
  }
  return Alias;
}
#endif

static bool RunCASPAL(uint64_t* GPRs, uint32_t Size, uint32_t DesiredReg1, uint32_t DesiredReg2, uint32_t ExpectedReg1,
                      uint32_t ExpectedReg2, uint32_t AddressReg, uint32_t* StrictSplitLockMutex) {

  std::optional<FEXCore::Utils::SpinWaitLock::UniqueSpinMutex<uint32_t>> Lock {};
  if (Size == 0) {
    // 32bit
    uint64_t Addr = GPRs[AddressReg];
#ifdef FEX_IOS_HOST
    Addr = IosAtomicWritableAlias(Addr, Size);
#endif

    // Lower register must be even, so only upper register can be 31.
    uint32_t DesiredLower = GPRs[DesiredReg1];
    uint32_t DesiredUpper = DesiredReg2 == 31 ? 0 : GPRs[DesiredReg2];

    uint32_t ExpectedLower = GPRs[ExpectedReg1];
    uint32_t ExpectedUpper = ExpectedReg2 == 31 ? 0 : GPRs[ExpectedReg2];

    // Cross-cacheline CAS doesn't work on ARM
    // It isn't even guaranteed to work on x86
    // Intel will do a "split lock" which locks the full bus
    // AMD will tear instead
    // Both cross-cacheline and cross 16byte both need dual CAS loops that can tear
    // ARMv8.4 LSE2 solves all atomic issues except cross-cacheline

    // Check for Split lock across a cacheline
    if ((Addr & 63) > 56) {
      FEXCORE_TELEMETRY_SET(TYPE_HAS_SPLIT_LOCKS, 1);
      if (StrictSplitLockMutex && !Lock.has_value()) {
        Lock.emplace(StrictSplitLockMutex);
      }
    }

    uint64_t AlignmentMask = 0b1111;
    if ((Addr & AlignmentMask) > 8) {
      FEXCORE_TELEMETRY_SET(TYPE_16BYTE_SPLIT, 1);
      if (StrictSplitLockMutex && !Lock.has_value()) {
        Lock.emplace(StrictSplitLockMutex);
      }

      uint64_t Alignment = Addr & 0b111;
      Addr &= ~0b111ULL;
      uint64_t AddrUpper = Addr + 8;

      // Crosses a 16byte boundary
      // Need to do 256bit atomic, but since that doesn't exist we need to do a dual CAS loop
      __uint128_t Mask = ~0ULL;
      Mask <<= Alignment * 8;
      __uint128_t NegMask = ~Mask;
      __uint128_t TmpExpected {};
      __uint128_t TmpDesired {};

      __uint128_t Desired = DesiredUpper;
      Desired <<= 32;
      Desired |= DesiredLower;
      Desired <<= Alignment * 8;

      __uint128_t Expected = ExpectedUpper;
      Expected <<= 32;
      Expected |= ExpectedLower;
      Expected <<= Alignment * 8;

      while (1) {
        __uint128_t LoadOrderUpper = LoadAcquire64(AddrUpper);
        LoadOrderUpper <<= 64;
        __uint128_t TmpActual = LoadOrderUpper | LoadAcquire64(Addr);

        // Set up expected
        TmpExpected = TmpActual;
        TmpExpected &= NegMask;
        TmpExpected |= Expected;

        // Set up desired
        TmpDesired = TmpExpected;
        TmpDesired &= NegMask;
        TmpDesired |= Desired;

        uint64_t TmpExpectedLower = TmpExpected;
        uint64_t TmpExpectedUpper = TmpExpected >> 64;

        uint64_t TmpDesiredLower = TmpDesired;
        uint64_t TmpDesiredUpper = TmpDesired >> 64;

        if (TmpExpected == TmpActual) {
          if (StoreCAS64(TmpExpectedUpper, TmpDesiredUpper, AddrUpper)) {
            if (StoreCAS64(TmpExpectedLower, TmpDesiredLower, Addr)) {
              // Stored successfully
              return true;
            } else {
              // CAS managed to tear, we can't really solve this
              // Continue down the path to let the guest know values weren't expected
              FEXCORE_TELEMETRY_SET(TYPE_CAS_128BIT_TEAR, 1);
            }
          }

          TmpExpected = TmpExpectedUpper;
          TmpExpected <<= 64;
          TmpExpected |= TmpExpectedLower;
        } else {
          // Mismatch up front
          TmpExpected = TmpActual;
        }

        // Not successful
        // Now we need to check the results to see if we need to try again
        __uint128_t FailedResultOurBits = TmpExpected & Mask;
        __uint128_t FailedResultNotOurBits = TmpExpected & NegMask;

        __uint128_t FailedDesiredOurBits = TmpDesired & Mask;
        __uint128_t FailedDesiredNotOurBits = TmpDesired & NegMask;
        if ((FailedResultNotOurBits ^ FailedDesiredNotOurBits) != 0) {
          // If the bits changed that weren't part of our regular CAS then we need to try again
          continue;
        }
        if ((FailedResultOurBits ^ FailedDesiredOurBits) != 0) {
          // If the bits changed that we were wanting to change then we have failed and can return
          // We need to extract the bits and return them in EXPECTED
          uint64_t FailedResult = FailedResultOurBits >> (Alignment * 8);
          GPRs[ExpectedReg1] = FailedResult & ~0U;
          GPRs[ExpectedReg2] = FailedResult >> 32;
          return true;
        }

        // This happens in the case that between Load and CAS that something has store our desired in to the memory location
        // This means our CAS fails because what we wanted to store was already stored
        uint64_t FailedResult = FailedResultOurBits >> (Alignment * 8);
        GPRs[ExpectedReg1] = FailedResult & ~0U;
        GPRs[ExpectedReg2] = FailedResult >> 32;
        return true;
      }
    } else {
      // Fits within a 16byte region
      uint64_t Alignment = Addr & 0b1111;
      Addr &= ~0b1111ULL;
      auto Atomic128 = std::atomic_ref<__uint128_t>(*reinterpret_cast<__uint128_t*>(Addr));

      __uint128_t Mask = ~0ULL;
      Mask <<= Alignment * 8;
      __uint128_t NegMask = ~Mask;
      __uint128_t TmpExpected {};
      __uint128_t TmpDesired {};

      __uint128_t Desired = (uint64_t)DesiredUpper << 32 | DesiredLower;
      Desired <<= Alignment * 8;

      __uint128_t Expected = (uint64_t)ExpectedUpper << 32 | ExpectedLower;
      Expected <<= Alignment * 8;

      while (1) {
        TmpExpected = Atomic128.load();

        // Set up expected
        TmpExpected &= NegMask;
        TmpExpected |= Expected;

        // Set up desired
        TmpDesired = TmpExpected;
        TmpDesired &= NegMask;
        TmpDesired |= Desired;

        bool CASResult = Atomic128.compare_exchange_strong(TmpExpected, TmpDesired);
        if (CASResult) {
          // Successful, so we are done
          return true;
        } else {
          // Not successful
          // Now we need to check the results to see if we need to try again
          __uint128_t FailedResultOurBits = TmpExpected & Mask;
          __uint128_t FailedResultNotOurBits = TmpExpected & NegMask;

          __uint128_t FailedDesiredNotOurBits = TmpDesired & NegMask;
          if ((FailedResultNotOurBits ^ FailedDesiredNotOurBits) != 0) {
            // If the bits changed that weren't part of our regular CAS then we need to try again
            continue;
          }

          // This happens in the case that between Load and CAS that something has store our desired in to the memory location
          // This means our CAS fails because what we wanted to store was already stored
          uint64_t FailedResult = FailedResultOurBits >> (Alignment * 8);
          GPRs[ExpectedReg1] = FailedResult & ~0U;
          GPRs[ExpectedReg2] = FailedResult >> 32;
          return true;
        }
      }
    }
  } else if (Size == 1) {
    // 64-bit pairs -- a true 128-bit CAS, which is what x86 LOCK CMPXCHG16B lowers to.
    //
    // iOS-Madeira ml258: this branch did not exist, so every CASPAL with sz=1 fell
    // through to `return false`, which callers escalate to "Unhandled JIT SIGBUS
    // CASPAL" and a fatal STATUS_DATATYPE_MISALIGNMENT. That is what ends the Steam
    // run: CASPAL x6,x7, x4,x5, [x11] (Instruction 0x4866fd64), reported aligned
    // (misalign=0, crosses16B=no) -- so nothing exotic, simply unimplemented.
    uint64_t Addr = GPRs[AddressReg];
#ifdef FEX_IOS_HOST
    Addr = IosAtomicWritableAlias(Addr, Size);
#endif

    // Lower register must be even, so only the upper register can be 31.
    uint64_t DesiredLower = GPRs[DesiredReg1];
    uint64_t DesiredUpper = DesiredReg2 == 31 ? 0 : GPRs[DesiredReg2];

    uint64_t ExpectedLower = GPRs[ExpectedReg1];
    uint64_t ExpectedUpper = ExpectedReg2 == 31 ? 0 : GPRs[ExpectedReg2];

    if (Addr & 0b1111) {
      // CASP with 64-bit operands architecturally requires a 16-byte aligned address,
      // and the LOCK CMPXCHG16B it comes from #GPs on hardware when unaligned -- so a
      // correct guest cannot produce this. Emulating it would be inventing semantics
      // x86 does not have, so keep the existing behaviour and let the caller report it.
      return false;
    }

    // A 16-byte aligned 16-byte access can never cross a 64-byte cacheline
    // (16 divides 64), so the split-lock handling the Size==0 path needs
    // cannot apply here.
    auto Atomic128 = std::atomic_ref<__uint128_t>(*reinterpret_cast<__uint128_t*>(Addr));

    __uint128_t Desired = (static_cast<__uint128_t>(DesiredUpper) << 64) | DesiredLower;
    __uint128_t Expected = (static_cast<__uint128_t>(ExpectedUpper) << 64) | ExpectedLower;

    __uint128_t Tmp = Expected;
    if (Atomic128.compare_exchange_strong(Tmp, Desired)) {
      // Succeeded. CAS writes the loaded value back to the Rs pair, and on success
      // that value equals Expected, so the registers already hold it.
      return true;
    }

    // Failed: compare_exchange_strong left the observed value in Tmp, and CAS returns
    // it in the Rs pair so the guest can retry its loop.
    GPRs[ExpectedReg1] = static_cast<uint64_t>(Tmp);
    if (ExpectedReg2 != 31) {
      GPRs[ExpectedReg2] = static_cast<uint64_t>(Tmp >> 64);
    }
    return true;
  }
  return false;
}

/* iOS-Madeira ml220 PROBE. RunCASPAL implements ONLY Size==0 (32-bit pairs); Size==1
 * (64-bit pairs, i.e. a 128-bit CAS from x86 LOCK CMPXCHG16B) falls straight through to
 * `return false`, which callers report as "Unhandled JIT SIGBUS CASPAL" and escalate to a
 * fatal STATUS_DATATYPE_MISALIGNMENT. Steam/CEF hits this
 *   Unhandled JIT SIGBUS CASPAL: PC: 0x120e53c00 Instruction: 0x4866fd64
 *     = CASPAL x6,x7, x4,x5, [x11]   (sz=1)
 *
 * Implementing a 128-bit unaligned CAS is real work, so establish WHY the address is
 * unaligned first: a correct x86 program cannot issue an unaligned LOCK CMPXCHG16B (it
 * #GPs on hardware), so either the guest really does it -- and we must emulate -- or the
 * address we computed is wrong, which is a different bug entirely and would make the
 * emulation pointless. Print the address and its misalignment so the next run decides. */
static void IosLogUnimplementedCASPAL(uint32_t Size, uint64_t* GPRs, uint32_t AddressReg) {
  static int reports;

  /* ml258: Size==1 is IMPLEMENTED now (see RunCASPAL). The only case still handed
   * back to the caller is a misaligned CASP, which a correct guest cannot emit, so
   * report exactly that and stay quiet otherwise. */
  if (Size == 0 || (GPRs[AddressReg] & 15) == 0 || reports >= 8) {
    return;
  }
  reports++;

  /* ml223: the address came back 16-byte ALIGNED (misalign=0), so this is not the
   * unaligned-CAS case the Size==0 path exists for -- implementing a 128-bit unaligned
   * CAS would not have fixed it. An aligned LSE atomic that still faults points at the
   * MEMORY rather than the instruction, and the address sits inside the JIT pool's range,
   * which we DUAL-MAP (RW alias + RX alias). Aliased mappings are exactly where atomics
   * can fault despite correct alignment. Report what the region actually is, so "guest
   * data in a dual-mapped pool page" is distinguishable from ordinary private memory. */
#ifdef _WIN32
  MEMORY_BASIC_INFORMATION mbi {};
  const char* type = "?";
  if (VirtualQuery(reinterpret_cast<LPCVOID>(GPRs[AddressReg]), &mbi, sizeof(mbi))) {
    type = mbi.Type == MEM_IMAGE ? "MEM_IMAGE" : mbi.Type == MEM_MAPPED ? "MEM_MAPPED" : "MEM_PRIVATE";
  }
  LogMan::Msg::EFmt("[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} "
                    "crosses16B={} | region base={} size={:#x} prot={:#x} type={} state={:#x}",
                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,
                    (GPRs[AddressReg] & 15) ? "yes" : "no", mbi.BaseAddress, mbi.RegionSize,
                    mbi.Protect, type, mbi.State);
#else
  LogMan::Msg::EFmt("[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x}",
                    Size, AddressReg, GPRs[AddressReg]);
#endif
}

static bool HandleCASPAL(uint32_t Instr, uint64_t* GPRs, uint32_t* StrictSplitLockMutex) {
  uint32_t Size = (Instr >> 30) & 1;

  uint32_t DesiredReg1 = Instr & 0b11111;
  uint32_t DesiredReg2 = DesiredReg1 + 1;
  uint32_t ExpectedReg1 = (Instr >> 16) & 0b11111;
  uint32_t ExpectedReg2 = ExpectedReg1 + 1;
  uint32_t AddressReg = (Instr >> 5) & 0b11111;

  IosLogUnimplementedCASPAL(Size, GPRs, AddressReg);
  return RunCASPAL(GPRs, Size, DesiredReg1, DesiredReg2, ExpectedReg1, ExpectedReg2, AddressReg, StrictSplitLockMutex);
}

static uint64_t HandleCASPAL_ARMv8(uint32_t Instr, uintptr_t ProgramCounter, uint64_t* GPRs, uint32_t* StrictSplitLockMutex) {
  // caspair
  // [1] ldaxp(TMP2.W(), TMP3.W(), MemOperand(MemSrc)); <-- DataReg & AddrReg
  // [2] cmp(TMP2.W(), Expected.first.W()); <-- ExpectedReg1
  // [3] ccmp(TMP3.W(), Expected.second.W(), NoFlag, Condition::eq); <-- ExpectedREg2
  // [4] b(&LoopNotExpected, Condition::ne);
  // [5] stlxp(TMP2.W(), Desired.first.W(), Desired.second.W(), MemOperand(MemSrc)); <-- DesiredReg
  // [6] cbnz(TMP2.W(), &LoopTop);
  // [7] mov(Dst.first.W(), Expected.first.W());
  // [8] mov(Dst.second.W(), Expected.second.W());
  // [9] b(&LoopExpected);
  // [10] mov(Dst.first.W(), TMP2.W());
  // [11] mov(Dst.second.W(), TMP3.W());
  // [12] clrex();

  uint32_t* PC = (uint32_t*)ProgramCounter;

  uint32_t Size = (Instr >> 30) & 1;
  uint32_t AddrReg = (Instr >> 5) & 0x1F;
  uint32_t DataReg = Instr & 0x1F;
  uint32_t DataReg2 = (Instr >> 10) & 0x1F;

  uint32_t ExpectedReg1 {};
  uint32_t ExpectedReg2 {};

  uint32_t DesiredReg1 {};
  uint32_t DesiredReg2 {};

  if (Size == 1) {
    // 64-bit pair happens on paranoid vector loads
    // [1] ldaxp(TMP1, TMP2, MemSrc);
    // [2] clrex();
    //
    // 64-bit pair happens on paranoid vector stores
    // [1] ldaxp(xzr, TMP3, MemSrc); // <- Can hit SIGBUS
    // [2] stlxp(TMP3, TMP1, TMP2, MemSrc); // <- Can also hit SIGBUS
    // [3] cbnz(TMP3, &B); // < Overwritten with DMB

    if (DataReg == 31) {
    } else {
      uint32_t NextInstr = PC[1];
      if ((NextInstr & ArchHelpers::Arm64::CLREX_MASK) == ArchHelpers::Arm64::CLREX_INST) {
        uint64_t Addr = GPRs[AddrReg];

        auto Res = DoLoad128(Addr);
        // We set the result register if it isn't a zero register
        if (DataReg != 31) {
          GPRs[DataReg] = Res;
        }
        if (DataReg2 != 31) {
          GPRs[DataReg2] = Res >> 64;
        }

        // Skip ldaxp and clrex
        return 2 * sizeof(uint32_t);
      }
    }
    return 0;
  }

  // Only 32-bit pairs
  for (int i = 1; i < 10; i++) {
    uint32_t NextInstr = PC[i];
    if ((NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::CMP_INST ||
        (NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::CMP_SHIFT_INST) {
      ExpectedReg1 = GetRmReg(NextInstr);
    } else if ((NextInstr & ArchHelpers::Arm64::CCMP_MASK) == ArchHelpers::Arm64::CCMP_INST) {
      ExpectedReg2 = GetRmReg(NextInstr);
    } else if ((NextInstr & ArchHelpers::Arm64::STLXP_MASK) == ArchHelpers::Arm64::STLXP_INST) {
      DesiredReg1 = (NextInstr & 0x1F);
      DesiredReg2 = (NextInstr >> 10) & 0x1F;
    }
  }

  // mov expected into the temp registers used by JIT
  GPRs[DataReg] = GPRs[ExpectedReg1];
  GPRs[DataReg2] = GPRs[ExpectedReg2];

  if (RunCASPAL(GPRs, Size, DesiredReg1, DesiredReg2, DataReg, DataReg2, AddrReg, StrictSplitLockMutex)) {
    return 9 * sizeof(uint32_t); // skip to mov + clrex
  } else {
    return 0;
  }
}

template<typename T>
using CASExpectedFn = T (*)(T Src, T Expected);
template<typename T>
using CASDesiredFn = T (*)(T Src, T Desired);

template<bool Retry>
static uint16_t DoCAS16(uint16_t DesiredSrc, uint16_t ExpectedSrc, uint64_t Addr, CASExpectedFn<uint16_t> ExpectedFunction,
                        CASDesiredFn<uint16_t> DesiredFunction, uint32_t* StrictSplitLockMutex) {
  std::optional<FEXCore::Utils::SpinWaitLock::UniqueSpinMutex<uint32_t>> Lock {};

  if ((Addr & 63) == 63) {
    FEXCORE_TELEMETRY_SET(TYPE_HAS_SPLIT_LOCKS, 1);
    if (StrictSplitLockMutex && !Lock.has_value()) {
      Lock.emplace(StrictSplitLockMutex);
    }
  }

  // 16 bit
  uint64_t AlignmentMask = 0b1111;
  if ((Addr & AlignmentMask) == 15) {
    FEXCORE_TELEMETRY_SET(TYPE_16BYTE_SPLIT, 1);
    if (StrictSplitLockMutex && !Lock.has_value()) {
      Lock.emplace(StrictSplitLockMutex);
    }

    // Address crosses over 16byte or 64byte threshold
    // Need a dual 8bit CAS loop
    uint64_t AddrUpper = Addr + 1;

    while (1) {
      uint8_t ActualUpper {};
      uint8_t ActualLower {};
      // Careful ordering here
      ActualUpper = LoadAcquire8(AddrUpper);
      ActualLower = LoadAcquire8(Addr);

      uint16_t Actual = ActualUpper;
      Actual <<= 8;
      Actual |= ActualLower;

      uint16_t Desired = DesiredFunction(Actual, DesiredSrc);
      uint8_t DesiredLower = Desired;
      uint8_t DesiredUpper = Desired >> 8;

      uint16_t Expected = ExpectedFunction(Actual, ExpectedSrc);
      uint8_t ExpectedLower = Expected;
      uint8_t ExpectedUpper = Expected >> 8;

      bool Tear = false;
      if (ActualUpper == ExpectedUpper && ActualLower == ExpectedLower) {
        if (StoreCAS8(ExpectedUpper, DesiredUpper, AddrUpper)) {
          if (StoreCAS8(ExpectedLower, DesiredLower, Addr)) {
            // Stored successfully
            return Expected;
          } else {
            // CAS managed to tear, we can't really solve this
            // Continue down the path to let the guest know values weren't expected
            Tear = true;
            FEXCORE_TELEMETRY_SET(TYPE_CAS_16BIT_TEAR, 1);
          }
        }

        ActualLower = ExpectedLower;
      }

      // If the bits changed that we were wanting to change then we have failed and can return
      // We need to extract the bits and return them in EXPECTED
      uint16_t FailedResult = ActualUpper;
      FailedResult <<= 8;
      FailedResult |= ActualLower;

      if constexpr (Retry) {
        if (Tear) {
          // If we are retrying and tearing then we can't do anything here
          // XXX: Resolve with TME
          return FailedResult;
        } else {
          // We can retry safely
        }
      } else {
        // Without Retry (CAS) then we have failed regardless of tear
        // CAS failed but handled successfully
        return FailedResult;
      }
    }
  } else {
    AlignmentMask = 0b111;
    if ((Addr & AlignmentMask) == 7) {
      // Crosses 8byte boundary
      // Needs 128bit CAS
      // Fits within a 16byte region
      uint64_t Alignment = Addr & 0b1111;
      Addr &= ~0b1111ULL;
      auto Atomic128 = std::atomic_ref<__uint128_t>(*reinterpret_cast<__uint128_t*>(Addr));

      __uint128_t Mask = 0xFFFF;
      Mask <<= Alignment * 8;
      __uint128_t NegMask = ~Mask;
      __uint128_t TmpExpected {};
      __uint128_t TmpDesired {};

      while (1) {
        TmpExpected = Atomic128.load();

        __uint128_t Desired = DesiredFunction(TmpExpected >> (Alignment * 8), DesiredSrc);
        Desired <<= Alignment * 8;

        __uint128_t Expected = ExpectedFunction(TmpExpected >> (Alignment * 8), ExpectedSrc);
        Expected <<= Alignment * 8;

        // Set up expected
        TmpExpected &= NegMask;
        TmpExpected |= Expected;

        // Set up desired
        TmpDesired = TmpExpected;
        TmpDesired &= NegMask;
        TmpDesired |= Desired;

        bool CASResult = Atomic128.compare_exchange_strong(TmpExpected, TmpDesired);
        if (CASResult) {
          // Successful, so we are done
          return Expected >> (Alignment * 8);
        } else {
          if constexpr (Retry) {
            // If we failed but we have enabled retry then just retry without checking results
            // CAS can't retry but atomic memory ops need to retry until passing
            continue;
          }
          // Not successful
          // Now we need to check the results to see if we need to try again
          __uint128_t FailedResultOurBits = TmpExpected & Mask;
          __uint128_t FailedResultNotOurBits = TmpExpected & NegMask;

          __uint128_t FailedDesiredNotOurBits = TmpDesired & NegMask;
          if ((FailedResultNotOurBits ^ FailedDesiredNotOurBits) != 0) {
            // If the bits changed that weren't part of our regular CAS then we need to try again
            continue;
          }

          // This happens in the case that between Load and CAS that something has store our desired in to the memory location
          // This means our CAS fails because what we wanted to store was already stored
          uint16_t FailedResult = FailedResultOurBits >> (Alignment * 8);
          // CAS failed but handled successfully
          return FailedResult;
        }
      }
    } else {
      AlignmentMask = 0b11;
      if ((Addr & AlignmentMask) == 3) {
        // Crosses 4byte boundary
        // Needs 64bit CAS
        uint64_t Alignment = Addr & AlignmentMask;
        Addr &= ~AlignmentMask;

        uint64_t Mask = 0xFFFF;
        Mask <<= Alignment * 8;

        uint64_t NegMask = ~Mask;

        uint64_t TmpExpected {};
        uint64_t TmpDesired {};

        auto Atomic = std::atomic_ref<uint64_t>(*reinterpret_cast<uint64_t*>(Addr));
        while (1) {
          TmpExpected = Atomic.load();

          uint64_t Desired = DesiredFunction(TmpExpected >> (Alignment * 8), DesiredSrc);
          Desired <<= Alignment * 8;

          uint64_t Expected = ExpectedFunction(TmpExpected >> (Alignment * 8), ExpectedSrc);
          Expected <<= Alignment * 8;

          // Set up expected
          TmpExpected &= NegMask;
          TmpExpected |= Expected;

          // Set up desired
          TmpDesired = TmpExpected;
          TmpDesired &= NegMask;
          TmpDesired |= Desired;

          bool CASResult = Atomic.compare_exchange_strong(TmpExpected, TmpDesired);
          if (CASResult) {
            // Successful, so we are done
            return Expected >> (Alignment * 8);
          } else {
            if constexpr (Retry) {
              // If we failed but we have enabled retry then just retry without checking results
              // CAS can't retry but atomic memory ops need to retry until passing
              continue;
            }
            // Not successful
            // Now we need to check the results to see if we can try again
            uint64_t FailedResultOurBits = TmpExpected & Mask;
            uint64_t FailedResultNotOurBits = TmpExpected & NegMask;

            uint64_t FailedDesiredNotOurBits = TmpDesired & NegMask;

            if ((FailedResultNotOurBits ^ FailedDesiredNotOurBits) != 0) {
              // If the bits changed that weren't part of our regular CAS then we need to try again
              continue;
            }

            // This happens in the case that between Load and CAS that something has store our desired in to the memory location
            // This means our CAS fails because what we wanted to store was already stored
            uint16_t FailedResult = FailedResultOurBits >> (Alignment * 8);
            // CAS failed but handled successfully
            return FailedResult;
          }
        }
      } else {
        // Fits within 4byte boundary
        // Only needs 32bit CAS
        // Only alignment offset will be 1 here
        uint64_t Alignment = Addr & AlignmentMask;
        Addr &= ~AlignmentMask;

        uint32_t Mask = 0xFFFF;
        Mask <<= Alignment * 8;

        uint32_t NegMask = ~Mask;

        uint32_t TmpExpected {};
        uint32_t TmpDesired {};

        auto Atomic = std::atomic_ref<uint32_t>(*reinterpret_cast<uint32_t*>(Addr));
        while (1) {
          TmpExpected = Atomic.load();


          uint32_t Desired = DesiredFunction(TmpExpected >> (Alignment * 8), DesiredSrc);
          Desired <<= Alignment * 8;

          uint32_t Expected = ExpectedFunction(TmpExpected >> (Alignment * 8), ExpectedSrc);
          Expected <<= Alignment * 8;

          // Set up expected
          TmpExpected &= NegMask;
          TmpExpected |= Expected;

          // Set up desired
          TmpDesired = TmpExpected;
          TmpDesired &= NegMask;
          TmpDesired |= Desired;

          bool CASResult = Atomic.compare_exchange_strong(TmpExpected, TmpDesired);
          if (CASResult) {
            // Successful, so we are done
            return Expected >> (Alignment * 8);
          } else {
            if constexpr (Retry) {
              // If we failed but we have enabled retry then just retry without checking results
              // CAS can't retry but atomic memory ops need to retry until passing
              continue;
            }
            // Not successful
            // Now we need to check the results to see if we can try again
            uint32_t FailedResultOurBits = TmpExpected & Mask;
            uint32_t FailedResultNotOurBits = TmpExpected & NegMask;

            uint32_t FailedDesiredNotOurBits = TmpDesired & NegMask;

            if ((FailedResultNotOurBits ^ FailedDesiredNotOurBits) != 0) {
              // If the bits changed that weren't part of our regular CAS then we need to try again
              continue;
            }

            // This happens in the case that between Load and CAS that something has store our desired in to the memory location
            // This means our CAS fails because what we wanted to store was already stored
            uint16_t FailedResult = FailedResultOurBits >> (Alignment * 8);
            // CAS failed but handled successfully
            return FailedResult;
          }
        }
      }
    }
  }
}

template<bool Retry>
static uint32_t DoCAS32(uint32_t DesiredSrc, uint32_t ExpectedSrc, uint64_t Addr, CASExpectedFn<uint32_t> ExpectedFunction,
                        CASDesiredFn<uint32_t> DesiredFunction, uint32_t* StrictSplitLockMutex) {
  std::optional<FEXCore::Utils::SpinWaitLock::UniqueSpinMutex<uint32_t>> Lock {};

  if ((Addr & 63) > 60) {
    FEXCORE_TELEMETRY_SET(TYPE_HAS_SPLIT_LOCKS, 1);
    if (StrictSplitLockMutex && !Lock.has_value()) {
      Lock.emplace(StrictSplitLockMutex);
    }
  }

  // 32 bit
  uint64_t AlignmentMask = 0b1111;
  if ((Addr & AlignmentMask) > 12) {
    FEXCORE_TELEMETRY_SET(TYPE_16BYTE_SPLIT, 1);
    if (StrictSplitLockMutex && !Lock.has_value()) {
      Lock.emplace(StrictSplitLockMutex);
    }

    // Address crosses over 16byte threshold
    // Needs dual 4 byte CAS loop
    uint64_t Alignment = Addr & 0b11;
    Addr &= ~0b11;

    uint64_t AddrUpper = Addr + 4;

    uint64_t Mask = ~0U;
    Mask <<= Alignment * 8;
    uint64_t NegMask = ~Mask;

    // Careful ordering here
    while (1) {
      uint64_t LoadOrderUpper = LoadAcquire32(AddrUpper);
      LoadOrderUpper <<= 32;
      uint64_t TmpActual = LoadOrderUpper | LoadAcquire32(Addr);

      uint64_t Desired = DesiredFunction(TmpActual >> (Alignment * 8), DesiredSrc);
      uint64_t Expected = ExpectedFunction(TmpActual >> (Alignment * 8), ExpectedSrc);

      uint64_t TmpExpected = TmpActual;
      TmpExpected &= NegMask;
      TmpExpected |= Expected << (Alignment * 8);

      uint64_t TmpDesired = TmpExpected;
      TmpDesired &= NegMask;
      TmpDesired |= Desired << (Alignment * 8);

      bool Tear = false;
      if (TmpExpected == TmpActual) {
        uint32_t TmpExpectedLower = TmpExpected;
        uint32_t TmpExpectedUpper = TmpExpected >> 32;

        uint32_t TmpDesiredLower = TmpDesired;
        uint32_t TmpDesiredUpper = TmpDesired >> 32;

        if (StoreCAS32(TmpExpectedUpper, TmpDesiredUpper, AddrUpper)) {
          if (StoreCAS32(TmpExpectedLower, TmpDesiredLower, Addr)) {
            // Stored successfully
            return Expected;
          } else {
            // CAS managed to tear, we can't really solve this
            // Continue down the path to let the guest know values weren't expected
            Tear = true;
            FEXCORE_TELEMETRY_SET(TYPE_CAS_32BIT_TEAR, 1);
          }
        }

        TmpExpected = TmpExpectedUpper;
        TmpExpected <<= 32;
        TmpExpected |= TmpExpectedLower;
      } else {
        // Mismatch up front
        TmpExpected = TmpActual;
      }

      // Not successful
      // Now we need to check the results to see if we need to try again
      uint64_t FailedResultOurBits = TmpExpected & Mask;
      uint64_t FailedResultNotOurBits = TmpExpected & NegMask;

      uint64_t FailedDesiredNotOurBits = TmpDesired & NegMask;
      if ((FailedResultNotOurBits ^ FailedDesiredNotOurBits) != 0) {
        // If the bits changed that weren't part of our regular CAS then we need to try again
        continue;
      }

      // This happens in the case that between Load and CAS that something has store our desired in to the memory location
      // This means our CAS fails because what we wanted to store was already stored
      uint32_t FailedResult = FailedResultOurBits >> (Alignment * 8);

      if constexpr (Retry) {
        if (Tear) {
          // If we are retrying and tearing then we can't do anything here
          // XXX: Resolve with TME
          return FailedResult;
        } else {
          // We can retry safely
        }
      } else {
        // Without Retry (CAS) then we have failed regardless of tear
        // CAS failed but handled successfully
        return FailedResult;
      }
    }
  } else {
    AlignmentMask = 0b111;
    if ((Addr & AlignmentMask) >= 5) {
      // Crosses 8byte boundary
      // Needs 128bit CAS
      // Fits within a 16byte region
      uint64_t Alignment = Addr & 0b1111;
      Addr &= ~0b1111ULL;
      auto Atomic128 = std::atomic_ref<__uint128_t>(*reinterpret_cast<__uint128_t*>(Addr));

      __uint128_t Mask = ~0U;
      Mask <<= Alignment * 8;
      __uint128_t NegMask = ~Mask;
      __uint128_t TmpExpected {};
      __uint128_t TmpDesired {};

      while (1) {
        __uint128_t TmpActual = Atomic128.load();

        __uint128_t Desired = DesiredFunction(TmpActual >> (Alignment * 8), DesiredSrc);
        __uint128_t Expected = ExpectedFunction(TmpActual >> (Alignment * 8), ExpectedSrc);

        // Set up expected
        TmpExpected = TmpActual;
        TmpExpected &= NegMask;
        TmpExpected |= Expected << (Alignment * 8);

        // Set up desired
        TmpDesired = TmpExpected;
        TmpDesired &= NegMask;
        TmpDesired |= Desired << (Alignment * 8);

        bool CASResult = Atomic128.compare_exchange_strong(TmpExpected, TmpDesired);
        if (CASResult) {
          // Stored successfully
          return Expected;
        } else {
          if constexpr (Retry) {
            // If we failed but we have enabled retry then just retry without checking results
            // CAS can't retry but atomic memory ops need to retry until passing
            continue;
          }

          // Not successful
          // Now we need to check the results to see if we need to try again
          __uint128_t FailedResultOurBits = TmpExpected & Mask;
          __uint128_t FailedResultNotOurBits = TmpExpected & NegMask;

          __uint128_t FailedDesiredNotOurBits = TmpDesired & NegMask;
          if ((FailedResultNotOurBits ^ FailedDesiredNotOurBits) != 0) {
            // If the bits changed that weren't part of our regular CAS then we need to try again
            continue;
          }

          // This happens in the case that between Load and CAS that something has store our desired in to the memory location
          // This means our CAS fails because what we wanted to store was already stored
          uint32_t FailedResult = FailedResultOurBits >> (Alignment * 8);
          // CAS failed but handled successfully
          return FailedResult;
        }
      }
    } else {
      // Fits within 8byte boundary
      // Only needs 64bit CAS
      // Alignments can be [1,5)
      uint64_t Alignment = Addr & AlignmentMask;
      Addr &= ~AlignmentMask;

      uint64_t Mask = ~0U;
      Mask <<= Alignment * 8;

      uint64_t NegMask = ~Mask;

      uint64_t TmpExpected {};
      uint64_t TmpDesired {};

      auto Atomic = std::atomic_ref<uint64_t>(*reinterpret_cast<uint64_t*>(Addr));
      while (1) {
        uint64_t TmpActual = Atomic.load();

        uint64_t Desired = DesiredFunction(TmpActual >> (Alignment * 8), DesiredSrc);
        uint64_t Expected = ExpectedFunction(TmpActual >> (Alignment * 8), ExpectedSrc);

        // Set up expected
        TmpExpected = TmpActual;
        TmpExpected &= NegMask;
        TmpExpected |= Expected << (Alignment * 8);

        // Set up desired
        TmpDesired = TmpExpected;
        TmpDesired &= NegMask;
        TmpDesired |= Desired << (Alignment * 8);

        bool CASResult = Atomic.compare_exchange_strong(TmpExpected, TmpDesired);
        if (CASResult) {
          // Stored successfully
          return Expected;
        } else {
          if constexpr (Retry) {
            // If we failed but we have enabled retry then just retry without checking results
            // CAS can't retry but atomic memory ops need to retry until passing
            continue;
          }

          // Not successful
          // Now we need to check the results to see if we can try again
          uint64_t FailedResultOurBits = TmpExpected & Mask;
          uint64_t FailedResultNotOurBits = TmpExpected & NegMask;

          uint64_t FailedDesiredNotOurBits = TmpDesired & NegMask;

          if ((FailedResultNotOurBits ^ FailedDesiredNotOurBits) != 0) {
            // If the bits changed that weren't part of our regular CAS then we need to try again
            continue;
          }

          // This happens in the case that between Load and CAS that something has store our desired in to the memory location
          // This means our CAS fails because what we wanted to store was already stored
          uint32_t FailedResult = FailedResultOurBits >> (Alignment * 8);
          // CAS failed but handled successfully
          return FailedResult;
        }
      }
    }
  }
}

template<bool Retry>
static uint64_t DoCAS64(uint64_t DesiredSrc, uint64_t ExpectedSrc, uint64_t Addr, CASExpectedFn<uint64_t> ExpectedFunction,
                        CASDesiredFn<uint64_t> DesiredFunction, uint32_t* StrictSplitLockMutex) {
  std::optional<FEXCore::Utils::SpinWaitLock::UniqueSpinMutex<uint32_t>> Lock {};

  if ((Addr & 63) > 56) {
    FEXCORE_TELEMETRY_SET(TYPE_HAS_SPLIT_LOCKS, 1);
    if (StrictSplitLockMutex && !Lock.has_value()) {
      Lock.emplace(StrictSplitLockMutex);
    }
  }

  // 64bit
  uint64_t AlignmentMask = 0b1111;
  if ((Addr & AlignmentMask) > 8) {
    FEXCORE_TELEMETRY_SET(TYPE_16BYTE_SPLIT, 1);
    if (StrictSplitLockMutex && !Lock.has_value()) {
      Lock.emplace(StrictSplitLockMutex);
    }

    uint64_t Alignment = Addr & 0b111;
    Addr &= ~0b111ULL;
    uint64_t AddrUpper = Addr + 8;

    // Crosses a 16byte boundary
    // Need to do 256bit atomic, but since that doesn't exist we need to do a dual CAS loop
    __uint128_t Mask = ~0ULL;
    Mask <<= Alignment * 8;
    __uint128_t NegMask = ~Mask;
    __uint128_t TmpExpected {};
    __uint128_t TmpDesired {};

    while (1) {
      __uint128_t LoadOrderUpper = LoadAcquire64(AddrUpper);
      LoadOrderUpper <<= 64;
      __uint128_t TmpActual = LoadOrderUpper | LoadAcquire64(Addr);

      __uint128_t Desired = DesiredFunction(TmpActual >> (Alignment * 8), DesiredSrc);
      __uint128_t Expected = ExpectedFunction(TmpActual >> (Alignment * 8), ExpectedSrc);

      // Set up expected
      TmpExpected = TmpActual;
      TmpExpected &= NegMask;
      TmpExpected |= Expected << (Alignment * 8);

      // Set up desired
      TmpDesired = TmpExpected;
      TmpDesired &= NegMask;
      TmpDesired |= Desired << (Alignment * 8);

      uint64_t TmpExpectedLower = TmpExpected;
      uint64_t TmpExpectedUpper = TmpExpected >> 64;

      uint64_t TmpDesiredLower = TmpDesired;
      uint64_t TmpDesiredUpper = TmpDesired >> 64;

      bool Tear = false;
      if (TmpExpected == TmpActual) {
        if (StoreCAS64(TmpExpectedUpper, TmpDesiredUpper, AddrUpper)) {
          if (StoreCAS64(TmpExpectedLower, TmpDesiredLower, Addr)) {
            // Stored successfully
            return Expected;
          } else {
            // CAS managed to tear, we can't really solve this
            // Continue down the path to let the guest know values weren't expected
            Tear = true;
            FEXCORE_TELEMETRY_SET(TYPE_CAS_64BIT_TEAR, 1);
          }
        }

        TmpExpected = TmpExpectedUpper;
        TmpExpected <<= 64;
        TmpExpected |= TmpExpectedLower;
      } else {
        // Mismatch up front
        TmpExpected = TmpActual;
      }

      // Not successful
      // Now we need to check the results to see if we need to try again
      __uint128_t FailedResultOurBits = TmpExpected & Mask;
      __uint128_t FailedResultNotOurBits = TmpExpected & NegMask;

      __uint128_t FailedDesiredNotOurBits = TmpDesired & NegMask;
      if ((FailedResultNotOurBits ^ FailedDesiredNotOurBits) != 0) {
        // If the bits changed that weren't part of our regular CAS then we need to try again
        continue;
      }

      // This happens in the case that between Load and CAS that something has store our desired in to the memory location
      // This means our CAS fails because what we wanted to store was already stored
      uint64_t FailedResult = FailedResultOurBits >> (Alignment * 8);

      if constexpr (Retry) {
        if (Tear) {
          // If we are retrying and tearing then we can't do anything here
          // XXX: Resolve with TME
          return FailedResult;
        } else {
          // We can retry safely
        }
      } else {
        // Without Retry (CAS) then we have failed regardless of tear
        // CAS failed but handled successfully
        return FailedResult;
      }
    }
  } else {
    // Fits within a 16byte region
    uint64_t Alignment = Addr & AlignmentMask;
    Addr &= ~AlignmentMask;
    auto Atomic128 = std::atomic_ref<__uint128_t>(*reinterpret_cast<__uint128_t*>(Addr));

    __uint128_t Mask = ~0ULL;
    Mask <<= Alignment * 8;
    __uint128_t NegMask = ~Mask;
    __uint128_t TmpExpected {};
    __uint128_t TmpDesired {};

    while (1) {
      __uint128_t TmpActual = Atomic128.load();

      __uint128_t Desired = DesiredFunction(TmpActual >> (Alignment * 8), DesiredSrc);
      __uint128_t Expected = ExpectedFunction(TmpActual >> (Alignment * 8), ExpectedSrc);

      // Set up expected
      TmpExpected = TmpActual;
      TmpExpected &= NegMask;
      TmpExpected |= Expected << (Alignment * 8);

      // Set up desired
      TmpDesired = TmpExpected;
      TmpDesired &= NegMask;
      TmpDesired |= Desired << (Alignment * 8);

      bool CASResult = Atomic128.compare_exchange_strong(TmpExpected, TmpDesired);
      if (CASResult) {
        // Stored successfully
        return Expected;
      } else {
        if constexpr (Retry) {
          // If we failed but we have enabled retry then just retry without checking results
          // CAS can't retry but atomic memory ops need to retry until passing
          continue;
        }

        // Not successful
        // Now we need to check the results to see if we need to try again
        __uint128_t FailedResultOurBits = TmpExpected & Mask;
        __uint128_t FailedResultNotOurBits = TmpExpected & NegMask;

        __uint128_t FailedDesiredNotOurBits = TmpDesired & NegMask;
        if ((FailedResultNotOurBits ^ FailedDesiredNotOurBits) != 0) {
          // If the bits changed that weren't part of our regular CAS then we need to try again
          continue;
        }

        // This happens in the case that between Load and CAS that something has store our desired in to the memory location
        // This means our CAS fails because what we wanted to store was already stored
        uint64_t FailedResult = FailedResultOurBits >> (Alignment * 8);
        // CAS failed but handled successfully
        return FailedResult;
      }
    }
  }
}

static std::optional<uint64_t> DoCAS(uint32_t Size, uint64_t Desired, uint64_t Expected, uint64_t Addr, uint32_t* StrictSplitLockMutex) {
  // Cross-cacheline CAS doesn't work on ARM
  // It isn't even guaranteed to work on x86
  // Intel will do a "split lock" which locks the full bus
  // AMD will tear instead
  // Both cross-cacheline and cross 16byte both need dual CAS loops that can tear
  // ARMv8.4 LSE2 solves all atomic issues except cross-cacheline
  // ARM's TME extension solves the cross-cacheline problem

  // 8bit can't be unaligned
  // Only need to handle 16, 32, 64
  if (Size == 2) {
    auto Res = DoCAS16<false>(
      Desired, Expected, Addr,
      [](uint16_t, uint16_t Expected) -> uint16_t {
        // Expected is just Expected
        return Expected;
      },
      [](uint16_t, uint16_t Desired) -> uint16_t {
        // Desired is just Desired
        return Desired;
      },
      StrictSplitLockMutex);
    return Res;
  } else if (Size == 4) {
    auto Res = DoCAS32<false>(
      Desired, Expected, Addr,
      [](uint32_t, uint32_t Expected) -> uint32_t {
        // Expected is just Expected
        return Expected;
      },
      [](uint32_t, uint32_t Desired) -> uint32_t {
        // Desired is just Desired
        return Desired;
      },
      StrictSplitLockMutex);
    return Res;
  } else if (Size == 8) {
    auto Res = DoCAS64<false>(
      Desired, Expected, Addr,
      [](uint64_t, uint64_t Expected) -> uint64_t {
        // Expected is just Expected
        return Expected;
      },
      [](uint64_t, uint64_t Desired) -> uint64_t {
        // Desired is just Desired
        return Desired;
      },
      StrictSplitLockMutex);
    return Res;
  }

  return std::nullopt;
}

static bool RunCASAL(uint64_t* GPRs, uint32_t Size, uint32_t DesiredReg, uint32_t ExpectedReg, uint32_t AddressReg, uint32_t* StrictSplitLockMutex) {
  uint64_t Desired = DesiredReg == 31 ? 0 : GPRs[DesiredReg];
  uint64_t Expected = ExpectedReg == 31 ? 0 : GPRs[ExpectedReg];
#ifdef FEX_IOS_HOST
  std::optional<uint64_t> Res = DoCAS(Size, Desired, Expected, IosAtomicWritableAlias(GPRs[AddressReg], Size), StrictSplitLockMutex);
#else
  std::optional<uint64_t> Res = DoCAS(Size, Desired, Expected, GPRs[AddressReg], StrictSplitLockMutex);
#endif
  if (!Res.has_value()) {
    return false;
  }

  // Regardless of pass or fail
  // We set the result register if it isn't a zero register
  if (ExpectedReg != 31) {
    GPRs[ExpectedReg] = *Res;
  }
  return true;
}

static bool HandleCASAL(uint64_t* GPRs, uint32_t Instr, uint32_t* StrictSplitLockMutex) {
  uint32_t Size = 1 << (Instr >> 30);

  uint32_t DesiredReg = Instr & 0b11111;
  uint32_t ExpectedReg = (Instr >> 16) & 0b11111;
  uint32_t AddressReg = (Instr >> 5) & 0b11111;
  return RunCASAL(GPRs, Size, DesiredReg, ExpectedReg, AddressReg, StrictSplitLockMutex);
}

static bool HandleAtomicMemOp(uint32_t Instr, uint64_t* GPRs, uint32_t* StrictSplitLockMutex) {
  uint32_t Size = 1 << (Instr >> 30);
  uint32_t ResultReg = Instr & 0b11111;
  uint32_t SourceReg = (Instr >> 16) & 0b11111;
  uint32_t AddressReg = (Instr >> 5) & 0b11111;

  uint64_t Addr = GPRs[AddressReg];
#ifdef FEX_IOS_HOST
  Addr = IosAtomicWritableAlias(Addr, Size);   /* ml275/ml656: see IosAtomicWritableAlias */
#endif

  uint8_t Op = (Instr >> 12) & 0xF;

  uint64_t Source = SourceReg == 31 ? 0 : GPRs[SourceReg];

  if (Size == 2) {
    auto NOPExpected = [](uint16_t SrcVal, uint16_t) -> uint16_t {
      return SrcVal;
    };

    auto ADDDesired = [](uint16_t SrcVal, uint16_t Desired) -> uint16_t {
      return SrcVal + Desired;
    };

    auto CLRDesired = [](uint16_t SrcVal, uint16_t Desired) -> uint16_t {
      return SrcVal & ~Desired;
    };

    auto EORDesired = [](uint16_t SrcVal, uint16_t Desired) -> uint16_t {
      return SrcVal ^ Desired;
    };

    auto SETDesired = [](uint16_t SrcVal, uint16_t Desired) -> uint16_t {
      return SrcVal | Desired;
    };

    auto SWAPDesired = [](uint16_t SrcVal, uint16_t Desired) -> uint16_t {
      return Desired;
    };

    CASDesiredFn<uint16_t> DesiredFunction {};

    switch (Op) {
    case ATOMIC_ADD_OP: DesiredFunction = ADDDesired; break;
    case ATOMIC_CLR_OP: DesiredFunction = CLRDesired; break;
    case ATOMIC_EOR_OP: DesiredFunction = EORDesired; break;
    case ATOMIC_SET_OP: DesiredFunction = SETDesired; break;
    case ATOMIC_SWAP_OP: DesiredFunction = SWAPDesired; break;
    default: LogMan::Msg::EFmt("Unhandled JIT SIGBUS Atomic mem op 0x{:02x}", Op); return false;
    }

    auto Res = DoCAS16<true>(Source,
                             0, // Unused
                             Addr, NOPExpected, DesiredFunction, StrictSplitLockMutex);
    // If we passed and our destination register is not zero
    // Then we need to update the result register with what was in memory
    if (ResultReg != 31) {
      GPRs[ResultReg] = Res;
    }
    return true;
  } else if (Size == 4) {
    auto NOPExpected = [](uint32_t SrcVal, uint32_t) -> uint32_t {
      return SrcVal;
    };

    auto ADDDesired = [](uint32_t SrcVal, uint32_t Desired) -> uint32_t {
      return SrcVal + Desired;
    };

    auto CLRDesired = [](uint32_t SrcVal, uint32_t Desired) -> uint32_t {
      return SrcVal & ~Desired;
    };

    auto EORDesired = [](uint32_t SrcVal, uint32_t Desired) -> uint32_t {
      return SrcVal ^ Desired;
    };

    auto SETDesired = [](uint32_t SrcVal, uint32_t Desired) -> uint32_t {
      return SrcVal | Desired;
    };

    auto SWAPDesired = [](uint32_t SrcVal, uint32_t Desired) -> uint32_t {
      return Desired;
    };

    CASDesiredFn<uint32_t> DesiredFunction {};

    switch (Op) {
    case ATOMIC_ADD_OP: DesiredFunction = ADDDesired; break;
    case ATOMIC_CLR_OP: DesiredFunction = CLRDesired; break;
    case ATOMIC_EOR_OP: DesiredFunction = EORDesired; break;
    case ATOMIC_SET_OP: DesiredFunction = SETDesired; break;
    case ATOMIC_SWAP_OP: DesiredFunction = SWAPDesired; break;
    default: LogMan::Msg::EFmt("Unhandled JIT SIGBUS Atomic mem op 0x{:02x}", Op); return false;
    }

    auto Res = DoCAS32<true>(Source,
                             0, // Unused
                             Addr, NOPExpected, DesiredFunction, StrictSplitLockMutex);
    // If we passed and our destination register is not zero
    // Then we need to update the result register with what was in memory
    if (ResultReg != 31) {
      GPRs[ResultReg] = Res;
    }
    return true;
  } else if (Size == 8) {
    auto NOPExpected = [](uint64_t SrcVal, uint64_t) -> uint64_t {
      return SrcVal;
    };

    auto ADDDesired = [](uint64_t SrcVal, uint64_t Desired) -> uint64_t {
      return SrcVal + Desired;
    };

    auto CLRDesired = [](uint64_t SrcVal, uint64_t Desired) -> uint64_t {
      return SrcVal & ~Desired;
    };

    auto EORDesired = [](uint64_t SrcVal, uint64_t Desired) -> uint64_t {
      return SrcVal ^ Desired;
    };

    auto SETDesired = [](uint64_t SrcVal, uint64_t Desired) -> uint64_t {
      return SrcVal | Desired;
    };

    auto SWAPDesired = [](uint64_t SrcVal, uint64_t Desired) -> uint64_t {
      return Desired;
    };

    CASDesiredFn<uint64_t> DesiredFunction {};

    switch (Op) {
    case ATOMIC_ADD_OP: DesiredFunction = ADDDesired; break;
    case ATOMIC_CLR_OP: DesiredFunction = CLRDesired; break;
    case ATOMIC_EOR_OP: DesiredFunction = EORDesired; break;
    case ATOMIC_SET_OP: DesiredFunction = SETDesired; break;
    case ATOMIC_SWAP_OP: DesiredFunction = SWAPDesired; break;
    default: LogMan::Msg::EFmt("Unhandled JIT SIGBUS Atomic mem op 0x{:02x}", Op); return false;
    }

    auto Res = DoCAS64<true>(Source,
                             0, // Unused
                             Addr, NOPExpected, DesiredFunction, StrictSplitLockMutex);
    // If we passed and our destination register is not zero
    // Then we need to update the result register with what was in memory
    if (ResultReg != 31) {
      GPRs[ResultReg] = Res;
    }
    return true;
  }

  return false;
}

static bool HandleAtomicLoad(uint32_t Instr, uint64_t* GPRs, int64_t Offset, Core::UnalignedExclusiveStore* Store = nullptr) {
  uint32_t Size = 1 << (Instr >> 30);

  uint32_t ResultReg = Instr & 0b11111;
  uint32_t AddressReg = (Instr >> 5) & 0b11111;

  uint64_t Addr = GPRs[AddressReg] + Offset;
  uint64_t Res;

  if (Size == 2) {
    Res = DoLoad16(Addr);
    // We set the result register if it isn't a zero register
    if (ResultReg != 31) {
      GPRs[ResultReg] = Res;
    }
  } else if (Size == 4) {
    Res = DoLoad32(Addr);
    // We set the result register if it isn't a zero register
    if (ResultReg != 31) {
      GPRs[ResultReg] = Res;
    }
  } else if (Size == 8) {
    Res = DoLoad64(Addr);
    // We set the result register if it isn't a zero register
    if (ResultReg != 31) {
      GPRs[ResultReg] = Res;
    }
  } else {
    return false;
  }

  if (Store) {
    Store->Addr = Addr;
    Store->Store = Res;
    Store->Size = Size;
  }
  return true;
}

static bool HandleAtomicStore(uint32_t Instr, uint64_t* GPRs, int64_t Offset, uint32_t* StrictSplitLockMutex) {
  uint32_t Size = 1 << (Instr >> 30);

  uint32_t DataReg = Instr & 0x1F;
  uint32_t AddressReg = (Instr >> 5) & 0b11111;

  uint64_t Addr = GPRs[AddressReg] + Offset;
#ifdef FEX_IOS_HOST
  Addr = IosAtomicWritableAlias(Addr, Size);   /* ml275/ml656 */
#endif

  constexpr bool DoRetry = false;
  uint64_t Data = DataReg == 31 ? 0 : GPRs[DataReg];

  if (Size == 2) {
    DoCAS16<DoRetry>(
      Data,
      0, // Unused
      Addr,
      [](uint16_t SrcVal, uint16_t) -> uint16_t {
        // Expected is just src
        return SrcVal;
      },
      [](uint16_t, uint16_t Desired) -> uint16_t {
        // Desired is just Desired
        return Desired;
      },
      StrictSplitLockMutex);
    return true;
  } else if (Size == 4) {
    DoCAS32<DoRetry>(
      Data,
      0, // Unused
      Addr,
      [](uint32_t SrcVal, uint32_t) -> uint32_t {
        // Expected is just src
        return SrcVal;
      },
      [](uint32_t, uint32_t Desired) -> uint32_t {
        // Desired is just Desired
        return Desired;
      },
      StrictSplitLockMutex);
    return true;
  } else if (Size == 8) {
    DoCAS64<DoRetry>(
      Data,
      0, // Unused
      Addr,
      [](uint64_t SrcVal, uint64_t) -> uint64_t {
        // Expected is just src
        return SrcVal;
      },
      [](uint64_t, uint64_t Desired) -> uint64_t {
        // Desired is just Desired
        return Desired;
      },
      StrictSplitLockMutex);
    return true;
  }

  return false;
}

static uint64_t HandleCAS_NoAtomics(uintptr_t ProgramCounter, uint64_t* GPRs, uint32_t* StrictSplitLockMutex) {
  // ARMv8.0 CAS
  // [1] ldaxrb(TMP2.W(), MemOperand(MemSrc))
  // [2] cmp (TMP2.W(), Expected.W())
  // [3] b
  // [4] stlxrb(TMP3.W(), Desired.W(), MemOperand(MemSrc)
  // [5] cbnz
  // [6] mov
  // [7] b
  // [8] mov (.., TMP2.W());
  // [9] clrex

  uint32_t* PC = (uint32_t*)ProgramCounter;
  uint32_t Instr = PC[0];
  uint32_t Size = 1 << (Instr >> 30);
  uint32_t AddressReg = GetRnReg(Instr);
  uint32_t ResultReg = GetRdReg(Instr); // TMP2
  uint32_t DesiredReg = 0;
  uint32_t ExpectedReg = 0;
  for (size_t i = 1; i < 6; ++i) {
    uint32_t NextInstr = PC[i];
    if ((NextInstr & ArchHelpers::Arm64::STLXR_MASK) == ArchHelpers::Arm64::STLXR_INST) {
#if defined(ASSERTIONS_ENABLED) && ASSERTIONS_ENABLED
      // Just double check that the memory destination matches
      const uint32_t StoreAddressReg = GetRnReg(NextInstr);
      LOGMAN_THROW_A_FMT(StoreAddressReg == AddressReg, "StoreExclusive memory register didn't match the store exclusive register");
#endif
      DesiredReg = GetRdReg(NextInstr);
    } else if ((NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::CMP_INST ||
               (NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::CMP_SHIFT_INST) {
      ExpectedReg = GetRmReg(NextInstr);
    }
  }
  // set up CASAL by doing mov(TMP2, Expected)
  GPRs[ResultReg] = GPRs[ExpectedReg];

  if (RunCASAL(GPRs, Size, DesiredReg, ResultReg, AddressReg, StrictSplitLockMutex)) {
    return 7 * sizeof(uint32_t); // jump to mov to allocated register
  } else {
    return 0;
  }
}

static uint64_t HandleAtomicLoadstoreExclusive(uintptr_t ProgramCounter, uint64_t* GPRs, uint32_t* StrictSplitLockMutex) {
  uint32_t* PC = (uint32_t*)ProgramCounter;
  uint32_t Instr = PC[0];

  // Atomic Add
  // [1] ldaxrb(TMP2.W(), MemOperand(MemSrc));
  // [2] add(TMP2.W(), TMP2.W(), GetReg<RA_32>(Op->Header.Args[1].ID()));
  // [3] stlxrb(TMP2.W(), TMP2.W(), MemOperand(MemSrc));
  // [4] cbnz(TMP2.W(), &LoopTop);
  //
  // Atomic Fetch Add
  // [1] ldaxrb(TMP2.W(), MemOperand(MemSrc));
  // [2] add(TMP3.W(), TMP2.W(), GetReg<RA_32>(Op->Header.Args[1].ID()));
  // [3] stlxrb(TMP4.W(), TMP3.W(), MemOperand(MemSrc));
  // [4] cbnz(TMP4.W(), &LoopTop);
  // [5] mov(GetReg<RA_32>(Node), TMP2.W());
  //
  // Atomic Swap
  //
  // [1] ldaxrb(TMP2.W(), MemOperand(MemSrc));
  // [2] stlxrb(TMP4.W(), GetReg<RA_32>(Op->Header.Args[1].ID()), MemOperand(MemSrc));
  // [3] cbnz(TMP4.W(), &LoopTop);
  // [4] uxtb(GetReg<RA_64>(Node), TMP2.W());
  //
  // ASSUMPTIONS:
  // - Both cases:
  //   - The [2]ALU op: (Non NEG case)
  //     - First source is from [1]ldaxr
  //     - Second source is incoming value
  //   - The [2]ALU op: (NEG case)
  //     - First source is zero register
  //     - The second source is the from [1]ldaxr
  //   - No ALU op: (SWAP case)
  //     - No DataSourceRegister
  //
  // - In Atomic case (non-fetch)
  //   - The [3]stlxr instruction status + memory register are the SAME register
  //
  // - In Atomic FETCH case
  //   - The [3]stlxr instruction's status + memory register are never the same register
  //   - The [5]mov instruction source is always the destination register from [1] ldaxr*
  uint32_t ResultReg = GetRdReg(Instr);
  uint32_t AddressReg = GetRnReg(Instr);
  uint64_t Addr = GPRs[AddressReg];
#ifdef FEX_IOS_HOST
  /* ml656: exclusives encode their width in bits 31:30 exactly as the atomic-store
   * path does; derive it rather than defaulting, so the alias bounds check is real. */
  Addr = IosAtomicWritableAlias(Addr, (uint64_t)1 << (Instr >> 30));
#endif

  size_t NumInstructionsToSkip = 0;

  // Are we an Atomic op or AtomicFetch?
  bool AtomicFetch = false;

  // This is the register that is the incoming source to the ALU operation
  // <DataResultReg> = <Load Exclusive Value> <Op> <DataSourceReg>
  // NEG case is special
  // <DataResultReg> = Zero <Sub> <Load Exclusive Value>
  // DataSourceRegister must always be the Rm register
  uint32_t DataSourceReg {};
  ExclusiveAtomicPairType AtomicOp {ExclusiveAtomicPairType::TYPE_SWAP};

  // Scan forward at most five instructions to find our instructions
  for (size_t i = 1; i < 6; ++i) {
    uint32_t NextInstr = PC[i];
    if ((NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::ADD_INST ||
        (NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::ADD_SHIFT_INST) {
      AtomicOp = ExclusiveAtomicPairType::TYPE_ADD;
      DataSourceReg = GetRmReg(NextInstr);
    } else if ((NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::SUB_INST ||
               (NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::SUB_SHIFT_INST) {
      uint32_t RnReg = GetRnReg(NextInstr);
      if (RnReg == REGISTER_MASK) {
        // Zero reg means neg
        AtomicOp = ExclusiveAtomicPairType::TYPE_NEG;
      } else {
        AtomicOp = ExclusiveAtomicPairType::TYPE_SUB;
      }
      DataSourceReg = GetRmReg(NextInstr);
    } else if ((NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::CMP_INST ||
               (NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::CMP_SHIFT_INST) {
      return HandleCAS_NoAtomics(ProgramCounter, GPRs, StrictSplitLockMutex); // ARMv8.0 CAS
    } else if ((NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::AND_INST) {
      AtomicOp = ExclusiveAtomicPairType::TYPE_AND;
      DataSourceReg = GetRmReg(NextInstr);
    } else if ((NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::BIC_INST) {
      AtomicOp = ExclusiveAtomicPairType::TYPE_BIC;
      DataSourceReg = GetRmReg(NextInstr);
    } else if ((NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::OR_INST) {
      AtomicOp = ExclusiveAtomicPairType::TYPE_OR;
      DataSourceReg = GetRmReg(NextInstr);
    } else if ((NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::ORN_INST) {
      AtomicOp = ExclusiveAtomicPairType::TYPE_ORN;
      DataSourceReg = GetRmReg(NextInstr);
    } else if ((NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::EOR_INST) {
      AtomicOp = ExclusiveAtomicPairType::TYPE_EOR;
      DataSourceReg = GetRmReg(NextInstr);
    } else if ((NextInstr & ArchHelpers::Arm64::ALU_OP_MASK) == ArchHelpers::Arm64::EON_INST) {
      AtomicOp = ExclusiveAtomicPairType::TYPE_EON;
      DataSourceReg = GetRmReg(NextInstr);
    } else if ((NextInstr & ArchHelpers::Arm64::STLXR_MASK) == ArchHelpers::Arm64::STLXR_INST) {
#if defined(ASSERTIONS_ENABLED) && ASSERTIONS_ENABLED
      // Just double check that the memory destination matches
      const uint32_t StoreAddressReg = GetRnReg(NextInstr);
      LOGMAN_THROW_A_FMT(StoreAddressReg == AddressReg, "StoreExclusive memory register didn't match the store exclusive register");
#endif
      uint32_t StatusReg = GetRmReg(NextInstr);
      uint32_t StoreResultReg = GetRdReg(NextInstr);
      // We are an atomic fetch instruction if the data register isn't the status register
      AtomicFetch = !(StatusReg == StoreResultReg);
      if (AtomicOp == ExclusiveAtomicPairType::TYPE_SWAP) {
        // In the case of swap we don't have an ALU op inbetween
        // Source is directly in STLXR
        DataSourceReg = StoreResultReg;
      }
    } else if ((NextInstr & ArchHelpers::Arm64::CBNZ_MASK) == ArchHelpers::Arm64::CBNZ_INST) {
      // Found the CBNZ, we want to skip to just after this instruction when done
      NumInstructionsToSkip = i + 1;
      // This is the last instruction we care about. Leave now
      break;
    } else {
      LogMan::Msg::AFmt("Unknown instruction 0x{:08x}", NextInstr);
    }
  }

  uint32_t Size = 1 << (Instr >> 30);

  constexpr bool DoRetry = true;

  auto NOPExpected = []<typename AtomicType>(AtomicType SrcVal, AtomicType) -> AtomicType {
    return SrcVal;
  };

  auto ADDDesired = []<typename AtomicType>(AtomicType SrcVal, AtomicType Desired) -> AtomicType {
    return SrcVal + Desired;
  };

  auto SUBDesired = []<typename AtomicType>(AtomicType SrcVal, AtomicType Desired) -> AtomicType {
    return SrcVal - Desired;
  };

  auto ANDDesired = []<typename AtomicType>(AtomicType SrcVal, AtomicType Desired) -> AtomicType {
    return SrcVal & Desired;
  };

  auto BICDesired = []<typename AtomicType>(AtomicType SrcVal, AtomicType Desired) -> AtomicType {
    return SrcVal & ~Desired;
  };

  auto ORDesired = []<typename AtomicType>(AtomicType SrcVal, AtomicType Desired) -> AtomicType {
    return SrcVal | Desired;
  };

  auto ORNDesired = []<typename AtomicType>(AtomicType SrcVal, AtomicType Desired) -> AtomicType {
    return SrcVal | ~Desired;
  };

  auto EORDesired = []<typename AtomicType>(AtomicType SrcVal, AtomicType Desired) -> AtomicType {
    return SrcVal ^ Desired;
  };

  auto EONDesired = []<typename AtomicType>(AtomicType SrcVal, AtomicType Desired) -> AtomicType {
    return SrcVal ^ ~Desired;
  };

  auto NEGDesired = []<typename AtomicType>(AtomicType SrcVal, AtomicType Desired) -> AtomicType {
    return -SrcVal;
  };

  auto SWAPDesired = []<typename AtomicType>(AtomicType SrcVal, AtomicType Desired) -> AtomicType {
    return Desired;
  };

  uint64_t Source = DataSourceReg == 31 ? 0 : GPRs[DataSourceReg];
  if (Size == 2) {
    using AtomicType = uint16_t;
    CASDesiredFn<AtomicType> DesiredFunction {};

    switch (AtomicOp) {
    case ExclusiveAtomicPairType::TYPE_SWAP: DesiredFunction = SWAPDesired; break;
    case ExclusiveAtomicPairType::TYPE_ADD: DesiredFunction = ADDDesired; break;
    case ExclusiveAtomicPairType::TYPE_SUB: DesiredFunction = SUBDesired; break;
    case ExclusiveAtomicPairType::TYPE_AND: DesiredFunction = ANDDesired; break;
    case ExclusiveAtomicPairType::TYPE_BIC: DesiredFunction = BICDesired; break;
    case ExclusiveAtomicPairType::TYPE_OR: DesiredFunction = ORDesired; break;
    case ExclusiveAtomicPairType::TYPE_ORN: DesiredFunction = ORNDesired; break;
    case ExclusiveAtomicPairType::TYPE_EOR: DesiredFunction = EORDesired; break;
    case ExclusiveAtomicPairType::TYPE_EON: DesiredFunction = EONDesired; break;
    case ExclusiveAtomicPairType::TYPE_NEG: DesiredFunction = NEGDesired; break;
    default: LogMan::Msg::EFmt("Unhandled JIT SIGBUS Atomic mem op 0x{:02x}", FEXCore::ToUnderlying(AtomicOp)); return false;
    }

    auto Res = DoCAS16<DoRetry>(Source,
                                0, // Unused
                                Addr, NOPExpected, DesiredFunction, StrictSplitLockMutex);

    if (AtomicFetch && ResultReg != 31) {
      // On atomic fetch then we store the resulting value back in to the loadacquire destination register
      // We want the memory value BEFORE the ALU op
      GPRs[ResultReg] = Res;
    }
  } else if (Size == 4) {
    using AtomicType = uint32_t;
    CASDesiredFn<AtomicType> DesiredFunction {};

    switch (AtomicOp) {
    case ExclusiveAtomicPairType::TYPE_SWAP: DesiredFunction = SWAPDesired; break;
    case ExclusiveAtomicPairType::TYPE_ADD: DesiredFunction = ADDDesired; break;
    case ExclusiveAtomicPairType::TYPE_SUB: DesiredFunction = SUBDesired; break;
    case ExclusiveAtomicPairType::TYPE_AND: DesiredFunction = ANDDesired; break;
    case ExclusiveAtomicPairType::TYPE_BIC: DesiredFunction = BICDesired; break;
    case ExclusiveAtomicPairType::TYPE_OR: DesiredFunction = ORDesired; break;
    case ExclusiveAtomicPairType::TYPE_ORN: DesiredFunction = ORNDesired; break;
    case ExclusiveAtomicPairType::TYPE_EOR: DesiredFunction = EORDesired; break;
    case ExclusiveAtomicPairType::TYPE_EON: DesiredFunction = EONDesired; break;
    case ExclusiveAtomicPairType::TYPE_NEG: DesiredFunction = NEGDesired; break;
    default: LogMan::Msg::EFmt("Unhandled JIT SIGBUS Atomic mem op 0x{:02x}", FEXCore::ToUnderlying(AtomicOp)); return false;
    }

    auto Res = DoCAS32<DoRetry>(Source,
                                0, // Unused
                                Addr, NOPExpected, DesiredFunction, StrictSplitLockMutex);

    if (AtomicFetch && ResultReg != 31) {
      // On atomic fetch then we store the resulting value back in to the loadacquire destination register
      // We want the memory value BEFORE the ALU op
      GPRs[ResultReg] = Res;
    }
  } else if (Size == 8) {
    using AtomicType = uint64_t;
    CASDesiredFn<AtomicType> DesiredFunction {};

    switch (AtomicOp) {
    case ExclusiveAtomicPairType::TYPE_SWAP: DesiredFunction = SWAPDesired; break;
    case ExclusiveAtomicPairType::TYPE_ADD: DesiredFunction = ADDDesired; break;
    case ExclusiveAtomicPairType::TYPE_SUB: DesiredFunction = SUBDesired; break;
    case ExclusiveAtomicPairType::TYPE_AND: DesiredFunction = ANDDesired; break;
    case ExclusiveAtomicPairType::TYPE_BIC: DesiredFunction = BICDesired; break;
    case ExclusiveAtomicPairType::TYPE_OR: DesiredFunction = ORDesired; break;
    case ExclusiveAtomicPairType::TYPE_ORN: DesiredFunction = ORNDesired; break;
    case ExclusiveAtomicPairType::TYPE_EOR: DesiredFunction = EORDesired; break;
    case ExclusiveAtomicPairType::TYPE_EON: DesiredFunction = EONDesired; break;
    case ExclusiveAtomicPairType::TYPE_NEG: DesiredFunction = NEGDesired; break;
    default: LogMan::Msg::EFmt("Unhandled JIT SIGBUS Atomic mem op 0x{:02x}", FEXCore::ToUnderlying(AtomicOp)); return false;
    }

    auto Res = DoCAS64<DoRetry>(Source,
                                0, // Unused
                                Addr, NOPExpected, DesiredFunction, StrictSplitLockMutex);
    if (AtomicFetch && ResultReg != 31) {
      // On atomic fetch then we store the resulting value back in to the loadacquire destination register
      // We want the memory value BEFORE the ALU op
      GPRs[ResultReg] = Res;
    }
  }

  // Multiply by 4 for number of bytes to skip
  return NumInstructionsToSkip * 4;
}

[[nodiscard]]
std::optional<int32_t> HandleUnalignedAccess(FEXCore::Core::InternalThreadState* Thread, UnalignedHandlerType HandleType,
                                             uintptr_t ProgramCounter, uint64_t* GPRs, bool IsJIT) {
#ifdef ARCHITECTURE_arm64
  constexpr bool is_arm64 = true;
#else
  constexpr bool is_arm64 = false;
#endif

  if constexpr (!is_arm64) {
    return std::nullopt;
  }

  uint32_t* PC = (uint32_t*)ProgramCounter;
  uint32_t Instr = PC[0];

  // 1 = 16bit
  // 2 = 32bit
  // 3 = 64bit
  uint32_t Size = (Instr & 0xC000'0000) >> 30;
  uint32_t AddrReg = (Instr >> 5) & 0x1F;
  uint32_t DataReg = Instr & 0x1F;

  auto CTX = static_cast<Context::ContextImpl*>(Thread->CTX);
  uint32_t* StrictSplitLockMutex {CTX->Config.StrictInProcessSplitLocks ? &CTX->StrictSplitLockMutex : nullptr};

  if (!IsJIT) [[unlikely]] {
    if ((Instr & ArchHelpers::Arm64::CASPAL_MASK) == ArchHelpers::Arm64::CASPAL_INST) { // CASPAL
      if (ArchHelpers::Arm64::HandleCASPAL(Instr, GPRs, StrictSplitLockMutex)) {
        // Skip this instruction now
        return 4;
      } else {
        LogMan::Msg::EFmt("Unhandled JIT SIGBUS CASPAL: PC: 0x{:x} Instruction: 0x{:08x}\n", ProgramCounter, PC[0]);
        return std::nullopt;
      }
    } else if ((Instr & ArchHelpers::Arm64::CASAL_MASK) == ArchHelpers::Arm64::CASAL_INST) { // CASAL
      if (ArchHelpers::Arm64::HandleCASAL(GPRs, Instr, StrictSplitLockMutex)) {
        // Skip this instruction now
        return 4;
      } else {
        LogMan::Msg::EFmt("Unhandled JIT SIGBUS CASAL: PC: 0x{:x} Instruction: 0x{:08x}\n", ProgramCounter, PC[0]);
        return std::nullopt;
      }
    } else if ((Instr & LDAXR_MASK) == LDAR_INST ||  // LDAR*
               (Instr & LDAXR_MASK) == LDAPR_INST) { // LDAPR*
      if (ArchHelpers::Arm64::HandleAtomicLoad(Instr, GPRs, 0)) {
        // Skip this instruction now
        return 4;
      } else {
        LogMan::Msg::EFmt("Unhandled JIT SIGBUS LDAR*: PC: 0x{:x} Instruction: 0x{:08x}\n", ProgramCounter, PC[0]);
        return std::nullopt;
      }
    } else if ((Instr & LDAXR_MASK) == STLR_INST) { // STLR*
      if (ArchHelpers::Arm64::HandleAtomicStore(Instr, GPRs, 0, StrictSplitLockMutex)) {
        // Skip this instruction now
        return 4;
      } else {
        LogMan::Msg::EFmt("Unhandled JIT SIGBUS STLR*: PC: 0x{:x} Instruction: 0x{:08x}\n", ProgramCounter, PC[0]);
        return std::nullopt;
      }
    } else if ((Instr & RCPC2_MASK) == LDAPUR_INST) { // LDAPUR*
      // Extract the 9-bit offset from the instruction
      int32_t Offset = static_cast<int32_t>(Instr) << 11 >> 23;
      if (ArchHelpers::Arm64::HandleAtomicLoad(Instr, GPRs, Offset)) {
        // Skip this instruction now
        return 4;
      } else {
        LogMan::Msg::EFmt("Unhandled JIT SIGBUS LDAPUR*: PC: 0x{:x} Instruction: 0x{:08x}\n", ProgramCounter, PC[0]);
        return std::nullopt;
      }
    } else if ((Instr & RCPC2_MASK) == STLUR_INST) { // STLUR*
      // Extract the 9-bit offset from the instruction
      int32_t Offset = static_cast<int32_t>(Instr) << 11 >> 23;
      if (ArchHelpers::Arm64::HandleAtomicStore(Instr, GPRs, Offset, StrictSplitLockMutex)) {
        // Skip this instruction now
        return 4;
      } else {
        LogMan::Msg::EFmt("Unhandled JIT SIGBUS LDLUR*: PC: 0x{:x} Instruction: 0x{:08x}\n", ProgramCounter, PC[0]);
        return std::nullopt;
      }
    } else if ((Instr & ArchHelpers::Arm64::LDAXR_MASK) == ArchHelpers::Arm64::LDAXR_INST) { // LDAXR*
      if (ArchHelpers::Arm64::HandleAtomicLoad(Instr, GPRs, 0, &Thread->ExclusiveStore)) {
        return 4;
      }
    } else if ((Instr & ArchHelpers::Arm64::STLXR_MASK) == ArchHelpers::Arm64::STLXR_INST) { // STLXR*
      uint32_t StatusReg = Instr << 11 >> 27;
      // // Emulate exclusive store by validating the address and value against the last unaligned LDAXR*.
      uint32_t SizeBytes = 1u << Size;
      if (GPRs[AddrReg] != Thread->ExclusiveStore.Addr || SizeBytes > Thread->ExclusiveStore.Size) {
        if (StatusReg != 31) {
          GPRs[StatusReg] = 1;
        }
        return 4;
      }
      if (std::optional<uint64_t> Prev =
            DoCAS(SizeBytes, DataReg == 31 ? 0 : GPRs[DataReg], Thread->ExclusiveStore.Store, GPRs[AddrReg], StrictSplitLockMutex)) {
        if (StatusReg != 31) {
          GPRs[StatusReg] = !!memcmp(&Thread->ExclusiveStore.Store, &*Prev, SizeBytes);
        }
        Thread->ExclusiveStore.Size = 0;
        return 4;
      }
    } else if ((Instr & ArchHelpers::Arm64::ATOMIC_MEM_MASK) == ArchHelpers::Arm64::ATOMIC_MEM_INST) { // Atomic memory op
      if (ArchHelpers::Arm64::HandleAtomicMemOp(Instr, GPRs, StrictSplitLockMutex)) {
        // Skip this instruction now
        return 4;
      } else {
        uint8_t Op = (PC[0] >> 12) & 0xF;
        LogMan::Msg::EFmt("Unhandled JIT SIGBUS Atomic mem op 0x{:02x}: PC: 0x{:x} Instruction: 0x{:08x}\n", Op, ProgramCounter, PC[0]);
        return std::nullopt;
      }
    }

    LogMan::Msg::EFmt("Unhandled non-JIT atomic");
    return std::nullopt;
  }

  const auto Frame = Thread->CurrentFrame;
  const uint64_t BlockBegin = Frame->State.InlineJITBlockHeader;
  auto InlineHeader = reinterpret_cast<const CPU::CPUBackend::JITCodeHeader*>(BlockBegin);
  auto InlineTail = reinterpret_cast<CPU::CPUBackend::JITCodeTail*>(Frame->State.InlineJITBlockHeader + InlineHeader->OffsetToBlockTail);

  // Check some instructions first that don't do any backpatching.
  if ((Instr & ArchHelpers::Arm64::CASPAL_MASK) == ArchHelpers::Arm64::CASPAL_INST) { // CASPAL
    if (ArchHelpers::Arm64::HandleCASPAL(Instr, GPRs, StrictSplitLockMutex)) {
      // Skip this instruction now
      return 4;
    } else {
      LogMan::Msg::EFmt("Unhandled JIT SIGBUS CASPAL: PC: 0x{:x} Instruction: 0x{:08x}\n", ProgramCounter, PC[0]);
      return std::nullopt;
    }
  } else if ((Instr & ArchHelpers::Arm64::CASAL_MASK) == ArchHelpers::Arm64::CASAL_INST) { // CASAL
    if (ArchHelpers::Arm64::HandleCASAL(GPRs, Instr, StrictSplitLockMutex)) {
      // Skip this instruction now
      return 4;
    } else {
      LogMan::Msg::EFmt("Unhandled JIT SIGBUS CASAL: PC: 0x{:x} Instruction: 0x{:08x}\n", ProgramCounter, PC[0]);
      return std::nullopt;
    }
  } else if ((Instr & LDAXR_MASK) == LDAR_INST ||  // LDAR*
             (Instr & LDAXR_MASK) == LDAPR_INST || // LDAPR*
             (Instr & LDAXR_MASK) == STLR_INST) {  // STLR*
    // This must fall through to the spin-lock implementation below.
    // This mask has a partial overlap with ATOMIC_MEM_INST so we need to check this here.
  } else if ((Instr & ArchHelpers::Arm64::ATOMIC_MEM_MASK) == ArchHelpers::Arm64::ATOMIC_MEM_INST) { // Atomic memory op
    if (ArchHelpers::Arm64::HandleAtomicMemOp(Instr, GPRs, StrictSplitLockMutex)) {
      // Skip this instruction now
      return 4;
    } else {
      uint8_t Op = (PC[0] >> 12) & 0xF;
      LogMan::Msg::EFmt("Unhandled JIT SIGBUS Atomic mem op 0x{:02x}: PC: 0x{:x} Instruction: 0x{:08x}\n", Op, ProgramCounter, PC[0]);
      return std::nullopt;
    }
  } else if ((Instr & ArchHelpers::Arm64::LDAXR_MASK) == ArchHelpers::Arm64::LDAXR_INST) { // LDAXR*
    uint64_t BytesToSkip = ArchHelpers::Arm64::HandleAtomicLoadstoreExclusive(ProgramCounter, GPRs, StrictSplitLockMutex);
    if (BytesToSkip) {
      // Skip this instruction now
      return BytesToSkip;
    }
    // Explicit fallthrough to the backpatch handler below!
  } else if ((Instr & ArchHelpers::Arm64::LDAXP_MASK) == ArchHelpers::Arm64::LDAXP_INST) { // LDAXP
    // Should be compare and swap pair only. LDAXP not used elsewhere
    uint64_t BytesToSkip = ArchHelpers::Arm64::HandleCASPAL_ARMv8(Instr, ProgramCounter, GPRs, StrictSplitLockMutex);
    if (BytesToSkip) {
      // Skip this instruction now
      return BytesToSkip;
    } else {
      LogMan::Msg::EFmt("Unhandled JIT SIGBUS CASPAL: PC: 0x{:x} Instruction: 0x{:08x}\n", ProgramCounter, PC[0]);
      return std::nullopt;
    }
  }

  // Lock code mutex during any SIGBUS handling that potentially changes code.
  // Due to code buffer sharing between threads, code must be carefully backpatched from last to first.
  // Multiple threads can be attempting to handle the SIGBUS or even be executing the code being backpatched.
  // iOS-Madeira ml472 (#80): the lock word carries no owner and lives in the
  // code buffer; the holder's backpatch stores fault through the Mach RX-alias
  // emulator, so a holder that dies or is unwound there orphans the lock and
  // every later unaligned-atomic thread WFE-spun here forever (ml470/ml471
  // post-BrowserReady livelocks). Bounded acquire that stamps the holder's
  // thread identity into the word (waiters only ever test zero/nonzero); on
  // timeout, emulate this one access with the same helpers the !IsJIT path
  // uses and leave the code unpatched.
  uint32_t* BPFutex = &InlineTail->SpinLockFutex;
  const uint32_t BPStamp = 0x80000000u | (static_cast<uint32_t>(reinterpret_cast<uintptr_t>(Thread) >> 4) & 0x7FFFFFFFu);
  bool BPLocked = false;
  for (int Attempt = 0; Attempt < 8; ++Attempt) {
    uint32_t Expected = 0;
    if (std::atomic_ref<uint32_t>(*BPFutex).compare_exchange_strong(Expected, BPStamp)) {
      BPLocked = true;
      break;
    }
    // 8 x 25ms = ~200ms worst case before giving up on the lock.
    FEXCore::Utils::SpinWaitLock::Wait(BPFutex, static_cast<uint32_t>(0), std::chrono::milliseconds(25));
  }
  if (!BPLocked) {
    static std::atomic<uint32_t> BPTimeoutLogs {};
    if (BPTimeoutLogs.fetch_add(1) < 16) {
      LogMan::Msg::EFmt("[bp-lock] acquire TIMEOUT lock=0x{:x} val=0x{:x} me=0x{:x} pc=0x{:x} instr=0x{:08x} rev=ml472",
                        reinterpret_cast<uintptr_t>(BPFutex), std::atomic_ref<uint32_t>(*BPFutex).load(), BPStamp, ProgramCounter,
                        Instr);
    }
    if ((Instr & LDAXR_MASK) == LDAR_INST || (Instr & LDAXR_MASK) == LDAPR_INST) {
      if (ArchHelpers::Arm64::HandleAtomicLoad(Instr, GPRs, 0)) {
        return 4;
      }
    } else if ((Instr & LDAXR_MASK) == STLR_INST) {
      if (ArchHelpers::Arm64::HandleAtomicStore(Instr, GPRs, 0, StrictSplitLockMutex)) {
        return 4;
      }
    } else if ((Instr & RCPC2_MASK) == LDAPUR_INST) {
      int32_t Offset = static_cast<int32_t>(Instr) << 11 >> 23;
      if (ArchHelpers::Arm64::HandleAtomicLoad(Instr, GPRs, Offset)) {
        return 4;
      }
    } else if ((Instr & RCPC2_MASK) == STLUR_INST) {
      int32_t Offset = static_cast<int32_t>(Instr) << 11 >> 23;
      if (ArchHelpers::Arm64::HandleAtomicStore(Instr, GPRs, Offset, StrictSplitLockMutex)) {
        return 4;
      }
    }
    // Not an emulatable family. If the site no longer holds the faulting
    // instruction it was backpatched while we waited: re-execute it, running
    // the store barrier first when the patch was the DMB+STR form.
    auto Now = std::atomic_ref<uint32_t>(PC[0]).load(std::memory_order_acquire);
    if (Now != Instr) {
      if ((Now & LDSTREGISTER_MASK) == STR_INST || (Now & LDSTUNSCALED_MASK) == STUR_INST) {
        return -4;
      }
      return 0;
    }
    LogMan::Msg::EFmt("Unhandled JIT SIGBUS under bp-lock timeout: PC: 0x{:x} Instruction: 0x{:08x}\n", ProgramCounter, PC[0]);
    return std::nullopt;
  }
  FEXCore::Utils::SpinWaitLock::UniqueSpinMutex lk(BPFutex, FEXCore::Utils::SpinWaitLock::adopt_lock);

  if ((Instr & LDAXR_MASK) == LDAR_INST ||  // LDAR*
      (Instr & LDAXR_MASK) == LDAPR_INST) { // LDAPR*
    uint32_t LDR = LDR_INST;
    LDR |= Size << 30;
    LDR |= AddrReg << 5;
    LDR |= DataReg;
    if (HandleType != UnalignedHandlerType::NonAtomic) {
      // Ordering matters with cross-thread visibility!
      std::atomic_ref<uint32_t>(PC[1]).store(DMB_LD, std::memory_order_release); // Back-patch the half-barrier.
    }
    std::atomic_ref<uint32_t>(PC[0]).store(LDR, std::memory_order_release);
    ClearICache(&PC[0], 8);
    // With the instruction modified, now execute again.
    return 0;
  } else if ((Instr & LDAXR_MASK) == STLR_INST) { // STLR*
    uint32_t STR = STR_INST;
    STR |= Size << 30;
    STR |= AddrReg << 5;
    STR |= DataReg;
    if (HandleType != UnalignedHandlerType::NonAtomic) {
      std::atomic_ref<uint32_t>(PC[-1]).store(DMB, std::memory_order_release); // Back-patch the half-barrier.
    }
    std::atomic_ref<uint32_t>(PC[0]).store(STR, std::memory_order_release);
    ClearICache(&PC[-1], 8);
    // Back up one instruction and have another go
    return -4;
  } else if ((Instr & RCPC2_MASK) == LDAPUR_INST) { // LDAPUR*
    // Extract the 9-bit offset from the instruction
    uint32_t LDUR = LDUR_INST;
    LDUR |= Size << 30;
    LDUR |= AddrReg << 5;
    LDUR |= DataReg;
    LDUR |= Instr & (0b1'1111'1111 << 12);
    if (HandleType != UnalignedHandlerType::NonAtomic) {
      // Ordering matters with cross-thread visibility!
      std::atomic_ref<uint32_t>(PC[1]).store(DMB_LD, std::memory_order_release); // Back-patch the half-barrier.
    }
    std::atomic_ref<uint32_t>(PC[0]).store(LDUR, std::memory_order_release);
    ClearICache(&PC[0], 8);
    // With the instruction modified, now execute again.
    return 0;
  } else if ((Instr & RCPC2_MASK) == STLUR_INST) { // STLUR*
    uint32_t STUR = STUR_INST;
    STUR |= Size << 30;
    STUR |= AddrReg << 5;
    STUR |= DataReg;
    STUR |= Instr & (0b1'1111'1111 << 12);
    if (HandleType != UnalignedHandlerType::NonAtomic) {
      std::atomic_ref<uint32_t>(PC[-1]).store(DMB, std::memory_order_release); // Back-patch the half-barrier.
    }
    std::atomic_ref<uint32_t>(PC[0]).store(STUR, std::memory_order_release);

    ClearICache(&PC[-1], 8);
    // Back up one instruction and have another go
    return -4;
  }

  // Check if another thread backpatched this instruction before this thread got here
  // Since we got here, this can happen in a couple situations:
  // - Unhandled instruction (Shouldn't occur, FEX programmer error added a new unhandled atomic)
  // - Another thread backpatched an atomic access to be a non-atomic access
  auto AtomicInst = std::atomic_ref<uint32_t>(PC[0]).load(std::memory_order_acquire);
  if ((AtomicInst & LDSTREGISTER_MASK) == LDR_INST || (AtomicInst & LDSTUNSCALED_MASK) == LDUR_INST) {
    // This atomic instruction was backpatched to a load.
    if (HandleType != UnalignedHandlerType::NonAtomic) {
      // Check if the next instruction is a DMB.
      auto DMBInst = std::atomic_ref<uint32_t>(PC[1]).load(std::memory_order_acquire);
      if (DMBInst == DMB_LD) {
        return 0;
      }
    } else {
      // No DMB instruction with this HandleType.
      return 0;
    }
  } else if ((AtomicInst & LDSTREGISTER_MASK) == STR_INST || (AtomicInst & LDSTUNSCALED_MASK) == STUR_INST) {
    if (HandleType != UnalignedHandlerType::NonAtomic) {
      // Check if the previous instruction is a DMB.
      auto DMBInst = std::atomic_ref<uint32_t>(PC[-1]).load(std::memory_order_acquire);
      if (DMBInst == DMB) {
        // Return handled, make sure to adjust PC so we run the DMB.
        return -4;
      }
    } else {
      // No DMB instruction with this HandleType.
      return 0;
    }
  } else if (AtomicInst == DMB) {
    // ARMv8.0-a LDAXP backpatch handling. Will have turned in to the following:
    // - PC[0] = DMB
    // - PC[1] = STP
    // - PC[2] = DMB
    auto STPInst = std::atomic_ref<uint32_t>(PC[1]).load(std::memory_order_acquire);
    auto DMBInst = std::atomic_ref<uint32_t>(PC[2]).load(std::memory_order_acquire);
    if ((STPInst & LDSTP_MASK) == STP_INST && DMBInst == DMB) {
      // Code that was backpatched is what was expected for ARMv8.0-a LDAXP.
      return 0;
    }
  }

  LogMan::Msg::EFmt("Unhandled JIT SIGBUS: PC: 0x{:x} Instruction: 0x{:08x}\n", ProgramCounter, PC[0]);
  return std::nullopt;
}


} // namespace FEXCore::ArchHelpers::Arm64
