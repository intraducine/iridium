// SPDX-License-Identifier: MIT

#include <FEXCore/Utils/AllocatorHooksBase.h>

#ifndef _WIN32
#include <sys/mman.h>
#endif

#ifdef ENABLE_FEX_ALLOCATOR
#include <rpmalloc/rpmalloc.h>
#ifndef _WIN32
#include <FEXCore/Utils/PrctlUtils.h>
#else
#define NTDDI_VERSION 0x0A000005
#include <memoryapi.h>
#endif
#endif

#include <cstdint>
#include <map>
#include <mutex>
#ifdef __APPLE__
#include <malloc/malloc.h>
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/vm_map.h>
#else
#include <malloc.h>
#endif
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <atomic>

#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
#include <pthread.h>

extern "C" uintptr_t iridium_fex_ios_prepare_debugger_owned_region(void* address, size_t size) __attribute__((weak_import));
extern "C" int iridium_fex_ios_debugger_region_protocol_required(void) __attribute__((weak_import));
extern "C" int iridium_fex_ios_debugger_region_protocol_ready(void) __attribute__((weak_import));
#endif

namespace FEXCore::Allocator {
using mmap_hook_type = void* (*)(void* addr, size_t length, int prot, int flags, int fd, off_t offset);
using munmap_hook_type = int (*)(void* addr, size_t length);
using JITWriteCallback = int (*)(void* Context);

namespace {
  struct SplitCodeRegion {
    uintptr_t executable_base {};
    uintptr_t writable_base {};
    size_t size {};
    CodeMemoryBackend backend {CodeMemoryBackend::None};
    bool from_preallocated_pool {false};
  };

  struct PreallocatedCodePool {
    uintptr_t executable_base {};
    uintptr_t writable_base {};
    size_t size {};
    size_t next_offset {};
    bool initialized {false};
  };

  std::mutex g_split_code_regions_mutex;
  std::map<uintptr_t, SplitCodeRegion> g_split_code_regions;
  std::mutex g_preallocated_code_pool_mutex;
  PreallocatedCodePool g_preallocated_code_pool;
  thread_local CodeMemoryOperationStatus g_last_code_memory_operation {};

  bool env_enabled(const char* name) {
    const char* value = std::getenv(name);
    return value != nullptr && std::strcmp(value, "1") == 0;
  }

  bool env_equals(const char* name, const char* expected) {
    const char* value = std::getenv(name);
    return value != nullptr && std::strcmp(value, expected) == 0;
  }

  bool split_allocator_requested() {
    // Explicit env var override.
    if (env_equals("IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND", "split-rx-rw")) {
      return true;
    }
    if (env_equals("IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND", "preallocated-rx-rw")) {
      return true;
    }
    if (env_equals("IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND", "map-jit-fallback")) {
      return false;
    }
    // Host testing support.
    if (env_enabled("IRIDIUM_FEX_IOS_ENABLE_SPLIT_CODE_ALLOCATOR_ON_HOST")) {
      return true;
    }
#if defined(IRIDIUM_FEX_IOS_EMBEDDED) && defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    // Sideloaded iOS builds obtain executable-memory permission through an
    // attached debugger. Keep executable and writable views split so the
    // debugger can own the RX mirror without making generated code RWX.
    return true;
#endif
    return false;
  }

  bool preallocated_pool_requested() {
    #if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (std::getenv("IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND") == nullptr) {
      return true;
    }
    #endif
    if (env_equals("IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND", "preallocated-rx-rw")) {
      return true;
    }
    if (env_equals("IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND", "split-rx-rw")) {
      return false;
    }
    return false;
  }

  size_t preallocated_pool_size() {
    constexpr size_t default_size = 512ULL * 1024ULL * 1024ULL;
    constexpr size_t maximum_size = 2ULL * 1024ULL * 1024ULL * 1024ULL;
    const char* value = std::getenv("IRIDIUM_FEX_IOS_PREALLOCATED_POOL_SIZE_BYTES");
    if (value == nullptr || value[0] == '\0') {
      return default_size;
    }

    char* end = nullptr;
    const unsigned long long parsed = std::strtoull(value, &end, 0);
    if (end == value || *end != '\0' || parsed == 0 || parsed > maximum_size) {
      return default_size;
    }
    return static_cast<size_t>(parsed);
  }

