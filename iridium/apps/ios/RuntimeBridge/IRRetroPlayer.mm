// SPDX-License-Identifier: AGPL-3.0-only
// Hosts upstream libretro implementations. No guest CPU/GPU/media code lives here.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAEAGLLayer.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <AVFAudio/AVFAudio.h>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <map>
#include <string>
#include <vector>
#include <dlfcn.h>
#include "libretro.h"
#include "IRPhase3.h"

@interface IRRetroSurface : UIView
@end
@implementation IRRetroSurface
+ (Class)layerClass { return CAEAGLLayer.class; }
@end

struct RetroAPI {
    decltype(&retro_set_environment) environment;
    decltype(&retro_set_video_refresh) video;
    decltype(&retro_set_audio_sample) audio;
    decltype(&retro_set_audio_sample_batch) batch;
    decltype(&retro_set_input_poll) poll;
    decltype(&retro_set_input_state) input;
    decltype(&retro_get_system_info) info;
    decltype(&retro_get_system_av_info) av;
    decltype(&retro_init) init;
    decltype(&retro_deinit) deinit;
    decltype(&retro_load_game) load;
    decltype(&retro_unload_game) unload;
    decltype(&retro_run) run;
    decltype(&retro_set_controller_port_device) controller;
    bool (*pause)(bool);
};

@interface IRRetroPlayer : UIViewController {
@public
    RetroAPI api;
    dispatch_queue_t owner;
    dispatch_source_t clock;
    IRPhase3Event event;
    uint64_t generation;
    IRPhase3Poll input;
    IRPhase3Input sampled;
    std::string engine, core, game, saves, system;
    std::map<std::string, std::string> options;
    retro_hw_render_callback hardware;
    retro_frame_time_callback frameTime;
    retro_pixel_format pixelFormat;
    EAGLContext *context;
    IRRetroSurface *surface;
    UIImageView *software;
    AVAudioEngine *audioEngine;
    AVAudioSourceNode *audioSource;
    AVAudioUnitVarispeed *audioSpeed;
    std::atomic<uint64_t> frameCount;
    std::atomic<bool> muted, imagePending, stopped;
    std::atomic<uint32_t> readAudio, writeAudio;
    std::vector<int16_t> samples;
    GLuint renderTarget, color, depth, displayTarget, displayColor;
    GLint width, height;
    unsigned maxWidth, maxHeight;
    bool initialized, initializationEntered, loaded, loadEntered, loadReturned, paused, jit, failed;
    bool starting, finishing, audioSessionOwned, cleanupUncertain;
    NSString *previousAudioCategory, *previousAudioMode;
    AVAudioSessionCategoryOptions previousAudioOptions;
    id audioConfigurationObserver, audioInterruptionObserver;
    void *coreImage;
    double displayAspect;
    double currentFPS, initialAudioRate;
    std::atomic<bool> resizeQueued;
    bool needsContextReset, hardwareSelected, shutdownRequested;
}
- (void)start;
- (void)startCore;
- (void)finish;
- (void)video:(const void *)data width:(unsigned)w height:(unsigned)h pitch:(size_t)pitch;
- (bool)updateGeometry:(retro_game_geometry)geometry;
- (bool)updateTiming:(retro_system_timing)timing;
- (bool)restartAudio;
- (bool)setPaused:(bool)value;
@end
static IRRetroPlayer *active;
static constexpr uint32_t audioCapacity = 16384;

