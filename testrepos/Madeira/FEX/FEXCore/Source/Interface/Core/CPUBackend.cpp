// SPDX-License-Identifier: MIT
#include "FEXCore/Config/Config.h"
#include "Interface/Context/Context.h"
#include "Interface/Core/CPUBackend.h"
#include "Interface/Core/LookupCache.h"
#include "Interface/Core/Dispatcher/Dispatcher.h"

#include <FEXCore/IR/IR.h>
#include <FEXCore/Utils/AllocatorHooks.h>
#include <FEXCore/Utils/PrctlUtils.h>

#include <cstdint>

#if defined(__linux__)
#include <linux/prctl.h>
#include <sys/prctl.h>
#endif

namespace FEXCore {
namespace CPU {

  static constexpr size_t INITIAL_CODE_SIZE = 1024 * 1024 * 16;
#ifdef FEX_IOS_HOST
  // iOS-Madeira ml437 (#74): the shared 896MB JIT pool's tail budget is ~188MB
  // for ALL threads' code buffers; hot threads doubling 16->32->64->128MB
  // exhausted it in ml436 (head 708MB of DLL copies + tail collided; 10 honest
  // refusals, 123 degraded threads). Cap growth at 32MB — hot threads clear
  // and recompile more often, but every thread gets a REAL buffer.
  static constexpr size_t MAX_CODE_SIZE = 1024 * 1024 * 32;
#else
  // We don't want to move above 128MB atm because that means we will have to encode longer jumps
  static constexpr size_t MAX_CODE_SIZE = 1024 * 1024 * 128;
#endif

  constexpr static uint64_t NamedVectorConstants[FEXCore::IR::NamedVectorConstant::NAMED_VECTOR_CONST_POOL_MAX][2] = {
    {0x0003'0002'0001'0000ULL, 0x0007'0006'0005'0004ULL}, // NAMED_VECTOR_INCREMENTAL_U16_INDEX
    {0x000B'000A'0009'0008ULL, 0x000F'000E'000D'000CULL}, // NAMED_VECTOR_INCREMENTAL_U16_INDEX_UPPER
    {0x0000'0000'8000'0000ULL, 0x0000'0000'8000'0000ULL}, // NAMED_VECTOR_PADDSUBPS_INVERT
    {0x0000'0000'8000'0000ULL, 0x0000'0000'8000'0000ULL}, // NAMED_VECTOR_PADDSUBPS_INVERT_UPPER
    {0x8000'0000'0000'0000ULL, 0x0000'0000'0000'0000ULL}, // NAMED_VECTOR_PADDSUBPD_INVERT
    {0x8000'0000'0000'0000ULL, 0x0000'0000'0000'0000ULL}, // NAMED_VECTOR_PADDSUBPD_INVERT_UPPER
    {0x8000'0000'0000'0000ULL, 0x8000'0000'0000'0000ULL}, // NAMED_VECTOR_PSUBADDPS_INVERT
    {0x8000'0000'0000'0000ULL, 0x8000'0000'0000'0000ULL}, // NAMED_VECTOR_PSUBADDPS_INVERT_UPPER
    {0x0000'0000'0000'0000ULL, 0x8000'0000'0000'0000ULL}, // NAMED_VECTOR_PSUBADDPD_INVERT
    {0x0000'0000'0000'0000ULL, 0x8000'0000'0000'0000ULL}, // NAMED_VECTOR_PSUBADDPD_INVERT_UPPER
    {0x0000'0001'0000'0000ULL, 0x0000'0003'0000'0002ULL}, // NAMED_VECTOR_MOVMSKPS_SHIFT
    {0x040B'0E01'0B0E'0104ULL, 0x0C03'0609'0306'090CULL}, // NAMED_VECTOR_AESKEYGENASSIST_SWIZZLE
    {0x0706'0504'FFFF'FFFFULL, 0xFFFF'FFFF'0B0A'0908ULL}, // NAMED_VECTOR_BLENDPS_0110B
    {0x0706'0504'0302'0100ULL, 0xFFFF'FFFF'0B0A'0908ULL}, // NAMED_VECTOR_BLENDPS_0111B
    {0xFFFF'FFFF'0302'0100ULL, 0x0F0E'0D0C'FFFF'FFFFULL}, // NAMED_VECTOR_BLENDPS_1001B
    {0x0706'0504'0302'0100ULL, 0x0F0E'0D0C'FFFF'FFFFULL}, // NAMED_VECTOR_BLENDPS_1011B
    {0xFFFF'FFFF'0302'0100ULL, 0x0F0E'0D0C'0B0A'0908ULL}, // NAMED_VECTOR_BLENDPS_1101B
    {0x0706'0504'FFFF'FFFFULL, 0x0F0E'0D0C'0B0A'0908ULL}, // NAMED_VECTOR_BLENDPS_1110B
    {0x8040'2010'0804'0201ULL, 0x8040'2010'0804'0201ULL}, // NAMED_VECTOR_MOVMASKB
    {0x8040'2010'0804'0201ULL, 0x8040'2010'0804'0201ULL}, // NAMED_VECTOR_MOVMASKB_UPPER
    {0x0706'0504'0302'0100ULL, 0x1716'1514'1312'1110ULL}, // NAMED_VECTOR_256_MID_ELEMENT_SWAP
    {0x0F0E'0D0C'0B0A'0908ULL, 0x1F1E'1D1C'1B1A'1918ULL}, // NAMED_VECTOR_256_MID_ELEMENT_SWAP_UPPER
    {0x8000'0000'0000'0000ULL, 0x0000'0000'0000'3FFFULL}, // NAMED_VECTOR_X87_ONE
    {0xD49A'784B'CD1B'8AFEULL, 0x0000'0000'0000'4000ULL}, // NAMED_VECTOR_X87_LOG2_10
    {0xB8AA'3B29'5C17'F0BCULL, 0x0000'0000'0000'3FFFULL}, // NAMED_VECTOR_X87_LOG2_E
    {0xC90F'DAA2'2168'C235ULL, 0x0000'0000'0000'4000ULL}, // NAMED_VECTOR_X87_PI
    {0x9A20'9A84'FBCF'F799ULL, 0x0000'0000'0000'3FFDULL}, // NAMED_VECTOR_X87_LOG10_2
    {0xB172'17F7'D1CF'79ACULL, 0x0000'0000'0000'3FFEULL}, // NAMED_VECTOR_X87_LOG_2
    {0x4F00'0000'4F00'0000ULL, 0x4F00'0000'4F00'0000ULL}, // NAMED_VECTOR_CVTMAX_F32_I32
    {0x4F00'0000'4F00'0000ULL, 0x4F00'0000'4F00'0000ULL}, // NAMED_VECTOR_CVTMAX_F32_I32_UPPER
    {0x5F00'0000'5F00'0000ULL, 0x5F00'0000'5F00'0000ULL}, // NAMED_VECTOR_CVTMAX_F32_I64
    {0x41E0'0000'0000'0000ULL, 0x41E0'0000'0000'0000ULL}, // NAMED_VECTOR_CVTMAX_F64_I32
    {0x41E0'0000'0000'0000ULL, 0x41E0'0000'0000'0000ULL}, // NAMED_VECTOR_CVTMAX_F64_I32_UPPER
    {0x43E0'0000'0000'0000ULL, 0x43E0'0000'0000'0000ULL}, // NAMED_VECTOR_CVTMAX_F64_I64
    {0x8000'0000'8000'0000ULL, 0x8000'0000'8000'0000ULL}, // NAMED_VECTOR_CVTMAX_I32
    {0x8000'0000'0000'0000ULL, 0x8000'0000'0000'0000ULL}, // NAMED_VECTOR_CVTMAX_I64
    {0x0000'0000'0000'0000ULL, 0x0000'0000'0000'8000ULL}, // NAMED_VECTOR_F80_SIGN_MASK
    {0x5A82'7999'5A82'7999ULL, 0x5A82'7999'5A82'7999ULL}, // NAMED_VECTOR_SHA1RNDS_K0
    {0x6ED9'EBA1'6ED9'EBA1ULL, 0x6ED9'EBA1'6ED9'EBA1ULL}, // NAMED_VECTOR_SHA1RNDS_K1
    {0x8F1B'BCDC'8F1B'BCDCULL, 0x8F1B'BCDC'8F1B'BCDCULL}, // NAMED_VECTOR_SHA1RNDS_K2
    {0xCA62'C1D6'CA62'C1D6ULL, 0xCA62'C1D6'CA62'C1D6ULL}, // NAMED_VECTOR_SHA1RNDS_K3
  };

