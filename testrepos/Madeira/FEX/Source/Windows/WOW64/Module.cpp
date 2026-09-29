// SPDX-License-Identifier: MIT
/*
$info$
tags: Bin|WOW64
desc: Implements the WOW64 BT module API using FEXCore
$end_info$
*/

// Thanks to André Zwing, whose ideas from https://github.com/AndreRH/hangover this code is based upon

#include <FEXCore/fextl/fmt.h>
#include <FEXCore/Core/X86Enums.h>
#include <FEXCore/Core/SignalDelegator.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/HLE/SyscallHandler.h>
#include <FEXCore/Config/Config.h>
#include <FEXCore/Utils/Allocator.h>
#include <FEXCore/Utils/LogManager.h>
#include <FEXCore/Utils/Threads.h>
#include <FEXCore/Utils/Profiler.h>
#include <FEXCore/Utils/SHMStats.h>
#include <FEXCore/Utils/EnumOperators.h>
#include <FEXCore/Utils/EnumUtils.h>
#include <FEXCore/Utils/FPState.h>
#include <FEXCore/Utils/ArchHelpers/Arm64.h>
#include <FEXCore/Utils/TypeDefines.h>
#include <FEXCore/Utils/SignalScopeGuards.h>

#include "Windows/Common/Allocator.h"
#include "Windows/Common/EnvironmentVariablesHandling.h"
#include "Windows/Common/FEXUnixLib.h"
#include "Common/CallRetStack.h"
#include "Common/JITGuardPage.h"
#include "Common/Config.h"
#include "Common/Exception.h"
#include "Common/TSOHandlerConfig.h"
#include "Common/ImageTracker.h"
#include "Common/InvalidationTracker.h"
#include "Common/OvercommitTracker.h"
#include "Common/CPUFeatures.h"
#include "Common/Logging.h"
#include "Common/Module.h"
#include "Common/CRT/CRT.h"
#include "Common/PortabilityInfo.h"
#include "Common/Handle.h"
#include "DummyHandlers.h"
#include "BTInterface.h"
#include "Windows/Common/SHMStats.h"

#include <cstdint>
#include <cstdlib> // MADEIRA ml1430: getenv for MADEIRA_WOW_SYSCALL_SWEEP
#include <type_traits>
#include <atomic>
#include <mutex>
#include <utility>
#include <unordered_map>
#include <ntstatus.h>
#include <windef.h>
#include <winternl.h>
#include <wine/debug.h>
#include <wine/unixlib.h>

#include "IosTeb.h"

using FEX::Windows::WOW64::CurrentTEB;

#ifdef FEX_IOS_HOST
/* MADEIRA: iOS host support for the WoW64 module. Mirrors the equivalents in ARM64EC/Module.cpp;
 * see the comments there for the full history behind each.
 *
 * Note that most of the iOS port comes for free: Logging, CPUFeatures, CallRetStack, FEXUnixLib and
 * InvalidationTracker are shared through the CommonWindows/CommonWindowsRuntime targets, and
 * CRT_iOS.cpp replaces the hand-rolled CRT for the whole runtime target. Only the pieces below are
 * per-module, because each of them needs storage or an import inside *this* PE. */

/* This PE statically links its own copy of FEXCore, separate from both the iOS app's
 * libFEXCore_Base.a and xtajit64.dll's copy, so it needs its own storage for the RX->RW alias
 * distance used by every JIT code write. Set in BTCpuProcessInit before InitCore(), because the
 * dispatcher's emit path reads it through the JIT class constructor. */
namespace FEXCore::DualMap {
int64_t WriteOffset = 0;
} // namespace FEXCore::DualMap

/* Storage for the TEB TSD offset declared in IosTeb.h. Shared with IosMonoBridge.cpp, which also
 * has to read a TEB without touching x18. */
namespace FEX::Windows::WOW64 {
uint32_t IosTebTsdOffset = 0;
}
static uint32_t IosTebTsdImportFound = 0;

#ifdef FEX_IOS_HOST
/* MADEIRA: FEXCore has its OWN, C-linkage copy of the same offset
 * (FEXCore/Source/Interface/Core/ArchHelpers/Arm64Emitter.cpp:29, declared in Arm64Emitter.h:109),
 * which the JIT emitters use when they have to materialise a TEB read into emitted code
 * (Dispatcher.cpp:129/233/379/394, Arm64Emitter.cpp:894, MiscOps.cpp:346). Every one of those sites
 * is inside `#ifdef ARCHITECTURE_arm64ec`, so in THIS build they are not compiled and the variable
 * is unread - but the storage exists in this link, ARM64EC/Module.cpp:841 sets it, and the only
 * thing keeping a zero here from emitting `ldr x, [x, #0]` against TPIDRRO_EL0 is that one #ifdef.
 * Publish it from the same import, so the two modules are initialised identically and any future
 * code path that starts reading it in the non-EC build gets the right slot instead of slot 0
 * (which belongs to libpthread). */
extern "C" uint32_t IosTebTsdOffset;
#endif

/* MADEIRA ml800: report-then-die for BTCpuProcessInit.
 *
 * FIFTH DEVICE RUN, trap #5: the module took `hlt #1` at libwow64fex+0x10220c
 * (FEXCore::Assert::ForcedAssert) with lr = BTCpuProcessInit+0xae4 and NOT ONE CHARACTER of
 * explanation in the log. Cause: the ERROR_AND_DIE_FMT that trapped sits at the very top of
 * BTCpuProcessInit, ~25 lines BEFORE FEX::Windows::Logging::Init(), so LogMan had no handler
 * installed and MFmt formatted the message into the void. Every early failure in this function
 * was therefore indistinguishable from a random trap - and so were the [wow-base] and
 * [va-profile] lines further down, which simply never ran.
 *
 * IosRawReport writes through ntdll's __wine_dbg_output (the path ntdll's own ERR() lines take
 * into Documents/madeira-log.txt) and deliberately formats into a STACK buffer: one of the things
 * it has to be able to report is "there is no host arena", i.e. the state in which every FEX heap
 * allocation returns NULL, so it must not allocate. */
/* Writes one formatted line straight to ntdll's __wine_dbg_output (the path ntdll's own ERR()
 * lines take), without LogMan, the config layer or a TEB. Used only before Logging::Init() can
 * have run, and only for the process-init reports below. */
static void IosRawWrite(const char* Str, size_t) {
  static int(__cdecl * DbgOut)(const char*);
  static bool Resolved;
  if (!Resolved) {
    Resolved = true;
    DbgOut = reinterpret_cast<decltype(DbgOut)>(GetProcAddress(GetModuleHandleA("ntdll.dll"), "__wine_dbg_output"));
  }
  if (DbgOut) {
    DbgOut(Str);
  }
}

template<typename... Args>
static void IosRawReport(::fmt::format_string<Args...> Fmt, Args&&... args) {
  char Buf[1024];
  const auto Res = ::fmt::format_to_n(Buf, sizeof(Buf) - 2, Fmt, std::forward<Args>(args)...);
  size_t Len = Res.size < (sizeof(Buf) - 2) ? Res.size : (sizeof(Buf) - 2);
  Buf[Len++] = '\n';
  Buf[Len] = '\0';
  IosRawWrite(Buf, Len);
}

/* Print first, through a path that works before Logging::Init(), then die exactly as before.
 * Refusing to run stays the behaviour - the only thing that changes is that the reason is now
 * in the log. */
#define IOS_WOW64_REPORT_AND_DIE(...)                     \
  do {                                                    \
    IosRawReport("A [wow64-init] FATAL: " __VA_ARGS__);    \
    ERROR_AND_DIE_FMT(__VA_ARGS__);                        \
  } while (0)

/* MADEIRA ml787: the VA band selector's deferred beacon buffer (rpmalloc's
 * ios_fex_band_select, see the ml751 comment there). It runs during this PE's
 * rpmalloc init - before LogMan, before the TEB is usable - so it appends to a
 * plain byte array and somebody else has to flush it. ARM64EC/Module.cpp does
 * that for xtajit64; this module never did, so on the FOURTH DEVICE RUN the
 * selector's verdict only reached the log by accident (a bare WriteFile to
 * STD_ERROR_HANDLE) and the module itself had no idea it had no arena.
 * ios_fex_band_base/_end are declared by Common/CallRetStack.h. */
extern "C" char ios_va_log[];
extern "C" int ios_va_log_len;

/* MADEIRA: the dual-mapped JIT pool's RX range, defined in rpmalloc.c beside ios_fex_band_base and
 * consumed by FEXCore::Allocator::VirtualAlloc's executable path. Published below, next to
 * FEXCore::DualMap::WriteOffset, from the same two environment variables. */
extern "C" uintptr_t ios_fex_jit_pool_rx;
extern "C" uintptr_t ios_fex_jit_pool_end;
#endif

namespace ControlBits {
// When this is unset, a thread can be safely interrupted and have its context recovered
// IMPORTANT: This can only safely be written by the owning thread
static constexpr uint32_t IN_JIT {1U << 0};

// JIT entry polls this bit until it is unset, at which point CONTROL_IN_JIT will be set
static constexpr uint32_t PAUSED {1U << 1};

// When this is set, the CPU context stored in the CPU area has not yet been flushed to the FEX TLS
static constexpr uint32_t WOW_CPU_AREA_DIRTY {1U << 2};
}; // namespace ControlBits

struct TLS {
  enum class Slot : size_t {
    ENTRY_CONTEXT = WOW64_TLS_MAX_NUMBER - 1,  // 18
    CONTROL_WORD = WOW64_TLS_MAX_NUMBER - 2,   // 17
    /* MADEIRA: upstream puts ThreadState in WOW64_TLS_MAX_NUMBER - 3 == 16. Under Wine slot 16 is
     * TAKEN: it is ntdll's `_errno()` cell (`wine/dlls/ntdll/ntdll_misc.h:36`
     * `#define NTDLL_TLS_ERRNO 16`, returned as `&NtCurrentTeb()->TlsSlots[16]` by
     * `wine/dlls/ntdll/thread.c:445`, and reserved on its own line in
     * `wine/dlls/ntdll/loader.c:5501`). Wine's ntdll writes it directly, NOT through TlsSetValue,
     * so the PEB TlsBitmap reservation of 0..WOW64_TLS_MAX_NUMBER-1 does not protect it.
     *
     * That is where the `[wow64-tls] … (was 0x2 - NOT ZERO…)` line came from on the EIGHTH DEVICE
     * RUN: 2 is ENOENT, left in the cell by ntdll before FEX ever ran. The collision is mutual and
     * would have been fatal in both directions — any `errno` store truncates this module's
     * ThreadState pointer to the value of errno, and this module's 64-bit store makes `errno`
     * return the low half of a pointer.
     *
     * 14 and 15 are unassigned by both Windows' WoW64 TLS layout (which defines 1..13) and by every
     * write in this Wine tree (`TlsSlots` is written only at 1, 3, 5, 7, 8, 10 by wow64.dll/ntdll/
     * win32u, and 16 by ntdll's errno), and they are inside the range the bitmap reserves, so
     * TlsAlloc can never hand them out either. */
    THREAD_STATE = WOW64_TLS_MAX_NUMBER - 5,      // 14
    CACHED_CALLRET_SP = WOW64_TLS_MAX_NUMBER - 4, // 15
  };

  _TEB* TEB;

  explicit TLS(_TEB* TEB)
    : TEB(TEB) {}

  // HOST: wow64.dll points this slot at `(WOW64INFO *)(peb32 + 1)`, i.e. just past the 32-bit PEB
  // it allocated (wine/dlls/wow64/syscall.c:990, :994) - a host pointer inside the window, not the
  // guest value the 32-bit PEB's own self-reference carries. Dereferenced natively here.
  WOW64INFO& Wow64Info() const {
    return *reinterpret_cast<WOW64INFO*>(TEB->TlsSlots[WOW64_TLS_WOW64INFO]);
  }

  std::atomic<uint32_t>& ControlWord() const {
    // TODO: Change this when libc++ gains std::atomic_ref support
    return reinterpret_cast<std::atomic<uint32_t>&>(TEB->TlsSlots[FEXCore::ToUnderlying(Slot::CONTROL_WORD)]);
  }

  CONTEXT*& EntryContext() const {
    return reinterpret_cast<CONTEXT*&>(TEB->TlsSlots[FEXCore::ToUnderlying(Slot::ENTRY_CONTEXT)]);
  }

  FEXCore::Core::InternalThreadState*& ThreadState() const {
    return reinterpret_cast<FEXCore::Core::InternalThreadState*&>(TEB->TlsSlots[FEXCore::ToUnderlying(Slot::THREAD_STATE)]);
  }

  // MADEIRA: the same slot, for the paths that can run BEFORE BTCpuThreadInit has filled it in.
  //
  // SIXTH DEVICE RUN: the exception handler read this slot as 2 and dereferenced it at +0x40
  // (FEXCORE_PROFILE_ACCUMULATION, libwow64fex+0xffe50), turning a reportable JIT fault into a
  // second meaningless one. A plain `!= nullptr` test did not help, because the value was not
  // null - it was a small integer.
  //
  // CORRECTED (EIGHTH DEVICE RUN): the 2 was NOT stale TEB content. It WAS a collision - the slot
  // was 16, which is ntdll's `_errno()` cell under Wine, and 2 is ENOENT. See the Slot enum above;
  // ThreadState now lives in 14. This guard stays anyway, because it is what makes a pre-ThreadInit
  // exception reportable instead of fatal, and it costs one compare.
  //
  // Any value below the lowest address anything can be mapped at is "not initialised". 64 KiB is
  // deliberately conservative: on this host nothing is mapped below 4 GiB at all.
  static constexpr size_t ThreadStateSlot = FEXCore::ToUnderlying(Slot::THREAD_STATE);

  uint64_t RawThreadState() const {
    return reinterpret_cast<uint64_t>(TEB->TlsSlots[ThreadStateSlot]);
  }

  FEXCore::Core::InternalThreadState* ThreadStateIfInitialised() const {
    const uint64_t Raw = RawThreadState();
    if (Raw < 0x10000) {
      return nullptr;
    }
    return reinterpret_cast<FEXCore::Core::InternalThreadState*>(Raw);
  }

  // This is used to work around user callback handling (see Wow64KiUserCallbackDispatcher in wine) unbalancing the
  // call-ret stace since user callbacks are returned from using a syscall that we can't really intercept.
  uint64_t& CachedCallRetSp() const {
    return reinterpret_cast<uint64_t&>(TEB->TlsSlots[FEXCore::ToUnderlying(Slot::CACHED_CALLRET_SP)]);
  }
};

