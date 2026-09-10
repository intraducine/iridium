/*
 * wineios.drv OpenGL framebuffer presentation
 */

#if 0
#pragma makedep unix
#endif

#include "config.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "winuser.h"
#include "iosdrv.h"
#include "wine/opengl_driver.h"
#include "wine/debug.h"

WINE_DEFAULT_DEBUG_CHANNEL(iosdrv);

struct wineios_opengl_drawable
{
    struct opengl_drawable base;
    struct wineios_bridge_configuration configuration;
    struct wineios_framebuffer_surface framebuffer;
    unsigned int presented_frames;
    unsigned int failed_frames;
    unsigned char *readback_rgba;
    unsigned char *present_bgra;
    size_t pixel_bytes;
};

static const struct egl_platform *wineios_egl;
static const struct opengl_funcs *wineios_gl;
static struct opengl_driver_funcs wineios_driver_funcs;

static const struct client_surface_funcs wineios_client_surface_funcs;
static const struct opengl_drawable_funcs wineios_drawable_funcs;

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

static BOOL wineios_load_opengl_bridge_configuration(struct wineios_bridge_configuration *configuration)
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
        wineiosdrv_trace("opengl configuration missing framebuffer=%s width=%u height=%u",
                         configuration->framebuffer_path,
                         configuration->surface_width,
                         configuration->surface_height);
        return FALSE;
    }
    wineiosdrv_trace("opengl configuration loaded surface=%s framebuffer=%s size=%ux%u",
                     configuration->surface_identifier,
                     configuration->framebuffer_path,
                     configuration->surface_width,
                     configuration->surface_height);
    return TRUE;
}

static BOOL wineios_open_opengl_framebuffer_surface(
    const struct wineios_bridge_configuration *configuration,
    struct wineios_framebuffer_surface *surface)
{
    FILE *file;
    size_t expected_bytes;
    size_t length;

    expected_bytes = (size_t)configuration->surface_width * configuration->surface_height * 4;
    file = fopen(configuration->framebuffer_path, "rb+");
    if (!file) file = fopen(configuration->framebuffer_path, "wb+");
    if (!file)
    {
        wineiosdrv_trace("opengl framebuffer open failed path=%s", configuration->framebuffer_path);
        return FALSE;
    }

    if (ftruncate(fileno(file), (off_t)expected_bytes) != 0)
    {
        fclose(file);
        wineiosdrv_trace("opengl framebuffer truncate failed path=%s bytes=%zu", configuration->framebuffer_path, expected_bytes);
        return FALSE;
    }

    fclose(file);
    memset(surface, 0, sizeof(*surface));
    length = min(strlen(configuration->framebuffer_path), sizeof(surface->path) - 1);
    memcpy(surface->path, configuration->framebuffer_path, length);
    surface->path[length] = '\0';
    surface->width = configuration->surface_width;
    surface->height = configuration->surface_height;
    wineiosdrv_trace("opengl framebuffer opened path=%s size=%ux%u", surface->path, surface->width, surface->height);
    return TRUE;
}

static BOOL wineios_present_opengl_frame(
    const struct wineios_framebuffer_surface *surface,
    const void *pixels,
    size_t pixel_bytes)
{
    FILE *file;
    size_t expected_bytes = (size_t)surface->width * surface->height * 4;

    if (!surface->path[0] || !pixels || pixel_bytes != expected_bytes)
    {
        wineiosdrv_trace(
            "opengl-framebuffer-write-failed frame=unknown path=%s bytes=%zu expected=%zu",
            surface->path,
            pixel_bytes,
            expected_bytes);
        return FALSE;
    }

    file = fopen(surface->path, "rb+");
    if (!file)
    {
        wineiosdrv_trace("opengl-framebuffer-write-failed frame=unknown path=%s reason=open", surface->path);
        return FALSE;
    }

    if (fwrite(pixels, 1, pixel_bytes, file) != pixel_bytes)
    {
        fclose(file);
        wineiosdrv_trace("opengl-framebuffer-write-failed frame=unknown path=%s reason=write", surface->path);
        return FALSE;
    }

    fflush(file);
    fclose(file);
    return TRUE;
}

static struct wineios_opengl_drawable *impl_from_opengl_drawable(struct opengl_drawable *base)
{
    return CONTAINING_RECORD(base, struct wineios_opengl_drawable, base);
}