  bool map_jit_fallback_requested() {
#if !defined(IRIDIUM_FEX_IOS_ENABLE_MAP_JIT_FALLBACK)
    return false;
#else
    // Explicit env var override.
    if (env_equals("IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND", "map-jit-fallback")) {
      return true;
    }
    if (env_equals("IRIDIUM_FEX_IOS_CODE_ALLOCATOR_BACKEND", "split-rx-rw")) {
      return false;
    }
    return false;
#endif
  }

  void set_last_code_memory_operation(CodeMemoryBackend backend, CodeMemoryFailureStage failure_stage, CodeMemoryErrorDomain error_domain,
                                      int error_code) {
    g_last_code_memory_operation = CodeMemoryOperationStatus {
      .backend = backend,
      .failure_stage = failure_stage,
      .error_domain = error_domain,
      .error_code = error_code,
    };
  }

  auto find_split_code_region_locked(uintptr_t address) {
    auto iterator = g_split_code_regions.upper_bound(address);
    if (iterator == g_split_code_regions.begin()) {
      return g_split_code_regions.end();
    }

    --iterator;
    const auto& region = iterator->second;
    if (address < region.executable_base || address >= region.executable_base + region.size) {
      return g_split_code_regions.end();
    }

    return iterator;
  }

  void* writable_alias_from_region(const SplitCodeRegion& region, uintptr_t address) {
    return reinterpret_cast<void*>(region.writable_base + (address - region.executable_base));
  }

  bool register_split_code_region(const SplitCodeRegion& region) {
    std::lock_guard<std::mutex> lock(g_split_code_regions_mutex);
    return g_split_code_regions.emplace(region.executable_base, region).second;
  }

  bool unregister_split_code_region(uintptr_t executable_base, SplitCodeRegion* region) {
    std::lock_guard<std::mutex> lock(g_split_code_regions_mutex);
    const auto iterator = g_split_code_regions.find(executable_base);
    if (iterator == g_split_code_regions.end()) {
      return false;
    }

    if (region != nullptr) {
      *region = iterator->second;
    }
    g_split_code_regions.erase(iterator);
    return true;
  }

  void* generic_virtual_alloc(void* base, size_t size, bool execute, CodeMemoryBackend backend) {
    int flags = MAP_PRIVATE | MAP_ANONYMOUS;
    int prot = PROT_READ | PROT_WRITE;
#if defined(__APPLE__) && defined(MAP_JIT)
    if (execute && backend == CodeMemoryBackend::MapJITFallback) {
      flags |= MAP_JIT;
      // MAP_JIT pages on iOS use a hardware W^X toggle managed by
      // pthread_jit_write_protect_np / pthread_jit_write_with_callback_np.
      // Requesting PROT_EXEC at mmap time is not allowed and causes the
      // allocation to fail.  The page starts in writable mode; execution
      // permission is enabled by the per-thread toggle.
    } else if (execute) {
      prot |= PROT_EXEC;
    }
#else
    if (execute) {
      prot |= PROT_EXEC;
    }
#endif

    void* pointer = FEXCore::Allocator::mmap(base, size, prot, flags, -1, 0);
    if (pointer == MAP_FAILED) {
      const auto failure_stage = backend == CodeMemoryBackend::MapJITFallback ? CodeMemoryFailureStage::MapJITFallbackAllocationFailed :
                                                                                CodeMemoryFailureStage::None;
      set_last_code_memory_operation(backend, failure_stage, CodeMemoryErrorDomain::Errno, errno);
      return nullptr;
    }

    set_last_code_memory_operation(backend, CodeMemoryFailureStage::None, CodeMemoryErrorDomain::None, 0);
    return pointer;
  }

#if defined(__APPLE__)
  void deallocate_mach_region(uintptr_t address, size_t size) {
    if (address == 0 || size == 0) {
      return;
    }

    vm_deallocate(mach_task_self(), static_cast<vm_address_t>(address), static_cast<vm_size_t>(size));
  }
#endif