  constexpr static auto PSHUFLW_LUT {[]() consteval {
    struct LUTType {
      uint64_t Val[2];
    };
    // Expectation for this LUT is to simulate PSHUFLW with ARM's TBL (single register) instruction
    // PSHUFLW behaviour:
    // 16-bit words in [63:48], [47:32], [31:16], [15:0] are selected using the 8-bit Index.
    // For 128-bit PSHUFLW, bits [127:64] are identity copied.
    constexpr uint64_t IdentityCopyUpper = 0x0f'0e'0d'0c'0b'0a'09'08;
    std::array<LUTType, 256> TotalLUT {};
    uint64_t WordSelection[4] = {
      0x01'00,
      0x03'02,
      0x05'04,
      0x07'06,
    };
    for (size_t i = 0; i < 256; ++i) {
      auto& LUT = TotalLUT[i];
      const auto Word0 = (i >> 0) & 0b11;
      const auto Word1 = (i >> 2) & 0b11;
      const auto Word2 = (i >> 4) & 0b11;
      const auto Word3 = (i >> 6) & 0b11;

      LUT.Val[0] = (WordSelection[Word0] << 0) | (WordSelection[Word1] << 16) | (WordSelection[Word2] << 32) | (WordSelection[Word3] << 48);

      LUT.Val[1] = IdentityCopyUpper;
    }
    return TotalLUT;
  }()};

  constexpr static auto PSHUFHW_LUT {[]() consteval {
    struct LUTType {
      uint64_t Val[2];
    };
    // Expectation for this LUT is to simulate PSHUFHW with ARM's TBL (single register) instruction
    // PSHUFHW behaviour:
    // 16-bit words in [127:112], [111:96], [95:80], [79:64] are selected using the 8-bit Index.
    // Incoming words come from bits [127:64] of the source.
    // Bits [63:0] are identity copied.
    constexpr uint64_t IdentityCopyLower = 0x07'06'05'04'03'02'01'00;
    std::array<LUTType, 256> TotalLUT {};
    uint64_t WordSelection[4] = {
      0x09'08,
      0x0b'0a,
      0x0d'0c,
      0x0f'0e,
    };
    for (size_t i = 0; i < 256; ++i) {
      auto& LUT = TotalLUT[i];
      const auto Word0 = (i >> 0) & 0b11;
      const auto Word1 = (i >> 2) & 0b11;
      const auto Word2 = (i >> 4) & 0b11;
      const auto Word3 = (i >> 6) & 0b11;

      LUT.Val[0] = IdentityCopyLower;

      LUT.Val[1] = (WordSelection[Word0] << 0) | (WordSelection[Word1] << 16) | (WordSelection[Word2] << 32) | (WordSelection[Word3] << 48);
    }
    return TotalLUT;
  }()};

