// SPDX-License-Identifier: MIT
// MADEIRA: iOS Mono-backpatcher bridge for the WoW64 module.
//
// This is the WoW64 counterpart of the ml648 bridge in ARM64EC/IosJitAlias.cpp. FEXCore's shared
// code (Core.cpp's MonoBackpatcherWrite and the Windows InvalidationTracker) calls into this
// bridge unconditionally on an iOS host, so both PEs have to provide it - each statically links its
// own copy of FEXCore, so neither can borrow the other's storage.
//
// What it is for: on iOS a guest code page is mapped R+X and iOS will not grant write on it, so a
// Mono-style backpatcher's store to its own code faults on every single patch. The bridge lets
// Wine's ntdll publish a table of guest-RX -> host-RW aliases so that store can be redirected to
// the writable view instead of being emulated through a Mach fault.
//
// What is NOT here, and why: ARM64EC/IosJitAlias.cpp also owns the PE-image -> JIT-pool alias table
// (IosAliasEntries) used by Module.S's ExitFunctionEC. That table exists because ARM64EC PE images
// have to be copied into the JIT pool to execute at all. The WoW64 module has no Module.S, no EC
// entry thunks, and its guest images are ordinary i386 mappings, so there is nothing to translate -
// see the identity IosJitReverseTranslate in FEXCore's Core.cpp for the non-EC build.
//
// Until Wine calls BTCpuIosSetMonoBridge, g_MonoBridge is null: every resolve misses, the miss is
// counted, and MonoBackpatcherWrite falls back to the direct store, which faults and is emulated
// exactly as it is today. That is a real answer ("no bridge has been published"), not a stub that
// pretends to have succeeded.

#include <cstdint>
#include <windows.h>
#include <winternl.h>

// Deliberately shared with the ARM64EC module rather than duplicated: this header must stay
// byte-identical to build/ntdll-unix/ios_mono_bridge.h, and two copies would be two chances to
// drift. abi_version is the runtime guard for the fact that the two sides are built by different
// toolchains.
#include "../ARM64EC/IosMonoBridge.h"

// For CurrentTEB(): this file must not read x18 either. See IosTeb.h.
#include "IosTeb.h"

#ifdef FEX_IOS_HOST

namespace {
ios_mono_bridge* g_MonoBridge = nullptr;
} // namespace

