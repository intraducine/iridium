// SPDX-License-Identifier: AGPL-3.0-only
#include "IRJITMemory.h"
#include "IRJITPrepare.h"
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// Eight 128 MiB 3DS CPU contexts, plus shader and retained service code.
#define POOL_BYTES (1152u * 1024 * 1024)
#define PAGE_BYTES 16384u
#define CONSOLE_SERVICE_BYTES (16u * 1024 * 1024)
// Madeira can add a fourth region outside its main address span.
#define MAX_WINDOWS_REGIONS 4
#define ARENA_BYTES (POOL_BYTES * 2u)
#define PAGE_COUNT (ARENA_BYTES / PAGE_BYTES)
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static void *read_view, *write_view;
static size_t prepared_bytes, verified_bytes;
static IRJITWindowsRegion windows_regions[MAX_WINDOWS_REGIONS];
static size_t windows_count, windows_bytes;
enum { WINDOWS_FREE, WINDOWS_IMAGE, WINDOWS_CODE };
static uint8_t windows_pages[PAGE_COUNT];
static uint32_t leases[PAGE_COUNT];
static bool reused[PAGE_COUNT];
static bool preparing;
static _Atomic(void (*)(void)) windows_reclaimer;

void ir_jit_memory_set_windows_reclaimer(void (*reclaim)(void)) {
    atomic_store(&windows_reclaimer, reclaim);
}

// Each stop is bounded. The app runs between chunks, including its main run loop.
static void *prepare_request(void *address, size_t bytes, unsigned command) {
#if defined(__aarch64__)
    register void *x0 __asm__("x0") = address;
    register size_t x1 __asm__("x1") = bytes;
    register unsigned long x16 __asm__("x16") = command;
    __asm__ volatile("brk #0xf00d" : "+r"(x0) : "r"(x1), "r"(x16) : "memory");
    return x0;
#else
    return NULL;
#endif
}
void *ir_jit_prepare_region(void *address, size_t bytes) {
    const size_t chunk = 2 * 1024 * 1024;
    if (!bytes || bytes > POOL_BYTES || bytes % PAGE_BYTES) return NULL;
    bool allocated = !address;
    if (allocated) address = prepare_request(NULL, bytes, 4);
    if (!address || address == MAP_FAILED || (uintptr_t)address % PAGE_BYTES || bytes > UINTPTR_MAX - (uintptr_t)address) return NULL;
    for (size_t offset = 0; offset < bytes; offset += chunk) {
        void *part = (char *)address + offset;
        size_t length = bytes - offset < chunk ? bytes - offset : chunk;
        if (prepare_request(part, length, 1) != part) {
            if (allocated) munmap(address, bytes);
            return NULL;
        }
        // Let resumed UI work run before the next debugger stop.
        if (offset + length < bytes) usleep(4000);
    }
    return address;
}

bool ir_jit_memory_ready(void) {
    pthread_mutex_lock(&mutex);
    bool ready = read_view && write_view;
    pthread_mutex_unlock(&mutex);
    return ready;
}
bool ir_jit_memory_has_capacity(size_t bytes) {
    pthread_mutex_lock(&mutex);
    bool ready = prepared_bytes >= (bytes ? bytes : POOL_BYTES);
    pthread_mutex_unlock(&mutex);
    return ready;
}
bool ir_jit_memory_prepare(void *(*prepare)(void *, size_t)) {
    return ir_jit_memory_prepare_sized(prepare, 0);
}
static bool reserve_view(vm_address_t *address, size_t bytes) {
    // Keep the mirrors away from Wine's low PE address space when possible.
    void *reserved = mmap((void *)(uintptr_t)(1ULL << 36), bytes, PROT_NONE,
                          MAP_PRIVATE | MAP_ANON, -1, 0);
    if (reserved == MAP_FAILED) return false;
    *address = (vm_address_t)reserved;
    return true;
}

static bool alias(void *source, vm_address_t target, size_t bytes, vm_prot_t protection) {
    vm_prot_t current = 0, maximum = 0;
    vm_address_t requested = target;
    return vm_remap(mach_task_self(), &target, bytes, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                    mach_task_self(), (vm_address_t)source, false, &current, &maximum,
                    VM_INHERIT_NONE) == KERN_SUCCESS && target == requested &&
           vm_protect(mach_task_self(), target, bytes, false, protection) == KERN_SUCCESS;
}

