// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
// Embedding adapter derived from DolphiniOS's EmulationCoordinator and
// DolphinCoreService. The upstream Metal renderer, core and host queue are used.
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>
#include <atomic>
#include <algorithm>
#include "IRDolphinAPI.h"
#include "IRAudioVolume.h"
#include "IRCheats.h"
#include "IRJITExecutionProbe.h"
#include <filesystem>
#include <cstring>
#include <cstdio>
#include <memory>
#include <mach/mach.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>
#include "Common/MemoryUtil.h"
#include "Common/MsgHandler.h"
#include "Core/WiiUtils.h"
#include "AudioCommon/AudioCommon.h"
#include "Core/State.h"
#include "Core/ConfigManager.h"
#include "Core/GeckoCode.h"
#include "Core/GeckoCodeConfig.h"
#include "Core/ActionReplay.h"
#include "Core/ARDecrypt.h"
#include <sstream>
#include "Core/Config/WiimoteSettings.h"
#include "Core/HW/SI/SI_Device.h"
#include "VideoCommon/PerformanceMetrics.h"
#include "Common/FileUtil.h"
#include "Common/IniFile.h"
#include "Common/WindowSystemInfo.h"
#include "Core/Boot/Boot.h"
#include "Core/BootManager.h"
#include "Core/Config/MainSettings.h"
#include "Core/Config/GraphicsSettings.h"
#include "IRDolphinOptions.h"
#include "Core/Core.h"
#include "Core/PatchEngine.h"
#include "Core/HW/DVD/DVDInterface.h"
#include "DiscIO/Volume.h"
#include "DiscIO/VolumeDisc.h"
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
#include "IRSharedJITMemory.h"
dispatch_queue_t DOLHostQueueGetUnderlyingQueue();

@interface IRDolphinPlayer : UIViewController {
@public
    std::string game, saves, assets;
    MTKView *metal;
    IRPhase3Event event;
    uint64_t generation;
    IRPhase3Poll input;
    IRDolphinPoll dolphinInput;
    IRDolphinOptions options;
    NSDictionary *extraOptions;
    NSArray *managedCheats;
    std::atomic<uint64_t> inputSamples;
    std::atomic<bool> jitVerified;
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
static std::atomic<bool> maintenanceUncertain{false};
static std::atomic<ptrdiff_t> sharedDifference{0};
extern "C" void *ir_dolphin_jit_allocate(size_t bytes) {
    const size_t page = getpagesize();
    if (!bytes || bytes > SIZE_MAX - (page - 1)) return nullptr;
    bytes = (bytes + page - 1) & ~(page - 1);
    void *write = nullptr;
    void *rx = ir_shared_jit_allocate(bytes, &write);
    if (!rx) return nullptr;
    ptrdiff_t difference = (intptr_t)write - (intptr_t)rx;
    ptrdiff_t expected = 0;
    sharedDifference.compare_exchange_strong(expected, difference);
    if (!difference || sharedDifference.load() != difference) { ir_shared_jit_release(rx); return nullptr; }
    return rx;
}
extern "C" void ir_dolphin_jit_release(void *code) { ir_shared_jit_release(code); }
extern "C" ptrdiff_t ir_dolphin_jit_difference() { return sharedDifference.load(); }
static bool dolphinAlert(const char *caption,const char *text,bool yesNo,Common::MsgType) {
    if(NSThread.isMainThread)return false;
    NSString *title=[NSString stringWithUTF8String:caption?caption:"Dolphin"];
    NSString *message=[NSString stringWithUTF8String:text?text:""];
    auto answer=std::make_shared<std::atomic<int>>(-1);
    dispatch_semaphore_t signal=dispatch_semaphore_create(0);
    __block UIAlertController *alert;
    dispatch_async(dispatch_get_main_queue(),^{
        if(answer->load()!=-1)return;
        UIWindow *window=nil;
        for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)
            if([scene isKindOfClass:UIWindowScene.class])
                for(UIWindow *candidate in ((UIWindowScene *)scene).windows)if(candidate.isKeyWindow)window=candidate;
        UIViewController *presenter=window.rootViewController;
        while(presenter.presentedViewController)presenter=presenter.presentedViewController;
        if(!presenter){answer->store(0);dispatch_semaphore_signal(signal);return;}
        alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:yesNo?@"Cancel":@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *){
            answer->store(yesNo?0:1);dispatch_semaphore_signal(signal);
        }]];
        if(yesNo)[alert addAction:[UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *){
            answer->store(1);dispatch_semaphore_signal(signal);
        }]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
    if(dispatch_semaphore_wait(signal,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))!=0) {
        answer->store(0);
        dispatch_async(dispatch_get_main_queue(),^{[alert dismissViewControllerAnimated:YES completion:nil];});
    }
    return answer->load()==1;
}
extern "C" int csops(pid_t, unsigned, void *, size_t);

