#include "../include/iridium_fex_ios_syscall_bridge.h"
#include "../include/iridium_fex_ios_bridge.h"

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)

#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/Utils/AllocatorHooks.h>
#include <CommonTools/DummyHandlers.h>

#include "iridium_fex_ios_guest_thread_state_internal.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csetjmp>
#include <cstddef>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <map>
#include <mutex>
#include <pthread.h>
#include <poll.h>
#include <sched.h>
#include <set>
#include <stdlib.h>
#include <spawn.h>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#include <sys/mman.h>
#include <sys/ioctl.h>
#if defined(__APPLE__)
#include <sys/mount.h>
#include <sys/sysctl.h>
#else
#include <sys/vfs.h>
#endif
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/ucontext.h>
#include <sys/uio.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <crt_externs.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#endif

namespace iridium::fex::ios {
namespace {

constexpr uint64_t kLinuxTaskMax64Bit = 1ULL << 48;
constexpr uint64_t kArchSetGS = 0x1001;
constexpr uint64_t kArchSetFS = 0x1002;
constexpr uint64_t kArchGetFS = 0x1003;
constexpr uint64_t kArchGetGS = 0x1004;
constexpr uint64_t kArchGetCPUID = 0x1011;
constexpr uint64_t kArchSetCPUID = 0x1012;
constexpr uint64_t kArchCETStatus = 0x3001;
constexpr int kLinuxErrnoNoSys = 38;
constexpr uint64_t kPrSetName = 15;
constexpr uint64_t kPrSetVMA = 0x53564d41;
constexpr uint64_t kPrSetVMAAnonName = 0;

constexpr int kLinuxMapShared = 0x01;
constexpr int kLinuxMapPrivate = 0x02;
constexpr int kLinuxMapFixed = 0x10;
constexpr int kLinuxMapAnonymous = 0x20;
constexpr int kLinuxMapDenyWrite = 0x800;
constexpr int kLinuxMapExecutable = 0x1000;
constexpr int kLinuxMapNoReserve = 0x4000;
constexpr int kLinuxMapStack = 0x20000;
constexpr int kLinuxMapFixedNoReplace = 0x100000;
constexpr int kLinuxAtFDCWD = -100;
constexpr int kLinuxOpenAccessMode = 0x3;
constexpr int kLinuxOpenWriteOnly = 0x1;
constexpr int kLinuxOpenReadWrite = 0x2;
constexpr int kLinuxOpenCreate = 0x40;
constexpr int kLinuxOpenExclusive = 0x80;
constexpr int kLinuxOpenNoCTTY = 0x100;
constexpr int kLinuxOpenTruncate = 0x200;
constexpr int kLinuxOpenAppend = 0x400;
constexpr int kLinuxOpenNonBlock = 0x800;
constexpr int kLinuxOpenDSync = 0x1000;
constexpr int kLinuxOpenDirect = 0x4000;
constexpr int kLinuxOpenLargeFile = 0x8000;
constexpr int kLinuxOpenDirectory = 0x10000;
constexpr int kLinuxOpenNoFollow = 0x20000;
constexpr int kLinuxOpenCloseOnExec = 0x80000;
constexpr int kLinuxOCloExec = 0x80000;
constexpr int kLinuxClockRealtime = 0;
constexpr int kLinuxClockMonotonic = 1;
constexpr int kLinuxTimerAbsolute = 1;
constexpr int kLinuxFGetFD = 1;
constexpr int kLinuxFSetFD = 2;
constexpr int kLinuxFGetFL = 3;
constexpr int kLinuxFSetFL = 4;
constexpr int kLinuxFDClOExec = 1;
constexpr int kLinuxAtSymlinkNoFollow = 0x100;
constexpr int kLinuxAtEAccess = 0x200;
constexpr int kLinuxAtEmptyPath = 0x1000;
constexpr unsigned int kLinuxGetRandomNonBlock = 0x1;
constexpr unsigned int kLinuxGetRandomRandom = 0x2;
constexpr int kLinuxFutexWait = 0;
constexpr int kLinuxFutexWake = 1;
constexpr int kLinuxFutexWaitBitset = 9;
constexpr int kLinuxFutexWakeBitset = 10;
constexpr int kLinuxFutexCommandMask = 0x7f;
constexpr int kLinuxFutexClockRealtime = 0x100;
constexpr int kLinuxSignalMax = 64;
constexpr uint64_t kLinuxCloneVM = 0x00000100;
constexpr uint64_t kLinuxCloneFS = 0x00000200;
constexpr uint64_t kLinuxCloneFiles = 0x00000400;
constexpr uint64_t kLinuxCloneSighand = 0x00000800;
constexpr uint64_t kLinuxCloneThread = 0x00010000;
constexpr uint64_t kLinuxCloneSysvsem = 0x00040000;
constexpr uint64_t kLinuxCloneSetTLS = 0x00080000;
constexpr uint64_t kLinuxCloneParentSetTID = 0x00100000;
constexpr uint64_t kLinuxCloneChildClearTID = 0x00200000;
constexpr uint64_t kLinuxCloneDetached = 0x00400000;
constexpr uint64_t kLinuxCloneUntraced = 0x00800000;
constexpr uint64_t kLinuxCloneChildSetTID = 0x01000000;
constexpr int kLinuxRtSignalBlock = 0;
constexpr int kLinuxRtSignalUnblock = 1;
constexpr int kLinuxRtSignalSetMask = 2;
constexpr size_t kLinuxX64SigsetSize = sizeof(uint64_t);
constexpr size_t kLinuxDirent64NameOffset = 19;
constexpr int kLinuxAfUnix = 1;
constexpr int kLinuxSockStream = 1;
constexpr int kLinuxSockDgram = 2;
constexpr int kLinuxSockSeqpacket = 5;
constexpr int kLinuxSockNonBlock = 0x800;
constexpr int kLinuxSockCloseOnExec = 0x80000;
constexpr int kLinuxSolSocket = 1;
constexpr int kLinuxScmRights = 1;
constexpr int kLinuxSoPassCred = 16;
constexpr int kLinuxMsgCtrunc = 0x8;
constexpr int kLinuxMsgNosignal = 0x4000;
constexpr int kLinuxMsgCmsgCloexec = 0x40000000;

thread_local std::jmp_buf* guest_exit_trap = nullptr;
thread_local int guest_exit_status = 0;
std::atomic<IridiumFEXIOSEmbeddedWineServerStart> embedded_wine_server_start {nullptr};
thread_local RuntimeMilestoneObserver runtime_milestone_observer = nullptr;
thread_local void* runtime_milestone_context = nullptr;
thread_local uint64_t guest_thread_identifier_override = 0;
thread_local int32_t* guest_clear_tid_address = nullptr;
std::atomic<uint64_t> next_guest_thread_identifier {10000};
std::mutex futex_wait_mutex;
std::condition_variable futex_wait_condition;
uint64_t futex_wake_generation = 0;

struct GuestSignalTarget {
  std::atomic<int>* pending_signal {};
  std::shared_ptr<std::atomic_bool> stop_requested;
};

std::mutex guest_signal_targets_mutex;
std::map<uint64_t, GuestSignalTarget> guest_signal_targets;
thread_local std::atomic<int>* current_guest_pending_signal = nullptr;

void register_guest_signal_target(
  uint64_t identifier,
  std::atomic<int>* pending_signal,
  const std::shared_ptr<std::atomic_bool>& stop_requested
) {
  const std::lock_guard<std::mutex> lock(guest_signal_targets_mutex);
  guest_signal_targets[identifier] = {pending_signal, stop_requested};
}

void unregister_guest_signal_target(uint64_t identifier, std::atomic<int>* pending_signal) {
  const std::lock_guard<std::mutex> lock(guest_signal_targets_mutex);
  const auto target = guest_signal_targets.find(identifier);
  if (target != guest_signal_targets.end() && target->second.pending_signal == pending_signal) {
    guest_signal_targets.erase(target);
  }
}

void emit_runtime_milestone(const char* milestone) {
  if (runtime_milestone_observer != nullptr) {
    runtime_milestone_observer(milestone, runtime_milestone_context);
  }
}

struct GuestExecutionSignalTrap {
  std::jmp_buf jump_buffer {};
  int signal_number {};
  uintptr_t fault_address {};
  uintptr_t host_pc {};
};

thread_local GuestExecutionSignalTrap* guest_execution_signal_trap = nullptr;
std::mutex guest_signal_handler_mutex;
size_t guest_signal_handler_users = 0;
struct sigaction guest_previous_segv {};
struct sigaction guest_previous_bus {};
struct sigaction guest_previous_ill {};
struct sigaction guest_previous_trap {};

#if defined(__APPLE__)
char** host_environment() {
  return *_NSGetEnviron();
}
#else
extern char** environ;
char** host_environment() {
  return environ;
}
#endif

struct LinuxUtsName {
  char sysname[65];
  char nodename[65];
  char release[65];
  char version[65];
  char machine[65];
  char domainname[65];
};

struct LinuxStat {
  uint64_t dev;
  uint64_t ino;
  uint64_t nlink;
  uint32_t mode;
  uint32_t uid;
  uint32_t gid;
  uint32_t pad0;
  uint64_t rdev;
  int64_t size;
  int64_t blksize;
  int64_t blocks;
  int64_t atime_sec;
  int64_t atime_nsec;
  int64_t mtime_sec;
  int64_t mtime_nsec;
  int64_t ctime_sec;
  int64_t ctime_nsec;
  int64_t unused[3];
};

static_assert(sizeof(LinuxStat) == 144, "x86_64 Linux stat layout should stay stable");

struct LinuxKernelSigAction {
  uint64_t handler;
  uint64_t flags;
  uint64_t restorer;
  uint64_t mask;
};

static_assert(sizeof(LinuxKernelSigAction) == 32, "x86_64 Linux kernel sigaction layout should stay stable");

struct LinuxRseqArea {
  uint32_t cpu_id_start;
  uint32_t cpu_id;
  uint64_t rseq_cs;
  uint32_t flags;
};

struct LinuxRLimit64 {
  uint64_t current;
  uint64_t maximum;
};

struct LinuxSysInfo {
  int64_t uptime;
  uint64_t loads[3];
  uint64_t totalram;
  uint64_t freeram;
  uint64_t sharedram;
  uint64_t bufferram;
  uint64_t totalswap;
  uint64_t freeswap;
  uint16_t procs;
  uint16_t padding;
  uint64_t totalhigh;
  uint64_t freehigh;
  uint32_t mem_unit;
};

static_assert(sizeof(LinuxSysInfo) == 112, "x86_64 Linux sysinfo layout should stay stable");

struct LinuxStatFS {
  int64_t type;
  int64_t block_size;
  uint64_t blocks;
  uint64_t blocks_free;
  uint64_t blocks_available;
  uint64_t files;
  uint64_t files_free;
  int32_t fsid[2];
  int64_t name_length;
  int64_t fragment_size;
  int64_t flags;
  int64_t spare[4];
};

static_assert(sizeof(LinuxStatFS) == 120, "x86_64 Linux statfs layout should stay stable");

struct LinuxStackT {
  uint64_t stack_pointer;
  int32_t flags;
  uint32_t padding;
  uint64_t size;
};

static_assert(sizeof(LinuxStackT) == 24, "x86_64 Linux stack_t layout should stay stable");

struct LinuxSockAddrUnix {
  uint16_t family;
  char path[108];
};

struct LinuxMsgHdr {
  uint64_t name;
  uint32_t name_length;
  uint32_t padding0;
  uint64_t iov;
  uint64_t iov_length;
  uint64_t control;
  uint64_t control_length;
  int32_t flags;
  uint32_t padding1;
};

static_assert(sizeof(LinuxMsgHdr) == 56, "x86_64 Linux msghdr layout should stay stable");

struct LinuxCmsghdr {
  uint64_t length;
  int32_t level;
  int32_t type;
};

static_assert(sizeof(LinuxCmsghdr) == 16, "x86_64 Linux cmsghdr layout should stay stable");

uint64_t linux_error_result() {
  return static_cast<uint64_t>(-errno);
}

std::string translate_guest_path(const char* path);

uint64_t handle_poll(uint64_t guest_fds, uint64_t guest_count, int timeout_ms) {
  if (guest_count > static_cast<uint64_t>(std::numeric_limits<nfds_t>::max())) {
    return static_cast<uint64_t>(-EINVAL);
  }
  if (guest_count != 0 && guest_fds == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }
  const int result = ::poll(
    reinterpret_cast<struct pollfd*>(guest_fds),
    static_cast<nfds_t>(guest_count),
    timeout_ms
  );
  return result < 0 ? linux_error_result() : static_cast<uint64_t>(result);
}

uint64_t handle_ppoll(
  uint64_t guest_fds,
  uint64_t guest_count,
  uint64_t guest_timeout,
  uint64_t guest_signal_mask,
  size_t signal_mask_size
) {
  if (guest_signal_mask != 0 && signal_mask_size != kLinuxX64SigsetSize) {
    return static_cast<uint64_t>(-EINVAL);
  }

  int timeout_ms = -1;
  if (guest_timeout != 0) {
    const auto* timeout = reinterpret_cast<const timespec*>(guest_timeout);
    if (timeout->tv_sec < 0 || timeout->tv_nsec < 0 || timeout->tv_nsec >= 1000000000) {
      return static_cast<uint64_t>(-EINVAL);
    }
    constexpr int64_t kMillisecondsPerSecond = 1000;
    constexpr int64_t kNanosecondsPerMillisecond = 1000000;
    if (timeout->tv_sec > (INT_MAX / kMillisecondsPerSecond)) {
      timeout_ms = INT_MAX;
    } else {
      const int64_t rounded_milliseconds =
        timeout->tv_sec * kMillisecondsPerSecond
        + (timeout->tv_nsec + kNanosecondsPerMillisecond - 1) / kNanosecondsPerMillisecond;
      timeout_ms = static_cast<int>(std::min<int64_t>(rounded_milliseconds, INT_MAX));
    }
  }
  return handle_poll(guest_fds, guest_count, timeout_ms);
}

uint64_t handle_faccessat2(int guest_dirfd, const char* guest_path, int mode, int guest_flags) {
  constexpr int supported_flags = kLinuxAtEAccess | kLinuxAtSymlinkNoFollow;
  if (guest_path == nullptr) {
    return static_cast<uint64_t>(-EFAULT);
  }
  if ((guest_flags & ~supported_flags) != 0) {
    return static_cast<uint64_t>(-EINVAL);
  }

  const int dirfd = guest_dirfd == kLinuxAtFDCWD ? AT_FDCWD : guest_dirfd;
  const auto translated_path = dirfd == AT_FDCWD
    ? translate_guest_path(guest_path)
    : std::string(guest_path);
  int host_flags = 0;
#if defined(AT_EACCESS)
  if ((guest_flags & kLinuxAtEAccess) != 0) host_flags |= AT_EACCESS;
#endif
#if defined(AT_SYMLINK_NOFOLLOW)
  if ((guest_flags & kLinuxAtSymlinkNoFollow) != 0) host_flags |= AT_SYMLINK_NOFOLLOW;
#endif
  if (::faccessat(dirfd, translated_path.c_str(), mode, host_flags) != 0) {
    return linux_error_result();
  }
  return 0;
}

uint64_t handle_getrandom(uint64_t guest_buffer, size_t length, unsigned int flags) {
  if ((flags & ~(kLinuxGetRandomNonBlock | kLinuxGetRandomRandom)) != 0) {
    return static_cast<uint64_t>(-EINVAL);
  }
  if (length != 0 && guest_buffer == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }
  if (length != 0) {
    ::arc4random_buf(reinterpret_cast<void*>(guest_buffer), length);
  }
  return static_cast<uint64_t>(length);
}

uint64_t handle_fstatfs(int fd, uint64_t guest_buffer) {
  if (guest_buffer == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }
  struct statfs host_stat {};
  if (::fstatfs(fd, &host_stat) != 0) {
    return linux_error_result();
  }

  auto* guest_stat = reinterpret_cast<LinuxStatFS*>(guest_buffer);
  *guest_stat = {};
  // Darwin doesn't expose Linux filesystem magic values. A zero type is the
  // kernel's "unknown" result and is safer than claiming a specific backend.
  guest_stat->block_size = static_cast<int64_t>(host_stat.f_bsize);
  guest_stat->blocks = static_cast<uint64_t>(host_stat.f_blocks);
  guest_stat->blocks_free = static_cast<uint64_t>(host_stat.f_bfree);
  guest_stat->blocks_available = static_cast<uint64_t>(host_stat.f_bavail);
  guest_stat->files = static_cast<uint64_t>(host_stat.f_files);
  guest_stat->files_free = static_cast<uint64_t>(host_stat.f_ffree);
  std::memcpy(guest_stat->fsid, &host_stat.f_fsid,
    std::min(sizeof(guest_stat->fsid), sizeof(host_stat.f_fsid)));
  guest_stat->name_length = 255;
  guest_stat->fragment_size = static_cast<int64_t>(host_stat.f_bsize);
  guest_stat->flags = static_cast<int64_t>(host_stat.f_flags);
  return 0;
}

uint64_t handle_ioctl(int fd, unsigned long guest_request, uint64_t guest_argument) {
  constexpr unsigned long kLinuxFSIOCGetFlags = 0x80086601UL;
  constexpr unsigned long kLinuxFIONRead = 0x541bUL;
  constexpr unsigned long kLinuxTIOCGWinSize = 0x5413UL;
  constexpr unsigned long kLinuxFIONBio = 0x5421UL;

  if (guest_request == kLinuxFSIOCGetFlags) {
    if (guest_argument == 0) return static_cast<uint64_t>(-EFAULT);
    *reinterpret_cast<uint32_t*>(guest_argument) = 0;
    return 0;
  }

  unsigned long host_request = 0;
  switch (guest_request) {
    case kLinuxFIONRead: host_request = FIONREAD; break;
    case kLinuxTIOCGWinSize: host_request = TIOCGWINSZ; break;
    case kLinuxFIONBio: host_request = FIONBIO; break;
    default: return static_cast<uint64_t>(-ENOTTY);
  }
  if (::ioctl(fd, host_request, reinterpret_cast<void*>(guest_argument)) != 0) {
    return linux_error_result();
  }
  return 0;
}

uint64_t unsupported_syscall() {
  return static_cast<uint64_t>(-kLinuxErrnoNoSys);
}

std::string path_for_fd(int fd) {
#if defined(__APPLE__)
  if (fd < 0) {
    return {};
  }

  char path[PATH_MAX] {};
  if (::fcntl(fd, F_GETPATH, path) == 0) {
    return path;
  }
#else
  (void)fd;
#endif

  return {};
}

uintptr_t host_signal_pc(void* raw_context) {
#if defined(__APPLE__) && defined(__aarch64__)
  auto* context = static_cast<ucontext_t*>(raw_context);
  return static_cast<uintptr_t>(context->uc_mcontext->__ss.__pc);
#elif defined(__APPLE__) && defined(__x86_64__)
  auto* context = static_cast<ucontext_t*>(raw_context);
  return static_cast<uintptr_t>(context->uc_mcontext->__ss.__rip);
#elif defined(__linux__) && defined(__x86_64__)
  auto* context = static_cast<ucontext_t*>(raw_context);
  return static_cast<uintptr_t>(context->uc_mcontext.gregs[REG_RIP]);
#elif defined(__linux__) && defined(__aarch64__)
  auto* context = static_cast<ucontext_t*>(raw_context);
  return static_cast<uintptr_t>(context->uc_mcontext.pc);
#else
  (void)raw_context;
  return 0;
#endif
}

void guest_execution_signal_handler(int signal_number, siginfo_t* info, void* raw_context) {
  if (guest_execution_signal_trap == nullptr) {
    std::signal(signal_number, SIG_DFL);
    std::raise(signal_number);
    return;
  }

  guest_execution_signal_trap->signal_number = signal_number;
  guest_execution_signal_trap->fault_address = reinterpret_cast<uintptr_t>(info != nullptr ? info->si_addr : nullptr);
  guest_execution_signal_trap->host_pc = host_signal_pc(raw_context);
  std::longjmp(guest_execution_signal_trap->jump_buffer, 1);
}

void install_guest_execution_signal_handler(int signal_number, struct sigaction* previous_action) {
  struct sigaction action {};
  sigemptyset(&action.sa_mask);
  action.sa_sigaction = guest_execution_signal_handler;
  action.sa_flags = SA_SIGINFO | SA_ONSTACK;
  sigaction(signal_number, &action, previous_action);
}

void restore_guest_execution_signal_handler(int signal_number, const struct sigaction* previous_action) {
  sigaction(signal_number, previous_action, nullptr);
}

void install_guest_execution_signal_handlers(GuestExecutionSignalTrap&) {
  const std::lock_guard<std::mutex> lock(guest_signal_handler_mutex);
  if (guest_signal_handler_users++ != 0) {
    return;
  }
  install_guest_execution_signal_handler(SIGSEGV, &guest_previous_segv);
  install_guest_execution_signal_handler(SIGBUS, &guest_previous_bus);
  install_guest_execution_signal_handler(SIGILL, &guest_previous_ill);
  install_guest_execution_signal_handler(SIGTRAP, &guest_previous_trap);
}

void restore_guest_execution_signal_handlers(const GuestExecutionSignalTrap&) {
  const std::lock_guard<std::mutex> lock(guest_signal_handler_mutex);
  if (guest_signal_handler_users == 0 || --guest_signal_handler_users != 0) {
    return;
  }
  restore_guest_execution_signal_handler(SIGTRAP, &guest_previous_trap);
  restore_guest_execution_signal_handler(SIGILL, &guest_previous_ill);
  restore_guest_execution_signal_handler(SIGBUS, &guest_previous_bus);
  restore_guest_execution_signal_handler(SIGSEGV, &guest_previous_segv);
}

uint64_t handle_iridium_spawn_host_wineserver(uint64_t guest_path, uint64_t debug_enabled) {
  if (const auto callback = embedded_wine_server_start.load(std::memory_order_acquire)) {
    char error_buffer[512] {};
    const int result = callback(debug_enabled != 0, error_buffer, sizeof(error_buffer));
    if (result == 0) {
      std::fprintf(stderr, "iridium-fex-ios: embedded Wine server is accepting clients\n");
      emit_runtime_milestone("wineServerReady");
      return 0;
    }

    const int error = result > 0 ? result : EIO;
    std::fprintf(
      stderr,
      "iridium-fex-ios: embedded Wine server startup failed errno=%d (%s)%s%s\n",
      error,
      std::strerror(error),
      error_buffer[0] != '\0' ? ": " : "",
      error_buffer
    );
    return static_cast<uint64_t>(-error);
  }

  if (guest_path == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }

  const char* path = reinterpret_cast<const char*>(guest_path);
  if (path[0] == '\0') {
    return static_cast<uint64_t>(-ENOENT);
  }

  std::array<char*, 3> argv {
    const_cast<char*>(path),
    debug_enabled != 0 ? const_cast<char*>("-d") : nullptr,
    nullptr,
  };
  if (debug_enabled == 0) {
    argv[1] = nullptr;
  }

  pid_t child_pid = -1;
  const int spawn_result = ::posix_spawn(&child_pid, path, nullptr, nullptr, argv.data(), host_environment());
  if (spawn_result != 0) {
    std::fprintf(
      stderr,
      "iridium-fex-ios: native Wine server helper spawn failed path=%s errno=%d (%s)\n",
      path,
      spawn_result,
      std::strerror(spawn_result)
    );
    return static_cast<uint64_t>(-spawn_result);
  }

  return static_cast<uint64_t>(child_pid);
}

}  // namespace

extern "C" void iridium_fex_ios_register_embedded_wine_server_start(
  IridiumFEXIOSEmbeddedWineServerStart callback
) {
  embedded_wine_server_start.store(callback, std::memory_order_release);
}

namespace {

[[noreturn]] void exit_guest_thread(int status) {
  guest_exit_status = status;
  if (guest_exit_trap != nullptr) {
    std::longjmp(*guest_exit_trap, 1);
  }
  _exit(status);
}

uint64_t current_thread_id() {
  if (guest_thread_identifier_override != 0) {
    return guest_thread_identifier_override;
  }
  uint64_t thread_id = 0;
  if (pthread_threadid_np(nullptr, &thread_id) != 0 || thread_id == 0) {
    return static_cast<uint64_t>(getpid());
  }
  return thread_id;
}

clockid_t darwin_clock_id(int guest_clock_id) {
  switch (guest_clock_id) {
    case kLinuxClockRealtime:
      return CLOCK_REALTIME;
    case kLinuxClockMonotonic:
      return CLOCK_MONOTONIC;
    default:
      errno = EINVAL;
      return static_cast<clockid_t>(-1);
  }
}

bool valid_timespec(const timespec& value) {
  return value.tv_sec >= 0 && value.tv_nsec >= 0 && value.tv_nsec < 1000000000L;
}

uint64_t handle_clock_nanosleep(
  int guest_clock_id,
  int guest_flags,
  uint64_t guest_request,
  uint64_t guest_remaining
) {
  if (guest_request == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }
  const auto& request = *reinterpret_cast<const timespec*>(guest_request);
  if (!valid_timespec(request) || (guest_flags & ~kLinuxTimerAbsolute) != 0) {
    return static_cast<uint64_t>(-EINVAL);
  }

  const clockid_t clock_id = darwin_clock_id(guest_clock_id);
  if (clock_id == static_cast<clockid_t>(-1)) {
    return linux_error_result();
  }
  if ((guest_flags & kLinuxTimerAbsolute) == 0) {
    auto* remaining = reinterpret_cast<timespec*>(guest_remaining);
    return ::nanosleep(&request, remaining) == 0 ? 0 : linux_error_result();
  }

  timespec now {};
  if (::clock_gettime(clock_id, &now) != 0) {
    return linux_error_result();
  }
  if (request.tv_sec < now.tv_sec ||
      (request.tv_sec == now.tv_sec && request.tv_nsec <= now.tv_nsec)) {
    return 0;
  }

  timespec delay {
    request.tv_sec - now.tv_sec,
    request.tv_nsec - now.tv_nsec,
  };
  if (delay.tv_nsec < 0) {
    --delay.tv_sec;
    delay.tv_nsec += 1000000000L;
  }
  return ::nanosleep(&delay, nullptr) == 0 ? 0 : linux_error_result();
}

uint64_t handle_sysinfo(uint64_t guest_buffer) {
  if (guest_buffer == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }

  timespec uptime {};
  if (::clock_gettime(CLOCK_MONOTONIC, &uptime) != 0) {
    return linux_error_result();
  }

  uint64_t total_memory = 0;
  uint64_t available_memory = 0;
#if defined(__APPLE__)
  size_t total_memory_size = sizeof(total_memory);
  if (::sysctlbyname("hw.memsize", &total_memory, &total_memory_size, nullptr, 0) != 0) {
    total_memory = 0;
  }

  const mach_port_t host = mach_host_self();
  vm_size_t page_size = 0;
  vm_statistics64_data_t statistics {};
  mach_msg_type_number_t statistics_count = HOST_VM_INFO64_COUNT;
  const kern_return_t page_size_result = ::host_page_size(host, &page_size);
  const kern_return_t statistics_result = ::host_statistics64(
    host,
    HOST_VM_INFO64,
    reinterpret_cast<host_info64_t>(&statistics),
    &statistics_count
  );
  ::mach_port_deallocate(mach_task_self(), host);
  if (page_size_result == KERN_SUCCESS && statistics_result == KERN_SUCCESS) {
    available_memory =
      (static_cast<uint64_t>(statistics.free_count) + statistics.inactive_count) * page_size;
    if (total_memory == 0) {
      total_memory =
        (static_cast<uint64_t>(statistics.free_count)
          + statistics.active_count
          + statistics.inactive_count
          + statistics.wire_count
          + statistics.compressor_page_count) * page_size;
    }
  }
#else
  const long page_size = ::sysconf(_SC_PAGESIZE);
  const long total_pages = ::sysconf(_SC_PHYS_PAGES);
  const long available_pages = ::sysconf(_SC_AVPHYS_PAGES);
  if (page_size > 0 && total_pages > 0) {
    total_memory = static_cast<uint64_t>(page_size) * static_cast<uint64_t>(total_pages);
  }
  if (page_size > 0 && available_pages > 0) {
    available_memory = static_cast<uint64_t>(page_size) * static_cast<uint64_t>(available_pages);
  }
#endif
  if (total_memory == 0) {
    total_memory = available_memory != 0 ? available_memory : 1;
  }
  available_memory = std::min(available_memory, total_memory);

  auto* guest_info = reinterpret_cast<LinuxSysInfo*>(guest_buffer);
  *guest_info = {};
  guest_info->uptime = uptime.tv_sec;
  guest_info->totalram = total_memory;
  guest_info->freeram = available_memory;
  guest_info->procs = 1;
  guest_info->mem_unit = 1;
  return 0;
}

void copy_linux_uts_field(char (&destination)[65], const char* source) {
  std::memset(destination, 0, sizeof(destination));
  std::strncpy(destination, source, sizeof(destination) - 1);
}

uint64_t handle_uname(uint64_t guest_buffer) {
  if (guest_buffer == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }

  auto* linux_uts = reinterpret_cast<LinuxUtsName*>(guest_buffer);
  utsname host_uts {};
  if (::uname(&host_uts) != 0) {
    return linux_error_result();
  }

  copy_linux_uts_field(linux_uts->sysname, "Linux");
  copy_linux_uts_field(linux_uts->nodename, host_uts.nodename);
  copy_linux_uts_field(linux_uts->release, "6.0.0-iridium-ios");
  copy_linux_uts_field(linux_uts->version, "Iridium FEX iOS syscall bridge");
  copy_linux_uts_field(linux_uts->machine, "x86_64");
  copy_linux_uts_field(linux_uts->domainname, "");
  return 0;
}

uint64_t handle_fcntl(int fd, int command, uint64_t value) {
  switch (command) {
    case kLinuxFGetFD: {
      const int result = ::fcntl(fd, F_GETFD);
      if (result < 0) {
        return linux_error_result();
      }
      return (result & FD_CLOEXEC) == FD_CLOEXEC ? kLinuxFDClOExec : 0;
    }
    case kLinuxFSetFD: {
      int flags = 0;
      if ((value & kLinuxFDClOExec) == kLinuxFDClOExec) {
        flags |= FD_CLOEXEC;
      }
      if (::fcntl(fd, F_SETFD, flags) != 0) {
        return linux_error_result();
      }
      return 0;
    }
    case kLinuxFGetFL: {
      const int result = ::fcntl(fd, F_GETFL);
      if (result < 0) {
        return linux_error_result();
      }
      return static_cast<uint64_t>(result);
    }
    case kLinuxFSetFL:
      if (::fcntl(fd, F_SETFL, static_cast<int>(value)) != 0) {
        return linux_error_result();
      }
      return 0;
    default:
      return static_cast<uint64_t>(-EINVAL);
  }
}

int darwin_socket_type(int guest_type) {
  if ((guest_type & kLinuxSockNonBlock) == kLinuxSockNonBlock) {
    guest_type &= ~kLinuxSockNonBlock;
  }
  if ((guest_type & kLinuxSockCloseOnExec) == kLinuxSockCloseOnExec) {
    guest_type &= ~kLinuxSockCloseOnExec;
  }

  switch (guest_type) {
    case kLinuxSockStream:
      return SOCK_STREAM;
    case kLinuxSockDgram:
      return SOCK_DGRAM;
#if defined(SOCK_SEQPACKET)
    case kLinuxSockSeqpacket:
      return SOCK_SEQPACKET;
#endif
    default:
      errno = EINVAL;
      return -1;
  }
}

uint64_t handle_socket(int guest_domain, int guest_type, int protocol) {
  int domain = 0;
  switch (guest_domain) {
    case kLinuxAfUnix:
      domain = AF_UNIX;
      break;
    default:
      return static_cast<uint64_t>(-EAFNOSUPPORT);
  }

  const int type = darwin_socket_type(guest_type);
  if (type < 0) {
    return linux_error_result();
  }

  const int result = ::socket(domain, type, protocol);
  if (result < 0) {
    return linux_error_result();
  }
  if ((guest_type & kLinuxSockCloseOnExec) == kLinuxSockCloseOnExec) {
    if (::fcntl(result, F_SETFD, FD_CLOEXEC) != 0) {
      const int saved_errno = errno;
      ::close(result);
      errno = saved_errno;
      return linux_error_result();
    }
  }
  if ((guest_type & kLinuxSockNonBlock) == kLinuxSockNonBlock) {
    const int flags = ::fcntl(result, F_GETFL);
    if (flags < 0 || ::fcntl(result, F_SETFL, flags | O_NONBLOCK) != 0) {
      const int saved_errno = errno;
      ::close(result);
      errno = saved_errno;
      return linux_error_result();
    }
  }
  return static_cast<uint64_t>(result);
}

uint64_t handle_socketpair(int guest_domain, int guest_type, int protocol, uint64_t guest_socketfds) {
  if (guest_socketfds == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }

  int domain = 0;
  switch (guest_domain) {
    case kLinuxAfUnix:
      domain = AF_UNIX;
      break;
    default:
      return static_cast<uint64_t>(-EAFNOSUPPORT);
  }

  const int type = darwin_socket_type(guest_type);
  if (type < 0) {
    return linux_error_result();
  }

  int fds[2] {-1, -1};
  if (::socketpair(domain, type, protocol, fds) != 0) {
    return linux_error_result();
  }

  auto close_socketpair_on_error = [&]() {
    const int saved_errno = errno;
    if (fds[0] >= 0) {
      ::close(fds[0]);
    }
    if (fds[1] >= 0) {
      ::close(fds[1]);
    }
    errno = saved_errno;
    return linux_error_result();
  };

  if ((guest_type & kLinuxSockCloseOnExec) == kLinuxSockCloseOnExec) {
    if (::fcntl(fds[0], F_SETFD, FD_CLOEXEC) != 0 || ::fcntl(fds[1], F_SETFD, FD_CLOEXEC) != 0) {
      return close_socketpair_on_error();
    }
  }
  if ((guest_type & kLinuxSockNonBlock) == kLinuxSockNonBlock) {
    const int left_flags = ::fcntl(fds[0], F_GETFL);
    const int right_flags = ::fcntl(fds[1], F_GETFL);
    if (
      left_flags < 0 ||
      right_flags < 0 ||
      ::fcntl(fds[0], F_SETFL, left_flags | O_NONBLOCK) != 0 ||
      ::fcntl(fds[1], F_SETFL, right_flags | O_NONBLOCK) != 0
    ) {
      return close_socketpair_on_error();
    }
  }

  auto* guest_fds = reinterpret_cast<int*>(guest_socketfds);
  guest_fds[0] = fds[0];
  guest_fds[1] = fds[1];
  return 0;
}

uint64_t handle_pipe(uint64_t guest_pipefds, int guest_flags) {
  if (guest_pipefds == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }

  int fds[2] {-1, -1};
  if (::pipe(fds) != 0) {
    return linux_error_result();
  }

  auto close_pipe_on_error = [&]() {
    const int saved_errno = errno;
    if (fds[0] >= 0) {
      ::close(fds[0]);
    }
    if (fds[1] >= 0) {
      ::close(fds[1]);
    }
    errno = saved_errno;
    return linux_error_result();
  };

  if ((guest_flags & kLinuxOCloExec) == kLinuxOCloExec) {
    if (::fcntl(fds[0], F_SETFD, FD_CLOEXEC) != 0 || ::fcntl(fds[1], F_SETFD, FD_CLOEXEC) != 0) {
      return close_pipe_on_error();
    }
    guest_flags &= ~kLinuxOCloExec;
  }
  if ((guest_flags & kLinuxOpenNonBlock) == kLinuxOpenNonBlock) {
    const int read_flags = ::fcntl(fds[0], F_GETFL);
    const int write_flags = ::fcntl(fds[1], F_GETFL);
    if (
      read_flags < 0 ||
      write_flags < 0 ||
      ::fcntl(fds[0], F_SETFL, read_flags | O_NONBLOCK) != 0 ||
      ::fcntl(fds[1], F_SETFL, write_flags | O_NONBLOCK) != 0
    ) {
      return close_pipe_on_error();
    }
    guest_flags &= ~kLinuxOpenNonBlock;
  }
  if (guest_flags != 0) {
    errno = EINVAL;
    return close_pipe_on_error();
  }

  auto* guest_fds = reinterpret_cast<int*>(guest_pipefds);
  guest_fds[0] = fds[0];
  guest_fds[1] = fds[1];
  return 0;
}

uint64_t handle_connect(int fd, uint64_t guest_address, uint64_t guest_length) {
  if (guest_address == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }
  if (guest_length < offsetof(LinuxSockAddrUnix, path)) {
    return static_cast<uint64_t>(-EINVAL);
  }

  const auto* guest_sockaddr = reinterpret_cast<const LinuxSockAddrUnix*>(guest_address);
  if (guest_sockaddr->family != kLinuxAfUnix) {
    return static_cast<uint64_t>(-EAFNOSUPPORT);
  }

  const size_t guest_path_capacity = static_cast<size_t>(guest_length) - offsetof(LinuxSockAddrUnix, path);
  const size_t bounded_path_capacity = std::min(guest_path_capacity, sizeof(guest_sockaddr->path));
  const void* nul = std::memchr(guest_sockaddr->path, '\0', bounded_path_capacity);
  const size_t path_length = nul != nullptr
    ? static_cast<size_t>(static_cast<const char*>(nul) - guest_sockaddr->path)
    : bounded_path_capacity;
  if (path_length == 0 || path_length >= sizeof(sockaddr_un::sun_path)) {
    return static_cast<uint64_t>(path_length == 0 ? -EPROTONOSUPPORT : -ENAMETOOLONG);
  }

  sockaddr_un host_sockaddr {};
  host_sockaddr.sun_family = AF_UNIX;
  std::memcpy(host_sockaddr.sun_path, guest_sockaddr->path, path_length);
  host_sockaddr.sun_path[path_length] = '\0';
#if defined(__APPLE__)
  host_sockaddr.sun_len = static_cast<unsigned char>(SUN_LEN(&host_sockaddr));
#endif

  socklen_t host_length = static_cast<socklen_t>(SUN_LEN(&host_sockaddr));
  if (::connect(fd, reinterpret_cast<const sockaddr*>(&host_sockaddr), host_length) != 0) {
    return linux_error_result();
  }
  return 0;
}

constexpr size_t align_linux_cmsg(size_t value) {
  return (value + sizeof(uint64_t) - 1) & ~(sizeof(uint64_t) - 1);
}

int darwin_msg_flags(int guest_flags, bool receiving) {
  guest_flags &= ~kLinuxMsgNosignal;
  if (receiving) {
    guest_flags &= ~kLinuxMsgCmsgCloexec;
  }
  return guest_flags;
}

bool append_host_rights_control(
  std::vector<char>& storage,
  const int* fds,
  size_t fd_count
) {
  const size_t data_size = fd_count * sizeof(int);
  const size_t old_size = storage.size();
  const size_t aligned_old_size = CMSG_SPACE(old_size) == 0 ? old_size : align_linux_cmsg(old_size);
  if (aligned_old_size > old_size) {
    storage.resize(aligned_old_size);
  }
  const size_t message_size = CMSG_SPACE(data_size);
  storage.resize(storage.size() + message_size);
  auto* header = reinterpret_cast<cmsghdr*>(storage.data() + storage.size() - message_size);
  header->cmsg_len = static_cast<decltype(header->cmsg_len)>(CMSG_LEN(data_size));
  header->cmsg_level = SOL_SOCKET;
  header->cmsg_type = SCM_RIGHTS;
  std::memcpy(CMSG_DATA(header), fds, data_size);
  return storage.size() >= old_size;
}

bool translate_linux_control_to_host(const LinuxMsgHdr& guest_msg, std::vector<char>& host_control) {
  if (guest_msg.control == 0 || guest_msg.control_length == 0) {
    return true;
  }

  size_t offset = 0;
  const auto* control = reinterpret_cast<const char*>(guest_msg.control);
  while (offset + sizeof(LinuxCmsghdr) <= guest_msg.control_length) {
    const auto* linux_header = reinterpret_cast<const LinuxCmsghdr*>(control + offset);
    if (linux_header->length < sizeof(LinuxCmsghdr) || offset + linux_header->length > guest_msg.control_length) {
      errno = EINVAL;
      return false;
    }
    if (linux_header->level == kLinuxSolSocket && linux_header->type == kLinuxScmRights) {
      const size_t data_size = static_cast<size_t>(linux_header->length) - sizeof(LinuxCmsghdr);
      if ((data_size % sizeof(int)) != 0) {
        errno = EINVAL;
        return false;
      }
      const auto* fds = reinterpret_cast<const int*>(control + offset + sizeof(LinuxCmsghdr));
      append_host_rights_control(host_control, fds, data_size / sizeof(int));
    }
    offset += align_linux_cmsg(static_cast<size_t>(linux_header->length));
  }
  return true;
}

void translate_host_control_to_linux(
  const msghdr& host_msg,
  LinuxMsgHdr& guest_msg,
  bool close_on_exec
) {
  if (guest_msg.control == 0 || guest_msg.control_length == 0) {
    guest_msg.control_length = 0;
    return;
  }

  auto* guest_control = reinterpret_cast<char*>(guest_msg.control);
  const size_t guest_capacity = static_cast<size_t>(guest_msg.control_length);
  size_t guest_used = 0;
  int flags = guest_msg.flags;

  for (cmsghdr* host_header = CMSG_FIRSTHDR(const_cast<msghdr*>(&host_msg));
       host_header != nullptr;
       host_header = CMSG_NXTHDR(const_cast<msghdr*>(&host_msg), host_header)) {
    if (host_header->cmsg_level != SOL_SOCKET || host_header->cmsg_type != SCM_RIGHTS) {
      continue;
    }

    const size_t data_size = static_cast<size_t>(host_header->cmsg_len) - CMSG_LEN(0);
    const size_t linux_length = sizeof(LinuxCmsghdr) + data_size;
    const size_t linux_space = align_linux_cmsg(linux_length);
    if (guest_used + linux_space > guest_capacity) {
      flags |= kLinuxMsgCtrunc;
      break;
    }

    auto* linux_header = reinterpret_cast<LinuxCmsghdr*>(guest_control + guest_used);
    linux_header->length = linux_length;
    linux_header->level = kLinuxSolSocket;
    linux_header->type = kLinuxScmRights;
    std::memcpy(guest_control + guest_used + sizeof(LinuxCmsghdr), CMSG_DATA(host_header), data_size);
    if (close_on_exec) {
      auto* fds = reinterpret_cast<int*>(guest_control + guest_used + sizeof(LinuxCmsghdr));
      for (size_t index = 0; index < data_size / sizeof(int); ++index) {
        ::fcntl(fds[index], F_SETFD, FD_CLOEXEC);
      }
    }
    if (linux_space > linux_length) {
      std::memset(guest_control + guest_used + linux_length, 0, linux_space - linux_length);
    }
    guest_used += linux_space;
  }

  guest_msg.control_length = guest_used;
  guest_msg.flags = flags;
}

uint64_t handle_sendmsg(int fd, uint64_t guest_message, int guest_flags) {
  if (guest_message == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }

  auto* guest_msg = reinterpret_cast<LinuxMsgHdr*>(guest_message);
  if (guest_msg->iov_length > static_cast<uint64_t>(INT_MAX)) {
    return static_cast<uint64_t>(-EINVAL);
  }

  std::vector<char> host_control;
  if (!translate_linux_control_to_host(*guest_msg, host_control)) {
    return linux_error_result();
  }

  msghdr host_msg {};
  host_msg.msg_name = reinterpret_cast<void*>(guest_msg->name);
  host_msg.msg_namelen = static_cast<socklen_t>(guest_msg->name_length);
  host_msg.msg_iov = reinterpret_cast<iovec*>(guest_msg->iov);
  host_msg.msg_iovlen = static_cast<decltype(host_msg.msg_iovlen)>(guest_msg->iov_length);
  host_msg.msg_control = host_control.empty() ? nullptr : host_control.data();
  host_msg.msg_controllen = static_cast<decltype(host_msg.msg_controllen)>(host_control.size());

  const ssize_t result = ::sendmsg(fd, &host_msg, darwin_msg_flags(guest_flags, false));
  if (result < 0) {
    return linux_error_result();
  }
  return static_cast<uint64_t>(result);
}

uint64_t handle_recvmsg(int fd, uint64_t guest_message, int guest_flags) {
  if (guest_message == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }

  auto* guest_msg = reinterpret_cast<LinuxMsgHdr*>(guest_message);
  if (guest_msg->iov_length > static_cast<uint64_t>(INT_MAX)) {
    return static_cast<uint64_t>(-EINVAL);
  }

  std::vector<char> host_control;
  if (guest_msg->control != 0 && guest_msg->control_length != 0) {
    host_control.resize(static_cast<size_t>(guest_msg->control_length));
  }

  msghdr host_msg {};
  host_msg.msg_name = reinterpret_cast<void*>(guest_msg->name);
  host_msg.msg_namelen = static_cast<socklen_t>(guest_msg->name_length);
  host_msg.msg_iov = reinterpret_cast<iovec*>(guest_msg->iov);
  host_msg.msg_iovlen = static_cast<decltype(host_msg.msg_iovlen)>(guest_msg->iov_length);
  host_msg.msg_control = host_control.empty() ? nullptr : host_control.data();
  host_msg.msg_controllen = static_cast<decltype(host_msg.msg_controllen)>(host_control.size());

  const bool close_on_exec = (guest_flags & kLinuxMsgCmsgCloexec) == kLinuxMsgCmsgCloexec;
  const ssize_t result = ::recvmsg(fd, &host_msg, darwin_msg_flags(guest_flags, true));
  if (result < 0) {
    return linux_error_result();
  }

  guest_msg->name_length = host_msg.msg_namelen;
  guest_msg->flags = host_msg.msg_flags;
  translate_host_control_to_linux(host_msg, *guest_msg, close_on_exec);
  return static_cast<uint64_t>(result);
}

uint64_t handle_setsockopt(int fd, int level, int option, uint64_t value, uint64_t length) {
  if (level == kLinuxSolSocket && option == kLinuxSoPassCred) {
    return 0;
  }
  const int result = ::setsockopt(
    fd,
    level,
    option,
    reinterpret_cast<const void*>(value),
    static_cast<socklen_t>(length)
  );
  if (result != 0) {
    return linux_error_result();
  }
  return 0;
}

void pack_linux_stat(const struct stat& host_stat, LinuxStat& linux_stat) {
  std::memset(&linux_stat, 0, sizeof(linux_stat));
  linux_stat.dev = static_cast<uint64_t>(host_stat.st_dev);
  linux_stat.ino = static_cast<uint64_t>(host_stat.st_ino);
  linux_stat.nlink = static_cast<uint64_t>(host_stat.st_nlink);
  linux_stat.mode = static_cast<uint32_t>(host_stat.st_mode);
  linux_stat.uid = static_cast<uint32_t>(host_stat.st_uid);
  linux_stat.gid = static_cast<uint32_t>(host_stat.st_gid);
  linux_stat.rdev = static_cast<uint64_t>(host_stat.st_rdev);
  linux_stat.size = static_cast<int64_t>(host_stat.st_size);
  linux_stat.blksize = static_cast<int64_t>(host_stat.st_blksize);
  linux_stat.blocks = static_cast<int64_t>(host_stat.st_blocks);
  linux_stat.atime_sec = static_cast<int64_t>(host_stat.st_atimespec.tv_sec);
  linux_stat.atime_nsec = static_cast<int64_t>(host_stat.st_atimespec.tv_nsec);
  linux_stat.mtime_sec = static_cast<int64_t>(host_stat.st_mtimespec.tv_sec);
  linux_stat.mtime_nsec = static_cast<int64_t>(host_stat.st_mtimespec.tv_nsec);
  linux_stat.ctime_sec = static_cast<int64_t>(host_stat.st_ctimespec.tv_sec);
  linux_stat.ctime_nsec = static_cast<int64_t>(host_stat.st_ctimespec.tv_nsec);
}

uint64_t write_linux_stat(const struct stat& host_stat, uint64_t guest_buffer) {
  if (guest_buffer == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }

  auto* linux_stat = reinterpret_cast<LinuxStat*>(guest_buffer);
  pack_linux_stat(host_stat, *linux_stat);
  return 0;
}

int darwin_fstatat_flags(int guest_flags) {
  int flags = 0;
  if ((guest_flags & kLinuxAtSymlinkNoFollow) == kLinuxAtSymlinkNoFollow) {
#if defined(AT_SYMLINK_NOFOLLOW)
    flags |= AT_SYMLINK_NOFOLLOW;
#else
    errno = EINVAL;
    return -1;
#endif
  }

  guest_flags &= ~(kLinuxAtSymlinkNoFollow | kLinuxAtEmptyPath);
  if (guest_flags != 0) {
    errno = EINVAL;
    return -1;
  }
  return flags;
}

size_t align_linux_dirent64_record(size_t size) {
  return (size + 7) & ~static_cast<size_t>(7);
}

uint8_t linux_dirent_type(uint8_t host_type) {
  switch (host_type) {
    case DT_FIFO:
      return 1;
    case DT_CHR:
      return 2;
    case DT_DIR:
      return 4;
    case DT_BLK:
      return 6;
    case DT_REG:
      return 8;
    case DT_LNK:
      return 10;
    case DT_SOCK:
      return 12;
    default:
      return 0;
  }
}

uint64_t handle_getdents64(int fd, uint64_t guest_buffer, size_t count) {
  if (guest_buffer == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }
  if (count < kLinuxDirent64NameOffset + 2) {
    return static_cast<uint64_t>(-EINVAL);
  }

  const int dup_fd = ::fcntl(fd, F_DUPFD_CLOEXEC, 0);
  if (dup_fd < 0) {
    return linux_error_result();
  }

  DIR* directory = ::fdopendir(dup_fd);
  if (directory == nullptr) {
    const int saved_errno = errno;
    ::close(dup_fd);
    errno = saved_errno;
    return linux_error_result();
  }

  auto* output = reinterpret_cast<char*>(guest_buffer);
  size_t written = 0;
  errno = 0;

  while (dirent* entry = ::readdir(directory)) {
    const size_t name_length = std::strlen(entry->d_name);
    const size_t record_length = align_linux_dirent64_record(kLinuxDirent64NameOffset + name_length + 1);
    if (record_length > count - written) {
      break;
    }

    char* record = output + written;
    std::memset(record, 0, record_length);

    const uint64_t inode = static_cast<uint64_t>(entry->d_ino);
    const int64_t offset = static_cast<int64_t>(::telldir(directory));
    const uint16_t linux_record_length = static_cast<uint16_t>(record_length);
    const uint8_t type = linux_dirent_type(entry->d_type);

    std::memcpy(record, &inode, sizeof(inode));
    std::memcpy(record + 8, &offset, sizeof(offset));
    std::memcpy(record + 16, &linux_record_length, sizeof(linux_record_length));
    std::memcpy(record + 18, &type, sizeof(type));
    std::memcpy(record + kLinuxDirent64NameOffset, entry->d_name, name_length + 1);

    written += record_length;
  }

  const int saved_errno = errno;
  ::closedir(directory);
  if (saved_errno != 0) {
    errno = saved_errno;
    return linux_error_result();
  }

  return static_cast<uint64_t>(written);
}

uint64_t handle_futex(uint64_t guest_uaddr, int guest_operation, uint32_t expected_value, uint64_t guest_timeout) {
  if (guest_uaddr == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }

  const int operation = guest_operation & kLinuxFutexCommandMask;
  auto* futex_word = reinterpret_cast<const uint32_t*>(guest_uaddr);
  const auto load_word = [futex_word]() {
    return __atomic_load_n(futex_word, __ATOMIC_SEQ_CST);
  };

  switch (operation) {
    case kLinuxFutexWait:
    case kLinuxFutexWaitBitset: {
      std::unique_lock<std::mutex> lock(futex_wait_mutex);
      if (load_word() != expected_value) {
        return static_cast<uint64_t>(-EAGAIN);
      }

      const uint64_t observed_generation = futex_wake_generation;
      const auto predicate = [&]() {
        return load_word() != expected_value || futex_wake_generation != observed_generation;
      };
      if (guest_timeout != 0) {
        const auto* timeout = reinterpret_cast<const timespec*>(guest_timeout);
        if (timeout->tv_sec < 0 || timeout->tv_nsec < 0 || timeout->tv_nsec >= 1000000000L) {
          return static_cast<uint64_t>(-EINVAL);
        }
        auto duration = std::chrono::seconds(timeout->tv_sec)
          + std::chrono::nanoseconds(timeout->tv_nsec);
        if (operation == kLinuxFutexWaitBitset) {
          timespec now {};
          const clockid_t clock = (guest_operation & kLinuxFutexClockRealtime) != 0
            ? CLOCK_REALTIME
            : CLOCK_MONOTONIC;
          if (::clock_gettime(clock, &now) != 0) {
            return linux_error_result();
          }
          const auto current = std::chrono::seconds(now.tv_sec)
            + std::chrono::nanoseconds(now.tv_nsec);
          duration -= current;
          if (duration <= std::chrono::nanoseconds::zero()) {
            return static_cast<uint64_t>(-ETIMEDOUT);
          }
        }
        if (!futex_wait_condition.wait_for(lock, duration, predicate)) {
          return static_cast<uint64_t>(-ETIMEDOUT);
        }
      } else {
        futex_wait_condition.wait(lock, predicate);
      }
      return 0;
    }
    case kLinuxFutexWake:
    case kLinuxFutexWakeBitset: {
      const int requested_count = static_cast<int>(expected_value);
      if (requested_count <= 0) {
        return 0;
      }
      {
        const std::lock_guard<std::mutex> lock(futex_wait_mutex);
        ++futex_wake_generation;
      }
      futex_wait_condition.notify_all();
      return static_cast<uint64_t>(requested_count);
    }
    default:
      return static_cast<uint64_t>(-ENOSYS);
  }
}

uint64_t handle_sched_getaffinity(uint64_t guest_size, uint64_t guest_mask) {
  if (guest_mask == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }
  if (guest_size < sizeof(uint64_t)) {
    return static_cast<uint64_t>(-EINVAL);
  }

  auto* mask = reinterpret_cast<uint64_t*>(guest_mask);
  *mask = 1;
  return sizeof(uint64_t);
}

uint64_t handle_getcpu(uint64_t guest_cpu, uint64_t guest_node) {
  if (guest_cpu != 0) {
    *reinterpret_cast<uint32_t*>(guest_cpu) = 0;
  }
  if (guest_node != 0) {
    *reinterpret_cast<uint32_t*>(guest_node) = 0;
  }
  return 0;
}

uint64_t handle_rseq(uint64_t guest_rseq, uint64_t guest_rseq_length, uint64_t flags) {
  if (guest_rseq == 0) {
    return static_cast<uint64_t>(-EFAULT);
  }
  if (guest_rseq_length < sizeof(LinuxRseqArea) || flags != 0) {
    return static_cast<uint64_t>(-EINVAL);
  }

  auto* rseq = reinterpret_cast<LinuxRseqArea*>(guest_rseq);
  rseq->cpu_id_start = 0;
  rseq->cpu_id = 0;
  rseq->rseq_cs = 0;
  rseq->flags = 0;
  return 0;
}

int darwin_rlimit_resource(int linux_resource) {
  switch (linux_resource) {
    case 0:
      return RLIMIT_CPU;
    case 1:
      return RLIMIT_FSIZE;
    case 2:
      return RLIMIT_DATA;
    case 3:
      return RLIMIT_STACK;
    case 4:
      return RLIMIT_CORE;
#if defined(RLIMIT_RSS)
    case 5:
      return RLIMIT_RSS;
#endif
    case 7:
      return RLIMIT_NOFILE;
#if defined(RLIMIT_MEMLOCK)
    case 8:
      return RLIMIT_MEMLOCK;
#endif
#if defined(RLIMIT_AS)
    case 9:
      return RLIMIT_AS;
#endif
    default:
      errno = EINVAL;
      return -1;
  }
}

uint64_t linux_rlimit_value(rlim_t value) {
  if (value == RLIM_INFINITY) {
    return UINT64_MAX;
  }
  return static_cast<uint64_t>(value);
}

uint64_t handle_prlimit64(uint64_t guest_pid, int linux_resource, uint64_t guest_new_limit, uint64_t guest_old_limit) {
  if (guest_pid != 0 && guest_pid != static_cast<uint64_t>(::getpid())) {
    return static_cast<uint64_t>(-ESRCH);
  }
  if (guest_new_limit != 0) {
    return static_cast<uint64_t>(-EPERM);
  }

  const int host_resource = darwin_rlimit_resource(linux_resource);
  if (host_resource < 0) {
    return linux_error_result();
  }

  struct rlimit host_limit {};
  if (::getrlimit(host_resource, &host_limit) != 0) {
    return linux_error_result();
  }

  if (guest_old_limit != 0) {
    auto* linux_limit = reinterpret_cast<LinuxRLimit64*>(guest_old_limit);
    linux_limit->current = linux_rlimit_value(host_limit.rlim_cur);
    linux_limit->maximum = linux_rlimit_value(host_limit.rlim_max);
  }

  return 0;
}

uint64_t handle_rt_sigaction(
  int signal,
  uint64_t guest_action,
  uint64_t guest_old_action,
  size_t sigset_size,
  std::array<MinimalDarwinSyscallHandler::GuestSignalAction, 65>& actions
) {
  if (sigset_size != kLinuxX64SigsetSize) {
    return static_cast<uint64_t>(-EINVAL);
  }
  if (signal <= 0 || signal > kLinuxSignalMax) {
    return static_cast<uint64_t>(-EINVAL);
  }

  if (guest_old_action != 0) {
    *reinterpret_cast<LinuxKernelSigAction*>(guest_old_action) = {
      actions[signal].handler,
      actions[signal].flags,
      actions[signal].restorer,
      actions[signal].mask,
    };
  }

  if (guest_action != 0) {
    const auto* action = reinterpret_cast<const LinuxKernelSigAction*>(guest_action);
    actions[signal] = {
      action->handler,
      action->flags,
      action->restorer,
      action->mask,
    };
  }

  return 0;
}

uint64_t handle_rt_sigprocmask(int how, uint64_t guest_set, uint64_t guest_old_set, size_t sigset_size, uint64_t& mask) {
  if (sigset_size != kLinuxX64SigsetSize) {
    return static_cast<uint64_t>(-EINVAL);
  }

  if (guest_old_set != 0) {
    *reinterpret_cast<uint64_t*>(guest_old_set) = mask;
  }

  if (guest_set == 0) {
    return 0;
  }

  const uint64_t requested_mask = *reinterpret_cast<const uint64_t*>(guest_set);
  switch (how) {
    case kLinuxRtSignalBlock:
      mask |= requested_mask;
      return 0;
    case kLinuxRtSignalUnblock:
      mask &= ~requested_mask;
      return 0;
    case kLinuxRtSignalSetMask:
      mask = requested_mask;
      return 0;
    default:
      return static_cast<uint64_t>(-EINVAL);
  }
}

uint64_t handle_sigaltstack(
  uint64_t guest_new_stack,
  uint64_t guest_old_stack,
  uint64_t& stack_pointer,
  uint64_t& stack_size,
  int32_t& stack_flags
) {
  if (guest_old_stack != 0) {
    *reinterpret_cast<LinuxStackT*>(guest_old_stack) = {
      stack_pointer,
      stack_flags,
      0,
      stack_size,
    };
  }

  if (guest_new_stack != 0) {
    const auto* requested_stack = reinterpret_cast<const LinuxStackT*>(guest_new_stack);
    constexpr int kLinuxSSDisable = 2;
    if ((requested_stack->flags & ~kLinuxSSDisable) != 0) {
      return static_cast<uint64_t>(-EINVAL);
    }
    stack_pointer = requested_stack->stack_pointer;
    stack_size = requested_stack->size;
    stack_flags = requested_stack->flags;
  }

  return 0;
}

std::string translate_guest_path(const char* path) {
  if (path == nullptr) {
    return {};
  }
  if (path[0] != '/') {
    return path;
  }

  const char* userland_root = std::getenv("IRIDIUM_USERLAND_ROOT");
  if (userland_root == nullptr || userland_root[0] == '\0') {
    return path;
  }

  std::string translated = userland_root;
  if (!translated.empty() && translated.back() == '/') {
    translated.pop_back();
  }
  translated += path;
  return ::access(translated.c_str(), F_OK) == 0 ? translated : std::string(path);
}

int darwin_mmap_flags(int guest_flags) {
  int flags = 0;
  if ((guest_flags & kLinuxMapShared) == kLinuxMapShared) {
    flags |= MAP_SHARED;
  }
  if ((guest_flags & kLinuxMapPrivate) == kLinuxMapPrivate) {
    flags |= MAP_PRIVATE;
  }
  if ((guest_flags & kLinuxMapFixed) == kLinuxMapFixed) {
    flags |= MAP_FIXED;
  }
  if ((guest_flags & kLinuxMapAnonymous) == kLinuxMapAnonymous) {
    flags |= MAP_ANONYMOUS;
  }
  if ((guest_flags & kLinuxMapFixedNoReplace) == kLinuxMapFixedNoReplace) {
#if defined(MAP_FIXED_NOREPLACE)
    flags |= MAP_FIXED_NOREPLACE;
#else
    // Darwin has no no-replace flag. Use an address hint and check the result;
    // MAP_FIXED would silently destroy an existing guest allocation.
    flags &= ~MAP_FIXED;
#endif
  }

  // Linux-only advisory flags used by Wine's preloader do not have Darwin
  // equivalents for this anonymous/file mapping stage.
  guest_flags &= ~(kLinuxMapShared | kLinuxMapPrivate | kLinuxMapFixed | kLinuxMapAnonymous |
                   kLinuxMapDenyWrite | kLinuxMapExecutable | kLinuxMapNoReserve |
                   kLinuxMapStack | kLinuxMapFixedNoReplace);
  if (guest_flags != 0) {
    errno = EINVAL;
    return -1;
  }

  return flags;
}

int darwin_guest_memory_protection(int guest_protection) {
  return guest_protection & ~PROT_EXEC;
}

bool ranges_overlap(uintptr_t first_start, uintptr_t first_length, uintptr_t second_start, uintptr_t second_length) {
  if (first_length == 0 || second_length == 0) {
    return false;
  }
  const uintptr_t first_end = first_start + first_length;
  const uintptr_t second_end = second_start + second_length;
  if (first_end < first_start || second_end < second_start) {
    return true;
  }
  return first_start < second_end && second_start < first_end;
}

bool fixed_mapping_overlaps_host_image(void* address, size_t length) {
#if defined(__APPLE__)
  const auto mapping_start = reinterpret_cast<uintptr_t>(address);
  const auto mapping_length = static_cast<uintptr_t>(length);
  const uint32_t image_count = _dyld_image_count();
  for (uint32_t image_index = 0; image_index < image_count; ++image_index) {
    const auto* header = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(image_index));
    if (header == nullptr || header->magic != MH_MAGIC_64) {
      continue;
    }
    const intptr_t slide = _dyld_get_image_vmaddr_slide(image_index);
    auto* command = reinterpret_cast<const uint8_t*>(header) + sizeof(mach_header_64);
    for (uint32_t command_index = 0; command_index < header->ncmds; ++command_index) {
      const auto* load_command = reinterpret_cast<const struct load_command*>(command);
      if (load_command->cmd == LC_SEGMENT_64 && load_command->cmdsize >= sizeof(segment_command_64)) {
        const auto* segment = reinterpret_cast<const segment_command_64*>(command);
        // Mach-O __PAGEZERO describes an intentionally inaccessible address
        // range; it is not a VM mapping owned by the host process. Treating it
        // as a mapped image segment rejects every low fixed guest allocation
        // Wine probes on Darwin (commonly the entire first 4 GiB).
        if (segment->maxprot == VM_PROT_NONE) {
          command += load_command->cmdsize;
          continue;
        }
        const auto segment_start = static_cast<uintptr_t>(segment->vmaddr + slide);
        const auto segment_length = static_cast<uintptr_t>(segment->vmsize);
        if (ranges_overlap(mapping_start, mapping_length, segment_start, segment_length)) {
          return true;
        }
      }
      if (load_command->cmdsize == 0) {
        break;
      }
      command += load_command->cmdsize;
    }
  }
#else
  (void)address;
  (void)length;
#endif
  return false;
}

struct GuestMappingRange {
  uintptr_t start {};
  uintptr_t length {};
};

std::mutex guest_mapping_mutex;
std::vector<GuestMappingRange> guest_mappings;
uintptr_t guest_fixed_mapping_reservation_start {};
uintptr_t guest_fixed_mapping_reservation_length {};

uintptr_t range_end(uintptr_t start, uintptr_t length) {
  const uintptr_t end = start + length;
  return end < start ? UINTPTR_MAX : end;
}

uintptr_t host_page_size() {
  const long page_size = ::sysconf(_SC_PAGESIZE);
  return page_size > 0 ? static_cast<uintptr_t>(page_size) : static_cast<uintptr_t>(0x1000);
}

GuestMappingRange host_page_aligned_range(void* address, size_t length) {
  const uintptr_t page_size = host_page_size();
  const uintptr_t start = reinterpret_cast<uintptr_t>(address);
  const uintptr_t end = range_end(start, static_cast<uintptr_t>(length));
  const uintptr_t aligned_start = start & ~(page_size - 1);
  const uintptr_t aligned_end = (end + page_size - 1) & ~(page_size - 1);
  return {aligned_start, aligned_end - aligned_start};
}

bool guest_mapping_contains_locked(uintptr_t start, uintptr_t length) {
  const uintptr_t end = range_end(start, length);
  for (const auto& mapping : guest_mappings) {
    const uintptr_t mapping_end = range_end(mapping.start, mapping.length);
    if (mapping.start <= start && end <= mapping_end) {
      return true;
    }
  }
  return false;
}

bool guest_fixed_mapping_reservation_contains_locked(uintptr_t start, uintptr_t length) {
  if (guest_fixed_mapping_reservation_length == 0) {
    return false;
  }
  const uintptr_t end = range_end(start, length);
  const uintptr_t reservation_end = range_end(
    guest_fixed_mapping_reservation_start,
    guest_fixed_mapping_reservation_length
  );
  return guest_fixed_mapping_reservation_start <= start && end <= reservation_end;
}

bool guest_mapping_contains(uintptr_t start, uintptr_t length) {
  std::lock_guard<std::mutex> lock(guest_mapping_mutex);
  return guest_mapping_contains_locked(start, length) ||
         guest_fixed_mapping_reservation_contains_locked(start, length);
}

void record_guest_mapping(void* address, size_t length) {
  if (address == MAP_FAILED || address == nullptr || length == 0) {
    return;
  }

  const GuestMappingRange aligned_range = host_page_aligned_range(address, length);
  std::lock_guard<std::mutex> lock(guest_mapping_mutex);
  guest_mappings.push_back(aligned_range);
  std::sort(guest_mappings.begin(), guest_mappings.end(), [](const auto& lhs, const auto& rhs) {
    return lhs.start < rhs.start;
  });

  std::vector<GuestMappingRange> merged;
  for (const auto& mapping : guest_mappings) {
    if (merged.empty()) {
      merged.push_back(mapping);
      continue;
    }

    auto& previous = merged.back();
    const uintptr_t previous_end = range_end(previous.start, previous.length);
    const uintptr_t mapping_end = range_end(mapping.start, mapping.length);
    if (mapping.start <= previous_end) {
      previous.length = range_end(previous.start, std::max(previous_end, mapping_end) - previous.start) - previous.start;
    } else {
      merged.push_back(mapping);
    }
  }
  guest_mappings = std::move(merged);
}

void forget_guest_mapping(void* address, size_t length) {
  if (address == nullptr || length == 0) {
    return;
  }

  const GuestMappingRange aligned_range = host_page_aligned_range(address, length);
  const uintptr_t start = aligned_range.start;
  const uintptr_t end = range_end(start, aligned_range.length);
  std::lock_guard<std::mutex> lock(guest_mapping_mutex);
  std::vector<GuestMappingRange> updated;
  for (const auto& mapping : guest_mappings) {
    const uintptr_t mapping_end = range_end(mapping.start, mapping.length);
    if (!ranges_overlap(start, aligned_range.length, mapping.start, mapping.length)) {
      updated.push_back(mapping);
      continue;
    }
    if (mapping.start < start) {
      updated.push_back({mapping.start, start - mapping.start});
    }
    if (end < mapping_end) {
      updated.push_back({end, mapping_end - end});
    }
  }
  guest_mappings = std::move(updated);
}

bool fixed_mapping_overlaps_host_vm_region(
  uintptr_t start,
  uintptr_t length,
  uintptr_t* overlapping_start = nullptr,
  uintptr_t* overlapping_length = nullptr
) {
#if defined(__APPLE__)
  const uintptr_t end = range_end(start, length);
  vm_address_t query_address = static_cast<vm_address_t>(start);
  natural_t depth = 0;
  while (query_address < end) {
    vm_address_t region_address = query_address;
    vm_size_t region_size = 0;
    vm_region_submap_info_data_64_t info {};
    mach_msg_type_number_t info_count = VM_REGION_SUBMAP_INFO_COUNT_64;
    const kern_return_t result = vm_region_recurse_64(
      mach_task_self(),
      &region_address,
      &region_size,
      &depth,
      reinterpret_cast<vm_region_recurse_info_t>(&info),
      &info_count
    );
    if (result != KERN_SUCCESS || region_size == 0) {
      return false;
    }

    if (region_address >= end) {
      return false;
    }
    // A submap is a container in the task's VM hierarchy, not proof that the
    // entire container range is occupied. iOS uses broad submaps around the
    // shared region; treating the container as a leaf falsely rejected Wine's
    // otherwise-free fixed x64 address reservations. Descend until a real VM
    // region is returned.
    if (info.is_submap) {
      query_address = region_address;
      ++depth;
      continue;
    }
    if (ranges_overlap(start, length, static_cast<uintptr_t>(region_address), static_cast<uintptr_t>(region_size))) {
      if (overlapping_start != nullptr) {
        *overlapping_start = static_cast<uintptr_t>(region_address);
      }
      if (overlapping_length != nullptr) {
        *overlapping_length = static_cast<uintptr_t>(region_size);
      }
      return true;
    }

    const vm_address_t next_address = region_address + region_size;
    if (next_address <= query_address) {
      return true;
    }
    query_address = next_address;
  }
#else
  (void)start;
  (void)length;
  (void)overlapping_start;
  (void)overlapping_length;
#endif
  return false;
}

bool fixed_mapping_is_allowed(void* address, size_t length) {
  if (address == nullptr) {
    return true;
  }

  const auto mapping_start = reinterpret_cast<uintptr_t>(address);
  const auto mapping_length = static_cast<uintptr_t>(length);
  if (fixed_mapping_overlaps_host_image(address, length)) {
    errno = ENOMEM;
    std::fprintf(
      stderr,
      "[IridiumFEX:mmap] denied fixed guest mapping over host image address=%p length=%zu\n",
      address,
      length
    );
    return false;
  }

  uintptr_t overlapping_start = 0;
  uintptr_t overlapping_length = 0;
  if (!guest_mapping_contains(mapping_start, mapping_length)
      && fixed_mapping_overlaps_host_vm_region(
        mapping_start,
        mapping_length,
        &overlapping_start,
        &overlapping_length)) {
    errno = ENOMEM;
    std::fprintf(
      stderr,
      "[IridiumFEX:mmap] denied fixed guest mapping over host vm region address=%p length=%zu host_region=0x%llx-0x%llx\n",
      address,
      length,
      static_cast<unsigned long long>(overlapping_start),
      static_cast<unsigned long long>(range_end(overlapping_start, overlapping_length))
    );
    return false;
  }
  return true;
}

void* mmap_private_file_with_linux_eof_semantics(
  void* address,
  size_t length,
  int protection,
  int flags,
  int fd,
  off_t offset
) {
  const bool trace_mmap = std::getenv("IRIDIUM_FEX_IOS_TRACE_MMAP") != nullptr;
  if (trace_mmap) {
    std::fprintf(
      stderr,
      "[IridiumFEX:mmap] request address=%p length=%zu protection=%d flags=%d fd=%d offset=%lld\n",
      address,
      length,
      protection,
      flags,
      fd,
      static_cast<long long>(offset)
    );
  }

  const int host_protection = darwin_guest_memory_protection(protection);
  const long host_page_size_value = ::sysconf(_SC_PAGESIZE);
  const auto host_page_size = host_page_size_value > 0
    ? static_cast<uintptr_t>(host_page_size_value)
    : static_cast<uintptr_t>(0x1000);
  const auto requested_start = reinterpret_cast<uintptr_t>(address);
  const auto requested_end = requested_start + length;
  if ((flags & MAP_FIXED) == MAP_FIXED && !fixed_mapping_is_allowed(address, length)) {
    return MAP_FAILED;
  }
  const bool fixed_private_file_mapping =
    fd >= 0 &&
    (flags & MAP_FIXED) == MAP_FIXED &&
    (flags & MAP_PRIVATE) == MAP_PRIVATE &&
    (flags & MAP_ANONYMOUS) != MAP_ANONYMOUS &&
    offset >= 0 &&
    length != 0;
  const bool needs_host_page_granularity =
    fixed_private_file_mapping &&
    ((requested_start & (host_page_size - 1)) != 0 ||
     (length & (host_page_size - 1)) != 0 ||
     (static_cast<uint64_t>(offset) & (host_page_size - 1)) != 0);
  const bool fixed_private_anonymous_mapping =
    fd < 0 &&
    (flags & MAP_FIXED) == MAP_FIXED &&
    (flags & MAP_PRIVATE) == MAP_PRIVATE &&
    (flags & MAP_ANONYMOUS) == MAP_ANONYMOUS &&
    length != 0;
  const bool needs_anonymous_host_page_granularity =
    fixed_private_anonymous_mapping &&
    ((requested_start & (host_page_size - 1)) != 0 || (length & (host_page_size - 1)) != 0);
  if (needs_anonymous_host_page_granularity) {
    const auto host_start = requested_start & ~(host_page_size - 1);
    const auto host_end = (requested_end + host_page_size - 1) & ~(host_page_size - 1);
    const auto host_length = static_cast<size_t>(host_end - host_start);
    const int copy_protection = host_protection | PROT_READ | PROT_WRITE;
    auto* host_address = reinterpret_cast<void*>(host_start);
    if (!fixed_mapping_is_allowed(host_address, host_length)) {
      return MAP_FAILED;
    }
    if (::mprotect(host_address, host_length, copy_protection) != 0) {
      const int mprotect_errno = errno;
      const int anonymous_host_flags = (flags & ~(MAP_FIXED)) | MAP_FIXED;
      void* mapped = mprotect_errno == ENOMEM
        ? ::mmap(host_address, host_length, copy_protection, anonymous_host_flags, -1, 0)
        : MAP_FAILED;
      if (mapped == host_address) {
        if (trace_mmap) {
          std::fprintf(stderr, "[IridiumFEX:mmap] fixed anonymous subpage allocated host page=%p length=%zu\n", host_address, host_length);
        }
      } else {
        if (mapped != MAP_FAILED) {
          ::munmap(mapped, host_length);
        }
        errno = mprotect_errno;
        if (trace_mmap) {
          std::fprintf(stderr, "[IridiumFEX:mmap] fixed anonymous subpage mprotect failed errno=%d\n", errno);
        }
        return MAP_FAILED;
      }
    }

    std::memset(address, 0, length);
    if (::mprotect(host_address, host_length, host_protection) != 0) {
      if (trace_mmap) {
        std::fprintf(stderr, "[IridiumFEX:mmap] fixed anonymous subpage mprotect failed errno=%d\n", errno);
      }
      return MAP_FAILED;
    }
    if (trace_mmap) {
      std::fprintf(stderr, "[IridiumFEX:mmap] fixed anonymous subpage result=%p\n", address);
    }
    record_guest_mapping(host_address, host_length);
    return address;
  }

  if (needs_host_page_granularity) {
    struct stat file_stat {};
    if (::fstat(fd, &file_stat) != 0) {
      if (trace_mmap) {
        std::fprintf(stderr, "[IridiumFEX:mmap] fixed file subpage fstat failed errno=%d\n", errno);
      }
      return MAP_FAILED;
    }

    const auto host_start = requested_start & ~(host_page_size - 1);
    const auto host_end = (requested_end + host_page_size - 1) & ~(host_page_size - 1);
    const auto host_length = static_cast<size_t>(host_end - host_start);
    const int copy_protection = host_protection | PROT_READ | PROT_WRITE;
    auto* host_address = reinterpret_cast<void*>(host_start);
    if (!fixed_mapping_is_allowed(host_address, host_length)) {
      return MAP_FAILED;
    }
    if (::mprotect(host_address, host_length, copy_protection) != 0) {
      if (trace_mmap) {
        std::fprintf(stderr, "[IridiumFEX:mmap] fixed file subpage mprotect failed errno=%d\n", errno);
      }
      return MAP_FAILED;
    }

    std::memset(address, 0, length);
    const auto file_size = static_cast<uint64_t>(std::max<off_t>(file_stat.st_size, 0));
    const auto mapping_offset = static_cast<uint64_t>(offset);
    const size_t bytes_to_copy = mapping_offset < file_size
      ? std::min<size_t>(length, static_cast<size_t>(file_size - mapping_offset))
      : 0;
    if (bytes_to_copy != 0) {
      ssize_t copied = ::pread(fd, address, bytes_to_copy, offset);
      if (copied < 0 || static_cast<size_t>(copied) != bytes_to_copy) {
        errno = copied < 0 ? errno : EIO;
        if (trace_mmap) {
          std::fprintf(stderr, "[IridiumFEX:mmap] fixed file subpage pread failed errno=%d copied=%zd expected=%zu\n", errno, copied, bytes_to_copy);
        }
        return MAP_FAILED;
      }
    }

    if (trace_mmap) {
      std::fprintf(stderr, "[IridiumFEX:mmap] fixed file subpage result=%p copied=%zu\n", address, bytes_to_copy);
    }
    record_guest_mapping(host_address, host_length);
    return address;
  }

  if (fd < 0 || offset < 0 || length == 0 ||
      (flags & MAP_PRIVATE) != MAP_PRIVATE ||
      (flags & MAP_ANONYMOUS) == MAP_ANONYMOUS) {
    void* result = ::mmap(address, length, host_protection, flags, fd, offset);
    if (trace_mmap) {
      std::fprintf(stderr, "[IridiumFEX:mmap] direct result=%p errno=%d\n", result, result == MAP_FAILED ? errno : 0);
    }
    if (result != MAP_FAILED) {
      record_guest_mapping(result, length);
    }
    return result;
  }

  struct stat file_stat {};
  if (::fstat(fd, &file_stat) != 0) {
    if (trace_mmap) {
      std::fprintf(stderr, "[IridiumFEX:mmap] fstat failed errno=%d\n", errno);
    }
    return MAP_FAILED;
  }

  const auto file_size = static_cast<uint64_t>(std::max<off_t>(file_stat.st_size, 0));
  const auto mapping_offset = static_cast<uint64_t>(offset);
  const bool extends_past_eof = mapping_offset > file_size || length > file_size - mapping_offset;
  if (!extends_past_eof) {
    void* result = ::mmap(address, length, host_protection, flags, fd, offset);
    if (trace_mmap) {
      std::fprintf(stderr, "[IridiumFEX:mmap] file result=%p errno=%d file_size=%llu\n", result, result == MAP_FAILED ? errno : 0, static_cast<unsigned long long>(file_size));
    }
    if (result != MAP_FAILED) {
      record_guest_mapping(result, length);
    }
    return result;
  }

  int anonymous_flags = flags;
  anonymous_flags &= ~MAP_SHARED;
  anonymous_flags |= MAP_PRIVATE | MAP_ANONYMOUS;

  const int copy_protection = host_protection | PROT_READ | PROT_WRITE;
  void* result = ::mmap(address, length, copy_protection, anonymous_flags, -1, 0);
  if (result == MAP_FAILED) {
    if (trace_mmap) {
      std::fprintf(stderr, "[IridiumFEX:mmap] eof anonymous result failed errno=%d file_size=%llu\n", errno, static_cast<unsigned long long>(file_size));
    }
    return MAP_FAILED;
  }

  const size_t bytes_to_copy = mapping_offset < file_size
    ? std::min<size_t>(length, static_cast<size_t>(file_size - mapping_offset))
    : 0;
  if (bytes_to_copy != 0) {
    ssize_t copied = ::pread(fd, result, bytes_to_copy, offset);
    if (copied < 0 || static_cast<size_t>(copied) != bytes_to_copy) {
      const int saved_errno = copied < 0 ? errno : EIO;
      ::munmap(result, length);
      errno = saved_errno;
      if (trace_mmap) {
        std::fprintf(stderr, "[IridiumFEX:mmap] eof pread failed errno=%d copied=%zd expected=%zu\n", errno, copied, bytes_to_copy);
      }
      return MAP_FAILED;
    }
  }

  if (copy_protection != host_protection && ::mprotect(result, length, host_protection) != 0) {
    const int saved_errno = errno;
    ::munmap(result, length);
    errno = saved_errno;
    if (trace_mmap) {
      std::fprintf(stderr, "[IridiumFEX:mmap] eof mprotect failed errno=%d\n", errno);
    }
    return MAP_FAILED;
  }

  if (trace_mmap) {
    std::fprintf(stderr, "[IridiumFEX:mmap] eof result=%p copied=%zu file_size=%llu\n", result, bytes_to_copy, static_cast<unsigned long long>(file_size));
  }
  record_guest_mapping(result, length);
  return result;
}

int darwin_open_flags(int guest_flags) {
  int flags = 0;
  switch (guest_flags & kLinuxOpenAccessMode) {
    case 0:
      flags |= O_RDONLY;
      break;
    case kLinuxOpenWriteOnly:
      flags |= O_WRONLY;
      break;
    case kLinuxOpenReadWrite:
      flags |= O_RDWR;
      break;
    default:
      errno = EINVAL;
      return -1;
  }

  if ((guest_flags & kLinuxOpenCreate) == kLinuxOpenCreate) {
    flags |= O_CREAT;
  }
  if ((guest_flags & kLinuxOpenExclusive) == kLinuxOpenExclusive) {
    flags |= O_EXCL;
  }
  if ((guest_flags & kLinuxOpenTruncate) == kLinuxOpenTruncate) {
    flags |= O_TRUNC;
  }
  if ((guest_flags & kLinuxOpenAppend) == kLinuxOpenAppend) {
    flags |= O_APPEND;
  }
  if ((guest_flags & kLinuxOpenNonBlock) == kLinuxOpenNonBlock) {
    flags |= O_NONBLOCK;
  }
  if ((guest_flags & kLinuxOpenDSync) == kLinuxOpenDSync) {
#if defined(O_DSYNC)
    flags |= O_DSYNC;
#elif defined(O_SYNC)
    flags |= O_SYNC;
#endif
  }
  if ((guest_flags & kLinuxOpenDirectory) == kLinuxOpenDirectory) {
#if defined(O_DIRECTORY)
    flags |= O_DIRECTORY;
#endif
  }
  if ((guest_flags & kLinuxOpenNoFollow) == kLinuxOpenNoFollow) {
#if defined(O_NOFOLLOW)
    flags |= O_NOFOLLOW;
#endif
  }
  if ((guest_flags & kLinuxOpenCloseOnExec) == kLinuxOpenCloseOnExec) {
#if defined(O_CLOEXEC)
    flags |= O_CLOEXEC;
#endif
  }

  guest_flags &= ~(kLinuxOpenAccessMode | kLinuxOpenCreate | kLinuxOpenExclusive |
                   kLinuxOpenNoCTTY | kLinuxOpenTruncate | kLinuxOpenAppend |
                   kLinuxOpenNonBlock | kLinuxOpenDSync | kLinuxOpenDirect |
                   kLinuxOpenLargeFile | kLinuxOpenDirectory | kLinuxOpenNoFollow |
                   kLinuxOpenCloseOnExec);
  if (guest_flags != 0) {
    errno = EINVAL;
    return -1;
  }

  return flags;
}

uint64_t handle_prctl(uint64_t option, uint64_t argument2) {
  switch (option) {
    case kPrSetName:
      return 0;
    case kPrSetVMA:
      return argument2 == kPrSetVMAAnonName ? 0 : static_cast<uint64_t>(-EINVAL);
    default:
      return static_cast<uint64_t>(-EINVAL);
  }
}

uint64_t handle_arch_prctl(FEXCore::Core::CpuStateFrame* frame, uint64_t code, uint64_t address) {
  if (frame == nullptr) {
    return static_cast<uint64_t>(-EINVAL);
  }

  switch (code) {
    case kArchSetGS:
      if (address >= kLinuxTaskMax64Bit) {
        return static_cast<uint64_t>(-EPERM);
      }
      frame->State.gs_cached = address;
      return 0;
    case kArchSetFS:
      if (address >= kLinuxTaskMax64Bit) {
        return static_cast<uint64_t>(-EPERM);
      }
      frame->State.fs_cached = address;
      return 0;
    case kArchGetFS:
      if (address == 0) {
        return static_cast<uint64_t>(-EFAULT);
      }
      *reinterpret_cast<uint64_t*>(address) = frame->State.fs_cached;
      return 0;
    case kArchGetGS:
      if (address == 0) {
        return static_cast<uint64_t>(-EFAULT);
      }
      *reinterpret_cast<uint64_t*>(address) = frame->State.gs_cached;
      return 0;
    case kArchCETStatus:
      return static_cast<uint64_t>(-EINVAL);
    case kArchGetCPUID:
      return 1;
    case kArchSetCPUID:
      return static_cast<uint64_t>(-ENODEV);
    default:
      return static_cast<uint64_t>(-EINVAL);
  }
}

}  // namespace

