// SPDX-License-Identifier: AGPL-3.0-only
// Included once in the checked Wine Metal shared-event adapter.
#pragma once
#import <Foundation/Foundation.h>
#import <CoreFoundation/CFRunLoop.h>
#import <Metal/Metal.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

extern void *ios_jit_current_peb(void);
extern uint64_t ir_windows_session_epoch(void);
extern NTSTATUS NtSetEvent(void *, void *);

enum {
    IR_EVENT_NO_MEMORY = (NTSTATUS)0xc0000017,
    IR_EVENT_INVALID_HANDLE = (NTSTATUS)0xc0000008
};

@interface IRWindowsMetalListener : NSObject {
@public
    uint64_t identifier, epoch;
    void *owner;
    bool stopped, started;
    CFRunLoopRef loop;
    CFRunLoopSourceRef source;
    MTLSharedEventListener *listener;
    NSMutableArray *pending;
}
@end
@implementation IRWindowsMetalListener
- (void)dealloc {
    if (source) { CFRunLoopRemoveSource(loop, source, kCFRunLoopCommonModes); CFRelease(source); }
    if (loop) CFRelease(loop);
    [listener release]; [pending release];
    [super dealloc];
}
@end

static pthread_mutex_t ir_event_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *ir_event_listeners;
static uint64_t ir_event_identifier;

// Registry handles never repeat. Delayed Metal blocks cannot find a later listener at an old address.
static IRWindowsMetalListener *ir_event_find(uint64_t identifier) {
    NSNumber *key = [[NSNumber alloc] initWithUnsignedLongLong:identifier];
    IRWindowsMetalListener *value = [ir_event_listeners objectForKey:key];
    [key release];
    return value;
}

static void ir_event_remove(IRWindowsMetalListener *value) {
    NSNumber *key = [[NSNumber alloc] initWithUnsignedLongLong:value->identifier];
    [ir_event_listeners removeObjectForKey:key];
    [key release];
}

static void ir_event_signal(uint64_t identifier, void *event) {
    pthread_mutex_lock(&ir_event_lock);
    IRWindowsMetalListener *value = ir_event_find(identifier);
    bool valid = value && !value->stopped && value->owner == ios_jit_current_peb();
    pthread_mutex_unlock(&ir_event_lock);
    if (valid) NtSetEvent(event, NULL);
}

static void ir_event_schedule(IRWindowsMetalListener *value, void *event) {
    uint64_t identifier = value->identifier;
    CFRunLoopPerformBlock(value->loop, kCFRunLoopCommonModes, ^{ ir_event_signal(identifier, event); });
    CFRunLoopWakeUp(value->loop);
}

static void ir_event_notify(uint64_t identifier, void *event) {
    pthread_mutex_lock(&ir_event_lock);
    IRWindowsMetalListener *value = ir_event_find(identifier);
    if (value && !value->stopped) {
        if (value->loop) ir_event_schedule(value, event);
        else {
            NSValue *saved = [[NSValue alloc] initWithBytes:&event objCType:@encode(void *)];
            [value->pending addObject:saved];
            [saved release];
        }
    }
    pthread_mutex_unlock(&ir_event_lock);
}

static void ir_event_stop(IRWindowsMetalListener *value) {
    value->stopped = true;
    [value->pending removeAllObjects];
    if (value->loop) {
        CFRunLoopRef loop = (CFRunLoopRef)CFRetain(value->loop);
        // Process retirement can hold Wine locks. Stop the run loop outside those locks.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ CFRunLoopStop(loop); CFRelease(loop); });
    }
}

void ir_windows_events_owner_died(void *owner) {
    if (!owner) return;
    pthread_mutex_lock(&ir_event_lock);
    for (NSNumber *key in ir_event_listeners) {
        IRWindowsMetalListener *value = [ir_event_listeners objectForKey:key];
        if (value->owner == owner) ir_event_stop(value);
    }
    pthread_mutex_unlock(&ir_event_lock);
}

void ir_windows_events_reclaim(uint64_t epoch) {
    @autoreleasepool {
        pthread_mutex_lock(&ir_event_lock);
        NSArray *values = [[ir_event_listeners allValues] retain];
        for (IRWindowsMetalListener *value in values)
            if (value->stopped && value->epoch && value->epoch < epoch) ir_event_remove(value);
        pthread_mutex_unlock(&ir_event_lock);
        [values release];
    }
}

