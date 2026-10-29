// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#import <Foundation/Foundation.h>
#include "IRCameraSource.h"
// The pinned Flycast header predates Libretro's version-1 microphone extension.
typedef struct { unsigned rate; } IRMicrophoneParams;
typedef struct {
    unsigned version;
    void *(*open)(const IRMicrophoneParams *);
    void (*close)(void *);
    bool (*params)(const void *, IRMicrophoneParams *);
    bool (*setState)(void *, bool);
    bool (*getState)(const void *);
    int (*read)(void *, int16_t *, size_t);
} IRMicrophoneInterface;

@interface IRCoreCapture : NSObject
@property(atomic,copy) NSString *status;
- (void)configureCamera:(unsigned)camera microphone:(bool)microphone;
- (void)suspend:(bool)suspended;
- (void)requestCamera:(unsigned)camera active:(bool)active;
- (bool)readCamera:(uint32_t *)pixels capacity:(size_t)capacity width:(unsigned *)width height:(unsigned *)height;
- (void)requestMicrophone:(bool)active;
- (bool)microphoneActive;
- (int)readMicrophone:(int16_t *)samples count:(size_t)count;
- (void)close;
@end
