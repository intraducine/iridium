// SPDX-License-Identifier: AGPL-3.0-only
#include "IRPPSSPPNative.h"
#include "IRAudioVolume.h"
#include "IRJITExecutionProbe.h"
#include "IRPSPExecutableMemory.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <signal.h>
#include <cerrno>
#include <cstring>
#include <unistd.h>
#include "ios/ViewController.h"
#include "ios/ViewControllerMetal.h"
#include "ios/iOSCoreAudio.h"
#include "Common/System/NativeApp.h"
#include "Common/System/System.h"
#include "Common/Input/InputState.h"
#include "Common/Log/LogManager.h"
#include "Common/MemoryUtil.h"
#include "Common/Arm64Emitter.h"
#include "Core/Config.h"
#include "Core/ConfigValues.h"
#include "Core/Core.h"
#include "Core/System.h"
#include "Core/SaveState.h"
#include "Core/ELF/ParamSFO.h"
#include "Core/HLE/sceCtrl.h"
#include "Core/Reporting.h"
#include "Core/Util/DarwinFileSystemServices.h"
#include "IRPPSSPPOptions.h"
#include "IRCheats.h"
#include "Core/CwCheat.h"
#include <sstream>
void ir_psp_managed_cheats(std::vector<CheatCode>);
#ifndef USE_FFMPEG
#error The native PSP player requires its upstream media decoders
#endif
extern "C" int csops(pid_t, unsigned, void *, size_t);

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
@property CGSize surfaceSize;
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
static std::atomic<bool> jitProbeVerified;
static std::atomic<bool> rendererFailed;
static std::atomic<uint64_t> frames;
static std::atomic<uint64_t> generation;
static std::atomic<IRNativePSPEvent> eventSink;
static std::atomic<bool> acceptingCallbacks;
static std::atomic<IRNativePSPInput> inputSource;
static std::atomic<int> pendingResolution;
static std::atomic<int> currentResolution{2};
static std::atomic<int> pendingState;
static std::atomic<bool> stateBusy;
static bool reportedCoreError; // native render thread, reset before starting it
static std::mutex optionsLock;
static NSDictionary *pendingOptions;
static NSDictionary *startupOptions;
static bool optionsReported;


static void event(unsigned kind, const char *message) {
    auto sink = eventSink.load();
    if (!sink) return;
    if (kind == 0) { sink(kind, message); return; }
    uint64_t owner = generation.load();
    IRPPSSPPContainer *origin = container;
    std::string copy(message);
    dispatch_async(dispatch_get_main_queue(), ^{
        uint64_t current = generation.load();
        bool live = owner == current && acceptingCallbacks && origin && !origin.closing;
        bool retiringError = kind == 2 && origin && origin.closing &&
            (owner == current || owner + 1 == current);
        if (origin && origin == container && (live || retiringError)) {
            if (auto callback = eventSink.load()) callback(kind, copy.c_str());
        }
    });
}

// Log callbacks are synchronous on the emitting thread. No stack sink is ever
// stored in userdata or read by another thread, and no native text enters the
// diagnostic journal. Only the two known upstream memory errno formats do.
static thread_local const IRJITDiagnosticSink *preflightLogSink;
static thread_local uint32_t preflightPass;
static thread_local int preflightErrno = -1;
static void forwardNativeLog(const LogMessage &message, void *) {
    if (preflightLogSink) {
        bool allocation = message.msg.find("Failed to allocate executable memory (") == 0;
        bool protection = message.msg.find("mprotect failed (") == 0;
        if (allocation || protection) {
            int saved = errno;
            size_t offset = message.msg.find("errno=");
            int code = -1;
            if (offset != std::string::npos) {
                offset += 6;
                int number = 0; size_t digits = 0;
                while (offset < message.msg.size() && digits < 5 &&
                       message.msg[offset] >= '0' && message.msg[offset] <= '9') {
                    number = number * 10 + message.msg[offset++] - '0'; ++digits;
                }
                if (digits && (offset == message.msg.size() || message.msg[offset] < '0' || message.msg[offset] > '9')) code = number;
            }
            preflightErrno = code;
            ir_jit_diagnostic_mark(preflightLogSink, allocation ? IR_JIT_ALLOC_ERROR : IR_JIT_PROTECT_ERROR,
                preflightPass, 0, code);
            errno = saved;
        } else if (message.level <= LogLevel::LERROR) {
            ir_jit_diagnostic_mark(preflightLogSink, IR_JIT_NATIVE_ERROR, preflightPass, static_cast<int>(message.level), -1);
        }
        return;
    }
    std::string text = std::string(message.log) + ": " + message.msg;
    event(0, text.c_str());
}