static bool prepareNativeJIT() {
#if TARGET_OS_SIMULATOR
    return false;
#else
    unsigned flags=0;
    if(csops(getpid(),0,&flags,sizeof flags)!=0||!(flags&0x10000000))return false;
    const Common::JitType type=Common::JitType::LuckTXM;
    Common::SetJitType(type);
    std::fputs("[Dolphin JIT] stage=allocate\n",stderr);
    Common::AllocateExecutableMemoryRegion();
    void *rx=Common::AllocateExecutableMemory(4096);if(!rx)return false;
    ptrdiff_t diff=Common::AllocateWritableRegionAndGetDiff(rx,4096);
    if(type!=Common::JitType::Legacy&&diff==0){Common::FreeExecutableMemory(rx,4096);return false;}
    auto rw=static_cast<uint8_t *>(rx)+diff;
    if(type==Common::JitType::Legacy)Common::JITPageWriteEnableExecuteDisable(rx);
    vm_address_t address=reinterpret_cast<vm_address_t>(rw);vm_size_t length=0;
    vm_region_basic_info_data_64_t info{};mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=MACH_PORT_NULL;
    auto kr=vm_region_64(mach_task_self(),&address,&length,VM_REGION_BASIC_INFO_64,
        reinterpret_cast<vm_region_info_t>(&info),&count,&object);
    if(object!=MACH_PORT_NULL)mach_port_deallocate(mach_task_self(),object);
    if(kr!=KERN_SUCCESS||address>reinterpret_cast<vm_address_t>(rw)||!(info.protection&VM_PROT_WRITE)) {
        if(type==Common::JitType::Legacy)Common::JITPageWriteDisableExecuteEnable(rx);
        Common::FreeWritableRegion(rx,4096,diff);Common::FreeExecutableMemory(rx,4096);return false;
    }
    const uint32_t first[]={0xd2800540,0xd65f03c0}; // return 42
    memcpy(rw,first,sizeof first);
    if(type==Common::JitType::Legacy)Common::JITPageWriteDisableExecuteEnable(rx);
    sys_icache_invalidate(rx,sizeof first);
    std::fputs("[Dolphin JIT] stage=execute\n",stderr);
    bool passed=ir_jit_probe_execute(rx,sizeof first,42);
    if(passed) {
        if(type==Common::JitType::Legacy)Common::JITPageWriteEnableExecuteDisable(rx);
        const uint32_t second[]={0xd28000e0,0xd65f03c0}; // return 7 after rewriting
        memcpy(rw,second,sizeof second);
        if(type==Common::JitType::Legacy)Common::JITPageWriteDisableExecuteEnable(rx);
        sys_icache_invalidate(rx,sizeof second);
        passed=ir_jit_probe_execute(rx,sizeof second,7);
    }
    Common::FreeWritableRegion(rx,4096,diff);Common::FreeExecutableMemory(rx,4096);
    std::fprintf(stderr,"[Dolphin JIT] stage=complete passed=%d\n",passed);
    return passed;
#endif
}
static void uncertainShutdown(IRDolphinPlayer *p) {
    p->cleanupUncertain=true;
    if(p->watcher){dispatch_source_cancel(p->watcher);p->watcher=nil;}
    p->event(p->generation,3,"Dolphin could not pause or close this game. Fully close and reopen Iridium.");
}

static IRDolphinOptions validated(IRDolphinOptions value) {
    value.resolution=std::clamp(value.resolution,1,4);
    value.aspect=std::clamp(value.aspect,0,2);value.remote=std::clamp(value.remote,0,2);
    value.players=std::clamp(value.players,1,4);return value;
}

