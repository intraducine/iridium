// SPDX-License-Identifier: MIT
// iOS JIT-pool alias table.
//
// On iOS, ARM64EC PE images cannot run from their loaded address (iOS rejects
// mprotect(RX) on file-backed mmaps). Wine's ntdll-unix copies each PE image
// into the dual-mapped JIT pool. Code in the copied image executes from the
// alias address, not the original PE address.
//
// FEX's range trackers only know the ORIGINAL PE address ranges, so they
// report alias addresses as non-executable. The lookup wrappers in
// Module.cpp call IosJitReverseTranslate to map alias → PE-original for
// the tracker query, then IosJitTranslate to map the result back.
//
// Lives in a separate TU from Module.cpp because accessing the table's
// global storage directly from ARM64EC class methods in Module.cpp produced
// a "misaligned ldr/str offset" link error — probably an ADRP+LDR
// page-offset issue in the hybrid emit. Putting the data + accessors in
// their own TU sidesteps the issue.

#include <cstdint>
#include <atomic>
#include <FEXCore/Utils/LogManager.h>
#include <windows.h>
#include <winternl.h>
#include "IosMonoBridge.h"

#ifdef FEX_IOS_HOST

struct IosAliasEntry {
  uint64_t PeBase;
  uint64_t JitBase;
  uint64_t Size;
  uint64_t _Padding;  // Keeps the struct 32-byte to make array stride a power of 2.
};
constexpr int kMaxEntries = 256;

// extern "C" storage (not anonymous-namespace) so Module.S's ExitFunctionEC
// can reach the table via adrp/:lo12: — it translates the branch target
// PE VA → pool VA inline before jumping to native EC code. That asm relies
// on the 32-byte stride and the PeBase/JitBase/Size field order.
extern "C" {
IosAliasEntry IosAliasEntries[kMaxEntries];
volatile int IosAliasCount = 0;
/* ml1116: the entry that satisfied the last translation, checked first by
 * Module.S before the walk. A pointer (one atomic 8-byte store) rather than a
 * copy of the fields, so a reader can never see a torn entry; a retired entry
 * has Size 0 and simply misses. The walk itself now runs NEWEST-FIRST: the
 * images the game calls (its own EC ntdll/kernel32/kernelbase, the D3D12
 * runtime) are registered late, so oldest-first cost ~150 iterations per
 * x64->EC call at up to a million calls a second. */
IosAliasEntry* volatile IosAliasLast = nullptr;
}

namespace {
IosAliasEntry* const g_Entries = IosAliasEntries;
volatile int& g_EntryCount = IosAliasCount;
}  // namespace

