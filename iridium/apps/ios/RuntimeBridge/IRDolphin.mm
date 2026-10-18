// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
// Embedding adapter derived from DolphiniOS's EmulationCoordinator and
// DolphinCoreService. The upstream Metal renderer, core and host queue are used.
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>
#include <atomic>
#include <algorithm>
#include "IRPhase3.h"
#include "Common/FileUtil.h"
#include "Common/IniFile.h"
#include "Common/WindowSystemInfo.h"
#include "Core/Boot/Boot.h"
#include "Core/BootManager.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Core.h"
#include "Core/DolphinAnalytics.h"
#include "Core/HW/GCPad.h"
#include "Core/HW/Wiimote.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/System.h"
#include "InputCommon/InputConfig.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"
#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "InputCommon/ControllerInterface/iOS/StateManager.h"
#include "UICommon/UICommon.h"
#include "VideoCommon/VideoEvents.h"
#include "VideoCommon/VideoConfig.h"
#include "HostQueue.h"
dispatch_queue_t DOLHostQueueGetUnderlyingQueue();

@interface IRDolphinPlayer : UIViewController {
@public
    std::string game, saves, assets;
    MTKView *metal;
    IRPhase3Event event;
    uint64_t generation;
    IRPhase3Poll input;
    std::atomic<uint64_t> frames;
    std::atomic<bool> ended;
    bool initialized, stopping, paused, started, finishing, cleanupUncertain;
    Common::EventHook presentation, sampling;
    dispatch_source_t watcher;
}
- (void)boot;
- (void)bootCore;
- (void)finish;
@end
static IRDolphinPlayer *active;
static void uncertainShutdown(IRDolphinPlayer *p) {
    p->cleanupUncertain=true;
    if(p->watcher){dispatch_source_cancel(p->watcher);p->watcher=nil;}
    p->event(p->generation,3,"Dolphin could not confirm a safe runtime transition. Restart Iridium before launching another game.");
}

static void sampleController(IRDolphinPlayer *p) {
    using namespace ciface::iOS;
    IRPhase3Input v{};p->input(&v);
    auto manager=StateManager::GetInstance();
    const std::pair<ButtonType,unsigned> buttons[]={{BUTTON_A,8},{BUTTON_B,0},{BUTTON_X,9},{BUTTON_Y,1},{BUTTON_START,3},{BUTTON_Z,13},{BUTTON_UP,4},{BUTTON_DOWN,5},{BUTTON_LEFT,6},{BUTTON_RIGHT,7}};
    for(auto [button,bit]:buttons)manager->SetButtonPressed(0,button,(v.buttons&(1u<<bit))!=0);
    float x=v.left_x/32768.f,y=-v.left_y/32768.f,rx=v.right_x/32768.f,ry=-v.right_y/32768.f;
    const std::pair<ButtonType,float> axes[]={{STICK_MAIN_LEFT,-x},{STICK_MAIN_RIGHT,x},{STICK_MAIN_UP,y},{STICK_MAIN_DOWN,-y},{STICK_C_LEFT,-rx},{STICK_C_RIGHT,rx},{STICK_C_UP,ry},{STICK_C_DOWN,-ry},{TRIGGER_L,(v.buttons&(1<<10))?1.f:0.f},{TRIGGER_R,(v.buttons&(1<<11))?1.f:0.f}};
    for(auto [axis,value]:axes)manager->SetAxisValue(0,axis,std::max(0.f,value));
    const std::pair<ButtonType,unsigned> wii[]={{WIIMOTE_BUTTON_A,8},{WIIMOTE_BUTTON_B,0},{WIIMOTE_BUTTON_MINUS,2},{WIIMOTE_BUTTON_PLUS,3},{WIIMOTE_BUTTON_HOME,14},{WIIMOTE_BUTTON_1,1},{WIIMOTE_BUTTON_2,9},{WIIMOTE_UP,4},{WIIMOTE_DOWN,5},{WIIMOTE_LEFT,6},{WIIMOTE_RIGHT,7},{NUNCHUK_BUTTON_C,10},{NUNCHUK_BUTTON_Z,11}};
    for(auto [button,bit]:wii)manager->SetButtonPressed(4,button,(v.buttons&(1u<<bit))!=0);
    const std::pair<ButtonType,float> wiiAxes[]={{NUNCHUK_STICK_LEFT,-x},{NUNCHUK_STICK_RIGHT,x},{NUNCHUK_STICK_UP,y},{NUNCHUK_STICK_DOWN,-y},{WIIMOTE_IR_LEFT,-rx},{WIIMOTE_IR_RIGHT,rx},{WIIMOTE_IR_UP,ry},{WIIMOTE_IR_DOWN,-ry}};
    for(auto [axis,value]:wiiAxes)manager->SetAxisValue(4,axis,std::max(0.f,value));
}

