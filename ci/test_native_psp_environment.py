"""Execute production observers and begin admission through closing/restart overlap."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from test_native_psp_lifecycle import method

ROOT=Path(__file__).resolve().parents[1]


class EnvironmentOverlapTests(unittest.TestCase):
    def test_environment_changes_are_recorded_during_teardown(self):
        if not shutil.which('clang++') or not Path('/Applications/Xcode.app').exists():self.skipTest('Apple Foundation required')
        source=(ROOT/'iridium/apps/ios/RuntimeBridge/IRPPSSPPNative.mm').read_text()
        begin=source[source.index('- (void)beginPlayer {'):source.index('    ir_native_psp_platform_init();')]+ '}\n'
        methods='\n'.join(method(source,s) for s in ('- (void)observeEnvironment {','- (BOOL)canPlay {','- (void)setPlaying:(BOOL)playing {'))
        code=r'''#import <Foundation/Foundation.h>
#include <atomic>
#include <mutex>
#include <stdio.h>
#include <stdlib.h>
static NSString *UIApplicationWillResignActiveNotification=@"resign",*UIApplicationDidBecomeActiveNotification=@"active";
static NSString *AVAudioSessionInterruptionNotification=@"interruption",*AVAudioSessionMediaServicesWereResetNotification=@"reset",*AVAudioSessionInterruptionTypeKey=@"type";
enum{UIApplicationStateActive,UIApplicationStateInactive,AVAudioSessionInterruptionTypeEnded=2};
@interface UIApplication:NSObject
@property int applicationState;
@property BOOL idleTimerDisabled;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication{static UIApplication *o;if(!o)o=[self new];return o;}
@end
static std::atomic<uint64_t> generation,frames;
static std::atomic<bool> rendererFailed,acceptingCallbacks,stateBusy;
static std::atomic<int> pendingResolution,pendingState;
static bool reportedCoreError;
static std::mutex optionsLock;
static NSDictionary *pendingOptions;
static bool optionsReported=true;
static NSArray *irPSPOptions(NSString *,NSString *,bool *) { return @[]; }
static struct{bool bEnableSound;}g_Config={true};
static unsigned audioStarts;
static NSMutableArray *pending;
#define dispatch_async(queue,block) [pending addObject:[block copy]]
static void iOSCoreAudioInit(){audioStarts++;}
static void iOSCoreAudioShutdown(){}
@interface Player:NSObject
@property unsigned starts;
- (void)didBecomeActive;
- (void)iridiumStopRenderLoop:(void(^)(void))completion;
@end
@implementation Player
- (void)didBecomeActive{self.starts++;}
- (void)iridiumStopRenderLoop:(void(^)(void))completion{completion();}
@end
@interface IRPPSSPPContainer:NSObject
@property Player *player;
@property NSArray *observers;
@property BOOL active,pausing,wantsActive,closing,initialized,interrupted,appActive,previousIdleTimerDisabled;
- (void)beginPlayer;
- (void)observeEnvironment;
- (BOOL)canPlay;
- (void)setPlaying:(BOOL)playing;
- (void)finishClose;
@end
@implementation IRPPSSPPContainer
METHODS
BEGIN
- (void)finishClose{}
@end
static void require(bool ok,const char*why){if(!ok){fprintf(stderr,"FAIL %s",why);exit(1);}}
static void drain(){while(pending.count){void(^b)(void)=pending.firstObject;[pending removeObjectAtIndex:0];b();}}
static void interrupt(unsigned type){[NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionInterruptionNotification object:nil userInfo:@{AVAudioSessionInterruptionTypeKey:@(type)}];}
int main(){@autoreleasepool {
 pending=[NSMutableArray array];UIApplication.sharedApplication.applicationState=UIApplicationStateActive;
 IRPPSSPPContainer *o=[IRPPSSPPContainer new];o.player=[Player new];o.wantsActive=YES;o.initialized=YES;
 [o beginPlayer];require(o.appActive&&o.observers.count==4,"initial environment observed once");
 o.closing=YES;UIApplication.sharedApplication.applicationState=UIApplicationStateInactive;
 [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];require(!o.appActive,"resign recorded while closing");
 UIApplication.sharedApplication.applicationState=UIApplicationStateActive;
 [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];require(o.appActive&&!o.active,"foreground recorded without starting closing renderer");
 o.closing=NO;[o beginPlayer];[o setPlaying:YES];require(o.active&&o.player.starts==1&&o.observers.count==4,"restart resumes foreground with one observer set");
 o.closing=YES;[o setPlaying:NO];
 // Deliver an interruption off-main, while teardown owns the UI thread.
 dispatch_semaphore_t done=dispatch_semaphore_create(0);
 NSOperationQueue *queue=[NSOperationQueue new];[queue addOperationWithBlock:^{interrupt(1);dispatch_semaphore_signal(done);}];
 require(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,"background interruption delivered");
 require(o.interrupted,"interruption recorded immediately during teardown");
 o.closing=NO;[o beginPlayer];[o setPlaying:YES];drain();require(!o.active&&o.player.starts==1,"restart stays paused through interruption");
 o.closing=YES;interrupt(AVAudioSessionInterruptionTypeEnded);require(!o.interrupted,"interruption end retained while closing");
 o.closing=NO;o.appActive=NO;[o beginPlayer];[o setPlaying:YES];require(o.active&&o.player.starts==2,"begin refreshes current foreground and resumes permitted intent");
 o.wantsActive=NO;o.closing=YES;[o setPlaying:NO];
 [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
 o.closing=NO;[o beginPlayer];[o setPlaying:YES];require(!o.active&&o.player.starts==2,"restart and environment changes preserve user pause");
 for(id token in o.observers)[NSNotificationCenter.defaultCenter removeObserver:token];
 puts("PASS foreground, background interruption, interruption end and user pause across teardown/restart");
}}
'''.replace('METHODS',methods).replace('BEGIN',begin)
        with tempfile.TemporaryDirectory() as folder:
            source=Path(folder)/'environment.mm';binary=Path(folder)/'environment';source.write_text(code)
            result=subprocess.run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation',str(source),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__':unittest.main()