  void* split_virtual_alloc(void* base, size_t size) {
#if defined(__APPLE__)
    if (base != nullptr) {
      set_last_code_memory_operation(CodeMemoryBackend::SplitRXRWDebugger, CodeMemoryFailureStage::RequestedAddressUnsupported,
                                     CodeMemoryErrorDomain::Errno, EINVAL);
      errno = EINVAL;
      return nullptr;
    }

    bool requires_rx_seed = false;
    bool requires_debugger_region_protocol = false;
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (__builtin_available(iOS 26, *)) {
      requires_rx_seed = true;
    }

    requires_debugger_region_protocol =
      iridium_fex_ios_debugger_region_protocol_required != nullptr &&
      iridium_fex_ios_debugger_region_protocol_required() != 0;
    if (requires_debugger_region_protocol) {
      if (iridium_fex_ios_debugger_region_protocol_ready == nullptr ||
          iridium_fex_ios_debugger_region_protocol_ready() == 0 ||
          iridium_fex_ios_prepare_debugger_owned_region == nullptr) {
        set_last_code_memory_operation(CodeMemoryBackend::SplitRXRWDebugger, CodeMemoryFailureStage::DebuggerPreparationFailed,
                                       CodeMemoryErrorDomain::Errno, ENOTCONN);
        errno = ENOTCONN;
        return nullptr;
      }
    }
#endif

    vm_address_t executable_address {};
    if (requires_debugger_region_protocol) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
      // iOS 26+ TXM does not permit an ordinary RW vm_allocate region to be
      // promoted to executable, even while the process is traced. Ask the
      // persistent StikDebug callback to allocate the RX region through
      // debugserver first; its maximum protection then permits vm_remap to
      // create the writable alias below.
      executable_address = static_cast<vm_address_t>(
        iridium_fex_ios_prepare_debugger_owned_region(nullptr, size));
      if (executable_address == 0) {
        set_last_code_memory_operation(CodeMemoryBackend::SplitRXRWDebugger, CodeMemoryFailureStage::DebuggerPreparationFailed,
                                       CodeMemoryErrorDomain::Errno, ENOTCONN);
        errno = ENOTCONN;
        return nullptr;
      }
      requires_rx_seed = false;
#endif
    } else {
      const kern_return_t allocation_result =
        vm_allocate(mach_task_self(), &executable_address, static_cast<vm_size_t>(size), VM_FLAGS_ANYWHERE);
      if (allocation_result != KERN_SUCCESS) {
        set_last_code_memory_operation(CodeMemoryBackend::SplitRXRWDebugger, CodeMemoryFailureStage::RWMappingFailed,
                                       CodeMemoryErrorDomain::Mach, allocation_result);
        return nullptr;
      }
    }

    if (requires_rx_seed &&
        ::mprotect(reinterpret_cast<void*>(executable_address), size, PROT_READ | PROT_EXEC) != 0) {
      const int error_number = errno;
      deallocate_mach_region(executable_address, size);
      set_last_code_memory_operation(CodeMemoryBackend::SplitRXRWDebugger, CodeMemoryFailureStage::RXMirrorMappingFailed,
                                     CodeMemoryErrorDomain::Errno, error_number);
      errno = error_number;
      return nullptr;
    }
    vm_address_t writable_address {};
    vm_prot_t current_protection {};
    vm_prot_t maximum_protection {};
    kern_return_t result =
      vm_remap(mach_task_self(), &writable_address, static_cast<vm_size_t>(size), 0, VM_FLAGS_ANYWHERE, mach_task_self(),
               executable_address, FALSE, &current_protection, &maximum_protection, VM_INHERIT_NONE);
    if (result != KERN_SUCCESS) {
      deallocate_mach_region(executable_address, size);
      set_last_code_memory_operation(CodeMemoryBackend::SplitRXRWDebugger, CodeMemoryFailureStage::RXMirrorMappingFailed,
                                     CodeMemoryErrorDomain::Mach, result);
      return nullptr;
    }

    if (::mprotect(reinterpret_cast<void*>(writable_address), size, PROT_READ | PROT_WRITE) != 0) {
      const int error_number = errno;
      deallocate_mach_region(executable_address, size);
      deallocate_mach_region(writable_address, size);
      set_last_code_memory_operation(CodeMemoryBackend::SplitRXRWDebugger, CodeMemoryFailureStage::RWMappingFailed,
                                     CodeMemoryErrorDomain::Errno, error_number);
      errno = error_number;
      return nullptr;
    }

    if (::mprotect(reinterpret_cast<void*>(executable_address), size, PROT_READ | PROT_EXEC) != 0) {
      const int error_number = errno;
      deallocate_mach_region(executable_address, size);
      deallocate_mach_region(writable_address, size);
      set_last_code_memory_operation(CodeMemoryBackend::SplitRXRWDebugger, CodeMemoryFailureStage::RXMirrorMappingFailed,
                                     CodeMemoryErrorDomain::Errno, error_number);
      errno = error_number;
      return nullptr;
    }