static bool installProfiles(IRDolphinPlayer *p) {
    auto lock=ControllerEmu::EmulatedController::GetStateLock();
    for(auto config:{Pad::GetConfig(),Wiimote::GetConfig()}) {
        Common::IniFile ini;
        if(!ini.Load(config->GetSysProfileDirectoryPath()+"Touchscreen.ini"))return false;
        auto profile=ini.GetOrCreateSection("Profile");
        bool wii=config==Wiimote::GetConfig();
        for(int index=0;index<4;++index) {
            profile->Set("Device","iOS/"+std::to_string(index+(wii?4:0))+"/Touchscreen");
            if(wii) {
                profile->Set("Extension",std::string(p->options.remote==1?"Nunchuk":p->options.remote==2?"Classic":"None"));
                profile->Set("Options/Sideways Wiimote",p->options.remote==0);
            }
            auto controller=config->GetController(index);
            controller->LoadConfig(profile);controller->UpdateReferences(g_controller_interface);
        }
        // Boot and title changes reload these files. In-memory profiles alone are lost.
        config->SaveConfig();
    }
    return true;
}

static void graphicsSettings(IRDolphinOptions options) {
    Config::SetCurrent(Config::GFX_EFB_SCALE,options.resolution);
    Config::SetCurrent(Config::GFX_ASPECT_RATIO,static_cast<AspectMode>(options.aspect));
    Config::SetCurrent(Config::MAIN_AUDIO_MUTED,options.muted);
}
static void dolphinControls(IRDolphinPlayer *p, NSDictionary *values) {
    NSString *gameID=@(SConfig::GetInstance().GetGameID().c_str());
    bool validID=p->frames.load()>0&&gameID.length>=4&&gameID.length<=16&&[gameID rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet]invertedSet]].location==NSNotFound;
    NSDictionary *folders=validID?@{@"Texture Packs":[@"Load/Textures/" stringByAppendingString:gameID],@"Game Patches":@"GameSettings",@"Shaders":@"Shaders"}:@{};
    NSMutableArray *patches=[NSMutableArray array];
    if(validID) {
        auto& config=SConfig::GetInstance();std::vector<PatchEngine::Patch> entries;
        PatchEngine::LoadPatchSection("OnFrame",&entries,config.LoadDefaultGameIni(),config.LoadLocalGameIni());
        for(const auto& patch:entries) {
            std::string code;for(const auto& line:patch.entries)code+=PatchEngine::SerializeLine(line)+"\n";
            [patches addObject:@{@"name":@(patch.name.c_str()),@"code":@(code.c_str()),@"enabled":@(patch.enabled),@"userDefined":@(patch.user_defined)}];
        }
    }
    NSDictionary *snapshot=@{@"options":irDolphinOptions(values),@"states":@YES,@"discCount":@0,@"discIndex":@0,
        @"players":@(p->options.players),@"aspect":@(4.0/3.0),@"cheatFormats":@[@"gecko",@"ar"],@"canChangeDisc":@YES,@"contentFolders":folders,@"patches":patches};
    NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    if(data)p->event(p->generation,8,[[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding] UTF8String]);
}

static bool dolphinCheats(id records) {
    std::vector<IRCheat> items;
    if(!ir_cheats_decode(records,items))return false;
    auto& config=SConfig::GetInstance();
    auto global=config.LoadDefaultGameIni(),local=config.LoadLocalGameIni();
    auto gecko=Gecko::LoadCodes(global,local);
    auto ar=ActionReplay::LoadCodes(global,local);
    for(const auto& item:items) {
        bool isGecko=!strcmp(item.format,"gecko");
        if(!isGecko&&strcmp(item.format,"ar"))return false;
        Gecko::GeckoCode gc;gc.name=item.name;gc.enabled=item.enabled;gc.user_defined=true;
        ActionReplay::ARCode ac;ac.name=item.name;ac.enabled=item.enabled;ac.user_defined=true;
        std::vector<std::string> encrypted;
        std::istringstream stream(item.code);
        for(std::string line;std::getline(stream,line);) {
            auto first=line.find_first_not_of(" \t\r"),last=line.find_last_not_of(" \t\r");
            if(first==std::string::npos)continue;
            line=line.substr(first,last-first+1);
            uint32_t address,value;
            if(ir_cheat_pair(line.c_str(),&address,&value)) {
                if(isGecko)gc.codes.push_back({address,value,line});
                else ac.ops.emplace_back(address,value);
            } else if(!isGecko&&std::holds_alternative<ActionReplay::EncryptedLine>(ActionReplay::DeserializeLine(line)))encrypted.push_back(line);
            else return false;
        }
        if(!encrypted.empty()) {
            if(!ac.ops.empty())return false;
            ActionReplay::DecryptARCode(encrypted,&ac.ops);
        }
        if(isGecko) {if(gc.codes.empty())return false;gecko.push_back(std::move(gc));}
        else {if(ac.ops.empty())return false;ar.push_back(std::move(ac));}
    }
    if(std::any_of(items.begin(),items.end(),[](const IRCheat& item){return item.enabled;}))
        Config::SetCurrent(Config::MAIN_ENABLE_CHEATS,true);
    Gecko::SetActiveCodes(gecko,config.GetGameID(),config.GetRevision());
    ActionReplay::ApplyCodes(ar,config.GetGameID(),config.GetRevision());
    return true;
}

