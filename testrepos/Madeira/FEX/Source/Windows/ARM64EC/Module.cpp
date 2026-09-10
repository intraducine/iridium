// SPDX-License-Identifier: MIT
/*
$info$
tags: Bin|ARM64EC
desc: Implements the ARM64EC BT module API using FEXCore
$end_info$
*/

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
#include <FEXCore/Utils/MathUtils.h>
#include <FEXCore/Utils/TypeDefines.h>
#include <FEXCore/Utils/SignalScopeGuards.h>

#include "Windows/Common/Allocator.h"
#include "Windows/Common/EnvironmentVariablesHandling.h"
#include "Windows/Common/FEXUnixLib.h"
#include "Common/CallRetStack.h"
#include "Common/JITGuardPage.h"
#include "Common/Config.h"
#include "Common/Exception.h"
#include "Common/ImageTracker.h"
#include "Common/InvalidationTracker.h"
#include "Common/OvercommitTracker.h"
#include "Common/TSOHandlerConfig.h"
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
#include <cstdio>
#include <type_traits>
#include <atomic>
#include <mutex>
#include <optional>
#include <unordered_map>
#include <utility>
#include <ntstatus.h>
#include <windef.h>
#include <winternl.h>
#include <winnt.h>
#include <wine/debug.h>

/* ml751: the VA band selector's deferred beacon buffer, filled by
 * ios_va_emit() in rpmalloc.c before the ARM64EC TEB exists and therefore
 * before any logging API is callable. Flushed once LogMan is up. */
extern "C" char ios_va_log[];
extern "C" int ios_va_log_len;

#ifdef FEX_IOS_HOST
/* iOS JIT-pool alias resolution. Implemented in IosJitAlias.cpp (separate
 * TU because ARM64EC class-method access to the static table directly from
 * this TU triggered "misaligned ldr/str offset" link errors). The
 * BTCpu64IosAddAliasMapping export is populated by Wine ntdll-unix when
 * PE images are copied into the JIT pool. */
extern "C" uint64_t IosJitTranslate(uint64_t Addr);
extern "C" uint64_t IosJitReverseTranslate(uint64_t Addr);
/* ml316: FFS-bypass diagnostics, written by ExitToX64's bypass path in Module.S:
 * [0] = native short-circuits taken, [1] = last EC target,
 * [2] = FFS matched but target not EC (fell through to emulation), [3] = last such
 * target. Read by the [ffs-bypass] reporter in Core.cpp's CompileBlock. */
extern "C" uint64_t IosFfsBypassLog[4];

/* Raw TSD byte offset (from TPIDRRO_EL0 & ~7) of the slot holding the TEB.
 * Discovered and published by wine's ntdll-unix; imported in ProcessInit.
 * Defined in FEXCore Arm64Emitter.cpp, where the JIT emitters also read it. */
extern "C" uint32_t IosTebTsdOffset;
/* uint32_t, not bool: a 1-byte global here misaligned the adrp/ldr pair
 * lld generates for the neighbouring word ("misaligned ldr/str offset"). */
static uint32_t IosTebTsdImportFound = 0;
uint64_t IosFfsBypassLog[4] {};
#endif // FEX_IOS_HOST

namespace Exception {
class ECSyscallHandler;
}

extern "C" {
extern IMAGE_DOS_HEADER __ImageBase; // Provided by the linker

extern void* ExitFunctionEC;
extern void* CheckCall;
extern void* ExitFunctionSuspendPoint;
extern void* ExitFunctionSuspendResumePoint;

void* X64ReturnInstr; // See Module.S
uintptr_t NtDllBase;

// Exports on ARM64EC point to x64 fast forward sequences to allow for redirecting to the JIT if functions are hotpatched. This LUT is from their addresses to the relative addresses of the native code exports.
uint32_t* NtDllRedirectionLUT;
uint32_t NtDllRedirectionLUTSize;

// Wine doesn't support issuing direct system calls with SVC, and unlike Windows it doesn't have a 'stable' syscall number for NtContinue
void* WineSyscallDispatcher;
uint64_t WineNtContinueSyscallId;
uint64_t WineNtAllocateVirtualMemorySyscallId;
uint64_t WineNtProtectVirtualMemorySyscallId;

NTSTATUS NtContinueNative(ARM64_NT_CONTEXT* NativeContext, BOOLEAN Alert);
NTSTATUS NtAllocateVirtualMemoryNative(HANDLE, PVOID*, ULONG_PTR, SIZE_T*, ULONG, ULONG);
NTSTATUS NtProtectVirtualMemoryNative(HANDLE, PVOID*, SIZE_T*, ULONG, ULONG*);

[[noreturn]]
void JumpSetStack(uintptr_t PC, uintptr_t SP);
}

struct ThreadCPUArea {
  static constexpr size_t TEBCPUAreaOffset = 0x1788;
  CHPE_V2_CPU_AREA_INFO* Area;

  explicit ThreadCPUArea(_TEB* TEB)
    : Area(*reinterpret_cast<CHPE_V2_CPU_AREA_INFO**>(reinterpret_cast<uintptr_t>(TEB) + TEBCPUAreaOffset)) {}

  uint64_t& EmulatorStackLimit() const {
    return Area->EmulatorStackLimit;
  }

  uint64_t& EmulatorStackBase() const {
    return Area->EmulatorStackBase;
  }

  ARM64EC_NT_CONTEXT& ContextAmd64() const {
    return *Area->ContextAmd64;
  }

  FEXCore::Core::CpuStateFrame*& StateFrame() const {
    return reinterpret_cast<FEXCore::Core::CpuStateFrame*&>(Area->EmulatorData[0]);
  }

  FEXCore::Core::InternalThreadState*& ThreadState() const {
    return reinterpret_cast<FEXCore::Core::InternalThreadState*&>(Area->EmulatorData[1]);
  }

  uint64_t& DispatcherLoopTopEnterEC() const {
    return reinterpret_cast<uint64_t&>(Area->EmulatorData[2]);
  }

  uint64_t& DispatcherLoopTopEnterECFillSRA() const {
    return reinterpret_cast<uint64_t&>(Area->EmulatorData[3]);
  }
};

struct FrontendThreadData {
  bool InLockedRWXRead {};
};

namespace {
fextl::unique_ptr<FEXCore::Context::Context> CTX;
fextl::unique_ptr<FEX::DummyHandlers::DummySignalDelegator> SignalDelegator;
fextl::unique_ptr<Exception::ECSyscallHandler> SyscallHandler;
fextl::unique_ptr<FEX::Windows::StatAlloc> StatAllocHandler;
std::optional<FEX::Windows::InvalidationTracker> InvalidationTracker;
std::optional<FEX::Windows::CPUFeatures> CPUFeatures;
std::optional<FEX::Windows::OvercommitTracker> OvercommitTracker;
std::optional<FEX::Windows::ImageTracker> ImageTracker;

// iOS-Madeira: arm64ec-mingw doesn't reliably run global C++ ctors, so the
// recursive_mutex / unordered_map below would be zero-init'd and any lock()
// would hang in NtWaitForAlertByThreadId. Wrap as Meyers singletons so they
// construct on first use regardless of the broken static-init chain.
inline std::recursive_mutex& GetThreadCreationMutex() {
  static std::recursive_mutex Mutex;
  return Mutex;
}
#define ThreadCreationMutex GetThreadCreationMutex()

inline std::unordered_map<DWORD, FEXCore::Core::InternalThreadState*>& GetThreadsMap() {
  static std::unordered_map<DWORD, FEXCore::Core::InternalThreadState*> Map;
  return Map;
}
#define Threads GetThreadsMap()

#ifdef FEX_IOS_HOST
/* iOS-Madeira ml460 (#75): pool-tail sweep registry, implemented in
 * CPUBackend.cpp (which has the full CPUBackend type). This frontend only
 * registers each thread's ThreadState + &CpuArea->InSimulation at init and
 * unregisters at term — the unregister BLOCKS until any in-flight sweep
 * drains and must be called with no locks held. */
extern "C" void IosSweepRegisterThread(FEXCore::Core::InternalThreadState* Thread, volatile uint8_t* InSimPtr);
extern "C" void IosSweepUnregisterThread(FEXCore::Core::InternalThreadState* Thread);
#endif

std::pair<NTSTATUS, ThreadCPUArea> GetThreadCPUArea(HANDLE Thread) {
  THREAD_BASIC_INFORMATION Info;
  const NTSTATUS Err = NtQueryInformationThread(Thread, ThreadBasicInformation, &Info, sizeof(Info), nullptr);
  return {Err, ThreadCPUArea(reinterpret_cast<_TEB*>(Info.TebBaseAddress))};
}

#ifdef FEX_IOS_HOST
/* iOS-Madeira 2026-05-19: NtCurrentTeb() compiles to a read of x18 on
 * ARM64EC, but x18 is clobbered by Apple runtime calls (libobjc, mach
 * syscalls, pthread, etc.). Reading it after any such call returns
 * garbage — typically 0 in cold-start paths. This is the documented
 * iOS quirk we already handle in Module.S via the IOS_LOAD_TEB macro
 * (TPIDRRO_EL0 & ~7 + TSD slot 275). This helper is the C++ equivalent.
 *
 * Use this instead of NtCurrentTeb() anywhere we're reading TEB after
 * having gone through any Apple/Wine/CRT runtime call. The asm has no
 * dependency on x18, so it's safe across clobber boundaries. */
static inline _TEB* IOSLoadTEB() {
  uintptr_t tpidrro;
  __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tpidrro));
  tpidrro &= ~uintptr_t(7);
  /* Offset zero means ProcessInit has not imported it yet -- read nothing
   * rather than dereferencing TSD slot 0, which belongs to libpthread. */
  _TEB* via_tsd = IosTebTsdOffset ? *reinterpret_cast<_TEB**>(tpidrro + IosTebTsdOffset) : nullptr;
  if (via_tsd) return via_tsd;
  /* 2026-05-19: TSD slot 275 isn't always populated by the time ThreadInit
   * runs on FMOD worker threads (Wine thread bootstrap race). Fall back to
   * NtCurrentTeb() which reads x18 — works if x18 hasn't been clobbered on
   * this thread's setup path. Better than returning nullptr (which would
   * set gs_cached=0 and cause every guest gs:[N] read to fault). */
  return NtCurrentTeb();
}
#endif

ThreadCPUArea GetCPUArea() {
#ifdef FEX_IOS_HOST
  return ThreadCPUArea(IOSLoadTEB());
#else
  return ThreadCPUArea(NtCurrentTeb());
#endif
}

#ifdef FEX_IOS_HOST
/* iOS-Madeira ml259 PROBE (#44). The CEF thread (0098) executes FEX JIT with x28 == 0:
 *   insn ldr x0,[x28,#0x658] faults with addr=0x658 -- the fault address IS the
 *   immediate, so the base is null. x28 is the CpuStateFrame, i.e. EmulatorData[0].
 *
 * Three causes need three different fixes and must be told apart:
 *   (a) ThreadInit never ran for this thread            -> no [ti-area] line for its tid
 *   (b) it ran, then the area was clobbered             -> [ti-area] non-null, [no-state] null
 *   (c) we are reading the WRONG CPU area               -> teb/area differ between the two
 * (c) is a live risk on iOS because GetCPUArea() goes through IOSLoadTEB(), which
 * falls back to NtCurrentTeb() (an x18 read) when TSD slot 275 is not yet populated --
 * and x18 is clobbered by Apple runtime calls.
 *
 * Deliberately uses LogMan (which reaches madeira-log.txt, as [caspal128] proved) and
 * NOT the WriteFile(hStdError) path the existing "ThreadInit() done" line uses -- that
 * one has never once appeared in a log, so its silence means nothing. */
static void IosLogCPUArea(const char* tag) {
  uintptr_t tpidrro;
  __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tpidrro));
  void* tsd275 = IosTebTsdOffset
                     ? *reinterpret_cast<void**>((tpidrro & ~uintptr_t(7)) + IosTebTsdOffset)
                     : nullptr;
  _TEB* teb = IOSLoadTEB();
  auto* area = *reinterpret_cast<CHPE_V2_CPU_AREA_INFO**>(reinterpret_cast<uintptr_t>(teb) + ThreadCPUArea::TEBCPUAreaOffset);

  LogMan::Msg::EFmt("[cpu-area] {} tid={:#x} teb={} tsd275={} x18teb={} area={} "
                    "StateFrame(ED0)={} ThreadState(ED1)={} EnterEC={}",
                    tag, (unsigned long long)GetCurrentThreadId(), (void*)teb, tsd275,
                    (void*)NtCurrentTeb(), (void*)area,
                    area ? (void*)area->EmulatorData[0] : nullptr,
                    area ? (void*)area->EmulatorData[1] : nullptr,
                    /* ml265: EnterEC is the dispatcher base. Needed to convert a faulting
                     * pool PC into a dispatcher-relative offset, so it can be matched
                     * against the documented emit layout (+0x160 / +0x184 / +0x264). */
                    area ? (void*)area->EmulatorData[2] : nullptr);
}
#endif

FrontendThreadData* GetFrontendThreadData(FEXCore::Core::InternalThreadState* Thread) {
  return static_cast<FrontendThreadData*>(Thread->FrontendPtr);
}

bool IsEmulatorStackAddress(const ThreadCPUArea CPUArea, uint64_t Address) {
  return Address <= CPUArea.EmulatorStackBase() && Address >= CPUArea.EmulatorStackLimit();
}

bool IsDispatcherAddress(uint64_t Address) {
  const auto& Config = SignalDelegator->GetConfig();
  return Address >= Config.DispatcherBegin && Address < Config.DispatcherEnd;
}