  constexpr static auto PSHUFD_LUT {[]() consteval {
    struct LUTType {
      uint64_t Val[2];
    };
    // Expectation for this LUT is to simulate PSHUFD with ARM's TBL (single register) instruction
    // PSHUFD behaviour:
    // 32-bit words in [127:96], [95:64], [63:32], [31:0] are selected using the 8-bit Index.
    std::array<LUTType, 256> TotalLUT {};
    uint64_t WordSelection[4] = {
      0x03'02'01'00,
      0x07'06'05'04,
      0x0b'0a'09'08,
      0x0f'0e'0d'0c,
    };
    for (size_t i = 0; i < 256; ++i) {
      auto& LUT = TotalLUT[i];
      const auto Word0 = (i >> 0) & 0b11;
      const auto Word1 = (i >> 2) & 0b11;
      const auto Word2 = (i >> 4) & 0b11;
      const auto Word3 = (i >> 6) & 0b11;

      LUT.Val[0] = (WordSelection[Word0] << 0) | (WordSelection[Word1] << 32);

      LUT.Val[1] = (WordSelection[Word2] << 0) | (WordSelection[Word3] << 32);
    }
    return TotalLUT;
  }()};

  constexpr static auto SHUFPS_LUT {[]() consteval {
    struct LUTType {
      uint64_t Val[2];
    };
    // 32-bit words in [127:96], [95:64], [63:32], [31:0] are selected using the 8-bit Index.
    // Expectation for this LUT is to simulate SHUFPS with ARM's TBL (two register) instruction.
    // SHUFPS behaviour:
    // Two 32-bits words from each source are selected from each source in the lower and upper halves of the 128-bit destination.
    // Dest[31:0]   = Src1[<Word0>]
    // Dest[63:32]  = Src1[<Word1>]
    // Dest[95:64]  = Src2[<Word2>]
    // Dest[127:96] = Src2[<Word3>]

    std::array<LUTType, 256> TotalLUT {};
    const uint64_t WordSelectionSrc1[4] = {
      0x03'02'01'00,
      0x07'06'05'04,
      0x0b'0a'09'08,
      0x0f'0e'0d'0c,
    };

    // Src2 needs to offset each byte index by 16-bytes to pull from the second source.
    const uint64_t WordSelectionSrc2[4] = {
      0x03'02'01'00 + (0x10101010),
      0x07'06'05'04 + (0x10101010),
      0x0b'0a'09'08 + (0x10101010),
      0x0f'0e'0d'0c + (0x10101010),
    };

    for (size_t i = 0; i < 256; ++i) {
      auto& LUT = TotalLUT[i];
      const auto Word0 = (i >> 0) & 0b11;
      const auto Word1 = (i >> 2) & 0b11;
      const auto Word2 = (i >> 4) & 0b11;
      const auto Word3 = (i >> 6) & 0b11;

      LUT.Val[0] = (WordSelectionSrc1[Word0] << 0) | (WordSelectionSrc1[Word1] << 32);

      LUT.Val[1] = (WordSelectionSrc2[Word2] << 0) | (WordSelectionSrc2[Word3] << 32);
    }
    return TotalLUT;
  }()};

  constexpr static auto DPPS_MASK {[]() consteval {
    struct LUTType {
      uint32_t Val[4];
    };

    std::array<LUTType, 16> TotalLUT {};
    for (size_t i = 0; i < TotalLUT.size(); ++i) {
      auto& LUT = TotalLUT[i];
      constexpr auto GetLUT = [](size_t i, size_t Index) {
        if (i & (1U << Index)) {
          return -1U;
        }
        return 0U;
      };

      LUT.Val[0] = GetLUT(i, 0);
      LUT.Val[1] = GetLUT(i, 1);
      LUT.Val[2] = GetLUT(i, 2);
      LUT.Val[3] = GetLUT(i, 3);
    }
    return TotalLUT;
  }()};

  constexpr static auto DPPD_MASK {[]() consteval {
    struct LUTType {
      uint64_t Val[2];
    };

    std::array<LUTType, 4> TotalLUT {};
    for (size_t i = 0; i < TotalLUT.size(); ++i) {
      auto& LUT = TotalLUT[i];
      constexpr auto GetLUT = [](size_t i, size_t Index) {
        if (i & (1U << Index)) {
          return -1ULL;
        }
        return 0ULL;
      };

      LUT.Val[0] = GetLUT(i, 0);
      LUT.Val[1] = GetLUT(i, 1);
    }
    return TotalLUT;
  }()};

