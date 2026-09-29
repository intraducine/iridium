// SPDX-License-Identifier: MIT
#pragma once

#include <FEXCore/Core/CoreState.h>
#include <FEXCore/Utils/AllocatorHooks.h>
#include <FEXCore/Utils/TypeDefines.h>
#include <FEXCore/Utils/LongJump.h>
#include <FEXCore/fextl/memory.h>
#include <FEXCore/fextl/vector.h>

#include <cstddef>
#include <cstdint>
#include <shared_mutex>
#include <type_traits>

namespace FEXCore {
class LookupCache;
struct JITSymbolBuffer;
} // namespace FEXCore

namespace FEXCore::Context {
class Context;
}

namespace FEXCore::CPU {
class CPUBackend;
} // namespace FEXCore::CPU

namespace FEXCore::Frontend {
class Decoder;
}

namespace FEXCore::IR {
class OpDispatchBuilder;
class PassManager;
} // namespace FEXCore::IR

namespace FEXCore::SHMStats {
struct ThreadStats;
};

namespace FEXCore::Core {

// Special-purpose replacement for std::unique_ptr to allow InternalThreadState to be standard layout.
// Since a NonMovableUniquePtr is neither copyable nor movable, its only function is to own and release the contained object.
template<typename T>
struct NonMovableUniquePtr {
  NonMovableUniquePtr() noexcept = default;
  NonMovableUniquePtr(const NonMovableUniquePtr&) = delete;
  NonMovableUniquePtr& operator=(const NonMovableUniquePtr& UPtr) = delete;

  NonMovableUniquePtr& operator=(fextl::unique_ptr<T> UPtr) noexcept {
    Ptr = UPtr.release();
    return *this;
  }

  ~NonMovableUniquePtr() {
    fextl::default_delete<T> {}(Ptr);
  }

  T* operator->() const noexcept {
    return Ptr;
  }

  std::add_lvalue_reference_t<T> operator*() const noexcept {
    return *Ptr;
  }

  T* get() const noexcept {
    return Ptr;
  }

  explicit operator bool() const noexcept {
    return Ptr != nullptr;
  }

private:
  T* Ptr = nullptr;
};
static_assert(!std::is_move_constructible_v<NonMovableUniquePtr<int>>);
static_assert(!std::is_move_assignable_v<NonMovableUniquePtr<int>>);

// Store used for unaligned LDAXR*/STLXR* emulation.
struct UnalignedExclusiveStore {
  uint64_t Addr;
  uint64_t Store;
  uint8_t Size;
};

struct alignas(FEXCore::Utils::FEX_PAGE_SIZE) InternalThreadState : public FEXCore::Allocator::FEXAllocOperators {
  FEXCore::Core::CpuStateFrame* const CurrentFrame = &BaseFrameState;

  FEXCore::Context::Context* const CTX;

  NonMovableUniquePtr<FEXCore::IR::OpDispatchBuilder> OpDispatcher;

  NonMovableUniquePtr<FEXCore::CPU::CPUBackend> CPUBackend;
  NonMovableUniquePtr<FEXCore::LookupCache> LookupCache;

  NonMovableUniquePtr<FEXCore::Frontend::Decoder> FrontendDecoder;
  NonMovableUniquePtr<FEXCore::IR::PassManager> PassManager;
  NonMovableUniquePtr<JITSymbolBuffer> SymbolBuffer;

  // This pointer is owned by the frontend.
  FEXCore::SHMStats::ThreadStats* ThreadStats {};

  UnalignedExclusiveStore ExclusiveStore;

  ///< Data pointer for exclusive use by the frontend
  void* FrontendPtr;

  // iOS-Madeira 2026-05-13: bumped 4MB → 16MB. SEH unwinds through translated
  // code on iOS don't pop FEX callret entries (FEX has no SEH-aware callret
  // cleanup yet), so caught faults leak entries. With 9700+ caught faults
  // observed in Thumper FMOD worker, the original 4MB filled up. 16MB buys
  // ~1M entries — enough to survive normal game runtimes that have a few
  // hundred per-thread caught faults. Real fix: callret-aware SEH unwind.
  static constexpr size_t CALLRET_STACK_SIZE {0x1000000};

