// SPDX-License-Identifier: AGPL-3.0-only
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <map>
#include <mutex>
#include <signal.h>
#include <libkern/OSCacheControl.h>
#include "IRPhase3.h"
#include "IRJITExecutionProbe.h"

extern "C" {
int iridium_melonx_install_firmware(const char *root, const char *frameworks, const char *file);
int iridium_melonx_initialize(const char *root, const char *frameworks, void (*diagnostic)(const char *));
int iridium_melonx_run(const char *game, void *layer,
    uint8_t (*allocate)(size_t, void **, void **), uint8_t (*release)(void *, size_t),
    uint8_t (*jitReady)(void), void (*frame)(void), void (*input)(void), int resolution, unsigned flags);
uint8_t iridium_melonx_reset_session();
uint8_t iridium_melonx_session_closed();
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
    std::mutex controlLock;
    bool stateReady;
    float volume;
    int resolution;
    unsigned options;
}
- (void)finish:(int)status enteredRuntime:(BOOL)entered;
@end

static IRMeloNXPlayer *player;
// The core keeps the cache and generated fault handler across games.
static const IRJITMemoryAPI *hostMemory;
static std::mutex allocationLock;
static std::condition_variable allocationReleased;
static std::map<uintptr_t, size_t> liveAllocations, retainedAllocations;
static const int faultSignals[] = {SIGSEGV, SIGBUS};
struct FaultHandlers { struct sigaction actions[2]; };
// Fault handlers can outlive a handoff on another thread. Keep published snapshots immutable.
static FaultHandlers predecessors[8];
static unsigned predecessorCount;
static std::atomic<const FaultHandlers *> predecessor;
static_assert(decltype(predecessor)::is_always_lock_free);
static struct sigaction scopedFaults[2];
static void (*melonxFaultHandler)(int, siginfo_t *, void *);
enum : unsigned { Docked = 1, DisableVSync = 2, ShaderCache = 4, DisableTextureRecompression = 8 };
static void diagnostic(const char *message) {
    if (message) player->event(player->generation, 0, message);
}
static uint8_t allocate(size_t bytes, void **rx, void **rw) {
    std::lock_guard<std::mutex> lock(allocationLock);
    if (!hostMemory->allocate(bytes, rx, rw)) return false;
    try {
        liveAllocations.emplace(reinterpret_cast<uintptr_t>(*rx), bytes);
    } catch (...) {
        hostMemory->release(*rx, bytes);
        *rx = *rw = nullptr;
        return false;
    }
    return true;
}
static uint8_t release(void *rx, size_t bytes) {
    std::lock_guard<std::mutex> lock(allocationLock);
    auto allocation = liveAllocations.find(reinterpret_cast<uintptr_t>(rx));
    if (allocation == liveAllocations.end() || allocation->second != bytes ||
        !hostMemory->release(rx, bytes)) return false;
    liveAllocations.erase(allocation);
    allocationReleased.notify_one();
    return true;
}

static bool readFaults(struct sigaction (&actions)[2]) {
    return sigaction(faultSignals[0], nullptr, &actions[0]) == 0 &&
           sigaction(faultSignals[1], nullptr, &actions[1]) == 0;
}

static bool sameFaults(const struct sigaction (&left)[2], const struct sigaction (&right)[2]) {
    for (unsigned i = 0; i < 2; ++i) {
        if (left[i].sa_flags != right[i].sa_flags || left[i].sa_mask != right[i].sa_mask ||
            left[i].sa_sigaction != right[i].sa_sigaction) return false;
    }
    return true;
}

static bool setFaults(const struct sigaction (&actions)[2]) {
    bool segv = sigaction(faultSignals[0], &actions[0], nullptr) == 0;
    bool bus = sigaction(faultSignals[1], &actions[1], nullptr) == 0;
    return segv && bus;
}

static void forwardFault(int signal, siginfo_t *info, void *context) {
    const auto *handlers = predecessor.load(std::memory_order_acquire);
    const auto &action = handlers->actions[signal == SIGSEGV ? 0 : 1];
    if (action.sa_handler == SIG_IGN) return;
    if (action.sa_handler == SIG_DFL) {
        sigaction(signal, &action, nullptr);
        raise(signal);
    } else if (action.sa_flags & SA_SIGINFO) {
        action.sa_sigaction(signal, info, context);
    } else {
        action.sa_handler(signal);
    }
}

static bool installFaultScope() {
    const auto &previous = predecessor.load(std::memory_order_acquire)->actions;
    for (unsigned i = 0; i < 2; ++i) {
        scopedFaults[i] = previous[i];
        scopedFaults[i].sa_flags |= SA_SIGINFO;
        scopedFaults[i].sa_sigaction = melonxFaultHandler ? melonxFaultHandler : forwardFault;
    }
    if (setFaults(scopedFaults)) return true;
    setFaults(previous);
    return false;
}