struct MinimalDarwinSyscallHandler::ManagedGuestThread {
  std::thread host_thread;
  std::atomic<FEXCore::Core::InternalThreadState*> guest_thread {nullptr};
  FEXCore::Context::Context* context {};
  GuestThreadRuntimeState runtime_state {};
  uint64_t identifier {};
  int32_t* initial_clear_tid {};
  std::atomic<int> pending_signal {0};
};

MinimalDarwinSyscallHandler::MinimalDarwinSyscallHandler(
  std::shared_ptr<std::atomic_bool> stop_requested,
  FEX::DummyHandlers::DummySignalDelegator* signal_delegator
) : stop_requested_(std::move(stop_requested)), signal_delegator_(signal_delegator) {
  OSABI = FEXCore::HLE::SyscallOSABI::OS_LINUX64;
}

MinimalDarwinSyscallHandler::~MinimalDarwinSyscallHandler() {
  StopManagedGuestThreads();
  for (auto& record : managed_guest_threads_) {
    if (record->host_thread.joinable()) {
      record->host_thread.join();
    }
  }
  const uint64_t main_identifier = main_guest_thread_identifier_.load(std::memory_order_acquire);
  if (main_identifier != 0) {
    unregister_guest_signal_target(main_identifier, &main_pending_signal_);
  }
  if (current_guest_pending_signal == &main_pending_signal_) {
    current_guest_pending_signal = nullptr;
  }
}