bool ir_jit_memory_register_windows(const IRJITWindowsRegion *regions, size_t count) {
    if (!regions || !count || count > MAX_WINDOWS_REGIONS) return false;
    size_t total = 0;
    for (size_t i = 0; i < count; ++i) {
        const IRJITWindowsRegion *r = regions + i;
        if (!r->rx || !r->rw || r->rx == r->rw || !r->bytes || r->bytes > ARENA_BYTES - CONSOLE_SERVICE_BYTES - total ||
            (((uintptr_t)r->rx | (uintptr_t)r->rw | r->bytes) & (PAGE_BYTES - 1))) return false;
        total += r->bytes;
    }
    pthread_mutex_lock(&mutex);
    bool ready = windows_count == count && windows_bytes == total;
    if (ready) {
        for (size_t i = 0; i < count; ++i)
            ready = ready && windows_regions[i].rx == regions[i].rx &&
                windows_regions[i].rw == regions[i].rw && windows_regions[i].bytes == regions[i].bytes &&
                windows_regions[i].bootstrap == regions[i].bootstrap;
    } else if (!windows_count && !prepared_bytes && !preparing) {
        memcpy(windows_regions, regions, count * sizeof(*regions));
        windows_count = count;
        windows_bytes = total;
        size_t page = 0;
        for (size_t i = 0; i < count; ++i) {
            if (regions[i].bootstrap) windows_pages[page] = WINDOWS_IMAGE;
            page += regions[i].bytes / PAGE_BYTES;
        }
        ready = true;
    }
    pthread_mutex_unlock(&mutex);
    return ready;
}

// Called with mutex held. Windows addresses need not be adjacent in the app.
static size_t windows_page_index(void *rx, size_t bytes) {
    if (!rx || !bytes || (((uintptr_t)rx | bytes) & (PAGE_BYTES - 1)) || prepared_bytes < windows_bytes)
        return PAGE_COUNT;
    size_t first = 0;
    for (size_t i = 0; i < windows_count; ++i) {
        size_t offset = (uintptr_t)rx - (uintptr_t)windows_regions[i].rx;
        size_t length = windows_regions[i].bytes;
        if (offset < length && bytes <= length - offset) return first + offset / PAGE_BYTES;
        first += length / PAGE_BYTES;
    }
    return PAGE_COUNT;
}

bool ir_jit_windows_claim(void *rx, size_t bytes, bool code) {
    pthread_mutex_lock(&mutex);
    size_t first = windows_page_index(rx, bytes);
    bool available = first < PAGE_COUNT && verified_bytes >= windows_bytes;
    size_t end = first + (available ? bytes / PAGE_BYTES : 0);
    for (size_t j = first; available && j < end; ++j) available = !leases[j];
    if (available) {
        for (size_t j = first; j < end; ++j) {
            if (windows_pages[j] != WINDOWS_IMAGE) windows_pages[j] = code ? WINDOWS_CODE : WINDOWS_IMAGE;
            reused[j] = true;
        }
    }
    pthread_mutex_unlock(&mutex);
    return available;
}

void ir_jit_windows_release_code(void *rx, size_t bytes) {
    pthread_mutex_lock(&mutex);
    size_t first = windows_page_index(rx, bytes);
    if (first < PAGE_COUNT) {
        size_t end = first + bytes / PAGE_BYTES;
        for (size_t j = first; j < end; ++j) {
            if (windows_pages[j] == WINDOWS_CODE) windows_pages[j] = WINDOWS_FREE;
        }
    }
    pthread_mutex_unlock(&mutex);
}

bool ir_jit_memory_intersects(const void *address, size_t bytes) {
    uintptr_t start = (uintptr_t)address;
    if (!bytes || bytes > UINTPTR_MAX - start) return false;
    pthread_mutex_lock(&mutex);
    uintptr_t rx = (uintptr_t)read_view, rw = (uintptr_t)write_view;
    size_t length = windows_bytes + CONSOLE_SERVICE_BYTES;
    if (length < POOL_BYTES) length = POOL_BYTES;
    bool overlaps = rx && ((start < rx + length && start + bytes > rx) ||
                           (start < rw + length && start + bytes > rw));
    pthread_mutex_unlock(&mutex);
    return overlaps;
}