static bool dolphinPatches(id records, NSArray *managedCheats) {
    std::vector<IRCheat> items;if(!ir_cheats_decode(records,items))return false;
    auto& config=SConfig::GetInstance();auto global=config.LoadDefaultGameIni(),local=config.LoadLocalGameIni();
    std::vector<PatchEngine::Patch> existing,pending;
    PatchEngine::LoadPatchSection("OnFrame",&existing,global,local);
    for(auto patch:existing)if(!patch.user_defined){patch.enabled=false;pending.push_back(std::move(patch));}
    std::vector<std::string> names;
    for(const auto& item:items) {
        if(strcmp(item.format,"patch")||std::find(names.begin(),names.end(),item.name)!=names.end())return false;
        names.emplace_back(item.name);
        PatchEngine::Patch patch;patch.name=item.name;patch.enabled=item.enabled;patch.user_defined=true;
        std::istringstream stream(item.code);
        for(std::string line;std::getline(stream,line);) {
            if(line.find_first_not_of(" \t\r")==std::string::npos)continue;
            auto entry=PatchEngine::DeserializeLine(line);if(!entry)return false;patch.entries.push_back(*entry);
        }
        if(patch.entries.empty())return false;
        auto builtin=std::find_if(pending.begin(),pending.end(),[&](const auto& old){return old.name==patch.name;});
        if(builtin!=pending.end()) {
            if(builtin->entries.size()!=patch.entries.size())return false;
            for(size_t i=0;i<patch.entries.size();++i)if(PatchEngine::SerializeLine(builtin->entries[i])!=PatchEngine::SerializeLine(patch.entries[i]))return false;
            builtin->enabled=patch.enabled;
        } else pending.push_back(std::move(patch));
    }
    PatchEngine::SavePatchSection(&local,pending);
    std::string path=File::GetUserPath(D_GAMESETTINGS_IDX)+config.GetGameID()+".ini";
    if(!local.Save(path))return false;
    PatchEngine::Reload(Core::System::GetInstance());
    return !managedCheats||dolphinCheats(managedCheats);
}

