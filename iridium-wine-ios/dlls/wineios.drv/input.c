/*
 * wineios.drv input bridge helpers
 */

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "iosdrv.h"

#define VK_TAB 0x09
#define VK_RETURN 0x0D
#define VK_ESCAPE 0x1B
#define VK_SPACE 0x20
#define VK_LEFT 0x25
#define VK_UP 0x26
#define VK_RIGHT 0x27
#define VK_DOWN 0x28

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

static int split_fields(char *line, char **fields, size_t count)
{
    size_t index = 0;
    char *cursor = line;

    while (index < count)
    {
        fields[index++] = cursor;
        cursor = strchr(cursor, ',');
        if (!cursor) break;
        *cursor = '\0';
        cursor++;
    }

    return index == count ? 0 : 1;
}

static int translate_named_virtual_key(const char *name, unsigned int *virtual_key)
{
    if (!name || !name[0] || !virtual_key) return 1;

    if (!strcmp(name, "ArrowUp") || !strcmp(name, "dpadUp")) *virtual_key = VK_UP;
    else if (!strcmp(name, "ArrowDown") || !strcmp(name, "dpadDown")) *virtual_key = VK_DOWN;
    else if (!strcmp(name, "ArrowLeft") || !strcmp(name, "dpadLeft")) *virtual_key = VK_LEFT;
    else if (!strcmp(name, "ArrowRight") || !strcmp(name, "dpadRight")) *virtual_key = VK_RIGHT;
    else if (!strcmp(name, "Return") || !strcmp(name, "buttonA") || !strcmp(name, "\r")) *virtual_key = VK_RETURN;
    else if (!strcmp(name, "Escape") || !strcmp(name, "buttonB")) *virtual_key = VK_ESCAPE;
    else if (!strcmp(name, " ") || !strcmp(name, "buttonX") || !strcmp(name, "rightShoulder")) *virtual_key = VK_SPACE;
    else if (!strcmp(name, "leftShoulder")) *virtual_key = VK_TAB;
    else if (name[1] == '\0') *virtual_key = (unsigned int)toupper((unsigned char)name[0]);
    else return 1;

    return 0;
}

int wineiosdrv_poll_input_event(
    const struct wineios_bridge_configuration *configuration,
    size_t *cursor,
    struct wineios_input_event *event,
    char *error_buffer,
    size_t error_buffer_size)
{
    FILE *file;
    long next_cursor;
    char line[512];
    char *fields[8] = {0};

    if (!configuration || !cursor || !event || !configuration->input_events_path[0])
    {
        write_error(error_buffer, error_buffer_size, "missing input bridge configuration");
        return 1;
    }

    file = fopen(configuration->input_events_path, "rb");
    if (!file)
    {
        write_error(error_buffer, error_buffer_size, "failed to open input bridge file");
        return 1;
    }

    if (fseek(file, (long)*cursor, SEEK_SET) != 0)
    {
        fclose(file);
        write_error(error_buffer, error_buffer_size, "failed to seek input bridge file");
        return 1;
    }

    if (!fgets(line, sizeof(line), file))
    {
        fclose(file);
        write_error(error_buffer, error_buffer_size, "");
        return 1;
    }

    next_cursor = ftell(file);
    fclose(file);
    if (next_cursor >= 0) *cursor = (size_t)next_cursor;

    line[strcspn(line, "\r\n")] = '\0';
    if (split_fields(line, fields, 8) != 0)
    {
        write_error(error_buffer, error_buffer_size, "failed to parse input bridge event");
        return 1;
    }

    memset(event, 0, sizeof(*event));
    event->sequence = strtoull(fields[0], NULL, 10);
    copy_string(event->type, sizeof(event->type), fields[1]);
    copy_string(event->phase, sizeof(event->phase), fields[2]);
    event->identifier = strtoull(fields[3], NULL, 10);
    event->x = fields[4][0] ? strtod(fields[4], NULL) : 0.0;
    event->y = fields[5][0] ? strtod(fields[5], NULL) : 0.0;
    event->value = fields[6][0] ? strtod(fields[6], NULL) : 0.0;
    copy_string(event->name, sizeof(event->name), fields[7]);
    write_error(error_buffer, error_buffer_size, "");
    return 0;
}

int wineiosdrv_translate_virtual_key(
    const struct wineios_input_event *event,
    unsigned int *virtual_key)
{
    if (!event || !virtual_key) return 1;
    if (strcmp(event->type, "keyboard") && strcmp(event->type, "controllerButton")) return 1;
    return translate_named_virtual_key(event->name, virtual_key);
}