void FillNtDllLUTs(HMODULE NtDll) {
  ULONG Size;
  const auto* LoadConfig =
    reinterpret_cast<_IMAGE_LOAD_CONFIG_DIRECTORY64*>(RtlImageDirectoryEntryToData(NtDll, true, IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG, &Size));
  const auto* CHPEMetadata = reinterpret_cast<IMAGE_ARM64EC_METADATA*>(LoadConfig->CHPEMetadataPointer);
  const auto* RedirectionTableBegin = reinterpret_cast<IMAGE_ARM64EC_REDIRECTION_ENTRY*>(NtDllBase + CHPEMetadata->RedirectionMetadata);
  const auto* RedirectionTableEnd = RedirectionTableBegin + CHPEMetadata->RedirectionMetadataCount;

  NtDllRedirectionLUTSize = std::prev(RedirectionTableEnd)->Source + 1;

  SIZE_T AllocSize = NtDllRedirectionLUTSize * sizeof(uint32_t);
  NtAllocateVirtualMemoryNative(NtCurrentProcess(), reinterpret_cast<void**>(&NtDllRedirectionLUT), 0, &AllocSize, MEM_COMMIT | MEM_RESERVE,
                                PAGE_READWRITE);
  for (auto It = RedirectionTableBegin; It != RedirectionTableEnd; It++) {
    NtDllRedirectionLUT[It->Source] = It->Destination;
  }
}

template<typename T>
void WriteModuleRVA(HMODULE Module, LONG RVA, T Data) {
  if (!RVA) {
    return;
  }

  void* Address = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(Module) + RVA);
  void* ProtAddress = Address;
  SIZE_T ProtSize = sizeof(T);
  ULONG Prot;
  NtProtectVirtualMemoryNative(NtCurrentProcess(), &ProtAddress, &ProtSize, PAGE_READWRITE, &Prot);
  *reinterpret_cast<T*>(Address) = Data;
  NtProtectVirtualMemoryNative(NtCurrentProcess(), &ProtAddress, &ProtSize, Prot, nullptr);
}

void PatchCallChecker() {
  // See the comment for CheckCall in Module.S for why this is necessary
  const auto Module = reinterpret_cast<HMODULE>(&__ImageBase);
  ULONG Size;
  const auto* LoadConfig =
    reinterpret_cast<_IMAGE_LOAD_CONFIG_DIRECTORY64*>(RtlImageDirectoryEntryToData(Module, true, IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG, &Size));
  const auto* CHPEMetadata = reinterpret_cast<IMAGE_ARM64EC_METADATA*>(LoadConfig->CHPEMetadataPointer);
  WriteModuleRVA(Module, CHPEMetadata->__os_arm64x_dispatch_call, &CheckCall);
  WriteModuleRVA(Module, CHPEMetadata->__os_arm64x_dispatch_icall, &CheckCall);
  WriteModuleRVA(Module, CHPEMetadata->__os_arm64x_dispatch_icall_cfg, &CheckCall);
}

// Fills in the syscall numbers necessary to call *Native variants of syscalls from FEX under wine.
void ParseWineSyscallNumbers(HMODULE NtDll) {
  ULONG Size;
  const auto* Exports = reinterpret_cast<IMAGE_EXPORT_DIRECTORY*>(RtlImageDirectoryEntryToData(NtDll, true, IMAGE_DIRECTORY_ENTRY_EXPORT, &Size));
  const auto* NameTable = reinterpret_cast<uint32_t*>(NtDllBase + Exports->AddressOfNames);
  const auto* FunctionTable = reinterpret_cast<uint32_t*>(NtDllBase + Exports->AddressOfFunctions);
  const auto* OrdinalTable = reinterpret_cast<uint16_t*>(NtDllBase + Exports->AddressOfNameOrdinals);
  struct SyscallEntry {
    const char* Name;
    uint32_t RVA;

    bool operator<(const SyscallEntry& Other) const {
      return RVA < Other.RVA;
    }
  };

  // Cannot use any syscalls at this stage, so rely on a stack-allocated array
  std::array<SyscallEntry, 0x200> SyscallTable;
  auto SyscallTableEnd = SyscallTable.begin();

  // Windows/Wine orders syscalls in memory by their ID, take advantage of that to find the syscall indices for those
  // which we need to manually issue. Note that all functions starting with Nt besides NtGetTickCount are syscalls.
  for (uint32_t Idx = 0; Idx < Exports->NumberOfNames; Idx++) {
    const char* Name = reinterpret_cast<const char*>(NtDllBase + NameTable[Idx]);
    if (Name[0] == 'N' && Name[1] == 't' && strcmp(Name, "NtGetTickCount") != 0) {
      *SyscallTableEnd++ = {Name, FunctionTable[OrdinalTable[Idx]]};
    }
  }

  // Sort such that index 0 is now syscall 0, etc
  std::sort(SyscallTable.begin(), SyscallTableEnd);

  for (auto it = SyscallTable.begin(); it != SyscallTableEnd; it++) {
    uint32_t CurSyscallId = static_cast<uint32_t>(std::distance(SyscallTable.begin(), it));
    if (strcmp(it->Name, "NtContinue") == 0) {
      WineNtContinueSyscallId = CurSyscallId;
    } else if (strcmp(it->Name, "NtAllocateVirtualMemory") == 0) {
      WineNtAllocateVirtualMemorySyscallId = CurSyscallId;
    } else if (strcmp(it->Name, "NtProtectVirtualMemory") == 0) {
      WineNtProtectVirtualMemorySyscallId = CurSyscallId;
    }
  }
}

// Syscall thunks may have been patched before FEX has loaded, the default call checker installed by ntdll into FEX will
// try to invoke the JIT when calling such patched syscalls but this obviously doesn't work before FEX is initalised.
// This function parses ntdll and sets up a custom call checker to prevent this, as such it must avoid using any syscall
// thunks itself.
void InitSyscalls() {
  // The ntdll exports called by GetModuleHandle/GetProcAddress aren't known to be patched before JIT init by any current
  // software so are safe to call, but if that changes the loader structures in the PEB could be parsed manually.
  const auto NtDll = GetModuleHandle("ntdll.dll");
  NtDllBase = reinterpret_cast<uintptr_t>(NtDll);

  const auto WineSyscallDispatcherPtr = reinterpret_cast<void**>(GetProcAddress(NtDll, "__wine_syscall_dispatcher"));
  if (WineSyscallDispatcherPtr) {
    WineSyscallDispatcher = *WineSyscallDispatcherPtr;
    ParseWineSyscallNumbers(NtDll);
  }

  FillNtDllLUTs(NtDll);
  PatchCallChecker();
}

void HandleImageMap(uint64_t Address, bool MainImage = false) {
  fextl::string ModulePath = FEX::Windows::GetSectionFilePath(Address);
  fextl::string ModuleName = fextl::string {FEX::Windows::BaseName(ModulePath)};
  InvalidationTracker->HandleImageMap(ModuleName, Address);
  ImageTracker->HandleImageMap(ModulePath, Address, MainImage);
}

/* iOS-Madeira ml190: REPLAY IMAGE MAPS THAT ARRIVE BEFORE THE TRACKERS EXIST.
 *
 * NotifyMapViewOfSection returns early when InvalidationTracker/ImageTracker are not yet
 * constructed (they are created in ProcessInit), and that notification was previously lost
 * forever. Any image mapped in that window never gets its executable sections inserted
 * into InvalidationTracker::XIntervals, so every later decode inside it reports NOEXEC ->
 * NoExecOp -> FAULT_SIGSEGV -> the GuestSignal_SIGSEGV trampoline -> dead thread.
 *
 * Evidence this is the remaining hole (ml190, self-targeting probe): libcef IS notified at
 * map time, and NOTHING ever removes its interval — 0 unexec and 0 unmap touching its
 * range — yet the decoder still reports NOEXEC at libcef+0x1900733 / +0x3b508f0. So the
 * INSERT is what failed. Queue them and replay once the trackers are up. */
constexpr size_t MaxPendingImageMaps = 64;
uint64_t PendingImageMaps[MaxPendingImageMaps];
size_t PendingImageMapCount = 0;

void QueuePendingImageMap(uint64_t Address) {
  for (size_t i = 0; i < PendingImageMapCount; i++) {
    if (PendingImageMaps[i] == Address) {
      return;
    }
  }
  if (PendingImageMapCount < MaxPendingImageMaps) {
    PendingImageMaps[PendingImageMapCount++] = Address;
  }
}

void HandleImageUnmap(uint64_t Address, uint64_t Size) {
  ImageTracker->HandleImageUnmap(Address, Size);
}
} // namespace

