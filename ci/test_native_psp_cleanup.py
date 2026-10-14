"""Execute the cleanup boundary with an injected stalled native worker."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from test_native_psp_lifecycle import method

ROOT=Path(__file__).resolve().parents[1]


class NativeCleanupTests(unittest.TestCase):
    def test_blocking_native_cleanup_keeps_ui_running_and_delays_release(self):
        if not shutil.which('clang++') or not Path('/Applications/Xcode.app').exists():self.skipTest('Apple Foundation required')
        body=method((ROOT/'iridium/apps/ios/RuntimeBridge/IRPPSSPPNative.mm').read_text(),'- (void)finishNativeClose {')
        code=r'''#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <stdio.h>
#include <stdlib.h>
static dispatch_semaphore_t releaseCleanup;
static std::atomic<bool> started, finished;
static void NativeShutdown(){if(NSThread.isMainThread)abort();started=true;dispatch_semaphore_wait(releaseCleanup,DISPATCH_TIME_FOREVER);finished=true;}
@interface View:NSObject
- (void)removeFromSuperview;
@end
@implementation View
- (void)removeFromSuperview{}
@end
@interface Player:NSObject
@property View *view;
- (void)willMoveToParentViewController:(id)parent;
- (void)shutdown;
- (void)removeFromParentViewController;
@end
@implementation Player
- (void)willMoveToParentViewController:(id)parent{}
- (void)shutdown{}
- (void)removeFromParentViewController{}
@end
@interface Owner:NSObject
@property Player *player;
@property NSMutableArray *inputRestorers;
@property NSMutableSet *capturedControllers;
@property BOOL initialized;
@property unsigned closes;
- (void)finishNativeClose;
- (void)completeClose;
- (void)resignFirstResponder;
@end
@implementation Owner
METHOD
- (void)completeClose{self.closes++;}
- (void)resignFirstResponder{}
@end
static void pump(double seconds){double end=CFAbsoluteTimeGetCurrent()+seconds;while(CFAbsoluteTimeGetCurrent()<end)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.01,false);}
static void require(bool ok,const char *why){if(!ok){fprintf(stderr,"FAIL %s\n",why);exit(1);}}
int main(){@autoreleasepool {
 releaseCleanup=dispatch_semaphore_create(0);
 Owner *owner=[Owner new];owner.player=[Player new];owner.player.view=[View new];
 owner.inputRestorers=[NSMutableArray array];owner.capturedControllers=[NSMutableSet set];owner.initialized=YES;
 double before=CFAbsoluteTimeGetCurrent();[owner finishNativeClose];
 require(CFAbsoluteTimeGetCurrent()-before<.5,"cleanup returns UI control");
 __block unsigned events=0;dispatch_async(dispatch_get_main_queue(),^{events++;});pump(.25);
 require(started&&!finished&&events==1&&owner.closes==0,"stalled worker cannot block UI or release owner early");
 dispatch_semaphore_signal(releaseCleanup);pump(.25);
 require(finished&&owner.closes==1,"native cleanup completes exactly once on main");
 puts("PASS injected stalled native cleanup preserves UI progress and owner lifetime");
}}
'''.replace('METHOD',body)
        with tempfile.TemporaryDirectory() as folder:
            source=Path(folder)/'cleanup.mm';binary=Path(folder)/'cleanup';source.write_text(code)
            result=subprocess.run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation','-framework','CoreFoundation',str(source),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__':unittest.main()
