#include "iridium_fex_ios_allocator_probe_internal.h"
#include "iridium_fex_ios_jit_runtime_internal.h"

#include "../include/iridium_fex_ios_bridge.h"

#include <FEXCore/Utils/AllocatorHooks.h>

#include <array>
#include <cctype>
#include <cerrno>
#include <csetjmp>
#include <csignal>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <sstream>
#include <string>
#include <unistd.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <mach/mach_error.h>
#include <mach/mach.h>
#endif

namespace {

thread_local sigjmp_buf g_allocator_probe_jump_buffer;
thread_local volatile sig_atomic_t g_allocator_probe_signal = 0;

bool looks_like_test_harness_name(std::string program_name) {
  for (char& character : program_name) {
    character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
  }

  return program_name == "xctest"
    || program_name.find("test") != std::string::npos;
}

bool allow_test_readiness_overrides() {
  const char* explicit_test_harness = std::getenv("IRIDIUM_TEST_HARNESS");
  if (explicit_test_harness != nullptr && explicit_test_harness[0] == '1'
      && explicit_test_harness[1] == '\0') {
    return true;
  }

  const char* xctest_config = std::getenv("XCTestConfigurationFilePath");
  if (xctest_config != nullptr && xctest_config[0] != '\0') {
    return true;
  }

  const char* xctest_bundle = std::getenv("XCTestBundlePath");
  if (xctest_bundle != nullptr && xctest_bundle[0] != '\0') {
    return true;
  }

#if defined(__APPLE__)
  const char* program_name = getprogname();
  if (program_name != nullptr && program_name[0] != '\0') {
    return looks_like_test_harness_name(program_name);
  }
#endif

  return false;
}

bool env_enabled(const char* name) {
  const char* value = std::getenv(name);
  return value != nullptr && std::strcmp(value, "1") == 0;
}

std::optional<std::string> env_value(const char* name) {
  const char* value = std::getenv(name);
  if (value == nullptr || value[0] == '\0') {
    return std::nullopt;
  }
  return std::string(value);
}

bool string_equals(const std::string& value, const char* expected) {
  return value == expected;
}

std::string forced_backend_name(const std::string& fallback_backend) {
  if (!allow_test_readiness_overrides()) {
    return fallback_backend;
  }

  if (const auto override = env_value("IRIDIUM_FEX_IOS_TEST_ALLOCATOR_BACKEND")) {
    return *override;
  }

  return fallback_backend;
}

std::string forced_failure_stage(const char* fallback_stage) {
  if (!allow_test_readiness_overrides()) {
    return fallback_stage;
  }

  if (const auto override = env_value("IRIDIUM_FEX_IOS_TEST_FAILURE_STAGE")) {
    return *override;
  }

  return fallback_stage;
}

bool should_probe_real_allocator() {
#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  return true;
#else
  return env_enabled("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST") || env_value("IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND").has_value();
#endif
}

std::string format_error_detail(FEXCore::Allocator::CodeMemoryErrorDomain error_domain, int error_code) {
  if (error_code == 0 || error_domain == FEXCore::Allocator::CodeMemoryErrorDomain::None) {
    return "";
  }

  std::ostringstream stream;
#if defined(__APPLE__)
  if (error_domain == FEXCore::Allocator::CodeMemoryErrorDomain::Mach) {
    stream << mach_error_string(error_code) << " (" << error_code << ")";
    return stream.str();
  }
#endif
  stream << std::strerror(error_code) << " (" << error_code << ")";
  return stream.str();
}

bool should_skip_executable_view_probe() {
  if (env_enabled("IRIDIUM_FEX_IOS_FORCE_EXECUTION_PROBE_UNDER_DEBUGGER")) {
    return false;
  }

  if (env_enabled("IRIDIUM_FEX_IOS_SKIP_EXECUTION_PROBE")) {
    return true;
  }

#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  const auto capabilities = iridium::ios::resolve_jit_memory_capabilities();
  if (capabilities.debugger_region_protocol_required &&
      iridium::ios::debugger_region_protocol_ready(capabilities)) {
    return false;
  }
  // Without the persistent helper, skip the execution probe. Allocation + write
  // success is sufficient to confirm that JIT code pages work.  Attempting
  // to actually *execute* the probe instructions can trigger an
  // EXC_BAD_ACCESS that is handled as a kernel-level code-signing kill on
  // cooperative dispatch threads, bypassing Unix signal delivery and making
  // signal-based crash recovery impossible.
  return true;
#endif

  return iridium::ios::looks_like_xcode_debug_launch();
}

std::string resolve_session_kind(bool trusted_debugger_signal) {
  if (const auto override = env_value("IRIDIUM_FEX_IOS_JIT_SESSION_KIND")) {
    return *override;
  }

  if (env_enabled("IRIDIUM_FEX_IOS_PRIVATE_JIT_CAPABILITY")) {
    return "trollstore-private";
  }

  return trusted_debugger_signal ? "debugger-backed" : "none";
}

std::string format_unavailable_summary(const std::string& failure_stage, const std::string& detail = "") {
  std::ostringstream stream;
  stream << "Debugger session detected, but executable code allocation still failed";
  if (!failure_stage.empty()) {
    stream << ": " << failure_stage;
  }
  if (!detail.empty()) {
    stream << ": " << detail;
  }
  stream << ".";
  return stream.str();
}

void allocator_probe_signal_handler(int signal_number) {
  g_allocator_probe_signal = signal_number;
  siglongjmp(g_allocator_probe_jump_buffer, 1);
}

class ScopedAllocatorProbeSignals final {
public:
  ScopedAllocatorProbeSignals() {
    install(SIGSEGV, &PreviousSEGV);
    install(SIGBUS, &PreviousBUS);
    install(SIGILL, &PreviousILL);
    install(SIGTRAP, &PreviousTRAP);
  }

