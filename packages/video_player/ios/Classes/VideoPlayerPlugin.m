// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "VideoPlayerPlugin.h"
#import <AVFoundation/AVFoundation.h>

int64_t FLTCMTimeToMillis(CMTime time) { return time.value * 1000 / time.timescale; }

@interface FLTFrameUpdater : NSObject
@property(nonatomic) int64_t textureId;
@property(nonatomic, readonly) NSObject<FlutterTextureRegistry>* registry;
- (void)onDisplayLink:(CADisplayLink*)link;
@end

@implementation FLTFrameUpdater
- (FLTFrameUpdater*)initWithRegistry:(NSObject<FlutterTextureRegistry>*)registry {
  NSAssert(self, @"super init cannot be nil");
  if (self == nil) return nil;
  _registry = registry;
  return self;
}

- (void)onDisplayLink:(CADisplayLink*)link {
  [_registry textureFrameAvailable:_textureId];
}
@end

@interface FLTVideoPlayer : NSObject<FlutterTexture, FlutterStreamHandler>
@property(readonly, nonatomic) AVPlayer* player;
@property(readonly, nonatomic) AVPlayerItemVideoOutput* videoOutput;
@property(readonly, nonatomic) CADisplayLink* displayLink;
@property(nonatomic) FlutterEventChannel* eventChannel;
@property(nonatomic) FlutterEventSink eventSink;
@property(nonatomic) CGAffineTransform preferredTransform;
@property(nonatomic, readonly) bool disposed;
@property(nonatomic, readonly) bool isPlaying;
@property(nonatomic, readonly) bool isLooping;
@property(nonatomic, readonly) bool isInitialized;
- (instancetype)initWithURL:(NSURL*)url frameUpdater:(FLTFrameUpdater*)frameUpdater;
- (void)play;
- (void)pause;
- (void)setIsLooping:(bool)isLooping;
- (void)updatePlayingState;
@end

static void* timeRangeContext = &timeRangeContext;
static void* statusContext = &statusContext;
static void* playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void* playbackBufferEmptyContext = &playbackBufferEmptyContext;
static void* playbackBufferFullContext = &playbackBufferFullContext;

@implementation FLTVideoPlayer
- (instancetype)initWithAsset:(NSString*)asset frameUpdater:(FLTFrameUpdater*)frameUpdater {
  NSString* path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
  return [self initWithURL:[NSURL fileURLWithPath:path] frameUpdater:frameUpdater];
}

- (void)addObservers:(AVPlayerItem*)item {
  [item addObserver:self
         forKeyPath:@"loadedTimeRanges"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:timeRangeContext];
  [item addObserver:self
         forKeyPath:@"status"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:statusContext];
  [item addObserver:self
         forKeyPath:@"playbackLikelyToKeepUp"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackLikelyToKeepUpContext];
  [item addObserver:self
         forKeyPath:@"playbackBufferEmpty"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackBufferEmptyContext];
  [item addObserver:self
         forKeyPath:@"playbackBufferFull"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackBufferFullContext];

  [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                    object:[_player currentItem]
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification* note) {
                                                  if (_isLooping) {
                                                    AVPlayerItem* p = [note object];
                                                    [p seekToTime:kCMTimeZero];
                                                  } else {
                                                    if (_eventSink) {
                                                      _eventSink(@{@"event" : @"completed"});
                                                    }
                                                  }
                                                }];
}

- (AVMutableVideoComposition*)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                     withAsset:(AVAsset*)asset
                                                withVideoTrack:(AVAssetTrack*)videoTrack {
  // CGAffineTransform t = _preferredTransform;
  // NSLog(@"Affine1 (a, b, c, d, tx, ty): (%f, %f, %f, %f, %f, %f)", t.a, t.b, t.c, t.d, t.tx,
  // t.ty);

  AVMutableVideoCompositionInstruction* instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
  instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
  AVMutableVideoCompositionLayerInstruction* layerInstruction =
      [AVMutableVideoCompositionLayerInstruction
          videoCompositionLayerInstructionWithAssetTrack:videoTrack];
  [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];

  AVMutableVideoComposition* videoComposition = [AVMutableVideoComposition videoComposition];
  instruction.layerInstructions = @[ layerInstruction ];
  videoComposition.instructions = @[ instruction ];

  // If in portrait mode, switch the width and height of the video
  float width = videoTrack.naturalSize.width;
  float height = videoTrack.naturalSize.height;
  NSInteger rotationDegrees =
      (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));
  if (rotationDegrees == 90 || rotationDegrees == 270) {
    width = videoTrack.naturalSize.height;
    height = videoTrack.naturalSize.width;
  }
  videoComposition.renderSize = CGSizeMake(width, height);

  // TODO use videoTrack.nominalFrameRate ?
  // Currently set at 30 FPS
  videoComposition.frameDuration = CMTimeMake(1, 30);

  return videoComposition;
}

