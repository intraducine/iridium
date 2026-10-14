"""Execute the final composed close chain after the session has been retired."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import ppsspp_native_overlay as overlay
from test_native_psp_lifecycle import method

ROOT=Path(__file__).resolve().parents[1]


class NativeCleanupTests(unittest.TestCase):
    def test_composed_sensor_completion_reaches_main_thread_native_shutdown(self):
        if not shutil.which('clang++') or not Path('/Applications/Xcode.app').exists():self.skipTest('Apple Foundation required')
        generated=overlay.apply('ios/ViewControllerCommon.mm',(ROOT/'vendor/PPSSPP/ios/ViewControllerCommon.mm').read_text())
        sensor=method(generated,'- (void)iridiumCloseSensors:')
        source=(ROOT/'iridium/apps/ios/RuntimeBridge/IRPPSSPPNative.mm').read_text()
        methods='\n'.join(method(source,s) for s in ('- (BOOL)canPlay {','- (void)setPlaying:(BOOL)playing {','- (void)closePlayer {','- (void)finishClose {','- (void)finishNativeClose {'))
        code=r'''#import <Foundation/Foundation.h>
#include <atomic>
#include <stdio.h>
#include <stdlib.h>
static NSMutableArray *mainWork;
#define dispatch_async(queue,block) [mainWork addObject:[block copy]]
static std::atomic<bool> acceptingCallbacks;
static std::atomic<uint64_t> generation;
static bool ir_native_psp_generation_current(uint64_t owner){return acceptingCallbacks&&generation==owner;}
static bool rendererFailed;
static struct {bool bEnableSound;} g_Config={true};
static unsigned nativeCloses;
static void require(bool ok,const char *why){if(!ok){fprintf(stderr,"FAIL %s\n",why);exit(1);}}
static void NativeShutdown(){require(NSThread.isMainThread,"NativeShutdown follows the upstream main-thread contract");nativeCloses++;}
static void iOSCoreAudioShutdown(){}
static void iOSCoreAudioInit(){}
enum{UIApplicationStateActive};
@interface UIApplication:NSObject
@property int applicationState;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication{static UIApplication *o;if(!o)o=[self new];return o;}
@end
@interface View:NSObject
- (void)removeFromSuperview;
@end
@implementation View
- (void)removeFromSuperview{}
@end
@interface Motion:NSObject
@property unsigned stops;
- (void)stopAccelerometerUpdates;
@end
@implementation Motion
- (void)stopAccelerometerUpdates{self.stops++;}
@end
@interface BarrierQueue:NSObject
@property NSMutableArray *barriers;
@property unsigned cancels;
- (void)cancelAllOperations;
- (void)addBarrierBlock:(void(^)(void))block;
@end
@implementation BarrierQueue
- (instancetype)init{self=[super init];self.barriers=[NSMutableArray array];return self;}
- (void)cancelAllOperations{self.cancels++;}
- (void)addBarrierBlock:(void(^)(void))block{[self.barriers addObject:[block copy]];}
@end
@interface Camera:NSObject
@property void(^completion)(void);
- (void)iridiumCloseWithCompletion:(void(^)(void))completion;
@end
@implementation Camera
- (void)iridiumCloseWithCompletion:(void(^)(void))completion{self.completion=completion;}
@end
@interface Location:NSObject
@property unsigned closes;
- (void)iridiumCloseWithCompletion:(void(^)(void))completion;
@end
@implementation Location
- (void)iridiumCloseWithCompletion:(void(^)(void))completion{self.closes++;completion();}
@end
@interface Base:NSObject {
@public
 Camera *cameraHelper;
 Location *locationHelper;
 std::atomic<bool> iridiumSensorsClosed;
 uint64_t iridiumOwnerGeneration;
}
@property Motion *motionManager;
@property BarrierQueue *accelerometerQueue;
@property View *view;
- (void)iridiumCloseSensors:(void(^)(void))completion;
- (void)willMoveToParentViewController:(id)parent;
- (void)shutdown;
- (void)removeFromParentViewController;
- (void)didBecomeActive;
- (void)iridiumStopRenderLoop:(void(^)(void))completion;
@end
@implementation Base
SENSOR
- (void)willMoveToParentViewController:(id)parent{}
- (void)shutdown{require(iridiumSensorsClosed&&!self.accelerometerQueue,"drained sensors before view shutdown");}
- (void)removeFromParentViewController{}
- (void)didBecomeActive{}
- (void)iridiumStopRenderLoop:(void(^)(void))completion{completion();}
@end
@interface Owner:NSObject
@property Base *player;
@property NSMutableArray *inputRestorers;
@property NSMutableSet *capturedControllers;
@property NSMutableDictionary *presentationCancels;
@property NSArray *observers;
@property BOOL initialized,active,pausing,wantsActive,closing,finishing,interrupted,appActive;
@property unsigned closes;
- (BOOL)canPlay;
- (void)setPlaying:(BOOL)playing;
- (void)closePlayer;
- (void)finishClose;
- (void)finishNativeClose;
- (void)completeClose;
- (void)resignFirstResponder;
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(id)completion;
@end
@implementation Owner
METHODS
- (void)completeClose{self.closes++;self.initialized=NO;}
- (void)resignFirstResponder{}
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(id)completion{}
@end
static void drain(){while(mainWork.count){void(^block)(void)=mainWork.firstObject;[mainWork removeObjectAtIndex:0];block();}}
int main(){@autoreleasepool {
 mainWork=[NSMutableArray array];
 for(unsigned round=0;round<5;round++){
  acceptingCallbacks=true;generation++;
  Owner *owner=[Owner new];Base *retired=[Base new];owner.player=retired;
  retired->iridiumOwnerGeneration=generation;retired->iridiumSensorsClosed=false;
  Camera *camera=[Camera new];Location *location=[Location new];Motion *motion=[Motion new];BarrierQueue *queue=[BarrierQueue new];
  retired->cameraHelper=camera;retired->locationHelper=location;
  retired.motionManager=motion;retired.accelerometerQueue=queue;retired.view=[View new];
  owner.initialized=YES;owner.appActive=YES;owner.wantsActive=YES;
  owner.inputRestorers=[NSMutableArray array];owner.capturedControllers=[NSMutableSet set];owner.presentationCancels=[NSMutableDictionary dictionary];
  [owner closePlayer];
  require(!acceptingCallbacks&&!ir_native_psp_generation_current(retired->iridiumOwnerGeneration),"close retires user callbacks before mandatory cleanup");
  require(owner.closing&&owner.closes==0&&nativeCloses==round,"native close waits for camera drain");
  require(motion.stops==1&&location.closes==1&&queue.cancels==1,"all sensor owners stopped");
  void(^cameraDone)(void)=camera.completion;camera.completion=nil;cameraDone();
  require(queue.barriers.count==1&&owner.closes==0,"wait for accelerometer barrier");
  void(^barrier)(void)=queue.barriers.firstObject;[queue.barriers removeAllObjects];barrier();
  require(mainWork.count==1,"mandatory main completion queued even after retirement");drain();
  require(owner.closes==1&&nativeCloses==round+1&&!owner.player,"composed close reaches NativeShutdown exactly once");
 }
 puts("PASS five final-composed sensor-to-native close chains after retirement, on main");
}}
'''.replace('SENSOR',sensor).replace('METHODS',methods)
        with tempfile.TemporaryDirectory() as folder:
            source=Path(folder)/'cleanup.mm';binary=Path(folder)/'cleanup';source.write_text(code)
            result=subprocess.run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation',str(source),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)


if __name__=='__main__':unittest.main()