    const SplitCodeRegion region {
      .executable_base = static_cast<uintptr_t>(executable_address),
      .writable_base = static_cast<uintptr_t>(writable_address),
      .size = size,
      .backend = CodeMemoryBackend::SplitRXRWDebugger,
    };
    if (!register_split_code_region(region)) {
      deallocate_mach_region(executable_address, size);
      deallocate_mach_region(writable_address, size);
      set_last_code_memory_operation(CodeMemoryBackend::SplitRXRWDebugger, CodeMemoryFailureStage::DebugMapRegistrationFailed,
                                     CodeMemoryErrorDomain::Errno, ENOMEM);
      errno = ENOMEM;
      return nullptr;
    }

    set_last_code_memory_operation(CodeMemoryBackend::SplitRXRWDebugger, CodeMemoryFailureStage::None, CodeMemoryErrorDomain::None, 0);
    return reinterpret_cast<void*>(executable_address);
#else
    (void)base;
    (void)size;
    set_last_code_memory_operation(CodeMemoryBackend::SplitRXRWDebugger, CodeMemoryFailureStage::RequestedAddressUnsupported,
                                   CodeMemoryErrorDomain::Errno, ENOTSUP);
    errno = ENOTSUP;
    return nullptr;
#endif
  }

  int prot_from_options(ProtectOptions options, bool executable_view) {
    int protection = PROT_NONE;
    if ((options & ProtectOptions::Read) == ProtectOptions::Read) {
      protection |= PROT_READ;
    }
    if (!executable_view && (options & ProtectOptions::Write) == ProtectOptions::Write) {
      protection |= PROT_WRITE;
    }
    if (executable_view && (options & ProtectOptions::Exec) == ProtectOptions::Exec) {
      protection |= PROT_READ | PROT_EXEC;
    }
    return protection;
  }
#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  bool iOSJITWriteCallbacksSupported() {
    if (__builtin_available(iOS 17.4, *)) {
      return pthread_jit_write_protect_supported_np() != 0;
    }

    return false;
  }

  struct JITWriteCallbackState {
    JITWriteCallback Callback;
    void* Context;
  };

  int GenericJITWriteCallback(void* Opaque) {
    auto* State = static_cast<JITWriteCallbackState*>(Opaque);
    return State->Callback(State->Context);
  }

  PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP(GenericJITWriteCallback);
#endif

  struct MemcpyCodeMemoryState {
    void* Destination;
    const void* Source;
    size_t Size;
  };

  int MemcpyCodeMemoryCallback(void* Opaque) {
    auto* State = static_cast<MemcpyCodeMemoryState*>(Opaque);
    ::memcpy(State->Destination, State->Source, State->Size);
    return 0;
  }

  struct StoreCodeMemory32State {
    uint32_t* Destination;
    uint32_t Value;
  };

  int StoreCodeMemory32Callback(void* Opaque) {
    auto* State = static_cast<StoreCodeMemory32State*>(Opaque);
    std::atomic_ref<uint32_t>(*State->Destination).store(State->Value, std::memory_order::relaxed);
    return 0;
  }

  struct StoreCodeMemory64State {
    uint64_t* Destination;
    uint64_t Value;
  };

  int StoreCodeMemory64Callback(void* Opaque) {
    auto* State = static_cast<StoreCodeMemory64State*>(Opaque);
    std::atomic_ref<uint64_t>(*State->Destination).store(State->Value, std::memory_order::seq_cst);
    return 0;
  }
} // namespace

const char* GetCodeMemoryBackendName(CodeMemoryBackend backend) {
  switch (backend) {
  case CodeMemoryBackend::SplitRXRWDebugger: return "split-rx-rw-debugger";
  case CodeMemoryBackend::MapJITFallback: return "map-jit-fallback";
  case CodeMemoryBackend::None: return "none";
  }

  return "none";
}