@implementation IRPPSSPPContainer
- (BOOL)canBecomeFirstResponder { return NO; }
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
    pendingResolution = 0; pendingState = 0; stateBusy = false; reportedCoreError = false;
    {std::lock_guard<std::mutex> guard(optionsLock);pendingOptions=nil;optionsReported=false;}
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
    if (jitVerified.load()) g_Config.iCpuCore = (int)CPUCore::JIT;
    // Presentation and input belong to Iridium even for older per-game settings.
    // Upstream AutoRun=false starts in its debugger, which this frontend does
    // not expose. Iridium's render owner already controls startup and pause.
    g_Config.bAutoRun = true;
    g_Config.iScreenRotation = ROTATION_AUTO;
    g_Config.bShowTouchControls = false;
    g_Config.bShowImDebugger = false;
    g_Config.bShowDeveloperMenu = false;
    currentResolution = g_Config.iInternalResolution;
    ir_native_psp_rotation_changed(g_Config.iScreenRotation);
    g_logManager.SetExternalLogCallback(forwardNativeLog, nullptr);
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
    self.player.view.userInteractionEnabled = NO;
    self.player.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.player.view];
    [self.player didMoveToParentViewController:self];
    if (g_Config.iGPUBackend != requestedBackend) {
        event(2, "The selected graphics backend could not initialize. No software fallback was used.");
        [self closePlayer];
        return;
    }
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    if (CGSizeEqualToSize(self.surfaceSize, size)) return;
    self.surfaceSize = size;
    // Use the same asynchronous drain as pause, then refresh viewport dimensions
    // in didBecomeActive. Covers rotation, touch visibility and split-view resize.
    if (self.active) [self setPlaying:NO];
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
#if defined(IRIDIUM_PSP_PREPARED_JIT)
    int executableClosed = jitVerified.load() && (self.restarting || ir_psp_exec_shared_memory())
        ? ir_psp_exec_reuse_native(ir_psp_exec_admission())
        : ir_native_psp_exec_end(ir_psp_exec_admission());
    if (executableClosed != IR_PSP_EXEC_OK) {
        event(9, "PSP executable memory still has live readers or writers; restart required.");
        return;
    }
#endif
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

static bool debuggerEnabled() {
    uint32_t flags = 0;
    return csops(getpid(), 0, &flags, sizeof flags) == 0 && (flags & 0x10000000u);
}

