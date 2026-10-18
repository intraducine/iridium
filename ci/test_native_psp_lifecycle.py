"""Execute production pause methods with a deterministic, delayed render drain."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'iridium/apps/ios/RuntimeBridge/IRPPSSPPNative.mm'


def method(source, signature):
    start = source.index(signature)
    end = source.index('\n}', start) + 2
    return source[start:end]


def run_lifecycle(source, historical=False):
    methods = method(source, '- (void)setPlaying:(BOOL)playing {')
    if '- (BOOL)canPlay {' in source:
        methods = method(source, '- (BOOL)canPlay {') + '\n' + methods
    methods += '\n' + method(source, '- (void)closePlayer {')
    stop = method(source, 'void ir_native_psp_stop(void) {')
    harness = r'''#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <atomic>
enum { UIApplicationStateActive, UIApplicationStateInactive };
@interface UIApplication : NSObject
@property int applicationState;
+ (UIApplication *)sharedApplication;
@end
@implementation UIApplication
+ (UIApplication *)sharedApplication { static UIApplication *app; if (!app) app=[UIApplication new]; return app; }
@end
static struct { bool bEnableSound; } g_Config = {true};
static bool rendererFailed;
static std::atomic<bool> acceptingCallbacks;
static std::atomic<uint64_t> generation;
static unsigned audioStarts, audioStops, assertions;
static void iOSCoreAudioInit(void) { audioStarts++; }
static void iOSCoreAudioShutdown(void) { audioStops++; }
static void require(bool condition,const char *message) {
    assertions++;
    if (!condition) { fprintf(stderr,"FAIL %s\n",message); exit(1); }
}
@interface Player : NSObject
@property unsigned starts;
@property NSMutableArray *drains;
- (void)didBecomeActive;
- (void)iridiumStopRenderLoop:(void (^)(void))completion;
- (void)drain;
@end
@implementation Player
- (instancetype)init { self=[super init]; self.drains=[NSMutableArray array]; return self; }
- (void)didBecomeActive { self.starts++; }
- (void)iridiumStopRenderLoop:(void (^)(void))completion { [self.drains addObject:[completion copy]]; }
- (void)drain { void (^completion)(void)=self.drains.firstObject; [self.drains removeObjectAtIndex:0]; completion(); }
@end
@interface IRPPSSPPContainer : NSObject
@property Player *player;
@property BOOL active, pausing, closing, wantsActive, interrupted, initialized, appActive;
@property BOOL restarting;
@property unsigned closes;
- (void)setPlaying:(BOOL)playing;
- (BOOL)canPlay;
- (void)finishClose;
- (void)closePlayer;
@end
static IRPPSSPPContainer *container;
// Execute an already-delivered main-queue stop during simulated worker cleanup.
#define dispatch_async(queue, block) block()
STOP
@implementation IRPPSSPPContainer
METHODS
- (void)finishClose { self.closes++; }
@end
static IRPPSSPPContainer *owner(void) {
    UIApplication.sharedApplication.applicationState=UIApplicationStateActive;
    IRPPSSPPContainer *o=[IRPPSSPPContainer new]; o.player=[Player new];
    o.active=YES; o.wantsActive=YES; o.initialized=YES; o.appActive=YES;
    audioStarts=audioStops=0; return o;
}
int main(void) { @autoreleasepool {
    IRPPSSPPContainer *o=owner(); o.appActive=NO;
    UIApplication.sharedApplication.applicationState=UIApplicationStateInactive;
    [o setPlaying:NO]; require(o.pausing && !o.active,"pause is asynchronous"); [o.player drain];
    if (HISTORICAL) {
        require(o.active && o.player.starts==1 && audioStarts==1,"reproduce inactive auto-resume");
        container=owner(); container.active=NO; container.closing=YES; container.restarting=YES;
        ir_native_psp_stop();
        require(container.restarting && container.wantsActive && container.closes==0,"reproduce stop failing to cancel restart during cleanup");
        puts("BASELINE reproduced: rendering/audio resumed while inactive; stop did not cancel pending restart");
        return 0;
    }
    require(!o.active && !o.pausing && o.player.starts==0 && audioStarts==0,"stay stopped while inactive");
    o.appActive=YES; UIApplication.sharedApplication.applicationState=UIApplicationStateActive;
    [o setPlaying:YES]; require(o.active && o.player.starts==1 && audioStarts==1,"resume on foreground with play intent");

    o=owner(); o.appActive=NO; // WillResign can arrive before shared applicationState changes.
    [o setPlaying:NO]; [o.player drain];
    require(!o.active && o.player.starts==0,"resign notification blocks an early drain completion");

    o=owner(); o.interrupted=YES; [o setPlaying:NO]; [o.player drain];
    require(!o.active && o.player.starts==0 && audioStarts==0,"stay stopped during audio interruption");
    [o setPlaying:YES]; require(!o.active,"resume command cannot override interruption");
    o.interrupted=NO; [o setPlaying:YES]; require(o.active,"interruption end may resume play intent");

    o=owner(); [o setPlaying:NO]; o.wantsActive=NO; [o.player drain];
    require(!o.active && o.player.starts==0,"user pause during drain wins");
    [o setPlaying:YES]; require(!o.active,"foreground never clears user pause intent");

    o=owner(); [o setPlaying:NO]; o.closing=YES; [o.player drain];
    require(!o.active && o.closes==1 && o.player.starts==0,"close during pause drain cannot restart");

    o=owner(); [o setPlaying:NO]; o.interrupted=YES; o.interrupted=NO;
    [o setPlaying:YES]; require(o.pausing && o.player.starts==0,"foreground waits for drain completion");
    [o.player drain]; require(o.active && o.player.starts==1,"one resume after permitted completion");

    o=owner(); o.active=NO; o.closing=YES; o.restarting=YES; container=o;
    ir_native_psp_stop();
    require(!o.restarting && !o.wantsActive && o.closing,"explicit stop cancels restart during cleanup");
    require(o.closes==0,"stop does not duplicate an in-flight cleanup");
    printf("PASS %u production lifecycle assertions\n", assertions);
    return 0;
} }
'''.replace('METHODS', methods).replace('STOP', stop).replace('HISTORICAL', '1' if historical else '0')
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder); file = root / 'check.mm'; binary = root / 'check'
        file.write_text(harness)
        result = subprocess.run(['clang++', '-std=c++17', '-fobjc-arc', '-framework', 'Foundation',
                                 str(file), '-o', str(binary)], capture_output=True, text=True)
        if result.returncode: raise AssertionError(result.stderr)
        return subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)


class NativePSPLifecycleTests(unittest.TestCase):
    def setUp(self):
        if not shutil.which('clang++') or not Path('/Applications/Xcode.app').exists():
            self.skipTest('Apple Foundation compiler required')

    def test_historical_commit_reproduces_inactive_resume(self):
        source = (ROOT / 'ci/psp/lifecycle-baseline-b0425719.txt').read_text()
        result = run_lifecycle(source, historical=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('BASELINE reproduced', result.stdout)

    def test_delayed_drain_obeys_environment_and_user_intent(self):
        result = run_lifecycle((ROOT / SOURCE).read_text())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('production lifecycle assertions', result.stdout)


if __name__ == '__main__': unittest.main()
