// SPDX-License-Identifier: AGPL-3.0-only
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include <atomic>
#include <libkern/OSCacheControl.h>
#include "IRPhase3.h"
#include "IRJITExecutionProbe.h"

extern "C" {
int iridium_melonx_install_firmware(const char *root, const char *frameworks, const char *file);
int iridium_melonx_initialize(const char *root, const char *frameworks, void (*diagnostic)(const char *));
int iridium_melonx_run(const char *game, void *layer,
    uint8_t (*allocate)(size_t, void **, void **), uint8_t (*release)(void *, size_t),
    void (*frame)(void), void (*input)(void), int resolution, unsigned flags);
void iridium_melonx_set_state(uint8_t stop, uint8_t pause, float volume);
void *attach_gamepad(const char *, void *, int, int);
void set_gamepad_button_state(void *, int, uint8_t);
void set_gamepad_stick_axis(void *, int, float, float);
}

@interface IRMeloNXView : UIView
@end
@implementation IRMeloNXView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

@interface IRMeloNXPlayer : UIViewController {
@public
    NSString *game, *root, *frameworks;
    uint64_t generation;
    IRPhase3Event event;
    IRPhase3Poll poll;
    const IRJITMemoryAPI *memory;
    std::atomic<uint64_t> frames;
    IRMeloNXView *surface;
    CFTimeInterval lastVideoReport;
    uint64_t lastReportedFrame;
    void *pad;
    bool started, ended, paused, stopping;
    float volume;
    int resolution;
    unsigned options;
}
- (void)finish:(int)status enteredRuntime:(BOOL)entered;
@end

// MeloNX keeps executable signal handlers and its translation cache until exit.
static IRMeloNXPlayer *player;
enum : unsigned { Docked = 1, DisableVSync = 2, ShaderCache = 4, DisableTextureRecompression = 8 };
static void diagnostic(const char *message) {
    if (message) player->event(player->generation, 0, message);
}
static uint8_t allocate(size_t bytes, void **rx, void **rw) {
    return player->memory->allocate(bytes, rx, rw);
}
static uint8_t release(void *rx, size_t bytes) {
    return player->memory->release(rx, bytes);
}

static bool probe(const IRJITMemoryAPI *memory) {
    const uint32_t code[] = {0xd2800540, 0xd65f03c0}; // return 42
    void *rx = nullptr, *rw = nullptr;
    if (!memory->allocate(sizeof code, &rx, &rw)) return false;
    memcpy(rw, code, sizeof code);
    sys_icache_invalidate(rx, sizeof code);
    bool executed = ir_jit_probe_execute(rx, sizeof code, 42);
    return memory->release(rx, sizeof code) && executed;
}

static void frame() {
    IRMeloNXPlayer *session = player;
    uint64_t count = session->frames.fetch_add(1) + 1;
    CFTimeInterval now = CACurrentMediaTime();
    if (count == 1) {
        session->lastVideoReport = now;
        session->lastReportedFrame = count;
        session->event(session->generation, 1, "MeloNX submitted its first Vulkan frame.");
    } else if (now - session->lastVideoReport >= 5) {
        double elapsed = now - session->lastVideoReport;
        char line[128];
        snprintf(line, sizeof line, "MeloNX video submissions=%llu submit_fps=%.1f",
            (unsigned long long)count, (count - session->lastReportedFrame) / elapsed);
        session->lastVideoReport = now;
        session->lastReportedFrame = count;
        session->event(session->generation, 11, line);
    }
}

static void input() {
    IRMeloNXPlayer *session = player;
    if (!session->pad) return;
    IRPhase3Input sample{};
    session->poll(&sample);
    // Iridium uses the libretro order. MeloNX expects NativeGamepad.ButtonMapping indices.
    static const int buttons[] = {1, 3, 4, 6, 11, 12, 13, 14, 0, 2, 9, 10, 15, 16, 7, 8};
    for (unsigned i = 0; i < sizeof buttons / sizeof buttons[0]; ++i)
        set_gamepad_button_state(session->pad, buttons[i], (sample.buttons >> i) & 1);
    set_gamepad_stick_axis(session->pad, 1, sample.left_x / 32768.f, -sample.left_y / 32768.f);
    set_gamepad_stick_axis(session->pad, 2, sample.right_x / 32768.f, -sample.right_y / 32768.f);
}