@implementation IRDolphinPlayer
- (void)loadView {
    metal=[[MTKView alloc]initWithFrame:CGRectZero device:MTLCreateSystemDefaultDevice()];
    metal.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    metal.preferredFramesPerSecond=120;metal.paused=YES;metal.enableSetNeedsDisplay=NO;
    metal.backgroundColor=UIColor.blackColor;self.view=metal;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if(started)return;started=true;
    DOLHostQueueRunAsync(^{[self boot];});
}
- (void)boot {
    try { [self bootCore]; }
    catch (...) {
        cleanupUncertain=true;
        event(generation,3,"Dolphin failed during initialization. Restart Iridium before launching another game.");
    }
}
- (void)bootCore {
    if(ended.load())return;
    auto &system=Core::System::GetInstance();
    // Upstream iOS resolves its complete Sys tree from the main app bundle.
    UICommon::SetUserDirectory(saves+"/");UICommon::CreateDirectories();UICommon::Init();initialized=true;
    WindowSystemInfo wsi;wsi.type=WindowSystemType::iOS;
    wsi.render_surface=(__bridge void *)metal.layer;wsi.render_surface_scale=metal.contentScaleFactor;
    UICommon::InitControllers(wsi);
    for(auto config:{Pad::GetConfig(),Wiimote::GetConfig()}) {
        Common::IniFile ini;
        if(ini.Load(config->GetSysProfileDirectoryPath()+"Touchscreen.ini")) {
            auto controller=config->GetController(0);controller->LoadConfig(ini.GetOrCreateSection("Profile"));controller->UpdateReferences(g_controller_interface);
        }
    }
    Config::SetBase(Config::MAIN_CPU_CORE,PowerPC::CPUCore::CachedInterpreter);
    Config::SetBase(Config::MAIN_FASTMEM,false);Config::SetBase(Config::MAIN_FASTMEM_ARENA,false);
    Config::SetBase(Config::MAIN_DSP_HLE,true);Config::SetBase(Config::MAIN_DSP_JIT,false);
    Config::SetBase(Config::MAIN_GFX_BACKEND,std::string("Metal"));
    Config::SetBase(Config::MAIN_AUDIO_BACKEND,std::string(BACKEND_COREAUDIO));
    Config::SetBase(Config::GFX_VERTEX_LOADER_TYPE,VertexLoaderType::Software);
    DolphinAnalytics::Instance().ReportDolphinStart("ios");
    IRDolphinPlayer *p=self;
    presentation=AfterPresentEvent::Register([p](PresentInfo &){
        if(p->frames.fetch_add(1)==0)p->event(p->generation,1,"Dolphin submitted its first Metal frame; cached interpreter selected.");
    },"Iridium presentation");
    sampling=VIEndFieldEvent::Register([p]{sampleController(p);},"Iridium shared input");
    auto boot=BootParameters::GenerateFromFile({game},BootSessionData());
    if(!boot||!BootManager::BootCore(system,std::move(boot),wsi)) {
        event(generation,3,"Dolphin could not boot this game. Check the dump and any user-supplied Wii prerequisites.");[self finish];return;
    }
    event(generation,0,"DolphiniOS upstream runtime loaded; Metal; cached interpreter; no executable memory requested.");
    watcher=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,DOLHostQueueGetUnderlyingQueue());
    dispatch_source_set_timer(watcher,dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_MSEC),25*NSEC_PER_MSEC,NSEC_PER_MSEC);
    dispatch_source_set_event_handler(watcher,^{
        Core::DeclareAsHostThread();
        try {
        auto &system=Core::System::GetInstance();
        if(Core::GetState(system)==Core::State::Uninitialized)[self finish];
        else if(self->paused&&Core::GetState(system)==Core::State::Running)Core::SetState(system,Core::State::Paused);
        } catch (...) {uncertainShutdown(self);}
        Core::UndeclareAsHostThread();
    });dispatch_resume(watcher);
}
- (void)finish {
    if(ended.load()||finishing||cleanupUncertain)return;
    finishing=true;
    if(watcher){dispatch_source_cancel(watcher);watcher=nil;}
    auto &system=Core::System::GetInstance();
    try {
        Core::Shutdown(system);presentation.reset();sampling.reset();
        if(initialized){Config::Save();UICommon::ShutdownControllers();UICommon::Shutdown();initialized=false;}
    } catch (...) {
        cleanupUncertain=true;
        event(generation,3,"Dolphin could not confirm shutdown. Restart Iridium before launching another game.");return;
    }
    ended.store(true);
    event(generation,2,"Dolphin stopped and saved its isolated configuration and memory cards.");
}
@end

extern "C" unsigned ir_native_engine_abi(){return 1;}
extern "C" void *ir_native_engine_create(const char *,const char *,const char *game,const char *save,const char *assets,bool,uint64_t generation,IRPhase3Event event,IRPhase3Poll input) {
    if(active&&!active->ended.load())return nullptr;
    IRDolphinPlayer *p=[[IRDolphinPlayer alloc]init];p->game=game;p->saves=save;p->assets=assets;p->generation=generation;p->event=event;p->input=input;p->frames.store(0);p->ended.store(false);active=p;
    return (__bridge_retained void *)p;
}
extern "C" void ir_native_engine_pause(bool paused) {
    IRDolphinPlayer *p=active;if(!p)return;
    DOLHostQueueRunAsync(^{
        if(p->cleanupUncertain||p->ended.load())return;
        try {p->paused=paused;auto &system=Core::System::GetInstance();if(Core::IsRunning(system))Core::SetState(system,paused?Core::State::Paused:Core::State::Running);}
        catch (...) {uncertainShutdown(p);}
    });
}
extern "C" void ir_native_engine_stop() {
    IRDolphinPlayer *p=active;if(!p)return;
    DOLHostQueueRunAsync(^{
        if(p->cleanupUncertain||p->ended.load())return;
        try {
        p->stopping=true;auto &system=Core::System::GetInstance();
        auto state=Core::GetState(system);
        if(state!=Core::State::Uninitialized&&state!=Core::State::Stopping)Core::Stop(system);
        else if(state==Core::State::Uninitialized)[p finish];
        } catch (...) {uncertainShutdown(p);}
    });
}
extern "C" uint64_t ir_native_engine_frames(){return active?active->frames.load():0;}
