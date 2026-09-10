#include "iridium_fex_ios_jit_runtime_internal.h"

#include <cstdlib>
#include <cstring>
#include <cctype>
#include <cmath>
#include <sstream>
#include <unistd.h>
#include <vector>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#endif

namespace {

std::string default_tool_bootstrap_kind(const std::string& recommendation) {
  if (recommendation == "trollstore") {
    return "trollstore-enable-jit";
  }
  if (recommendation == "sidestore") {
    return "sidestore-attach";
  }
  return "stikdebug-script";
}

std::string default_tool_bootstrap_summary(const std::string& recommendation, const std::string& bootstrap_kind) {
  if (bootstrap_kind == "trollstore-enable-jit") {
    return "Private JIT capability is present, but the TrollStore-compatible bootstrap has not completed executable region preparation.";
  }
  if (bootstrap_kind == "sidestore-attach") {
    return "Debugger attach is present, but SideStore has not completed the required debugger-backed executable region bootstrap yet.";
  }
  if (recommendation == "stikdebug") {
    return "Debugger attach is present, but StikDebug still needs to complete the required executable region bootstrap script.";
  }
  return "External debugger/JIT bootstrap is still required before executable region preparation can complete.";
}

bool parse_apple_hardware_version(
  const std::string& hardware_identifier,
  const char* prefix,
  int* major,
  int* minor
) {
  const size_t prefix_length = std::strlen(prefix);
  if (hardware_identifier.compare(0, prefix_length, prefix) != 0) {
    return false;
  }

  const char* cursor = hardware_identifier.c_str() + prefix_length;
  if (!std::isdigit(static_cast<unsigned char>(*cursor))) {
    return false;
  }

  char* end = nullptr;
  const long parsed_major = std::strtol(cursor, &end, 10);
  if (end == cursor || *end != ',') {
    return false;
  }

  cursor = end + 1;
  const long parsed_minor = std::strtol(cursor, &end, 10);
  if (end == cursor || *end != '\0' || parsed_major < 0 || parsed_minor < 0) {
    return false;
  }

  *major = static_cast<int>(parsed_major);
  *minor = static_cast<int>(parsed_minor);
  return true;
}

int current_ios_major_version() {
#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  if (__builtin_available(iOS 27, *)) {
    return 27;
  }
  if (__builtin_available(iOS 26, *)) {
    return 26;
  }
#endif
  return 0;
}

std::string current_hardware_identifier() {
#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  struct utsname system_info {};
  if (::uname(&system_info) == 0) {
    return system_info.machine;
  }
#endif
  return "unknown";
}

#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
bool current_process_is_traced() {
  struct kinfo_proc process_info {};
  size_t process_info_size = sizeof(process_info);
  int query[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, ::getpid()};
  if (::sysctl(
        query,
        static_cast<u_int>(sizeof(query) / sizeof(query[0])),
        &process_info,
        &process_info_size,
        nullptr,
        0) != 0) {
    return false;
  }
  return (process_info.kp_proc.p_flag & P_TRACED) != 0;
}
#endif

bool should_install_exception_port_guard(const std::string& session_kind) {
#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  // An attached JIT helper owns the process exception ports. Replacing those
  // ports breaks the debugger protocol that prepares executable mappings.
  // Keep the legacy fault-classification guard available only for controlled
  // diagnostics where no external debugger owns the task.
  return (session_kind == "debugger-backed" || session_kind == "trollstore-private") &&
         iridium::ios::jit_runtime_env_enabled("IRIDIUM_FEX_IOS_ENABLE_EXCEPTION_PORT_GUARD");
#else
  (void)session_kind;
  return iridium::ios::jit_runtime_env_enabled("IRIDIUM_FEX_IOS_ENABLE_EXCEPTION_PORT_GUARD_ON_HOST");
#endif
}

#if defined(__APPLE__) && defined(__aarch64__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
constexpr uint32_t kIridiumBootstrapBRKImmediate = 0xf00d;
#endif