  constexpr static auto PBLENDW_LUT {[]() consteval {
    struct LUTType {
      uint16_t Val[8];
    };
    // 16-bit words in [127:112], [111:96], [95:80], [79:64], [63:48], [47:32], [31:16], [15:0] are selected using 8-bit swizzle.
    // Expectation for this LUT is to simulate PBLENDW with ARM's TBX (one register) instruction.
    // PBLENDW behaviour:
    // 16-bit words from the source is moved in to the destination based on the bit in the swizzle.
    // Dest[15:0]    = Swizzle[0] ? Src[15:0] : Dest[15:0]
    // Dest[31:16]   = Swizzle[1] ? Src[31:16] : Dest[31:16]
    // Dest[47:32]   = Swizzle[2] ? Src[47:32] : Dest[47:32]
    // Dest[63:48]   = Swizzle[3] ? Src[63:48] : Dest[63:48]
    // Dest[79:64]   = Swizzle[4] ? Src[79:64] : Dest[79:64]
    // Dest[95:80]   = Swizzle[5] ? Src[95:80] : Dest[95:80]
    // Dest[111:96]  = Swizzle[6] ? Src[111:96] : Dest[111:96]
    // Dest[127:112] = Swizzle[7] ? Src[127:112] : Dest[127:112]

    std::array<LUTType, 256> TotalLUT {};
    const uint16_t WordSelectionSrc[8] = {
      0x01'00, 0x03'02, 0x05'04, 0x07'06, 0x09'08, 0x0B'0A, 0x0D'0C, 0x0F'0E,
    };

    constexpr uint16_t OriginalDest = 0xFF'FF;

    for (size_t i = 0; i < 256; ++i) {
      auto& LUT = TotalLUT[i];
      for (size_t j = 0; j < 8; ++j) {
        LUT.Val[j] = ((i >> j) & 1) ? WordSelectionSrc[j] : OriginalDest;
      }
    }
    return TotalLUT;
  }()};

  CPUBackend::CPUBackend(CodeBufferManager& CodeBuffers, FEXCore::Core::InternalThreadState* ThreadState)
    : ThreadState(ThreadState)
    , CodeBuffers(CodeBuffers) {

    auto& Ptrs = ThreadState->CurrentFrame->Pointers;

    // Initialize named vector constants.
    for (size_t i = 0; i < FEXCore::IR::NamedVectorConstant::NAMED_VECTOR_CONST_POOL_MAX; ++i) {
      Ptrs.NamedVectorConstantPointers[i] = reinterpret_cast<uint64_t>(NamedVectorConstants[i]);
    }

    // Copy named vector constants.
    memcpy(Ptrs.NamedVectorConstants, NamedVectorConstants, sizeof(NamedVectorConstants));

    // Initialize Indexed named vector constants.
    Ptrs.IndexedNamedVectorConstantPointers[FEXCore::IR::IndexNamedVectorConstant::INDEXED_NAMED_VECTOR_PSHUFLW] =
      reinterpret_cast<uint64_t>(PSHUFLW_LUT.data());
    Ptrs.IndexedNamedVectorConstantPointers[FEXCore::IR::IndexNamedVectorConstant::INDEXED_NAMED_VECTOR_PSHUFHW] =
      reinterpret_cast<uint64_t>(PSHUFHW_LUT.data());
    Ptrs.IndexedNamedVectorConstantPointers[FEXCore::IR::IndexNamedVectorConstant::INDEXED_NAMED_VECTOR_PSHUFD] =
      reinterpret_cast<uint64_t>(PSHUFD_LUT.data());
    Ptrs.IndexedNamedVectorConstantPointers[FEXCore::IR::IndexNamedVectorConstant::INDEXED_NAMED_VECTOR_SHUFPS] =
      reinterpret_cast<uint64_t>(SHUFPS_LUT.data());
    Ptrs.IndexedNamedVectorConstantPointers[FEXCore::IR::IndexNamedVectorConstant::INDEXED_NAMED_VECTOR_DPPS_MASK] =
      reinterpret_cast<uint64_t>(DPPS_MASK.data());
    Ptrs.IndexedNamedVectorConstantPointers[FEXCore::IR::IndexNamedVectorConstant::INDEXED_NAMED_VECTOR_DPPD_MASK] =
      reinterpret_cast<uint64_t>(DPPD_MASK.data());
    Ptrs.IndexedNamedVectorConstantPointers[FEXCore::IR::IndexNamedVectorConstant::INDEXED_NAMED_VECTOR_PBLENDW] =
      reinterpret_cast<uint64_t>(PBLENDW_LUT.data());

#ifndef FEX_DISABLE_TELEMETRY
    // Fill in telemetry values
    for (size_t i = 0; i < FEXCore::Telemetry::TYPE_LAST; ++i) {
      auto& Telem = FEXCore::Telemetry::GetTelemetryValue(static_cast<FEXCore::Telemetry::TelemetryType>(i));
      Ptrs.TelemetryValueAddresses[i] = reinterpret_cast<uint64_t>(&Telem);
    }
#endif
  }

  CPUBackend::~CPUBackend() = default;

#ifdef FEX_IOS_HOST
  /* iOS-Madeira ml460 (#75): every C++ toucher of CurrentCodeBuffer /
   * SignalHandlerCodeBuffers holds this while the sweeper may run (see the
   * header comment). Plain test-and-set spin — all critical sections are a
   * few pointer ops. NOT recursive: RegisterForSignalHandler is only called
   * from already-guarded scopes and must not re-acquire. */
  namespace {
    struct IosMigrateLockGuard {
      std::atomic<uint32_t>& Lock;
      explicit IosMigrateLockGuard(std::atomic<uint32_t>& Lock)
        : Lock(Lock) {
        while (Lock.exchange(1, std::memory_order_acquire) != 0) {
          __asm volatile("yield");
        }
      }
      ~IosMigrateLockGuard() {
        Lock.store(0, std::memory_order_release);
      }
    };
  } // namespace
#endif