  ~ScopedAllocatorProbeSignals() {
    restore(SIGSEGV, &PreviousSEGV);
    restore(SIGBUS, &PreviousBUS);
    restore(SIGILL, &PreviousILL);
    restore(SIGTRAP, &PreviousTRAP);
  }

private:
  static void install(int signal_number, struct sigaction* previous_action) {
    struct sigaction action {};
    action.sa_handler = allocator_probe_signal_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    sigaction(signal_number, &action, previous_action);
  }

  static void restore(int signal_number, const struct sigaction* previous_action) {
    sigaction(signal_number, previous_action, nullptr);
  }

  struct sigaction PreviousSEGV {};
  struct sigaction PreviousBUS {};
  struct sigaction PreviousILL {};
  struct sigaction PreviousTRAP {};
};

iridium::ios::AllocatorProbeResult forced_probe_result() {
  iridium::ios::AllocatorProbeResult result;
  if (!allow_test_readiness_overrides()) {
    return result;
  }

  const auto forced_status = env_value("IRIDIUM_FEX_IOS_TEST_READINESS");
  if (!forced_status.has_value()) {
    return result;
  }

  result.session_kind = resolve_session_kind(true);
  const auto metadata = iridium::ios::resolve_jit_runtime_metadata(result.session_kind, true, string_equals(*forced_status, "ready"),
                                                                   iridium::ios::looks_like_xcode_debug_launch());
  result.tool_recommendation = metadata.tool_recommendation;
  result.tool_bootstrap_required = metadata.tool_bootstrap_required;
  result.tool_bootstrap_kind = metadata.tool_bootstrap_kind;
  result.tool_bootstrap_summary = metadata.tool_bootstrap_summary;

  if (string_equals(*forced_status, "ready")) {
    if (metadata.tool_bootstrap_required) {
      result.status = "unavailable";
      result.backend = forced_backend_name("debugger-mirrored-rx-rw");
      result.failure_stage = "external bootstrap required";
      result.summary = metadata.tool_bootstrap_summary.empty() ? format_unavailable_summary("external bootstrap required") :
                                                                 metadata.tool_bootstrap_summary;
      return result;
    }
    result.ready = true;
    result.allocation_succeeded = true;
    result.write_succeeded = true;
    result.execution_succeeded = true;
    result.status = "ready";
    result.backend = forced_backend_name("split-rx-rw-debugger");
    result.summary = "JIT allocator ready.";
    return result;
  }

  if (string_equals(*forced_status, "unavailable")) {
    result.status = "unavailable";
    result.backend = forced_backend_name("split-rx-rw-debugger");
    result.failure_stage = forced_failure_stage("debug-map registration failed");
    result.summary = format_unavailable_summary(result.failure_stage, "forced for testing");
    return result;
  }

  result.status = "required";
  result.backend = forced_backend_name("none");
  result.session_kind = "none";
  result.failure_stage = "debugger signal missing";
  result.summary = "No external debugger/JIT session detected.";
  return result;
}

constexpr uint32_t kProbeInstructions[] = {
  0x52800540u,
  0xD65F03C0u,
};

std::optional<std::string> attempt_helper_bootstrap_sequence(
  const std::string& bootstrap_kind,
  size_t page_size
) {
  (void)page_size;
  if (bootstrap_kind != "stikdebug-script") {
    return "Iridium does not have an automatic helper bootstrap flow for this debugger-backed JIT provider yet.";
  }

  const auto extension_install = iridium::ios::install_jit_bootstrap_extension_script(
    iridium::ios::default_jit_bootstrap_extension_script()
  );
  if (!extension_install.handled || extension_install.value == 0) {
    return extension_install.failure_summary.empty()
      ? std::optional<std::string>("Iridium helper bootstrap could not install its follow-up debugger script.")
      : std::optional<std::string>(extension_install.failure_summary);
  }

  const auto detach_config = iridium::ios::configure_jit_bootstrap_detach_after_first_breakpoint(false);
  if (!detach_config.handled || detach_config.value == 0) {
    return detach_config.failure_summary.empty()
      ? std::optional<std::string>("Iridium helper bootstrap could not configure the debugger detach policy.")
      : std::optional<std::string>(detach_config.failure_summary);
  }

  // The real allocator probe below prepares and tests the shared pool.
  // A separate helper allocation leaked one executable page on every refresh.
  return std::nullopt;
}

} // namespace

