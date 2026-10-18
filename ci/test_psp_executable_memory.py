"""Exercise the shipping prepared-arena state/ownership implementation without a debugger."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'iridium/apps/ios/RuntimeBridge'


@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('clang++'), 'Darwin compiler required')
class PreparedMemoryTests(unittest.TestCase):
    def test_real_backend_bounds_receipts_aba_quiescence_and_metadata_cap(self):
        fixture = r'''
#define IR_PSP_EXEC_FIXTURE 1
#include "IRPSPExecutableMemory.cpp"
#include <cassert>
#include <cstdio>
#include <sys/mman.h>
#include <unistd.h>
#include <atomic>
static unsigned mappings, unmappings, preparations, detachCalls;
static bool negative, rejectPrepare, uncertainPrepare, rejectUnmap;
static unsigned badBytes;
static IRJITDiagnosticStage lastStage;
static uint32_t lastPass;
static int64_t lastValue;
static IRJITDiagnosticStage refuseStage;
static bool record(void *,IRJITDiagnosticStage s,uint32_t p,int64_t v,int e) {
    assert(e==0);lastStage=s;lastPass=p;lastValue=v;return s!=refuseStage;
}
static IRJITDiagnosticSink sink{nullptr,record};
static unsigned arenaOperation;
static bool detail(void *c,IRJITDiagnosticStage s,uint32_t p,int64_t v,int e) {
    if(s==IR_JIT_ARENA_ERROR)arenaOperation=p;
    return record(c,s,p,v,e);
}
static IRJITDiagnosticSink detailed{nullptr,detail};
static std::atomic<bool> blocked, entered, resume;
static FILE *pendingFile;
static void *pendingRX;
static uintptr_t pendingAlias;
namespace {
bool mapArena(Arena &a) {
    assert(a.rx && pendingRX==a.rx && pendingFile && !a.rw); // Allocation must precede aliasing.
    a.rw = (uint8_t *)mmap((void *)pendingAlias,a.bytes,PROT_READ|PROT_WRITE,
        badBytes==2 ? MAP_PRIVATE|MAP_ANON : MAP_SHARED,badBytes==2 ? -1:fileno(pendingFile),0);
    assert(a.rw!=MAP_FAILED && a.rw!=a.rx);mappings++;
    if(badBytes==2)for(size_t n=0;n<a.bytes;n+=16384)a.rw[n]=0x69;
    fclose(pendingFile);pendingFile=nullptr;pendingRX=nullptr;return true;
}
bool unmapView(void *p, size_t bytes) {
    if (rejectUnmap) { rejectUnmap = false; return false; }
    if(p==pendingRX && pendingFile){fclose(pendingFile);pendingFile=nullptr;pendingRX=nullptr;}
    assert(munmap(p, bytes) == 0); unmappings++; return true;
}
void synchronize(void *, void *, size_t) {}
}
static int prepare(void *, void **out, size_t bytes, unsigned sequence) {
    assert(sequence == ++preparations && out && !*out);
    if (blocked && sequence==2) { entered = true; while (!resume) std::this_thread::yield(); }
    if (uncertainPrepare && sequence==2) return IR_PSP_EXEC_UNCERTAIN;
    assert(!pendingFile);pendingFile=tmpfile();assert(pendingFile && ftruncate(fileno(pendingFile),bytes)==0);
    uintptr_t low=0x400000000ULL+mappings*0x2000000ULL,high=0xc00000000ULL+mappings*0x2000000ULL;
    pendingAlias=negative?low:high;
    pendingRX=mmap((void *)(negative?high:low),bytes,PROT_READ|PROT_WRITE,MAP_SHARED,fileno(pendingFile),0);
    assert(pendingRX!=MAP_FAILED);mappings++;*out=pendingRX;
    if(badBytes!=1)for(size_t n=0;n<bytes;n+=16384)((uint8_t *)pendingRX)[n]=0x69;
    return rejectPrepare ? IR_PSP_EXEC_PREPARATION : 0;
}
static int detach(void *) { detachCalls++; return 0; }
static IRPSPExecHost config() {
    IRPSPExecHost h{}; h.size = sizeof h; h.version = IR_PSP_EXEC_VERSION; h.admission = 1; h.generation = 7; h.attempt = 9;
    h.script_sha256[0] = 1; h.prepare = prepare; h.detach = detach; return h;
}
static void admit(const IRPSPExecHost &h) {
    IRPSPExecShutdown r{}; r.size = sizeof r; r.version = IR_PSP_EXEC_VERSION; r.admission = h.admission;
    r.generation = h.generation; r.attempt = h.attempt; memcpy(r.script_sha256,h.script_sha256,32);
    for (unsigned flags = 0; flags < IR_PSP_SHUTDOWN_ALL; flags++) {
        r.flags = flags; assert(ir_native_psp_exec_accept_shutdown(&r) == IR_PSP_EXEC_SHUTDOWN);
    }
    assert(ir_native_psp_exec_detach(h.admission) == 0);
    r.flags = IR_PSP_SHUTDOWN_ALL;
    r.version=2;assert(ir_native_psp_exec_accept_shutdown(&r)==IR_PSP_EXEC_SHUTDOWN);r.version=IR_PSP_EXEC_VERSION;
    r.attempt++; assert(ir_native_psp_exec_accept_shutdown(&r) == IR_PSP_EXEC_SHUTDOWN); r.attempt--;
    assert(ir_native_psp_exec_accept_shutdown(&r) == 0);
    assert(ir_native_psp_exec_restored_diagnostic(1,false,&sink) == IR_PSP_EXEC_RESTORATION);
    assert(lastStage==IR_JIT_PREPARE_RETURN&&lastPass==1&&lastValue==IR_PSP_EXEC_RESTORATION);
    assert(ir_native_psp_exec_restored_diagnostic(2,true,&sink) == IR_PSP_EXEC_RESTORATION);
    assert(ir_native_psp_exec_restored(1,true) == 0);
}
int main() {
    // macOS chooses a different VA layout; test the unmodified iOS wire predicate
    // separately while the fixture mapping adapter exercises real shared aliases.
    assert(wireRange((1ULL<<36)-16384,16384));
    assert(!wireRange((1ULL<<36)-16384,32768));
    assert(!wireRange(0,16384) && !wireRange(1,16384) && !wireRange(16384,0));
    assert(ir_native_psp_exec_version()==3);
    // Every identity guard reports a fixed rejection, without allocating.
    for(unsigned code=2;code<=10;code++) {
        auto candidate=config();
        switch(code){case 3:candidate.size--;break;case 4:candidate.version--;break;
        case 5:candidate.admission=0;break;case 6:candidate.generation=0;break;case 7:candidate.attempt=0;break;
        case 8:candidate.prepare=nullptr;break;case 9:candidate.detach=nullptr;break;case 10:memset(candidate.script_sha256,0,32);break;}
        assert(prepare(code==2?nullptr:&candidate,&sink)==IR_PSP_EXEC_IDENTITY);
        assert(lastStage==IR_JIT_PREPARE_REJECT&&lastPass==code&&mappings==0);
    }
    refuseStage=IR_JIT_PREPARE_ENTER;
    auto declined=config();assert(ir_native_psp_exec_prepare_diagnostic(&declined,&sink)==IR_PSP_EXEC_PREPARATION&&mappings==0);
    refuseStage=(IRJITDiagnosticStage)0;
    auto old=config();old.version=2;assert(ir_native_psp_exec_prepare(&old)==IR_PSP_EXEC_IDENTITY);
    auto h = config(); void *rx = nullptr, *rw = nullptr;
    assert(!ir_psp_exec_claim(IR_PSP_EXEC_CPU, 16*1024*1024, &rx, &rw));
    assert(ir_native_psp_exec_prepare(&h) == 0 && preparations == 4 && mappings == 8);
    assert(ir_native_psp_exec_prepare(&h) == IR_PSP_EXEC_IDENTITY);
    assert(!ir_psp_exec_claim(IR_PSP_EXEC_CPU, 16*1024*1024, &rx, &rw));
    admit(h);
    auto claim = ir_psp_exec_claim(IR_PSP_EXEC_CPU, 16*1024*1024, &rx, &rw); assert(claim && rx != rw);
    assert(!ir_psp_exec_claim(IR_PSP_EXEC_CPU, 16*1024*1024, &rx, &rw));
    rx = arenas[0].rx; rw = arenas[0].rw;
    void *translated = nullptr;
    assert(ir_psp_exec_translate((uint8_t *)rx + 4, 4, true, &translated) && translated == (uint8_t *)rw + 4);
    assert(!ir_psp_exec_translate((uint8_t *)rx + sizes[0], 4, true, &translated));
    assert(!ir_psp_exec_write32(rx,rw,0x52800540));
    assert(ir_psp_exec_begin_write(claim,rx,sizes[0]));
    assert(ir_psp_exec_write32(rx,rw,0x52800540)); assert(*(uint32_t *)rx == 0x52800540);
    assert(!ir_psp_exec_write32((uint8_t *)rx + sizes[0], (uint8_t *)rw + sizes[0], 1));
    assert(!ir_psp_exec_release(claim));
    assert(ir_psp_exec_end_write(claim,rx,4));
    auto reader = ir_psp_exec_enter(rx); assert(reader == claim);
    assert(!ir_psp_exec_release(claim) && ir_native_psp_exec_end(h.admission) == IR_PSP_EXEC_UNCERTAIN);
    ir_psp_exec_leave(reader); assert(ir_psp_exec_release(claim)); assert(ir_psp_exec_release(claim));
    assert(ir_native_psp_exec_advance(h.admission,7,8) == IR_PSP_EXEC_IDENTITY);
    ir_psp_exec_probe_proven(true); assert(ir_native_psp_exec_advance(h.admission,7,8) == 0);
    for (unsigned n = 1; n < 1024; n++) {
        auto c = ir_psp_exec_claim(IR_PSP_EXEC_VERTEX,256*1024,&rx,&rw); assert(c && c != claim);
        assert(ir_psp_exec_release(c));
    }
    assert(!ir_psp_exec_claim(IR_PSP_EXEC_VERTEX,256*1024,&rx,&rw));
    assert(ir_native_psp_exec_end(h.admission) == 0 && unmappings == 8);
    preparations = 0; negative = true;
    assert(ir_native_psp_exec_prepare(&h) == 0); admit(h);
    auto newer = ir_psp_exec_claim(IR_PSP_EXEC_CPU,16*1024*1024,&rx,&rw); assert(newer && newer != claim);
    assert(!ir_psp_exec_release(claim));
    assert(ir_psp_exec_release(newer)); assert(ir_native_psp_exec_end(h.admission) == 0);
    preparations = 0; rejectPrepare = true;
    assert(ir_native_psp_exec_prepare_diagnostic(&h,&detailed) == IR_PSP_EXEC_PREPARATION);
    assert(arenaOperation==((1u<<8)|helperPrepare)&&lastStage==IR_JIT_PREPARE_RETURN&&lastValue==IR_PSP_EXEC_PREPARATION);
    assert(!ir_psp_exec_claim(IR_PSP_EXEC_CPU,16*1024*1024,&rx,&rw));
    assert(ir_native_psp_exec_end(h.admission) == 0 && unmappings == mappings);
    rejectPrepare=false;
    for(unsigned mode=1;mode<=2;mode++) {
        preparations=0;badBytes=mode;
        assert(ir_native_psp_exec_prepare_diagnostic(&h,&detailed)==IR_PSP_EXEC_PREPARATION);
        assert(arenaOperation==((1u<<8)|(mode==1?sentinel:coherence)));
        assert(ir_native_psp_exec_end(1)==0);
    }
    badBytes=0;
    for(auto stage:{IR_JIT_ARENA_ENTER,IR_JIT_ARENA_RETURN,IR_JIT_PREPARE_RETURN}) {
        preparations=0;refuseStage=stage;
        assert(ir_native_psp_exec_prepare_diagnostic(&h,&sink)==IR_PSP_EXEC_PREPARATION);
        assert(ir_native_psp_exec_end(1)==0);
    }
    refuseStage=(IRJITDiagnosticStage)0;
    // Cancellation cannot turn an uncertain command into a definitive abort.
    rejectPrepare = false; uncertainPrepare = true; blocked = true; entered = false; resume = false; preparations = 0;
    int result = -1;
    std::thread worker([&] { result = ir_native_psp_exec_prepare(&h); });
    while (!entered) std::this_thread::yield();
    unsigned before = unmappings;
    assert(ir_native_psp_exec_end(1) == IR_PSP_EXEC_UNCERTAIN && unmappings == before);
    ir_native_psp_exec_cancel(1); resume = true; worker.join();
    assert(result == IR_PSP_EXEC_UNCERTAIN && preparations == 2);
    // Only this fixture's returned worker is now drained; failed unmaps stay
    // owned and accounted for until a later successful end.
    rejectUnmap = true; assert(ir_native_psp_exec_end(1) == IR_PSP_EXEC_MAPPING);
    assert(ir_native_psp_exec_end(1) == 0 && unmappings == mappings);
    blocked = false; uncertainPrepare = false; preparations = 0;
    assert(ir_native_psp_exec_prepare(&h) == 0); admit(h);
    auto held = ir_psp_exec_claim(IR_PSP_EXEC_CPU,16*1024*1024,&rx,&rw); assert(held);
    entered = false; resume = false;
    std::thread consumer([&] { auto active = ir_psp_exec_enter(rw); assert(active == held); entered = true; while (!resume) std::this_thread::yield(); ir_psp_exec_leave(active); });
    while (!entered) std::this_thread::yield();
    assert(!ir_psp_exec_release(held) && ir_native_psp_exec_end(1) == IR_PSP_EXEC_UNCERTAIN);
    resume = true; consumer.join(); assert(ir_psp_exec_release(held)); assert(ir_native_psp_exec_end(1) == 0);
    puts("PASS shipping arena backend: fixed identity/failure diagnostics, sentinel/coherence and journal refusal, four roles, strict receipts/restoration, aliases, bounds, live reader/writer refusal, ABA and finite tombstones; no code executed/debugger used");
}
'''
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory); source = folder / 'main.cpp'; binary = folder / 'test'
            source.write_text(fixture)
            subprocess.run(['clang++', '-std=c++17', '-O1', '-Wall', '-Wextra', '-Werror',
                            '-I', str(BRIDGE), str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