void MinimalDarwinSyscallHandler::RegisterMainGuestThreadSignalTarget() {
  if (guest_thread_identifier_override != 0) {
    return;
  }
  const uint64_t identifier = current_thread_id();
  uint64_t expected = 0;
  if (main_guest_thread_identifier_.compare_exchange_strong(
        expected, identifier, std::memory_order_acq_rel)) {
    register_guest_signal_target(identifier, &main_pending_signal_, stop_requested_);
  }
  if (main_guest_thread_identifier_.load(std::memory_order_acquire) == identifier) {
    current_guest_pending_signal = &main_pending_signal_;
  }
}

void MinimalDarwinSyscallHandler::StopManagedGuestThreads(
  FEXCore::Core::InternalThreadState* except_thread
) {
  if (stop_requested_) {
    stop_requested_->store(true, std::memory_order_release);
  }
  {
    const std::lock_guard<std::mutex> lock(managed_guest_threads_mutex_);
    for (const auto& record : managed_guest_threads_) {
      auto* thread = record->guest_thread.load(std::memory_order_acquire);
      if (thread == nullptr || thread == except_thread) {
        continue;
      }
      FEXCore::Allocator::VirtualProtect(
        &thread->InterruptFaultPage,
        sizeof(thread->InterruptFaultPage),
        FEXCore::Allocator::ProtectOptions::Read
      );
    }
  }
  {
    const std::lock_guard<std::mutex> lock(futex_wait_mutex);
    ++futex_wake_generation;
  }
  futex_wait_condition.notify_all();
}