namespace Exception {
static std::optional<FEX::Windows::TSOHandlerConfig> HandlerConfig;
static uintptr_t KiUserExceptionDispatcher;

struct alignas(16) KiUserExceptionDispatcherStackLayout {
  ARM64_NT_CONTEXT Context;
  uint64_t Pad[4]; // Only present on newer Windows versions, likely for SVE.
  EXCEPTION_RECORD Rec;
  uint64_t Align;
  uint64_t Redzone[2];
};

static bool HandleUnalignedAccess(const ThreadCPUArea CPUArea, ARM64_NT_CONTEXT& Context, bool IsJIT) {
  auto Thread = CPUArea.ThreadState();
  FEXCORE_PROFILE_INSTANT_INCREMENT(Thread, AccumulatedSIGBUSCount, 1);
  const auto Result =
    FEXCore::ArchHelpers::Arm64::HandleUnalignedAccess(Thread, HandlerConfig->GetUnalignedHandlerType(), Context.Pc, &Context.X0, IsJIT);
  Context.Pc += Result.value_or(0);
  return Result.has_value();
}

static void LoadStateFromECContext(FEXCore::Core::InternalThreadState* Thread, CONTEXT& Context) {
  auto& State = Thread->CurrentFrame->State;

  if ((Context.ContextFlags & CONTEXT_INTEGER) == CONTEXT_INTEGER) {
    // General register state
    State.gregs[FEXCore::X86State::REG_RAX] = Context.Rax;
    State.gregs[FEXCore::X86State::REG_RCX] = Context.Rcx;
    State.gregs[FEXCore::X86State::REG_RDX] = Context.Rdx;
    State.gregs[FEXCore::X86State::REG_RBX] = Context.Rbx;

    State.gregs[FEXCore::X86State::REG_RSI] = Context.Rsi;
    State.gregs[FEXCore::X86State::REG_RDI] = Context.Rdi;
    State.gregs[FEXCore::X86State::REG_R8] = Context.R8;
    State.gregs[FEXCore::X86State::REG_R9] = Context.R9;
    State.gregs[FEXCore::X86State::REG_R10] = Context.R10;
    State.gregs[FEXCore::X86State::REG_R11] = Context.R11;
    State.gregs[FEXCore::X86State::REG_R12] = Context.R12;
    State.gregs[FEXCore::X86State::REG_R13] = Context.R13;
    State.gregs[FEXCore::X86State::REG_R14] = Context.R14;
    State.gregs[FEXCore::X86State::REG_R15] = Context.R15;
  }

  if ((Context.ContextFlags & CONTEXT_CONTROL) == CONTEXT_CONTROL) {
    State.rip = Context.Rip;
    State.gregs[FEXCore::X86State::REG_RSP] = Context.Rsp;
    State.gregs[FEXCore::X86State::REG_RBP] = Context.Rbp;
    CTX->SetFlagsFromCompactedEFLAGS(Thread, Context.EFlags);
  }

  if ((Context.ContextFlags & CONTEXT_SEGMENTS) == CONTEXT_SEGMENTS) {
    State.es_idx = Context.SegEs & 0xffff;
    State.cs_idx = Context.SegCs & 0xffff;
    State.ss_idx = Context.SegSs & 0xffff;
    State.ds_idx = Context.SegDs & 0xffff;
    State.fs_idx = Context.SegFs & 0xffff;
    State.gs_idx = Context.SegGs & 0xffff;

    // The TEB is the only populated GDT entry by default
    //
    // iOS-Madeira 2026-07-02: use IOSLoadTEB() (TPIDRRO_EL0 + TSD slot 275)
    // instead of NtCurrentTeb() (raw x18 read). This function runs late in
    // ThreadInit and on every EC->x86 context restore; on threads whose x18
    // has been clobbered by Apple runtime calls, NtCurrentTeb() returns 0
    // and gs_cached gets zeroed — overwriting the correct value ThreadInit
    // set earlier. Confirmed on iOS 27 beta: 2 of 8 Thumper worker threads
    // ended ThreadInit with gs_cached=0 via this path, causing gs:[N] fault
    // loops when MSVC TLS guard code ran on those threads.
#ifdef FEX_IOS_HOST
    const auto TEB = reinterpret_cast<uint64_t>(IOSLoadTEB());
#else
    const auto TEB = reinterpret_cast<uint64_t>(NtCurrentTeb());
#endif
    auto GDT = State.GetSegmentFromIndex(State, (Context.SegGs & 0xffff));
    State.SetGDTBase(GDT, TEB);
    State.SetGDTLimit(GDT, 0xF'FFFFU);
    State.gs_cached = TEB;
    State.fs_cached = 0;
    State.es_cached = 0;
    State.cs_cached = 0;
    State.ss_cached = 0;
    State.ds_cached = 0;
  }

  if ((Context.ContextFlags & CONTEXT_FLOATING_POINT) == CONTEXT_FLOATING_POINT) {
    // Floating-point register state
    if ((Context.ContextFlags & CONTEXT_XSTATE) == CONTEXT_XSTATE) {
      const auto* Ymm = RtlLocateExtendedFeature(reinterpret_cast<CONTEXT_EX*>(&Context + 1), XSTATE_AVX, nullptr);
      CTX->SetXMMRegistersFromState(Thread, reinterpret_cast<const __uint128_t*>(Context.FltSave.XmmRegisters),
                                    reinterpret_cast<const __uint128_t*>(Ymm));
    } else {
      CTX->SetXMMRegistersFromState(Thread, reinterpret_cast<const __uint128_t*>(Context.FltSave.XmmRegisters), nullptr);
    }
    memcpy(State.mm, Context.FltSave.FloatRegisters, sizeof(State.mm));

    State.FCW = Context.FltSave.ControlWord;
    State.flags[FEXCore::X86State::X87FLAG_IE_LOC] = Context.FltSave.StatusWord & 1;
    State.flags[FEXCore::X86State::X87FLAG_C0_LOC] = (Context.FltSave.StatusWord >> 8) & 1;
    State.flags[FEXCore::X86State::X87FLAG_C1_LOC] = (Context.FltSave.StatusWord >> 9) & 1;
    State.flags[FEXCore::X86State::X87FLAG_C2_LOC] = (Context.FltSave.StatusWord >> 10) & 1;
    State.flags[FEXCore::X86State::X87FLAG_C3_LOC] = (Context.FltSave.StatusWord >> 14) & 1;
    State.flags[FEXCore::X86State::X87FLAG_TOP_LOC] = (Context.FltSave.StatusWord >> 11) & 0b111;
    State.AbridgedFTW = Context.FltSave.TagWord;
  }
}

static void ReconstructThreadState(FEXCore::Core::InternalThreadState* Thread, ARM64_NT_CONTEXT& Context) {
  const auto& Config = SignalDelegator->GetConfig();
  auto& State = Thread->CurrentFrame->State;

  State.rip = CTX->RestoreRIPFromHostPC(Thread, Context.Pc);

  // Spill all SRA GPRs
  for (size_t i = 0; i < Config.SRAGPRCount; i++) {
    State.gregs[i] = Context.X[Config.SRAGPRMapping[i]];
  }

  // Spill all SRA FPRs
  for (size_t i = 0; i < Config.SRAFPRCount; i++) {
    memcpy(State.xmm.sse.data[i], &Context.V[Config.SRAFPRMapping[i]], sizeof(__uint128_t));
  }

  // Spill EFlags
  uint32_t EFlags = CTX->ReconstructCompactedEFLAGS(Thread, true, Context.X, Context.Cpsr);
  CTX->SetFlagsFromCompactedEFLAGS(Thread, EFlags);
}

// Reconstructs an x64 context from the input thread's state, packed into a regular ARM64 context following the ARM64EC register mapping
static ARM64_NT_CONTEXT StoreStateToPackedECContext(FEXCore::Core::InternalThreadState* Thread, uint32_t FPCR, uint32_t FPSR) {
  ARM64_NT_CONTEXT ECContext {};

  ECContext.ContextFlags = CONTEXT_ARM64_FULL;
  if (CPUFeatures->IsFeaturePresent(PF_AVX2_INSTRUCTIONS_AVAILABLE)) {
    // This is a FEX extension and requires corresponding wine-side patches to be of use, however it is harmless to set
    // even if those patches are not used.
    ECContext.ContextFlags |= CONTEXT_ARM64_FEX_YMMSTATE;
  }

  auto& State = Thread->CurrentFrame->State;

  ECContext.X8 = State.gregs[FEXCore::X86State::REG_RAX];
  ECContext.X0 = State.gregs[FEXCore::X86State::REG_RCX];
  ECContext.X1 = State.gregs[FEXCore::X86State::REG_RDX];
  ECContext.X27 = State.gregs[FEXCore::X86State::REG_RBX];
  ECContext.Sp = State.gregs[FEXCore::X86State::REG_RSP];
  ECContext.Fp = State.gregs[FEXCore::X86State::REG_RBP];
  ECContext.X25 = State.gregs[FEXCore::X86State::REG_RSI];
  ECContext.X26 = State.gregs[FEXCore::X86State::REG_RDI];
  ECContext.X2 = State.gregs[FEXCore::X86State::REG_R8];
  ECContext.X3 = State.gregs[FEXCore::X86State::REG_R9];
  ECContext.X4 = State.gregs[FEXCore::X86State::REG_R10];
  ECContext.X5 = State.gregs[FEXCore::X86State::REG_R11];
  ECContext.X19 = State.gregs[FEXCore::X86State::REG_R12];
  ECContext.X20 = State.gregs[FEXCore::X86State::REG_R13];
  ECContext.X21 = State.gregs[FEXCore::X86State::REG_R14];
  ECContext.X22 = State.gregs[FEXCore::X86State::REG_R15];

  ECContext.Pc = State.rip;

  CTX->ReconstructXMMRegisters(Thread, reinterpret_cast<__uint128_t*>(&ECContext.V[0]), reinterpret_cast<__uint128_t*>(&ECContext.V[16]));

  ECContext.Lr = State.mm[0][0];
  ECContext.X6 = State.mm[1][0];
  ECContext.X7 = State.mm[2][0];
  ECContext.X9 = State.mm[3][0];
  ECContext.X16 = (State.mm[3][1] & 0xffff) << 48 | (State.mm[2][1] & 0xffff) << 32 | (State.mm[1][1] & 0xffff) << 16 | (State.mm[0][1] & 0xffff);
  ECContext.X10 = State.mm[4][0];
  ECContext.X11 = State.mm[5][0];
  ECContext.X12 = State.mm[6][0];
  ECContext.X15 = State.mm[7][0];
  ECContext.X17 = (State.mm[7][1] & 0xffff) << 48 | (State.mm[6][1] & 0xffff) << 32 | (State.mm[5][1] & 0xffff) << 16 | (State.mm[4][1] & 0xffff);

  // Zero all disallowed registers
  ECContext.X13 = 0;
  ECContext.X14 = 0;
  ECContext.X18 = 0;
  ECContext.X23 = 0;
  ECContext.X24 = 0;
  ECContext.X28 = 0;

  // NZCV+SS will be converted into EFlags by ntdll, the rest are lost during exception handling.
  // See HandleGuestException
  uint32_t EFlags = CTX->ReconstructCompactedEFLAGS(Thread, false, nullptr, 0);
  ECContext.Cpsr = 0;
  ECContext.Cpsr |= (EFlags & (1U << FEXCore::X86State::RFLAG_TF_RAW_LOC)) ? (1U << 21) : 0;
  ECContext.Cpsr |= (EFlags & (1U << FEXCore::X86State::RFLAG_OF_RAW_LOC)) ? (1U << 28) : 0;
  ECContext.Cpsr |= (EFlags & (1U << FEXCore::X86State::RFLAG_CF_RAW_LOC)) ? (1U << 29) : 0;
  ECContext.Cpsr |= (EFlags & (1U << FEXCore::X86State::RFLAG_ZF_RAW_LOC)) ? (1U << 30) : 0;
  ECContext.Cpsr |= (EFlags & (1U << FEXCore::X86State::RFLAG_SF_RAW_LOC)) ? (1U << 31) : 0;

  ECContext.Fpcr = FPCR;
  ECContext.Fpsr = FPSR;

  return ECContext;
}

static void RethrowGuestException(const EXCEPTION_RECORD& Rec, ARM64_NT_CONTEXT& Context) {
  const auto& Config = SignalDelegator->GetConfig();
  auto* Thread = GetCPUArea().ThreadState();
  auto& Fault = Thread->CurrentFrame->SynchronousFaultData;
  uint64_t GuestSp = Context.X[Config.SRAGPRMapping[static_cast<size_t>(FEXCore::X86State::REG_RSP)]];
  auto* Args = reinterpret_cast<KiUserExceptionDispatcherStackLayout*>(FEXCore::AlignDown(GuestSp, 64)) - 1;

  LogMan::Msg::DFmt("Reconstructing context");
  if (!IsDispatcherAddress(Context.Pc)) {
    ReconstructThreadState(Thread, Context);
  }
  Args->Context = StoreStateToPackedECContext(Thread, Context.Fpcr, Context.Fpsr);
  LogMan::Msg::DFmt("pc: {:X} rip: {:X}", Context.Pc, Args->Context.Pc);

  // ml341: same gap as #52 but on the exception path — the reconstructed rip can be a
  // module POOL-COPY alias (block metadata predating the CompileBlock redirect, or a
  // branch target captured mid-lookup). Handing a pool-band rip to KiUserExceptionDispatcher
  // makes the fault unresolvable for guest SEH (Steam's handlers see an address outside
  // every module) and the process dies on an otherwise-survivable fault. Reverse-translate
  // via the alias table (the only valid discriminator — never a band test).
  {
    const uint64_t PeRip = IosJitReverseTranslate(Args->Context.Pc);
    if (PeRip != Args->Context.Pc) {
      LogMan::Msg::EFmt("[exc-pool-rip] rev=ml341 reconstructed guest rip {:#x} is a POOL-COPY alias of PE {:#x} "
                        "-- rewriting so guest SEH can resolve the faulting module",
                        Args->Context.Pc, PeRip);
      Args->Context.Pc = PeRip;
    }
  }

  // X64 Windows always clears TF, DF and AF when handling an exception, restoring after.
  // Current ARM64EC windows can only restore NZCV+SS when returning from an exception and other flags are left untouched from the handler context.
  // TODO: Can extend wine to support this by mapping the remaining EFlags into reserved cpsr members.
  uint32_t EFlags = CTX->ReconstructCompactedEFLAGS(Thread, false, nullptr, 0);
  EFlags &= ~(1 << FEXCore::X86State::RFLAG_TF_RAW_LOC);
  CTX->SetFlagsFromCompactedEFLAGS(Thread, EFlags);

  Args->Rec = FEX::Windows::HandleGuestException(Fault, Rec, Args->Context.Pc, Args->Context.X8, Args->Context.X0);
  if (Args->Rec.ExceptionCode == EXCEPTION_SINGLE_STEP) {
    Args->Context.Cpsr &= ~(1 << 21); // PSTATE.SS
  } else if (Args->Rec.ExceptionCode == EXCEPTION_BREAKPOINT) {
    // INT3 will set RIP to the instruction following it, undo this (any edge cases with multibyte instructions that trigger breakpoints are bugs present in Windows also)
    Args->Context.Pc -= 1;
  }

  Context.Sp = reinterpret_cast<uint64_t>(Args);
  Context.Pc = KiUserExceptionDispatcher;
}

class ECSyscallHandler : public FEXCore::HLE::SyscallHandler, public FEXCore::Allocator::FEXAllocOperators {
public:
  ECSyscallHandler() {
    OSABI = FEXCore::HLE::SyscallOSABI::OS_GENERIC;
  }

  uint64_t HandleSyscall(FEXCore::Core::CpuStateFrame* Frame, FEXCore::HLE::SyscallArguments* Args) override {
    ProcessPendingCrossProcessEmulatorWork();

    // Manually raise an exeption with the current JIT state packed into a native context, ntdll handles this and
    // reenters the JIT (see dlls/ntdll/signal_arm64ec.c in wine).
    uint64_t FPCR, FPSR;
    __asm volatile("mrs %[fpcr], fpcr" : [fpcr] "=r"(FPCR));
    __asm volatile("mrs %[fpsr], fpsr" : [fpsr] "=r"(FPSR));

    auto* Thread = GetCPUArea().ThreadState();
    KiUserExceptionDispatcherStackLayout DispatchArgs {
      .Context = StoreStateToPackedECContext(Thread, static_cast<uint32_t>(FPCR), static_cast<uint32_t>(FPSR)),
      .Rec = {.ExceptionCode = STATUS_EMULATION_SYSCALL}};
    // PC is expected to hold the return address after the thunk, so skip over the INT 2E/SYSCALL instruction.
    DispatchArgs.Context.Pc += 2;
    JumpSetStack(KiUserExceptionDispatcher, reinterpret_cast<uintptr_t>(&DispatchArgs));
  }

  std::optional<FEXCore::ExecutableFileSectionInfo> LookupExecutableFileSection(FEXCore::Core::InternalThreadState*, uint64_t Address) override {
    auto Result = ImageTracker->LookupExecutableFileSection(Address);
#ifdef FEX_IOS_HOST
    if (!Result.has_value()) {
      /* iOS JIT-alias-aware: same pattern as QueryGuestExecutableRange. */
      uint64_t OrigAddr = IosJitReverseTranslate(Address);
      if (OrigAddr != Address) {
        auto Inner = ImageTracker->LookupExecutableFileSection(OrigAddr);
        if (Inner.has_value()) {
          FEXCore::ExecutableFileSectionInfo Aliased = *Inner;
          Aliased.FileStartVA = IosJitTranslate(Inner->FileStartVA);
          Aliased.BeginVA = IosJitTranslate(Inner->BeginVA);
          Aliased.EndVA = IosJitTranslate(Inner->EndVA - 1) + 1;
          return Aliased;
        }
      }
    }
#endif
    return Result;
  }

  void MarkGuestExecutableRange(FEXCore::Core::InternalThreadState* Thread, uint64_t Start, uint64_t Length) override {
    InvalidationTracker->ReprotectRWXIntervals(Start, Length);
  }

  void InvalidateGuestCodeRange(FEXCore::Core::InternalThreadState* Thread, uint64_t Start, uint64_t Length) override {
    InvalidationTracker->InvalidateAlignedInterval(Start, Length, false);
  }

  void MarkOvercommitRange(uint64_t Start, uint64_t Length) override {
    OvercommitTracker->MarkRange(Start, Length);
  }

  void UnmarkOvercommitRange(uint64_t Start, uint64_t Length) override {
    OvercommitTracker->UnmarkRange(Start, Length);
  }

  FEXCore::HLE::ExecutableRangeInfo QueryGuestExecutableRange(FEXCore::Core::InternalThreadState* Thread, uint64_t Address) override {
    auto Result = InvalidationTracker->QueryExecutableRange(Address);
#ifdef FEX_IOS_HOST
    if (Result.Size == 0) {
      /* iOS JIT-alias-aware: reverse-translate alias → PE-original, query
       * tracker with that, then forward-translate the result base back. */
      uint64_t OrigAddr = IosJitReverseTranslate(Address);
      if (OrigAddr != Address) {
        auto Inner = InvalidationTracker->QueryExecutableRange(OrigAddr);
        if (Inner.Size != 0) {
          return {IosJitTranslate(Inner.Base), Inner.Size, Inner.Writable};
        }
      }
    }
    if (Result.Size == 0) {
      static uint32_t QueryFailCount = 0;
      if (QueryFailCount < 12) {
        QueryFailCount++;
        LogMan::Msg::EFmt("[iOS-xquery] MISS tracker={} addr={:#x} rev={:#x}",
                          static_cast<void*>(&*InvalidationTracker), Address, IosJitReverseTranslate(Address));
      }
    }
#endif
    return Result;
  }

  void PreCompile() override {
    ProcessPendingCrossProcessEmulatorWork();
  }
};
} // namespace Exception

extern "C" void SyncThreadContext(CONTEXT* Context) {
  ProcessPendingCrossProcessEmulatorWork();
  auto* Thread = GetCPUArea().ThreadState();
  // All other EFlags bits are lost when converting to/from an ARM64EC context, so merge them in from the current JIT state.
  // This is advisable over dropping their values as thread suspend/resume uses this function, and that can happen at any point in guest code.
  static constexpr uint32_t ECValidEFlagsMask {(1U << FEXCore::X86State::RFLAG_OF_RAW_LOC) | (1U << FEXCore::X86State::RFLAG_CF_RAW_LOC) |
                                               (1U << FEXCore::X86State::RFLAG_ZF_RAW_LOC) | (1U << FEXCore::X86State::RFLAG_SF_RAW_LOC) |
                                               (1U << FEXCore::X86State::RFLAG_TF_RAW_LOC)};

  uint32_t StateEFlags = CTX->ReconstructCompactedEFLAGS(Thread, false, nullptr, 0);
  Context->EFlags = (Context->EFlags & ECValidEFlagsMask) | (StateEFlags & ~ECValidEFlagsMask);
  Exception::LoadStateFromECContext(Thread, *Context);
}

#ifdef FEX_IOS_HOST
/* iOS-Madeira 2026-05-19: define FEXCore::DualMap::WriteOffset for THIS PE.
 * xtajit64.dll has its own statically-linked copy of FEXCore separate from
 * the iOS Madeira app's libFEXCore_Base.a — so we need our own storage for
 * the variable. Set early in ProcessInit (before InitCore + dispatcher emit).
 * Convention is +0x10000000 (RX→RW alias separation), matching the iOS JIT
 * pool layout established in virtual_ios.c. */
namespace FEXCore::DualMap {
int64_t WriteOffset = 0;
} // namespace FEXCore::DualMap
#endif

NTSTATUS ProcessInit() {
  /* iOS-Madeira: DualMap::WriteOffset (RX→RW alias distance) is set below,
   * after InitCRTProcess() populates the environment, and BEFORE InitCore().
   * It is read from MADEIRA_JIT_WRITE_OFFSET rather than hardcoded, because
   * the app creates the RW alias with VM_FLAGS_ANYWHERE — the alias is NOT
   * guaranteed to land at RX+0x10000000 (observed +0x105a4000 on iOS 27).
   * The old hardcode corrupted the JIT pool on runs where the offset
   * differed. See FEXBridge.mm (setenv) + env_ios.c (forwarding). */

#ifdef FEX_IOS_HOST
  /* Import the raw TSD slot offset for the TEB before anything reads a TEB or
   * emits code. It is published by wine's ntdll as a data export because the
   * slot is not knowable at build time: it is whichever slot backs the pthread
   * key ntdll-unix creates, which differs per device and per load order.
   *
   * We used to assemble slot 275 (0x898) into every one of these reads. That
   * is a dynamic pthread key nobody guaranteed us, and when its real owner
   * showed up -- Metal, on an M4 iPad, at the first nextDrawable -- it reset
   * the slot and every TEB read in the process started returning zero.
   *
   * A missing or zero export is fatal, not a reason to fall back: the old
   * constant is exactly the value that is wrong. */
  {
    const auto NtDllForTsd = GetModuleHandle("ntdll.dll");
    const auto Published = reinterpret_cast<uint32_t*>(GetProcAddress(NtDllForTsd, "ios_teb_tsd_offset"));
    if (Published && *Published) {
      IosTebTsdOffset = *Published;
    }
    /* Report via LogMan next to [build-id], not here: at this point
     * ProcessParameters->hStdError is not usable yet, so the ml707 build's
     * WriteFile report never reached the log at all. */
    IosTebTsdImportFound = Published != nullptr ? 1u : 0u;
    if (!IosTebTsdOffset) {
      return STATUS_UNSUCCESSFUL;
    }
  }
#endif

  InitSyscalls();

  FEX::Windows::InitCRTProcess();
  const auto ExecutableName = FEX::Windows::BaseName(FEX::Windows::GetExecutableFilePath());
  FEX::Config::LoadConfig(fextl::string {ExecutableName}, _environ, FEX::ReadPortabilityInformation());
  FEXCore::Config::ReloadMetaLayer();
  FEX::Windows::Logging::Init();
#ifdef FEX_IOS_HOST
  /* iOS-Madeira ml278: announce the atomic-alias geometry UNCONDITIONALLY, AFTER
   * Logging::Init().
   *
   * The first cut put this line inside IosAtomicWritableAlias (Arm64.cpp), on its first
   * call -- so it could only ever appear if the situation it exists to report had already
   * occurred. ml277 then logged nothing at all, and "the fix works" was indistinguishable
   * from "the helper was never called" and from "the env vars never arrived". A liveness
   * marker that depends on the event it measures is useless; print it at init. */
  {
    const char* RxEnv = getenv("WINE_IOS_JIT_RX");
    const char* SzEnv = getenv("WINE_IOS_JIT_SIZE");
    const char* RwEnv = getenv("WINE_IOS_JIT_RW");
    LogMan::Msg::EFmt("[atomic-alias] LIVE: WINE_IOS_JIT_RX={} SIZE={} RW={} -- atomics whose "
                      "target lands in the pool's RX alias get redirected to RX+WriteOffset",
                      RxEnv ? RxEnv : "<unset>", SzEnv ? SzEnv : "<unset>", RwEnv ? RwEnv : "<unset>");
  }

  /* iOS-Madeira ml293: UNCONDITIONAL BUILD IDENTITY.
   *
   * ml292 could only be attributed to a build by comparing the log's wall-clock start
   * against the install time, because every other marker in the binary is printed from
   * inside the very code path under test -- so "marker absent" meant either "old build"
   * or "new build, event did not fire", with no way to tell them apart. That is the same
   * defect as the [atomic-alias] note above, one level up.
   *
   * __DATE__/__TIME__ are baked at compile time and this line is printed before any guest
   * code runs. Grep it first in every pull.
   *
   * CAVEAT found immediately (ml294): __DATE__/__TIME__ stamp THIS translation unit's
   * compile time, so changing only another .cpp leaves the stamp stale and the ambiguity
   * half-returns. The MADEIRA_REV tag below fixes that: bump it for every deploy, which
   * necessarily edits this file and so refreshes the timestamp too. Self-enforcing. */
/* ml706: this tag went stale -- an ml705 binary still reported ml466, which is
 * exactly the "self-enforcing marker" failure it exists to prevent. The
 * __DATE__/__TIME__ below is compiler-generated and therefore the
 * authoritative identity; if the two disagree, the tag is wrong, not the
 * build. */
#define MADEIRA_REV "ml755"
  LogMan::Msg::EFmt("[build-id] xtajit64 rev=" MADEIRA_REV " compiled " __DATE__ " " __TIME__);
#ifdef FEX_IOS_HOST
  /* ml751: flush the VA band selector's beacons.
   *
   * ios_fex_band_select() runs during rpmalloc init, before the ARM64EC TEB
   * exists, so it cannot call a logging API -- ml750 tried OutputDebugStringA
   * there and crashed every launch with x18=0x0. It appends to a plain byte
   * buffer instead; this is the first point where LogMan is known to work, as
   * the build-id line above demonstrates. Without this the selector that
   * decides where FEX's arena lives reports nothing at all. */
  {
    if (ios_va_log_len > 0) {
      ios_va_log[ios_va_log_len] = 0;
      LogMan::Msg::EFmt("[va-profile] ml751 deferred selector log ({} bytes):\n{}",
                        ios_va_log_len, ios_va_log);
    } else {
      LogMan::Msg::EFmt("[va-profile] ml751 selector emitted NOTHING -- it did not run");
    }
  }
#endif
#ifdef FEX_IOS_HOST
  {
    const uint32_t Off = IosTebTsdOffset;
    const bool Found = IosTebTsdImportFound != 0;
    LogMan::Msg::EFmt("[fex-tsd] imported offset={:#x} (ntdll export {})", Off,
                      Found ? "found" : "MISSING");
  }
#endif
#endif

  FEXCore::Config::Set(FEXCore::Config::CONFIG_IS64BIT_MODE, "1");

  FEXCore::Profiler::Init("", "");

  SignalDelegator = fextl::make_unique<FEX::DummyHandlers::DummySignalDelegator>();
  SyscallHandler = fextl::make_unique<Exception::ECSyscallHandler>();

  const auto NtDll = GetModuleHandle("ntdll.dll");
  const bool IsWine = !!GetProcAddress(NtDll, "wine_get_version");
  OvercommitTracker.emplace(IsWine);

  FEX::Windows::SetupEnvironmentVariableValues(NtDll);

  FEX::Windows::Allocator::SetupHooks(NtDll);
  FEX::Windows::UnixLib::Init(NtDll);

  {
    auto HostFeatures = FEX::Windows::CPUFeatures::FetchHostFeatures(IsWine, FEXCore::HostFeatures::HostTypeEnum::Arm64ec);
    CTX = FEXCore::Context::Context::CreateNewContext(HostFeatures);
  }

  CTX->SetSignalDelegator(SignalDelegator.get());
  CTX->SetSyscallHandler(SyscallHandler.get());

#ifdef FEX_IOS_HOST
  /* Set DualMap::WriteOffset BEFORE InitCore (the dispatcher's emit path
   * reads it via the JIT class constructor). Compute it from the SAME
   * env vars the app already publishes for the unix side's JIT pool —
   * WINE_IOS_JIT_RW / WINE_IOS_JIT_RX (set in ContentView.swift before
   * Wine launches, forwarded through get_initial_environment because they
   * are WINE-prefixed and non-special). offset = RW_base - RX_base.
   *
   * This replaces the earlier MADEIRA_JIT_WRITE_OFFSET attempt, which read
   * an uninitialized FEXBridge pool (the guest's real pool is owned by
   * StikJITHelper, not FEXBridge) and always came back null. Fail LOUD if
   * the vars are missing — a wrong/zero offset corrupts the JIT pool. */
  {
    const char *rw_env = getenv("WINE_IOS_JIT_RW");
    const char *rx_env = getenv("WINE_IOS_JIT_RX");
    uint64_t rw = rw_env ? strtoull(rw_env, nullptr, 16) : 0;
    uint64_t rx = rx_env ? strtoull(rx_env, nullptr, 16) : 0;
    int64_t off = (rw && rx) ? (int64_t)(rw - rx) : 0;
    HANDLE stderr_h = NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters
        ? reinterpret_cast<HANDLE>(reinterpret_cast<RTL_USER_PROCESS_PARAMETERS64*>(
              NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters)->hStdError)
        : nullptr;
    char buf[160];
    if (off != 0) {
      /* iOS-Madeira 2026-07-06: FAST-WRITE re-enabled per the 2026-07-03
       * TODO — the flush is now NtFlushInstructionCache (kernel IPI) in
       * JIT.cpp instead of inline dc/ic asm, which was the suspected root
       * cause of the msvcp140-DllMain/steam_api64 fast-write crashes AND
       * the proven cause of the Thumper-desktop icache-staleness ILLs
       * (every crash pc 64-byte aligned; trap-mode's 1000x slower copies
       * just widened the same window). Fast-write removes ~300K mach
       * exceptions per compile storm. If the old fast-write crash sites
       * return (msvcp140 EH pre-splash, steam_api64 init), revert THIS
       * assignment to 0 but KEEP the NtFlushInstructionCache flush. */
      FEXCore::DualMap::WriteOffset = off;
      int n = snprintf(buf, sizeof(buf),
          "[FEX-iOS] fast-write ENABLED (WriteOffset=0x%llx RW=0x%llx RX=0x%llx)\n",
          (unsigned long long)off, (unsigned long long)rw, (unsigned long long)rx);
      if (stderr_h) { ULONG w = 0; WriteFile(stderr_h, buf, n, &w, nullptr); }
    } else {
      int n = snprintf(buf, sizeof(buf),
          "[FEX-iOS] FATAL: WINE_IOS_JIT_RW/RX missing (RW=%s RX=%s) — JIT pool writes will corrupt!\n",
          rw_env ? rw_env : "(null)", rx_env ? rx_env : "(null)");
      if (stderr_h) { ULONG w = 0; WriteFile(stderr_h, buf, n, &w, nullptr); }
    }
  }
#endif

  CTX->InitCore();
  Exception::HandlerConfig.emplace(*CTX);
  InvalidationTracker.emplace(*CTX, Threads);
  ImageTracker.emplace(*CTX, false);

  auto MainModule = reinterpret_cast<__TEB*>(NtCurrentTeb())->Peb->ImageBaseAddress;
  HandleImageMap(reinterpret_cast<uint64_t>(MainModule), true);

  HandleImageMap(NtDllBase);

  /* ml190: replay any image maps that arrived before the trackers existed. */
  for (size_t i = 0; i < PendingImageMapCount; i++) {
    HandleImageMap(PendingImageMaps[i]);
  }
  PendingImageMapCount = 0;

  CPUFeatures.emplace(*CTX);

  X64ReturnInstr = ::VirtualAlloc(nullptr, FEXCore::Utils::FEX_PAGE_SIZE, MEM_COMMIT | MEM_TOP_DOWN, PAGE_EXECUTE_READWRITE);
  InvalidationTracker->HandleMemoryProtectionNotification(reinterpret_cast<uint64_t>(X64ReturnInstr), FEXCore::Utils::FEX_PAGE_SIZE,
                                                          PAGE_EXECUTE_READ);
  *reinterpret_cast<uint8_t*>(X64ReturnInstr) = 0xc3;

  /* iOS-Madeira ml199: state this address explicitly.
   *
   * [iOS-noexec]/[iOS-bogusrip] show FEX being handed GuestRIP=0x7c200e0080 — page
   * 0x7c200e0000 plus 0x80 — and the same +0x0e0080 offset has appeared across three
   * different runs/arenas. This sentinel is a ONE-PAGE MEM_TOP_DOWN allocation holding a
   * single 0xC3 at offset 0, which Module.S:168 loads into lr before entering the
   * simulator, so guest returns out of simulation land on it. Top-down placement now puts
   * it in the 0x7c.. band, which is also where the iOS VA steering places its 512MB
   * reserve-only ranges — so log the address (and whether it is inside a steer slot) to
   * confirm the failing RIP really is X64ReturnInstr+0x80 rather than a coincidence, and
   * whether the sentinel is landing inside a steered reservation. */
  LogMan::Msg::EFmt("[iOS-sentinel] X64ReturnInstr={:#x} page={:#x} in_steer_band={}",
                    reinterpret_cast<uint64_t>(X64ReturnInstr),
                    reinterpret_cast<uint64_t>(X64ReturnInstr) & ~0xfffULL,
                    reinterpret_cast<uint64_t>(X64ReturnInstr) >= 0x7400000000ULL ? "YES" : "no");

  const uintptr_t KiUserExceptionDispatcherFFS = reinterpret_cast<uintptr_t>(GetProcAddress(NtDll, "KiUserExceptionDispatcher"));
  Exception::KiUserExceptionDispatcher = NtDllRedirectionLUT[KiUserExceptionDispatcherFFS - NtDllBase] + NtDllBase;

  FEX_CONFIG_OPT(ProfileStats, PROFILESTATS);
  FEX_CONFIG_OPT(StartupSleep, STARTUPSLEEP);
  FEX_CONFIG_OPT(StartupSleepProcName, STARTUPSLEEPPROCNAME);

  if (IsWine && ProfileStats()) {
    StatAllocHandler = fextl::make_unique<FEX::Windows::StatAlloc>(FEXCore::SHMStats::AppType::WIN_ARM64EC);
  }

  if (StartupSleep() && (StartupSleepProcName().empty() || ExecutableName == StartupSleepProcName())) {
    LogMan::Msg::IFmt("[{}][{}] Sleeping for {} seconds", GetCurrentProcessId(), ExecutableName, StartupSleep());
    std::this_thread::sleep_for(std::chrono::seconds(StartupSleep()));
  }

  return STATUS_SUCCESS;
}

void ProcessTerm(HANDLE Handle, BOOL After, NTSTATUS Status) {}

class ScopedCallbackDisable {
private:
  bool Prev;

public:
  ScopedCallbackDisable() {
    const auto CPUArea = GetCPUArea();
    Prev = CPUArea.Area->InSyscallCallback;
    CPUArea.Area->InSyscallCallback = true;
  }

