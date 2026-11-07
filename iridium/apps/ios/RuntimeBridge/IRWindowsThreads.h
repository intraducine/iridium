// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <pthread.h>
#define IR_WINDOWS_THREAD_SLOTS 1024
int ir_windows_thread_slot(void);
int ir_windows_pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
bool ir_windows_threads_begin(void);
bool ir_windows_threads_drained(void);
uint64_t ir_windows_session_epoch(void);
