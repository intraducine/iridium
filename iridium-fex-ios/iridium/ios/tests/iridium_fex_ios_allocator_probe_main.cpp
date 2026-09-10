#include "../include/iridium_fex_ios_bridge.h"

#include <iostream>

int main(int argc, char** argv) {
  const char* jit_status = argc > 1 ? argv[1] : "ready";
  IridiumFEXIOSAllocatorProbe probe {};
  const int result = iridium_fex_ios_probe_allocator(jit_status, &probe);
  if (result != IRIDIUM_FEX_IOS_STATUS_OK) {
    std::cerr << "status=error\n";
    std::cerr << "code=" << result << '\n';
    return result;
  }

  std::cout << "status=" << (probe.status == nullptr ? "unknown" : probe.status) << '\n';
  std::cout << "backend=" << (probe.backend == nullptr ? "none" : probe.backend) << '\n';
  std::cout << "allocationSucceeded=" << probe.allocation_succeeded << '\n';
  std::cout << "writeSucceeded=" << probe.write_succeeded << '\n';
  std::cout << "executionSucceeded=" << probe.execution_succeeded << '\n';
  std::cout << "failureStage=" << (probe.failure_stage == nullptr ? "" : probe.failure_stage) << '\n';
  std::cout << "errorDomain=" << (probe.error_domain == nullptr ? "none" : probe.error_domain) << '\n';
  std::cout << "errorCode=" << probe.error_code << '\n';
  std::cout << "summary=" << (probe.status_summary == nullptr ? "" : probe.status_summary) << '\n';
  return probe.execution_succeeded ? 0 : 1;
}