  ~ScopedCallbackDisable() {
    GetCPUArea().Area->InSyscallCallback = Prev;
  }
};

// Returns true if exception dispatch should be halted and the execution context restored to NativeContext
bool ResetToConsistentStateImpl(const ThreadCPUArea CPUArea, EXCEPTION_RECORD* Exception, CONTEXT* GuestContext, ARM64_NT_CONTEXT* NativeContext) {
  auto Thread = CPUArea.ThreadState();
  FEXCORE_PROFILE_ACCUMULATION(Thread, AccumulatedSignalTime);
  LogMan::Msg::DFmt("Exception: Code: {:X} Address: {:X}", Exception->ExceptionCode, reinterpret_cast<uintptr_t>(Exception->ExceptionAddress));

  if (NativeContext->Pc == reinterpret_cast<uint64_t>(&ExitFunctionSuspendPoint)) {
    // A suspend interrupt can occur in ExitFunctionEC before InSimulation is unset and set SuspendDoorbell. If this
    // occurs then it is still our duty to cooperatively suspend with an appropriate context. To support this, after
    // unsetting InSimulation a brk #0xCAFE instruction will be raised that we can handle here.
    NativeContext->Pc = reinterpret_cast<uintptr_t>(&ExitFunctionSuspendResumePoint); // Jump to the suspend resume point.
    *CPUArea.Area->SuspendDoorbell = 0;
    return true;
  }

  if (Exception->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
    const auto FaultAddress = static_cast<uint64_t>(Exception->ExceptionInformation[1]);

    if (FEX::Windows::CallRetStack::HandleAccessViolation(Thread, FaultAddress, NativeContext->X17)) {
      return true;
    }

    if (FEX::Windows::JITGuardPage::HandleJITGuardPage(Thread, reinterpret_cast<void*>(FaultAddress), NativeContext->X,
                                                       reinterpret_cast<__uint128_t*>(NativeContext->V), &NativeContext->Pc)) {
      return true;
    }

    std::scoped_lock Lock(ThreadCreationMutex);
    if (InvalidationTracker && InvalidationTracker->HandleRWXAccessViolation(Thread, NativeContext->Pc, FaultAddress)) {
      FEXCORE_PROFILE_INSTANT_INCREMENT(Thread, AccumulatedSMCCount, 1);
      if (CTX->IsAddressInCodeBuffer(Thread, NativeContext->Pc) && !CTX->IsCurrentBlockSingleInst(CPUArea.ThreadState()) &&
          CTX->IsAddressInCurrentBlock(Thread, FaultAddress & FEXCore::Utils::FEX_PAGE_MASK, FEXCore::Utils::FEX_PAGE_SIZE)) {
        // If we are not patching ourself (single inst block case) and potentially patching the current block, this is inline SMC. Reconstruct the current context (before the SMC write) then single step the write to reduce it to regular SMC.
        Exception::ReconstructThreadState(Thread, *NativeContext);
        LogMan::Msg::DFmt("Handled inline self-modifying code: pc: {:X} rip: {:X} fault: {:X}", NativeContext->Pc,
                          Thread->CurrentFrame->State.rip, FaultAddress);
        NativeContext->Pc = CPUArea.DispatcherLoopTopEnterECFillSRA();
        NativeContext->Sp = CPUArea.EmulatorStackBase();
        NativeContext->X11 = 1;                                        // Set ENTRY_FILL_SRA_SINGLE_INST_REG to force a single step
        NativeContext->X17 = reinterpret_cast<uint64_t>(CPUArea.Area); // Set EC_ENTRY_CPUAREA_REG
      } else {
        LogMan::Msg::DFmt("Handled self-modifying code: pc: {:X} fault: {:X}", NativeContext->Pc, FaultAddress);
#ifdef FEX_IOS_HOST
        /* ml657: ON iOS THE SMC RETRY CAN NEVER SUCCEED, SO PERFORM THE ACCESS HERE.
         *
         * This path claims the fault and returns without advancing Pc, because on
         * Windows HandleRWXAccessViolation has just unprotected the page and the
         * re-executed store will land. On iOS the guest mapping stays RX BY DESIGN —
         * that is the whole reason the RW alias exists — so the retry re-faults at the
         * identical Pc forever.
         *
         * Book of the Dead died exactly here: 1,999 iterations of
         *   Detected mono backpatcher at: 71F7680F64
         *   Handled self-modifying code: pc: 154839E18 fault: 7045F901E6
         * until the 2,000-redelivery guard killed the process. Note the unaligned
         * handler below at the EXCEPTION_DATATYPE_MISALIGNMENT check is unreachable in
         * this state, because SMC claims the fault first.
         *
         * So run the atomic through the RW alias here and let Pc advance. That also
         * un-wedges the Mono optimisation: MarkMonoBackpatcherBlock has already marked
         * this block, but a marked block is only recompiled once execution LEAVES it,
         * and execution never left. Advancing past the store is what lets the
         * MonoBackpatcherWrite recompile actually happen.
         *
         * Safe by construction: HandleUnalignedAccess only claims encodings it
         * recognises. If it declines we fall through to the previous behaviour
         * unchanged. ⚠️ An ALIGNED store trapped by SMC would still loop — not observed,
         * and it would need a different fix rather than a wider net here. */
        const uint64_t SmcPc = NativeContext->Pc;
        if (Exception::HandleUnalignedAccess(CPUArea, *NativeContext, CTX->IsAddressInCodeBuffer(Thread, SmcPc))) {
          static unsigned SmcAtomicCount;
          if (SmcAtomicCount < 16) {
            LogMan::Msg::EFmt("[smc-atomic] ml657 #{} handled pc {:X} -> {:X} fault {:X}", ++SmcAtomicCount, SmcPc,
                              NativeContext->Pc, FaultAddress);
          }
        }
#endif
      }

      return true;
    }
  }

  bool IsJIT = CTX->IsAddressInCodeBuffer(Thread, NativeContext->Pc);
  if (Exception->ExceptionCode == EXCEPTION_DATATYPE_MISALIGNMENT && Exception::HandleUnalignedAccess(CPUArea, *NativeContext, IsJIT)) {
    LogMan::Msg::DFmt("Handled unaligned atomic: new pc: {:X}", NativeContext->Pc);
    return true;
  }

  if (!IsJIT && !IsDispatcherAddress(NativeContext->Pc)) {
    LogMan::Msg::DFmt("Passing through exception");
    return false;
  }

  // The JIT (in CompileBlock) emits code to check the suspend doorbell at the start of every block, and run the following instruction if it is set:
  static constexpr uint32_t SuspendTrapMagic {0xD4395FC0}; // brk #0xCAFE
  if (Exception->ExceptionCode == EXCEPTION_ILLEGAL_INSTRUCTION && *reinterpret_cast<uint32_t*>(NativeContext->Pc) == SuspendTrapMagic) {
    Exception::ReconstructThreadState(Thread, *NativeContext);
    *NativeContext = Exception::StoreStateToPackedECContext(Thread, NativeContext->Fpcr, NativeContext->Fpsr);
    LogMan::Msg::DFmt("Suspending: RIP: {:X} SP: {:X}", NativeContext->Pc, NativeContext->Sp);
    CPUArea.Area->InSimulation = 0;
    *CPUArea.Area->SuspendDoorbell = 0;
    return true;
  }

  if (IsEmulatorStackAddress(CPUArea, reinterpret_cast<uint64_t>(__builtin_frame_address(0)))) {
    Exception::RethrowGuestException(*Exception, *NativeContext);
    LogMan::Msg::DFmt("Rethrowing onto guest stack: {:X}", NativeContext->Sp);
    return true;
  } else {
#ifdef FEX_IOS_HOST
    // iOS-Madeira 2026-05-13: iOS doesn't switch exception delivery to a
    // separate emulator stack like Windows-ARM64EC does (no CPU_AREA-driven
    // sigaltstack). Mach exception delivery arrives on whatever thread
    // stack was current, which is usually the guest stack. Attempt rethrow
    // anyway — same path Windows takes; worst case we crash here instead
    // of terminating with "Unexpected exception" silently. Better signal
    // than fatal bail.
    LogMan::Msg::EFmt("iOS: rethrowing JIT fault onto guest stack despite "
                       "frame@{:X} not in emulator-stack range ({:X}..{:X})",
                       (uint64_t)__builtin_frame_address(0),
                       CPUArea.EmulatorStackLimit(),
                       CPUArea.EmulatorStackBase());
    Exception::RethrowGuestException(*Exception, *NativeContext);
    return true;
#else
    LogMan::Msg::EFmt("Unexpected exception in JIT code on guest stack");
    return false;
#endif
  }
}

NTSTATUS ResetToConsistentState(EXCEPTION_RECORD* Exception, CONTEXT* GuestContext, ARM64_NT_CONTEXT* NativeContext) {
  bool Cont {};
  if (Exception->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
    const auto FaultAddress = static_cast<uint64_t>(Exception->ExceptionInformation[1]);

    if (OvercommitTracker) {
      {
        ScopedCallbackDisable guard;
        Cont = OvercommitTracker->HandleAccessViolation(FaultAddress);
      }
      if (Cont) {
        NtContinueNative(NativeContext, false);
      }
    }
  }

  const auto CPUArea = GetCPUArea();
  if (!CPUArea.ThreadState()) {
#ifdef FEX_IOS_HOST
    /* ml259 #44: this bail SILENTLY swallows the null-state case and returns
     * STATUS_SUCCESS, so the fault escalates with no trace. Say so, capped. */
    static int reported;
    if (reported++ < 10) {
      IosLogCPUArea("no-state-at-exception");
    }
#endif
    return STATUS_SUCCESS;
  }

  {
    ScopedCallbackDisable guard;
    Cont = ResetToConsistentStateImpl(CPUArea, Exception, GuestContext, NativeContext);
  }

  if (Cont) {
    NtContinueNative(NativeContext, false);
  }

  CPUArea.Area->InSimulation = false;
  CPUArea.Area->InSyscallCallback = false;
  return STATUS_SUCCESS;
}

/* iOS-port note: previously this took ThreadCreationMutex on the BEFORE
 * call and released it on the AFTER call, holding the lock across the
 * actual memory operation. On Wine-on-iOS that creates an AB-BA deadlock:
 * Wine's RtlAllocateHeap (heap mutex) may grow its arena via
 * NtAllocateVirtualMemory, which calls NotifyMemoryAlloc(BEFORE) → wants
 * ThreadCreationMutex; meanwhile a worker thread holds ThreadCreationMutex
 * (taken in its own NotifyMemoryAlloc(BEFORE)) and needs heap for an
 * InvalidationTracker allocation.
 *
 * The InvalidationTracker has its own internal locking (IntervalsLock,
 * CodeInvalidationMutex), so external serialization isn't strictly
 * required for its correctness. Drop the BEFORE/AFTER mutex entirely
 * and just call into the tracker directly on AFTER. */
void NotifyMemoryAlloc(void* Address, SIZE_T Size, ULONG Type, ULONG Prot, BOOL After, NTSTATUS Status) {
  if (!InvalidationTracker || !GetCPUArea().ThreadState()) {
    return;
  }

  if (After) {
    // MEM_RESET(_UNDO) ignores the passed permissions
    if (!Status && !(Type & (MEM_RESET | MEM_RESET_UNDO))) {
      InvalidationTracker->HandleMemoryProtectionNotification(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), Prot);
    }
  }
}

