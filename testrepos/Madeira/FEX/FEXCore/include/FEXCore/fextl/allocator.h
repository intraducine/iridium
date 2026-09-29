// SPDX-License-Identifier: MIT
#pragma once
#include <FEXCore/Utils/AllocatorHooks.h>

#include <memory>

namespace fextl {
/* Reports an allocation failure and terminates. Out-of-line and allocation-free;
 * see the call site in FEXAlloc::allocate. */
[[noreturn]] FEX_DEFAULT_VISIBILITY void ReportAllocationFailure(std::size_t Alignment, std::size_t Bytes);

/**
 * @brief C++ allocator class interface in to FEXCore::Allocator for memory allocations.
 */
template<typename T>
class FEXAlloc : public std::allocator<T> {
public:
  using value_type = T;
  using propagate_on_container_move_assignment = std::true_type;

  FEXAlloc() noexcept {}
  template<class U>
  FEXAlloc(const FEXAlloc<U>&) noexcept {}

  inline value_type* allocate(std::size_t n) {
    auto* Ret = reinterpret_cast<value_type*>(::FEXCore::Allocator::aligned_alloc(alignof(value_type), n * sizeof(value_type)));
    if (!Ret) [[unlikely]] {
      /* iOS-Madeira ml798: an unchecked NULL here is how VA exhaustion presented
       * as an unattributable crash.
       *
       * FEXCore builds with -fno-exceptions, so this allocator cannot throw and
       * the standard's "succeed or throw" contract collapses to "return NULL".
       * std::vector then value-initialises over that NULL, and the process dies
       * in memset() with no indication of which allocation failed. That is the
       * crash we spent a run diagnosing: guest window creation succeeded, the
       * band filled, and DeadFlagCalculationEliminination::Run's BlockMap.resize
       * came back NULL inside the JIT compile path.
       *
       * There is nothing to return here that a caller could act on, so name the
       * failure at the point of truth and stop. Reporting is out-of-line and
       * allocation-free on purpose: formatting inside a failed-allocation path
       * is how an earlier probe died on its own log text. */
      ::fextl::ReportAllocationFailure(alignof(value_type), n * sizeof(value_type));
    }
    return Ret;
  }

  inline void deallocate(value_type* p, size_t) noexcept {
    ::FEXCore::Allocator::aligned_free(p);
  }

  inline bool operator==(const FEXAlloc&) const {
    return true;
  }
};
} // namespace fextl