uint64_t MinimalDarwinSyscallHandler::HandleClone(
  FEXCore::Core::CpuStateFrame* frame,
  uint64_t flags,
  uint64_t child_stack,
  uint64_t parent_tid,
  uint64_t child_tid,
  uint64_t tls
) {
  constexpr uint64_t supported_flags = kLinuxCloneVM | kLinuxCloneFS | kLinuxCloneFiles
    | kLinuxCloneSighand | kLinuxCloneThread | kLinuxCloneSysvsem | kLinuxCloneSetTLS
    | kLinuxCloneParentSetTID | kLinuxCloneChildClearTID | kLinuxCloneDetached
    | kLinuxCloneUntraced | kLinuxCloneChildSetTID;
  constexpr uint64_t required_flags = kLinuxCloneVM | kLinuxCloneSighand | kLinuxCloneThread;

  if (frame == nullptr || frame->Thread == nullptr || frame->Thread->CTX == nullptr
      || child_stack == 0 || signal_delegator_ == nullptr) {
    return static_cast<uint64_t>(-EINVAL);
  }
  if ((flags & required_flags) != required_flags || (flags & ~supported_flags) != 0) {
    std::fprintf(stderr, "iridium-fex-ios: unsupported clone flags=0x%llx\n",
      static_cast<unsigned long long>(flags));
    return static_cast<uint64_t>(-ENOSYS);
  }

  auto record = std::make_unique<ManagedGuestThread>();
  record->context = frame->Thread->CTX;
  record->identifier = next_guest_thread_identifier.fetch_add(1, std::memory_order_relaxed);
  record->initial_clear_tid = (flags & kLinuxCloneChildClearTID) != 0
    ? reinterpret_cast<int32_t*>(child_tid)
    : nullptr;

  auto* thread = record->context->CreateThread(0, 0, &frame->State);
  if (thread == nullptr) {
    return static_cast<uint64_t>(-ENOMEM);
  }
  thread->CurrentFrame->State.gregs[FEXCore::X86State::REG_RAX] = 0;
  thread->CurrentFrame->State.gregs[FEXCore::X86State::REG_RSP] = child_stack;
  thread->CurrentFrame->State.rip += 2;
  if ((flags & kLinuxCloneSetTLS) != 0) {
    thread->CurrentFrame->State.fs_cached = tls;
  }
  InitializeGuest64BitThreadState(thread->CurrentFrame->State, record->runtime_state.gdt);
  if ((flags & kLinuxCloneSetTLS) != 0) {
    thread->CurrentFrame->State.fs_cached = tls;
  }
  if (!InitializeGuestCallRetStack(
        thread->CallRetStackBase,
        thread->CurrentFrame->State.callret_sp,
        record->runtime_state)) {
    record->context->DestroyThread(thread);
    return static_cast<uint64_t>(-ENOMEM);
  }
  record->guest_thread.store(thread, std::memory_order_release);

  if ((flags & kLinuxCloneParentSetTID) != 0 && parent_tid != 0) {
    *reinterpret_cast<int32_t*>(parent_tid) = static_cast<int32_t>(record->identifier);
  }
  if ((flags & kLinuxCloneChildSetTID) != 0 && child_tid != 0) {
    *reinterpret_cast<int32_t*>(child_tid) = static_cast<int32_t>(record->identifier);
  }

  ManagedGuestThread* raw_record = record.get();
  {
    const std::lock_guard<std::mutex> lock(managed_guest_threads_mutex_);
    managed_guest_threads_.push_back(std::move(record));
  }
  raw_record->host_thread = std::thread([this, raw_record, thread] {
    guest_thread_identifier_override = raw_record->identifier;
    guest_clear_tid_address = raw_record->initial_clear_tid;
    current_guest_pending_signal = &raw_record->pending_signal;
    register_guest_signal_target(
      raw_record->identifier,
      &raw_record->pending_signal,
      stop_requested_
    );
    signal_delegator_->RegisterTLSState(thread);
    GuestExecutionTrapResult result {};
    RunWithGuestExecutionTrap(
      [](void* raw_context) {
        auto* managed = static_cast<ManagedGuestThread*>(raw_context);
        managed->context->ExecuteThread(
          managed->guest_thread.load(std::memory_order_acquire));
      },
      raw_record,
      result
    );
    signal_delegator_->UninstallTLSState(thread);
    if (guest_clear_tid_address != nullptr) {
      __atomic_store_n(guest_clear_tid_address, 0, __ATOMIC_SEQ_CST);
      {
        const std::lock_guard<std::mutex> lock(futex_wait_mutex);
        ++futex_wake_generation;
      }
      futex_wait_condition.notify_all();
    }
    DestroyGuestCallRetStack(thread->CallRetStackBase, raw_record->runtime_state);
    raw_record->guest_thread.store(nullptr, std::memory_order_release);
    raw_record->context->DestroyThread(thread);
    unregister_guest_signal_target(raw_record->identifier, &raw_record->pending_signal);
    current_guest_pending_signal = nullptr;
    guest_clear_tid_address = nullptr;
    guest_thread_identifier_override = 0;
  });

  return raw_record->identifier;
}