static EGLConfig egl_config_for_format(int format)
{
    return wineios_egl->configs[(format - 1) % wineios_egl->config_count];
}

static BOOL wineios_ensure_readback_buffers(struct wineios_opengl_drawable *drawable)
{
    const size_t expected_bytes =
        (size_t)drawable->framebuffer.width * drawable->framebuffer.height * 4;

    if (drawable->readback_rgba && drawable->present_bgra
        && drawable->pixel_bytes == expected_bytes)
    {
        return TRUE;
    }

    free(drawable->readback_rgba);
    free(drawable->present_bgra);
    drawable->readback_rgba = malloc(expected_bytes);
    drawable->present_bgra = malloc(expected_bytes);
    drawable->pixel_bytes = expected_bytes;

    return drawable->readback_rgba && drawable->present_bgra;
}

static void wineios_convert_rgba_to_bgra_top_down(struct wineios_opengl_drawable *drawable)
{
    const unsigned int width = drawable->framebuffer.width;
    const unsigned int height = drawable->framebuffer.height;
    unsigned int y;

    for (y = 0; y < height; y++)
    {
        const unsigned char *src = drawable->readback_rgba + (size_t)(height - 1 - y) * width * 4;
        unsigned char *dst = drawable->present_bgra + (size_t)y * width * 4;
        unsigned int x;

        for (x = 0; x < width; x++)
        {
            dst[x * 4 + 0] = src[x * 4 + 2];
            dst[x * 4 + 1] = src[x * 4 + 1];
            dst[x * 4 + 2] = src[x * 4 + 0];
            dst[x * 4 + 3] = 0xff;
        }
    }
}

static BOOL wineios_present_current_gl_frame(struct wineios_opengl_drawable *drawable)
{
    if (!wineios_ensure_readback_buffers(drawable))
    {
        WARN("failed to allocate OpenGL readback buffers\n");
        wineiosdrv_trace("opengl-readback-failed reason=allocation size=%ux%u",
                         drawable->framebuffer.width,
                         drawable->framebuffer.height);
        return FALSE;
    }

    wineiosdrv_trace("opengl-readback-enter size=%ux%u",
                     drawable->framebuffer.width,
                     drawable->framebuffer.height);
    wineios_gl->p_glFinish();
    wineios_gl->p_glReadPixels(
        0,
        0,
        drawable->framebuffer.width,
        drawable->framebuffer.height,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        drawable->readback_rgba);
    wineiosdrv_trace("opengl-readback-complete bytes=%zu", drawable->pixel_bytes);
    wineios_convert_rgba_to_bgra_top_down(drawable);

    if (!wineios_present_opengl_frame(
            &drawable->framebuffer,
            drawable->present_bgra,
            drawable->pixel_bytes))
    {
        drawable->failed_frames++;
        if (drawable->failed_frames <= 3 || drawable->failed_frames % 60 == 0)
        {
            WARN("OpenGL framebuffer present failed frame=%u path=%s\n",
                 drawable->failed_frames,
                 debugstr_a(drawable->framebuffer.path));
            wineiosdrv_trace("opengl-framebuffer-write-failed frame=%u path=%s",
                             drawable->failed_frames,
                             drawable->framebuffer.path);
        }
        return FALSE;
    }

    drawable->presented_frames++;
    if (drawable->presented_frames <= 3 || drawable->presented_frames % 60 == 0)
    {
        TRACE("presented OpenGL framebuffer frame=%u drawable=%s size=%ux%u path=%s\n",
              drawable->presented_frames,
              debugstr_opengl_drawable(&drawable->base),
              drawable->framebuffer.width,
              drawable->framebuffer.height,
              debugstr_a(drawable->framebuffer.path));
        wineiosdrv_trace("opengl-framebuffer-write-complete frame=%u size=%ux%u path=%s",
                         drawable->presented_frames,
                         drawable->framebuffer.width,
                         drawable->framebuffer.height,
                         drawable->framebuffer.path);
    }
    return TRUE;
}

static void wineios_drawable_destroy(struct opengl_drawable *base)
{
    struct wineios_opengl_drawable *drawable = impl_from_opengl_drawable(base);

    TRACE("drawable=%s presented_frames=%u failed_frames=%u\n",
          debugstr_opengl_drawable(base),
          drawable->presented_frames,
          drawable->failed_frames);

    if (base->surface) wineios_gl->p_eglDestroySurface(wineios_egl->display, base->surface);
    free(drawable->readback_rgba);
    free(drawable->present_bgra);
}