const char* GetCodeMemoryFailureStageName(CodeMemoryFailureStage stage) {
  switch (stage) {
  case CodeMemoryFailureStage::RequestedAddressUnsupported: return "requested fixed executable address is unsupported";
  case CodeMemoryFailureStage::RWMappingFailed: return "RW mapping failed";
  case CodeMemoryFailureStage::RXMirrorMappingFailed: return "RX mirror mapping failed";
  case CodeMemoryFailureStage::DebuggerPreparationFailed: return "debugger RX preparation failed";
  case CodeMemoryFailureStage::DebugMapRegistrationFailed: return "debug-map registration failed";
  case CodeMemoryFailureStage::MapJITFallbackAllocationFailed: return "MAP_JIT fallback allocation failed";
  case CodeMemoryFailureStage::None: return "";
  }

  return "";
}

CodeMemoryOperationStatus GetLastCodeMemoryOperationStatus() {
  return g_last_code_memory_operation;
}

void* GetWritableAlias(void* Ptr) {
  if (Ptr == nullptr) {
    return nullptr;
  }

  const uintptr_t address = reinterpret_cast<uintptr_t>(Ptr);
  std::lock_guard<std::mutex> lock(g_split_code_regions_mutex);
  const auto iterator = find_split_code_region_locked(address);
  if (iterator == g_split_code_regions.end()) {
    return Ptr;
  }

  return writable_alias_from_region(iterator->second, address);
}

void* preallocated_pool_virtual_alloc(void* Base, size_t Size);

void* VirtualAllocImpl(void* Base, size_t Size, bool Execute, bool Commit) {
  (void)Commit;
  if (!Execute) {
    return generic_virtual_alloc(Base, Size, false, CodeMemoryBackend::None);
  }

  if (map_jit_fallback_requested()) {
    void* result = generic_virtual_alloc(Base, Size, true, CodeMemoryBackend::MapJITFallback);
    // An explicitly selected backend must fail closed. Falling through would
    // report a different memory model than the caller requested and obscure
    // the real entitlement or debugger-bootstrap failure.
    return result;
  }

  if (split_allocator_requested()) {
    if (preallocated_pool_requested()) {
      return preallocated_pool_virtual_alloc(Base, Size);
    }
    return split_virtual_alloc(Base, Size);
  }

  return generic_virtual_alloc(Base, Size, true, CodeMemoryBackend::None);
}

void* preallocated_pool_virtual_alloc(void* Base, size_t Size) {
  if (Base != nullptr || Size == 0) {
    set_last_code_memory_operation(
      CodeMemoryBackend::SplitRXRWDebugger,
      CodeMemoryFailureStage::RequestedAddressUnsupported,
      CodeMemoryErrorDomain::Errno,
      EINVAL
    );
    errno = EINVAL;
    return nullptr;
  }

  const size_t page_size = static_cast<size_t>(::getpagesize());
  if (page_size == 0 || Size > static_cast<size_t>(-1) - (page_size - 1)) {
    set_last_code_memory_operation(
      CodeMemoryBackend::SplitRXRWDebugger,
      CodeMemoryFailureStage::RWMappingFailed,
      CodeMemoryErrorDomain::Errno,
      ENOMEM
    );
    errno = ENOMEM;
    return nullptr;
  }
  const size_t allocation_size = (Size + page_size - 1) & ~(page_size - 1);

  std::lock_guard<std::mutex> pool_lock(g_preallocated_code_pool_mutex);
  if (!g_preallocated_code_pool.initialized) {
    size_t pool_size = preallocated_pool_size();
    if (pool_size < allocation_size) {
      pool_size = allocation_size;
    }
    if (pool_size > static_cast<size_t>(-1) - (page_size - 1)) {
      set_last_code_memory_operation(
        CodeMemoryBackend::SplitRXRWDebugger,
        CodeMemoryFailureStage::RWMappingFailed,
        CodeMemoryErrorDomain::Errno,
        ENOMEM
      );
      errno = ENOMEM;
      return nullptr;
    }
    pool_size = (pool_size + page_size - 1) & ~(page_size - 1);

    // Reuse the existing RX/RW creation path. The temporary registry entry is
    // replaced by subrange entries as callers carve the pool.
    void* pool_rx = split_virtual_alloc(nullptr, pool_size);
    if (pool_rx == nullptr) {
      return nullptr;
    }

    SplitCodeRegion backing_region {};
    if (!unregister_split_code_region(reinterpret_cast<uintptr_t>(pool_rx), &backing_region)) {
      set_last_code_memory_operation(
        CodeMemoryBackend::SplitRXRWDebugger,
        CodeMemoryFailureStage::DebugMapRegistrationFailed,
        CodeMemoryErrorDomain::Errno,
        ENOMEM
      );
      errno = ENOMEM;
      return nullptr;
    }

    g_preallocated_code_pool = PreallocatedCodePool {
      .executable_base = backing_region.executable_base,
      .writable_base = backing_region.writable_base,
      .size = backing_region.size,
      .next_offset = 0,
      .initialized = true,
    };
  }

  auto& pool = g_preallocated_code_pool;
  if (pool.next_offset > pool.size || allocation_size > pool.size - pool.next_offset) {
    set_last_code_memory_operation(
      CodeMemoryBackend::SplitRXRWDebugger,
      CodeMemoryFailureStage::RWMappingFailed,
      CodeMemoryErrorDomain::Errno,
      ENOMEM
    );
    errno = ENOMEM;
    return nullptr;
  }

  const size_t offset = pool.next_offset;
  const SplitCodeRegion allocation {
    .executable_base = pool.executable_base + offset,
    .writable_base = pool.writable_base + offset,
    .size = allocation_size,
    .backend = CodeMemoryBackend::SplitRXRWDebugger,
    .from_preallocated_pool = true,
  };
  if (!register_split_code_region(allocation)) {
    set_last_code_memory_operation(
      CodeMemoryBackend::SplitRXRWDebugger,
      CodeMemoryFailureStage::DebugMapRegistrationFailed,
      CodeMemoryErrorDomain::Errno,
      ENOMEM
    );
    errno = ENOMEM;
    return nullptr;
  }

  pool.next_offset += allocation_size;
  set_last_code_memory_operation(
    CodeMemoryBackend::SplitRXRWDebugger,
    CodeMemoryFailureStage::None,
    CodeMemoryErrorDomain::None,
    0
  );
  return reinterpret_cast<void*>(allocation.executable_base);
}