const char* helper_bootstrap_extension_script() {
  return R"JS(
let iridiumDetachAfterFirstBreakpoint = false;

iridiumCommands[3] = function(stopInfo) {
    iridiumDetachAfterFirstBreakpoint = stopInfo.address !== 0n;
    iridiumWriteResult(1n);
};

iridiumCommands[4] = function(stopInfo) {
    if (stopInfo.address === 0n || stopInfo.length === 0n) {
        iridiumWriteResult(0n);
        return;
    }

    const regionAddress = stopInfo.address.toString(16);
    const regionLength = stopInfo.length.toString(16);
    const bytes = send_command(`m${regionAddress},${regionLength}`);
    send_command(`M${regionAddress},${regionLength}:${bytes}`);
    iridiumWriteResult(1n);
    if (iridiumDetachAfterFirstBreakpoint) {
        iridiumDetach();
    }
};
)JS";
}

struct BootstrapSimulationState {
  bool extension_loaded {false};
  bool detach_after_first_breakpoint {false};
  bool detached {false};
  std::vector<std::pair<void*, size_t>> allocated_regions;

  ~BootstrapSimulationState() {
    for (const auto& allocation : allocated_regions) {
      void* pointer = allocation.first;
      if (pointer != nullptr) {
        std::free(pointer);
      }
    }
  }
};

BootstrapSimulationState& bootstrap_simulation_state() {
  static thread_local BootstrapSimulationState state;
  return state;
}

bool bootstrap_command_simulation_enabled() {
  return iridium::ios::jit_runtime_env_enabled("IRIDIUM_FEX_IOS_SIMULATE_HELPER_BOOTSTRAP");
}

void* allocate_bootstrap_region(size_t length) {
  if (length == 0) {
    return nullptr;
  }
  return std::malloc(length);
}

iridium::ios::JITBootstrapCommandResult simulate_bootstrap_command(
  iridium::ios::JITBootstrapCommand command,
  uintptr_t x0,
  uintptr_t x1
) {
  auto& state = bootstrap_simulation_state();
  switch (command) {
    case iridium::ios::JITBootstrapCommand::Detach:
      state.detached = true;
      return {.handled = true, .value = 1};
    case iridium::ios::JITBootstrapCommand::PrepareExecutableRegion: {
      if (x1 == 0) {
        return {
          .handled = false,
          .failure_stage = "bootstrap prepare region failed",
          .failure_summary = "Helper bootstrap refused to prepare a zero-length executable region.",
        };
      }
      void* region = reinterpret_cast<void*>(x0);
      if (region == nullptr) {
        region = allocate_bootstrap_region(static_cast<size_t>(x1));
        if (region == nullptr) {
          return {
            .handled = false,
            .failure_stage = "bootstrap prepare region failed",
            .failure_summary = "Helper bootstrap could not allocate an executable region.",
          };
        }
        state.allocated_regions.emplace_back(region, static_cast<size_t>(x1));
      }
      return {.handled = true, .value = reinterpret_cast<uintptr_t>(region)};
    }
    case iridium::ios::JITBootstrapCommand::InstallExtensionScript: {
      if (x0 == 0 || x1 == 0) {
        return {
          .handled = false,
          .failure_stage = "bootstrap extension install failed",
          .failure_summary = "Helper bootstrap did not receive an extension script payload.",
        };
      }
      const auto* bytes = reinterpret_cast<const char*>(x0);
      std::string script(bytes, bytes + x1);
      state.extension_loaded = !script.empty();
      return {.handled = state.extension_loaded, .value = state.extension_loaded ? 1u : 0u};
    }
    case iridium::ios::JITBootstrapCommand::SetDetachAfterFirstBreakpoint:
      state.detach_after_first_breakpoint = x0 != 0;
      return {.handled = true, .value = 1};
    case iridium::ios::JITBootstrapCommand::PreparePatchRegion: {
      if (x0 == 0 || x1 == 0) {
        return {
          .handled = false,
          .failure_stage = "bootstrap patch prepare failed",
          .failure_summary = "Helper bootstrap cannot round-trip an empty patch region.",
        };
      }
      auto* region = reinterpret_cast<unsigned char*>(x0);
      std::vector<unsigned char> bytes(region, region + x1);
      std::memcpy(region, bytes.data(), bytes.size());
      return {.handled = true, .value = 1};
    }
  }

  return {
    .handled = false,
    .failure_stage = "bootstrap command unsupported",
    .failure_summary = "Helper bootstrap does not support that command.",
  };
}

