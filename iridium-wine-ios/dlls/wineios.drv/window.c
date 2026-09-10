/*
 * wineios.drv fullscreen framebuffer presentation
 */

#if 0
#pragma makedep unix
#endif

#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "wingdi.h"
#include "winuser.h"
#include "iosdrv.h"
#include "unixlib.h"
#include "wine/gdi_driver.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(iosdrv);

struct wineios_window_surface
{
    struct window_surface header;
    struct wineios_bridge_configuration configuration;
    struct wineios_framebuffer_surface framebuffer;
    unsigned int source_width;
    unsigned int source_height;
    unsigned int presented_frames;
    unsigned int failed_frames;
    unsigned char *scaled_pixels;
    size_t scaled_pixel_bytes;
};

static inline struct wineios_window_surface *wineios_surface_from_window_surface(
    struct window_surface *surface)
{
    return (struct wineios_window_surface *)surface;
}

static inline int dib_stride(int width, int bpp)
{
    return ((width * bpp + 31) >> 3) & ~3;
}

static inline int dib_image_size(const BITMAPINFO *info)
{
    return dib_stride(info->bmiHeader.biWidth, info->bmiHeader.biBitCount)
        * abs(info->bmiHeader.biHeight);
}

static void copy_env_string(char *buffer, size_t buffer_size, const char *name)
{
    const char *value = getenv(name);
    size_t length;

    if (!buffer || !buffer_size) return;
    if (!value) value = "";
    length = min(strlen(value), buffer_size - 1);
    memcpy(buffer, value, length);
    buffer[length] = '\0';
}

static BOOL wineios_load_bridge_configuration(struct wineios_bridge_configuration *configuration)
{
    const char *width;
    const char *height;

    memset(configuration, 0, sizeof(*configuration));
    copy_env_string(configuration->surface_identifier, sizeof(configuration->surface_identifier),
                    IRIDIUM_WINE_IOS_SURFACE_ID_ENV);
    copy_env_string(configuration->framebuffer_path, sizeof(configuration->framebuffer_path),
                    IRIDIUM_WINE_IOS_FRAMEBUFFER_PATH_ENV);
    copy_env_string(configuration->input_events_path, sizeof(configuration->input_events_path),
                    IRIDIUM_WINE_IOS_INPUT_EVENTS_PATH_ENV);
    copy_env_string(configuration->audio_state_path, sizeof(configuration->audio_state_path),
                    IRIDIUM_WINE_IOS_AUDIO_STATE_PATH_ENV);
    copy_env_string(configuration->trace_path, sizeof(configuration->trace_path),
                    IRIDIUM_WINE_IOS_TRACE_PATH_ENV);
    copy_env_string(configuration->graphics_driver, sizeof(configuration->graphics_driver),
                    IRIDIUM_WINE_IOS_GRAPHICS_DRIVER_ENV);

    width = getenv(IRIDIUM_WINE_IOS_SURFACE_WIDTH_ENV);
    height = getenv(IRIDIUM_WINE_IOS_SURFACE_HEIGHT_ENV);
    configuration->surface_width = width ? (unsigned int)strtoul(width, NULL, 10) : 0;
    configuration->surface_height = height ? (unsigned int)strtoul(height, NULL, 10) : 0;
    configuration->fullscreen_only = TRUE;

    if (!configuration->framebuffer_path[0] || !configuration->surface_width || !configuration->surface_height)
    {
        wineiosdrv_trace("window configuration missing framebuffer=%s width=%u height=%u",
                         configuration->framebuffer_path,
                         configuration->surface_width,
                         configuration->surface_height);
        return FALSE;
    }
    wineiosdrv_trace("window configuration loaded surface=%s framebuffer=%s size=%ux%u",
                     configuration->surface_identifier,
                     configuration->framebuffer_path,
                     configuration->surface_width,
                     configuration->surface_height);
    return TRUE;
}

static BOOL wineios_open_framebuffer_surface(
    const struct wineios_bridge_configuration *configuration,
    struct wineios_framebuffer_surface *surface)
{
    char error[256];

    if (wineiosdrv_open_framebuffer_surface(configuration, surface, error, sizeof(error)))
    {
        wineiosdrv_trace("window framebuffer open failed path=%s error=%s",
                         configuration->framebuffer_path, error);
        return FALSE;
    }
    wineiosdrv_trace("window framebuffer opened path=%s size=%ux%u", surface->path, surface->width, surface->height);
    return TRUE;
}