@implementation IRMeloNXPlayer
- (void)loadView {
    self.view = [[UIView alloc] init];
    self.view.backgroundColor = UIColor.blackColor;
    surface = [[IRMeloNXView alloc] init];
    CAMetalLayer *layer = (CAMetalLayer *)surface.layer;
    layer.device = MTLCreateSystemDefaultDevice();
    layer.framebufferOnly = NO;
    // UIKit can move or scale the view without changing the live swapchain extent.
    layer.drawableSize = CGSizeMake(1280, 720);
    [self.view addSubview:surface];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat width = MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds) * (16.0 / 9.0));
    if (width <= 0) return;
    CGFloat height = width * (9.0 / 16.0);
    surface.frame = CGRectMake(CGRectGetMidX(bounds) - width / 2, CGRectGetMidY(bounds) - height / 2, width, height);
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (started || ended || !memory) return;
    started = true;
    CAMetalLayer *layer = (CAMetalLayer *)surface.layer;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int status = -2;
        BOOL entered = NO;
        if (probe(self->memory)) {
            entered = YES;
            self->event(self->generation, 5, "MeloNX verified shared executable memory.");
            self->event(self->generation, 0, "Starting MeloNX.");
            status = iridium_melonx_initialize(self->root.fileSystemRepresentation, self->frameworks.fileSystemRepresentation, diagnostic);
            if (status == 0) {
                // A nonzero opaque token is required by the upstream virtual pad.
                self->pad = attach_gamepad("Iridium", (void *)1, 0, 1);
                if (self->pad)
                    status = iridium_melonx_run(self->game.fileSystemRepresentation, (__bridge void *)layer,
                        allocate, release, frame, input, self->resolution, self->options);
                else {
                    diagnostic("MeloNX could not attach its virtual controller.");
                    status = -5;
                }
            } else {
                status = -5;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self finish:status enteredRuntime:entered]; });
    });
}
- (void)finish:(int)status enteredRuntime:(BOOL)entered {
    if (ended) return;
    ended = true;
    if (status == -4) {
        event(generation, 9, "MeloNX could not close safely. Reopen Iridium.");
        return;
    }
    if (status && !stopping) {
        const char *message;
        switch (status) {
        case -2: message = "MeloNX could not prepare shared JIT."; break;
        case -5: message = "MeloNX initialization failed. See the console log."; break;
        case -6: message = "Import prod.keys and any required title.keys from your Switch."; break;
        case -7: message = "This file has no bootable Switch game. Import the base game file."; break;
        case -8: message = "MeloNX could not decrypt this game. Check your key files against the game dump."; break;
        case -9: message = "Install a firmware ZIP from your Switch."; break;
        default: message = "MeloNX could not run this game. Check its files and required Switch system data."; break;
        }
        event(generation, status == -6 || status == -8 || status == -9 ? 12 : 3, message);
    } else if (!stopping && frames.load() == 0) {
        event(generation, 3, "MeloNX exited before producing video.");
    }
    event(generation, 2, entered ? "MeloNX stopped. Reopen Iridium before starting another game." : "MeloNX launch ended.");
    // Cancellation or a failed probe before initialization leaves no resident core.
    if (!entered) player = nil;
}
@end

extern "C" unsigned ir_native_engine_abi() { return 1; }
extern "C" void *ir_native_engine_create(const char *, const char *, const char *game, const char *,
    const char *assets, bool jit, uint64_t generation, IRPhase3Event event, IRPhase3Poll poll) {
    if (player || !jit) return nullptr;
    IRMeloNXPlayer *session = [[IRMeloNXPlayer alloc] init];
    session->game = [NSString stringWithUTF8String:game];
    session->root = [NSString stringWithUTF8String:assets];
    session->frameworks = NSBundle.mainBundle.privateFrameworksPath;
    if (!session->game || !session->root || !session->frameworks) return nullptr;
    session->generation = generation;
    session->event = event;
    session->poll = poll;
    session->volume = 1;
    session->resolution = 1;
    player = session;
    return (__bridge_retained void *)session;
}

extern "C" bool ir_phase3_core_prepare_memory(const IRJITMemoryAPI *api) {
    if (!player || !api || api->version != 1 || api->size < sizeof *api || !api->allocate || !api->release)
        return false;
    player->memory = api;
    return true;
}
extern "C" void ir_native_engine_pause(bool pause) {
    if (!player || player->ended) return;
    player->paused = pause;
    iridium_melonx_set_state(player->stopping, pause, player->volume);
}
extern "C" void ir_native_engine_stop() {
    if (!player || player->ended) return;
    player->stopping = true;
    if (!player->started) [player finish:0 enteredRuntime:NO];
    else iridium_melonx_set_state(1, 0, player->volume);
}
extern "C" void ir_native_engine_set_volume(float volume) {
    if (!player || player->ended) return;
    player->volume = volume;
    iridium_melonx_set_state(player->stopping, player->paused, volume);
}
extern "C" uint64_t ir_native_engine_frames() { return player ? player->frames.load() : 0; }

extern "C" bool ir_native_engine_command(const char *json) {
    if (!player || player->started || !json || strlen(json) > 16384) return false;
    NSData *data = [NSData dataWithBytes:json length:strlen(json)];
    id request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class] || ![request[@"operation"] isEqual:@"configure"]) return false;
    id values = request[@"values"];
    if (![values isKindOfClass:NSDictionary.class]) return false;
    id resolution = values[@"melonx_resolution"];
    player->resolution = [resolution isEqual:@"3"] ? 3 : [resolution isEqual:@"2"] ? 2 : 1;
    player->options = ([values[@"melonx_mode"] isEqual:@"docked"] ? Docked : 0)
        | ([values[@"melonx_vsync"] isEqual:@"off"] ? DisableVSync : 0)
        | ([values[@"melonx_shader_cache"] isEqual:@"on"] ? ShaderCache : 0)
        | ([values[@"melonx_texture_recompression"] isEqual:@"off"] ? DisableTextureRecompression : 0);
    return true;
}

extern "C" int ir_melonx_install_firmware(const char *system, const char *frameworks, const char *file) {
    if (player) return 1;
    return iridium_melonx_install_firmware(system, frameworks, file);
}
