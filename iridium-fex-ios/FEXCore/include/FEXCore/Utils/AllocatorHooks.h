// SPDX-License-Identifier: MIT
#pragma once
#include <FEXCore/Utils/AllocatorHooksBase.h>
#include <FEXCore/Utils/CompilerDefs.h>
#include <FEXCore/Utils/LogManager.h>

#ifndef _WIN32
#include <stdlib.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#include <malloc/malloc.h>
#else
#include <malloc.h>
#endif
#include <sys/mman.h>
#else
#define NTDDI_VERSION 0x0A000005
#include <memoryapi.h>
#endif

#include <new>
#include <cstddef>
#include <cstdint>
#include <string>
#include <sys/types.h>

namespace FEXCore::Allocator {
#ifdef _WIN32
inline void* VirtualAlloc(void* Base, size_t Size, bool Execute = false, bool Commit = true) {
  // Allocate top-down to avoid polluting the lower VA space, as even on 64-bit some programs (i.e. LuaJIT) require allocations below 4GB.
  DWORD Flags = (Commit ? MEM_COMMIT : 0) | MEM_RESERVE | MEM_TOP_DOWN;
#ifdef ARCHITECTURE_arm64ec
  MEM_EXTENDED_PARAMETER Parameter {};
  if (Execute) {
    Parameter.Type = MemExtendedParameterAttributeFlags;
    Parameter.ULong64 = MEM_EXTENDED_PARAMETER_EC_CODE;
  };
  return ::VirtualAlloc2(nullptr, Base, Size, Flags, Execute ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE, Execute ? &Parameter : nullptr,
                         Execute ? 1 : 0);
#else
  return ::VirtualAlloc(Base, Size, Flags, Execute ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE);
#endif
}

inline void* VirtualAlloc(size_t Size, bool Execute = false, bool Commit = true) {
  return VirtualAlloc(nullptr, Size, Execute, Commit);
}

inline void VirtualFree(void* Ptr, size_t Size) {
  ::VirtualFree(Ptr, 0, MEM_RELEASE);
}

inline void VirtualDontNeed(void* Ptr, size_t Size, bool Recommit = true) {
  // Zero the page-aligned region, preserving permissions.
  MEMORY_BASIC_INFORMATION Info;
  ::VirtualQuery(Ptr, &Info, sizeof(Info));
  ::VirtualFree(Ptr, Size, MEM_DECOMMIT);
  if (Recommit) {
    ::VirtualAlloc(Ptr, Size, MEM_COMMIT, Info.Protect);
  }
}

inline bool VirtualProtect(void* Ptr, size_t Size, ProtectOptions options) {
  DWORD prot {PAGE_NOACCESS};

  if (options == ProtectOptions::None) {
    prot = PAGE_NOACCESS;
  } else if (options == ProtectOptions::Read) {
    prot = PAGE_READONLY;
  } else if (options == (ProtectOptions::Read | ProtectOptions::Write)) {
    prot = PAGE_READWRITE;
  } else if (options == (ProtectOptions::Read | ProtectOptions::Exec)) {
    prot = PAGE_EXECUTE_READ;
  } else if (options == (ProtectOptions::Read | ProtectOptions::Write | ProtectOptions::Exec)) {
    prot = PAGE_EXECUTE_READWRITE;
  } else {
    LOGMAN_MSG_A_FMT("Unknown VirtualProtect options combination");
  }

  return ::VirtualProtect(Ptr, Size, prot, nullptr) == 0;
}

inline void VirtualName(const char*, void*, size_t) {}
inline void VirtualTHPControl(void* Ptr, size_t Size, THPControl Control) {}

#else
FEX_DEFAULT_VISIBILITY extern void VirtualName(const char* Name, void* Ptr, size_t Size);

FEX_DEFAULT_VISIBILITY void* VirtualAllocImpl(void* Base, size_t Size, bool Execute = false, bool Commit = true);
FEX_DEFAULT_VISIBILITY void VirtualFreeImpl(void* Ptr, size_t Size);
FEX_DEFAULT_VISIBILITY void VirtualDontNeedImpl(void* Ptr, size_t Size, bool Recommit = true);
FEX_DEFAULT_VISIBILITY bool VirtualProtectImpl(void* Ptr, size_t Size, ProtectOptions options);
FEX_DEFAULT_VISIBILITY void VirtualTHPControlImpl(void* Ptr, size_t Size, THPControl Control);
FEX_DEFAULT_VISIBILITY void* GetWritableAlias(void* Ptr);
FEX_DEFAULT_VISIBILITY CodeMemoryOperationStatus GetLastCodeMemoryOperationStatus();
FEX_DEFAULT_VISIBILITY const char* GetCodeMemoryBackendName(CodeMemoryBackend backend);
FEX_DEFAULT_VISIBILITY const char* GetCodeMemoryFailureStageName(CodeMemoryFailureStage stage);

// All commit parameters are ignored here, they are unnecessary as Linux supports overcommit

inline void* VirtualAlloc(size_t Size, bool Execute = false, bool Commit = true) {
  return VirtualAllocImpl(nullptr, Size, Execute, Commit);
}

inline void* VirtualAlloc(void* Base, size_t Size, bool Execute = false, bool Commit = true) {
  return VirtualAllocImpl(Base, Size, Execute, Commit);
}

inline void VirtualFree(void* Ptr, size_t Size) {
  VirtualFreeImpl(Ptr, Size);
}
inline void VirtualDontNeed(void* Ptr, size_t Size, bool Recommit = true) {
  VirtualDontNeedImpl(Ptr, Size, Recommit);
}
inline bool VirtualProtect(void* Ptr, size_t Size, ProtectOptions options) {
  return VirtualProtectImpl(Ptr, Size, options);
}

inline void VirtualTHPControl(void* Ptr, size_t Size, THPControl Control) {
  VirtualTHPControlImpl(Ptr, Size, Control);
}

FEX_DEFAULT_VISIBILITY int ExecuteJITWriteCallbackForCodeMemory(void* WriteTarget, JITWriteCallback Callback, void* Context);
FEX_DEFAULT_VISIBILITY int ExecuteJITWriteCallback(JITWriteCallback Callback, void* Context);
FEX_DEFAULT_VISIBILITY void MemcpyToCodeMemory(void* Destination, const void* Source, size_t Size);
FEX_DEFAULT_VISIBILITY void StoreToCodeMemory(uint32_t* Destination, uint32_t Value);
FEX_DEFAULT_VISIBILITY void StoreToCodeMemory(uint64_t& Destination, uint64_t Value);

#endif

// Memory allocation routines to be defined externally.
// This allows to use jemalloc for emulation while using the normal allocator
// for host tools without building FEXCore twice.
void* malloc(size_t size);
void* calloc(size_t n, size_t size);
void* memalign(size_t align, size_t s);
void* valloc(size_t size);
int posix_memalign(void** r, size_t a, size_t s);
void* realloc(void* ptr, size_t size);
void free(void* ptr);
#ifdef __APPLE__
size_t malloc_size(const void* ptr);
#endif
size_t malloc_usable_size(void* ptr);
void* aligned_alloc(size_t a, size_t s);
void aligned_free(void* ptr);

FEX_DEFAULT_VISIBILITY extern void InitializeThread();

#ifndef _WIN32
void InitializeAllocator(size_t PageSize);
void SetupAllocatorHooks(void* (*)(void* addr, size_t length, int prot, int flags, int fd, off_t offset), int (*)(void* addr, size_t length));
#endif

struct FEXAllocOperators {
  FEXAllocOperators() = default;

  void* operator new(size_t size) {
    return FEXCore::Allocator::malloc(size);
  }

  void* operator new(size_t size, std::align_val_t align) {
    return FEXCore::Allocator::aligned_alloc(static_cast<size_t>(align), size);
  }

  void operator delete(void* ptr) {
    return FEXCore::Allocator::free(ptr);
  }

  void operator delete(void* ptr, std::align_val_t align) {
    return FEXCore::Allocator::aligned_free(ptr);
  }
};
} // namespace FEXCore::Allocator
