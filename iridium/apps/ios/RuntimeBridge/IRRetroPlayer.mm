// SPDX-License-Identifier: AGPL-3.0-only
// Hosts upstream libretro implementations. No guest CPU/GPU/media code lives here.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAEAGLLayer.h>
#import <QuartzCore/CAMetalLayer.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreMotion/CoreMotion.h>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <exception>
#include <stdexcept>
#include <string>
#include <vector>
#include <dlfcn.h>
#include "libretro.h"
#include "IRPhase3.h"
#include "IRAudioVolume.h"
#include "IRFlycastFaultRoute.h"
#define IR_CORE_OPTIONS_IMPLEMENTATION
#include "IRCoreOptions.h"
#include "IRDiscControl.h"
#include "IRCheats.h"
#include "IRStateFile.h"
#include "IRCoreCapture.h"

@interface IRRetroSurface : UIView
@end
@implementation IRRetroSurface
+ (Class)layerClass { return CAEAGLLayer.class; }
@end
@interface IRAzaharSurface : UIView
@end
@implementation IRAzaharSurface
+ (Class)layerClass { return CAMetalLayer.class; }
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
    decltype(&retro_serialize_size) stateSize;
    decltype(&retro_serialize) saveState;
    decltype(&retro_unserialize) loadState;
    bool (*pause)(bool);
    unsigned (*jitStatus)(void);
    bool (*metalSurface)(void *);
    bool (*cheats)(const IRCheat *, size_t);
    IRDiscResult (*changeDisc)(const char *);
};

