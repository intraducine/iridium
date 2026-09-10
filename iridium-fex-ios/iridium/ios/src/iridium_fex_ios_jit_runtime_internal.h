#pragma once

#include <array>
#include <memory>
#include <optional>
#include <string>

#if defined(__APPLE__)
#include <mach/mach.h>
#endif

namespace iridium::ios {

struct JITRuntimeMetadata {
  std::string tool_recommendation {"none"};
  bool tool_bootstrap_required {false};
  std::string tool_bootstrap_kind;
  std::string tool_bootstrap_summary;
  bool exception_ports_active {false};
};

struct JITMemoryCapabilities {
  int ios_major_version {0};
  std::string hardware_identifier;
  bool txm_present {false};
  bool debugger_region_protocol_required {false};
  std::string active_provider {"none"};
  bool provider_supports_debugger_region_protocol {false};
};

enum class JITBootstrapCommand : uint64_t {
  Detach = 0,
  PrepareExecutableRegion = 1,
  InstallExtensionScript = 2,
  SetDetachAfterFirstBreakpoint = 3,
  PreparePatchRegion = 4,
};

struct JITBootstrapCommandResult {
  bool handled {false};
  uintptr_t value {0};
  std::string failure_stage;
  std::string failure_summary;
};

std::optional<std::string> jit_runtime_env_value(const char* name);
bool jit_runtime_env_enabled(const char* name);
bool looks_like_xcode_debug_launch();
bool infer_stikdebug_txm_capability(int ios_major_version, const std::string& hardware_identifier);
JITMemoryCapabilities resolve_jit_memory_capabilities();
bool debugger_region_protocol_ready(const JITMemoryCapabilities& capabilities);

JITRuntimeMetadata resolve_jit_runtime_metadata(const std::string& session_kind, bool trusted_debugger_signal, bool ready, bool xcode_debug_launch);
const char* default_jit_bootstrap_extension_script();
JITBootstrapCommandResult issue_jit_bootstrap_command(JITBootstrapCommand command, uintptr_t x0, uintptr_t x1);
JITBootstrapCommandResult install_jit_bootstrap_extension_script(const std::string& script_source);
JITBootstrapCommandResult configure_jit_bootstrap_detach_after_first_breakpoint(bool enabled);
JITBootstrapCommandResult prepare_jit_bootstrap_executable_region(size_t length);
JITBootstrapCommandResult prepare_jit_bootstrap_patch_region(void* address, size_t length);
JITBootstrapCommandResult detach_jit_bootstrap_session();
void reset_jit_bootstrap_test_state();
bool jit_bootstrap_test_extension_loaded();
bool jit_bootstrap_test_detach_after_first_breakpoint();
bool jit_bootstrap_test_detached();

class ScopedJITExceptionPorts final {
public:
  ~ScopedJITExceptionPorts();

  ScopedJITExceptionPorts(const ScopedJITExceptionPorts&) = delete;
  ScopedJITExceptionPorts& operator=(const ScopedJITExceptionPorts&) = delete;

  static std::shared_ptr<ScopedJITExceptionPorts>
  Install(const std::string& session_kind, bool xcode_debug_launch, std::string* failure_stage, std::string* failure_summary);

  bool active() const {
    return active_;
  }

private:
  ScopedJITExceptionPorts() = default;

  bool active_ {false};

#if defined(__APPLE__)
  thread_t thread_ {MACH_PORT_NULL};
  unsigned count_ {0};
  std::array<exception_mask_t, EXC_TYPES_COUNT> masks_ {};
  std::array<exception_behavior_t, EXC_TYPES_COUNT> behaviors_ {};
  std::array<thread_state_flavor_t, EXC_TYPES_COUNT> flavors_ {};
  std::array<mach_port_t, EXC_TYPES_COUNT> ports_ {};

  unsigned thread_count_ {0};
  std::array<exception_mask_t, EXC_TYPES_COUNT> thread_masks_ {};
  std::array<exception_behavior_t, EXC_TYPES_COUNT> thread_behaviors_ {};
  std::array<thread_state_flavor_t, EXC_TYPES_COUNT> thread_flavors_ {};
  std::array<mach_port_t, EXC_TYPES_COUNT> thread_ports_ {};
#endif
};

} // namespace iridium::ios
