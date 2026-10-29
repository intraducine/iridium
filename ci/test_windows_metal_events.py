"""Run the actual Metal listener adapter with delayed and abandoned callbacks."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
import madeira_threads

ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / 'iridium/apps/ios/RuntimeBridge/IRWindowsMetalEvents.h'
FIXTURE = r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreFoundation/CFRunLoop.h>
#include <pthread.h>
#include <stdatomic.h>
#include <assert.h>
#include <stdint.h>
typedef int NTSTATUS;
typedef uint64_t obj_handle_t;
#define STATUS_SUCCESS 0
struct unixcall_generic_obj_ret { obj_handle_t ret; };
struct unixcall_generic_obj_noret { obj_handle_t handle; };
struct unixcall_mtlsharedevent_setevent {
 obj_handle_t shared_event,shared_event_listener,event_handle; uint64_t value;
};
static _Thread_local void *owner;
static uint64_t epoch=1;
static atomic_uint signals;
static atomic_bool exit_on_event;
static dispatch_semaphore_t delivered;
void *ios_jit_current_peb(void) { return owner; }
uint64_t ir_windows_session_epoch(void) { return epoch; }
NTSTATUS NtSetEvent(void *handle,void *previous) {
 (void)previous; assert(owner==(void*)1 && handle==(void*)1);
 if(atomic_exchange(&exit_on_event,false)) pthread_exit(NULL);
 atomic_fetch_add(&signals,1);dispatch_semaphore_signal(delivered);return 0;
}
#include "events-under-test.h"
@interface FakeEvent : NSObject { void (^callback)(id<MTLSharedEvent>,uint64_t); }
- (void)notifyListener:(MTLSharedEventListener*)listener atValue:(uint64_t)value
 block:(void (^)(id<MTLSharedEvent>,uint64_t))block;
- (void)fire;
@end
@implementation FakeEvent
- (void)notifyListener:(MTLSharedEventListener*)listener atValue:(uint64_t)value
 block:(void (^)(id<MTLSharedEvent>,uint64_t))block {
 (void)listener;(void)value;[callback release];callback=[block copy];
}
- (void)fire { assert(callback);callback((id<MTLSharedEvent>)self,1); }
- (void)dealloc { [callback release];[super dealloc]; }
@end
static obj_handle_t create(void) {
 struct unixcall_generic_obj_ret p={0};assert(!_SharedEventListener_create(&p));assert(p.ret);return p.ret;
}
static void destroy(obj_handle_t handle) {
 struct unixcall_generic_obj_noret p={handle};assert(!_SharedEventListener_destroy(&p));
}
static void subscribe(obj_handle_t handle,FakeEvent *event) {
 struct unixcall_mtlsharedevent_setevent p={(obj_handle_t)event,handle,1,1};
 assert(!_MTLSharedEvent_setWin32EventAtValue(&p));
}
static void *run(void *handle) {
 owner=(void*)1;
 struct unixcall_generic_obj_noret p={(obj_handle_t)handle};
 assert(!_SharedEventListener_start(&p));return NULL;
}
static void wait_event(void) {
 assert(!dispatch_semaphore_wait(delivered,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)));
}
#if IR_NEW_EVENTS
static void *notify_many(void *pointer) {
 for(unsigned i=0;i<500;i++)[(FakeEvent*)pointer fire];
 return NULL;
}
#endif
int main(void) {
 @autoreleasepool {
 owner=(void*)1;delivered=dispatch_semaphore_create(0);
 FakeEvent *ready=[[FakeEvent alloc]init],*late=[[FakeEvent alloc]init];
 obj_handle_t handle=create();subscribe(handle,ready);subscribe(handle,late);
 pthread_t thread;assert(!pthread_create(&thread,NULL,run,(void*)handle));
 [ready fire];wait_event();destroy(handle);assert(!pthread_join(thread,NULL));
 unsigned before=atomic_load(&signals);
 [late fire]; /* The upstream implementation dereferences its freed listener here. */
 assert(atomic_load(&signals)==before);
 [ready release];[late release];
#if IR_NEW_EVENTS
 assert(![ir_event_listeners count]);
 handle=create();destroy(handle);run((void*)handle);destroy(handle);
 struct unixcall_mtlsharedevent_setevent invalid={0,handle,1,1};
 assert(_MTLSharedEvent_setWin32EventAtValue(&invalid)==(NTSTATUS)0xc0000008);
 assert(![ir_event_listeners count]);
 for(unsigned i=0;i<100;i++) {
  @autoreleasepool {
   obj_handle_t next=create();assert(next>handle);handle=next;
   ready=[[FakeEvent alloc]init];late=[[FakeEvent alloc]init];
   subscribe(handle,ready);subscribe(handle,late);
   [ready fire]; /* Notification before the guest run-loop thread starts. */
   assert(!pthread_create(&thread,NULL,run,(void*)handle));wait_event();
   owner=(void*)2;destroy(handle);owner=(void*)1;
   assert([ir_event_listeners count]==1);
   if(i%3==0) {
    ir_windows_events_owner_died(owner);assert(!pthread_join(thread,NULL));
    ir_windows_events_reclaim(epoch);assert([ir_event_listeners count]==1);
    ir_windows_events_reclaim(++epoch);
   } else if(i%3==1) {
    atomic_store(&exit_on_event,true);[ready fire];
    assert(!pthread_join(thread,NULL));destroy(handle);
   } else { destroy(handle);assert(!pthread_join(thread,NULL)); }
   before=atomic_load(&signals);[late fire];assert(atomic_load(&signals)==before);
   assert(![ir_event_listeners count]);[ready release];[late release];
  }
 }
 handle=create();ready=[[FakeEvent alloc]init];late=[[FakeEvent alloc]init];
 subscribe(handle,ready);subscribe(handle,late);
 assert(!pthread_create(&thread,NULL,run,(void*)handle));[ready fire];wait_event();
 pthread_t senders[4];
 for(unsigned i=0;i<4;i++)assert(!pthread_create(&senders[i],NULL,notify_many,late));
 destroy(handle);
 for(unsigned i=0;i<4;i++)assert(!pthread_join(senders[i],NULL));
 assert(!pthread_join(thread,NULL));before=atomic_load(&signals);
 [late fire];assert(atomic_load(&signals)==before && ![ir_event_listeners count]);
 [ready release];[late release];
#endif
 }
 return 0;
}
'''


class WindowsMetalEventTests(unittest.TestCase):
    def test_listener_adaptation_rejects_api_drift(self):
        original = (ROOT / 'vendor/Madeira/dxmt/src/winemetal/unix/winemetal_unix.c').read_text()
        metal = HEADER.with_name('IRWindowsMetal.h')
        self.assertIn('#include "' + str(HEADER) + '"', madeira_threads.apply_metal(original, metal))
        changed = original.replace('_SharedEventListener_destroy(void *obj)', '_OtherListener_destroy(void *obj)', 1)
        with self.assertRaises(ValueError):
            madeira_threads.apply_metal(changed, metal)

    @unittest.skipUnless(os.uname().sysname == 'Darwin', 'Apple run loops and Metal required')
    def test_delayed_callbacks_early_destroy_retirement_and_thread_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'events-under-test.h').write_bytes(HEADER.read_bytes())
            (root / 'events.m').write_text(FIXTURE)
            subprocess.run(['xcrun', 'clang', '-std=c11', '-fblocks', '-fno-objc-arc',
                            '-Wall', '-Wextra', '-Werror', '-DIR_NEW_EVENTS=1',
                            '-fsanitize=address,undefined', '-framework', 'Foundation', '-framework', 'Metal',
                            str(root / 'events.m'), '-o', str(root / 'events')], check=True, timeout=45)
            subprocess.run([str(root / 'events')], check=True, timeout=30, capture_output=True)
