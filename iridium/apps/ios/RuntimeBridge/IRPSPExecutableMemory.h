// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "IRJITDiagnostic.h"
#include "IRJITMemory.h"

#ifdef __cplusplus
extern "C" {
#endif
#pragma GCC visibility push(default)

// Version 3 obtains owned helper-allocated RX before creating RW aliases.
// Retains version-2 self-task/retained-worker teardown proof; no host-wide claim.
enum { IR_PSP_EXEC_VERSION = 3 };
enum IRPSPExecRole { IR_PSP_EXEC_CPU = 1, IR_PSP_EXEC_VERTEX, IR_PSP_EXEC_PIXEL, IR_PSP_EXEC_SAMPLER };
enum IRPSPExecResult {
    IR_PSP_EXEC_OK = 0, IR_PSP_EXEC_UNAVAILABLE, IR_PSP_EXEC_IDENTITY,
    IR_PSP_EXEC_RANGE, IR_PSP_EXEC_MAPPING, IR_PSP_EXEC_PREPARATION,
    IR_PSP_EXEC_UNCERTAIN, IR_PSP_EXEC_CLOSING, IR_PSP_EXEC_EMISSION,
    IR_PSP_EXEC_METADATA_LIMIT, IR_PSP_EXEC_SHUTDOWN, IR_PSP_EXEC_RESTORATION
};
typedef uint64_t IRPSPExecClaim; // Monotonic opaque identity, never a dereferenced address.
typedef struct {
    uint32_t size, version;
    uint64_t admission, generation;
    uint64_t attempt;
    uint8_t script_sha256[32];
    void *context; // Retained by caller until end returns OK; never replaced live.
    // On OK, or definitive PREPARATION failure after allocation, transfers the
    // correlated RX allocation for cleanup through owned_rx. Other failures
    // leave it null: unknown remote outcomes require restart, never guessed frees.
    int (*prepare)(void *, void **owned_rx, size_t bytes, unsigned sequence);
    int (*detach)(void *); // Existing owned BRK; may block without a hard timeout.
} IRPSPExecHost;

enum {
    IR_PSP_SHUTDOWN_CALL_RETURNED = 1u << 0,
    IR_PSP_SHUTDOWN_D_ACK = 1u << 1,
    IR_PSP_SHUTDOWN_SDK_DRAINED = 1u << 2,
    IR_PSP_SHUTDOWN_REPLY_MATCHED = 1u << 3,
    IR_PSP_SHUTDOWN_TRACE_CLEAR = 1u << 4,
    IR_PSP_SHUTDOWN_SCOPED_ROUTES_MATCH = 1u << 5,
    IR_PSP_SHUTDOWN_ALL = 63
};
typedef struct {
    uint32_t size, version, flags;
    uint64_t admission, generation, attempt;
    uint8_t script_sha256[32];
} IRPSPExecShutdown;

// Additive, separately negotiated API; never infer these services from ABI 3.
uint32_t ir_native_psp_exec_version(void);
// Shared-memory extension 1. The app returns only after its helper has closed.
int ir_native_psp_exec_prepare_shared(uint64_t admission, const IRJITMemoryAPI *, const IRJITDiagnosticSink *);
int ir_native_psp_exec_prepare(const IRPSPExecHost *);
int ir_native_psp_exec_prepare_diagnostic(const IRPSPExecHost *, const IRJITDiagnosticSink *);
int ir_native_psp_exec_detach(uint64_t admission);
int ir_native_psp_exec_accept_shutdown(const IRPSPExecShutdown *);
int ir_native_psp_exec_restored(uint64_t admission, bool success);
int ir_native_psp_exec_restored_diagnostic(uint64_t admission, bool success, const IRJITDiagnosticSink *);
int ir_native_psp_exec_advance(uint64_t admission, uint64_t previous, uint64_t next);
void ir_native_psp_exec_cancel(uint64_t admission);
int ir_native_psp_exec_end(uint64_t admission);
#pragma GCC visibility pop

// Internal engine boundary: no unregistered executable allocation or growth.
IRPSPExecClaim ir_psp_exec_claim(unsigned role, size_t bytes, void **rx, void **rw);
bool ir_psp_exec_release(IRPSPExecClaim );
bool ir_psp_exec_translate(const void *pointer, size_t bytes, bool to_rw, void **result);
bool ir_psp_exec_begin_write(IRPSPExecClaim, const void *rx, size_t bytes);
IRPSPExecClaim ir_psp_exec_begin_patch(const void *pointer, size_t bytes);
bool ir_psp_exec_end_write(IRPSPExecClaim , const void *rx, size_t bytes);
bool ir_psp_exec_write32(const void *rx, void *rw, uint32_t value);
bool ir_psp_exec_validate(const void *pointer, size_t bytes, bool writable);
bool ir_psp_exec_publish(const void *rx, size_t bytes);
void ir_psp_exec_probe_proven(bool);
uint64_t ir_psp_exec_generation(void);
uint64_t ir_psp_exec_admission(void);
bool ir_psp_exec_native_ready(void);
bool ir_psp_exec_shared_memory(void);
int ir_psp_exec_reuse_native(uint64_t admission);
bool ir_psp_exec_failed(void);
void ir_psp_exec_fail(void);
IRPSPExecClaim ir_psp_exec_enter(const void *rx);
IRPSPExecClaim ir_psp_exec_enter_role(unsigned role);
void ir_psp_exec_leave(IRPSPExecClaim );

#ifdef __cplusplus
}
class IRPSPExecReadScope {
    IRPSPExecClaim claim_;
public:
    explicit IRPSPExecReadScope(const void *rx) : claim_(ir_psp_exec_enter(rx)) {}
    explicit IRPSPExecReadScope(unsigned role) : claim_(ir_psp_exec_enter_role(role)) {}
    IRPSPExecReadScope(const IRPSPExecReadScope &) = delete;
    IRPSPExecReadScope &operator=(const IRPSPExecReadScope &) = delete;
    ~IRPSPExecReadScope() { if (claim_) ir_psp_exec_leave(claim_); }
    explicit operator bool() const { return claim_ != 0; }
};
class IRPSPExecPatchScope {
    IRPSPExecClaim claim_;
    const void *rx_ = nullptr;
    size_t bytes_;
public:
    IRPSPExecPatchScope(const void *pointer, size_t bytes)
        : claim_(ir_psp_exec_begin_patch(pointer, bytes)), bytes_(bytes) {
        void *translated = nullptr;
        if (claim_) rx_ = ir_psp_exec_translate(pointer, bytes, false, &translated) ? translated : pointer;
    }
    IRPSPExecPatchScope(const IRPSPExecPatchScope &) = delete;
    IRPSPExecPatchScope &operator=(const IRPSPExecPatchScope &) = delete;
    ~IRPSPExecPatchScope() { if (claim_ && !ir_psp_exec_end_write(claim_, rx_, bytes_)) ir_psp_exec_fail(); }
    explicit operator bool() const { return claim_ != 0; }
};
#endif