struct FrontendThreadData {
  bool InLockedRWXRead {};
  // MADEIRA ml1430: syscall parking for the code-buffer sweeper (see IosWowSyscallC).
  // IosInSim is the sweeper's per-thread "may be executing emitted code" byte; it is 0
  // only while the thread is blocked in an outermost-level syscall whose return can be
  // redirected. IosMigrated is set by the sweeper when it moves the thread to a newer
  // generation; IosSyscallArmed/IosSyscallDepth are owner-only.
  volatile uint8_t IosInSim {1};
  volatile uint8_t IosMigrated {0};
  bool IosSyscallArmed {};
  bool IosSweepRegistered {};
  uint32_t IosSyscallDepth {};
};

class WowSyscallHandler;

// MADEIRA: the guest window.
//
// On iOS nothing can be mapped below 4 GiB (XNU forces a 4 GiB __PAGEZERO on arm64 binaries), and
// every Windows "process" is a thread in one Mach task sharing one address space - so the classic
// WoW64 assumption that a guest address equals a host address is impossible. Instead each 32-bit
// pseudo-process gets a reserved 4 GiB host range and guest address `a` lives at `GuestBase + a`.
//
// The rules, which the rest of this file is written to:
//   - Anything the 32-bit guest can observe - EIP, ESP and the other GPRs, the FS base, the BOP
//     code pointers, anything in a WOW64_CONTEXT - is a GUEST address, always below 4 GiB.
//   - Anything this module, wow64.dll, ntdll or the unix side dereferences is a HOST address.
//   - FEXCore is told the base once (CONFIG_GUEST32BASE) and does the conversion in the JIT; this
//     file only has to convert at the boundaries FEXCore does not see.
//   - Handles, sizes, flags and packed values are never offset.
//
// GuestBase stays 0 when this module is not running under the iOS host, in which case everything
// below degrades to the upstream identity behaviour.
namespace GuestWindow {
// Wine-private NtQueryInformationProcess class, declared next to ProcessWineMakeProcessSystem in
// wine/include/winternl.h. Returns the ULONG_PTR host address of guest address 0 for the target
// process, or 0 when it is not a WoW process. Deliberately spelled out here rather than pulling in
// a Wine header, because this module is built against the mingw SDK headers.
static constexpr ULONG ProcessWineIosWowGuestBase = 1010;

// Host address of guest address 0. Read once in BTCpuProcessInit, never written again.
uint64_t Base {};

// The guest address space is exactly 4 GiB; anything outside [Base, Base + 4GiB) is a genuine host
// address (FEX's own heap, the JIT pool, ntdll) with no guest counterpart.
static constexpr uint64_t Size {1ULL << 32};

// Guest -> host. Pure arithmetic: guest address 0 maps to the (deliberately unmapped) first page of
// the window, so a guest null dereference still faults, exactly as it would under an identity map.
inline uint64_t ToHost(uint64_t Guest) {
  return Base + Guest;
}

inline void* ToHostPtr(uint64_t Guest) {
  return reinterpret_cast<void*>(Base + Guest);
}

// Host -> guest, for addresses that are known to be inside the window.
inline uint64_t ToGuest(uint64_t Host) {
  return Host - Base;
}

inline bool Contains(uint64_t Host) {
  return !Base || (Host >= Base && (Host - Base) < Size);
}

// Host -> guest for addresses that may or may not be in the window; anything outside is passed
// through unchanged so host-only faults and host-only ranges keep their real addresses.
inline uint64_t ToGuestIfInWindow(uint64_t Host) {
  return (Base && Host >= Base && (Host - Base) < Size) ? Host - Base : Host;
}
} // namespace GuestWindow

namespace {
namespace BridgeInstrs {
  // These directly jumped to by the guest to make system calls
  void* Syscall {};
  void* UnixCall {};
} // namespace BridgeInstrs

fextl::unique_ptr<FEXCore::Context::Context> CTX;
fextl::unique_ptr<FEX::DummyHandlers::DummySignalDelegator> SignalDelegator;
fextl::unique_ptr<WowSyscallHandler> SyscallHandler;
fextl::unique_ptr<FEX::Windows::StatAlloc> StatAllocHandler;

std::optional<FEX::Windows::InvalidationTracker> InvalidationTracker;
std::optional<FEX::Windows::CPUFeatures> CPUFeatures;
std::optional<FEX::Windows::OvercommitTracker> OvercommitTracker;
std::optional<FEX::Windows::ImageTracker> ImageTracker;

std::mutex ThreadCreationMutex;
// Map of TIDs to their FEX thread state, `ThreadCreationMutex` must be locked when accessing
std::unordered_map<DWORD, FEXCore::Core::InternalThreadState*> Threads;

decltype(__wine_unix_call_dispatcher) WineUnixCall;

// HOST: this module is native aarch64 code, so it calls the real NtQueryInformationThread rather
// than wow64.dll's thunk - TebBaseAddress is the 64-bit TEB's host address, never the guest value
// the wow64_NtQueryInformationThread(ThreadBasicInformation) path hands to 32-bit callers.
// ClientId is a TID pair, never offset.
std::pair<NTSTATUS, TLS> GetThreadTLS(HANDLE Thread) {
  // MADEIRA ml970: the current-thread pseudo-handle needs no round trip at all.
  // On this target NtQueryInformationThread(ThreadBasicInformation) is a
  // wineserver request (get_thread_info), and BTCpuGetContext/BTCpuSetContext
  // are called with GetCurrentThread() by every internal wow64 path -- see the
  // comment on BTCpuGetContext below. CurrentTEB() is the same answer, read
  // from the register.
  if (Thread == GetCurrentThread()) {
    return {STATUS_SUCCESS, TLS {CurrentTEB()}};
  }

  THREAD_BASIC_INFORMATION Info;
  const NTSTATUS Err = NtQueryInformationThread(Thread, ThreadBasicInformation, &Info, sizeof(Info), nullptr);
  return {Err, TLS {reinterpret_cast<_TEB*>(Info.TebBaseAddress)}};
}

TLS GetTLS() {
  return TLS {CurrentTEB()};
}

FrontendThreadData* GetFrontendThreadData(FEXCore::Core::InternalThreadState* Thread) {
  return static_cast<FrontendThreadData*>(Thread->FrontendPtr);
}

/* MADEIRA ml1430: WOW64 SYSCALL PARKING FOR THE CODE-BUFFER SWEEPER.
 *
 * The emitted code of every process shares one code buffer that is replaced by a new
 * generation when it fills; an old generation is freed only when no thread references it.
 * The ml460 sweeper moves parked threads to the newest generation, but only the ARM64EC
 * frontend ever registered threads with it: there, a syscall leaves emitted code
 * (InSimulation=0). Here a syscall is a call OUT of an emitted block (BranchOps.cpp
 * DEF_OP(Syscall)), so a thread waiting in a syscall has a return address into its
 * generation on the stack and could never be moved. Device log: a desktop client's
 * 32-bit browser processes (hundreds of mostly waiting threads) kept 30 generations live,
 * 720 MB of the 896 MB pool, until code allocation failed and a thread died at the
 * out-of-pool fault.
 *
 * What the block does after the handler returns is fixed for these syscalls: the bridge
 * instructions end their block, and the tail spills nothing new: it restores SP, refills
 * every static register, clears InSyscallInfo, pops the dynamic registers and exits to the
 * dispatcher at the RIP the handler wrote (OpcodeDispatcher.cpp SyscallOp, OS_GENERIC:
 * no result register). The dispatcher's LoopTopFillSRA entry does exactly that from the
 * dispatcher's own stack pointer. So a thread that is moved while blocked resumes there
 * instead of in its old block, and its old generation can go.
 *
 * Only the outermost syscall of a simulation is ever parked: a callback that re-enters
 * simulation from inside a syscall sets IosInSim=1 again (BTCpuSimulateImpl), and nested
 * syscalls are never parked, so no emitted frame other than the one being redirected can
 * be below a moved thread. MADEIRA_WOW_SYSCALL_SWEEP=0 disables all of it. */
extern "C" void IosSweepRegisterThreadEx(FEXCore::Core::InternalThreadState* Thread, volatile uint8_t* InSimPtr,
                                         volatile uint8_t* MigratedPtr);
extern "C" void IosSweepUnregisterThread(FEXCore::Core::InternalThreadState* Thread);
extern "C" uint64_t IosCodeBufferSweepGate;

static bool IosWowSweepEnabled() {
  static std::atomic<int8_t> Cached {-1};
  int8_t V = Cached.load(std::memory_order_relaxed);
  if (V < 0) {
    const char* E = getenv("MADEIRA_WOW_SYSCALL_SWEEP");
    V = (E && E[0] == '0') ? 0 : 1;
    Cached.store(V, std::memory_order_relaxed);
    LogMan::Msg::EFmt("[wow-sweep] ml1430 syscall parking {} (MADEIRA_WOW_SYSCALL_SWEEP=0 disables)", V ? "on" : "off");
  }
  return V != 0;
}

// Leaving emitted code for a blocking call: the sweeper may now move this thread.
static void IosWowPark(FrontendThreadData* TD) {
  if (TD && TD->IosSyscallArmed) {
    __atomic_store_n(&TD->IosInSim, 0, __ATOMIC_RELEASE);
  }
}

// Back from the call: publish "in simulation" before looking at the gate (Dekker pair with
// IosMaybeSweepCodeBuffers), then wait out any sweep, so IosMigrated is final when read.
static void IosWowUnpark(FrontendThreadData* TD) {
  if (!TD || TD->IosInSim) {
    return;
  }
  __atomic_store_n(&TD->IosInSim, 1, __ATOMIC_RELAXED);
  __atomic_thread_fence(__ATOMIC_SEQ_CST);
  while (__atomic_load_n(&IosCodeBufferSweepGate, __ATOMIC_ACQUIRE)) {
    __asm volatile("yield");
  }
}

// Returns the HOST address of the 32-bit TEB paired with the given 64-bit TEB.
uint64_t GetWowTEBHost(void* TEB) {
  static constexpr size_t WowTEBOffsetMemberOffset {0x180c};
  return static_cast<uint64_t>(
    *reinterpret_cast<LONG*>(reinterpret_cast<uintptr_t>(TEB) + WowTEBOffsetMemberOffset) + reinterpret_cast<uint64_t>(TEB));
}

// MADEIRA: the GUEST address of TEB32, which is what goes into the FS segment base and the GDT.
// ntdll allocates the TEB pair inside the window for a WoW process, so this is always < 4 GiB and
// no widening is needed - the segment caches in CPUState are uint32_t and SetGDTBase takes a
// uint32_t, which is exactly why the base register exists instead of a segment-base hack.
uint64_t GetWowTEB(void* TEB) {
  const uint64_t Host = GetWowTEBHost(TEB);
  LOGMAN_THROW_A_FMT(GuestWindow::Contains(Host), "TEB32 must live inside the guest window");
  return GuestWindow::ToGuest(Host);
}

bool IsDispatcherAddress(uint64_t Address) {
  const auto& Config = SignalDelegator->GetConfig();
  return Address >= Config.DispatcherBegin && Address < Config.DispatcherEnd;
}

bool IsAddressInJit(uint64_t Address) {
  if (IsDispatcherAddress(Address)) {
    return true;
  }

  auto Thread = GetTLS().ThreadState();
  return Thread->CTX->IsAddressInCodeBuffer(Thread, Address);
}

// MADEIRA: last-resort image name, read out of the PE itself.
//
// HandleImageMap normally names an image from its section file name
// (NtQueryVirtualMemory/MemoryMappedFilenameInformation -> wineserver get_mapping_filename), which
// only answers for a view the server knows about. The 32-bit ntdll is mapped by the unix side's
// WoW64 path and the 64-bit loader does not track i386 modules at all, so there is no guarantee of
// a name for it. An empty name is not fatal (it is used for logging, the CodeMap id and the
// volatile-metadata lookup) but it makes every i386 module anonymous in the log, which is exactly
// what the image-map crash was diagnosed from.
//
// The export directory's Name RVA is the image's own idea of its file name and is present in every
// DLL Wine builds. It is only a NAME, never an address: nothing here is dereferenced as a pointer
// beyond the image itself, which the caller has already proven is a mapped host address.
fextl::string GetImageNameFromExports(uint64_t HostAddress, IMAGE_NT_HEADERS* Nt) {
  ULONG Size = 0;
  const auto* Exports =
    reinterpret_cast<const IMAGE_EXPORT_DIRECTORY*>(RtlImageDirectoryEntryToData(reinterpret_cast<HMODULE>(HostAddress), TRUE,
                                                                                IMAGE_DIRECTORY_ENTRY_EXPORT, &Size));
  if (!Exports || Size < sizeof(IMAGE_EXPORT_DIRECTORY) || !Exports->Name || Exports->Name >= Nt->OptionalHeader.SizeOfImage) {
    return {};
  }

  const auto* Name = reinterpret_cast<const char*>(HostAddress + Exports->Name);
  // Bound the read by the image, so a corrupt/unterminated RVA cannot walk off the end of the map.
  const size_t MaxLen = Nt->OptionalHeader.SizeOfImage - Exports->Name;
  size_t Len = 0;
  while (Len < MaxLen && Name[Len]) {
    ++Len;
  }
  return fextl::string {Name, Len};
}

// Address is always a HOST address here - both trackers parse the PE headers at it (see
// InvalidationTracker::HandleImageMap -> RtlImageNtHeader and ImageTracker::HandleImageMap), and
// per the design the tracker internals speak host addresses throughout. Every caller that receives
// an address from outside the module is responsible for converting first.
void HandleImageMap(uint64_t Address, bool MainImage = false) {
  // MADEIRA: both trackers dereference the PE headers at Address without checking, so prove the
  // image is parseable here rather than faulting inside them. This is also the only place that can
  // tell "the address was in the wrong namespace" apart from "this really is not a PE".
  auto* Nt = RtlImageNtHeader(reinterpret_cast<HMODULE>(Address));
  if (!Nt) {
    LogMan::Msg::EFmt("[wow-image] no PE header at host {:#x} (guest {:#x}, window [{:#x}, {:#x})) - not registering", Address,
                      GuestWindow::ToGuestIfInWindow(Address), GuestWindow::Base, GuestWindow::Base + GuestWindow::Size);
    return;
  }

  fextl::string ModulePath = FEX::Windows::GetSectionFilePath(Address);
  fextl::string ModuleName = fextl::string {FEX::Windows::BaseName(ModulePath)};
  if (ModuleName.empty()) {
    ModuleName = GetImageNameFromExports(Address, Nt);
    // ImageTracker only ever takes the basename of the path, so handing it the bare name is
    // equivalent to a path with no directory component.
    ModulePath = ModuleName;
  }
  InvalidationTracker->HandleImageMap(ModuleName, Address);
  ImageTracker->HandleImageMap(ModulePath, Address, MainImage);
}

void HandleImageUnmap(uint64_t Address, uint64_t Size) {
  ImageTracker->HandleImageUnmap(Address, Size);
}
} // namespace

