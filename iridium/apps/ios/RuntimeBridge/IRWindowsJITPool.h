// SPDX-License-Identifier: AGPL-3.0-only
// Included once in the generated Wine virtual-memory adapter.
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

struct ir_windows_image_request {
    const void *base;
    size_t size, delta, trampolines;
};
struct ir_windows_image_slot {
    struct ir_windows_image_slot *next;
    size_t offset, size;
    void *owner;
    uint64_t epoch;
    bool retired;
};
static struct ir_windows_image_slot *ir_windows_image_slots;
typedef bool (*ir_windows_image_access)(size_t, size_t, bool);
typedef bool (*ir_windows_image_overlap)(size_t, size_t);

static uint32_t ir_windows_image_word(const unsigned char *base, size_t offset, size_t count) {
    uint32_t result = 0;
    for (size_t i = 0; i < count; i++) result |= (uint32_t)base[offset + i] << (8 * i);
    return result;
}

static bool ir_windows_image_fits(const struct ir_windows_image_request *request,
                                 size_t offset, size_t capacity, ir_windows_image_access access) {
    const unsigned char *base = request->base;
    size_t size = request->size;
    if (!base || size < 64 || size > SIZE_MAX - 0x3fff || request->delta >= 0x4000 ||
        (request->delta & 0xfff) || offset > SIZE_MAX - capacity) return false;
    size_t aligned = (size + 0x3fff) & ~(size_t)0x3fff;
    if (request->delta > capacity || aligned > capacity - request->delta ||
        request->trampolines > capacity - request->delta - aligned) return false;
    if (ir_windows_image_word(base, 0, 2) != 0x5a4d) return false;
    size_t nt = ir_windows_image_word(base, 0x3c, 4);
    if (nt < 64 || nt > size - 24 || ir_windows_image_word(base, nt, 4) != 0x4550) return false;
    size_t count = ir_windows_image_word(base, nt + 6, 2);
    size_t optional = ir_windows_image_word(base, nt + 20, 2);
    if (!count || count > 96 || optional < 64 || optional > size - nt - 24) return false;
    size_t magic = ir_windows_image_word(base, nt + 24, 2);
    if ((magic != 0x10b && magic != 0x20b) ||
        ir_windows_image_word(base, nt + 24 + 56, 4) != size) return false;
    size_t sections = nt + 24 + optional;
    if (count > (size - sections) / 40) return false;
    bool executable = false;
    for (size_t i = 0; i < count; i++) {
        size_t section = sections + i * 40;
        size_t length = ir_windows_image_word(base, section + 8, 4);
        size_t rva = ir_windows_image_word(base, section + 12, 4);
        uint32_t flags = ir_windows_image_word(base, section + 36, 4);
        if (rva > size || length > size - rva) return false;
        if (!length) continue;
        if (flags & 0x20000000) {
            executable = true;
            if (!access(offset + request->delta + rva, length, false)) return false;
        } else if (flags & 0x80000000) {
            // Reuse existing data pages without removing execute access from new pages.
            if (!access(offset + request->delta + rva, length, true)) return false;
        }
    }
    return executable && (!request->trampolines ||
        access(offset + request->delta + aligned, request->trampolines, false));
}

// All list operations run under Wine's pool lock. A new epoch proves old guest threads ended.
static size_t ir_windows_image_take(const struct ir_windows_image_request *request, size_t limit,
                                   size_t *capacity, uint64_t epoch,
                                   ir_windows_image_access access, ir_windows_image_overlap overlap) {
    struct ir_windows_image_slot *best = NULL;
    for (struct ir_windows_image_slot *slot = ir_windows_image_slots; slot; slot = slot->next) {
        if (!slot->retired || !slot->epoch || epoch <= slot->epoch || slot->size < *capacity ||
            slot->offset > limit || slot->size > limit - slot->offset ||
            (best && slot->size >= best->size) || overlap(slot->offset, slot->size)) continue;
        if (ir_windows_image_fits(request, slot->offset, slot->size, access)) best = slot;
    }
    if (!best) return SIZE_MAX;
    best->retired = false;
    *capacity = best->size;
    return best->offset;
}

static void ir_windows_image_note(size_t offset, size_t size, void *owner, uint64_t epoch) {
    if (!owner || !epoch) return;
    struct ir_windows_image_slot *slot = ir_windows_image_slots;
    while (slot && (slot->offset != offset || slot->size != size)) slot = slot->next;
    if (!slot) {
        slot = calloc(1, sizeof(*slot));
        if (!slot) return;
        slot->next = ir_windows_image_slots;
        ir_windows_image_slots = slot;
    }
    slot->offset = offset; slot->size = size; slot->owner = owner;
    slot->epoch = epoch; slot->retired = false;
}

static bool ir_windows_image_retire(size_t offset, size_t size, void *owner) {
    for (struct ir_windows_image_slot *slot = ir_windows_image_slots; slot; slot = slot->next) {
        if (!slot->retired && slot->offset == offset && slot->size == size && slot->owner == owner) {
            slot->retired = true;
            return true;
        }
    }
    return false;
}
