// SPDX-License-Identifier: AGPL-3.0-only
#include "IRSharedJITMemory.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cstring>
#include <map>
#include <mutex>
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>

static IRJITMemoryAPI memory_api{};
static std::atomic<IRPhase3JITPrepare> prepare_region{nullptr};
static constexpr size_t block_size = 4096, pool_size = 4 * 1024 * 1024, pool_slots = pool_size / block_size;
struct Pool { void *write; size_t live; std::array<bool, pool_slots> used{}; };
struct Mapping { void *write; size_t size; void *pool; };
static std::map<void *, Mapping> mappings;
static std::map<void *, Pool> pools;
static void *spare_pool;
static std::mutex mapping_lock;

extern "C" bool ir_phase3_core_prepare_jit(IRPhase3JITPrepare prepare) {
    if (!prepare) return false;
    std::lock_guard<std::mutex> guard(mapping_lock);
    if (memory_api.allocate) return false;
    if (spare_pool) {
        munmap(pools.at(spare_pool).write, pool_size);
        munmap(spare_pool, pool_size);
        pools.erase(spare_pool); spare_pool = nullptr;
    }
    prepare_region.store(prepare);
    return true;
}

extern "C" bool ir_phase3_core_prepare_memory(const IRJITMemoryAPI *api) {
    if (!api || api->size != sizeof(*api) || api->version != 1 || !api->allocate || !api->release) return false;
    std::lock_guard<std::mutex> guard(mapping_lock);
    if (!mappings.empty() || !pools.empty()) return memory_api.allocate == api->allocate && memory_api.release == api->release;
    memory_api = *api;
    return true;
}
static void release_region(void *rx, void *rw, size_t bytes) {
    if (memory_api.release) memory_api.release(rx, bytes);
    else { munmap(rw, bytes); munmap(rx, bytes); }
}
static void *map_region(size_t size, void **write_pointer) {
    if (memory_api.allocate) {
        void *rx = nullptr;
        return memory_api.allocate(size, &rx, write_pointer) ? rx : nullptr;
    }
    auto prepare = prepare_region.load();
    const size_t page = getpagesize();
    void *rx = prepare(nullptr, size);
    if (!rx || rx == MAP_FAILED || ((uintptr_t)rx & (page - 1))) return nullptr;
    vm_address_t rw = 0;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t result = vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE,
        mach_task_self(), (vm_address_t)rx, false, &current, &maximum, VM_INHERIT_NONE);
    if (result != KERN_SUCCESS ||
        vm_protect(mach_task_self(), rw, size, false, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
        if (result == KERN_SUCCESS) vm_deallocate(mach_task_self(), rw, size);
        munmap(rx, size);
        return nullptr;
    }
    *write_pointer = (void *)rw;
    return rx;
}

extern "C" void *ir_shared_jit_allocate(size_t size, void **write_pointer) {
    if (!write_pointer) return nullptr;
    *write_pointer = nullptr;
    const size_t page = getpagesize();
    if ((!memory_api.allocate && !prepare_region.load()) || !size || size > SIZE_MAX - page ||
        (!memory_api.allocate && size > 128 * 1024 * 1024)) return nullptr;
    std::lock_guard<std::mutex> guard(mapping_lock);
    // CodeGen's small blocks share a prepared region instead of stopping the
    // whole app in the debugger for every block. Keep one idle pool for reuse.
    if (size <= block_size) {
        auto pool = std::find_if(pools.begin(), pools.end(), [](const auto &item) { return item.second.live < pool_slots; });
        if (pool == pools.end()) {
            void *write = nullptr;
            void *rx = map_region(pool_size, &write);
            if (!rx) return nullptr;
            try { pool = pools.emplace(rx, Pool{write, 0, {}}).first; }
            catch (...) { release_region(rx, write, pool_size); return nullptr; }
        }
        size_t slot = std::find(pool->second.used.begin(), pool->second.used.end(), false) - pool->second.used.begin();
        void *rx = (char *)pool->first + slot * block_size;
        void *write = (char *)pool->second.write + slot * block_size;
        try { mappings.emplace(rx, Mapping{write, size, pool->first}); }
        catch (...) {
            if (!pool->second.live) {
                release_region(pool->first, pool->second.write, pool_size);
                if (spare_pool == pool->first) spare_pool = nullptr;
                pools.erase(pool);
            }
            return nullptr;
        }
        pool->second.used[slot] = true; ++pool->second.live;
        if (spare_pool == pool->first) spare_pool = nullptr;
        std::memset(write, 0, block_size);
        *write_pointer = write;
        return rx;
    }
    size = (size + page - 1) & ~(page - 1);
    void *write = nullptr;
    void *rx = map_region(size, &write);
    if (!rx) return nullptr;
    try { mappings.emplace(rx, Mapping{write, size, nullptr}); }
    catch (...) { release_region(rx, write, size); return nullptr; }
    *write_pointer = write;
    return rx;
}

extern "C" void *ir_shared_jit_write(void *code) {
    std::lock_guard<std::mutex> guard(mapping_lock);
    auto found = mappings.find(code);
    return found == mappings.end() ? nullptr : found->second.write;
}

extern "C" void ir_shared_jit_release(void *code) {
    std::lock_guard<std::mutex> guard(mapping_lock);
    auto found = mappings.find(code);
    if (found == mappings.end())
        found = std::find_if(mappings.begin(), mappings.end(), [code](const auto &item) { return item.second.write == code; });
    if (found == mappings.end()) return;
    if (found->second.pool) {
        auto pool = pools.find(found->second.pool);
        size_t slot = ((uintptr_t)found->first - (uintptr_t)pool->first) / block_size;
        pool->second.used[slot] = false;
        if (!--pool->second.live) {
            if (!spare_pool) spare_pool = pool->first;
            else {
                release_region(pool->first, pool->second.write, pool_size);
                pools.erase(pool);
            }
        }
    } else {
        release_region(found->first, found->second.write, found->second.size);
    }
    mappings.erase(found);
}
