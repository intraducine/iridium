"""Exercise generated sensor ownership with substituted permissions and capture IO."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import ppsspp_sensor_overlay as sensors
from test_native_psp_lifecycle import method

ROOT = Path(__file__).resolve().parents[1]


class SensorOwnershipTests(unittest.TestCase):
    def test_pending_permission_active_capture_and_repeated_cleanup(self):
        if not shutil.which('clang++') or not Path('/Applications/Xcode.app').exists(): self.skipTest('Apple Foundation required')
        generated=sensors.apply('ios/CameraHelper.mm',(ROOT/'vendor/PPSSPP/ios/CameraHelper.mm').read_text())
        check=method(generated,'-(int) checkPermission {')
        close=method(generated,'- (void)iridiumCloseWithCompletion:')
        stop=method(generated,'-(void) stopVideo {')
        start=method(generated,'-(void) startVideo:')
        # The hardware setup is substituted; execute the original admission and
        # queued setup gates, before invoking the fake capture device boundary.
        prefix=start[:start.index('        NSError *error = nil;')]
        start=prefix+'        captureSession=[AVCaptureSession new]; captureSession.running=YES; hardwareStarts++;\n    });\n}'
        code=r'''#import <Foundation/Foundation.h>
#include <atomic>
#include <stdio.h>
#include <stdlib.h>
typedef NS_ENUM(int, AVAuthorizationStatus) {AVAuthorizationStatusNotDetermined,AVAuthorizationStatusRestricted,AVAuthorizationStatusDenied,AVAuthorizationStatusAuthorized};
static NSString *AVMediaTypeVideo=@"video";
static AVAuthorizationStatus authorization=AVAuthorizationStatusNotDetermined;
static NSMutableArray *mainWork,*cameraWork;
static void (^permission)(BOOL);
static unsigned hardwareStarts,completions,frames;
static void enqueue(id queue,void (^b)(void)){[(NSMutableArray*)queue addObject:[b copy]];}
#define dispatch_async(q,b) enqueue(q,b)
#define dispatch_get_main_queue() mainWork
static void drain(NSMutableArray *q){while(q.count){void(^b)(void)=q.firstObject;[q removeObjectAtIndex:0];b();}}
@interface AVCaptureOutput:NSObject @end
@implementation AVCaptureOutput @end
@interface AVCaptureVideoDataOutput:AVCaptureOutput
@property id delegate;
- (void)setSampleBufferDelegate:(id)delegate queue:(id)queue;
@end
@implementation AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {self.delegate=d;}
@end
@interface AVCaptureSession:NSObject
@property BOOL running;
@property NSArray *outputs;
@property unsigned stops;
- (void)stopRunning;
@end
@implementation AVCaptureSession
- (instancetype)init {self=[super init];self.outputs=@[[AVCaptureVideoDataOutput new]];return self;}
- (void)stopRunning {self.running=NO;self.stops++;}
@end
@interface AVCaptureDevice:NSObject
+(AVAuthorizationStatus)authorizationStatusForMediaType:(id)t;
+(void)requestAccessForMediaType:(id)t completionHandler:(void(^)(BOOL))h;
@end
@implementation AVCaptureDevice
+(AVAuthorizationStatus)authorizationStatusForMediaType:(id)t{return authorization;}
+(void)requestAccessForMediaType:(id)t completionHandler:(void(^)(BOOL))h{permission=[h copy];}
@end
@interface CameraHelper:NSObject {
@public AVCaptureSession *captureSession; id previewLayer;
int mWidth,mHeight; std::atomic<bool> iridiumClosed; uint64_t iridiumRequestGeneration; id iridiumCameraQueue;
}
@property(weak) id delegate;
-(int)checkPermission;
-(void)startVideo:(int)width h:(int)height;
-(void)stopVideo;
-(void)iridiumCloseWithCompletion:(void(^)(void))completion;
@end
@implementation CameraHelper
CHECK
START
STOP
CLOSE
@end
static void require(bool ok,const char *why){if(!ok){fprintf(stderr,"FAIL %s\n",why);exit(1);}}
static CameraHelper *owner(void){CameraHelper *o=[CameraHelper new];o->iridiumClosed=false;o->iridiumCameraQueue=cameraWork;return o;}
int main(void){@autoreleasepool{
 mainWork=[NSMutableArray array];cameraWork=[NSMutableArray array];
 CameraHelper *o=owner(); [o startVideo:16 h:16]; require(permission!=nil,"permission is pending");
 [o iridiumCloseWithCompletion:^{completions++;}];
 authorization=AVAuthorizationStatusAuthorized;permission(YES);permission=nil;
 drain(mainWork);require(hardwareStarts==0,"late permission cannot create capture");
 drain(cameraWork);drain(mainWork);require(completions==1,"closed pending session drains");

 o=owner();[o startVideo:16 h:16];[o stopVideo];drain(mainWork);
 require(hardwareStarts==0,"stop cancels queued capture setup");

 o=owner();[o startVideo:16 h:16];drain(mainWork);
 AVCaptureSession *session=o->captureSession;
 require(session.running && hardwareStarts==1,"active capture started through admitted setup");
 [cameraWork addObject:^{if(!o->iridiumClosed)frames++;}];
 [o iridiumCloseWithCompletion:^{completions++;}];
 require(completions==1,"close waits for callback queue");
 drain(cameraWork);drain(mainWork);
 require(!session.running && session.stops==1 && frames==0 && completions==2,"active capture stops and queued frame is rejected before completion");
 require(o.delegate==nil,"sensor delegate detached");

 for(int i=0;i<5;i++){
   __weak CameraHelper *retired;
   @autoreleasepool{CameraHelper *p=owner();retired=p;[p iridiumCloseWithCompletion:^{}];drain(cameraWork);drain(mainWork);p=nil;}
   require(retired==nil,"repeated session owner released after drain");
 }
 puts("PASS pending permission, setup cancellation, capture drain and five repeated owner releases");return 0;
}}
'''.replace('CHECK',check).replace('START',start).replace('STOP',stop).replace('CLOSE',close)
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); file=root/'check.mm';binary=root/'check';file.write_text(code)
            r=subprocess.run(['clang++','-std=c++17','-fobjc-arc','-framework','Foundation',str(file),'-o',str(binary)],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stderr)
            r=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertIn('PASS pending permission',r.stdout)


if __name__=='__main__':unittest.main()
