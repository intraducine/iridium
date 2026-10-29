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
    def test_native_gdi_cache_survives_game_cleanup_and_wow_keeps_its_namespace(self):
        original = (ROOT / 'vendor/Madeira/wine/dlls/win32u/dc.c').read_text()
        source = madeira_threads.apply_dc(original)
        buckets = source[source.index('struct dc_attr_bucket\n'):source.index('static BOOL DC_DeleteObject')]
        allocate = source[source.index('static DC_ATTR *alloc_dc_attr('):source.index('/***********************************************************************\n *           set_initial_dc_state')]
        virtual = madeira_threads.apply_virtual((ROOT / 'vendor/Madeira/build/ntdll-unix/virtual_ios.c').read_text())
        keep = virtual[virtual.index('void ir_windows_keep_view( void *base'):]
        fixture = r'''
#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include "wine/list.h"
#define WINE_IOS 1
#define FALSE 0
#define MEM_RESERVE 1
#define MEM_COMMIT 2
#define PAGE_READWRITE 4
typedef unsigned DWORD;
typedef int BOOL;
typedef size_t SIZE_T;
typedef struct {char data[192];} DC_ATTR;
static struct {void *Peb;struct {void *UniqueProcess;} ClientId;int WowTebOffset;} teb;
#define NtCurrentTeb() (&teb)
#define HandleToULong(x) ((DWORD)(uintptr_t)(x))
static int win32u_wow_session=1;
static struct {size_t AllocationGranularity;} system_info={4096};
static pthread_mutex_t dc_attr_lock=PTHREAD_MUTEX_INITIALIZER;
static void win32u_gdi_check_publish(void){}
static int caller_zero_bits(void){return teb.WowTebOffset;}
static void *GetCurrentProcess(void){return (void*)-1;}
struct file_view {void *base;size_t size;void *ios_owner;uint64_t ios_epoch;unsigned ios_retired;};
static struct file_view views[10];
static unsigned count;
static int virtual_mutex,locked;
static void server_enter_uninterrupted_section(int*m,sigset_t*s){(void)s;assert(m==&virtual_mutex && !locked);locked=1;}
static void server_leave_uninterrupted_section(int*m,sigset_t*s){(void)s;assert(m==&virtual_mutex && locked);locked=0;}
static struct file_view *find_view(void*p,size_t size){
 assert(locked);
 for(unsigned i=0;i<count;i++)if(views[i].base==p && size<=views[i].size)return &views[i];
 return NULL;
}
static int NtAllocateVirtualMemory(void*process,void**p,int bits,size_t*size,int flags,int prot){
 (void)process;(void)bits;(void)flags;(void)prot;assert(count<10);
 *p=mmap(0,*size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);assert(*p!=MAP_FAILED);
 views[count++]=(struct file_view){*p,*size,teb.Peb,1,0};return 0;
}
''' + keep + buckets + allocate + r'''
static void retire(void *owner){
 for(unsigned i=0;i<count;i++)if(views[i].ios_owner==owner){
  views[i].ios_retired=1;assert(!mprotect(views[i].base,views[i].size,PROT_NONE));
 }
}
int main(void){
 teb.Peb=(void*)1;teb.ClientId.UniqueProcess=(void*)1;
 DC_ATTR *native=alloc_dc_attr();assert(native && !views[0].ios_owner);
 free_dc_attr(native);retire(teb.Peb);
 for(unsigned i=2;i<302;i++){
  teb.Peb=(void*)(uintptr_t)i;teb.ClientId.UniqueProcess=teb.Peb;
  DC_ATTR *next=alloc_dc_attr();assert(next==native && count==1);next->data[0]=42;
  free_dc_attr(next);retire(teb.Peb);
 }
 teb.WowTebOffset=1;teb.Peb=(void*)400;teb.ClientId.UniqueProcess=teb.Peb;
 DC_ATTR *wow=alloc_dc_attr();assert(wow!=native && count==2 && views[1].ios_owner==teb.Peb);
 free_dc_attr(wow);retire(teb.Peb);
 teb.Peb=(void*)401;teb.ClientId.UniqueProcess=teb.Peb;
 DC_ATTR *other=alloc_dc_attr();assert(other!=wow && count==3 && views[2].ios_owner==teb.Peb);
 free_dc_attr(other);teb.WowTebOffset=0;teb.Peb=(void*)402;teb.ClientId.UniqueProcess=teb.Peb;
 assert(alloc_dc_attr()==native && count==3 && !locked);
 ir_windows_keep_view((void*)0x1234,4096);assert(!locked);
 for(unsigned i=0;i<count;i++)assert(!munmap(views[i].base,views[i].size));
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(ROOT / 'vendor/Madeira/wine/include'),
                            str(path / 'main.c'), '-pthread', '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)
        gdi = (ROOT / 'vendor/Madeira/wine/dlls/win32u/gdiobj.c').read_text()
        self.assertIn('ir_windows_keep_view( gdi_shared, size );', madeira_threads.apply_gdi(gdi))
        for adapt, text in [(madeira_threads.apply_dc, original), (madeira_threads.apply_gdi, gdi)]:
            with self.assertRaises(ValueError): adapt(text + text)

    def test_steered_reservations_wait_for_process_exit_and_next_thread_fence(self):
        original = (ROOT / 'vendor/Madeira/build/ntdll-unix/virtual_ios.c').read_text()
        source = madeira_threads.apply_virtual(original)
        table = source[source.index('#define IOS_STEER_MAX'):source.index('static uint64_t ios_steer_reclaim_dead( void );')]
        ownership = source[source.index('static void ios_steer_forget('):source.index('/* ml255: STORM GATE.')]
        start = source.index('static uint64_t ios_steer_reclaim_dead( void )\n{')
        reclaim = source[start:source.index('\n\n/***********************************************************************\n *           register_view', start)]
        fixture = r'''