int ir_native_psp_check_jit(void) { return ir_native_psp_check_jit_diagnostic(nullptr); }
int ir_native_psp_check_jit_diagnostic(const IRJITDiagnosticSink *sink) {
    jitProbeVerified = false;
    auto mark = [&](IRJITDiagnosticStage stage, uint32_t pass, int64_t value, int error = 0) {
        return ir_jit_diagnostic_mark(sink, stage, pass, value, error);
    };
    auto finish = [&](int result) { return mark(IR_JIT_NATIVE_RETURN, 0, result) ? result : -6; };
    if (!mark(IR_JIT_NATIVE_ENTER, 0, 0)) return -6;
    if (container) return finish(-5);
#if TARGET_OS_SIMULATOR || !PPSSPP_ARCH(ARM64)
    return finish(-1);
#else
    struct ErrorSink {
        LogOutput previous = g_logManager.GetOutputsEnabled();
        explicit ErrorSink(const IRJITDiagnosticSink *value) {
            if (!value) return;
            preflightLogSink = value;
            g_logManager.SetExternalLogCallback(forwardNativeLog, nullptr);
            g_logManager.EnableOutput(LogOutput::ExternalCallback);
        }
        ~ErrorSink() { preflightLogSink = nullptr; g_logManager.SetOutputsEnabled(previous); }
    } errors(sink);
    uint32_t flags = 0;
    int status = csops(getpid(), 0, &flags, sizeof flags);
    int statusError = status ? errno : 0;
    if (!mark(IR_JIT_CSOPS, 0, flags, statusError)) return -6;
    if (status || !(flags & 0x10000000u)) return finish(-4);
    // Use the CPU backend's code-block lifecycle, with checked protection results.
    // A Madeira pool or a successful mprotect alone proves neither execution
    // nor rewriting here. No debugger allocation/BRK protocol is inferred.
    constexpr size_t size = 16 * 1024 * 1024;
    if (!mark(IR_JIT_ALLOC_ENTER, 0, size)) return -6;
    preflightPass = 0; preflightErrno = -1;
    Arm64Gen::ARM64CodeBlock block;
    block.AllocCodeSpace(size, IR_PSP_EXEC_CPU);
    auto code = block.GetBasePtr();
    if (!mark(IR_JIT_ALLOC_RETURN, 0, code != nullptr, code ? 0 : preflightErrno)) return -6;
    if (!code) return finish(-2);
    if (!mark(IR_JIT_PROBE_BASE, 0, (int64_t)(uintptr_t)code)) {
        block.FreeCodeSpace(); return finish(-6);
    }
    int result = 1;
    uint32_t pass = 0;
    for (int value : {42, 7}) {
        ++pass; preflightPass = pass;
        size_t estimate = GetMemoryProtectPageSize();
        if (!mark(IR_JIT_RW_ENTER, pass, estimate)) { result = -6; break; }
        preflightErrno = -1;
        block.ResetCodePtr(0);
        bool writable = block.BeginWrite(estimate);
#if defined(IRIDIUM_PSP_PREPARED_JIT)
        struct ProbeWriteScope {
            Arm64Gen::ARM64CodeBlock &block;
            bool active;
            ~ProbeWriteScope() { if (active) { block.FailEmission(); block.EndWrite(); } }
            bool end() { active = false; return block.EndWrite(); }
        } write{block, writable};
#endif
        if (!mark(IR_JIT_RW_RETURN, pass, writable, writable ? 0 : preflightErrno)) { result = -6; break; }
        if (!writable) { result = -3; break; }
        if (!mark(IR_JIT_EMIT_ENTER, pass, value)) { result = -6; break; }
        block.MOVI2R(Arm64Gen::W0, value);
        block.RET();
        if (!mark(IR_JIT_EMIT_RETURN, pass, 0)) { result = -6; break; }
        // Only this constant-return probe's emitted words, never game code,
        // pointers or unused allocation bytes. The journal has a fixed byte cap.
        size_t length = block.GetCodePointer() - code;
        bool recorded = mark(IR_JIT_CODE_LENGTH, pass, length);
        for (size_t index = 0; recorded && index < 4 && (index + 1) * sizeof(uint32_t) <= length; ++index) {
            uint32_t word = 0; memcpy(&word, code + index * sizeof word, sizeof word);
            recorded = mark(static_cast<IRJITDiagnosticStage>(IR_JIT_CODE_WORD_0 + index), pass, word);
        }
        if (!recorded || !mark(IR_JIT_CACHE_ENTER, pass, 0)) { result = -6; break; }
        block.FlushIcache();
        // Upstream's void cache wrapper does not expose a syscall status.
        if (!mark(IR_JIT_CACHE_RETURN, pass, 0, -1) ||
            !mark(IR_JIT_RX_ENTER, pass, length > estimate ? length : estimate)) { result = -6; break; }
        preflightErrno = -1;
        bool executable =
#if defined(IRIDIUM_PSP_PREPARED_JIT)
            write.end();
#else
            block.EndWrite();
#endif
        if (!mark(IR_JIT_RX_RETURN, pass, executable, executable ? 0 : preflightErrno)) { result = -6; break; }
        if (!executable) { result = -3; break; }
        const uint32_t expected[] = {value == 42 ? 0x52800540u : 0x528000e0u, 0xd65f03c0u};
        const void *writableCode = block.GetWritablePtrFromCodePtr(code);
        if (length != sizeof expected || !writableCode || memcmp(code, expected, sizeof expected) ||
            memcmp(writableCode, expected, sizeof expected)) { result = 0; break; }
#if defined(IRIDIUM_PSP_PREPARED_JIT)
        IRPSPExecReadScope executing((const void *)code);
        if (!executing) { result = 0; break; }
#endif
        if (!ir_jit_probe_execute_diagnostic(code, size, value, sink, pass)) { result = 0; break; }
    }
    if (!mark(IR_JIT_FREE_ENTER, 0, 0)) result = -6;
    block.FreeCodeSpace();
    if (!mark(IR_JIT_FREE_RETURN, 0, 0, -1)) result = -6;
    result = finish(result);
#if defined(IRIDIUM_PSP_PREPARED_JIT)
    ir_psp_exec_probe_proven(result == 1);
    if (result == 1) {
        uint64_t previous = ir_psp_exec_generation();
        if (previous == UINT64_MAX || ir_native_psp_exec_advance(ir_psp_exec_admission(), previous, previous + 1) != IR_PSP_EXEC_OK) result = -7;
    }
#endif
    jitProbeVerified = result == 1;
    return result;
#endif
}

