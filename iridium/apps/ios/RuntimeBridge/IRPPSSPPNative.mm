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
#include "Core/Util/DarwinFileSystemServices.h"
#ifndef USE_FFMPEG
#error The native PSP player requires its upstream media decoders
#endif

@interface PPSSPPBaseViewController (IridiumLifecycle)
- (void)iridiumStopRenderLoop:(void (^)(void))completion;
- (void)iridiumCloseSensors:(void (^)(void))completion;
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
@property BOOL appActive;
@property BOOL previousIdleTimerDisabled;
@property NSString *audioCategory;
@property NSString *audioMode;
@property AVAudioSessionCategoryOptions audioOptions;
@property NSMutableArray *inputRestorers;
@property NSMutableSet *capturedControllers;
@property NSMutableDictionary *presentationCancels;
@property UIInterfaceOrientationMask rotationMask;
- (void)beginPlayer;
- (void)observeEnvironment;
- (void)setPlaying:(BOOL)playing;
- (BOOL)canPlay;
- (void)closePlayer;
- (void)finishClose;
- (void)finishNativeClose;
- (void)completeClose;
@end

static __weak IRPPSSPPContainer *container;
static std::atomic<bool> jitVerified;
static std::atomic<bool> rendererFailed;
static std::atomic<uint64_t> frames;
static std::atomic<uint64_t> generation;
static std::atomic<IRNativePSPEvent> eventSink;
static std::atomic<bool> acceptingCallbacks;

static void event(unsigned kind, const char *message) {
    auto sink = eventSink.load();
    if (!sink) return;
    if (kind == 0) { sink(kind, message); return; }
    uint64_t owner = generation.load();
    IRPPSSPPContainer *origin = container;
    std::string copy(message);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (origin && origin == container &&
            (owner == generation.load() || (kind == 2 && origin.closing))) {
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
    return self.rotationMask;
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
    generation.fetch_add(1);
    self.appActive = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    [self observeEnvironment];
    acceptingCallbacks = true;
    self.previousIdleTimerDisabled = UIApplication.sharedApplication.idleTimerDisabled;
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
    ir_native_psp_rotation_changed(g_Config.iScreenRotation);
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
}
- (void)observeEnvironment {
    if (self.observers.count) return;
    __weak IRPPSSPPContainer *weakSelf = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *name in @[UIApplicationWillResignActiveNotification, UIApplicationDidBecomeActiveNotification,
                             AVAudioSessionInterruptionNotification, AVAudioSessionMediaServicesWereResetNotification]) {
        [tokens addObject:[center addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *notice) {
            IRPPSSPPContainer *owner = weakSelf;
            if (!owner) return;
            if ([notice.name isEqualToString:UIApplicationWillResignActiveNotification]) owner.appActive = NO;
            else if ([notice.name isEqualToString:UIApplicationDidBecomeActiveNotification]) owner.appActive = YES;
            else if ([notice.name isEqualToString:AVAudioSessionInterruptionNotification])
                owner.interrupted = [notice.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] != AVAudioSessionInterruptionTypeEnded;
            // The atomic environment properties stay current while closing,
            // including an AV interruption posted from a non-UI thread.
            void (^apply)(void) = ^{
                if (owner.closing) return;
                if ([notice.name isEqualToString:AVAudioSessionMediaServicesWereResetNotification]) {
                    iOSCoreAudioShutdown();
                    if ([owner canPlay] && owner.active && g_Config.bEnableSound) iOSCoreAudioInit();
                } else [owner setPlaying:[owner canPlay]];
            };
            if (NSThread.isMainThread) apply(); else dispatch_async(dispatch_get_main_queue(), apply);
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
    playing = playing && [self canPlay];
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
            else [self setPlaying:YES];  // Reevaluate intent and environment after the delayed drain.
        }];
    }
}
- (BOOL)canPlay {
    return self.wantsActive && self.appActive && !self.interrupted && !self.closing &&
        self.initialized && self.player && !rendererFailed &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}