  auto CPUBackend::GetEmptyCodeBuffer() -> CodeBuffer* {
#ifdef FEX_IOS_HOST
    IosMigrateLockGuard g {IosMigrateLock};
#endif
    auto PrevCodeBuffer = CurrentCodeBuffer;

    // Resize the code buffer and reallocate our code size
    CurrentCodeBuffer = CodeBuffers.StartLargerCodeBuffer();

    RegisterForSignalHandler(std::move(PrevCodeBuffer));
    return CurrentCodeBuffer.get();
  }

  void CPUBackend::RegisterForSignalHandler(fextl::shared_ptr<CodeBuffer> CodeBuffer) {
    if (ThreadState->CurrentFrame->SignalHandlerRefCounter != 0) {
      // We have signal handlers that have generated code
      // This means that we can not safely clear the code at this point in time
      // Keep a reference to the old code buffer to delay deallocation
#ifdef FEX_IOS_HOST
      /* iOS-Madeira ml459 (#75): old code buffers are the pool's TAIL, and the
       * ml458 run ended with 12 carves (5 of them 32MB) but only ONE freed —
       * 214MB of a 896MB pool pinned while the head needed 1MB more. A buffer
       * lives until every strong ref drops; this vector is the one ref that can
       * grow without bound, because it is only ever cleared by a LATER swap on
       * a thread whose counter happens to be 0 by then. A thread that leaks a
       * non-zero SignalHandlerRefCounter therefore pins EVERY generation it
       * ever saw, forever. Name the pinner: tid, the counter that caused it,
       * and how deep this thread's pin list now is. */
      {
        static std::atomic<int> PinLogCount {0};
        uint64_t Teb = 0;
        __asm volatile("mov %0, x18" : "=r"(Teb));
        if (PinLogCount.fetch_add(1, std::memory_order_relaxed) < 40) {
          LogMan::Msg::EFmt("[pool-tail] PIN old CodeBuffer size=0x{:x} refcnt={} pinned_now={} tid={:#x} rev=ml459",
                            CodeBuffer ? CodeBuffer->AllocatedSize : 0, ThreadState->CurrentFrame->SignalHandlerRefCounter,
                            SignalHandlerCodeBuffers.size() + 1, Teb ? *reinterpret_cast<uint32_t*>(Teb + 0x48) : 0);
        }
      }
#endif
      SignalHandlerCodeBuffers.push_back(std::move(CodeBuffer));
    } else {
      SignalHandlerCodeBuffers.clear();
    }
  }

  fextl::shared_ptr<CodeBuffer> CPUBackend::CheckCodeBufferUpdate() {
    auto NewCodeBuffer = CodeBuffers.GetLatest();
#ifdef FEX_IOS_HOST
    IosMigrateLockGuard g {IosMigrateLock};
#endif
    if (CurrentCodeBuffer != NewCodeBuffer) {
      RegisterForSignalHandler(CurrentCodeBuffer);
      return std::exchange(CurrentCodeBuffer, NewCodeBuffer);
    }
    return nullptr;
  }

#ifdef FEX_IOS_HOST
  /* iOS-Madeira ml460 (#75): remote-migrate a PARKED thread off a stale
   * generation. Runs on the SWEEPER's thread; the caller has verified under
   * the Dekker gate that the owner is outside emitted code (InSimulation==0)
   * and cannot re-enter until the gate clears — so the owner cannot be inside
   * any of its own guarded sections, and the only contender for
   * IosMigrateLock is another C++ path on a third thread (exception-state
   * queries), which the spin lock serializes. Mirrors the self-migration in
   * JIT.cpp (CheckCodeBufferUpdate + ChangeGuestToHostMapping +
   * callret-entry wipe); KeepAlive must outlive the map write lock because
   * the lock lives INSIDE the CodeBuffer being dropped (the ClearCache
   * lesson: "Holding on to the reference here is required"). */
  int CPUBackend::IosRemoteMigrateStale(const fextl::shared_ptr<CodeBuffer>& LatestBuf) {
    for (int Attempt = 0; Attempt < 4; Attempt++) {
      fextl::shared_ptr<CodeBuffer> KeepAlive;
      {
        IosMigrateLockGuard g {IosMigrateLock};
        KeepAlive = CurrentCodeBuffer;
      }
      if (!KeepAlive || KeepAlive == LatestBuf) {
        return 0;
      }
      auto lk = KeepAlive->LookupCache->AcquireWriteLock();
      IosMigrateLockGuard g {IosMigrateLock};
      if (CurrentCodeBuffer != KeepAlive) {
        continue; // owner-side state moved between the peek and the locks; retry
      }
      if (ThreadState->CurrentFrame->SignalHandlerRefCounter != 0) {
        return -1; // interrupted JIT frames below this thread still reference old code
      }
      auto Prev = std::exchange(CurrentCodeBuffer, LatestBuf);
      ThreadState->LookupCache->ChangeGuestToHostMapping(*Prev, *LatestBuf->LookupCache, lk);
      // Stale callret predictions pair (guest RIP, host addr into Prev); wipe
      // the entries the same way the self-migration path does. SP itself
      // stays — zeroed entries just mispredict into the slow path.
      FEXCore::Core::ResetCallRetStack(ThreadState, "cpubackend");
      SignalHandlerCodeBuffers.clear();
      return 1;
      // Prev + KeepAlive drop after lk releases; the final ref frees the
      // buffer to the pool tail on this (the sweeper's) thread.
    }
    return -2;
  }
#endif

