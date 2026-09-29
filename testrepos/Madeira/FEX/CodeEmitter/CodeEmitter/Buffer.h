// SPDX-License-Identifier: MIT
#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>

namespace ARMEmitter {
class Buffer {
public:
  Buffer() {
    SetBuffer(nullptr, 0);
  }

  Buffer(uint8_t* Base, uint64_t BaseSize) {
    SetBuffer(Base, BaseSize);
  }

  void SetBuffer(uint8_t* Base, uint64_t BaseSize) {
    BufferBase = Base;
    CurrentOffset = BufferBase;
    Size = BaseSize;
  }

#if defined(__APPLE__) || defined(FEX_IOS_HOST)
  // iOS dual-mapping support: BufferBase/CurrentOffset are RX (executable) addresses.
  // Actual writes go to (address + WriteOffset) which points to the RW mirror.
  // On non-Apple platforms this is always 0 and optimizes away.
  //
  // FEX_IOS_HOST: enables the same machinery for the ARM64EC PE build
  // (xtajit64.dll) running on iOS. The PE targets Windows so __APPLE__
  // is undefined, but the JIT pool it writes to is still iOS-allocated
  // dual-mapped memory and the per-Buffer offset semantics are identical.
  void SetWriteOffset(int64_t Offset) { WriteOffset = Offset; }
  int64_t GetWriteOffset() const { return WriteOffset; }
#else
  void SetWriteOffset(int64_t) {}
  static constexpr int64_t GetWriteOffset() { return 0; }
#endif

  template<typename T>
  requires (std::is_trivially_copyable_v<T>)
  void dcn(const T& Data) {
    std::memcpy(WritePtr(CurrentOffset), &Data, sizeof(Data));
    CurrentOffset += sizeof(Data);
  }
  void dc8(uint8_t Data) {
    dcn(Data);
  }
  void dc16(uint16_t Data) {
    dcn(Data);
  }
  void dc32(uint32_t Data) {
    dcn(Data);
  }
  void dc64(uint64_t Data) {
    dcn(Data);
  }

  void EmitString(const char* String) {
    const auto StringLength = strlen(String);
    memcpy(WritePtr(CurrentOffset), String, StringLength);
    CurrentOffset += StringLength;
  }

  void Align(size_t Size = 4) {
    // Align the buffer to provided size.
    auto CurrentAlignment = reinterpret_cast<uint64_t>(CurrentOffset) & (Size - 1);
    if (!CurrentAlignment) {
      return;
    }
    std::memset(WritePtr(CurrentOffset), 0, Size - CurrentAlignment);
    CurrentOffset += Size - CurrentAlignment;
  }

  template<typename T>
  T GetCursorAddress() const {
    return reinterpret_cast<T>(CurrentOffset);
  }

  static void ClearICache(void* Begin, std::size_t Length) {
    __builtin___clear_cache(static_cast<char*>(Begin), static_cast<char*>(Begin) + Length);
  }

  size_t GetCursorOffset() const {
    return static_cast<size_t>(CurrentOffset - BufferBase);
  }

  uint8_t* GetBufferBase() const {
    return BufferBase;
  }

  void CursorIncrement(size_t Size) {
    CurrentOffset += Size;
  }

  void SetCursorOffset(size_t Offset) {
    CurrentOffset = BufferBase + Offset;
  }

  uint64_t GetBufferSize() const {
    return Size;
  }

  template<typename T>
  size_t GetCursorOffsetFromAddress(const T* Address) const {
    return static_cast<size_t>(reinterpret_cast<const uint8_t*>(Address) - BufferBase);
  }

protected:
  // Convert an RX (executable) address to the RW (writable) address for memory writes.
  // On non-Apple platforms, WriteOffset is 0 and this is identity.
  //
  // iOS-Madeira 2026-05-19: ARM64EC PE builds (xtajit64.dll) target Windows
  // so __APPLE__ is undefined, but they still need the dual-map offset
  // because the JIT pool they write to is iOS-allocated dual-mapped memory.
  // FEX_IOS_HOST is defined for those PE builds and switches in a global
  // WriteOffset that Module.cpp::ProcessInit sets at module init.
  uint8_t* WritePtr(uint8_t* RXAddr) const {
#if defined(__APPLE__) || defined(FEX_IOS_HOST)
    return RXAddr + WriteOffset;
#else
    return RXAddr;
#endif
  }

  uint8_t* BufferBase;
  uint8_t* CurrentOffset;
  uint64_t Size;
#if defined(__APPLE__) || defined(FEX_IOS_HOST)
  int64_t WriteOffset = 0;
#endif
};
} // namespace ARMEmitter
