// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static constexpr size_t irStateLimit = 512 * 1024 * 1024;
static int irStateFolder(const char *directory) {
    if (!directory || directory[0] != '/' || strlen(directory) >= PATH_MAX) return -1;
    char path[PATH_MAX];
    if (!realpath(directory, path)) return -1;
    // Foundation can remove /private from Apple's /var and /tmp aliases.
    bool systemAlias = (!strncmp(directory, "/var/", 5) || !strncmp(directory, "/tmp/", 5)) &&
        !strncmp(path, "/private", 8) && !strcmp(path + 8, directory);
    if (strcmp(path, directory) && !systemAlias) return -1;
    // iOS permits the app container, but not reads of its filesystem ancestors.
    for (NSString *root in @[NSHomeDirectory(), NSTemporaryDirectory()]) {
        char base[PATH_MAX];
        if (!realpath(root.fileSystemRepresentation, base)) continue;
        size_t length = strlen(base);
        if (length <= 1 || strncmp(path, base, length) || (path[length] && path[length] != '/')) continue;
        int folder = open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        char *cursor = nullptr;
        for (char *name = strtok_r(path + length, "/", &cursor); name && folder >= 0; name = strtok_r(nullptr, "/", &cursor)) {
            int next = strcmp(name, ".") && strcmp(name, "..") ?
                openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) : -1;
            close(folder); folder = next;
        }
        return folder;
    }
    return -1;
}
static bool irStateTransfer(int fd, void *bytes, size_t count, bool writing) {
    char *cursor = (char *)bytes;
    while (count) {
        ssize_t n = writing ? write(fd, cursor, count) : read(fd, cursor, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        cursor += n; count -= (size_t)n;
    }
    return true;
}
static NSData *irStateRead(const char *directory, unsigned slot, NSString *identity, NSString *gameID = nil) {
    NSUUID *game = gameID ? [[NSUUID alloc] initWithUUIDString:gameID] : nil;
    if (slot >= 5 || (gameID && !game)) return nil;
    int folder = irStateFolder(directory);
    if (folder < 0) return nil;
    NSString *name = game ? [NSString stringWithFormat:@"%@-state-%u.bin", game.UUIDString, slot] : [NSString stringWithFormat:@"state-%u.bin", slot];
    int fd = openat(folder, name.UTF8String, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); close(folder);
    if (fd < 0) return nil;
    struct stat status;
    NSData *prefix = [[@"IridiumState1\n" stringByAppendingFormat:@"%@\n", identity] dataUsingEncoding:NSUTF8StringEncoding];
    bool valid = !fstat(fd, &status) && S_ISREG(status.st_mode) && status.st_nlink == 1 &&
        status.st_size > (off_t)prefix.length && status.st_size <= (off_t)(irStateLimit + prefix.length);
    NSMutableData *header = valid ? [NSMutableData dataWithLength:prefix.length] : nil;
    valid = valid && irStateTransfer(fd, header.mutableBytes, header.length, false) && [header isEqualToData:prefix];
    NSMutableData *data = valid ? [NSMutableData dataWithLength:(NSUInteger)status.st_size - prefix.length] : nil;
    valid = valid && data && irStateTransfer(fd, data.mutableBytes, data.length, false);
    close(fd); return valid ? data : nil;
}
static bool irStateWrite(const char *directory, unsigned slot, NSString *identity, NSData *data, NSString *gameID = nil) {
    NSUUID *game = gameID ? [[NSUUID alloc] initWithUUIDString:gameID] : nil;
    if (slot >= 5 || !data.length || data.length > irStateLimit || (gameID && !game)) return false;
    int folder = irStateFolder(directory);
    if (folder < 0) return false;
    NSString *name = game ? [NSString stringWithFormat:@"%@-state-%u.bin", game.UUIDString, slot] : [NSString stringWithFormat:@"state-%u.bin", slot];
    NSString *temporary = [@".state-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(folder, temporary.UTF8String, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    NSData *prefix = [[@"IridiumState1\n" stringByAppendingFormat:@"%@\n", identity] dataUsingEncoding:NSUTF8StringEncoding];
    bool success = fd >= 0 && irStateTransfer(fd, (void *)prefix.bytes, prefix.length, true) &&
        irStateTransfer(fd, (void *)data.bytes, data.length, true) && !fsync(fd);
    if (fd >= 0 && close(fd)) success = false;
    if (success) success = !renameat(folder, temporary.UTF8String, folder, name.UTF8String);
    if (success) fsync(folder);
    else unlinkat(folder, temporary.UTF8String, 0);
    close(folder); return success;
}
