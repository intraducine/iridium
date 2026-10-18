"""Every shipping probe breadcrumb fails once over the real prepared backend."""
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


@unittest.skipUnless(platform.system()=='Darwin' and platform.machine()=='arm64' and shutil.which('clang++'),'Apple Silicon compiler required')
class PreparedProbeFailureTests(unittest.TestCase):
    def test_each_breadcrumb_closes_finished_writer_and_releases_claim(self):
        text=(BRIDGE/'IRPPSSPPNative.mm').read_text()
        probe=text[text.index('int ir_native_psp_check_jit_diagnostic('):text.index('\nuint32_t ir_native_psp_abi(')]
        fixture=r'''
#include "psp_prepared_memory_fixture.h"
#include "IRJITExecutionProbe.h"
#include <pthread.h>
#include <vector>
#define TARGET_OS_SIMULATOR 0
static bool logging=false;bool *g_bLogEnabledSetting=&logging;
LogChannel g_log[(size_t)Log::NUMBER_OF_LOGS];
enum class LogOutput {Stdio,ExternalCallback};
struct LogManager {
 LogOutput GetOutputsEnabled(){return LogOutput::Stdio;}
 void SetExternalLogCallback(void (*)(int,void *),void *){}
 void EnableOutput(LogOutput){} void SetOutputsEnabled(LogOutput){}
} g_logManager;
static void forwardNativeLog(int,void *){}
static thread_local const IRJITDiagnosticSink *preflightLogSink;
static thread_local uint32_t preflightPass;
static thread_local int preflightErrno;
static void *container;
static std::atomic<bool> jitProbeVerified;
static unsigned calls,failOrdinal;
static bool failed;
static bool mark(void *,IRJITDiagnosticStage,uint32_t,int64_t,int) {
 calls++;if(calls==failOrdinal){failed=true;return false;}return true;
}
static const IRJITDiagnosticSink sink{nullptr,mark};
int csops(pid_t,unsigned,void *out,size_t bytes) {assert(bytes==4);*(uint32_t *)out=0x10000000;return 0;}
extern "C" bool fixture_execute(void *,size_t,int64_t,const IRJITDiagnosticSink *,uint32_t);
extern "C" bool ir_jit_probe_execute_diagnostic(void *code,size_t bytes,int64_t expected,const IRJITDiagnosticSink *sink,uint32_t pass) {
 assert(bytes==16*1024*1024);
 // Host executable shared-file aliases are unavailable. Execute an exact copy
 // with the original production signal/TLS guard in host-supported MAP_JIT.
 void *copy=mmap(nullptr,16384,PROT_READ|PROT_WRITE|PROT_EXEC,MAP_PRIVATE|MAP_ANON|MAP_JIT,-1,0);assert(copy!=MAP_FAILED);
 pthread_jit_write_protect_np(0);memcpy(copy,code,8);pthread_jit_write_protect_np(1);sys_icache_invalidate(copy,8);
 bool result=fixture_execute(copy,8,expected,sink,pass);assert(munmap(copy,16384)==0);return result;
}
PROBE
static unsigned run(unsigned fail) {
 admit();calls=0;failOrdinal=fail;failed=false;
 int result=ir_native_psp_check_jit_diagnostic(&sink);unsigned total=calls;
 if(fail)assert(failed&&result!=1);else assert(result==1);
 for(auto &c:claims)assert(!c.live&&!c.writers&&!c.readers);
 assert(!arenas[0].claim && preflightLogSink==nullptr);
 assert(ir_native_psp_exec_end(1)==0);return total;
}
int main() {
 unsigned total=run(0);assert(total>30);
 for(unsigned i=1;i<=total;i++)run(i);
 printf("PASS actual prepared backend + shipping probe/CodeBlock/emitter and production signal/TLS guard: both 42/7 rewrites and all %u breadcrumb failures release every finished writer/claim; exec_end succeeds. Host executes copied bytes in MAP_JIT, not device aliases.\n",total);
}
'''.replace('PROBE',probe)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'Common').mkdir()
            for name in ['Common/CodeBlock.h','Common/Arm64Emitter.h','Common/Arm64Emitter.cpp']:
                (root/name).write_text(overlay.apply(name,(UPSTREAM/name).read_text()))
            source=root/'main.cpp';source.write_text(fixture);obj=root/'guard.o';binary=root/'check'
            result=subprocess.run(['clang','-std=c11','-Dir_jit_probe_execute_diagnostic=fixture_execute','-I',str(BRIDGE),'-c',str(BRIDGE/'IRJITExecutionProbe.c'),'-o',str(obj)],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            command=['clang++','-std=c++17','-O1','-DIRIDIUM_PSP_PREPARED_JIT=1','-D_DEBUG','-ffunction-sections','-fdata-sections','-Wl,-dead_strip','-I',str(root),'-I',str(ROOT/'ci/input'),'-I',str(UPSTREAM),'-I',str(BRIDGE),str(root/'Common/Arm64Emitter.cpp'),str(source),str(obj),'-o',str(binary)]
            result=subprocess.run(command,capture_output=True,text=True,timeout=90);self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30);self.assertEqual(result.returncode,0,result.stdout+result.stderr);print(result.stdout.strip())


if __name__=='__main__':unittest.main()