void NotifyMemoryFree(void* Address, SIZE_T Size, ULONG FreeType, BOOL After, NTSTATUS Status) {
  if (!InvalidationTracker || !GetCPUArea().ThreadState()) {
    return;
  }

  if (After) {
    if (!Status) {
      InvalidationTracker->InvalidateAlignedInterval(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), true);
    }
  }
}

void NotifyMemoryProtect(void* Address, SIZE_T Size, ULONG NewProt, BOOL After, NTSTATUS Status) {
  if (!InvalidationTracker || !GetCPUArea().ThreadState()) {
    return;
  }

  if (After) {
    if (!Status) {
      InvalidationTracker->HandleMemoryProtectionNotification(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), NewProt);
    }
  }
}

/* iOS-Madeira ml710: LOADER-SAFE EXECUTABLE-INTERVAL REGISTRATION.
 *
 * This is a FALLBACK, not a second full registration path. It exists because in a child
 * pseudo-process the syscall notification never arrives -- enter_syscall_callback()
 * refuses, InSyscallCallback having been left set -- so no module except the main image
 * and ntdll is ever marked executable and the first x86-64 instruction the loader enters
 * decodes as NOEXEC, raises NoExecOp and takes the GuestSignal_SIGSEGV trampoline.
 *
 * Wine calls this from its loader once a module is mapped, relocated and imported, before
 * any DllMain runs. It must therefore be safe to call from a thread that is EXECUTING
 * TRANSLATED CODE, and that constraint is what makes it distinct from
 * NotifyMapViewOfSection():
 *
 *   NotifyMapViewOfSection -> HandleImageMap() -> ImageTracker::HandleImageMap(), which
 *   opens with std::scoped_lock(CTX.GetCodeInvalidationMutex()) -- EXCLUSIVE. A thread
 *   running translated code already holds that mutex SHARED, there is no read-to-write
 *   upgrade, and it blocks on itself forever while holding wine's loader lock. That is
 *   exactly how Book of the Dead froze on an unload and Marvel Cosmic Invasion froze on
 *   cryptbase.dll's load, 88s parked with the [iOS-xins] lines as the last output.
 *
 * So this touches ONLY InvalidationTracker, which takes just its own IntervalsLock.
 *
 * WHAT THIS DOES NOT DO, and why that is still a gap: ImageTracker owns image relocation
 * and code-cache information plus extended volatile/ForceTSO metadata. Skipping it keeps
 * execution correct -- the intervals are what gate decoding -- but leaves that metadata
 * incomplete for any module whose syscall notification was genuinely missed. The durable
 * fix is to repair the pseudo-process notification gate, or to defer the ImageTracker half
 * to a dispatcher point where no shared code-invalidation hold exists. Neither is done.
 *
 * Idempotent: re-registering the same intervals is harmless, and the syscall path still
 * fires for the same module whenever its gate does let it through. */