namespace Context {
// GUEST for every register field: a WOW64_CONTEXT is what the 32-bit guest observes, so Eip/Esp and
// the rest are guest addresses below 4 GiB and go into CPUState unchanged - FEXCore applies the base
// in the JIT. `Context` itself is a HOST pointer (ntdll's CPU area, or a caller stack temporary);
// WowTEB is the GUEST TEB32 address, see GetWowTEB(). Applies to both directions and therefore to
// BTCpuGetContext/BTCpuSetContext, which only move whole WOW64_CONTEXTs through ntdll.
void LoadStateFromWowContext(FEXCore::Core::InternalThreadState* Thread, uint64_t WowTEB, WOW64_CONTEXT* Context) {
  auto& State = Thread->CurrentFrame->State;

  // General register state

  State.gregs[FEXCore::X86State::REG_RAX] = Context->Eax;
  State.gregs[FEXCore::X86State::REG_RBX] = Context->Ebx;
  State.gregs[FEXCore::X86State::REG_RCX] = Context->Ecx;
  State.gregs[FEXCore::X86State::REG_RDX] = Context->Edx;
  State.gregs[FEXCore::X86State::REG_RSI] = Context->Esi;
  State.gregs[FEXCore::X86State::REG_RDI] = Context->Edi;
  State.gregs[FEXCore::X86State::REG_RBP] = Context->Ebp;
  State.gregs[FEXCore::X86State::REG_RSP] = Context->Esp;

  State.rip = Context->Eip;
  CTX->SetFlagsFromCompactedEFLAGS(Thread, Context->EFlags);

  State.es_idx = Context->SegEs & 0xffff;
  State.cs_idx = Context->SegCs & 0xffff;
  State.ss_idx = Context->SegSs & 0xffff;
  State.ds_idx = Context->SegDs & 0xffff;
  State.fs_idx = Context->SegFs & 0xffff;
  State.gs_idx = Context->SegGs & 0xffff;

  // The TEB is the only populated GDT entry by default
  auto GDT = State.GetSegmentFromIndex(State, (Context->SegFs & 0xffff));
  State.SetGDTBase(GDT, WowTEB);
  State.SetGDTLimit(GDT, 0xF'FFFFU);
  State.fs_cached = WowTEB;
  State.es_cached = 0;
  State.cs_cached = 0;
  State.ss_cached = 0;
  State.ds_cached = 0;

  // Floating-point register state
  const auto* XSave = reinterpret_cast<XSAVE_FORMAT*>(Context->ExtendedRegisters);

  CTX->SetXMMRegistersFromState(Thread, reinterpret_cast<const __uint128_t*>(XSave->XmmRegisters), nullptr);
  memcpy(State.mm, XSave->FloatRegisters, sizeof(State.mm));

  State.FCW = XSave->ControlWord;
  State.flags[FEXCore::X86State::X87FLAG_IE_LOC] = XSave->StatusWord & 1;
  State.flags[FEXCore::X86State::X87FLAG_C0_LOC] = (XSave->StatusWord >> 8) & 1;
  State.flags[FEXCore::X86State::X87FLAG_C1_LOC] = (XSave->StatusWord >> 9) & 1;
  State.flags[FEXCore::X86State::X87FLAG_C2_LOC] = (XSave->StatusWord >> 10) & 1;
  State.flags[FEXCore::X86State::X87FLAG_C3_LOC] = (XSave->StatusWord >> 14) & 1;
  State.flags[FEXCore::X86State::X87FLAG_TOP_LOC] = (XSave->StatusWord >> 11) & 0b111;
  State.AbridgedFTW = XSave->TagWord;
}

void StoreWowContextFromState(FEXCore::Core::InternalThreadState* Thread, WOW64_CONTEXT* Context) {
  auto& State = Thread->CurrentFrame->State;

  // General register state

  Context->Eax = State.gregs[FEXCore::X86State::REG_RAX];
  Context->Ebx = State.gregs[FEXCore::X86State::REG_RBX];
  Context->Ecx = State.gregs[FEXCore::X86State::REG_RCX];
  Context->Edx = State.gregs[FEXCore::X86State::REG_RDX];
  Context->Esi = State.gregs[FEXCore::X86State::REG_RSI];
  Context->Edi = State.gregs[FEXCore::X86State::REG_RDI];
  Context->Ebp = State.gregs[FEXCore::X86State::REG_RBP];
  Context->Esp = State.gregs[FEXCore::X86State::REG_RSP];

  Context->Eip = State.rip;
  Context->EFlags = CTX->ReconstructCompactedEFLAGS(Thread, false, nullptr, 0);

  Context->SegEs = State.es_idx;
  Context->SegCs = State.cs_idx;
  Context->SegSs = State.ss_idx;
  Context->SegDs = State.ds_idx;
  Context->SegFs = State.fs_idx;
  Context->SegGs = State.gs_idx;

  // Floating-point register state

  auto* XSave = reinterpret_cast<XSAVE_FORMAT*>(Context->ExtendedRegisters);

  CTX->ReconstructXMMRegisters(Thread, reinterpret_cast<__uint128_t*>(XSave->XmmRegisters), nullptr);
  memcpy(XSave->FloatRegisters, State.mm, sizeof(State.mm));

  XSave->ControlWord = State.FCW;
  XSave->StatusWord = (State.flags[FEXCore::X86State::X87FLAG_TOP_LOC] << 11) | (State.flags[FEXCore::X86State::X87FLAG_C0_LOC] << 8) |
                      (State.flags[FEXCore::X86State::X87FLAG_C1_LOC] << 9) | (State.flags[FEXCore::X86State::X87FLAG_C2_LOC] << 10) |
                      (State.flags[FEXCore::X86State::X87FLAG_C3_LOC] << 14) | State.flags[FEXCore::X86State::X87FLAG_IE_LOC];
  XSave->TagWord = State.AbridgedFTW;

  Context->FloatSave.ControlWord = XSave->ControlWord;
  Context->FloatSave.StatusWord = XSave->StatusWord;
  Context->FloatSave.TagWord = FEXCore::FPState::ConvertFromAbridgedFTW(XSave->StatusWord, State.mm, XSave->TagWord);
  Context->FloatSave.ErrorOffset = XSave->ErrorOffset;
  Context->FloatSave.ErrorSelector = XSave->ErrorSelector | (XSave->ErrorOpcode << 16);
  Context->FloatSave.DataOffset = XSave->DataOffset;
  Context->FloatSave.DataSelector = XSave->DataSelector;
  Context->FloatSave.Cr0NpxState = XSave->StatusWord | 0xffff0000;
}

NTSTATUS FlushThreadStateContext(HANDLE Thread) {
  const auto [Err, TLS] = GetThreadTLS(Thread);
  if (Err) {
    return Err;
  }

  WOW64_CONTEXT TmpWowContext {.ContextFlags = WOW64_CONTEXT_FULL | WOW64_CONTEXT_EXTENDED_REGISTERS};

  Context::StoreWowContextFromState(TLS.ThreadState(), &TmpWowContext);
  return RtlWow64SetThreadContext(Thread, &TmpWowContext);
}

void ReconstructThreadState(TLS TLS, CONTEXT* Context) {
  const auto& Config = SignalDelegator->GetConfig();
  auto* Thread = TLS.ThreadState();
  auto& State = Thread->CurrentFrame->State;

  State.rip = CTX->RestoreRIPFromHostPC(Thread, Context->Pc);

  // Spill all SRA GPRs
  for (size_t i = 0; i < Config.SRAGPRCount; i++) {
    State.gregs[i] = Context->X[Config.SRAGPRMapping[i]];
  }

  // Spill all SRA FPRs
  for (size_t i = 0; i < Config.SRAFPRCount; i++) {
    memcpy(State.xmm.sse.data[i], &Context->V[Config.SRAFPRMapping[i]], sizeof(__uint128_t));
  }

  // Spill EFlags
  uint32_t EFlags = CTX->ReconstructCompactedEFLAGS(Thread, true, Context->X, Context->Cpsr);
  CTX->SetFlagsFromCompactedEFLAGS(Thread, EFlags);
}

WOW64_CONTEXT ReconstructWowContext(TLS TLS, CONTEXT* Context) {
  if (!IsDispatcherAddress(Context->Pc)) {
    ReconstructThreadState(TLS, Context);
  }

  WOW64_CONTEXT WowContext {
    .ContextFlags = WOW64_CONTEXT_ALL,
  };

  auto* XSave = reinterpret_cast<XSAVE_FORMAT*>(WowContext.ExtendedRegisters);
  XSave->ControlWord = 0x27f;
  XSave->MxCsr = 0x1f80;

  Context::StoreWowContextFromState(TLS.ThreadState(), &WowContext);
  return WowContext;
}

static std::optional<FEX::Windows::TSOHandlerConfig> HandlerConfig;

bool HandleUnalignedAccess(TLS TLS, CONTEXT* Context) {
  auto Thread = TLS.ThreadState();
  if (!Thread->CTX->IsAddressInCodeBuffer(Thread, Context->Pc)) {
    return false;
  }

  const auto Result =
    FEXCore::ArchHelpers::Arm64::HandleUnalignedAccess(Thread, HandlerConfig->GetUnalignedHandlerType(), Context->Pc, &Context->X0);
  Context->Pc += Result.value_or(0);
  return Result.has_value();
}

#ifdef FEX_IOS_HOST
/* MADEIRA: the CPU area is the 32-bit register state other threads see and set.
 *
 * Wine keeps a WOW64_CPURESERVED header ({ USHORT Flags; USHORT Machine; }) at
 * TEB64->TlsSlots[WOW64_TLS_CPURESERVED], followed by the I386_CONTEXT that
 * RtlWow64GetCurrentCpuArea() returns. A GetThreadContext from another thread
 * reads that context, and a SetThreadContext from another thread writes it and
 * sets WOW64_CPURESERVED_FLAG_RESET_STATE (ntdll's set_thread_wow64_context,
 * and the iOS wineserver's apply-on-resume path, which writes it while the
 * target is held inside a system call). wow64cpu, the reference CPU module,
 * stores its registers into the CPU area on every transition out of 32-bit
 * code and reloads them when it finds RESET_STATE on the way back.
 *
 * This module only did the equivalent through WOW_CPU_AREA_DIRTY, which is set
 * by BTCpuSuspendLocalThread. The Wine tree this host uses never calls that
 * (wow64's NtSuspendThread thunk is a plain NtSuspendThread and
 * Wow64SuspendLocalThread is a stub), so a cross-thread Get saw whatever the
 * CPU area held since the last BTCpuGetContext/SetContext, and a cross-thread
 * Set was never loaded. So, as wow64cpu does:
 *   - FlushCpuAreaForExit() stores the JIT state into the CPU area before a
 *     system call or unix call leaves emitted code;
 *   - LockJITContext() consumes RESET_STATE on the thread's own CPU area and
 *     reloads the JIT state from it, exactly as for WOW_CPU_AREA_DIRTY.
 * Both only touch the calling thread's own TEB. */
static constexpr size_t IosWow64TlsCpuReserved = 1;      // WOW64_TLS_CPURESERVED
static constexpr uint16_t IosWow64CpuResetState = 1;     // WOW64_CPURESERVED_FLAG_RESET_STATE

static bool ConsumeCpuAreaReset(_TEB* TEB) {
  auto* Flags = reinterpret_cast<uint16_t*>(TEB->TlsSlots[IosWow64TlsCpuReserved]);
  if (!Flags || !(__atomic_load_n(Flags, __ATOMIC_ACQUIRE) & IosWow64CpuResetState)) {
    return false;
  }
  __atomic_fetch_and(Flags, static_cast<uint16_t>(~IosWow64CpuResetState), __ATOMIC_ACQ_REL);
  return true;
}

void FlushCpuAreaForExit(TLS TLS) {
  if (TLS.TEB != CurrentTEB() || !TLS.TEB->TlsSlots[IosWow64TlsCpuReserved]) {
    return;
  }
  WOW64_CONTEXT* WowContext;
  RtlWow64GetCurrentCpuArea(nullptr, reinterpret_cast<void**>(&WowContext), nullptr);
  StoreWowContextFromState(TLS.ThreadState(), WowContext);
}
#endif

void LockJITContext(TLS TLS) {
  uint32_t Expected = TLS.ControlWord().load(), New;

  // Spin until PAUSED is unset, setting IN_JIT when that occurs
  do {
    Expected = Expected & ~ControlBits::PAUSED;
    New = (Expected | ControlBits::IN_JIT) & ~ControlBits::WOW_CPU_AREA_DIRTY;
  } while (!TLS.ControlWord().compare_exchange_weak(Expected, New, std::memory_order::relaxed));
  std::atomic_signal_fence(std::memory_order::seq_cst);

#ifdef FEX_IOS_HOST
  // MADEIRA: a context set from outside (see ConsumeCpuAreaReset) counts as a dirty CPU area.
  if (TLS.TEB == CurrentTEB() && ConsumeCpuAreaReset(TLS.TEB)) {
    Expected |= ControlBits::WOW_CPU_AREA_DIRTY;
  }
#endif

  // If the CPU area is dirty, flush it to the JIT context before reentry
  if (Expected & ControlBits::WOW_CPU_AREA_DIRTY) {
    WOW64_CONTEXT* WowContext;
    RtlWow64GetCurrentCpuArea(nullptr, reinterpret_cast<void**>(&WowContext), nullptr);
    Context::LoadStateFromWowContext(TLS.ThreadState(), GetWowTEB(CurrentTEB()), WowContext);
  }
}

void UnlockJITContext(TLS TLS) {
  std::atomic_signal_fence(std::memory_order::seq_cst);
  TLS.ControlWord().fetch_and(~ControlBits::IN_JIT, std::memory_order::relaxed);
}

class ScopedJITContextLock {
private:
  TLS TLSData;

public:
  ScopedJITContextLock(TLS TLSData)
    : TLSData {TLSData} {
    LockJITContext(TLSData);
  }

  ~ScopedJITContextLock() {
    UnlockJITContext(TLSData);
  }
};

bool HandleSuspendInterrupt(TLS TLS, CONTEXT* Context, uint64_t FaultAddress) {
  if (FaultAddress != reinterpret_cast<uint64_t>(&TLS.ThreadState()->InterruptFaultPage)) {
    return false;
  }

  void* TmpAddress = reinterpret_cast<void*>(FaultAddress);
  SIZE_T TmpSize = FEXCore::Utils::FEX_PAGE_SIZE;
  ULONG TmpProt;
  NtProtectVirtualMemory(NtCurrentProcess(), &TmpAddress, &TmpSize, PAGE_READWRITE, &TmpProt);

  // Since interrupts only happen at the start of blocks, the reconstructed state should be entirely accurate
  ReconstructThreadState(TLS, Context);

  // Yield to the suspender
  UnlockJITContext(TLS);
  LockJITContext(TLS);

  // Adjust context to return to the dispatcher, reloading SRA from thread state
  const auto& Config = SignalDelegator->GetConfig();
  Context->Pc = Config.AbsoluteLoopTopAddressFillSRA;
  Context->X1 = 0; // Set ENTRY_FILL_SRA_SINGLE_INST_REG
  return true;
}
} // namespace Context

// Calls a 2-argument function `Func` setting the parent unwind frame information to the given SP and PC
__attribute__((naked)) extern "C" uint64_t SEHFrameTrampoline2Args(void* Arg0, void* Arg1, void* Func, uint64_t Sp, uint64_t Pc) {
  asm(".seh_proc SEHFrameTrampoline2Args;"
      "stp x3, x4, [sp, #-0x10]!;"
      ".seh_pushframe;"
      "stp x29, x30, [sp, #-0x10]!;"
      ".seh_save_fplr_x 16;"
      ".seh_endprologue;"
      "blr x2;"
      "ldp x29, x30, [sp], 0x20;"
      "ret;"
      ".seh_endproc;");
}

class WowSyscallHandler : public FEXCore::HLE::SyscallHandler, public FEXCore::Allocator::FEXAllocOperators {
public:
  WowSyscallHandler() {
    OSABI = FEXCore::HLE::SyscallOSABI::OS_GENERIC;
  }

