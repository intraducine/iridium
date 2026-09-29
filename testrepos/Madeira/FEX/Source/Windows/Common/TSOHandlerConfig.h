// SPDX-License-Identifier: MIT
#pragma once

#include <FEXCore/Core/Context.h>
#include <FEXCore/Config/Config.h>
#include <FEXCore/Utils/ArchHelpers/Arm64.h>

#include "Windows/Common/FEXUnixLib.h"

namespace FEX::Windows {
class TSOHandlerConfig final {
public:
  TSOHandlerConfig(FEXCore::Context::Context& CTX) {
    if (HalfBarrierTSOEnabled()) {
      UnalignedHandlerType = FEXCore::ArchHelpers::Arm64::UnalignedHandlerType::HalfBarrier;
    } else {
      UnalignedHandlerType = FEXCore::ArchHelpers::Arm64::UnalignedHandlerType::NonAtomic;
    }

    if (TSOEnabled() && FEX::Windows::UnixLib::TryEnableHardwareTSO()) {
      CTX.SetHardwareTSOSupport(true);
    }

    uint64_t Flags = (StrictInProcessSplitLocks() ? FEX_UNALIGN_ATOMIC_STRICT_SPLIT_LOCKS : 0) |
                     (KernelUnalignedAtomicBackpatching() ? FEX_UNALIGN_ATOMIC_BACKPATCH : 0) | FEX_UNALIGN_ATOMIC_EMULATE;

    if (UnixLib::SetKernelUnalignedAtomicControl(Flags)) {
      LogMan::Msg::IFmt("FEX: Kernel unaligned atomics enabled!");
    }

    /* iOS-Madeira ml512/ml513: report the EFFECTIVE TSO configuration at
     * runtime. A compiled-in config default is invisible to binary greps, so
     * this line is the only way to know what the JIT is actually doing.
     *
     * ml512 flipped VectorTSOEnabled/MemcpySetTSOEnabled to true and the
     * Chromium raster corruption was UNCHANGED; ml513 reverted both to the
     * upstream default (false). KNOWN ACCURACY GAP, deliberately accepted:
     * x86 orders SSE/AVX and rep-movs accesses under TSO and FEX emits them
     * unordered, so a guest relying on per-location vector ordering without
     * a scalar release would misbehave. Nothing observed needs it, and
     * ordering every vector access taxes exactly the vector-heavy game
     * workloads that are the product (Thumper). Re-enable by flipping the
     * two Config.json.in defaults; this line proves which way it shipped. */
    {
      FEX_CONFIG_OPT(VecTSO, VECTORTSOENABLED);
      FEX_CONFIG_OPT(MemcpyTSO, MEMCPYSETTSOENABLED);
      LogMan::Msg::IFmt("FEX: TSO config tso={} halfbar={} vector={} memcpyset={} rev=ml513",
                        TSOEnabled(), HalfBarrierTSOEnabled(), VecTSO(), MemcpyTSO());
      /* ml538: and the EFFECTIVE host-feature set. A compiled-in default is
       * invisible to binary greps, and the whole AVX experiment is worthless
       * without proof of which way it shipped. */
      FEX_CONFIG_OPT(HostFeat, HOSTFEATURES);
      LogMan::Msg::IFmt("FEX: HostFeatures={} (ml538: DISABLEAVX expected; "
                        "AVX off => Skia takes SSE paths) rev=ml538", HostFeat());
    }
  }

  FEXCore::ArchHelpers::Arm64::UnalignedHandlerType GetUnalignedHandlerType() const {
    return UnalignedHandlerType;
  }

private:
  FEX_CONFIG_OPT(TSOEnabled, TSOENABLED);
  FEX_CONFIG_OPT(HalfBarrierTSOEnabled, HALFBARRIERTSOENABLED);
  FEX_CONFIG_OPT(StrictInProcessSplitLocks, STRICTINPROCESSSPLITLOCKS);
  FEX_CONFIG_OPT(KernelUnalignedAtomicBackpatching, KERNELUNALIGNEDATOMICBACKPATCHING);

  FEXCore::ArchHelpers::Arm64::UnalignedHandlerType UnalignedHandlerType {FEXCore::ArchHelpers::Arm64::UnalignedHandlerType::HalfBarrier};
};
} // namespace FEX::Windows
