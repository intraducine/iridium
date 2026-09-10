#include "../include/iridium_fex_ios_bridge.h"
#include "../include/iridium_fex_ios_guest_loader.h"
#include "../include/iridium_fex_ios_syscall_bridge.h"
#include "iridium_fex_ios_guest_thread_state_internal.h"
#include "iridium_fex_ios_allocator_probe_internal.h"
#include "iridium_fex_ios_jit_runtime_internal.h"

#include <cerrno>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>
#include <filesystem>
#include <fcntl.h>
#include <fstream>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <pthread.h>
#include <sstream>
#include <spawn.h>
#include <string>
#include <sys/wait.h>
#include <thread>
#include <utility>
#include <vector>
#include <unistd.h>

#ifndef _WIN32
#include <sys/mman.h>
#endif

#if defined(__APPLE__)
#include <crt_externs.h>
#include <mach/mach.h>
#include <TargetConditionals.h>
#endif

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
#include "Common/Config.h"
#include "Common/HostFeatures.h"
#if !defined(IRIDIUM_FEX_IOS_EMBEDDED)
#include "Common/Linux/SBRKAllocations.h"
#endif
#include "DummyHandlers.h"

#include <FEXCore/Config/Config.h>
#include <FEXCore/Core/Context.h>
#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Debug/InternalThreadState.h>
#include <FEXCore/Utils/Allocator.h>
#include <FEXCore/Utils/AllocatorHooks.h>
#include <FEXCore/Utils/Profiler.h>
#include <FEXCore/Utils/TypeDefines.h>
#include <FEXCore/fextl/string.h>

#endif

namespace fs = std::filesystem;

namespace {

struct LaunchConfiguration {
  std::string translator_binary;
  std::string executable_path;
  std::string runtime_bundle_root;
  std::string prefix_root;
  std::string environment_file_path;
  std::string launch_mode;
  std::string windows_guest_architecture;
  std::map<std::string, std::string> environment;
  std::string userland_root;
  std::string guest_loader_binary;
  std::string wine_binary;
  std::string config_root;
  std::string data_root;
  std::string cache_root;
  std::vector<std::string> launch_arguments;
};

struct SessionLifecycleSnapshot {
  std::string state;
  std::string status_summary;
};

struct SessionState {
  std::string identifier;
  std::vector<SessionLifecycleSnapshot> lifecycle;
  size_t poll_index {0};
  std::string poll_state_cache;
  std::string poll_status_summary_cache;
  bool succeeded {false};
  bool process_started {false};
  bool wine_server_ready {false};
  bool windows_process_started {false};
  bool first_frame_presented {false};
  bool terminal_recorded {false};
  pid_t child_pid {-1};
  std::shared_ptr<std::atomic_bool> stop_requested {std::make_shared<std::atomic_bool>(false)};
  std::shared_ptr<std::thread> guest_thread;
  std::shared_ptr<iridium::ios::ScopedJITExceptionPorts> jit_exception_ports;
#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
  FEXCore::Core::InternalThreadState* active_thread {nullptr};
#endif
  std::string terminal_state {"failed"};
  std::string failure_code {"runtimeBootFailed"};
  std::string failure_reason {"Embedded FEX execution has not completed."};
  LaunchConfiguration configuration;
  std::mutex mutex;
};

std::mutex g_sessions_mutex;
std::map<std::string, std::shared_ptr<SessionState>> g_sessions;
std::mutex g_spawn_mutex;

std::map<std::string, std::string> current_process_environment();

bool file_exists(const char* path) {
  return path != nullptr && path[0] != '\0' && access(path, F_OK) == 0;
}

#if !(defined(__APPLE__) && TARGET_OS_IPHONE)
bool file_is_executable(const char* path) {
  return path != nullptr && path[0] != '\0' && access(path, X_OK) == 0;
}
#endif

bool file_is_launchable(const std::string& path) {
  if (path.empty()) {
    return false;
  }
#if defined(__APPLE__) && TARGET_OS_IPHONE
  return file_exists(path.c_str());
#else
  return file_is_executable(path.c_str());
#endif
}

bool directory_exists(const char* path) {
  if (path == nullptr || path[0] == '\0') {
    return false;
  }

  return access(path, F_OK) == 0 && access(path, X_OK) == 0;
}

bool string_equals(const char* value, const char* expected) {
  return value != nullptr && std::string(value) == expected;
}

bool string_equals(const std::string& value, const char* expected) {
  return value == expected;
}

std::string join_path(const std::string& lhs, const std::string& rhs) {
  if (lhs.empty()) {
    return rhs;
  }
  if (lhs.back() == '/') {
    return lhs + rhs;
  }
  return lhs + "/" + rhs;
}

std::string filename_from_path(const std::string& path) {
  const auto separator = path.find_last_of('/');
  if (separator == std::string::npos) {
    return path;
  }
  return path.substr(separator + 1);
}

bool ensure_directory(const std::string& path) {
  if (path.empty()) {
    return false;
  }

  std::error_code error;
  fs::create_directories(path, error);
  return !error && fs::is_directory(path, error);
}

void write_error(char* buffer, size_t buffer_size, const char* message) {
  if (buffer == nullptr || buffer_size == 0) {
    return;
  }
  std::strncpy(buffer, message, buffer_size - 1);
  buffer[buffer_size - 1] = '\0';
}

bool is_ready_status(const char* jit_status) {
  if (jit_status == nullptr || jit_status[0] == '\0') {
    return false;
  }
  return string_equals(jit_status, "ready");
}

bool bootstrap_bypass_enabled() {
  const char* value = std::getenv("IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY");
  return value != nullptr && std::string(value) == "1";
}

bool smoke_execution_mode_enabled() {
  const char* value = std::getenv("IRIDIUM_FEX_IOS_SMOKE_EXECUTION");
  return value != nullptr && std::string(value) == "1";
}

size_t stderr_capture_stress_bytes() {
  const char* value = std::getenv("IRIDIUM_FEX_IOS_TEST_WRITE_STDERR_BYTES");
  if (value == nullptr || value[0] == '\0') {
    return 0;
  }

  char* end = nullptr;
  errno = 0;
  const auto parsed = std::strtoull(value, &end, 10);
  if (errno != 0 || end == value || (end != nullptr && *end != '\0')) {
    return 0;
  }
  return static_cast<size_t>(std::min<unsigned long long>(
    parsed,
    static_cast<unsigned long long>(std::numeric_limits<size_t>::max())
  ));
}

#if !defined(__APPLE__)
constexpr uintptr_t kDefaultWindowsSharedDataAddress = 0x7ffe0000ULL;
#endif
// Keep the in-process guest alias clear of the app image and dyld shared-cache
// ranges, which occupy the low addresses immediately above Darwin's 4 GiB
// __PAGEZERO on physical iOS devices. This remains within arm64 Darwin's user
// address space and is aligned to both Wine's 4 KiB and iOS's 16 KiB pages.
constexpr uintptr_t kDarwinFallbackWindowsSharedDataAddress = 0x7000000000ULL;
constexpr size_t kWindowsSharedDataSize = 0x1000;
// iOS reserves the host range immediately below 0x7000000000. Secure PE-image
// space above the relocated shared-data/TEB range before FEXCore initializes,
// then let guest MAP_FIXED calls replace pages inside that placeholder. This
// must match Wine's IRIDIUM_GUEST_IMAGE_ARENA_SIZE.
constexpr size_t kWindowsGuestImageArenaSize = 0x80000000ULL;
// Must match Wine's IRIDIUM_USER_SHARED_DATA_RESERVE_SIZE. The reservation
// includes KUSER_SHARED_DATA, its syscall thunk, the iOS TEB arena, and room
// for Wine's virtual-address tracking heap.
constexpr size_t kWindowsSharedDataReservationSize = 0x04010000;

uintptr_t windows_startup_arena_start(uintptr_t windows_shared_data_address) {
  return windows_shared_data_address;
}

uintptr_t windows_startup_arena_end(uintptr_t windows_shared_data_address) {
  const size_t image_arena_size =
#if defined(__APPLE__)
    windows_shared_data_address == kDarwinFallbackWindowsSharedDataAddress
      ? kWindowsGuestImageArenaSize
      : 0;
#else
    0;
#endif
  return windows_shared_data_address + kWindowsSharedDataReservationSize + image_arena_size;
}

#if !defined(__APPLE__)
uintptr_t parse_windows_shared_data_address(const std::string& value, uintptr_t fallback) {
  if (value.empty()) {
    return fallback;
  }

  char* end = nullptr;
  errno = 0;
  const auto parsed = std::strtoull(value.c_str(), &end, 0);
  if (errno != 0 || end == value.c_str() || (end != nullptr && *end != '\0') ||
      (parsed & (kWindowsSharedDataSize - 1)) != 0) {
    return fallback;
  }
  return static_cast<uintptr_t>(parsed);
}

uintptr_t configured_windows_shared_data_address(const LaunchConfiguration& configuration) {
  const auto environment_value = configuration.environment.find("IRIDIUM_WINE_USER_SHARED_DATA_ADDRESS");
  if (environment_value != configuration.environment.end()) {
    return parse_windows_shared_data_address(environment_value->second, kDefaultWindowsSharedDataAddress);
  }
  if (const char* process_value = std::getenv("IRIDIUM_WINE_USER_SHARED_DATA_ADDRESS")) {
    return parse_windows_shared_data_address(process_value, kDefaultWindowsSharedDataAddress);
  }
  return kDefaultWindowsSharedDataAddress;
}
#endif

bool windows_shared_data_reservation_mappable(uintptr_t windows_shared_data_address, std::string* error_message) {
  const long host_page_size_value = ::sysconf(_SC_PAGESIZE);
  const auto host_page_size = host_page_size_value > 0
    ? static_cast<uintptr_t>(host_page_size_value)
    : static_cast<uintptr_t>(kWindowsSharedDataSize);
  const auto host_start = windows_startup_arena_start(windows_shared_data_address) & ~(host_page_size - 1);
  const auto host_end =
    (windows_startup_arena_end(windows_shared_data_address) + host_page_size - 1) &
    ~(host_page_size - 1);
  const auto host_length = static_cast<size_t>(host_end - host_start);

#if defined(__APPLE__)
  // MAP_FIXED replaces an existing Darwin mapping. Query first so this probe
  // cannot silently unmap a native image, shared-cache page, or app region.
  vm_address_t query_address = static_cast<vm_address_t>(host_start);
  natural_t depth = 0;
  while (query_address < static_cast<vm_address_t>(host_end)) {
    vm_address_t next_region = query_address;
    vm_size_t next_region_size = 0;
    vm_region_submap_info_data_64_t region_info {};
    mach_msg_type_number_t region_info_count = VM_REGION_SUBMAP_INFO_COUNT_64;
    const kern_return_t region_result = vm_region_recurse_64(
      mach_task_self(),
      &next_region,
      &next_region_size,
      &depth,
      reinterpret_cast<vm_region_recurse_info_t>(&region_info),
      &region_info_count
    );
    if (region_result != KERN_SUCCESS || next_region_size == 0
        || next_region >= static_cast<vm_address_t>(host_end)) {
      break;
    }
    if (region_info.is_submap) {
      query_address = next_region;
      ++depth;
      continue;
    }

    errno = EEXIST;
    if (error_message != nullptr) {
      char address_buffer[32] = {};
      char occupied_buffer[80] = {};
      std::snprintf(address_buffer, sizeof(address_buffer), "0x%llx",
                    static_cast<unsigned long long>(windows_shared_data_address));
      std::snprintf(
        occupied_buffer,
        sizeof(occupied_buffer),
        "0x%llx-0x%llx",
        static_cast<unsigned long long>(next_region),
        static_cast<unsigned long long>(next_region + next_region_size)
      );
      *error_message =
        "Host process cannot reserve Wine's required Windows startup arena at " + std::string(address_buffer) +
        " because host range " + std::string(occupied_buffer) + " is already occupied";
    }
    return false;
  }
#endif

  int map_flags = MAP_PRIVATE | MAP_ANON;
#if defined(MAP_FIXED_NOREPLACE)
  map_flags |= MAP_FIXED_NOREPLACE;
#else
  map_flags |= MAP_FIXED;
#endif

  void* mapped = ::mmap(
    reinterpret_cast<void*>(host_start),
    host_length,
    PROT_NONE,
    map_flags,
    -1,
    0
  );
  if (mapped == reinterpret_cast<void*>(host_start)) {
    ::munmap(mapped, host_length);
    return true;
  }

  const int failure_errno = errno;
  if (mapped != MAP_FAILED) {
    ::munmap(mapped, host_length);
  }
  if (error_message != nullptr) {
    char address_buffer[32] = {};
    std::snprintf(address_buffer, sizeof(address_buffer), "0x%llx",
                  static_cast<unsigned long long>(windows_shared_data_address));
    *error_message =
      "Host process cannot reserve Wine's required Windows startup arena at " + std::string(address_buffer) +
      " because the address range is unavailable: " + std::string(std::strerror(failure_errno));
  }
  return false;
}

class ScopedWindowsStartupArenaReservation final {
public:
  ScopedWindowsStartupArenaReservation() = default;
  ScopedWindowsStartupArenaReservation(const ScopedWindowsStartupArenaReservation&) = delete;
  ScopedWindowsStartupArenaReservation& operator=(const ScopedWindowsStartupArenaReservation&) = delete;