extern "C" {

// ml357: STALE ALIASES ARE FATAL, and the old de-dupe guaranteed them.
//
// The previous rule was "same PeBase = already registered, ignore" — so a DLL
// that unloaded and was replaced at the same (or an overlapping) PE VA kept
// FEX pointing at the ORIGINAL pool copy forever. That copy is tombstoned and
// eventually reclaimed/zeroed, so every guest RIP in the new module translated
// into dead memory: ml356 died executing a page of zeros (udf → c000001d) one
// instruction after wevtapi.dll loaded INSIDE a departed module's old range.
//
// Wine's own table (ios_jit_add_mapping) already purges by OVERLAP for exactly
// this reason; this is that rule's missing twin on the FEX side. Tombstone
// order matches wine's: Size = 0 first (a zero-size entry matches no range
// query, including Module.S's inline asm walk), barrier, then reuse the slot.
/* iOS-Madeira ml549: EXACT guest RIP from a host PC, for the unix-side fault probes.
 *
 * The Mach handlers in ntdll-unix read the guest RIP from CpuStateFrame+0x18, which FEX
 * only syncs at BLOCK boundaries -- it names the calling block, not the instruction that
 * ran. ml548 disassembled such a RIP and got call setup instead of the store it was
 * hunting, which is why the render-corruption writer could never be identified.
 *
 * FEX already stores a host-PC -> guest-RIP table in every JIT block tail and walks it
 * for exception reconstruction. ios_fex_rip_from_hostpc (Core.cpp) is that walk without
 * the Thread dependency; this is its EC export so the unix side can reach it through the
 * same bind-and-push path as BTCpu64IosAddAliasMapping.
 *
 * Zero runtime cost: nothing is instrumented, the table already exists. Returns 0 when
 * the PC is outside the block, so a caller can distinguish "no answer" from a real RIP. */
uint64_t BTCpu64IosRipFromHostPC(uint64_t BlockBegin, uint64_t HostPC) {
  extern uint64_t ios_fex_rip_from_hostpc(uint64_t, uint64_t);
  return ios_fex_rip_from_hostpc(BlockBegin, HostPC);
}

/* ============================ ml648 MONO BRIDGE ============================
 * Owned here rather than in Module.cpp for the same reason the alias table is:
 * reaching global storage from ARM64EC class methods there produced misaligned
 * ldr/str link errors. Kept in a DIFFERENT table from IosAliasEntries — see
 * IosMonoBridge.h. */
ios_mono_bridge* g_MonoBridge = nullptr;

extern void ios_fex_mono_bridge_publish(void* Bridge);      // Core.cpp: has the types
extern void ios_fex_mono_report_armed(uint64_t, uint64_t);  // Core.cpp: has LogMan

void BTCpu64IosSetMonoBridge(uint64_t BridgeAddr) {
  auto* B = reinterpret_cast<ios_mono_bridge*>(BridgeAddr);
  if (!B || B->abi_version != IOS_MONO_ABI_VERSION) {
    // Refuse rather than arm a struct whose layout we cannot trust — the native
    // side reads it inside a Mach fault handler.
    return;
  }
  g_MonoBridge = B;
  ios_fex_mono_bridge_publish(B);
}

/* Resolve a guest RX address to its writable alias. Sequence-lock read exactly
 * as the writer publishes: sample the generation, read, sample again, and
 * accept only when both are equal and ODD. A retired-and-reused slot therefore
 * misses instead of returning a stale mapping — which would put a guest code
 * write into memory that no longer backs it. Returns 0 on miss; the caller
 * counts it and falls back rather than guessing. */
uint64_t IosMonoResolveRW(uint64_t GuestAddr, uint64_t Size) {
  auto* B = g_MonoBridge;
  if (!B) {
    return 0;
  }
  const uint32_t Count = __atomic_load_n(&B->alias_count, __ATOMIC_ACQUIRE);
  for (uint32_t i = 0; i < Count && i < IOS_MONO_MAX_ALIASES; i++) {
    const uint32_t G1 = __atomic_load_n(&B->aliases[i].generation, __ATOMIC_ACQUIRE);
    if (!(G1 & 1)) {
      continue;  // retired or mid-update
    }
    const uint64_t Base = B->aliases[i].guest_rx;
    const uint64_t Sz = B->aliases[i].size;
    const uint64_t RW = B->aliases[i].host_rw;
    const uint32_t G2 = __atomic_load_n(&B->aliases[i].generation, __ATOMIC_ACQUIRE);
    if (G1 != G2) {
      continue;  // changed under us
    }
    if (GuestAddr >= Base && GuestAddr + Size <= Base + Sz) {
      return RW + (GuestAddr - Base);
    }
  }
  return 0;
}
/* Called from InvalidationTracker the moment the Mono module is recognised.
 * Until this runs, mono_base is 0 and the native Mach handler declines every
 * capture — the ordering the design depends on, enforced by construction. */
void ios_fex_mono_arm(uint64_t Base, uint64_t End) {
  auto* B = g_MonoBridge;
  if (!B) {
    return;
  }
  B->mono_end = End;
  __atomic_store_n(&B->mono_base, Base, __ATOMIC_RELEASE);  // publish LAST: it is the gate
  ios_fex_mono_report_armed(Base, End);
}

/* Take this context's pending event, if any. One-shot: the slot moves to state 2
 * and never fires again for this process, so a mis-detection cannot loop.
 *
 * Keyed by PEB because pseudo-processes share one address space — a global slot
 * would let one process's fault mark another process's block. */
int ios_fex_mono_take_pending(uint64_t* BlockBegin, uint64_t* HostPC, uint64_t* FaultAddr) {
  auto* B = g_MonoBridge;
  if (!B) {
    return 0;
  }
  const uint64_t Context = reinterpret_cast<uint64_t>(NtCurrentTeb()->ProcessEnvironmentBlock);
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
      return 0;  // empty, or already consumed
    }
    *BlockBegin = P.block_begin;
    *HostPC = P.host_pc;
    *FaultAddr = P.fault_addr;
    return 1;
  }
  return 0;
}

/* One relaxed load. Keeps CompileBlock's added cost to a load+branch until the
 * bridge is armed AND something is actually pending. */
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

/* Counters live with the table, off the caller's hot path. */
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
/* ========================== end ml648 MONO BRIDGE ========================= */