  static uint64_t HandleSyscallImpl(FEXCore::Core::CpuStateFrame* Frame, FEXCore::HLE::SyscallArguments* Args) {
    // MADEIRA: ESP is a guest address, so every read through it goes via the window. ReturnRSP and
    // ReturnRIP stay GUEST, because they are written straight back into the guest's ESP/EIP below.
    const uint64_t ReturnRIP =
      *reinterpret_cast<uint32_t*>(GuestWindow::ToHost(Frame->State.gregs[FEXCore::X86State::REG_RSP])); // Return address from the stack
    uint64_t ReturnRSP = Frame->State.gregs[FEXCore::X86State::REG_RSP] + 4; // Stack pointer after popping return address
    uint64_t ReturnRAX = 0;

    if (Frame->State.rip == (uint64_t)BridgeInstrs::UnixCall) {
      struct StackLayout {
        unixlib_handle_t Handle;
        UINT32 ID;
        ULONG32 Args;
      }* StackArgs = reinterpret_cast<StackLayout*>(GuestWindow::ToHost(ReturnRSP));

      ReturnRSP += sizeof(StackLayout);

      const auto TLS = GetTLS();
#ifdef FEX_IOS_HOST
      Context::FlushCpuAreaForExit(TLS); // MADEIRA: see ConsumeCpuAreaReset
#endif
      Context::UnlockJITContext(TLS);
      // StackArgs->Args is a 32-bit GUEST pointer to the call's parameter block, and the unix side
      // dereferences it natively, so it has to cross as a host pointer.
      //
      // NOTE for the Wine side: only the *outer* pointer is converted here. Any pointer embedded
      // inside that parameter block is still a guest address and must be converted by the unixlib
      // thunk that owns the struct layout, exactly as wow64.dll's `*_32to64` helpers do for
      // syscalls. FEX cannot do it - it does not know the layout.
      auto* TD = GetFrontendThreadData(TLS.ThreadState());
      IosWowPark(TD); // ml1430
      ReturnRAX = static_cast<uint64_t>(WineUnixCall(StackArgs->Handle, StackArgs->ID, GuestWindow::ToHostPtr(StackArgs->Args)));
      IosWowUnpark(TD);
      Context::LockJITContext(TLS);
    } else if (Frame->State.rip == (uint64_t)BridgeInstrs::Syscall) {
      const uint64_t EntryRAX = Frame->State.gregs[FEXCore::X86State::REG_RAX];

      const auto TLS = GetTLS();
#ifdef FEX_IOS_HOST
      Context::FlushCpuAreaForExit(TLS); // MADEIRA: see ConsumeCpuAreaReset
#endif
      Context::UnlockJITContext(TLS);
      Wow64ProcessPendingCrossProcessItems();
      // wow64.dll reads the argument block directly, so it needs a host pointer. The 32-bit values
      // *inside* the block stay guest and are converted by wow64.dll's own get_ptr/*_32to64
      // helpers, which the design makes window-aware.
      auto* TD = GetFrontendThreadData(TLS.ThreadState());
      IosWowPark(TD); // ml1430
      ReturnRAX = static_cast<uint64_t>(
        Wow64SystemServiceEx(static_cast<UINT>(EntryRAX), reinterpret_cast<UINT*>(GuestWindow::ToHost(ReturnRSP + 4))));
      IosWowUnpark(TD);
      Context::LockJITContext(TLS);
    }
    // If a new context has been set, use it directly and don't return to the syscall caller
    if (Frame->State.rip == (uint64_t)BridgeInstrs::Syscall || Frame->State.rip == (uint64_t)BridgeInstrs::UnixCall) {
      Frame->State.gregs[FEXCore::X86State::REG_RAX] = ReturnRAX;
      Frame->State.gregs[FEXCore::X86State::REG_RSP] = ReturnRSP;
      Frame->State.rip = ReturnRIP;
    }

    // NORETURNEDRESULT causes this result to be ignored since we restore all registers back from memory after a syscall anyway
    return 0;
  }

  uint64_t HandleSyscall(FEXCore::Core::CpuStateFrame* Frame, FEXCore::HLE::SyscallArguments* Args) override {
    const auto TLS = GetTLS();
    // Stash the the context pointer on the stack, as Simulate can be called from this syscall handler which would overwrite it
    CONTEXT* EntryContext = TLS.EntryContext();
    // Call the syscall handler with unwind information pointing to Simulate as its caller
    uint64_t Ret = SEHFrameTrampoline2Args(reinterpret_cast<void*>(Frame), reinterpret_cast<void*>(Args),
                                           reinterpret_cast<void*>(&HandleSyscallImpl), EntryContext->Sp, EntryContext->Pc);
    TLS.EntryContext() = EntryContext;
    return Ret;
  }

  // MADEIRA: this is the FEXCore <-> tracker boundary. FEXCore speaks GUEST addresses here;
  // InvalidationTracker, ImageTracker and OvercommitTracker all speak HOST addresses, because their
  // other callers are wow64.dll's BTCpuNotify* callbacks and the OS memory APIs. So: add the base
  // on the way in, subtract it from anything handed back.
  std::optional<FEXCore::ExecutableFileSectionInfo> LookupExecutableFileSection(FEXCore::Core::InternalThreadState*, uint64_t Address) override {
    auto Info = ImageTracker->LookupExecutableFileSection(GuestWindow::ToHost(Address));
    if (Info && GuestWindow::Base) {
      // FileStartVA/BeginVA/EndVA are compared against guest addresses by the frontend's
      // section-bounds and relocation logic, so they must come back in the guest namespace.
      //
      // A section that does not lie inside the window has no guest address at all. Report "no
      // section" rather than an arithmetically-derived nonsense address: the frontend's fallback
      // for a miss is safe, whereas a bogus BeginVA/EndVA silently mis-bounds every relocation
      // offset computed against it.
      if (!GuestWindow::Contains(Info->BeginVA) || !GuestWindow::Contains(Info->EndVA - 1) ||
          !GuestWindow::Contains(Info->FileStartVA)) {
        return std::nullopt;
      }
      Info->FileStartVA = GuestWindow::ToGuest(Info->FileStartVA);
      Info->BeginVA = GuestWindow::ToGuest(Info->BeginVA);
      Info->EndVA = GuestWindow::ToGuest(Info->EndVA);
    }
    return Info;
  }

  void MarkGuestExecutableRange(FEXCore::Core::InternalThreadState* Thread, uint64_t Start, uint64_t Length) override {
    InvalidationTracker->ReprotectRWXIntervals(GuestWindow::ToHost(Start), Length);
  }

  void InvalidateGuestCodeRange(FEXCore::Core::InternalThreadState* Thread, uint64_t Start, uint64_t Length) override {
    InvalidationTracker->InvalidateAlignedInterval(GuestWindow::ToHost(Start), Length, false);
  }

  void MarkOvercommitRange(uint64_t Start, uint64_t Length) override {
    OvercommitTracker->MarkRange(GuestWindow::ToHost(Start), Length);
  }

  void UnmarkOvercommitRange(uint64_t Start, uint64_t Length) override {
    OvercommitTracker->UnmarkRange(GuestWindow::ToHost(Start), Length);
  }

  FEXCore::HLE::ExecutableRangeInfo QueryGuestExecutableRange(FEXCore::Core::InternalThreadState* Thread, uint64_t Address) override {
    auto Info = InvalidationTracker->QueryExecutableRange(GuestWindow::ToHost(Address));
    // A zero Size means "not executable"; leave that alone rather than turning it into a window
    // address. FEXCore compares Base against guest addresses in CheckRangeExecutable, so an
    // executable range that is somehow outside the window has no guest meaning and is reported as
    // non-executable instead of as a wrong range.
    if (GuestWindow::Base && Info.Size) {
      if (!GuestWindow::Contains(Info.Base)) {
        return {};
      }
      Info.Base = GuestWindow::ToGuest(Info.Base);
    }
    return Info;
  }