  ~ScopedWindowsStartupArenaReservation() {
    release();
  }

  bool reserve(uintptr_t windows_shared_data_address, std::string* error_message) {
    if (!windows_shared_data_reservation_mappable(windows_shared_data_address, error_message)) {
      return false;
    }

    const long host_page_size_value = ::sysconf(_SC_PAGESIZE);
    const auto host_page_size = host_page_size_value > 0
      ? static_cast<uintptr_t>(host_page_size_value)
      : static_cast<uintptr_t>(kWindowsSharedDataSize);
    const auto host_start =
      windows_startup_arena_start(windows_shared_data_address) & ~(host_page_size - 1);
    const auto host_end =
      (windows_startup_arena_end(windows_shared_data_address) + host_page_size - 1) &
      ~(host_page_size - 1);
    const auto host_length = static_cast<size_t>(host_end - host_start);

    int map_flags = MAP_PRIVATE | MAP_ANON;
#if defined(MAP_FIXED_NOREPLACE)
    map_flags |= MAP_FIXED_NOREPLACE;
#else
    map_flags |= MAP_FIXED;
#endif
    void* mapped = ::mmap(
      reinterpret_cast<void*>(host_start),
      host_length,
      PROT_NONE,
      map_flags,
      -1,
      0
    );
    if (mapped != reinterpret_cast<void*>(host_start)) {
      const int failure_errno = errno;
      if (mapped != MAP_FAILED) {
        ::munmap(mapped, host_length);
      }
      if (error_message != nullptr) {
        char address_buffer[32] = {};
        std::snprintf(
          address_buffer,
          sizeof(address_buffer),
          "0x%llx",
          static_cast<unsigned long long>(windows_shared_data_address)
        );
        *error_message =
          "Host process could not retain Wine's required Windows startup arena at " +
          std::string(address_buffer) + " across FEX initialization: " +
          std::string(std::strerror(failure_errno));
      }
      return false;
    }

    start_ = host_start;
    length_ = host_length;
    iridium::fex::ios::SetGuestFixedMappingReservation(start_, length_);
    return true;
  }

  uintptr_t start() const {
    return start_;
  }

  size_t length() const {
    return length_;
  }

private:
  void release() {
    if (length_ == 0) {
      return;
    }
    iridium::fex::ios::ClearGuestFixedMappingReservation(start_, length_);
    ::munmap(reinterpret_cast<void*>(start_), length_);
    start_ = 0;
    length_ = 0;
  }