bool RunWithGuestExitTrap(GuestExitTrapCallback callback, void* context, int& exit_code) {
  GuestExecutionTrapResult result {};
  const bool trapped = RunWithGuestExecutionTrap(callback, context, result);
  if (result.exited) {
    exit_code = result.exit_code;
  }
  return trapped && result.exited;
}

bool RunWithGuestExecutionTrap(GuestExitTrapCallback callback, void* context, GuestExecutionTrapResult& result) {
  std::jmp_buf jump_buffer {};
  GuestExecutionSignalTrap signal_trap {};
  result = {};
  guest_exit_trap = &jump_buffer;
  guest_exit_status = 0;
  guest_execution_signal_trap = &signal_trap;
  install_guest_execution_signal_handlers(signal_trap);

  if (setjmp(jump_buffer) == 0) {
    if (setjmp(signal_trap.jump_buffer) == 0) {
      callback(context);
      restore_guest_execution_signal_handlers(signal_trap);
      guest_execution_signal_trap = nullptr;
      guest_exit_trap = nullptr;
      return false;
    }

    restore_guest_execution_signal_handlers(signal_trap);
    result.fatal_signal = true;
    result.signal_number = signal_trap.signal_number;
    result.fault_address = signal_trap.fault_address;
    result.host_pc = signal_trap.host_pc;
    guest_execution_signal_trap = nullptr;
    guest_exit_trap = nullptr;
    return true;
  }

  restore_guest_execution_signal_handlers(signal_trap);
  result.exited = true;
  result.exit_code = guest_exit_status;
  guest_execution_signal_trap = nullptr;
  guest_exit_trap = nullptr;
  return true;
}

