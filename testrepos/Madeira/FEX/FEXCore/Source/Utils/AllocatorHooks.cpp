// SPDX-License-Identifier: MIT
#ifdef ENABLE_FEX_ALLOCATOR
#include <rpmalloc/rpmalloc.h>
#ifndef _WIN32
#include <sys/prctl.h>
#include <sys/mman.h>
#else
#define NTDDI_VERSION 0x0A000005
#include <memoryapi.h>
#endif
#endif

#include <cstdint>
#ifdef __APPLE__
#include <stdlib.h>
#include <malloc/malloc.h>
#else
#include <malloc.h>
#endif
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

namespace FEXCore::Allocator {
using mmap_hook_type = void* (*)(void* addr, size_t length, int prot, int flags, int fd, off_t offset);
using munmap_hook_type = int (*)(void* addr, size_t length);

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

// iOS-Madeira (ml107-ml109): threads that enter FEX without passing through
// InitCRTThread (wine loader threads during EC child boot) have no rpmalloc
// thread heap, so every hook below returned NULL/failed. The observed death:
// LogMan::Msg::MFmtImpl -> aligned_alloc == NULL -> unchecked memmove(NULL)
// -> c0000005 in ntdll memcpy, killing the child before the message it was
// formatting ever surfaced. Lazily initialize the thread heap at the hook
// boundary; rpmalloc_is_thread_initialized() is a cheap TLS read.
static inline void EnsureThreadHeap() {
  if (!::rpmalloc_is_thread_initialized()) {
    ::rpmalloc_thread_initialize();
  }
}

void* malloc(size_t size) {
  EnsureThreadHeap();
  return ::rpmalloc(size);
}
void* calloc(size_t n, size_t size) {
  EnsureThreadHeap();
  return ::rpcalloc(n, size);
}
void* memalign(size_t align, size_t s) {
  EnsureThreadHeap();
  return ::rpmemalign(align, s);
}
void* valloc(size_t size) {
  EnsureThreadHeap();
  return ::rpaligned_alloc(global_config.page_size, size);
}
int posix_memalign(void** r, size_t a, size_t s) {
  void* ptr;
  EnsureThreadHeap();
  auto res = ::rpposix_memalign(&ptr, a, s);
  *r = ptr;
  return res;
}
void* realloc(void* ptr, size_t size) {
  EnsureThreadHeap();
  return ::rprealloc(ptr, size);
}
void free(void* ptr) {
  EnsureThreadHeap();
  return ::rpfree(ptr);
}
size_t malloc_usable_size(void* ptr) {
  return ::rpmalloc_usable_size(ptr);
}
void* aligned_alloc(size_t a, size_t s) {
  EnsureThreadHeap();
  return ::rpaligned_alloc(a, s);
}
void aligned_free(void* ptr) {
  EnsureThreadHeap();
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
#ifndef PR_SET_VMA
#define PR_SET_VMA 0x53564d41
#endif

#ifndef PR_SET_VMA_ANON_NAME
#define PR_SET_VMA_ANON_NAME 0
#endif
    prctl(PR_SET_VMA, PR_SET_VMA_ANON_NAME, ptr, map_size, global_config.page_name);

    // Disable HUGEPAGE on allocation from rpmalloc.
    madvise(ptr, map_size, MADV_NOHUGEPAGE);
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
void InitializeThread() {}

void* malloc(size_t size) {
  return ::malloc(size);
}
void* calloc(size_t n, size_t size) {
  return ::calloc(n, size);
}
void* memalign(size_t align, size_t s) {
#ifdef __APPLE__
  // posix_memalign requires alignment >= sizeof(void*) and power of 2
  if (align < sizeof(void*)) align = sizeof(void*);
  void* ptr = nullptr;
  ::posix_memalign(&ptr, align, s);
  return ptr;
#else
  return ::memalign(align, s);
#endif
}
void* valloc(size_t size) {
#ifdef __APPLE__
  void* ptr = nullptr;
  ::posix_memalign(&ptr, 4096, size);
  return ptr;
#else
  return ::valloc(size);
#endif
}
int posix_memalign(void** r, size_t a, size_t s) {
#ifdef __APPLE__
  if (a < sizeof(void*)) a = sizeof(void*);
#endif
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
#ifdef __APPLE__
  // posix_memalign requires alignment >= sizeof(void*) and power of 2
  if (a < sizeof(void*)) a = sizeof(void*);
  void* ptr = nullptr;
  ::posix_memalign(&ptr, a, s);
  return ptr;
#else
  return ::aligned_alloc(a, s);
#endif
}
void aligned_free(void* ptr) {
  return ::free(ptr);
}

void SetupAllocatorHooks(mmap_hook_type MMapHook, munmap_hook_type MunmapHook) {}

void InitializeAllocator(size_t PageSize) {}

#endif
} // namespace FEXCore::Allocator