  uintptr_t start_ {};
  size_t length_ {};
};

uintptr_t resolve_windows_shared_data_address_for_launch(const LaunchConfiguration& configuration) {
#if defined(__APPLE__)
  (void)configuration;
  // The bundled Wine PE modules use this same deterministic address. Do not
  // accept a per-title override that would desynchronize those consumers.
  return kDarwinFallbackWindowsSharedDataAddress;
#else
  const auto configured_address = configured_windows_shared_data_address(configuration);
  if (configured_address != kDefaultWindowsSharedDataAddress) {
    return configured_address;
  }

  std::string ignored_error;
  if (windows_shared_data_reservation_mappable(kDefaultWindowsSharedDataAddress, &ignored_error)) {
    return kDefaultWindowsSharedDataAddress;
  }

  return kDarwinFallbackWindowsSharedDataAddress;
#endif
}

bool syscall_bridge_available_for_guest_execution() {
  return true;
}

const char* syscall_bridge_unavailable_summary() {
  return "Embedded FEX syscall bridge is not available in this build; guest Linux syscalls cannot be routed on this platform yet.";
}

std::chrono::milliseconds delay_from_env_ms(const char* key) {
  const char* value = std::getenv(key);
  if (value == nullptr || value[0] == '\0') {
    return std::chrono::milliseconds::zero();
  }

  char* end = nullptr;
  errno = 0;
  long parsed = std::strtol(value, &end, 10);
  if (errno != 0 || end == value || (end != nullptr && *end != '\0') || parsed <= 0) {
    return std::chrono::milliseconds::zero();
  }
  if (parsed > 5000) {
    parsed = 5000;
  }
  return std::chrono::milliseconds(parsed);
}

std::chrono::milliseconds guest_thread_startup_delay() {
  return delay_from_env_ms("IRIDIUM_FEX_IOS_TEST_GUEST_THREAD_STARTUP_DELAY_MS");
}

std::chrono::milliseconds guest_thread_initialization_hold_delay() {
  return delay_from_env_ms("IRIDIUM_FEX_IOS_TEST_INITIALIZATION_HOLD_MS");
}

void configure_guest_thread_qos() {
#if defined(__APPLE__)
  pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#endif
}

std::string trim(std::string value) {
  const auto start = value.find_first_not_of(" \t\r\n");
  if (start == std::string::npos) {
    return "";
  }

  const auto end = value.find_last_not_of(" \t\r\n");
  return value.substr(start, end - start + 1);
}

std::map<std::string, std::string> load_environment_file(const char* path) {
  std::map<std::string, std::string> values;
  if (!file_exists(path)) {
    return values;
  }

  std::ifstream stream(path);
  std::string line;
  while (std::getline(stream, line)) {
    const auto separator = line.find('=');
    if (separator == std::string::npos) {
      continue;
    }

    const std::string key = trim(line.substr(0, separator));
    const std::string value = trim(line.substr(separator + 1));
    if (!key.empty()) {
      values[key] = value;
    }
  }
  return values;
}

bool ensure_prefix_root_writable(const char* prefix_root_path) {
  if (!directory_exists(prefix_root_path)) {
    return false;
  }

  const std::string probe_path = std::string(prefix_root_path) + "/.iridium-fex-write-probe";
  std::ofstream stream(probe_path, std::ios::trunc);
  if (!stream.is_open()) {
    return false;
  }
  stream << "probe\n";
  stream.close();
  return ::unlink(probe_path.c_str()) == 0;
}

struct RuntimeJITProbeResult {
  bool ready {false};
  std::string status {"required"};
  std::string backend {"none"};
  std::string session_kind {"none"};
  std::string failure_stage;
  std::string tool_recommendation {"none"};
  bool tool_bootstrap_required {false};
  std::string tool_bootstrap_kind;
  std::string tool_bootstrap_summary;
  bool exception_ports_active {false};
  std::string summary;
};

RuntimeJITProbeResult probe_runtime_jit_support(bool trusted_debugger_signal) {
#if !defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
  return RuntimeJITProbeResult {
    .ready = false,
    .status = "unavailable",
    .backend = "none",
    .summary = "Embedded FEX runtime was compiled without FEXCore support.",
  };
#else
  const auto allocator_probe = iridium::ios::probe_allocator_backend(trusted_debugger_signal);
  return RuntimeJITProbeResult {
    .ready = allocator_probe.ready,
    .status = allocator_probe.status,
    .backend = allocator_probe.backend,
    .session_kind = allocator_probe.session_kind,
    .failure_stage = allocator_probe.failure_stage,
    .tool_recommendation = allocator_probe.tool_recommendation,
    .tool_bootstrap_required = allocator_probe.tool_bootstrap_required,
    .tool_bootstrap_kind = allocator_probe.tool_bootstrap_kind,
    .tool_bootstrap_summary = allocator_probe.tool_bootstrap_summary,
    .exception_ports_active = allocator_probe.exception_ports_active,
    .summary = allocator_probe.summary,
  };
#endif
}

std::optional<std::string> detect_wine_binary(const std::string& userland_root);
std::optional<std::string> detect_preloader_companion_wine_binary(const std::string& preloader_path);

std::optional<std::string> detect_userland_root(
  const std::string& runtime_bundle_root,
  const std::map<std::string, std::string>& environment
) {
  const auto explicit_root = environment.find("IRIDIUM_USERLAND_ROOT");
  if (explicit_root != environment.end()) {
    if (directory_exists(explicit_root->second.c_str()) && detect_wine_binary(explicit_root->second).has_value()) {
      return explicit_root->second;
    }
  }

  const std::vector<std::string> candidates = {
    join_path(runtime_bundle_root, "Support/wine-userland"),
    join_path(runtime_bundle_root, "Userland/root"),
    join_path(runtime_bundle_root, "Userland/extracted"),
  };

  for (const auto& candidate : candidates) {
    if (directory_exists(candidate.c_str()) && detect_wine_binary(candidate).has_value()) {
      return candidate;
    }
  }

  return std::nullopt;
}

std::optional<std::string> detect_wine_binary(const std::string& userland_root) {
  const std::vector<std::string> candidates = {
    join_path(userland_root, "lib/wine/x86_64-unix/wine-preloader"),
    join_path(userland_root, "lib64/wine/x86_64-unix/wine-preloader"),
    join_path(userland_root, "lib/wine/x86_64-unix/wine"),
    join_path(userland_root, "lib64/wine/x86_64-unix/wine"),
    join_path(userland_root, "bin/wine64"),
    join_path(userland_root, "bin/wine"),
    join_path(userland_root, "wine64"),
    join_path(userland_root, "wine"),
    join_path(userland_root, "Contents/MacOS/wine"),
    join_path(userland_root, "Contents/Resources/wine/bin/wine64"),
    join_path(userland_root, "Contents/Resources/wine/bin/wine"),
  };

  for (const auto& candidate : candidates) {
    if (file_is_launchable(candidate)) {
      return candidate;
    }
  }

  return std::nullopt;
}

bool is_wine_preloader_path(const std::string& path) {
  const auto name = filename_from_path(path);
  return name == "wine-preloader" || name == "wine64-preloader";
}

std::optional<std::string> detect_preloader_companion_wine_binary(const std::string& preloader_path) {
  const auto parent = fs::path(preloader_path).parent_path();
  const std::vector<std::string> candidates = {
    (parent / "wine").string(),
    (parent / "wine64").string(),
  };

  for (const auto& candidate : candidates) {
    if (file_is_launchable(candidate) && !is_wine_preloader_path(candidate)) {
      return candidate;
    }
  }

  return std::nullopt;
}

std::optional<LaunchConfiguration> build_launch_configuration(
  const IridiumFEXIOSLaunchPaths* launch_paths,
  std::string* error_message
) {
  if (launch_paths == nullptr) {
    if (error_message != nullptr) {
      *error_message = "missing launch paths";
    }
    return std::nullopt;
  }

  if (!file_exists(launch_paths->translator_binary_path)) {
    if (error_message != nullptr) {
      *error_message = "translator binary is missing";
    }
    return std::nullopt;
  }
  if (!file_exists(launch_paths->executable_path)) {
    if (error_message != nullptr) {
      *error_message = "selected executable is missing";
    }
    return std::nullopt;
  }
  if (!file_exists(launch_paths->environment_file_path)) {
    if (error_message != nullptr) {
      *error_message = "environment file is missing";
    }
    return std::nullopt;
  }
  if (!directory_exists(launch_paths->prefix_root_path)) {
    if (error_message != nullptr) {
      *error_message = "prefix root is missing";
    }
    return std::nullopt;
  }
  if (!directory_exists(launch_paths->runtime_bundle_root_path)) {
    if (error_message != nullptr) {
      *error_message = "runtime bundle root is missing";
    }
    return std::nullopt;
  }
  if (!ensure_prefix_root_writable(launch_paths->prefix_root_path)) {
    if (error_message != nullptr) {
      *error_message = "prefix root is not writable";
    }
    return std::nullopt;
  }

  LaunchConfiguration configuration;
  configuration.translator_binary = launch_paths->translator_binary_path;
  configuration.executable_path = launch_paths->executable_path;
  configuration.runtime_bundle_root = launch_paths->runtime_bundle_root_path;
  configuration.prefix_root = launch_paths->prefix_root_path;
  configuration.environment_file_path = launch_paths->environment_file_path;
  configuration.launch_mode = launch_paths->launch_mode != nullptr ? launch_paths->launch_mode : "";
  configuration.windows_guest_architecture =
    launch_paths->windows_guest_architecture != nullptr ? launch_paths->windows_guest_architecture : "";
  if (launch_paths->launch_argument_count > 0) {
    if (launch_paths->launch_arguments == nullptr) {
      if (error_message != nullptr) {
        *error_message = "launch arguments are missing";
      }
      return std::nullopt;
    }
    configuration.launch_arguments.reserve(launch_paths->launch_argument_count);
    for (size_t index = 0; index < launch_paths->launch_argument_count; ++index) {
      if (launch_paths->launch_arguments[index] == nullptr) {
        if (error_message != nullptr) {
          *error_message = "launch argument is missing";
        }
        return std::nullopt;
      }
      configuration.launch_arguments.push_back(launch_paths->launch_arguments[index]);
    }
  }
  configuration.environment = current_process_environment();
  for (const auto& [key, value] : load_environment_file(launch_paths->environment_file_path)) {
    configuration.environment[key] = value;
  }

  if (!string_equals(configuration.launch_mode, "direct")) {
    if (error_message != nullptr) {
      *error_message = "launch mode must be direct";
    }
    return std::nullopt;
  }
  if (!string_equals(configuration.windows_guest_architecture, "win64")) {
    if (error_message != nullptr) {
      *error_message = "bridge only supports win64 guest launches";
    }
    return std::nullopt;
  }

  const auto prefix_iterator = configuration.environment.find("WINEPREFIX");
  if (prefix_iterator == configuration.environment.end() || prefix_iterator->second != configuration.prefix_root) {
    if (error_message != nullptr) {
      *error_message = "environment file does not bind the expected WINEPREFIX";
    }
    return std::nullopt;
  }
  const auto no_desktop_iterator = configuration.environment.find("IRIDIUM_NO_DESKTOP");
  if (no_desktop_iterator == configuration.environment.end() || no_desktop_iterator->second != "1") {
    if (error_message != nullptr) {
      *error_message = "environment file is missing IRIDIUM_NO_DESKTOP=1";
    }
    return std::nullopt;
  }
  const auto architecture_iterator = configuration.environment.find("WINEARCH");
  if (architecture_iterator == configuration.environment.end() || architecture_iterator->second != "win64") {
    if (error_message != nullptr) {
      *error_message = "environment file is missing WINEARCH=win64";
    }
    return std::nullopt;
  }

  const auto userland_root = detect_userland_root(configuration.runtime_bundle_root, configuration.environment);
  if (!userland_root.has_value()) {
    if (error_message != nullptr) {
      *error_message = "runtime bundle does not expose a Wine userland root";
    }
    return std::nullopt;
  }
  configuration.userland_root = *userland_root;

  const auto wine_binary = detect_wine_binary(configuration.userland_root);
  if (!wine_binary.has_value()) {
    if (error_message != nullptr) {
      *error_message = "runtime bundle does not expose a launchable Wine binary";
    }
    return std::nullopt;
  }
  configuration.guest_loader_binary = *wine_binary;
  configuration.wine_binary = *wine_binary;
  if (is_wine_preloader_path(configuration.guest_loader_binary)) {
    const auto companion = detect_preloader_companion_wine_binary(configuration.guest_loader_binary);
    if (!companion.has_value()) {
      if (error_message != nullptr) {
        *error_message = "wine-preloader requires a companion Unix Wine loader";
      }
      return std::nullopt;
    }
    configuration.guest_loader_binary = *companion;
    configuration.wine_binary = *companion;
  }

  configuration.config_root = join_path(configuration.prefix_root, "fex/config");
  configuration.data_root = join_path(configuration.prefix_root, "fex/data");
  configuration.cache_root = join_path(configuration.prefix_root, "fex/cache");
  return configuration;
}

int validation_status_from_error(const std::string& error_message) {
  if (error_message == "translator binary is missing") {
    return IRIDIUM_FEX_IOS_STATUS_TRANSLATOR_MISSING;
  }
  if (error_message == "selected executable is missing") {
    return IRIDIUM_FEX_IOS_STATUS_EXECUTABLE_MISSING;
  }
  if (error_message == "environment file is missing") {
    return IRIDIUM_FEX_IOS_STATUS_ENVIRONMENT_FILE_MISSING;
  }
  if (error_message == "prefix root is missing") {
    return IRIDIUM_FEX_IOS_STATUS_PREFIX_ROOT_MISSING;
  }
  if (error_message == "runtime bundle root is missing") {
    return IRIDIUM_FEX_IOS_STATUS_RUNTIME_BUNDLE_ROOT_MISSING;
  }
  if (error_message == "prefix root is not writable") {
    return IRIDIUM_FEX_IOS_STATUS_PREFIX_ROOT_NOT_WRITABLE;
  }
  if (error_message == "launch mode must be direct") {
    return IRIDIUM_FEX_IOS_STATUS_DIRECT_LAUNCH_REQUIRED;
  }
  if (error_message == "bridge only supports win64 guest launches") {
    return IRIDIUM_FEX_IOS_STATUS_GUEST_ARCHITECTURE_UNSUPPORTED;
  }
  if (error_message == "environment file does not bind the expected WINEPREFIX") {
    return IRIDIUM_FEX_IOS_STATUS_WINEPREFIX_MISMATCH;
  }
  if (error_message == "environment file is missing IRIDIUM_NO_DESKTOP=1") {
    return IRIDIUM_FEX_IOS_STATUS_NO_DESKTOP_MISSING;
  }
  if (error_message == "environment file is missing WINEARCH=win64") {
    return IRIDIUM_FEX_IOS_STATUS_WINEARCH_INVALID;
  }
  return IRIDIUM_FEX_IOS_STATUS_RUNTIME_CONTRACT_INVALID;
}

std::string next_session_identifier() {
  using clock = std::chrono::steady_clock;
  static std::atomic_uint64_t counter {0};
  std::ostringstream stream;
  stream << "embedded-fex-session-"
         << std::chrono::duration_cast<std::chrono::microseconds>(clock::now().time_since_epoch()).count()
         << "-"
         << counter.fetch_add(1, std::memory_order_relaxed) + 1;
  return stream.str();
}

std::string format_hex_address(uintptr_t address) {
  std::ostringstream stream;
  stream << "0x" << std::hex << address;
  return stream.str();
}

bool should_enable_host_split_code_allocator() {
#if defined(__APPLE__) && (!defined(TARGET_OS_IPHONE) || !TARGET_OS_IPHONE)
  return std::getenv("IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND") == nullptr
      && std::getenv("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST") == nullptr;
#else
  return false;
#endif
}

std::shared_ptr<SessionState> lookup_session(const char* session_identifier) {
  if (session_identifier == nullptr || session_identifier[0] == '\0') {
    return nullptr;
  }

  std::lock_guard<std::mutex> lock(g_sessions_mutex);
  const auto iterator = g_sessions.find(session_identifier);
  if (iterator == g_sessions.end()) {
    return nullptr;
  }
  return iterator->second;
}

#if !defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
void finalize_session(
  const std::shared_ptr<SessionState>& session,
  bool succeeded,
  std::string terminal_state,
  std::string failure_code,
  std::string failure_reason,
  std::vector<SessionLifecycleSnapshot> lifecycle
) {
  {
    std::lock_guard<std::mutex> lock(session->mutex);
    session->succeeded = succeeded;
    session->terminal_state = std::move(terminal_state);
    session->failure_code = std::move(failure_code);
    session->failure_reason = std::move(failure_reason);
    session->process_started = false;
    session->terminal_recorded = true;
    session->child_pid = -1;
    session->lifecycle = std::move(lifecycle);
    if (session->lifecycle.empty()) {
      session->lifecycle.push_back({
        session->terminal_state,
        "Embedded FEX translator did not report a session lifecycle."
      });
    }
  }
}
#endif

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
class ScopedEnvironmentOverride {
public:
  ScopedEnvironmentOverride(std::string key, std::string value)
    : key_(std::move(key)) {
    const char* existing = std::getenv(key_.c_str());
    if (existing != nullptr) {
      had_previous_ = true;
      previous_value_ = existing;
    }
    setenv(key_.c_str(), value.c_str(), 1);
  }