- (void)createVideoOutputAndDisplayLink:(FLTFrameUpdater*)frameUpdater {
  NSDictionary* pixBuffAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };
  _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixBuffAttributes];

  _displayLink =
      [CADisplayLink displayLinkWithTarget:frameUpdater selector:@selector(onDisplayLink:)];
  [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
  _displayLink.paused = YES;
}

- (instancetype)initWithURL:(NSURL*)url frameUpdater:(FLTFrameUpdater*)frameUpdater {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _isInitialized = false;
  _isPlaying = false;
  _disposed = false;

  AVPlayerItem* item = [AVPlayerItem playerItemWithURL:url];

  AVAsset* asset = [item asset];
  void (^assetCompletionHandler)(void) = ^{
    if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
      NSArray* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
      if ([tracks count] > 0) {
        AVAssetTrack* videoTrack = [tracks objectAtIndex:0];
        void (^trackCompletionHandler)(void) = ^{
          if (_disposed) return;
          if ([videoTrack statusOfValueForKey:@"preferredTransform" error:nil] ==
              AVKeyValueStatusLoaded) {
            // Rotate the video by using a videoComposition and the preferredTransform
            _preferredTransform = videoTrack.preferredTransform;
            // Note:
            // https://developer.apple.com/documentation/avfoundation/avplayeritem/1388818-videocomposition
            // Aideo composition can only be used with file-based media and is not supported for use
            // with media served using HTTP Live Streaming.
            item.videoComposition = [self getVideoCompositionWithTransform:_preferredTransform
                                                                 withAsset:asset
                                                            withVideoTrack:videoTrack];
            dispatch_async(dispatch_get_main_queue(), ^{
              // Without this line, videos are not always rendered in app. TODO explain why
              [_player replaceCurrentItemWithPlayerItem:item];
            });
          }
        };
        [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                                  completionHandler:trackCompletionHandler];
      }
    }
  };

  _player = [AVPlayer playerWithPlayerItem:item];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

  [self createVideoOutputAndDisplayLink:frameUpdater];

  [self addObservers:item];

  [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:assetCompletionHandler];

  return self;
}

- (void)observeValueForKeyPath:(NSString*)path
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
  if (context == timeRangeContext) {
    if (_eventSink != nil) {
      NSMutableArray<NSArray<NSNumber*>*>* values = [[NSMutableArray alloc] init];
      for (NSValue* rangeValue in [object loadedTimeRanges]) {
        CMTimeRange range = [rangeValue CMTimeRangeValue];
        int64_t start = FLTCMTimeToMillis(range.start);
        [values addObject:@[ @(start), @(start + FLTCMTimeToMillis(range.duration)) ]];
      }
      _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values});
    }
  } else if (context == statusContext) {
    AVPlayerItem* item = (AVPlayerItem*)object;
    switch (item.status) {
      case AVPlayerStatusFailed:
        if (_eventSink != nil) {
          _eventSink([FlutterError
              errorWithCode:@"VideoError"
                    message:[@"Failed to load video: "
                                stringByAppendingString:[item.error localizedDescription]]
                    details:nil]);
        }
        break;
      case AVPlayerItemStatusUnknown:
        break;
      case AVPlayerItemStatusReadyToPlay:
        _isInitialized = true;
        [item addOutput:_videoOutput];
        [self sendInitialized];
        [self updatePlayingState];
        break;
    }
  } else if (context == playbackLikelyToKeepUpContext) {
    if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
      [self updatePlayingState];
      if (_eventSink != nil) {
        _eventSink(@{@"event" : @"bufferingEnd"});
      }
    }
  } else if (context == playbackBufferEmptyContext) {
    if (_eventSink != nil) {
      _eventSink(@{@"event" : @"bufferingStart"});
    }
  } else if (context == playbackBufferFullContext) {
    if (_eventSink != nil) {
      _eventSink(@{@"event" : @"bufferingEnd"});
    }
  }
}