uint32_t ir_native_psp_abi(void) { return 3; }
void *ir_native_psp_create(const char *game, const char *memoryStick, const char *assets,
                          bool jit, IRNativePSPEvent callback, IRNativePSPInput input) {
    if (!NSThread.isMainThread || container || !game || !memoryStick || !assets || !callback || !input) return nullptr;
#if defined(IRIDIUM_PSP_PREPARED_JIT)
    if (jit && !ir_psp_exec_native_ready()) return nullptr;
#endif
    if (!ir_native_psp_codec_check()) return nullptr;
    IRPPSSPPContainer *owner = [[IRPPSSPPContainer alloc] init];
    owner.inputRestorers = [NSMutableArray array]; owner.capturedControllers = [NSMutableSet set];
    owner.presentationCancels = [NSMutableDictionary dictionary]; owner.rotationMask = UIInterfaceOrientationMaskAll;
    owner.gamePath = @(game); owner.memoryStick = @(memoryStick); owner.assets = @(assets);
    AVAudioSession *audio = AVAudioSession.sharedInstance;
    owner.audioCategory = audio.category; owner.audioMode = audio.mode; owner.audioOptions = audio.categoryOptions;
    owner.previousIdleTimerDisabled = UIApplication.sharedApplication.idleTimerDisabled;
    owner.wantsActive = YES;
    owner.appActive = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    bool verified = jitProbeVerified.exchange(false);
    eventSink = callback; inputSource = input;
    jitVerified = jit && verified && debuggerEnabled();
    { std::lock_guard<std::mutex> guard(optionsLock); startupOptions=nil; }
    generation.fetch_add(1); container = owner;
    return (__bridge_retained void *)owner;
}
void ir_native_psp_pause(void) { container.wantsActive = NO; [container setPlaying:NO]; }
void ir_native_psp_resume(void) {
    container.wantsActive = YES;
    [container setPlaying:!container.interrupted && UIApplication.sharedApplication.applicationState == UIApplicationStateActive];
}
// Requests are accepted on the UI thread and applied by the existing render
// owner after resume. No UI thread reads or mutates live emulation/config state.
void ir_native_psp_set_volume(float level) { ir_audio_volume_set(level); }
bool ir_native_psp_request(unsigned operation, int value) {
    if (!NSThread.isMainThread || !container || !container.initialized || container.closing) return false;
    if (operation == 1 && value >= 1 && value <= 4) {
        pendingResolution = value; return true;
    }
    if ((operation == 2 || operation == 3) && value >= 0 && value < 5) {
        bool idle = false;
        if (!stateBusy.compare_exchange_strong(idle, true)) return false;
        pendingState = (int)operation * 10 + value;
        return true;
    }
    return false;
}
bool ir_native_psp_command(const char *json) {
    if(!NSThread.isMainThread||!container||container.closing||!json||strlen(json)>131072)return false;
    id request=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:nil];
    if(![request isKindOfClass:NSDictionary.class])return false;
    if([request[@"operation"] isEqual:@"startupOptions"]) {
        if(container.initialized||![request[@"values"] isKindOfClass:NSDictionary.class])return false;
        NSDictionary *values=request[@"values"];
        for(id key in values)if(![key isKindOfClass:NSString.class]||!irPSPStartupKey(key)||
            ![values[key] isKindOfClass:NSString.class]||(![values[key] isEqual:@"0"]&&![values[key] isEqual:@"1"]))return false;
        std::lock_guard<std::mutex> guard(optionsLock);startupOptions=[values copy];return true;
    }
    if(!container.initialized)return false;
    if(![request[@"operation"] isEqual:@"cheats"]&&(![request[@"operation"] isEqual:@"option"]||
       ![request[@"key"] isKindOfClass:NSString.class]||![request[@"value"] isKindOfClass:NSString.class]))return false;
    std::lock_guard<std::mutex> guard(optionsLock);
    if(pendingOptions)return false;
    bool idle=false;
    if(!stateBusy.compare_exchange_strong(idle,true))return false;
    pendingOptions=request;return true;
}
int ir_native_psp_resolution(void) { return currentResolution.load(); }
void ir_native_psp_frontend_event(unsigned kind, const char *message) {
    if (kind == 4) {
        optionsReported=false;
        currentResolution = g_Config.iInternalResolution;
        const char *cpu = "Unknown";
        switch (PSP_CoreParameter().cpuCore) {
        case CPUCore::INTERPRETER: cpu = "Interpreter"; break;
        case CPUCore::IR_INTERPRETER: cpu = "IR interpreter"; break;
        case CPUCore::JIT: cpu = "JIT"; break;
        case CPUCore::JIT_IR: cpu = "JIT using IR"; break;
        default: break;
        }
        event(8, cpu);
    }
    event(kind, message);
}