  void PreCompile() override {
    Wow64ProcessPendingCrossProcessItems();
  }

};

/* MADEIRA ml1430: the syscall entry emitted blocks call (Pointers.SyscallHandlerFunc, set
 * per thread in BTCpuThreadInit). IosWowSyscallC arms parking for an outermost-level syscall
 * and, when the sweeper moved the thread while it was blocked, answers where to resume: the
 * dispatcher's stack pointer and LoopTopFillSRA. See the ml1430 comment at IosWowPark. */
struct IosSyscallResume {
  uint64_t NewSP;  // 0: return into the calling block as usual
  uint64_t Target; // DispatcherLoopTopFillSRA when NewSP != 0
};

extern "C" IosSyscallResume IosWowSyscallC(FEXCore::HLE::SyscallHandler* Obj, FEXCore::Core::CpuStateFrame* Frame,
                                           FEXCore::HLE::SyscallArguments* Args, uint64_t CallerSP) {
  static std::atomic<uint32_t> Redirects {0}, Declined {0};
  const auto TLS = GetTLS();
  auto* TD = GetFrontendThreadData(TLS.ThreadState());
  const uint32_t Depth = TD->IosSyscallDepth++;
  const bool PrevArmed = TD->IosSyscallArmed;
  // The dispatcher's stack pointer, as its entry stored it. A callback that re-entered
  // simulation and was left by a long jump leaves a deeper (lower) value behind; the calling
  // block sits a few hundred bytes below the real one. Anything else is not trusted.
  const uint64_t DispatcherSP = Frame->ReturningStackLocation;
  const uint64_t ResumeAt = Frame->Pointers.DispatcherLoopTopFillSRA;
  bool Arm = TD->IosSweepRegistered && Depth == 0 && ResumeAt != 0;
  if (Arm && (DispatcherSP < CallerSP || DispatcherSP - CallerSP > 0x2000 || (DispatcherSP & 15))) {
    Arm = false;
    if (Declined.fetch_add(1, std::memory_order_relaxed) < 4) {
      LogMan::Msg::EFmt("[wow-sweep] ml1430 not parked: dispatcher sp {:#x} caller sp {:#x}", DispatcherSP, CallerSP);
    }
  }
  TD->IosSyscallArmed = Arm;
  if (Arm) {
    TD->IosMigrated = 0;
  }

  Obj->HandleSyscall(Frame, Args);

  TD->IosSyscallArmed = PrevArmed;
  TD->IosSyscallDepth = Depth;
  if (Arm && TD->IosMigrated) {
    TD->IosMigrated = 0;
    Frame->ReturningStackLocation = DispatcherSP;
    Frame->InSyscallInfo = 0;
    const uint32_t N = Redirects.fetch_add(1, std::memory_order_relaxed) + 1;
    if (N <= 8 || (N & 1023) == 0) {
      LogMan::Msg::EFmt("[wow-sweep] ml1430 resumed #{} at the dispatcher after a move while blocked (rip {:#x})", N,
                        Frame->State.rip);
    }
    return {DispatcherSP, ResumeAt};
  }
  return {0, 0};
}

// Same arguments as SyscallHandler::HandleSyscall (x0 handler, x1 frame, x2 args) plus the
// caller's SP. Normal case: return into the block (x0, the ignored OS_GENERIC result, is 0).
// Moved case: the callee-saved registers the block relies on (STATE in x28, PF/AF, the static
// registers) are already restored by IosWowSyscallC's epilogue; switch to the dispatcher's
// stack, clear the single-instruction entry flag (TMP2 = x1) and enter LoopTopFillSRA, which
// refills the static registers and dispatches at State.rip.
extern "C" __attribute__((naked)) void IosWowSyscallEntry() {
  asm(".seh_proc IosWowSyscallEntry;"
      "mov x3, sp;"
      ".seh_nop;"
      "stp x29, x30, [sp, #-16]!;"
      ".seh_save_fplr_x 16;"
      ".seh_endprologue;"
      "bl IosWowSyscallC;"
      "ldp x29, x30, [sp], #16;"
      "cbnz x0, 1f;"
      "ret;"
      "1:;"
      "mov sp, x0;"
      "mov x16, x1;"
      "mov x1, #0;"
      "br x16;"
      ".seh_endproc;");
}

void BTCpuProcessInit() {
  FEX::Windows::InitCRTProcess();

#ifdef FEX_IOS_HOST
  /* MADEIRA: import the TEB TSD slot offset before anything reads a TEB. A missing or zero export
   * is fatal rather than a fallback - the fallback path (x18) is exactly the thing that is
   * unreliable, and a wrong TEB here silently corrupts every thread's TLS slots. BTCpuProcessInit
   * has no way to report failure to wow64.dll, so this is loud on stderr and then refuses to
   * continue rather than limping. */
  {
    const auto NtDllForTsd = GetModuleHandle("ntdll.dll");
    const auto Published = reinterpret_cast<uint32_t*>(GetProcAddress(NtDllForTsd, "ios_teb_tsd_offset"));
    IosTebTsdImportFound = Published != nullptr ? 1u : 0u;
    if (Published && *Published) {
      FEX::Windows::WOW64::IosTebTsdOffset = *Published;
      // Parity with ARM64EC/Module.cpp:841 - see the declaration near the top of this file.
      ::IosTebTsdOffset = *Published;
    }
    /* ml800: this is the FIRST thing that can fail in this module and it runs before LogMan
     * exists, so report the whole import unconditionally through the raw path. Which of the three
     * failure modes it is - no ntdll handle, no export, or an export the unix side never
     * published into THIS pseudo-process's ntdll .data copy - decides where the fix goes, and the
     * FIFTH DEVICE RUN could not tell them apart because the message never left the module. */
    IosRawReport("E [wow64-init] teb-tsd: ntdll={} export={} found={} value={:#x}", static_cast<void*>(NtDllForTsd),
                 static_cast<void*>(Published), IosTebTsdImportFound, FEX::Windows::WOW64::IosTebTsdOffset);
    if (!FEX::Windows::WOW64::IosTebTsdOffset) {
      IOS_WOW64_REPORT_AND_DIE("[FEX-iOS][wow64] ntdll!ios_teb_tsd_offset missing or zero (ntdll={} export={}) - "
                               "refusing to run with an unreliable TEB",
                               static_cast<void*>(NtDllForTsd), static_cast<void*>(Published));
    }
  }
#endif

  // MADEIRA: keep the path alive; BaseName returns a view into it (it used to point into a
  // temporary that was already destroyed).
  const fextl::string ExecutablePath = FEX::Windows::GetExecutableFilePath();
  const auto ExecutableName = FEX::Windows::BaseName(ExecutablePath);
  FEX::Config::LoadConfig(fextl::string {ExecutableName}, _environ, FEX::ReadPortabilityInformation());
  FEXCore::Config::ReloadMetaLayer();
  FEX::Windows::Logging::Init();

  FEXCore::Config::Set(FEXCore::Config::CONFIG_INTERPRETER_INSTALLED, "0");
  FEXCore::Config::Set(FEXCore::Config::CONFIG_IS64BIT_MODE, "0");

  /* MADEIRA ml950: 64-bit x87 is the DEFAULT for 32-bit guests on this host.
   *
   * Why: with the compiled-in default (80-bit, X87ReducedPrecision=0) every x87 op that FEXCore
   * cannot keep in a double goes out through the softfloat ABI thunks, and a device A/B on a
   * 32-bit D3D9 title measured those thunks at 20-50 % of ALL CPU, with frame rate roughly
   * doubling when the option was flipped. 32-bit code is where x87 still lives -- a 64-bit guest
   * uses SSE for scalar float -- so the trade is worth taking exactly here and the 64-bit/ARM64EC
   * module is untouched.
   *
   * The trade is real and is not a rounding detail: x87 intermediates become 53-bit instead of
   * 64-bit, so anything that genuinely depends on the extra mantissa bits (some geometry,
   * collision and physics kernels, a few reduction loops) can produce different results, and a
   * guest that compares its own float output against a recorded value can disagree. That is the
   * price of the frame rate, and it is why this is a DEFAULT rather than a hard-coded value.
   *
   * Exists() is the layered "did anyone actually ask for this" test: FEX::Config::LoadConfig and
   * ReloadMetaLayer have already run above, so the meta layer holds whatever the environment layer
   * picked up from FEX_X87REDUCEDPRECISION -- which is exactly what Documents/madeira-fex.txt
   * writes (ContentView.swift setenv("FEX_" + NAME)). So a user line X87REDUCEDPRECISION=0 still
   * wins, and so does the env var directly; only the absence of any override lands here. */
  if (!FEXCore::Config::Exists(FEXCore::Config::CONFIG_X87REDUCEDPRECISION)) {
    FEXCore::Config::Set(FEXCore::Config::CONFIG_X87REDUCEDPRECISION, "1");
  }

  /* MADEIRA: StrictInProcessSplitLocks defaults ON for 32-bit guests.
   *
   * An x86 LOCK op on a word that crosses a 16-byte boundary faults on this host and FEX emulates it
   * as two separate half-width CASes. Without the strict mode two threads doing that on the same
   * word interleave freely, and a failed second half can leave the word torn. The strict mode serializes every split-lock emulation in the
   * process behind one lock, which is what x86 split-lock semantics require; split locks are rare
   * and each one already costs a fault, so the extra lock is noise. Same Exists() rule as the x87
   * default above: FEX_STRICTINPROCESSSPLITLOCKS / madeira-fex.txt still wins.
   * MADEIRA_STRICT_SPLITLOCK=0 leaves the compiled default (off). */
  bool MadeiraStrictSplitDefaultApplied = false;
  {
    const char* Switch = getenv("MADEIRA_STRICT_SPLITLOCK");
    const bool Disabled = Switch && Switch[0] == '0' && Switch[1] == '\0';
    const bool UserSet = FEXCore::Config::Exists(FEXCore::Config::CONFIG_STRICTINPROCESSSPLITLOCKS);
    if (!Disabled && !UserSet) {
      FEXCore::Config::Set(FEXCore::Config::CONFIG_STRICTINPROCESSSPLITLOCKS, "1");
      MadeiraStrictSplitDefaultApplied = true;
    }
    LogMan::Msg::EFmt("[splitlock] StrictInProcessSplitLocks {} (MADEIRA_STRICT_SPLITLOCK=0 keeps the compiled default)",
                      MadeiraStrictSplitDefaultApplied ? "=1 (madeira-32bit-default)" : (UserSet ? "user-set, kept" : "default kept (disabled)"));
  }

  // MADEIRA: pick up the guest window before anything else touches a guest address, and in
  // particular before CreateNewContext - FEXCore resolves Config.GuestBase in its constructor and
  // the dispatcher bakes the base into emitted code, so a later value would be ignored.
  //
  // A non-WoW process, or a Wine build without the window, returns 0 and everything below stays
  // identity mapped. Any failure is also 0: this is not a silent fallback, it is the correct answer
  // for "there is no window", and the only host where a window is mandatory (iOS) always provides
  // one. The value is never inherited from another process or an environment variable, so two
  // 32-bit pseudo-processes sharing this address space cannot pick up each other's window.
  {
    ULONG_PTR QueriedBase = 0;
    const NTSTATUS Err = NtQueryInformationProcess(NtCurrentProcess(), static_cast<PROCESSINFOCLASS>(GuestWindow::ProcessWineIosWowGuestBase),
                                                  &QueriedBase, sizeof(QueriedBase), nullptr);
    if (!Err && QueriedBase) {
#ifdef FEX_GUEST_WINDOW
      GuestWindow::Base = static_cast<uint64_t>(QueriedBase);
      LOGMAN_THROW_A_FMT((GuestWindow::Base & (FEXCore::Utils::FEX_PAGE_SIZE - 1)) == 0, "Guest window base must be page aligned");
      FEXCore::Config::Set(FEXCore::Config::CONFIG_GUEST32BASE, fextl::fmt::format("{}", GuestWindow::Base));
#else
      // Running the guest identity mapped would dereference guest addresses as host ones.
      ERROR_AND_DIE_FMT("Wine placed this 32-bit process in a guest window at {:#x}, but FEX was built without "
                        "ENABLE_GUEST_WINDOW",
                        static_cast<uint64_t>(QueriedBase));
#endif
    }
#ifdef FEX_IOS_HOST
    // MADEIRA: one line for the value every guest address in this process is formed from, with the
    // query status, so "there is no window" and "the query failed" are never confused in a log.
    /* ml800: raw path, not LogMan. This line is the value every guest address in the process is
     * formed from and it has to survive the case where Logging::Init() itself never got to
     * install a handler - which is exactly the window in which the FIFTH DEVICE RUN died. */
    IosRawReport("E [wow-base] class {} -> status={:#x} B={:#x} (guest window [{:#x}, {:#x}))",
                 GuestWindow::ProcessWineIosWowGuestBase, static_cast<uint32_t>(Err), GuestWindow::Base, GuestWindow::Base,
                 GuestWindow::Base + GuestWindow::Size);
#endif
  }

#ifdef FEX_IOS_HOST
  /* MADEIRA ml787: flush the VA band selector's beacons, then REFUSE TO RUN WITHOUT AN ARENA.
   *
   * Every FEX host allocation on iOS goes through a band chosen once, at this PE's first
   * rpmalloc mapping, and there is deliberately no unconstrained fallback: placing FEX's own
   * structures in guest-writable memory corrupted the heap before FEX had a ThreadState (see the
   * ml465/ml706 history in rpmalloc.c). So with no band, every host allocation returns NULL and
   * the first use of one stores through it - which is all the FOURTH DEVICE RUN left behind: a
   * fault at rip=0 with addr=0x7f0, 2,000 redeliveries, and the actual cause 40 lines earlier.
   *
   * Die here instead, with the cause named, while LogMan is up and before InitCore() allocates
   * anything. */
  /* ml800: all three of these go out raw. The selector's own buffer is written straight through
   * rather than formatted into it, so it is neither truncated by a formatting buffer nor routed
   * through an allocator that may be the thing that is broken. */
  if (ios_va_log_len > 0) {
    ios_va_log[ios_va_log_len] = 0;
    IosRawReport("E [va-profile] ml787 deferred selector log ({} bytes):", ios_va_log_len);
    IosRawWrite(ios_va_log, static_cast<size_t>(ios_va_log_len));
  } else {
    IosRawReport("E [va-profile] ml787 selector emitted NOTHING -- it did not run");
  }
  if (!ios_fex_band_base) {
    IOS_WOW64_REPORT_AND_DIE("[FEX-iOS][wow64] no FEX host arena: the VA band selector found no usable host "
                             "band, so every FEX host allocation would return NULL. Guest window B={:#x}. See the "
                             "[va-profile] log above for the candidates it tried - a WoW process needs the ntdll "
                             "side to validate an explicit >=4GiB address requirement against the HOST ceiling, "
                             "not the guest one.",
                             GuestWindow::Base);
  }
  IosRawReport("E [va-profile] ml787 FEX host arena = [{:#x}, {:#x}]", ios_fex_band_base, ios_fex_band_end);
#endif

  FEXCore::Profiler::Init("", "");

  SignalDelegator = fextl::make_unique<FEX::DummyHandlers::DummySignalDelegator>();
  SyscallHandler = fextl::make_unique<WowSyscallHandler>();
  const auto NtDll = GetModuleHandle("ntdll.dll");
  const bool IsWine = !!GetProcAddress(NtDll, "wine_get_version");
  OvercommitTracker.emplace(IsWine);

  FEX::Windows::Allocator::SetupHooks(NtDll);
  FEX::Windows::UnixLib::Init(NtDll);

  {
    auto HostFeatures = FEX::Windows::CPUFeatures::FetchHostFeatures(IsWine, FEXCore::HostFeatures::HostTypeEnum::Wow64);
    CTX = FEXCore::Context::Context::CreateNewContext(HostFeatures);
  }

  CTX->SetSignalDelegator(SignalDelegator.get());
  CTX->SetSyscallHandler(SyscallHandler.get());

#ifdef FEX_IOS_HOST
  /* MADEIRA: publish the RX->RW alias distance for this PE's FEXCore copy BEFORE InitCore(), which
   * emits the dispatcher and therefore already needs to write through the alias. The two env vars
   * are the same ones the app publishes for the unix side's JIT pool, so there is exactly one
   * source of truth for the pool layout. A zero offset is fatal: it would send every JIT write to
   * the executable mapping, which iOS will not make writable. */
  {
    const char* rw_env = getenv("WINE_IOS_JIT_RW");
    const char* rx_env = getenv("WINE_IOS_JIT_RX");
    const char* size_env = getenv("WINE_IOS_JIT_SIZE");
    const uint64_t rw = rw_env ? strtoull(rw_env, nullptr, 16) : 0;
    const uint64_t rx = rx_env ? strtoull(rx_env, nullptr, 16) : 0;
    const uint64_t pool_size = size_env ? strtoull(size_env, nullptr, 16) : 0;
    if (!rw || !rx) {
      IOS_WOW64_REPORT_AND_DIE("[FEX-iOS][wow64] WINE_IOS_JIT_RW/RX missing (RW={} RX={}) - JIT pool writes would corrupt memory",
                               rw_env ? rw_env : "(null)", rx_env ? rx_env : "(null)");
    }
    FEXCore::DualMap::WriteOffset = static_cast<int64_t>(rw - rx);
    /* MADEIRA: publish the pool's RX range for FEXCore::Allocator::VirtualAlloc, which refuses an
     * executable allocation outside it. The write offset alone is not enough to detect the SIXTH
     * DEVICE RUN failure - it is applied unconditionally, to whatever buffer it is handed, so a
     * buffer allocated outside the pool produces an unmapped write target instead of an error.
     * A missing size disables the check rather than failing the launch: the offset, which is
     * mandatory, is validated above. */
    if (pool_size) {
      ios_fex_jit_pool_rx = static_cast<uintptr_t>(rx);
      ios_fex_jit_pool_end = static_cast<uintptr_t>(rx + pool_size);
    }
    LogMan::Msg::EFmt("[FEX-iOS][wow64] fast-write enabled (WriteOffset={:#x} RW={:#x} RX={:#x} pool=[{:#x}, {:#x})) guest_window={:#x}",
                      FEXCore::DualMap::WriteOffset, rw, rx, ios_fex_jit_pool_rx, ios_fex_jit_pool_end, GuestWindow::Base);
    IosRawReport("E [jit-pool] wow64 exec allocations restricted to RX [{:#x}, {:#x}) (WriteOffset={:#x}, SIZE={})",
                 ios_fex_jit_pool_rx, ios_fex_jit_pool_end, FEXCore::DualMap::WriteOffset, size_env ? size_env : "(null)");
  }
#endif

  CTX->InitCore();
  Context::HandlerConfig.emplace(*CTX);
  // The tracker speaks host addresses to the OS and converts at its calls into FEXCore.
  InvalidationTracker.emplace(*CTX, Threads, GuestWindow::Base);
  ImageTracker.emplace(*CTX, false);

  // The 64-bit PEB's ImageBaseAddress is a HOST address: ntdll-unix's init_peb stores the address
  // it actually mapped the i386 image at, i.e. inside the window. No conversion.
  auto MainModule = reinterpret_cast<__TEB*>(CurrentTEB())->Peb->ImageBaseAddress;
  HandleImageMap(reinterpret_cast<uint64_t>(MainModule), true);

  // MADEIRA: LdrSystemDllInitBlock is published entirely in the GUEST namespace.
  //
  // SEVENTH DEVICE RUN: this line handed HandleImageMap the raw ntdll_handle (0x7bf40000) and the
  // tracker's RtlImageNtHeader faulted reading the MZ signature at that address - there is nothing
  // mapped below 4 GiB on this host, so a guest address dereferenced as a host one always faults.
  //
  // Contract (WOW64_DESIGN.md §4, build/ntdll-unix/loader_ios.c:2231-2248): every member of
  // LdrSystemDllInitBlock is a guest address. The p* entries have to be, because they end up in a
  // 32-bit CONTEXT (LdrInitializeThunk, KiUser*Dispatcher, RtlUserThreadStart) and are compared
  // against the guest RIP; ntdll_handle is published the same way for uniformity, and wow64.dll
  // adds B back before using it as an HMODULE (wine/dlls/wow64/syscall.c:1038 guest_ptr32()).
  // So convert here too - HandleImageMap and both trackers are host-namespace.
  const uint64_t NtDllX86Guest =
    reinterpret_cast<SYSTEM_DLL_INIT_BLOCK*>(GetProcAddress(NtDll, "LdrSystemDllInitBlock"))->ntdll_handle;
  const uint64_t NtDllX86 = GuestWindow::ToHost(NtDllX86Guest);
#ifdef FEX_IOS_HOST
  IosRawReport("E [wow-image] i386 ntdll guest={:#x} host={:#x} (LdrSystemDllInitBlock.ntdll_handle is a GUEST address)",
               NtDllX86Guest, NtDllX86);
#endif
  if (NtDllX86Guest) {
    HandleImageMap(NtDllX86);
  }

  CPUFeatures.emplace(*CTX);

  // Allocate the syscall/unixcall trampolines in the lower 2GB of the address space
  //
  // MADEIRA: `zero_bits` of (1<<31)-1 is a request for "below 2 GiB". For a WoW process the Wine
  // side interprets a sub-4GiB zero_bits / HighestUserAddress constraint as "inside this process's
  // guest window" and hands back a host address in [Base, Base + 2GiB) - the same semantics every
  // other low allocation (TEB32, the 32-bit stacks, the i386 image) goes through, so there is no
  // separate allocation path to keep in sync.
  //
  // The page is then written and tracked through its HOST address, but PUBLISHED to wow64.dll and
  // compared against State.rip as a GUEST address, because that is what the 32-bit code jumps to.
  SIZE_T Size = 4;
  void* Addr = nullptr;
#ifdef FEX_IOS_HOST
  /* MADEIRA: PAGE_READWRITE on the iOS host, NOT PAGE_EXECUTE_READWRITE.
   *
   * These 4 bytes are x86 data that FEX *decodes* (the guest's `Wow64Transition` /
   * `__wine_unix_call_dispatcher` target); no host instruction is ever fetched from them. Asking
   * for host execute permission here is not merely redundant, it is actively harmful, because of
   * what ntdll-unix does with such a request:
   *
   *   allocate_virtual_memory (virtual_ios.c:14467) translates the sub-4GiB zero_bits ceiling into
   *   this process's window (ios_wow_translate_limits, :14488), maps the page there, and then -
   *   because VPROT_EXEC is set - calls mprotect_range -> mprotect_exec (:14552, :8071).
   *   mprotect_exec finds that iOS/TXM will not grant exec (:8301-8318: it mprotects, re-queries
   *   via mach_vm_region and sees no VM_PROT_EXECUTE), runs a 64 MB BACKWARD MZ SCAN through guest
   *   memory looking for an owning PE image (:8417), decides the page is anonymous RWX (:8470),
   *   carves a 16 KiB JIT-pool slot (:8630), copies the page's bytes into it and `vm_remap`s the
   *   pool slot OVER the window VA with VM_FLAGS_FIXED|VM_FLAGS_OVERWRITE (:8694), then
   *   vm_protect()s it R+X (:8715) - i.e. read-execute, NOT writable.
   *
   * So the old request did not fail; it succeeded in the worst possible way. The page stayed
   * inside the window (so the window check below still passed) but its backing became
   * pool-remapped R+X memory - executable memory inside the guest window, which invariant 7
   * forbids outright - it burned a pool slot per 32-bit process, and the very next store
   * (`*Addr = 0x2ecd2ecd`) became a Mach-fault-emulated write through the anon-alias table.
   *
   * PAGE_READWRITE skips all of that: no VPROT_EXEC, so mprotect_exec is never reached, the page
   * is an ordinary readable/writable window page, the store is a plain store, and FEX's frontend
   * reads the opcode bytes directly.
   *
   * Executability is FEX's own bookkeeping, not the host page protection: the
   * HandleMemoryProtectionNotification(..., PAGE_EXECUTE) below inserts the range into
   * InvalidationTracker's XIntervals (InvalidationTracker.cpp:75), and QueryExecutableRange
   * (:435) - which is what WowSyscallHandler::QueryGuestExecutableRange and therefore FEXCore's
   * "is this guest range executable" check consult - answers purely from those intervals and
   * never calls NtQueryVirtualMemory. PAGE_EXECUTE is also not writable, so the range is X but
   * not RWX and no SMC trapping is armed for it. Nothing on wow64.dll's side inspects the page
   * either: all four publish sites (wow64/syscall.c:811, 1050-1051, 1076) store the guest address
   * verbatim, and the 32-bit ntdll's syscall stubs only load and jump through it. */
  constexpr ULONG BopProt = PAGE_READWRITE;
#else
  constexpr ULONG BopProt = PAGE_EXECUTE_READWRITE;
#endif
  const NTSTATUS BopStatus = NtAllocateVirtualMemory(NtCurrentProcess(), &Addr, (1U << 31) - 1, &Size, MEM_RESERVE | MEM_COMMIT, BopProt);
  /* MADEIRA: the return value was ignored, and the very next statement stores through Addr, so a
   * refusal turned into a NULL store with no message. Report it instead. */
  if (BopStatus || !Addr) {
#ifdef FEX_IOS_HOST
    IOS_WOW64_REPORT_AND_DIE("BOP trampoline allocation failed: status={:#x} addr={} prot={:#x} window [{:#x}, {:#x})",
                             static_cast<uint32_t>(BopStatus), Addr, BopProt, GuestWindow::Base, GuestWindow::Base + GuestWindow::Size);
#else
    ERROR_AND_DIE_FMT("BOP trampoline allocation failed: status={:#x} addr={}", static_cast<uint32_t>(BopStatus), Addr);
#endif
  }
  // PAGE_EXECUTE (not _READWRITE): X but not RWX, so the range is decodable by the frontend and no
  // SMC write-trap is armed on it. This is FEX's own executability record; the host page stays RW.
  InvalidationTracker->HandleMemoryProtectionNotification(reinterpret_cast<uint64_t>(Addr), Size, PAGE_EXECUTE);
  *reinterpret_cast<uint32_t*>(Addr) = 0x2ecd2ecd;
#ifdef FEX_IOS_HOST
  IosRawReport("E [wow-bop] page host={} guest={:#x} size={:#x} host_prot={:#x} (RW by design; FEX tracks it as "
               "executable, nothing host-executes it)",
               Addr, GuestWindow::ToGuestIfInWindow(reinterpret_cast<uint64_t>(Addr)), Size, BopProt);
#endif

  const uint64_t BridgeHost = reinterpret_cast<uint64_t>(Addr);
  if (GuestWindow::Base && !GuestWindow::Contains(BridgeHost)) {
    // Refusing loudly beats publishing a >4GiB pointer that the guest will silently truncate.
#ifdef FEX_IOS_HOST
    IOS_WOW64_REPORT_AND_DIE("BOP trampoline landed outside the guest window: host {:#x} window [{:#x}, {:#x})", BridgeHost,
                             GuestWindow::Base, GuestWindow::Base + GuestWindow::Size);
#else
    ERROR_AND_DIE_FMT("BOP trampoline landed outside the guest window: host {:#x} window [{:#x}, {:#x})", BridgeHost, GuestWindow::Base,
                      GuestWindow::Base + GuestWindow::Size);
#endif
  }
  const uint64_t BridgeGuest = GuestWindow::ToGuest(BridgeHost);
  BridgeInstrs::Syscall = reinterpret_cast<void*>(BridgeGuest);
  BridgeInstrs::UnixCall = reinterpret_cast<void*>(BridgeGuest + 2);

  const auto Sym = GetProcAddress(NtDll, "__wine_unix_call_dispatcher");
  if (Sym) {
    WineUnixCall = *reinterpret_cast<decltype(WineUnixCall)*>(Sym);
  }

  FEX::Windows::SetupEnvironmentVariableValues(NtDll);

  // wow64.dll will only initialise the cross-process queue if this is set
  GetTLS().Wow64Info().CpuFlags = WOW64_CPUFLAGS_SOFTWARE;

  FEX_CONFIG_OPT(ProfileStats, PROFILESTATS);
  FEX_CONFIG_OPT(StartupSleep, STARTUPSLEEP);
  FEX_CONFIG_OPT(StartupSleepProcName, STARTUPSLEEPPROCNAME);

  if (IsWine && ProfileStats()) {
    StatAllocHandler = fextl::make_unique<FEX::Windows::StatAlloc>(FEXCore::SHMStats::AppType::WIN_WOW64);
  }

  if (StartupSleep() && (StartupSleepProcName().empty() || ExecutableName == StartupSleepProcName())) {
    LogMan::Msg::IFmt("[{}][{}] Sleeping for {} seconds", GetCurrentProcessId(), ExecutableName, StartupSleep());
    std::this_thread::sleep_for(std::chrono::seconds(StartupSleep()));
  }
}

void BTCpuProcessTerm(HANDLE Handle, BOOL After, ULONG Status) {}

void BTCpuThreadInit() {
  static constexpr size_t DefaultWow64CS {4};
  std::unique_lock<std::mutex> Lock(ThreadCreationMutex);
  FEX::Windows::InitCRTThread();
  auto* Thread = CTX->CreateThread(0, 0);

  // Default segment setup.
  auto Frame = Thread->CurrentFrame;
  auto NewSegments = new FEXCore::Core::CPUState::gdt_segment[32]();

  // Setup initial code-segment GDT
  auto& GDT = NewSegments[DefaultWow64CS];
  FEXCore::Core::CPUState::SetGDTBase(&GDT, 0);
  FEXCore::Core::CPUState::SetGDTLimit(&GDT, 0xF'FFFFU);
  GDT.L = 0; // L = Long Mode = 32-bit
  GDT.D = 1; // D = Default Operand Size = 32-bit

  Frame->State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_GDT] = &NewSegments[0];
  // TODO: LDTs are currently unsupported, mirror them to GDT.
  Frame->State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_LDT] = &NewSegments[0];