static bool beginFaultScope() {
    FaultHandlers current{};
    if (!readFaults(current.actions)) return false;
    for (const auto &action : current.actions) {
        if ((action.sa_flags & SA_RESETHAND) || action.sa_sigaction == forwardFault ||
            (melonxFaultHandler && action.sa_sigaction == melonxFaultHandler)) return false;
    }
    unsigned index = 0;
    while (index < predecessorCount && !sameFaults(current.actions, predecessors[index].actions)) ++index;
    if (index == predecessorCount) {
        if (index == sizeof predecessors / sizeof *predecessors) return false;
        predecessors[predecessorCount++] = current;
    }
    predecessor.store(&predecessors[index], std::memory_order_release);
    // The core records this relay once. Each session can then use the app's current handlers.
    return installFaultScope();
}

static uint8_t checkpointJIT() {
    struct sigaction current[2]{};
    if (!readFaults(current)) return false;
    std::lock_guard<std::mutex> lock(allocationLock);
    if (melonxFaultHandler) return sameFaults(current, scopedFaults) && liveAllocations == retainedAllocations;
    auto handler = reinterpret_cast<uintptr_t>(current[0].sa_sigaction);
    auto allocation = liveAllocations.upper_bound(handler);
    if (!(current[0].sa_flags & SA_SIGINFO) || !(current[1].sa_flags & SA_SIGINFO) ||
        current[0].sa_sigaction != current[1].sa_sigaction || current[0].sa_sigaction == forwardFault ||
        allocation == liveAllocations.begin()) return false;
    --allocation;
    if (handler - allocation->first >= allocation->second) return false;
    try {
        retainedAllocations = liveAllocations;
    } catch (...) {
        return false;
    }
    melonxFaultHandler = current[0].sa_sigaction;
    return installFaultScope();
}

static bool endFaultScope() {
    struct sigaction current[2]{};
    if (!readFaults(current)) return false;
    const auto &previous = predecessor.load(std::memory_order_acquire)->actions;
    if (!sameFaults(current, scopedFaults) || !setFaults(previous) ||
        !readFaults(current) || !sameFaults(current, previous)) return false;
    // Workers have stopped. Give deferred releases a bounded chance to finish.
    std::unique_lock<std::mutex> lock(allocationLock);
    return allocationReleased.wait_for(lock, std::chrono::seconds(1),
        [] { return liveAllocations == retainedAllocations; });
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
                {
                    std::lock_guard<std::mutex> lock(self->controlLock);
                    self->stateReady = iridium_melonx_reset_session();
                    if (self->stateReady)
                        iridium_melonx_set_state(self->stopping, self->paused, self->volume);
                }
                // A nonzero opaque token is required by the upstream virtual pad.
                if (self->stateReady) self->pad = attach_gamepad("Iridium", (void *)1, 0, 1);
                if (!self->pad) {
                    diagnostic("MeloNX could not attach its virtual controller.");
                    status = -5;
                } else if (beginFaultScope()) {
                    status = iridium_melonx_run(self->game.fileSystemRepresentation, (__bridge void *)layer,
                        allocate, release, checkpointJIT, frame, input, self->resolution, self->options);
                    if (status == 0 && (!iridium_melonx_session_closed() || !endFaultScope()))
                        status = -4;
                } else {
                    diagnostic("MeloNX could not take ownership of its executable fault handlers.");
                    status = -4;
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
    if (entered && status != 0) {
        event(generation, 9, "MeloNX could not verify shutdown. Reopen Iridium.");
        return;
    }
    player = nil;
    event(generation, 2, entered ? "MeloNX stopped. Session released." : "MeloNX launch ended.");
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
    if (!player || !api || api->version != 1 || api->size < sizeof *api || !api->allocate || !api->release ||
        (hostMemory && hostMemory != api))
        return false;
    if (!hostMemory) hostMemory = api;
    player->memory = api;
    return true;
}
extern "C" void ir_native_engine_pause(bool pause) {
    if (!player || player->ended) return;
    std::lock_guard<std::mutex> lock(player->controlLock);
    player->paused = pause;
    if (player->stateReady) iridium_melonx_set_state(player->stopping, pause, player->volume);
}
extern "C" void ir_native_engine_stop() {
    if (!player || player->ended) return;
    {
        std::lock_guard<std::mutex> lock(player->controlLock);
        player->stopping = true;
        if (player->stateReady) iridium_melonx_set_state(1, 0, player->volume);
    }
    if (!player->started) [player finish:0 enteredRuntime:NO];
}
extern "C" void ir_native_engine_set_volume(float volume) {
    if (!player || player->ended) return;
    std::lock_guard<std::mutex> lock(player->controlLock);
    player->volume = volume;
    if (player->stateReady) iridium_melonx_set_state(player->stopping, player->paused, volume);
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