void VirtualFreeImpl(void* Ptr, size_t Size) {
  if (Ptr == nullptr) {
    return;
  }

  SplitCodeRegion region {};
  if (unregister_split_code_region(reinterpret_cast<uintptr_t>(Ptr), &region)) {
    if (region.from_preallocated_pool) {
      // The pool is intentionally process-lived. Releasing a subrange with
      // vm_deallocate would split the shared mapping and make later offsets
      // unsafe; the bump frontier remains monotonic for this process.
      // ponytail: no subrange reuse; add a free-list if long-lived sessions
      // exhaust the configured pool.
      return;
    }
#if defined(__APPLE__)
    deallocate_mach_region(region.executable_base, region.size);
    deallocate_mach_region(region.writable_base, region.size);
#else
    (void)Size;
#endif
    return;
  }

  FEXCore::Allocator::munmap(Ptr, Size);
}

void VirtualDontNeedImpl(void* Ptr, size_t Size, bool Recommit) {
  (void)Recommit;
  if (Ptr == nullptr || Size == 0) {
    return;
  }

  const uintptr_t address = reinterpret_cast<uintptr_t>(Ptr);
  {
    std::lock_guard<std::mutex> lock(g_split_code_regions_mutex);
    const auto iterator = find_split_code_region_locked(address);
    if (iterator != g_split_code_regions.end()) {
      ::madvise(writable_alias_from_region(iterator->second, address), Size, MADV_DONTNEED);
      return;
    }
  }

  ::madvise(reinterpret_cast<void*>(Ptr), Size, MADV_DONTNEED);
}

bool VirtualProtectImpl(void* Ptr, size_t Size, ProtectOptions options) {
  if (Ptr == nullptr || Size == 0) {
    return true;
  }

  const uintptr_t address = reinterpret_cast<uintptr_t>(Ptr);
  {
    std::lock_guard<std::mutex> lock(g_split_code_regions_mutex);
    const auto iterator = find_split_code_region_locked(address);
    if (iterator != g_split_code_regions.end()) {
      const auto writable = writable_alias_from_region(iterator->second, address);
      const bool writable_result = ::mprotect(writable, Size, prot_from_options(options, false)) == 0;
      const bool executable_result = ::mprotect(Ptr, Size, prot_from_options(options, true)) == 0;
      return writable_result && executable_result;
    }
  }

  return ::mprotect(Ptr, Size,
                    prot_from_options(options, false) | (((options & ProtectOptions::Exec) == ProtectOptions::Exec) ? PROT_EXEC : 0)) == 0;
}