  ~ScopedEnvironmentOverride() {
    if (had_previous_) {
      setenv(key_.c_str(), previous_value_.c_str(), 1);
    } else {
      unsetenv(key_.c_str());
    }
  }

private:
  std::string key_;
  bool had_previous_ {false};
  std::string previous_value_;
};

class ScopedEnvironmentBlock {
public:
  explicit ScopedEnvironmentBlock(const std::vector<std::string>& entries) {
    for (const auto& entry : entries) {
      const auto separator = entry.find('=');
      if (separator == std::string::npos) {
        continue;
      }

      const auto key = entry.substr(0, separator);
      const auto value = entry.substr(separator + 1);
      if (key.empty()) {
        continue;
      }

      PreviousValue previous;
      previous.key = key;
      if (const char* current = std::getenv(key.c_str())) {
        previous.had_value = true;
        previous.value = current;
      }
      previous_values_.push_back(std::move(previous));
      setenv(key.c_str(), value.c_str(), 1);
    }
  }

  ~ScopedEnvironmentBlock() {
    for (auto iterator = previous_values_.rbegin(); iterator != previous_values_.rend(); ++iterator) {
      if (iterator->had_value) {
        setenv(iterator->key.c_str(), iterator->value.c_str(), 1);
      } else {
        unsetenv(iterator->key.c_str());
      }
    }
  }

private:
  struct PreviousValue {
    std::string key;
    bool had_value {false};
    std::string value;
  };

  std::vector<PreviousValue> previous_values_;
};

constexpr size_t kWineStderrCaptureLimitBytes = 256 * 1024;

class ScopedStderrRedirect {
public:
  explicit ScopedStderrRedirect(const std::string& path) {
    if (path.empty()) {
      return;
    }

    const int file_fd = open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (file_fd == -1) {
      return;
    }

    int pipe_fds[2] {-1, -1};
    if (pipe(pipe_fds) == -1) {
      close(file_fd);
      return;
    }

    saved_fd_ = dup(STDERR_FILENO);
    if (saved_fd_ == -1) {
      close(pipe_fds[0]);
      close(pipe_fds[1]);
      close(file_fd);
      return;
    }

    try {
      reader_ = std::thread([read_fd = pipe_fds[0], output_fd = file_fd]() {
        drain_stderr_pipe(read_fd, output_fd);
      });
    } catch (...) {
      close(saved_fd_);
      saved_fd_ = -1;
      close(pipe_fds[0]);
      close(pipe_fds[1]);
      close(file_fd);
      return;
    }

    if (dup2(pipe_fds[1], STDERR_FILENO) == -1) {
      close(saved_fd_);
      saved_fd_ = -1;
      close(pipe_fds[1]);
      if (reader_.joinable()) {
        reader_.join();
      }
      reader_ = std::thread();
      return;
    }
    close(pipe_fds[1]);
  }

  ScopedStderrRedirect(const ScopedStderrRedirect&) = delete;
  ScopedStderrRedirect& operator=(const ScopedStderrRedirect&) = delete;

  ~ScopedStderrRedirect() {
    finish();
  }

  void finish() {
    if (saved_fd_ != -1) {
      dup2(saved_fd_, STDERR_FILENO);
      close(saved_fd_);
      saved_fd_ = -1;
    }
    if (reader_.joinable()) {
      reader_.join();
    }
  }

  bool active() const {
    return saved_fd_ != -1;
  }

private:
  static void write_all(int fd, const char* data, size_t length) {
    size_t written = 0;
    while (written < length) {
      const ssize_t result = write(fd, data + written, length - written);
      if (result <= 0) {
        return;
      }
      written += static_cast<size_t>(result);
    }
  }

  static void drain_stderr_pipe(int read_fd, int output_fd) {
    size_t captured = 0;
    bool wrote_truncation_marker = false;
    char buffer[4096];
    while (true) {
      const ssize_t result = read(read_fd, buffer, sizeof(buffer));
      if (result <= 0) {
        break;
      }

      const size_t incoming = static_cast<size_t>(result);
      if (captured < kWineStderrCaptureLimitBytes) {
        const size_t writable = std::min(incoming, kWineStderrCaptureLimitBytes - captured);
        write_all(output_fd, buffer, writable);
        captured += writable;
      }

      if (captured >= kWineStderrCaptureLimitBytes && !wrote_truncation_marker) {
        static constexpr const char* marker =
          "\niridium-fex-ios: wine stderr capture truncated after 262144 bytes\n";
        write_all(output_fd, marker, std::strlen(marker));
        wrote_truncation_marker = true;
      }
    }

    close(read_fd);
    close(output_fd);
  }

