"""Execute the generated drain method with delayed completion and replacement loops."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import ppsspp_native_overlay as overlay
from test_native_psp_lifecycle import method

ROOT = Path(__file__).resolve().parents[1]


class RendererGenerationTests(unittest.TestCase):
    def test_retired_owner_and_old_loop_never_mutate_replacement(self):
        if not shutil.which('clang++') or not Path('/Applications/Xcode.app').exists(): self.skipTest('Apple Foundation required')
        for name in ('ios/ViewController.mm', 'ios/ViewControllerMetal.mm'):
            generated = overlay.apply(name, (ROOT / 'vendor/PPSSPP' / name).read_text())
            drain = method(generated, '- (void)iridiumAwaitRenderLoop:')
            final_drain = method(generated, '- (void)iridiumDrainCompletedRenderLoop') if name.endswith('/ViewController.mm') else '- (void)iridiumDrainCompletedRenderLoop {}'
            code = r'''#import <Foundation/Foundation.h>
#include <atomic>
#include <stdio.h>
#include <stdlib.h>
#include <cassert>
static std::atomic<bool> exitRenderLoop, iridiumLoopStarted, renderLoopRunning;
static struct { bool live; unsigned joins; bool joinable(){return live;} void join(){live=false;joins++;} } g_renderLoopThread;
struct FakeGraphics {unsigned calls=0;bool ThreadFrame(bool wait){assert(!wait && !g_renderLoopThread.joinable());return ++calls<3;}};
@interface EAGLContext : NSObject
+ (BOOL)setCurrentContext:(id)context;
@end
@implementation EAGLContext
+ (BOOL)setCurrentContext:(id)context {return context!=nil;}
@end
static NSMutableArray *pending;
static void later(void (^block)(void)) { [pending addObject:[block copy]]; }
#define dispatch_after(time, queue, block) later(block)
@interface Link : NSObject
@property BOOL paused;
@end
@implementation Link @end
@interface Renderer : NSObject { @public FakeGraphics *graphicsContext; }
@property uint64_t iridiumRenderGeneration;
@property Link *displayLink;
@property id glContext;
- (void)iridiumAwaitRenderLoop:(uint64_t)owner completion:(void (^)(void))completion;
- (void)iridiumDrainCompletedRenderLoop;
@end
static Renderer *current;
static bool ir_native_psp_is_current_player(void *pointer) {return pointer == (__bridge void *)current;}
@implementation Renderer
DRAIN
FINAL_DRAIN
@end
static void require(bool ok,const char *why) { if(!ok){fprintf(stderr,"FAIL %s\n",why);exit(1);} }
static void deliver(void) { void (^b)(void)=pending.firstObject; [pending removeObjectAtIndex:0]; b(); }
int main(void) { @autoreleasepool {
    pending=[NSMutableArray array]; __block unsigned completed=0;
    Renderer *old=[Renderer new]; old.iridiumRenderGeneration=1; current=old;
    FakeGraphics graphics;old->graphicsContext=&graphics;old.glContext=[NSObject new];
    iridiumLoopStarted=true;renderLoopRunning=true;g_renderLoopThread.live=true;exitRenderLoop=true;
    [old iridiumAwaitRenderLoop:1 completion:^{completed++;}];
    require(pending.count==1,"drain is delayed while running");
    Renderer *replacement=[Renderer new]; replacement.iridiumRenderGeneration=1; current=replacement;
    deliver(); require(completed==0 && g_renderLoopThread.live && exitRenderLoop && g_renderLoopThread.joins==0,"retired view cannot touch replacement thread");

    current=old; old.iridiumRenderGeneration=2;
    [old iridiumAwaitRenderLoop:1 completion:^{completed++;}];
    require(pending.count==0 && completed==0 && exitRenderLoop,"old generation of current view is discarded");

    old.iridiumRenderGeneration=3;renderLoopRunning=true;
    [old iridiumAwaitRenderLoop:3 completion:^{
        completed++; old.iridiumRenderGeneration=4; g_renderLoopThread.live=true;
        renderLoopRunning=true; exitRenderLoop=true;
    }];
    [old iridiumAwaitRenderLoop:3 completion:^{completed++;}];
    require(pending.count==2,"two same-loop waiters queued");
    renderLoopRunning=false; deliver(); deliver();
    require(completed==1 && g_renderLoopThread.joins==1 && g_renderLoopThread.live && exitRenderLoop,"late second waiter cannot join or clear replacement loop");
    require(graphics.calls==EXPECTED_DRAINS,"GL final queue drained completely after producer joined, once per owned stop");
    puts("PASS retired-owner, replaced-loop and multiple-waiter orderings");return 0;
} }
'''.replace('FINAL_DRAIN', final_drain).replace('EXPECTED_DRAINS','3' if name.endswith('/ViewController.mm') else '0').replace('DRAIN\n', drain+'\n')
            with tempfile.TemporaryDirectory() as folder:
                root=Path(folder); source=root/'check.mm'; source.write_text(code); binary=root/'check'
                result=subprocess.run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation',str(source),'-o',str(binary)],capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('PASS retired-owner',result.stdout)


if __name__ == '__main__': unittest.main()
