"""Cancel an admitted production patch immediately before its virtual translation."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest
import ppsspp_native_overlay as overlay
ROOT=Path(__file__).resolve().parents[1]
UPSTREAM=ROOT/'vendor/PPSSPP'
BRIDGE=ROOT/'iridium/apps/ios/RuntimeBridge'


def method(text,signature):
    start=text.index(signature);brace=text.index('{',start);depth=1;end=brace+1
    while depth:
        depth += (text[end]=='{')-(text[end]=='}');end+=1
    return text[start:end]


@unittest.skipUnless(platform.system()=='Darwin' and shutil.which('clang++'),'Darwin compiler required')
class PatchCancellationTests(unittest.TestCase):
    def test_production_classic_ir_and_code_pointer_translation_decline_cancellation(self):
        classic=overlay.apply('Core/MIPS/ARM64/Arm64Jit.cpp',(UPSTREAM/'Core/MIPS/ARM64/Arm64Jit.cpp').read_text())
        ir=overlay.apply('Core/MIPS/ARM64/Arm64IRJit.cpp',(UPSTREAM/'Core/MIPS/ARM64/Arm64IRJit.cpp').read_text())
        bodies='\n'.join([method(classic,'void Arm64Jit::LinkBlock('),method(classic,'void Arm64Jit::UnlinkBlock('),method(ir,'void Arm64JitBackend::OverwriteExit('),method(ir,'void Arm64JitBackend::InvalidateBlock(')])
        bodies=bodies.replace('Arm64Jit::','Patch::').replace('Arm64JitBackend::','Patch::').replace('ARM64XEmitter emit','ObservedEmitter emit')
        fixture=r'''
#define ProtectMemoryPages FixtureForbiddenProtection
#include "psp_prepared_memory_fixture.h"
#undef ProtectMemoryPages
static unsigned constructions,translations;
static bool cancelTranslation;
static int coreState;
enum {CORE_RUNTIME_ERROR=9};void Core_UpdateState(int s){coreState=s;}
constexpr auto SCRATCH1=W16,CTXREG=X20;
struct MIPSState {uint32_t pc;};
bool ProtectMemoryPages(const void *p,size_t n,uint32_t flags) {
 void *rx=nullptr;if(ir_psp_exec_translate(p,n,false,&rx))return !(flags&MEM_PROT_EXEC)||ir_psp_exec_publish(rx,n);
 return ir_psp_exec_validate(p,n,false) && (!(flags&MEM_PROT_EXEC)||ir_psp_exec_publish(p,n));
}
struct ObservedEmitter:ARM64XEmitter {
 ObservedEmitter(const u8 *rx,u8 *rw):ARM64XEmitter(rx,rw){constructions++;assert(rx&&rw);}
};
struct IRNativeBlock {int checkedOffset=96;};
struct IRBlock {int GetNativeOffset(){return 32;}u32 GetOriginalStart(){return 123;}};
struct IRBlockCache {IRBlock block;IRBlock *GetBlock(int){return &block;}};
struct Interface {virtual const u8 *GetDispatcher()=0;};
namespace MIPSComp {static Interface *jit;}
struct Patch:ARM64CodeBlock,Interface {
 enum {MIN_BLOCK_EXIT_LEN=16,MIN_BLOCK_NORMAL_LEN=16};
 IRNativeBlock native;const u8 *dispatcherPCInSCRATCH1_;
 const IRNativeBlock *GetNativeBlock(int){return &native;}
 const u8 *GetDispatcher() override{return dispatcherPCInSCRATCH1_;}
 void EraseAllLinks(int){}
 const u8 *GetCodePtrFromWritablePtr(u8 *p) override {
  translations++;if(cancelTranslation)ir_native_psp_exec_cancel(1);
  return ARM64CodeBlock::GetCodePtrFromWritablePtr(p);
 }
 u8 *GetWritablePtrFromCodePtr(const u8 *p) override {
  translations++;if(cancelTranslation)ir_native_psp_exec_cancel(1);
  return ARM64CodeBlock::GetWritablePtrFromCodePtr(p);
 }
 void set(const u8 *p){SetCodePtr(const_cast<u8 *>(p));}
 void LinkBlock(u8 *,const u8 *);void UnlinkBlock(u8 *,u32);
 void OverwriteExit(int,int,int);void InvalidateBlock(IRBlockCache *,int);
};
METHODS
int main(int argc,char **argv) {
 assert(argc==3);unsigned kind=atoi(argv[1]);bool cancellation=atoi(argv[2]);
 admit();ir_psp_exec_probe_proven(true);assert(ir_native_psp_exec_advance(1,1,2)==0);
 {
  Patch p;MIPSComp::jit=&p;p.AllocCodeSpace(16777216,IR_PSP_EXEC_CPU);assert(p.BeginWrite());
  for(unsigned i=0;i<64;i++)p.MOV(W0,W0);assert(p.EndWrite());p.dispatcherPCInSCRATCH1_=p.GetBasePtr()+96;
  auto *rw=p.GetWritablePtrFromCodePtr(p.GetBasePtr());uint8_t before[256];memcpy(before,p.GetBasePtr(),256);
  constructions=translations=0;cancelTranslation=cancellation;
  if(kind==0)p.LinkBlock(rw+32,p.GetBasePtr()+96);
  if(kind==1)p.UnlinkBlock(rw+32,123);
  if(kind==2)p.OverwriteExit(32,32,0);
  if(kind==3){IRBlockCache cache;p.InvalidateBlock(&cache,0);}
  if(kind==4)p.set(p.GetBasePtr()+32);
  assert(translations==1);
  if(cancellation){assert(constructions==0&&memcmp(before,p.GetBasePtr(),256)==0);}
  else if(kind<4){assert(constructions==1&&memcmp(before,p.GetBasePtr(),256)!=0);}
  cancelTranslation=false;for(auto &c:claims)assert(!c.writers);
  p.FreeCodeSpace();assert(!arenas[0].claim);
 }
 assert(ir_native_psp_exec_end(1)==0);
 puts("PASS admitted production patch translation: cancellation returns before arithmetic/emitter construction; success preserves patching; writer drains and claim releases");
}
'''.replace('METHODS',bodies)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'Common').mkdir()
            for name in ['Common/CodeBlock.h','Common/Arm64Emitter.h','Common/Arm64Emitter.cpp']:
                (root/name).write_text(overlay.apply(name,(UPSTREAM/name).read_text()))
            source=root/'main.cpp';source.write_text(fixture);binary=root/'check'
            command=['clang++','-std=c++17','-O1','-fsanitize=undefined,pointer-overflow','-fno-sanitize-recover=all','-DIRIDIUM_PSP_PREPARED_JIT=1','-D_DEBUG','-ffunction-sections','-fdata-sections','-Wl,-dead_strip','-I',str(root),'-I',str(ROOT/'ci/input'),'-I',str(UPSTREAM),'-I',str(BRIDGE),str(root/'Common/Arm64Emitter.cpp'),str(source),'-o',str(binary)]
            result=subprocess.run(command,capture_output=True,text=True,timeout=90);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            for kind in range(5):
                for cancellation in range(2):
                    result=subprocess.run([str(binary),str(kind),str(cancellation)],capture_output=True,text=True,timeout=10)
                    self.assertEqual(result.returncode,0,f'path {kind}, cancellation {cancellation}\n'+result.stdout+result.stderr)
            print('PASS production classic Link/Unlink, native IR Overwrite/Invalidate, and CodeBlock SetCodePtr: 5 success + 5 cancellation injections, UBSan/pointer-overflow enabled; no speculative emitter construction or null arithmetic')


if __name__=='__main__':unittest.main()