void VirtualTHPControlImpl(void* Ptr, size_t Size, THPControl Control) {
#if defined(MADV_HUGEPAGE) && defined(MADV_NOHUGEPAGE)
  ::madvise(Ptr, Size, Control == THPControl::Enable ? MADV_HUGEPAGE : MADV_NOHUGEPAGE);
#else
  (void)Ptr;
  (void)Size;
  (void)Control;
#endif
}

#ifdef ENABLE_FEX_ALLOCATOR
typedef void* (*rp_mmap_hook_type)(size_t size, size_t alignment, size_t* offset, size_t* mapped_size);
typedef void (*rp_munmap_hook_type)(void* address, size_t offset, size_t mapped_size);
extern "C" rp_mmap_hook_type rp_mmap_hook;
extern "C" rp_munmap_hook_type rp_munmap_hook;

#ifndef _WIN32
mmap_hook_type fex_mmap_hook = ::mmap;
munmap_hook_type fex_munmap_hook = ::munmap;
#endif

// Assume a 64KB page size until told otherwise.
static rpmalloc_config_t global_config {
  .page_size = 64 * 1024,
  // THP causes crashes for some reason.
  .enable_huge_pages = 0,
  .disable_decommit = 0,
  .page_name = "FEXAllocator",
  .huge_page_name = "FEXAllocator",
  .unmap_on_finalize = 0,
};

void* malloc(size_t size) {
  return ::rpmalloc(size);
}
void* calloc(size_t n, size_t size) {
  return ::rpcalloc(n, size);
}
void* memalign(size_t align, size_t s) {
  return ::rpmemalign(align, s);
}
void* valloc(size_t size) {
  return ::rpaligned_alloc(global_config.page_size, size);
}
int posix_memalign(void** r, size_t a, size_t s) {
  void* ptr;
  auto res = ::rpposix_memalign(&ptr, a, s);
  *r = ptr;
  return res;
}
void* realloc(void* ptr, size_t size) {
  return ::rprealloc(ptr, size);
}
void free(void* ptr) {
  return ::rpfree(ptr);
}
size_t malloc_usable_size(void* ptr) {
  return ::rpmalloc_usable_size(ptr);
}
void* aligned_alloc(size_t a, size_t s) {
  return ::rpaligned_alloc(a, s);
}
void aligned_free(void* ptr) {
  return ::rpfree(ptr);
}

void InitializeThread() {
  rpmalloc_thread_initialize();
}

#ifndef _WIN32
[[nodiscard]]
constexpr uint64_t AlignUp(uint64_t value, uint64_t size) {
  return value + (size - value % size) % size;
}

static void* FEX_rp_mmap(size_t size, size_t alignment, size_t* offset, size_t* mapped_size) {
#define pointer_offset(ptr, ofs) (void*)((char*)(ptr) + (ptrdiff_t)(ofs))
  // If the alignment is less than the operating page size then alignment is guaranteed. Just remove it.
  if (alignment < global_config.page_size) {
    alignment = 0;
  }

  size_t map_size = AlignUp(size + alignment, global_config.page_size);
  auto ptr = fex_mmap_hook(0, map_size, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);

  if (ptr == MAP_FAILED) {
    ptr = nullptr;
  } else {
    prctl(PR_SET_VMA, PR_SET_VMA_ANON_NAME, ptr, map_size, global_config.page_name);

    // Disable HUGEPAGE on allocation from rpmalloc when the host exposes the advice flag.
#ifdef MADV_NOHUGEPAGE
    madvise(ptr, map_size, MADV_NOHUGEPAGE);
#endif
  }

  if (ptr == nullptr) {
    fprintf(stderr, "Failed to map VMA region.");
    return nullptr;
  }

  if (alignment) {
    size_t padding = ((uintptr_t)ptr & (uintptr_t)(alignment - 1));
    if (padding) {
      padding = alignment - padding;
    }
    ptr = pointer_offset(ptr, padding);
    *offset = padding;
  }
  *mapped_size = map_size;
  return ptr;
}

static void FEX_rp_memory_commit(void* address, size_t size) {
  // NOP-implementation.
}

static void FEX_rp_memory_decommit(void* address, size_t size) {
  if (global_config.disable_decommit) {
    return;
  }

  if (madvise(address, size, MADV_DONTNEED)) {
    fprintf(stderr, "Failed to decommit VMA region.");
  }
}

