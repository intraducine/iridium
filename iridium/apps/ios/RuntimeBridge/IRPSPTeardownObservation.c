// SPDX-License-Identifier: AGPL-3.0-only
#include "IRPSPTeardownObservation.h"
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <TargetConditionals.h>
#include <errno.h>

typedef struct {
    mach_msg_type_number_t count;
    exception_mask_t masks[EXC_TYPES_COUNT];
    mach_port_t ports[EXC_TYPES_COUNT];
    exception_behavior_t behavior[EXC_TYPES_COUNT];
    thread_state_flavor_t flavor[EXC_TYPES_COUNT];
} Routes;
struct IRPSPTeardownObservation {
    Routes task, thread;
    thread_t worker;
    uint64_t identity;
};
static void release_routes(Routes *r) {
    for (unsigned i = 0; i < r->count; ++i) if (MACH_PORT_VALID(r->ports[i])) mach_port_deallocate(mach_task_self(), r->ports[i]);
    r->count = 0;
}
void ir_psp_teardown_free(IRPSPTeardownObservation *value) {
    if (!value) return;
    release_routes(&value->task); release_routes(&value->thread);
    if (MACH_PORT_VALID(value->worker)) mach_port_deallocate(mach_task_self(), value->worker);
    free(value);
}
static void observation_failed(IRPSPObservationDiagnostic *result,
    IRPSPObservationFailure failure, int32_t code, size_t count) {
    if (result && result->failure == IR_PSP_OBSERVATION_OK) {
        result->failure = failure; result->code = code;
        result->count = count > 65535 ? 65535 : (uint32_t)count;
    }
}
bool ir_psp_self_trace_clear_diagnostic(IRPSPObservationDiagnostic *result) {
    int names[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info; memset(&info, 0, sizeof info); size_t size = sizeof info;
    if (sysctl(names, 4, &info, &size, NULL, 0) != 0) {
        observation_failed(result, IR_PSP_OBSERVATION_TRACE_QUERY, errno, size); return false;
    }
    if (size != sizeof info) {
        observation_failed(result, IR_PSP_OBSERVATION_TRACE_SIZE, 0, size); return false;
    }
    if (info.kp_proc.p_flag & P_TRACED) {
        observation_failed(result, IR_PSP_OBSERVATION_TRACED, 0, 0); return false;
    }
    return true;
}
bool ir_psp_self_trace_clear(void) { return ir_psp_self_trace_clear_diagnostic(NULL); }
static bool readable_routes(Routes *r, kern_return_t status, IRPSPObservationFailure kind,
    IRPSPObservationDiagnostic *result) {
    if (status != KERN_SUCCESS) {
        observation_failed(result, kind, status, r->count); r->count = 0; return false;
    }
    if (r->count > EXC_TYPES_COUNT) {
        observation_failed(result, IR_PSP_OBSERVATION_ROUTE_COUNT, 0, r->count);
        r->count = EXC_TYPES_COUNT; return false;
    }
    exception_mask_t seen = 0;
    for (unsigned i = 0; i < r->count; ++i) {
        if (!r->masks[i] || (r->masks[i] & ~EXC_MASK_ALL) || (seen & r->masks[i])) {
            observation_failed(result, IR_PSP_OBSERVATION_ROUTE_COUNT, 0, r->count); return false;
        }
        seen |= r->masks[i];
        // PSP preflight installs no Mach handlers. A non-null explicit route has
        // no app-owned provenance here; equality alone cannot authorize it.
        if (r->ports[i] != MACH_PORT_NULL) {
            observation_failed(result, IR_PSP_OBSERVATION_UNKNOWN_ROUTE, 0, r->count); return false;
        }
    }
    return true;
}
IRPSPTeardownObservation *ir_psp_teardown_capture_diagnostic(IRPSPObservationDiagnostic *result) {
    if (!ir_psp_self_trace_clear_diagnostic(result)) return NULL;
    IRPSPTeardownObservation *v = calloc(1, sizeof(*v));
    if (!v) { observation_failed(result, IR_PSP_OBSERVATION_ALLOCATION, errno, 0); return NULL; }
    v->worker = mach_thread_self();
    if (!MACH_PORT_VALID(v->worker)) {
        observation_failed(result, IR_PSP_OBSERVATION_WORKER_PORT, 0, 0); goto failed;
    }
    thread_identifier_info_data_t identity; mach_msg_type_number_t size = THREAD_IDENTIFIER_INFO_COUNT;
    kern_return_t status = thread_info(v->worker, THREAD_IDENTIFIER_INFO, (thread_info_t)&identity, &size);
    if (status != KERN_SUCCESS || size != THREAD_IDENTIFIER_INFO_COUNT || !identity.thread_id) {
        observation_failed(result, status != KERN_SUCCESS ? IR_PSP_OBSERVATION_THREAD_IDENTITY :
            IR_PSP_OBSERVATION_THREAD_IDENTITY_COUNT, status, size); goto failed;
    }
    v->identity = identity.thread_id;
    v->task.count = EXC_TYPES_COUNT;
    status = task_get_exception_ports(mach_task_self(), EXC_MASK_ALL, v->task.masks, &v->task.count,
        v->task.ports, v->task.behavior, v->task.flavor);
    if (!readable_routes(&v->task, status, IR_PSP_OBSERVATION_TASK_ROUTES, result)) goto failed;
    v->thread.count = EXC_TYPES_COUNT;
    status = thread_get_exception_ports(v->worker, EXC_MASK_ALL, v->thread.masks, &v->thread.count,
        v->thread.ports, v->thread.behavior, v->thread.flavor);
    if (!readable_routes(&v->thread, status, IR_PSP_OBSERVATION_THREAD_ROUTES, result)) goto failed;
    return v;
failed:
    ir_psp_teardown_free(v); return NULL;
}
IRPSPTeardownObservation *ir_psp_teardown_capture(void) { return ir_psp_teardown_capture_diagnostic(NULL); }
static bool equal_routes(const Routes *a, const Routes *b) {
    for (unsigned bit = 0; bit < EXC_TYPES_COUNT; ++bit) {
        exception_mask_t mask = (exception_mask_t)1u << bit;
        int ai = -1, bi = -1;
        for (unsigned n = 0; n < a->count; ++n) if (a->masks[n] & mask) ai = (int)n;
        for (unsigned n = 0; n < b->count; ++n) if (b->masks[n] & mask) bi = (int)n;
        if (ai < 0 || bi < 0) { if (ai != bi) return false; continue; }
        if (a->ports[ai] != b->ports[bi] || a->behavior[ai] != b->behavior[bi] || a->flavor[ai] != b->flavor[bi]) return false;
    }
    return true;
}
bool ir_psp_teardown_matches_diagnostic(IRPSPTeardownObservation *before, IRPSPObservationDiagnostic *result) {
    if (!before) { observation_failed(result, IR_PSP_OBSERVATION_WORKER_MISMATCH, 0, 0); return false; }
    IRPSPTeardownObservation *after = ir_psp_teardown_capture_diagnostic(result); if (!after) return false;
    bool same_worker = before->worker == after->worker && before->identity == after->identity;
    bool match = same_worker && equal_routes(&before->task, &after->task) && equal_routes(&before->thread, &after->thread);
    if (!match) observation_failed(result, same_worker ? IR_PSP_OBSERVATION_ROUTING_MISMATCH :
        IR_PSP_OBSERVATION_WORKER_MISMATCH, 0, 0);
    ir_psp_teardown_free(after); return match;
}
bool ir_psp_teardown_matches(IRPSPTeardownObservation *before) { return ir_psp_teardown_matches_diagnostic(before, NULL); }
__attribute__((noinline,optnone)) void *ir_psp_owned_allocate_region(unsigned long bytes, unsigned sequence) {
#if defined(__aarch64__) && !TARGET_OS_SIMULATOR
    register void *x0 __asm__("x0") = NULL;
    register unsigned long x1 __asm__("x1") = bytes;
    register unsigned long x2 __asm__("x2") = 2;
    register unsigned long x3 __asm__("x3") = sequence;
    __asm__ volatile("mov x16, #1\n brk #0xf00d" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3) : "x16", "memory");
    return x0;
#else
    (void)bytes; (void)sequence; return NULL;
#endif
}
__attribute__((noinline,optnone)) int ir_psp_owned_detach(void) {
#if defined(__aarch64__) && !TARGET_OS_SIMULATOR
    register unsigned long x0 __asm__("x0") = 0, x1 __asm__("x1") = 0;
    register unsigned long x2 __asm__("x2") = 2, x3 __asm__("x3") = 0;
    __asm__ volatile("mov x16, #0\n brk #0xf00d" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3) : "x16", "memory");
    return 0; // Target return only; D ACK and original helper response are separate.
#else
    return -1;
#endif
}