- (void)updatePlayingState {
  if (!_isInitialized) {
    return;
  }
  if (_isPlaying) {
    [_player play];
  } else {
    [_player pause];
  }
  _displayLink.paused = !_isPlaying;
}

static inline CGFloat radiansToDegrees(CGFloat radians) {
  // Input range [-pi, pi] or [-180, 180]
  CGFloat degrees = radians * 180 / M_PI;
  if (degrees < 0) {
    // Convert -90 to 270 and -180 to 180
    return degrees + 360;
  }
  // Output degrees in between [0, 360[
  return degrees;
};

- (void)sendInitialized {
  if (_eventSink && _isInitialized) {
    CGSize size = [self.player currentItem].presentationSize;
    // CGAffineTransform transform = [_player currentItem] asset].preferredTransform;
    // CGAffineTransform transform = [[[_player currentItem] asset] preferredTransform];
    // NSArray* tracks = [[[_player currentItem] asset] tracksWithMediaType:AVMediaTypeVideo];
    // NSLog(@"Track lenght: %d", tracks.count);
    // CGAffineTransform transform = [[tracks objectAtIndex:0] preferredTransform];
    // atan2 returns values in the closed interval [-pi,pi]. See:
    // https://www.mathworks.com/help/matlab/ref/atan2.html#buct8h0-4
    // https://developer.apple.com/documentation/coregraphics/cgaffinetransform
    // https://en.wikipedia.org/wiki/File:2D_affine_transformation_matrix.svg
    NSInteger rotationDegrees =
        (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));

    CGAffineTransform t = _preferredTransform;
    NSLog(@"atan2: %f", atan2(_preferredTransform.b, _preferredTransform.a));
    NSLog(@"Rotation degrees: %d \tFrom (a, b, c, d, tx, ty): (%f, %f, %f, %f, %f, %f)",
          (int)rotationDegrees, t.a, t.b, t.c, t.d, t.tx, t.ty);

    _eventSink(@{
      @"event" : @"initialized",
      @"duration" : @([self duration]),
      @"width" : @(size.width),
      @"height" : @(size.height),
      @"rotationDegrees" : @(rotationDegrees),
    });
  }
}

- (void)play {
  _isPlaying = true;
  [self updatePlayingState];
}

- (void)pause {
  _isPlaying = false;
  [self updatePlayingState];
}

- (int64_t)position {
  return FLTCMTimeToMillis([_player currentTime]);
}

- (int64_t)duration {
  return FLTCMTimeToMillis([[_player currentItem] duration]);
}

- (void)seekTo:(int)location {
  [_player seekToTime:CMTimeMake(location, 1000)
      toleranceBefore:kCMTimeZero
       toleranceAfter:kCMTimeZero];
}

- (void)setIsLooping:(bool)isLooping {
  _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
  _player.volume = (volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume);
}