static void sampleController(IRDolphinPlayer *p) {
    using namespace ciface::iOS;
    static uint32_t lastButtons[4]{};static unsigned loggedButtons=0;
    auto manager=StateManager::GetInstance();
    for(unsigned index=0;index<4;++index) {
        IRDolphinInput sample{};
        if(index<static_cast<unsigned>(p->options.players)) {
            if(p->dolphinInput)p->dolphinInput(index,&sample);
            else if(index==0)p->input(&sample.controls);
        }
        auto &v=sample.controls;
        if(v.buttons!=lastButtons[index]) {
            lastButtons[index]=v.buttons;
            if(v.buttons&&loggedButtons<16) {
                ++loggedButtons;std::fprintf(stderr,"[Dolphin input] player=%u buttons=%u\n",index+1,v.buttons);
            }
        }
        auto buttons=[&](int id,std::initializer_list<std::pair<ButtonType,unsigned>> bindings) {
            for(auto [button,bit]:bindings)manager->SetButtonPressed(id,button,(v.buttons&(1u<<bit))!=0);
        };
        auto axes=[&](int id,std::initializer_list<std::pair<ButtonType,float>> bindings) {
            for(auto [axis,value]:bindings)manager->SetAxisValue(id,axis,std::clamp(value,-1.f,1.f));
        };
        float x=v.left_x/32768.f,y=-v.left_y/32768.f,rx=v.right_x/32768.f,ry=-v.right_y/32768.f;
        float l=std::max(sample.left_trigger,(v.buttons&(1<<10))?1.f:0.f);
        float r=sample.right_trigger;
        buttons(index,{{BUTTON_A,8},{BUTTON_B,0},{BUTTON_X,9},{BUTTON_Y,1},{BUTTON_START,3},
            {BUTTON_Z,11},{BUTTON_UP,4},{BUTTON_DOWN,5},{BUTTON_LEFT,6},{BUTTON_RIGHT,7}});
        axes(index,{{STICK_MAIN_LEFT,x},{STICK_MAIN_RIGHT,x},{STICK_MAIN_UP,-y},{STICK_MAIN_DOWN,-y},
            {STICK_C_LEFT,rx},{STICK_C_RIGHT,rx},{STICK_C_UP,-ry},{STICK_C_DOWN,-ry},{TRIGGER_L,l},{TRIGGER_R,r}});
        int wii=index+4;
        buttons(wii,{{WIIMOTE_BUTTON_A,8},{WIIMOTE_BUTTON_B,0},{WIIMOTE_BUTTON_MINUS,2},{WIIMOTE_BUTTON_PLUS,3},
            {WIIMOTE_BUTTON_1,1},{WIIMOTE_BUTTON_2,9},{WIIMOTE_UP,4},{WIIMOTE_DOWN,5},
            {WIIMOTE_LEFT,6},{WIIMOTE_RIGHT,7},{NUNCHUK_BUTTON_C,10},{NUNCHUK_BUTTON_Z,11},
            {CLASSIC_BUTTON_A,8},{CLASSIC_BUTTON_B,0},{CLASSIC_BUTTON_X,9},{CLASSIC_BUTTON_Y,1},
            {CLASSIC_BUTTON_MINUS,2},{CLASSIC_BUTTON_PLUS,3},{CLASSIC_BUTTON_HOME,14},
            {CLASSIC_BUTTON_ZL,10},{CLASSIC_BUTTON_ZR,11},{CLASSIC_DPAD_UP,4},{CLASSIC_DPAD_DOWN,5},
            {CLASSIC_DPAD_LEFT,6},{CLASSIC_DPAD_RIGHT,7}});
        manager->SetButtonPressed(wii,WIIMOTE_BUTTON_HOME,(v.buttons&((p->options.remote==2?0u:1u<<13)|(1u<<14)))!=0);
        for(auto button:{WIIMOTE_SHAKE_X,WIIMOTE_SHAKE_Y,WIIMOTE_SHAKE_Z})
            manager->SetButtonPressed(wii,button,p->options.remote!=2&&(v.buttons&(1u<<12)));
        float irx=v.pointer_down?v.pointer_x/32768.f:rx,iry=v.pointer_down?-v.pointer_y/32768.f:ry;
        axes(wii,{{NUNCHUK_STICK_LEFT,x},{NUNCHUK_STICK_RIGHT,x},{NUNCHUK_STICK_UP,-y},{NUNCHUK_STICK_DOWN,-y},
            {WIIMOTE_IR_LEFT,irx},{WIIMOTE_IR_RIGHT,irx},{WIIMOTE_IR_UP,-iry},{WIIMOTE_IR_DOWN,-iry},
            {CLASSIC_STICK_LEFT_LEFT,x},{CLASSIC_STICK_LEFT_RIGHT,x},{CLASSIC_STICK_LEFT_UP,-y},{CLASSIC_STICK_LEFT_DOWN,-y},
            {CLASSIC_STICK_RIGHT_LEFT,rx},{CLASSIC_STICK_RIGHT_RIGHT,rx},{CLASSIC_STICK_RIGHT_UP,-ry},{CLASSIC_STICK_RIGHT_DOWN,-ry},
            {CLASSIC_TRIGGER_L,sample.left_trigger},{CLASSIC_TRIGGER_R,sample.right_trigger}});
        // IMU controls use physical units, unlike the normalized sticks above.
        const std::pair<ButtonType,float> motion[]={
            {WIIMOTE_ACCEL_LEFT,sample.acceleration[0]},{WIIMOTE_ACCEL_RIGHT,sample.acceleration[0]},
            {WIIMOTE_ACCEL_FORWARD,sample.acceleration[1]},{WIIMOTE_ACCEL_BACKWARD,sample.acceleration[1]},
            {WIIMOTE_ACCEL_UP,sample.acceleration[2]},{WIIMOTE_ACCEL_DOWN,sample.acceleration[2]},
            {WIIMOTE_GYRO_PITCH_UP,sample.rotation[0]},{WIIMOTE_GYRO_PITCH_DOWN,sample.rotation[0]},
            {WIIMOTE_GYRO_ROLL_LEFT,sample.rotation[1]},{WIIMOTE_GYRO_ROLL_RIGHT,sample.rotation[1]},
            {WIIMOTE_GYRO_YAW_LEFT,sample.rotation[2]},{WIIMOTE_GYRO_YAW_RIGHT,sample.rotation[2]}};
        for(auto [axis,value]:motion)manager->SetAxisValue(wii,axis,value);
        const std::pair<ButtonType,float> nunchukMotion[]={
            {NUNCHUK_ACCEL_LEFT,sample.acceleration[0]},{NUNCHUK_ACCEL_RIGHT,sample.acceleration[0]},
            {NUNCHUK_ACCEL_FORWARD,sample.acceleration[1]},{NUNCHUK_ACCEL_BACKWARD,sample.acceleration[1]},
            {NUNCHUK_ACCEL_UP,sample.acceleration[2]},{NUNCHUK_ACCEL_DOWN,sample.acceleration[2]}};
        for(auto [axis,value]:nunchukMotion)manager->SetAxisValue(wii,axis,value);
    }
    p->inputSamples.fetch_add(1,std::memory_order_relaxed);
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
        event(generation,3,"Dolphin could not start. Fully close and reopen Iridium.");
    }
}
- (void)bootCore {
    if(ended.load())return;
    auto &system=Core::System::GetInstance();
    // Upstream iOS resolves its complete Sys tree from the main app bundle.
    Common::RegisterMsgAlertHandler(dolphinAlert);
    UICommon::SetUserDirectory(saves+"/");UICommon::CreateDirectories();UICommon::Init();initialized=true;
    WindowSystemInfo wsi;wsi.type=WindowSystemType::iOS;
    wsi.render_surface=(__bridge void *)metal.layer;wsi.render_surface_scale=metal.contentScaleFactor;
    UICommon::InitControllers(wsi);
    if(!installProfiles(self)) {
        event(generation,3,"Dolphin controller profiles are missing from this app.");[self finish];return;
    }
    for(int index=0;index<4;++index) {
        Config::SetCurrent(Config::GetInfoForSIDevice(index),index<options.players?SerialInterface::SIDEVICE_GC_CONTROLLER:SerialInterface::SIDEVICE_NONE);
        Config::SetCurrent(Config::GetInfoForWiimoteSource(index),index<options.players?WiimoteSource::Emulated:WiimoteSource::None);
    }
    Config::SetCurrent(Config::MAIN_CPU_THREAD,options.dual_core);
    graphicsSettings(options);
    dolphinControls(self,extraOptions);
    // Current-run settings outrank per-game INI layers loaded during BootCore.
    if(!options.use_jit||!prepareNativeJIT()) {
        event(generation,3,"Dolphin’s JIT check failed. Close the game and try again.");[self finish];return;
    }
    jitVerified.store(true);
    Config::SetCurrent(Config::MAIN_CPU_CORE,PowerPC::CPUCore::JITARM64);
    Config::SetCurrent(Config::MAIN_FASTMEM,true);Config::SetCurrent(Config::MAIN_FASTMEM_ARENA,true);
    Config::SetCurrent(Config::MAIN_DSP_HLE,true);Config::SetCurrent(Config::MAIN_DSP_JIT,false);
    Config::SetCurrent(Config::MAIN_GFX_BACKEND,std::string("Metal"));
    Config::SetCurrent(Config::MAIN_AUDIO_BACKEND,std::string(BACKEND_COREAUDIO));
    Config::SetCurrent(Config::GFX_VERTEX_LOADER_TYPE,VertexLoaderType::Native);
    event(generation,5,"Dolphin's executable-memory allocation, execution and rewrite probe passed.");
    DolphinAnalytics::Instance().ReportDolphinStart("ios");
    IRDolphinPlayer *p=self;
    presentation=AfterPresentEvent::Register([p](PresentInfo &){
        if(p->frames.fetch_add(1)==0)p->event(p->generation,1,"Dolphin submitted its first Metal frame; native JIT selected.");
    },"Iridium presentation");
    sampling=VIEndFieldEvent::Register([p]{sampleController(p);},"Iridium shared input");
    auto boot=BootParameters::GenerateFromFile({game},BootSessionData());
    if(!boot||!BootManager::BootCore(system,std::move(boot),wsi)) {
        event(generation,3,"This game could not start. Check its game files and any required Wii system files.");[self finish];return;
    }
    event(generation,0,"Dolphin runtime loaded; Metal; native JIT verified.");
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
        event(generation,3,"Dolphin could not close this game. Fully close and reopen Iridium.");return;
    }
    ended.store(true);
    event(generation,2,"Dolphin stopped and saved its isolated configuration and memory cards.");
}
@end