  Frame->State.cs_idx = DefaultWow64CS << 3;
  Frame->State.cs_cached = FEXCore::Core::CPUState::CalculateGDTBase(GDT);

  if (!FEX::Windows::CallRetStack::InitializeThread(Thread)) {
    delete[] NewSegments;
    Frame->State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_GDT] = nullptr;
    Frame->State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_LDT] = nullptr;
    CTX->DestroyThread(Thread);
    Lock.unlock();
    FEX::Windows::DeinitCRTThread();
    /* Keep the exported void ABI. Terminate natively before any guest callback
     * can observe a zero call-return stack. */
    RtlExitUserThread(STATUS_NO_MEMORY);
  }

  const auto TLS = GetTLS();
  // MADEIRA: one line per thread naming the slot this module's ThreadState lives in, the TEB it is
  // written to, and what was in the slot beforehand.
  //
  // The SIXTH DEVICE RUN found 2 in this slot on a thread that had never reached here, and there
  // was no way to tell "somebody else owns the slot" from "the TEB was never zeroed" from "we read
  // the wrong TEB". A non-zero `was` value answers that directly, on the thread that claims it.
  const uint64_t PrevSlotValue = TLS.RawThreadState();
  TLS.ThreadState() = Thread;
  TLS.ControlWord().fetch_or(ControlBits::WOW_CPU_AREA_DIRTY, std::memory_order::relaxed);
  LogMan::Msg::EFmt("[wow64-tls] tid={:#x} teb={} slot[{}]=ThreadState {} (was {:#x}{})", GetCurrentThreadId(),
                    static_cast<void*>(TLS.TEB), TLS.ThreadStateSlot, static_cast<void*>(Thread), PrevSlotValue,
                    PrevSlotValue ? " - NOT ZERO, slot content did not come from this module" : "");

  Thread->FrontendPtr = new FrontendThreadData();

  // MADEIRA ml1430: route this thread's syscalls through the parking entry and let the
  // code-buffer sweeper see it (see IosWowPark).
  if (IosWowSweepEnabled()) {
    auto* TD = GetFrontendThreadData(Thread);
    Thread->CurrentFrame->Pointers.SyscallHandlerFunc = reinterpret_cast<uint64_t>(&IosWowSyscallEntry);
    IosSweepRegisterThreadEx(Thread, &TD->IosInSim, &TD->IosMigrated);
    TD->IosSweepRegistered = true;
  }

  auto ThreadTID = GetCurrentThreadId();
  Threads.emplace(ThreadTID, Thread);
  if (StatAllocHandler) {
    Thread->ThreadStats = StatAllocHandler->AllocateSlot(ThreadTID);
  }
}