void ir_native_psp_poll_input(void) {
    uint16_t buttons = 0; int16_t x = 0, y = 0;
    if (acceptingCallbacks) {
        if (auto poll = inputSource.load()) poll(&buttons, &x, &y);
    }
    const uint32_t mapping[] = {CTRL_CROSS, CTRL_SQUARE, CTRL_SELECT, CTRL_START,
        CTRL_UP, CTRL_DOWN, CTRL_LEFT, CTRL_RIGHT, CTRL_CIRCLE, CTRL_TRIANGLE,
        CTRL_LTRIGGER, CTRL_RTRIGGER};
    uint32_t pspButtons = 0;
    for (unsigned bit = 0; bit < 12; ++bit)
        if (buttons & (1u << bit)) pspButtons |= mapping[bit];
    __CtrlUpdateButtons(pspButtons, CTRL_MASK_USER);
    // Shared console samples use down-positive Y; PPSSPP expects up-positive.
    __CtrlSetAnalogXY(0, x / 32768.0f, -y / 32768.0f);
}

void ir_native_psp_frontend_startup(void) {
    NSDictionary *values;
    { std::lock_guard<std::mutex> guard(optionsLock); values=startupOptions; }
    if(values[@"iPSPModel"])g_Config.iPSPModel=[values[@"iPSPModel"] intValue];
    if(values[@"bSoftwareRendering"])g_Config.bSoftwareRendering=[values[@"bSoftwareRendering"] boolValue];
}