  int saved_fd_ {-1};
  std::thread reader_;
};

struct RuntimeBootstrapResult {
  bool initialized {false};
  bool executable {false};
  std::string failure_code;
  std::string failure_reason;
};

void disable_sbrk_allocations_for_process() {
#if defined(IRIDIUM_FEX_IOS_EMBEDDED)
  // The embedded iPhone path is x64-only. The Linux brk guard is not needed here
  // and can fail before bootstrap completes because an app-hosted runtime does not
  // preserve Linux's early-process brk layout assumptions. The embedded CMake path
  // intentionally omits the Linux SBRK allocator implementation on every Apple
  // validation target, including the host executable tests.
#else
  static std::once_flag guard;
  std::call_once(guard, [] {
    // Embedded FEX retains mappings beyond an individual context teardown, so
    // restoring the host brk boundary can collide with those mappings. Reserve
    // it once for the lifetime of this runtime-host process instead.
    (void)FEX::SBRKAllocations::DisableSBRKAllocations();
  });
#endif
}

RuntimeBootstrapResult bootstrap_fexcore_runtime(const LaunchConfiguration& configuration) {
  RuntimeBootstrapResult result;
  if (bootstrap_bypass_enabled()) {
    result.initialized = true;
    result.executable = true;
    return result;
  }

  disable_sbrk_allocations_for_process();
  FEXCore::Allocator::GLIBCScopedFault glibc_fault_scope;
  if (!ensure_directory(configuration.config_root) ||
      !ensure_directory(configuration.data_root) ||
      !ensure_directory(configuration.cache_root)) {
    result.failure_code = "configInitializationFailed";
    result.failure_reason = "Embedded FEX runtime could not materialize prefix-scoped config directories.";
    return result;
  }

  ScopedEnvironmentOverride config_location_override("FEX_APP_CONFIG_LOCATION", configuration.config_root);
  ScopedEnvironmentOverride data_location_override("FEX_APP_DATA_LOCATION", configuration.data_root);
  ScopedEnvironmentOverride cache_location_override("FEX_APP_CACHE_LOCATION", configuration.cache_root);
  ScopedEnvironmentOverride translator_path_override("IRIDIUM_FEX_TRANSLATOR_PATH", configuration.translator_binary);

#if defined(__APPLE__)
  char** process_environment = *_NSGetEnviron();
#else
  extern char** environ;
  char** process_environment = environ;
#endif

  try {
    // FEX configuration is process-global. Rebuild it per launch under serialization
    // so InitCore/ExecuteThread always sees a fully initialized Meta layer.
    FEXCore::Config::Shutdown();
    FEX::Config::LoadConfig("iridium", process_environment, {});
    FEXCore::Config::ReloadMetaLayer();
    FEXCore::Config::Set(FEXCore::Config::CONFIG_IS64BIT_MODE, "1");
  } catch (const std::exception& exception) {
    result.failure_code = "configInitializationFailed";
    result.failure_reason = std::string("FEX config initialization failed: ") + exception.what();
    return result;
  } catch (...) {
    result.failure_code = "configInitializationFailed";
    result.failure_reason = "FEX config initialization failed: unknown exception";
    return result;
  }

  // Context creation and guest loading follow in the serialized session body;
  // this bootstrap step owns only process-global FEX configuration.
  result.initialized = true;
  result.executable = true;
  return result;
}
#endif

// ... stripped current_process_environment ...

std::map<std::string, std::string> current_process_environment() {
  std::map<std::string, std::string> values;
#if defined(__APPLE__)
  char** process_environment = *_NSGetEnviron();
#else
  extern char** environ;
  char** process_environment = environ;
#endif

  if (process_environment == nullptr) {
    return values;
  }

  for (char** entry = process_environment; *entry != nullptr; ++entry) {
    const std::string raw(*entry);
    const auto separator = raw.find('=');
    if (separator == std::string::npos) {
      continue;
    }

    values[raw.substr(0, separator)] = raw.substr(separator + 1);
  }

  return values;
}

void capture_launch_environment_if_requested(const std::map<std::string, std::string>& environment) {
  const auto capture_path = environment.find("IRIDIUM_FEX_IOS_TEST_CAPTURE_LAUNCH_ENV_PATH");
  if (capture_path == environment.end() || capture_path->second.empty()) {
    return;
  }

  std::ofstream output(capture_path->second, std::ios::trunc);
  for (const auto& [key, value] : environment) {
    output << key << "=" << value << "\n";
  }
}

std::string wine_debug_log_path(const LaunchConfiguration& configuration) {
  const auto iterator = configuration.environment.find("WINEDEBUGLOG");
  if (iterator == configuration.environment.end()) {
    return "";
  }
  return iterator->second;
}

struct ClassifiedWineFailure {
  std::string code;
  std::string reason;
};

std::optional<ClassifiedWineFailure> classify_wine_failure(
  const LaunchConfiguration& configuration,
  const std::string& debug_log_path
) {
  if (debug_log_path.empty()) {
    return std::nullopt;
  }

  std::ifstream stream(debug_log_path, std::ios::binary);
  if (!stream.is_open()) {
    return std::nullopt;
  }

  std::string contents(
    (std::istreambuf_iterator<char>(stream)),
    std::istreambuf_iterator<char>()
  );
  if (contents.find("could not exec wineserver") != std::string::npos) {
    const auto guest_server = configuration.environment.find("WINESERVER");
    const auto host_server = configuration.environment.find("IRIDIUM_WINE_HOST_WINESERVER");
    const std::string guest_path = guest_server == configuration.environment.end()
      ? "unset"
      : guest_server->second;
    const std::string host_path = host_server == configuration.environment.end()
      ? "unset"
      : host_server->second;
    return ClassifiedWineFailure {
      "wineserverLaunchFailed",
      "Wine could not start wineserver before launching the Windows process. "
        "WINESERVER=" + guest_path + " IRIDIUM_WINE_HOST_WINESERVER=" + host_path + "."
    };
  }

  // An earlier recoverable mmap failure or optional ENOSYS probe can remain in
  // Wine's debug log after execution has continued. Do not promote either
  // historical line into the terminal cause merely because the guest later
  // exits nonzero. The runtime preserves the raw trace for diagnosis and uses
  // guestProcessExited unless Wine emitted an unambiguous bootstrap failure.

  return std::nullopt;
}

void append_lifecycle_snapshot(
  const std::shared_ptr<SessionState>& session,
  std::string state,
  std::string status_summary
) {
  if (!session->lifecycle.empty()) {
    const auto& latest = session->lifecycle.back();
    if (latest.state == state && latest.status_summary == status_summary) {
      return;
    }
  }

  session->lifecycle.push_back({std::move(state), std::move(status_summary)});
}

void record_runtime_milestone(const char* milestone, void* context) {
  auto* session = static_cast<SessionState*>(context);
  if (session == nullptr || milestone == nullptr) {
    return;
  }

  std::lock_guard<std::mutex> lock(session->mutex);
  if (std::strcmp(milestone, "wineServerReady") == 0) {
    session->wine_server_ready = true;
    const std::string summary = "Native embedded Wine server is accepting guest clients.";
    if (session->lifecycle.empty() || session->lifecycle.back().state != "wineServerReady") {
      session->lifecycle.push_back({"wineServerReady", summary});
    }
  } else if (std::strcmp(milestone, "windowsProcessStarted") == 0) {
    session->windows_process_started = true;
    const std::string summary = "Wine completed Windows process initialization.";
    if (session->lifecycle.empty() || session->lifecycle.back().state != "windowsProcessStarted") {
      session->lifecycle.push_back({"windowsProcessStarted", summary});
    }
  }
}


std::vector<std::string> build_launch_environment_storage(const LaunchConfiguration& configuration) {
  // The guest thread may start after the runtime host restores scoped process
  // environment overrides, so use the environment captured at session start.
  auto merged_environment = configuration.environment;
  
  merged_environment["FEX_APP_DATA_LOCATION"] = configuration.data_root;
  merged_environment["FEX_APP_CONFIG_LOCATION"] = configuration.config_root;
  merged_environment["FEX_APP_CACHE_LOCATION"] = configuration.cache_root;
  merged_environment["IRIDIUM_FEX_TRANSLATOR_PATH"] = configuration.translator_binary;
  merged_environment["IRIDIUM_USERLAND_ROOT"] = configuration.userland_root;
  merged_environment["WINELOADERNOEXEC"] = "1";
  char shared_data_address[32] = {};
  std::snprintf(
    shared_data_address,
    sizeof(shared_data_address),
    "0x%llx",
    static_cast<unsigned long long>(resolve_windows_shared_data_address_for_launch(configuration))
  );
  merged_environment["IRIDIUM_WINE_USER_SHARED_DATA_ADDRESS"] = shared_data_address;

  capture_launch_environment_if_requested(merged_environment);

  std::vector<std::string> storage;
  storage.reserve(merged_environment.size());
  for (const auto& [key, value] : merged_environment) {
    storage.push_back(key + "=" + value);
  }

  return storage;
}

struct GuestLaunchResult {
  bool started {false};
  pid_t child_pid {-1};
  std::string failure_code;
  std::string failure_reason;
};

// Removed multi-process `launch_guest_process`.
// FEX/Wine should now be invoked in-process via thread initialization.

void record_terminal_result(const std::shared_ptr<SessionState>& session, int process_status) {
  if (session->terminal_recorded) {
    return;
  }

  session->terminal_recorded = true;
  session->process_started = false;
  session->child_pid = -1;

  if (process_status == 0) {
    session->succeeded = true;
    session->terminal_state = "completed";
    session->failure_code.clear();
    session->failure_reason.clear();
    append_lifecycle_snapshot(
      session,
      "completed",
      "Embedded FEX in-process guest exited successfully."
    );
    return;
  }

  session->succeeded = false;
  session->terminal_state = "failed";
  session->failure_code = "guestProcessExited";
  session->failure_reason = "Embedded FEX in-process guest exited with non-zero status " + std::to_string(process_status) + ".";
  append_lifecycle_snapshot(session, "failed", session->failure_reason);
}

void record_classified_terminal_failure(
  const std::shared_ptr<SessionState>& session,
  const ClassifiedWineFailure& failure
) {
  if (session->terminal_recorded) {
    return;
  }

  session->terminal_recorded = true;
  session->process_started = false;
  session->child_pid = -1;
  session->succeeded = false;
  session->terminal_state = "failed";
  session->failure_code = failure.code;
  session->failure_reason = failure.reason;
  append_lifecycle_snapshot(session, "failed", session->failure_reason);
}

void record_stop_requested_terminal_result(const std::shared_ptr<SessionState>& session) {
  if (session->terminal_recorded) {
    return;
  }

  session->terminal_recorded = true;
  session->process_started = false;
  session->child_pid = -1;
  session->succeeded = false;
  session->terminal_state = "failed";
  session->failure_code = "guestProcessExited";
  session->failure_reason = "Embedded FEX guest execution stopped after a fullscreen runtime player stop request.";
  append_lifecycle_snapshot(session, "failed", session->failure_reason);
}

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
void request_guest_thread_interrupt(const std::shared_ptr<SessionState>& session) {
  if (session == nullptr || session->active_thread == nullptr) {
    return;
  }

  FEXCore::Allocator::VirtualProtect(
    &session->active_thread->InterruptFaultPage,
    sizeof(session->active_thread->InterruptFaultPage),
    FEXCore::Allocator::ProtectOptions::Read
  );
}
#endif

void refresh_session_process_state(const std::shared_ptr<SessionState>& session, bool wait_for_completion) {
  (void)wait_for_completion;
  if (!session->process_started || session->terminal_recorded) {
    return;
  }

  // The guest thread is not enough to claim that fullscreen handoff is ready.
  // Specific lifecycle milestones below report when Wine is loaded and guest
  // execution has actually started.
}

}  // namespace

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
namespace iridium::fex::ios {

FEXCore::HostFeatures CreateEmbeddedHostFeaturesForFEX() {
  return FEX::FetchHostFeatures();
}

void ConfigureEmbeddedFEXFor64BitGuest() {
  FEXCore::Config::Set(FEXCore::Config::CONFIG_IS64BIT_MODE, "1");
  FEXCore::Config::Set(FEXCore::Config::CONFIG_TSOENABLED, "0");
  FEXCore::Config::Set(FEXCore::Config::CONFIG_VECTORTSOENABLED, "0");
  FEXCore::Config::Set(FEXCore::Config::CONFIG_MEMCPYSETTSOENABLED, "0");
  FEXCore::Config::Set(FEXCore::Config::CONFIG_DISABLE_VIXL_INDIRECT_RUNTIME_CALLS, "1");
}

void InitializeGuest64BitThreadState(FEXCore::Core::CPUState& state, GuestThreadGDT& gdt) {
  gdt = {};
  state.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_GDT] = gdt.data();
  state.segment_arrays[FEXCore::Core::CPUState::SEGMENT_ARRAY_INDEX_LDT] = gdt.data();