static void wineios_drawable_flush(struct opengl_drawable *base, UINT flags)
{
    TRACE("drawable=%s flags=%#x\n", debugstr_opengl_drawable(base), flags);
    if (flags & GL_FLUSH_INTERVAL) wineios_gl->p_eglSwapInterval(wineios_egl->display, abs(base->interval));
    if (flags & (GL_FLUSH_PRESENT | GL_FLUSH_FORCE_SWAP | GL_FLUSH_FINISHED))
        wineios_present_current_gl_frame(impl_from_opengl_drawable(base));
}

static BOOL wineios_drawable_swap(struct opengl_drawable *base)
{
    struct wineios_opengl_drawable *drawable = impl_from_opengl_drawable(base);

    TRACE("drawable=%s surface=%p\n", debugstr_opengl_drawable(base), base->surface);
    wineiosdrv_trace("opengl-swap-enter drawable=%s", debugstr_opengl_drawable(base));
    wineios_present_current_gl_frame(drawable);
    wineios_gl->p_eglSwapBuffers(wineios_egl->display, base->surface);
    return TRUE;
}

static const struct opengl_drawable_funcs wineios_drawable_funcs =
{
    .destroy = wineios_drawable_destroy,
    .flush = wineios_drawable_flush,
    .swap = wineios_drawable_swap,
};

static void wineios_client_surface_destroy(struct client_surface *client)
{
    TRACE("%s\n", debugstr_client_surface(client));
}

static void wineios_client_surface_detach(struct client_surface *client)
{
}

static void wineios_client_surface_update(struct client_surface *client)
{
}

static void wineios_client_surface_present(struct client_surface *client, HDC hdc)
{
}

static const struct client_surface_funcs wineios_client_surface_funcs =
{
    .destroy = wineios_client_surface_destroy,
    .detach = wineios_client_surface_detach,
    .update = wineios_client_surface_update,
    .present = wineios_client_surface_present,
};

static BOOL wineios_surface_create(HWND hwnd, int format, struct opengl_drawable **drawable)
{
    struct wineios_opengl_drawable *wineios_drawable;
    struct client_surface *client;

    TRACE("hwnd=%p format=%d drawable=%p\n", hwnd, format, drawable);
    wineiosdrv_trace("opengl-surface-create-enter hwnd=%p format=%d", hwnd, format);

    if (*drawable)
    {
        (*drawable)->format = format;
        return TRUE;
    }

    if (!(client = client_surface_create(sizeof(*client), &wineios_client_surface_funcs, hwnd)))
        return FALSE;

    wineios_drawable = opengl_drawable_create(
        sizeof(*wineios_drawable),
        &wineios_drawable_funcs,
        format,
        client);
    client_surface_release(client);
    if (!wineios_drawable) return FALSE;

    if (!wineios_load_opengl_bridge_configuration(&wineios_drawable->configuration))
    {
        WARN("missing OpenGL bridge configuration\n");
        wineiosdrv_trace("opengl-surface-create-config-missing");
        opengl_drawable_release(&wineios_drawable->base);
        return FALSE;
    }

    if (!wineios_open_opengl_framebuffer_surface(
            &wineios_drawable->configuration,
            &wineios_drawable->framebuffer))
    {
        WARN("failed to open OpenGL framebuffer surface path=%s size=%ux%u\n",
             debugstr_a(wineios_drawable->configuration.framebuffer_path),
             wineios_drawable->configuration.surface_width,
             wineios_drawable->configuration.surface_height);
        wineiosdrv_trace("opengl-surface-create-framebuffer-open-failed path=%s size=%ux%u",
                         wineios_drawable->configuration.framebuffer_path,
                         wineios_drawable->configuration.surface_width,
                         wineios_drawable->configuration.surface_height);
        opengl_drawable_release(&wineios_drawable->base);
        return FALSE;
    }
    wineiosdrv_trace("opengl-surface-create-framebuffer-opened path=%s size=%ux%u",
                     wineios_drawable->framebuffer.path,
                     wineios_drawable->framebuffer.width,
                     wineios_drawable->framebuffer.height);

    {
        const int attribs[] =
        {
            EGL_WIDTH, wineios_drawable->framebuffer.width,
            EGL_HEIGHT, wineios_drawable->framebuffer.height,
            EGL_NONE
        };
        wineios_drawable->base.surface = wineios_gl->p_eglCreatePbufferSurface(
            wineios_egl->display,
            egl_config_for_format(format),
            attribs);
    }

    if (!wineios_drawable->base.surface)
    {
        WARN("failed to create OpenGL pbuffer surface for %ux%u\n",
             wineios_drawable->framebuffer.width,
             wineios_drawable->framebuffer.height);
        wineiosdrv_trace("opengl-surface-create-pbuffer-failed size=%ux%u",
                         wineios_drawable->framebuffer.width,
                         wineios_drawable->framebuffer.height);
        opengl_drawable_release(&wineios_drawable->base);
        return FALSE;
    }

    TRACE("created OpenGL framebuffer drawable=%s size=%ux%u path=%s\n",
          debugstr_opengl_drawable(&wineios_drawable->base),
          wineios_drawable->framebuffer.width,
          wineios_drawable->framebuffer.height,
          debugstr_a(wineios_drawable->framebuffer.path));
    wineiosdrv_trace("opengl drawable created size=%ux%u path=%s",
                     wineios_drawable->framebuffer.width,
                     wineios_drawable->framebuffer.height,
                     wineios_drawable->framebuffer.path);
    wineiosdrv_trace("opengl-surface-create-success size=%ux%u path=%s",
                     wineios_drawable->framebuffer.width,
                     wineios_drawable->framebuffer.height,
                     wineios_drawable->framebuffer.path);
    *drawable = &wineios_drawable->base;
    return TRUE;
}