/* ========================= ml951 SUB-FLOOR WINDOWS =======================
 *
 * iOS reserves the low 4GB of every task, so a PE whose preferred base is below
 * it cannot be mapped there (measured four ways -- see the ml938 block in
 * ntdll-unix/signal_arm64_ios.c). Such an image is mapped high instead, and
 * Wine's fault handler services data accesses to the vacated low range against
 * the real mapping.
 *
 * That covers faults, but not QUESTIONS. FEX's QueryGuestExecutableRange asks
 * the InvalidationTracker whether an address is executable; the tracker is
 * built from actually-mapped sections, so a low address answers "no" and FEX
 * refuses to build the entry block ("NoExec instruction in entry block"). No
 * fault occurs, so there is nothing for the handler to service. This table
 * lets that one lookup be answered.
 *
 * ⛔ DELIBERATELY SEPARATE FROM IosAliasEntries. Module.S's ExitFunctionEC
 * translates branch targets PeBase -> JitBase through that table inline, so an
 * entry there REWRITES CONTROL FLOW. Putting a sub-floor window in it would
 * silently move the guest RIP to the high backing address, which is exactly
 * what must not happen: the guest's address identity has to stay low. This
 * table is query-only and Module.S never sees it.
 *
 * Registration reuses BTCpu64IosAddAliasMapping rather than adding an export,
 * because a new export would need a PE-side binding and these are ARM64EC PE
 * entry points -- NOT callable from native Mach-O code (ml613 armed such a
 * call and crashed every launch). The discriminator is self-identifying and
 * disjoint: a real JIT alias's PeBase is a mapped PE image base, which on iOS
 * is always >= 4GB; a sub-floor window's low base is by definition < 4GB.
 */
static constexpr uint64_t kIosSubfloorFloor = 0x100000000ull;
static constexpr int kMaxSubfloorEntries = 8;

struct IosSubfloorEntry {
  uint64_t LowBase;   // what the guest uses (below the floor)
  uint64_t RealBase;  // where the image actually is
  uint64_t Size;
  uint64_t _Padding;
};
static IosSubfloorEntry g_Subfloor[kMaxSubfloorEntries];
static int g_SubfloorCount;

// low -> real, or Addr unchanged when it is not in a window.
uint64_t IosSubfloorToReal(uint64_t Addr) {
  if (Addr >= kIosSubfloorFloor) {
    return Addr; // fast reject: the overwhelmingly common case
  }
  const int count = g_SubfloorCount;
  for (int i = 0; i < count; i++) {
    const uint64_t lb = g_Subfloor[i].LowBase;
    const uint64_t sz = g_Subfloor[i].Size;
    if (sz && Addr >= lb && Addr < lb + sz) {
      return g_Subfloor[i].RealBase + (Addr - lb);
    }
  }
  return Addr;
}

// ml1057: is this guest RIP code that belongs to a sub-floor image -- either at the
// image's real (high) mapping, which is where it executes, or named by its low
// address? If so report the window so the JIT can translate that image's own
// memory operands inline instead of faulting on each one.
extern "C" int IosSubfloorWindowForCode(uint64_t Rip, uint64_t* Low, uint64_t* Size, uint64_t* Real) {
  const int count = g_SubfloorCount;
  for (int i = 0; i < count; i++) {
    const uint64_t lb = g_Subfloor[i].LowBase, rb = g_Subfloor[i].RealBase, sz = g_Subfloor[i].Size;
    if (!sz || !rb) continue;
    if ((Rip >= rb && Rip < rb + sz) || (Rip >= lb && Rip < lb + sz)) {
      static std::atomic<int> Said {0};
      if (Said.fetch_add(1, std::memory_order_relaxed) < 4) {
        LogMan::Msg::EFmt("[iOS-subfloor-xlate] ml1057 block at {:#x} lives in window [{:#x},+{:#x}) -> {:#x}: translating its "
                          "memory operands inline", Rip, lb, sz, rb);
      }
      *Low = lb; *Size = sz; *Real = rb;
      return 1;
    }
  }
  return 0;
}

// real -> low, or Addr unchanged. Used to map a tracker result back into the
// guest's own address domain so the guest RIP is never moved high.
uint64_t IosSubfloorToLow(uint64_t Addr) {
  const int count = g_SubfloorCount;
  for (int i = 0; i < count; i++) {
    const uint64_t rb = g_Subfloor[i].RealBase;
    const uint64_t sz = g_Subfloor[i].Size;
    if (sz && Addr >= rb && Addr < rb + sz) {
      return g_Subfloor[i].LowBase + (Addr - rb);
    }
  }
  return Addr;
}

// Clip a range to the end of the window containing LowAddr, so a tracker range
// can never be reported as extending past the window we actually back.
uint64_t IosSubfloorClipSize(uint64_t LowAddr, uint64_t Size) {
  const int count = g_SubfloorCount;
  for (int i = 0; i < count; i++) {
    const uint64_t lb = g_Subfloor[i].LowBase;
    const uint64_t sz = g_Subfloor[i].Size;
    if (sz && LowAddr >= lb && LowAddr < lb + sz) {
      const uint64_t avail = (lb + sz) - LowAddr;
      return Size < avail ? Size : avail;
    }
  }
  return Size;
}