#include <assert.h>
#include <signal.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#define dprintf(...) ((void)0)
#define VPROT_READ 0x01
#define VPROT_WRITE 0x02
#define VPROT_EXEC 0x04
#define VPROT_COMMITTED 0x20
static int virtual_mutex,locked;
static unsigned deleted,committed,freed_committed;
static int waiters_ready=1;
static uint64_t epoch=1;
static _Atomic uint64_t ios_cleanup_epoch=1;
static bool metal_ready=true;
static bool ir_windows_metal_reclaim(uint64_t e){assert(e==epoch && !locked);return metal_ready;}
static void ir_windows_metal_owner_died(void*p){(void)p;}
static uintptr_t owner=0xa;
static uint64_t ir_windows_session_epoch(void){return epoch;}
static void *ios_jit_current_peb(void){return (void*)owner;}
static void ios_views_owner_died(void*p){(void)p;}
static uint64_t ios_views_reclaim(uint64_t e){assert(e==ios_cleanup_epoch);return 0;}
static int ios_views_forget_waiters(uint64_t e){assert(e==ios_cleanup_epoch);return waiters_ready;}
struct file_view {void *base;size_t size;unsigned protect,ios_flags;};
static struct file_view current;
static int ios_view_reclaimable(const struct file_view*v,uint64_t e){assert(e==ios_cleanup_epoch);return !(v->protect&~(VPROT_READ|VPROT_WRITE|VPROT_COMMITTED)) && !v->ios_flags;}
static void server_enter_uninterrupted_section(int*m,sigset_t*s){(void)s;assert(m==&virtual_mutex && !locked);locked=1;}
static void server_leave_uninterrupted_section(int*m,sigset_t*s){(void)s;assert(m==&virtual_mutex && locked);locked=0;}
''' + table + ownership + r'''
static struct file_view *find_view(void*p,size_t n){(void)n;assert(locked);return current.base==p?&current:0;}
static void ios_bigres_release(void*p){assert(locked && p==current.base);}
static void delete_view(struct file_view*v){assert(locked);ios_steer_forget(v->base,v->size);v->base=0;deleted++;freed_committed+=committed;}
''' + reclaim + r'''
int main(void){
 current=(struct file_view){(void*)0x10000,8192,0,0};ios_steer_record(current.base,current.size,1);ios_thread_died(1);
 assert(!ios_steer_reclaim_dead()); /* An allocator thread can end while its process lives. */
 ios_steer_owner_died((void*)0xb);assert(!ios_steer[0].retired);
 ios_steer_owner_died((void*)owner);assert(!ios_steer_reclaim_dead());
 /* Explicit free, then a different allocation at the same address. */
 ios_steer_forget(current.base,current.size);assert(ios_steer_reclaim_dead()==0 && !deleted);
 epoch++;ios_cleanup_epoch=epoch;owner=0xb;
 ios_steer_record(current.base,current.size,2);assert(ios_steer_n==1 && !ios_tid_is_dead(2));
 ios_steer_owner_died((void*)0xa);assert(!ios_steer[0].retired);
 assert(ios_steer_reclaim_dead()==0 && !deleted);ios_thread_died(2);
 committed=1;ios_steer[0].inuse=1;
 assert(ios_steer_reclaim_dead()==0 && !deleted);
 ios_steer_owner_died((void*)owner);assert(!ios_steer_reclaim_dead());
 epoch++;ios_cleanup_epoch=epoch; /* begin() can advance only after all previous guest TLS destructors end. */
 current.protect=0x10000;assert(ios_steer_reclaim_dead()==0);current.protect=0;
 current.protect=VPROT_EXEC;assert(ios_steer_reclaim_dead()==0);current.protect=0;
 current.ios_flags=4;assert(ios_steer_reclaim_dead()==0);current.ios_flags=0;
 waiters_ready=0;assert(!ios_steer_reclaim_dead() && !deleted && !locked);waiters_ready=1;
 metal_ready=false;ios_cleanup_epoch=epoch-1;
 ir_windows_reclaim_completed();assert(!deleted && ios_cleanup_epoch==epoch-1);
 assert(!ios_steer_reclaim_dead() && !deleted); /* An allocation cannot bypass a failed GPU fence. */
 metal_ready=true;ir_windows_reclaim_completed();
 assert(deleted==1 && ios_steer[0].freed && ios_cleanup_epoch==epoch);
 for(unsigned i=0;i<300;i++){
  unsigned protection=i%2?VPROT_READ:VPROT_READ|VPROT_WRITE;
  current=(struct file_view){(void*)0x10000,8192,protection,0};ios_steer_record(current.base,current.size,2);
  assert(!ios_tid_is_dead(2) && ios_steer_n==1 && !ios_steer[0].inuse);
  assert(!ios_steer_reclaim_dead());ios_thread_died(2);
  committed=1;ios_steer[0].inuse=1;assert(!ios_steer_reclaim_dead());
  ios_steer_owner_died((void*)owner);assert(!ios_steer_reclaim_dead());epoch++;ios_cleanup_epoch=epoch;
  assert(ios_steer_reclaim_dead()==8192);
 }
 current=(struct file_view){(void*)0x10000,8192,0,0};owner=0;
 ios_steer_record(current.base,current.size,2);ios_steer_owner_died(0);epoch++;ios_cleanup_epoch=epoch;
 assert(!ios_steer_reclaim_dead());
 assert(deleted==301 && freed_committed==301 && !locked);return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(path / 'main.c'),
                            '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)
        deletion = source.split('static void delete_view(', 1)[1].split('static uint64_t ios_steer_reclaim_dead(', 1)[0]
        self.assertLess(deletion.index('ios_steer_forget('), deletion.index('unmap_area('))
        self.assertNotIn('NtFreeVirtualMemory(', reclaim)
        self.assertIn('!ios_view_reclaimable( view, epoch )', reclaim)
        with self.assertRaises(ValueError): madeira_threads.apply_virtual(original + original)

    def test_dead_image_cleanup_preserves_live_images_shared_views_and_private_code(self):
        original = (ROOT / 'vendor/Madeira/build/ntdll-unix/virtual_ios.c').read_text()
        source = madeira_threads.apply_virtual(original)
        helpers = source[source.index('static void ios_view_created('):source.index('struct ios_session_futex_queue')]
        split = source.split('        new_view->ios_owner = view->ios_owner;', 1)[1].split('\n\n', 1)[0]
        fixture = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#define VPROT_READ 1
#define VPROT_WRITE 2
#define VPROT_EXEC 4
#define VPROT_WRITECOPY 8
#define VPROT_COMMITTED 0x20
#define VPROT_WRITEWATCH 0x40
#define VPROT_ARM64EC 0x100
#define SEC_FILE 0x800000
#define SEC_IMAGE 0x1000000
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
static const size_t page_size=4096;
struct file_view {void *base;size_t size;unsigned protect,ios_flags;void *ios_owner;uint64_t ios_epoch;unsigned ios_retired;};
static struct file_view views[320];
static unsigned view_count,deleted;
static uintptr_t owner=1,executable;
static uint64_t epoch=1;
static int locked=1;
static void *ios_jit_current_peb(void){return (void*)owner;}
static uint64_t ir_windows_session_epoch(void){return epoch;}
static unsigned get_page_vprot(void*p){return (uintptr_t)p==executable?VPROT_EXEC:0;}
static void ios_bigres_release(void*p){assert(locked && p);}
static void delete_view(struct file_view*v){assert(locked && v->base);v->base=0;deleted++;}
#define WINE_RB_FOR_EACH_ENTRY(v,tree,type,entry) for(unsigned idx=0;idx<view_count;idx++) if(((v)=&views[idx])->base)
''' + helpers + r'''
static struct file_view *make(void){
 struct file_view*v=&views[view_count++];assert(view_count<ARRAY_SIZE(views));
 *v=(struct file_view){.base=(void*)((uintptr_t)view_count*8192),.size=8192,.protect=VPROT_READ|VPROT_WRITE|VPROT_COMMITTED};
 ios_view_created(v);return v;
}
static void split_owner(struct file_view *new_view,struct file_view *view){
 new_view->ios_owner=view->ios_owner;
''' + split + r'''
}
int main(void){
 for(unsigned i=0;i<300;i++)make();
 owner=2;struct file_view*live=make();
 owner=1;struct file_view*code=make();code->protect|=VPROT_EXEC;
 struct file_view*upgraded=make();executable=(uintptr_t)upgraded->base+page_size;
 struct file_view*file=make();file->protect|=0x10000;
 struct file_view*system=make();system->protect|=0x200;
 struct file_view*placeholder=make();placeholder->protect|=0x400;
 struct file_view*quarantined=make();quarantined->ios_flags=4;
 struct file_view*image=make();image->protect=SEC_IMAGE|SEC_FILE|VPROT_COMMITTED|VPROT_READ|VPROT_EXEC|VPROT_WRITECOPY|VPROT_ARM64EC;
 struct file_view*system_image=make();system_image->protect=image->protect|0x200;
 struct file_view*shared_file=make();shared_file->protect|=SEC_FILE;
 struct file_view*quarantined_image=make();quarantined_image->protect=image->protect;quarantined_image->ios_flags=4;
 owner=2;struct file_view*live_image=make();live_image->protect=image->protect;owner=1;
 epoch=0;struct file_view*resident=make();epoch=1;
 owner=0;struct file_view*unknown=make();owner=1;
 ios_views_owner_died((void*)owner);assert(!live->ios_retired && code->ios_retired);
 assert(!ios_views_reclaim(1) && !deleted);
 epoch=2;struct file_view*current=make();ios_views_owner_died((void*)owner);
 assert(ios_views_reclaim(2)==301*8192 && deleted==301 && !image->base);
 assert(live->base && code->base && upgraded->base && file->base && system->base && placeholder->base && quarantined->base && resident->base && unknown->base && current->base);
 assert(system_image->base && shared_file->base && quarantined_image->base && live_image->base);
 struct file_view*reused=&views[0];reused->base=(void*)8192;owner=3;ios_view_created(reused);
 assert(reused->ios_owner==(void*)3 && reused->ios_epoch==2 && !reused->ios_retired);
 ios_views_owner_died((void*)1);assert(!reused->ios_retired && !ios_views_reclaim(2));
 struct file_view copy={0};split_owner(&copy,current);
 assert(copy.ios_owner==current->ios_owner && copy.ios_epoch==current->ios_epoch && copy.ios_retired==current->ios_retired);
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(path / 'main.c'),
                            '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)

    def test_reclaim_removes_dead_waiters_and_preserves_shared_teb_cache_and_live_wakes(self):
        native = (ROOT / 'vendor/Madeira/wine/dlls/ntdll/unix/sync.c').read_text()
        pe = (ROOT / 'vendor/Madeira/wine/dlls/ntdll/sync.c').read_text()
        madeira_threads.verify_futex_layout(native, pe)
        with self.assertRaises(ValueError): madeira_threads.verify_futex_layout(native, pe.replace('    DWORD tid;', '    DWORD changed;'))
        source = madeira_threads.apply_virtual((ROOT / 'vendor/Madeira/build/ntdll-unix/virtual_ios.c').read_text())
        cleanup = source[source.index('struct ios_session_futex_queue'):source.index('/* A later epoch proves')]
        resident = source[source.index('            if (!wow)\n            {'):source.index('            *p_teb_block = ptr;')]
        start = source.index('    if (*p_next_free_teb)')
        cached = source[start:source.index('\n    else\n    {', start)]
        structs = pe[pe.index('struct futex_entry\n'):pe.index('static struct futex_queue futex_queues[256];')]
        start = pe.index('void WINAPI RtlWakeAddressAll(')
        wake = pe[start:pe.index('\n}', start) + 2]
        fixture = r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "wine/list.h"
typedef int32_t LONG;
typedef uint32_t DWORD;
typedef uintptr_t ULONG_PTR;
typedef void *HANDLE;
#define WINAPI
#define TRACE(...) ((void)0)
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
static LONG InterlockedCompareExchange(LONG*p,LONG value,LONG expected){return __sync_val_compare_and_swap(p,expected,value);}
static void InterlockedExchange(LONG*p,LONG value){__sync_lock_test_and_set(p,value);}
static void InterlockedIncrement64(long long*p){++*p;}
static struct {long long woa_wake_all;} ios_xp_nt;
struct file_view {void *base;size_t size;uint64_t ios_epoch;int ios_retired;void *ios_owner;};
static struct file_view views[3];
static struct file_view *find_view(void*p,size_t size){
 for(unsigned i=0;i<ARRAY_SIZE(views);i++)
  if((uintptr_t)p>=(uintptr_t)views[i].base && size<=views[i].size && (uintptr_t)p-(uintptr_t)views[i].base<=views[i].size-size)return &views[i];
 return 0;
}
static int ios_view_reclaimable(const struct file_view*v,uint64_t epoch){return v->ios_owner && v->ios_retired && v->ios_epoch && v->ios_epoch<epoch;}
static void keep_shared_teb(void *ptr,size_t total,int wow){
''' + resident + r'''
}
static void *reuse_teb(void ***p_next_free_teb){
 void *ptr=0;const size_t teb_size=64;
''' + cached + r'''
 return ptr;
}
''' + structs + cleanup + r'''
static struct ios_session_futex_queue queues[256];
void *ios_get_shared_futex_queues(void){return queues;}
static struct futex_queue *get_futex_queue(const void*addr){return (void*)&queues[((uintptr_t)addr>>4)%256];}
static void spin_lock(LONG*p){assert(!InterlockedCompareExchange(p,-1,0));}
static void spin_unlock(LONG*p){InterlockedExchange(p,0);}
static unsigned alerts;
static void NtAlertMultipleThreadByThreadId(HANDLE*tids,unsigned count,void*a,void*b){
 (void)a;(void)b;for(unsigned i=0;i<count;i++){assert((uintptr_t)tids[i]==2 || (uintptr_t)tids[i]==3);alerts++;}
}
static void ios_futex_note_wake(const char*s,const void*a,const void*q,int n){(void)s;(void)a;(void)q;(void)n;}
''' + wake + r'''
int main(void){
 _Static_assert(sizeof(struct futex_entry)==sizeof(struct ios_session_futex_entry),"waiter layout");
 _Static_assert(sizeof(struct futex_queue)==sizeof(struct ios_session_futex_queue),"queue layout");
 size_t size=(size_t)sysconf(_SC_PAGESIZE);
 void*dead=mmap(0,size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);assert(dead!=MAP_FAILED);
 void*pool=mmap(0,size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);assert(pool!=MAP_FAILED);
 struct futex_entry*old=dead,live={0},current={0};
 int key=0;old->addr=live.addr=current.addr=&key;old->tid=1;live.tid=2;current.tid=3;
 views[0]=(struct file_view){dead,size,1,1,(void*)1};views[1]=(struct file_view){&current,sizeof(current),2,1,(void*)1};
 views[2]=(struct file_view){pool,size,1,1,(void*)1};
 keep_shared_teb(pool,size,1);assert(views[2].ios_owner==(void*)1); /* A WoW cache belongs to its own window. */
 keep_shared_teb(pool,size,0);assert(!views[2].ios_owner && !views[2].ios_epoch && !views[2].ios_retired);
 struct futex_queue*q=get_futex_queue(&key);list_init(&q->queue);
 list_add_tail(&q->queue,&old->entry);list_add_tail(&q->queue,&live.entry);list_add_tail(&q->queue,&current.entry);
 queues[0].lock=-1;assert(!ios_views_forget_waiters(2) && old->addr==&key);queues[0].lock=0;
 assert(ios_views_forget_waiters(2) && !old->addr && live.addr==&key && current.addr==&key);
 assert(!mprotect(dead,size,PROT_NONE));
 if(ios_view_reclaimable(&views[2],2))assert(!mprotect(pool,size,PROT_NONE));
 void **free_teb=pool;*(void**)pool=0;assert(reuse_teb(&free_teb)==pool && !free_teb);
 RtlWakeAddressAll(&key);assert(alerts==2 && !live.addr && !current.addr && list_empty(&q->queue));
 assert(!munmap(dead,size) && !munmap(pool,size));return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(ROOT / 'vendor/Madeira/wine/include'),
                            str(path / 'main.c'), '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)

    def test_window_callbacks_reuse_completed_process_slots_without_touching_live_owners(self):
        original = (ROOT / 'vendor/Madeira/build/win32u-unix/class_ios.c').read_text()
        source = madeira_threads.apply_class(original)
        arrays = source[source.index('static WINDOWPROC winproc_array['):source.index('static struct list class_list')]
        registry = source[source.index('struct ios_client_procs\n'):source.index('/* Redirect a builtin winproc_array')]
        start = source.index('static WINDOWPROC *find_winproc(')
        lookup = source[start:source.index('/* A 32-bit program', start)]
        start = source.index('static WINDOWPROC *get_winproc_ptr(')
        allocate = source[start:source.index('/**********************************************************************', start)]
        start = source.index('NTSTATUS WINAPI NtUserInitializeClientPfnArrays(')
        initialize = source[start:source.index('\n}', start) + 2]
        fixture = r'''
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
typedef uintptr_t WNDPROC, HINSTANCE, ULONG_PTR;
typedef unsigned UINT;
typedef int BOOL, NTSTATUS;
typedef WNDPROC ntuser_client_func_ptr[2];
typedef struct {WNDPROC procA,procW;} WINDOWPROC;
#define NTUSER_NB_PROCS 2
#define MAX_WINPROCS 5
#define WINPROC_HANDLE 0xffffu
#define WINPROC_PROC16 ((WINDOWPROC*)1)
#define WINAPI
#define LOWORD(x) ((x)&0xffff)
#define STATUS_SUCCESS 0
#define TRACE_(x) trace_noop
#define WARN_(x) trace_noop
#define trace_noop(...) ((void)0)
#define dprintf(...) ((void)0)
static struct {void *Peb;} teb;
#define NtCurrentTeb() (&teb)
static HINSTANCE user32_module;
static WNDPROC ios_winproc_handle_arg(WNDPROC p){return p;}
static void init_user(void){}
''' + arrays + registry + lookup + allocate + initialize + r'''
int main(void){
 ntuser_client_func_ptr procs[2]={{0x100,0},{0x200,0}};
 teb.Peb=(void*)1;NtUserInitializeClientPfnArrays(procs,procs,procs,0x1000);
 WINDOWPROC *parent=alloc_winproc_ptr(0x123,1);WNDPROC parent_handle=proc_to_handle(parent);
 assert(ios_client_procs_count==1 && user32_module==0x1000);
 for(uintptr_t g=2;g<302;g++){
  teb.Peb=(void*)g;NtUserInitializeClientPfnArrays(procs,procs,procs,g*0x1000);
  assert(ios_client_procs_count==2 && !get_winproc_ptr(parent_handle));
  WINDOWPROC *child=alloc_winproc_ptr(0x456,1);assert(child && child!=parent);
  WNDPROC handle=proc_to_handle(child);assert(get_winproc_ptr(handle)==child);
  assert(alloc_winproc_ptr(0x456,1)==child && winproc_used==4);
  ios_client_procs_release(teb.Peb);
  assert(!get_winproc_ptr(handle) && !ios_client_procs_reg[1].peb);
  assert(user32_module==0x1000 && !child->procA && !child->procW);
  teb.Peb=(void*)1;assert(get_winproc_ptr(parent_handle)==parent && parent->procA==0x123);
 }
 ios_client_procs_release((void*)1);assert(!user32_module && !winproc_array[0].procA);
 teb.Peb=(void*)302;NtUserInitializeClientPfnArrays(procs,procs,procs,0x9999);
 assert(user32_module==0x9999 && ios_client_procs_count==2);
 assert(alloc_winproc_ptr(0x789,1)==parent);return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                            str(path / 'main.c'), '-pthread', '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)
        server = madeira_threads.apply_process_server((ROOT / 'vendor/Madeira/build/ntdll-unix/server_ios.c').read_text())
        teardown = server.split('void process_exit_wrapper(', 1)[1]
        self.assertLess(teardown.index('ios_client_procs_release(dead_peb)'), teardown.index('ios_jit_reclaim_process( dead_peb )'))
        with self.assertRaises(ValueError): madeira_threads.apply_class(original + original)

    def test_user_cache_rejects_objects_from_an_old_handle_generation_or_process(self):
        original = (ROOT / 'vendor/Madeira/wine/dlls/win32u/window.c').read_text()
        source = madeira_threads.apply_window(original)
        cache = source[source.index('static void *client_objects['):source.index('\n#define SWP_AGG_NOGEOMETRYCHANGE')]
        start = source.index('void *get_user_handle_ptr(')
        lookup = source[start:source.index('\n/***********************************************************************', start)]
        start = source.index('void *next_thread_user_object(')
        iterator = source[start:source.index('\n/***********************************************************************', start)]
        fixture = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
typedef unsigned UINT, DWORD, ULONG;
typedef unsigned short WORD;
typedef void *HANDLE;
#define MAX_USER_HANDLES 4
#define OBJ_OTHER_PROCESS ((void*)1)
#define USER_HANDLE_TO_INDEX(h) ((((uintptr_t)(h)&0xffff)-0x20)>>1)
#define InterlockedExchangePointer(p,v) __atomic_exchange_n(p,v,__ATOMIC_SEQ_CST)
static DWORD current=1;
static int locked;
static void user_lock(void){locked++;}
static void user_unlock(void){assert(locked>0);locked--;}
static DWORD GetCurrentProcessId(void){return current;}
struct user_entry {ULONG pid,tid;};
static HANDLE live=(void*)0x10022;
static struct user_entry owner={1,10};
static int get_user_entry(HANDLE h,unsigned short type,struct user_entry*entry,HANDLE*full){
 (void)type;if(USER_HANDLE_TO_INDEX(h)!=1)return 0;*entry=owner;*full=live;return 1;}
static int get_user_entry_at(WORD i,unsigned short type,struct user_entry*entry,HANDLE*full){
 (void)type;if(i!=1)return 0;*entry=owner;*full=live;return 1;}
''' + cache + lookup + iterator + r'''
int main(void){
 int *old=malloc(sizeof(*old)),fresh=2;assert(old);cache_user_object(live,old);assert(!locked);
 assert(get_user_handle_ptr(live,1)==old && locked==1);user_unlock();
 free(old);live=(void*)0x20022;owner.pid=2;current=2;
 assert(get_user_handle_ptr(live,1)==OBJ_OTHER_PROCESS && !locked);
 HANDLE next=0;user_lock();assert(!next_thread_user_object(-1,&next,1));user_unlock();
 cache_user_object(live,&fresh);assert(get_user_handle_ptr(live,1)==&fresh);user_unlock();
 next=0;user_lock();assert(next_thread_user_object(-1,&next,1)==&fresh);user_unlock();
 owner.pid=3;current=3;assert(get_user_handle_ptr(live,1)==OBJ_OTHER_PROCESS && !locked);
 cache_user_object(live,&fresh);assert(get_user_handle_ptr(live,1)==&fresh);user_unlock();
 cache_user_object(live,0);assert(!get_user_handle_ptr(live,1) && !locked);return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-sign-compare',
                            str(path / 'main.c'), '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)
        with self.assertRaises(ValueError): madeira_threads.apply_window(original + original)

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
let slowRoot=folder.appendingPathComponent("slow-polls"),slowID=UUID()
let slow=IridiumMadeiraRuntime(root:slowRoot,nativeRunning:{true},beginFence:{true},drained:{true},clock:{observation.now()})
try slow.submit(slowID);slow.configureHost();try status(zero,phase:0,inRoot:slowRoot)
_=poll(slowID,from:slow)
try FileManager.default.removeItem(at:slowRoot.appendingPathComponent("request.bin"))
try status(slowID,phase:1,inRoot:slowRoot);_=poll(slowID,from:slow)
observation.advance(30)
if case .running=poll(slowID,from:slow){}else{fatalError("first background gap needs grace")}
var slowExpired=false
for _ in 0..<5 {
 observation.advance(5)
 if case .blocked=poll(slowID,from:slow){slowExpired=true;break}
}
precondition(slowExpired && slow.isBusy,"repeated slow polls must not renew a silent supervisor forever")
let recoveredRoot=folder.appendingPathComponent("fresh-heartbeat"),recoveredID=UUID()
let recovered=IridiumMadeiraRuntime(root:recoveredRoot,nativeRunning:{true},beginFence:{true},drained:{true},clock:{observation.now()})
try recovered.submit(recoveredID);recovered.configureHost();try status(zero,phase:0,inRoot:recoveredRoot)
_=poll(recoveredID,from:recovered)
try FileManager.default.removeItem(at:recoveredRoot.appendingPathComponent("request.bin"))
try status(recoveredID,phase:1,inRoot:recoveredRoot);_=poll(recoveredID,from:recovered)
for i in 0..<3 {
 observation.advance(30)
 if case .running=poll(recoveredID,from:recovered){}else{fatalError("real background gap poisoned a recovering host")}
 try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:Double(i))],ofItemAtPath:recoveredRoot.appendingPathComponent("status.bin").path)
 if case .running=poll(recoveredID,from:recovered){}else{fatalError("new heartbeat must restore background grace")}
}
precondition(!recovered.requiresRestart)
let occupiedRoot=folder.appendingPathComponent("occupied"),occupiedID=UUID()
let occupied=IridiumMadeiraRuntime(root:occupiedRoot,nativeRunning:{true},beginFence:{fatalError("unpublished request advanced the session epoch")},drained:{true},clock:{observation.now()})
try occupied.submit(occupiedID);occupied.configureHost();try status(zero,phase:0,inRoot:occupiedRoot)
try Data("pending request".utf8).write(to:occupiedRoot.appendingPathComponent("request.bin"))
if case .blocked=poll(occupiedID,from:occupied){}else{fatalError("overwrote a pending request")}
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

    def test_thread_slots_refuse_live_or_uncertain_owners_and_never_fall_back(self):
        bridge = ROOT / 'iridium/apps/ios/RuntimeBridge'
        native = (bridge / 'IRWindowsThreads.c').read_text()
        allocator = native[native.index('int ir_windows_thread_slot(void)'):native.index('static void *guest_start(')]
        fixture = r"""
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#define IR_WINDOWS_THREAD_SLOTS 3
#define MACH_PORT_NULL 0
#define KERN_SUCCESS 0
#define MACH_PORT_TYPE_DEAD_NAME 1
typedef unsigned mach_port_t;
typedef unsigned mach_port_type_t;
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static unsigned current=1,types[2000],failed,refs[2000];
static unsigned mach_task_self(void){return 1;}
static unsigned mach_thread_self(void){refs[current]++;return current;}
static int mach_port_deallocate(unsigned task,unsigned port){(void)task;assert(refs[port]);refs[port]--;return 0;}
static int mach_port_type(unsigned task,unsigned port,unsigned *type){(void)task;if(port==failed)return 1;*type=types[port];return 0;}
""" + allocator + r"""
int main(void){
 assert(ir_windows_thread_slot()==0 && refs[1]==1);
 assert(ir_windows_thread_slot()==0 && refs[1]==1);
 current=2;assert(ir_windows_thread_slot()==1);
 current=3;assert(ir_windows_thread_slot()==2);
 current=4;assert(ir_windows_thread_slot()==-1 && !refs[4]);
 failed=2;types[2]=MACH_PORT_TYPE_DEAD_NAME;
 assert(ir_windows_thread_slot()==-1 && !refs[4]);failed=0;
 for(current=4;current<1500;current++){
  unsigned old=current==4?2:current-1;types[old]=MACH_PORT_TYPE_DEAD_NAME;
  assert(ir_windows_thread_slot()==1 && !refs[old]);
  assert(ir_windows_thread_slot()==1 && refs[current]==1);
  assert(refs[1]==1 && refs[3]==1);
 }
 return 0;
}
"""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder); (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(path / 'main.c'),
                            '-pthread', '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=10)
        signal = (ROOT / 'vendor/Madeira/build/ntdll-unix/signal_arm64_ios.c').read_text()
        adapted = madeira_threads.apply_signal(signal, bridge / 'IRWindowsThreads.h')
        lookup = adapted[adapted.index('static int ios_lookup_thread('):adapted.index('/* ml405', adapted.index('static int ios_lookup_thread('))]
        self.assertNotIn('ios_thread_registry[0]', lookup)
        self.assertIn('int idx = ios_my_slot;', adapted)
        self.assertIn('if (ios_my_slot < 0) abort_thread( STATUS_NO_MEMORY );', adapted)
        virtual = madeira_threads.apply_virtual((ROOT / 'vendor/Madeira/build/ntdll-unix/virtual_ios.c').read_text())
        self.assertIn('int slot = ir_windows_thread_slot();', virtual)
        self.assertNotIn('ios_jit_next_slot', virtual)
        with self.assertRaises(ValueError):
            madeira_threads.apply_signal(signal.replace('#define IOS_MAX_WINE_THREADS 512', '#define IOS_MAX_WINE_THREADS 513'), bridge / 'IRWindowsThreads.h')

    @unittest.skipUnless(os.uname().sysname == 'Darwin', 'Mach thread APIs required')
    def test_thread_slots_and_exception_records_reuse_after_kernel_thread_exit(self):
        bridge = ROOT / 'iridium/apps/ios/RuntimeBridge'
        signal = madeira_threads.apply_signal((ROOT / 'vendor/Madeira/build/ntdll-unix/signal_arm64_ios.c').read_text(), bridge / 'IRWindowsThreads.h')
        layout = signal[signal.index('struct ios_thread_entry {'):signal.index('/* Exact-match registry probe')]
        lookup = signal[signal.index('static int ios_lookup_thread('):signal.index('\n/*', signal.index('static int ios_lookup_thread('))]
        setup = signal[signal.index('    int idx = ios_my_slot;'):signal.index('    /* Set exception port for this thread')]
        fixture = r"""
#include "IRWindowsThreads.h"
#include <assert.h>
#include <mach/mach.h>
#include <stdatomic.h>
#include <stdlib.h>
#define IOS_MAX_WINE_THREADS IR_WINDOWS_THREAD_SLOTS
#define STATUS_NO_MEMORY 1
static _Thread_local int ios_my_slot;
static void abort_thread(int status){(void)status;abort();}
void ir_windows_reclaim_completed(void){}
""" + layout + lookup + '\nstatic void register_thread(thread_t pe_thread,uintptr_t teb,void *trampoline){\n' + setup + r"""
}
static void *worker(void *value){
 ios_my_slot=ir_windows_thread_slot();assert(ios_my_slot>0 && ios_my_slot<64);
 assert(ios_my_slot==ir_windows_thread_slot());
 thread_t port=mach_thread_self();register_thread(port,(uintptr_t)value,value);
 uintptr_t teb;void *tramp;assert(ios_lookup_thread(port,&teb,&tramp));
 assert(teb==(uintptr_t)value && tramp==value);mach_port_deallocate(mach_task_self(),port);return 0;
}
int main(void){
 assert(ir_windows_thread_slot()==0);
 register_thread(pthread_mach_thread_np(pthread_self()),1,(void*)1);
 for(uintptr_t i=2;i<1602;i++){
  pthread_t t;assert(!pthread_create(&t,0,worker,(void*)i));assert(!pthread_join(t,0));
 }
 pthread_t group[32];for(uintptr_t i=0;i<32;i++)assert(!pthread_create(&group[i],0,worker,(void*)(i+2000)));
 for(unsigned i=0;i<32;i++)assert(!pthread_join(group[i],0));
 uintptr_t teb=1;void *tramp=(void*)1;
 assert(!ios_lookup_thread(MACH_PORT_DEAD,&teb,&tramp) && !teb && !tramp);
 assert(ios_thread_count<64);return 0;
}
"""
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder); (path / 'main.c').write_text(fixture)
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-I', str(bridge),
                            str(path / 'main.c'), str(bridge / 'IRWindowsThreads.c'), '-pthread',
                            '-o', str(path / 'check')], check=True, timeout=30)
            subprocess.run([str(path / 'check')], check=True, timeout=30)

    @unittest.skipUnless(os.uname().sysname == 'Darwin', 'Mach thread APIs required')
    def test_guest_thread_exit_destructors_and_retained_host_services(self):
        fixture = r'''
#include "IRWindowsThreads.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>
static atomic_bool entered,stop,host_stop,destructing,release_destructor;
static uint64_t cleaned;
void ir_windows_reclaim_completed(void){assert(ir_windows_threads_drained());assert(ir_windows_session_epoch()==++cleaned);}
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
 assert(ir_windows_session_epoch()==0);
 assert(!ir_windows_pthread_create(&baseline,0,host,0));
 assert(!ir_windows_threads_drained());assert(ir_windows_threads_begin());wait_drain();
 assert(ir_windows_session_epoch()==1);
 assert(!pthread_create(&system_thread,0,host,0));wait_drain();
 for(int mode=0;mode<100;++mode){
  atomic_store(&entered,false);atomic_store(&stop,false);atomic_store(&destructing,false);atomic_store(&release_destructor,false);
  assert(ir_windows_threads_begin());
  uint64_t epoch=ir_windows_session_epoch();assert(epoch==(uint64_t)mode+2);
  pthread_attr_t attr;assert(!pthread_attr_init(&attr));
  bool detached=mode%2; if(detached)assert(!pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED));
  assert(!ir_windows_pthread_create(&thread,&attr,worker,(void*)(long)(mode%3)));assert(!pthread_attr_destroy(&attr));
  assert(!ir_windows_threads_drained());assert(!ir_windows_threads_begin());assert(ir_windows_session_epoch()==epoch);wait_for(&entered);
  atomic_store(&stop,true);wait_for(&destructing);
  assert(!ir_windows_threads_drained());assert(!ir_windows_threads_begin());assert(ir_windows_session_epoch()==epoch);atomic_store(&release_destructor,true);
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
void ir_windows_reclaim_completed(void){assert(ir_windows_threads_drained());}
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