#if defined(__APPLE__) && defined(__aarch64__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
uintptr_t issue_bootstrap_command_raw(uint64_t command, uintptr_t x0, uintptr_t x1) {
  register uintptr_t x0_register asm("x0") = x0;
  register uintptr_t x1_register asm("x1") = x1;
  register uint64_t x16_register asm("x16") = command;
  asm volatile("brk #%c[immediate]" : "+r"(x0_register) : "r"(x1_register), "r"(x16_register), [immediate] "i"(kIridiumBootstrapBRKImmediate) : "memory");
  return x0_register;
}
#endif

} // namespace

namespace iridium::ios {

std::optional<std::string> jit_runtime_env_value(const char* name) {
  const char* value = std::getenv(name);
  if (value == nullptr || value[0] == '\0') {
    return std::nullopt;
  }
  return std::string(value);
}

bool jit_runtime_env_enabled(const char* name) {
  const char* value = std::getenv(name);
  return value != nullptr && std::strcmp(value, "1") == 0;
}

bool looks_like_xcode_debug_launch() {
  return jit_runtime_env_value("XCODE_RUNNING_FOR_PREVIEWS") == std::optional<std::string>("1") ||
         jit_runtime_env_value("__XCODE_BUILT_PRODUCTS_DIR_PATHS").has_value();
}

bool infer_stikdebug_txm_capability(int ios_major_version, const std::string& hardware_identifier) {
  if (ios_major_version >= 27) {
    // StikDebug 3.1.6's iOS 27 policy: the only supported non-TXM devices are
    // the A12Z iPad Pro models. Keep this in lockstep with the provider that
    // decides whether it will actually install our persistent JS callback.
    return hardware_identifier != "iPad8,11" && hardware_identifier != "iPad8,12";
  }

  if (ios_major_version != 26) {
    return false;
  }

  int model_major = 0;
  int model_minor = 0;
  if (parse_apple_hardware_version(hardware_identifier, "iPhone", &model_major, &model_minor)) {
    const auto minor_digits = std::to_string(model_minor).size();
    const double version = static_cast<double>(model_major) +
      static_cast<double>(model_minor) / std::pow(10.0, static_cast<double>(minor_digits));
    return version >= 14.2;
  }
  if (parse_apple_hardware_version(hardware_identifier, "iPad", &model_major, &model_minor)) {
    const auto minor_digits = std::to_string(model_minor).size();
    const double version = static_cast<double>(model_major) +
      static_cast<double>(model_minor) / std::pow(10.0, static_cast<double>(minor_digits));
    return version >= 14.5;
  }
  return false;
}

JITMemoryCapabilities resolve_jit_memory_capabilities() {
  JITMemoryCapabilities capabilities;
  capabilities.ios_major_version = current_ios_major_version();
  capabilities.hardware_identifier = current_hardware_identifier();
  capabilities.txm_present = infer_stikdebug_txm_capability(
    capabilities.ios_major_version,
    capabilities.hardware_identifier
  );

  if (const auto policy_override = jit_runtime_env_value("IRIDIUM_FEX_IOS_DEBUGGER_REGION_PROTOCOL")) {
    if (*policy_override == "required") {
      capabilities.txm_present = true;
    } else if (*policy_override == "disabled") {
      capabilities.txm_present = false;
    }
  }

  capabilities.debugger_region_protocol_required =
    capabilities.ios_major_version >= 26 && capabilities.txm_present;
  capabilities.active_provider =
    jit_runtime_env_value("IRIDIUM_FEX_IOS_ACTIVE_JIT_PROVIDER").value_or("none");
  if (capabilities.active_provider == "trollstore" ||
      jit_runtime_env_value("IRIDIUM_FEX_IOS_JIT_SESSION_KIND") == std::optional<std::string>("trollstore-private") ||
      jit_runtime_env_enabled("IRIDIUM_FEX_IOS_PRIVATE_JIT_CAPABILITY")) {
    capabilities.debugger_region_protocol_required = false;
  }
  capabilities.provider_supports_debugger_region_protocol =
    capabilities.active_provider == "stikdebug";
  return capabilities;
}

bool debugger_region_protocol_ready(const JITMemoryCapabilities& capabilities) {
  if (!capabilities.debugger_region_protocol_required) {
    return true;
  }
  if (!capabilities.provider_supports_debugger_region_protocol) {
    return false;
  }
#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  // StikDebug remains attached while its JS callback services the BRK
  // protocol. Avoid issuing an unhandled BRK after the helper disconnects.
  return current_process_is_traced();
#else
  return bootstrap_command_simulation_enabled();
#endif
}

JITRuntimeMetadata resolve_jit_runtime_metadata(const std::string& session_kind, bool trusted_debugger_signal, bool ready, bool xcode_debug_launch) {
  JITRuntimeMetadata metadata;
  const auto memory_capabilities = resolve_jit_memory_capabilities();

  if (const auto override = jit_runtime_env_value("IRIDIUM_FEX_IOS_TOOL_RECOMMENDATION")) {
    metadata.tool_recommendation = *override;
  } else if (session_kind == "trollstore-private") {
    metadata.tool_recommendation = "trollstore";
  } else if (!trusted_debugger_signal || !ready) {
    metadata.tool_recommendation = "stikdebug";
  }

  if (jit_runtime_env_enabled("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_REQUIRED") || jit_runtime_env_enabled("IRIDIUM_FEX_IOS_JIT_SCRIPT_"
                                                                                                    "REQUIRED")) {
    metadata.tool_bootstrap_required = true;
  }

  if (session_kind == "debugger-backed" && memory_capabilities.debugger_region_protocol_required) {
    metadata.tool_bootstrap_required = true;
    metadata.tool_recommendation = "stikdebug";
  }

  if (metadata.tool_bootstrap_required && metadata.tool_recommendation == "none") {
    metadata.tool_recommendation = session_kind == "trollstore-private" ? "trollstore" : "stikdebug";
  }

  if (ready && !metadata.tool_bootstrap_required) {
    metadata.tool_recommendation = "none";
  }

  if (metadata.tool_bootstrap_required) {
    metadata.tool_bootstrap_kind =
      jit_runtime_env_value("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_KIND").value_or(default_tool_bootstrap_kind(metadata.tool_recommendation));
    metadata.tool_bootstrap_summary = jit_runtime_env_value("IRIDIUM_FEX_IOS_TOOL_BOOTSTRAP_SUMMARY")
                                        .value_or(default_tool_bootstrap_summary(metadata.tool_recommendation, metadata.tool_bootstrap_kind));
    if (session_kind == "debugger-backed" && memory_capabilities.debugger_region_protocol_required &&
        !memory_capabilities.provider_supports_debugger_region_protocol) {
      metadata.tool_bootstrap_summary =
        "This iOS/device combination requires StikDebug's persistent TXM executable-region callback; the active JIT provider (" +
        memory_capabilities.active_provider + ") only supplied a debugger session.";
    }
  } else if (xcode_debug_launch && trusted_debugger_signal) {
    metadata.tool_bootstrap_kind = "xcode-debugger";
    metadata.tool_bootstrap_summary = "Xcode is attached; Iridium will skip the unsafe execute probe but still requires the real runtime "
                                      "backend to pass under a non-Xcode debugger-backed session.";
  }

  return metadata;
}

const char* default_jit_bootstrap_extension_script() {
  return helper_bootstrap_extension_script();
}

JITBootstrapCommandResult issue_jit_bootstrap_command(JITBootstrapCommand command, uintptr_t x0, uintptr_t x1) {
  if (bootstrap_command_simulation_enabled()) {
    return simulate_bootstrap_command(command, x0, x1);
  }

#if defined(__APPLE__) && defined(__aarch64__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  return {
    .handled = true,
    .value = issue_bootstrap_command_raw(static_cast<uint64_t>(command), x0, x1),
  };
#else
  return {
    .handled = false,
    .failure_stage = "helper bootstrap unavailable",
    .failure_summary = "Debugger-backed helper bootstrap is not available on this host build.",
  };
#endif
}

