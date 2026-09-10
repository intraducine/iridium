// SPDX-License-Identifier: MIT
#pragma once

#include <FEXCore/Utils/CompilerDefs.h>
#include <FEXCore/Utils/EnumOperators.h>

#include <cstddef>
#include <cstdint>
#include <sys/types.h>

namespace FEXCore::Allocator {

enum class ProtectOptions : uint32_t {
  None = 0,
  Read = (1U << 0),
  Write = (1U << 1),
  Exec = (1U << 2),
};
FEX_DEF_NUM_OPS(ProtectOptions)

enum class THPControl {
  Enable,
  Disable,
};

#ifndef _WIN32
using MMAP_Hook = void* (*)(void*, size_t, int, int, int, off_t);
using MUNMAP_Hook = int (*)(void*, size_t);
using JITWriteCallback = int (*)(void* Context);

enum class CodeMemoryBackend : uint8_t {
  None = 0,
  SplitRXRWDebugger,
  MapJITFallback,
};

enum class CodeMemoryFailureStage : uint8_t {
  None = 0,
  RequestedAddressUnsupported,
  RWMappingFailed,
  RXMirrorMappingFailed,
  DebuggerPreparationFailed,
  DebugMapRegistrationFailed,
  MapJITFallbackAllocationFailed,
};

enum class CodeMemoryErrorDomain : uint8_t {
  None = 0,
  Errno,
  Mach,
};

struct CodeMemoryOperationStatus {
  CodeMemoryBackend backend {CodeMemoryBackend::None};
  CodeMemoryFailureStage failure_stage {CodeMemoryFailureStage::None};
  CodeMemoryErrorDomain error_domain {CodeMemoryErrorDomain::None};
  int error_code {0};
};

FEX_DEFAULT_VISIBILITY extern MMAP_Hook mmap;
FEX_DEFAULT_VISIBILITY extern MUNMAP_Hook munmap;
#endif

} // namespace FEXCore::Allocator
