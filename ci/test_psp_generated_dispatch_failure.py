"""Execute production generated classic/native-IR fetch and post-JitAt dispatch."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest
import ppsspp_native_overlay as overlay
from test_psp_patch_cancellation import method
ROOT=Path(__file__).resolve().parents[1]
UPSTREAM=ROOT/'vendor/PPSSPP'
BRIDGE=ROOT/'iridium/apps/ios/RuntimeBridge'


@unittest.skipUnless(platform.system()=='Darwin' and platform.machine()=='arm64' and shutil.which('clang++'),'Apple Silicon compiler required')
class GeneratedDispatchFailureTests(unittest.TestCase):
    def test_generated_classic_and_ir_dispatch_exit_after_checked_failure(self):
        def source(name):return overlay.apply(name,(UPSTREAM/name).read_text())
        classic=source('Core/MIPS/ARM64/Arm64Asm.cpp')
        ir=source('Core/MIPS/ARM64/Arm64IRAsm.cpp')
        def dispatch(text,label):
            start=text.index('\t\t\t'+label+' = GetCodePtr();')
            end=text.index('\t\tSetJumpTarget(bail);',start)
            tail=text[text.index('\tconst uint8_t *quitLoop = GetCodePtr();',end):text.index('\tSetJumpTarget(badCoreState);',end)]
            return text[start:end]+tail+'\n        exitTarget = quitLoop; epilogue();\n'
        compile_classic=method(source('Core/MIPS/ARM64/Arm64Jit.cpp'),'void Arm64Jit::Compile(').replace('Arm64Jit::Compile','Fixture::CompileClassic')
        compile_ir=method(source('Core/MIPS/IR/IRJit.cpp'),'void IRJit::Compile(').replace('IRJit::Compile','Fixture::CompileIR')
        jit_at=method(source('Core/MIPS/JitCommon/JitCommon.cpp'),'void JitAt()')
        fixture=r'''
#include "psp_prepared_memory_fixture.h"
#include <pthread.h>
#include <vector>
#define PROFILE_THIS_SCOPE(...) ((void)0)
#define WARN_LOG_REPORT(...) ((void)0)
static bool logging=false;bool *g_bLogEnabledSetting=&logging;LogChannel g_log[(size_t)Log::NUMBER_OF_LOGS];
static int coreState;
enum {CORE_RUNNING=0,CORE_STEPPING=1,CORE_RUNTIME_ERROR=9};
void Core_UpdateState(int state){coreState=state;}
enum class ExecExceptionType {JUMP};
void Core_ExecException(u32,u32,ExecExceptionType){Core_UpdateState(CORE_RUNTIME_ERROR);}
namespace Memory {bool IsValid4AlignedAddress(u32){return true;}constexpr u32 MEMVIEW32_MASK=0x3fffffff;}
constexpr u32 MIPS_EMUHACK_OPCODE=0x68000000;
constexpr auto SCRATCH1=W16,SCRATCH1_64=X16,SCRATCH2=W17,MEMBASEREG=X19,CTXREG=X20,JITBASEREG=X21,DOWNCOUNTREG=W22;
struct MIPSState {u32 pc=0;};static MIPSState mips;static MIPSState *currentMIPS=&mips;
struct Interface {virtual void Compile(u32)=0;};
namespace MIPSComp {static Interface *jit;JIT_AT}
struct IRInst {};
struct JitBlock {void DoIntegrityCheck(u32,int,const char *){}};
struct JitBlockCache {static constexpr unsigned MAX_BLOCK_INSTRUCTIONS=32;};
enum class IRProfilerStatus {COMPILING,IN_JIT};
static void ShowPC(){abort();}
struct Fixture:ARM64CodeBlock,Interface {
 bool ir=false,compilerEnabled_=true;unsigned mode=0,calls=0,clears=0,finalized=0,nativeCalls=0;
 bool enableDebug=false;const u8 *dispatcherNoCheck=nullptr,*dispatcherNoCheck_=nullptr,*dispatcherFetch=nullptr,*exitTarget=nullptr;
 struct {const u8 *dispatchFetch=nullptr;} hooks_;
 struct {bool enableBlocklink=false;} jo;
 struct State {unsigned nextExit=0;bool hasSetRounding=false,lastSetRounding=false,startDefaultPrefix=false;bool MayHavePrefix(){return false;}void LogPrefix(){}} js;
 struct Frontend {bool CheckRounding(u32){return false;}} frontend_;
 struct Blocks {
  Fixture *owner;JitBlock block;
  bool IsFull(){return false;}int AllocateBlock(u32){return 0;}JitBlock *GetBlock(int){return &block;}
  void FinalizeBlock(int,bool){owner->finalize();}
 } blocks{this};
 void *copy=nullptr;u32 guest=0;size_t compiledOffset=0;
 void SaveStaticRegisters(){}void LoadStaticRegisters(){}void RestoreRoundingMode(bool){}void ApplyRoundingMode(bool){}
 void WriteDebugPC(ARM64Reg){}void WriteDebugProfilerStatus(IRProfilerStatus){}
 void MovFromPC(ARM64Reg r){LDR(INDEX_UNSIGNED,r,CTXREG,offsetof(MIPSState,pc));}
 u32 GetCompilerPC(){return 0;}
 void ClearCache(){clears++;assert(clears==0);}
 void Compile(u32 pc) override {if(++calls>3)abort();if(ir)CompileIR(pc);else CompileClassic(pc);}
 void CompileClassic(u32);void CompileIR(u32);
 void DoJit(u32,JitBlock *) {
  compiledOffset=GetOffset(GetCodePtr());
  if(mode==1){ResetCodePtr(16777216-4);MOVI2R(W0,42);RET();assert(EmissionFailed());}
  else {MOVI2R(W0,77);B(exitTarget);if(mode==2)Core_UpdateState(CORE_STEPPING);}
 }
 bool CompileBlock(u32 pc,std::vector<IRInst> &,u32 &) {
  nativeCalls++;assert(nativeCalls==1);
  if(!BeginWrite(512)){ir_psp_exec_fail();return false;}
  DoJit(pc,nullptr);bool published=EndWrite();FlushIcache();
  if(!published||EmissionFailed()){ir_psp_exec_fail();return false;}
  finalize();return true;
 }
 void finalize() {
  finalized++;assert(finalized==1);guest=MIPS_EMUHACK_OPCODE+(u32)compiledOffset;
  publishCopy();
 }
 void publishCopy(){pthread_jit_write_protect_np(0);memcpy(copy,GetBasePtr(),GetOffset(GetCodePtr()));pthread_jit_write_protect_np(1);sys_icache_invalidate(copy,GetOffset(GetCodePtr()));}
 void prologue(){
  STP(INDEX_PRE,X29,X30,SP,-16);STP(INDEX_PRE,X19,X20,SP,-16);STP(INDEX_PRE,X21,X22,SP,-16);
  MOVP2R(MEMBASEREG,&guest);MOVP2R(CTXREG,&mips);MOVP2R(JITBASEREG,(void *)((uintptr_t)copy-(ir?MIPS_EMUHACK_OPCODE:0)));MOVI2R(W0,0);
 }
 void epilogue(){LDP(INDEX_POST,X21,X22,SP,16);LDP(INDEX_POST,X19,X20,SP,16);LDP(INDEX_POST,X29,X30,SP,16);RET();}
 void generate(){
  copy=mmap(nullptr,16777216,PROT_READ|PROT_WRITE|PROT_EXEC,MAP_PRIVATE|MAP_ANON|MAP_JIT,-1,0);assert(copy!=MAP_FAILED);
  assert(BeginWrite());prologue();
  if(ir){IR_DISPATCH}else{CLASSIC_DISPATCH}
  assert(EndWrite()&&!EmissionFailed());publishCopy();
 }
};
CLASSIC_COMPILE
IR_COMPILE
int main(int argc,char **argv){
 assert(argc==3);admit();ir_psp_exec_probe_proven(true);assert(ir_native_psp_exec_advance(1,1,2)==0);
 {
  Fixture f;f.ir=atoi(argv[1]);f.mode=atoi(argv[2]);MIPSComp::jit=&f;
  f.AllocCodeSpace(16777216,IR_PSP_EXEC_CPU);f.generate();
  if(f.mode==3)ir_psp_exec_fail();
  {
   // Prepared backing is held while host executes an exact dispatcher copy.
   IRPSPExecReadScope reader(f.mode==3?nullptr:(const void *)f.GetBasePtr());if(f.mode!=3)assert(reader);
   int value=((int (*)())f.copy)();
   if(f.mode==0){assert(value==77&&coreState==CORE_RUNNING&&f.calls==1&&f.finalized==1);}
   else if(f.mode==2){assert(coreState==CORE_STEPPING&&f.calls==1&&f.finalized==1);}
   else{assert(coreState==CORE_RUNTIME_ERROR&&f.finalized==0&&f.calls==(f.mode==3?0:1));}
   assert(f.clears==0);
  }
  assert(munmap(f.copy,16777216)==0);f.FreeCodeSpace();assert(!arenas[0].claim);
 }
 assert(ir_native_psp_exec_end(1)==0);
 puts("PASS real generated fetch/post-JitAt dispatcher, production JitAt and classic/IR compile control: failed emission exits without publication/retry; success dispatches once; core-state transition exits");
}
'''.replace('JIT_AT',jit_at).replace('IR_DISPATCH',dispatch(ir,'dispatcherNoCheck_')).replace('CLASSIC_DISPATCH',dispatch(classic,'dispatcherNoCheck')).replace('CLASSIC_COMPILE',compile_classic).replace('IR_COMPILE',compile_ir)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'Common').mkdir()
            for name in ['Common/CodeBlock.h','Common/Arm64Emitter.h','Common/Arm64Emitter.cpp']:
                (root/name).write_text(source(name))
            cpp=root/'main.cpp';cpp.write_text(fixture);binary=root/'check'
            command=['clang++','-std=c++17','-O1','-DIRIDIUM_PSP_PREPARED_JIT=1','-D_DEBUG','-ffunction-sections','-fdata-sections','-Wl,-dead_strip','-I',str(root),'-I',str(ROOT/'ci/input'),'-I',str(UPSTREAM),'-I',str(BRIDGE),str(root/'Common/Arm64Emitter.cpp'),str(cpp),'-o',str(binary)]
            result=subprocess.run(command,capture_output=True,text=True,timeout=90);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            for backend in range(2):
                for mode in range(4):
                    result=subprocess.run([str(binary),str(backend),str(mode)],capture_output=True,text=True,timeout=10)
                    self.assertEqual(result.returncode,0,f'backend {backend}, mode {mode}\n'+result.stdout+result.stderr)
            print('PASS host execution of both production generated dispatcher fetch/post-compile paths, production JitAt and classic/IR compile control: checked emission failure, prelatched failure, core-state transition, normal success; no retry/cache clear/unpublished dispatch. Copied MAP_JIT code, not device prepared-alias proof; frontend/cache and ABI-rounding endpoints are fixture stubs.')


if __name__=='__main__':unittest.main()