static NTSTATUS _SharedEventListener_create(void *obj) {
    struct unixcall_generic_obj_ret *params = obj;
    params->ret = 0;
    IRWindowsMetalListener *value = [[IRWindowsMetalListener alloc] init];
    if (!value) return IR_EVENT_NO_MEMORY;
    value->listener = [[MTLSharedEventListener alloc] init];
    value->pending = [[NSMutableArray alloc] init];
    value->owner = ios_jit_current_peb(); value->epoch = ir_windows_session_epoch();
    pthread_mutex_lock(&ir_event_lock);
    if (!ir_event_listeners) ir_event_listeners = [[NSMutableDictionary alloc] init];
    if (ir_event_listeners && value->listener && value->pending && ir_event_identifier != UINT64_MAX) {
        value->identifier = ++ir_event_identifier;
        NSNumber *key = [[NSNumber alloc] initWithUnsignedLongLong:value->identifier];
        [ir_event_listeners setObject:value forKey:key];
        [key release];
        params->ret = value->identifier;
    }
    pthread_mutex_unlock(&ir_event_lock);
    [value release];
    return params->ret ? STATUS_SUCCESS : IR_EVENT_NO_MEMORY;
}

static void ir_event_finish(void *pointer) {
    IRWindowsMetalListener *value = pointer;
    pthread_mutex_lock(&ir_event_lock);
    value->stopped = true;
    CFRunLoopRef loop = value->loop; CFRunLoopSourceRef source = value->source;
    value->loop = NULL; value->source = NULL;
    [value->pending removeAllObjects];
    pthread_mutex_unlock(&ir_event_lock);
    if (source) { CFRunLoopRemoveSource(loop, source, kCFRunLoopCommonModes); CFRelease(source); }
    if (loop) CFRelease(loop);
    [value release];
}

static NTSTATUS _SharedEventListener_start(void *obj) {
    struct unixcall_generic_obj_noret *params = obj;
    pthread_mutex_lock(&ir_event_lock);
    IRWindowsMetalListener *value = ir_event_find(params->handle);
    bool active = value && !value->stopped && !value->started && value->owner == ios_jit_current_peb();
    if (active) { [value retain]; value->started = true; }
    pthread_mutex_unlock(&ir_event_lock);
    if (!active) return STATUS_SUCCESS;
    pthread_cleanup_push(ir_event_finish, value);
    pthread_mutex_lock(&ir_event_lock);
    if (!value->stopped) {
        value->loop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
        CFRunLoopSourceContext context = {0};
        value->source = CFRunLoopSourceCreate(NULL, 0, &context);
        if (value->source) {
            CFRunLoopAddSource(value->loop, value->source, kCFRunLoopCommonModes);
            for (NSValue *saved in value->pending) {
                void *event; [saved getValue:&event size:sizeof(event)];
                ir_event_schedule(value, event);
            }
        } else value->stopped = true;
        [value->pending removeAllObjects];
    }
    active = !value->stopped;
    pthread_mutex_unlock(&ir_event_lock);
    while (active) {
        // A stop before the first run must not strand the guest thread in CFRunLoopRun.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        pthread_mutex_lock(&ir_event_lock); active = !value->stopped; pthread_mutex_unlock(&ir_event_lock);
    }
    pthread_cleanup_pop(1);
    return STATUS_SUCCESS;
}

static NTSTATUS _SharedEventListener_destroy(void *obj) {
    struct unixcall_generic_obj_noret *params = obj;
    pthread_mutex_lock(&ir_event_lock);
    IRWindowsMetalListener *value = ir_event_find(params->handle);
    if (value && value->owner == ios_jit_current_peb()) {
        [value retain]; ir_event_stop(value); ir_event_remove(value);
    } else value = nil;
    pthread_mutex_unlock(&ir_event_lock);
    [value release];
    return STATUS_SUCCESS;
}

static NTSTATUS _MTLSharedEvent_setWin32EventAtValue(void *obj) {
    struct unixcall_mtlsharedevent_setevent *params = obj;
    pthread_mutex_lock(&ir_event_lock);
    IRWindowsMetalListener *value = ir_event_find(params->shared_event_listener);
    if (value && !value->stopped && value->owner == ios_jit_current_peb()) [value retain];
    else value = nil;
    pthread_mutex_unlock(&ir_event_lock);
    if (!value) return IR_EVENT_INVALID_HANDLE;
    uint64_t identifier = value->identifier;
    void *event = (void *)params->event_handle;
    [(id<MTLSharedEvent>)params->shared_event notifyListener:value->listener atValue:params->value
        block:^(id<MTLSharedEvent> unused_event, uint64_t unused_value) {
            (void)unused_event; (void)unused_value;
            ir_event_notify(identifier, event);
        }];
    [value release];
    return STATUS_SUCCESS;
}