static void report(unsigned kind, const char *message) {
    if (active && active->event) active->event(active->generation, kind, message);
}
static uintptr_t framebuffer() { return active ? active->renderTarget : 0; }
static retro_proc_address_t procedure(const char *name) {
    static void *gles = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW | RTLD_LOCAL);
    return gles ? (retro_proc_address_t)dlsym(gles, name) : nullptr;
}
static void coreLog(enum retro_log_level, const char *, ...) {
    // Cores require a callable logger. Guest titles, firmware paths and other
    // arbitrary upstream format arguments must not enter exported app logs.
}
static bool environment(unsigned command, void *data) {
    IRRetroPlayer *p = active;
    if (!p) return false;
    switch (command) {
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: ((retro_log_callback *)data)->log=coreLog; return true;
    case RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES:
        *(uint64_t *)data=(1ull<<RETRO_DEVICE_JOYPAD)|(1ull<<RETRO_DEVICE_ANALOG)|(1ull<<RETRO_DEVICE_POINTER);return true;
    case RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS: *(unsigned *)data=1;return true;
    case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE: *(int *)data=p->paused?0:3;return true;
    case RETRO_ENVIRONMENT_GET_FASTFORWARDING: *(bool *)data=false;return true;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: *(const char **)data = p->system.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: *(const char **)data = p->saves.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY: *(const char **)data = p->system.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_LIBRETRO_PATH: *(const char **)data = p->core.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE: *(bool *)data = true; return true;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: return true;
    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE: *(bool *)data = p->jit; return true;
    case RETRO_ENVIRONMENT_GET_LANGUAGE: *(unsigned *)data = RETRO_LANGUAGE_ENGLISH; return true;
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION: *(unsigned *)data = 2; return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2: {
        auto definitions = ((retro_core_options_v2 *)data)->definitions;
        for (auto item = definitions; item && item->key; ++item)
            if (!p->options.count(item->key)) p->options[item->key] = item->default_value ? item->default_value : item->values[0].value;
        return true;
    }
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS: {
        for (auto item = (retro_core_option_definition *)data; item && item->key; ++item)
            if (!p->options.count(item->key)) p->options[item->key] = item->default_value ? item->default_value : item->values[0].value;
        return true;
    }
    case RETRO_ENVIRONMENT_SET_VARIABLES: {
        for (auto item = (retro_variable *)data; item && item->key; ++item) {
            if (p->options.count(item->key) || !item->value) continue;
            std::string value(item->value);
            auto separator = value.find("; ");
            if (separator != std::string::npos) p->options[item->key] = value.substr(separator + 2, value.find('|', separator + 2) - separator - 2);
        }
        return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        auto variable = (retro_variable *)data;
        auto found = p->options.find(variable->key);
        variable->value = found == p->options.end() ? nullptr : found->second.c_str();
        return found != p->options.end();
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: *(bool *)data = false; return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        if (*(retro_pixel_format *)data != RETRO_PIXEL_FORMAT_XRGB8888 && *(retro_pixel_format *)data != RETRO_PIXEL_FORMAT_RGB565) return false;
        p->pixelFormat = *(retro_pixel_format *)data; return true;
    case RETRO_ENVIRONMENT_SET_HW_RENDER: {
        auto request = (retro_hw_render_callback *)data;
        // iOS implements OpenGL ES 3.0. Explicitly reject desktop GL/Vulkan.
        if (request->context_type != RETRO_HW_CONTEXT_OPENGLES3 &&
            !(request->context_type == RETRO_HW_CONTEXT_OPENGLES_VERSION && request->version_major == 3 && request->version_minor == 0)) return false;
        request->get_current_framebuffer = framebuffer;
        request->get_proc_address = procedure;
        p->hardware = *request; p->hardwareSelected = true; p->needsContextReset = true;
        return true;
    }
    case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER: *(unsigned *)data = RETRO_HW_CONTEXT_OPENGLES3; return true;
    case RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK: p->frameTime = *(retro_frame_time_callback *)data; return true;
    case RETRO_ENVIRONMENT_SET_GEOMETRY: return [p updateGeometry:*(retro_game_geometry *)data];
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
        auto info=(retro_system_av_info *)data;
        return [p updateGeometry:info->geometry] && [p updateTiming:info->timing];
    }
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
    case RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT: return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE:
    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT:
        // Upstream messages can contain game paths. Preserve a fixed public
        // classification, never forward arbitrary messages into exported logs.
        report(0, "The core reported a status message."); return true;
    case RETRO_ENVIRONMENT_SHUTDOWN: p->shutdownRequested = true; return true;
    default: return false;
    }
}
static void pollInput() {
    if(!active||!active->input)return;
    active->input(&active->sampled);
    // L3 is Azahar's screen-swap hotkey, not a 3DS gameplay button. Keep the
    // selected top-bottom layout consistent with the lower-screen touch map.
    if(active->engine=="azahar")active->sampled.buttons &= ~(1u << RETRO_DEVICE_ID_JOYPAD_L3);
}
static int16_t inputState(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (!active || port != 0) return 0;
    const auto &v = active->sampled;
    if (device == RETRO_DEVICE_JOYPAD) return id == RETRO_DEVICE_ID_JOYPAD_MASK ? (int16_t)v.buttons : id < 16 && (v.buttons & (1u << id)) ? 1 : 0;
    if (device == RETRO_DEVICE_ANALOG && index <= 1 && id <= 1)
        return index == 0 ? (id == 0 ? v.left_x : v.left_y) : (id == 0 ? v.right_x : v.right_y);
    if (device == RETRO_DEVICE_POINTER) {
        if (id == RETRO_DEVICE_ID_POINTER_X) return v.pointer_x;
        if (id == RETRO_DEVICE_ID_POINTER_Y) return v.pointer_y;
        if (id == RETRO_DEVICE_ID_POINTER_PRESSED) return v.pointer_down;
        if (id == RETRO_DEVICE_ID_POINTER_COUNT) return v.pointer_down ? 1 : 0;
    }
    return 0;
}
static size_t audioBatch(const int16_t *source, size_t count) {
    IRRetroPlayer *p = active;
    if (!p || !source || p->muted.load()) return count;
    uint32_t write = p->writeAudio.load(std::memory_order_relaxed);
    uint32_t read = p->readAudio.load(std::memory_order_acquire);
    size_t accepted = std::min(count, (size_t)(audioCapacity - (write - read)));
    for (size_t i = 0; i < accepted; ++i) {
        p->samples[((write + i) % audioCapacity) * 2] = source[i * 2];
        p->samples[((write + i) % audioCapacity) * 2 + 1] = source[i * 2 + 1];
    }
    p->writeAudio.store(write + (uint32_t)accepted, std::memory_order_release);
    return count; // Dropped overflow is consumed, never retried by the core.
}
static void audioSample(int16_t l, int16_t r) { const int16_t sample[] = {l, r}; audioBatch(sample, 1); }
static void videoFrame(const void *data, unsigned w, unsigned h, size_t pitch) { [active video:data width:w height:h pitch:pitch]; }