void BTCpuThreadTerm(HANDLE Thread, LONG ExitCode) {
  if (!FEX::Windows::ValidateHandleAccess(Thread, THREAD_TERMINATE)) {
    return;
  }

  auto ThreadDup = FEX::Windows::DupHandle(Thread, THREAD_QUERY_INFORMATION | THREAD_SUSPEND_RESUME);

  THREAD_BASIC_INFORMATION Info;
  if (auto Err = NtQueryInformationThread(*ThreadDup, ThreadBasicInformation, &Info, sizeof(Info), nullptr); Err) {
    return;
  }

  const auto ThreadTID = reinterpret_cast<uint64_t>(Info.ClientId.UniqueThread);
  bool Self = ThreadTID == GetCurrentThreadId();
  if (!Self) {
    // If we are suspending a thread that isn't ourselves, try to suspend it first so we know internal JIT locks aren't being held.
    RtlWow64SuspendThread(*ThreadDup, NULL);
  }

  auto [Err, TLS] = GetThreadTLS(*ThreadDup);
  if (Err) {
    return;
  }

  {
    std::scoped_lock Lock(ThreadCreationMutex);
    auto it = Threads.find(ThreadTID);
    if (it == Threads.end()) {
      // Thread already terminated
      return;
    }

    Threads.erase(it);
    if (StatAllocHandler) {
      StatAllocHandler->DeallocateSlot(TLS.ThreadState()->ThreadStats);
    }
  }
  auto ThreadState = TLS.ThreadState();

  // MADEIRA ml1430: the sweeper's registry points into the frontend data; leave it (and
  // wait out any sweep in flight) before that is freed. No locks are held here.
  if (GetFrontendThreadData(ThreadState)->IosSweepRegistered) {
    IosSweepUnregisterThread(ThreadState);
  }
  delete GetFrontendThreadData(ThreadState);

  // GDT and LDT are mirrored, only free one.
  delete[] ThreadState->CurrentFrame->State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_GDT];

  FEX::Windows::CallRetStack::DestroyThread(ThreadState);
  CTX->DestroyThread(ThreadState);
  if (Self) {
    FEX::Windows::DeinitCRTThread();
  }
}

void* BTCpuGetBopCode() {
  return BridgeInstrs::Syscall;
}

void* __wine_get_unix_opcode() {
  return BridgeInstrs::UnixCall;
}

/*
 * MADEIRA ml970: SELF IS NOT A HANDLE OPERATION.
 *
 * [srv-stats] on a 32-bit D3D9 title showed five wineserver request kinds
 * locked together at ~177/s each -- get_object_info=1770 dup_handle=1770
 * close_handle=1772 get_thread_context=1770 per 10 s, plus
 * set_thread_context=2950 -- which is 3 to 5 requests per rendered frame for
 * something no D3D9 game does. They are all ours: with G calls of
 * BTCpuGetContext and S of BTCpuSetContext the bodies below issue exactly
 * G+S object-info, G+S dup, G+S close, G+S get_thread_context and G+2S
 * set_thread_context requests, and G=590 S=1180 reproduces all five measured
 * numbers exactly.
 *
 * And the handle is always the same one. Every internal caller in
 * wine/dlls/wow64/syscall.c -- 32-bit exception dispatch, NtContinue,
 * NtSetContextThread, the APC and callback paths -- passes
 * GetCurrentThread(), i.e. the pseudo-handle, never a real thread handle:
 *
 *     pBTCpuGetContext( GetCurrentThread(), GetCurrentProcess(), NULL, &ctx );
 *
 * so the NtQueryObject / NtDuplicateObject / NtClose triple validates,
 * duplicates and closes a handle to the calling thread itself, three server
 * round trips to learn something the thread already knows. Worse, the
 * duplicate is what made the rest expensive: Wine's get_thread_wow64_context()
 * and set_thread_wow64_context() (dlls/ntdll/unix/signal_arm64.c) both open
 * with `BOOL self = (handle == GetCurrentThread());' and read or write the
 * caller's own CPU area with NO server call when that holds -- a duplicated
 * handle to the same thread does not compare equal, so every context transfer
 * took the cross-thread path through the server for nothing.
 *
 * So: when the target IS the current thread, skip the validation (a thread
 * always has full access to itself), skip the duplicate, and hand the
 * pseudo-handle straight down. Nothing else changes: a real handle -- which is
 * what a guest-issued GetThreadContext on another thread arrives as -- still
 * takes the original path, access check included.
 *
 * Expected: get_object_info, dup_handle and close_handle drop to ~0,
 * get_thread_info loses ~1770 per 10 s, and get_thread_context /
 * set_thread_context drop to ~0 as well because the self fast path above then
 * engages -- together ~1180 requests/s of the measured ~3700/s.
 */
NTSTATUS BTCpuGetContext(HANDLE Thread, HANDLE Process, void* Unknown, WOW64_CONTEXT* Context) {
  const bool Self = Thread == GetCurrentThread();

  if (!Self && !FEX::Windows::ValidateHandleAccess(Thread, THREAD_GET_CONTEXT)) {
    return STATUS_ACCESS_DENIED;
  }

  auto ThreadDup = Self ? FEX::Windows::ScopedHandle {} :
                          FEX::Windows::DupHandle(Thread, THREAD_QUERY_INFORMATION | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT);
  const HANDLE Target = Self ? Thread : *ThreadDup;

  auto [Err, TLS] = GetThreadTLS(Target);
  if (Err) {
    return Err;
  }

  Context::ScopedJITContextLock Lk {TLS};
  if (Err = Context::FlushThreadStateContext(Target); Err) {
    return Err;
  }

  return RtlWow64GetThreadContext(Target, Context);
}

// MADEIRA ml970: same self short-circuit as BTCpuGetContext above; see the
// comment there for the measurement and for why the duplicate was the thing
// that forced Wine's cross-thread context path.
NTSTATUS BTCpuSetContext(HANDLE Thread, HANDLE Process, void* Unknown, WOW64_CONTEXT* Context) {
  const bool Self = Thread == GetCurrentThread();

  if (!Self && !FEX::Windows::ValidateHandleAccess(Thread, THREAD_SET_CONTEXT)) {
    return STATUS_ACCESS_DENIED;
  }

  auto ThreadDup = Self ? FEX::Windows::ScopedHandle {} :
                          FEX::Windows::DupHandle(Thread, THREAD_QUERY_INFORMATION | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT);
  const HANDLE Target = Self ? Thread : *ThreadDup;

  auto [Err, TLS] = GetThreadTLS(Target);
  if (Err) {
    return Err;
  }

  // Back-up the input context incase we've been passed the CPU area (the flush below would wipe it out otherwise)
  WOW64_CONTEXT TmpContext = *Context;

  Context::ScopedJITContextLock Lk {TLS};
  if (Err = Context::FlushThreadStateContext(Target); Err) {
    return Err;
  }

  // Merge the input context into the CPU area then pass the full context into the JIT
  if (Err = RtlWow64SetThreadContext(Target, &TmpContext); Err) {
    return Err;
  }

  TmpContext.ContextFlags = WOW64_CONTEXT_FULL | WOW64_CONTEXT_EXTENDED_REGISTERS;

  if (Err = RtlWow64GetThreadContext(Target, &TmpContext); Err) {
    return Err;
  }

  if (Thread == GetCurrentThread() && TLS.CachedCallRetSp()) {
    TLS.ThreadState()->CurrentFrame->State.callret_sp = TLS.CachedCallRetSp();
  }

  Context::LoadStateFromWowContext(TLS.ThreadState(), GetWowTEB(TLS.TEB), &TmpContext);
  return STATUS_SUCCESS;
}

// .seh_pushframe doesn't restore the frame pointer, so if when unwinding from RtlCaptureContext an operation is used
// that sets SP from FP, the unwound SP value will be incorrect. Wrap RtlCaptureContext so the correct FP is immediately
// restored from the stack to prevent this.
__attribute__((naked)) void BTCpuSimulate() {
  asm(".seh_proc BTCpuSimulate;"
      "sub sp, sp, #0x390;"
      ".seh_stackalloc 0x390;"
      "stp x29, x30, [sp, #-0x10]!;"
      ".seh_save_fplr_x 16;"
      ".seh_endprologue;"
      "add x0, sp, #0x10;"
      "bl RtlCaptureContext;"
      "add x0, sp, #0x10;"
      "bl BTCpuSimulateImpl;"
      "ldp x29, x30, [sp], 0x10;"
      "add sp, sp, #0x390;"
      "ret;"
      ".seh_endproc;");
}

extern "C" void BTCpuSimulateImpl(CONTEXT* entry_context) {
  const auto TLS = GetTLS();
  // MADEIRA ml1430: a callback can re-enter simulation from inside a parked syscall; it runs
  // emitted code, so the sweeper must see it as in-simulation again (and any sweep finish).
  IosWowUnpark(GetFrontendThreadData(TLS.ThreadState()));
  TLS.EntryContext() = entry_context;
  TLS.CachedCallRetSp() = TLS.ThreadState()->CurrentFrame->State.callret_sp;

  Context::ScopedJITContextLock Lk {TLS};
  CTX->ExecuteThread(TLS.ThreadState());
}

NTSTATUS BTCpuSuspendLocalThread(HANDLE Thread, ULONG* Count) {
  if (!FEX::Windows::ValidateHandleAccess(Thread, THREAD_SUSPEND_RESUME)) {
    return STATUS_ACCESS_DENIED;
  }

  auto ThreadDup = FEX::Windows::DupHandle(Thread, THREAD_QUERY_INFORMATION | THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT);
  THREAD_BASIC_INFORMATION Info;
  if (NTSTATUS Err = NtQueryInformationThread(*ThreadDup, ThreadBasicInformation, &Info, sizeof(Info), nullptr); Err) {
    return Err;
  }

  const auto ThreadTID = reinterpret_cast<uint64_t>(Info.ClientId.UniqueThread);
  if (ThreadTID == GetCurrentThreadId()) {
    LogMan::Msg::DFmt("Suspending self");
    // Mark the CPU area as dirty, to force the JIT context to be restored from it on entry as it may be changed using
    // SetThreadContext (which doesn't use the BTCpu API)
    if (!(GetTLS().ControlWord().fetch_or(ControlBits::WOW_CPU_AREA_DIRTY, std::memory_order::relaxed) & ControlBits::WOW_CPU_AREA_DIRTY)) {
      if (NTSTATUS Err = Context::FlushThreadStateContext(*ThreadDup); Err) {
        return Err;
      }
    }

    return NtSuspendThread(*ThreadDup, Count);
  }

  LogMan::Msg::DFmt("Suspending thread: {:X}", ThreadTID);

  auto [Err, TLS] = GetThreadTLS(*ThreadDup);
  if (Err) {
    return Err;
  }

  std::scoped_lock Lock(ThreadCreationMutex);

  // If the thread hasn't yet been initialized, suspend it without special handling as it wont yet have entered the JIT
  if (!Threads.contains(ThreadTID)) {
    LogMan::Msg::DFmt("Thread suspended: {:X}", ThreadTID);
    return NtSuspendThread(*ThreadDup, Count);
  }

  // If CONTROL_IN_JIT is unset at this point, then it can never be set (and thus the JIT cannot be reentered) as
  // CONTROL_PAUSED has been set, as such, while this may redundantly request interrupts in rare cases it will never
  // miss them
  if (TLS.ControlWord().fetch_or(ControlBits::PAUSED, std::memory_order::relaxed) & ControlBits::IN_JIT) {
    LogMan::Msg::DFmt("Thread {:X} is in JIT, polling for interrupt", ThreadTID);

    ULONG TmpProt;
    void* TmpAddress = &TLS.ThreadState()->InterruptFaultPage;
    SIZE_T TmpSize = FEXCore::Utils::FEX_PAGE_SIZE;
    NtProtectVirtualMemory(NtCurrentProcess(), &TmpAddress, &TmpSize, PAGE_READONLY, &TmpProt);
  }

  /* Spin until the JIT is interrupted.
   *
   * ml930: `yield` added. This was a NAKED relaxed-load spin: on iOS the waiter
   * and the JIT thread it is waiting for are frequently on the same cluster and a
   * bare load loop both burns a full core and starves the very thread that has to
   * reach the interrupt check. `yield` is an instruction hint, not a syscall — it
   * costs nothing and never enters the kernel, so it cannot become another
   * swtch_pri source (see the NtYieldExecution finding in WOW64_DESIGN.md §6). */
  while (TLS.ControlWord().load() & ControlBits::IN_JIT) {
    __asm__ volatile("yield" ::: "memory");
  }

  // The JIT has now been interrupted and the context stored in the thread's CPU area is up-to-date
  if (Err = NtSuspendThread(*ThreadDup, Count); Err) {
    TLS.ControlWord().fetch_and(~ControlBits::PAUSED, std::memory_order::relaxed);
    return Err;
  }

  CONTEXT TmpContext {
    .ContextFlags = CONTEXT_INTEGER,
  };

  // NtSuspendThread may return before the thread is actually suspended, so a sync operation like NtGetContextThread
  // needs to be called to ensure it is before we unset CONTROL_PAUSED
  std::ignore = NtGetContextThread(*ThreadDup, &TmpContext);

  // Mark the CPU area as dirty, to force the JIT context to be restored from it on entry as it may be changed using
  // SetThreadContext (which doesn't use the BTCpu API)
  if (!(TLS.ControlWord().fetch_or(ControlBits::WOW_CPU_AREA_DIRTY, std::memory_order::relaxed) & ControlBits::WOW_CPU_AREA_DIRTY)) {
    if (Err = Context::FlushThreadStateContext(*ThreadDup); Err) {
      return Err;
    }
  }

  LogMan::Msg::DFmt("Thread suspended: {:X}", ThreadTID);

  // Now the thread is suspended on the host, unset CONTROL_PAUSED so that NtResumeThread will
  // continue execution in the JIT
  TLS.ControlWord().fetch_and(~ControlBits::PAUSED, std::memory_order::relaxed);

  return Err;
}