  // iOS-Madeira ml609/ml610: NAMED bounds for the window the CALL/RET guard enforces.
  //
  // The default sp sits at base + SIZE/4 = base+4MB and the predictor grows DOWN
  // from there; BranchOps.cpp bounds sp to [base+2MB, base+6MB).
  //
  // ⚠️ These are NAMED because several sites derive their own bounds from
  // CALLRET_STACK_SIZE (/4 for the default location, +SIZE for the end). Changing
  // CALLRET_STACK_SIZE alone does NOT move the window — fix these together.
  //
  // ⛔ THIS WINDOW IS NOT THE LIVE SET, AND MUST NOT BE USED TO SIZE A CLEAR.
  // ml609 assumed it was and clipped ResetCallRetStack() to it; the build
  // regressed by ~388MB of `fex` band at a matched cycle and still died of
  // jetsam. Two reasons, both checkable in source:
  //
  //   (a) Dispatcher.cpp's JITCallback sentinel push tests only
  //       (sp - base) >> 24 — the WHOLE 16MB — so the callback path is not
  //       bounded by this window at all. (What fraction of the 16MB it really
  //       touches is measured by [dc-census] in wine's decommit_pages().)
  //
  //   (b) The clear RECLAIMS rather than dirties. VirtualDontNeed() is
  //       MEM_DECOMMIT + MEM_COMMIT, and on this (non-pool-aliased) range wine's
  //       decommit_pages() does anon_mmap_fixed() — a fresh MAP_ANON|MAP_FIXED
  //       that drops the physical pages and installs zero-fill-on-demand. The
  //       recommit only restores access. So a full-size clear RETURNS memory,
  //       and shrinking it strands the remainder resident.
  //
  // Clear CALLRET_STACK_SIZE. These constants describe the guard, not the cost.
  static constexpr size_t CALLRET_DEFAULT_OFFSET {CALLRET_STACK_SIZE / 4};        // 4MB: initial sp
  static constexpr size_t CALLRET_LIVE_OFFSET {CALLRET_STACK_SIZE / 8};           // 2MB: guard low bound
  static constexpr size_t CALLRET_LIVE_SIZE {CALLRET_STACK_SIZE / 4};             // 4MB: guard window [2MB,6MB)

  // The low address of the call-ret stack allocation (not including guard pages)
  void* CallRetStackBase {};

  uintptr_t JITGuardPage {};
  uint64_t JITGuardOverflowArgument {};
  FEXCore::UncheckedLongJump::JumpBuf RestartJump;

  // BaseFrameState should always be at the end, directly before the interrupt fault page
  FEXCore::Core::CpuStateFrame BaseFrameState {};

  // Can be reprotected as RO to trigger an interrupt at generated code block entrypoints
  alignas(FEXCore::Utils::FEX_PAGE_SIZE) uint8_t InterruptFaultPage[FEXCore::Utils::FEX_PAGE_SIZE];
};
static_assert(std::is_standard_layout_v<FEXCore::Core::InternalThreadState>);
// Apple's libc++ has a larger std::shared_mutex (~200 bytes vs ~56 on Linux),
// which pushes InternalThreadState past the offsets/sizes these asserts check.
// They remain valid on Linux/Windows.
#if !defined(__APPLE__)
// Maximum unsigned-offset store range for fault page.
static_assert(
  (offsetof(FEXCore::Core::InternalThreadState, InterruptFaultPage) - offsetof(FEXCore::Core::InternalThreadState, BaseFrameState)) <= 65520,
  "Fault page is outside of immediate range from CPU state");
#endif

// ml609/ml610: THE single callret reset path, shared by Core.cpp/CPUBackend.cpp/JIT.cpp.
// Defined in Core.cpp. Clears the FULL [base, base+CALLRET_STACK_SIZE) reservation —
// see the ⛔ note above for why a smaller clear is a regression, not an optimisation.
// Site must be one of the literals in Core.cpp's CallRetSiteNames[] to be counted.
void ResetCallRetStack(InternalThreadState* Thread, const char* Site);

} // namespace FEXCore::Core
