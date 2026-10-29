// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    const char *name;
    const char *format;
    const char *code;
    bool enabled;
} IRCheat;

static inline bool ir_cheats_valid(const IRCheat *items, size_t count) {
    if (count > 64 || (count && !items)) return false;
    size_t bytes = 0;
    for (size_t i = 0; i < count; ++i) {
        if (!items[i].name || !items[i].format || !items[i].code) return false;
        size_t name = strnlen(items[i].name, 128), format = strnlen(items[i].format, 32), code = strnlen(items[i].code, 8193);
        if (!name || name == 128 || !format || format == 32 || !code || code > 8192) return false;
        for (size_t j = 0; j < name; ++j)
            if ((unsigned char)items[i].name[j] < 32 || items[i].name[j] == 127) return false;
        bytes += name + format + code;
        if (bytes > 65536) return false;
    }
    return true;
}

static inline bool ir_cheat_pair(const char *line, uint32_t *first, uint32_t *second) {
    uint32_t words[2] = {0, 0};
    for (unsigned word = 0; word < 2; ++word) {
        while (*line == ' ' || *line == '\t') ++line;
        if (line[0] == '0' && (line[1] == 'x' || line[1] == 'X')) line += 2;
        for (unsigned digit = 0; digit < 8; ++digit) {
            unsigned char c = (unsigned char)*line++;
            unsigned value = c >= '0' && c <= '9' ? c - '0' : c >= 'A' && c <= 'F' ? c - 'A' + 10 : c >= 'a' && c <= 'f' ? c - 'a' + 10 : 16;
            if (value == 16) return false;
            words[word] = (words[word] << 4) | value;
        }
        if (!word && *line != ' ' && *line != '\t') return false;
    }
    while (*line == ' ' || *line == '\t' || *line == '\r') ++line;
    if (*line) return false;
    *first = words[0]; *second = words[1]; return true;
}

#if defined(__OBJC__) && defined(__cplusplus)
#import <Foundation/Foundation.h>
#include <vector>
static inline bool ir_cheats_decode(id value, std::vector<IRCheat>& items) {
    if (![value isKindOfClass:NSArray.class] || [value count] > 64) return false;
    for (id record in value) {
        if (![record isKindOfClass:NSDictionary.class]) return false;
        for (NSString *key in @[@"name", @"format", @"code"])
            if (![record[key] isKindOfClass:NSString.class] || [record[key] rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound) return false;
        if (![record[@"enabled"] isKindOfClass:NSNumber.class]) return false;
        items.push_back({[record[@"name"] UTF8String], [record[@"format"] UTF8String], [record[@"code"] UTF8String], [record[@"enabled"] boolValue]});
    }
    return ir_cheats_valid(items.data(), items.size());
}
#endif