@implementation IRRetroPlayer
- (bool)restartAudio {
    if(!audioEngine)return true;
    NSError *error=nil;
    return [AVAudioSession.sharedInstance setActive:YES error:&error] &&
        (audioEngine.isRunning || [audioEngine startAndReturnError:&error]);
}
- (bool)updateGeometry:(retro_game_geometry)geometry {
    if(!geometry.base_width||!geometry.base_height||geometry.base_width>4096||geometry.base_height>4096)return false;
    double aspect=geometry.aspect_ratio>0?geometry.aspect_ratio:(double)geometry.base_width/geometry.base_height;
    if(!std::isfinite(aspect)||aspect<0.05||aspect>8)return false;
    displayAspect=aspect;return true;
}
- (bool)updateTiming:(retro_system_timing)timing {
    if(!std::isfinite(timing.fps)||timing.fps<1||timing.fps>240||!std::isfinite(timing.sample_rate)||timing.sample_rate<8000||timing.sample_rate>192000)return false;
    currentFPS=timing.fps;
    if(clock)dispatch_source_set_timer(clock,dispatch_time(DISPATCH_TIME_NOW,0),(uint64_t)(NSEC_PER_SEC/currentFPS),NSEC_PER_MSEC);
    if(audioSpeed&&initialAudioRate>0) {
        double ratio=timing.sample_rate/initialAudioRate;
        if(ratio<0.25||ratio>4)return false;
        audioSpeed.rate=(float)ratio;
    }
    return true;
}
- (bool)setPaused:(bool)value {
    if(paused==value)return true;
    if(!value && ![self restartAudio])return false;
    muted.store(true);
    [EAGLContext setCurrentContext:context];
    bool accepted=true;
    try { if(api.pause)accepted=api.pause(value); }
    catch (...) {
        // Play's mailbox flush can retain a stack-capturing marker if an
        // earlier GS call throws. Never execute that queue again via deinit.
        cleanupUncertain=true;paused=true;accepted=false;
        if(clock){dispatch_source_cancel(clock);clock=nil;}
        report(3,"The game could not pause or resume. Fully close and reopen Iridium.");
    }
    [EAGLContext setCurrentContext:nil];
    if(!accepted)return false;
    paused=value;muted.store(value);
    if(api.pause)report(0,value?"The upstream virtual machine paused.":"The upstream virtual machine resumed.");
    return true;
}
- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:CGRectZero]; root.backgroundColor = UIColor.blackColor;
    surface = [[IRRetroSurface alloc] initWithFrame:root.bounds];
    surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    surface.contentScaleFactor = UIScreen.mainScreen.scale;
    ((CAEAGLLayer *)surface.layer).drawableProperties = @{kEAGLDrawablePropertyRetainedBacking: @NO, kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8};
    [root addSubview:surface];
    software = [[UIImageView alloc] initWithFrame:root.bounds];
    software.contentMode = UIViewContentModeScaleAspectFit;
    software.autoresizingMask = surface.autoresizingMask;
    [root addSubview:software]; self.view = root;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!stopped.load()) dispatch_async(owner, ^{ [self start]; });
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if(resizeQueued.exchange(true))return;
    dispatch_async(owner, ^{
        if(self->hardwareSelected&&self->loaded&&!self->stopped&&self->displayColor) {
            [EAGLContext setCurrentContext:self->context];
            glBindRenderbuffer(GL_RENDERBUFFER,self->displayColor);
            if([self->context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self->surface.layer]) {
                glGetRenderbufferParameteriv(GL_RENDERBUFFER,GL_RENDERBUFFER_WIDTH,&self->width);
                glGetRenderbufferParameteriv(GL_RENDERBUFFER,GL_RENDERBUFFER_HEIGHT,&self->height);
            }
            [EAGLContext setCurrentContext:nil];
        }
        self->resizeQueued.store(false);
    });
}
- (void)start {
    try { [self startCore]; }
    catch (...) {
        report(3,"This game could not open. Your saves have been kept.");
        [self finish];
    }
}
- (void)startCore {
    if (starting || finishing || stopped.load()) return;
    starting = true;
    if(engine=="play" || engine=="flycast") {
        api.pause=(bool(*)(bool))dlsym(coreImage,"ir_phase3_core_pause");
        if(!api.pause) {report(3,"This emulator is unavailable. Reinstall Iridium and try again.");[self finish];return;}
#if TARGET_OS_SIMULATOR
        // Flycast deliberately compiles every CPU/DSP recompiler out for the
        // simulator. Its iOS entry point still asks the host for this flag.
        if(engine=="flycast")jit=true;
#endif
        if(!jit) { report(3,"Enable Launch Support, then try this game again."); [self finish]; return; }
        auto probe=(bool(*)(void))dlsym(coreImage,"ir_phase3_core_check_jit");
#if TARGET_OS_SIMULATOR
        bool verified=engine=="flycast" || (probe && probe());
#else
        bool verified=probe && probe();
#endif
        if(!verified) { report(3,"This emulator cannot start on this device right now. Check Launch Support and try again.");[self finish];return; }
#if TARGET_OS_SIMULATOR
        if(engine!="flycast")
#endif
            report(5,"The engine's upstream executable-memory allocator executed 42, then rewrote and executed 7.");
        if(engine=="play") {
            auto prepare=(bool(*)(const char *))dlsym(coreImage,"ir_phase3_core_prepare");
            if(!prepare || !prepare(saves.c_str())) { report(3,"Fully close and reopen Iridium before starting another PlayStation 2 game.");[self finish];return; }
        }
    }
    NSError *sessionError=nil;
    AVAudioSession *session=AVAudioSession.sharedInstance;
    audioSessionOwned=true;
    if(![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:&sessionError] ||
       ![session setActive:YES error:&sessionError]) {
        report(3,"The engine audio session could not start.");[self finish];return;
    }
    api.environment(environment); api.video(videoFrame); api.audio(audioSample); api.batch(audioBatch); api.poll(pollInput); api.input(inputState);
    context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    [EAGLContext setCurrentContext:context];
    initializationEntered=true;api.init();initialized=true;
    retro_game_info content{}; content.path = game.c_str();
    loadEntered=true;bool accepted=api.load(&content);loadReturned=true;
    if (!accepted) { report(3, "This game could not start. Check its files and any required system files."); failed = true; [self finish]; return; }
    loaded = true;
    retro_system_av_info info{}; api.av(&info);
    if(![self updateGeometry:info.geometry]||![self updateTiming:info.timing]) {report(3,"The core reported invalid geometry or timing.");[self finish];return;}
    // Use current resolution, with a bounded 4096 texture cap. Upstream maxima
    // can describe 8x modes that this build does not select.
    maxWidth = std::min(4096u, std::max(info.geometry.base_width, 1024u));
    maxHeight = std::min(4096u, std::max(info.geometry.base_height, 1024u));
    if (hardwareSelected) {
        if (!context) { report(3, "OpenGL ES 3 is unavailable."); [self finish]; return; }
        glGenFramebuffers(1, &renderTarget); glBindFramebuffer(GL_FRAMEBUFFER, renderTarget);
        glGenTextures(1, &color); glBindTexture(GL_TEXTURE_2D, color);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, maxWidth, maxHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0);
        glGenRenderbuffers(1, &depth); glBindRenderbuffer(GL_RENDERBUFFER, depth);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, maxWidth, maxHeight);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, depth);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { report(3, "The engine render target could not be created."); [self finish]; return; }
        glGenFramebuffers(1, &displayTarget); glBindFramebuffer(GL_FRAMEBUFFER, displayTarget);
        glGenRenderbuffers(1, &displayColor); glBindRenderbuffer(GL_RENDERBUFFER, displayColor);
        if (![context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)surface.layer]) { report(3, "The iOS graphics surface is unavailable."); [self finish]; return; }
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, displayColor);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);
        if (width <= 0 || height <= 0 || glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { report(3, "The iOS display target is incomplete."); [self finish]; return; }
        glBindFramebuffer(GL_FRAMEBUFFER, renderTarget);
        if (needsContextReset && hardware.context_reset) hardware.context_reset();
        needsContextReset = false;
    }
    api.controller(0, RETRO_DEVICE_JOYPAD);
    double rate = info.timing.sample_rate, fps = info.timing.fps;
    if (!std::isfinite(rate) || rate < 8000 || rate > 192000 || !std::isfinite(fps) || fps < 1 || fps > 240) { report(3, "The core reported invalid audio or video timing."); [self finish]; return; }
    samples.resize(audioCapacity * 2);
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    audioEngine = [[AVAudioEngine alloc] init];
    IRRetroPlayer *p = self;
    audioSource = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *silent, const AudioTimeStamp *, AVAudioFrameCount count, AudioBufferList *buffers) {
        uint32_t read = p->readAudio.load(std::memory_order_relaxed), write = p->writeAudio.load(std::memory_order_acquire);
        bool mute = p->muted.load();
        uint32_t available = mute ? 0 : std::min<uint32_t>(count, write - read);
        for (UInt32 channel = 0; channel < buffers->mNumberBuffers; ++channel) {
            float *out = (float *)buffers->mBuffers[channel].mData;
            for (UInt32 i = 0; i < count; ++i) out[i] = i < available ? p->samples[((read + i) % audioCapacity) * 2 + std::min(channel, 1u)] / 32768.f : 0;
        }
        p->readAudio.store(mute ? write : read + available, std::memory_order_release); *silent = available == 0; return noErr;
    }];
    initialAudioRate=rate;audioSpeed=[[AVAudioUnitVarispeed alloc]init];
    [audioEngine attachNode:audioSource];[audioEngine attachNode:audioSpeed];
    [audioEngine connect:audioSource to:audioSpeed format:format];[audioEngine connect:audioSpeed to:audioEngine.mainMixerNode format:format];
    NSError *error = nil;
    if (![audioEngine startAndReturnError:&error]) { report(3, "The engine audio output could not start."); [self finish]; return; }
    audioConfigurationObserver=[NSNotificationCenter.defaultCenter addObserverForName:AVAudioEngineConfigurationChangeNotification object:audioEngine queue:nil usingBlock:^(NSNotification *) {
        dispatch_async(p->owner, ^{
            if(p->finishing||p->stopped.load()||p->paused)return;
            if(![p restartAudio]) {report(3,"The engine audio output could not recover after a route change.");[p finish];}
        });
    }];
    audioInterruptionObserver=[NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification object:AVAudioSession.sharedInstance queue:nil usingBlock:^(NSNotification *notice) {
        bool began=[notice.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]==AVAudioSessionInterruptionTypeBegan;
        if(!began)return;
        dispatch_async(p->owner, ^{
            if(p->finishing||p->stopped.load())return;
            if(![p setPaused:true]) {report(3,"The upstream virtual machine could not pause after an audio interruption.");[p finish];return;}
            report(4,"Audio was interrupted. Resume the game when ready.");
        });
    }];
    muted.store(paused);
    clock = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, owner);
    dispatch_source_set_timer(clock, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(NSEC_PER_SEC / fps), NSEC_PER_MSEC);
    dispatch_source_set_event_handler(clock, ^{
        @autoreleasepool {
        if (self->stopped.load() || self->finishing || self->cleanupUncertain) return;
        if (self->shutdownRequested) { [self finish]; return; }
        if (self->paused) return;
        [EAGLContext setCurrentContext:self->context];
        if (self->frameTime.callback) self->frameTime.callback((retro_usec_t)(1000000 / self->currentFPS));
        try { self->api.run(); }
        catch (...) {
            report(3,"This game stopped unexpectedly. Your saves have been kept.");
            [self finish];
        }
        [EAGLContext setCurrentContext:nil];
        }
    });
    dispatch_resume(clock);
    [EAGLContext setCurrentContext:nil];
    report(0, hardwareSelected ? "Upstream core loaded; OpenGL ES; waiting for video." : "Upstream core loaded; software renderer; waiting for video.");
}
- (void)video:(const void *)data width:(unsigned)w height:(unsigned)h pitch:(size_t)pitch {
    if (!data || paused || finishing || stopped.load() || !w || !h || w > 4096 || h > 4096) return;
    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        if (!hardwareSelected || w > maxWidth || h > maxHeight) { shutdownRequested = true; report(3, "The core exceeded the configured render target."); return; }
        glBindFramebuffer(GL_READ_FRAMEBUFFER, renderTarget); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, displayTarget);
        glDisable(GL_SCISSOR_TEST); glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
        double aspect=displayAspect>0?displayAspect:(double)w/h;
        GLint rw=(GLint)std::min((double)width,height*aspect),rh=(GLint)(rw/aspect),x=(width-rw)/2,y=(height-rh)/2;
        glBlitFramebuffer(0, hardware.bottom_left_origin ? 0 : h, w, hardware.bottom_left_origin ? h : 0, x,y,x+rw,y+rh,GL_COLOR_BUFFER_BIT,GL_NEAREST);
        glBindRenderbuffer(GL_RENDERBUFFER, displayColor);
        if (![context presentRenderbuffer:GL_RENDERBUFFER]) return;
        glBindFramebuffer(GL_FRAMEBUFFER, renderTarget);
    } else {
        const size_t bpp = pixelFormat == RETRO_PIXEL_FORMAT_RGB565 ? 2 : 4;
        if (pitch < w * bpp || pitch > 65536 || imagePending.exchange(true)) return;
        NSMutableData *rgba = [NSMutableData dataWithLength:(size_t)w*h*4];
        uint8_t *dest = (uint8_t *)rgba.mutableBytes;
        for (unsigned y=0;y<h;++y) for(unsigned x=0;x<w;++x) {
            uint32_t value;
            if (bpp==2) { uint16_t raw; memcpy(&raw,(const uint8_t*)data+y*pitch+x*2,2); value=((raw>>11)*255/31<<16)|(((raw>>5)&63)*255/63<<8)|((raw&31)*255/31); }
            else memcpy(&value,(const uint8_t*)data+y*pitch+x*4,4);
            size_t i=((size_t)y*w+x)*4; dest[i]=value>>16;dest[i+1]=value>>8;dest[i+2]=value;dest[i+3]=255;
        }
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB(); CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
        CGImageRef image=CGImageCreate(w,h,8,32,w*4,space,kCGImageAlphaNoneSkipLast,provider,nullptr,false,kCGRenderingIntentDefault);
        UIImage *frame=image ? [UIImage imageWithCGImage:image] : nil;
        if(image)CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(space);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self->stopped.load() && !self->muted.load()) self->software.image=frame;
            self->imagePending.store(false);
        });
    }
    if (frameCount.fetch_add(1)==0) report(1,"The upstream core produced its first video frame.");
}
- (void)finish {
    if (finishing || stopped.load() || cleanupUncertain) return;
    finishing = true; muted.store(true);
    if(audioConfigurationObserver)[NSNotificationCenter.defaultCenter removeObserver:audioConfigurationObserver];
    if(audioInterruptionObserver)[NSNotificationCenter.defaultCenter removeObserver:audioInterruptionObserver];
    audioConfigurationObserver=nil;audioInterruptionObserver=nil;
    [EAGLContext setCurrentContext:context];
    if(clock) { dispatch_source_cancel(clock); clock=nil; }
    if((initializationEntered&&!initialized)||(loadEntered&&!loadReturned)) {
        report(3,"Fully close and reopen Iridium before trying another game.");
        return;
    }
    try {
    if(loaded) api.unload();
    // Play! destroys its GS worker during retro_deinit; keep GL current while
    // it drains upstream's mailbox. Other cores destroy their context first.
    if(engine != "play" && hardwareSelected && hardware.context_destroy) hardware.context_destroy();
    if(initialized) api.deinit();
    } catch (...) {
        // An upstream worker may still own this image/context. The frontend's
        // stop deadline retains its lease and requires a process restart.
        report(3,"Fully close and reopen Iridium before trying another game.");
        return;
    }
    loaded=false;initialized=false;
    [audioEngine stop];if(audioSource)[audioEngine detachNode:audioSource];if(audioSpeed)[audioEngine detachNode:audioSpeed];audioSource=nil;audioSpeed=nil;audioEngine=nil;
    if(context) {
        glDeleteFramebuffers(1,&renderTarget);glDeleteFramebuffers(1,&displayTarget);
        glDeleteRenderbuffers(1,&depth);glDeleteRenderbuffers(1,&displayColor);glDeleteTextures(1,&color);
        [EAGLContext setCurrentContext:nil]; context=nil;
    }
    if(audioSessionOwned) {
        AVAudioSession *session=AVAudioSession.sharedInstance;
        BOOL deactivated=[session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        BOOL restored=[session setCategory:previousAudioCategory mode:previousAudioMode options:previousAudioOptions error:nil];
        if(!deactivated||!restored)report(0,"The engine stopped, but the previous audio session could not be fully restored.");
        audioSessionOwned=false;
    }
    stopped.store(true);
    report(2,"The upstream core and audio/video workers stopped.");
}
@end

extern "C" unsigned ir_native_engine_abi() { return 1; }
extern "C" void *ir_native_engine_create(const char *name,const char *binary,const char *content,const char *save,const char *assets,bool jit,uint64_t generation,IRPhase3Event event,IRPhase3Poll poll) {
    if(active && !active->stopped.load()) return nullptr;
    IRRetroPlayer *p=[[IRRetroPlayer alloc] init];
    p->engine=name;p->core=binary;p->game=content;p->saves=save;p->system=assets;p->jit=jit;p->generation=generation;p->event=event;p->input=poll;
    p->owner=dispatch_queue_create("software.iridium.upstream-core",DISPATCH_QUEUE_SERIAL);
    AVAudioSession *audio=AVAudioSession.sharedInstance;
    p->previousAudioCategory=audio.category;p->previousAudioMode=audio.mode;p->previousAudioOptions=audio.categoryOptions;
    p->pixelFormat=RETRO_PIXEL_FORMAT_XRGB8888;
    // Deterministic launch policy, independent of a previous core's options.
    if(p->engine=="azahar") {
        p->options["citra_graphics_api"]="Software";p->options["citra_use_cpu_jit"]="disabled";
        p->options["citra_use_shader_jit"]="disabled";
        p->options["citra_layout_option"]="default";p->options["citra_swap_screen"]="Top";
    }
    p->frameCount.store(0);p->muted.store(true);p->imagePending.store(false);p->resizeQueued.store(false);p->stopped.store(false);
    p->readAudio.store(0);p->writeAudio.store(0);p->samples.resize(audioCapacity*2);
    void *image=dlopen(binary,RTLD_NOW|RTLD_LOCAL);p->coreImage=image;
    if(!image) { event(generation,3,"The bundled upstream core could not be loaded."); return nullptr; }
#define BIND(member, symbol) p->api.member=(decltype(p->api.member))dlsym(image,#symbol); if(!p->api.member)return nullptr
    BIND(environment,retro_set_environment);BIND(video,retro_set_video_refresh);BIND(audio,retro_set_audio_sample);
    BIND(batch,retro_set_audio_sample_batch);BIND(poll,retro_set_input_poll);BIND(input,retro_set_input_state);
    BIND(info,retro_get_system_info);BIND(av,retro_get_system_av_info);BIND(init,retro_init);BIND(deinit,retro_deinit);
    BIND(load,retro_load_game);BIND(unload,retro_unload_game);BIND(run,retro_run);BIND(controller,retro_set_controller_port_device);
#undef BIND
    auto version=(unsigned(*)(void))dlsym(image,"retro_api_version");
    if(!version||version()!=RETRO_API_VERSION)return nullptr;
    active=p; return (__bridge_retained void *)p;
}
extern "C" void ir_native_engine_pause(bool paused) {
    IRRetroPlayer *p=active;if(!p)return;
    dispatch_async(p->owner, ^{
        if(p->finishing||p->stopped.load()||p->cleanupUncertain)return;
        if(![p setPaused:paused] && !p->cleanupUncertain) {report(3,"The game could not pause or resume. Close it and try again.");[p finish];return;}
    });
}
extern "C" void ir_native_engine_stop() {
    IRRetroPlayer *p=active;if(!p)return;
    dispatch_async(p->owner, ^{[p finish];});
}
extern "C" uint64_t ir_native_engine_frames() { return active?active->frameCount.load():0; }
