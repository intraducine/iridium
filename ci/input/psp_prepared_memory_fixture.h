// Test-only shared alias adapter. Never included in the app/component.

#define IR_PSP_EXEC_FIXTURE 1
#include "IRPSPExecutableMemory.cpp"
#include "Common/Arm64Emitter.h"
#include "Common/Log.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <libkern/OSCacheControl.h>
using namespace Arm64Gen;
bool HandleAssert(bool, const char *, const char *, int, const char *, const char *, ...) { abort(); }
void GenericLog(Log, LogLevel, const char *, int, const char *, ...) {}
bool PlatformIsWXExclusive() { return true; }
int GetMemoryProtectPageSize() { return 16384; }
void *AllocateExecutableMemory(size_t) { abort(); }
void FreeExecutableMemory(void *, size_t) { abort(); }
bool ProtectMemoryPages(const void *, size_t, uint32_t) { abort(); }
static bool reverseAliases;
static unsigned ordinal;
static FILE *pendingFile;
static uintptr_t pendingAlias;
static uint8_t *fixtureView(uintptr_t desired,size_t bytes,int protections) {
    mach_vm_address_t reservation=desired;kern_return_t status=KERN_NO_SPACE;
    for(unsigned n=0;n<64&&status!=KERN_SUCCESS;n++) {
        reservation=desired+n*0x2000000ULL;
        status=mach_vm_allocate(mach_task_self(),&reservation,bytes+32768,VM_FLAGS_FIXED);
    }
    assert(status==KERN_SUCCESS && mprotect((void *)reservation,bytes+32768,PROT_NONE)==0);
    void *value=mmap((void *)(reservation+16384),bytes,protections,MAP_FIXED|MAP_SHARED,fileno(pendingFile),0);
    assert(value==(void *)(reservation+16384));return (uint8_t *)value;
}
namespace {
bool mapArena(Arena &a) {
    assert(a.rx && !a.rw && pendingFile);
    a.rw=fixtureView(pendingAlias,a.bytes,PROT_READ|PROT_WRITE);
    fclose(pendingFile);pendingFile=nullptr;return true;
}
bool unmapView(void *p,size_t bytes) { return munmap((uint8_t *)p-16384,bytes+32768)==0; }
void synchronize(void *rw,void *rx,size_t bytes) {
#ifdef IR_PSP_FIXTURE_EXECUTE
    sys_dcache_flush(rw,bytes);sys_icache_invalidate(rx,bytes);
#else
    (void)rw;(void)rx;(void)bytes;
#endif
}
}
static int prepare(void *,void **out,size_t bytes,unsigned sequence) {
    assert(out && !*out && sequence>=1 && sequence<=4 && !pendingFile);
    pendingFile=tmpfile();assert(pendingFile && ftruncate(fileno(pendingFile),bytes)==0);
    uintptr_t low=0x8000000000ULL+ordinal*0x2000000ULL,high=0xc000000000ULL+ordinal++*0x2000000ULL;
    pendingAlias=reverseAliases?low:high;
    uint8_t *rx=fixtureView(reverseAliases?high:low,bytes,PROT_READ|PROT_WRITE);
    for(size_t n=0;n<bytes;n+=16384)rx[n]=0x69;
    assert(mprotect(rx,bytes,PROT_READ
#ifdef IR_PSP_FIXTURE_EXECUTE
        |PROT_EXEC
#endif
    )==0);*out=rx;return 0;
}
static int detach(void *) { return 0; }
static void admit() {
    IRPSPExecHost h{};h.size=sizeof h;h.version=IR_PSP_EXEC_VERSION;h.admission=1;h.generation=1;h.attempt=1;
    h.script_sha256[0]=1;h.prepare=prepare;h.detach=detach;
    assert(ir_native_psp_exec_prepare(&h)==0 && ir_native_psp_exec_detach(1)==0);
    IRPSPExecShutdown r{};r.size=sizeof r;r.version=IR_PSP_EXEC_VERSION;r.flags=63;r.admission=1;r.generation=1;r.attempt=1;r.script_sha256[0]=1;
    assert(ir_native_psp_exec_accept_shutdown(&r)==0 && ir_native_psp_exec_restored(1,true)==0);
}