- (void)closePlayer {
    if (self.closing) return;
    self.closing = YES;
    acceptingCallbacks = false;
    generation.fetch_add(1);
    [self setPlaying:NO];
    if (!self.pausing) [self finishClose];
}
- (void)finishClose {
    if (self.finishing) return;
    self.finishing = YES;
    iOSCoreAudioShutdown();
    for (void (^cancel)(void) in [self.presentationCancels.allValues copy]) cancel();
    [self.presentationCancels removeAllObjects];
    [self dismissViewControllerAnimated:NO completion:nil];
    if (self.player) [self.player iridiumCloseSensors:^{ [self finishNativeClose]; }];
    else [self finishNativeClose];
}
- (void)finishNativeClose {
    NSAssert(NSThread.isMainThread, @"Native shutdown follows the upstream main-thread contract");
    [self.player willMoveToParentViewController:nil];
    [self.player shutdown];
    [self.player.view removeFromSuperview];
    [self.player removeFromParentViewController];
    self.player = nil;
    for (void (^restore)(void) in self.inputRestorers) restore();
    [self.inputRestorers removeAllObjects];
    [self.capturedControllers removeAllObjects];
    [self resignFirstResponder];
    // Follow the release-pinned iOS lifecycle contract after asynchronous
    // renderer/sensor drains. Upstream native cleanup itself is synchronous.
    if (self.initialized) NativeShutdown();
    [self completeClose];
}
- (void)completeClose {
    DarwinFileSystemServices::terminate();
    self.initialized = NO;
    UIApplication.sharedApplication.idleTimerDisabled = self.previousIdleTimerDisabled;
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
        for (id token in self.observers) [NSNotificationCenter.defaultCenter removeObserver:token];
        self.observers = nil;
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
    owner.presentationCancels = [NSMutableDictionary dictionary]; owner.rotationMask = UIInterfaceOrientationMaskAll;
    owner.gamePath = @(game); owner.memoryStick = @(memoryStick); owner.assets = @(assets);
    AVAudioSession *audio = AVAudioSession.sharedInstance;
    owner.audioCategory = audio.category; owner.audioMode = audio.mode; owner.audioOptions = audio.categoryOptions;
    owner.wantsActive = YES;
    owner.appActive = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    eventSink = callback; jitVerified = jit; generation.fetch_add(1); container = owner;
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
    IRPPSSPPContainer *owner = container;
    void (^stop)(void) = ^{
        if (container != owner) return;
        owner.restarting = NO;
        owner.wantsActive = NO;
        [owner closePlayer];
    };
    if (NSThread.isMainThread) stop();
    else dispatch_async(dispatch_get_main_queue(), stop);
}
void ir_native_psp_restart(void) {
    uint64_t owner = generation.load();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!ir_native_psp_generation_current(owner) || !container || container.closing) return;
        container.restarting = YES; [container closePlayer];
    });
}
bool ir_native_psp_jit_available(void) { return jitVerified.load(); }
bool ir_native_psp_should_render(void) { return container.active && !container.pausing && [container canPlay]; }
bool ir_native_psp_is_current_player(void *player) { return player && container.player == (__bridge id)player; }
uint64_t ir_native_psp_generation(void) { return generation.load(); }
bool ir_native_psp_generation_current(uint64_t owner) { return acceptingCallbacks.load() && owner == generation.load(); }
void ir_native_psp_present(UIViewController *controller, void (^cancel)(void)) {
    NSCAssert(NSThread.isMainThread, @"Native presentation belongs to the main thread");
    IRPPSSPPContainer *owner = container;
    if (!owner || owner.closing || owner.presentedViewController || !owner.view.window) { cancel(); return; }
    owner.presentationCancels[[NSValue valueWithNonretainedObject:controller]] = [cancel copy];
    [owner presentViewController:controller animated:YES completion:nil];
}
void ir_native_psp_presentation_finished(UIViewController *controller) {
    [container.presentationCancels removeObjectForKey:[NSValue valueWithNonretainedObject:controller]];
}
void ir_native_psp_rotation_changed(int rotation) {
    uint64_t owner = generation.load();
    void (^apply)(void) = ^{
        if (!ir_native_psp_generation_current(owner)) return;
        UIInterfaceOrientationMask mask;
        switch (rotation) {
            case ROTATION_LOCKED_HORIZONTAL: mask = UIInterfaceOrientationMaskLandscapeRight; break;
            case ROTATION_LOCKED_HORIZONTAL180: mask = UIInterfaceOrientationMaskLandscapeLeft; break;
            case ROTATION_LOCKED_VERTICAL:
            case ROTATION_LOCKED_VERTICAL180:
                mask = UIInterfaceOrientationMaskPortrait;
                if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) mask |= UIInterfaceOrientationMaskPortraitUpsideDown;
                break;
            case ROTATION_AUTO_HORIZONTAL: mask = UIInterfaceOrientationMaskLandscape; break;
            default: mask = UIInterfaceOrientationMaskAll; break;
        }
        container.rotationMask = mask;
        [container setNeedsUpdateOfSupportedInterfaceOrientations];
        [container.parentViewController setNeedsUpdateOfSupportedInterfaceOrientations];
        UIWindowScene *scene = container.view.window.windowScene;
        if (@available(iOS 16.0, *)) {
            UIWindowSceneGeometryPreferencesIOS *preferences = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
            [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
                event(0, "The scene could not apply the requested PSP orientation.");
            }];
        }
    };
    if (NSThread.isMainThread) apply(); else dispatch_async(dispatch_get_main_queue(), apply);
}
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
