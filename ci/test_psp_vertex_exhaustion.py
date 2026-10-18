"""Real lookup -> SetVertexType -> Compile -> DecodeVerts exhaustion on the Mac."""
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


@unittest.skipUnless(platform.system() == 'Darwin' and platform.machine() == 'arm64' and shutil.which('clang++'), 'Apple Silicon compiler required')
class VertexExhaustionTests(unittest.TestCase):
    def test_real_caller_chain_preserves_prior_decoders_and_uses_generic_fallback(self):
        source = (UPSTREAM/'GPU/Common/DrawEngineCommon.h').read_text()
        start = source.index('\tVertexDecoder *GetVertexDecoder(u32 vertTypeID) {')
        lookup = source[start:source.index('\n\tvoid AssertEmpty()',start)]
        fixture = r'''
#include "psp_prepared_memory_fixture.h"
#include <pthread.h>
#include "Core/Config.h"
#include "Core/ConfigValues.h"
#include "GPU/Common/VertexDecoderCommon.h"
#include "GPU/GPUState.h"
#include "GPU/ge_constants.h"
#include "Common/Data/Collections/Hashmaps.h"
#include <vector>
#include <string>
// App/UI configuration and reporting are the only stubs. Decoder, lookup,
// allocation, emission, bounds, cache publication and fallback are production.
Config::~Config() {}
bool TouchControlConfig::ResetToDefault(std::string_view) { return false; }
bool DisplayLayoutConfig::ResetToDefault(std::string_view) { return false; }
bool GestureControlConfig::ResetToDefault(std::string_view) { return false; }
Config g_Config{};
GPUgstate gstate{};
GPUStateCache gstate_c{};
bool g_DoubleTextureCoordinates=false;
static bool enabled=false;
bool *g_bLogEnabledSetting=&enabled;
LogChannel g_log[(size_t)Log::NUMBER_OF_LOGS];
std::vector<std::string> DisassembleArm64(const u8 *,int) { return {}; }
namespace Reporting { void ReportMessage(const char *,...) {} bool ShouldLogNTimes(const char *,int) { return false; } }
struct Lookup {
    DenseHashMap<u32,VertexDecoder *> decoderMap_{16};
    VertexDecoderOptions decOptions_{};
    VertexDecoderJitCache *decJitCache_;
    explicit Lookup(VertexDecoderJitCache *cache):decJitCache_(cache) {}
    ~Lookup() { decoderMap_.Iterate([](const uint32_t,VertexDecoder *decoder){delete decoder;}); }
LOOKUP
};
static u32 format(unsigned i) {
    return GE_VTYPE_POS_FLOAT | ((i&3)<<11) | (((i>>2)&7)<<14) | (((i>>5)&3)<<24) | (((i>>7)&1)<<26) | (((i>>8)&31)<<27) | (((i>>13)&1)<<13);
}
static void decode(const VertexDecoder &decoder) {
    alignas(16) float vertices[]={1.0f,2.0f,3.0f,4.0f,5.0f,6.0f};
    alignas(16) uint8_t actual[256],expected[256];memset(actual,0xcd,sizeof actual);memset(expected,0xcd,sizeof expected);
    VertexDecoder reference;reference.SetVertexType(decoder.VertexType(),VertexDecoderOptions{},nullptr);
    UVScale uv{};
    reference.DecodeVerts(expected,(const u8 *)vertices,&uv,2);
    if(decoder.jitted_) {
        // macOS rejects executable file aliases here. Execute a copy in its
        // supported MAP_JIT harness; this is not device prepared-alias proof.
        IRPSPExecReadScope reader((const void *)decoder.jitted_);assert(reader);
        void *code=mmap(nullptr,16384,PROT_READ|PROT_WRITE|PROT_EXEC,MAP_PRIVATE|MAP_ANON|MAP_JIT,-1,0);
        assert(code!=MAP_FAILED && decoder.jittedSize_<=16384);
        pthread_jit_write_protect_np(0);memcpy(code,(const void *)decoder.jitted_,decoder.jittedSize_);pthread_jit_write_protect_np(1);
        sys_icache_invalidate(code,decoder.jittedSize_);
        ((JittedVertexDecoder)code)((const u8 *)vertices,actual,2,&uv);
        assert(munmap(code,16384)==0);
    } else decoder.DecodeVerts(actual,(const u8 *)vertices,&uv,2);
    size_t output=decoder.GetDecVtxFmt().stride*2;
    assert(memcmp(actual,expected,output)==0);
    // Upstream permits a full extra vertex plus 16 bytes of SIMD slack.
    for(size_t n=output+decoder.GetDecVtxFmt().stride+16;n<sizeof actual;n++)assert(actual[n]==0xcd);
}
int main() {
    admit();ir_psp_exec_probe_proven(true);assert(ir_native_psp_exec_advance(1,1,2)==0);
    {
        VertexDecoderJitCache cache;Lookup lookup(&cache);
        auto *first=lookup.GetVertexDecoder(format(0));assert(first->jitted_ && first->jittedSize_>0);
        auto *entry=first->jitted_;std::vector<uint8_t> saved((const uint8_t *)entry,(const uint8_t *)entry+first->jittedSize_);
        decode(*first); // Actually execute this production ARM64 decoder on the host.
        unsigned failed=0;size_t left=0;
        for(unsigned i=1;i<16384;i++) {
            size_t before=cache.GetSpaceLeft();auto *decoder=lookup.GetVertexDecoder(format(i));
            if(!decoder->jitted_) {
                assert(decoder->jittedSize_==0 && cache.GetSpaceLeft()==before);
                decode(*decoder);failed=i;left=before;break;
            }
        }
        assert(failed && left<4096);
        for(unsigned i=failed+1;i<failed+100&&i<16384;i++) {
            auto *decoder=lookup.GetVertexDecoder(format(i));
            assert(!decoder->jitted_ && decoder->jittedSize_==0 && cache.GetSpaceLeft()==left);decode(*decoder);
        }
        assert(first==lookup.GetVertexDecoder(format(0)) && entry==first->jitted_);
        assert(memcmp(saved.data(),(const void *)entry,saved.size())==0);decode(*first);
        assert(claimsUsed==1 && !ir_psp_exec_failed());
        printf("PASS real production lookup/SetVertexType/ARM64 Compile/DecodeVerts: exhaustion at %u cached formats, repeated null/size-zero generic decoding matches reference, guard pages and prior bytes/pointer/results preserved; host executes copied decoder bytes via MAP_JIT, no debugger/device or prepared-alias execution proof\n",failed);
    }
    assert(ir_native_psp_exec_end(1)==0);
}
'''.replace('LOOKUP',lookup)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            names=('Common/CodeBlock.h','Common/Arm64Emitter.h','Common/Arm64Emitter.cpp','GPU/Common/VertexDecoderCommon.cpp','GPU/Common/VertexDecoderArm64.cpp')
            for name in names:
                target=root/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(overlay.apply(name,(UPSTREAM/name).read_text()))
            (root/'main.cpp').write_text(fixture);binary=root/'check'
            command=['clang++','-std=c++17','-O1','-DIRIDIUM_PSP_PREPARED_JIT=1','-ffunction-sections','-fdata-sections','-Wl,-dead_strip','-I',str(root),'-I',str(ROOT/'ci/input'),'-I',str(UPSTREAM),'-I',str(BRIDGE),str(root/'main.cpp'),str(root/'Common/Arm64Emitter.cpp'),str(root/'GPU/Common/VertexDecoderCommon.cpp'),str(root/'GPU/Common/VertexDecoderArm64.cpp'),str(UPSTREAM/'GPU/Common/VertexDecoderHandwritten.cpp'),str(UPSTREAM/'ext/xxhash.c'),'-o',str(binary)]
            result=subprocess.run(command,capture_output=True,text=True,timeout=90)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr);print(result.stdout.strip())


if __name__=='__main__':unittest.main()