static void FEX_rp_memory_unmap(void* address, size_t offset, size_t mapped_size) {
  address = pointer_offset(address, -(int32_t)offset);
  int Result = fex_munmap_hook(address, mapped_size);
  if (Result == -1) {
    fprintf(stderr, "Failed to unmap VMA region.");
  }
#undef pointer_offset
}

void SetupAllocatorHooks(mmap_hook_type MMapHook, munmap_hook_type MunmapHook) {
  fex_mmap_hook = MMapHook;
  fex_munmap_hook = MunmapHook;
}

static rpmalloc_interface_t global_interface {
  .memory_map = FEX_rp_mmap,
  .memory_commit = FEX_rp_memory_commit,
  .memory_decommit = FEX_rp_memory_decommit,
  .memory_unmap = FEX_rp_memory_unmap,
  .map_fail_callback = nullptr,
  .error_callback = nullptr,
};

void InitializeAllocator(size_t PageSize) {
  global_config.page_size = PageSize;
  rpmalloc_initialize_config(&global_interface, &global_config);
  rp_mmap_hook = FEX_rp_mmap;
  rp_munmap_hook = FEX_rp_memory_unmap;
}
#endif

#elif defined(_WIN32)
#error "Tried building _WIN32 without jemalloc"

#else
void InitializeThread() { }

void* malloc(size_t size) {
  return ::malloc(size);
}
void* calloc(size_t n, size_t size) {
  return ::calloc(n, size);
}
void* memalign(size_t align, size_t s) {
  return ::memalign(align, s);
}
void* valloc(size_t size) {
  return ::valloc(size);
}
int posix_memalign(void** r, size_t a, size_t s) {
  return ::posix_memalign(r, a, s);
}
void* realloc(void* ptr, size_t size) {
  return ::realloc(ptr, size);
}
void free(void* ptr) {
  return ::free(ptr);
}
size_t malloc_usable_size(void* ptr) {
#ifdef __APPLE__
  return ::malloc_size(ptr);
#else
  return ::malloc_usable_size(ptr);
#endif
}
void* aligned_alloc(size_t a, size_t s) {
  return ::aligned_alloc(a, s);
}
void aligned_free(void* ptr) {
  return ::free(ptr);
}

void SetupAllocatorHooks(mmap_hook_type MMapHook, munmap_hook_type MunmapHook) { }

void InitializeAllocator(size_t PageSize) { }

#endif

int ExecuteJITWriteCallbackForCodeMemory(void* WriteTarget, JITWriteCallback Callback, void* Context) {
#if defined(__APPLE__) && TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
  if (iOSJITWriteCallbacksSupported() && (WriteTarget == nullptr || GetWritableAlias(WriteTarget) == WriteTarget)) {
    if (__builtin_available(iOS 17.4, *)) {
      JITWriteCallbackState State {
        .Callback = Callback,
        .Context = Context,
      };
      return pthread_jit_write_with_callback_np(GenericJITWriteCallback, &State);
    }
  }
#endif

  return Callback(Context);
}

int ExecuteJITWriteCallback(JITWriteCallback Callback, void* Context) {
  return ExecuteJITWriteCallbackForCodeMemory(nullptr, Callback, Context);
}

void MemcpyToCodeMemory(void* Destination, const void* Source, size_t Size) {
  MemcpyCodeMemoryState State {
    .Destination = GetWritableAlias(Destination),
    .Source = Source,
    .Size = Size,
  };
  ExecuteJITWriteCallbackForCodeMemory(Destination, MemcpyCodeMemoryCallback, &State);
}

void StoreToCodeMemory(uint32_t* Destination, uint32_t Value) {
  StoreCodeMemory32State State {
    .Destination = static_cast<uint32_t*>(GetWritableAlias(Destination)),
    .Value = Value,
  };
  ExecuteJITWriteCallbackForCodeMemory(Destination, StoreCodeMemory32Callback, &State);
}

void StoreToCodeMemory(uint64_t& Destination, uint64_t Value) {
  StoreCodeMemory64State State {
    .Destination = static_cast<uint64_t*>(GetWritableAlias(&Destination)),
    .Value = Value,
  };
  ExecuteJITWriteCallbackForCodeMemory(&Destination, StoreCodeMemory64Callback, &State);
}
} // namespace FEXCore::Allocator