static BOOL wineios_present_frame(
    const struct wineios_framebuffer_surface *surface,
    const void *pixels,
    size_t pixel_bytes)
{
    char error[256];

    if (wineiosdrv_present_frame(surface, pixels, pixel_bytes,
                                 surface->width, surface->height,
                                 error, sizeof(error)))
    {
        wineiosdrv_trace("window framebuffer present failed path=%s error=%s",
                         surface->path, error);
        return FALSE;
    }
    return TRUE;
}

static void wineios_surface_set_clip(struct window_surface *window_surface, const RECT *rects, UINT count)
{
    TRACE("surface=%p rects=%p count=%u\n", window_surface, rects, count);
}

static BOOL wineios_surface_ensure_scaled_buffer(struct wineios_window_surface *surface)
{
    size_t expected_bytes = (size_t)surface->framebuffer.width * surface->framebuffer.height * 4;

    if (surface->scaled_pixels && surface->scaled_pixel_bytes == expected_bytes) return TRUE;

    free(surface->scaled_pixels);
    surface->scaled_pixels = malloc(expected_bytes);
    surface->scaled_pixel_bytes = expected_bytes;
    return surface->scaled_pixels != NULL;
}

static void wineios_scale_bgra_frame(
    struct wineios_window_surface *surface,
    const BITMAPINFO *color_info,
    const void *color_bits)
{
    const unsigned int src_width = color_info->bmiHeader.biWidth;
    const unsigned int src_height = abs(color_info->bmiHeader.biHeight);
    const unsigned int dst_width = surface->framebuffer.width;
    const unsigned int dst_height = surface->framebuffer.height;
    const int src_stride = dib_stride(color_info->bmiHeader.biWidth, color_info->bmiHeader.biBitCount);
    const unsigned char *src_base = color_bits;
    unsigned int y;

    for (y = 0; y < dst_height; y++)
    {
        const unsigned int src_y = (unsigned int)(((uint64_t)y * src_height) / dst_height);
        const unsigned char *src_row;
        unsigned int x;

        if (color_info->bmiHeader.biHeight < 0)
            src_row = src_base + src_y * src_stride;
        else
            src_row = src_base + (src_height - 1 - src_y) * src_stride;

        for (x = 0; x < dst_width; x++)
        {
            const unsigned int src_x = (unsigned int)(((uint64_t)x * src_width) / dst_width);
            const unsigned char *src = src_row + src_x * 4;
            unsigned char *dst = surface->scaled_pixels + ((size_t)y * dst_width + x) * 4;

            dst[0] = src[0];
            dst[1] = src[1];
            dst[2] = src[2];
            dst[3] = 0xff;
        }
    }
}

static BOOL wineios_surface_flush(
    struct window_surface *window_surface,
    const RECT *rect,
    const RECT *dirty,
    const BITMAPINFO *color_info,
    const void *color_bits,
    BOOL shape_changed,
    const BITMAPINFO *shape_info,
    const void *shape_bits)
{
    struct wineios_window_surface *surface = wineios_surface_from_window_surface(window_surface);

    if (!color_info || !color_bits || color_info->bmiHeader.biBitCount != 32)
    {
        WARN("unsupported surface flush color_info=%p color_bits=%p bpp=%u\n",
             color_info, color_bits, color_info ? color_info->bmiHeader.biBitCount : 0);
        return TRUE;
    }

    if (!wineios_surface_ensure_scaled_buffer(surface))
    {
        WARN("failed to allocate scaled framebuffer buffer\n");
        return TRUE;
    }

    wineios_scale_bgra_frame(surface, color_info, color_bits);
    if (!wineios_present_frame(&surface->framebuffer, surface->scaled_pixels, surface->scaled_pixel_bytes))
    {
        surface->failed_frames++;
        if (surface->failed_frames <= 3 || surface->failed_frames % 60 == 0)
        {
            WARN("framebuffer present failed frame=%u path=%s bytes=%zu\n",
                 surface->failed_frames, debugstr_a(surface->framebuffer.path), surface->scaled_pixel_bytes);
            wineiosdrv_trace("window framebuffer present failed frame=%u path=%s bytes=%zu",
                             surface->failed_frames, surface->framebuffer.path, surface->scaled_pixel_bytes);
        }
        return TRUE;
    }

    surface->presented_frames++;
    if (surface->presented_frames <= 3 || surface->presented_frames % 60 == 0)
    {
        TRACE("presented framebuffer frame=%u hwnd=%p source=%ux%u target=%ux%u rect=%s dirty=%s shape=%u\n",
              surface->presented_frames,
              window_surface->hwnd,
              surface->source_width,
              surface->source_height,
              surface->framebuffer.width,
              surface->framebuffer.height,
              wine_dbgstr_rect(rect),
              wine_dbgstr_rect(dirty),
              shape_changed);
        wineiosdrv_trace("window framebuffer presented frame=%u source=%ux%u target=%ux%u path=%s",
                         surface->presented_frames,
                         surface->source_width,
                         surface->source_height,
                         surface->framebuffer.width,
                         surface->framebuffer.height,
                         surface->framebuffer.path);
    }

    return TRUE;
}