- (CVPixelBufferRef)copyPixelBuffer {
  CMTime outputItemTime = [_videoOutput itemTimeForHostTime:CACurrentMediaTime()];
  if ([_videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
    return [_videoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
  } else {
    return NULL;
  }
}

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  _eventSink = events;
  [self sendInitialized];
  return nil;
}

- (void)dispose {
  _disposed = true;
  [_displayLink invalidate];
  [[_player currentItem] removeObserver:self forKeyPath:@"status" context:statusContext];
  [[_player currentItem] removeObserver:self
                             forKeyPath:@"loadedTimeRanges"
                                context:timeRangeContext];
  [[_player currentItem] removeObserver:self
                             forKeyPath:@"playbackLikelyToKeepUp"
                                context:playbackLikelyToKeepUpContext];
  [[_player currentItem] removeObserver:self
                             forKeyPath:@"playbackBufferEmpty"
                                context:playbackBufferEmptyContext];
  [[_player currentItem] removeObserver:self
                             forKeyPath:@"playbackBufferFull"
                                context:playbackBufferFullContext];
  [_player replaceCurrentItemWithPlayerItem:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_eventChannel setStreamHandler:nil];
}

@end

@interface FLTVideoPlayerPlugin ()
@property(readonly, nonatomic) NSObject<FlutterTextureRegistry>* registry;
@property(readonly, nonatomic) NSObject<FlutterBinaryMessenger>* messenger;
@property(readonly, nonatomic) NSMutableDictionary* players;
@property(readonly, nonatomic) NSObject<FlutterPluginRegistrar>* registrar;

@end

@implementation FLTVideoPlayerPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:@"flutter.io/videoPlayer"
                                  binaryMessenger:[registrar messenger]];
  FLTVideoPlayerPlugin* instance = [[FLTVideoPlayerPlugin alloc] initWithRegistrar:registrar];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _registry = [registrar textures];
  _messenger = [registrar messenger];
  _registrar = registrar;
  _players = [NSMutableDictionary dictionaryWithCapacity:1];
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([@"init" isEqualToString:call.method]) {
    // Allow audio playback when the Ring/Silent switch is set to silent
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];

    for (NSNumber* textureId in _players) {
      [_registry unregisterTexture:[textureId unsignedIntegerValue]];
      [[_players objectForKey:textureId] dispose];
    }
    [_players removeAllObjects];
    result(nil);
  } else if ([@"create" isEqualToString:call.method]) {
    NSDictionary* argsMap = call.arguments;
    FLTFrameUpdater* frameUpdater = [[FLTFrameUpdater alloc] initWithRegistry:_registry];
    NSString* dataSource = argsMap[@"asset"];
    FLTVideoPlayer* player;
    if (dataSource) {
      NSString* assetPath;
      NSString* package = argsMap[@"package"];
      if (![package isEqual:[NSNull null]]) {
        assetPath = [_registrar lookupKeyForAsset:dataSource fromPackage:package];
      } else {
        assetPath = [_registrar lookupKeyForAsset:dataSource];
      }
      player = [[FLTVideoPlayer alloc] initWithAsset:assetPath frameUpdater:frameUpdater];
    } else {
      dataSource = argsMap[@"uri"];
      player = [[FLTVideoPlayer alloc] initWithURL:[NSURL URLWithString:dataSource]
                                      frameUpdater:frameUpdater];
    }
    int64_t textureId = [_registry registerTexture:player];
    frameUpdater.textureId = textureId;
    FlutterEventChannel* eventChannel = [FlutterEventChannel
        eventChannelWithName:[NSString stringWithFormat:@"flutter.io/videoPlayer/videoEvents%lld",
                                                        textureId]
             binaryMessenger:_messenger];
    [eventChannel setStreamHandler:player];
    player.eventChannel = eventChannel;
    _players[@(textureId)] = player;
    result(@{ @"textureId" : @(textureId) });
  } else {
    NSDictionary* argsMap = call.arguments;
    int64_t textureId = ((NSNumber*)argsMap[@"textureId"]).unsignedIntegerValue;
    FLTVideoPlayer* player = _players[@(textureId)];
    if ([@"dispose" isEqualToString:call.method]) {
      [_registry unregisterTexture:textureId];
      [_players removeObjectForKey:@(textureId)];
      [player dispose];
      result(nil);
    } else if ([@"setLooping" isEqualToString:call.method]) {
      [player setIsLooping:[[argsMap objectForKey:@"looping"] boolValue]];
      result(nil);
    } else if ([@"setVolume" isEqualToString:call.method]) {
      [player setVolume:[[argsMap objectForKey:@"volume"] doubleValue]];
      result(nil);
    } else if ([@"play" isEqualToString:call.method]) {
      [player play];
      result(nil);
    } else if ([@"position" isEqualToString:call.method]) {
      result(@([player position]));
    } else if ([@"seekTo" isEqualToString:call.method]) {
      [player seekTo:[[argsMap objectForKey:@"location"] intValue]];
      result(nil);
    } else if ([@"pause" isEqualToString:call.method]) {
      [player pause];
      result(nil);
    } else {
      result(FlutterMethodNotImplemented);
    }
  }
}

@end
