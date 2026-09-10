#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)
namespace FEXCore {
namespace Context {
class Context;
}
}
#endif

namespace iridium::fex::ios::guest {

/**
 * @brief Result of loading a guest ELF binary
 */
struct LoaderResult {
  bool success = false;
  std::string error_message;
  uint64_t entrypoint = 0;
  uint64_t stack_address = 0;
  uint64_t load_base = 0;
  uint64_t mapped_size = 0;
  uint64_t phdr_address = 0;
  uint64_t phdr_entry_size = 0;
  uint64_t phdr_count = 0;
};

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)

/**
 * @brief Loads a Wine ELF binary into memory and sets up guest thread state.
 * 
 * This is the Phase 2C loader: it memory-maps PT_LOAD segments, applies
 * per-segment permissions, builds an argv/envp/auxv process stack image,
 * and prepares the guest thread for execution via
 * FEXCore::Context::ExecuteThread().
 */
class GuestBinaryLoader {
public:
  /**
   * @brief Load the Wine ELF binary and initialize guest memory space
   * 
   * @param wine_binary_path Path to the Wine ELF executable or shared library
   * @param context The FEXCore::Context for memory allocation (can be nullptr for future syscall routing)
   * @param guest_args Command-line arguments for the guest binary
   * @param guest_environment Environment variables for the guest
   * @return LoaderResult with entrypoint, stack_address, and error status
   *         The entrypoint and stack_address should be passed to Context::CreateThread()
   */
  static LoaderResult LoadAndInitializeGuest(
    const std::string& wine_binary_path,
    FEXCore::Context::Context* context,
    const std::vector<std::string>& guest_args,
    const std::vector<std::string>& guest_environment
  );

private:
  /**
   * @brief Set up the guest stack with argc, argv, envp following AMD64 ABI
   */
  static uint64_t SetupGuestStack(
    uint64_t stack_top,
    uint64_t entrypoint,
    uint64_t phdr_address,
    uint64_t phdr_entry_size,
    uint64_t phdr_count,
    uint64_t interpreter_base,
    const std::vector<std::string>& args,
    const std::vector<std::string>& environment
  );
};

#endif  // IRIDIUM_FEX_IOS_ENABLE_FEXCORE

}  // namespace iridium::fex::ios::guest
