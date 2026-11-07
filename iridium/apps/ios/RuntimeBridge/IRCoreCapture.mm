// SPDX-License-Identifier: AGPL-3.0-only
#import "IRCoreCapture.h"
#import <AVFoundation/AVFoundation.h>
#include <array>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

@interface IRCoreCapture () <AVCaptureVideoDataOutputSampleBufferDelegate> {
    dispatch_queue_t queue;
    AVCaptureSession *cameraSession;
    AVAudioEngine *microphoneEngine;
    std::atomic<unsigned> cameraSelection, cameraRequests;
    std::atomic<bool> allowMicrophone, micRequested, suspended, closed, micRunning;
    unsigned openedCamera;
    bool cameraPermissionPending, microphonePermissionPending;
    std::mutex lock;
    std::vector<uint32_t> frame;
    unsigned frameWidth, frameHeight, frameCamera;
    std::array<int16_t,16384> audio;
    size_t audioRead, audioWrite;
}
- (void)update;
@end
@implementation IRCoreCapture
- (instancetype)init {
    if((self=[super init]))queue=dispatch_queue_create("software.iridium.core-capture",DISPATCH_QUEUE_SERIAL);
    return self;
}
- (void)configureCamera:(unsigned)camera microphone:(bool)microphone {
    self.status=nil;
    cameraSelection.store(camera<=2?camera:0);allowMicrophone.store(microphone);
    dispatch_async(queue, ^{[self update];});
}
- (void)suspend:(bool)value { suspended.store(value);dispatch_async(queue, ^{[self update];}); }
- (void)requestCamera:(unsigned)camera active:(bool)active {
    if(camera>=3)return;
    if(active)cameraRequests.fetch_or(1u<<camera);else cameraRequests.fetch_and(~(1u<<camera));
    dispatch_async(queue, ^{[self update];});
}
- (void)requestMicrophone:(bool)active {micRequested.store(active);dispatch_async(queue, ^{[self update];});}
- (bool)microphoneActive {return allowMicrophone.load()&&micRequested.load()&&micRunning.load()&&!suspended.load()&&!closed.load();}
- (void)update {
    bool live=!suspended.load()&&!closed.load();
    unsigned wanted=live&&cameraRequests.load()?cameraSelection.load():0;
    if(cameraSession&&openedCamera!=wanted){[cameraSession stopRunning];cameraSession=nil;openedCamera=0;std::lock_guard<std::mutex> guard(lock);frame.clear();}
    if(wanted&&!cameraSession) {
        auto status=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if(status==AVAuthorizationStatusNotDetermined&&!cameraPermissionPending) {
            cameraPermissionPending=true;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL){dispatch_async(self->queue, ^{self->cameraPermissionPending=false;[self update];});}];
        } else if(status==AVAuthorizationStatusAuthorized) {
            AVCaptureDevice *device=[AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera mediaType:AVMediaTypeVideo position:wanted==2?AVCaptureDevicePositionFront:AVCaptureDevicePositionBack];
            NSError *error=nil;
            AVCaptureDeviceInput *input=device?[AVCaptureDeviceInput deviceInputWithDevice:device error:&error]:nil;
            AVCaptureSession *session=[[AVCaptureSession alloc]init];
            AVCaptureVideoDataOutput *output=[[AVCaptureVideoDataOutput alloc]init];
            output.videoSettings=@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
            output.alwaysDiscardsLateVideoFrames=YES;[output setSampleBufferDelegate:self queue:queue];
            [session beginConfiguration];
            if([session canSetSessionPreset:AVCaptureSessionPreset640x480])session.sessionPreset=AVCaptureSessionPreset640x480;
            if(input&&[session canAddInput:input]&&[session canAddOutput:output]) {
                [session addInput:input];[session addOutput:output];[session commitConfiguration];
                cameraSession=session;openedCamera=wanted;[session startRunning];
            } else { [session commitConfiguration];self.status=@"The selected camera is unavailable."; }
        } else if(status==AVAuthorizationStatusDenied||status==AVAuthorizationStatusRestricted)self.status=@"Camera access is off. You can allow it in iOS Settings.";
    }
    bool mic=live&&allowMicrophone.load()&&micRequested.load();
    if(!mic&&microphoneEngine) {
        [microphoneEngine.inputNode removeTapOnBus:0];[microphoneEngine stop];microphoneEngine=nil;micRunning.store(false);
        std::lock_guard<std::mutex> guard(lock);audioRead=audioWrite=0;
    }
    if(mic&&!microphoneEngine) {
        auto status=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if(status==AVAuthorizationStatusNotDetermined&&!microphonePermissionPending) {
            microphonePermissionPending=true;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL){dispatch_async(self->queue, ^{self->microphonePermissionPending=false;[self update];});}];
        } else if(status==AVAuthorizationStatusAuthorized) {
            NSError *error=nil;
            AVAudioSession *session=AVAudioSession.sharedInstance;
            if(![session setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers|AVAudioSessionCategoryOptionDefaultToSpeaker error:&error]||![session setActive:YES error:&error])return;
            AVAudioEngine *engine=[[AVAudioEngine alloc]init];
            AVAudioFormat *input=[engine.inputNode inputFormatForBus:0];
            AVAudioFormat *target=[[AVAudioFormat alloc]initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:48000 channels:1 interleaved:NO];
            if(!input.channelCount||input.sampleRate<=0)return;
            AVAudioConverter *converter=[[AVAudioConverter alloc]initFromFormat:input toFormat:target];
            if(!converter)return;
            __weak IRCoreCapture *weakSelf=self;
            [engine.inputNode installTapOnBus:0 bufferSize:1024 format:input block:^(AVAudioPCMBuffer *buffer,AVAudioTime *) {
                IRCoreCapture *capture=weakSelf;if(!capture||!capture->allowMicrophone.load()||capture->suspended.load()||capture->closed.load())return;
                AVAudioFrameCount capacity=(AVAudioFrameCount)std::min(8192.0,ceil(buffer.frameLength*48000.0/input.sampleRate)+32);
                AVAudioPCMBuffer *converted=[[AVAudioPCMBuffer alloc]initWithPCMFormat:target frameCapacity:capacity];
                __block bool supplied=false;
                NSError *conversionError=nil;
                [converter convertToBuffer:converted error:&conversionError withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount,AVAudioConverterInputStatus *state) {
                    if(supplied){*state=AVAudioConverterInputStatus_NoDataNow;return nil;}
                    supplied=true;*state=AVAudioConverterInputStatus_HaveData;return buffer;
                }];
                if(conversionError||!converted.int16ChannelData)return;
                std::lock_guard<std::mutex> guard(capture->lock);
                for(unsigned i=0;i<converted.frameLength;++i) {
                    if(capture->audioWrite-capture->audioRead==capture->audio.size())++capture->audioRead;
                    capture->audio[capture->audioWrite++%capture->audio.size()]=converted.int16ChannelData[0][i];
                }
            }];
            if([engine startAndReturnError:&error]){microphoneEngine=engine;micRunning.store(true);}
            else [engine.inputNode removeTapOnBus:0];
        } else if(status==AVAuthorizationStatusDenied||status==AVAuthorizationStatusRestricted)self.status=@"Microphone access is off. You can allow it in iOS Settings.";
    }
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    if(suspended.load()||closed.load()||!cameraSelection.load())return;
    CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);if(!pixels)return;
    CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);
    size_t width=CVPixelBufferGetWidth(pixels),height=CVPixelBufferGetHeight(pixels),pitch=CVPixelBufferGetBytesPerRow(pixels);
    if(width&&height&&width<=640&&height<=480) {
        auto bytes=(const uint8_t *)CVPixelBufferGetBaseAddress(pixels);
        std::lock_guard<std::mutex> guard(lock);frame.resize(width*height);
        for(size_t y=0;y<height;++y)memcpy(frame.data()+y*width,bytes+y*pitch,width*4);
        frameWidth=(unsigned)width;frameHeight=(unsigned)height;frameCamera=openedCamera;
    }
    CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);
}
- (bool)readCamera:(uint32_t *)pixels capacity:(size_t)capacity width:(unsigned *)width height:(unsigned *)height {
    if(!pixels||!width||!height||!cameraSelection.load()||suspended.load()||closed.load())return false;
    std::lock_guard<std::mutex> guard(lock);
    if(frame.empty()||frame.size()>capacity||frameCamera!=cameraSelection.load())return false;
    memcpy(pixels,frame.data(),frame.size()*4);*width=frameWidth;*height=frameHeight;return true;
}
- (int)readMicrophone:(int16_t *)samples count:(size_t)count {
    if(!samples||count>16384)return -1;
    std::lock_guard<std::mutex> guard(lock);
    size_t available=[self microphoneActive]?std::min(count,audioWrite-audioRead):0;
    for(size_t i=0;i<available;++i)samples[i]=audio[audioRead++%audio.size()];
    return (int)available;
}
- (void)close {closed.store(true);dispatch_sync(queue, ^{[self update];});}
@end
