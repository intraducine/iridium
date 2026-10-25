// SPDX-License-Identifier: AGPL-3.0-only
#include "IRJITMemory.h"
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// Eight 128 MiB 3DS CPU contexts, plus shader and retained service code.
#define POOL_BYTES (1152u * 1024 * 1024)
#define PAGE_BYTES 16384u
#define PAGE_COUNT (POOL_BYTES / PAGE_BYTES)
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static void *read_view, *write_view;
static uint32_t leases[PAGE_COUNT];
static bool reused[PAGE_COUNT];
static bool preparing;

bool ir_jit_memory_ready(void) {
    pthread_mutex_lock(&mutex);
    bool ready = read_view && write_view;
    pthread_mutex_unlock(&mutex);
    return ready;
}
bool ir_jit_memory_prepare(void *(*prepare)(void *, size_t)) {
    pthread_mutex_lock(&mutex);
    if (read_view && write_view) { pthread_mutex_unlock(&mutex); return true; }
    if (!prepare || preparing || getpagesize() != PAGE_BYTES) { pthread_mutex_unlock(&mutex); return false; }
    preparing = true;
    pthread_mutex_unlock(&mutex);
    // The debugger must not stop the app while its allocator lock is held.
    void *rx = prepare(NULL, POOL_BYTES);
    vm_address_t rw = 0;
    vm_prot_t current = 0, maximum = 0;
    task_vm_info_data_t map = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    bool valid = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&map, &count) == KERN_SUCCESS &&
        rx && rx != MAP_FAILED && !((uintptr_t)rx & (PAGE_BYTES - 1)) &&
        (uintptr_t)rx >= map.min_address && (uintptr_t)rx < map.max_address &&
        POOL_BYTES <= map.max_address - (uintptr_t)rx;
    kern_return_t remapped = valid ? vm_remap(mach_task_self(), &rw, POOL_BYTES, 0, VM_FLAGS_ANYWHERE,
        mach_task_self(), (vm_address_t)rx, false, &current, &maximum, VM_INHERIT_NONE) : KERN_INVALID_ARGUMENT;
    bool mapped = remapped == KERN_SUCCESS;
    kern_return_t protected = mapped ? vm_protect(mach_task_self(), rw, POOL_BYTES, false,
        VM_PROT_READ | VM_PROT_WRITE) : KERN_INVALID_ARGUMENT;
    bool ready = mapped && (void *)rw != rx && protected == KERN_SUCCESS;
    fprintf(stderr, "[JIT memory] rx=%p rw=%p valid=%d remap=%d protect=%d ready=%d\n",
        rx, (void *)rw, valid, remapped, protected, ready);
    if (!ready) {
        if (mapped) vm_deallocate(mach_task_self(), rw, POOL_BYTES);
        if (valid) vm_deallocate(mach_task_self(), (vm_address_t)rx, POOL_BYTES);
    }
    pthread_mutex_lock(&mutex);
    if (ready) { read_view = rx; write_view = (void *)rw; }
    preparing = false;
    pthread_mutex_unlock(&mutex);
    return ready;
}
static bool allocate(size_t bytes, void **rx, void **rw) {
    if (rx) *rx = NULL;
    if (rw) *rw = NULL;
    if (!rx || !rw || !bytes || bytes > POOL_BYTES) return false;
    size_t pages = (bytes + PAGE_BYTES - 1) / PAGE_BYTES;
    pthread_mutex_lock(&mutex);
    if (!read_view || !write_view) { pthread_mutex_unlock(&mutex); return false; }
    size_t run = 0, available = 0, largest = 0;
    for (size_t i = 0; i < PAGE_COUNT; ++i) {
        run = leases[i] ? 0 : run + 1;
        if (!leases[i]) ++available;
        if (run > largest) largest = run;
        if (run != pages) continue;
        size_t start = i + 1 - pages;
        leases[start] = (uint32_t)pages;
        for (size_t j = start + 1; j <= i; ++j) leases[j] = UINT32_MAX;
        *rx = (char *)read_view + start * PAGE_BYTES;
        *rw = (char *)write_view + start * PAGE_BYTES;
        for (size_t j = start; j <= i; ++j) {
            if (reused[j]) memset((char *)write_view + j * PAGE_BYTES, 0, PAGE_BYTES);
            else *((char *)write_view + j * PAGE_BYTES) = 0; // The helper prepares a fresh page with one byte.
            reused[j] = true;
        }
        pthread_mutex_unlock(&mutex);
        return true;
    }
    fprintf(stderr, "[JIT memory] allocation failed bytes=%zu free=%zu largest=%zu\n",
        bytes, available * PAGE_BYTES, largest * PAGE_BYTES);
    pthread_mutex_unlock(&mutex);
    return false;
}
static bool release(void *rx, size_t bytes) {
    pthread_mutex_lock(&mutex);
    uintptr_t offset = (uintptr_t)rx - (uintptr_t)read_view;
    bool valid = read_view && rx && bytes && bytes <= POOL_BYTES && offset < POOL_BYTES && !(offset & (PAGE_BYTES - 1));
    size_t index = offset / PAGE_BYTES, pages = valid ? (bytes + PAGE_BYTES - 1) / PAGE_BYTES : 0;
    valid = valid && index <= PAGE_COUNT - pages && leases[index] == pages;
    if (valid) memset(leases + index, 0, pages * sizeof(*leases));
    pthread_mutex_unlock(&mutex);
    return valid;
}
const IRJITMemoryAPI *ir_jit_memory_api(void) {
    static const IRJITMemoryAPI api = {sizeof(IRJITMemoryAPI), 1, allocate, release};
    return &api;
}
