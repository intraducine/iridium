#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct iridium_ios_audio_state
{
    int session_active;
    int interrupted;
    char category[32];
};

int iridium_ios_audio_read_state(
    const char *path,
    struct iridium_ios_audio_state *state,
    char *error_buffer,
    size_t error_buffer_size);
int iridium_ios_audio_render_ready(char *error_buffer, size_t error_buffer_size);

#ifdef __cplusplus
}
#endif