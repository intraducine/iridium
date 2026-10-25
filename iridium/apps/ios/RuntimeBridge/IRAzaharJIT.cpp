// SPDX-License-Identifier: AGPL-3.0-only
#include "IRPhase3.h"
#include "IRJITExecutionProbe.h"
#include <atomic>
#include <cstring>
#include <mach/mach.h>
#include <oaknut/code_block.hpp>
#include <sys/mman.h>
#include <unistd.h>
#include <TargetConditionals.h>

static std::atomic<IRPhase3JITPrepare> prepare_region{nullptr};
static std::atomic<unsigned> executed{0};
static IRJITMemoryAPI memory_api{};
extern "C" bool ir_phase3_core_prepare_memory(const IRJITMemoryAPI *api) {
    if (!api || api->size != sizeof(*api) || api->version != 1 || !api->allocate || !api->release) return false;
    if (memory_api.allocate && (memory_api.allocate != api->allocate || memory_api.release != api->release)) return false;
    memory_api = *api; executed.store(0); return true;
}
extern "C" void ir_azahar_jit_release(void *rx, void *rw, size_t bytes) {
    if (memory_api.release) memory_api.release(rx, bytes);
    else { munmap(rw, bytes); munmap(rx, bytes); }
}

extern "C" bool ir_phase3_core_prepare_jit(IRPhase3JITPrepare prepare) {
    if (!prepare) return false;
    prepare_region.store(prepare);
    executed.store(0);
    return true;
}

extern "C" void *ir_azahar_jit_allocate(size_t size, void **write_pointer) {
    const size_t page = getpagesize();
    auto prepare = prepare_region.load();
    if (!write_pointer || !size || size > 128 * 1024 * 1024) return nullptr;
    if (memory_api.allocate) {
        void *rx = nullptr; *write_pointer = nullptr;
        return memory_api.allocate(size, &rx, write_pointer) ? rx : nullptr;
    }
    if (!prepare) return nullptr;
    *write_pointer = nullptr;
    size = (size + page - 1) & ~(page - 1);
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

extern "C" bool ir_phase3_core_check_jit() {
#if defined(__aarch64__) && !TARGET_OS_SIMULATOR
    try {
        oaknut::CodeBlock code(getpagesize());
        const uint32_t first[] = {0xd2800540, 0xd65f03c0};
        std::memcpy(code.wptr(), first, sizeof first);
        code.invalidate(code.ptr(), sizeof first);
        if (!ir_jit_probe_execute(code.ptr(), sizeof first, 42)) return false;
        const uint32_t second[] = {0xd28000e0, 0xd65f03c0};
        std::memcpy(code.wptr(), second, sizeof second);
        code.invalidate(code.ptr(), sizeof second);
        return ir_jit_probe_execute(code.ptr(), sizeof second, 7);
    } catch (...) { return false; }
#else
    return false;
#endif
}

extern "C" void ir_azahar_jit_executed(unsigned kind) {
    executed.fetch_or(1u << kind, std::memory_order_relaxed);
}
extern "C" unsigned ir_phase3_core_jit_status() {
    return executed.load(std::memory_order_relaxed);
}
