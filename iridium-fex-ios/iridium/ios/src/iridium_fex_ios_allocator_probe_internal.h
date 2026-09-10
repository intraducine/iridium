#pragma once

#include <string>

namespace iridium::ios {

struct AllocatorProbeResult {
  bool ready {false};
  bool allocation_succeeded {false};
  bool write_succeeded {false};
  bool execution_succeeded {false};
  std::string status {"required"};
  std::string backend {"none"};
  std::string session_kind {"none"};
  std::string failure_stage;
  std::string tool_recommendation {"none"};
  bool tool_bootstrap_required {false};
  std::string tool_bootstrap_kind;
  std::string tool_bootstrap_summary;
  bool exception_ports_active {false};
  std::string error_domain {"none"};
  int error_code {0};
  std::string summary;
};

AllocatorProbeResult probe_allocator_backend(bool trusted_debugger_signal);

} // namespace iridium::ios
