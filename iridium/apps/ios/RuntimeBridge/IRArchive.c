// SPDX-License-Identifier: AGPL-3.0-only
#include "IRArchive.h"
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

// Public libarchive ABI. Apple ships the library but omits its SDK headers.
// https://github.com/libarchive/libarchive/blob/v3.7.7/libarchive/archive.h
struct archive;
struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_format_zip(struct archive *);
extern int archive_read_support_format_7zip(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_free(struct archive *);
extern const char *archive_entry_pathname_utf8(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);

static int entry_file(int root, const char *name, int directory) {
    if (!name || !*name || name[0] == '/' || strlen(name) >= 1024 || strchr(name, '\\') || strchr(name, ':')) return -1;
    char *path = strdup(name);
    if (!path) return -1;
    int parent = dup(root), result = -1;
    char *cursor = path, *component;
    while ((component = strsep(&cursor, "/"))) {
        if (!*component || !strcmp(component, ".")) continue;
        if (!strcmp(component, "..")) goto done;
        for (const unsigned char *c = (const unsigned char *)component; *c; ++c) if (*c < 32 || *c == 127) goto done;
        if (cursor || directory) {
            if (mkdirat(parent, component, 0700) && errno != EEXIST) goto done;
            int next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (next < 0) goto done;
            close(parent); parent = next;
        } else {
            result = openat(parent, component, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            goto done;
        }
    }
    if (directory) { result = parent; parent = -1; }
done:
    if (parent >= 0) close(parent);
    free(path);
    return result;
}

int ir_archive_extract(const char *source, const char *destination, uint64_t maximum_bytes,
                       unsigned maximum_entries, int (*cancelled)(void *), void *context) {
    int root = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) return 4;
    struct archive *reader = archive_read_new();
    if (!reader) { close(root); return 4; }
    int result = 1, status;
    uint64_t total = 0;
    unsigned count = 0;
    archive_read_support_format_zip(reader);
    archive_read_support_format_7zip(reader);
    if (archive_read_open_filename(reader, source, 64 * 1024) != 0) goto done;
    struct archive_entry *entry;
    while ((status = archive_read_next_header(reader, &entry)) == 0) {
        if (cancelled && cancelled(context)) { result = 3; goto done; }
        if (++count > maximum_entries) { result = 2; goto done; }
        mode_t kind = archive_entry_filetype(entry);
        int64_t size = archive_entry_size(entry);
        if ((kind != S_IFREG && kind != S_IFDIR) || archive_entry_symlink(entry) || archive_entry_hardlink(entry)) goto done;
        if (size < 0 || (uint64_t)size > maximum_bytes - total) { result = 2; goto done; }
        int output = entry_file(root, archive_entry_pathname_utf8(entry), kind == S_IFDIR);
        if (output < 0) goto done;
        unsigned char buffer[64 * 1024];
        uint64_t written = 0;
        ssize_t bytes;
        while ((bytes = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
            if (cancelled && cancelled(context)) { close(output); result = 3; goto done; }
            if ((uint64_t)bytes > maximum_bytes - total || (uint64_t)bytes > (uint64_t)size - written) {
                close(output); result = 2; goto done;
            }
            size_t offset = 0;
            while (offset < (size_t)bytes) {
                ssize_t n = write(output, buffer + offset, (size_t)bytes - offset);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) { close(output); result = 4; goto done; }
                offset += (size_t)n;
            }
            written += (uint64_t)bytes; total += (uint64_t)bytes;
        }
        if (close(output)) { result = 4; goto done; }
        if (bytes < 0 || (kind == S_IFREG && written != (uint64_t)size)) goto done;
    }
    if (status == 1 && count) result = 0; // ARCHIVE_EOF, never a partial archive.
done:
    archive_read_free(reader);
    close(root);
    return result;
}