  state.cs_idx = FEXCore::Core::CPUState::DEFAULT_USER_CS << 3;
  auto* code_segment = FEXCore::Core::CPUState::GetSegmentFromIndex(state, state.cs_idx);
  FEXCore::Core::CPUState::SetGDTBase(code_segment, 0);
  FEXCore::Core::CPUState::SetGDTLimit(code_segment, 0xF'FFFFU);
  code_segment->L = 1;
  code_segment->D = 0;
  state.cs_cached = FEXCore::Core::CPUState::CalculateGDTBase(*code_segment);
}

bool InitializeGuestCallRetStack(void*& callret_stack_base, uint64_t& callret_sp, GuestThreadRuntimeState& runtime_state) {
  const long host_page_size_value = ::sysconf(_SC_PAGESIZE);
  const auto host_page_size = host_page_size_value > 0
    ? static_cast<std::size_t>(host_page_size_value)
    : static_cast<std::size_t>(FEXCore::Utils::FEX_PAGE_SIZE);
  const auto guard_page_size = std::max<std::size_t>(host_page_size, FEXCore::Utils::FEX_PAGE_SIZE);
  const auto allocation_size = kGuestCallRetStackSize + 2 * guard_page_size;
  auto* allocation = ::mmap(
    nullptr,
    allocation_size,
    PROT_READ | PROT_WRITE,
    MAP_PRIVATE | MAP_ANONYMOUS,
    -1,
    0
  );
  if (allocation == MAP_FAILED || allocation == nullptr) {
    return false;
  }

  FEXCore::Allocator::VirtualName("FEXMem_CallRetStacks", allocation, allocation_size);
  FEXCore::Allocator::VirtualTHPControl(allocation, allocation_size, FEXCore::Allocator::THPControl::Disable);

  auto* stack_base = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(allocation) + guard_page_size);
  auto* trailing_guard = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(stack_base) + kGuestCallRetStackSize);
  if (::mprotect(allocation, guard_page_size, PROT_NONE) != 0 ||
      ::mprotect(trailing_guard, guard_page_size, PROT_NONE) != 0) {
    ::munmap(allocation, allocation_size);
    return false;
  }

  runtime_state.callret_stack_allocation_base = allocation;
  runtime_state.callret_stack_allocation_size = allocation_size;
  callret_stack_base = stack_base;
  callret_sp = reinterpret_cast<uint64_t>(stack_base) + kGuestCallRetStackSize / 4;
  return true;
}

void DestroyGuestCallRetStack(void*& callret_stack_base, GuestThreadRuntimeState& runtime_state) {
  if (runtime_state.callret_stack_allocation_base != nullptr && runtime_state.callret_stack_allocation_size != 0) {
    ::munmap(runtime_state.callret_stack_allocation_base, runtime_state.callret_stack_allocation_size);
  }
  runtime_state.callret_stack_allocation_base = nullptr;
  runtime_state.callret_stack_allocation_size = 0;
  callret_stack_base = nullptr;
}

}  // namespace iridium::fex::ios
#endif

extern "C" int iridium_fex_ios_probe_readiness(
  const char* translator_binary_path,
  const char* jit_status,
  IridiumFEXIOSReadiness* out_readiness
) {
  if (out_readiness == nullptr) {
    return IRIDIUM_FEX_IOS_STATUS_INVALID_ARGUMENT;
  }

  const bool translator_present = file_exists(translator_binary_path);
  const RuntimeJITProbeResult runtime_jit = probe_runtime_jit_support(is_ready_status(jit_status));
  const bool jit_ready = runtime_jit.ready;
  const char* launch_status = "blocked";
  const char* status_summary = "Embedded FEX translator cannot launch yet.";
  static thread_local std::string runtime_jit_status;
  static thread_local std::string runtime_jit_summary;
  static thread_local std::string runtime_jit_backend;
  static thread_local std::string runtime_jit_session_kind;
  static thread_local std::string runtime_jit_failure_stage;
  static thread_local std::string runtime_jit_tool_recommendation;
  static thread_local std::string runtime_jit_tool_bootstrap_kind;
  static thread_local std::string runtime_jit_tool_bootstrap_summary;
  runtime_jit_status = runtime_jit.status;
  runtime_jit_backend = runtime_jit.backend;
  runtime_jit_session_kind = runtime_jit.session_kind;
  runtime_jit_failure_stage = runtime_jit.failure_stage;
  runtime_jit_tool_recommendation = runtime_jit.tool_recommendation;
  runtime_jit_tool_bootstrap_kind = runtime_jit.tool_bootstrap_kind;
  runtime_jit_tool_bootstrap_summary = runtime_jit.tool_bootstrap_summary;
  bool launch_ready = false;
  if (!translator_present) {
    launch_status = "translatorMissing";
    status_summary = "Embedded FEX translator archive is missing.";
  } else if (runtime_jit.status == "required") {
    launch_status = "jitRequired";
    runtime_jit_summary = runtime_jit.summary;
    status_summary = runtime_jit_summary.c_str();
  } else if (runtime_jit.status == "unavailable") {
    launch_status = runtime_jit.tool_bootstrap_required ? "jitBootstrapRequired" : "jitUnavailable";
    runtime_jit_summary = runtime_jit.summary;
    status_summary = runtime_jit_summary.c_str();
  } else if (!syscall_bridge_available_for_guest_execution()) {
    launch_status = "syscallBridgeUnavailable";
    status_summary = syscall_bridge_unavailable_summary();
  } else {
    launch_status = "bootstrapReady";
    status_summary = "JIT and embedded bootstrap are ready; Wine server, Windows process, and first-frame milestones are not yet verified.";
    launch_ready = true;
  }

  out_readiness->translator_present = translator_present ? 1 : 0;
  out_readiness->jit_required = 1;
  out_readiness->jit_ready = jit_ready ? 1 : 0;
  out_readiness->launch_ready = launch_ready ? 1 : 0;
  out_readiness->translator_status = translator_present ? "present" : "missing";
  out_readiness->jit_status = runtime_jit_status.c_str();
  out_readiness->launch_status = launch_status;
  out_readiness->status_summary = status_summary;
  out_readiness->allocator_backend = runtime_jit_backend.c_str();
  out_readiness->jit_session_kind = runtime_jit_session_kind.c_str();
  out_readiness->jit_failure_stage =
    runtime_jit_failure_stage.empty() ? nullptr : runtime_jit_failure_stage.c_str();
  out_readiness->tool_bootstrap_required = runtime_jit.tool_bootstrap_required ? 1 : 0;
  out_readiness->exception_ports_active = runtime_jit.exception_ports_active ? 1 : 0;
  out_readiness->jit_tool_recommendation =
    runtime_jit_tool_recommendation.empty() ? nullptr : runtime_jit_tool_recommendation.c_str();
  out_readiness->tool_bootstrap_kind =
    runtime_jit_tool_bootstrap_kind.empty() ? nullptr : runtime_jit_tool_bootstrap_kind.c_str();
  out_readiness->tool_bootstrap_summary =
    runtime_jit_tool_bootstrap_summary.empty() ? nullptr : runtime_jit_tool_bootstrap_summary.c_str();
  return IRIDIUM_FEX_IOS_STATUS_OK;
}

extern "C" int iridium_fex_ios_probe_allocator(
  const char* jit_status,
  IridiumFEXIOSAllocatorProbe* out_probe
);

extern "C" int iridium_fex_ios_validate_launch(
  const IridiumFEXIOSLaunchPaths* launch_paths,
  char* error_buffer,
  size_t error_buffer_size
) {
  if (launch_paths == nullptr) {
    write_error(error_buffer, error_buffer_size, "missing launch paths");
    return IRIDIUM_FEX_IOS_STATUS_INVALID_ARGUMENT;
  }

  std::string error_message;
  const auto configuration = build_launch_configuration(launch_paths, &error_message);
  if (!configuration.has_value()) {
    write_error(error_buffer, error_buffer_size, error_message.c_str());
    return validation_status_from_error(error_message);
  }

  write_error(error_buffer, error_buffer_size, "");
  return IRIDIUM_FEX_IOS_STATUS_OK;
}

