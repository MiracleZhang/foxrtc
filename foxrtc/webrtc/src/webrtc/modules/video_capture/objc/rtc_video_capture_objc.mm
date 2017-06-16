/*
 *  Copyright (c) 2013 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

#import <AVFoundation/AVFoundation.h>
#ifdef WEBRTC_IOS
#import <UIKit/UIKit.h>
#endif

#import "webrtc/modules/video_capture/objc/device_info_objc.h"
#import "webrtc/modules/video_capture/objc/rtc_video_capture_objc.h"

#include "webrtc/system_wrappers/include/trace.h"

using namespace webrtc;
using namespace webrtc::videocapturemodule;

@interface RTCVideoCaptureIosObjC (hidden)
- (int)changeCaptureInputWithName:(NSString*)captureDeviceName;
@end

@implementation RTCVideoCaptureIosObjC {
  webrtc::videocapturemodule::VideoCaptureIos* _owner;
  webrtc::VideoCaptureCapability _capability;
  AVCaptureSession* _captureSession;
  int _captureId;
  //BOOL _orientationHasChanged;
  AVCaptureVideoOrientation _currentOrientation;
  AVCaptureConnection* _connection;
    
  BOOL _captureChanging;  // Guarded by _captureChangingCondition.
  NSCondition* _captureChangingCondition;
  BOOL _isRunning;
}

@synthesize frameRotation = _framRotation;

- (id)initWithOwner:(VideoCaptureIos*)owner captureId:(int)captureId {
  if (self == [super init]) {
    _owner = owner;
    _captureId = captureId;
    _captureSession = [[AVCaptureSession alloc] init];
#if defined(WEBRTC_IOS)
    _captureSession.usesApplicationAudioSession = NO;
#endif
    _captureChanging = NO;
    _captureChangingCondition = [[NSCondition alloc] init];

    if (!_captureSession || !_captureChangingCondition) {
      return nil;
    }

    // create and configure a new output (using callbacks)
    AVCaptureVideoDataOutput* captureOutput =
        [[AVCaptureVideoDataOutput alloc] init];
    NSString* key = (NSString*)kCVPixelBufferPixelFormatTypeKey;

    NSNumber* val = [NSNumber
        numberWithUnsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange];
    NSDictionary* videoSettings =
        [NSDictionary dictionaryWithObject:val forKey:key];
    captureOutput.videoSettings = videoSettings;
      
      // add new output
      if ([_captureSession canAddOutput:captureOutput]) {
          [_captureSession addOutput:captureOutput];
      } else {
          WEBRTC_TRACE(kTraceError, kTraceVideoCapture, _captureId,
                       "%s:%s:%d Could not add output to AVCaptureSession ",
                       __FILE__, __FUNCTION__, __LINE__);
      }
      

#ifdef WEBRTC_IOS
      //默认初始化为头像是正的
      _currentOrientation = AVCaptureVideoOrientationPortrait;
      switch ([UIDevice currentDevice].orientation) {
          case UIDeviceOrientationPortrait:
              _currentOrientation = AVCaptureVideoOrientationPortrait;
              break;
          case UIDeviceOrientationPortraitUpsideDown:
              _currentOrientation =
              AVCaptureVideoOrientationPortraitUpsideDown;
              break;
          case UIDeviceOrientationLandscapeLeft:
              _currentOrientation = AVCaptureVideoOrientationLandscapeRight;
              break;
          case UIDeviceOrientationLandscapeRight:
              _currentOrientation = AVCaptureVideoOrientationLandscapeLeft;
              break;
          default:
              _currentOrientation = AVCaptureVideoOrientationPortrait;
              break;
      }
      
#else
      _currentOrientation = AVCaptureVideoOrientationLandscapeRight;
#endif
      
#ifdef WEBRTC_IOS
      //改为app控制
      //[[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];

    NSNotificationCenter* notify = [NSNotificationCenter defaultCenter];
    [notify addObserver:self
               selector:@selector(onVideoError:)
                   name:AVCaptureSessionRuntimeErrorNotification
                 object:_captureSession];
      
      //改为app控制
//    [notify addObserver:self
//               selector:@selector(deviceOrientationDidChange:)
//                   name:UIDeviceOrientationDidChangeNotification
//                 object:nil];
      
      //改为app控制
      [notify addObserver:self
                 selector:@selector(deviceOrientationDidChange:)
                     name:@"BlitzUIDeviceOrientationDidChangeNotification"
                   object:nil];
#endif
      _isRunning = NO;
  }

  return self;
}

- (void)directOutputToSelf {
  [[self currentOutput]
      setSampleBufferDelegate:self
                        queue:dispatch_get_global_queue(
                                  DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)];
}

- (void)directOutputToNil {
  [[self currentOutput] setSampleBufferDelegate:nil queue:NULL];
}

- (void)deviceOrientationDidChange:(NSNotification*)notification {
    NSString* rotation = [[notification userInfo] objectForKey:@"rotation"];
    assert(rotation != nil);
    //_orientationHasChanged = YES;
    if ([rotation isEqualToString:@"LandscapeRight"]) {
        _currentOrientation = AVCaptureVideoOrientationLandscapeRight;
    }
    else if ([rotation isEqualToString:@"Portrait"]) {
        _currentOrientation = AVCaptureVideoOrientationPortrait;
    }
    else if ([rotation isEqualToString:@"LandscapeLeft"]) {
        _currentOrientation = AVCaptureVideoOrientationLandscapeLeft;
    }
    else if ([rotation isEqualToString:@"PortraitUpsideDown"]) {
        _currentOrientation = AVCaptureVideoOrientationPortraitUpsideDown;
    }
    else {
        assert(false);
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                   ^{
                       //避免卡住主线程
                       [self waitForCaptureChangeToFinish];
                       [self setRelativeVideoOrientation];
                   });
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)setCaptureDeviceByUniqueId:(NSString*)uniqueId {
  [self waitForCaptureChangeToFinish];
  // check to see if the camera is already set
  if (_captureSession) {
    NSArray* currentInputs = [NSArray arrayWithArray:[_captureSession inputs]];
    if ([currentInputs count] > 0) {
      AVCaptureDeviceInput* currentInput = [currentInputs objectAtIndex:0];
      if ([uniqueId isEqualToString:[currentInput.device localizedName]]) {
        return YES;
      }
    }
  }

  return [self changeCaptureInputByUniqueId:uniqueId];
}

- (BOOL)startCaptureWithCapability:(const VideoCaptureCapability&)capability {
  [self waitForCaptureChangeToFinish];
  if (!_captureSession) {
    return NO;
  }

  // check limits of the resolution
  if (capability.maxFPS < 0 || capability.maxFPS > 60) {
    return NO;
  }

  if ([_captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
    if (capability.width > 1280 || capability.height > 720) {
      return NO;
    }
  } else if ([_captureSession
                 canSetSessionPreset:AVCaptureSessionPreset640x480]) {
    if (capability.width > 640 || capability.height > 480) {
      return NO;
    }
  } else if ([_captureSession
                 canSetSessionPreset:AVCaptureSessionPreset352x288]) {
    if (capability.width > 352 || capability.height > 288) {
      return NO;
    }
  } else if (capability.width < 0 || capability.height < 0) {
    return NO;
  }

  _capability = capability;

  AVCaptureVideoDataOutput* currentOutput = [self currentOutput];
  if (!currentOutput)
    return NO;

  [self directOutputToSelf];

  //_orientationHasChanged = NO;
  _captureChanging = YES;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   [self startCaptureInBackgroundWithOutput:currentOutput];
                 });
    
    _isRunning = YES;
  return YES;
}

- (AVCaptureVideoDataOutput*)currentOutput {
  return [[_captureSession outputs] firstObject];
}

- (void)startCaptureInBackgroundWithOutput:
(AVCaptureVideoDataOutput*)currentOutput {
    NSString* captureQuality =
    [NSString stringWithString:AVCaptureSessionPresetLow];
    if (_capability.width >= 1280 || _capability.height >= 720) {
        captureQuality = [NSString stringWithString:AVCaptureSessionPreset1280x720];
    } else if (_capability.width >= 640 || _capability.height >= 480) {
        captureQuality = [NSString stringWithString:AVCaptureSessionPreset640x480];
    } else if (_capability.width >= 352 || _capability.height >= 288) {
        captureQuality = [NSString stringWithString:AVCaptureSessionPreset352x288];
    }
    
    [_captureSession beginConfiguration];
    if ([_captureSession canSetSessionPreset:captureQuality]) {
        [_captureSession setSessionPreset:captureQuality];
    }
    [currentOutput setVideoSettings:nil];
    [_captureSession commitConfiguration];
    
    NSDictionary* videoSettings = [currentOutput videoSettings];
    NSMutableDictionary* newVideoSettings = [NSMutableDictionary dictionaryWithCapacity:0];
    NSNumber* format = [NSNumber numberWithUnsignedInt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange];
    [newVideoSettings addEntriesFromDictionary:videoSettings];
    [newVideoSettings setObject:format forKey:(NSString*)kCVPixelBufferPixelFormatTypeKey];
    [newVideoSettings setObject:AVVideoScalingModeResizeAspectFill forKey:AVVideoScalingModeKey];
    
    [_captureSession beginConfiguration];
    [currentOutput setVideoSettings:newVideoSettings];
    
    _connection = [currentOutput connectionWithMediaType:AVMediaTypeVideo];
    [self setRelativeVideoOrientation];
    
    // finished configuring, commit settings to AVCaptureSession.
    [_captureSession commitConfiguration];
    
    [_captureSession startRunning];
    [self signalCaptureChangeEnd];
}

- (void)setRelativeVideoOrientation {
  if (!_connection.supportsVideoOrientation) {
    return;
  }
#ifndef WEBRTC_IOS
  _connection.videoOrientation = AVCaptureVideoOrientationLandscapeRight;
  return;
#else
    _connection.videoOrientation = _currentOrientation;
#endif
}

- (void)onVideoError:(NSNotification*)notification {
  NSLog(@"onVideoError: %@", notification);
  // TODO(sjlee): make the specific error handling with this notification.
  WEBRTC_TRACE(kTraceError, kTraceVideoCapture, _captureId,
               "%s:%s:%d [AVCaptureSession startRunning] error.", __FILE__,
               __FUNCTION__, __LINE__);
}

- (BOOL)stopCapture {
    _isRunning = NO;
#ifdef WEBRTC_IOS
  //[[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
#endif
  //_orientationHasChanged = NO;
  [self waitForCaptureChangeToFinish];
  [self directOutputToNil];

  if (!_captureSession) {
    return NO;
  }

  _captureChanging = YES;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^(void) {
                   [self stopCaptureInBackground];
                 });
  return YES;
}

- (void)stopCaptureInBackground {
  [_captureSession stopRunning];
  [self signalCaptureChangeEnd];
}

- (BOOL)changeCaptureInputByUniqueId:(NSString*)uniqueId {
  [self waitForCaptureChangeToFinish];
  NSArray* currentInputs = [_captureSession inputs];
  // remove current input
  if ([currentInputs count] > 0) {
    AVCaptureInput* currentInput =
        (AVCaptureInput*)[currentInputs objectAtIndex:0];

    [_captureSession removeInput:currentInput];
  }

  // Look for input device with the name requested (as our input param)
  // get list of available capture devices
  int captureDeviceCount = [DeviceInfoIosObjC captureDeviceCount];
  if (captureDeviceCount <= 0) {
    return NO;
  }

  AVCaptureDevice* captureDevice =
      [DeviceInfoIosObjC captureDeviceForUniqueId:uniqueId];

  if (!captureDevice) {
    return NO;
  }

  // now create capture session input out of AVCaptureDevice
  NSError* deviceError = nil;
  AVCaptureDeviceInput* newCaptureInput =
      [AVCaptureDeviceInput deviceInputWithDevice:captureDevice
                                            error:&deviceError];

  if (!newCaptureInput) {
    const char* errorMessage = [[deviceError localizedDescription] UTF8String];

    WEBRTC_TRACE(kTraceError, kTraceVideoCapture, _captureId,
                 "%s:%s:%d deviceInputWithDevice error:%s", __FILE__,
                 __FUNCTION__, __LINE__, errorMessage);

    return NO;
  }

  // try to add our new capture device to the capture session
  [_captureSession beginConfiguration];

  BOOL addedCaptureInput = NO;
  if ([_captureSession canAddInput:newCaptureInput]) {
    [_captureSession addInput:newCaptureInput];
    addedCaptureInput = YES;
  } else {
    addedCaptureInput = NO;
  }

  [_captureSession commitConfiguration];

  return addedCaptureInput;
}

- (void)captureOutput:(AVCaptureOutput*)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection*)connection {
  const int kFlags = 0;
  CVImageBufferRef videoFrame = CMSampleBufferGetImageBuffer(sampleBuffer);

  if (CVPixelBufferLockBaseAddress(videoFrame, kFlags) != kCVReturnSuccess) {
    return;
  }

  const int kYPlaneIndex = 0;
  const int kUVPlaneIndex = 1;

  uint8_t* baseAddress =
      (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(videoFrame, kYPlaneIndex);
  size_t yPlaneBytesPerRow =
      CVPixelBufferGetBytesPerRowOfPlane(videoFrame, kYPlaneIndex);
  size_t yPlaneHeight = CVPixelBufferGetHeightOfPlane(videoFrame, kYPlaneIndex);
  size_t uvPlaneBytesPerRow =
      CVPixelBufferGetBytesPerRowOfPlane(videoFrame, kUVPlaneIndex);
  size_t uvPlaneHeight =
      CVPixelBufferGetHeightOfPlane(videoFrame, kUVPlaneIndex);
  size_t frameSize =
      yPlaneBytesPerRow * yPlaneHeight + uvPlaneBytesPerRow * uvPlaneHeight;

  VideoCaptureCapability tempCaptureCapability;
  tempCaptureCapability.width = CVPixelBufferGetWidth(videoFrame);
  tempCaptureCapability.height = CVPixelBufferGetHeight(videoFrame);
  tempCaptureCapability.maxFPS = _capability.maxFPS;
  tempCaptureCapability.rawType = kVideoNV12;

    //美颜要求在单线程回调，现在改为主线程回调
    //否则是一个随机线程
  dispatch_sync(dispatch_get_main_queue(), ^{
      if (_isRunning) {
        _owner->IncomingFrame(baseAddress, frameSize, tempCaptureCapability, 0);
      }
  });

  CVPixelBufferUnlockBaseAddress(videoFrame, kFlags);
}

- (void)signalCaptureChangeEnd {
  [_captureChangingCondition lock];
  _captureChanging = NO;
  [_captureChangingCondition signal];
  [_captureChangingCondition unlock];
}

- (void)waitForCaptureChangeToFinish {
  [_captureChangingCondition lock];
  while (_captureChanging) {
    [_captureChangingCondition wait];
  }
  [_captureChangingCondition unlock];
}
@end
