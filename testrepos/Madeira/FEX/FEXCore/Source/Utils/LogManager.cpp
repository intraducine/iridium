// SPDX-License-Identifier: MIT
/*
$info$
tags: glue|log-manager
$end_info$
*/

#include <FEXCore/Utils/CompilerDefs.h>
#include <FEXCore/Utils/LogManager.h>
#include <FEXCore/fextl/fmt.h>

namespace LogMan {

namespace Throw {
  ThrowHandler Handler {};
  void InstallHandler(ThrowHandler _Handler) {
    Handler = _Handler;
  }
  void UnInstallHandler() {
    Handler = nullptr;
  }

  void MFmt(const char* fmt, const fmt::format_args& args) {
    if (Handler) {
      auto msg = fextl::fmt::vformat(fmt, args);
      Handler(msg.c_str());
    }

    FEX_TRAP_EXECUTION;
  }
} // namespace Throw

namespace Msg {
  MsgHandler Handler {};
  void InstallHandler(MsgHandler _Handler) {
    Handler = _Handler;
  }
  void UnInstallHandler() {
    Handler = nullptr;
  }

  // iOS-Madeira ml115: last format string that reached MFmtImpl, exported so a
// crash dump can name the message even when every output channel is unusable
// in a cloned pool copy. Plain pointer store — cannot fail.
extern "C" __attribute__((visibility("default"))) const char* LastDroppedFmt = nullptr;

void MFmtImpl(DebugLevels level, const char* fmt, const fmt::format_args& args) {
    // iOS-Madeira (ml107/ml114): three separate child deaths traced to THIS
    // function — the allocator returned NULL on the logging thread and the
    // unchecked memmove inside vformat/fextl::string killed the process, so
    // the message that would have named the real bug never surfaced. Emit the
    // raw format string first via write(2): it is a compile-time literal and
    // needs no allocation, so the complaint is readable even if everything
    // below fails. Then probe the allocator and drop the formatted message
    // gracefully instead of crashing.
    // ml115: the write(2) raw-emit itself crashed — in a pseudo-process child
    // the FEX pool copy's .data is cloned, so the CRT file table (and the
    // rpmalloc heap state) are invalid in that copy; NOTHING in this DLL that
    // touches its own globals is safe there. Probe the allocator and drop the
    // message silently rather than crash; the child surviving matters more
    // than the message text. (Message identity: park the fmt pointer in a
    // fixed global so a debugger/fault dump can retrieve it — a pointer store
    // to our own .data is the only side effect that cannot fail.)
    LastDroppedFmt = fmt;
    void* probe = FEXCore::Allocator::malloc(64);
    if (!probe) {
      return;   // allocator dead in this copy — drop the message, survive
    }
    FEXCore::Allocator::free(probe);
    if (Handler) {
      const auto msg = fextl::fmt::vformat(fmt, args);
      Handler(level, msg.c_str());
    }
  }

} // namespace Msg
} // namespace LogMan
