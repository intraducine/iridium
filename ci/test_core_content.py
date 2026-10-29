"""Execute content publication and the native paths added to the core controls."""
from pathlib import Path
import importlib.util
import subprocess
import tempfile
import unittest
import test_core_controls as controls

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'
SUPPORT = ROOT / 'iridium/apps/ios/RuntimeSupport'
FRONTEND = ROOT / 'iridium/apps/ios/MadeiraFrontend'


class CoreContentTests(unittest.TestCase):
    compile_run = controls.CoreControlsTests.compile_run

    def test_content_merge_backup_failure_rollback_and_installed_paths(self):
        self.compile_run(r'''
import Foundation
func check(_ value:Bool,file:StaticString=#file,line:UInt=#line){precondition(value,file:file,line:line)}
let fm=FileManager.default
let root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
try fm.createDirectory(at:root,withIntermediateDirectories:true)
defer{try? fm.removeItem(at:root)}
let source=root.appendingPathComponent("pack"),target=root.appendingPathComponent("textures"),backup=root.appendingPathComponent("backup")
for folder in [source,target]{try fm.createDirectory(at:folder,withIntermediateDirectories:true)}
try Data("old".utf8).write(to:target.appendingPathComponent("textures.ini"))
try Data("keep".utf8).write(to:target.appendingPathComponent("keep.png"))
try Data("new".utf8).write(to:source.appendingPathComponent("textures.ini"))
try IridiumFilesImport.importContent(from:source,to:target,backup:backup)
check(try String(contentsOf:target.appendingPathComponent("textures.ini"),encoding:.utf8)=="new")
check(try String(contentsOf:backup.appendingPathComponent("textures.ini"),encoding:.utf8)=="old")
precondition(fm.fileExists(atPath:target.appendingPathComponent("keep.png").path))
try fm.createSymbolicLink(at:source.appendingPathComponent("bad"),withDestinationURL:backup)
do{try IridiumFilesImport.importContent(from:source,to:target,backup:root.appendingPathComponent("bad-backup"));fatalError("accepted link")}catch{}
check(try String(contentsOf:target.appendingPathComponent("textures.ini"),encoding:.utf8)=="new")
let rollback=root.appendingPathComponent("rollback")
do{try IridiumFilesImport.publishContent(staging:root.appendingPathComponent("missing"),destination:target,backup:rollback);fatalError("missing source")}catch{}
precondition(fm.fileExists(atPath:target.appendingPathComponent("keep.png").path) && !fm.fileExists(atPath:rollback.path))
for path in ["../out","/absolute","a//b","a/../b","a\\b","x\u{0}"]{
 do{_=try IridiumCoreContent.components(path);fatalError("unsafe path")}catch{}
}
let store=IridiumConsoleStore(root:root)
let owner=UUID()
var game=IridiumConsoleGame(id:UUID(),title:"Installed",platform:.nintendo3DS,runtimeID:"azahar",fileExtension:"app",importedAt:Date())
game.storageOwnerID=owner;game.installedPath="sdmc/title/content.app"
try game.validate()
check(try store.rom(game).path==root.appendingPathComponent("Saves/azahar/\(owner)/Azahar/sdmc/title/content.app").path)
check(try store.saveDirectory(game).path==root.appendingPathComponent("Saves/azahar/\(owner)",isDirectory:true).path)
let restored=try JSONDecoder().decode(IridiumConsoleGame.self,from:JSONEncoder().encode(game));precondition(restored==game)
game.installedPath="../outside.app"
do{try game.validate();fatalError("unsafe installed path")}catch{}
''', '.swift', sources=[SUPPORT/'IridiumRuntime.swift', SUPPORT/'IridiumCoreContent.swift', FRONTEND/'IridiumFilesImport.swift'])

    def test_cia_first_game_updates_and_failed_import_keep_library_and_storage(self):
        from test_native_psp_frontend import function
        installer=function((FRONTEND/'IridiumConsoleSession.swift').read_text(),'    @MainActor func install3DSCIA(')
        register=function((FRONTEND/'IridiumRuntimeLibrary.swift').read_text(),'    func registerInstalled(')
        self.compile_run(r'''
import Foundation
struct Bundle {static let main=Bundle();let privateFrameworksURL:URL?=FileManager.default.temporaryDirectory}
enum IridiumFilesAccess {static func read<T>(_ url:URL,operation:(URL)throws->T)throws->T{try operation(url)}}
final class IridiumConsoleLibrary:@unchecked Sendable {
    static let shared=IridiumConsoleLibrary()
    let store=IridiumConsoleStore(root:FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString))
    let queue=DispatchQueue(label:"test.library")
    var games:[IridiumConsoleGame]=[]
'''+register+r'''
}
func ir_phase3_azahar_install_cia(_ frameworks:String,_ user:String,_ file:String)->Int32 {
    let root=URL(fileURLWithPath:user),name=URL(fileURLWithPath:file).lastPathComponent
    if name=="encrypted.cia"{return 5}
    if name=="update.cia"{try! Data("update".utf8).write(to:root.appendingPathComponent("update.bin"));return 0}
    var executable=Data(repeating:0,count:512)
    executable.replaceSubrange(0x100..<0x104,with:Data("NCCH".utf8));executable[0x104]=1
    try! executable.write(to:root.appendingPathComponent("title.app"))
    let path=name=="invalid.cia" ? "../outside.app" : "title.app"
    try! JSONSerialization.data(withJSONObject:["title":"Installed Game","path":path]).write(to:root.appendingPathComponent("iridium-installed.json"))
    return 0
}
final class Session:@unchecked Sendable {
    let queue=DispatchQueue(label:"test.installer")
    var dolphinMaintenance=false
    var dolphinSystemStatus:String?
    @MainActor func beginContentMaintenance()->Bool{if dolphinMaintenance{return false};dolphinMaintenance=true;return true}
'''+installer+r'''
}
let fm=FileManager.default,library=IridiumConsoleLibrary.shared,s=Session(),root=IridiumConsoleLibrary.shared.store.root
try fm.createDirectory(at:root,withIntermediateDirectories:true)
defer{try? fm.removeItem(at:root)}
for name in ["base","update","invalid","encrypted"]{try Data(name.utf8).write(to:root.appendingPathComponent(name+".cia"))}
func wait(){let end=Date(timeIntervalSinceNow:5);while s.dolphinMaintenance&&Date()<end{
    _=RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.005))
};precondition(!s.dolphinMaintenance,"installer did not finish")}
s.install3DSCIA(root.appendingPathComponent("update.cia"));wait()
precondition(library.games.isEmpty&&s.dolphinSystemStatus!.contains("existing"))
s.install3DSCIA(root.appendingPathComponent("base.cia"));wait()
precondition(library.games.count==1&&library.games[0].installedPath=="title.app")
let game=library.games[0],rom=try library.store.validateROM(game),before=try Data(contentsOf:rom)
let saved=try library.store.load();precondition(game.storageOwnerID != game.id && saved==[game])
s.install3DSCIA(root.appendingPathComponent("update.cia"),game:game);wait()
precondition(library.games==[game]&&s.dolphinSystemStatus=="3DS update or DLC installed.")
let user=rom.deletingLastPathComponent()
precondition(fm.fileExists(atPath:user.appendingPathComponent("update.bin").path))
for name in ["invalid","encrypted"]{
    s.install3DSCIA(root.appendingPathComponent(name+".cia"),game:game);wait()
    let after=try Data(contentsOf:rom);precondition(library.games==[game] && after==before)
    precondition(fm.fileExists(atPath:user.appendingPathComponent("update.bin").path))
}
precondition(fm.fileExists(atPath:root.appendingPathComponent("base.cia").path))
''', '.swift',sources=[SUPPORT/'IridiumRuntime.swift',SUPPORT/'IridiumCoreContent.swift',FRONTEND/'IridiumFilesImport.swift'])

    def test_flycast_state_calls_preserve_running_and_paused_vm(self):
        spec=importlib.util.spec_from_file_location('content_flycast',ROOT/'ci/phase3_flycast.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            module.generated(ROOT,Path(folder))
            text=(Path(folder)/'libretro.cpp').read_text()
            state=text[text.index('size_t retro_serialize_size()'):text.index('// Cheats',text.index('size_t retro_serialize_size()'))]
        self.compile_run(r'''
#include <cassert>
#include <mutex>
#include <exception>
struct FlycastException:std::exception{const char*what()const noexcept override{return "error";}};
struct Serializer{struct Exception:FlycastException{};Serializer(){}Serializer(void*,size_t){}size_t size(){return 4;}};
struct Deserializer{struct Exception:FlycastException{};Deserializer(const void*,size_t){}};
struct Emulator{bool active=false;bool running(){return active;}void stop(){active=false;}void start(){active=true;}void loadstate(Deserializer&){}}emu;
static bool first_run=false;static std::mutex mtx_serialization;
void dc_serialize(Serializer&){}void retro_audio_flush_buffer(){}
#define DEBUG_LOG(...)
#define ERROR_LOG(...)
''' + state + r'''
int main(){for(bool running:{false,true}){char bytes[4]{};emu.active=running;
assert(retro_serialize_size()==4&&emu.active==running);
assert(retro_serialize(bytes,4)&&emu.active==running);
assert(retro_unserialize(bytes,4)&&emu.active==running);}}
''')

    def test_flycast_external_disc_failure_restores_actual_previous_disc(self):
        text=(ROOT/'vendor/Flycast/shell/libretro/libretro.cpp').read_text()
        from test_native_psp_frontend import function
        callbacks='\n'.join(function(text,name) for name in (
            'static bool retro_set_eject_state(', 'static bool retro_get_eject_state(',
            'static unsigned retro_get_image_index(', 'static bool retro_replace_image_index(',
            'static bool retro_get_image_path('))
        self.compile_run(r'''
#include "IRDiscControl.h"
#include <cassert>
#include <string>
#include <vector>
#include <stdexcept>
#include <limits.h>
struct FlycastException:std::runtime_error{using std::runtime_error::runtime_error;};
bool disc_tray_open=false,failRestore=false;
unsigned disk_index=0;
std::vector<std::string>disk_paths={"old"},disk_labels={"old"};
struct Emulator{std::string mounted="old";void openGdrom(){mounted.clear();}
void insertGdrom(const std::string&path){if(path=="throw")throw std::runtime_error("unexpected insertion failure");if(path=="bad"||(failRestore&&path=="second"))throw FlycastException("bad disc");mounted=path;}}emu;
const char*path_basename(const char*p){return p;}
void fill_pathname(char*out,const char*name,const char*,size_t size){strncpy(out,name,size-1);out[size-1]=0;}
#define ERROR_LOG(...)
'''+callbacks+r'''
int main(){retro_disk_control_ext_callback discs{};
discs.set_eject_state=retro_set_eject_state;discs.get_eject_state=retro_get_eject_state;
discs.get_image_index=retro_get_image_index;discs.replace_image_index=retro_replace_image_index;discs.get_image_path=retro_get_image_path;
assert(irDiscReplace(discs,"bad")==IRDiscResult::Failed&&disk_paths[0]=="old"&&emu.mounted=="old"&&!disc_tray_open);
assert(irDiscReplace(discs,"first")==IRDiscResult::Changed&&emu.mounted=="first");
assert(irDiscReplace(discs,"second")==IRDiscResult::Changed&&emu.mounted=="second");
assert(irDiscReplace(discs,"bad")==IRDiscResult::Failed&&disk_paths[0]=="second"&&emu.mounted=="second");
assert(irDiscReplace(discs,"throw")==IRDiscResult::Failed&&disk_paths[0]=="second"&&emu.mounted=="second");
retro_set_eject_state(true);assert(irDiscReplace(discs,"bad")==IRDiscResult::Failed&&disc_tray_open&&emu.mounted.empty());
retro_set_eject_state(false);failRestore=true;
assert(irDiscReplace(discs,"bad")==IRDiscResult::RestoreFailed&&disk_paths[0]=="second");
}
''')

    def test_play_disc_change_runs_on_vm_thread_and_keeps_old_disc_on_failure(self):
        spec=importlib.util.spec_from_file_location('content_play',ROOT/'ci/phase3_play.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        owner=next(s for s in module.generated.__code__.co_consts if isinstance(s,str) and s.startswith('class IRPlayVM'))
        disc=next(s for s in module.generated.__code__.co_consts if isinstance(s,str) and 'IRDiscResult ir_phase3_core_change_disc_result' in s)
        disc=disc.replace('#include "DiskUtils.h"','')
        from test_native_psp_frontend import function
        sync=function((ROOT/'vendor/Play/Source/PS2VM.cpp').read_text(),'void CPS2VM::CDROM0_SyncPath()')
        self.compile_run(r'''
#include <cassert>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <string>
#include <thread>
#include <stdexcept>
namespace fs=std::filesystem;
const char*PREF_PS2_CDROM0_PATH="disc";
std::thread::id mainThread=std::this_thread::get_id();
bool failMount=false,failRestore=false;
struct Media{std::string path;};
namespace DiskUtils{auto CreateOpticalMediaFromPath(const fs::path&p){
 if(p=="bad"||(std::this_thread::get_id()!=mainThread&&((failMount&&p=="new")||(failRestore&&p=="old"))))throw std::runtime_error("bad");
 return std::make_unique<Media>(p.string());}}
struct CAppConfig{fs::path path="old";static CAppConfig&GetInstance(){static CAppConfig c;return c;}
fs::path GetPreferencePath(const char*){return path;}void SetPreferencePath(const char*,fs::path value){path=value;}};
struct CVirtualMachine{enum{PAUSED,RUNNING};};
struct CPS2VM{
 virtual ~CPS2VM()=default;int status=CVirtualMachine::PAUSED;std::unique_ptr<Media>m_cdrom0=std::make_unique<Media>("old");
 int GetStatus(){return status;}
 void CDROM0_SyncPath();void CDROM0_Reset(){assert(std::this_thread::get_id()!=mainThread);m_cdrom0.reset();}
 void SetIopOpticalMedia(Media*){}
protected:struct Mailbox{template<typename F>void SendCall(F&&f,bool){std::thread worker([&]{f();});worker.join();}}m_mailBox;
};
''' + sync + owner + r'''
static CPS2VM*m_virtualMachine;
''' + disc + r'''
int main(){assert(ir_phase3_core_change_disc_result("new")==IRDiscResult::Failed);IRPlayVM vm;m_virtualMachine=&vm;
assert(ir_phase3_core_change_disc_result("bad")==IRDiscResult::Failed&&vm.m_cdrom0->path=="old");
failMount=true;assert(ir_phase3_core_change_disc_result("new")==IRDiscResult::Failed&&vm.m_cdrom0->path=="old");
failRestore=true;assert(ir_phase3_core_change_disc_result("new")==IRDiscResult::RestoreFailed&&!vm.m_cdrom0);
failMount=failRestore=false;assert(ir_phase3_core_change_disc_result("new")==IRDiscResult::Changed&&vm.m_cdrom0->path=="new");
vm.status=CVirtualMachine::RUNNING;assert(ir_phase3_core_change_disc_result("old")==IRDiscResult::Failed&&vm.m_cdrom0->path=="new");}
''')

    def test_play_resolution_notifies_host_before_scaled_draw(self):
        from test_native_psp_frontend import function
        spec=importlib.util.spec_from_file_location('geometry_play',ROOT/'ci/phase3_play.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            module.generated(ROOT,Path(folder))
            flip=function((Path(folder)/'GSH_OpenGL_Libretro.cpp').read_text(),'void CGSH_OpenGL_Libretro::FlipImpl(')
            initialize=function((Path(folder)/'GSH_OpenGL_Libretro.cpp').read_text(),'void CGSH_OpenGL_Libretro::InitializeImpl()')
            gs=(Path(folder)/'GSHandler.cpp').read_text()
            self.assertIn('SendGSCall([&]() { SyncMemoryCache(); }, true, true);',gs)
        self.compile_run(r'''
#include "libretro.h"
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <stdexcept>
unsigned width=640,height=448,maxWidth=1024,maxHeight=1024,draws=0,initializations=0;
int g_res_factor=1;bool accepts=true;
struct DISPLAY_INFO{};
struct CGSH_OpenGL{
 void FlipImpl(const DISPLAY_INFO&){assert(width*g_res_factor<=maxWidth&&height*g_res_factor<=maxHeight);++draws;}
 void InitializeImpl(){assert(width*g_res_factor<=maxWidth&&height*g_res_factor<=maxHeight);++initializations;}
};
struct CGSH_OpenGL_Libretro:CGSH_OpenGL{
 unsigned m_presentFramebuffer=0;unsigned GetCrtWidth(){return width;}unsigned GetCrtHeight(){return height;}
 void FlipImpl(const DISPLAY_INFO&);void InitializeImpl();void UpdatePresentationImpl(){}
};
retro_hw_render_callback g_hw_render{};
bool geometry(unsigned command,void*data){assert(command==RETRO_ENVIRONMENT_SET_GEOMETRY);
 auto info=static_cast<retro_game_geometry*>(data);assert(info->base_width==width*g_res_factor&&info->base_height==height*g_res_factor);
 if(!accepts||info->base_width>4096||info->base_height>4096)return false;
 maxWidth=std::max(maxWidth,info->base_width);maxHeight=std::max(maxHeight,info->base_height);return true;}
retro_environment_t g_environ_cb=geometry;
struct CLog{static CLog&GetInstance(){static CLog log;return log;}template<class...T>void Print(T...){}};
#define LOG_NAME "test"
''' + flip + initialize + r'''
int main(){CGSH_OpenGL_Libretro gs;DISPLAY_INFO info;
 g_hw_render.get_current_framebuffer=[]()->uintptr_t{return 7;};
 g_res_factor=4;gs.InitializeImpl();assert(initializations==1);
 for(auto w:{640u,720u})for(auto h:{448u,576u})for(int scale:{1,2,4}){
  width=w;height=h;g_res_factor=scale;gs.FlipImpl(info);assert(gs.m_presentFramebuffer==7);
 }
 assert(draws==12);accepts=false;
 try{gs.FlipImpl(info);assert(false);}catch(const std::runtime_error&){}assert(draws==12);
 accepts=true;width=2048;g_res_factor=4;
 try{gs.FlipImpl(info);assert(false);}catch(const std::runtime_error&){}assert(draws==12);
}
''')

    def test_disc_restore_failure_blocks_host_resume(self):
        source=(BRIDGE/'IRRetroPlayer.mm').read_text()
        start=source.index('                const auto result=api.changeDisc?')
        end=source.index('                if(success)report(6,"Disc changed.");',start)
        block=source[start:end]
        self.compile_run(r'''
#import <Foundation/Foundation.h>
#include "IRDiscControl.h"
#include <cassert>
unsigned failure=0;void report(unsigned kind,const char*){failure=kind;}
IRDiscResult result=IRDiscResult::Failed;
struct Player{
 struct{IRDiscResult(*changeDisc)(const char*)=[](const char*){return result;};}api;
 retro_disk_control_ext_callback discs{};bool cleanupUncertain=false,success=false;
 void change(){NSString*path=@"/tmp/disc";
''' + block + r'''
 }
};
int main(){@autoreleasepool{
 for(auto value:{IRDiscResult::Failed,IRDiscResult::Changed,IRDiscResult::RestoreFailed}){
  result=value;failure=0;Player player;player.change();
  assert(player.success==(value==IRDiscResult::Changed));
  assert(player.cleanupUncertain==(value==IRDiscResult::RestoreFailed));
  assert(failure==(value==IRDiscResult::RestoreFailed?3u:0u));
 }
}}
''','.mm',frameworks=['Foundation'])

    def test_host_render_target_growth_keeps_bindings_and_rejects_failed_allocation(self):
        source=(BRIDGE/'IRRetroPlayer.mm').read_text()
        start=source.index('    if(!geometry.base_width',source.index('- (bool)updateGeometry:(retro_game_geometry)geometry {'))
        end=source.index('    if(api.metalSurface)',start)
        self.compile_run(r'''
#include "libretro.h"
#include <algorithm>
#include <cassert>
#include <cmath>
using GLint=int;using GLuint=unsigned;
enum{GL_TEXTURE_BINDING_2D,GL_RENDERBUFFER_BINDING,GL_DRAW_FRAMEBUFFER_BINDING,GL_TEXTURE_2D,
 GL_RGBA,GL_UNSIGNED_BYTE,GL_RENDERBUFFER,GL_DEPTH24_STENCIL8,GL_DRAW_FRAMEBUFFER,GL_FRAMEBUFFER_COMPLETE};
int texture=71,buffer=72,target=73;bool complete=true;unsigned allocations=0;
void glGetIntegerv(int key,int*out){*out=key==GL_TEXTURE_BINDING_2D?texture:key==GL_RENDERBUFFER_BINDING?buffer:target;}
void glBindTexture(int,unsigned n){texture=n;}void glBindRenderbuffer(int,unsigned n){buffer=n;}
void glBindFramebuffer(int,unsigned n){target=n;}int glCheckFramebufferStatus(int){assert(target==7);return complete?GL_FRAMEBUFFER_COMPLETE:0;}
void glTexImage2D(int,int,int,unsigned,unsigned,int,int,int,void*){++allocations;assert(texture==5);}
void glRenderbufferStorage(int,int,unsigned,unsigned){assert(buffer==6);}
struct Player{
 bool hardwareSelected=true;GLuint color=5,depth=6,renderTarget=7;
 unsigned maxWidth=1024,maxHeight=1024;double displayAspect=0;
 bool grow(unsigned w,unsigned h){retro_game_geometry geometry{w,h,4096,4096,4.0f/3.0f};
''' + source[start:end] + r'''
 return true;}
};
int main(){
 for(bool valid:{false,true}){complete=valid;allocations=0;Player player;
  assert(player.grow(640,448)&&allocations==0);
  assert(player.grow(2560,1792)==valid&&allocations==1);
  assert(texture==71&&buffer==72&&target==73);
  assert(!player.grow(8192,1792)&&allocations==1);
 }
}
''')

    def test_azahar_camera_converts_colors_flips_and_returns_blank_without_capture(self):
        interface=r'''
#pragma once
#include <vector>
#include <cstdint>
using u16=uint16_t;
namespace Service::CAM{
enum class Flip{NoFlip,Horizontal,Vertical,Reverse};enum class Effect{NoEffect,Mono,Sepia,Negative,Negafilm,Sepia01};
enum class OutputFormat{YUV422,RGB565};enum class FrameRate{Rate_30};struct Resolution{unsigned width,height;};}
namespace Camera{class CameraInterface{public:virtual~CameraInterface()=default;
virtual void StartCapture()=0;virtual void StopCapture()=0;virtual void SetResolution(const Service::CAM::Resolution&)=0;
virtual void SetFlip(Service::CAM::Flip)=0;virtual void SetEffect(Service::CAM::Effect)=0;virtual void SetFormat(Service::CAM::OutputFormat)=0;
virtual void SetFrameRate(Service::CAM::FrameRate)=0;virtual std::vector<u16>ReceiveFrame()=0;virtual bool IsPreviewAvailable()=0;};}
'''
        factory=r'''
#pragma once
#include "core/frontend/camera/interface.h"
#include <memory>
#include <string>
namespace Camera{class CameraFactory{public:virtual~CameraFactory()=default;
virtual std::unique_ptr<CameraInterface>Create(const std::string&,const Service::CAM::Flip&)=0;};
inline std::unique_ptr<CameraFactory>factory;
inline void RegisterFactory(const std::string&,std::unique_ptr<CameraFactory>value){factory=std::move(value);}}
'''
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            headers={'core/frontend/camera/interface.h':interface,'core/frontend/camera/factory.h':factory,
                'core/hle/service/cam/cam.h':'#include "core/frontend/camera/interface.h"\n',
                'common/settings.h':'#pragma once\n#include <array>\n#include <string>\nnamespace Settings{struct Values{std::array<std::string,3>camera_name,camera_config;};inline Values values;}\n'}
            for name,text in headers.items():
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text)
            unit=root/'check.cpp'
            unit.write_text(r'''
#include <cassert>
#include <thread>
#include <atomic>
#include "IRAzaharCamera.cpp"
::Camera::CameraInterface *changingCamera=nullptr;
bool changeSettings=false;
bool capture=false;
void request(void*,unsigned,bool active){capture=active;}
bool read(void*,uint32_t*p,size_t capacity,unsigned*w,unsigned*h){
if(changeSettings){changeSettings=false;std::thread setter([]{
    changingCamera->SetResolution({4,4});changingCamera->SetFlip(Service::CAM::Flip::Reverse);
    changingCamera->SetEffect(Service::CAM::Effect::Mono);changingCamera->SetFormat(Service::CAM::OutputFormat::YUV422);
});setter.join();}
if(!capture)return false;assert(capacity>=4);*w=2;*h=2;p[0]=0xFFFF0000;p[1]=0xFF00FF00;p[2]=0xFF0000FF;p[3]=0xFFFFFFFF;return true;}
int main(){IRCameraSource api{1,nullptr,request,read};assert(ir_phase3_core_camera(&api));api.version=2;assert(!ir_phase3_core_camera(&api));
ir_azahar_register_camera();auto camera=::Camera::factory->Create("0",Service::CAM::Flip::NoFlip);
camera->SetResolution({2,2});camera->SetFormat(Service::CAM::OutputFormat::RGB565);
assert(camera->ReceiveFrame()==std::vector<u16>({0,0,0,0}));camera->StartCapture();
assert(camera->ReceiveFrame()==std::vector<u16>({0xf800,0x07e0,0x001f,0xffff}));
camera->SetFlip(Service::CAM::Flip::Horizontal);assert(camera->ReceiveFrame()==std::vector<u16>({0x07e0,0xf800,0xffff,0x001f}));
changingCamera=camera.get();changeSettings=true;
assert(camera->ReceiveFrame()==std::vector<u16>({0x07e0,0xf800,0xffff,0x001f}));
assert(camera->ReceiveFrame().size()==16);
std::thread first([&]{for(int i=0;i<20;++i)assert(camera->ReceiveFrame().size()==16);});
std::thread second([&]{for(int i=0;i<20;++i)assert(camera->ReceiveFrame().size()==16);});first.join();second.join();
camera->SetResolution({2,2});camera->SetEffect(Service::CAM::Effect::NoEffect);
camera->SetFlip(Service::CAM::Flip::NoFlip);camera->SetFormat(Service::CAM::OutputFormat::YUV422);auto yuv=camera->ReceiveFrame();
assert(yuv[0]==(82|(72<<8))&&yuv[1]==(144|(137<<8)));camera->StopCapture();assert(!capture);
assert(camera->ReceiveFrame()==std::vector<u16>({0x8000,0x8000,0x8000,0x8000}));}
''')
            subprocess.run(['clang++','-std=c++20','-fsanitize=address','-fno-omit-frame-pointer','-I',str(root),'-I',str(BRIDGE),str(unit),'-o',str(root/'check')],check=True,timeout=30)
            subprocess.run([str(root/'check')],check=True,timeout=5)

    def test_microphone_extension_matches_the_pinned_libretro_abi(self):
        header=next((ROOT/'.build/phase3-downloads').glob('azahar-*/externals/libretro-common/libretro-common/include/libretro.h'),None)
        if header is None:self.skipTest('Azahar source package is not initialized')
        self.compile_run('#include "IRCoreCapture.h"\n#include "'+str(header)+'"\n#include <cstddef>\n#include <cassert>\nint main(){'
            'static_assert(sizeof(IRMicrophoneInterface)==sizeof(retro_microphone_interface));'
            'static_assert(sizeof(IRMicrophoneParams)==sizeof(retro_microphone_params_t));'
            'static_assert(offsetof(IRMicrophoneInterface,read)==offsetof(retro_microphone_interface,read_mic));'
            'static_assert(RETRO_ENVIRONMENT_GET_MICROPHONE_INTERFACE==(75|RETRO_ENVIRONMENT_EXPERIMENTAL));}', '.mm',frameworks=['Foundation'])

    def test_dolphin_empty_and_disabled_cheats_preserve_global_switch(self):
        text=(BRIDGE/'IRDolphin.mm').read_text()
        method=text[text.index('static bool dolphinCheats(id records)'):text.index('\nstatic bool dolphinPatches',text.index('static bool dolphinCheats'))]
        self.compile_run(r'''
#import <Foundation/Foundation.h>
#include "IRCheats.h"
#include <algorithm>
#include <cassert>
#include <sstream>
#include <string>
#include <variant>
namespace Config{enum Key{MAIN_ENABLE_CHEATS};bool enabled=false;void SetCurrent(Key,bool value){enabled=value;}}
struct SConfig{static SConfig&GetInstance(){static SConfig c;return c;}int LoadDefaultGameIni(){return 0;}int LoadLocalGameIni(){return 0;}std::string GetGameID(){return "TEST";}int GetRevision(){return 0;}};
namespace Gecko{struct GeckoCode{struct Line{uint32_t address,value;std::string text;};std::string name;bool enabled=false,user_defined=false;std::vector<Line>codes;};
auto LoadCodes(int,int){return std::vector<GeckoCode>{};}void SetActiveCodes(const std::vector<GeckoCode>&,const std::string&,int){}}
namespace ActionReplay{struct EncryptedLine{};struct Other{};struct ARCode{std::string name;bool enabled=false,user_defined=false;std::vector<std::pair<uint32_t,uint32_t>>ops;};
auto LoadCodes(int,int){return std::vector<ARCode>{};}auto DeserializeLine(const std::string&){return std::variant<EncryptedLine,Other>{Other{}};}
void DecryptARCode(const std::vector<std::string>&,std::vector<std::pair<uint32_t,uint32_t>>*){}void ApplyCodes(const std::vector<ARCode>&,const std::string&,int){}}
''' + method + r'''
int main(){@autoreleasepool{
assert(dolphinCheats(@[])&&!Config::enabled);
id record=@{@"name":@"Test",@"format":@"gecko",@"code":@"12345678 00000000",@"enabled":@NO};
assert(dolphinCheats(@[record])&&!Config::enabled);
record=@{@"name":@"Test",@"format":@"gecko",@"code":@"12345678 00000000",@"enabled":@YES};
assert(dolphinCheats(@[record])&&Config::enabled);
}}
''', '.mm', frameworks=['Foundation'])

    def test_dolphin_patches_preserve_other_sections_and_reject_partial_edits(self):
        from test_native_psp_frontend import function
        upstream = ROOT / 'vendor/Dolphin/Source/Core'
        patch = (upstream / 'Core/PatchEngine.cpp').read_text()
        header = (upstream / 'Core/PatchEngine.h').read_text()
        types = header[header.index('enum class PatchType'):header.index('const char* PatchTypeAsString')]
        parser = function(patch, 'std::optional<PatchEntry> DeserializeLine')
        save = function(patch, 'void SavePatchSection(')
        adapter = function((BRIDGE / 'IRDolphin.mm').read_text(), 'static bool dolphinPatches(')
        self.compile_run(r'''
#import <Foundation/Foundation.h>
#include "IRCheats.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <map>
#include <optional>
#include <sstream>
#include <string>
using u32=uint32_t;
static bool failSave=false;static int saves=0,reloads=0,cheatsRestored=0;
using Sections=std::map<std::string,std::vector<std::string>>;
static Sections published{{"Video",{"Keep this setting"}}};
namespace Common{struct IniFile{
 Sections sections=published;
 void SetLines(const std::string&key,const std::vector<std::string>&lines){sections[key]=lines;}
 bool Save(const std::string&){if(failSave)return false;published=sections;++saves;return true;}
};}
namespace Core{struct System{static System&GetInstance(){static System s;return s;}};}
namespace File{std::string GetUserPath(int){return "/user/";}}constexpr int D_GAMESETTINGS_IDX=0;
struct SConfig{static SConfig&GetInstance(){static SConfig c;return c;}
Common::IniFile LoadDefaultGameIni(){return {};}Common::IniFile LoadLocalGameIni(){return {};}
std::string GetGameID(){return "GAME01";}};
static bool dolphinCheats(id){++cheatsRestored;return true;}
std::vector<std::string>SplitString(std::string text,char delimiter){std::istringstream in(text);std::vector<std::string>out;for(std::string s;std::getline(in,s,delimiter);)out.push_back(s);return out;}
bool TryParse(const std::string&text,u32*value){try{size_t n=0;auto result=std::stoul(text,&n,0);if(n!=text.size()||result>UINT32_MAX)return false;*value=(u32)result;return true;}catch(...){return false;}}
namespace PatchEngine{
''' + types + r'''
constexpr std::array<const char*,3>s_patch_type_strings{{"byte","word","dword"}};
''' + parser + r'''
std::string SerializeLine(const PatchEntry&entry){return std::to_string(entry.address)+":"+s_patch_type_strings[(int)entry.type]+":"+std::to_string(entry.value);}
void LoadPatchSection(const char*,std::vector<Patch>*out,const Common::IniFile&,const Common::IniFile&){Patch p;p.name="Built-in";p.entries={*DeserializeLine("0x80000000:byte:0")};p.enabled=p.default_enabled=true;out->push_back(p);}
''' + save + r'''
void Reload(Core::System&){++reloads;}
}
''' + adapter + r'''
id record(NSString*name,NSString*code,bool enabled){return @{@"name":name,@"format":@"patch",@"code":code,@"enabled":@(enabled)};}
int main(){@autoreleasepool{
id builtin=record(@"Built-in",@"0x80000000:byte:0",false);
id custom=record(@"Custom",@"0x80000001:word:1",true);
assert(dolphinPatches(@[builtin,custom],@[])&&saves==1&&reloads==1&&cheatsRestored==1);
assert(published["Video"]==std::vector<std::string>{"Keep this setting"});
assert(published["OnFrame_Disabled"]==std::vector<std::string>{"$Built-in"});
assert(published["OnFrame"].size()==2&&published["OnFrame"][0]=="$Custom");
auto old=published;
for(id records in @[@[custom,record(@"Bad",@"invalid",true)],@[custom,custom],
                   @[record(@"Built-in",@"0x80000000:byte:1",true)],@[record(@"Name\n[Other]",@"0:byte:0",true)]]){
 assert(!dolphinPatches(records,@[])&&published==old&&saves==1&&reloads==1&&cheatsRestored==1);
}
failSave=true;assert(!dolphinPatches(@[],@[])&&published==old&&reloads==1);
failSave=false;assert(dolphinPatches(@[],nil)&&published["OnFrame"].empty()&&reloads==2&&cheatsRestored==1);
}}
''', '.mm', frameworks=['Foundation'])

    def test_display_blit_restores_core_state_even_if_presentation_fails(self):
        text=(BRIDGE/'IRRetroPlayer.mm').read_text()
        begin=text.index('        GLint readTarget=0,drawTarget=0,previousRenderbuffer=0;')
        end=text.index('        if(!presented)return;',begin)+len('        if(!presented)return;')
        block=text[begin:end]
        self.compile_run(r'''
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cassert>
using GLint=int;using GLuint=unsigned;using GLfloat=float;using GLboolean=bool;
enum{GL_READ_FRAMEBUFFER_BINDING,GL_DRAW_FRAMEBUFFER_BINDING,GL_RENDERBUFFER_BINDING,GL_COLOR_CLEAR_VALUE,GL_SCISSOR_TEST,GL_READ_FRAMEBUFFER,GL_DRAW_FRAMEBUFFER,GL_RENDERBUFFER,GL_COLOR_BUFFER_BIT,GL_NEAREST};
int readFbo=71,drawFbo=72,renderbuffer=73;bool scissor=true;float clearColor[4]={.1,.2,.3,.4};
void glGetIntegerv(int key,int*p){*p=key==GL_READ_FRAMEBUFFER_BINDING?readFbo:key==GL_DRAW_FRAMEBUFFER_BINDING?drawFbo:renderbuffer;}
void glGetFloatv(int,float*p){std::copy(clearColor,clearColor+4,p);}bool glIsEnabled(int){return scissor;}
void glBindFramebuffer(int key,unsigned n){(key==GL_READ_FRAMEBUFFER?readFbo:drawFbo)=(int)n;}
void glBindRenderbuffer(int,unsigned n){renderbuffer=(int)n;}void glEnable(int){scissor=true;}void glDisable(int){scissor=false;}
void glClearColor(float r,float g,float b,float a){clearColor[0]=r;clearColor[1]=g;clearColor[2]=b;clearColor[3]=a;}void glClear(int){}
void glBlitFramebuffer(int,int,int,int,int,int,int,int,int,int){assert(!scissor&&readFbo==5&&drawFbo==6);}
static bool acceptPresentation=true;
@interface Context:NSObject
- (bool)presentRenderbuffer:(unsigned)target;
@end
@implementation Context
- (bool)presentRenderbuffer:(unsigned)target{return acceptPresentation;}
@end
struct Player{unsigned renderTarget=5,displayTarget=6,displayColor=7;int width=100,height=100;unsigned w=10,h=10;double displayAspect=1;struct{bool bottom_left_origin=false;}hardware;Context*context=[Context new];void video(){
''' + block + r'''
}};
int main(){@autoreleasepool{for(bool enabled:{false,true})for(bool success:{false,true}){scissor=enabled;acceptPresentation=success;Player p;p.video();assert(readFbo==71&&drawFbo==72&&renderbuffer==73&&scissor==enabled);assert(clearColor[0]==.1f&&clearColor[3]==.4f);}}}
''', '.mm', frameworks=['Foundation'])

    def test_rumble_recreates_output_after_reset_or_start_failure(self):
        source=(FRONTEND/'IridiumControllerRumble.swift').read_text().replace('import CoreHaptics','').replace('import GameController','')
        source=source.replace('self?.remove(key, matching: generation)', 'self?.remove(key, matching: generation); Callbacks.count += 1')
        self.compile_run(r'''
import Foundation
@MainActor enum Callbacks{static var count=0}
let CHHapticTimeImmediate:Double=0
enum ParameterID{case hapticIntensity,hapticSharpness,hapticIntensityControl}
struct CHHapticEventParameter{init(parameterID:ParameterID,value:Float){}}
struct CHHapticDynamicParameter{init(parameterID:ParameterID,value:Float,relativeTime:Double){}}
enum EventType{case hapticContinuous}
struct CHHapticEvent{init(eventType:EventType,parameters:[CHHapticEventParameter],relativeTime:Double,duration:Double){}}
struct CHHapticPattern{init(events:[CHHapticEvent],parameters:[Int])throws{}}
@MainActor protocol CHHapticAdvancedPatternPlayer:AnyObject{
 var loopEnabled:Bool{get set};func stop(atTime:Double)throws;func start(atTime:Double)throws
 func sendParameters(_ values:[CHHapticDynamicParameter],atTime:Double)throws
}
@MainActor final class Player:CHHapticAdvancedPatternPlayer{
 var loopEnabled=false,running=false
 func stop(atTime:Double)throws{running=false}
 func start(atTime:Double)throws{running=true}
 func sendParameters(_ values:[CHHapticDynamicParameter],atTime:Double)throws{}
}
@MainActor final class CHHapticEngine{
 static var engines:[CHHapticEngine]=[],failNext=false
 var playsHapticsOnly=false,resetHandler:(()->Void)?,stoppedHandler:((Int)->Void)?
 let player=Player();var stops=0
 init(){Self.engines.append(self)}
 func makeAdvancedPlayer(with pattern:CHHapticPattern)throws->any CHHapticAdvancedPatternPlayer{player}
 func start()throws{if Self.failNext{Self.failNext=false;throw NSError(domain:"test",code:1)}}
 func stop(completionHandler:((Error?)->Void)?){stops+=1;stoppedHandler?(0)}
}
enum Locality{case `default`}
@MainActor final class Haptics{func createEngine(withLocality:Locality)->CHHapticEngine?{CHHapticEngine()}}
@MainActor final class GCController{
 static var connected:[GCController]=[]
 var haptics:Haptics?=Haptics()
 static func controllers()->[GCController]{connected}
}
''' + source + r'''
Task{@MainActor in
 let controller=GCController();GCController.connected=[controller]
 let output=IridiumControllerRumble();output.set(controller,motor:0,strength:50000)
 precondition(CHHapticEngine.engines.count==1&&CHHapticEngine.engines[0].player.running)
 CHHapticEngine.engines[0].resetHandler?()
 while Callbacks.count<1{await Task.yield()}
 precondition(CHHapticEngine.engines[0].stops>0)
 output.set(controller,motor:0,strength:50000)
 precondition(CHHapticEngine.engines.count==2&&CHHapticEngine.engines[1].player.running)
 output.stopAll();CHHapticEngine.failNext=true
 output.set(controller,motor:0,strength:50000)
 precondition(CHHapticEngine.engines.count==3 && !CHHapticEngine.engines[2].player.running)
 output.set(controller,motor:0,strength:50000)
 precondition(CHHapticEngine.engines.count==4&&CHHapticEngine.engines[3].player.running)
 let old=CHHapticEngine.engines[3]
 old.resetHandler?();old.stoppedHandler?(0)
 output.stopAll();output.set(controller,motor:0,strength:50000)
 let replacement=CHHapticEngine.engines[4]
 precondition(replacement.player.running)
 while Callbacks.count<3{await Task.yield()}
 precondition(replacement.player.running&&replacement.stops==0)
 output.stopAll();exit(0)
}
dispatchMain()
''', '.swift')


if __name__ == '__main__':
    unittest.main()
