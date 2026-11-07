"""Exercise native graphics references after a Windows pseudo-process exits."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
import madeira_threads

ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / 'iridium/apps/ios/RuntimeBridge/IRWindowsMetal.h'


class WindowsMetalTests(unittest.TestCase):
    def test_only_vertex_interpolants_have_defined_finite_outputs(self):
        source = (ROOT / 'vendor/Madeira/dxmt/src/airconv/dxbc_signature.cpp').read_text()
        generated = madeira_threads.apply_vertex_outputs(source)
        original = 'ctx.epilogue >> pop_output_reg(reg, mask, assigned_index);'
        filled = original.replace('pop_output_reg(', 'ir_pop_vertex_output(')
        self.assertEqual(generated.count(original), source.count(original) - 1)
        self.assertEqual(generated.count(filled), source.count(filled) + 1)
        self.assertEqual(generated[generated.index('void handle_signature_ps('):],
                         source[source.index('void handle_signature_ps('):])
        with self.assertRaises(ValueError):
            madeira_threads.apply_vertex_outputs(source.replace('.user = sig.fullSemanticString(),', '.user = "changed",'))

    def test_owned_api_adaptation_and_pin_changes(self):
        source = (ROOT / 'vendor/Madeira/dxmt/src/winemetal/unix/winemetal_unix.c').read_text()
        generated = madeira_threads.apply_metal(source, HEADER)
        self.assertIn('_ir_original_MTLDevice_newGeometryEmulationPipelineState(obj)', generated)
        self.assertIn('ir_metal_acquire((id)params->ret_pso)', generated)
        self.assertIn('ir_metal_acquire(*obj)', generated)
        self.assertIn('ir_metal_release(*obj)', generated)
        for changed in [source.replace('_MTLDevice_newBuffer(void', '_MTLDevice_newBufferV2(void', 1),
                        source.replace('  [*obj release];', '  [(id)*obj release];', 1),
                        source + '\nstatic NTSTATUS\n_MTLDevice_newOther(void *obj) {\n}\n']:
            with self.assertRaises(ValueError): madeira_threads.apply_metal(changed, HEADER)

    @unittest.skipUnless(os.uname().sysname == 'Darwin', 'Objective-C runtime required')
    def test_balanced_shared_retired_and_repeated_sessions(self):
        fixture = r'''
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
static bool allocation_fail;
static void *checked_calloc(size_t count,size_t size) { return allocation_fail ? NULL : calloc(count,size); }
#define calloc checked_calloc
static _Thread_local void *owner;
static _Atomic uint64_t epoch;
void *ios_jit_current_peb(void) { return owner; }
uint64_t ir_windows_session_epoch(void) { return epoch; }
void ir_windows_events_owner_died(void *value) { (void)value; }
void ir_windows_events_reclaim(uint64_t value) { (void)value; }
#include "IRWindowsMetal.h"
#undef calloc
static unsigned destroyed;
@interface Probe : NSObject @end
@implementation Probe
- (void)dealloc { ir_metal_release(nil); destroyed++; [super dealloc]; }
@end
@interface Command : NSObject { void (^completion)(id<MTLCommandBuffer>); @public bool delayed; }
- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))handler;
- (void)commit;
@end
@implementation Command
- (void)addCompletedHandler:(void (^)(id<MTLCommandBuffer>))handler { completion = [handler copy]; }
- (void)commit {
    if (delayed) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6*NSEC_PER_SEC),
        dispatch_get_global_queue(0,0), ^{ completion((id<MTLCommandBuffer>)self); });
    else completion((id<MTLCommandBuffer>)self);
}
- (void)dealloc { [completion release]; [super dealloc]; }
@end
static id make(void) { id p = [[Probe alloc] init]; ir_metal_acquire(p); return p; }
static void release(id p) { ir_metal_release(p); [p release]; }
static void *copies(void *p) {
    owner = (void *)40;
    for (int i=0; i<10000; i++) {
        [(id)p retain]; ir_metal_acquire((id)p); release((id)p);
    }
    return NULL;
}
int main(void) {
 @autoreleasepool {
    epoch=1; owner=(void *)1;
    id p=make(); [p retain]; ir_metal_acquire(p); release(p);
    ir_windows_metal_owner_died(owner);
    assert(ir_windows_metal_reclaim(1) && destroyed==0);
    epoch=2; assert(ir_windows_metal_reclaim(2) && destroyed==1);
    owner=(void *)2; id live=make(); epoch=3;
    assert(ir_windows_metal_reclaim(3) && destroyed==1);
    ir_windows_metal_owner_died(owner);
    assert(ir_windows_metal_reclaim(3) && destroyed==2);
    (void)live;
    owner=(void *)3; id shared=make(); [shared retain]; owner=(void *)4;
    ir_metal_acquire(shared);
    ir_windows_metal_owner_died((void *)3); ir_windows_metal_owner_died((void *)4);
    epoch=4; assert(!ir_windows_metal_reclaim(4) && destroyed==2);
    release(shared); release(shared); assert(destroyed==3);
    assert(ir_windows_metal_reclaim(4));
    owner=NULL; id unknown=make(); epoch=5;
    assert(ir_windows_metal_reclaim(5) && destroyed==3); release(unknown);
    owner=(void *)5;
    NSAutoreleasePool *pool=[[NSAutoreleasePool alloc] init];
    id borrowed=[[[Probe alloc] init] autorelease];
    [borrowed retain]; ir_metal_acquire(borrowed); [pool drain];
    ir_windows_metal_owner_died(owner); epoch=6;
    assert(ir_windows_metal_reclaim(6) && destroyed==5);
    owner=(void *)6; id balanced=make(); release(balanced);
    ir_windows_metal_owner_died(owner); epoch=7;
    assert(ir_windows_metal_reclaim(7) && destroyed==6);
    owner=(void *)7; make();
    Command *cmd=[[[Command alloc] init] autorelease]; cmd->delayed=true;
    ir_metal_submit((id<MTLCommandBuffer>)cmd); [cmd commit];
    Command *finished=[[[Command alloc] init] autorelease];
    ir_metal_submit((id<MTLCommandBuffer>)finished); [finished commit];
    ir_windows_metal_owner_died(owner); epoch=8;
    double start=CFAbsoluteTimeGetCurrent();
    assert(!ir_windows_metal_reclaim(8) && destroyed==6);
    double elapsed=CFAbsoluteTimeGetCurrent()-start; assert(elapsed>=4.9 && elapsed<5.9);
    [NSThread sleepForTimeInterval:1.2];
    assert(ir_windows_metal_reclaim(8) && destroyed==7);
    owner=(void *)8; id normal=make(); release(normal); assert(destroyed==8);
    ir_windows_metal_owner_died(owner); epoch=9;
    assert(ir_windows_metal_reclaim(9) && destroyed==8);
    owner=(void *)40; id parallel=make(); pthread_t threads[4];
    for (int i=0;i<4;i++) assert(!pthread_create(&threads[i], NULL, copies, parallel));
    for (int i=0;i<4;i++) assert(!pthread_join(threads[i], NULL));
    ir_windows_metal_owner_died(owner); epoch=10;
    assert(ir_windows_metal_reclaim(10) && destroyed==9);
    for (int run=0;run<300;run++) {
        owner=(void *)(uintptr_t)(100+run);
        for (int i=0;i<100;i++) { id obj=make(); [obj retain]; ir_metal_acquire(obj); }
        ir_windows_metal_owner_died(owner); epoch++;
        assert(ir_windows_metal_reclaim(epoch) && destroyed==(unsigned)(9+(run+1)*100));
    }
    for (int i=0;i<1024;i++) assert(!ir_metal_references[i]);
    owner=(void *)900; allocation_fail=true; id untracked=make();
    ir_windows_metal_owner_died(owner); epoch++;
    assert(!ir_windows_metal_reclaim(epoch) && ir_metal_untracked);
    release(untracked);
 }
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            (path / 'check.m').write_text(fixture)
            subprocess.run(['xcrun', 'clang', '-std=c11', '-fblocks', '-fno-objc-arc',
                            '-Wall', '-Wextra', '-Werror', '-framework', 'Foundation', '-framework', 'Metal',
                            '-I', str(HEADER.parent), str(path / 'check.m'), '-o', str(path / 'check')],
                           check=True, timeout=45)
            subprocess.run([str(path / 'check')], check=True, timeout=30, capture_output=True)