@interface IRRetroPlayer : UIViewController {
@public
    RetroAPI api;
    IRFlycastFaultRoute flycastFaultRoute;
    dispatch_queue_t owner;
    dispatch_source_t clock;
    IRPhase3Event event;
    uint64_t generation;
    IRPhase3Poll input;
    IRPhase3PollPlayer playerInput;
    IRPhase3Rumble rumble;
    IRPhase3Input sampled[4];
    std::string engine, core, game, saves, system;
    IROptions options;
    retro_core_options_update_display_callback optionDisplay;
    bool controlsDirty;
    retro_disk_control_ext_callback discs;
    NSArray *controllerChoices[4];
    unsigned controllerDevices[4];
    CMMotionManager *motion;
    IRCoreCapture *capture;
    NSString *captureStatus;
    unsigned sensorDemand;
    retro_hw_render_callback hardware;
    retro_frame_time_callback frameTime;
    retro_pixel_format pixelFormat;
    EAGLContext *context;
    UIView *surface;
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
    bool starting, finishing, audioSessionOwned, cleanupUncertain, metalReady;
    NSString *previousAudioCategory, *previousAudioMode;
    AVAudioSessionCategoryOptions previousAudioOptions;
    id audioConfigurationObserver, audioInterruptionObserver;
    void *coreImage;
    double displayAspect;
    CGFloat surfaceAspect;
    double currentFPS, initialAudioRate;
    double diagnosticTime;
    uint64_t diagnosticFrames;
    unsigned reportedJIT;
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
- (void)controlsSnapshot;
- (void)command:(NSDictionary *)request;
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
static bool coreRumble(unsigned port, retro_rumble_effect motor, uint16_t strength) {
    return active && port < 4 && active->rumble && active->rumble(port, (unsigned)motor, strength);
}
static bool protectedOption(const char *key) {
    return key && (!strcmp(key, "citra_graphics_api") || !strcmp(key, "citra_use_cpu_jit") || !strcmp(key, "citra_use_shader_jit") || !strcmp(key,"citra_use_libretro_save_path"));
}
static IRCoreCapture *microphone(const void *handle) { return active&&handle==(__bridge const void *)active->capture?active->capture:nil; }
static void *microphoneOpen(const IRMicrophoneParams *) {return active?(__bridge void *)active->capture:nullptr;}
static void microphoneClose(void *handle) { [microphone(handle)requestMicrophone:false]; }
static bool microphoneParams(const void *handle,IRMicrophoneParams *params) {if(!microphone(handle)||!params)return false;params->rate=48000;return true;}
static bool microphoneSet(void *handle,bool value) {IRCoreCapture *capture=microphone(handle);if(!capture)return false;[capture requestMicrophone:value];return true;}
static bool microphoneGet(const void *handle) {return [microphone(handle)microphoneActive];}
static int microphoneRead(void *handle,int16_t *samples,size_t count) {IRCoreCapture *capture=microphone(handle);return capture?[capture readMicrophone:samples count:count]:-1;}
static void configureCapture(IRRetroPlayer *p) {
    IROption *camera=ir_option_find(&p->options,"iridium_camera",false),*mic=ir_option_find(&p->options,"iridium_microphone",false);
    unsigned selection=camera&&camera->value?(!strcmp(camera->value,"rear")?1:!strcmp(camera->value,"front")?2:0):0;
    [p->capture configureCamera:selection microphone:mic&&mic->value&&!strcmp(mic->value,"on")];
}
static bool allowedOption(const char *key,const char *value) {
    if(!key||!value)return false;
    if(!strcmp(key,"citra_resolution_factor")||!strcmp(key,"play_res_multi"))return atoi(value)>=1&&atoi(value)<=4;
    if(strstr(key,"_internal_resolution")) {
        unsigned width=0,height=0;
        if(sscanf(value,"%ux%u",&width,&height)==2)return width&&height&&width<=4096&&height<=4096;
    }
    return true;
}
static bool sensorState(unsigned port, retro_sensor_action action, unsigned rate) {
    IRRetroPlayer *p=active;
    if(!p||port||!p->motion.isDeviceMotionAvailable)return false;
    switch(action) {
    case RETRO_SENSOR_ACCELEROMETER_ENABLE:p->sensorDemand|=1;break;
    case RETRO_SENSOR_GYROSCOPE_ENABLE:p->sensorDemand|=2;break;
    case RETRO_SENSOR_ACCELEROMETER_DISABLE:p->sensorDemand&=~1u;break;
    case RETRO_SENSOR_GYROSCOPE_DISABLE:p->sensorDemand&=~2u;break;
    default:return false;
    }
    p->motion.deviceMotionUpdateInterval=1.0/std::clamp(rate,1u,120u);
    if(p->sensorDemand&&!p->paused)[p->motion startDeviceMotionUpdates];
    else [p->motion stopDeviceMotionUpdates];
    return true;
}
static float sensorInput(unsigned port,unsigned sensor) {
    IRRetroPlayer *p=active;if(!p||port||p->paused)return 0;
    CMDeviceMotion *sample=p->motion.deviceMotion;if(!sample)return sensor==RETRO_SENSOR_ACCELEROMETER_Z?-1:0;
    CMAcceleration g=sample.gravity,u=sample.userAcceleration;CMRotationRate r=sample.rotationRate;
    switch(sensor) {
    case RETRO_SENSOR_ACCELEROMETER_X:return -(g.x+u.x);
    case RETRO_SENSOR_ACCELEROMETER_Y:return -(g.z+u.z);
    case RETRO_SENSOR_ACCELEROMETER_Z:return g.y+u.y;
    case RETRO_SENSOR_GYROSCOPE_X:return -r.x;
    case RETRO_SENSOR_GYROSCOPE_Y:return -r.z;
    case RETRO_SENSOR_GYROSCOPE_Z:return r.y;
    default:return 0;
    }
}
static void appendOption(void *context, const char *key, const char *title, const char *info,
    const char *category, const char *value, const char *defaultValue,
    const char *const *values, const char *const *labels, size_t count, bool visible) {
    if(protectedOption(key))return;
    NSMutableArray *choices=[NSMutableArray array];
    for(size_t i=0;i<count;++i)if(allowedOption(key,values[i]))[choices addObject:@{@"value":@(values[i]),@"title":@(labels[i])}];
    [(__bridge NSMutableArray *)context addObject:@{@"key":@(key),@"title":@(title),@"info":@(info),
        @"category":@(category),@"value":@(value),@"defaultValue":@(defaultValue),@"choices":choices,@"visible":@(visible)}];
}
static bool environment(unsigned command, void *data) {
    IRRetroPlayer *p = active;
    if (!p) return false;
    switch (command) {
    case (75|RETRO_ENVIRONMENT_EXPERIMENTAL): {
        if(!data||!p->capture)return false;
        auto api=(IRMicrophoneInterface *)data;
        if(api->version!=1)return false;
        *api={1,microphoneOpen,microphoneClose,microphoneParams,microphoneSet,microphoneGet,microphoneRead};return true;
    }
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: ((retro_log_callback *)data)->log=coreLog; return true;
    case RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES:
        *(uint64_t *)data=(1ull<<RETRO_DEVICE_JOYPAD)|(1ull<<RETRO_DEVICE_ANALOG)|(1ull<<RETRO_DEVICE_POINTER);return true;
    case RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS: *(unsigned *)data=p->engine=="azahar"?1:4;return true;
    case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE:
        if(!data||!p->rumble)return false;
        ((retro_rumble_interface *)data)->set_rumble_state=coreRumble;return true;
    case RETRO_ENVIRONMENT_GET_SENSOR_INTERFACE:
        if(!data||!p->motion.isDeviceMotionAvailable)return false;
        ((retro_sensor_interface *)data)->set_sensor_state=sensorState;
        ((retro_sensor_interface *)data)->get_sensor_input=sensorInput;return true;
    case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE:
        if(!data)return false;
        { const auto& legacy=*(retro_disk_control_callback *)data;
          p->discs={legacy.set_eject_state,legacy.get_eject_state,legacy.get_image_index,legacy.set_image_index,
              legacy.get_num_images,legacy.replace_image_index,legacy.add_image_index}; }
        return true;
    case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION:
        if(!data)return false;
        *(unsigned *)data=1;return true;
    case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE:
        if(!data)return false;
        p->discs=*(retro_disk_control_ext_callback *)data;return true;
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
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
    case RETRO_ENVIRONMENT_SET_VARIABLES:
    case RETRO_ENVIRONMENT_GET_VARIABLE:
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
        if(command==RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY)p->controlsDirty=true;
        return ir_options_environment(&p->options, command, data);
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
        if(!data)return false;
        p->optionDisplay=*(retro_core_options_update_display_callback *)data;return true;
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
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:return true;
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
        if(!data)return false;
        for(unsigned port=0;port<4;++port) {
            auto info=((retro_controller_info *)data)[port];if(!info.num_types)break;
            NSMutableArray *choices=[NSMutableArray arrayWithObject:@{@"value":@"0",@"title":@"None"}];
            for(unsigned i=0;i<std::min(info.num_types,32u);++i) {
                const char *name=info.types[i].desc;
                if(!name)continue;
                NSString *title=@(name);
                if([@[@"Controller",@"Arcade Stick",@"Twin Stick",@"Saturn Twin-Stick",@"Race Controller",@"Full Controller"]containsObject:title])
                    [choices addObject:@{@"value":[NSString stringWithFormat:@"%u",info.types[i].id],@"title":title}];
            }
            p->controllerChoices[port]=choices;
        }
        return true;
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
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
    memset(active->sampled,0,sizeof active->sampled);
    if(active->playerInput)for(unsigned port=0;port<(active->engine=="azahar"?1u:4u);++port)
        active->playerInput(port,&active->sampled[port]);
    else active->input(&active->sampled[0]);
}
static int16_t inputState(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (!active || port >= 4 || (active->engine=="azahar" && port)) return 0;
    const auto &v = active->sampled[port];
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
- (void)controlsSnapshot {
    controlsDirty=false;
    NSMutableArray *items=[NSMutableArray array];
    ir_options_visit(&options,appendOption,(__bridge void *)items);
    if(engine=="flycast")for(unsigned port=0;port<4;++port)if(controllerChoices[port]) {
        NSString *value=[NSString stringWithFormat:@"%u",controllerDevices[port]];
        [items addObject:@{@"key":[NSString stringWithFormat:@"iridium_device_port_%u",port],@"title":[NSString stringWithFormat:@"Controller Port %u",port+1],
            @"category":@"Controllers",@"value":value,@"defaultValue":@"1",@"choices":controllerChoices[port],@"visible":@YES,
            @"info":@"Other ports use physical controllers. Touch and keyboard control port 1. VMU and rumble-pack choices are in the expansion-slot settings."}];
    }
    unsigned count=discs.get_num_images?discs.get_num_images():0;
    NSDictionary *snapshot=@{@"options":items,@"states":@(api.stateSize&&api.saveState&&api.loadState),
        @"discCount":@(count),@"discIndex":@(discs.get_image_index?discs.get_image_index():0),
        @"players":@(engine=="azahar"?1:engine=="play"?2:4),@"aspect":@(displayAspect>0?displayAspect:400.0/480.0),
        @"cheatFormats":api.cheats?@[@"gateway"]:@[],@"canChangeDisc":@(api.changeDisc||(discs.replace_image_index&&discs.get_image_path)),@"captureStatus":capture.status?:@""};
    NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    if(data)report(8,[[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);
}
- (void)command:(NSDictionary *)request {
    if(finishing||stopped.load()||cleanupUncertain)return;
    NSString *operation=request[@"operation"];
    if([operation isEqual:@"configure"]&&!initializationEntered) {
        NSDictionary *values=request[@"values"];
        if([values isKindOfClass:NSDictionary.class])for(id key in values) {
            id value=values[key];
            if([key isKindOfClass:NSString.class]&&[value isKindOfClass:NSString.class]&&!protectedOption([key UTF8String])&&allowedOption([key UTF8String],[value UTF8String]))
                ir_option_set(&options,[key UTF8String],[value UTF8String],true);
        }
        return;
    }
    if(!loaded)return;
    if([operation isEqual:@"snapshot"]) { [self controlsSnapshot];return; }
    if(!paused) { report(7,"Pause the game before changing core controls.");return; }
    if([operation isEqual:@"option"]) {
        id key=request[@"key"],value=request[@"value"];
        if(engine=="flycast"&&[key isKindOfClass:NSString.class]&&[value isKindOfClass:NSString.class]) {
            for(unsigned port=0;port<4;++port)if([key isEqual:[NSString stringWithFormat:@"iridium_device_port_%u",port]]) {
                for(NSDictionary *choice in controllerChoices[port])if([choice[@"value"]isEqual:value]) {
                    controllerDevices[port]=[value unsignedIntValue];api.controller(port,controllerDevices[port]);
                    if(optionDisplay.callback)optionDisplay.callback();[self controlsSnapshot];return;
                }
                report(7,"This controller type is unavailable.");return;
            }
        }
        if(![key isKindOfClass:NSString.class]||![value isKindOfClass:NSString.class]||protectedOption([key UTF8String])||!allowedOption([key UTF8String],[value UTF8String])||
           !ir_option_set(&options,[key UTF8String],[value UTF8String],false)) {
            report(7,"This core setting is unavailable.");return;
        }
        if(optionDisplay.callback)optionDisplay.callback();
        configureCapture(self);
        [self controlsSnapshot];return;
    }
    [EAGLContext setCurrentContext:context];
    bool success=false;
    try {
        if([operation isEqual:@"cheats"]&&api.cheats) {
            std::vector<IRCheat> items;
            success=ir_cheats_decode(request[@"items"],items)&&api.cheats(items.data(),items.size());
            if(success)report(6,"Cheats applied.");
        } else if([operation isEqual:@"state"]&&api.stateSize&&api.saveState&&api.loadState) {
            id slot=request[@"slot"],load=request[@"load"];
            id gameID=request[@"gameID"];
            if(gameID&&![gameID isKindOfClass:NSString.class])throw std::runtime_error("state identity");
            if(![slot isKindOfClass:NSNumber.class]||![load isKindOfClass:NSNumber.class]||[slot intValue]<0||[slot intValue]>=5)
                throw std::runtime_error("state request");
            retro_system_info info{};api.info(&info);
            NSString *identity=[NSString stringWithFormat:@"%s|%s|%s",engine.c_str(),info.library_name?:"",info.library_version?:""];
            size_t count=api.stateSize();
            if(!count||count>irStateLimit)throw std::runtime_error("state size");
            NSMutableData *current=[NSMutableData dataWithLength:count];
            if(!current||!api.saveState(current.mutableBytes,count))throw std::runtime_error("state backup");
            if([load boolValue]) {
                NSData *saved=irStateRead(saves.c_str(),[slot unsignedIntValue],identity,gameID);
                if(saved) {
                    success=api.loadState(saved.bytes,saved.length);
                    if(!success&&!api.loadState(current.bytes,current.length)) {
                        cleanupUncertain=true;report(3,"The core could not restore the game after a failed state load. Fully close and reopen Iridium.");
                    }
                }
            } else success=irStateWrite(saves.c_str(),[slot unsignedIntValue],identity,current,gameID);
            if(success) {readAudio.store(writeAudio.load());report(6,[load boolValue]?"State loaded.":"State saved.");}
        } else if([operation isEqual:@"discFile"]) {
            NSString *path=request[@"path"];
            if([path isKindOfClass:NSString.class]&&path.isAbsolutePath&&[[NSFileManager defaultManager]isReadableFileAtPath:path]) {
                const auto result=api.changeDisc?api.changeDisc(path.UTF8String):irDiscReplace(discs,path.UTF8String);
                success=result==IRDiscResult::Changed;
                if(result==IRDiscResult::RestoreFailed) {
                    cleanupUncertain=true;
                    report(3,"The previous disc could not be restored. Fully close and reopen Iridium.");
                }
                if(success)report(6,"Disc changed.");
            }
        } else if([operation isEqual:@"disc"]) {
            id number=request[@"index"];
            if([number isKindOfClass:NSNumber.class]&&[number intValue]>=0&&discs.set_eject_state&&discs.set_image_index&&discs.get_num_images&&
               [number unsignedIntValue]<discs.get_num_images()) {
                unsigned previous=discs.get_image_index?discs.get_image_index():0;
                if(discs.set_eject_state(true)) {
                    success=discs.set_image_index([number unsignedIntValue])&&discs.set_eject_state(false);
                    if(!success) {
                        bool restored=discs.set_eject_state(true);
                        restored=discs.set_image_index(previous)&&restored;
                        restored=discs.set_eject_state(false)&&restored;
                        if(!restored) {cleanupUncertain=true;report(3,"The previous disc could not be restored. Fully close and reopen Iridium.");}
                    }
                }
            }
            if(success) { [self controlsSnapshot];report(6,"Disc changed."); }
        }
    } catch (...) {success=false;}
    [EAGLContext setCurrentContext:nil];
    if(!success&&!cleanupUncertain)report(7,"The core could not complete this operation. Existing save files have been kept.");
}
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
    bool changed=displayAspect!=aspect;displayAspect=aspect;
    if(hardwareSelected&&color&&depth&&(geometry.base_width>maxWidth||geometry.base_height>maxHeight)) {
        GLint texture=0,renderbuffer=0;
        glGetIntegerv(GL_TEXTURE_BINDING_2D,&texture);glGetIntegerv(GL_RENDERBUFFER_BINDING,&renderbuffer);
        maxWidth=std::max(maxWidth,geometry.base_width);maxHeight=std::max(maxHeight,geometry.base_height);
        glBindTexture(GL_TEXTURE_2D,color);
        glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,maxWidth,maxHeight,0,GL_RGBA,GL_UNSIGNED_BYTE,nullptr);
        glBindRenderbuffer(GL_RENDERBUFFER,depth);
        glRenderbufferStorage(GL_RENDERBUFFER,GL_DEPTH24_STENCIL8,maxWidth,maxHeight);
        glBindTexture(GL_TEXTURE_2D,(GLuint)texture);glBindRenderbuffer(GL_RENDERBUFFER,(GLuint)renderbuffer);
        GLint target=0;glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&target);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER,renderTarget);
        bool complete=glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE;
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER,(GLuint)target);
        if(!complete)return false;
    }
    if(api.metalSurface) {
        unsigned w=geometry.base_width,h=geometry.base_height;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->surfaceAspect=aspect;
            ((CAMetalLayer *)self->surface.layer).drawableSize=CGSizeMake(w,h);
            [self.view setNeedsLayout];
        });
    }
    if(changed&&loaded)[self controlsSnapshot];
    return true;
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
    [capture suspend:value];
    if(value)[motion stopDeviceMotionUpdates];
    else if(sensorDemand)[motion startDeviceMotionUpdates];
    if(value&&rumble)for(unsigned port=0;port<4;++port)for(unsigned motor=0;motor<2;++motor)rumble(port,motor,0);
    if(api.pause)report(0,value?"The upstream virtual machine paused.":"The upstream virtual machine resumed.");
    return true;
}
- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:CGRectZero]; root.backgroundColor = UIColor.blackColor;
    surface = api.metalSurface ? [[IRAzaharSurface alloc] initWithFrame:root.bounds] : [[IRRetroSurface alloc] initWithFrame:root.bounds];
    surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    surface.contentScaleFactor = UIScreen.mainScreen.scale;
    if(api.metalSurface)metalReady=api.metalSurface((__bridge void *)surface.layer);
    else ((CAEAGLLayer *)surface.layer).drawableProperties = @{kEAGLDrawablePropertyRetainedBacking: @NO, kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8};
    [root addSubview:surface];
    software = [[UIImageView alloc] initWithFrame:root.bounds];
    software.contentMode = UIViewContentModeScaleAspectFit;
    software.hidden=api.metalSurface!=nullptr;
    software.autoresizingMask = surface.autoresizingMask;
    [root addSubview:software]; self.view = root;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!stopped.load()) dispatch_async(owner, ^{ [self start]; });
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if(api.metalSurface) {
        CGSize size=self.view.bounds.size;
        CGFloat aspect=surfaceAspect>0?surfaceAspect:400.0/480.0;
        CGFloat w=MIN(size.width,size.height*aspect),h=w/aspect;
        surface.frame=CGRectMake((size.width-w)/2,(size.height-h)/2,w,h);
        return;
    }
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
    if(api.metalSurface&&!metalReady) {report(3,"The 3DS Metal display could not start.");[self finish];return;}
    if(engine=="play" || engine=="flycast") {
        api.pause=(bool(*)(bool))dlsym(coreImage,"ir_phase3_core_pause");
        if(!api.pause) {report(3,"This emulator is unavailable. Reinstall Iridium and try again.");[self finish];return;}
    }
    if(engine=="azahar" || engine=="play" || engine=="flycast") {
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
        if(engine=="azahar") {
            api.jitStatus=(unsigned(*)(void))dlsym(coreImage,"ir_phase3_core_jit_status");
            if(!api.jitStatus) {report(3,"The 3DS JIT interface is incomplete.");[self finish];return;}
        }
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
    if(capture) {
        auto bind=(bool(*)(const IRCameraSource *))dlsym(coreImage,"ir_phase3_core_camera");
        IRCameraSource camera{1,(__bridge void *)capture,
            [](void *context,unsigned camera,bool active){[(__bridge IRCoreCapture *)context requestCamera:camera active:active];},
            [](void *context,uint32_t *pixels,size_t capacity,unsigned *width,unsigned *height){return [(__bridge IRCoreCapture *)context readCamera:pixels capacity:capacity width:width height:height];}};
        if(bind&&!bind(&camera)){report(3,"The 3DS camera interface is incompatible.");[self finish];return;}
        const retro_core_option_value cameras[]={{"off","Off"},{"rear","Rear Camera"},{"front","Front Camera"},{nullptr,nullptr}};
        const retro_core_option_value microphones[]={{"off","Off"},{"on","On"},{nullptr,nullptr}};
        if(bind)ir_option_define(&options,"iridium_camera","Phone Camera","Uses one phone camera for the 3DS camera view. iOS asks for access when a game requests capture.","Camera",cameras,"off");
        ir_option_define(&options,"iridium_microphone","Phone Microphone","Enable this and choose Frontend as Microphone Input. iOS asks for access when the game requests recording.","Audio",microphones,"off");
        configureCapture(self);
    }
    if(!api.metalSurface)context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    [EAGLContext setCurrentContext:context];
    if(engine=="flycast" && !flycastFaultRoute.begin()) {
        report(3,"The Dreamcast memory fault handler could not start.");[self finish];return;
    }
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
    for(unsigned port=0;port<4;++port) {
        controllerDevices[port]=RETRO_DEVICE_JOYPAD;
        if(engine=="flycast") {
            std::string key="iridium_device_port_"+std::to_string(port);
            IROption *saved=ir_option_find(&options,key.c_str(),false);
            if(saved&&saved->value)for(NSDictionary *choice in controllerChoices[port])
                if([choice[@"value"]isEqual:@(saved->value)])controllerDevices[port]=[choice[@"value"]unsignedIntValue];
        }
    }
    api.controller(0, controllerDevices[0]);
    // Flycast refreshes expansion slots only after every port is configured.
    if(engine=="flycast"||engine=="play")for(unsigned port=1;port<4;++port)api.controller(port,controllerDevices[port]);
    [self controlsSnapshot];
    double rate = info.timing.sample_rate, fps = info.timing.fps;
    if (!std::isfinite(rate) || rate < 8000 || rate > 192000 || !std::isfinite(fps) || fps < 1 || fps > 240) { report(3, "The core reported invalid audio or video timing."); [self finish]; return; }
    samples.resize(audioCapacity * 2);
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    audioEngine = [[AVAudioEngine alloc] init];
    // Quiet device tests mute only this engine's audio graph.
    const char *testMute = getenv("IRIDIUM_TEST_MUTE_AUDIO");
    if(testMute && !strcmp(testMute,"1"))audioEngine.mainMixerNode.outputVolume=0;
    IRRetroPlayer *p = self;
    audioSource = [[AVAudioSourceNode alloc] initWithFormat:format renderBlock:^OSStatus(BOOL *silent, const AudioTimeStamp *, AVAudioFrameCount count, AudioBufferList *buffers) {
        uint32_t read = p->readAudio.load(std::memory_order_relaxed), write = p->writeAudio.load(std::memory_order_acquire);
        bool mute = p->muted.load();
        uint32_t available = mute ? 0 : std::min<uint32_t>(count, write - read);
        for (UInt32 channel = 0; channel < buffers->mNumberBuffers; ++channel) {
            float *out = (float *)buffers->mBuffers[channel].mData;
            for (UInt32 i = 0; i < count; ++i) out[i] = i < available ? p->samples[((read + i) % audioCapacity) * 2 + std::min(channel, 1u)] / 32768.f : 0;
            ir_audio_volume_apply_float(out, count);
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
    diagnosticTime=CFAbsoluteTimeGetCurrent();diagnosticFrames=0;reportedJIT=0;
    clock = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, owner);
    dispatch_source_set_timer(clock, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(NSEC_PER_SEC / fps), NSEC_PER_MSEC);
    dispatch_source_set_event_handler(clock, ^{
        @autoreleasepool {
        if (self->stopped.load() || self->finishing || self->cleanupUncertain) return;
        if (self->shutdownRequested) { [self finish]; return; }
        if (self->paused) return;
        [EAGLContext setCurrentContext:self->context];
        if (self->frameTime.callback) self->frameTime.callback((retro_usec_t)(1000000 / self->currentFPS));
        try {
            self->api.run();
            NSString *captureStatus=self->capture.status;
            if(captureStatus!=self->captureStatus&&![captureStatus isEqual:self->captureStatus]) {self->captureStatus=captureStatus;self->controlsDirty=true;}
            if(self->controlsDirty)[self controlsSnapshot];
            if(self->api.jitStatus) {
                unsigned status=self->api.jitStatus();
                if((status&1)&&!(self->reportedJIT&1))report(0,"Azahar CPU JIT completed guest execution.");
                if((status&2)&&!(self->reportedJIT&2))report(0,"Azahar shader JIT completed shader execution.");
                self->reportedJIT=status;
                double now=CFAbsoluteTimeGetCurrent();
                if(now-self->diagnosticTime>=5) {
                    uint64_t frames=self->frameCount.load();
                    char message[160];
                    std::snprintf(message,sizeof message,"Azahar fps=%.2f target=%.2f cpu_jit=%u shader_jit=%u",(frames-self->diagnosticFrames)/(now-self->diagnosticTime),self->currentFPS,status&1,(status>>1)&1);
                    report(0,message);
                    self->diagnosticTime=now;self->diagnosticFrames=frames;
                }
            }
        }
        catch (const std::exception &failure) {
            std::fprintf(stderr,"[Console core] frame exception: %.240s\n",failure.what());
            report(3,"This game stopped unexpectedly. Your saves have been kept.");
            [self finish];
        }
        catch (...) {
            report(3,"This game stopped unexpectedly. Your saves have been kept.");
            [self finish];
        }
        [EAGLContext setCurrentContext:nil];
        }
    });
    dispatch_resume(clock);
    [EAGLContext setCurrentContext:nil];
    report(0, api.metalSurface ? "Azahar loaded; upstream Vulkan renderer on Metal; waiting for video." : hardwareSelected ? "Upstream core loaded; OpenGL ES; waiting for video." : "Upstream core loaded; software renderer; waiting for video.");
}
- (void)video:(const void *)data width:(unsigned)w height:(unsigned)h pitch:(size_t)pitch {
    if (!data || paused || finishing || stopped.load() || !w || !h || w > 4096 || h > 4096) return;
    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        if(api.metalSurface) {
            if(frameCount.fetch_add(1)==0)report(1,"Azahar submitted its first Vulkan frame to Metal.");
            return;
        }
        if (!hardwareSelected || w > maxWidth || h > maxHeight) { shutdownRequested = true; report(3, "The core exceeded the configured render target."); return; }
        GLint readTarget=0,drawTarget=0,previousRenderbuffer=0;GLfloat clear[4];
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&readTarget);glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&drawTarget);
        glGetIntegerv(GL_RENDERBUFFER_BINDING,&previousRenderbuffer);glGetFloatv(GL_COLOR_CLEAR_VALUE,clear);
        GLboolean scissor=glIsEnabled(GL_SCISSOR_TEST);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, renderTarget); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, displayTarget);
        glDisable(GL_SCISSOR_TEST); glClearColor(0,0,0,1); glClear(GL_COLOR_BUFFER_BIT);
        double aspect=displayAspect>0?displayAspect:(double)w/h;
        GLint rw=(GLint)std::min((double)width,height*aspect),rh=(GLint)(rw/aspect),x=(width-rw)/2,y=(height-rh)/2;
        glBlitFramebuffer(0, hardware.bottom_left_origin ? 0 : h, w, hardware.bottom_left_origin ? h : 0, x,y,x+rw,y+rh,GL_COLOR_BUFFER_BIT,GL_NEAREST);
        glBindRenderbuffer(GL_RENDERBUFFER, displayColor);
        bool presented=[context presentRenderbuffer:GL_RENDERBUFFER];
        glBindFramebuffer(GL_READ_FRAMEBUFFER,(GLuint)readTarget);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,(GLuint)drawTarget);
        glBindRenderbuffer(GL_RENDERBUFFER,(GLuint)previousRenderbuffer);glClearColor(clear[0],clear[1],clear[2],clear[3]);
        if(scissor)glEnable(GL_SCISSOR_TEST);else glDisable(GL_SCISSOR_TEST);
        if(!presented)return;
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
    [capture close];
    if (stopped.load()) return;
    muted.store(true);
    [motion stopDeviceMotionUpdates];motion=nil;sensorDemand=0;
    if(rumble)for(unsigned port=0;port<4;++port)for(unsigned motor=0;motor<2;++motor)rumble(port,motor,0);
    if(clock) { dispatch_source_cancel(clock); clock=nil; }
    if (finishing || cleanupUncertain) return;
    finishing = true;
    if(audioConfigurationObserver)[NSNotificationCenter.defaultCenter removeObserver:audioConfigurationObserver];
    if(audioInterruptionObserver)[NSNotificationCenter.defaultCenter removeObserver:audioInterruptionObserver];
    audioConfigurationObserver=nil;audioInterruptionObserver=nil;
    [EAGLContext setCurrentContext:context];
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
    if(api.metalSurface)api.metalSurface(nullptr);
    } catch (...) {
        // An upstream worker may still own this image/context. The frontend's
        // stop deadline retains its lease and requires a process restart.
        report(3,"Fully close and reopen Iridium before trying another game.");
        return;
    }
    loaded=false;initialized=false;
    ir_options_clear(&options);
    if(!flycastFaultRoute.restore()) {
        report(3,"The Dreamcast memory fault handler could not close. Fully close and reopen Iridium.");return;
    }
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

