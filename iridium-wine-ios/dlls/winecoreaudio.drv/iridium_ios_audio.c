/*
 * iPhone audio bridge helpers for winecoreaudio.drv
 */

#pragma makedep unix

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "iridium_ios_audio.h"

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

int iridium_ios_audio_read_state(
    const char *path,
    struct iridium_ios_audio_state *state,
    char *error_buffer,
    size_t error_buffer_size)
{
    FILE *file;
    char line[256];

    if (!path || !path[0] || !state)
    {
        write_error(error_buffer, error_buffer_size, "missing iPhone audio state path");
        return 1;
    }

    file = fopen(path, "rb");
    if (!file)
    {
        write_error(error_buffer, error_buffer_size, "failed to open iPhone audio state file");
        return 1;
    }

    memset(state, 0, sizeof(*state));
    while (fgets(line, sizeof(line), file))
    {
        char *value = strchr(line, '=');
        if (!value) continue;
        *value++ = '\0';
        value[strcspn(value, "\r\n")] = '\0';

        if (!strcmp(line, "sessionActive")) state->session_active = atoi(value);
        else if (!strcmp(line, "interrupted")) state->interrupted = atoi(value);
        else if (!strcmp(line, "category")) copy_string(state->category, sizeof(state->category), value);
    }

    fclose(file);
    write_error(error_buffer, error_buffer_size, "");
    return 0;
}

int iridium_ios_audio_render_ready(char *error_buffer, size_t error_buffer_size)
{
    const char *path = getenv("IRIDIUM_WINE_IOS_AUDIO_STATE_PATH");
    struct iridium_ios_audio_state state;

    if (!path || !path[0])
    {
        write_error(error_buffer, error_buffer_size, "");
        return 0;
    }

    if (iridium_ios_audio_read_state(path, &state, error_buffer, error_buffer_size) != 0)
        return 1;

    if (!state.session_active)
    {
        write_error(error_buffer, error_buffer_size, "iPhone playback session is not active");
        return 1;
    }
    if (state.interrupted)
    {
        write_error(error_buffer, error_buffer_size, "iPhone playback session is interrupted");
        return 1;
    }

    write_error(error_buffer, error_buffer_size, "");
    return 0;
}
