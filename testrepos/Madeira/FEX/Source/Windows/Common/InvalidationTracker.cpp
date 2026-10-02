// SPDX-License-Identifier: MIT

#include <atomic>
#include <cstdlib>  // ml623: getenv/strtoull for the IR-capture target
#include <cstring>  // ml623: strlen
#include <FEXCore/Utils/LogManager.h>
#include <FEXCore/Utils/TypeDefines.h>
#include <FEXCore/Utils/SignalScopeGuards.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Config/Config.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include "InvalidationTracker.h"
#include <windef.h>
#include <winternl.h>

/* ml623: targeted IR capture target (defined in FEXCore PassManager.cpp). File scope on
 * purpose -- an extern "C" at block scope is a compile error and cost a build earlier. */
extern "C" uint64_t FEX_MadeiraIRCapTarget;

/* ml648: defined in the ARM64EC alias TU. Declared at FILE scope — an
 * extern "C" declaration is illegal at block scope, and declaring it inside
 * namespace FEX::Windows would mangle it as FEX::Windows::ios_fex_mono_arm. */
#ifdef FEX_IOS_HOST
extern "C" void ios_fex_mono_arm(uint64_t Base, uint64_t End);
#endif

namespace FEX::Windows {
#if !defined(ARCHITECTURE_arm64ec)
InvalidationTracker::InvalidationTracker(FEXCore::Context::Context& CTX,
                                         const std::unordered_map<DWORD, FEXCore::Core::InternalThreadState*>& Threads, uint64_t GuestBase)
  : CTX {CTX}
  , Threads {Threads}
  , GuestBase {GuestBase} {
#else
InvalidationTracker::InvalidationTracker(FEXCore::Context::Context& CTX, const std::unordered_map<DWORD, FEXCore::Core::InternalThreadState*>& Threads)
  : CTX {CTX}
  , Threads {Threads} {
#endif
  FEX_CONFIG_OPT(SMCChecks, SMCCHECKS);
  SMCDetectionDisabled = (SMCChecks == FEXCore::Config::CONFIG_SMC_NONE);

  MEMORY_BASIC_INFORMATION Info;
  uint64_t Address = 0;

  while (VirtualQuery(reinterpret_cast<LPCVOID>(Address), &Info, sizeof(Info))) {
    uint64_t BaseAddress = reinterpret_cast<uint64_t>(Info.BaseAddress);
    if (Info.State == MEM_COMMIT) {
      HandleMemoryProtectionNotification(BaseAddress, Info.RegionSize, Info.Protect);
    }

    Address = BaseAddress + Info.RegionSize;
  }
}

static bool ProtHasExec(ULONG Prot) {
  return (Prot & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) != 0;
}

static bool ProtIsReadable(ULONG Prot) {
  return (Prot & (PAGE_READONLY | PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE |
                  PAGE_EXECUTE_WRITECOPY)) != 0;
}

static bool ProtIsWritable(ULONG Prot) {
  return (Prot & (PAGE_READWRITE | PAGE_WRITECOPY | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) != 0;
}

void InvalidationTracker::HandleMemoryProtectionNotification(uint64_t Address, uint64_t Size, ULONG Prot) {
  const auto AlignedBase = Address & FEXCore::Utils::FEX_PAGE_MASK;
  const auto AlignedSize = (Address - AlignedBase + Size + FEXCore::Utils::FEX_PAGE_SIZE - 1) & FEXCore::Utils::FEX_PAGE_MASK;

  const bool NeedsInvalidate = [&]() {
    std::unique_lock Lock(IntervalsLock);

    FEXCore::IntervalList<uint64_t>::Interval ProtInterval {AlignedBase, AlignedBase + AlignedSize};

    const bool HasExec = ProtHasExec(Prot);
#if !defined(ARCHITECTURE_arm64ec)
    // Guest window: DEP-off does not promote here. Treating every readable allocation or reprotect
    // as executable arms an SMC write-trap on plain data at the guest's allocation rate, although
    // most programs without NX_COMPAT never execute from their data. Under a window promotion is
    // lazy, on an actual execute attempt (QueryExecutableRange -> PromoteDEPRegionLocked).
    // Identity-mapped builds keep the eager promotion below.
    const bool EagerDEP = DEPDisabled && !GuestBase;
    const bool EffectiveExec = HasExec || (EagerDEP && ProtIsReadable(Prot));
    const bool EffectiveRWX = EffectiveExec && ProtIsWritable(Prot);

    if (EffectiveExec) {
      XIntervals.Insert(ProtInterval);
      if (EffectiveRWX) {
        LogMan::Msg::DFmt("Add SMC interval: {:X} - {:X}", AlignedBase, AlignedBase + AlignedSize);
        RWXIntervals.Insert(ProtInterval);
      }
      if (EagerDEP && !HasExec) {
        DEPPromotedIntervals.Insert(ProtInterval);
      }
      return true;
#else
    const bool EffectiveExec = HasExec || (DEPDisabled && ProtIsReadable(Prot));
    const bool EffectiveRWX = EffectiveExec && ProtIsWritable(Prot);

    if (EffectiveExec) {
      XIntervals.Insert(ProtInterval);
      if (EffectiveRWX) {
        LogMan::Msg::DFmt("Add SMC interval: {:X} - {:X}", AlignedBase, AlignedBase + AlignedSize);
        RWXIntervals.Insert(ProtInterval);
      }
      if (DEPDisabled && !HasExec) {
        DEPPromotedIntervals.Insert(ProtInterval);
      }
      return true;
#endif
    } else if (XIntervals.Intersect(ProtInterval)) {
      /* iOS-Madeira ml208 ROOT-CAUSE FIX.
       *
       * A >=1GB non-executable range is an allocator reserving or managing a pool, never a
       * code-permission change. Removing exec intervals for it wipes the executable range
       * of EVERY module inside at once. Observed: PartitionAlloc reserving its 16GB soft
       * pool 0x7000000000-0x7400000000 erased libcef's .text (0x7388f41000-0x7393f7cd23),
       * after which the decoder reported NOEXEC at libcef code addresses, raised
       * FAULT_SIGSEGV and killed 42 webhelper threads.
       *
       * Note this arrives via NotifyMemoryAlloc (ARM64EC/Module.cpp), NOT NotifyMemoryProtect
       * — an earlier fix guarding Wine's NtProtectVirtualMemory therefore never fired. The
       * guard belongs here, at the single choke point all three callers share.
       *
       * Only the REMOVAL branch is guarded: modules keep their own mappings and issue their
       * own notifications, so ignoring a bulk range cannot lose a genuine executability
       * transition, while the insert path above is left untouched so DEP promotion behaves
       * exactly as before. */
      if (AlignedSize >= (1ull << 30)) {
        LogMan::Msg::EFmt("[iOS-xrem] SUPPRESSED bulk non-exec {:#x}-{:#x} ({} MB) prot={:#x}", ProtInterval.Offset,
                          ProtInterval.End, AlignedSize >> 20, Prot);
        return false;
      }
      LogMan::Msg::EFmt("[iOS-xrem] via=protect tracker={} {:#x}-{:#x}", static_cast<void*>(this),
                        ProtInterval.Offset, ProtInterval.End);
      XIntervals.Remove(ProtInterval);
      RWXIntervals.Remove(ProtInterval);
      if (DEPDisabled) {
        DEPPromotedIntervals.Remove(ProtInterval);
      }
      return true;
    }

    return false;
  }();

  if (NeedsInvalidate) {
    // IntervalsLock cannot be held during invalidation
    InvalidateIntervalInternal(AlignedBase, AlignedSize);
  }
}

void InvalidationTracker::HandleProcessExecuteFlagsChange(ULONG Flags) {
  const bool DisableDEP = (Flags & MEM_EXECUTE_OPTION_ENABLE) != 0;

  std::scoped_lock CodeLock(CTX.GetCodeInvalidationMutex());
  std::unique_lock Lock(IntervalsLock);

  if (DisableDEP == DEPDisabled) {
    return;
  }

  DEPDisabled = DisableDEP;

  if (DisableDEP) {
    DEPPromotedIntervals.Clear();

#if !defined(ARCHITECTURE_arm64ec)
    if (GuestBase) {
      // Guest window: nothing is promoted up front (see PromoteDEPRegionLocked). A sweep here
      // would walk the whole 64-bit host address space - FEX's own heap and the JIT pool's RW
      // alias included - and arm write-traps on every data page of the process.
      LogMan::Msg::EFmt("[dep-off] DEP disabled for this process: a committed readable page becomes executable when the guest "
                        "first branches into it");
    } else
#endif
    {
    MEMORY_BASIC_INFORMATION Info;
    uint64_t Address = 0;

    while (VirtualQuery(reinterpret_cast<LPCVOID>(Address), &Info, sizeof(Info))) {
      uint64_t BaseAddress = reinterpret_cast<uint64_t>(Info.BaseAddress);
      if (Info.State == MEM_COMMIT && ProtIsReadable(Info.Protect) && !ProtHasExec(Info.Protect)) {
        const auto AlignedBase = BaseAddress & FEXCore::Utils::FEX_PAGE_MASK;
        const auto AlignedSize = (BaseAddress - AlignedBase + Info.RegionSize + FEXCore::Utils::FEX_PAGE_SIZE - 1) & FEXCore::Utils::FEX_PAGE_MASK;
        FEXCore::IntervalList<uint64_t>::Interval ProtInterval {AlignedBase, AlignedBase + AlignedSize};

        XIntervals.Insert(ProtInterval);
        if (ProtIsWritable(Info.Protect)) {
          RWXIntervals.Insert(ProtInterval);
        }
        DEPPromotedIntervals.Insert(ProtInterval);
      }

      Address = BaseAddress + Info.RegionSize;
    }
    }
  } else {
    for (const auto& Interval : DEPPromotedIntervals) {
      LogMan::Msg::EFmt("[iOS-xrem] via=depflags tracker={} {:#x}-{:#x}", static_cast<void*>(this),
                        Interval.Offset, Interval.End);
#if !defined(ARCHITECTURE_arm64ec)
      // Untrap before forgetting: a promoted region that held compiled code had write access
      // removed by ProtectRWXIntervalsInternal (GetTrapProt -> PAGE_READONLY). Dropping the
      // interval without restoring it would leave the guest's own data read-only, and the next
      // store would be delivered as an access violation. PAGE_READWRITE, not GetUntrapProt:
      // DEPDisabled is already false, and the host page never was executable.
      if (GuestBase && RWXIntervals.Query(Interval.Offset).Enclosed) {
        void* TmpAddress = reinterpret_cast<void*>(Interval.Offset);
        SIZE_T TmpSize = static_cast<SIZE_T>(Interval.End - Interval.Offset);
        ULONG TmpProt;
        NtProtectVirtualMemory(NtCurrentProcess(), &TmpAddress, &TmpSize, PAGE_READWRITE, &TmpProt);
      }
#endif
      XIntervals.Remove(Interval);
      RWXIntervals.Remove(Interval);
    }
    DEPPromotedIntervals.Clear();
  }

  // Invalidate all cached code: previously-compiled blocks may contain NoExec stubs for addresses
  // that are now executable (or reference regions whose executability just changed).
  InvalidateIntervalInternalLocked(0, std::numeric_limits<uint64_t>::max());
}

void InvalidationTracker::HandleImageMap(std::string_view Name, uint64_t Address) {
  auto* Nt = RtlImageNtHeader(reinterpret_cast<HMODULE>(Address));
  auto* SectionsBegin = IMAGE_FIRST_SECTION(Nt);
  auto* SectionsEnd = SectionsBegin + Nt->FileHeader.NumberOfSections;
  uint64_t LastExecutableSectionEnd = 0;

  for (auto* Section = SectionsBegin; Section != SectionsEnd; Section++) {
    if (Section->Characteristics & IMAGE_SCN_MEM_EXECUTE) {
      std::unique_lock Lock(IntervalsLock);

      uint64_t SectionBase = Address + Section->VirtualAddress;
      uint64_t SectionEnd = SectionBase + Section->Misc.VirtualSize;
      XIntervals.Insert({SectionBase, SectionEnd});
      /* iOS-Madeira ml200: FEX reports NOEXEC for libcef code addresses even though the
       * ntdll side proves the map notification arrives and nothing ever removes the
       * interval. So log the actual inserts (with `this`, since each pseudo-process runs
       * its own xtajit64 copy and its own tracker) and pair it with the query-side log in
       * QueryGuestExecutableRange. If the insert and the failing query name different
       * `this`, the registration is landing in a different process's tracker. */
      LogMan::Msg::EFmt("[iOS-xins] tracker={} {} sec={:#x}-{:#x}", static_cast<void*>(this), Name,
                        SectionBase, SectionEnd);
      LastExecutableSectionEnd = std::max(LastExecutableSectionEnd, SectionEnd);
      if (Section->Characteristics & IMAGE_SCN_MEM_WRITE) {
        LogMan::Msg::DFmt("Add image SMC interval: {:X} - {:X}", SectionBase, SectionBase + Section->Misc.VirtualSize);
        RWXIntervals.Insert({SectionBase, SectionBase + Section->Misc.VirtualSize});
      }
    }
  }

  FEX_CONFIG_OPT(MonoHacks, MONOHACKS);
  FEX_CONFIG_OPT(MaxInst, MAXINST);
  FEX_CONFIG_OPT(Multiblock, MULTIBLOCK);

  /* ml712: wine-mono ships its runtime as libmono-2.0-x86_64.dll (the file mscoree's
   * find_mono_dll() looks for on an x86_64/ARM64EC host), which matched neither name
   * above -- so on Marvel Cosmic Invasion the hooks stayed inert and Mono startup paid
   * the full W^X tax: ~735,000 emulated stores from one hot site during init.
   *
   * Recognised, but activation is OPT-IN via MADEIRA_WINEMONO_BRIDGE=1, default OFF, for a
   * correctness reason rather than caution about perf: the bridge reclassifies a detected
   * XCHG from a true atomic exchange into an alias-directed plain write. Deciding that by
   * FILENAME alone would let any unrelated lock-free XCHG in this DLL be treated as a
   * backpatch site and silently lose its atomicity -- and wine-mono's thread-suspend
   * machinery is exactly the kind of lock-free code that would break. The existing two
   * names are Unity's embedded Mono, where the hook has been field-proven since ml648.
   *
   * Verification is deliberately incomplete: wine-mono ships no PDB (its debug directory
   * points at a build-server path) and its exports are ~195KB apart around the hot RIP, so
   * the faulting site CANNOT be symbolized offline to prove it is a code-patching routine.
   * Until it is, this stays off by default and the detected RIP is logged for inspection.
   *
   * NOTE: this storm is a STARTUP cost and is NOT why the game shows no window. Measured
   * between matched checkpoints the rate is ~91/sec by the time FNA3D loads, not the
   * thousands/sec a cumulative-total-over-runtime average suggests. The current stall is
   * thread 007c holding a Mono critical section while workers queue behind it. */
  const bool IsUnityMono = (Name == "mono-2.0-bdwgc.dll" || Name == "mono.dll");
  const bool IsWineMono = (Name == "libmono-2.0-x86_64.dll" || Name == "libmono-2.0-x86.dll");
  bool WineMonoOptIn = false;
  if (IsWineMono) {
    const char* Env = getenv("MADEIRA_WINEMONO_BRIDGE");
    WineMonoOptIn = Env && Env[0] == '1';
    LogMan::Msg::EFmt("[mono-winemono] ml712 module={} base={:#x} opt-in={} (MADEIRA_WINEMONO_BRIDGE={})", Name, Address,
                      WineMonoOptIn ? 1 : 0, Env ? Env : "unset");
  }

  const bool IsMono = IsUnityMono || (IsWineMono && WineMonoOptIn);
  if (IsMono) {
    /* ml623: report the EFFECTIVE settings at EFmt on every branch.
     *
     * MonoHacks defaults to true and is gated on Multiblock && MaxInst >= 500, but
     * MarkMonoDetected() logs nothing and the refusal message is IFmt, which
     * MADEIRA_QUIET eats -- so the ULTRAKILL log could not distinguish "hooks armed"
     * from "hooks refused". That ambiguity also decides whether a later
     * block-splitting A/B is interpretable at all, because the hook explicitly
     * requires all SMC sites to land in ONE block. Never leave this unfalsifiable. */
    const bool Armed = MonoHacks && Multiblock && MaxInst() >= 500;
    LogMan::Msg::EFmt("[mono-cfg] ml623 module={} base={:#x} xend={:#x} | MonoHacks={} Multiblock={} MaxInst={} => {}", Name,
                      Address, LastExecutableSectionEnd, MonoHacks() ? 1 : 0, Multiblock() ? 1 : 0, MaxInst(),
                      Armed          ? "HOOKS ARMED (MarkMonoDetected)" :
                      !MonoHacks()   ? "off: MonoHacks disabled" :
                                       "off: needs Multiblock && MaxInst>=500");
    if (Armed) {
      // Require these settings to ensure we can safely hook all SMC sites in a single block
      CTX.MarkMonoDetected();
      MonoBackpatcherDetectionPending = true;
      MonoBase = Address;
      MonoEnd = LastExecutableSectionEnd;
#ifdef FEX_IOS_HOST
      /* ml648: arm the native bridge HERE, not at FEX startup — Mono is not
       * loaded then. The Mach handler declines to capture while mono_base is 0,
       * so the ordering is enforced by construction rather than by discipline.
       * This is the last of the three one-time liveness lines; without it a run
       * with no activations cannot be told apart from one where the bridge was
       * never wired up at all. */
      ios_fex_mono_arm(MonoBase, MonoEnd);
#endif
    }
  }

  /* ml623: arm the targeted IR capture (PassManager.cpp) once the module that owns the
   * instruction under investigation is mapped. Module + RVA come from the environment so
   * chasing a different miscompile never needs a rebuild; the defaults are the ULTRAKILL
   * Mono emitter store `mov byte ptr [rcx+2], al`.
   *
   * setenv() in WineProcessBridge.m does NOT reach GetEnvironmentVariableW, but it DOES
   * reach FEX's own getenv (proven by MADEIRA_NO_DFE in ml597/598), which is what this uses. */
  {
    const char* CapRVA = getenv("MADEIRA_IRCAP_RVA");
    const char* CapMod = getenv("MADEIRA_IRCAP_MODULE");

    /* ml623b: THE ENV CHANNEL DOES NOT REACH THIS CODE.
     *
     * ml623 shipped env-gated and never armed -- yet [mono-cfg] printed from this very
     * function in the same run, so the function ran and getenv simply returned null.
     * (get_initial_environment copies all of unix `environ` into the Windows block, so
     * the loss is somewhere later: the PE CRT's copy, or the pseudo-process PEB clone.)
     * Rather than theorise, the target is now COMPILED IN and env is only an override.
     * The probe line below reports what getenv actually returned, so the channel
     * question gets settled for free instead of costing another run. */
    {
      static bool Reported = false;
      if (!Reported) {
        Reported = true;
        LogMan::Msg::EFmt("[ircap] ml623b env probe: MADEIRA_IRCAP_RVA={} MADEIRA_IRCAP_MODULE={}", CapRVA ? CapRVA : "(null)",
                          CapMod ? CapMod : "(null)");
      }
    }
    if (!CapRVA || !*CapRVA) {
      CapRVA = "0x4db25b"; // mono-2.0-bdwgc.dll: mov byte ptr [rcx+2], al
    }
    if (CapRVA && *CapRVA) {
      if (!CapMod || !*CapMod) {
        CapMod = "mono-2.0-bdwgc.dll";
      }
      // Case-insensitive: the loader logs both "VERSION.dll" and "version.dll".
      const size_t ModLen = strlen(CapMod);
      bool Match = (Name.size() == ModLen);
      for (size_t i = 0; Match && i < ModLen; ++i) {
        const char A = Name[i] | 0x20;
        const char B = CapMod[i] | 0x20;
        Match = (A == B);
      }
      if (Match) {
        const uint64_t RVA = strtoull(CapRVA, nullptr, 0);
        if (RVA) {
          FEX_MadeiraIRCapTarget = Address + RVA;
          LogMan::Msg::EFmt("[ircap] ml623b ARMED: module={} base={:#x} rva={:#x} => target guest addr {:#x}", Name, Address,
                            RVA, FEX_MadeiraIRCapTarget);
        } else {
          LogMan::Msg::EFmt("[ircap] ml623b DISARMED by MADEIRA_IRCAP_RVA=0 (module={})", Name);
        }
      }
    }
  }
}

InvalidationTracker::InvalidateContainingSectionResult InvalidationTracker::InvalidateContainingSection(uint64_t Address, bool Free) {
  MEMORY_BASIC_INFORMATION Info;
  if (NtQueryVirtualMemory(NtCurrentProcess(), reinterpret_cast<void*>(Address), MemoryBasicInformation, &Info, sizeof(Info), nullptr)) {
    return {Address, 0};
  }

  const auto SectionBase = reinterpret_cast<uint64_t>(Info.AllocationBase);
  auto SectionSize = reinterpret_cast<uint64_t>(Info.BaseAddress) + Info.RegionSize - SectionBase;

  while (!NtQueryVirtualMemory(NtCurrentProcess(), reinterpret_cast<void*>(SectionBase + SectionSize), MemoryBasicInformation, &Info,
                               sizeof(Info), nullptr) &&
         reinterpret_cast<uint64_t>(Info.AllocationBase) == SectionBase) {
    SectionSize += Info.RegionSize;
  }

  InvalidateIntervalInternal(SectionBase, SectionSize);

  if (Free) {
    std::unique_lock Lock(IntervalsLock);
    LogMan::Msg::EFmt("[iOS-xrem] via=section tracker={} {:#x}-{:#x}", static_cast<void*>(this),
                      SectionBase, SectionBase + SectionSize);
    XIntervals.Remove({SectionBase, SectionBase + SectionSize});
    RWXIntervals.Remove({SectionBase, SectionBase + SectionSize});
  }

  return {SectionBase, SectionSize};
}

void InvalidationTracker::InvalidateAlignedInterval(uint64_t Address, uint64_t Size, bool Free) {
  if (!Address) {
    // Match the Windows behaviour when passed a NULL base address.
    Size = std::numeric_limits<uint64_t>::max();
  }

  const auto AlignedBase = Address & FEXCore::Utils::FEX_PAGE_MASK;
  const auto AlignedSize = std::max(Size, (Address - AlignedBase + Size + FEXCore::Utils::FEX_PAGE_SIZE - 1) & FEXCore::Utils::FEX_PAGE_MASK);

  InvalidateIntervalInternal(AlignedBase, AlignedSize);

  if (Free) {
    std::unique_lock Lock(IntervalsLock);
    // ml437 (#74): this fires on EVERY guest free/decommit (the ml201 probe is
    // unconditional) — ml436 logged 4,234 lines of ordinary heap decommit
    // churn, drowning the log and costing a dprintf syscall per free. The
    // signal (which path removes a tracked range) is preserved by the first 40
    // plus a 1-in-64 sample.
    static std::atomic<uint32_t> AlignedRemoveCount;
    const auto N = AlignedRemoveCount.fetch_add(1) + 1;
    if (N <= 40 || !(N & 63)) {
      LogMan::Msg::EFmt("[iOS-xrem] via=aligned #{} tracker={} {:#x}-{:#x}", N, static_cast<void*>(this),
                        AlignedBase, AlignedBase + AlignedSize);
    }
    XIntervals.Remove({AlignedBase, AlignedBase + AlignedSize});
    RWXIntervals.Remove({AlignedBase, AlignedBase + AlignedSize});
  }
}

void InvalidationTracker::ReprotectRWXIntervals(uint64_t Address, uint64_t Size) {
  ProtectRWXIntervalsInternal(Address, Size, false);
}

bool InvalidationTracker::HandleRWXAccessViolation(FEXCore::Core::InternalThreadState* Thread, uint64_t HostPc, uint64_t FaultAddress) {
  const auto [NeedsInvalidate, UntrapProt] = [&](uint64_t Address) -> std::pair<bool, ULONG> {
    std::shared_lock Lock(IntervalsLock);
    if (!RWXIntervals.Query(Address).Enclosed) {
      return {false, 0};
    }
    return {true, GetUntrapProt(Address)};
  }(FaultAddress);

  if (NeedsInvalidate) {
    // IntervalsLock cannot be held during invalidation
    {
      std::scoped_lock Lock(CTX.GetCodeInvalidationMutex());

      InvalidateIntervalInternalLocked(FaultAddress & FEXCore::Utils::FEX_PAGE_MASK, FEXCore::Utils::FEX_PAGE_SIZE);

      // Invalidate, then unprotect the faulting page with the compilation lock held to ensure that any racing invalidations are not dropped.
      ULONG TmpProt;
      void* TmpAddress = reinterpret_cast<void*>(FaultAddress);
      SIZE_T TmpSize = 1;
      NtProtectVirtualMemory(NtCurrentProcess(), &TmpAddress, &TmpSize, UntrapProt, &TmpProt);
    }
    DetectMonoBackpatcherBlock(Thread, HostPc);
    return true;
  }
  return false;
}

bool InvalidationTracker::BeginUntrackedWriteLocked(uint64_t Address, uint64_t Size) {
  return ProtectRWXIntervalsInternal(Address, Size, true);
}

/* iOS-Madeira ml201: log EVERY XIntervals removal, tagged by path.
 *
 * Proven this run: libcef's .text IS inserted (0x7385cf1000-0x7390d2cd23) into the SAME
 * tracker (0x1229612c8) that later reports MISS for 0x73875f0733 and 0x73898408f0 — both
 * inside that range. IntervalList::Query and ::Insert are correct for a sorted disjoint
 * list, so a sub-range must be getting REMOVED. My ntdll-side probes only covered
 * NtProtectVirtualMemory and unmap; Remove is also reachable from
 * HandleProcessExecuteFlagsChange (DEP) and InvalidateAlignedInterval (via
 * NotifyMemoryFree), neither of which was instrumented. Tag each site so the culprit
 * path names itself. */
#if !defined(ARCHITECTURE_arm64ec)
FEXCore::HLE::ExecutableRangeInfo InvalidationTracker::QueryExecutableRange(uint64_t Address) {
  {
    // The hot path: one interval query under a shared lock. A zero Size means "not executable",
    // which only gets a second chance under a guest window with DEP off.
    std::shared_lock Lock(IntervalsLock);
    const auto Info = QueryExecutableRangeLocked(Address);
    if (Info.Size || !DEPDisabled || !GuestBase) {
      return Info;
    }
  }

  /* Lazy DEP-off promotion, the decode-time half of DEP-off under a guest window.
   *
   * On Windows a 32-bit image without IMAGE_DLLCHARACTERISTICS_NX_COMPAT runs with DEP disabled:
   * executing from any committed readable page is legal (unpackers, copy-protection wrappers and
   * runtime thunks rely on it). Here nothing host-executes a guest page; the only thing deciding
   * whether a guest address may be executed is XIntervals, which the decoder asks before it emits
   * anything. So promotion happens here, on the miss: the block is compiled correctly the first
   * time, and a program that never executes from its data pays nothing.
   *
   * Only IntervalsLock is taken, and nothing is invalidated: nothing can have been compiled for a
   * range the decoder is only now asking about, and the compiling thread already holds
   * CodeInvalidationMutex shared. A miss that is not a committed readable page still returns a
   * zero-size result, so a wild branch still faults. */
  std::unique_lock Lock(IntervalsLock);
  if (!XIntervals.Query(Address).Enclosed && !PromoteDEPRegionLocked(Address).End) {
    return {};
  }
  return QueryExecutableRangeLocked(Address);
}

FEXCore::IntervalList<uint64_t>::Interval InvalidationTracker::PromoteDEPRegionLocked(uint64_t Address) {
  // DEP is a property of the guest's memory: a host address outside the window is FEX's heap, the
  // JIT pool or a host module, and must never be promoted.
  if (Address < GuestBase || (Address - GuestBase) >= (1ULL << 32)) {
    return {};
  }

  MEMORY_BASIC_INFORMATION Info;
  if (!VirtualQuery(reinterpret_cast<LPCVOID>(Address), &Info, sizeof(Info))) {
    return {};
  }
  // A guard page reads as readable; promoting one would arm a write-trap on a page whose job is
  // to fault once. Not committed, not readable, or already executable: leave it to fault.
  if ((Info.Protect & (PAGE_GUARD | PAGE_NOACCESS)) || Info.State != MEM_COMMIT || !ProtIsReadable(Info.Protect) ||
      ProtHasExec(Info.Protect)) {
    return {};
  }

  const auto BaseAddress = reinterpret_cast<uint64_t>(Info.BaseAddress);
  const auto AlignedBase = BaseAddress & FEXCore::Utils::FEX_PAGE_MASK;
  const auto AlignedSize = (BaseAddress - AlignedBase + Info.RegionSize + FEXCore::Utils::FEX_PAGE_SIZE - 1) & FEXCore::Utils::FEX_PAGE_MASK;
  FEXCore::IntervalList<uint64_t>::Interval ProtInterval {AlignedBase, AlignedBase + AlignedSize};

  if (DEPPromotedIntervals.Query(Address).Enclosed) {
    return ProtInterval;
  }

  XIntervals.Insert(ProtInterval);
  if (ProtIsWritable(Info.Protect)) {
    // Writable and now executable, so the SMC write-trap must cover it: a self-decrypting unpacker
    // writes the next stage into the page it is about to jump into.
    RWXIntervals.Insert(ProtInterval);
  }
  DEPPromotedIntervals.Insert(ProtInterval);

  static std::atomic<uint32_t> PromoteLogCount {0};
  if (PromoteLogCount.fetch_add(1, std::memory_order_relaxed) < 64) {
    LogMan::Msg::EFmt("[dep-off] promoting guest {:#x}+{:#x} to executable on an execute attempt (prot={:#x})", AlignedBase - GuestBase,
                      AlignedSize, Info.Protect);
  }
  return ProtInterval;
}

// NOTE: IntervalsLock must be held (shared or exclusive) by the caller.
FEXCore::HLE::ExecutableRangeInfo InvalidationTracker::QueryExecutableRangeLocked(uint64_t Address) {
#else
FEXCore::HLE::ExecutableRangeInfo InvalidationTracker::QueryExecutableRange(uint64_t Address) {
  std::shared_lock Lock(IntervalsLock);
#endif
  const auto XResult = XIntervals.Query(Address);
  if (!XResult.Enclosed) {
    return {};
  }
  const auto RWXResult = RWXIntervals.Query(Address);
  if (RWXResult.Enclosed) {
    return {RWXResult.Interval.Offset, RWXResult.Interval.End - RWXResult.Interval.Offset, true};
  } else if (RWXResult.Size && RWXResult.Size < XResult.Size) {
    return {XResult.Interval.Offset, RWXResult.Interval.Offset - XResult.Interval.Offset, false};
  }
  return {XResult.Interval.Offset, XResult.Interval.End - XResult.Interval.Offset, false};
}

void InvalidationTracker::DetectMonoBackpatcherBlock(FEXCore::Core::InternalThreadState* Thread, uint64_t HostPc) {
  if (!MonoBackpatcherDetectionPending) {
    return;
  }

  if (!CTX.IsAddressInCodeBuffer(Thread, HostPc)) {
    return;
  }

#if !defined(ARCHITECTURE_arm64ec)
  // RestoreRIPFromHostPC returns a guest RIP, while MonoBase/MonoEnd come from HandleImageMap and
  // are host addresses. Lift the RIP for the range test and the code reads; BlockEntry below stays
  // guest because it is a FEXCore invalidation key.
  const uint64_t GuestRIP = CTX.RestoreRIPFromHostPC(Thread, HostPc);
  const uint64_t RIP = GuestRIP ? GuestRIP + GuestBase : 0;
#else
  uint64_t RIP = CTX.RestoreRIPFromHostPC(Thread, HostPc);
#endif
  if (!RIP || RIP < MonoBase || RIP >= MonoEnd) {
    return;
  }

  static constexpr uint8_t XChgOp = 0x87;
  if (*reinterpret_cast<uint8_t*>(RIP) != XChgOp && *reinterpret_cast<uint8_t*>(RIP + 1) != XChgOp) {
    return;
  }

  uint64_t BlockEntry = CTX.GetGuestBlockEntry(Thread);
  LogMan::Msg::DFmt("Detected mono backpatcher at: {:X}", BlockEntry);

  /* ml712: name the site at EFmt, once, with module-relative RVAs and the bytes.
   *
   * The DFmt line above is eaten by MADEIRA_QUIET, so a run could neither confirm which
   * guest instruction was reclassified nor let it be checked afterwards. That matters more
   * for wine-mono than for Unity's Mono: this reclassifies an XCHG from a true atomic
   * exchange into an alias-directed plain write, wine-mono ships no PDB, and its exports
   * sit ~195KB apart around the hot region -- so the RVA printed here is the ONLY evidence
   * available for deciding whether the site is a genuine code-patching routine or an
   * unrelated lock-free exchange that must keep its atomicity. Print it before marking. */
  {
    static bool Reported = false;
    if (!Reported) {
      Reported = true;
      const auto* Bytes = reinterpret_cast<const uint8_t*>(RIP);
      LogMan::Msg::EFmt("[mono-site] ml712 FIRST detect rip={:#x} (mono+{:#x}) block={:#x} (mono+{:#x}) "
                        "bytes={:02x} {:02x} {:02x} {:02x} {:02x} {:02x} {:02x} {:02x}",
#if !defined(ARCHITECTURE_arm64ec)
                        RIP, RIP - MonoBase, BlockEntry, BlockEntry + GuestBase - MonoBase, Bytes[0], Bytes[1], Bytes[2], Bytes[3],
                        Bytes[4], Bytes[5], Bytes[6], Bytes[7]);
#else
                        RIP, RIP - MonoBase, BlockEntry, BlockEntry - MonoBase, Bytes[0], Bytes[1], Bytes[2], Bytes[3],
                        Bytes[4], Bytes[5], Bytes[6], Bytes[7]);
#endif
    }
  }
#ifndef FEX_IOS_HOST
  /* ml648: SKIPPED ON iOS. DisableSMCDetection() reprotects every RWX interval
   * as WRITABLE, and iOS will never grant write on the guest VA — that is the
   * entire reason the RW alias exists. On iOS it can only churn protections
   * that cannot change. The win here comes purely from MarkMonoBackpatcherBlock
   * plus the alias-directed MonoBackpatcherWrite. */
  DisableSMCDetection();
#endif
  {
    std::scoped_lock CodeLock(CTX.GetCodeInvalidationMutex());
    CTX.MarkMonoBackpatcherBlock(BlockEntry);
  }
#if !defined(ARCHITECTURE_arm64ec)
  // InvalidateAlignedInterval takes host addresses like the rest of this class.
  InvalidateAlignedInterval(BlockEntry + GuestBase, FEXCore::Utils::FEX_PAGE_SIZE, false);
#else
  InvalidateAlignedInterval(BlockEntry, FEXCore::Utils::FEX_PAGE_SIZE, false);
#endif
}

void InvalidationTracker::DisableSMCDetection() {
  std::unique_lock Lock(IntervalsLock);
  SMCDetectionDisabled = true;
  uint64_t Address = 0;

  // Reprotect all RWX intervals as writable
  FEXCore::IntervalList<uint64_t>::QueryResult Query;
  do {
    Query = RWXIntervals.Query(Address);
    if (Query.Enclosed) {
      void* TmpAddress = reinterpret_cast<void*>(Address);
      SIZE_T TmpSize = static_cast<SIZE_T>(Query.Size);
      ULONG TmpProt;
      NtProtectVirtualMemory(NtCurrentProcess(), &TmpAddress, &TmpSize, GetUntrapProt(Address), &TmpProt);
    }
    Address += Query.Size;
  } while (Query.Size);
}

ULONG InvalidationTracker::GetTrapProt(uint64_t Address) const {
  if (DEPDisabled && DEPPromotedIntervals.Query(Address).Enclosed) {
    return PAGE_READONLY;
  }
  return PAGE_EXECUTE_READ;
}

ULONG InvalidationTracker::GetUntrapProt(uint64_t Address) const {
  if (DEPDisabled && DEPPromotedIntervals.Query(Address).Enclosed) {
    return PAGE_READWRITE;
  }
  return PAGE_EXECUTE_READWRITE;
}

void InvalidationTracker::InvalidateIntervalInternal(uint64_t Address, uint64_t Size) {
  std::scoped_lock CodeLock(CTX.GetCodeInvalidationMutex());
  InvalidateIntervalInternalLocked(Address, Size);
}

void InvalidationTracker::InvalidateIntervalInternalLocked(uint64_t Address, uint64_t Size) {
  // NOTE: This assumes CodeInvalidationMutex is locked by the caller
#if !defined(ARCHITECTURE_arm64ec)
  // The boundary into FEXCore: Address is a host address, FEXCore's code buffers and lookup caches
  // are keyed on guest addresses. Clip the range to the window and convert; the part outside the
  // window has no guest counterpart (the JIT pool's own addresses also flow through the BTCpuNotify*
  // callbacks) and cannot name guest code. The "everything" range (0, max) maps to the whole window.
  if (GuestBase) {
    const uint64_t WindowEnd = GuestBase + (1ULL << 32);
    const uint64_t Begin = std::max(Address, GuestBase);
    const uint64_t RangeEnd = Size > std::numeric_limits<uint64_t>::max() - Address ? std::numeric_limits<uint64_t>::max() : Address + Size;
    const uint64_t End = std::min(RangeEnd, WindowEnd);
    if (Begin >= End) {
      return;
    }
    Address = Begin - GuestBase;
    Size = End - Begin;
  }
#endif
  CTX.InvalidateCodeBuffersCodeRange(Address, Size);
  for (auto Thread : Threads) {
    CTX.InvalidateThreadCachedCodeRange(Thread.second, Address, Size);
  }
}

bool InvalidationTracker::ProtectRWXIntervalsInternal(uint64_t Address, uint64_t Size, bool ForWriteLocked) {
  const auto End = Address + Size;
  std::shared_lock Lock(IntervalsLock);

  if (SMCDetectionDisabled) {
    return false;
  }

  bool HitRWXInterval = false;
  do {
    const auto Query = RWXIntervals.Query(Address);
    if (Query.Enclosed) {
      if (!HitRWXInterval) {
        if (ForWriteLocked) {
          // If we are protecting as writable, then the entire range must be invalidated before any protections are
          // applied and the invalidation mutex must be locked throughout.
          // Do this lazily only when an RWX region is actually hit.
          // NOTE: This assumes CodeInvalidationMutex is locked by the caller
          InvalidateIntervalInternalLocked(Address, Size);
        }
        HitRWXInterval = true;
      }
      void* TmpAddress = reinterpret_cast<void*>(Address);
      SIZE_T TmpSize = static_cast<SIZE_T>(std::min(End, Address + Query.Size) - Address);
      ULONG TmpProt;
      NtProtectVirtualMemory(NtCurrentProcess(), &TmpAddress, &TmpSize, ForWriteLocked ? GetUntrapProt(Address) : GetTrapProt(Address), &TmpProt);
    } else if (!Query.Size) {
      // No more regions past `Address` in the interval list
      break;
    }

    Address += Query.Size;
  } while (Address < End);

  return HitRWXInterval;
}

} // namespace FEX::Windows