static bool IosSubfloorAdd(uint64_t LowBase, uint64_t RealBase, uint64_t Size) {
  const int count = g_SubfloorCount;
  for (int i = 0; i < count; i++) {
    if (g_Subfloor[i].LowBase == LowBase) {
      // Re-registration: a second pseudo-process mapped the same image. Last
      // writer wins, which is unsafe with two live loaders -- see the ml938
      // note; ownership is owed before this is durable.
      g_Subfloor[i].RealBase = RealBase;
      __sync_synchronize();
      g_Subfloor[i].Size = Size;
      return true;
    }
  }
  if (count >= kMaxSubfloorEntries) {
    return false;
  }
  g_Subfloor[count].LowBase = LowBase;
  g_Subfloor[count].RealBase = RealBase;
  __sync_synchronize();
  g_Subfloor[count].Size = Size; // published last
  g_SubfloorCount = count + 1;
  return true;
}
/* ======================= end ml951 SUB-FLOOR WINDOWS ===================== */

void BTCpu64IosAddAliasMapping(uint64_t PeBase, uint64_t JitBase, uint64_t Size) {
  /* ml951: a sub-floor window arrives through this same entry point, marked by
   * a below-4GB "PeBase" (no real PE base can be there on iOS). Route it to the
   * query-only table and return -- it must NEVER land in IosAliasEntries, which
   * Module.S uses to rewrite branch targets. */
  if (PeBase < kIosSubfloorFloor) {
    IosSubfloorAdd(PeBase, JitBase, Size);
    return;
  }

  int count = g_EntryCount;

  // Identical re-registration: nothing to do.
  for (int i = 0; i < count; i++) {
    if (g_Entries[i].PeBase == PeBase && g_Entries[i].JitBase == JitBase && g_Entries[i].Size == Size) {
      return;
    }
  }

  // Retire every entry whose PE range overlaps the incoming image: a live
  // image proves any overlapping entry is dead (two images cannot share a VA).
  for (int i = 0; i < count; i++) {
    const uint64_t pb = g_Entries[i].PeBase;
    const uint64_t sz = g_Entries[i].Size;
    if (!sz) {
      continue;
    }
    if (pb < PeBase + Size && PeBase < pb + sz) {
      g_Entries[i].Size = 0;
      __sync_synchronize();
    }
  }

  // Prefer a retired slot so long-running processes don't exhaust the table.
  for (int i = 0; i < count; i++) {
    if (!g_Entries[i].Size) {
      g_Entries[i].PeBase = PeBase;
      g_Entries[i].JitBase = JitBase;
      __sync_synchronize();
      g_Entries[i].Size = Size; // published last: readers see a complete entry
      return;
    }
  }

  if (count >= kMaxEntries) {
    /* ml1106: a silent refusal here means ExitFunctionEC never translates this
     * image, so EVERY x64->EC call into it pays a Mach exec-fault redirect
     * (ph-rdr59: 69k of every 100k redirects were one kernelbase export). */
    static int said = 0;
    if (said++ < 8) {
      LogMan::Msg::EFmt("[jit-alias] ml1106 IosAliasEntries FULL ({} entries): image 0x{:x}+0x{:x} NOT registered -- its calls will fault-redirect", count, PeBase, Size);
    }
    return;
  }
  g_Entries[count].PeBase = PeBase;
  g_Entries[count].JitBase = JitBase;
  g_Entries[count].Size = Size;
  __sync_synchronize();
  g_EntryCount = count + 1;
}

uint64_t IosJitTranslate(uint64_t Addr) {
  int count = g_EntryCount;
  for (int i = 0; i < count; i++) {
    uint64_t pb = g_Entries[i].PeBase;
    uint64_t sz = g_Entries[i].Size;
    if (Addr >= pb && Addr < pb + sz) {
      return g_Entries[i].JitBase + (Addr - pb);
    }
  }
  return Addr;
}

uint64_t IosJitReverseTranslate(uint64_t Addr) {
  int count = g_EntryCount;
  for (int i = 0; i < count; i++) {
    uint64_t jb = g_Entries[i].JitBase;
    uint64_t sz = g_Entries[i].Size;
    if (Addr >= jb && Addr < jb + sz) {
      return g_Entries[i].PeBase + (Addr - jb);
    }
  }
  return Addr;
}

}  // extern "C"

#endif  // FEX_IOS_HOST
