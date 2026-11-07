// SPDX-License-Identifier: AGPL-3.0-only
// Included once in the generated Wine Metal Unix adapter.
#pragma once
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

extern void *ios_jit_current_peb(void);
extern uint64_t ir_windows_session_epoch(void);
extern void ir_windows_events_owner_died(void *);
extern void ir_windows_events_reclaim(uint64_t);

struct ir_metal_reference {
    struct ir_metal_reference *next;
    id object;
    void *owner;
    uint64_t epoch;
    size_t count;
    bool retired;
};
static pthread_mutex_t ir_metal_lock = PTHREAD_MUTEX_INITIALIZER;
static struct ir_metal_reference *ir_metal_references[1024];
static bool ir_metal_untracked;

static struct ir_metal_reference **ir_metal_find(id object) {
    struct ir_metal_reference **cursor = &ir_metal_references[((uintptr_t)object >> 4) % 1024];
    while (*cursor && (*cursor)->object != object) cursor = &(*cursor)->next;
    return cursor;
}

static void ir_metal_acquire(id object) {
    if (!object || [object isKindOfClass:[NSAutoreleasePool class]]) return;
    void *owner = ios_jit_current_peb();
    uint64_t epoch = ir_windows_session_epoch();
    pthread_mutex_lock(&ir_metal_lock);
    struct ir_metal_reference **cursor = ir_metal_find(object), *entry = *cursor;
    if (entry) {
        entry->count++;
        if (entry->owner != owner || entry->epoch != epoch) {
            // A reference shared with a live process must keep its normal lifetime.
            entry->owner = NULL;
            entry->epoch = 0;
        }
    } else if (owner && epoch) {
        entry = calloc(1, sizeof(*entry));
        if (entry) {
            *entry = (struct ir_metal_reference){.object=object, .owner=owner,
                .epoch=epoch, .count=1};
            *cursor = entry;
        } else {
            if (!ir_metal_untracked) fprintf(stderr, "[session-reclaim] Metal tracking allocation failed; keeping guest mappings\n");
            ir_metal_untracked = true;
        }
    }
    pthread_mutex_unlock(&ir_metal_lock);
}

static void ir_metal_release(id object) {
    pthread_mutex_lock(&ir_metal_lock);
    struct ir_metal_reference **cursor = ir_metal_find(object), *entry = *cursor;
    if (entry && !--entry->count) {
        *cursor = entry->next;
        free(entry);
    }
    pthread_mutex_unlock(&ir_metal_lock);
}

void ir_windows_metal_owner_died(void *owner) {
    if (!owner) return;
    ir_windows_events_owner_died(owner);
    pthread_mutex_lock(&ir_metal_lock);
    for (size_t i = 0; i < 1024; i++)
        for (struct ir_metal_reference *entry = ir_metal_references[i]; entry; entry = entry->next)
            if (entry->owner == owner) entry->retired = true;
    pthread_mutex_unlock(&ir_metal_lock);
}

static bool ir_metal_completed(struct ir_metal_reference *entry, uint64_t epoch) {
    return entry->owner && entry->retired && entry->epoch && entry->epoch < epoch;
}

static dispatch_group_t ir_metal_work(void) {
    static dispatch_group_t group;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ group = dispatch_group_create(); });
    return group;
}

static void ir_metal_submit(id<MTLCommandBuffer> buffer) {
    dispatch_group_t group = ir_metal_work();
    dispatch_group_enter(group);
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> unused) {
        (void)unused;
        dispatch_group_leave(group);
    }];
}

bool ir_windows_metal_reclaim(uint64_t epoch) {
    struct ir_metal_reference *completed = NULL;
    if (dispatch_group_wait(ir_metal_work(), dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) return false;
    pthread_mutex_lock(&ir_metal_lock);
    bool ready = !ir_metal_untracked;
    for (size_t i = 0; i < 1024 && ready; i++)
        for (struct ir_metal_reference *entry = ir_metal_references[i]; entry; entry = entry->next)
            if (!entry->owner && entry->count) { ready = false; break; }
    if (!ready) { pthread_mutex_unlock(&ir_metal_lock); return false; }
    for (size_t i = 0; i < 1024; i++) {
        struct ir_metal_reference **cursor = &ir_metal_references[i];
        while (*cursor) {
            struct ir_metal_reference *entry = *cursor;
            if (!ir_metal_completed(entry, epoch)) { cursor = &entry->next; continue; }
            *cursor = entry->next;
            entry->next = completed;
            completed = entry;
        }
    }
    pthread_mutex_unlock(&ir_metal_lock);
    size_t released = 0;
    ir_windows_events_reclaim(epoch);
    @autoreleasepool {
        while (completed) {
            struct ir_metal_reference *entry = completed;
            completed = entry->next;
            for (size_t i = 0; i < entry->count; i++) [entry->object release];
            released += entry->count;
            free(entry);
        }
    }
    if (released) fprintf(stderr, "[session-reclaim] released %zu Metal references\n", released);
    return true;
}
