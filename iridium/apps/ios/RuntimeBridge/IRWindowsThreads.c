// SPDX-License-Identifier: AGPL-3.0-only
#include "IRWindowsThreads.h"
#include <errno.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdlib.h>

struct guest_thread {
    struct guest_thread *next;
    uint64_t generation;
    mach_port_t port;
    void *(*start)(void *);
    void *argument;
};
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct guest_thread *threads;
static uint64_t generation, baseline;
static bool captured;

static void *guest_start(void *argument) {
    struct guest_thread *thread = argument;
    void *(*start)(void *) = thread->start;
    void *value = thread->argument;
    mach_port_t port = mach_thread_self();
    pthread_mutex_lock(&lock);
    thread->port = port;
    pthread_mutex_unlock(&lock);
    return start(value);
}

int ir_windows_pthread_create(pthread_t *thread, const pthread_attr_t *attributes,
                             void *(*start)(void *), void *argument) {
    struct guest_thread *entry = calloc(1, sizeof(*entry));
    if (!entry) return ENOMEM;
    entry->start = start; entry->argument = argument;
    pthread_mutex_lock(&lock);
    if (generation == UINT64_MAX) { pthread_mutex_unlock(&lock); free(entry); return EAGAIN; }
    entry->generation = ++generation;
    entry->next = threads; threads = entry;
    pthread_mutex_unlock(&lock);
    int result = pthread_create(thread, attributes, guest_start, entry);
    if (result) {
        pthread_mutex_lock(&lock);
        struct guest_thread **cursor = &threads;
        while (*cursor != entry) cursor = &(*cursor)->next;
        *cursor = entry->next;
        pthread_mutex_unlock(&lock);
        free(entry);
    }
    return result;
}

static bool prune(void) {
    struct guest_thread **cursor = &threads;
    while (*cursor) {
        struct guest_thread *entry = *cursor;
        if (entry->port != MACH_PORT_NULL) {
            mach_port_type_t type = 0;
            if (mach_port_type(mach_task_self(), entry->port, &type) != KERN_SUCCESS) return false;
            // A dead send right proves the kernel thread ended, including TLS destructors.
            if (type & MACH_PORT_TYPE_DEAD_NAME) {
                mach_port_deallocate(mach_task_self(), entry->port);
                *cursor = entry->next; free(entry); continue;
            }
        }
        cursor = &entry->next;
    }
    return true;
}
static bool drained(void) {
    for (struct guest_thread *entry = threads; entry; entry = entry->next)
        if (entry->generation > baseline) return false;
    return true;
}
bool ir_windows_threads_begin(void) {
    pthread_mutex_lock(&lock);
    bool valid = prune() && (!captured || drained());
    if (valid) { baseline = generation; captured = true; }
    pthread_mutex_unlock(&lock);
    return valid;
}
bool ir_windows_threads_drained(void) {
    pthread_mutex_lock(&lock);
    bool valid = captured && prune() && drained();
    pthread_mutex_unlock(&lock);
    return valid;
}
