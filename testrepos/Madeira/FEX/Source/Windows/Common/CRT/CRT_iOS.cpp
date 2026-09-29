// SPDX-License-Identifier: MIT
// Minimal CRT lifecycle hooks for the iOS-host arm64ec build of libarm64ecfex.dll.
// The full CRT.cpp redefines _tls_index, DllMainCRTStartup, and the CRT section
// markers, which conflict with mingw's default startup chain that we use on
// iOS-host builds (llvm-mingw 22.1.4's arm64ec EC-mangling doesn't reconcile
// cleanly with -nostdlib + custom CRT). So we let mingw's default
// DllMainCRTStartup run the C++ constructors / TLS callbacks for us.
//
// BUT the FEX rpmalloc allocator still needs its explicit init. ENABLE_FEX_ALLOCATOR
// is TRUE on this MinGW EC build (CMake: MinGW => TRUE; the _WIN32 branch of
// AllocatorHooks.cpp is a hard #error "without jemalloc"), so every fextl/FEXAlloc
// allocation goes through rpmalloc. On the non-iOS path that init lives in
// CRT.cpp's InitCRTProcess (rpmalloc_initialize) and InitCRTThread
// (rpmalloc_thread_initialize). Making those no-ops here left rpmalloc's
// PER-THREAD heap uninitialized on FEX worker threads: such a thread would
// allocate from a garbage thread-local heap and hand back a corrupt/truncated
// pointer. Observed failure: the shared GuestToHostMap bucket array got a
// garbage base (0xcf069bfd), so LookupCache::FindBlock -> ankerl do_find scanned
// off the end into unmapped guest memory -> undispatchable fault -> terminate.
// Restore the rpmalloc init here (mirroring CRT.cpp) while still delegating
// ctors/TLS to mingw.
#include <rpmalloc/rpmalloc.h>

namespace FEX::Windows {
void InitCRTProcess() {
  // mingw's default startup already ran the C++ ctors. Ensure the rpmalloc
  // global heap is up (idempotent) before any per-thread init below.
  rpmalloc_initialize(nullptr);
}
void InitCRTThread() {
  // The critical piece that was missing on iOS: give this thread its own
  // rpmalloc heap. Without it, FEX worker-thread allocations are corrupt.
  rpmalloc_thread_initialize();
}
void DeinitCRTThread() {
  rpmalloc_thread_finalize();
}
} // namespace FEX::Windows