// Returns true if exception dispatch should be halted and the execution context restored to Ptrs->Context
bool BTCpuResetToConsistentStateImpl(EXCEPTION_POINTERS* Ptrs) {
  auto* Context = Ptrs->ContextRecord;
  auto* Exception = Ptrs->ExceptionRecord;
  auto TLS = GetTLS();

  // MADEIRA ml800: an exception can reach this module before the faulting thread has any FEX
  // state at all.
  //
  // FIFTH DEVICE RUN, fault #3: a fault taken inside a Wine syscall was delivered "best effort"
  // into this module during BTCpuProcessInit - before BTCpuThreadInit had ever run, so
  // TlsSlots[THREAD_STATE] was still NULL - and the very first statement here,
  // FEXCORE_PROFILE_ACCUMULATION(Thread, ...), dereferenced it at +0x40
  // (libwow64fex+0xff9b0, addr=0x40). A null thread state turned a reportable fault into a
  // second, meaningless one.
  //
  // Every handler below except the overcommit tracker is per-thread and has nothing to say for a
  // thread with no state (HandleSuspendInterrupt and JITGuardPage both read through
  // TLS.ThreadState() themselves), so the honest answer is "not handled": return false and let
  // wow64.dll/ntdll dispatch the original exception.
  // CurrentTEB() falls back to x18 when the TSD slot is not populated yet, and iOS zeroes x18.
  if (!TLS.TEB) {
    return false;
  }

  // MADEIRA: hardened read - see ThreadStateIfInitialised(). A value that is not a pointer means
  // this thread has never run BTCpuThreadInit, which is the same situation as a null slot.
  auto Thread = TLS.ThreadStateIfInitialised();
  if (!Thread) {
    if (Exception->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && OvercommitTracker &&
        OvercommitTracker->HandleAccessViolation(static_cast<uint64_t>(Exception->ExceptionInformation[1]))) {
      // Process-wide, not per-thread: a commit-on-demand fault is still ours to satisfy.
      return true;
    }
    return false;
  }

  FEXCORE_PROFILE_ACCUMULATION(Thread, AccumulatedSignalTime);

  if (Exception->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
    // MADEIRA: this record is still the 64-bit one wow64.dll captured, so ExceptionInformation[1]
    // is a HOST address - which is what every handler below wants, since CallRetStack, the
    // overcommit tracker, the JIT guard pages, the suspend-interrupt page and InvalidationTracker
    // all live in host addresses.
    //
    // It is deliberately NOT converted to a guest address here. wow64.dll owns that conversion:
    // exception_record_64to32() is what builds the 32-bit record the guest actually sees, and per
    // the design it applies -B to ExceptionAddress and to ExceptionInformation[1] of access
    // violations. Converting here as well would double-apply it. The one thing this module must
    // guarantee in return is that any address it *synthesises* into a record stays host-side, so
    // that wow64.dll's single uniform conversion is correct.
    const auto FaultAddress = static_cast<uint64_t>(Exception->ExceptionInformation[1]);

    if (FEX::Windows::CallRetStack::HandleAccessViolation(Thread, FaultAddress, Context->X25)) {
      return true;
    }

    if (OvercommitTracker && OvercommitTracker->HandleAccessViolation(FaultAddress)) {
      return true;
    }

    if (Context::HandleSuspendInterrupt(TLS, Context, FaultAddress)) {
      LogMan::Msg::DFmt("Resumed from suspend");
      return true;
    }

    if (FEX::Windows::JITGuardPage::HandleJITGuardPage(Thread, reinterpret_cast<void*>(FaultAddress), Context->X,
                                                       reinterpret_cast<__uint128_t*>(Context->V), &Context->Pc)) {
      return true;
    }

    if (Thread) {
      std::scoped_lock Lock(ThreadCreationMutex);
      FEXCORE_PROFILE_INSTANT_INCREMENT(Thread, AccumulatedSMCCount, 1);
      if (InvalidationTracker->HandleRWXAccessViolation(Thread, Context->Pc, FaultAddress)) {
        // MADEIRA: IsAddressInCurrentBlock compares against the block's guest RIP, so this one
        // needs the fault address in the guest namespace - unlike everything else on this path.
        const auto GuestFaultAddress = GuestWindow::ToGuestIfInWindow(FaultAddress);
        if (CTX->IsAddressInCodeBuffer(Thread, Context->Pc) && !CTX->IsCurrentBlockSingleInst(Thread) &&
            CTX->IsAddressInCurrentBlock(Thread, GuestFaultAddress & FEXCore::Utils::FEX_PAGE_MASK, FEXCore::Utils::FEX_PAGE_SIZE)) {
          Context::ReconstructThreadState(TLS, Context);
          LogMan::Msg::DFmt("Handled inline self-modifying code: pc: {:X} rip: {:X} fault: {:X}", Context->Pc,
                            Thread->CurrentFrame->State.rip, FaultAddress);

          // Adjust context to return to the dispatcher, reloading SRA from thread state
          const auto& Config = SignalDelegator->GetConfig();
          Context->Pc = Config.AbsoluteLoopTopAddressFillSRA;
          Context->X1 = 1; // Set ENTRY_FILL_SRA_SINGLE_INST_REG to force a single step
        } else {
          LogMan::Msg::DFmt("Handled self-modifying code: pc: {:X} fault: {:X}", Context->Pc, FaultAddress);
        }
        return true;
      }
    }
  }

  if (!Thread || !IsAddressInJit(Context->Pc)) {
    return false;
  }

  FEXCORE_PROFILE_INSTANT_INCREMENT(Thread, AccumulatedSIGBUSCount, 1);
  if (Exception->ExceptionCode == EXCEPTION_DATATYPE_MISALIGNMENT && Context::HandleUnalignedAccess(TLS, Context)) {
    LogMan::Msg::DFmt("Handled unaligned atomic: new pc: {:X}", Context->Pc);
    return true;
  }

  LogMan::Msg::DFmt("Reconstructing context");

  WOW64_CONTEXT WowContext = Context::ReconstructWowContext(TLS, Context);
  LogMan::Msg::DFmt("pc: {:X} eip: {:X}", Context->Pc, WowContext.Eip);

  auto& Fault = Thread->CurrentFrame->SynchronousFaultData;
  *Exception = FEX::Windows::HandleGuestException(Fault, *Exception, WowContext.Eip, WowContext.Eax, WowContext.Ecx);
  if (Exception->ExceptionCode == EXCEPTION_SINGLE_STEP) {
    WowContext.EFlags &= ~(1 << FEXCore::X86State::RFLAG_TF_RAW_LOC);
  }
  // wow64.dll will handle adjusting PC in the dispatched context after a breakpoint

  BTCpuSetContext(GetCurrentThread(), GetCurrentProcess(), nullptr, &WowContext);
  Context::UnlockJITContext(TLS);

  // Replace the host context with one captured before JIT entry so host code can unwind
  memcpy(Context, TLS.EntryContext(), sizeof(*Context));

  return false;
}

NTSTATUS BTCpuResetToConsistentState(EXCEPTION_POINTERS* Ptrs) {
  if (BTCpuResetToConsistentStateImpl(Ptrs)) {
    NtContinue(Ptrs->ContextRecord, FALSE);
  }

  return STATUS_SUCCESS;
}

// MADEIRA - namespace contract for every BTCpu* callback below: wow64.dll converts guest -> host
// before it calls us, so every `Address`/`Size` pair that arrives here is already a HOST address in
// this process's window, and the trackers it is forwarded to are host-namespace. Conversions happen
// only where FEXCore is on the other side (WowSyscallHandler above) or where the value came from a
// guest-namespace publisher (LdrSystemDllInitBlock in BTCpuProcessInit). Per-callback evidence is
// noted on each one.

// HOST: wine/dlls/wow64/virtual.c:279 retarget_ptr() after get_ptr() (which is guest_ptr32);
// cross-process path syscall.c:1610 passes entry->addr, the sender's host address in OUR window.
void BTCpuFlushInstructionCache2(const void* Address, SIZE_T Size) {
  std::scoped_lock Lock(ThreadCreationMutex);
  InvalidationTracker->InvalidateAlignedInterval(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), false);
}

// HOST: same as above; also called with (NULL, 0) from syscall.c:1576 as a flush-everything request.
void BTCpuFlushInstructionCacheHeavy(const void* Address, SIZE_T Size) {
  std::scoped_lock Lock(ThreadCreationMutex);
  InvalidationTracker->InvalidateAlignedInterval(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), false);
}

// HOST: only caller is wine/dlls/wow64/syscall.c:1618 (CrossProcessMemoryWrite), entry->addr.
void BTCpuNotifyMemoryDirty(void* Address, SIZE_T Size) {
  std::scoped_lock Lock(ThreadCreationMutex);
  InvalidationTracker->InvalidateAlignedInterval(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), false);
}

// HOST: wine/dlls/wow64/virtual.c:158/198 `addr = guest_ptr32_in( base, *addr32 )` before the call
// and the value NtAllocateVirtualMemory(Ex) returned after it; the guest only sees it again through
// put_addr_in() at :177/:221. Cross-process: syscall.c:1593, entry->addr, the target's host address.
void BTCpuNotifyMemoryAlloc(void* Address, SIZE_T Size, ULONG Type, ULONG Prot, BOOL After, ULONG Status) {
  if (!After) {
    ThreadCreationMutex.lock();
  } else {
    // MEM_RESET(_UNDO) ignores the passed permissions
    if (!Status && !(Type & (MEM_RESET | MEM_RESET_UNDO))) {
      InvalidationTracker->HandleMemoryProtectionNotification(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), Prot);
    }
    ThreadCreationMutex.unlock();
  }
}

// HOST: wine/dlls/wow64/virtual.c:558 guest_ptr32_in(); cross-process syscall.c:1605 entry->addr.
void BTCpuNotifyMemoryProtect(void* Address, SIZE_T Size, ULONG NewProt, BOOL After, ULONG Status) {
  if (!After) {
    ThreadCreationMutex.lock();
  } else {
    if (!Status) {
      InvalidationTracker->HandleMemoryProtectionNotification(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), NewProt);
    }
    ThreadCreationMutex.unlock();
  }
}

// HOST: wine/dlls/wow64/virtual.c:327 guest_ptr32_in(); cross-process syscall.c:1599 entry->addr.
void BTCpuNotifyMemoryFree(void* Address, SIZE_T Size, ULONG FreeType, BOOL After, ULONG Status) {
  if (!After) {
    ThreadCreationMutex.lock();
  } else {
    if (!Status) {
      InvalidationTracker->InvalidateAlignedInterval(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), true);
    }
    ThreadCreationMutex.unlock();
  }
}

// HOST: wine/dlls/wow64/virtual.c:465 notify_map_view_of_section() forwards the `addr` that
// NtMapViewOfSection(Ex) returned through addr_32to64_in( base, ... ) at :494/:534, i.e. the host VA
// the view was actually mapped at - the guest value is only written back by put_addr_in() at
// :498/:538. Same value init_image_mapping() is given one line earlier.
NTSTATUS BTCpuNotifyMapViewOfSection(void* Unk1, void* Address, void* Unk2, SIZE_T Size, ULONG AllocType, ULONG Prot) {
  std::scoped_lock Lock(ThreadCreationMutex);
  HandleImageMap(reinterpret_cast<uint64_t>(Address));
  return STATUS_SUCCESS;
}

// HOST: wine/dlls/wow64/virtual.c:881 and :903 retarget_ptr( target's base, get_ptr(...) ).
void BTCpuNotifyUnmapViewOfSection(void* Address, BOOL After, ULONG Status) {
  if (!After) {
    ThreadCreationMutex.lock();
    auto [Start, Size] = InvalidationTracker->InvalidateContainingSection(reinterpret_cast<uint64_t>(Address), true);
    if (Size) {
      HandleImageUnmap(Start, Size);
    }
  } else {
    ThreadCreationMutex.unlock();
  }
}

// HOST: wine/dlls/wow64/file.c:672 `buffer = get_ptr( &args )` = guest_ptr32(), passed verbatim to
// both the notification (:680, :683) and NtReadFile itself. Handle is a handle - never offset.
void BTCpuNotifyReadFile(HANDLE Handle, void* Address, SIZE_T Size, BOOL After, NTSTATUS Status) {
  // MADEIRA: wow64.dll calls this from NtReadFile, which the 32-bit loader uses before this
  // thread has any FEX state - so the slot read has to be the hardened one, and a thread with no
  // state has no RWX read to track. Same reasoning as the exception handler.
  auto* NotifyThread = GetTLS().ThreadStateIfInitialised();
  if (!NotifyThread) {
    return;
  }
  auto& InLockedRWXRead = GetFrontendThreadData(NotifyThread)->InLockedRWXRead;
  if (!After) {
    ThreadCreationMutex.lock();
    CTX->GetCodeInvalidationMutex().lock();
    if (InvalidationTracker->BeginUntrackedWriteLocked(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size))) {
      InLockedRWXRead = true;
    } else {
      CTX->GetCodeInvalidationMutex().unlock();
      ThreadCreationMutex.unlock();
    }
  } else {
    if (InLockedRWXRead) {
      InLockedRWXRead = false;
      CTX->GetCodeInvalidationMutex().unlock();
      ThreadCreationMutex.unlock();
    }
  }
}

// No address at all - Flags is a bitmask (MEM_EXECUTE_OPTION_*). Nothing to convert. Note that this
// Wine tree never calls it: NtSetInformationProcess(ProcessExecuteFlags) is forwarded straight
// through at wine/dlls/wow64/process.c:962 with no BTCpu notification.
void BTCpuNotifyProcessExecuteFlagsChange(ULONG Flags) {
  std::scoped_lock Lock(ThreadCreationMutex);
  InvalidationTracker->HandleProcessExecuteFlagsChange(Flags);
}

BOOLEAN WINAPI BTCpuIsProcessorFeaturePresent(UINT Feature) {
  return CPUFeatures->IsFeaturePresent(Feature) ? TRUE : FALSE;
}

void BTCpuUpdateProcessorInformation(SYSTEM_CPU_INFORMATION* Info) {
  CPUFeatures->UpdateInformation(Info);
}

#ifdef FEX_IOS_HOST
/* MADEIRA: FEXCore's Frontend and OpcodeDispatcher call the ARM64EC module's
 * sub-floor window lookups (ARM64EC/IosJitAlias.cpp) on the iOS host, which the
 * WOW64 module does not link. A 32-bit guest
 * lives entirely inside its own 4 GB window and never has a PE image mapped below
 * the 4 GB floor, so here there is no window: addresses map to themselves and no
 * code belongs to one. */
extern "C" uint64_t IosSubfloorToReal(uint64_t Addr) {
  return Addr;
}
extern "C" int IosSubfloorWindowForCode(uint64_t, uint64_t*, uint64_t*, uint64_t*) {
  return 0;
}
#endif
