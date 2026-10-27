"""Execute the Madeira adapter's wire format, job admission and thread fence."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import time
import struct
import uuid
import unittest
from host_tests import module_cache
import madeira_session
import madeira_threads

ROOT = Path(__file__).resolve().parents[1]
SESSION = ROOT / madeira_session.SOURCE


class WindowsRuntimeTests(unittest.TestCase):
    def test_child_boot_publishes_the_existing_shared_gdi_table_for_each_x64_process(self):
        loader = madeira_threads.apply_loader((ROOT / 'vendor/Madeira/build/ntdll-unix/loader_ios.c').read_text())
        boot = loader[loader.index('void wine_ios_child_main('):]
        self.assertLess(boot.index('server_init_process_child( child_fd_socket )'), boot.index('win32u_gdi_publish_shared();'))
        self.assertLess(boot.index('win32u_gdi_publish_shared();'), boot.index('server_init_process_done();'))
        source = (ROOT / 'vendor/Madeira/wine/dlls/win32u/gdiobj.c').read_text()
        start = source.index('void win32u_gdi_publish_shared(void)')
        publish = source[start:source.index('    pid = HandleToULong(', start)] + '\n}\n'
        fixture = '''#include <assert.h>
#include <stddef.h>
typedef unsigned DWORD;
struct peb {void *GdiSharedHandleTable;};
static struct {struct peb *Peb;int WowTebOffset;} teb;
#define NtCurrentTeb() (&teb)
static void *gdi_shared,*win32u_gdi_published_peb;
''' + publish + '''
int main(void){int table=1;struct peb parent={0},child={0};teb.Peb=&parent;
win32u_gdi_publish_shared();assert(!parent.GdiSharedHandleTable);
gdi_shared=&table;win32u_gdi_publish_shared();assert(parent.GdiSharedHandleTable==&table);
for(int i=0;i<300;++i){child.GdiSharedHandleTable=0;teb.Peb=&child;
win32u_gdi_publish_shared();assert(child.GdiSharedHandleTable==&table && win32u_gdi_published_peb==&child);}
return 0;}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-unused-variable',
                            str(path / 'main.c'), '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)

    def test_completed_sessions_release_identity_and_reuse_file_cache_slots(self):
        server = madeira_threads.apply_process_server((ROOT / 'vendor/Madeira/build/ntdll-unix/server_ios.c').read_text())
        start = server.index('struct ios_fd_cache {')
        cache = server[start:server.index('\n#define fd_cache ', start)]
        loader = (ROOT / 'vendor/Madeira/build/ntdll-unix/loader_ios.c').read_text()
        start = loader.index('void ios_register_proc_ident(')
        identities = loader[start:loader.index('/* X3c: attach a private ntdll', start)]
        self.assertIn('ios_proc_ident_release(dead_peb)', server.split('void process_exit_wrapper(', 1)[1])
        fixture = r'''
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#define FD_CACHE_ENTRIES 2
#define FD_CACHE_BLOCK_SIZE 4
#define FD_TYPE_INVALID 1
union fd_cache_entry {struct {int fd,type;}s;};
static void *current;
static void *ios_jit_current_peb(void){return current;}
static void ios_inproc_cache_release(void*p){(void)p;}
static int closed;
static void ios_fdt_note_close(int fd,const char*why,void*p){(void)why;assert(p==current && fd==9);}
static int close_fixture(int fd){assert(fd==9);closed++;return 0;}
#define close close_fixture
''' + cache + r'''
#define IOS_MAX_PROC_IDENTS 2
typedef struct {int Machine;} SECTION_IMAGE_INFORMATION;
static struct {void *peb; SECTION_IMAGE_INFORMATION info;void *ntdll_module;int funcs;} ios_proc_idents[2];
static int ios_proc_ident_count;
''' + identities + r'''
int main(void){
 SECTION_IMAGE_INFORMATION info={0x8664};
 current=0;struct ios_fd_cache *parent=ios_get_fd_cache();
 for(uintptr_t generation=1;generation<=300;++generation){
  current=(void*)generation;ios_register_proc_ident(current,&info);
  assert(ios_proc_ident_count==1 && ios_proc_idents[0].peb==current);
  struct ios_fd_cache *guest=ios_get_fd_cache();
  assert(guest!=parent && guest!=&ios_fd_cache_fallback && guest==ios_get_fd_cache());
  guest->blocks[0]=guest->initial_block;guest->blocks[0][0].s.fd=10;
  ios_fd_cache_release(current);ios_proc_ident_release(current);
  assert(!ios_proc_idents[0].peb && ios_fd_cache_count==2);
  assert(closed==(int)generation);
  current=0;assert(parent==ios_get_fd_cache());
 }
 ios_fd_cache_release(0);return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread',
                            str(path / 'main.c'), '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10, capture_output=True)

    def test_each_x64_child_loads_a_fresh_ntdll_in_both_host_modes(self):
        source = (ROOT / 'vendor/Madeira/build/ntdll-unix/loader_ios.c').read_text()
        patched = madeira_threads.apply_loader(source)
        condition = patched.split('CHILD_STAGE( "load_child_ec_ntdll" );', 1)[0].rsplit('if (', 1)[1].split('\n', 1)[0]
        fixture = '''#include <assert.h>
#define IMAGE_FILE_MACHINE_AMD64 0x8664
static struct {int Machine;} image;
static int fresh_loads, pool_copies, host_ec;
#define is_arm64ec() host_ec
static void launch(int machine,int ec){image.Machine=machine;host_ec=ec;assert(host_ec==0 || host_ec==1);
if (''' + condition + ''' {fresh_loads++;}else{pool_copies++;}}
int main(void){launch(0x8664,0);launch(0x8664,1);launch(0xaa64,0);launch(0x14c,0);
assert(fresh_loads==2 && pool_copies==2);return 0;}
'''
        fixture = fixture.replace('ios_cur_image_info()', '(&image)')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', str(path / 'main.c'),
                            '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)
        with self.assertRaises(ValueError): madeira_threads.apply_loader(source.replace('&& !is_arm64ec()', '&& changed()'))

    @unittest.skipUnless(os.uname().machine == 'arm64', 'ARM64 host required')
    def test_fex_diagnostic_identity_works_before_windows_tls_initialization(self):
        path = ROOT / 'vendor/Madeira/FEX/FEXCore/Source/Utils/AllocWatch.cpp'
        source = madeira_threads.apply_fex(path.read_text())
        self.assertEqual(madeira_threads.apply_fex(source), source)
        with self.assertRaises(ValueError): madeira_threads.apply_fex(source + source)
        function = source[source.index('  uint64_t CurrentThreadId() {'):source.index('  const char* EventName(')]
        fixture = r'''
#include <cstdint>
#include <cassert>
#include <pthread.h>
#define FEX_IOS_HOST 1
#define _WIN32 1
#define ARCHITECTURE_arm64ec 1
''' + function + r'''
static void *check(void *unused){(void)unused;auto id=CurrentThreadId();assert(id && id==CurrentThreadId());return reinterpret_cast<void*>(id);}
int main(){pthread_t a,b;assert(!pthread_create(&a,0,check,0));assert(!pthread_create(&b,0,check,0));void *first,*second;assert(!pthread_join(a,&first));assert(!pthread_join(b,&second));assert(first!=second);return 0;}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.cpp').write_text(fixture)
            subprocess.run(['c++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-pthread',
                            str(path / 'main.cpp'), '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_running_game_clears_starting_message_without_clearing_stop_progress(self):
        source = (ROOT / 'iridium/apps/ios/App/Adapters/Madeira/IridiumWindowsLibraryService.swift').read_text()
        handler = source.split('IridiumMadeiraRuntime.shared.poll(owner) { event in\n', 1)[1]
        handler = handler.split('\n            }\n        }\n        let dockStart', 1)[0]
        fixture = '''import Foundation
enum Event { case starting, running, ended(UInt32), blocked(String) }
final class Library {
 var nativeLaunchID=UUID(), current:UUID?=UUID(), sawProcess=false, quitRequested=false, launching=true
 var sessionMessage="Starting…", error:String?, timer:Timer?
 func finish(){current=nil}
 func accept(_ event:Event, owner:UUID) {
''' + handler + '''
 }
}
let library=Library(), owner=library.nativeLaunchID
library.accept(.starting,owner:owner)
precondition(!library.sawProcess && library.sessionMessage == "Starting…")
library.accept(.running,owner:UUID())
precondition(!library.sawProcess && library.sessionMessage == "Starting…")
library.accept(.running,owner:owner)
precondition(library.sawProcess && library.sessionMessage.isEmpty)
library.sessionMessage="Ending the remaining game processes…"
library.accept(.running,owner:owner)
precondition(library.sessionMessage == "Ending the remaining game processes…")
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.swift').write_text(fixture)
            subprocess.run(['swiftc', '-module-cache-path', module_cache('macosx'),
                            str(path / 'main.swift'), '-o', str(path / 'check')], check=True, timeout=45)
            subprocess.run([str(path / 'check')], check=True, timeout=10)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_status_callback_has_explicit_main_actor_isolation(self):
        fixture = '''import Foundation
func wine_process_is_running()->Int32{1}
func wineserver_is_running()->Int32{1}
func ir_windows_threads_begin()->Bool{true}
func ir_windows_threads_drained()->Bool{true}
final class Library {
 var current:UUID?;var count=0
 @MainActor func poll(_ owner:UUID) {
  IridiumMadeiraRuntime.shared.poll(owner) { event in
   guard self.current == owner else { return };self.count += 1
  }
 }
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'fixture.swift').write_text(fixture)
            subprocess.run(['swiftc', '-swift-version', '5', '-strict-concurrency=complete',
                            '-warnings-as-errors', '-module-cache-path', module_cache('macosx'),
                            '-parse-as-library', '-emit-module', str(SESSION / 'IridiumMadeiraRuntime.swift'),
                            str(path / 'fixture.swift'), '-o', str(path / 'Fixture.swiftmodule')],
                           check=True, timeout=45)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_two_games_stale_status_failed_launch_and_retained_threads(self):
        fixture = r'''
import Foundation
import Darwin
func wine_process_is_running()->Int32{1}
func wineserver_is_running()->Int32{1}
func ir_windows_threads_begin()->Bool{true}
func ir_windows_threads_drained()->Bool{true}
let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer{try? FileManager.default.removeItem(at:folder)}
func status(_ token:UUID,phase:UInt32,result:UInt32=0,inRoot:URL?=nil)throws{
 var d=Data([0x31,0x57,0x52,0x49,1,0,0,0]),u=token.uuid
 withUnsafeBytes(of:&u){d.append(contentsOf:$0)}
 for n in [phase,result]{for i in 0..<4{d.append(UInt8(truncatingIfNeeded:n >> (i*8)))}}
 try d.write(to:(inRoot ?? folder).appendingPathComponent("status.bin"),options:.atomic)
}
final class Observation:@unchecked Sendable {
 let lock=NSLock();var drain=true;var time:TimeInterval=0;var event:IridiumMadeiraRuntime.Event?
 func now()->TimeInterval{lock.lock();defer{lock.unlock()};return time}
 func advance(_ value:TimeInterval){lock.lock();time+=value;lock.unlock()}
 func drained()->Bool{lock.lock();defer{lock.unlock()};return drain}
 func set(_ value:Bool){lock.lock();drain=value;lock.unlock()}
}
let observation=Observation()
let runtime=IridiumMadeiraRuntime(root:folder,nativeRunning:{true},beginFence:{true},drained:{observation.drained()},clock:{observation.now()})
func poll(_ token:UUID,from engine:IridiumMadeiraRuntime?=nil)->IridiumMadeiraRuntime.Event{
 let sem=DispatchSemaphore(value:0)
 (engine ?? runtime).poll(token){event in precondition(Thread.isMainThread);observation.lock.lock();observation.event=event;observation.lock.unlock();sem.signal()}
 let deadline=Date(timeIntervalSinceNow:3)
 while sem.wait(timeout:.now()) != .success {
  precondition(Date()<deadline);_=RunLoop.current.run(mode:.default,before:Date(timeIntervalSinceNow:0.005))
 }
 observation.lock.lock();defer{observation.lock.unlock()};return observation.event!
}
setenv("MADEIRA_EXE","C:\\Games\\Game A.exe",1);setenv("MADEIRA_ARGS","--level \"one two\"",1)
setenv("MADEIRA_WORKDIR","C:\\Games",1)
let a=UUID(),b=UUID(),c=UUID(),zero=UUID(uuid:(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
try runtime.submit(a);precondition(runtime.isBusy && !runtime.isResident)
runtime.configureHost();try status(zero,phase:0)
if case .starting=poll(a){}else{fatalError("boot did not submit")}
let request=folder.appendingPathComponent("request.bin")
let bytes=try Data(contentsOf:request);precondition(bytes.count==77848)
try bytes.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
do{try runtime.submit(b);fatalError("overlapping game")}catch{}
try FileManager.default.removeItem(at:request)
try status(a,phase:1);if case .running=poll(a){}else{fatalError("not running")}
observation.set(false);try status(a,phase:3)
if case .running=poll(a){}else{fatalError("released live threads")}
precondition(runtime.isBusy)
observation.set(true)
if case .ended(0)=poll(a){}else{fatalError("not drained")}
precondition(!runtime.isBusy && runtime.isResident)
setenv("MADEIRA_EXE","C:\\Games\\Game B.exe",1)
try runtime.submit(b)
if case .starting=poll(b){}else{fatalError("accepted previous game's status")}
try FileManager.default.removeItem(at:request)
try status(b,phase:4,result:2)
if case .ended(2)=poll(b){}else{fatalError("failed launch not released")}
precondition(!runtime.isBusy)
let cancelled=UUID();runtime.requestStop(cancelled);try runtime.submit(cancelled)
if case .ended(0)=poll(cancelled){}else{fatalError("cancelled preparation launched")}
precondition(!FileManager.default.fileExists(atPath:request.path) && !runtime.isBusy)
for _ in 0..<100 {
 let repeated=UUID();try runtime.submit(repeated)
 try FileManager.default.removeItem(at:request)
 try status(repeated,phase:3)
 if case .ended(0)=poll(repeated){}else{fatalError("repeat failed")}
}
try runtime.submit(c);try FileManager.default.removeItem(at:request)
try Data(repeating:0,count:40).write(to:folder.appendingPathComponent("status.bin"))
if case .blocked=poll(c){}else{fatalError("accepted corrupt status")}
precondition(runtime.isBusy)
do{try runtime.submit(UUID());fatalError("released poisoned host")}catch{}
let stalledRoot=folder.appendingPathComponent("stalled"),stalledID=UUID()
let stalled=IridiumMadeiraRuntime(root:stalledRoot,nativeRunning:{true},beginFence:{true},drained:{true},clock:{observation.now()})
try stalled.submit(stalledID);stalled.configureHost();try status(zero,phase:0,inRoot:stalledRoot)
_=poll(stalledID,from:stalled)
try FileManager.default.removeItem(at:stalledRoot.appendingPathComponent("request.bin"))
try status(stalledID,phase:1,inRoot:stalledRoot);_=poll(stalledID,from:stalled)
observation.advance(30) // A background/resume gap gets a fresh observation window.
if case .running=poll(stalledID,from:stalled){}else{fatalError("background gap poisoned host")}
var expired=false
for _ in 0..<9 {
 observation.advance(2)
 if case .blocked=poll(stalledID,from:stalled){expired=true;break}
}
precondition(expired && stalled.isBusy,"silent host released admission")
let foreign=folder.appendingPathComponent("foreign")
try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:true)
try Data("user data".utf8).write(to:foreign.appendingPathComponent("status.bin"))
let foreignRuntime=IridiumMadeiraRuntime(root:foreign,nativeRunning:{false})
do{try foreignRuntime.submit(UUID());fatalError("accepted unowned control directory")}catch{}
let kept=try Data(contentsOf:foreign.appendingPathComponent("status.bin"));precondition(kept == Data("user data".utf8))
for invalid in ["",String(repeating:"x",count:1024),"a\u{0}b","a\nb"]{
 do{_=try IridiumMadeiraRuntime.request(executable:invalid,arguments:"",directory:"C:\\",token:UUID());fatalError("invalid executable")}catch{}
}
print("PASS two games, stale completion, failure recovery, native drain and corrupt status")
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.swift').write_text(fixture)
            subprocess.run(['swiftc', '-swift-version', '5', '-module-cache-path', module_cache('macosx'),
                            str(SESSION / 'IridiumMadeiraRuntime.swift'), str(path / 'main.swift'),
                            '-o', str(path / 'check')], check=True, timeout=45)
            subprocess.run([str(path / 'check'), str(path / 'request.bin')], check=True, timeout=15)
            c = path / 'wire.c'
            c.write_text(r'''
#include "IRWindowsSession.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(int argc,char**argv){
 assert(argc==2);IRWindowsLaunch request;
 FILE*f=fopen(argv[1],"rb");assert(f);assert(fread(&request,1,sizeof(request),f)==sizeof(request));fclose(f);
 assert(ir_windows_launch_valid(&request));assert(request.executable[0]=='C');
 request.version++;assert(!ir_windows_launch_valid(&request));request.version--;
 memset(request.executable,'x',sizeof(request.executable));assert(!ir_windows_launch_valid(&request));
 return 0;
}
''')
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(SESSION),
                            str(c), '-o', str(path / 'wire')], check=True, timeout=30)
            subprocess.run([str(path / 'wire'), str(path / 'request.bin')], check=True, timeout=5)

    @unittest.skipUnless(os.uname().sysname == 'Darwin', 'Mach thread APIs required')
    def test_guest_thread_exit_destructors_and_retained_host_services(self):
        fixture = r'''
#include "IRWindowsThreads.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
static atomic_bool entered,stop,host_stop,destructing,release_destructor;
static pthread_key_t key;
static void*host(void*unused){(void)unused;while(!atomic_load(&host_stop))usleep(1000);return 0;}
static void destructor(void*value){(void)value;atomic_store(&destructing,true);while(!atomic_load(&release_destructor))usleep(1000);}
static void*worker(void*value){
 assert(!pthread_setspecific(key,(void*)1));atomic_store(&entered,true);
 while(!atomic_load(&stop))usleep(1000);
 if(value)pthread_exit(0);
 return 0;
}
static void wait_for(atomic_bool*value){for(int i=0;i<5000&&!atomic_load(value);++i)usleep(1000);assert(atomic_load(value));}
static void wait_drain(void){for(int i=0;i<5000&&!ir_windows_threads_drained();++i)usleep(1000);assert(ir_windows_threads_drained());}
int main(void){
 assert(!pthread_key_create(&key,destructor));
 pthread_t baseline,system_thread,thread;
 assert(!ir_windows_pthread_create(&baseline,0,host,0));
 assert(!ir_windows_threads_drained());assert(ir_windows_threads_begin());wait_drain();
 assert(!pthread_create(&system_thread,0,host,0));wait_drain();
 for(int mode=0;mode<100;++mode){
  atomic_store(&entered,false);atomic_store(&stop,false);atomic_store(&destructing,false);atomic_store(&release_destructor,false);
  assert(ir_windows_threads_begin());
  pthread_attr_t attr;assert(!pthread_attr_init(&attr));
  bool detached=mode%2; if(detached)assert(!pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED));
  assert(!ir_windows_pthread_create(&thread,&attr,worker,(void*)(long)(mode%3)));assert(!pthread_attr_destroy(&attr));
  assert(!ir_windows_threads_drained());assert(!ir_windows_threads_begin());wait_for(&entered);
  atomic_store(&stop,true);wait_for(&destructing);
  assert(!ir_windows_threads_drained());atomic_store(&release_destructor,true);
  if(!detached)assert(!pthread_join(thread,0));
  wait_drain();
 }
 atomic_store(&host_stop,true);assert(!pthread_join(baseline,0));assert(!pthread_join(system_thread,0));
 wait_drain();assert(!pthread_key_delete(key));return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            bridge = ROOT / 'iridium/apps/ios/RuntimeBridge'
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(bridge),
                            str(path / 'main.c'), str(bridge / 'IRWindowsThreads.c'),
                            '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=60)

    @unittest.skipUnless(os.uname().sysname == 'Darwin', 'Mach thread APIs required')
    def test_failed_thread_creation_does_not_leave_a_pending_guest(self):
        fixture = r'''
#include "IRWindowsThreads.h"
#include <assert.h>
#include <errno.h>
int fail_create(pthread_t*t,const pthread_attr_t*a,void*(*s)(void*),void*v){(void)t;(void)a;(void)s;(void)v;return EAGAIN;}
static void*worker(void*v){return v;}
int main(void){pthread_t thread;assert(ir_windows_threads_begin());assert(ir_windows_pthread_create(&thread,0,worker,0)==EAGAIN);assert(ir_windows_threads_drained());return 0;}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            bridge = ROOT / 'iridium/apps/ios/RuntimeBridge'
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Dpthread_create=fail_create',
                            '-I', str(bridge), str(path / 'main.c'), str(bridge / 'IRWindowsThreads.c'),
                            '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)

    def test_guest_creation_hooks_reject_upstream_drift(self):
        for name in ('process_ios.c', 'thread_ios.c'):
            source = (ROOT / 'vendor/Madeira/build/ntdll-unix' / name).read_text()
            result = madeira_threads.apply(source, name, 'IRWindowsThreads.h')
            self.assertEqual(result.count('ir_windows_pthread_create('), 1)
            self.assertEqual(result.count('pthread_join('), source.count('pthread_join('))
            self.assertEqual(result.count('pthread_detach('), source.count('pthread_detach('))
            for changed in (source.replace('pthread_create(', 'changed_create('), source + source):
                with self.assertRaisesRegex(ValueError, 'guest thread creation changed'):
                    madeira_threads.apply(changed, name, 'IRWindowsThreads.h')

    @unittest.skipUnless(os.uname().sysname == 'Darwin', 'Mach thread APIs required')
    def test_pseudo_process_stop_signal_without_a_debugger_port(self):
        source = (ROOT / 'vendor/Madeira/build/wineserver/mach_ios.c').read_text()
        patched = madeira_threads.apply_server(source)
        begin = patched.index('extern int __pthread_kill(')
        function = patched[begin:patched.index('\n#ifdef WINE_IOS\n/* iOS cross-thread', begin)]
        fixture = r'''
#include <assert.h>
#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>
struct process { mach_port_t trace_data; };
struct thread { struct process *process; int unix_pid, unix_tid; unsigned id; };
static int debug_level;
static mach_port_t get_process_port(struct process *p){return p->trace_data;}
static atomic_bool started,release_section,received;
static void stopped(int sig){assert(sig==SIGQUIT);atomic_store(&received,true);}
static void *worker(void *unused){
 (void)unused;sigset_t set;sigemptyset(&set);sigaddset(&set,SIGQUIT);
 assert(!pthread_sigmask(SIG_BLOCK,&set,0));atomic_store(&started,true);
 while(!atomic_load(&release_section))usleep(1000);
 assert(!atomic_load(&received));assert(!pthread_sigmask(SIG_UNBLOCK,&set,0));
 for(int i=0;i<1000&&!atomic_load(&received);++i)usleep(1000);
 assert(atomic_load(&received));return 0;
}
''' + function + r'''
int main(void){
 struct sigaction action={0};action.sa_handler=stopped;sigemptyset(&action.sa_mask);
 assert(!sigaction(SIGQUIT,&action,0));
 struct process process={0};pthread_t native;
 assert(!pthread_create(&native,0,worker,0));
 while(!atomic_load(&started))usleep(1000);
 struct thread target={&process,getpid(),pthread_mach_thread_np(native),1};
 assert(!send_thread_signal(&target,SIGUSR1));
 target.unix_pid=-1;assert(!send_thread_signal(&target,SIGQUIT));
 target.unix_pid=getpid()+1;assert(!send_thread_signal(&target,SIGQUIT));
 target.unix_pid=getpid();assert(send_thread_signal(&target,SIGQUIT));
 assert(!atomic_load(&received));atomic_store(&release_section,true);
 assert(!pthread_join(native,0));assert(atomic_load(&received));return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-DWINE_IOS', '-std=c11', '-Wall', '-Wextra', '-Werror',
                            str(path / 'main.c'), '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)

    def test_process_thread_counts_are_isolated_and_exit_is_counted_once(self):
        source = (ROOT / 'vendor/Madeira/build/ntdll-unix/thread_ios.c').read_text()
        patched = madeira_threads.apply(source, 'thread_ios.c', 'unused.h')
        begin = patched.index('#define nb_threads ')
        accounting = patched[begin:patched.index('\nstatic inline int get_unix_exit_code', begin)]
        server = madeira_threads.apply_process_server((ROOT / 'vendor/Madeira/build/ntdll-unix/server_ios.c').read_text())
        begin = server.index('LONG *ios_process_thread_count_ptr(void)')
        accessors = server[begin:server.index('/* Master socket for the CURRENT', begin)]
        begin = server.index('static void ios_register_proc_socket(void *peb_id, int fd)')
        registration = server[begin:server.index('\n}', begin) + 2]
        fixture = r'''
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
typedef int LONG;
typedef bool BOOL;
typedef struct {int value;} TEB;
#define TRUE true
#define InterlockedDecrement(p) __atomic_sub_fetch(p,1,__ATOMIC_SEQ_CST)
static _Thread_local int process_index=-1;
static struct {void *peb;int fd;BOOL exiting;LONG threads;TEB *previous_teb;} ios_proc_sockets[2];
static int ios_proc_socket_index(void){return process_index;}
#define FALSE false
#define IOS_MAX_PROC_SOCKETS 2
#define IOS_DEAD_PEB_MAX 2
#define FDT_MASTER 1
#define wine_log_write(...) ((void)0)
static int ios_proc_socket_count;
static void *ios_dead_pebs[IOS_DEAD_PEB_MAX];
static void ios_fdt_reg(int fd,int kind,void *peb){(void)fd;(void)kind;(void)peb;}
''' + registration + accessors + accounting + r'''
static void *end_thread(void *argument){
 process_index=(int)(long)argument;
 bool last=ios_end_process_thread();assert(ios_end_process_thread()==last);
 return (void*)(long)last;
}
int main(void){
 LONG *parent=ios_process_thread_count_ptr();assert(*parent==1);
 for(int generation=0;generation<100;++generation){
  pthread_t threads[4];int last[2]={0};
  TEB first={1},second={2};
  ios_register_proc_socket(&first,1);ios_register_proc_socket(&second,2);
  assert(ios_proc_socket_count==2 && ios_proc_sockets[0].peb==&first && ios_proc_sockets[1].peb==&second);
  for(int i=0;i<2;++i){assert(ios_proc_sockets[i].threads==1 && !ios_proc_sockets[i].previous_teb);ios_proc_sockets[i].threads=2;}
  process_index=0;*ios_process_previous_teb_ptr()=&first;
  process_index=1;*ios_process_previous_teb_ptr()=&second;
  for(int i=0;i<4;++i)assert(!pthread_create(&threads[i],0,end_thread,(void*)(long)(i%2)));
  for(int i=0;i<4;++i){void *value;assert(!pthread_join(threads[i],&value));last[i%2]+=(int)(long)value;}
  for(int i=0;i<2;++i){assert(last[i]==1);assert(!ios_proc_sockets[i].threads);}
  process_index=0;assert(*ios_process_previous_teb_ptr()==&first);
  process_index=1;assert(*ios_process_previous_teb_ptr()==&second);
  for(int i=0;i<2;++i)ios_proc_sockets[i].peb=0;
  assert(*parent==1);
 }
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread',
                            str(path / 'main.c'), '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)

    def test_child_slots_are_released_on_return_longjmp_and_pthread_exit(self):
        source = (ROOT / 'vendor/Madeira/build/ntdll-unix/process_ios.c').read_text()
        patched = madeira_threads.apply(source, 'process_ios.c', 'unused.h')
        begin = patched.index('static void ios_child_args_release( void *arg )')
        child = patched[begin:patched.index('\n#endif', begin)]
        fixture = r'''
#include <assert.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define IMAGE_FLAGS_ComPlusNativeReady 1
#define ERR(...) ((void)0)
static int native_machine;
static _Thread_local int ios_child_main_machine,wine_ios_exit_initialized,wine_ios_exit_code;
static _Thread_local pthread_t wine_ios_main_thread;
static _Thread_local jmp_buf wine_ios_exit_jmpbuf;
static _Thread_local const char *ios_child_boot_stage="running";
static pthread_key_t ios_teb_tls_key;
static atomic_int released;
struct ios_child_args {int socketfd,unixdir;char **argv;int argc;struct {int image_flags,machine;} pe_info;int slot;};
void ios_child_boot_unlock(void){}
static void ios_child_slot_release(int slot){assert(slot==0);atomic_fetch_add(&released,1);}
static void ios_wow_window_release_current(void){}
static void wine_ios_child_main(int mode,char **argv,int fd){
 (void)argv;(void)fd;
 if(mode==1)longjmp(wine_ios_exit_jmpbuf,1);
 if(mode==2)pthread_exit(0);
}
''' + child + r'''
int main(void){
 assert(!pthread_key_create(&ios_teb_tls_key,0));
 for(int i=0;i<100;++i)for(int mode=0;mode<3;++mode){
  struct ios_child_args *args=calloc(1,sizeof(*args));assert(args);
  args->argv=calloc(1,sizeof(char*));assert(args->argv);args->unixdir=-1;args->argc=mode;
  pthread_t thread;assert(!pthread_create(&thread,0,ios_child_thread_entry,args));assert(!pthread_join(thread,0));
  assert(atomic_load(&released)==i*3+mode+1);
 }
 assert(!pthread_key_delete(ios_teb_tls_key));return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread',
                            str(path / 'main.c'), '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=20, capture_output=True)

    @unittest.skipUnless((ROOT / 'vendor/Madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang').is_file(), 'Prepared Windows cross compiler required')
    def test_launcher_pe_and_source_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            madeira_session.build(path)
            original = (path / 'iridium-session.exe').read_bytes()
            (path / 'iridium-session.exe').write_bytes(original + b'changed')
            with self.assertRaises(ValueError): madeira_session.verify(path)

    @unittest.skipUnless(os.environ.get('IRIDIUM_WINDOWS_WINE'), 'Optional desktop Wine process test')
    def test_real_windows_jobs_environment_failure_retry_and_stop(self):
        wine = Path(os.environ['IRIDIUM_WINDOWS_WINE']).resolve()
        compiler = ROOT / 'vendor/Madeira/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang'
        with tempfile.TemporaryDirectory(prefix='iridium-session-wine-') as folder:
            path = Path(folder)
            prefix = path / 'prefix'
            control = prefix / 'drive_c/iridium-session'
            control.mkdir(parents=True)
            madeira_session.build(control)
            unit = path / 'fixture.c'
            unit.write_text(r'''
#include <windows.h>
#include <string.h>
int main(int argc,char**argv){
 char value[64],cwd[2048];
 if(argc!=2 || !GetEnvironmentVariableA("IRIDIUM_TEST_GAME",value,sizeof(value)) || strcmp(value,argv[1]))return 71;
 if(!GetCurrentDirectoryA(sizeof(cwd),cwd) || !strstr(cwd,"game directory"))return 72;
 if(!strcmp(argv[1],"wait"))Sleep(30000);
 return 0;
}
''')
            game = control / 'fixture.exe'
            subprocess.run([str(compiler), '-static', '-O2', str(unit), '-o', str(game)], check=True, timeout=30)
            (control / 'game directory').mkdir()
            env = dict(os.environ, WINEPREFIX=str(prefix), WINEDEBUG='-all',
                       WINEDLLOVERRIDES='winemenubuilder.exe=d')
            log = (path / 'wine.log').open('w')
            process = subprocess.Popen([str(wine), str(control / 'iridium-session.exe'), r'C:\iridium-session'],
                                       env=env, stdout=log, stderr=log)
            def status(token=None, terminal=False, timeout=45):
                until = time.monotonic() + timeout
                while time.monotonic() < until:
                    if process.poll() is not None:
                        log.flush(); self.fail('Windows launcher exited: ' + (path / 'wine.log').read_text()[-2000:])
                    try:
                        data = (control / 'status.bin').read_bytes()
                        if len(data) == 32:
                            magic, version, owner, phase, result = struct.unpack('<II16sII', data)
                            if magic == 0x49525731 and version == 1 and (token is None or owner == token.bytes):
                                if not terminal or phase in (3, 4): return phase, result
                    except FileNotFoundError: pass
                    time.sleep(.02)
                log.flush(); self.fail('Windows job timed out: ' + (path / 'wine.log').read_text()[-2000:])
            def request(value, executable=r'C:\iridium-session\fixture.exe'):
                token = uuid.uuid4()
                data = struct.pack('<II16s', 0x49525731, 1, token.bytes)
                for text, size in [(executable, 1024), (value, 4096), (r'C:\iridium-session\game directory', 1024)]:
                    encoded = text.encode('utf-16-le'); data += encoded + bytes(size * 2 - len(encoded))
                variables = ('IRIDIUM_TEST_GAME=' + value + '\0\0').encode('utf-16-le')
                data += variables + bytes(32768 * 2 - len(variables))
                temporary = control / 'request.tmp'; temporary.write_bytes(data); temporary.replace(control / 'request.bin')
                return token
            try:
                self.assertEqual(status()[0], 0)
                for value in ('first', 'second'):
                    self.assertEqual(status(request(value), terminal=True), (3, 0))
                failure = status(request('missing', r'C:\iridium-session\missing.exe'), terminal=True)
                self.assertEqual(failure[0], 4); self.assertNotEqual(failure[1], 0)
                self.assertEqual(status(request('retry'), terminal=True), (3, 0))
                token = request('wait')
                self.assertEqual(status(token)[0], 1)
                stale = struct.pack('<II16sII', 0x49525731, 1, uuid.uuid4().bytes, 0, 0)
                (control / 'stop.bin').write_bytes(stale)
                time.sleep(.2); self.assertEqual(status(token)[0], 1)
                (control / 'stop.bin').write_bytes(struct.pack('<II16sII', 0x49525731, 1, token.bytes, 0, 0))
                self.assertEqual(status(token, terminal=True)[0], 3)
                self.assertEqual(status(request('after-stop'), terminal=True), (3, 0))
            finally:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
                # This private prefix has its own server. Never stop another bottle.
                server = wine.parents[3] / 'bin/wineserver'
                if server.is_file(): subprocess.run([str(server), '-k'], env=env, timeout=10, check=False)
                log.close()
