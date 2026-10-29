"""Exercise Play's complete VM snapshot path through the host state adapter."""
from pathlib import Path
import re
import unittest
import test_core_controls as controls
from test_native_psp_frontend import function

ROOT = Path(__file__).resolve().parents[1]


class PlayStateTests(unittest.TestCase):
    def test_full_vm_timing_graphics_sync_bounds_and_temporary_cleanup(self):
        upstream = (ROOT / 'vendor/Play/Source/PS2VM.cpp').read_text()
        definitions = '\n'.join(re.findall(r'^#define STATE_VM_TIMING_.*$', upstream, re.MULTILINE))
        methods = '\n'.join(function(upstream, signature) for signature in (
            'std::future<bool> CPS2VM::SaveState(', 'std::future<bool> CPS2VM::LoadState(',
            'bool CPS2VM::SaveVMState(', 'bool CPS2VM::LoadVMState(',
            'void CPS2VM::SaveVmTimingState(', 'void CPS2VM::LoadVmTimingState('))
        controls.CoreControlsTests().compile_run(r'''
#include <atomic>
#include <cassert>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <future>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>
namespace fs=std::filesystem;
using Registers=std::map<std::string,uint64_t>;
struct CRegisterStateFile {
 std::string name;Registers values;
 explicit CRegisterStateFile(const char* name):name(name){}
 explicit CRegisterStateFile(const Registers& values):values(values){}
 void SetRegister32(const char*key,uint32_t value){values[key]=value;}
 void SetRegister64(const char*key,uint64_t value){values[key]=value;}
 uint32_t GetRegister32(const char*key){return values.at(key);}
 uint64_t GetRegister64(const char*key){return values.at(key);}
};
namespace Framework {
auto CreateOutputStdStream(const fs::path::string_type& path){return std::ofstream(path,std::ios::binary);}
auto CreateInputStdStream(const fs::path::string_type& path){return std::ifstream(path,std::ios::binary);}
struct CZipArchiveWriter {
 std::map<std::string,Registers> files;
 void InsertFile(std::unique_ptr<CRegisterStateFile> file){files[file->name]=file->values;}
 void Write(std::ofstream& out){
  for(auto&[name,values]:files)for(auto&[key,value]:values)out<<name<<' '<<key<<' '<<value<<'\n';
  if(!out)throw std::runtime_error("write");
 }
};
struct CZipArchiveReader {
 std::map<std::string,Registers> files;
 explicit CZipArchiveReader(std::ifstream& in){std::string name,key;uint64_t value;
  while(in>>name>>key>>value)files[name][key]=value;
 }
 const Registers* BeginReadFile(const char*name){return &files.at(name);}
};
}
struct Device {
 const char*name;uint64_t value=1;
 void SaveState(Framework::CZipArchiveWriter& archive){auto file=std::make_unique<CRegisterStateFile>(name);file->SetRegister64("value",value);archive.InsertFile(std::move(file));}
 void LoadState(Framework::CZipArchiveReader& archive){value=archive.BeginReadFile(name)->at("value");}
};
struct CGSH_OpenGL_Libretro:Device {
 CGSH_OpenGL_Libretro():Device{"gs"}{}
 std::atomic<bool> pending=false;unsigned flushes=0;
 void FlushMailBox(){++flushes;pending=false;}
 void SaveState(Framework::CZipArchiveWriter& archive){
  pending=true;while(pending.load())std::this_thread::yield();Device::SaveState(archive);
 }
};
struct EE:Device {CGSH_OpenGL_Libretro*m_gs;EE(CGSH_OpenGL_Libretro*gs):Device{"ee"},m_gs(gs){}};
struct CVirtualMachine{enum STATUS{PAUSED,RUNNING};};
struct CPS2VM {
 CGSH_OpenGL_Libretro gs;EE ee{&gs};Device iop{"iop"};EE*m_ee=&ee;Device*m_iop=&iop;
 int m_vblankTicks=17,m_eeExecutionTicks=23,m_iopExecutionTicks=31;bool m_inVblank=true;
 uint64_t m_spuUpdateTicks=0x123456789ULL;int status=CVirtualMachine::PAUSED,reloads=0,notifications=0;
 bool failSave=false;
 struct Mailbox{
  std::vector<std::thread> workers;
  template<class F>void SendCall(F work){workers.emplace_back(work);}
  ~Mailbox(){for(auto&worker:workers)worker.join();}
 }m_mailBox;
 int GetStatus(){return status;}auto GetGSHandler(){return &gs;}
 void ReloadFrameRateLimit(){++reloads;}void OnMachineStateChange(){++notifications;}void PauseImpl(){status=CVirtualMachine::PAUSED;}
 std::future<bool>SaveState(const fs::path&);std::future<bool>LoadState(const fs::path&);
 bool SaveVMState(const fs::path&);bool LoadVMState(const fs::path&);
 void SaveVmTimingState(Framework::CZipArchiveWriter&);void LoadVmTimingState(Framework::CZipArchiveReader&);
};
''' + definitions + '\n' + methods.replace('auto stateStream = Framework::CreateOutputStdStream(statePath.native());',
                                  'if(failSave)return false;\n\t\tauto stateStream = Framework::CreateOutputStdStream(statePath.native());') + r'''
#include "IRPlayState.h"
size_t temporaries(){size_t count=0;for(auto&file:fs::directory_iterator(fs::temp_directory_path()))
 if(file.path().filename().string().starts_with("iridium-play-state-"))++count;return count;}
int main(){
 auto before=temporaries();CPS2VM vm;std::vector<unsigned char> bytes(irPlayStateSize,0xff);
 assert(irPlaySaveState(&vm,bytes.data(),bytes.size()));assert(temporaries()==before&&vm.gs.flushes>0);
 uint32_t header[2];memcpy(header,bytes.data(),8);assert(header[0]==irPlayStateMagic&&header[1]>0);
 for(size_t i=8+header[1];i<bytes.size();++i)assert(bytes[i]==0);
 vm.ee.value=vm.iop.value=vm.gs.value=99;
 vm.m_vblankTicks=vm.m_eeExecutionTicks=vm.m_iopExecutionTicks=99;vm.m_inVblank=false;vm.m_spuUpdateTicks=99;
 assert(irPlayLoadState(&vm,bytes.data(),bytes.size()));assert(temporaries()==before);
 assert(vm.ee.value==1&&vm.iop.value==1&&vm.gs.value==1);
 assert(vm.m_vblankTicks==17&&vm.m_eeExecutionTicks==23&&vm.m_iopExecutionTicks==31&&vm.m_inVblank);
 assert(vm.m_spuUpdateTicks==0x123456789ULL&&vm.reloads==1&&vm.notifications==1);
 auto invalid=bytes;invalid[0]^=1;assert(!irPlayLoadState(&vm,invalid.data(),invalid.size()));
 uint32_t badLength=irPlayStateSize;memcpy(invalid.data(),bytes.data(),8);memcpy(invalid.data()+4,&badLength,4);
 assert(!irPlayLoadState(&vm,invalid.data(),invalid.size())&&vm.notifications==1);
 assert(!irPlaySaveState(&vm,bytes.data(),bytes.size()-1));assert(!irPlayLoadState(&vm,bytes.data(),bytes.size()-1));
 vm.status=CVirtualMachine::RUNNING;assert(!irPlaySaveState(&vm,bytes.data(),bytes.size()));assert(!irPlayLoadState(&vm,bytes.data(),bytes.size()));
 vm.status=CVirtualMachine::PAUSED;vm.failSave=true;assert(!irPlaySaveState(&vm,bytes.data(),bytes.size()));
 assert(temporaries()==before);
}
''')


if __name__ == '__main__':
    unittest.main()