extern "C" void NotifyImageMap(void* Address) {
  if (!InvalidationTracker || !Address) {
    return;
  }

  static std::atomic<uint32_t> Count {0};
  const auto N = ++Count;

  fextl::string ModulePath = FEX::Windows::GetSectionFilePath(reinterpret_cast<uint64_t>(Address));
  fextl::string ModuleName = fextl::string {FEX::Windows::BaseName(ModulePath)};
  InvalidationTracker->HandleImageMap(ModuleName, reinterpret_cast<uint64_t>(Address));

  if (N <= 64) {
    LogMan::Msg::EFmt("[img-map] ml710 #{} intervals-only {} base={}", N, ModuleName, Address);
  }
}

NTSTATUS NotifyMapViewOfSection(void* Unk1, void* Address, void* Unk2, SIZE_T Size, ULONG AllocType, ULONG Prot) {
  /* iOS-Madeira ml183: do NOT require GetCPUArea().ThreadState() here.
   *
   * HandleImageMap() only needs InvalidationTracker + ImageTracker — it never touches
   * thread state. Requiring a live ThreadState silently DROPPED the notification whenever
   * a module was mapped on a thread FEX had not initialised yet, so that image's
   * executable sections were never inserted into InvalidationTracker::XIntervals.
   *
   * The consequence is severe and was the Steam/CEF blocker: Decoder::CheckRangeExecutable
   * -> QueryGuestExecutableRange -> QueryExecutableRange returns Size==0 for the untracked
   * range, the decoder sets HitNonExecutableRange, Core.cpp raises NoExecOp
   * (FAULT_SIGSEGV / TRAPNO_PF / SEGV_ACCERR), and the JIT branches to the
   * GuestSignal_SIGSEGV trampoline which deliberately reads address 0 to force a SIGSEGV.
   * On iOS that lands in our Mach/segv handler as an unhandleable fault and kills the
   * thread — observed 41x per run in the webhelper at libcef.dll function entries
   * (+0x1900733, +0x3b508f0), which is why CEF never finished initialising.
   *
   * Keep the tracker null-checks; only the thread-state requirement is wrong. */
  if (!InvalidationTracker || !ImageTracker) {
    /* ml190: do not drop it — replay once ProcessInit has built the trackers. */
    QueuePendingImageMap(reinterpret_cast<uint64_t>(Address));
    return STATUS_SUCCESS;
  }

  {
    std::scoped_lock Lock(ThreadCreationMutex);
    HandleImageMap(reinterpret_cast<uint64_t>(Address));
  }


  return STATUS_SUCCESS;
}

void NotifyUnmapViewOfSection(void* Address, BOOL After, NTSTATUS Status) {
  if (!InvalidationTracker || !GetCPUArea().ThreadState()) {
    return;
  }

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

void FlushInstructionCacheHeavy(const void* Address, SIZE_T Size) {
  if (!InvalidationTracker || !GetCPUArea().ThreadState()) {
    return;
  }

  std::scoped_lock Lock(ThreadCreationMutex);
  InvalidationTracker->InvalidateAlignedInterval(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), false);
}

void BTCpu64FlushInstructionCache(const void* Address, SIZE_T Size) {
  if (!InvalidationTracker || !GetCPUArea().ThreadState()) {
    return;
  }

  std::scoped_lock Lock(ThreadCreationMutex);
  InvalidationTracker->InvalidateAlignedInterval(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), false);
}

void BTCpu64NotifyMemoryDirty(void* Address, SIZE_T Size) {
  if (!InvalidationTracker || !GetCPUArea().ThreadState()) {
    return;
  }

  std::scoped_lock Lock(ThreadCreationMutex);
  InvalidationTracker->InvalidateAlignedInterval(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size), false);
}

/* iOS-Madeira ml411 (#60/#66): the release half must never be gated on state
 * that can change between the paired calls.
 *
 * Upstream returns early when `!InvalidationTracker || !ThreadState`, and
 * reads the "do I hold the locks" flag out of ThreadState's frontend data.
 * Wine calls this before AND after every NtReadFile, but if ThreadState (or
 * the tracker) is gone by the "after" call, the early return skips the
 * unlock and CodeInvalidationMutex stays WRITE-OWNED FOREVER. Every other
 * thread that read-locks it then parks in WaitOnAddress with no waker —
 * which is exactly the ml411 webhelper stall: the chrome_ipc pump receives
 * Steam's hello, tries to take this lock, and never returns, so the reply is
 * never written and Steam shows the "webhelper is not responding" dialog.
 *
 * Mirror the flag somewhere reachable with no dependency on ThreadState, and
 * check it before any early return.
 *
 * ml412: that mirror must NOT be a thread_local — mingw TLS access loads
 * TEB->ThreadLocalStoragePointer ([x18+0x58]), which is still NULL when the
 * loader issues the first NtReadFile of the first process (crashed at
 * BTCpu64NotifyReadFile+0x3c, addr=0). Use a raw TEB slot instead:
 * Instrumentation[9] is dead space we own for the whole thread lifetime and
 * is zero-initialized with the TEB. (Slot 10 is the wine chrome-ipc PUMP
 * beacon; keep clear of it.) */
static bool* IosInLockedRWXReadSlot() {
  /* TEB->Instrumentation[9] = 0x16b8 + 9*8. mingw's _TEB doesn't expose the
   * field, so address it by offset; wine's EC ntdll stamps Instrumentation[10]
   * (0x1708) as the PUMP beacon, pinning this layout on device. */
  return reinterpret_cast<bool*>(reinterpret_cast<uintptr_t>(NtCurrentTeb()) + 0x1700);
}

void BTCpu64NotifyReadFile(HANDLE Handle, void* Address, SIZE_T Size, BOOL After, NTSTATUS Status) {
  auto* ThreadState = GetCPUArea().ThreadState();
  bool* InLockedRead = IosInLockedRWXReadSlot();

  if (After) {
    if (*InLockedRead) {
      *InLockedRead = false;
      if (ThreadState) {
        GetFrontendThreadData(ThreadState)->InLockedRWXRead = false;
      }
      CTX->GetCodeInvalidationMutex().unlock();
      ThreadCreationMutex.unlock();
    }
    return;
  }

  if (!InvalidationTracker || !ThreadState) {
    return;
  }

  ThreadCreationMutex.lock();
  CTX->GetCodeInvalidationMutex().lock();
  if (InvalidationTracker->BeginUntrackedWriteLocked(reinterpret_cast<uint64_t>(Address), static_cast<uint64_t>(Size))) {
    GetFrontendThreadData(ThreadState)->InLockedRWXRead = true;
    *InLockedRead = true;
  } else {
    CTX->GetCodeInvalidationMutex().unlock();
    ThreadCreationMutex.unlock();
  }
}

/* iOS-Madeira ml612: RELEASE FEX LOCKS A DYING THREAD STILL HOLDS.
 *
 * ml611's whole-app freeze: CrBrowserMain (00b0) blew FEX's 256KB emulator stack
 * inside a recursive fextl::set tree deleter, the fault was misclassified as
 * STATUS_DATATYPE_MISALIGNMENT, dispatch DID occur, nothing handled it, and the
 * thread ran pthread_exit while owning one READ hold of CodeInvalidationMutex
 * ([exit-hold] said exactly that). A writer then queued behind the dead reader;
 * write-priority blocks every later reader, so JIT compilation stopped process-
 * wide -- 11 minutes of an alive app repainting one frozen frame.
 *
 * Called from wine's pthread_exit_wrapper BEFORE it clears TSD slot 275, while
 * x18/TEB and FEX thread state are still reachable.
 *
 * ⚠️ THREE RULES, each of which was a way to make this worse:
 *  1. NEVER trust the stamped address alone and NEVER poke its futex word. The
 *     stamp in Instrumentation[8] is a diagnostic written by whichever mutex was
 *     held; releasing on that basis could unlock a completely different lock.
 *     Verify it equals THIS context's CodeInvalidationMutex, then go through the
 *     mutex API so the futex/wake protocol stays intact.
 *  2. Release exactly the recorded per-thread depth (Instrumentation[7]) -- the
 *     mutex is non-recursive for writers but shared holds nest, and one unlock
 *     for an N-deep hold leaves the wedge in place.
 *  3. Instrumentation[9] means BTCpu64NotifyReadFile is mid-flight, which holds
 *     CodeInvalidationMutex EXCLUSIVELY *and* ThreadCreationMutex. Both must be
 *     dropped, in the same order its After path uses.
 *
 * Returns a bitmask of what was actually released so the caller can log it;
 * every branch is reported, so silence never has to be interpreted.
 */
/* ml618: TEB is passed EXPLICITLY rather than read from x18.
 *
 * This is invoked from wine's pthread_exit_wrapper on a dying thread, so the
 * caller is the authority on which TEB is being torn down. A SELF-TEST call
 * (TebPtr == nullptr) returns REL_SELFTEST and echoes nothing — registration
 * uses it to prove the pointer it bound is the redirected ARM64 alias and not a
 * raw x64 entry thunk, which is exactly what ml613 shipped by mistake. */
