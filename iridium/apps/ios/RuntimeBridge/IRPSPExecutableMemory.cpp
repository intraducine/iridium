// SPDX-License-Identifier: AGPL-3.0-only
#include "IRPSPExecutableMemory.h"
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <limits>
#include <mutex>
#include <thread>
#if !defined(IR_PSP_EXEC_FIXTURE)
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#endif

namespace {
constexpr size_t page = 16384, maxClaims = 1024;
constexpr std::array<size_t, 4> sizes = {16 * 1024 * 1024, 256 * 1024, 256 * 1024, 256 * 1024};
enum class Phase { empty, preparing, sealed, detached, restored, native, closing, failed };
struct Claim;
struct Arena { uint8_t *rx = nullptr, *rw = nullptr; size_t bytes = 0; Claim *claim = nullptr; };
std::mutex mutex;
IRPSPExecHost host{};
Phase phase = Phase::empty;
bool request = false, failure = false, detachReturned = false;
size_t claimsUsed = 0;
std::array<Arena, 4> arenas;

// arena.error pass=(role << 8)|operation. Values are fixed flags, role/page
// indexes or result codes; error is the captured errno/Mach return, never text.
enum Operation { pageSize = 1, allocate, remap, protectRX, protectRW, queryRX,
    queryRW, wire, aliasOverlap, arenaOverlap, helperPrepare, sentinel, coherence };
bool arenaError(const IRJITDiagnosticSink *sink, unsigned role, Operation operation,
                int64_t value = 0, int error = 0) {
    ir_jit_diagnostic_mark(sink, IR_JIT_ARENA_ERROR, (role << 8) | operation, value, error);
    return false;
}

#if defined(IR_PSP_EXEC_FIXTURE)
bool mapArena(Arena &);
bool unmapView(void *, size_t);
void synchronize(void *, void *, size_t);
#else
// arena.view: pass=role:8/checkpoint:8/view:4/info-count:8/proof-flags:4.
// value=current protection (low uint32), maximum protection (high uint32).
// Checkpoints: helper RX allocation=1, remap=2, RW protect=4,
// helper return=5, restoration=6, mandatory query rejection=7. Old checkpoint 3
// (app RX mprotect) is no longer used: the helper supplies executable RX.
// Observation never authorizes a mapping or replaces the strict query below.
bool recordView(const IRJITDiagnosticSink *sink, unsigned role, unsigned checkpoint, unsigned view,
                void *pointer, size_t bytes) {
    if (!sink || !pointer) return true;
    vm_address_t address = (vm_address_t)pointer; vm_size_t extent = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t status = vm_region_64(mach_task_self(), &address, &extent, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    uintptr_t target = (uintptr_t)pointer;
    bool contains = address <= target && target - address <= extent;
    unsigned flags = (count == VM_REGION_BASIC_INFO_COUNT_64 ? 1 : 0) | (address == target ? 2 : 0)
        | (contains ? 4 : 0) | (contains && bytes <= extent - (target - address) ? 8 : 0);
    uint32_t pass = (role << 24) | (checkpoint << 16) | (view << 12) | (std::min(count, 255u) << 4) | flags;
    uint64_t protections = (uint32_t)info.protection | ((uint64_t)(uint32_t)info.max_protection << 32);
    return ir_jit_diagnostic_mark(sink, IR_JIT_ARENA_VIEW, pass, (int64_t)protections, status);
}
bool recordViews(const IRJITDiagnosticSink *sink, unsigned role, unsigned checkpoint, const Arena &a) {
    return recordView(sink, role, checkpoint, 1, a.rx, a.bytes)
        && recordView(sink, role, checkpoint, 2, a.rw, a.bytes);
}
bool query(void *pointer, size_t bytes, vm_prot_t expected,
           const IRJITDiagnosticSink *sink = nullptr, unsigned role = 0, Operation operation = queryRX) {
    uintptr_t cursor = (uintptr_t)pointer;
    if (!cursor || !bytes || bytes > UINTPTR_MAX - cursor) return arenaError(sink, role, operation);
    // One owned allocation may contain several regions (e.g. inheritance or
    // backing differs). Require every byte and exact protection, with no holes.
    // The largest admitted arena is 16 MB / 16 KB = 1024 pages/regions.
    constexpr unsigned maxRegions = 1024;
    size_t remaining = bytes;
    for (unsigned region = 0; region < maxRegions; ++region) {
        vm_address_t address = (vm_address_t)cursor;
        vm_size_t extent = 0;
        vm_region_basic_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t status = vm_region_64(mach_task_self(), &address, &extent, VM_REGION_BASIC_INFO_64,
            (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        bool validExtent = extent && extent <= UINTPTR_MAX - address;
        bool contains = address <= cursor && cursor - address < extent;
        bool covers = validExtent && contains && remaining <= extent - (cursor - address);
        bool accepted = status == KERN_SUCCESS && count == VM_REGION_BASIC_INFO_COUNT_64
            && validExtent && contains && info.protection == expected && (covers || region + 1 < maxRegions);
        if (accepted) {
            if (covers) return true;
            size_t advance = extent - (cursor - address);
            cursor += advance;
            remaining -= advance;
            continue;
        }
        // Preserve both permission masks alongside the existing rejection flags.
        // Containment/coverage flags describe the failing cursor and remainder;
        // the preceding prefix has already passed the same strict checks.
        uint32_t pass = (role << 24) | (7u << 16) | ((operation == queryRW ? 2u : 1u) << 12)
            | (std::min(count, 255u) << 4);
        uint64_t protections = (uint32_t)info.protection | ((uint64_t)(uint32_t)info.max_protection << 32);
        ir_jit_diagnostic_mark(sink, IR_JIT_ARENA_VIEW, pass, (int64_t)protections, status);
        unsigned flags = (status == KERN_SUCCESS ? 1 : 0) | (count == VM_REGION_BASIC_INFO_COUNT_64 ? 2 : 0)
            | (address == cursor ? 4 : 0) | (contains ? 8 : 0)
            | (covers ? 16 : 0) | (info.protection == expected ? 32 : 0);
        return arenaError(sink, role, operation, flags, status);
    }
    return false;
}
bool unmapView(void *p, size_t bytes) { return !p || vm_deallocate(mach_task_self(), (vm_address_t)p, bytes) == KERN_SUCCESS; }
bool mapArena(Arena &a, unsigned role, const IRJITDiagnosticSink *sink) {
    if (vm_page_size != page) return arenaError(sink, role, pageSize, vm_page_size);
    // Match the established app path: owned helper RX is prepared first, then
    // remapped without copying. Never ask the app to manufacture execute rights.
    if (!recordViews(sink, role, 1, a)) return false;
    if (!query(a.rx, a.bytes, VM_PROT_READ | VM_PROT_EXECUTE, sink, role, queryRX)) return false;
    vm_address_t alias = 0;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t status = vm_remap(mach_task_self(), &alias, a.bytes, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                     (vm_address_t)a.rx, false, &current, &maximum, VM_INHERIT_NONE);
    if (status != KERN_SUCCESS) return arenaError(sink, role, remap, 0, status);
    a.rw = (uint8_t *)alias;
    if (!recordViews(sink, role, 2, a)) return false;
    if (a.rx == a.rw) { a.rw = nullptr; return arenaError(sink, role, aliasOverlap); }
    status = vm_protect(mach_task_self(), alias, a.bytes, false, VM_PROT_READ | VM_PROT_WRITE);
    if (status != KERN_SUCCESS) return arenaError(sink, role, protectRW, 0, status);
    if (!recordViews(sink, role, 4, a)) return false;
    return query(a.rx, a.bytes, VM_PROT_READ | VM_PROT_EXECUTE, sink, role, queryRX)
        && query(a.rw, a.bytes, VM_PROT_READ | VM_PROT_WRITE, sink, role, queryRW);
}
void synchronize(void *rw, void *rx, size_t bytes) {
    sys_dcache_flush(rw, bytes);
    sys_icache_invalidate(rx, bytes);
}
#endif
bool range(uintptr_t base, size_t extent, uintptr_t pointer, size_t bytes) {
    return pointer >= base && pointer - base <= extent && bytes <= extent - (pointer - base);
}
bool wireRange(uintptr_t rx, size_t bytes) {
    return rx && !(rx & (page - 1)) && bytes && !(bytes & (page - 1)) &&
        rx < (1ULL << 36) && bytes <= (1ULL << 36) - rx;
}
bool livePhase() { return phase == Phase::restored || phase == Phase::native; }
}

namespace {
struct Claim {
    uint64_t identity = 0;
    uint64_t generation = 0;
    unsigned slot = 0, readers = 0, writers = 0;
    bool live = false, failed = false;
    std::thread::id writer;
    uintptr_t writeBegin = 0;
    size_t writeBytes = 0;
};
static_assert(sizeof(Claim) <= 256, "bounded handle metadata");
std::array<Claim, maxClaims> claims;
uint64_t nextIdentity = 1;
bool probeProven = false;
Claim *known(IRPSPExecClaim identity) {
    if (!identity) return nullptr;
    for (size_t i = 0; i < claimsUsed; ++i) if (claims[i].identity == identity) return &claims[i];
    return nullptr;
}
Claim *find(const void *p, size_t bytes, bool rw) {
    for (auto &a : arenas) if (a.claim && range((uintptr_t)(rw ? a.rw : a.rx), a.bytes, (uintptr_t)p, bytes)) return a.claim;
    return nullptr;
}
bool valid(Claim *c) { return c && c->live && c->generation == host.generation && !c->failed && livePhase() && !failure; }
bool idle() {
    for (auto &a : arenas) if (a.claim) return false;
    return !request;
}
bool cleanMappings() {
    bool ok = true;
    for (auto it = arenas.rbegin(); it != arenas.rend(); ++it) {
        if (it->rw && unmapView(it->rw, it->bytes)) it->rw = nullptr;
        if (it->rw) { ok = false; continue; }
        if (it->rx && unmapView(it->rx, it->bytes)) it->rx = nullptr;
        if (it->rx) ok = false;
    }
    return ok;
}
}

uint32_t ir_native_psp_exec_version(void) { return IR_PSP_EXEC_VERSION; }
static int prepare(const IRPSPExecHost *value, const IRJITDiagnosticSink *sink) {
    unsigned rejected = 0;
    {
        std::lock_guard<std::mutex> lock(mutex);
        rejected = phase != Phase::empty ? 1 : !value ? 2 : value->size != sizeof(*value) ? 3
            : value->version != IR_PSP_EXEC_VERSION ? 4 : !value->admission ? 5 : !value->generation ? 6
            : !value->attempt ? 7 : !value->prepare ? 8 : !value->detach ? 9 : 0;
        if (!rejected) {
            bool hash = false; for (auto byte : value->script_sha256) hash |= byte != 0;
            if (!hash) rejected = 10;
        }
        if (!rejected) { host = *value; phase = Phase::preparing; request = true; failure = false; }
    }
    if (rejected) {
        ir_jit_diagnostic_mark(sink, IR_JIT_PREPARE_REJECT, rejected, IR_PSP_EXEC_IDENTITY, 0);
        return IR_PSP_EXEC_IDENTITY;
    }
    int result = IR_PSP_EXEC_OK;
    // No lifecycle/metadata lock spans a BRK or blocking helper command.
    for (size_t i = 0; i < arenas.size(); ++i) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (phase != Phase::preparing) { result = IR_PSP_EXEC_CLOSING; }
        }
        if (result) { ir_jit_diagnostic_mark(sink, IR_JIT_PREPARE_REJECT, 12, result, 0); break; }
        Arena &a = arenas[i]; a.bytes = sizes[i];
        unsigned role = (unsigned)i + 1;
        if (!ir_jit_diagnostic_mark(sink, IR_JIT_ARENA_ENTER, role, (int64_t)a.bytes, 0)) { result = IR_PSP_EXEC_PREPARATION; break; }
        void *owned = nullptr;
        result = host.prepare(host.context, &owned, a.bytes, role);
        // Only a correlated definitive allocation transfers ownership. Do not
        // adopt/free an address on an unknown helper outcome or invalid range.
        if (result != IR_PSP_EXEC_OK && result != IR_PSP_EXEC_PREPARATION) {
            arenaError(sink, role, helperPrepare, result); break;
        }
        if (owned) {
            uintptr_t pointer = (uintptr_t)owned;
#if !defined(IR_PSP_EXEC_FIXTURE)
            if (!wireRange(pointer, a.bytes)) { arenaError(sink, role, wire); result = IR_PSP_EXEC_UNCERTAIN; break; }
#endif
            bool overlap = false;
            for (size_t j = 0; j < i; ++j) {
                for (auto *view : {arenas[j].rx, arenas[j].rw}) if (view &&
                    (range((uintptr_t)view, arenas[j].bytes, pointer, 1) ||
                     range(pointer, a.bytes, (uintptr_t)view, 1))) overlap = true;
            }
            if (overlap) { arenaError(sink, role, arenaOverlap); result = IR_PSP_EXEC_UNCERTAIN; break; }
            a.rx = (uint8_t *)owned;
        }
        if (result) { arenaError(sink, role, helperPrepare, result); break; }
        if (!a.rx) { arenaError(sink, role, helperPrepare); result = IR_PSP_EXEC_UNCERTAIN; break; }
#if !defined(IR_PSP_EXEC_FIXTURE)
        if (!recordViews(sink, role, 5, a)) { result = IR_PSP_EXEC_PREPARATION; break; }
#endif
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (phase != Phase::preparing) result = IR_PSP_EXEC_CLOSING;
        }
        if (result) break;
#if defined(IR_PSP_EXEC_FIXTURE)
        if (!mapArena(a)) { arenaError(sink, role, allocate); result = IR_PSP_EXEC_MAPPING; break; }
#else
        if (!mapArena(a, role, sink)) { result = IR_PSP_EXEC_MAPPING; break; }
#endif
        uintptr_t rx = (uintptr_t)a.rx, rw = (uintptr_t)a.rw;
#if !defined(IR_PSP_EXEC_FIXTURE)
        if (!wireRange(rx, a.bytes)) { arenaError(sink, role, wire); result = IR_PSP_EXEC_RANGE; break; }
#endif
        if (range(rx, a.bytes, rw, 1) || range(rw, a.bytes, rx, 1)) { arenaError(sink, role, aliasOverlap); result = IR_PSP_EXEC_RANGE; break; }
        for (size_t j = 0; j < i; ++j) {
            if (range((uintptr_t)arenas[j].rx, arenas[j].bytes, rx, 1) || range(rx, a.bytes, (uintptr_t)arenas[j].rx, 1)) {
                arenaError(sink, role, arenaOverlap, (int64_t)j + 1); result = IR_PSP_EXEC_RANGE;
            }
        }
        if (result) break;
        for (size_t n = 0; n < a.bytes; n += page) {
            if (a.rx[n] != 0x69 || a.rw[n] != 0x69) { arenaError(sink, role, sentinel, n / page); result = IR_PSP_EXEC_PREPARATION; break; }
            a.rw[n] = 0;
            if (a.rx[n] != 0 || a.rw[n] != 0) { arenaError(sink, role, coherence, n / page); result = IR_PSP_EXEC_PREPARATION; break; }
        }
        if (result) break;
        if (!ir_jit_diagnostic_mark(sink, IR_JIT_ARENA_RETURN, role, IR_PSP_EXEC_OK, 0)) { result = IR_PSP_EXEC_PREPARATION; break; }
    }
    std::lock_guard<std::mutex> lock(mutex);
    request = false;
    if (phase == Phase::closing) return result == IR_PSP_EXEC_UNCERTAIN ? result : IR_PSP_EXEC_CLOSING;
    phase = result ? Phase::failed : Phase::sealed;
    failure = result != 0;
    // A failed/uncertain helper is still owned; end only after definitive return.
    return result;
}
int ir_native_psp_exec_prepare_diagnostic(const IRPSPExecHost *value, const IRJITDiagnosticSink *sink) {
    if (!ir_jit_diagnostic_mark(sink, IR_JIT_PREPARE_ENTER, 0, 0, 0)) return IR_PSP_EXEC_PREPARATION;
    int result = prepare(value, sink);
    return ir_jit_diagnostic_mark(sink, IR_JIT_PREPARE_RETURN, 0, result, 0) ? result : IR_PSP_EXEC_PREPARATION;
}
int ir_native_psp_exec_prepare(const IRPSPExecHost *value) { return ir_native_psp_exec_prepare_diagnostic(value, nullptr); }
int ir_native_psp_exec_detach(uint64_t owner) {
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (owner != host.admission || (phase != Phase::sealed && phase != Phase::failed) || request) return IR_PSP_EXEC_CLOSING;
        request = true;
    }
    int result = host.detach(host.context);
    std::lock_guard<std::mutex> lock(mutex); request = false; detachReturned = result == 0;
    return result; // Only target return; the correlated shutdown receipt is separate.
}
int ir_native_psp_exec_accept_shutdown(const IRPSPExecShutdown *receipt) {
    std::lock_guard<std::mutex> lock(mutex);
    if (request || !detachReturned || phase != Phase::sealed || !receipt || receipt->size != sizeof(*receipt) || receipt->version != IR_PSP_EXEC_VERSION ||
        receipt->flags != IR_PSP_SHUTDOWN_ALL || receipt->admission != host.admission ||
        receipt->generation != host.generation || receipt->attempt != host.attempt ||
        memcmp(receipt->script_sha256, host.script_sha256, 32)) return IR_PSP_EXEC_SHUTDOWN;
    phase = Phase::detached; return IR_PSP_EXEC_OK;
}
int ir_native_psp_exec_restored_diagnostic(uint64_t owner, bool success, const IRJITDiagnosticSink *sink) {
    if (!ir_jit_diagnostic_mark(sink, IR_JIT_PREPARE_ENTER, 1, 0, 0)) return IR_PSP_EXEC_PREPARATION;
    std::lock_guard<std::mutex> lock(mutex);
    unsigned rejected = owner != host.admission ? 13 : phase != Phase::detached ? 14 : !success ? 15 : 0;
    if (rejected) {
        ir_jit_diagnostic_mark(sink, IR_JIT_PREPARE_REJECT, rejected, IR_PSP_EXEC_RESTORATION, 0);
        ir_jit_diagnostic_mark(sink, IR_JIT_PREPARE_RETURN, 1, IR_PSP_EXEC_RESTORATION, 0);
        return IR_PSP_EXEC_RESTORATION;
    }
    int result = IR_PSP_EXEC_OK;
    // Recheck the unpublished mappings after debugger teardown and restoration.
    for (size_t i = 0; i < arenas.size() && !result; ++i) {
        auto &a = arenas[i];
        unsigned role = (unsigned)i + 1;
#if !defined(IR_PSP_EXEC_FIXTURE)
        if (!recordViews(sink, role, 6, a)) { result = IR_PSP_EXEC_PREPARATION; break; }
        if (!query(a.rx, a.bytes, VM_PROT_READ | VM_PROT_EXECUTE, sink, role, queryRX) ||
            !query(a.rw, a.bytes, VM_PROT_READ | VM_PROT_WRITE, sink, role, queryRW)) { result = IR_PSP_EXEC_MAPPING; break; }
#endif
        for (size_t n = 0; n < a.bytes; n += page) {
            if (a.rx[n] != 0 || a.rw[n] != 0) { arenaError(sink, role, sentinel, n / page); result = IR_PSP_EXEC_PREPARATION; break; }
            a.rw[n] = 0x35;
            bool coherent = a.rx[n] == 0x35;
            a.rw[n] = 0;
            if (!coherent || a.rx[n] != 0) { arenaError(sink, role, coherence, n / page); result = IR_PSP_EXEC_PREPARATION; break; }
        }
    }
    if (!ir_jit_diagnostic_mark(sink, IR_JIT_PREPARE_RETURN, 1, result, 0)) return IR_PSP_EXEC_PREPARATION;
    if (result) return result;
    phase = Phase::restored; return IR_PSP_EXEC_OK;
}
int ir_native_psp_exec_restored(uint64_t owner, bool success) { return ir_native_psp_exec_restored_diagnostic(owner, success, nullptr); }
int ir_native_psp_exec_advance(uint64_t owner, uint64_t previous, uint64_t next) {
    std::lock_guard<std::mutex> lock(mutex);
    if (owner != host.admission || !probeProven || phase != Phase::restored || previous != host.generation || next <= previous || !idle()) return IR_PSP_EXEC_IDENTITY;
    host.generation = next; phase = Phase::native; return IR_PSP_EXEC_OK;
}
void ir_native_psp_exec_cancel(uint64_t owner) { std::lock_guard<std::mutex> lock(mutex); if (owner == host.admission && phase != Phase::empty) phase = Phase::closing; }
int ir_native_psp_exec_end(uint64_t owner) {
    std::lock_guard<std::mutex> lock(mutex);
    if (phase != Phase::empty && owner != host.admission) return IR_PSP_EXEC_IDENTITY;
    if (!idle()) return IR_PSP_EXEC_UNCERTAIN;
    if (!cleanMappings()) { phase = Phase::closing; return IR_PSP_EXEC_MAPPING; }
    host = {}; arenas = {}; claims = {}; claimsUsed = 0; probeProven = false; detachReturned = false; phase = Phase::empty; failure = false;
    return IR_PSP_EXEC_OK;
}
IRPSPExecClaim ir_psp_exec_claim(unsigned role, size_t bytes, void **rx, void **rw) {
    std::lock_guard<std::mutex> lock(mutex);
    if (rx) *rx = nullptr; if (rw) *rw = nullptr;
    if (!rx || !rw || !livePhase() || failure || role < 1 || role > 4 || bytes != sizes[role - 1] ||
        arenas[role - 1].claim || claimsUsed == maxClaims || !nextIdentity ||
        (phase == Phase::restored && role != IR_PSP_EXEC_CPU)) return 0;
    auto &c = claims[claimsUsed++]; c.identity = nextIdentity++; c.generation = host.generation; c.slot = role - 1; c.live = true;
    arenas[c.slot].claim = &c; *rx = arenas[c.slot].rx; *rw = arenas[c.slot].rw; return c.identity;
}
bool ir_psp_exec_release(IRPSPExecClaim pointer) {
    std::lock_guard<std::mutex> lock(mutex);
    auto *c = known(pointer);
    if (!c) return false;
    if (!c->live) return true;
    if (c->readers || c->writers) return false;
    auto &a = arenas[c->slot];
    memset(a.rw, 0, a.bytes); synchronize(a.rw, a.rx, a.bytes);
    a.claim = nullptr; c->live = false; return true;
}
bool ir_psp_exec_translate(const void *pointer, size_t bytes, bool to_rw, void **out) {
    std::lock_guard<std::mutex> lock(mutex); if (out) *out = nullptr;
    auto *c = find(pointer, bytes, !to_rw); if (!out || !valid(c)) return false;
    auto &a = arenas[c->slot]; uintptr_t offset = (uintptr_t)pointer - (uintptr_t)(to_rw ? a.rx : a.rw);
    *out = (void *)((uintptr_t)(to_rw ? a.rw : a.rx) + offset); return true;
}
bool ir_psp_exec_begin_write(IRPSPExecClaim pointer, const void *rx, size_t bytes) {
    std::lock_guard<std::mutex> lock(mutex); auto *c = known(pointer);
    if (!valid(c) || c->writers || ((uintptr_t)rx & 3) || !range((uintptr_t)arenas[c->slot].rx, arenas[c->slot].bytes, (uintptr_t)rx, bytes)) return false;
    c->writers = 1; c->writer = std::this_thread::get_id();
    c->writeBegin = (uintptr_t)rx; c->writeBytes = bytes; return true;
}
IRPSPExecClaim ir_psp_exec_begin_patch(const void *p, size_t bytes) {
    std::lock_guard<std::mutex> lock(mutex); auto *c = find(p, bytes, false);
    bool writable = false;
    if (!c) { c = find(p, bytes, true); writable = true; }
    if (!valid(c) || c->writers || ((uintptr_t)p & 3)) return 0;
    auto &a = arenas[c->slot];
    c->writeBegin = (uintptr_t)a.rx + ((uintptr_t)p - (uintptr_t)(writable ? a.rw : a.rx));
    c->writeBytes = bytes; c->writers = 1; c->writer = std::this_thread::get_id(); return c->identity;
}
bool ir_psp_exec_end_write(IRPSPExecClaim pointer, const void *rx, size_t bytes) {
    std::lock_guard<std::mutex> lock(mutex); auto *c = known(pointer);
    if (!c || !c->writers || c->writer != std::this_thread::get_id()) return false;
    c->writers = 0; c->writer = {}; c->writeBegin = 0; c->writeBytes = 0;
    auto &a = arenas[c->slot];
    if (!valid(c) || !range((uintptr_t)a.rx, a.bytes, (uintptr_t)rx, bytes)) return false;
    synchronize(a.rw + ((uintptr_t)rx - (uintptr_t)a.rx), (void *)rx, bytes); return true;
}
bool ir_psp_exec_write32(const void *rx, void *rw, uint32_t word) {
    std::lock_guard<std::mutex> lock(mutex); auto *c = find(rx, 4, false);
    if (!valid(c)) return false;
    auto &a = arenas[c->slot]; size_t offset = (uintptr_t)rx - (uintptr_t)a.rx;
    if (((uintptr_t)rx & 3) || rw != a.rw + offset || !c->writers || c->writer != std::this_thread::get_id() ||
        !range(c->writeBegin, c->writeBytes, (uintptr_t)rx, 4)) return false;
    memcpy(rw, &word, 4); return true;
}
bool ir_psp_exec_validate(const void *p, size_t bytes, bool writable) {
    std::lock_guard<std::mutex> lock(mutex); return valid(find(p, bytes, writable));
}
bool ir_psp_exec_publish(const void *rx, size_t bytes) {
    std::lock_guard<std::mutex> lock(mutex); auto *c = find(rx, bytes, false); if (!valid(c)) return false;
    auto &a = arenas[c->slot]; synchronize(a.rw + ((uintptr_t)rx - (uintptr_t)a.rx), (void *)rx, bytes); return true;
}
void ir_psp_exec_probe_proven(bool value) { std::lock_guard<std::mutex> lock(mutex); if (phase == Phase::restored) probeProven = value; }
uint64_t ir_psp_exec_admission(void) { std::lock_guard<std::mutex> lock(mutex); return host.admission; }
uint64_t ir_psp_exec_generation(void) { std::lock_guard<std::mutex> lock(mutex); return host.generation; }
bool ir_psp_exec_native_ready(void) { std::lock_guard<std::mutex> lock(mutex); return phase == Phase::native && probeProven && !failure; }
int ir_psp_exec_reuse_native(uint64_t owner) {
    std::lock_guard<std::mutex> lock(mutex);
    if (owner != host.admission || phase != Phase::native || failure || !idle() || host.generation == UINT64_MAX) return IR_PSP_EXEC_UNCERTAIN;
    ++host.generation; return IR_PSP_EXEC_OK;
}
bool ir_psp_exec_failed(void) { std::lock_guard<std::mutex> lock(mutex); return failure; }
void ir_psp_exec_fail(void) { std::lock_guard<std::mutex> lock(mutex); failure = true; }
IRPSPExecClaim ir_psp_exec_enter(const void *rx) {
    std::lock_guard<std::mutex> lock(mutex); auto *c = find(rx, 1, false);
    if (!c) c = find(rx, 1, true);
    if (!valid(c) || c->readers == std::numeric_limits<unsigned>::max()) return 0;
    c->readers++; return c->identity;
}
IRPSPExecClaim ir_psp_exec_enter_role(unsigned role) {
    std::lock_guard<std::mutex> lock(mutex);
    auto *c = role >= 1 && role <= 4 ? arenas[role - 1].claim : nullptr;
    if (!valid(c) || c->readers == std::numeric_limits<unsigned>::max()) return 0;
    c->readers++; return c->identity;
}
void ir_psp_exec_leave(IRPSPExecClaim pointer) {
    std::lock_guard<std::mutex> lock(mutex); auto *c = known(pointer);
    if (c && c->live && c->readers) c->readers--;
}
