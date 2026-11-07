"""Exercise debugger chunking and PSP RAM aliases from the shipping implementations."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest
import ppsspp_native_overlay as overlay

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('clang++'), 'Mach host required')
class SharedSessionFollowupTests(unittest.TestCase):
    def run_cpp(self, source):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); main=root/'check.cpp'; main.write_text(source)
            subprocess.run(['clang++','-std=c++17','-Wall','-Wextra','-Werror',str(main),'-o',str(root/'check')],check=True,timeout=60)
            subprocess.run([str(root/'check')],check=True,timeout=15)

    def test_psp_reserves_its_own_band_and_never_overwrites_foreign_memory(self):
        native=ROOT/'vendor/PPSSPP'
        header=overlay.apply('Common/MemArena.h',(native/'Common/MemArena.h').read_text())
        header=header[header.index('class MemArena'):]
        source=overlay.apply('Common/MemArenaDarwin.cpp',(native/'Common/MemArenaDarwin.cpp').read_text())
        source='\n'.join(line for line in source.splitlines() if not line.startswith('#include'))
        self.run_cpp(r'''
#include <mach/mach.h>
#include <cassert>
#include <cstdint>
#include <cstddef>
using u8=uint8_t;using s64=int64_t;
#define ERROR_LOG(...) ((void)0)
#define INFO_LOG(...) ((void)0)
''' + header + source + r'''
int main() {
 vm_address_t foreign=0;assert(vm_allocate(mach_task_self(),&foreign,16384,VM_FLAGS_ANYWHERE)==KERN_SUCCESS);
 *(uint32_t*)foreign=123;
 for(unsigned session=0;session<30;session++) {
  MemArena arena;assert(arena.GrabMemSpace(32*1024*1024));assert(!arena.NeedsProbing());
  u8 *base=arena.Find4GBBase();assert(base && arena.Find4GBBase()==base);
  auto first=(uint32_t*)arena.CreateView(0,16384,base);
  auto alias=(uint32_t*)arena.CreateView(0,16384,base+0x80000000ULL);
  assert(first && alias);*first=42;assert(*alias==42);
  assert(!arena.CreateView(0,16384,(void*)foreign));assert(*(uint32_t*)foreign==123);
  arena.ReleaseView(0,first,16384);
  first=(uint32_t*)arena.CreateView(0,16384,base);assert(first && *first==42);
  arena.ReleaseView(0,first,16384);arena.ReleaseView(0,alias,16384);arena.ReleaseSpace();
 }
 assert(*(uint32_t*)foreign==123);vm_deallocate(mach_task_self(),foreign,16384);
}
''')

    def test_jit_preparation_has_bounded_stops_and_failure_releases_only_owned_memory(self):
        source=(ROOT/'iridium/apps/ios/RuntimeBridge/IRJITMemory.c').read_text()
        body=source[source.index('void *ir_jit_prepare_region('):source.index('\nbool ir_jit_memory_ready(')]
        self.run_cpp(r'''
#include <cassert>
#include <cstdint>
#include <cstddef>
#include <sys/mman.h>
#define PAGE_BYTES 16384u
#define POOL_BYTES (1152u*1024*1024)
static unsigned calls,frames,removed,failAt;
static bool owned;
static size_t extent;
static void *base;
static int release(void *p,size_t bytes){assert(p==base&&bytes==extent);removed++;return 0;}
#define munmap release
static void usleep(unsigned value){assert(value==4000);frames++;}
static void *prepare_request(void *p,size_t bytes,unsigned command) {
 calls++;
 if(command==4){assert(!p&&bytes==extent);owned=true;return base;}
 assert(command==1&&p&&bytes<=2*1024*1024);
 assert((uintptr_t)p>=(uintptr_t)base && bytes<=extent-((uintptr_t)p-(uintptr_t)base));
 return calls==failAt?nullptr:p;
}
''' + body + r'''
int main(){
 base=(void*)0x100000000ULL;extent=17*1024*1024;
 assert(ir_jit_prepare_region(nullptr,extent)==base);assert(owned&&calls==10&&frames==8&&!removed);
 calls=frames=0;failAt=3;
 assert(!ir_jit_prepare_region(nullptr,extent)&&calls==3&&removed==1);
 calls=frames=0;failAt=2;
 assert(!ir_jit_prepare_region(base,extent)&&removed==1);
 calls=0;assert(!ir_jit_prepare_region(nullptr,0)&&!ir_jit_prepare_region(nullptr,1)&&!calls);
 assert(!ir_jit_prepare_region(nullptr,POOL_BYTES+PAGE_BYTES)&&!calls);
}
''')

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_native_cleanup_does_not_lock_ui_and_explorer_has_a_system_path(self):
        from host_tests import module_cache
        native=ROOT/'iridium/apps/ios/App/Adapters/Madeira/Session/IridiumMadeiraRuntime.swift'
        fixture=r'''
import Foundation
func wine_process_is_running()->Int32{1}
func wineserver_is_running()->Int32{1}
func ir_windows_threads_begin()->Bool{true}
func ir_windows_threads_drained()->Bool{true}
final class Gate: @unchecked Sendable {
 let entered=DispatchSemaphore(value:0), finish=DispatchSemaphore(value:0), done=DispatchSemaphore(value:0)
 func begin()->Bool{entered.signal();precondition(finish.wait(timeout:.now()+3) == .success);return true}
}
@main struct Check {
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let gate=Gate()
  let runtime=IridiumMadeiraRuntime(root:root,nativeRunning:{true},beginFence:{gate.begin()})
  runtime.configureHost()
  setenv("MADEIRA_EXE","explorer.exe",1);setenv("MADEIRA_ARGS","/desktop=madeira",1);setenv("MADEIRA_WORKDIR","C:\\",1)
  DispatchQueue.global().async { try! runtime.submit(UUID());gate.done.signal() }
  precondition(gate.entered.wait(timeout:.now()+3) == .success)
  let start=Date();precondition(runtime.isBusy && runtime.isResident && !runtime.requiresRestart)
  precondition(Date().timeIntervalSince(start)<0.1)
  gate.finish.signal();precondition(gate.done.wait(timeout:.now()+3) == .success)
  let request=try Data(contentsOf:root.appendingPathComponent("request.bin"))
  let path=String(data:request[24..<2072],encoding:.utf16LittleEndian)!.prefix{ $0 != "\0" }
  precondition(path=="C:\\windows\\system32\\explorer.exe")
 }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);main=root/'check.swift';main.write_text(fixture)
            subprocess.run(['swiftc','-swift-version','6','-warnings-as-errors','-parse-as-library','-module-cache-path',module_cache('macosx'),str(native),str(main),'-o',str(root/'check')],check=True,timeout=60)
            subprocess.run([str(root/'check'),str(root/'session')],check=True,timeout=10)