  GuestToHostMap& GetLookupCache(const CodeBuffer& Buffer) {
    return *Buffer.LookupCache;
  }

  CodeBuffer::CodeBuffer(size_t Size)
    : AllocatedSize(Size) {
    Ptr = static_cast<uint8_t*>(FEXCore::Allocator::VirtualAlloc(Size, true));
#ifdef FEX_IOS_HOST
    /* iOS-Madeira ml364: exec allocations come from the finite JIT pool, and
     * ml363 died exactly here — the pool was exhausted (bump 858/896MB,
     * freelist 0), VirtualAlloc returned garbage/NULL with LOGMAN_THROW
     * compiled out, and ClearCache scribbled the detection string through a
     * wild pointer on Chrome's GPU thread. Degrade before dying: halve the
     * request down to 1MB (freelist gaps often satisfy small carves), and if
     * even that fails force a fault at a recognizable address so the honest-
     * fault pipeline reports it instead of a random-looking wild write. */
    while (!Ptr && Size > 0x100000) {
      Size >>= 1;
      Ptr = static_cast<uint8_t*>(FEXCore::Allocator::VirtualAlloc(Size, true));
    }
    if (Ptr && Size != AllocatedSize) {
      LogMan::Msg::EFmt("[code-buffer] rev=ml364 exec alloc degraded 0x{:x} -> 0x{:x} (pool pressure)", AllocatedSize, Size);
      AllocatedSize = Size;
    }
    if (!Ptr) {
      LogMan::Msg::EFmt("[code-buffer] rev=ml364 EXEC ALLOC FAILED even at 0x{:x} — JIT pool exhausted; forcing honest fault at 0xdead", Size);
      *reinterpret_cast<volatile uint64_t*>(0xdeadULL) = Size;
    }
#endif
    LOGMAN_THROW_A_FMT(!!Ptr, "Couldn't allocate code buffer");

    // Protect the last page of the allocated buffer to trigger SIGSEGV on write access
    uintptr_t LastPageAddr = AlignDown(reinterpret_cast<uintptr_t>(Ptr) + Size - 1, FEXCore::Utils::FEX_PAGE_SIZE);
    if (!FEXCore::Allocator::VirtualProtect(reinterpret_cast<void*>(LastPageAddr), FEXCore::Utils::FEX_PAGE_SIZE,
                                            FEXCore::Allocator::ProtectOptions::None)) {
      LogMan::Msg::EFmt("Failed to mprotect last page of code buffer.");
    }

    FEXCore::Allocator::VirtualName("FEXMemJIT", reinterpret_cast<void*>(Ptr), Size);

    // Huge-pages reduce the amount of iTLB misses dramatically when it works.
    FEXCore::Allocator::VirtualTHPControl(reinterpret_cast<void*>(Ptr), Size, FEXCore::Allocator::THPControl::Enable);

    LookupCache = fextl::make_unique<GuestToHostMap>();
  }

  CodeBuffer::~CodeBuffer() {
    FEXCore::Allocator::VirtualFree(Ptr, AllocatedSize);
  }

#ifdef FEX_IOS_HOST
  /* ml460 (#75): process-wide generation counter; read by the deferred-sweep
   * trigger (Core.cpp) and the sweeper (Module.cpp) via IosCodeBufferGeneration. */
  std::atomic<uint64_t> IosCodeBufferGenCounter {0};
  uint64_t IosCodeBufferGeneration() {
    return IosCodeBufferGenCounter.load(std::memory_order_acquire);
  }
#endif

