/*
 * wineios.drv bridge contract
 */

#ifndef __WINE_IOSDRV_H
#define __WINE_IOSDRV_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef BOOL
typedef int BOOL;
#endif

#ifndef TRUE
#define TRUE 1
#define FALSE 0
#endif

#define IRIDIUM_WINE_IOS_BRIDGE_CONFIG_ENV "IRIDIUM_WINE_IOS_BRIDGE_CONFIG"
#define IRIDIUM_WINE_IOS_GRAPHICS_DRIVER_ENV "IRIDIUM_WINE_IOS_GRAPHICS_DRIVER"
#define IRIDIUM_WINE_IOS_AUDIO_DRIVER_ENV "IRIDIUM_WINE_IOS_AUDIO_DRIVER"
#define IRIDIUM_WINE_IOS_SURFACE_ID_ENV "IRIDIUM_WINE_IOS_SURFACE_ID"
#define IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH_ENV "IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH"
#define IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH_ENV "IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH"
#define IRIDIUM_WINE_IOS_AUDIO_STATE_PATH_ENV "IRIDIUM_WINE_IOS_AUDIO_STATE_PATH"
#define IRIDIUM_WINE_IOS_TRACE_PATH_ENV "IRIDIUM_WINE_IOS_TRACE_PATH"
#define IRIDIUM_WINE_IOS_SURFACE_WIDTH_ENV "IRIDIUM_WINE_IOS_SURFACE_WIDTH"
#define IRIDIUM_WINE_IOS_SURFACE_HEIGHT_ENV "IRIDIUM_WINE_IOS_SURFACE_HEIGHT"

static inline void wineiosdrv_trace(const char *format, ...)
{
    const char *path = getenv(IRIDIUM_WINE_IOS_TRACE_PATH_ENV);
    FILE *file;
    va_list args;

    if (!path || !path[0] || !format) return;
    file = fopen(path, "a");
    if (!file) return;

    va_start(args, format);
    vfprintf(file, format, args);
    va_end(args);
    fputc('\n', file);
    fclose(file);
}

struct wineios_bridge_configuration
{
    char bridge_config_path[1024];
    char session_identifier[128];
    char surface_identifier[128];
    char framebuffer_path[1024];
    char input_events_path[1024];
    char audio_state_path[1024];
    char trace_path[1024];
    char graphics_driver[64];
    char audio_driver[64];
    char graphics_stack[64];
    unsigned int surface_width;
    unsigned int surface_height;
    BOOL fullscreen_only;
};

struct wineios_playable_session_contract
{
    const char *bridge_config_path;
    const char *graphics_driver;
    const char *audio_driver;
    const char *graphics_stack;
    const char *surface_identifier;
    const char *framebuffer_path;
    const char *input_events_path;
    const char *audio_state_path;
    unsigned int surface_width;
    unsigned int surface_height;
    BOOL fullscreen_only;
};

struct wineios_framebuffer_surface
{
    char path[1024];
    unsigned int width;
    unsigned int height;
};

struct opengl_funcs;
struct opengl_driver_funcs;

struct wineios_input_event
{
    uint64_t sequence;
    char type[32];
    char phase[32];
    uint64_t identifier;
    double x;
    double y;
    double value;
    char name[64];
};

int wineiosdrv_load_bridge_configuration(
    struct wineios_bridge_configuration *configuration,
    char *error_buffer,
    size_t error_buffer_size);
int wineiosdrv_open_framebuffer_surface(
    const struct wineios_bridge_configuration *configuration,
    struct wineios_framebuffer_surface *surface,
    char *error_buffer,
    size_t error_buffer_size);
int wineiosdrv_present_frame(
    const struct wineios_framebuffer_surface *surface,
    const void *pixels,
    size_t pixel_bytes,
    unsigned int width,
    unsigned int height,
    char *error_buffer,
    size_t error_buffer_size);
int wineiosdrv_read_framebuffer_pixel(
    const struct wineios_framebuffer_surface *surface,
    unsigned int x,
    unsigned int y,
    uint32_t *pixel,
    char *error_buffer,
    size_t error_buffer_size);
int wineiosdrv_poll_input_event(
    const struct wineios_bridge_configuration *configuration,
    size_t *cursor,
    struct wineios_input_event *event,
    char *error_buffer,
    size_t error_buffer_size);
int wineiosdrv_translate_virtual_key(
    const struct wineios_input_event *event,
    unsigned int *virtual_key);

extern const struct wineios_playable_session_contract *wineiosdrv_get_playable_session_contract(void);
extern unsigned int wineiosdrv_OpenGLInit(
    unsigned int version,
    const struct opengl_funcs *opengl_funcs,
    const struct opengl_driver_funcs **driver_funcs);

#ifdef __cplusplus
}
#endif

#endif