extern "C" int iridium_fex_ios_start_guest_execution(
  const IridiumFEXIOSLaunchPaths* launch_paths,
  const char* jit_status,
  char* session_identifier_buffer,
  size_t session_identifier_buffer_size,
  char* error_buffer,
  size_t error_buffer_size
) {
  const int validation_result = iridium_fex_ios_validate_launch(
    launch_paths,
    error_buffer,
    error_buffer_size
  );
  if (validation_result != 0) {
    return validation_result;
  }

  const RuntimeJITProbeResult runtime_jit = probe_runtime_jit_support(is_ready_status(jit_status));
  if (!runtime_jit.ready) {
    write_error(error_buffer, error_buffer_size, runtime_jit.summary.c_str());
    return IRIDIUM_FEX_IOS_STATUS_JIT_NOT_READY;
  }

  const bool lightweight_debugger_check = iridium::ios::looks_like_xcode_debug_launch();

  if (lightweight_debugger_check) {
    const auto xcode_metadata = iridium::ios::resolve_jit_runtime_metadata(
      runtime_jit.session_kind.empty() ? std::string("debugger-backed") : runtime_jit.session_kind,
      true,
      true,
      true
    );
    const std::string summary = xcode_metadata.tool_bootstrap_summary.empty()
      ? std::string("Xcode-attached JIT checks use lightweight debugger detection only. Direct launch stays blocked until the embedded runtime backend is validated outside the Xcode check flow.")
      : xcode_metadata.tool_bootstrap_summary;
    write_error(error_buffer, error_buffer_size, summary.c_str());
    return IRIDIUM_FEX_IOS_STATUS_JIT_NOT_READY;
  }

  std::string error_message;
  const auto configuration = build_launch_configuration(launch_paths, &error_message);
  if (!configuration.has_value()) {
    write_error(error_buffer, error_buffer_size, error_message.c_str());
    return IRIDIUM_FEX_IOS_STATUS_RUNTIME_CONTRACT_INVALID;
  }

  const auto session = std::make_shared<SessionState>();
  session->identifier = next_session_identifier();
  session->configuration = *configuration;
  if (const char* requested_session_identifier = std::getenv("IRIDIUM_RUNTIME_SESSION_ID");
      requested_session_identifier != nullptr && requested_session_identifier[0] != '\0') {
    session->identifier = requested_session_identifier;
  }

  std::string exception_port_failure_stage;
  std::string exception_port_failure_summary;
  session->jit_exception_ports = iridium::ios::ScopedJITExceptionPorts::Install(
    runtime_jit.session_kind,
    iridium::ios::looks_like_xcode_debug_launch(),
    &exception_port_failure_stage,
    &exception_port_failure_summary
  );
  if (!exception_port_failure_stage.empty()) {
    write_error(
      error_buffer,
      error_buffer_size,
      exception_port_failure_summary.empty()
        ? exception_port_failure_stage.c_str()
        : exception_port_failure_summary.c_str()
    );
    return IRIDIUM_FEX_IOS_STATUS_JIT_NOT_READY;
  }

  // Phase 2C: Initialize FEXCore context and load guest binary in-process
  session->lifecycle = {
    {
      "accepted",
      "Embedded FEX translator accepted the direct win64 launch request."
    }
  };

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
  // Create a guest execution thread that loads the Wine binary and runs it
  session->guest_thread = std::make_shared<std::thread>([session]() {
    configure_guest_thread_qos();
    {
      std::lock_guard<std::mutex> lock(session->mutex);
      append_lifecycle_snapshot(
        session,
        "waitingForSpawnLock",
        "Embedded FEX guest thread is waiting for serialized bootstrap access."
      );
    }
    std::unique_lock<std::mutex> execution_lock(g_spawn_mutex);
    LaunchConfiguration configuration;
    const auto startup_delay = guest_thread_startup_delay();
    if (startup_delay.count() > 0) {
      std::this_thread::sleep_for(startup_delay);
    }
    const bool smoke_mode = smoke_execution_mode_enabled();
    {
      std::lock_guard<std::mutex> lock(session->mutex);
      if (session->stop_requested->load(std::memory_order_acquire)) {
        record_stop_requested_terminal_result(session);
        return;
      }

      session->process_started = true;
      configuration = session->configuration;
      if (!smoke_mode) {
          append_lifecycle_snapshot(
            session,
            "initializing",
            "Embedded FEX is initializing FEXCore runtime and loading Wine binary."
          );
      }
    }
    const auto initialization_hold = guest_thread_initialization_hold_delay();
    if (initialization_hold.count() > 0) {
      std::this_thread::sleep_for(initialization_hold);
    }

    try {
      if (smoke_mode) {
        std::lock_guard<std::mutex> lock(session->mutex);
        if (session->stop_requested->load(std::memory_order_acquire)) {
          record_stop_requested_terminal_result(session);
          return;
        }

        append_lifecycle_snapshot(
          session,
          "running",
          "Smoke mode skipped FEXCore initialization and marked guest execution as running."
        );
        record_terminal_result(session, 0);
        return;
      }

      const auto shared_data_address = resolve_windows_shared_data_address_for_launch(configuration);
      std::string shared_data_error;
      ScopedWindowsStartupArenaReservation startup_arena_reservation;
      if (!startup_arena_reservation.reserve(shared_data_address, &shared_data_error)) {
        throw std::runtime_error(shared_data_error);
      }
      {
        char reservation_summary[192] = {};
        std::snprintf(
          reservation_summary,
          sizeof(reservation_summary),
          "Reserved Wine startup arena at 0x%llx-0x%llx across FEX initialization.",
          static_cast<unsigned long long>(startup_arena_reservation.start()),
          static_cast<unsigned long long>(
            startup_arena_reservation.start() + startup_arena_reservation.length()
          )
        );
        std::lock_guard<std::mutex> lock(session->mutex);
        append_lifecycle_snapshot(session, "initializing", reservation_summary);
      }

      std::unique_ptr<ScopedEnvironmentOverride> preallocated_pool_override;
#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
      if (std::getenv("IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND") == nullptr) {
        preallocated_pool_override = std::make_unique<ScopedEnvironmentOverride>(
          "IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND",
          "preallocated-rx-rw"
        );
      }
#endif

      const auto bootstrap = bootstrap_fexcore_runtime(configuration);
      if (!bootstrap.initialized || !bootstrap.executable) {
        std::lock_guard<std::mutex> lock(session->mutex);
        session->succeeded = false;
        session->terminal_state = "failed";
        session->failure_code = bootstrap.failure_code.empty() ? "configInitializationFailed" : bootstrap.failure_code;
        session->failure_reason = bootstrap.failure_reason.empty()
          ? "Embedded FEX runtime bootstrap failed before guest load."
          : bootstrap.failure_reason;
        session->terminal_recorded = true;
        session->process_started = false;
        append_lifecycle_snapshot(session, "failed", session->failure_reason);
        return;
      }

      // Create FEXCore context
      std::unique_ptr<ScopedEnvironmentOverride> host_split_allocator_override;
      if (should_enable_host_split_code_allocator()) {
        host_split_allocator_override = std::make_unique<ScopedEnvironmentOverride>(
          "IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST",
          "1"
        );
      }
      iridium::fex::ios::ConfigureEmbeddedFEXFor64BitGuest();
      auto HostFeats = iridium::fex::ios::CreateEmbeddedHostFeaturesForFEX();
      auto context = FEXCore::Context::Context::CreateNewContext(HostFeats);

      if (!context) {
        throw std::runtime_error("Failed to create FEXCore context");
      }

      // FEX requires signal/syscall handlers to be set on the context before core init/execute.
      ScopedEnvironmentOverride userland_root_override("IRIDIUM_USERLAND_ROOT", configuration.userland_root);
      auto signal_delegator = FEX::DummyHandlers::CreateSignalDelegator();
      auto syscall_handler = iridium::fex::ios::CreateMinimalDarwinSyscallHandler(
        session->stop_requested,
        signal_delegator.get()
      );
      if (!signal_delegator || !syscall_handler) {
        throw std::runtime_error("Failed to create embedded signal/syscall handlers");
      }
      context->SetSignalDelegator(signal_delegator.get());
      context->SetSyscallHandler(syscall_handler.get());

      // Initialize core
      if (!context->InitCore()) {
        throw std::runtime_error("Failed to initialize FEXCore");
      }
      {
        std::lock_guard<std::mutex> lock(session->mutex);
        append_lifecycle_snapshot(
          session,
          "initializing",
          "Embedded FEXCore runtime initialized; preparing Wine launch environment."
        );
      }

      const auto launch_environment_storage = build_launch_environment_storage(configuration);
      ScopedEnvironmentBlock launch_environment_override(launch_environment_storage);
      const auto wine_debug_path = wine_debug_log_path(configuration);
      ScopedStderrRedirect wine_stderr_redirect(wine_debug_path);
      {
        std::lock_guard<std::mutex> lock(session->mutex);
        append_lifecycle_snapshot(
          session,
          "initializing",
          wine_stderr_redirect.active()
            ? "Wine stderr capture is active at " + wine_debug_path + "."
            : (
                wine_debug_path.empty()
                  ? std::string("Wine stderr capture was not requested.")
                  : "Wine stderr capture could not open " + wine_debug_path + "."
              )
        );
      }
      if (wine_stderr_redirect.active()) {
        dprintf(STDERR_FILENO, "iridium-fex-ios: wine stderr capture active\n");
        const auto stress_bytes = stderr_capture_stress_bytes();
        if (stress_bytes > 0) {
          std::string chunk(4096, 'x');
          size_t written = 0;
          while (written < stress_bytes) {
            const size_t count = std::min(chunk.size(), stress_bytes - written);
            write(STDERR_FILENO, chunk.data(), count);
            written += count;
          }
        }
      }
      std::vector<std::string> guest_args {
        configuration.guest_loader_binary,
      };
      if (is_wine_preloader_path(configuration.guest_loader_binary)) {
        guest_args.push_back(configuration.wine_binary);
      }
      guest_args.push_back(configuration.executable_path);
      for (const auto& argument : configuration.launch_arguments) {
        guest_args.push_back(argument);
      }

      // Load Wine binary and initialize guest state
      auto loader_result = iridium::fex::ios::guest::GuestBinaryLoader::LoadAndInitializeGuest(
        configuration.guest_loader_binary,
        context.get(),
        guest_args,
        launch_environment_storage
      );

      if (!loader_result.success) {
        throw std::runtime_error("Wine binary loader failed: " + loader_result.error_message);
      }

      // Create main thread state with the loaded entrypoint and stack
      auto thread = context->CreateThread(loader_result.entrypoint, loader_result.stack_address);
      if (!thread) {
        throw std::runtime_error("Failed to create guest thread state");
      }
      iridium::fex::ios::GuestThreadRuntimeState guest_thread_runtime_state {};
      iridium::fex::ios::InitializeGuest64BitThreadState(thread->CurrentFrame->State, guest_thread_runtime_state.gdt);
      if (!iridium::fex::ios::InitializeGuestCallRetStack(
            thread->CallRetStackBase,
            thread->CurrentFrame->State.callret_sp,
            guest_thread_runtime_state
          )) {
        context->DestroyThread(thread);
        throw std::runtime_error("Failed to initialize guest call-ret stack");
      }

      signal_delegator->RegisterTLSState(thread);

      {
        std::lock_guard<std::mutex> lock(session->mutex);
        session->active_thread = thread;
        append_lifecycle_snapshot(
          session,
          "loaded",
          "Wine binary loaded in guest memory and thread state initialized."
        );
        append_lifecycle_snapshot(
          session,
          "executing",
          "Embedded FEX guest execution started."
        );
      }

      execution_lock.unlock();

      if (smoke_execution_mode_enabled()) {
        std::lock_guard<std::mutex> lock(session->mutex);
        signal_delegator->UninstallTLSState(thread);
        iridium::fex::ios::DestroyGuestCallRetStack(thread->CallRetStackBase, guest_thread_runtime_state);
        session->active_thread = nullptr;
        context->DestroyThread(thread);
        record_terminal_result(session, 0);
        return;
      }

      struct ExecuteThreadTrapContext {
        FEXCore::Context::Context* context;
        FEXCore::Core::InternalThreadState* thread;
      } execute_trap_context {
        context.get(),
        thread,
      };
      iridium::fex::ios::GuestExecutionTrapResult execution_result {};
      iridium::fex::ios::SetRuntimeMilestoneObserver(record_runtime_milestone, session.get());
      iridium::fex::ios::RunWithGuestExecutionTrap(
        [](void* raw_context) {
          auto* trap_context = static_cast<ExecuteThreadTrapContext*>(raw_context);
          trap_context->context->ExecuteThread(trap_context->thread);
        },
        &execute_trap_context,
        execution_result
      );
      iridium::fex::ios::SetRuntimeMilestoneObserver(nullptr, nullptr);
      const uint64_t fatal_signal_guest_rip = execution_result.fatal_signal
        ? context->RestoreRIPFromHostPC(thread, execution_result.host_pc)
        : 0;
      signal_delegator->UninstallTLSState(thread);
      iridium::fex::ios::DestroyGuestCallRetStack(thread->CallRetStackBase, guest_thread_runtime_state);
      {
        std::lock_guard<std::mutex> lock(session->mutex);
        session->active_thread = nullptr;
      }
      context->DestroyThread(thread);
      wine_stderr_redirect.finish();
      const auto classified_wine_failure = classify_wine_failure(configuration, wine_debug_path);

      if (execution_result.fatal_signal) {
        if (session->stop_requested->load(std::memory_order_acquire)) {
          std::lock_guard<std::mutex> lock(session->mutex);
          record_stop_requested_terminal_result(session);
          return;
        }
        throw std::runtime_error(
          "Guest execution trapped host signal " + std::to_string(execution_result.signal_number)
          + " at fault address " + format_hex_address(execution_result.fault_address)
          + " host PC " + format_hex_address(execution_result.host_pc)
          + " guest RIP " + format_hex_address(static_cast<uintptr_t>(fatal_signal_guest_rip))
        );
      }

      {
        std::lock_guard<std::mutex> lock(session->mutex);
        if (session->stop_requested->load(std::memory_order_acquire)) {
          record_stop_requested_terminal_result(session);
        } else if (execution_result.exited
                   && execution_result.exit_code != 0
                   && classified_wine_failure.has_value()) {
          record_classified_terminal_failure(session, *classified_wine_failure);
        } else {
          record_terminal_result(session, execution_result.exited ? execution_result.exit_code : 0);
        }
      }
    } catch (const std::exception& e) {
      std::lock_guard<std::mutex> lock(session->mutex);
      session->succeeded = false;
      session->terminal_state = "failed";
      session->failure_code = "runtimeBootFailed";
      session->failure_reason = std::string("Guest execution error: ") + e.what();
      session->terminal_recorded = true;
      session->process_started = false;
      
      append_lifecycle_snapshot(
        session,
        "failed",
        session->failure_reason
      );
    } catch (...) {
      std::lock_guard<std::mutex> lock(session->mutex);
      session->succeeded = false;
      session->terminal_state = "failed";
      session->failure_code = "runtimeBootFailed";
      session->failure_reason = "Guest execution error: unknown exception";
      session->terminal_recorded = true;
      session->process_started = false;
      append_lifecycle_snapshot(session, "failed", session->failure_reason);
    }
  });
#else
  // FEXCore not enabled; return error
  finalize_session(
    session,
    false,
    "failed",
    "fexcoreDisabled",
    "Embedded FEX runtime was compiled without FEXCore support (IRIDIUM_FEX_IOS_ENABLE_FEXCORE not set).",
    {
      {"accepted", "Embedded FEX translator accepted the direct win64 launch request."},
      {"failed", "FEXCore support not compiled in"}
    }
  );
#endif

  {
    std::lock_guard<std::mutex> lock(g_sessions_mutex);
    g_sessions[session->identifier] = session;
  }

  write_error(error_buffer, error_buffer_size, "");
  write_error(session_identifier_buffer, session_identifier_buffer_size, session->identifier.c_str());
  return IRIDIUM_FEX_IOS_STATUS_OK;
}

