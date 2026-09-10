// SPDX-License-Identifier: MIT
// iOS-Madeira ml648 — FEX's copy of the Mono-bridge contract.
//
// ⚠️ THIS MUST STAY BYTE-IDENTICAL TO build/ntdll-unix/ios_mono_bridge.h.
// The two live in different build systems (llvm-mingw arm64ec PE here, native
// clang there) so there is no shared include path and no compile-time check is
// possible. `abi_version` is the runtime guard: FEX refuses to arm the bridge
// if it does not match, which turns a silent layout drift — the worst possible
// failure for a struct read inside a fault handler — into one loud line.
//
// See the unix-side header for WHY this table is separate from IosAliasEntries.
// Short version: Module.S's ios_ffs_xlate_loop rewrites control-flow targets
// through that one, so a guest-RX -> RW pair in it would send calls into the
// non-executable mapping.

#pragma once
#include <cstdint>

#define IOS_MONO_ABI_VERSION 2
#define IOS_MONO_MAX_ALIASES 4096
#define IOS_MONO_MAX_CONTEXTS 64

struct ios_mono_alias {
  uint64_t guest_rx;
  uint64_t host_rw;
  uint64_t size;
  uint32_t generation;  // odd = live, even = retired
  uint32_t _pad;
};

struct ios_mono_pending {
  uint64_t context;      // PEB, 0 = slot free
  uint64_t block_begin;  // CpuStateFrame+0, the InlineJITBlockHeader
  uint64_t host_pc;
  uint64_t fault_addr;
  uint32_t state;  // 0 empty, 1 published, 2 consumed (one-shot)
  uint32_t _pad;
};

struct ios_mono_bridge {
  uint32_t abi_version;
  uint32_t diag_enabled;  // ml649: runtime diagnostic switch
  uint32_t off_inline_jit_block_header;
  uint32_t off_block_tail;
  uint32_t off_tail_rip;

  uint64_t mono_base;
  uint64_t mono_end;
  uint64_t code_lo;
  uint64_t code_hi;

  ios_mono_pending pending[IOS_MONO_MAX_CONTEXTS];

  uint32_t alias_count;
  ios_mono_alias aliases[IOS_MONO_MAX_ALIASES];

  uint64_t n_captured;
  uint64_t n_activated;
  uint64_t n_helper_calls;
  uint64_t n_alias_miss;
  uint64_t n_residual_swp;
  uint64_t n_reject_unarmed;
  uint64_t n_reject_no_frame;
  uint64_t n_reject_bad_block;
  uint64_t n_reject_outside_code;
};
