"""Session-scoped teardown for the release-pinned iOS camera/GPS owners."""
def replace(text, old, new):
    if text.count(old) != 1: raise ValueError('Sensor ownership hook changed: ' + old[:80])
    return text.replace(old, new)


PATCHED = ('ios/CameraHelper.h', 'ios/CameraHelper.mm', 'ios/LocationHelper.h', 'ios/LocationHelper.mm', 'ios/ViewControllerCommon.h')


def apply(name, text):
    if name in ('ios/CameraHelper.h', 'ios/LocationHelper.h'):
        text = replace(text, 'nonatomic, strong' if name.endswith('CameraHelper.h') else 'nonatomic,strong', 'nonatomic, weak')
        anchor = '- (void) stopVideo;' if name.endswith('CameraHelper.h') else '- (void) stopLocationUpdates;'
        text = replace(text, anchor, anchor + '\n- (void)iridiumCloseWithCompletion:(void (^)(void))completion;')
    if name == 'ios/ViewControllerCommon.h':
        text = replace(text, '- (void)shutdown;', '- (void)shutdown;\n- (void)iridiumCloseSensors:(void (^)(void))completion;')
    if name == 'ios/CameraHelper.mm':
        text = '#include <atomic>\n' + text
        text = replace(text, '    int mHeight;', '    int mHeight;\n    std::atomic<bool> iridiumClosed;\n    uint64_t iridiumRequestGeneration;\n    dispatch_queue_t iridiumCameraQueue;')
        text = replace(text, '@implementation CameraHelper', '''@implementation CameraHelper
- (instancetype)init {
    self = [super init];
    if (self) {
        iridiumClosed = false;
        iridiumCameraQueue = dispatch_queue_create("Iridium.PPSSPP.camera", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)iridiumCloseWithCompletion:(void (^)(void))completion {
    NSAssert(NSThread.isMainThread, @"Sensor ownership belongs to the main thread");
    iridiumClosed = true;
    iridiumRequestGeneration++;
    self.delegate = nil;
    AVCaptureSession *session = captureSession;
    captureSession = nil; previewLayer = nil;
    dispatch_async(iridiumCameraQueue, ^{
        for (AVCaptureOutput *output in session.outputs) {
            if ([output isKindOfClass:AVCaptureVideoDataOutput.class])
                [(AVCaptureVideoDataOutput *)output setSampleBufferDelegate:nil queue:NULL];
        }
        [session stopRunning];
        // Drain callbacks already enqueued before the delegate was detached.
        dispatch_async(iridiumCameraQueue, ^{ dispatch_async(dispatch_get_main_queue(), completion); });
    });
}
''')
        old = '''            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                if (granted) {
                    NSLog(@"camera permission granted");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self startVideo:mWidth h:mHeight];
                    });
                } else {
                    NSLog(@"camera permission denied");
                }
            }];'''
        new = '''            uint64_t request = iridiumRequestGeneration;
            __weak CameraHelper *weakSelf = self;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    CameraHelper *owner = weakSelf;
                    if (!owner || owner->iridiumClosed || request != owner->iridiumRequestGeneration) return;
                    if (granted) [owner startVideo:owner->mWidth h:owner->mHeight];
                });
            }];'''
        text = replace(text, old, new)
        text = replace(text, '\tmWidth = width;', '\tif (iridiumClosed) return;\n\tiridiumRequestGeneration++;\n\tmWidth = width;')
        text = replace(text, '    dispatch_async(dispatch_get_main_queue(), ^{\n        NSError *error = nil;',
                       '    uint64_t request = iridiumRequestGeneration;\n    dispatch_async(dispatch_get_main_queue(), ^{\n        if (iridiumClosed || request != iridiumRequestGeneration) return;\n        NSError *error = nil;')
        text = replace(text, '        dispatch_queue_t queue = dispatch_queue_create("cameraQueue", NULL);', '        dispatch_queue_t queue = iridiumCameraQueue;')
        text = replace(text, '-(void) stopVideo {', '-(void) stopVideo {\n    iridiumRequestGeneration++;')
        text = replace(text, '    CGImageRef cgImage = [self imageFromSampleBuffer:sampleBuffer];',
                       '    if (iridiumClosed) return;\n    CGImageRef cgImage = [self imageFromSampleBuffer:sampleBuffer];')
        text = replace(text, '    CGImageRef outImage = CGBitmapContextCreateImage(outContext);',
                       '    CGImageRef outImage = CGBitmapContextCreateImage(outContext);\n    CGContextRelease(outContext);')
    if name == 'ios/LocationHelper.mm':
        text = replace(text, '@interface LocationHelper()\n@end', '@interface LocationHelper() { BOOL iridiumClosed; }\n@end')
        text = replace(text, '-(void) startLocationUpdates {', '-(void) startLocationUpdates {\n    if (iridiumClosed) return;')
        text = replace(text, '    for (id location in locations) {', '    if (iridiumClosed) return;\n    for (id location in locations) {')
        text = replace(text, '@implementation LocationHelper', '''@implementation LocationHelper
- (void)iridiumCloseWithCompletion:(void (^)(void))completion {
    iridiumClosed = YES;
    [locationManager stopUpdatingLocation];
    locationManager.delegate = nil;
    self.delegate = nil;
    locationManager = nil;
    completion();
}
''')
    return text
