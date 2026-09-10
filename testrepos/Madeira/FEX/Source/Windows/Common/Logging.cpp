// SPDX-License-Identifier: MIT
#include <FEXCore/fextl/fmt.h>
#include <FEXCore/Config/Config.h>
#include <FEXCore/Utils/LogManager.h>

#include <cstdio>
#include <ntstatus.h>
#include <windef.h>
#include <winternl.h>
#include <winnt.h>

#ifdef FEX_IOS_HOST
#include <unistd.h>
#endif

namespace {
void (*WineDbgOut)(const char* Message);
FILE* LogFile;

/* iOS-Madeira ml194: FEX's log output was being DISCARDED, which is why no LogMan
 * message (e.g. "[TI-IC] lookupcache-alloc") has ever appeared in madeira-log.txt and why
 * every FEX-side question this session had to be answered indirectly from ntdll probes.
 *
 * Logging::Init() IS called (ARM64EC Module.cpp ProcessInit) and ProcessInit completes,
 * yet even its own install trace never showed up. Cause: this is a PE module, so
 * ::write(2, ...) goes through the CRT's descriptor table bound to the Windows stderr
 * HANDLE — NOT the unix fd 2 that the app redirects into madeira-log.txt. Writing to the
 * process's real hStdError is the path already proven to work here (see the FEX-iOS FATAL
 * message in ARM64EC/Module.cpp). */
static void IosLogWrite(const char* Str, size_t Len) {
  /* ml195: hStdError is NULL in this context, so the WriteFile path produced nothing
   * (which also means the pre-existing "[FEX-iOS] FATAL" message was never functional).
   * Prefer __wine_dbg_output: it IS exported by our PE ntdll (export table ordinal 1464)
   * and is exactly what that ntdll's own ERR() lines go through — those reach
   * madeira-log.txt reliably. Keep WriteFile as a fallback. */
  static int (__cdecl *DbgOut)(const char*);
  static bool Resolved;
  if (!Resolved) {
    Resolved = true;
    DbgOut = reinterpret_cast<decltype(DbgOut)>(
        GetProcAddress(GetModuleHandleA("ntdll.dll"), "__wine_dbg_output"));
  }
  if (DbgOut) {
    DbgOut(Str);
    return;
  }
  HANDLE h = NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters
                 ? reinterpret_cast<HANDLE>(reinterpret_cast<RTL_USER_PROCESS_PARAMETERS64*>(
                       NtCurrentTeb()->ProcessEnvironmentBlock->ProcessParameters)->hStdError)
                 : nullptr;
  if (h) {
    ULONG Written = 0;
    WriteFile(h, Str, static_cast<DWORD>(Len), &Written, nullptr);
  }
}

static void MsgHandler(LogMan::DebugLevels Level, const char* Message) {
  const auto Output = fextl::fmt::format("{} {:X} {}\n", LogMan::DebugLevelStr(Level), GetCurrentThreadId(), Message);
#ifdef FEX_IOS_HOST
  /* iOS-Madeira: route directly to stderr (which is dup2'd to madeira-log.txt
   * by WineProcessBridge). __wine_dbg_output is exported but doesn't always
   * resolve via GetProcAddress on our embedded ntdll, so go around it. */
  IosLogWrite(Output.c_str(), Output.size());
  return;
#endif
  if (WineDbgOut) {
    WineDbgOut(Output.c_str());
  } else if (LogFile) {
    fwrite(Output.c_str(), 1, Output.size(), LogFile);
  }
}

static void AssertHandler(const char* Message) {
  const auto Output = fextl::fmt::format("A {}\n", Message);
#ifdef FEX_IOS_HOST
  IosLogWrite(Output.c_str(), Output.size());
  return;
#endif
  if (WineDbgOut) {
    WineDbgOut(Output.c_str());
  } else if (LogFile) {
    fwrite(Output.c_str(), 1, Output.size(), LogFile);
  }
}
} // namespace

namespace FEX::Windows::Logging {
void Init() {
#ifndef FEX_IOS_HOST
  FEX_CONFIG_OPT(SilentLog, SILENTLOG);
  if (SilentLog()) {
    return;
  }
#endif

#ifdef FEX_IOS_HOST
  /* iOS-Madeira: trace install via stderr directly to confirm Init() ran. */
  const char *m = "[FEX-iOS] Logging::Init installing MsgHandler\n";
  IosLogWrite(m, __builtin_strlen(m));
#endif

  WineDbgOut = reinterpret_cast<decltype(WineDbgOut)>(GetProcAddress(GetModuleHandleA("ntdll.dll"), "__wine_dbg_output"));
  if (!WineDbgOut) {
    const auto Path = fextl::fmt::format("{}\\fex-{}.log", getenv("LOCALAPPDATA"), GetCurrentProcessId());
    LogFile = fopen(Path.c_str(), "a");
  }
  LogMan::Throw::InstallHandler(AssertHandler);
  LogMan::Msg::InstallHandler(MsgHandler);
}
} // namespace FEX::Windows::Logging