namespace iridium::ios {

AllocatorProbeResult probe_allocator_backend(bool trusted_debugger_signal) {
  if (allow_test_readiness_overrides()) {
    if (const auto forced_status = env_value("IRIDIUM_FEX_IOS_TEST_READINESS")) {
      return forced_probe_result();
    }
  }

  if (!trusted_debugger_signal) {
    return AllocatorProbeResult {
      .status = "required",
      .backend = "none",
      .session_kind = "none",
      .failure_stage = "debugger signal missing",
      .tool_recommendation = "stikdebug",
      .summary = "No external debugger/JIT session detected.",
    };
  }

  const std::string session_kind = resolve_session_kind(trusted_debugger_signal);
  const bool xcode_debug_launch = iridium::ios::looks_like_xcode_debug_launch();
  const auto memory_capabilities = iridium::ios::resolve_jit_memory_capabilities();
  const auto metadata = iridium::ios::resolve_jit_runtime_metadata(session_kind, trusted_debugger_signal, false, xcode_debug_launch);
  auto ready_metadata = iridium::ios::resolve_jit_runtime_metadata(session_kind, trusted_debugger_signal, true, xcode_debug_launch);
  const bool skip_execution_probe = should_skip_executable_view_probe();
  const bool explicit_skip_request = env_enabled("IRIDIUM_FEX_IOS_SKIP_EXECUTION_PROBE");
  bool helper_bootstrap_completed = false;

  if (env_enabled("IRIDIUM_FEX_IOS_FORCE_JIT_UNAVAILABLE")) {
    return AllocatorProbeResult {
      .status = "unavailable",
      .backend = forced_backend_name("none"),
      .session_kind = session_kind,
      .failure_stage = forced_failure_stage("forced unavailable for testing"),
      .tool_recommendation = metadata.tool_recommendation,
      .summary = format_unavailable_summary(forced_failure_stage("forced unavailable for testing")),
    };
  }

  if (session_kind == "debugger-backed" && memory_capabilities.debugger_region_protocol_required &&
      !iridium::ios::debugger_region_protocol_ready(memory_capabilities)) {
    return AllocatorProbeResult {
      .status = "unavailable",
      .backend = forced_backend_name("split-rx-rw-debugger"),
      .session_kind = session_kind,
      .failure_stage = "persistent TXM callback unavailable",
      .tool_recommendation = "stikdebug",
      .tool_bootstrap_required = true,
      .tool_bootstrap_kind = "stikdebug-script",
      .tool_bootstrap_summary = metadata.tool_bootstrap_summary,
      .summary = metadata.tool_bootstrap_summary,
    };
  }

  if (env_enabled("IRIDIUM_FEX_IOS_ASSUME_BOOTSTRAP_READY") || env_enabled("IRIDIUM_FEX_IOS_SMOKE_EXECUTION")) {
    return AllocatorProbeResult {
      .ready = true,
      .allocation_succeeded = true,
      .write_succeeded = true,
      .execution_succeeded = true,
      .status = "ready",
      .backend = "none",
      .session_kind = session_kind,
      .tool_recommendation = ready_metadata.tool_recommendation,
      .tool_bootstrap_kind = ready_metadata.tool_bootstrap_kind,
      .tool_bootstrap_summary = ready_metadata.tool_bootstrap_summary,
      .summary = "JIT allocator ready.",
    };
  }

  const long page_size = ::sysconf(_SC_PAGESIZE);
  if (page_size <= 0) {
    return AllocatorProbeResult {
      .status = "unavailable",
      .backend = "none",
      .session_kind = session_kind,
      .failure_stage = "RW mapping failed",
      .tool_recommendation = metadata.tool_recommendation,
      .error_domain = "errno",
      .error_code = EINVAL,
      .summary = format_unavailable_summary("RW mapping failed", "could not resolve the host page size"),
    };
  }

  #if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  // Keep initial RX and RW pool mappings out of Wine's future startup arena.
  // VM_FLAGS_FIXED never replaces an existing mapping. Later guest sessions
  // already own this range, so only release a reservation we created here.
  struct ProbeArenaExclusion {
    vm_address_t address = 0x7000000000ULL;
    static constexpr vm_size_t size() { return 0x84010000ULL; }
    bool owned = vm_allocate(mach_task_self(), &address, size(), VM_FLAGS_FIXED) == KERN_SUCCESS;
    ~ProbeArenaExclusion() { if (owned) vm_deallocate(mach_task_self(), address, size()); }
  } arena_exclusion;
  #endif

  if (metadata.tool_bootstrap_required) {
    ScopedAllocatorProbeSignals signals;
    g_allocator_probe_signal = 0;
    if (sigsetjmp(g_allocator_probe_jump_buffer, 1) == 0) {
      if (const auto helper_failure = attempt_helper_bootstrap_sequence(metadata.tool_bootstrap_kind, static_cast<size_t>(page_size))) {
        return AllocatorProbeResult {
          .status = "unavailable",
          .backend = forced_backend_name(session_kind == "trollstore-private" ? "trollstore-private" : "debugger-mirrored-rx-rw"),
          .session_kind = session_kind,
          .failure_stage = "external bootstrap required",
          .tool_recommendation = metadata.tool_recommendation,
          .tool_bootstrap_required = true,
          .tool_bootstrap_kind = metadata.tool_bootstrap_kind,
          .tool_bootstrap_summary = metadata.tool_bootstrap_summary,
          .summary = *helper_failure,
        };
      }
      helper_bootstrap_completed = true;
      ready_metadata.tool_bootstrap_required = false;
      ready_metadata.tool_bootstrap_kind.clear();
      ready_metadata.tool_bootstrap_summary.clear();
      ready_metadata.tool_recommendation = "none";
    } else {
      std::ostringstream detail;
      detail << "signal " << g_allocator_probe_signal;
      return AllocatorProbeResult {
        .status = "unavailable",
        .backend = forced_backend_name("debugger-mirrored-rx-rw"),
        .session_kind = session_kind,
        .failure_stage = "external bootstrap required",
        .tool_recommendation = metadata.tool_recommendation,
        .tool_bootstrap_required = true,
        .tool_bootstrap_kind = metadata.tool_bootstrap_kind,
        .tool_bootstrap_summary = metadata.tool_bootstrap_summary,
        .summary = format_unavailable_summary("external bootstrap required", detail.str()),
      };
    }
  }

  if (!should_probe_real_allocator()) {
    return AllocatorProbeResult {
      .ready = true,
      .allocation_succeeded = true,
      .write_succeeded = true,
      .execution_succeeded = true,
      .status = "ready",
      .backend = "none",
      .session_kind = session_kind,
      .tool_recommendation = ready_metadata.tool_recommendation,
      .tool_bootstrap_kind = ready_metadata.tool_bootstrap_kind,
      .tool_bootstrap_summary = ready_metadata.tool_bootstrap_summary,
      .summary = "JIT allocator ready.",
    };
  }

  if (skip_execution_probe) {
    if (xcode_debug_launch && !explicit_skip_request) {
      const std::string skipped_stage = "execution probe skipped under xcode debugger";
      const std::string skipped_summary =
        ready_metadata.tool_bootstrap_summary.empty()
          ? format_unavailable_summary(skipped_stage)
          : ready_metadata.tool_bootstrap_summary;
      return AllocatorProbeResult {
        .status = "unavailable",
        .backend = "xcode-debugger-check",
        .session_kind = session_kind,
        .failure_stage = skipped_stage,
        .tool_recommendation = ready_metadata.tool_recommendation,
        .tool_bootstrap_kind = ready_metadata.tool_bootstrap_kind,
        .tool_bootstrap_summary = ready_metadata.tool_bootstrap_summary,
        .summary = skipped_summary,
      };
    }
  }

  void* executable_view = FEXCore::Allocator::VirtualAlloc(static_cast<size_t>(page_size), true);
  const auto allocation_status = FEXCore::Allocator::GetLastCodeMemoryOperationStatus();
  const std::string backend = FEXCore::Allocator::GetCodeMemoryBackendName(allocation_status.backend);
  if (executable_view == nullptr) {
    std::string failure_stage = allocation_status.failure_stage == FEXCore::Allocator::CodeMemoryFailureStage::None ?
                                  std::string("RW mapping failed") :
                                  std::string(FEXCore::Allocator::GetCodeMemoryFailureStageName(allocation_status.failure_stage));
    if (allocation_status.error_code != 0) {
      failure_stage += " (";
      failure_stage += allocation_status.error_domain == FEXCore::Allocator::CodeMemoryErrorDomain::Mach ? "mach:" : "errno:";
      failure_stage += std::to_string(allocation_status.error_code);
      failure_stage += ")";
    }
    return AllocatorProbeResult {
      .status = "unavailable",
      .backend = backend,
      .session_kind = session_kind,
      .failure_stage = failure_stage,
      .tool_recommendation = metadata.tool_recommendation,
      .error_domain = allocation_status.error_domain == FEXCore::Allocator::CodeMemoryErrorDomain::Mach ? "mach" : "errno",
      .error_code = allocation_status.error_code,
      .summary = format_unavailable_summary(failure_stage, format_error_detail(allocation_status.error_domain, allocation_status.error_code)),
    };
  }

  struct ScopedExecutableView final {
    void* pointer;
    size_t size;

    ~ScopedExecutableView() {
      if (pointer != nullptr) {
        FEXCore::Allocator::VirtualFree(pointer, size);
      }
    }
  } cleanup {executable_view, static_cast<size_t>(page_size)};

  auto* writable_view = static_cast<uint32_t*>(FEXCore::Allocator::GetWritableAlias(executable_view));
  if (writable_view == nullptr) {
    return AllocatorProbeResult {
      .allocation_succeeded = true,
      .status = "unavailable",
      .backend = backend,
      .session_kind = session_kind,
      .failure_stage = "writable alias failed",
      .tool_recommendation = metadata.tool_recommendation,
      .error_domain = "errno",
      .error_code = EFAULT,
      .summary = format_unavailable_summary("writable alias failed", "allocator did not expose a writable view"),
    };
  }

  const auto write_probe_callback = [](void* context) -> int {
    auto* destination = static_cast<uint32_t*>(context);
    destination[0] = kProbeInstructions[0];
    destination[1] = kProbeInstructions[1];
    return 0;
  };
  if (FEXCore::Allocator::ExecuteJITWriteCallbackForCodeMemory(executable_view, write_probe_callback, writable_view) != 0) {
    return AllocatorProbeResult {
      .allocation_succeeded = true,
      .status = "unavailable",
      .backend = backend,
      .session_kind = session_kind,
      .failure_stage = "write callback failed",
      .tool_recommendation = metadata.tool_recommendation,
      .summary = format_unavailable_summary("write callback failed", "allocator write callback failed"),
    };
  }

  if (writable_view[0] != kProbeInstructions[0] || writable_view[1] != kProbeInstructions[1]) {
    return AllocatorProbeResult {
      .allocation_succeeded = true,
      .status = "unavailable",
      .backend = backend,
      .session_kind = session_kind,
      .failure_stage = "emitted code verification failed",
      .tool_recommendation = metadata.tool_recommendation,
      .summary = format_unavailable_summary("emitted code verification failed"),
    };
  }

  if (skip_execution_probe) {
    return AllocatorProbeResult {
      .ready = true,
      .allocation_succeeded = true,
      .write_succeeded = true,
      .status = "ready",
      .backend = backend,
      .session_kind = session_kind,
      .failure_stage = helper_bootstrap_completed ? "helper bootstrap completed" : "execution probe skipped for debugger-backed session",
      .tool_recommendation = ready_metadata.tool_recommendation,
      .tool_bootstrap_kind = ready_metadata.tool_bootstrap_kind,
      .tool_bootstrap_summary = ready_metadata.tool_bootstrap_summary,
      .summary = "JIT allocator ready.",
    };
  }

  std::string exception_port_failure_stage;
  std::string exception_port_failure_summary;
  const auto exception_ports = iridium::ios::ScopedJITExceptionPorts::Install(
    session_kind, xcode_debug_launch, &exception_port_failure_stage, &exception_port_failure_summary);
  const bool exception_ports_active = exception_ports != nullptr && exception_ports->active();
  if (!exception_port_failure_stage.empty()) {
    return AllocatorProbeResult {
      .allocation_succeeded = true,
      .write_succeeded = true,
      .status = "unavailable",
      .backend = backend,
      .session_kind = session_kind,
      .failure_stage = exception_port_failure_stage,
      .tool_recommendation = metadata.tool_recommendation,
      .summary = exception_port_failure_summary.empty() ? format_unavailable_summary(exception_port_failure_stage) : exception_port_failure_summary,
    };
  }

  ScopedAllocatorProbeSignals signals;
  g_allocator_probe_signal = 0;

  __builtin___clear_cache(static_cast<char*>(executable_view), static_cast<char*>(executable_view) + sizeof(kProbeInstructions));

  uint32_t execution_result = 0;
  if (sigsetjmp(g_allocator_probe_jump_buffer, 1) == 0) {
    execution_result = reinterpret_cast<uint32_t (*)()>(executable_view)();
  } else {
    std::ostringstream detail;
    detail << "signal " << g_allocator_probe_signal;
    return AllocatorProbeResult {
      .allocation_succeeded = true,
      .write_succeeded = true,
      .status = "unavailable",
      .backend = backend,
      .session_kind = session_kind,
      .failure_stage = "executable-view execution failed",
      .tool_recommendation = metadata.tool_recommendation,
      .exception_ports_active = exception_ports_active,
      .summary = format_unavailable_summary("executable-view execution failed", detail.str()),
    };
  }

  if (execution_result != 42) {
    std::ostringstream detail;
    detail << "probe returned " << execution_result;
    return AllocatorProbeResult {
      .allocation_succeeded = true,
      .write_succeeded = true,
      .status = "unavailable",
      .backend = backend,
      .session_kind = session_kind,
      .failure_stage = "executable-view execution failed",
      .tool_recommendation = metadata.tool_recommendation,
      .exception_ports_active = exception_ports_active,
      .summary = format_unavailable_summary("executable-view execution failed", detail.str()),
    };
  }

  return AllocatorProbeResult {
    .ready = true,
    .allocation_succeeded = true,
    .write_succeeded = true,
    .execution_succeeded = true,
    .status = "ready",
    .backend = backend,
    .session_kind = session_kind,
    .tool_recommendation = ready_metadata.tool_recommendation,
    .tool_bootstrap_kind = ready_metadata.tool_bootstrap_kind,
    .tool_bootstrap_summary = ready_metadata.tool_bootstrap_summary,
    .exception_ports_active = exception_ports_active,
    .summary = "JIT allocator ready.",
  };
}

} // namespace iridium::ios

extern "C" int iridium_fex_ios_probe_allocator(const char* jit_status, IridiumFEXIOSAllocatorProbe* out_probe) {
  if (out_probe == nullptr) {
    return IRIDIUM_FEX_IOS_STATUS_INVALID_ARGUMENT;
  }

  static thread_local iridium::ios::AllocatorProbeResult cached_probe;
  cached_probe = iridium::ios::probe_allocator_backend(jit_status != nullptr && std::strcmp(jit_status, "ready") == 0);

  out_probe->allocation_succeeded = cached_probe.allocation_succeeded ? 1 : 0;
  out_probe->write_succeeded = cached_probe.write_succeeded ? 1 : 0;
  out_probe->execution_succeeded = cached_probe.execution_succeeded ? 1 : 0;
  out_probe->status = cached_probe.status.c_str();
  out_probe->backend = cached_probe.backend.c_str();
  out_probe->failure_stage = cached_probe.failure_stage.empty() ? nullptr : cached_probe.failure_stage.c_str();
  out_probe->error_domain = cached_probe.error_domain.c_str();
  out_probe->error_code = cached_probe.error_code;
  out_probe->status_summary = cached_probe.summary.c_str();
  return IRIDIUM_FEX_IOS_STATUS_OK;
}