uint64_t MinimalDarwinSyscallHandler::HandleSyscall(
  FEXCore::Core::CpuStateFrame* frame,
  FEXCore::HLE::SyscallArguments* args
) {
  if (args == nullptr) {
    return static_cast<uint64_t>(-EINVAL);
  }
  RegisterMainGuestThreadSignalTarget();
  if (current_guest_pending_signal != nullptr
      && current_guest_pending_signal->load(std::memory_order_acquire) == SIGQUIT) {
    current_guest_pending_signal->store(0, std::memory_order_release);
    exit_guest_thread(0);
  }
  if (stop_requested_ && stop_requested_->load(std::memory_order_acquire)) {
    exit_guest_thread(130);
  }

  const bool trace_syscalls = std::getenv("IRIDIUM_FEX_IOS_TRACE_SYSCALLS") != nullptr;
  if (trace_syscalls) {
    std::fprintf(
      stderr,
      "[IridiumFEX:syscall] nr=%llu frame=%p rip=0x%llx fs=0x%llx gs=0x%llx args=[0x%llx,0x%llx,0x%llx,0x%llx,0x%llx,0x%llx]\n",
      static_cast<unsigned long long>(args->Argument[0]),
      frame,
      static_cast<unsigned long long>(frame != nullptr ? frame->State.rip : 0),
      static_cast<unsigned long long>(frame != nullptr ? frame->State.fs_cached : 0),
      static_cast<unsigned long long>(frame != nullptr ? frame->State.gs_cached : 0),
      static_cast<unsigned long long>(args->Argument[1]),
      static_cast<unsigned long long>(args->Argument[2]),
      static_cast<unsigned long long>(args->Argument[3]),
      static_cast<unsigned long long>(args->Argument[4]),
      static_cast<unsigned long long>(args->Argument[5]),
      static_cast<unsigned long long>(args->Argument[6])
    );
  }

  switch (static_cast<MinimalSyscallNumber>(args->Argument[0])) {
    case MinimalSyscallNumber::read: {
      const int fd = static_cast<int>(args->Argument[1]);
      void* buffer = reinterpret_cast<void*>(args->Argument[2]);
      const size_t count = static_cast<size_t>(args->Argument[3]);
      const ssize_t result = ::read(fd, buffer, count);
      if (result < 0) {
        return linux_error_result();
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::write: {
      const int fd = static_cast<int>(args->Argument[1]);
      const void* buffer = reinterpret_cast<const void*>(args->Argument[2]);
      const size_t count = static_cast<size_t>(args->Argument[3]);
      const ssize_t result = ::write(fd, buffer, count);
      if (result < 0) {
        return linux_error_result();
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::open: {
      const auto translated_path = translate_guest_path(reinterpret_cast<const char*>(args->Argument[1]));
      const char* path = translated_path.c_str();
      const int flags = darwin_open_flags(static_cast<int>(args->Argument[2]));
      if (flags < 0) {
        if (trace_syscalls) {
          std::fprintf(stderr, "[IridiumFEX:syscall] open path=\"%s\" flags=0x%x result=0x%llx errno=%d\n", path, static_cast<int>(args->Argument[2]), static_cast<unsigned long long>(linux_error_result()), errno);
        }
        return linux_error_result();
      }
      const int mode = static_cast<int>(args->Argument[3]);
      const int result = ::open(path, flags, mode);
      if (result < 0) {
        if (trace_syscalls) {
          std::fprintf(stderr, "[IridiumFEX:syscall] open path=\"%s\" flags=0x%x result=0x%llx errno=%d\n", path, static_cast<int>(args->Argument[2]), static_cast<unsigned long long>(linux_error_result()), errno);
        }
        return linux_error_result();
      }
      if (trace_syscalls) {
        std::fprintf(stderr, "[IridiumFEX:syscall] open path=\"%s\" flags=0x%x result=%d\n", path, static_cast<int>(args->Argument[2]), result);
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::close: {
      const int fd = static_cast<int>(args->Argument[1]);
      if (::close(fd) != 0) {
        return linux_error_result();
      }
      return 0;
    }
    case MinimalSyscallNumber::fstat: {
      const int fd = static_cast<int>(args->Argument[1]);
      struct stat host_stat {};
      if (::fstat(fd, &host_stat) != 0) {
        return linux_error_result();
      }
      return write_linux_stat(host_stat, args->Argument[2]);
    }
    case MinimalSyscallNumber::poll:
      return handle_poll(
        args->Argument[1],
        args->Argument[2],
        static_cast<int>(args->Argument[3])
      );
    case MinimalSyscallNumber::lseek: {
      const int fd = static_cast<int>(args->Argument[1]);
      const off_t offset = static_cast<off_t>(args->Argument[2]);
      const int whence = static_cast<int>(args->Argument[3]);
      const off_t result = ::lseek(fd, offset, whence);
      if (result < 0) {
        return linux_error_result();
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::mmap: {
      void* address = reinterpret_cast<void*>(args->Argument[1]);
      const size_t length = static_cast<size_t>(args->Argument[2]);
      const int protection = static_cast<int>(args->Argument[3]);
      const int flags = darwin_mmap_flags(static_cast<int>(args->Argument[4]));
      if (flags < 0) {
        if (trace_syscalls) {
          std::fprintf(stderr, "[IridiumFEX:syscall] mmap result=0x%llx errno=%d\n", static_cast<unsigned long long>(linux_error_result()), errno);
        }
        return linux_error_result();
      }
      const int fd = static_cast<int>(args->Argument[5]);
      const off_t offset = static_cast<off_t>(args->Argument[6]);
      if ((static_cast<int>(args->Argument[4]) & kLinuxMapFixedNoReplace) && (flags & MAP_ANONYMOUS)) {
        const auto range = host_page_aligned_range(address, length);
#if defined(__APPLE__)
        vm_address_t reserved = range.start;
        if (vm_allocate(mach_task_self(), &reserved, range.length, VM_FLAGS_FIXED) != KERN_SUCCESS) {
          errno = fixed_mapping_overlaps_host_vm_region(range.start, range.length) ? EEXIST : ENOMEM;
          return linux_error_result();
        }
        void* mapped = ::mmap(reinterpret_cast<void*>(range.start), range.length,
                              darwin_guest_memory_protection(protection), flags | MAP_FIXED, fd, offset);
        if (mapped == MAP_FAILED) {
          const int saved_errno = errno;
          vm_deallocate(mach_task_self(), reserved, range.length);
          errno = saved_errno;
          return linux_error_result();
        }
#else
        void* mapped = ::mmap(reinterpret_cast<void*>(range.start), range.length,
                              darwin_guest_memory_protection(protection), flags, fd, offset);
        if (mapped == MAP_FAILED) return linux_error_result();
        if (mapped != reinterpret_cast<void*>(range.start)) {
          ::munmap(mapped, range.length);
          errno = EEXIST;
          return linux_error_result();
        }
#endif
        record_guest_mapping(mapped, range.length);
        return reinterpret_cast<uint64_t>(address);
      }
      void* result = mmap_private_file_with_linux_eof_semantics(address, length, protection, flags, fd, offset);
      if (result != MAP_FAILED &&
          (static_cast<int>(args->Argument[4]) & kLinuxMapFixedNoReplace) && result != address) {
        ::munmap(result, length);
        forget_guest_mapping(result, length);
        errno = EEXIST;
        result = MAP_FAILED;
      }
      if (result == MAP_FAILED) {
        if (trace_syscalls) {
          std::fprintf(stderr, "[IridiumFEX:syscall] mmap result=0x%llx errno=%d fd=%d fd_path=\"%s\"\n", static_cast<unsigned long long>(linux_error_result()), errno, fd, path_for_fd(fd).c_str());
        }
        return linux_error_result();
      }
      if (trace_syscalls) {
        std::fprintf(
          stderr,
          "[IridiumFEX:syscall] mmap result=0x%llx length=0x%zx prot=0x%x flags=0x%x fd=%d offset=0x%llx fd_path=\"%s\"\n",
          static_cast<unsigned long long>(reinterpret_cast<uint64_t>(result)),
          length,
          protection,
          static_cast<int>(args->Argument[4]),
          fd,
          static_cast<unsigned long long>(offset),
          path_for_fd(fd).c_str()
        );
      }
      return reinterpret_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::mprotect: {
      void* address = reinterpret_cast<void*>(args->Argument[1]);
      const size_t length = static_cast<size_t>(args->Argument[2]);
      const int protection = darwin_guest_memory_protection(static_cast<int>(args->Argument[3]));
      const long host_page_size_value = ::sysconf(_SC_PAGESIZE);
      const auto host_page_size = host_page_size_value > 0
        ? static_cast<uintptr_t>(host_page_size_value)
        : static_cast<uintptr_t>(0x1000);
      const auto requested_start = reinterpret_cast<uintptr_t>(address);
      if (
        host_page_size > 0x1000 &&
        ((requested_start & (host_page_size - 1)) != 0 || (length & (host_page_size - 1)) != 0)
      ) {
        if ((protection & PROT_WRITE) == PROT_WRITE) {
          const auto host_start = requested_start & ~(host_page_size - 1);
          const auto requested_end = requested_start + length;
          const auto host_end = (requested_end + host_page_size - 1) & ~(host_page_size - 1);
          if (::mprotect(reinterpret_cast<void*>(host_start), static_cast<size_t>(host_end - host_start), protection) != 0) {
            return linux_error_result();
          }
        }
        return 0;
      }
      if (::mprotect(address, length, protection) != 0) {
        return linux_error_result();
      }
      return 0;
    }
    case MinimalSyscallNumber::munmap: {
      void* address = reinterpret_cast<void*>(args->Argument[1]);
      const size_t length = static_cast<size_t>(args->Argument[2]);
      const auto page_size = host_page_size();
      const auto requested_start = reinterpret_cast<uintptr_t>(address);
      if (
        page_size > 0x1000 &&
        ((requested_start & (page_size - 1)) != 0 || (length & (page_size - 1)) != 0)
      ) {
        return 0;
      }
      if (::munmap(address, length) != 0) {
        return linux_error_result();
      }
      forget_guest_mapping(address, length);
      return 0;
    }
    case MinimalSyscallNumber::brk:
      return 0;
    case MinimalSyscallNumber::rt_sigaction:
      return handle_rt_sigaction(
        static_cast<int>(args->Argument[1]),
        args->Argument[2],
        args->Argument[3],
        static_cast<size_t>(args->Argument[4]),
        signal_actions_
      );
    case MinimalSyscallNumber::rt_sigprocmask:
      return handle_rt_sigprocmask(
        static_cast<int>(args->Argument[1]),
        args->Argument[2],
        args->Argument[3],
        static_cast<size_t>(args->Argument[4]),
        signal_mask_
      );
    case MinimalSyscallNumber::ioctl:
      return handle_ioctl(
        static_cast<int>(args->Argument[1]),
        static_cast<unsigned long>(args->Argument[2]),
        args->Argument[3]
      );
    case MinimalSyscallNumber::sigaltstack:
      return handle_sigaltstack(
        args->Argument[1],
        args->Argument[2],
        signal_alt_stack_pointer_,
        signal_alt_stack_size_,
        signal_alt_stack_flags_
      );
    case MinimalSyscallNumber::pread64: {
      const int fd = static_cast<int>(args->Argument[1]);
      void* buffer = reinterpret_cast<void*>(args->Argument[2]);
      const size_t count = static_cast<size_t>(args->Argument[3]);
      const off_t offset = static_cast<off_t>(args->Argument[4]);
      const ssize_t result = ::pread(fd, buffer, count, offset);
      if (result < 0) {
        return linux_error_result();
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::pwrite64: {
      const int fd = static_cast<int>(args->Argument[1]);
      const void* buffer = reinterpret_cast<const void*>(args->Argument[2]);
      const size_t count = static_cast<size_t>(args->Argument[3]);
      const off_t offset = static_cast<off_t>(args->Argument[4]);
      const ssize_t result = ::pwrite(fd, buffer, count, offset);
      if (result < 0) {
        return linux_error_result();
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::readv: {
      const int fd = static_cast<int>(args->Argument[1]);
      const auto* vectors = reinterpret_cast<const iovec*>(args->Argument[2]);
      const int vector_count = static_cast<int>(args->Argument[3]);
      const ssize_t result = ::readv(fd, vectors, vector_count);
      if (result < 0) {
        return linux_error_result();
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::writev: {
      const int fd = static_cast<int>(args->Argument[1]);
      const auto* vectors = reinterpret_cast<const iovec*>(args->Argument[2]);
      const int vector_count = static_cast<int>(args->Argument[3]);
      const ssize_t result = ::writev(fd, vectors, vector_count);
      if (result < 0) {
        return linux_error_result();
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::access: {
      const auto translated_path = translate_guest_path(reinterpret_cast<const char*>(args->Argument[1]));
      const char* path = translated_path.c_str();
      const int mode = static_cast<int>(args->Argument[2]);
      if (::access(path, mode) != 0) {
        return linux_error_result();
      }
      return 0;
    }
    case MinimalSyscallNumber::pipe:
      return handle_pipe(args->Argument[1], 0);
    case MinimalSyscallNumber::sched_yield:
      return ::sched_yield() == 0 ? 0 : linux_error_result();
    case MinimalSyscallNumber::dup: {
      const int result = ::dup(static_cast<int>(args->Argument[1]));
      return result < 0 ? linux_error_result() : static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::dup2: {
      const int result = ::dup2(
        static_cast<int>(args->Argument[1]),
        static_cast<int>(args->Argument[2])
      );
      return result < 0 ? linux_error_result() : static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::nanosleep: {
      const auto* request = reinterpret_cast<const timespec*>(args->Argument[1]);
      auto* remaining = reinterpret_cast<timespec*>(args->Argument[2]);
      if (request == nullptr) {
        return static_cast<uint64_t>(-EFAULT);
      }
      return ::nanosleep(request, remaining) == 0 ? 0 : linux_error_result();
    }
    case MinimalSyscallNumber::clone:
      return HandleClone(
        frame,
        args->Argument[1],
        args->Argument[2],
        args->Argument[3],
        args->Argument[4],
        args->Argument[5]
      );
    case MinimalSyscallNumber::getpid:
      return static_cast<uint64_t>(::getpid());
    case MinimalSyscallNumber::socket:
      return handle_socket(
        static_cast<int>(args->Argument[1]),
        static_cast<int>(args->Argument[2]),
        static_cast<int>(args->Argument[3])
      );
    case MinimalSyscallNumber::connect:
      return handle_connect(
        static_cast<int>(args->Argument[1]),
        args->Argument[2],
        args->Argument[3]
      );
    case MinimalSyscallNumber::sendmsg:
      return handle_sendmsg(
        static_cast<int>(args->Argument[1]),
        args->Argument[2],
        static_cast<int>(args->Argument[3])
      );
    case MinimalSyscallNumber::recvmsg:
      return handle_recvmsg(
        static_cast<int>(args->Argument[1]),
        args->Argument[2],
        static_cast<int>(args->Argument[3])
      );
    case MinimalSyscallNumber::socketpair:
      return handle_socketpair(
        static_cast<int>(args->Argument[1]),
        static_cast<int>(args->Argument[2]),
        static_cast<int>(args->Argument[3]),
        args->Argument[4]
      );
    case MinimalSyscallNumber::setsockopt:
      return handle_setsockopt(
        static_cast<int>(args->Argument[1]),
        static_cast<int>(args->Argument[2]),
        static_cast<int>(args->Argument[3]),
        args->Argument[4],
        args->Argument[5]
      );
    case MinimalSyscallNumber::wait4: {
      const pid_t pid = static_cast<pid_t>(args->Argument[1]);
      int status = 0;
      const int options = static_cast<int>(args->Argument[3]);
      const pid_t result = ::waitpid(pid, &status, options);
      if (result < 0) {
        return linux_error_result();
      }
      if (args->Argument[2] != 0) {
        *reinterpret_cast<int*>(args->Argument[2]) = status;
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::uname:
      return handle_uname(args->Argument[1]);
    case MinimalSyscallNumber::fcntl:
      return handle_fcntl(
        static_cast<int>(args->Argument[1]),
        static_cast<int>(args->Argument[2]),
        args->Argument[3]
      );
    case MinimalSyscallNumber::getcwd: {
      char* buffer = reinterpret_cast<char*>(args->Argument[1]);
      const size_t size = static_cast<size_t>(args->Argument[2]);
      if (::getcwd(buffer, size) == nullptr) {
        return linux_error_result();
      }
      return static_cast<uint64_t>(std::strlen(buffer) + 1);
    }
    case MinimalSyscallNumber::chdir: {
      const auto translated_path = translate_guest_path(reinterpret_cast<const char*>(args->Argument[1]));
      const char* path = translated_path.c_str();
      if (::chdir(path) != 0) {
        return linux_error_result();
      }
      return 0;
    }
    case MinimalSyscallNumber::fchdir:
      return ::fchdir(static_cast<int>(args->Argument[1])) == 0 ? 0 : linux_error_result();
    case MinimalSyscallNumber::mkdir: {
      const auto translated_path = translate_guest_path(reinterpret_cast<const char*>(args->Argument[1]));
      const char* path = translated_path.c_str();
      const mode_t mode = static_cast<mode_t>(args->Argument[2]);
      if (::mkdir(path, mode) != 0) {
        return linux_error_result();
      }
      return 0;
    }
    case MinimalSyscallNumber::symlink: {
      const char* target = reinterpret_cast<const char*>(args->Argument[1]);
      const auto translated_link_path = translate_guest_path(reinterpret_cast<const char*>(args->Argument[2]));
      const char* link_path = translated_link_path.c_str();
      if (::symlink(target, link_path) != 0) {
        return linux_error_result();
      }
      return 0;
    }
    case MinimalSyscallNumber::readlink: {
      const auto translated_path = translate_guest_path(reinterpret_cast<const char*>(args->Argument[1]));
      const char* path = translated_path.c_str();
      char* buffer = reinterpret_cast<char*>(args->Argument[2]);
      const size_t size = static_cast<size_t>(args->Argument[3]);
      const ssize_t result = ::readlink(path, buffer, size);
      if (result < 0) {
        return linux_error_result();
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::gettimeofday: {
      auto* guest_time = reinterpret_cast<timeval*>(args->Argument[1]);
      auto* guest_timezone = reinterpret_cast<struct timezone*>(args->Argument[2]);
      if (guest_time == nullptr) {
        return static_cast<uint64_t>(-EFAULT);
      }
      return ::gettimeofday(guest_time, guest_timezone) == 0 ? 0 : linux_error_result();
    }
    case MinimalSyscallNumber::sysinfo:
      return handle_sysinfo(args->Argument[1]);
    case MinimalSyscallNumber::umask:
      return static_cast<uint64_t>(::umask(static_cast<mode_t>(args->Argument[1])));
    case MinimalSyscallNumber::exit:
      exit_guest_thread(static_cast<int>(args->Argument[1]));
    case MinimalSyscallNumber::exit_group:
      StopManagedGuestThreads(frame == nullptr ? nullptr : frame->Thread);
      exit_guest_thread(static_cast<int>(args->Argument[1]));
    case MinimalSyscallNumber::getuid:
      return static_cast<uint64_t>(::getuid());
    case MinimalSyscallNumber::getgid:
      return static_cast<uint64_t>(::getgid());
    case MinimalSyscallNumber::geteuid:
      return static_cast<uint64_t>(::geteuid());
    case MinimalSyscallNumber::getegid:
      return static_cast<uint64_t>(::getegid());
    case MinimalSyscallNumber::getppid:
      return static_cast<uint64_t>(::getppid());
    case MinimalSyscallNumber::fstatfs:
      return handle_fstatfs(
        static_cast<int>(args->Argument[1]),
        args->Argument[2]
      );
    case MinimalSyscallNumber::prctl:
      return handle_prctl(args->Argument[1], args->Argument[2]);
    case MinimalSyscallNumber::arch_prctl:
      return handle_arch_prctl(frame, args->Argument[1], args->Argument[2]);
    case MinimalSyscallNumber::gettid:
      return current_thread_id();
    case MinimalSyscallNumber::time: {
      const auto result = static_cast<int64_t>(::time(nullptr));
      if (result < 0) {
        return linux_error_result();
      }
      if (args->Argument[1] != 0) {
        *reinterpret_cast<int64_t*>(args->Argument[1]) = result;
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::futex:
      return handle_futex(
        args->Argument[1],
        static_cast<int>(args->Argument[2]),
        static_cast<uint32_t>(args->Argument[3]),
        args->Argument[4]
      );
    case MinimalSyscallNumber::sched_setaffinity:
      return 0;
    case MinimalSyscallNumber::sched_getaffinity:
      return handle_sched_getaffinity(args->Argument[2], args->Argument[3]);
    case MinimalSyscallNumber::set_tid_address:
      guest_clear_tid_address = reinterpret_cast<int32_t*>(args->Argument[1]);
      return current_thread_id();
    case MinimalSyscallNumber::clock_gettime: {
      const clockid_t clock_id = darwin_clock_id(static_cast<int>(args->Argument[1]));
      if (clock_id == static_cast<clockid_t>(-1)) {
        return linux_error_result();
      }
      auto* guest_timespec = reinterpret_cast<timespec*>(args->Argument[2]);
      if (guest_timespec == nullptr) {
        return static_cast<uint64_t>(-EFAULT);
      }
      if (::clock_gettime(clock_id, guest_timespec) != 0) {
        return linux_error_result();
      }
      return 0;
    }
    case MinimalSyscallNumber::clock_getres: {
      const clockid_t clock_id = darwin_clock_id(static_cast<int>(args->Argument[1]));
      if (clock_id == static_cast<clockid_t>(-1)) {
        return linux_error_result();
      }
      auto* guest_timespec = reinterpret_cast<timespec*>(args->Argument[2]);
      if (guest_timespec == nullptr) {
        return static_cast<uint64_t>(-EFAULT);
      }
      return ::clock_getres(clock_id, guest_timespec) == 0 ? 0 : linux_error_result();
    }
    case MinimalSyscallNumber::clock_nanosleep:
      return handle_clock_nanosleep(
        static_cast<int>(args->Argument[1]),
        static_cast<int>(args->Argument[2]),
        args->Argument[3],
        args->Argument[4]
      );
    case MinimalSyscallNumber::pipe2:
      return handle_pipe(args->Argument[1], static_cast<int>(args->Argument[2]));
    case MinimalSyscallNumber::ppoll:
      return handle_ppoll(
        args->Argument[1],
        args->Argument[2],
        args->Argument[3],
        args->Argument[4],
        static_cast<size_t>(args->Argument[5])
      );
    case MinimalSyscallNumber::prlimit64:
      return handle_prlimit64(
        args->Argument[1],
        static_cast<int>(args->Argument[2]),
        args->Argument[3],
        args->Argument[4]
      );
    case MinimalSyscallNumber::getdents64:
      return handle_getdents64(
        static_cast<int>(args->Argument[1]),
        args->Argument[2],
        static_cast<size_t>(args->Argument[3])
      );
    case MinimalSyscallNumber::openat: {
      const int guest_dirfd = static_cast<int>(args->Argument[1]);
      const int dirfd = guest_dirfd == kLinuxAtFDCWD ? AT_FDCWD : guest_dirfd;
      const char* guest_path = reinterpret_cast<const char*>(args->Argument[2]);
      const auto translated_path = dirfd == AT_FDCWD
        ? translate_guest_path(guest_path)
        : std::string(guest_path != nullptr ? guest_path : "");
      const char* path = translated_path.c_str();
      const int flags = darwin_open_flags(static_cast<int>(args->Argument[3]));
      if (flags < 0) {
        if (trace_syscalls) {
          std::fprintf(stderr, "[IridiumFEX:syscall] openat dirfd=%d path=\"%s\" flags=0x%x result=0x%llx errno=%d\n", dirfd, path, static_cast<int>(args->Argument[3]), static_cast<unsigned long long>(linux_error_result()), errno);
        }
        return linux_error_result();
      }
      const int mode = static_cast<int>(args->Argument[4]);
      const int result = ::openat(dirfd, path, flags, mode);
      if (result < 0) {
        if (trace_syscalls) {
          std::fprintf(stderr, "[IridiumFEX:syscall] openat dirfd=%d path=\"%s\" flags=0x%x result=0x%llx errno=%d\n", dirfd, path, static_cast<int>(args->Argument[3]), static_cast<unsigned long long>(linux_error_result()), errno);
        }
        return linux_error_result();
      }
      if (trace_syscalls) {
        std::fprintf(stderr, "[IridiumFEX:syscall] openat dirfd=%d path=\"%s\" flags=0x%x result=%d\n", dirfd, path, static_cast<int>(args->Argument[3]), result);
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::newfstatat: {
      const int guest_dirfd = static_cast<int>(args->Argument[1]);
      const int dirfd = guest_dirfd == kLinuxAtFDCWD ? AT_FDCWD : guest_dirfd;
      const char* guest_path = reinterpret_cast<const char*>(args->Argument[2]);
      const auto translated_path = dirfd == AT_FDCWD
        ? translate_guest_path(guest_path)
        : std::string(guest_path != nullptr ? guest_path : "");
      const char* path = translated_path.c_str();
      const int guest_flags = static_cast<int>(args->Argument[4]);
      struct stat host_stat {};
      if ((guest_flags & kLinuxAtEmptyPath) == kLinuxAtEmptyPath && path != nullptr && path[0] == '\0') {
        if (::fstat(dirfd, &host_stat) != 0) {
          if (trace_syscalls) {
            std::fprintf(stderr, "[IridiumFEX:syscall] newfstatat dirfd=%d path=\"\" flags=0x%x result=0x%llx errno=%d\n", dirfd, guest_flags, static_cast<unsigned long long>(linux_error_result()), errno);
          }
          return linux_error_result();
        }
        const uint64_t result = write_linux_stat(host_stat, args->Argument[3]);
        if (trace_syscalls) {
          std::fprintf(stderr, "[IridiumFEX:syscall] newfstatat dirfd=%d path=\"\" flags=0x%x result=0x%llx\n", dirfd, guest_flags, static_cast<unsigned long long>(result));
        }
        return result;
      }

      const int flags = darwin_fstatat_flags(guest_flags);
      if (flags < 0) {
        if (trace_syscalls) {
          std::fprintf(stderr, "[IridiumFEX:syscall] newfstatat dirfd=%d path=\"%s\" flags=0x%x result=0x%llx errno=%d\n", dirfd, path, guest_flags, static_cast<unsigned long long>(linux_error_result()), errno);
        }
        return linux_error_result();
      }
      if (::fstatat(dirfd, path, &host_stat, flags) != 0) {
        if (trace_syscalls) {
          std::fprintf(stderr, "[IridiumFEX:syscall] newfstatat dirfd=%d path=\"%s\" flags=0x%x result=0x%llx errno=%d\n", dirfd, path, guest_flags, static_cast<unsigned long long>(linux_error_result()), errno);
        }
        return linux_error_result();
      }
      const uint64_t result = write_linux_stat(host_stat, args->Argument[3]);
      if (trace_syscalls) {
        std::fprintf(stderr, "[IridiumFEX:syscall] newfstatat dirfd=%d path=\"%s\" flags=0x%x result=0x%llx\n", dirfd, path, guest_flags, static_cast<unsigned long long>(result));
      }
      return result;
    }
    case MinimalSyscallNumber::readlinkat: {
      const int guest_dirfd = static_cast<int>(args->Argument[1]);
      const int dirfd = guest_dirfd == kLinuxAtFDCWD ? AT_FDCWD : guest_dirfd;
      const char* guest_path = reinterpret_cast<const char*>(args->Argument[2]);
      const auto translated_path = dirfd == AT_FDCWD
        ? translate_guest_path(guest_path)
        : std::string(guest_path != nullptr ? guest_path : "");
      const char* path = translated_path.c_str();
      char* buffer = reinterpret_cast<char*>(args->Argument[3]);
      const size_t size = static_cast<size_t>(args->Argument[4]);
      const ssize_t result = ::readlinkat(dirfd, path, buffer, size);
      if (result < 0) {
        return linux_error_result();
      }
      return static_cast<uint64_t>(result);
    }
    case MinimalSyscallNumber::set_robust_list:
      return 0;
    case MinimalSyscallNumber::userfaultfd:
      /* Wine probes userfaultfd as an optional Linux write-watch backend.
       * Darwin has no equivalent, so make the supported fallback explicit. */
      return static_cast<uint64_t>(-ENOSYS);
    case MinimalSyscallNumber::getcpu:
      return handle_getcpu(args->Argument[1], args->Argument[2]);
    case MinimalSyscallNumber::getrandom:
      return handle_getrandom(
        args->Argument[1],
        static_cast<size_t>(args->Argument[2]),
        static_cast<unsigned int>(args->Argument[3])
      );
    case MinimalSyscallNumber::rseq: {
      const uint64_t result = handle_rseq(args->Argument[1], args->Argument[2], args->Argument[3]);
      if (trace_syscalls) {
        std::fprintf(
          stderr,
          "[IridiumFEX:syscall] nr=%llu result=0x%llx\n",
          static_cast<unsigned long long>(args->Argument[0]),
          static_cast<unsigned long long>(result)
        );
      }
      return result;
    }
    case MinimalSyscallNumber::faccessat2:
      return handle_faccessat2(
        static_cast<int>(args->Argument[1]),
        reinterpret_cast<const char*>(args->Argument[2]),
        static_cast<int>(args->Argument[3]),
        static_cast<int>(args->Argument[4])
      );
    case MinimalSyscallNumber::iridium_spawn_host_wineserver:
      return handle_iridium_spawn_host_wineserver(args->Argument[1], args->Argument[2]);
    case MinimalSyscallNumber::iridium_windows_process_started:
      emit_runtime_milestone("windowsProcessStarted");
      return 0;
  }

  static std::mutex unsupported_syscall_mutex;
  static std::set<uint64_t> reported_unsupported_syscalls;
  {
    const std::lock_guard<std::mutex> lock(unsupported_syscall_mutex);
    if (reported_unsupported_syscalls.insert(args->Argument[0]).second) {
      std::fprintf(
        stderr,
        "iridium-fex-ios: unsupported Linux guest syscall nr=%llu; returning ENOSYS\n",
        static_cast<unsigned long long>(args->Argument[0])
      );
    }
  }
  return unsupported_syscall();
}

extern "C" int iridium_fex_ios_signal_guest_thread(
  uint64_t guest_thread_identifier,
  int signal_number
) {
  if (guest_thread_identifier == 0) {
    return EINVAL;
  }
  if (signal_number != SIGUSR1 && signal_number != SIGQUIT) {
    return ENOTSUP;
  }

  std::shared_ptr<std::atomic_bool> stop_requested;
  {
    const std::lock_guard<std::mutex> lock(guest_signal_targets_mutex);
    const auto target = guest_signal_targets.find(guest_thread_identifier);
    if (target == guest_signal_targets.end() || target->second.pending_signal == nullptr) {
      return ESRCH;
    }
    target->second.pending_signal->store(signal_number, std::memory_order_release);
    stop_requested = target->second.stop_requested;
  }

  if (signal_number == SIGQUIT && stop_requested) {
    stop_requested->store(true, std::memory_order_release);
  }
  {
    const std::lock_guard<std::mutex> lock(futex_wait_mutex);
    ++futex_wake_generation;
  }
  futex_wait_condition.notify_all();
  return 0;
}

FEXCore::HLE::ExecutableRangeInfo MinimalDarwinSyscallHandler::QueryGuestExecutableRange(
  FEXCore::Core::InternalThreadState*,
  uint64_t
) {
  return {0, UINT64_MAX, true};
}

std::optional<FEXCore::ExecutableFileSectionInfo> MinimalDarwinSyscallHandler::LookupExecutableFileSection(
  FEXCore::Core::InternalThreadState*,
  uint64_t
) {
  return std::nullopt;
}

fextl::unique_ptr<FEXCore::HLE::SyscallHandler> CreateMinimalDarwinSyscallHandler(
  std::shared_ptr<std::atomic_bool> stop_requested,
  FEX::DummyHandlers::DummySignalDelegator* signal_delegator
) {
  return fextl::make_unique<MinimalDarwinSyscallHandler>(
    std::move(stop_requested),
    signal_delegator
  );
}

void SetRuntimeMilestoneObserver(RuntimeMilestoneObserver observer, void* context) {
  runtime_milestone_observer = observer;
  runtime_milestone_context = context;
}

void SetGuestFixedMappingReservation(uintptr_t start, size_t length) {
  std::lock_guard<std::mutex> lock(guest_mapping_mutex);
  guest_fixed_mapping_reservation_start = start;
  guest_fixed_mapping_reservation_length = static_cast<uintptr_t>(length);
}

void ClearGuestFixedMappingReservation(uintptr_t start, size_t length) {
  {
    std::lock_guard<std::mutex> lock(guest_mapping_mutex);
    if (guest_fixed_mapping_reservation_start == start &&
        guest_fixed_mapping_reservation_length == static_cast<uintptr_t>(length)) {
      guest_fixed_mapping_reservation_start = 0;
      guest_fixed_mapping_reservation_length = 0;
    }
  }
  forget_guest_mapping(reinterpret_cast<void*>(start), length);
}

}  // namespace iridium::fex::ios

#endif  // IRIDIUM_FEX_IOS_ENABLE_FEXCORE
