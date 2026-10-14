// SPDX-License-Identifier: AGPL-3.0-only
#include "IRPPSSPPNative.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include <atomic>
#include <signal.h>
#include "ios/ViewController.h"
#include "ios/ViewControllerMetal.h"
#include "ios/iOSCoreAudio.h"
#include "Common/System/NativeApp.h"
#include "Common/System/System.h"
#include "Common/Input/InputState.h"
#include "Common/Log/LogManager.h"
#include "Core/Config.h"
#include "Core/ConfigValues.h"
#ifndef USE_FFMPEG
#error The native PSP player requires its upstream media decoders
#endif

@interface PPSSPPBaseViewController (IridiumLifecycle)
- (void)iridiumStopRenderLoop:(void (^)(void))completion;
@end

@interface IRPPSSPPContainer : UIViewController {
    struct sigaction previousPipe;
    BOOL ownsPipe;
}
@property PPSSPPBaseViewController *player;
@property NSString *gamePath;
@property NSString *memoryStick;
@property NSString *assets;
@property NSArray *observers;
@property BOOL active;
@property BOOL pausing;
@property BOOL wantsActive;
@property BOOL closing;
@property BOOL restarting;
@property BOOL initialized;
@property BOOL finishing;
@property BOOL interrupted;
@property NSString *audioCategory;
@property NSString *audioMode;
@property AVAudioSessionCategoryOptions audioOptions;
@property NSMutableArray *inputRestorers;
@property NSMutableSet *capturedControllers;
- (void)beginPlayer;
- (void)setPlaying:(BOOL)playing;
- (void)closePlayer;
- (void)finishClose;
- (void)completeClose;
@end

static __weak IRPPSSPPContainer *container;
static std::atomic<bool> jitVerified;
static std::atomic<bool> rendererFailed;
static std::atomic<uint64_t> frames;
static std::atomic<uint64_t> generation;
static std::atomic<IRNativePSPEvent> eventSink;

static void event(unsigned kind, const char *message) {
    auto sink = eventSink.load();
    if (!sink) return;
    if (kind == 0) { sink(kind, message); return; }
    uint64_t owner = generation.load();
    std::string copy(message);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (owner == generation.load() && container) {
            if (auto callback = eventSink.load()) callback(kind, copy.c_str());
        }
    });
}

