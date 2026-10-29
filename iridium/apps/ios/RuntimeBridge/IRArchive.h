// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdint.h>
// The caller owns a new, empty staging directory and removes it on failure.
// 0: complete, 1: invalid archive/path, 2: limit, 3: cancelled, 4: file I/O.
int ir_archive_extract(const char *source, const char *destination,
                       uint64_t maximum_bytes, unsigned maximum_entries,
                       int (*cancelled)(void *), void *context);
