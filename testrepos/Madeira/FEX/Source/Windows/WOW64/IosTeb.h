// SPDX-License-Identifier: MIT
#pragma once

// MADEIRA: the one way this module is allowed to obtain a TEB pointer.
//
// NtCurrentTeb() compiles to a read of x18. On iOS x18 is not ours: the kernel wipes it on return
// to EL0 and libobjc/mach/pthread scribble on it, so any read after one of those calls returns
// garbage - typically 0 on cold-start paths, which then turns every TLS-slot access in this module
// into a null dereference. TPIDRRO_EL0 *is* preserved across context switches, and Wine's
// ntdll-unix stashes the TEB in a pthread TSD slot, so the TEB is read from there instead.
//
// Shared between Module.cpp and IosMonoBridge.cpp rather than duplicated: the TSD offset is
// discovered at process init and there must be exactly one copy of it, or one translation unit ends
// up reading slot 0 (which belongs to libpthread) while the other reads the right one.

#include <cstdint>
#include <winternl.h>

namespace FEX::Windows::WOW64 {
#ifdef FEX_IOS_HOST
// Raw TSD slot offset for the TEB, published by Wine's ntdll as the data export
// `ios_teb_tsd_offset` and imported in BTCpuProcessInit. Defined in Module.cpp.
//
// It is NOT a compile-time constant: it is whichever slot backs the pthread key ntdll-unix created,
// which varies by device and by load order. Zero means "not imported yet", and reading against zero
// is a bug rather than a fallback - BTCpuProcessInit refuses to continue in that case.
extern uint32_t IosTebTsdOffset;

inline _TEB* IOSLoadTEB() {
  uintptr_t tpidrro;
  __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tpidrro));
  tpidrro &= ~uintptr_t(7);
  _TEB* via_tsd = IosTebTsdOffset ? *reinterpret_cast<_TEB**>(tpidrro + IosTebTsdOffset) : nullptr;
  if (via_tsd) {
    return via_tsd;
  }
  // The slot is not always populated by the time a freshly bootstrapped Wine worker thread gets
  // here. Falling back to x18 is better than returning nullptr: it is correct whenever x18 has not
  // been clobbered yet on this thread's setup path, and every caller would otherwise read TLS slots
  // off a null pointer.
  return NtCurrentTeb();
}
#endif

// Every TEB read in this module goes through here. On an iOS host that avoids x18; everywhere else
// it is exactly NtCurrentTeb().
inline _TEB* CurrentTEB() {
#ifdef FEX_IOS_HOST
  return IOSLoadTEB();
#else
  return NtCurrentTeb();
#endif
}
} // namespace FEX::Windows::WOW64