bool ir_jit_memory_prepare_sized(void *(*prepare)(void *, size_t), size_t bytes) {
    if (!bytes) bytes = POOL_BYTES;
    if (bytes > ARENA_BYTES || bytes % PAGE_BYTES) return false;
    pthread_mutex_lock(&mutex);
    // Console signal relays can outlive a game. Keep room outside Wine's address
    // span for those allocations even if the Windows layout uses the full budget.
    size_t minimum = windows_bytes ? windows_bytes + CONSOLE_SERVICE_BYTES : 0;
    if (bytes < minimum) bytes = minimum;
    if (prepared_bytes >= bytes) { pthread_mutex_unlock(&mutex); return true; }
    if (!prepare || preparing || getpagesize() != PAGE_BYTES) { pthread_mutex_unlock(&mutex); return false; }
    for (size_t i = 0; i < prepared_bytes / PAGE_BYTES; ++i) {
        if (leases[i]) { pthread_mutex_unlock(&mutex); return false; }
    }
    preparing = true;
    size_t existing = prepared_bytes;
    size_t arena_bytes = minimum > POOL_BYTES ? minimum : POOL_BYTES;
    if (bytes > arena_bytes) { preparing = false; pthread_mutex_unlock(&mutex); return false; }
    vm_address_t rx = (vm_address_t)read_view, rw = (vm_address_t)write_view;
    pthread_mutex_unlock(&mutex);

    // These reservations hold addresses only. The mirrors share the physical
    // pages already prepared for Windows, including split or low regions.
    bool rx_reserved = existing || reserve_view(&rx, arena_bytes);
    bool rw_reserved = existing || (rx_reserved && reserve_view(&rw, arena_bytes));
    bool ready = rx_reserved && rw_reserved;
    size_t cursor = existing;
    if (!existing) {
        for (size_t i = 0; ready && i < windows_count; ++i) {
            const IRJITWindowsRegion *r = windows_regions + i;
            ready = alias(r->rx, rx + cursor, r->bytes, VM_PROT_READ | VM_PROT_EXECUTE) &&
                    alias(r->rw, rw + cursor, r->bytes, VM_PROT_READ | VM_PROT_WRITE);
            cursor += r->bytes;
        }
    }

    if (ready && cursor < bytes) {
        size_t added = bytes - cursor;
        // The helper must not stop the app while the allocator lock is held.
        void *backing = prepare(NULL, added);
        task_vm_info_data_t map = {0};
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        bool valid = backing && backing != MAP_FAILED && !((uintptr_t)backing & (PAGE_BYTES - 1)) &&
            task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&map, &count) == KERN_SUCCESS &&
            (uintptr_t)backing >= map.min_address && (uintptr_t)backing < map.max_address &&
            added <= map.max_address - (uintptr_t)backing;
        ready = valid && alias(backing, rx + cursor, added, VM_PROT_READ | VM_PROT_EXECUTE) &&
                         alias(backing, rw + cursor, added, VM_PROT_READ | VM_PROT_WRITE);
        if (valid) vm_deallocate(mach_task_self(), (vm_address_t)backing, added);
    }

    if (!ready && !existing) {
        if (rx_reserved) vm_deallocate(mach_task_self(), rx, arena_bytes);
        if (rw_reserved) vm_deallocate(mach_task_self(), rw, arena_bytes);
    } else if (!ready) {
        // Keep the reserved addresses so a retry can replace the failed extension.
        vm_protect(mach_task_self(), rx + existing, bytes - existing, false, VM_PROT_NONE);
        vm_protect(mach_task_self(), rw + existing, bytes - existing, false, VM_PROT_NONE);
    }
    pthread_mutex_lock(&mutex);
    if (ready) {
        read_view = (void *)rx;
        write_view = (void *)rw;
        prepared_bytes = bytes;
    }
    preparing = false;
    pthread_mutex_unlock(&mutex);
    return ready;
}
static bool verify_region(size_t start, size_t end, bool (*probe)(void *, void *)) {
    for (size_t i = start / PAGE_BYTES; i < end / PAGE_BYTES; ++i) {
        if (leases[i] || windows_pages[i]) continue;
        size_t offset = i * PAGE_BYTES;
        return probe((char *)read_view + offset, (char *)write_view + offset);
    }
    return false;
}