static void wineios_surface_destroy(struct window_surface *window_surface)
{
    struct wineios_window_surface *surface = wineios_surface_from_window_surface(window_surface);

    TRACE("surface=%p presented_frames=%u failed_frames=%u\n",
          surface, surface->presented_frames, surface->failed_frames);
    free(surface->scaled_pixels);
}

static const struct window_surface_funcs wineios_surface_funcs =
{
    wineios_surface_set_clip,
    wineios_surface_flush,
    wineios_surface_destroy,
};

static struct window_surface *wineios_create_surface(HWND hwnd, const RECT *rect)
{
    struct wineios_window_surface *surface;
    struct window_surface *window_surface;
    char buffer[FIELD_OFFSET(BITMAPINFO, bmiColors[256])];
    BITMAPINFO *info = (BITMAPINFO *)buffer;
    int width = rect->right - rect->left;
    int height = rect->bottom - rect->top;

    if (width <= 0 || height <= 0)
    {
        WARN("invalid surface rect %s\n", wine_dbgstr_rect(rect));
        return NULL;
    }

    memset(info, 0, sizeof(*info));
    info->bmiHeader.biSize = sizeof(info->bmiHeader);
    info->bmiHeader.biWidth = width;
    info->bmiHeader.biHeight = -height;
    info->bmiHeader.biPlanes = 1;
    info->bmiHeader.biBitCount = 32;
    info->bmiHeader.biSizeImage = dib_image_size(info);
    info->bmiHeader.biCompression = BI_RGB;

    if (!(window_surface = window_surface_create(sizeof(*surface), &wineios_surface_funcs, hwnd, rect, info, 0)))
        return NULL;

    surface = wineios_surface_from_window_surface(window_surface);
    surface->source_width = width;
    surface->source_height = height;

    if (!wineios_load_bridge_configuration(&surface->configuration))
    {
        WARN("missing bridge configuration for window surface\n");
        window_surface_release(window_surface);
        return NULL;
    }

    if (!wineios_open_framebuffer_surface(&surface->configuration, &surface->framebuffer))
    {
        WARN("failed to open framebuffer surface path=%s size=%ux%u\n",
             debugstr_a(surface->configuration.framebuffer_path),
             surface->configuration.surface_width,
             surface->configuration.surface_height);
        window_surface_release(window_surface);
        return NULL;
    }

    TRACE("created framebuffer window surface hwnd=%p source=%dx%d target=%ux%u path=%s\n",
          hwnd,
          width,
          height,
          surface->framebuffer.width,
          surface->framebuffer.height,
          debugstr_a(surface->framebuffer.path));
    wineiosdrv_trace("window surface created hwnd=%p source=%dx%d target=%ux%u path=%s",
                     hwnd,
                     width,
                     height,
                     surface->framebuffer.width,
                     surface->framebuffer.height,
                     surface->framebuffer.path);
    return window_surface;
}

static BOOL wineios_create_window_surface(
    HWND hwnd,
    BOOL layered,
    const RECT *surface_rect,
    struct window_surface **surface)
{
    struct window_surface *previous;

    TRACE("hwnd=%p layered=%u surface_rect=%s surface=%p\n",
          hwnd, layered, wine_dbgstr_rect(surface_rect), surface);

    if ((previous = *surface) && previous->funcs == &wineios_surface_funcs) return TRUE;
    if (previous) window_surface_release(previous);

    *surface = wineios_create_surface(hwnd, surface_rect);
    return TRUE;
}

static const struct user_driver_funcs wineios_driver_funcs =
{
    .pCreateWindowSurface = wineios_create_window_surface,
    .pOpenGLInit = wineiosdrv_OpenGLInit,
};

static NTSTATUS wineiosdrv_unix_init(void *arg)
{
    TRACE("registering wineios user driver\n");
    wineiosdrv_trace("registering wineios user driver");
    __wine_set_user_driver(&wineios_driver_funcs, WINE_GDI_DRIVER_VERSION);
    return STATUS_SUCCESS;
}

const unixlib_entry_t __wine_unix_call_funcs[] =
{
    wineiosdrv_unix_init,
};

const unixlib_entry_t __wine_unix_call_wow64_funcs[] =
{
    wineiosdrv_unix_init,
};