static void wineios_init_egl_platform(struct egl_platform *platform)
{
    platform->native_display = EGL_DEFAULT_DISPLAY;
    wineios_egl = platform;
}

static void *wineios_get_proc_address(const char *name)
{
    return wineios_gl->p_eglGetProcAddress(name);
}

static const char *wineios_init_wgl_extensions(struct opengl_funcs *funcs)
{
    return "WGL_EXT_framebuffer_sRGB";
}

unsigned int wineiosdrv_OpenGLInit(
    unsigned int version,
    const struct opengl_funcs *opengl_funcs,
    const struct opengl_driver_funcs **driver_funcs)
{
    wineiosdrv_trace("opengl-init-enter version=%u egl=%s",
                     version,
                     opengl_funcs && opengl_funcs->egl_handle ? "present" : "missing");
    if (version != WINE_OPENGL_DRIVER_VERSION)
    {
        ERR("version mismatch, opengl32 wants %u but driver has %u\n",
            version,
            WINE_OPENGL_DRIVER_VERSION);
        wineiosdrv_trace("opengl init version mismatch requested=%u driver=%u", version, WINE_OPENGL_DRIVER_VERSION);
        return STATUS_INVALID_PARAMETER;
    }

    if (!opengl_funcs || !opengl_funcs->egl_handle)
    {
        WARN("OpenGL presentation unavailable because no EGL backend is loaded\n");
        wineiosdrv_trace("opengl-init-unavailable reason=no-egl-backend");
        return STATUS_NOT_SUPPORTED;
    }

    wineios_gl = opengl_funcs;
    memset(&wineios_driver_funcs, 0, sizeof(wineios_driver_funcs));
    wineios_driver_funcs.p_init_egl_platform = wineios_init_egl_platform;
    wineios_driver_funcs.p_get_proc_address = wineios_get_proc_address;
    wineios_driver_funcs.p_init_pixel_formats = (*driver_funcs)->p_init_pixel_formats;
    wineios_driver_funcs.p_describe_pixel_format = (*driver_funcs)->p_describe_pixel_format;
    wineios_driver_funcs.p_init_wgl_extensions = wineios_init_wgl_extensions;
    wineios_driver_funcs.p_surface_create = wineios_surface_create;
    wineios_driver_funcs.p_context_create = (*driver_funcs)->p_context_create;
    wineios_driver_funcs.p_context_destroy = (*driver_funcs)->p_context_destroy;
    wineios_driver_funcs.p_make_current = (*driver_funcs)->p_make_current;

    *driver_funcs = &wineios_driver_funcs;
    TRACE("registered wineios OpenGL framebuffer presentation driver\n");
    wineiosdrv_trace("opengl framebuffer presentation driver registered");
    wineiosdrv_trace("opengl-init-registered");
    return STATUS_SUCCESS;
}
