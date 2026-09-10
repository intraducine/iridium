// SPDX-License-Identifier: MIT
#pragma once
#include <cstdint>

namespace FEXCore::DualMap {

#if defined(__APPLE__) || defined(FEX_IOS_HOST)
// Global write offset for iOS dual-mapped JIT memory.
// RX (executable) addresses are canonical. To write to JIT memory,
// add this offset to convert RX→RW.
// Set by the host application before FEXCore initialization.
//
// FEX_IOS_HOST: also enabled for the ARM64EC PE (xtajit64.dll) build —
// that PE has its own statically-linked copy of FEXCore separate from
// the iOS app's libFEXCore_Base.a. Its WriteOffset definition lives in
// Source/Windows/ARM64EC/Module.cpp and is set early in ProcessInit
// (before InitCore, so dispatcher emit picks it up).
extern int64_t WriteOffset;

inline void* WriteAddr(void* RXAddr) {
  return reinterpret_cast<uint8_t*>(RXAddr) + WriteOffset;
}

template<typename T>
inline T* WriteAddr(T* RXAddr) {
  return reinterpret_cast<T*>(reinterpret_cast<uint8_t*>(RXAddr) + WriteOffset);
}
#else
static constexpr int64_t WriteOffset = 0;

inline void* WriteAddr(void* Addr) { return Addr; }

template<typename T>
inline T* WriteAddr(T* Addr) { return Addr; }
#endif

} // namespace FEXCore::DualMap