@implementation IRPPSSPPContainer
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (self.active && !self.closing) [self.player pressesBegan:presses withEvent:event];
    else [super pressesBegan:presses withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (self.initialized && !self.closing) [self.player pressesEnded:presses withEvent:event];
    else [super pressesEnded:presses withEvent:event];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (self.initialized && !self.closing) [self.player pressesCancelled:presses withEvent:event];
    else [super pressesCancelled:presses withEvent:event];
}
- (UIViewController *)childViewControllerForHomeIndicatorAutoHidden { return self.player; }
- (UIViewController *)childViewControllerForScreenEdgesDeferringSystemGestures { return self.player; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return self.player ? self.player.supportedInterfaceOrientations : UIInterfaceOrientationMaskAll;
}
- (BOOL)shouldAutorotate { return self.player ? self.player.shouldAutorotate : YES; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    [self beginPlayer];
}
- (void)beginPlayer {
    NSAssert(NSThread.isMainThread, @"Native initialization belongs to the UI thread");
    if (self.closing) return;
    frames = 0; rendererFailed = false;
    ir_native_psp_platform_init();
    struct sigaction ignored{};
    ignored.sa_handler = SIG_IGN;
    sigemptyset(&ignored.sa_mask);
    ownsPipe = sigaction(SIGPIPE, &ignored, &previousPipe) == 0;
    NSString *configuration = [self.memoryStick stringByAppendingPathComponent:@"PSP/SYSTEM/ppsspp.ini"];
    BOOL hasSettings = [NSFileManager.defaultManager fileExistsAtPath:configuration];
    const char *argv[] = {"Iridium", self.gamePath.UTF8String};
    NativeInit(2, argv, self.memoryStick.UTF8String, self.assets.UTF8String, nullptr);
    self.initialized = YES;
    // Defaults apply only to a new memory stick; existing upstream settings survive.
    if (!hasSettings) {
        g_Config.iGPUBackend = (int)GPUBackend::OPENGL;
        g_Config.iCpuCore = (int)CPUCore::IR_INTERPRETER;
        g_Config.iInternalResolution = 2;
        g_Config.bSoftwareRendering = false;
    }
    g_logManager.SetExternalLogCallback([](const LogMessage &message, void *) {
        std::string text = std::string(message.log) + ": " + message.msg;
        event(0, text.c_str());
    }, nullptr);
    g_logManager.EnableOutput(LogOutput::ExternalCallback);
    NSString *settings = [NSString stringWithFormat:@"release=1.20.4 cpu_core=%d jit_available=%d gpu_backend=%d software_rendering=%d resolution=%d media=FFmpeg H.264/AAC",
        g_Config.iCpuCore, jitVerified.load(), g_Config.iGPUBackend, g_Config.bSoftwareRendering, g_Config.iInternalResolution];
    event(0, settings.UTF8String);
    int requestedBackend = g_Config.iGPUBackend;
    self.player = requestedBackend == (int)GPUBackend::VULKAN
        ? (PPSSPPBaseViewController *)[[PPSSPPViewControllerMetal alloc] init]
        : (PPSSPPBaseViewController *)[[PPSSPPViewControllerGL alloc] init];
    [self addChildViewController:self.player];
    self.player.view.frame = self.view.bounds;
    self.player.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.player.view];
    [self.player didMoveToParentViewController:self];
    if (g_Config.iGPUBackend != requestedBackend) {
        event(2, "The selected graphics backend could not initialize. No software fallback was used.");
        [self closePlayer];
        return;
    }
    __weak IRPPSSPPContainer *weakSelf = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *name in @[UIApplicationWillResignActiveNotification, UIApplicationDidBecomeActiveNotification,
                             AVAudioSessionInterruptionNotification, AVAudioSessionMediaServicesWereResetNotification]) {
        [tokens addObject:[center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notice) {
            IRPPSSPPContainer *owner = weakSelf;
            if (!owner || owner.closing) return;
            if ([notice.name isEqualToString:UIApplicationWillResignActiveNotification]) [owner setPlaying:NO];
            else if ([notice.name isEqualToString:UIApplicationDidBecomeActiveNotification]) [owner setPlaying:owner.wantsActive && !owner.interrupted];
            else if ([notice.name isEqualToString:AVAudioSessionInterruptionNotification]) {
                BOOL ended = [notice.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded;
                owner.interrupted = !ended;
                [owner setPlaying:ended && owner.wantsActive && UIApplication.sharedApplication.applicationState == UIApplicationStateActive];
            } else {
                iOSCoreAudioShutdown();
                if (owner.active && g_Config.bEnableSound) iOSCoreAudioInit();
            }
        }]];
    }
    self.observers = tokens;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self becomeFirstResponder];
    [self setPlaying:self.wantsActive && !self.closing && !self.interrupted && UIApplication.sharedApplication.applicationState == UIApplicationStateActive];
}
- (void)setPlaying:(BOOL)playing {
    NSAssert(NSThread.isMainThread, @"Player lifecycle belongs to the main thread");
    if (self.pausing || (self.closing && playing)) return;
    if (playing && !self.active) {
        self.active = YES;
        [self.player didBecomeActive];
        if (g_Config.bEnableSound) iOSCoreAudioInit();
    } else if (!playing && self.active) {
        self.active = NO; self.pausing = YES;
        iOSCoreAudioShutdown();
        [self.player iridiumStopRenderLoop:^{
            self.pausing = NO;
            if (self.closing) [self finishClose];
            else if (self.wantsActive) [self setPlaying:YES];
        }];
    }
}
- (void)closePlayer {
    if (self.closing) return;
    self.closing = YES;
    [self setPlaying:NO];
    if (!self.pausing) [self finishClose];
}
- (void)finishClose {
    if (self.finishing) return;
    self.finishing = YES;
    for (id token in self.observers) [NSNotificationCenter.defaultCenter removeObserver:token];
    self.observers = nil;
    iOSCoreAudioShutdown();
    [self.player willMoveToParentViewController:nil];
    [self.player shutdown];
    [self.player.view removeFromSuperview];
    [self.player removeFromParentViewController];
    self.player = nil;
    for (void (^restore)(void) in self.inputRestorers) restore();
    [self.inputRestorers removeAllObjects];
    [self.capturedControllers removeAllObjects];
    [self resignFirstResponder];
    // All UIKit, input and render owners are stopped. Serialize the remaining
    // native cleanup off the UI thread; worker joins and config I/O can block.
    // No frontend API is called again until its main-thread completion.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (self.initialized) NativeShutdown();
        dispatch_async(dispatch_get_main_queue(), ^{ [self completeClose]; });
    });
}
- (void)completeClose {
    self.initialized = NO;
    struct sigaction current{};
    if (ownsPipe && sigaction(SIGPIPE, nullptr, &current) == 0 && current.sa_handler == SIG_IGN)
        sigaction(SIGPIPE, &previousPipe, nullptr);
    ownsPipe = NO;
    AVAudioSession *audio = AVAudioSession.sharedInstance;
    [audio setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    [audio setCategory:self.audioCategory mode:self.audioMode options:self.audioOptions error:nil];
    if (self.restarting) {
        self.restarting = NO; self.closing = NO; self.finishing = NO;
        [self beginPlayer]; [self setPlaying:self.wantsActive && !self.interrupted && UIApplication.sharedApplication.applicationState == UIApplicationStateActive];
    } else {
        generation.fetch_add(1);
        container = nil;
        if (auto callback = eventSink.load()) callback(1, "Native PSP session closed; memory-stick files retained.");
    }
}
@end

uint32_t ir_native_psp_abi(void) { return 1; }
void *ir_native_psp_create(const char *game, const char *memoryStick, const char *assets,
                          bool jit, IRNativePSPEvent callback) {
    if (!NSThread.isMainThread || container || !game || !memoryStick || !assets || !callback) return nullptr;
    if (!ir_native_psp_codec_check()) return nullptr;
    IRPPSSPPContainer *owner = [[IRPPSSPPContainer alloc] init];
    owner.inputRestorers = [NSMutableArray array]; owner.capturedControllers = [NSMutableSet set];
    owner.gamePath = @(game); owner.memoryStick = @(memoryStick); owner.assets = @(assets);
    AVAudioSession *audio = AVAudioSession.sharedInstance;
    owner.audioCategory = audio.category; owner.audioMode = audio.mode; owner.audioOptions = audio.categoryOptions;
    owner.wantsActive = YES; eventSink = callback; jitVerified = jit; generation.fetch_add(1); container = owner;
    return (__bridge_retained void *)owner;
}
void ir_native_psp_pause(void) { container.wantsActive = NO; [container setPlaying:NO]; }
void ir_native_psp_resume(void) {
    container.wantsActive = YES;
    [container setPlaying:!container.interrupted && UIApplication.sharedApplication.applicationState == UIApplicationStateActive];
}
void ir_native_psp_menu(void) {
    if (!container || container.closing) return;
    KeyInput key{}; key.deviceId = DEVICE_ID_TOUCH; key.keyCode = NKCODE_BACK;
    key.flags = KeyInputFlags::DOWN | KeyInputFlags::UP; NativeKey(key);
}
void ir_native_psp_stop(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [container closePlayer]; });
}
void ir_native_psp_restart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!container || container.closing) return;
        container.restarting = YES; [container closePlayer];
    });
}
bool ir_native_psp_jit_available(void) { return jitVerified.load(); }
bool ir_native_psp_should_render(void) { return container.active && !container.closing && !container.pausing; }
uint64_t ir_native_psp_frames(void) { return frames.load(); }
void ir_native_psp_frame(void) { frames.fetch_add(1); }
void ir_native_psp_renderer_ready(void) {
    if (!rendererFailed) event(3, "Native graphics initialized; game loading progress remains unverified.");
}
void ir_native_psp_renderer_failed(void) {
    rendererFailed = true;
    event(2, "The native renderer failed to initialize. No software fallback was used.");
    ir_native_psp_stop();
}
void ir_native_psp_capture_controller(void *pointer) {
    GCController *controller = (__bridge GCController *)pointer;
    IRPPSSPPContainer *owner = container;
    if (!owner || !controller || [owner.capturedControllers containsObject:controller]) return;
    [owner.capturedControllers addObject:controller];
    for (GCControllerElement *element in controller.physicalInputProfile.allElements) {
        GCSystemGestureState state = element.preferredSystemGestureState;
        [owner.inputRestorers addObject:^{ element.preferredSystemGestureState = state; }];
        if ([element isKindOfClass:GCControllerButtonInput.class]) {
            GCControllerButtonInput *button = (GCControllerButtonInput *)element;
            auto changed = button.valueChangedHandler;
            [owner.inputRestorers addObject:^{ button.valueChangedHandler = changed; }];
        } else if ([element isKindOfClass:GCControllerAxisInput.class]) {
            GCControllerAxisInput *axis = (GCControllerAxisInput *)element;
            auto changed = axis.valueChangedHandler;
            [owner.inputRestorers addObject:^{ axis.valueChangedHandler = changed; }];
        } else if ([element isKindOfClass:GCControllerDirectionPad.class]) {
            GCControllerDirectionPad *pad = (GCControllerDirectionPad *)element;
            auto changed = pad.valueChangedHandler;
            [owner.inputRestorers addObject:^{ pad.valueChangedHandler = changed; }];
        }
    }
}