extern "C" unsigned ir_native_engine_abi(){return 1;}
extern "C" void *ir_native_engine_create(const char *,const char *,const char *game,const char *save,const char *assets,bool,uint64_t generation,IRPhase3Event event,IRPhase3Poll input) {
    if(maintenanceUncertain.load()||(active&&!active->ended.load()))return nullptr;
    IRDolphinPlayer *p=[[IRDolphinPlayer alloc]init];p->game=game;p->saves=save;p->assets=assets;p->generation=generation;p->event=event;p->input=input;p->options={1,0,0,1,true,false};p->jitVerified.store(false);p->inputSamples.store(0);p->frames.store(0);p->ended.store(false);active=p;
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
extern "C" void ir_native_engine_set_volume(float level) { ir_audio_volume_set(level); }
extern "C" uint64_t ir_native_engine_frames(){return active?active->frames.load():0;}
extern "C" bool ir_native_engine_command(const char *json) {
    IRDolphinPlayer *p=active;
    if(!p||!json||strlen(json)>131072)return false;
    id request=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:nil];
    if(![request isKindOfClass:NSDictionary.class]||![request[@"operation"] isKindOfClass:NSString.class])return false;
    DOLHostQueueRunAsync(^{
        if(p->ended.load()||p->cleanupUncertain)return;
        if([request[@"operation"] isEqual:@"configure"]&&!p->started) {
            if([request[@"values"] isKindOfClass:NSDictionary.class])p->extraOptions=request[@"values"];
        } else if([request[@"operation"] isEqual:@"snapshot"])dolphinControls(p,nil);
        else if([request[@"operation"] isEqual:@"cheats"]&&p->paused) {
            bool success=dolphinCheats(request[@"items"]);
            if(success)p->managedCheats=request[@"items"];
            p->event(p->generation,success?6:7,success?"Cheats applied.":"Check the cheat format and code. Existing codes have been kept.");
        }
        else if([request[@"operation"] isEqual:@"patches"]&&p->paused) {
            bool success=dolphinPatches(request[@"items"],p->managedCheats);
            if(success)dolphinControls(p,nil);
            p->event(p->generation,success?6:7,success?"Patches saved.":"Check patch names and code lines. Built-in patch code must stay unchanged; give an edited copy a new name.");
        }
        else if([request[@"operation"] isEqual:@"discFile"]&&p->paused) {
            NSString *path=request[@"path"];
            bool success=false;
            if([path isKindOfClass:NSString.class]&&path.isAbsolutePath) {
                try {
                    auto volume=DiscIO::CreateDisc(path.UTF8String);
                    if(volume) {
                        auto& system=Core::System::GetInstance();
                        const Core::CPUThreadGuard guard(system);
                        system.GetDVDInterface().ChangeDisc(guard,path.UTF8String);success=true;
                    }
                } catch (...) {}
            }
            p->event(p->generation,success?6:7,success?"Disc changed.":"The selected disc could not be inserted.");
        }
        else if([request[@"operation"] isEqual:@"option"]&&p->paused&&
            [request[@"key"] isKindOfClass:NSString.class]&&[request[@"value"] isKindOfClass:NSString.class]) {
            dolphinControls(p,@{request[@"key"]:request[@"value"]});
        }
    });return true;
}

