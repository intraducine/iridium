/*
 * wineios.drv bridge configuration helpers
 */

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "iosdrv.h"

static void write_error(char *buffer, size_t buffer_size, const char *message)
{
    if (!buffer || !buffer_size) return;
    if (!message) message = "";
    strncpy(buffer, message, buffer_size - 1);
    buffer[buffer_size - 1] = '\0';
}

static void copy_string(char *buffer, size_t buffer_size, const char *value)
{
    if (!buffer || !buffer_size) return;
    if (!value) value = "";
    strncpy(buffer, value, buffer_size - 1);
    buffer[buffer_size - 1] = '\0';
}

static char *read_text_file(const char *path)
{
    FILE *file;
    long length;
    size_t read_length;
    char *buffer;

    if (!path || !path[0]) return NULL;

    file = fopen(path, "rb");
    if (!file) return NULL;
    if (fseek(file, 0, SEEK_END) != 0)
    {
        fclose(file);
        return NULL;
    }
    length = ftell(file);
    if (length < 0)
    {
        fclose(file);
        return NULL;
    }
    if (fseek(file, 0, SEEK_SET) != 0)
    {
        fclose(file);
        return NULL;
    }

    buffer = malloc((size_t)length + 1);
    if (!buffer)
    {
        fclose(file);
        return NULL;
    }

    read_length = fread(buffer, 1, (size_t)length, file);
    fclose(file);
    if (read_length != (size_t)length)
    {
        free(buffer);
        return NULL;
    }

    buffer[length] = '\0';
    return buffer;
}

static int extract_json_string(const char *json, const char *key, char *buffer, size_t buffer_size)
{
    char needle[96];
    const char *start;
    const char *end;
    size_t length;

    if (!json || !key || !buffer || !buffer_size) return 1;
    snprintf(needle, sizeof(needle), "\"%s\"", key);

    start = strstr(json, needle);
    if (!start) return 1;
    start = strchr(start + strlen(needle), ':');
    if (!start) return 1;
    start++;
    while (*start == ' ' || *start == '\t' || *start == '\n' || *start == '\r') start++;
    if (*start != '"') return 1;
    start++;
    end = strchr(start, '"');
    if (!end) return 1;

    length = (size_t)(end - start);
    if (length >= buffer_size) length = buffer_size - 1;
    memcpy(buffer, start, length);
    buffer[length] = '\0';
    return 0;
}

static int extract_json_uint(const char *json, const char *key, unsigned int *value)
{
    char needle[96];
    const char *start;
    char *end;
    unsigned long parsed;

    if (!json || !key || !value) return 1;
    snprintf(needle, sizeof(needle), "\"%s\"", key);

    start = strstr(json, needle);
    if (!start) return 1;
    start = strchr(start + strlen(needle), ':');
    if (!start) return 1;
    start++;
    while (*start == ' ' || *start == '\t' || *start == '\n' || *start == '\r') start++;

    parsed = strtoul(start, &end, 10);
    if (end == start) return 1;
    *value = (unsigned int)parsed;
    return 0;
}

static void apply_env_string(const char *key, char *buffer, size_t buffer_size)
{
    const char *value = getenv(key);
    if (value && value[0]) copy_string(buffer, buffer_size, value);
}

static void apply_env_uint(const char *key, unsigned int *value)
{
    const char *text = getenv(key);
    char *end;
    unsigned long parsed;

    if (!text || !text[0] || !value) return;
    parsed = strtoul(text, &end, 10);
    if (end != text && *end == '\0') *value = (unsigned int)parsed;
}

static void append_config_trace(const struct wineios_bridge_configuration *configuration)
{
    FILE *file;

    if (!configuration || !configuration->trace_path[0]) return;
    file = fopen(configuration->trace_path, "a");
    if (!file) return;

    fprintf(
        file,
        "bridge-config-loaded session=%s framebuffer=%s size=%ux%u driver=%s config=%s\n",
        configuration->session_identifier,
        configuration->framebuffer_path,
        configuration->surface_width,
        configuration->surface_height,
        configuration->graphics_driver,
        configuration->bridge_config_path);
    fclose(file);
}

