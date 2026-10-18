"""Checked production ARM64 emitter and profiler bodies over real far RW/RX aliases."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest
import ppsspp_native_overlay as overlay

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = ROOT / 'vendor/PPSSPP'
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('clang++'), 'Darwin compiler required')
class PreparedEmitterTests(unittest.TestCase):
    def test_checked_writes_fixups_and_full_width_profiler_over_far_aliases(self):
        ir = overlay.apply('Core/MIPS/ARM64/Arm64IRJit.cpp', (UPSTREAM/'Core/MIPS/ARM64/Arm64IRJit.cpp').read_text())
        profiler = ir[ir.index('void Arm64JitBackend::WriteDebugPC(uint32_t'):ir.index('void Arm64JitBackend::SaveStaticRegisters()')].replace('Arm64JitBackend::','Profiler::')
        fixture = r'''
#include "psp_prepared_memory_fixture.h"
enum class IRProfilerStatus { NOT_RUNNING=0, IR_INTERPRET=3, SYSCALL=7 };
static constexpr auto SCRATCH1=W16,SCRATCH2=W17,SCRATCH2_64=X17;
struct Block:ARM64CodeBlock { using ARM64XEmitter::Write32; };
struct Profiler:Block {
    struct { uint32_t *profilerPC=nullptr;IRProfilerStatus *profilerStatus=nullptr; } hooks_;
    bool debug=true;
    bool DebugProfilerEnabled() const { return debug; }
    void WriteDebugPC(uint32_t);void WriteDebugPC(ARM64Reg);void WriteDebugProfilerStatus(IRProfilerStatus);
};
PROFILER_BODIES
// Decode the actual emitted address/store instructions. This is explicitly not
// AArch64 execution: no generated code or debugger is used by this fixture.
static void decode(const uint8_t *first,const uint8_t *last,uint32_t expected,void *target,uint32_t input=0) {
    uint64_t regs[32]{};regs[16]=input;unsigned stores=0;
    for(auto p=first;p<last;p+=4) {
        uint32_t word;memcpy(&word,p,4);unsigned dest=word&31,shift=((word>>21)&3)*16;
        uint64_t immediate=(word>>5)&0xffff,mask=(word>>31)?UINT64_MAX:UINT32_MAX;
        switch(word&0x7f800000) {
        case 0x52800000:regs[dest]=(immediate<<shift)&mask;continue;
        case 0x12800000:regs[dest]=~(immediate<<shift)&mask;continue;
        case 0x72800000:regs[dest]=((regs[dest]&~(0xffffULL<<shift))|(immediate<<shift))&mask;continue;
        }
        assert((word&0xffc00000)==0xb9000000);assert(((word>>5)&31)==17);
        assert(((word>>10)&0xfff)==0 && regs[17]==(uintptr_t)target && uint32_t(regs[dest])==expected);
        uint32_t value=regs[dest];memcpy(target,&value,4);stores++;
    }
    assert(stores==1 && *(uint32_t *)target==expected);
}
int main() {
  for(bool negative:{false,true}) {
    reverseAliases=negative;admit();
    {
      Profiler cpu;cpu.AllocCodeSpace(16*1024*1024,IR_PSP_EXEC_CPU);assert(cpu.GetBasePtr());
      auto *rw=(uint8_t *)cpu.GetWritablePtrFromCodePtr(cpu.GetBasePtr());
      int64_t delta=int64_t((uintptr_t)rw)-int64_t((uintptr_t)cpu.GetBasePtr());
      assert(negative ? delta < -int64_t(UINT32_MAX):delta > int64_t(UINT32_MAX));
      cpu.hooks_.profilerPC=(uint32_t *)rw;cpu.hooks_.profilerStatus=(IRProfilerStatus *)(rw+4);
      cpu.Write32(0);assert(cpu.EmissionFailed() && cpu.GetCodePointer()==cpu.GetBasePtr());
      assert(cpu.BeginWrite());cpu.Write32(0);cpu.Write32(0);cpu.Write32(0xaabbccdd);assert(cpu.EndWrite());
      for(unsigned which=0;which<3;which++) {
        assert(cpu.BeginWrite());auto *start=cpu.GetCodePointer();
        if(which==0)cpu.WriteDebugPC(uint32_t(0x12345678));
        if(which==1)cpu.WriteDebugPC(SCRATCH1);
        if(which==2)cpu.WriteDebugProfilerStatus(IRProfilerStatus::SYSCALL);
        assert(cpu.EndWrite()&&!cpu.EmissionFailed());
        decode(start,cpu.GetCodePointer(),which==0?0x12345678:which==1?0xfeed1234:7,which==2?(void *)(rw+4):rw,0xfeed1234);
        assert(*(uint32_t *)(rw+8)==0xaabbccdd && *(uint32_t *)cpu.GetBasePtr()==*(uint32_t *)rw);
      }
      assert(cpu.BeginWrite());auto *before=cpu.GetCodePointer();cpu.WriteDebugPC(SCRATCH2);
      assert(cpu.EmissionFailed()&&cpu.GetCodePointer()==before&&!cpu.EndWrite());
      assert(cpu.BeginWrite());cpu.hooks_.profilerStatus=nullptr;cpu.WriteDebugPC(uint32_t(1));assert(!cpu.EndWrite());
      assert(cpu.BeginWrite());before=cpu.GetCodePointer();cpu.debug=false;cpu.hooks_.profilerPC=nullptr;
      cpu.WriteDebugPC(SCRATCH2);cpu.WriteDebugPC(uint32_t(1));cpu.WriteDebugProfilerStatus(IRProfilerStatus::SYSCALL);
      assert(cpu.GetCodePointer()==before && cpu.EndWrite());
      cpu.FreeCodeSpace();
    }
    ir_psp_exec_probe_proven(true);assert(ir_native_psp_exec_advance(1,1,2)==0);
    {
      Block vertex;vertex.AllocCodeSpace(262144,IR_PSP_EXEC_VERTEX);assert(vertex.BeginWrite());
      auto old=vertex.B();vertex.RET();vertex.SetJumpTarget(old);assert(vertex.EndWrite());
      uint8_t saved[8];memcpy(saved,vertex.GetBasePtr(),8);size_t checkpoint=vertex.GetOffset(vertex.GetCodePointer());
      assert(vertex.BeginWrite());vertex.SetJumpTarget(old);assert(!vertex.EndWrite());
      assert(memcmp(saved,vertex.GetBasePtr(),8)==0);vertex.ResetCodePtr(checkpoint);
      for(unsigned bits:{14u,19u,26u}) {
        assert(vertex.BeginWrite());auto *start=vertex.GetCodePointer();auto *far=(const void *)((uintptr_t)start+(1ULL<<(bits+1)));
        if(bits==14)vertex.TBZ(W0,0,far);else if(bits==19)vertex.CBZ(W0,far);else vertex.B(far);
        assert(vertex.EmissionFailed()&&vertex.GetCodePointer()==start&&!vertex.EndWrite());vertex.ResetCodePtr(checkpoint);
      }
      vertex.ResetCodePtr(262140);assert(vertex.BeginWrite());vertex.Write32(0);vertex.Write32(1);vertex.RET();
      assert(vertex.EmissionFailed()&&vertex.GetSpaceLeft()==0&&!vertex.EndWrite());
      vertex.ResetCodePtr(checkpoint);assert(memcmp(saved,vertex.GetBasePtr(),8)==0);
      assert(vertex.BeginWrite());vertex.RET();assert(vertex.EndWrite());vertex.FreeCodeSpace();
    }
    assert(!ir_psp_exec_failed()&&ir_psp_exec_reuse_native(1)==0&&ir_native_psp_exec_end(1)==0);
  }
  puts("PASS production checked emitter and all three profiler bodies: far positive/negative aliases, full-width RW stores decoded, write-scope denial, stale fixup denial, branch limits, guarded exhaustion and preserved prior bytes; no generated code executed");
}
'''.replace('PROFILER_BODIES',profiler)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'Common').mkdir()
            for name in ('Common/CodeBlock.h','Common/Arm64Emitter.h','Common/Arm64Emitter.cpp'):
                (root/name).write_text(overlay.apply(name,(UPSTREAM/name).read_text()))
            (root/'main.cpp').write_text(fixture);binary=root/'check'
            result=subprocess.run(['clang++','-std=c++17','-O1','-DIRIDIUM_PSP_PREPARED_JIT=1','-D_DEBUG','-ffunction-sections','-fdata-sections','-Wl,-dead_strip','-I',str(root),'-I',str(ROOT/'ci/input'),'-I',str(UPSTREAM),'-I',str(BRIDGE),str(root/'Common/Arm64Emitter.cpp'),str(root/'main.cpp'),'-o',str(binary)],capture_output=True,text=True,timeout=90)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr);print(result.stdout.strip())


if __name__ == '__main__': unittest.main()
