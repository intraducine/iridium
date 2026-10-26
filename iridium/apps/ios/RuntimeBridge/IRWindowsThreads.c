// SPDX-License-Identifier: AGPL-3.0-only
#include "IRWindowsThreads.h"
#include <mach/mach.h>
#include <pthread.h>
#include <stdint.h>

static uint64_t baseline[1024];
static size_t baseline_count;
static bool captured;
static bool snapshot(uint64_t *ids, size_t *count) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t number = 0;
    if (task_threads(mach_task_self(), &threads, &number) != KERN_SUCCESS) return false;
    bool valid = number <= 1024;
    *count = 0;
    for (mach_msg_type_number_t i = 0; i < number; ++i) {
        thread_identifier_info_data_t info;
        mach_msg_type_number_t size = THREAD_IDENTIFIER_INFO_COUNT;
        kern_return_t result = thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&info, &size);
        if (result == KERN_TERMINATED || result == KERN_INVALID_ARGUMENT) { mach_port_deallocate(mach_task_self(), threads[i]); continue; }
        if (result != KERN_SUCCESS) valid = false;
        else if (valid) ids[(*count)++] = info.thread_id;
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, number * sizeof(*threads));
    return valid;
}
bool ir_windows_threads_begin(void) {
    captured = snapshot(baseline, &baseline_count);
    return captured;
}
bool ir_windows_threads_drained(void) {
    uint64_t current[1024]; size_t count = 0;
    if (!captured || !snapshot(current, &count)) return false;
    uint64_t sampler = 0;
    if (pthread_threadid_np(pthread_self(), &sampler)) return false;
    for (size_t i = 0; i < count; ++i) {
        if (current[i] == sampler) continue;
        bool found = false;
        for (size_t j = 0; j < baseline_count; ++j) if (current[i] == baseline[j]) { found = true; break; }
        if (!found) return false;
    }
    return true;
}