bool ir_jit_memory_verified(void) {
    pthread_mutex_lock(&mutex);
    bool ready = prepared_bytes && verified_bytes == prepared_bytes && !preparing;
    pthread_mutex_unlock(&mutex);
    return ready;
}

bool ir_jit_memory_verify(bool (*probe)(void *, void *)) {
    if (!probe) return false;
    pthread_mutex_lock(&mutex);
    bool ready = prepared_bytes && !preparing;
    if (ready && verified_bytes < prepared_bytes) {
        size_t offset = 0;
        for (size_t i = 0; ready && i < windows_count; ++i) {
            size_t end = offset + windows_regions[i].bytes;
            if (end > verified_bytes) ready = verify_region(offset, end, probe);
            offset = end;
        }
        if (offset < verified_bytes) offset = verified_bytes;
        if (ready && offset < prepared_bytes) ready = verify_region(offset, prepared_bytes, probe);
        if (ready) verified_bytes = prepared_bytes;
    }
    pthread_mutex_unlock(&mutex);
    return ready;
}

static bool allocate_from_arena(size_t bytes, void **rx, void **rw) {
    if (rx) *rx = NULL;
    if (rw) *rw = NULL;
    if (!rx || !rw || !bytes || bytes > POOL_BYTES) return false;
    size_t pages = (bytes + PAGE_BYTES - 1) / PAGE_BYTES;
    pthread_mutex_lock(&mutex);
    if (!prepared_bytes || preparing) { pthread_mutex_unlock(&mutex); return false; }
    size_t run = 0, available = 0, largest = 0;
    // Prefer high addresses so small persistent console allocations land past
    // the Windows span. Big caches can extend down into unclaimed Windows pages.
    size_t limit = prepared_bytes / PAGE_BYTES;
    for (size_t i = limit; i-- > 0;) {
        bool free = !leases[i] && !windows_pages[i];
        run = free ? run + 1 : 0;
        if (free) ++available;
        if (run > largest) largest = run;
        if (run != pages) continue;
        size_t start = i;
        leases[start] = (uint32_t)pages;
        for (size_t j = start + 1; j < start + pages; ++j) leases[j] = UINT32_MAX;
        *rx = (char *)read_view + start * PAGE_BYTES;
        *rw = (char *)write_view + start * PAGE_BYTES;
        for (size_t j = start; j < start + pages; ++j) {
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
static bool allocate(size_t bytes, void **rx, void **rw) {
    if (allocate_from_arena(bytes, rx, rw)) return true;
    void (*reclaim)(void) = atomic_load(&windows_reclaimer);
    if (!rx || !rw || !bytes || bytes > POOL_BYTES || !reclaim) return false;
    // Wine can retire a buffer before its reuse grace has passed. Check again
    // only when the console cannot find room, with no arena lock held.
    reclaim();
    return allocate_from_arena(bytes, rx, rw);
}

static bool release(void *rx, size_t bytes) {
    pthread_mutex_lock(&mutex);
    uintptr_t offset = (uintptr_t)rx - (uintptr_t)read_view;
    bool valid = read_view && rx && bytes && bytes <= POOL_BYTES && offset < prepared_bytes && !(offset & (PAGE_BYTES - 1));
    size_t index = offset / PAGE_BYTES, pages = valid ? (bytes + PAGE_BYTES - 1) / PAGE_BYTES : 0;
    valid = valid && pages <= prepared_bytes / PAGE_BYTES && index <= prepared_bytes / PAGE_BYTES - pages && leases[index] == pages;
    if (valid) memset(leases + index, 0, pages * sizeof(*leases));
    pthread_mutex_unlock(&mutex);
    return valid;
}
const IRJITMemoryAPI *ir_jit_memory_api(void) {
    static const IRJITMemoryAPI api = {sizeof(IRJITMemoryAPI), 1, allocate, release};
    return &api;
}