int wineiosdrv_load_bridge_configuration(
    struct wineios_bridge_configuration *configuration,
    char *error_buffer,
    size_t error_buffer_size)
{
    const char *bridge_config_path;
    char *json = NULL;

    if (!configuration)
    {
        write_error(error_buffer, error_buffer_size, "missing configuration storage");
        return 1;
    }

    memset(configuration, 0, sizeof(*configuration));
    configuration->fullscreen_only = TRUE;
    copy_string(configuration->graphics_driver, sizeof(configuration->graphics_driver), "wineios.drv");
    copy_string(configuration->audio_driver, sizeof(configuration->audio_driver), "winecoreaudio.drv");
    copy_string(configuration->graphics_stack, sizeof(configuration->graphics_stack), "metalOpenGLFallback");

    bridge_config_path = getenv(IRIDIUM_WINE_IOS_BRIDGE_CONFIG_ENV);
    if (bridge_config_path && bridge_config_path[0])
    {
        copy_string(configuration->bridge_config_path, sizeof(configuration->bridge_config_path), bridge_config_path);
        json = read_text_file(bridge_config_path);
        if (!json)
        {
            write_error(error_buffer, error_buffer_size, "failed to read playable-session bridge config");
            return 1;
        }

        extract_json_string(json, "sessionIdentifier", configuration->session_identifier, sizeof(configuration->session_identifier));
        extract_json_string(json, "surfaceIdentifier", configuration->surface_identifier, sizeof(configuration->surface_identifier));
        extract_json_string(json, "framebufferPath", configuration->framebuffer_path, sizeof(configuration->framebuffer_path));
        extract_json_string(json, "inputEventsPath", configuration->input_events_path, sizeof(configuration->input_events_path));
        extract_json_string(json, "audioStatePath", configuration->audio_state_path, sizeof(configuration->audio_state_path));
        extract_json_string(json, "tracePath", configuration->trace_path, sizeof(configuration->trace_path));
        extract_json_string(json, "graphicsDriver", configuration->graphics_driver, sizeof(configuration->graphics_driver));
        extract_json_string(json, "audioDriver", configuration->audio_driver, sizeof(configuration->audio_driver));
        extract_json_string(json, "graphicsStack", configuration->graphics_stack, sizeof(configuration->graphics_stack));
        extract_json_uint(json, "surfaceWidth", &configuration->surface_width);
        extract_json_uint(json, "surfaceHeight", &configuration->surface_height);
        configuration->fullscreen_only = strstr(json, "\"fullscreenOnly\": true") != NULL;
    }

    apply_env_string(IRIDIUM_WINE_IOS_GRAPHICS_DRIVER_ENV, configuration->graphics_driver, sizeof(configuration->graphics_driver));
    apply_env_string(IRIDIUM_WINE_IOS_AUDIO_DRIVER_ENV, configuration->audio_driver, sizeof(configuration->audio_driver));
    apply_env_string(IRIDIUM_WINE_IOS_SURFACE_ID_ENV, configuration->surface_identifier, sizeof(configuration->surface_identifier));
    apply_env_string(IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH_ENV, configuration->framebuffer_path, sizeof(configuration->framebuffer_path));
    apply_env_string(IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH_ENV, configuration->input_events_path, sizeof(configuration->input_events_path));
    apply_env_string(IRIDIUM_WINE_IOS_AUDIO_STATE_PATH_ENV, configuration->audio_state_path, sizeof(configuration->audio_state_path));
    apply_env_string(IRIDIUM_WINE_IOS_TRACE_PATH_ENV, configuration->trace_path, sizeof(configuration->trace_path));
    apply_env_uint(IRIDIUM_WINE_IOS_SURFACE_WIDTH_ENV, &configuration->surface_width);
    apply_env_uint(IRIDIUM_WINE_IOS_SURFACE_HEIGHT_ENV, &configuration->surface_height);

    if (json) free(json);

    if (!configuration->session_identifier[0]
        || !configuration->surface_identifier[0]
        || !configuration->framebuffer_path[0]
        || !configuration->input_events_path[0]
        || !configuration->audio_state_path[0]
        || configuration->surface_width == 0
        || configuration->surface_height == 0)
    {
        write_error(error_buffer, error_buffer_size, "playable-session bridge config is incomplete");
        return 1;
    }

    write_error(error_buffer, error_buffer_size, "");
    append_config_trace(configuration);
    return 0;
}
