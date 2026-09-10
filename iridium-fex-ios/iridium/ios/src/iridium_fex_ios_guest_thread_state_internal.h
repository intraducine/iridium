#pragma once

#if defined(IRIDIUM_FEX_IOS_ENABLE_FEXCORE)

#include <array>
#include <cstddef>
#include <cstdint>

#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Core/HostFeatures.h>
#include <FEXCore/Utils/TypeDefines.h>

namespace iridium::fex::ios {

using GuestThreadGDT = std::array<FEXCore::Core::CPUState::gdt_segment, 32>;
constexpr std::size_t kGuestCallRetStackSize = 0x400000;
constexpr std::size_t kGuestCallRetStackAllocationSize = kGuestCallRetStackSize + 2 * FEXCore::Utils::FEX_PAGE_SIZE;

struct GuestThreadRuntimeState {
  GuestThreadGDT gdt {};
  void* callret_stack_allocation_base {};
  std::size_t callret_stack_allocation_size {};
};

FEXCore::HostFeatures CreateEmbeddedHostFeaturesForFEX();
void ConfigureEmbeddedFEXFor64BitGuest();
void InitializeGuest64BitThreadState(FEXCore::Core::CPUState& state, GuestThreadGDT& gdt);
bool InitializeGuestCallRetStack(void*& callret_stack_base, uint64_t& callret_sp, GuestThreadRuntimeState& runtime_state);
void DestroyGuestCallRetStack(void*& callret_stack_base, GuestThreadRuntimeState& runtime_state);

}  // namespace iridium::fex::ios

#endif