extern "C" uint32_t BTCpu64IosReleaseThreadHolds(void* TebPtr, uint64_t* OutStamp, uint32_t* OutDepth, uint32_t* OutFlags) {
  enum : uint32_t {
    REL_NOTHING = 0,
    REL_SHARED = 1 << 0,      // dropped N shared holds
    REL_RWX_EXCLUSIVE = 1 << 1, // dropped the NotifyReadFile exclusive pair
    REL_STAMP_FOREIGN = 1 << 2, // stamp did not match our mutex -- refused
    REL_NO_CTX = 1 << 3,      // context already gone
  };

  enum : uint32_t { REL_SELFTEST = 1u << 4 };
  if (!TebPtr) {
    /* Registration self-test: reaching here at all proves the callback was
     * entered with a correct ARM64 ABI. */
    return REL_SELFTEST;
  }
  auto* Teb = reinterpret_cast<TEB*>(TebPtr);

  auto* Depth = reinterpret_cast<volatile uint32_t*>(reinterpret_cast<uintptr_t>(Teb) + 0x16f0);
  auto* Stamp = reinterpret_cast<volatile uint64_t*>(reinterpret_cast<uintptr_t>(Teb) + 0x16f8);
  auto* InLockedRead = IosInLockedRWXReadSlot();

  const uint64_t StampVal = *Stamp;
  const uint32_t DepthVal = *Depth;
  const bool RWXRead = InLockedRead && *InLockedRead;

  if (OutStamp) {
    *OutStamp = StampVal;
  }
  if (OutDepth) {
    *OutDepth = DepthVal;
  }
  if (OutFlags) {
    *OutFlags = RWXRead ? 1 : 0;
  }

  if (!StampVal && !RWXRead) {
    return REL_NOTHING; // clean exit, nothing held
  }
  if (!CTX) {
    return REL_NO_CTX;
  }

  auto& CodeMutex = CTX->GetCodeInvalidationMutex();
  uint32_t Result = REL_NOTHING;

  // Rule 3 first: the exclusive pair, in NotifyReadFile's own release order.
  if (RWXRead) {
    *InLockedRead = false;
    auto* ThreadState = GetCPUArea().ThreadState();
    if (ThreadState) {
      GetFrontendThreadData(ThreadState)->InLockedRWXRead = false;
    }
    CodeMutex.unlock();
    ThreadCreationMutex.unlock();
    Result |= REL_RWX_EXCLUSIVE;
  }

  // Rule 1 + 2: shared holds, only after proving the stamp is ours.
  if (StampVal && DepthVal) {
    if (StampVal != CodeMutex.IosStampAddress()) {
      return Result | REL_STAMP_FOREIGN;
    }
    for (uint32_t i = 0; i < DepthVal; ++i) {
      CodeMutex.unlock_shared(); // clears the stamp/depth via NoteReadReleased()
    }
    Result |= REL_SHARED;
  }

  return Result;
}

#ifdef FEX_IOS_HOST
/* iOS-Madeira: step markers through ThreadInit. Two runs have died with a
 * fresh post-detach thread's "ThreadInit() entered" as the last FEX log
 * line (silent kill, no crash report) — once during loading's worker-thread
 * spawn, once when QuickTime's recording start triggered a thread spawn.
 * These markers bisect which init step dies (CreateThread's per-thread
 * CodeBuffer/LookupCache allocation is the prime suspect). */
static void IosTiLog(const char* msg) {
  HANDLE stderr_h = NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters
      ? reinterpret_cast<HANDLE>(reinterpret_cast<RTL_USER_PROCESS_PARAMETERS64*>(
            NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters)->hStdError)
      : nullptr;
  if (stderr_h) {
    ULONG written = 0;
    size_t len = 0;
    while (msg[len]) len++;
    WriteFile(stderr_h, msg, static_cast<DWORD>(len), &written, nullptr);
  }
}
#endif

NTSTATUS ThreadInit() {
#ifdef FEX_IOS_HOST
  /* iOS-Madeira diagnostic: log entry to thread-init so we can confirm Wine
   * is calling BTCpu64ThreadInit for the main x86_64 thread before the
   * dispatcher is invoked. Without this, EmulatorData[0] is garbage and
   * the dispatcher BLR's into uninitialized memory. */
  {
    HANDLE stderr_h = NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters
        ? reinterpret_cast<HANDLE>(reinterpret_cast<RTL_USER_PROCESS_PARAMETERS64*>(
              NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters)->hStdError)
        : nullptr;
    if (stderr_h) {
      const char *msg = "[FEX-iOS] ThreadInit() entered\n";
      ULONG written = 0;
      WriteFile(stderr_h, msg, 32, &written, nullptr);
    }
  }
#endif
  std::scoped_lock Lock(ThreadCreationMutex);
#ifdef FEX_IOS_HOST
  IosTiLog("[FEX-iOS] TI:lock\n");
#endif
  FEX::Windows::InitCRTThread();
#ifdef FEX_IOS_HOST
  IosTiLog("[FEX-iOS] TI:crt\n");
#endif
  const auto CPUArea = GetCPUArea();

  static constexpr size_t EmulatorStackSize = 0x40000;
  const uint64_t EmulatorStack =
    reinterpret_cast<uint64_t>(::VirtualAlloc(nullptr, EmulatorStackSize, MEM_COMMIT | MEM_RESERVE | MEM_TOP_DOWN, PAGE_READWRITE));
  CPUArea.EmulatorStackLimit() = EmulatorStack;
  CPUArea.EmulatorStackBase() = EmulatorStack + EmulatorStackSize;
#ifdef FEX_IOS_HOST
  IosTiLog("[FEX-iOS] TI:stack\n");
#endif

  auto* Thread = CTX->CreateThread(0, 0);
#ifdef FEX_IOS_HOST
  IosTiLog("[FEX-iOS] TI:createthread\n");
#endif

  // Default segment setup.
  auto Frame = Thread->CurrentFrame;
  auto NewSegments = new FEXCore::Core::CPUState::gdt_segment[32];

  // Setup initial code-segment GDT
  auto& GDT = NewSegments[FEXCore::Core::CPUState::DEFAULT_USER_CS];
  FEXCore::Core::CPUState::SetGDTBase(&GDT, 0);
  FEXCore::Core::CPUState::SetGDTLimit(&GDT, 0xF'FFFFU);
  GDT.L = 1; // L = Long Mode = 64-bit
  GDT.D = 0; // D = Default Operand SIze = Reserved

  Frame->State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_GDT] = &NewSegments[0];
  // TODO: LDTs are currently unsupported, mirror them to GDT.
  Frame->State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_LDT] = &NewSegments[0];

  Frame->State.cs_idx = FEXCore::Core::CPUState::DEFAULT_USER_CS << 3;
  Frame->State.cs_cached = FEXCore::Core::CPUState::CalculateGDTBase(GDT);

#ifdef FEX_IOS_HOST
  /* iOS-Madeira: set up GS base for x86_64 TLS access. On Windows x64 the
   * convention is GS-base = TEB pointer, and MSVC-emitted code uses
   * `mov rax, gs:[0x58]` to reach TEB->ThreadLocalStoragePointer.
   * LoadStateFromECContext() at the EC->x86 transition sets this, but for
   * the path where x86 code starts running before any CONTEXT-load happens
   * (e.g. Thumper's startup invoking thread-local guards before its first
   * exception-driven context restore), gs_cached stays 0 and gs:[N] hits
   * SEGV at addr=N.
   *
   * 2026-05-19: use IOSLoadTEB() (TPIDRRO_EL0 + TSD slot 275) instead of
   * NtCurrentTeb(). The latter reads x18, which is clobbered by Apple
   * runtime calls earlier in ThreadInit (InitCRTThread, VirtualAlloc,
   * CreateThread). With x18=0, gs_cached was getting set to 0 — confirmed
   * regression that broke boot intermittently. Use the TSD-slot path
   * which is x18-independent. */
  {
    const uint64_t TEB = reinterpret_cast<uint64_t>(IOSLoadTEB());
    Frame->State.gs_cached = TEB;
    Frame->State.fs_cached = 0;
  }
  /* Hard guard: if somehow STILL zero, log loudly so we catch it. */
  if (Frame->State.gs_cached == 0) {
    HANDLE stderr_h_g = NtCurrentTeb() ? (HANDLE)reinterpret_cast<RTL_USER_PROCESS_PARAMETERS64*>(
        NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters)->hStdError : nullptr;
    if (stderr_h_g) {
      const char *msg = "[FEX-iOS] FATAL: gs_cached STILL 0 after IOSLoadTEB!\n";
      ULONG written = 0;
      WriteFile(stderr_h_g, msg, 53, &written, nullptr);
    }
  }
#endif

  FEX::Windows::CallRetStack::InitializeThread(Thread);
#ifdef FEX_IOS_HOST
  IosTiLog("[FEX-iOS] TI:callret\n");
#endif
  Thread->CurrentFrame->Pointers.ExitFunctionEC = reinterpret_cast<uintptr_t>(&ExitFunctionEC);
  CPUArea.StateFrame() = Thread->CurrentFrame;

  uint64_t EnterEC = Thread->CurrentFrame->Pointers.DispatcherLoopTopEnterEC;
  CPUArea.DispatcherLoopTopEnterEC() = EnterEC;

#ifdef FEX_IOS_HOST
  /* iOS-Madeira: PATCH FEX dispatcher's broken SpillStaticRegs.
   *
   * FEX's emitter on iOS produces 7 stale `madd`/`mul` instructions where
   * 7 `stp` should be (pairs 1-7: RDX/RBX, RSP/RBP, RSI/RDI, R8/R9, R10/R11,
   * R12/R13, R14/R15). Same bug at BOTH SpillStaticRegs sites in the
   * dispatcher (ExitFunctionLink at +0x164, NoBlock at +0x264). Net effect:
   * State.gregs[REG_RSP] never spilled before CompileBlock; FillStaticRegs
   * later reloads x23=0 and block 0's first `stp x26, x25, [x23, #-0x10]!`
   * faults at 0xfffffffffffffff0.
   *
   * Workaround: write the correct stp encodings over the broken slots at
   * BOTH sites. The writes go to the RX address; iOS denies RW on RX pages
   * but the ntdll-unix Mach STR emulator catches each fault and redirects
   * the store to the JIT pool's RW alias (located at a runtime-chosen
   * address, NOT a fixed offset from RX).                                   */
  {
    /* Expected stp instructions for pairs 1..7 of SpillStaticRegs.
     * ARM64EC SRA: RAX=x8 (pair0=RAX,RCX), RDX=x1, RBX=x27 (pair1),
     * RSP=x23, RBP=x29 (pair2), RSI=x25, RDI=x26 (pair3),
     * R8=x2, R9=x3 (pair4), R10=x4, R11=x5 (pair5),
     * R12=x19, R13=x20 (pair6), R14=x21, R15=x22 (pair7). */
    static constexpr uint32_t expected[7] = {
      0xa9036f81,  // stp x1, x27, [x28, #0x30]
      0xa9047797,  // stp x23, x29, [x28, #0x40]
      0xa9056b99,  // stp x25, x26, [x28, #0x50]
      0xa9060f82,  // stp x2, x3, [x28, #0x60]
      0xa9071784,  // stp x4, x5, [x28, #0x70]
      0xa9085393,  // stp x19, x20, [x28, #0x80]
      0xa9095b95,  // stp x21, x22, [x28, #0x90]
    };

    /* Two SpillStaticRegs sites in the dispatcher emit, with DIFFERENT
     * shapes:
     *  - First site (ExitFunctionLink path) at EnterEC+0x160: emitter places
     *    pair-0 at +0x160, then a SPURIOUS invalid word at +0x164, then
     *    pair-1..pair-7 at +0x168..+0x180. Net 9 instructions for 8 spills.
     *  - Second site (NoBlock path) at EnterEC+0x264: emitter places pair-0
     *    at +0x264 (legit, no spurious), then pair-1..pair-7 at +0x268..+0x280.
     *
     * Fix: at the FIRST site, shift pair-1..pair-7 LEFT by 4 bytes so they
     * land at +0x164..+0x17C — overwriting the spurious slot, with NOP at
     * +0x180 (was the displaced pair-7). The dispatcher then executes 8 stp
     * pairs at consecutive offsets +0x160..+0x17C, falls through the NOP at
     * +0x180, and resumes at the existing FP-save base setup at +0x184. At
     * the SECOND site, layout is already correct: pair-0 stays at +0x264,
     * pair-1..pair-7 patched at +0x268..+0x280 as before. */
    struct PatchSite {
      uintptr_t pair1_offset;   // where pair-1 should land
      bool      nop_after_pair7; // need a NOP just past pair-7?
    };
    static constexpr PatchSite kSites[] = {
      // 2026-05-19: The hardcoded {0x164, true} site has been removed.
      // With the per-Buffer dual-map fix in place, FEX's dispatcher emit
      // now produces correct stp instructions at +0x164 directly (GPT
      // diagnosed: pair0 at +0x158, pair1 at +0x15c, pair2 at +0x160 —
      // valid code, not the broken pattern). The hardcoded patch was
      // OVERWRITING valid code with stp's that didn't belong there,
      // corrupting the dispatcher layout and causing st1 faults later.
      //
      // The generic uniformity-based scanner below correctly handles the
      // REAL broken sites (where pair-0 stp is followed by 7 uniform-class
      // garbage words). If the scanner reports 0 patched, the dispatcher
      // came out correct.
      // All other sites are scanned/patched dynamically below — the FEX
      // emitter produces the same broken 7-word pattern at MANY offsets
      // (24+ sites in Thumper, growing with each new code path). Iterating
      // a hardcoded list was whack-a-mole; we now scan the whole dispatcher
      // region for `stp x8,x0,[x28,#0x20]` immediately followed by the
      // canonical 7-invalid-words sequence, and rewrite them in-place.
    };

    HANDLE stderr_h = NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters
        ? reinterpret_cast<HANDLE>(reinterpret_cast<RTL_USER_PROCESS_PARAMETERS64*>(
              NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters)->hStdError)
        : nullptr;
    auto log_hex = [&](const char* label, uint64_t val) {
      if (!stderr_h) return;
      char buf[160];
      const char* hexd = "0123456789abcdef";
      int n = 0;
      while (label[n]) { buf[n] = label[n]; n++; }
      buf[n++] = '0'; buf[n++] = 'x';
      for (int j = 60; j >= 0; j -= 4) buf[n++] = hexd[(val >> j) & 0xf];
      buf[n++] = '\n';
      ULONG written = 0;
      WriteFile(stderr_h, buf, n, &written, nullptr);
    };

    log_hex("[FEX-iOS] DispatcherPatch: EnterEC=", EnterEC);

    static constexpr uint32_t kNopInstr = 0xd503201f;  // nop

    for (auto site : kSites) {
      /* Write directly to RX address. iOS doesn't allow RX writes — but the
       * ntdll-unix Mach STR emulator catches the resulting page fault and
       * redirects each store to the correct RW alias (which iOS placed at
       * a runtime-chosen address, NOT a fixed +128MB offset). This is the
       * same path FEX itself uses for its compile-time block emit. */
      uint32_t* patch_rx = reinterpret_cast<uint32_t*>(EnterEC + site.pair1_offset);

      bool already_ok = true;
      for (int i = 0; i < 7; i++) {
        if (patch_rx[i] != expected[i]) { already_ok = false; break; }
      }
      if (already_ok && site.nop_after_pair7 && patch_rx[7] != kNopInstr) {
        already_ok = false;
      }

      if (!already_ok) {
        log_hex("[FEX-iOS]   site pair-1 offset=", site.pair1_offset);
        /* Write to RW alias directly. The iOS JIT pool is dual-mapped:
         * RX at the runtime-chosen base, RW at RX + 256MB. Writing to RX
         * triggers a Mach exception that our STR emulator handles, but
         * empirically that path has been silently dropping a specific store
         * per site (e.g. pair-5) without faulting — possibly an iOS
         * page-protection quirk where ThreadInit's STRs to RX from xtajit64.dll
         * neither succeed natively nor trap.
         *
         * Bypass entirely by writing to the RW alias. RX→RW offset comes
         * from DualMap::WriteOffset (set in ProcessInit from the app's real
         * runtime mapping) — NOT a hardcoded 0x10000000, since the RW alias
         * is placed with VM_FLAGS_ANYWHERE and isn't guaranteed to sit at
         * RX+256MB. */
        const int64_t kRwOffset = FEXCore::DualMap::WriteOffset;
        uint32_t* patch_rw = reinterpret_cast<uint32_t*>(reinterpret_cast<uintptr_t>(patch_rx) + kRwOffset);
        for (int i = 0; i < 7; i++) {
          patch_rw[i] = expected[i];
        }
        size_t flush_size = sizeof(expected);
        if (site.nop_after_pair7) {
          patch_rw[7] = kNopInstr;
          flush_size += sizeof(kNopInstr);
        }
        NtFlushInstructionCache(NtCurrentProcess(), patch_rx, flush_size);
      } else {
        log_hex("[FEX-iOS]   already OK at pair-1 offset=", site.pair1_offset);
      }
    }

    /* Generic scan: many SpillStaticRegs sites in the dispatcher exhibit the
     * same broken-pattern (pair-0 stp at offset N, then 7 invalid words at
     * N+4..N+0x1c). Rather than hardcoding each offset, walk the dispatcher
     * region and rewrite every occurrence in-place. The 7-word signature is
     * specific enough that there are no false positives in the FEX
     * dispatcher (the canonical broken first-word `0x1ccfef95` doesn't
     * decode to anything used in normal emit). */
    {
      static constexpr size_t kScanBytes = 0x2000;
      static constexpr uint32_t kStpPair0 = 0xa9020388;  /* stp x8,x0,[x28,#0x20] */
      /* Detect broken sites by UNIFORMITY: the FEX emitter's bug produces 7
       * garbage instructions where pair-1..pair-7 stps should go. The exact
       * encoding class varies per build (FCSEL 0x1c..0x1d, MADD/MSUB
       * 0x1a..0x1b, observed) but within a single broken site, all 7 garbage
       * words share the same top encoding-class byte (`& 0xff800000`).
       *
       * Real dispatcher code that follows a legitimate pair-0 stp varies:
       * arithmetic, branches, loads, calls — DIFFERENT top bytes. So
       * "uniform top byte across 7 words AND not 0xa9 (stp)" is a tight
       * discriminator that catches every observed garbage class without
       * false-positiving on real code.
       *
       * (Earlier negative-match-on-stp filter false-positived: legitimate
       * pair-0 sites whose follow-up code has 7 non-stp instructions got
       * their tails overwritten with pair-1..pair-7, breaking valid code.) */
      static constexpr uint32_t kStpMask = 0xff800000;
      static constexpr uint32_t kStp64SignedOffset = 0xa9000000;
      uint32_t* base = reinterpret_cast<uint32_t*>(EnterEC);
      int patched = 0;
      int already_ok = 0;
      for (size_t i = 0; i < kScanBytes / 4 - 8; i++) {
        if (base[i] != kStpPair0) continue;
        uint32_t top0 = base[i + 1] & kStpMask;
        if (top0 == kStp64SignedOffset) { already_ok++; continue; }
        bool uniform = true;
        for (int j = 2; j <= 7; j++) {
          if ((base[i + j] & kStpMask) != top0) { uniform = false; break; }
        }
        if (!uniform) continue;  /* legit code following pair-0 — leave alone */
        /* Write to RW alias via the real runtime offset (DualMap::WriteOffset),
         * not a hardcoded 0x10000000. See the other patch site for rationale. */
        const int64_t kRwOffset = FEXCore::DualMap::WriteOffset;
        uint32_t* rw_base = reinterpret_cast<uint32_t*>(reinterpret_cast<uintptr_t>(&base[i + 1]) + kRwOffset);
        for (int j = 0; j < 7; j++) {
          rw_base[j] = expected[j];
        }
        NtFlushInstructionCache(NtCurrentProcess(), &base[i + 1], sizeof(expected));
        patched++;
      }
      log_hex("[FEX-iOS]   scan-patched broken sites: count=", (uint64_t)patched);
      log_hex("[FEX-iOS]   scan-skipped already-ok pair-0 sites: count=", (uint64_t)already_ok);
    }

    log_hex("[FEX-iOS] DispatcherPatch DONE.", 0);
  }