void ir_native_psp_frontend_frame(void) {
    if (!acceptingCallbacks || !PSP_IsInited()) return;
    NSDictionary *settings;
    {std::lock_guard<std::mutex> guard(optionsLock);settings=pendingOptions;pendingOptions=nil;}
    if([settings[@"operation"] isEqual:@"cheats"]) {
        std::vector<IRCheat> items;std::vector<CheatCode> codes;
        bool valid=ir_cheats_decode(settings[@"items"],items);
        for(const auto& item:items) {
            if(strcmp(item.format,"cwcheat")) {valid=false;break;}
            CheatCode code;code.name=item.name;
            std::istringstream stream(item.code);
            for(std::string line;std::getline(stream,line);) {
                if(line.find_first_not_of(" \t\r")==std::string::npos)continue;
                CheatLine pair;
                if(!ir_cheat_pair(line.c_str(),&pair.part1,&pair.part2)){valid=false;break;}
                code.lines.push_back(pair);
            }
            if(code.lines.empty())valid=false;
            if(item.enabled)codes.push_back(std::move(code));
        }
        if(valid) {ir_psp_managed_cheats(std::move(codes));event(5,"Cheats applied.");}
        else event(6,"Check the cheat format and code. Existing codes have been kept.");
        stateBusy=false;
        settings=nil;
    }
    if(settings||!optionsReported) {
        bool accepted=false;
        NSArray *items=irPSPOptions(settings[@"key"],settings[@"value"],&accepted);
        if(settings&&accepted) {
            Reporting::UpdateConfig();System_PostUIMessage(UIMessage::GPU_RENDER_RESIZED);
            if(!g_Config.Save("Iridium core settings"))event(6,"The settings could not be saved. Check free storage.");
        } else if(settings)event(6,"This PSP setting is unavailable.");
        NSString *discID=@(g_paramSFO.GetDiscID().c_str());
        bool validID=discID.length>0&&discID.length<=16&&[discID rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet]invertedSet]].location==NSNotFound;
        NSDictionary *folders=validID?@{@"Texture Packs":[@"PSP/TEXTURES/" stringByAppendingString:discID],@"Shaders":@"PSP/shaders",@"Cheat Files":@"PSP/Cheats"}:@{};
        NSDictionary *snapshot=@{@"options":items,@"states":@YES,@"discCount":@0,@"discIndex":@0,@"players":@1,@"aspect":@(480.0/272.0),@"cheatFormats":@[@"cwcheat"],@"contentFolders":folders};
        NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        if(data)event(10,[[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);
        optionsReported=true;
        if(settings)stateBusy=false;
    }
    if (coreState == CORE_RUNTIME_ERROR && !reportedCoreError) {
        reportedCoreError = true;
        event(2, "The PSP engine reported a runtime error. Details are available in View Log.");
        return;
    }
    int resolution = pendingResolution.exchange(0);
    if (resolution) {
        g_Config.iInternalResolution = resolution;
        Reporting::UpdateConfig();
        System_PostUIMessage(UIMessage::GPU_RENDER_RESIZED);
        g_Config.Save("Iridium resolution");
    }
    currentResolution = g_Config.iInternalResolution;
    int request = pendingState.exchange(0);
    if (!request) return;
    struct Completion {
        uint64_t owner;
        std::atomic<bool> finished{false};
        explicit Completion(uint64_t value) : owner(value) {}
        void finish(SaveState::Status status, std::string_view message) {
            if (finished.exchange(true) || !ir_native_psp_generation_current(owner)) return;
            stateBusy = false;
            std::string text(message);
            if (text.empty()) text = status == SaveState::Status::SUCCESS ? "Save-state operation completed." : "Save-state operation failed.";
            event(status == SaveState::Status::FAILURE ? 6 : 5, text.c_str());
        }
        ~Completion() {
            finish(SaveState::Status::FAILURE,
                "The PSP engine declined the save-state request. Multiplayer or Hardcore mode may restrict save states.");
        }
    };
    // Upstream policy guards may discard a callback without invoking it. A
    // queued operation retains this owner; only the last discarded copy fails
    // the request. Never release an in-flight operation based on elapsed time.
    auto result = std::make_shared<Completion>(generation.load());
    auto completion = [result](SaveState::Status status, std::string_view message) {
        result->finish(status, message);
    };
    std::string prefix = SaveState::GetGamePrefix(g_paramSFO);
    if (request / 10 == 2) SaveState::SaveSlot(prefix, request % 10, completion);
    else SaveState::LoadSlot(prefix, request % 10, completion);
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