extern "C" int iridium_fex_ios_poll_guest_state(
  const char* session_identifier,
  IridiumFEXIOSExecutionPoll* out_poll
) {
  if (out_poll == nullptr) {
    return IRIDIUM_FEX_IOS_STATUS_INVALID_ARGUMENT;
  }

  const auto session = lookup_session(session_identifier);
  if (session == nullptr) {
    return IRIDIUM_FEX_IOS_STATUS_INVALID_ARGUMENT;
  }

  std::lock_guard<std::mutex> lock(session->mutex);
  refresh_session_process_state(session, false);
  out_poll->wine_server_ready = session->wine_server_ready ? 1 : 0;
  out_poll->windows_process_started = session->windows_process_started ? 1 : 0;
  out_poll->first_frame_presented = session->first_frame_presented ? 1 : 0;
  if (session->lifecycle.empty()) {
    session->poll_state_cache = session->terminal_recorded ? session->terminal_state : "running";
    session->poll_status_summary_cache = session->terminal_recorded
      ? "Embedded FEX in-process guest reached a terminal state."
      : "Embedded FEX in-process guest execution is mapped and running.";
    out_poll->state = session->poll_state_cache.c_str();
    out_poll->status_summary = session->poll_status_summary_cache.c_str();
    return IRIDIUM_FEX_IOS_STATUS_OK;
  }

  const size_t index = session->poll_index < session->lifecycle.size() ? session->poll_index : session->lifecycle.size() - 1;
  const auto& snapshot = session->lifecycle[index];
  if (session->poll_index > 0 && snapshot.state == "accepted") {
    if (session->terminal_recorded) {
      session->poll_state_cache = session->terminal_state;
      if (!session->lifecycle.empty()) {
        session->poll_status_summary_cache = session->lifecycle.back().status_summary;
      } else {
        session->poll_status_summary_cache = "Embedded FEX in-process guest reached a terminal state.";
      }
    } else {
      session->poll_state_cache = "running";
      session->poll_status_summary_cache = "Embedded FEX in-process guest execution is mapped and running.";
    }
  } else {
    session->poll_state_cache = snapshot.state;
    session->poll_status_summary_cache = snapshot.status_summary;
  }
  out_poll->state = session->poll_state_cache.c_str();
  out_poll->status_summary = session->poll_status_summary_cache.c_str();
  ++session->poll_index;
  return IRIDIUM_FEX_IOS_STATUS_OK;
}

extern "C" int iridium_fex_ios_collect_guest_exit(
  const char* session_identifier,
  const char* terminal_status_override,
  IridiumFEXIOSExecutionResult* out_result
) {
  (void)terminal_status_override;
  if (out_result == nullptr) {
    return IRIDIUM_FEX_IOS_STATUS_INVALID_ARGUMENT;
  }

  const auto session = lookup_session(session_identifier);
  if (session == nullptr) {
    return IRIDIUM_FEX_IOS_STATUS_INVALID_ARGUMENT;
  }

  std::shared_ptr<std::thread> join_target;
  {
    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->guest_thread && session->guest_thread->joinable()) {
      join_target = session->guest_thread;
    }
  }

  if (join_target && join_target->joinable()) {
    join_target->join();
  }

  std::lock_guard<std::mutex> lock(session->mutex);
  refresh_session_process_state(session, true);
  if (smoke_execution_mode_enabled()) {
    record_terminal_result(session, 0);
  }
  if (!session->lifecycle.empty()) {
    session->poll_index = session->lifecycle.size() - 1;
  } else {
    session->poll_index = 0;
  }
  out_result->succeeded = session->succeeded ? 1 : 0;
  out_result->terminal_state = session->terminal_state.c_str();
  out_result->failure_code = session->failure_code.empty() ? nullptr : session->failure_code.c_str();
  out_result->failure_reason = session->failure_reason.empty() ? nullptr : session->failure_reason.c_str();
  return IRIDIUM_FEX_IOS_STATUS_OK;
}

extern "C" int iridium_fex_ios_request_guest_stop(
  const char* session_identifier,
  char* error_buffer,
  size_t error_buffer_size
) {
  const auto session = lookup_session(session_identifier);
  if (session == nullptr) {
    write_error(error_buffer, error_buffer_size, "unknown embedded FEX session");
    return IRIDIUM_FEX_IOS_STATUS_INVALID_ARGUMENT;
  }

  session->stop_requested->store(true, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lock(session->mutex);
#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
    request_guest_thread_interrupt(session);
#endif
    append_lifecycle_snapshot(
      session,
      "stopping",
      "Embedded FEX guest stop requested by the fullscreen runtime player."
    );
  }

  write_error(error_buffer, error_buffer_size, "");
  return IRIDIUM_FEX_IOS_STATUS_OK;
}
