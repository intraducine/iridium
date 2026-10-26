"""Execute core option, state storage, controller port and rewind policies."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import importlib.util
import re
from host_tests import module_cache

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'
INCLUDE = ROOT / 'vendor/Flycast/core/deps/libretro-common/include'


class CoreControlsTests(unittest.TestCase):
    def test_psp_pending_cheats_can_resume_after_pause_without_releasing_ownership(self):
        source=(ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        from test_native_psp_frontend import function
        finish=function(source,'    private func finishCheats(')
        resume=source[source.index('    func resume() {'):source.index('        if phase3Controller != nil, phase3JITRequested',source.index('    func resume() {'))]
        self.compile_run(r'''
import Foundation
struct Game {let id=UUID()}
enum IridiumCheat {static func save(_ items:Int,game:UUID)throws{}}
final class Session {
    var game:Game?=Game(),error:String?,cheats=0
    enum Phase {case paused,running}; var phase=Phase.paused
    var lease:Int?=1,nativePSPController:Int?=1,pendingCheats:Int?=1
    var dolphinStatePending=false,coreOperationPending=true,resumes=0
'''+resume+r'''
        _ = owner;resumes+=1;phase = .running
    }
'''+finish+r'''
    func completed(_ success:Bool){finishCheats(success:success)}
}
let s=Session();s.resume();precondition(s.resumes==1 && s.coreOperationPending && s.pendingCheats==1)
s.phase = .paused;s.resume();precondition(s.resumes==2 && s.coreOperationPending)
s.completed(true);precondition(s.pendingCheats==nil && !s.coreOperationPending && s.cheats==1)
s.phase = .paused;s.resume();precondition(s.resumes==3)
s.pendingCheats=2;s.coreOperationPending=true;s.completed(false)
precondition(s.pendingCheats==nil && !s.coreOperationPending && s.cheats==1)
s.pendingCheats=nil;s.coreOperationPending=true;s.phase = .paused;s.resume();precondition(s.resumes==3)
s.lease=nil;s.phase = .paused;s.pendingCheats=1;s.resume();precondition(s.resumes==3)
let other=Session();other.nativePSPController=nil;other.resume();precondition(other.resumes==0)
let state=Session();state.dolphinStatePending=true;state.resume();precondition(state.resumes==0)
''', '.swift')

    def test_psp_startup_command_is_bounded_and_only_applies_before_core_initialization(self):
        from test_native_psp_frontend import function
        source=(BRIDGE/'IRPPSSPPNative.mm').read_text()
        command=function(source,'bool ir_native_psp_command(')
        startup=function(source,'void ir_native_psp_frontend_startup(')
        catalog=(BRIDGE/'IRPPSSPPOptions.h').read_text()
        key=function(catalog,'static bool irPSPStartupKey(')
        self.compile_run(r'''
#import <Foundation/Foundation.h>
#include <cassert>
#include <mutex>
#include <atomic>
#include <cstring>
@interface Owner:NSObject
@property BOOL initialized;
@property BOOL closing;
@end
@implementation Owner
@end
Owner *container;
static std::mutex optionsLock;
static NSDictionary *startupOptions,*pendingOptions;
static std::atomic<bool>stateBusy;
struct {int iPSPModel=0;bool bSoftwareRendering=false;}g_Config;
'''+key+command+startup+r'''
int main(){@autoreleasepool{
container=[Owner new];
assert(ir_native_psp_command(R"({"operation":"startupOptions","values":{"iPSPModel":"1","bSoftwareRendering":"1"}})"));
assert(g_Config.iPSPModel==0&&!g_Config.bSoftwareRendering);
for(const char*text:{R"({"operation":"startupOptions","values":{"iPSPModel":"2"}})",
 R"({"operation":"startupOptions","values":{"iPSPModel":true}})",
 R"({"operation":"startupOptions","values":{"iCpuCore":"1"}})"})assert(!ir_native_psp_command(text));
ir_native_psp_frontend_startup();assert(g_Config.iPSPModel==1&&g_Config.bSoftwareRendering);
container.initialized=YES;
assert(!ir_native_psp_command(R"({"operation":"startupOptions","values":{"iPSPModel":"0"}})"));
assert(ir_native_psp_command(R"({"operation":"cheats","items":[]})")&&stateBusy);
assert(!ir_native_psp_command(R"({"operation":"cheats","items":[]})"));
}}
''', '.mm', frameworks=['Foundation'])
        import ppsspp_native_overlay as overlay
        native=overlay.apply('Core/System.cpp',(ROOT/'vendor/PPSSPP/Core/System.cpp').read_text())
        self.assertLess(native.index('ir_native_psp_frontend_startup();'),native.index('Memory::g_PSPModel ='))
        late=native.index('ir_native_psp_frontend_startup();',native.index('ir_native_psp_frontend_startup();')+1)
        self.assertLess(late,native.index('if (g_Config.bSoftwareRendering ||'))
        host=(ROOT/'iridium/apps/ios/MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        launch=function(host,'        if !values.isEmpty {')
        self.compile_run(r'''
import Foundation
var calls=0
var accepts=false
@MainActor func ir_psp_native_command(_ text:String)->Bool{calls+=1;return accepts}
@MainActor final class Host {
    var error:String?,stops=0
    func stop(){stops+=1}
    func launch(_ values:[String:String]) {
'''+launch+r'''
    }
}
MainActor.assumeIsolated {
    let older=Host();older.launch([:]);precondition(calls==0&&older.error==nil&&older.stops==0)
    older.launch(["iPSPModel":"1"]);precondition(calls==1&&older.error != nil&&older.stops==1)
    accepts=true;let current=Host();current.launch(["bSoftwareRendering":"0"])
    precondition(calls==2&&current.error==nil&&current.stops==0)
}
''', '.swift')

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift required')
    def test_cheats_restore_once_after_the_current_game_boots(self):
        from test_native_psp_frontend import function
        source = (ROOT / 'iridium/apps/ios/MadeiraFrontend/IridiumConsoleSession.swift').read_text()
        restore = function(source, '    private func restoreCheatsIfNeeded()')
        self.compile_run(r'''
import Foundation
enum Platform {case psp,threeDS,gameBoy;var isPhase3:Bool{self == .threeDS}}
struct Game {var platform:Platform}
final class Session {
    enum Request {case play,pause};var requested=Request.play
    var game:Game?
    var restoredCheats=false,phase3Ready=false,pspReady=false,paused=false
    var applies=0
    var coreControls=IridiumCoreControls(cheatFormats:["gateway"])
    var cheats=[IridiumCheat(name:"Test",format:"gateway",code:"12345678 00000000")]
    func pause(){paused=true}
    @discardableResult func applyCheats(_ items:[IridiumCheat])->Bool{precondition(paused);applies+=1;return true}
    func restore(){restoreCheatsIfNeeded()}
''' + restore + r'''
}
let phase3=Session();phase3.game=Game(platform:.threeDS)
phase3.restore();precondition(!phase3.restoredCheats && phase3.applies==0)
phase3.phase3Ready=true;phase3.restore();phase3.restore()
precondition(phase3.restoredCheats && phase3.applies==1)
let psp=Session();psp.game=Game(platform:.psp)
psp.restore();precondition(!psp.restoredCheats && psp.applies==0)
psp.pspReady=true;psp.restore();psp.restore();precondition(psp.applies==1)
let gb=Session();gb.game=Game(platform:.gameBoy);gb.restore();gb.restore();precondition(gb.applies==1)
let empty=Session();empty.cheats=[];empty.restore();precondition(empty.restoredCheats && !empty.paused && empty.applies==0)
let paused=Session();paused.game=Game(platform:.threeDS);paused.phase3Ready=true;paused.requested = .pause
paused.restore();precondition(!paused.restoredCheats && paused.applies==0)
paused.requested = .play;paused.restore();precondition(paused.restoredCheats && paused.applies==1)
''', '.swift', sources=(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumCoreControls.swift',))

    @unittest.skipUnless(shutil.which('clang++'), 'Clang required')
    def test_azahar_cheats_keep_existing_and_reject_partial_edits(self):
        spec = importlib.util.spec_from_file_location('cheat_azahar', ROOT / 'ci/phase3_azahar.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        source = next(value for value in module.generated.__code__.co_consts
                      if isinstance(value, str) and 'bool ir_phase3_core_cheats' in value)
        source = source[source.index('extern "C" bool ir_phase3_core_cheats'):]
        source = '\n'.join(line for line in source.splitlines() if not line.startswith('#include'))
        self.compile_run(r'''
#include "IRCheats.h"
#include <cassert>
#include <algorithm>
#include <memory>
#include <sstream>
#include <string>
#include <vector>
namespace Cheats {
struct CheatBase { virtual ~CheatBase()=default; bool enabled=false; };
struct GatewayCheat:CheatBase {
    struct CheatLine { bool valid=true; explicit CheatLine(const std::string&){} };
    GatewayCheat(const char*,std::vector<CheatLine>,const char*){}
    void SetEnabled(bool value){enabled=value;}
};
struct CheatEngine {
    std::vector<std::shared_ptr<CheatBase>> values;
    const auto& GetCheats(){return values;}
    void RemoveCheat(size_t index){values.erase(values.begin()+index);}
    void AddCheat(std::shared_ptr<CheatBase>&& item){values.push_back(std::move(item));}
};
}
namespace Core {
struct System {
    Cheats::CheatEngine engine;
    static System& GetInstance(){static System s;return s;}
    auto& CheatEngine(){return engine;}
};
}
''' + source + r'''
int main(){
    auto& engine=Core::System::GetInstance().engine;
    auto existing=std::make_shared<Cheats::CheatBase>();engine.values.push_back(existing);
    IRCheat codes[]={{"A","gateway","12345678 90ABCDEF",true},{"B","gateway","00000000 00000001",false}};
    assert(ir_phase3_core_cheats(codes,2));
    assert(engine.values.size()==3 && engine.values[0]==existing);
    assert(engine.values[1]->enabled && !engine.values[2]->enabled);
    auto old=engine.values[1];
    codes[1].code="invalid";
    assert(!ir_phase3_core_cheats(codes,2));
    assert(engine.values.size()==3 && engine.values[1]==old);
    codes[1].code="12345678 90ABCDEF";
    assert(ir_phase3_core_cheats(codes,1));
    assert(engine.values.size()==2 && engine.values[0]==existing && engine.values[1]!=old);
    assert(ir_phase3_core_cheats(nullptr,0));
    assert(engine.values.size()==1 && engine.values[0]==existing);
}
''')

    @unittest.skipUnless(shutil.which('clang++') and subprocess.run(['uname'], capture_output=True, text=True).stdout.strip() == 'Darwin', 'macOS Foundation required')
    def test_cheat_bounds_numeric_lines_and_json_types(self):
        self.compile_run(r'''
#include "IRCheats.h"
#include <cassert>
#include <string>
int main() {
    uint32_t first=0,second=0;
    assert(ir_cheat_pair(" 0x1234abcd\t90ABCDEF\r",&first,&second));
    assert(first==0x1234abcd && second==0x90abcdef);
    for(const char *text:{"","1 2","123456789 12345678","12345678 12345678 extra",
                         "1234567g 12345678","1234567812345678","12345678 "})
        assert(!ir_cheat_pair(text,&first,&second));
    IRCheat code{"Name","gateway","12345678 12345678",true};
    assert(ir_cheats_valid(&code,1));
    code.name="Name\n[Section]";assert(!ir_cheats_valid(&code,1));code.name="Name";
    assert(ir_cheats_valid(nullptr,0));
    assert(!ir_cheats_valid(nullptr,1));
    assert(!ir_cheats_valid(&code,65));
    std::string longCode(8193,'a');code.code=longCode.c_str();
    assert(!ir_cheats_valid(&code,1));
    std::vector<IRCheat> items;
    assert(ir_cheats_decode(@[@{@"name":@"Test",@"format":@"gateway",@"code":@"12345678 12345678",@"enabled":@YES}],items));
    assert(items.size()==1);
    for(id value in @[@{},@[@{@"name":@1}],@[@{@"name":@"Test",@"format":@"gateway",@"code":@1,@"enabled":@YES}],
                       @[@{@"name":@"Test",@"format":@"gateway",@"code":@"12",@"enabled":@"yes"}]]) {
        items.clear();assert(!ir_cheats_decode(value,items));
    }
    NSString *nul=[NSString stringWithFormat:@"X%CY",(unichar)0];
    items.clear();assert(!ir_cheats_decode(@[@{@"name":@"Test",@"format":@"gateway",@"code":nul,@"enabled":@YES}],items));
}
''', '.mm', frameworks=('Foundation',))

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift required')
    def test_cheat_model_round_trip_and_limits(self):
        self.compile_run(r'''
import Foundation
let game=UUID()
defer {
    UserDefaults.standard.removeObject(forKey:"CoreCheats.\(game)")
    UserDefaults.standard.removeObject(forKey:"CoreOptions.\(game)")
}
IridiumCorePreferences.save("1",key:"iPSPModel",game:game)
IridiumCorePreferences.save("0",key:"bSoftwareRendering",game:game)
IridiumCorePreferences.save("1",key:"iCpuCore",game:game)
precondition(IridiumCorePreferences.pspStartup(game)==["iPSPModel":"1","bSoftwareRendering":"0"])
IridiumCorePreferences.save("2",key:"iPSPModel",game:game)
precondition(IridiumCorePreferences.pspStartup(game)==["bSoftwareRendering":"0"])
let item=IridiumCheat(name:"Health",format:"gateway",code:"00000000 00000001")
try IridiumCheat.validate([item],formats:["gateway"])
try IridiumCheat.save([item],game:game)
let loaded=try IridiumCheat.load(game)
precondition(loaded==[item])
for changed in [IridiumCheat(name:"",format:"gateway",code:"1"),
                IridiumCheat(name:"name\n[Section]",format:"gateway",code:"1"),
                IridiumCheat(name:"x",format:"other",code:"1"),
                IridiumCheat(name:"x",format:"gateway",code:String(repeating:"1",count:8193)),
                IridiumCheat(name:"x",format:"gateway",code:"1\u{0}2")] {
    do { try IridiumCheat.validate([changed],formats:["gateway"]);fatalError("accepted invalid cheat") } catch {}
}
do {try IridiumCheat.validate([item,item],formats:["gateway"]);fatalError("duplicate id")}catch{}
try IridiumCheat.save([],game:game)
let empty=try IridiumCheat.load(game)
precondition(empty.isEmpty)
''', '.swift', sources=(ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumCoreControls.swift',))

    def compile_run(self, text, suffix='.cpp', sources=(), frameworks=()):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); unit = folder / ('main' + suffix); unit.write_text(text)
            binary = folder / 'check'
            if suffix == '.swift':
                args = ['swiftc', '-swift-version', '6', '-module-cache-path', module_cache('macosx'), *map(str, sources), str(unit)]
            else:
                args = ['clang++', '-std=c++20', '-I', str(INCLUDE), '-I', str(BRIDGE), str(unit)]
                if suffix == '.mm': args += ['-fobjc-arc']
                for framework in frameworks: args += ['-framework', framework]
            subprocess.run([*args, '-o', str(binary)], check=True, timeout=60)
            subprocess.run([str(binary)], check=True, timeout=15)

    @unittest.skipUnless(shutil.which('clang++') and (INCLUDE / 'libretro.h').is_file(), 'Pinned libretro header and Clang required')
    def test_options_copy_validate_changes_and_replace_definitions(self):
        self.compile_run(r'''
#define IR_CORE_OPTIONS_IMPLEMENTATION
#include "IRCoreOptions.h"
#include <cassert>
#include <string>
int main() {
    IROptions options{};
    assert(!ir_options_environment(&options,RETRO_ENVIRONMENT_GET_VARIABLE,nullptr));
    assert(ir_option_set(&options,"resolution","2",true));
    char definition[]="Resolution; 1|2|3";
    retro_variable vars[]={{"resolution",definition},{nullptr,nullptr}};
    assert(ir_options_environment(&options,RETRO_ENVIRONMENT_SET_VARIABLES,vars));
    memset(definition,0,sizeof definition);
    retro_variable query{"resolution",nullptr};
    assert(ir_options_environment(&options,RETRO_ENVIRONMENT_GET_VARIABLE,&query));
    assert(std::string(query.value)=="2");
    bool changed=false;
    assert(ir_options_environment(&options,RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE,&changed)&&changed);
    assert(ir_options_environment(&options,RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE,&changed)&&!changed);
    assert(!ir_option_set(&options,"resolution","../../../outside",false));
    assert(!ir_option_set(&options,"unknown","2",false));
    assert(ir_option_set(&options,"resolution","3",false));
    ir_options_environment(&options,RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE,&changed);assert(changed);
    char updated[]="Resolution; 1|2";vars[0].value=updated;
    ir_options_environment(&options,RETRO_ENVIRONMENT_SET_VARIABLES,vars);
    ir_options_environment(&options,RETRO_ENVIRONMENT_GET_VARIABLE,&query);assert(std::string(query.value)=="1");
    retro_core_option_display display{"resolution",false};
    assert(ir_options_environment(&options,RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY,&display));
    assert(!ir_option_find(&options,"resolution",false)->visible);
    ir_options_clear(&options);assert(!options.first&&!options.count&&!options.changed);
}
''')

    @unittest.skipUnless(shutil.which('clang++') and (INCLUDE / 'libretro.h').is_file(), 'Pinned libretro header and Clang required')
    def test_all_ports_are_independent_and_handheld_rejects_extra_players(self):
        source = (BRIDGE / 'IRRetroPlayer.mm').read_text()
        state = source[source.index('static int16_t inputState('):source.index('static size_t audioBatch(')]
        self.compile_run(r'''
#include "libretro.h"
#include "IRPhase3.h"
#include <string>
#include <cassert>
struct Player { std::string engine="flycast";IRPhase3Input sampled[4]{}; } player;
static Player *active=&player;
STATE
int main() {
    for(unsigned port=0;port<4;++port) {
        player.sampled[port].buttons=1u<<port;
        player.sampled[port].left_x=(port+1)*100;
    }
    for(unsigned port=0;port<4;++port) {
        assert(inputState(port,RETRO_DEVICE_JOYPAD,0,RETRO_DEVICE_ID_JOYPAD_MASK)==(1u<<port));
        assert(inputState(port,RETRO_DEVICE_ANALOG,0,0)==(port+1)*100);
        assert(inputState(port,RETRO_DEVICE_JOYPAD,0,(port+1)%4)==0);
    }
    assert(inputState(4,RETRO_DEVICE_JOYPAD,0,0)==0);
    player.engine="azahar";assert(inputState(1,RETRO_DEVICE_ANALOG,0,0)==0);
    active=nullptr;assert(inputState(0,RETRO_DEVICE_JOYPAD,0,0)==0);
}
'''.replace('STATE', state))

    @unittest.skipUnless(shutil.which('clang++') and (ROOT / 'vendor/Play/deps/CodeGen/src/MemoryFunction.cpp').is_file(), 'Pinned Play and CodeGen sources required')
    def test_play_adapter_routes_both_pads_and_analog_endpoints(self):
        spec = importlib.util.spec_from_file_location('play_controls', ROOT / 'ci/phase3_play.py')
        play = importlib.util.module_from_spec(spec); spec.loader.exec_module(play)
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); play.generated(ROOT, folder)
            (folder / 'PadHandler.h').write_text(r'''
#pragma once
#include <cstdint>
#include <functional>
#include <vector>
using uint8=uint8_t;using int8=int8_t;using int16=int16_t;using int32=int32_t;using uint32=uint32_t;
namespace PS2 { struct CControllerInfo {
 enum BUTTON { ANALOG_LEFT_X,ANALOG_LEFT_Y,ANALOG_RIGHT_X,ANALOG_RIGHT_Y,FIRE,MAX_BUTTONS };
 static bool IsAxis(BUTTON button) { return button<=ANALOG_RIGHT_Y; }
}; }
struct CPadInterface {
 uint8 axes[2][4]{};bool buttons[2]{};
 void SetAxisState(unsigned port,PS2::CControllerInfo::BUTTON button,uint8 value,uint8*) { axes[port][button]=value; }
 void SetButtonState(unsigned port,PS2::CControllerInfo::BUTTON,bool value,uint8*) { buttons[port]=value; }
};
class CPadHandler {
public:
 using FactoryFunction=std::function<CPadHandler*()>;
 virtual ~CPadHandler()=default;virtual void Update(uint8*)=0;
 void InsertListener(CPadInterface* value) { m_interfaces.push_back(value); }
protected:std::vector<CPadInterface*> m_interfaces;
};
''')
            (folder / 'main.cpp').write_text(r'''
#include "PH_Libretro_Input.h"
#include "ext/libretro.h"
#include <cassert>
bool libretro_supports_bitmasks=true;
std::map<int,int> g_ds2_to_retro_btn_map={{0,0},{1,1},{2,0},{3,1},{4,RETRO_DEVICE_ID_JOYPAD_A}};
static unsigned polls;
static int16_t stick=-32768;
static void poll(){++polls;}
static int16_t input(unsigned port,unsigned device,unsigned,unsigned id) {
 if(device==RETRO_DEVICE_ANALOG)return port?32767:stick;
 if(id==RETRO_DEVICE_ID_JOYPAD_MASK)return port?(1<<RETRO_DEVICE_ID_JOYPAD_A):0;
 return port&&id==RETRO_DEVICE_ID_JOYPAD_A;
}
retro_input_poll_t g_input_poll_cb=poll;
retro_input_state_t g_input_state_cb=input;
int main() {
 CPH_Libretro_Input handler;CPadInterface output;handler.InsertListener(&output);
 for(bool bitmasks:{true,false}) {
  libretro_supports_bitmasks=bitmasks;
  for(auto pair:{std::pair<int16_t,uint8_t>{-32768,0},{0,127},{32767,255}}) {
   stick=pair.first;handler.UpdateInputState();handler.Update(nullptr);
   for(unsigned axis=0;axis<4;++axis)assert(output.axes[0][axis]==pair.second&&output.axes[1][axis]==255);
   assert(!output.buttons[0]&&output.buttons[1]);
  }
 }
 assert(polls==6);
}
''')
            binary = folder / 'check'
            subprocess.run(['clang++', '-std=c++17', '-I', str(folder), '-I', str(ROOT / 'vendor/Play/Source/ui_libretro'),
                            str(folder / 'PH_Libretro_Input.cpp'), str(folder / 'main.cpp'), '-o', str(binary)], check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=10)

    @unittest.skipUnless(shutil.which('clang++') and subprocess.run(['uname'], capture_output=True, text=True).stdout.strip() == 'Darwin', 'macOS Foundation required')
    def test_state_storage_preserves_slots_on_failure_and_rejects_wrong_versions_and_symlinks(self):
        self.compile_run(r'''
#include "IRStateFile.h"
#include <cassert>
int main() { @autoreleasepool {
    NSString *root=[[NSTemporaryDirectory() stringByResolvingSymlinksInPath] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *first=[@"first game state" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *second=[@"second game state" dataUsingEncoding:NSUTF8StringEncoding];
    assert(irStateWrite(root.UTF8String,0,@"engine|revision1",first));
    assert([irStateRead(root.UTF8String,0,@"engine|revision1") isEqualToData:first]);
    assert(!irStateRead(root.UTF8String,0,@"engine|revision2"));
    assert(!irStateWrite(root.UTF8String,5,@"engine|revision1",second));
    assert(!irStateWrite(root.UTF8String,0,@"engine|revision1",[NSData data]));
    assert([irStateRead(root.UTF8String,0,@"engine|revision1") isEqualToData:first]);
    assert(irStateWrite(root.UTF8String,0,@"engine|revision1",second));
    assert([irStateRead(root.UTF8String,0,@"engine|revision1") isEqualToData:second]);
    NSString *gameA=NSUUID.UUID.UUIDString,*gameB=NSUUID.UUID.UUIDString;
    assert(irStateWrite(root.UTF8String,0,@"engine|revision1",first,gameA));
    assert(irStateWrite(root.UTF8String,0,@"engine|revision1",second,gameB));
    assert([irStateRead(root.UTF8String,0,@"engine|revision1",gameA) isEqualToData:first]);
    assert([irStateRead(root.UTF8String,0,@"engine|revision1",gameB) isEqualToData:second]);
    assert([irStateRead(root.UTF8String,0,@"engine|revision1") isEqualToData:second]);
    assert(!irStateWrite(root.UTF8String,0,@"engine|revision1",first,@"../outside"));
    assert(!irStateRead(root.UTF8String,0,@"engine|revision1",@"../outside"));
    NSString *link=[root stringByAppendingPathComponent:@"state-1.bin"];
    NSString *target=[root stringByAppendingPathComponent:@"state-0.bin"];
    assert(!symlink(target.UTF8String,link.UTF8String));
    assert(!irStateRead(root.UTF8String,1,@"engine|revision1"));
    assert(irStateWrite(root.UTF8String,1,@"engine|revision1",first));
    assert([irStateRead(root.UTF8String,0,@"engine|revision1") isEqualToData:second]);
    NSString *alias=[root stringByAppendingString:@"-alias"];
    assert(!symlink(root.UTF8String,alias.UTF8String));
    assert(!irStateRead(alias.UTF8String,0,@"engine|revision1"));
    assert(!irStateWrite(alias.UTF8String,0,@"engine|revision1",first));
    NSString *nested=[root stringByAppendingPathComponent:@"nested"];
    [NSFileManager.defaultManager createDirectoryAtPath:nested withIntermediateDirectories:NO attributes:nil error:nil];
    assert(irStateWrite(nested.UTF8String,0,@"engine|revision1",first));
    NSString *throughAlias=[alias stringByAppendingPathComponent:@"nested"];
    assert(!irStateRead(throughAlias.UTF8String,0,@"engine|revision1"));
    assert(!irStateWrite(throughAlias.UTF8String,0,@"engine|revision1",second));
    assert([irStateRead(nested.UTF8String,0,@"engine|revision1") isEqualToData:first]);
    [NSFileManager.defaultManager removeItemAtPath:alias error:nil];
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
} }
''', '.mm', frameworks=['Foundation'])

    @unittest.skipUnless(shutil.which('clang++') and subprocess.run(['uname'], capture_output=True, text=True).stdout.strip() == 'Darwin', 'macOS Foundation required')
    def test_psp_option_ranges_labels_and_protected_settings(self):
        catalog = (BRIDGE / 'IRPPSSPPOptions.h').read_text().replace('#include "GPU/Common/PostShader.h"', '')
        fields = '\n'.join(('bool ' if kind == 'BOOL' else 'int ') + name + '{};'
                           for kind, name in re.findall(r'(BOOL|INT)\((\w+),"', catalog))
        self.compile_run(r'''
#import <Foundation/Foundation.h>
#include <cassert>
#include <string>
#include <vector>
struct Config { FIELDS std::string sProAdhocServer;std::vector<std::string> vPostShaderNames; } g_Config;
struct Shader { bool visible;std::string section,name; };
static const std::vector<Shader>& GetAllPostShaderInfo() {
    static const std::vector<Shader> shaders={{true,"Off","Off"},{true,"test","Test Shader"}};return shaders;
}
static void ReloadAllPostShaderInfo(void*) {}
CATALOG
int main() { @autoreleasepool {
    bool accepted=false;
    NSArray *items=irPSPOptions(@"iAnisotropyLevel",@"4",&accepted);
    assert(accepted&&g_Config.iAnisotropyLevel==4);
    for(NSDictionary *item in items)if([item[@"key"] isEqual:@"iAnisotropyLevel"]) {
        NSArray *choices=item[@"choices"];
        assert(choices.count==5&&[choices.lastObject[@"title"] isEqual:@"16×"]);
    }
    accepted=false;irPSPOptions(@"iAnisotropyLevel",@"5",&accepted);
    assert(!accepted&&g_Config.iAnisotropyLevel==4);
    accepted=false;irPSPOptions(@"iTexScalingLevel",@"1",&accepted);
    assert(accepted&&g_Config.iTexScalingLevel==1);
    accepted=false;irPSPOptions(@"iTexScalingLevel",@"0",&accepted);
    assert(!accepted&&g_Config.iTexScalingLevel==1);
    for(NSString *value in @[@"0",@"1",@"6",@"11"]) {
        accepted=false;items=irPSPOptions(@"iWlanAdhocChannel",value,&accepted);
        assert(accepted&&g_Config.iWlanAdhocChannel==value.intValue);
        for(NSDictionary *item in items)if([item[@"key"]isEqual:@"iWlanAdhocChannel"]) {
            assert([item[@"choices"] count]==4);
            for(NSDictionary *choice in item[@"choices"])if([choice[@"value"]isEqual:value])
                assert([choice[@"title"]isEqual:(value.intValue?value:@"Auto")]);
        }
    }
    for(NSString *value in @[@"2",@"3",@"5",@"10",@"12"]) {
        accepted=false;irPSPOptions(@"iWlanAdhocChannel",value,&accepted);assert(!accepted&&g_Config.iWlanAdhocChannel==11);
    }
    for(NSString *key in @[@"bSoftwareRendering",@"iPSPModel"]) {
        accepted=false;items=irPSPOptions(key,@"1",&accepted);assert(!accepted);
        for(NSDictionary *item in items)if([item[@"key"]isEqual:key])assert([item[@"restartRequired"]boolValue]);
    }
    assert(!g_Config.bSoftwareRendering&&g_Config.iPSPModel==0);
    for(NSString *key in @[@"iCpuCore",@"iGPUBackend",@"unknown"]) {
        accepted=false;irPSPOptions(key,@"1",&accepted);assert(!accepted);
    }
    accepted=false;irPSPOptions(@"sProAdhocServer",@"host;command",&accepted);assert(!accepted);
    accepted=false;irPSPOptions(@"sProAdhocServer",@"192.168.1.2",&accepted);assert(accepted);
    for(NSString *value in @[@"0",@"10000",@"60000"]) {accepted=false;irPSPOptions(@"iPortOffset",value,&accepted);assert(accepted);}
    for(NSString *value in @[@"60001",@"-1",@"x",@"1;2"]) {accepted=false;irPSPOptions(@"iPortOffset",value,&accepted);assert(!accepted);}
    accepted=false;items=irPSPOptions(@"iMinTimeout",@"15000",&accepted);assert(accepted);
    for(NSDictionary *item in items)if([item[@"key"]isEqual:@"iPortOffset"])assert([item[@"choices"]count]==0);
} }
'''.replace('FIELDS', fields).replace('CATALOG', catalog), '.mm', frameworks=['Foundation'])

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift required')
    def test_rewind_memory_limit_and_state_envelope_round_trip(self):
        self.compile_run(r'''
import Foundation
var history=IridiumRewindHistory(limit: 10)
history.append(Data(repeating:1,count:4));history.append(Data(repeating:2,count:4))
history.append(Data(repeating:3,count:4))
precondition(history.pop(steps:30)==Data(repeating:2,count:4))
precondition(history.pop()==nil)
history.append(Data(repeating:4,count:11));precondition(history.pop()==nil)
history.append(Data([5]));history.clear();precondition(history.pop()==nil)
let original=IridiumConsoleStateRecord(runtime:"sameboy",version:"pin1",data:Data([0,1,255]))
let record=try JSONDecoder().decode(IridiumConsoleStateRecord.self,from:JSONEncoder().encode(original))
precondition(record.runtime=="sameboy"&&record.version=="pin1"&&record.data==original.data)
''', '.swift', sources=[ROOT / 'iridium/apps/ios/RuntimeSupport/IridiumCoreControls.swift'])


if __name__ == '__main__':
    unittest.main()
