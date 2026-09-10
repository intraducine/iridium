/*
 * wineios.drv framebuffer bridge helpers
 */

#if 0
#pragma makedep unix
#endif

#include <stdio.h>
#include <string.h>
#ifdef __WINE_PE_BUILD
#include <io.h>
#else
#include <sys/types.h>
#include <unistd.h>
#endif

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
    size_t length;

    if (!buffer || !buffer_size) return;
    if (!value) value = "";
    length = strlen(value);
    if (length >= buffer_size) length = buffer_size - 1;
    memcpy(buffer, value, length);
    buffer[length] = '\0';
}

static int ensure_file_size(FILE *file, size_t size)
{
    if (!file) return 1;
#ifdef __WINE_PE_BUILD
    return _chsize_s(_fileno(file), size) == 0 ? 0 : 1;
#else
    return ftruncate(fileno(file), (off_t)size) == 0 ? 0 : 1;
#endif
}

static int frame_ready_path(
    const struct wineios_framebuffer_surface *surface,
    char *path,
    size_t path_size)
{
    int length;

    if (!surface || !surface->path[0] || !path || !path_size) return 1;
    length = snprintf(path, path_size, "%s.ready", surface->path);
    return length < 0 || (size_t)length >= path_size;
}

static int mark_frame_ready(
    const struct wineios_framebuffer_surface *surface,
    char *error_buffer,
    size_t error_buffer_size)
{
    char path[sizeof(surface->path) + 7];
    FILE *file;

    if (frame_ready_path(surface, path, sizeof(path)))
    {
        write_error(error_buffer, error_buffer_size, "frame-ready marker path is too long");
        return 1;
    }
    file = fopen(path, "wb");
    if (!file)
    {
        write_error(error_buffer, error_buffer_size, "failed to create frame-ready marker");
        return 1;
    }
    if (fwrite("ready\n", 1, 6, file) != 6 || fflush(file) != 0)
    {
        fclose(file);
        write_error(error_buffer, error_buffer_size, "failed to write frame-ready marker");
        return 1;
    }
    fclose(file);
    return 0;
}

int wineiosdrv_open_framebuffer_surface(
    const struct wineios_bridge_configuration *configuration,
    struct wineios_framebuffer_surface *surface,
    char *error_buffer,
    size_t error_buffer_size)
{
    FILE *file;
    size_t expected_bytes;

    if (!configuration || !surface || !configuration->framebuffer_path[0]
        || configuration->surface_width == 0 || configuration->surface_height == 0)
    {
        write_error(error_buffer, error_buffer_size, "missing framebuffer surface configuration");
        return 1;
    }

    expected_bytes = (size_t)configuration->surface_width * configuration->surface_height * 4;
    file = fopen(configuration->framebuffer_path, "rb+");
    if (!file) file = fopen(configuration->framebuffer_path, "wb+");
    if (!file)
    {
        write_error(error_buffer, error_buffer_size, "failed to open framebuffer bridge file");
        return 1;
    }

    if (ensure_file_size(file, expected_bytes) != 0)
    {
        fclose(file);
        write_error(error_buffer, error_buffer_size, "failed to size framebuffer bridge file");
        return 1;
    }

    fclose(file);
    memset(surface, 0, sizeof(*surface));
    copy_string(surface->path, sizeof(surface->path), configuration->framebuffer_path);
    surface->width = configuration->surface_width;
    surface->height = configuration->surface_height;
    write_error(error_buffer, error_buffer_size, "");
    return 0;
}

int wineiosdrv_present_frame(
    const struct wineios_framebuffer_surface *surface,
    const void *pixels,
    size_t pixel_bytes,
    unsigned int width,
    unsigned int height,
    char *error_buffer,
    size_t error_buffer_size)
{
    FILE *file;
    size_t expected_bytes;

    if (!surface || !pixels || !surface->path[0])
    {
        write_error(error_buffer, error_buffer_size, "missing framebuffer presentation target");
        return 1;
    }

    if (width != surface->width || height != surface->height)
    {
        write_error(error_buffer, error_buffer_size, "frame dimensions do not match the playable surface");
        return 1;
    }

    expected_bytes = (size_t)surface->width * surface->height * 4;
    if (pixel_bytes != expected_bytes)
    {
        write_error(error_buffer, error_buffer_size, "frame payload size does not match the playable surface");
        return 1;
    }

    file = fopen(surface->path, "rb+");
    if (!file)
    {
        write_error(error_buffer, error_buffer_size, "failed to open framebuffer bridge file");
        return 1;
    }

    if (fwrite(pixels, 1, pixel_bytes, file) != pixel_bytes)
    {
        fclose(file);
        write_error(error_buffer, error_buffer_size, "failed to write framebuffer bridge file");
        return 1;
    }

    if (fflush(file) != 0)
    {
        fclose(file);
        write_error(error_buffer, error_buffer_size, "failed to flush framebuffer bridge file");
        return 1;
    }
    if (fclose(file) != 0)
    {
        write_error(error_buffer, error_buffer_size, "failed to flush framebuffer bridge file");
        return 1;
    }
    if (mark_frame_ready(surface, error_buffer, error_buffer_size)) return 1;
    write_error(error_buffer, error_buffer_size, "");
    return 0;
}

int wineiosdrv_read_framebuffer_pixel(
    const struct wineios_framebuffer_surface *surface,
    unsigned int x,
    unsigned int y,
    uint32_t *pixel,
    char *error_buffer,
    size_t error_buffer_size)
{
    FILE *file;
    long offset;

    if (!surface || !pixel || !surface->path[0] || x >= surface->width || y >= surface->height)
    {
        write_error(error_buffer, error_buffer_size, "invalid framebuffer readback request");
        return 1;
    }

    file = fopen(surface->path, "rb");
    if (!file)
    {
        write_error(error_buffer, error_buffer_size, "failed to open framebuffer bridge file");
        return 1;
    }

    offset = (long)(((size_t)y * surface->width + x) * 4);
    if (fseek(file, offset, SEEK_SET) != 0 || fread(pixel, sizeof(*pixel), 1, file) != 1)
    {
        fclose(file);
        write_error(error_buffer, error_buffer_size, "failed to read framebuffer bridge file");
        return 1;
    }

    fclose(file);
    write_error(error_buffer, error_buffer_size, "");
    return 0;
}