  auto CodeBufferManager::AllocateNew(size_t Size) -> fextl::shared_ptr<CodeBuffer> {
#if defined(__linux__)
// MDWE (Memory-Deny-Write-Execute) is a new Linux 6.3 feature.
// It's equivalent to systemd's `MemoryDenyWriteExecute` but implemented entirely in the kernel.
//
// MDWE prevents applications from creating RWX memory mappings.
// This prevents FEX from doing anything JIT related, as FEX uses RWX for JIT memory mappings.
//
// A potential workaround to make FEX work with MDWE is to call mprotect every time we need to write or modify code.
// Alternatively, FEX could use a memory mirror where one half is mapped as RW and the other is RX.
//
// Once MDWE is enabled with the prctl, the feature is sealed and it can /NOT/ be turned off.
//
// Status of MDWE is queried through prctl using `PR_GET_MDWE`:
// -1: The kernel doesn't support MDWE
// 0: MDWE is supported but disabled
// >0: MDWE is enabled, hence prohibiting RWX mappings
#ifndef PR_GET_MDWE
#define PR_GET_MDWE 66
#endif
    int MDWE = ::prctl(PR_GET_MDWE, 0, 0, 0, 0);
    if (MDWE != -1 && MDWE != 0) {
      LogMan::Msg::EFmt("MDWE was set to 0x{:x} which means FEX can't allocate executable memory", MDWE);
    }
#endif

    auto Buffer = fextl::make_shared<CodeBuffer>(Size);

#ifdef FEX_IOS_HOST
    /* ml460 (#75): generation bookkeeping. prev_use_count at swap time is the
     * direct pinning measurement — 1 (the manager) + one per thread still
     * holding the outgoing generation. The counter drives the deferred sweep
     * (Core.cpp CompileBlock tail -> Module.cpp IosMaybeSweepCodeBuffers). */
    {
      static std::atomic<int> GenLogCount {0};
      long PrevUseCount = 0;
      size_t PrevSize = 0;
      {
        std::scoped_lock lk {LatestMutex};
        if (Latest) {
          PrevUseCount = Latest.use_count();
          PrevSize = Latest->AllocatedSize;
        }
        Latest = Buffer;
        LatestOffset = 0;
      }
      const uint64_t Gen = IosCodeBufferGenCounter.fetch_add(1, std::memory_order_release) + 1;
      if (GenLogCount.fetch_add(1, std::memory_order_relaxed) < 64) {
        LogMan::Msg::EFmt("[gen] alloc#{} size=0x{:x} prev_size=0x{:x} prev_use_count={} rev=ml460", Gen, Size, PrevSize, PrevUseCount);
      }
    }
#else
    Latest = Buffer;
    LatestOffset = 0;
#endif

    OnCodeBufferAllocated(Buffer);

    return Buffer;
  }

  fextl::shared_ptr<CodeBuffer> CodeBufferManager::GetLatest() {
#ifdef FEX_IOS_HOST
    /* ml460: the sweeper reads Latest without CodeBufferWriteMutex; all reads
     * and the AllocateNew assignment go through LatestMutex. First-allocation
     * recursion is avoided by checking under the lock, allocating outside it
     * (boot-time single-threaded in practice). */
    {
      std::scoped_lock lk {LatestMutex};
      if (Latest) {
        return Latest;
      }
    }
    if (FEXCore::Config::Get_ENABLECODECACHINGWIP()) {
      AllocateNew(MAX_CODE_SIZE);
    } else {
      AllocateNew(INITIAL_CODE_SIZE);
    }
    std::scoped_lock lk {LatestMutex};
    return Latest;
#else
    if (!Latest) {
      if (FEXCore::Config::Get_ENABLECODECACHINGWIP()) {
        // Start with a larger code buffer to avoid resizes that would discard
        // code loaded from caches
        AllocateNew(MAX_CODE_SIZE);
      } else {
        AllocateNew(INITIAL_CODE_SIZE);
      }
    }
    return Latest;
#endif
  }

  fextl::shared_ptr<CodeBuffer> CodeBufferManager::StartLargerCodeBuffer() {
    if (!Latest) {
      // Allocate initial CodeBuffer and return it
      return GetLatest();
    }

    auto NewCodeBufferSize = GetLatest()->AllocatedSize;
    NewCodeBufferSize = std::min<size_t>(NewCodeBufferSize * 2, MAX_CODE_SIZE);
    return AllocateNew(NewCodeBufferSize);
  }


#if defined(FEX_IOS_HOST) && defined(_WIN32)
  /* iOS-Madeira ml460 (#75): the pool-tail sweep. ml459 proved the 208MB tail
   * is 13 live generations where steady state needs ~2 — each pinned by the
   * CurrentCodeBuffer ref of threads parked in wine waits, which never run
   * the compile-path self-migration. This sweep remote-migrates them.
   *
   * Safety model:
   *  - IosCodeBufferSweepGate is the asm-side Dekker flag. The JIT entry
   *    funnels (Module.S enter_jit / BeginSimulation) store InSimulation=1,
   *    dmb ish, then spin while the gate is set. The sweeper stores the gate,
   *    fences, then reads InSimulation per target: the fenced store->load
   *    pairs guarantee at least one side observes the other, so the sweeper
   *    never migrates a thread that is (or is entering) emitted code.
   *  - C++ paths that touch CurrentCodeBuffer on a native-side thread
   *    (exception queries) are serialized by IosMigrateLock instead.
   *  - IosSweepBusy makes ThreadTerm's unregister block until an in-flight
   *    sweep drains, so a snapshotted ThreadState cannot be destroyed under
   *    the sweeper. The unregister wait runs with NO locks held (Module.cpp
   *    calls it outside the ThreadCreationMutex scope).
   *  - The sweeper runs from a synchronous CompileBlock tail (WPM-shared
   *    held). Lock order WPM -> map-write -> IosMigrateLock matches every
   *    other taker; gate-spinners hold nothing; map-write holders are in-JIT
   *    threads that always drain. VirtualDontNeed inside the migrate is
   *    notify-free (bzero semantics), proven by the identical call in the
   *    self-migration path under an even richer lock context. */
  extern "C" {
  __attribute__((used)) uint64_t IosCodeBufferSweepGate = 0;
  }

  namespace {
    struct IosSweepSlot {
      FEXCore::Core::InternalThreadState* Thread;
      volatile uint8_t* InSim;
    };
    constexpr size_t IosSweepSlotMax = 512;
    IosSweepSlot IosSweepSlots[IosSweepSlotMax];
    size_t IosSweepSlotHighWater = 0;
    std::atomic<uint32_t> IosSweepBusy {0};
    std::atomic<uint64_t> IosSweepLastGen {0};
    // Meyers singleton: arm64ec-mingw does not reliably run global C++ ctors
    // (the Module.cpp lesson), so no namespace-scope std::mutex object.
    std::mutex& IosSweepRegistryLock() {
      static std::mutex M;
      return M;
    }
  } // namespace