#endif

  uint64_t EnterECFillSRA = Thread->CurrentFrame->Pointers.DispatcherLoopTopEnterECFillSRA;
  CPUArea.DispatcherLoopTopEnterECFillSRA() = EnterECFillSRA;

  CPUArea.ContextAmd64() = {.ContextFlags = CONTEXT_CONTROL | CONTEXT_SEGMENTS | CONTEXT_INTEGER | CONTEXT_FLOATING_POINT,
                            .AMD64_SegCs = (FEXCore::Core::CPUState::DEFAULT_USER_CS << 3) | 3,
                            .AMD64_SegDs = 0x2b,
                            .AMD64_SegEs = 0x2b,
                            .AMD64_SegFs = 0x53,
                            .AMD64_SegGs = 0x2b,
                            .AMD64_SegSs = 0x2b,
                            .AMD64_EFlags = 0x202,
                            .AMD64_MxCsr = 0x1f80,
                            .AMD64_MxCsr_copy = 0x1f80,
                            .AMD64_ControlWord = 0x27f};
  Exception::LoadStateFromECContext(Thread, CPUArea.ContextAmd64().AMD64_Context);

  Thread->FrontendPtr = new FrontendThreadData();

  {
    auto ThreadTID = GetCurrentThreadId();
    Threads.emplace(ThreadTID, Thread);
    if (StatAllocHandler) {
      Thread->ThreadStats = StatAllocHandler->AllocateSlot(ThreadTID);
    }
  }

#ifdef FEX_IOS_HOST
  // ml460 (#75): expose this thread to the pool-tail sweeper.
  IosSweepRegisterThread(Thread, reinterpret_cast<volatile uint8_t*>(&CPUArea.Area->InSimulation));
#endif

  CPUArea.ThreadState() = Thread;
  CPUArea.Area->SuspendDoorbell = reinterpret_cast<ULONG*>(&Thread->CurrentFrame->SuspendDoorbell);
#ifdef FEX_IOS_HOST
  IosLogCPUArea("ThreadInit-done");
#endif
#ifdef FEX_IOS_HOST
  {
    HANDLE stderr_h = NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters
        ? reinterpret_cast<HANDLE>(reinterpret_cast<RTL_USER_PROCESS_PARAMETERS64*>(
              NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters)->hStdError)
        : nullptr;
    if (stderr_h) {
      char buf[256];
      const char *hexd = "0123456789abcdef";
      const char *prefix = "[FEX-iOS] ThreadInit() done: EmulatorData[0]=0x";
      int i = 0;
      while (prefix[i]) { buf[i] = prefix[i]; i++; }
      unsigned long long ed0 = (unsigned long long)CPUArea.Area->EmulatorData[0];
      for (int j = 60; j >= 0; j -= 4) buf[i++] = hexd[(ed0 >> j) & 0xf];
      const char *p2 = " EnterEC=0x";
      for (int k = 0; p2[k]; ++k) buf[i++] = p2[k];
      unsigned long long enter_ec = (unsigned long long)CPUArea.DispatcherLoopTopEnterEC();
      for (int j = 60; j >= 0; j -= 4) buf[i++] = hexd[(enter_ec >> j) & 0xf];
      const char *p3 = " gs_cached=0x";
      for (int k = 0; p3[k]; ++k) buf[i++] = p3[k];
      unsigned long long gs = (unsigned long long)Frame->State.gs_cached;
      for (int j = 60; j >= 0; j -= 4) buf[i++] = hexd[(gs >> j) & 0xf];
      buf[i++] = '\n';
      ULONG written = 0;
      WriteFile(stderr_h, buf, i, &written, nullptr);
    }
  }
#endif
  return STATUS_SUCCESS;
}

NTSTATUS ThreadTerm(HANDLE Thread, LONG ExitCode) {
  if (!FEX::Windows::ValidateHandleAccess(Thread, THREAD_TERMINATE)) {
    // ml435 (#73): every exit that bails here leaks the thread's rpmalloc heap
    // (64-192MB of band spans) — count them.
    LogMan::Msg::EFmt("[thr-term] rev=ml435 DENIED handle={}", Thread);
    return STATUS_ACCESS_DENIED;
  }

  auto ThreadDup = FEX::Windows::DupHandle(Thread, THREAD_QUERY_INFORMATION | THREAD_SUSPEND_RESUME);

  THREAD_BASIC_INFORMATION Info;
  if (auto Err = NtQueryInformationThread(*ThreadDup, ThreadBasicInformation, &Info, sizeof(Info), nullptr); Err) {
    LogMan::Msg::EFmt("[thr-term] rev=ml435 QUERY-FAIL {:#x}", static_cast<uint32_t>(Err));
    return Err;
  }

  const auto ThreadTID = reinterpret_cast<uint64_t>(Info.ClientId.UniqueThread);
  bool Self = ThreadTID == GetCurrentThreadId();
  if (!Self) {
    CONTEXT TmpContext;
    // If we are suspending a thread that isn't ourselves, try to suspend it first so we know internal JIT locks aren't being held.
    NtSuspendThread(*ThreadDup, NULL);
    // This will wait for the thread to be suspended
    NtGetContextThread(*ThreadDup, &TmpContext);
  }

  const auto [Err, CPUArea] = GetThreadCPUArea(*ThreadDup);
  if (Err) {
    LogMan::Msg::EFmt("[thr-term] rev=ml435 CPUAREA-FAIL tid={:#x} self={} st={:#x}", ThreadTID, Self, static_cast<uint32_t>(Err));
    if (Self) {
      FEX::Windows::DeinitCRTThread();
    }
    return Err;
  }

  {
    std::scoped_lock Lock(ThreadCreationMutex);
    auto it = Threads.find(ThreadTID);
    if (it == Threads.end()) {
      // Thread already terminated. ml435 (#73): this early-out used to skip
      // DeinitCRTThread entirely — a self-exiting thread that misses the
      // registry leaked its rpmalloc heap (64-192MB of band spans) every
      // time. rpmalloc_thread_finalize is fallback-safe (empty TLS resolves
      // to global_heap_default and is skipped), so release it here too.
      LogMan::Msg::EFmt("[thr-term] rev=ml435 REGISTRY-MISS tid={:#x} self={}", ThreadTID, Self);
      if (Self) {
        FEX::Windows::DeinitCRTThread();
      }
      return STATUS_SUCCESS;
    }

    Threads.erase(it);
    if (StatAllocHandler) {
      StatAllocHandler->DeallocateSlot(CPUArea.ThreadState()->ThreadStats);
    }
  }
  auto ThreadState = CPUArea.ThreadState();

#ifdef FEX_IOS_HOST
  /* ml460 (#75): remove from the sweep registry and drain any in-flight
   * sweep BEFORE tearing the thread down. Must be outside the
   * ThreadCreationMutex scope above — the wait inside TCM would close an
   * ABBA loop through a sweeper blocked on a map lock whose holder wants
   * TCM via a memory notify. */
  IosSweepUnregisterThread(ThreadState);
#endif

  delete GetFrontendThreadData(ThreadState);

  // GDT and LDT are mirrored, only free one.
  delete[] ThreadState->CurrentFrame->State.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_GDT];

  FEX::Windows::CallRetStack::DestroyThread(ThreadState);
  CTX->DestroyThread(ThreadState);
  ::VirtualFree(reinterpret_cast<void*>(CPUArea.EmulatorStackLimit()), 0, MEM_RELEASE);
  if (ThreadTID == GetCurrentThreadId()) {
    static std::atomic<uint32_t> DeinitCount;
    LogMan::Msg::EFmt("[thr-term] rev=ml435 deinit #{} tid={:#x}", DeinitCount.fetch_add(1) + 1, ThreadTID);
    FEX::Windows::DeinitCRTThread();
  } else {
    // ml435 (#73): cross-thread termination cannot run the victim's TLS-based
    // finalize — its rpmalloc heap leaks. Count these; if nonzero they are the
    // remaining leak source after the registry-miss fix.
    LogMan::Msg::EFmt("[thr-term] rev=ml435 CROSS-TERM tid={:#x} — victim heap not finalized", ThreadTID);
  }

  return STATUS_SUCCESS;
}

BOOLEAN BTCpu64IsProcessorFeaturePresent(UINT Feature) {
  return CPUFeatures->IsFeaturePresent(Feature) ? TRUE : FALSE;
}

void UpdateProcessorInformation(SYSTEM_CPU_INFORMATION* Info) {
  CPUFeatures->UpdateInformation(Info);
}