extern "C" {

// Defined in FEXCore's Core.cpp, which has the types and LogMan.
extern void ios_fex_mono_bridge_publish(void* Bridge);
extern void ios_fex_mono_report_armed(uint64_t, uint64_t);

// Exported from libwow64fex.dll. Named BTCpuIos* to match the WoW64 BT API prefix, where the
// ARM64EC module uses BTCpu64Ios*. dllexport rather than a libwow64fex.def entry because the DEF is
// shared with non-iOS builds, where this function does not exist.
__declspec(dllexport) void BTCpuIosSetMonoBridge(uint64_t BridgeAddr) {
  auto* B = reinterpret_cast<ios_mono_bridge*>(BridgeAddr);
  if (!B || B->abi_version != IOS_MONO_ABI_VERSION) {
    // Refuse rather than arm a struct whose layout we cannot trust - the native side reads it from
    // inside a Mach fault handler.
    return;
  }
  g_MonoBridge = B;
  ios_fex_mono_bridge_publish(B);
}

// Resolve an executable address to its writable alias. Sequence-lock read exactly as the writer
// publishes: sample the generation, read, sample again, accept only when both are equal and ODD. A
// retired-and-reused slot therefore misses instead of returning a stale mapping, which would put a
// guest code write into memory that no longer backs it. Returns 0 on miss; the caller counts it and
// falls back rather than guessing.
//
// The parameter is a HOST address. Everything in this table is an address actually mapped in this
// process, and MonoBackpatcherWrite applies the guest window before calling in - the name says host
// so a reader does not "helpfully" add the base a second time.
uint64_t IosMonoResolveRW(uint64_t HostAddr, uint64_t Size) {
  auto* B = g_MonoBridge;
  if (!B) {
    return 0;
  }
  const uint32_t Count = __atomic_load_n(&B->alias_count, __ATOMIC_ACQUIRE);
  for (uint32_t i = 0; i < Count && i < IOS_MONO_MAX_ALIASES; i++) {
    const uint32_t G1 = __atomic_load_n(&B->aliases[i].generation, __ATOMIC_ACQUIRE);
    if (!(G1 & 1)) {
      continue; // retired or mid-update
    }
    const uint64_t Base = B->aliases[i].guest_rx;
    const uint64_t Sz = B->aliases[i].size;
    const uint64_t RW = B->aliases[i].host_rw;
    const uint32_t G2 = __atomic_load_n(&B->aliases[i].generation, __ATOMIC_ACQUIRE);
    if (G1 != G2) {
      continue; // changed under us
    }
    if (HostAddr >= Base && HostAddr + Size <= Base + Sz) {
      return RW + (HostAddr - Base);
    }
  }
  return 0;
}

// Called from InvalidationTracker the moment the Mono module is recognised. Until this runs,
// mono_base is 0 and the native Mach handler declines every capture.
//
// NOTE for the guest window: the addresses in this table are the ones actually mapped in this
// process, i.e. HOST addresses. InvalidationTracker's module bases are host addresses, and
// MonoBackpatcherWrite converts the guest address to a host one before calling IosMonoResolveRW,
// so both callers already agree.
void ios_fex_mono_arm(uint64_t Base, uint64_t End) {
  auto* B = g_MonoBridge;
  if (!B) {
    return;
  }
  B->mono_end = End;
  __atomic_store_n(&B->mono_base, Base, __ATOMIC_RELEASE); // publish LAST: it is the gate
  ios_fex_mono_report_armed(Base, End);
}

// Take this context's pending event, if any. One-shot: the slot moves to state 2 and never fires
// again for this process, so a mis-detection cannot loop.
//
// Keyed by PEB because pseudo-processes share one address space - a global slot would let one
// process's fault mark another process's block. This matters more here than for ARM64EC: several
// 32-bit pseudo-processes can be live at once, each with its own guest window.
int ios_fex_mono_take_pending(uint64_t* BlockBegin, uint64_t* HostPC, uint64_t* FaultAddr) {
  auto* B = g_MonoBridge;
  if (!B) {
    return 0;
  }
  // Via CurrentTEB(), not NtCurrentTeb(): this runs from CompileBlock, long after Metal/libobjc/
  // mach calls have had a chance to clobber x18, and a garbage TEB here would read a garbage PEB and
  // silently match the wrong pseudo-process's pending slot.
  const uint64_t Context = reinterpret_cast<uint64_t>(FEX::Windows::WOW64::CurrentTEB()->ProcessEnvironmentBlock);
  if (!Context) {
    return 0;
  }
  for (uint32_t i = 0; i < IOS_MONO_MAX_CONTEXTS; i++) {
    auto& P = B->pending[i];
    if (__atomic_load_n(&P.context, __ATOMIC_ACQUIRE) != Context) {
      continue;
    }
    uint32_t Want = 1;
    if (!__atomic_compare_exchange_n(&P.state, &Want, 2, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
      return 0; // empty, or already consumed
    }
    *BlockBegin = P.block_begin;
    *HostPC = P.host_pc;
    *FaultAddr = P.fault_addr;
    return 1;
  }
  return 0;
}

// One relaxed load. Keeps CompileBlock's added cost to a load+branch until the bridge is armed AND
// something is actually pending.
int ios_fex_mono_bridge_armed() {
  auto* B = g_MonoBridge;
  if (!B || !__atomic_load_n(&B->mono_base, __ATOMIC_ACQUIRE)) {
    return 0;
  }
  return __atomic_load_n(&B->n_captured, __ATOMIC_RELAXED) != __atomic_load_n(&B->n_activated, __ATOMIC_RELAXED);
}

void ios_fex_mono_count_activated() {
  if (g_MonoBridge) {
    __atomic_add_fetch(&g_MonoBridge->n_activated, 1, __ATOMIC_RELAXED);
  }
}

uint64_t ios_fex_mono_captured_count() {
  return g_MonoBridge ? __atomic_load_n(&g_MonoBridge->n_captured, __ATOMIC_RELAXED) : 0;
}

// Counters live with the table, off the caller's hot path.
void ios_fex_mono_count_helper(int Miss) {
  auto* B = g_MonoBridge;
  if (!B) {
    return;
  }
  __atomic_add_fetch(&B->n_helper_calls, 1, __ATOMIC_RELAXED);
  if (Miss) {
    __atomic_add_fetch(&B->n_alias_miss, 1, __ATOMIC_RELAXED);
  }
}

} // extern "C"

#endif // FEX_IOS_HOST
