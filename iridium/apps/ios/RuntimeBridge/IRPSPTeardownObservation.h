// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef struct IRPSPTeardownObservation IRPSPTeardownObservation;
// Read-only observation failures. A zero-initialized result retains the first failure.
// code is errno for sysctl/allocation, kern_return_t for Mach calls, else zero.
// count is an in/out byte/word/thread count, saturated at 65535; no port or ID.
typedef enum {
    IR_PSP_OBSERVATION_OK = 0,
    IR_PSP_OBSERVATION_TRACE_QUERY, IR_PSP_OBSERVATION_TRACE_SIZE,
    IR_PSP_OBSERVATION_TRACED, IR_PSP_OBSERVATION_ALLOCATION,
    IR_PSP_OBSERVATION_HOST_ROUTES, IR_PSP_OBSERVATION_TASK_ROUTES, // host value retired
    IR_PSP_OBSERVATION_TASK_THREADS, IR_PSP_OBSERVATION_THREAD_COUNT,
    IR_PSP_OBSERVATION_THREAD_IDENTITY, IR_PSP_OBSERVATION_THREAD_IDENTITY_COUNT,
    IR_PSP_OBSERVATION_THREAD_ROUTES,
    IR_PSP_OBSERVATION_WORKER_PORT, IR_PSP_OBSERVATION_WORKER_MISMATCH,
    IR_PSP_OBSERVATION_ROUTE_COUNT, IR_PSP_OBSERVATION_UNKNOWN_ROUTE,
    IR_PSP_OBSERVATION_ROUTING_MISMATCH
} IRPSPObservationFailure;
typedef struct {
    IRPSPObservationFailure failure;
    int32_t code;
    uint32_t count;
} IRPSPObservationDiagnostic;
// Version-2 scope: self task and the same retained preflight thread only.
// Every self query must succeed. Explicit non-null Mach routes are unknown.
// No host-wide or unrelated-thread cleanliness claim. Capture and compare on
// the same live owned worker; keep the snapshot until its work has returned.
// No rights to another task, debugger commands, or exception-port repair.
IRPSPTeardownObservation *ir_psp_teardown_capture(void);
IRPSPTeardownObservation *ir_psp_teardown_capture_diagnostic(IRPSPObservationDiagnostic *);
bool ir_psp_teardown_matches(IRPSPTeardownObservation *);
bool ir_psp_teardown_matches_diagnostic(IRPSPTeardownObservation *, IRPSPObservationDiagnostic *);
void ir_psp_teardown_free(IRPSPTeardownObservation *);
bool ir_psp_self_trace_clear(void);
bool ir_psp_self_trace_clear_diagnostic(IRPSPObservationDiagnostic *);
// Wire version 2: allocation only, four fixed sequence/size pairs; no caller VA.
void *ir_psp_owned_allocate_region(unsigned long bytes, unsigned sequence);
int ir_psp_owned_detach(void);
