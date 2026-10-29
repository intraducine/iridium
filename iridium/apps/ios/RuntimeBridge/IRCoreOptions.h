// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stddef.h>

typedef void (*IRCoreOptionVisitor)(void *context, const char *key, const char *title,
    const char *info, const char *category, const char *value, const char *default_value,
    const char *const *values, const char *const *labels, size_t count, bool visible);

#ifdef IR_CORE_OPTIONS_IMPLEMENTATION
#include "libretro.h"
#include <stdlib.h>
#include <string.h>

typedef struct IROption {
    char *key, *title, *info, *category, *value, *default_value;
    char *values[RETRO_NUM_CORE_OPTION_VALUES_MAX], *labels[RETRO_NUM_CORE_OPTION_VALUES_MAX];
    size_t count;
    bool visible;
    struct IROption *next;
} IROption;
typedef struct { IROption *first; size_t count; bool changed; } IROptions;

static char *ir_option_copy(const char *value) {
    if (!value || strlen(value) > 8192) return NULL;
    return strdup(value);
}
static IROption *ir_option_find(IROptions *options, const char *key, bool create) {
    if (!key || !*key || strlen(key) > 256) return NULL;
    for (IROption *item = options->first; item; item = item->next)
        if (!strcmp(item->key, key)) return item;
    if (!create || options->count >= 512) return NULL;
    IROption *item = (IROption *)calloc(1, sizeof *item);
    if (!item || !(item->key = ir_option_copy(key))) { free(item); return NULL; }
    item->visible = true; item->next = options->first; options->first = item; ++options->count;
    return item;
}
static bool ir_option_contains(const IROption *item, const char *value) {
    if (!value) return false;
    for (size_t i = 0; i < item->count; ++i)
        if (!strcmp(item->values[i], value)) return true;
    return false;
}
static bool ir_option_set(IROptions *options, const char *key, const char *value, bool seed) {
    IROption *item = ir_option_find(options, key, seed);
    if (!item || !value || (!seed && !ir_option_contains(item, value))) return false;
    if (item->value && !strcmp(item->value, value)) return true;
    char *copy = ir_option_copy(value);
    if (!copy) return false;
    free(item->value); item->value = copy; options->changed = true; return true;
}
static void ir_options_clear(IROptions *options) {
    IROption *item = options->first;
    while (item) {
        IROption *next = item->next;
        free(item->key); free(item->title); free(item->info); free(item->category);
        free(item->value); free(item->default_value);
        for (size_t i = 0; i < item->count; ++i) { free(item->values[i]); free(item->labels[i]); }
        free(item); item = next;
    }
    memset(options, 0, sizeof *options);
}
static void ir_option_define(IROptions *options, const char *key, const char *title,
    const char *info, const char *category, const struct retro_core_option_value *values,
    const char *default_value) {
    IROption *item = ir_option_find(options, key, true);
    if (!item) return;
    free(item->title); item->title = ir_option_copy(title ? title : key);
    free(item->info); item->info = ir_option_copy(info ? info : "");
    free(item->category); item->category = ir_option_copy(category ? category : "");
    free(item->default_value); item->default_value = NULL;
    for (size_t i = 0; i < item->count; ++i) { free(item->values[i]); free(item->labels[i]); }
    item->count = 0;
    for (size_t i = 0; values && i < RETRO_NUM_CORE_OPTION_VALUES_MAX && values[i].value; ++i) {
        char *value = ir_option_copy(values[i].value);
        char *label = ir_option_copy(values[i].label ? values[i].label : values[i].value);
        if (!value || !label) { free(value); free(label); break; }
        item->values[item->count] = value; item->labels[item->count++] = label;
    }
    if (!item->count) return;
    item->default_value = ir_option_copy(ir_option_contains(item, default_value) ? default_value : item->values[0]);
    if (!ir_option_contains(item, item->value)) ir_option_set(options, key, item->default_value, true);
}
static bool ir_options_environment(IROptions *options, unsigned command, void *data) {
    if (!data) return false;
    switch (command) {
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION: *(unsigned *)data = 2; return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL: {
        struct retro_core_options_v2_intl *v = (struct retro_core_options_v2_intl *)data;
        return v->us && ir_options_environment(options, RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2, v->us);
    }
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2: {
        struct retro_core_options_v2 *v = (struct retro_core_options_v2 *)data;
        for (struct retro_core_option_v2_definition *i = v->definitions; i && i->key; ++i)
            ir_option_define(options, i->key, i->desc, i->info, i->category_key, i->values, i->default_value);
        return true;
    }
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL: {
        struct retro_core_options_intl *v = (struct retro_core_options_intl *)data;
        return v->us && ir_options_environment(options, RETRO_ENVIRONMENT_SET_CORE_OPTIONS, v->us);
    }
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
        for (struct retro_core_option_definition *i = (struct retro_core_option_definition *)data; i && i->key; ++i)
            ir_option_define(options, i->key, i->desc, i->info, NULL, i->values, i->default_value);
        return true;
    case RETRO_ENVIRONMENT_SET_VARIABLES:
        for (struct retro_variable *i = (struct retro_variable *)data; i && i->key; ++i) {
            char *text = ir_option_copy(i->value);
            if (!text) continue;
            char *choices = strstr(text, "; ");
            if (choices) {
                *choices = 0; choices += 2;
                struct retro_core_option_value values[RETRO_NUM_CORE_OPTION_VALUES_MAX] = {0};
                size_t count = 0; char *cursor = NULL;
                for (char *value = strtok_r(choices, "|", &cursor); value && count + 1 < RETRO_NUM_CORE_OPTION_VALUES_MAX; value = strtok_r(NULL, "|", &cursor))
                    values[count++].value = value;
                ir_option_define(options, i->key, text, NULL, NULL, values, count ? values[0].value : NULL);
            }
            free(text);
        }
        return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        struct retro_variable *v = (struct retro_variable *)data;
        IROption *item = ir_option_find(options, v->key, false);
        v->value = item ? item->value : NULL; return v->value != NULL;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        *(bool *)data = options->changed; options->changed = false; return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY: {
        struct retro_core_option_display *v = (struct retro_core_option_display *)data;
        IROption *item = ir_option_find(options, v->key, false);
        if (item) item->visible = v->visible;
        return item != NULL;
    }
    default: return false;
    }
}
static void ir_options_visit(IROptions *options, IRCoreOptionVisitor visitor, void *context) {
    if (!visitor) return;
    for (IROption *item = options->first; item; item = item->next)
        if (item->count && item->value && item->default_value) visitor(context, item->key,
            item->title ? item->title : item->key, item->info ? item->info : "", item->category ? item->category : "",
            item->value, item->default_value, (const char *const *)item->values,
            (const char *const *)item->labels, item->count, item->visible);
}
#endif