  extern "C" void IosSweepRegisterThread(FEXCore::Core::InternalThreadState* Thread, volatile uint8_t* InSimPtr) {
    std::scoped_lock lk {IosSweepRegistryLock()};
    for (size_t i = 0; i < IosSweepSlotMax; i++) {
      if (!IosSweepSlots[i].Thread) {
        IosSweepSlots[i] = {Thread, InSimPtr};
        if (i + 1 > IosSweepSlotHighWater) {
          IosSweepSlotHighWater = i + 1;
        }
        return;
      }
    }
    LogMan::Msg::EFmt("[gen-sweep] registry FULL — thread unswept rev=ml460");
  }

  extern "C" void IosSweepUnregisterThread(FEXCore::Core::InternalThreadState* Thread) {
    {
      std::scoped_lock lk {IosSweepRegistryLock()};
      for (size_t i = 0; i < IosSweepSlotMax; i++) {
        if (IosSweepSlots[i].Thread == Thread) {
          IosSweepSlots[i] = {nullptr, nullptr};
          break;
        }
      }
    }
    // An in-flight sweep may have snapshotted this ThreadState before the
    // erase; hold destruction until it drains. Caller holds no locks here.
    while (IosSweepBusy.load(std::memory_order_acquire) != 0) {
      __asm volatile("yield");
    }
  }

  extern "C" void IosMaybeSweepCodeBuffers(FEXCore::Core::InternalThreadState* CallerThread) {
    const uint64_t Gen = IosCodeBufferGenCounter.load(std::memory_order_acquire);
    if (Gen == IosSweepLastGen.load(std::memory_order_relaxed)) {
      return;
    }
    if (IosSweepBusy.exchange(1, std::memory_order_acq_rel) != 0) {
      return; // another sweep in flight; it covers this generation or the next trigger will
    }
    auto Latest = CallerThread->CPUBackend->GetCodeBufferManager().GetLatest();

    IosSweepSlot Snap[IosSweepSlotMax];
    size_t SnapCount = 0;
    {
      std::scoped_lock lk {IosSweepRegistryLock()};
      for (size_t i = 0; i < IosSweepSlotHighWater; i++) {
        if (IosSweepSlots[i].Thread && IosSweepSlots[i].Thread != CallerThread) {
          Snap[SnapCount++] = IosSweepSlots[i];
        }
      }
    }

    __atomic_store_n(&IosCodeBufferSweepGate, 1, __ATOMIC_SEQ_CST);
    std::atomic_thread_fence(std::memory_order_seq_cst);

    int Migrated = 0, InSimSkip = 0, SigPinSkip = 0, Raced = 0;
    for (size_t i = 0; i < SnapCount; i++) {
      if (*Snap[i].InSim != 0) {
        InSimSkip++;
        continue;
      }
      switch (Snap[i].Thread->CPUBackend->IosRemoteMigrateStale(Latest)) {
      case 1: Migrated++; break;
      case -1: SigPinSkip++; break;
      case -2: Raced++; break;
      default: break;
      }
    }

    std::atomic_thread_fence(std::memory_order_seq_cst);
    __atomic_store_n(&IosCodeBufferSweepGate, 0, __ATOMIC_SEQ_CST);
    IosSweepLastGen.store(Gen, std::memory_order_relaxed);
    IosSweepBusy.store(0, std::memory_order_release);

    static std::atomic<int> SweepLogCount {0};
    if ((Migrated || SigPinSkip || Raced) && SweepLogCount.fetch_add(1, std::memory_order_relaxed) < 64) {
      LogMan::Msg::EFmt("[gen-sweep] gen={} threads={} migrated={} in_sim={} sig_pin={} raced={} rev=ml460", Gen, SnapCount, Migrated,
                        InSimSkip, SigPinSkip, Raced);
    }
  }
#endif

  bool CPUBackend::IsAddressInCodeBuffer(uintptr_t Address) const {
#ifdef FEX_IOS_HOST
    /* ml460: exception paths call this on threads that are native-side
     * (InSimulation==0) — exactly the threads the sweeper may be migrating.
     * Serialize against the CurrentCodeBuffer exchange. */
    IosMigrateLockGuard g {IosMigrateLock};
#endif
    auto CheckCodeBuffer = [](CodeBuffer& Buffer, uintptr_t Address) {
      // The last page of the code buffer is protected, so we need to exclude it from the valid range
      // when checking if the address is in the code buffer.
      uintptr_t LastPageAddr = AlignDown(reinterpret_cast<uintptr_t>(Buffer.Ptr) + Buffer.AllocatedSize - 1, FEXCore::Utils::FEX_PAGE_SIZE);
      return (Address >= reinterpret_cast<uintptr_t>(Buffer.Ptr) && Address < LastPageAddr);
    };

    if (CheckCodeBuffer(*CurrentCodeBuffer, Address)) {
      return true;
    }
    for (auto& Buffer : SignalHandlerCodeBuffers) {
      if (CheckCodeBuffer(*Buffer, Address)) {
        return true;
      }
    }
    return false;
  }

} // namespace CPU
} // namespace FEXCore