JITBootstrapCommandResult install_jit_bootstrap_extension_script(const std::string& script_source) {
  return issue_jit_bootstrap_command(
    JITBootstrapCommand::InstallExtensionScript,
    reinterpret_cast<uintptr_t>(script_source.data()),
    static_cast<uintptr_t>(script_source.size())
  );
}

JITBootstrapCommandResult configure_jit_bootstrap_detach_after_first_breakpoint(bool enabled) {
  return issue_jit_bootstrap_command(
    JITBootstrapCommand::SetDetachAfterFirstBreakpoint,
    enabled ? 1u : 0u,
    0
  );
}

JITBootstrapCommandResult prepare_jit_bootstrap_executable_region(size_t length) {
  return issue_jit_bootstrap_command(
    JITBootstrapCommand::PrepareExecutableRegion,
    0,
    static_cast<uintptr_t>(length)
  );
}

JITBootstrapCommandResult prepare_jit_bootstrap_patch_region(void* address, size_t length) {
  return issue_jit_bootstrap_command(
    JITBootstrapCommand::PreparePatchRegion,
    reinterpret_cast<uintptr_t>(address),
    static_cast<uintptr_t>(length)
  );
}

JITBootstrapCommandResult detach_jit_bootstrap_session() {
  return issue_jit_bootstrap_command(JITBootstrapCommand::Detach, 0, 0);
}

