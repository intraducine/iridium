// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <pthread.h>
int ir_windows_pthread_create(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
bool ir_windows_threads_begin(void);
bool ir_windows_threads_drained(void);
