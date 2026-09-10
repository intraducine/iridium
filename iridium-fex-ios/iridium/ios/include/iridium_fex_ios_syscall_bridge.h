#pragma once

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)

#include <FEXCore/HLE/SyscallHandler.h>
#include <FEXCore/Utils/AllocatorHooks.h>
#include <FEXCore/fextl/memory.h>

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace FEX::DummyHandlers {
class DummySignalDelegator;
}

namespace iridium::fex::ios {

enum class MinimalSyscallNumber : uint64_t {
  read = 0,
  write = 1,
  open = 2,
  close = 3,
  fstat = 5,
  poll = 7,
  lseek = 8,
  mmap = 9,
  mprotect = 10,
  munmap = 11,
  brk = 12,
  rt_sigaction = 13,
  rt_sigprocmask = 14,
  ioctl = 16,
  readv = 19,
  pread64 = 17,
  pwrite64 = 18,
  writev = 20,
  access = 21,
  pipe = 22,
  sched_yield = 24,
  dup = 32,
  dup2 = 33,
  nanosleep = 35,
  clone = 56,
  getpid = 39,
  socket = 41,
  connect = 42,
  sendmsg = 46,
  recvmsg = 47,
  socketpair = 53,
  setsockopt = 54,
  wait4 = 61,
  uname = 63,
  fcntl = 72,
  getcwd = 79,
  chdir = 80,
  fchdir = 81,
  mkdir = 83,
  symlink = 88,
  readlink = 89,
  umask = 95,
  gettimeofday = 96,
  sysinfo = 99,
  exit = 60,
  getuid = 102,
  getgid = 104,
  geteuid = 107,
  getegid = 108,
  getppid = 110,
  sigaltstack = 131,
  fstatfs = 138,
  exit_group = 231,
  prctl = 157,
  arch_prctl = 158,
  gettid = 186,
  time = 201,
  futex = 202,
  sched_setaffinity = 203,
  sched_getaffinity = 204,
  getdents64 = 217,
  set_tid_address = 218,
  clock_gettime = 228,
  clock_getres = 229,
  clock_nanosleep = 230,
  pipe2 = 293,
  prlimit64 = 302,
  getrandom = 318,
  openat = 257,
  newfstatat = 262,
  readlinkat = 267,
  set_robust_list = 273,
  getcpu = 309,
  userfaultfd = 323,
  rseq = 334,
  faccessat2 = 439,
  ppoll = 271,
  iridium_spawn_host_wineserver = 0x69726401,
  iridium_windows_process_started = 0x69726402,
};

using RuntimeMilestoneObserver = void (*)(const char* milestone, void* context);
void SetRuntimeMilestoneObserver(RuntimeMilestoneObserver observer, void* context);

// Keep a host-side placeholder for Wine's fixed startup arena while FEXCore
// initializes. Fixed guest mappings inside this range may replace the
// placeholder, but unrelated host VM regions remain protected.
void SetGuestFixedMappingReservation(uintptr_t start, size_t length);
void ClearGuestFixedMappingReservation(uintptr_t start, size_t length);

class MinimalDarwinSyscallHandler final : public FEXCore::HLE::SyscallHandler,
                                          public FEXCore::Allocator::FEXAllocOperators {
public:
  struct GuestSignalAction {
    uint64_t handler;
    uint64_t flags;
    uint64_t restorer;
    uint64_t mask;
  };

  explicit MinimalDarwinSyscallHandler(
    std::shared_ptr<std::atomic_bool> stop_requested = {},
    FEX::DummyHandlers::DummySignalDelegator* signal_delegator = nullptr
  );
  ~MinimalDarwinSyscallHandler() override;

  uint64_t HandleSyscall(FEXCore::Core::CpuStateFrame* frame, FEXCore::HLE::SyscallArguments* args) override;
  FEXCore::HLE::ExecutableRangeInfo QueryGuestExecutableRange(
    FEXCore::Core::InternalThreadState* thread,
    uint64_t address
  ) override;
  std::optional<FEXCore::ExecutableFileSectionInfo> LookupExecutableFileSection(
    FEXCore::Core::InternalThreadState* thread,
    uint64_t guest_address
  ) override;

private:
  struct ManagedGuestThread;
  uint64_t HandleClone(
    FEXCore::Core::CpuStateFrame* frame,
    uint64_t flags,
    uint64_t child_stack,
    uint64_t parent_tid,
    uint64_t child_tid,
    uint64_t tls
  );
  void StopManagedGuestThreads(FEXCore::Core::InternalThreadState* except_thread = nullptr);
  void RegisterMainGuestThreadSignalTarget();

  std::array<GuestSignalAction, 65> signal_actions_ {};
  uint64_t signal_mask_ {};
  uint64_t signal_alt_stack_pointer_ {};
  uint64_t signal_alt_stack_size_ {};
  int32_t signal_alt_stack_flags_ {2};
  std::shared_ptr<std::atomic_bool> stop_requested_;
  FEX::DummyHandlers::DummySignalDelegator* signal_delegator_ {};
  std::atomic<int> main_pending_signal_ {0};
  std::atomic<uint64_t> main_guest_thread_identifier_ {0};
  std::mutex managed_guest_threads_mutex_;
  std::vector<std::unique_ptr<ManagedGuestThread>> managed_guest_threads_;
};

fextl::unique_ptr<FEXCore::HLE::SyscallHandler> CreateMinimalDarwinSyscallHandler(
  std::shared_ptr<std::atomic_bool> stop_requested = {},
  FEX::DummyHandlers::DummySignalDelegator* signal_delegator = nullptr
);

using GuestExitTrapCallback = void (*)(void* context);

struct GuestExecutionTrapResult {
  bool exited {};
  int exit_code {};
  bool fatal_signal {};
  int signal_number {};
  uintptr_t fault_address {};
  uintptr_t host_pc {};
};

bool RunWithGuestExitTrap(GuestExitTrapCallback callback, void* context, int& exit_code);
bool RunWithGuestExecutionTrap(GuestExitTrapCallback callback, void* context, GuestExecutionTrapResult& result);

}  // namespace iridium::fex::ios

#endif  // IRIDIUM_FEX_IOS_ENABLE_FEXCORE