extern "C" void ir_native_engine_set_volume(float level) { ir_audio_volume_set(level); }
extern "C" unsigned ir_native_engine_abi() { return 1; }
extern "C" void *ir_native_engine_create(const char *name,const char *binary,const char *content,const char *save,const char *assets,bool jit,uint64_t generation,IRPhase3Event event,IRPhase3Poll poll) {
    if(active && !active->stopped.load()) return nullptr;
    IRRetroPlayer *p=[[IRRetroPlayer alloc] init];
    p->engine=name;p->core=binary;p->game=content;p->saves=save;p->system=assets;p->jit=jit;p->generation=generation;p->event=event;p->input=poll;
    p->owner=dispatch_queue_create("software.iridium.upstream-core",DISPATCH_QUEUE_SERIAL);
    AVAudioSession *audio=AVAudioSession.sharedInstance;
    p->previousAudioCategory=audio.category;p->previousAudioMode=audio.mode;p->previousAudioOptions=audio.categoryOptions;
    p->pixelFormat=RETRO_PIXEL_FORMAT_XRGB8888;
    if(p->engine=="azahar"){p->motion=[[CMMotionManager alloc]init];p->capture=[[IRCoreCapture alloc]init];}
    // Deterministic launch policy, independent of a previous core's options.
    if(p->engine=="azahar") {
        ir_option_set(&p->options,"citra_graphics_api","Vulkan",true);
        ir_option_set(&p->options,"citra_use_cpu_jit","enabled",true);
        ir_option_set(&p->options,"citra_use_shader_jit","enabled",true);
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
    if(p->engine=="azahar") {BIND(metalSurface,ir_phase3_core_set_metal_surface);}
#undef BIND
    p->api.stateSize=(decltype(p->api.stateSize))dlsym(image,"retro_serialize_size");
    p->api.saveState=(decltype(p->api.saveState))dlsym(image,"retro_serialize");
    p->api.loadState=(decltype(p->api.loadState))dlsym(image,"retro_unserialize");
    p->api.cheats=(decltype(p->api.cheats))dlsym(image,"ir_phase3_core_cheats");
    p->api.changeDisc=(decltype(p->api.changeDisc))dlsym(image,"ir_phase3_core_change_disc_result");
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
extern "C" void ir_native_engine_input(IRPhase3PollPlayer poll,IRPhase3Rumble rumble) {
    IRRetroPlayer *p=active;if(!p)return;
    dispatch_async(p->owner, ^{if(!p->starting){p->playerInput=poll;p->rumble=rumble;}});
}
extern "C" bool ir_native_engine_command(const char *json) {
    IRRetroPlayer *p=active;if(!p||!json||strlen(json)>131072)return false;
    NSData *data=[NSData dataWithBytes:json length:strlen(json)];
    id request=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![request isKindOfClass:NSDictionary.class]||![request[@"operation"] isKindOfClass:NSString.class])return false;
    dispatch_async(p->owner, ^{[p command:request];});return true;
}