extern "C" uintptr_t iridium_fex_ios_prepare_debugger_owned_region(void* address, size_t size) {
  const auto result = issue_jit_bootstrap_command(
    JITBootstrapCommand::PrepareExecutableRegion,
    reinterpret_cast<uintptr_t>(address),
    static_cast<uintptr_t>(size)
  );
  return result.handled ? result.value : 0;
}

extern "C" int iridium_fex_ios_debugger_region_protocol_required() {
  return resolve_jit_memory_capabilities().debugger_region_protocol_required ? 1 : 0;
}

extern "C" int iridium_fex_ios_debugger_region_protocol_ready() {
  return debugger_region_protocol_ready(resolve_jit_memory_capabilities()) ? 1 : 0;
}

void reset_jit_bootstrap_test_state() {
  bootstrap_simulation_state() = BootstrapSimulationState {};
}

bool jit_bootstrap_test_extension_loaded() {
  return bootstrap_simulation_state().extension_loaded;
}

bool jit_bootstrap_test_detach_after_first_breakpoint() {
  return bootstrap_simulation_state().detach_after_first_breakpoint;
}

bool jit_bootstrap_test_detached() {
  return bootstrap_simulation_state().detached;
}

ScopedJITExceptionPorts::~ScopedJITExceptionPorts() {
#if defined(__APPLE__)
  if (active_) {
    for (unsigned index = 0; index < thread_count_; ++index) {
      thread_set_exception_ports(thread_, static_cast<exception_mask_t>(thread_masks_[index]),
                                 static_cast<mach_port_t>(thread_ports_[index]), static_cast<exception_behavior_t>(thread_behaviors_[index]),
                                 static_cast<thread_state_flavor_t>(thread_flavors_[index]));
    }

    for (unsigned index = 0; index < count_; ++index) {
      task_set_exception_ports(mach_task_self(), static_cast<exception_mask_t>(masks_[index]), static_cast<mach_port_t>(ports_[index]),
                               static_cast<exception_behavior_t>(behaviors_[index]), static_cast<thread_state_flavor_t>(flavors_[index]));
    }
  }

  for (unsigned index = 0; index < thread_count_; ++index) {
    if (thread_ports_[index] != MACH_PORT_NULL) {
      mach_port_deallocate(mach_task_self(), thread_ports_[index]);
    }
  }
  for (unsigned index = 0; index < count_; ++index) {
    if (ports_[index] != MACH_PORT_NULL) {
      mach_port_deallocate(mach_task_self(), ports_[index]);
    }
  }
  if (thread_ != MACH_PORT_NULL) {
    mach_port_deallocate(mach_task_self(), thread_);
  }
#endif
}