static void configureDolphin(IRDolphinOptions options,IRDolphinPoll poll) {
    if(active&&!active->started){active->options=validated(options);active->dolphinInput=poll;}
}
static void updateDolphin(IRDolphinOptions options) {
    IRDolphinPlayer *p=active;if(!p)return;
    options=validated(options);
    DOLHostQueueRunAsync(^{
        if(p->ended.load()||p->cleanupUncertain)return;
        if(!p->paused){p->event(p->generation,7,"Pause the game before changing Dolphin settings.");return;}
        try {
            p->options.resolution=options.resolution;p->options.aspect=options.aspect;p->options.remote=options.remote;p->options.muted=options.muted;
            graphicsSettings(p->options);
            AudioCommon::UpdateSoundStream(Core::System::GetInstance());
            if(!installProfiles(p))p->event(p->generation,7,"The controller profile could not be loaded.");
        } catch (...) {p->event(p->generation,7,"Dolphin could not apply these settings.");}
    });
}
static IRDolphinStats dolphinStats() {
    IRDolphinPlayer *p=active;if(!p)return {};
    return {g_perf_metrics.GetFPS(),g_perf_metrics.GetVPS(),g_perf_metrics.GetSpeed(),p->frames.load(),p->inputSamples.load(),p->jitVerified.load()};
}
static void dolphinState(bool load,unsigned slot) {
    IRDolphinPlayer *p=active;if(!p||slot>=5)return;
    DOLHostQueueRunAsync(^{
        if(p->ended.load()||p->cleanupUncertain||!p->paused)return;
        auto &system=Core::System::GetInstance();
        std::string file=p->saves+"/StateSaves/Iridium-"+std::to_string(slot)+".sav";
        bool success=false;
        try {
            State::StateHeader header;
            if(load) {
                if(State::ReadHeader(file,header)) {
                    State::SetOnAfterLoadCallback([&]{success=true;});
                    State::LoadAs(system,file);State::SetOnAfterLoadCallback({});
                }
            } else {
                std::string pending=file+".pending";
                if(File::Exists(pending))File::Delete(pending);
                State::SaveAs(system,pending,true);
                success=State::ReadHeader(pending,header)&&File::Rename(pending,file);
            }
        } catch (...) {State::SetOnAfterLoadCallback({});}
        p->event(p->generation,success?6:7,success?(load?"Dolphin state loaded.":"Dolphin state saved."):
            "Dolphin could not complete the state operation. Existing saves have been retained.");
    });
}
extern "C" const IRDolphinAPI *ir_dolphin_api() {
    static const IRDolphinAPI api={2,configureDolphin,updateDolphin,dolphinStats,dolphinState,[](const char *root,const char *wad,IRDolphinCompletion completion){
        std::string save=root,file=wad;
        DOLHostQueueRunAsync(^{
            if(maintenanceUncertain.load()) {
                completion(false,true,"Fully close and reopen Iridium before changing Wii files.");return;
            }
            if((active&&!active->ended.load())||Core::GetState(Core::System::GetInstance())!=Core::State::Uninitialized) {
                completion(false,false,"Close the active game before installing Wii content.");return;
            }
            bool initialized=false,success=false,restart=false;
            try {
                Common::RegisterMsgAlertHandler(dolphinAlert);
                UICommon::SetUserDirectory(save+"/");UICommon::CreateDirectories();UICommon::Init();initialized=true;
                success=WiiUtils::InstallWAD(file);
            } catch (...) {restart=!initialized;}
            if(initialized)try {UICommon::Shutdown();}catch (...) {restart=true;}
            if(restart) {
                maintenanceUncertain.store(true);
                completion(false,true,"Dolphin could not close the Wii installer. Fully close and reopen Iridium. Your backup is kept in Dolphin Backups.");
            } else completion(success,false,success?"Wii content installed. Your backup is kept in Dolphin Backups.":"Dolphin could not install this WAD. Your backup is kept in Dolphin Backups.");
        });
    }};return &api;
}