std::shared_ptr<ScopedJITExceptionPorts> ScopedJITExceptionPorts::Install(const std::string& session_kind, bool xcode_debug_launch,
                                                                          std::string* failure_stage, std::string* failure_summary) {
  if (!should_install_exception_port_guard(session_kind)) {
    return nullptr;
  }

#if !defined(__APPLE__)
  (void)xcode_debug_launch;
  (void)failure_stage;
  (void)failure_summary;
  auto guard = std::shared_ptr<ScopedJITExceptionPorts>(new ScopedJITExceptionPorts());
  guard->active_ = true;
  return guard;
#else
  auto guard = std::shared_ptr<ScopedJITExceptionPorts>(new ScopedJITExceptionPorts());
  guard->thread_ = mach_thread_self();
  mach_msg_type_number_t count = 16;
  kern_return_t result = task_get_exception_ports(
    mach_task_self(), EXC_MASK_BAD_ACCESS, reinterpret_cast<exception_mask_array_t>(guard->masks_.data()), &count,
    reinterpret_cast<exception_handler_array_t>(guard->ports_.data()), reinterpret_cast<exception_behavior_array_t>(guard->behaviors_.data()),
    reinterpret_cast<thread_state_flavor_array_t>(guard->flavors_.data()));
  if (result != KERN_SUCCESS) {
    if (failure_stage != nullptr) {
      *failure_stage = "exception-port setup failed";
    }
    if (failure_summary != nullptr) {
      std::ostringstream stream;
      stream << "Embedded FEX runtime could not snapshot task exception ports: " << mach_error_string(result) << " (" << result << ").";
      *failure_summary = stream.str();
    }
    return nullptr;
  }

  guard->count_ = count;

  mach_msg_type_number_t thread_count = 16;
  result = thread_get_exception_ports(guard->thread_, EXC_MASK_BAD_ACCESS,
                                      reinterpret_cast<exception_mask_array_t>(guard->thread_masks_.data()), &thread_count,
                                      reinterpret_cast<exception_handler_array_t>(guard->thread_ports_.data()),
                                      reinterpret_cast<exception_behavior_array_t>(guard->thread_behaviors_.data()),
                                      reinterpret_cast<thread_state_flavor_array_t>(guard->thread_flavors_.data()));
  if (result != KERN_SUCCESS) {
    thread_count = 0;
  }
  guard->thread_count_ = thread_count;

  guard->active_ = true;
  result = thread_set_exception_ports(guard->thread_, EXC_MASK_BAD_ACCESS, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
  (void)result;

  result = task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, MACH_PORT_NULL, EXCEPTION_DEFAULT, THREAD_STATE_NONE);
  if (result != KERN_SUCCESS) {
    if (failure_stage != nullptr) {
      *failure_stage = "exception-port setup failed";
    }
    if (failure_summary != nullptr) {
      std::ostringstream stream;
      stream << "Embedded FEX runtime could not install its bad-access exception guard: " << mach_error_string(result) << " (" << result << ").";
      if (xcode_debug_launch) {
        stream << " Xcode is still likely to intercept execution faults before Iridium can classify them.";
      }
      *failure_summary = stream.str();
    }
    return nullptr;
  }

  return guard;
#endif
}

} // namespace iridium::ios
