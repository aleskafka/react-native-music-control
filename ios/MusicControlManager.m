#import "MusicControlManager.h"
#import <React/RCTConvert.h>
#import <React/RCTBridge.h>
#import <React/RCTEventDispatcher.h>
#import <AVFoundation/AVFoundation.h>

@import MediaPlayer;

@interface MusicControlManager ()

@property (nonatomic, strong) NSDictionary *controlDict;
@property (nonatomic, strong) NSMutableDictionary *mediaDict;
@property (nonatomic, strong) NSArray *controls;
@property (nonatomic, copy) NSString *artworkUrl;
@property (nonatomic, copy) NSString *artworkCommited;
@property (nonatomic, assign) BOOL audioInterruptionsObserved;

@end

#define MEDIA_STATE_PLAYING @"STATE_PLAYING"
#define MEDIA_STATE_PAUSED @"STATE_PAUSED"
#define MEDIA_SPEED @"speed"
#define MEDIA_STATE @"state"
#define MEDIA_DICT @{@"album": MPMediaItemPropertyAlbumTitle, \
    @"trackCount": MPMediaItemPropertyAlbumTrackCount, \
    @"trackNumber": MPMediaItemPropertyAlbumTrackNumber, \
    @"artist": MPMediaItemPropertyArtist, \
    @"composer": MPMediaItemPropertyComposer, \
    @"discCount": MPMediaItemPropertyDiscCount, \
    @"discNumber": MPMediaItemPropertyDiscNumber, \
    @"genre": MPMediaItemPropertyGenre, \
    @"persistentID": MPMediaItemPropertyPersistentID, \
    @"duration": MPMediaItemPropertyPlaybackDuration, \
    @"title": MPMediaItemPropertyTitle, \
    @"elapsedTime": MPNowPlayingInfoPropertyElapsedPlaybackTime, \
    MEDIA_SPEED: MPNowPlayingInfoPropertyPlaybackRate, \
    @"playbackQueueIndex": MPNowPlayingInfoPropertyPlaybackQueueIndex, \
    @"playbackQueueCount": MPNowPlayingInfoPropertyPlaybackQueueCount, \
    @"chapterNumber": MPNowPlayingInfoPropertyChapterNumber, \
    @"chapterCount": MPNowPlayingInfoPropertyChapterCount \
}

@implementation MusicControlManager

@synthesize bridge = _bridge;

RCT_EXPORT_MODULE()

- (NSDictionary *)constantsToExport
{
    return @{
        @"STATE_PLAYING": MEDIA_STATE_PLAYING,
        @"STATE_PAUSED": MEDIA_STATE_PAUSED
    };
}

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}


RCT_EXPORT_METHOD(updatePlaying:(NSDictionary *) state withDetails:(NSDictionary *) details withControls:(NSArray *)controls)
{
    self.mediaDict = [NSMutableDictionary dictionary];
    self.controls = controls;

    for (NSString *key in MEDIA_DICT) {
        if ([details objectForKey:key] != nil) {
            [self.mediaDict setValue:[details objectForKey:key] forKey:[MEDIA_DICT objectForKey:key]];
        }

        if ([state objectForKey:key] != nil) {
            [self.mediaDict setValue:[state objectForKey:key] forKey:[MEDIA_DICT objectForKey:key]];
        }
    }

    // Set the playback rate from the state if no speed has been defined
    // If they provide the speed, then use it
    if ([state objectForKey:MEDIA_STATE] != nil && [state objectForKey:MEDIA_SPEED] == nil) {
        NSNumber *speed = [[state objectForKey:MEDIA_STATE] isEqual:MEDIA_STATE_PAUSED]
        ? [NSNumber numberWithDouble:0]
        : [NSNumber numberWithDouble:1];

        [self.mediaDict setValue:speed forKey:MEDIA_SPEED];
    }

    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];

    NSString *artworkUrl = [self getArtworkUrl:[details objectForKey:@"artwork"]];


    if ([artworkUrl isEqual:self.artworkCommited]) {
        if (center.nowPlayingInfo == nil) {
            [self.mediaDict setValue:nil forKey:MPMediaItemPropertyArtwork];

        } else {
            NSMutableDictionary *nowPlayingInfo = [[NSMutableDictionary alloc] initWithDictionary: center.nowPlayingInfo];
            [self.mediaDict setValue:[nowPlayingInfo objectForKey:MPMediaItemPropertyArtwork] forKey:MPMediaItemPropertyArtwork];
        }

        [self commitCenter];

    } else {
        self.artworkCommited = nil;

        if (artworkUrl == nil || [artworkUrl isEqual: @""]) {
            self.artworkUrl = nil;
            [self.mediaDict setValue:nil forKey:MPMediaItemPropertyArtwork];
            [self commitCenter];

        } else if (self.artworkUrl != artworkUrl) {
            self.artworkUrl = artworkUrl;
            [self commitArtwork:artworkUrl];
        }
    }
}

RCT_EXPORT_METHOD(reset)
{
    self.artworkUrl = nil;
    self.artworkCommited = nil;

    for (NSString *key in self.controlDict) {
        SEL handlerSEL = NSSelectorFromString([[self.controlDict objectForKey:key] objectForKey:@"selector"]);
        [self toggleHandler:[[self.controlDict objectForKey:key] objectForKey:@"handler"] withSelector:handlerSEL enabled:false];
    }

    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
    center.nowPlayingInfo = nil;
}

RCT_EXPORT_METHOD(enableControl:(NSString *) controlName enabled:(BOOL) enabled options:(NSDictionary *)options)
{
    NSDictionary *control = [self.controlDict objectForKey:controlName];

    if (control != nil) {
        if ([control objectForKey:@"interval"] && options[@"interval"]) {
            MPSkipIntervalCommand *handler = [control objectForKey:@"handler"];
            handler.preferredIntervals = @[options[@"interval"]];
        }

        SEL handlerSEL = NSSelectorFromString([control objectForKey:@"selector"]);
        [self toggleHandler:[control objectForKey:@"handler"] withSelector:handlerSEL enabled:enabled];
    }
}

/* We need to set the category to allow remote control etc... */

RCT_EXPORT_METHOD(enableBackgroundMode:(BOOL) enabled){
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory: AVAudioSessionCategoryPlayback error: nil];
    [session setActive: enabled error: nil];
}

RCT_EXPORT_METHOD(stopControl){
    [self stop];
}

RCT_EXPORT_METHOD(observeAudioInterruptions:(BOOL) observe){
    if (self.audioInterruptionsObserved == observe) {
        return;
    }
    if (observe) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];
    } else {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionInterruptionNotification object:nil];
    }
    self.audioInterruptionsObserved = observe;
}

#pragma mark internal

- (id)init {
    self = [super init];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioHardwareRouteChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    self.audioInterruptionsObserved = false;

    MPRemoteCommandCenter *remoteCenter = [MPRemoteCommandCenter sharedCommandCenter];

    self.controlDict = @{
        @"pause": @{
            @"handler": remoteCenter.pauseCommand,
            @"selector": NSStringFromSelector(@selector(onPause:))
        },
        @"play": @{
            @"handler": remoteCenter.playCommand,
            @"selector": NSStringFromSelector(@selector(onPlay:))
        },
        @"changePlaybackPosition": @{
            @"handler": remoteCenter.changePlaybackPositionCommand,
            @"selector": NSStringFromSelector(@selector(onChangePlaybackPosition:))
        },
        @"stop": @{
            @"handler": remoteCenter.stopCommand,
            @"selector": NSStringFromSelector(@selector(onStop:))
        },
        @"togglePlayPause": @{
            @"handler": remoteCenter.togglePlayPauseCommand,
            @"selector": NSStringFromSelector(@selector(onTogglePlayPause:))
        },
        @"enableLanguageOption": @{
            @"handler": remoteCenter.enableLanguageOptionCommand,
            @"selector": NSStringFromSelector(@selector(onEnableLanguageOption:))
        },
        @"disableLanguageOption": @{
            @"handler": remoteCenter.disableLanguageOptionCommand,
            @"selector": NSStringFromSelector(@selector(onDisableLanguageOption:))
        },
        @"nextTrack": @{
            @"handler": remoteCenter.nextTrackCommand,
            @"selector": NSStringFromSelector(@selector(onNextTrack:))
        },
        @"previousTrack": @{
            @"handler": remoteCenter.previousTrackCommand,
            @"selector": NSStringFromSelector(@selector(onPreviousTrack:))
        },
        @"seekForward": @{
            @"handler": remoteCenter.seekForwardCommand,
            @"selector": NSStringFromSelector(@selector(onSeekForward:))
        },
        @"seekBackward": @{
            @"handler": remoteCenter.seekBackwardCommand,
            @"selector": NSStringFromSelector(@selector(onSeekBackward:))
        },
        @"skipForward": @{
            @"handler": remoteCenter.skipForwardCommand,
            @"selector": NSStringFromSelector(@selector(onSkipForward:)),
            @"interval": @YES
        },
        @"skipBackward": @{
            @"handler": remoteCenter.skipBackwardCommand,
            @"selector": NSStringFromSelector(@selector(onSkipBackward:)),
            @"interval": @YES
        }
    };

    return self;
}

- (void) toggleHandler:(MPRemoteCommand *) command withSelector:(SEL) selector enabled:(BOOL) enabled {
    [command removeTarget:self action:selector];
    if(enabled){
        [command addTarget:self action:selector];
    }
    command.enabled = enabled;
}

+ (BOOL)requiresMainQueueSetup
{
    return YES;
}

- (void)dealloc {
    [self stop];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionRouteChangeNotification object:nil];
}

- (void)stop {
    [self reset];
    [self observeAudioInterruptions:false];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVAudioSessionRouteChangeNotification object:nil];
}

- (void)onPause:(MPRemoteCommandEvent*)event { [self sendEvent:@"pause"]; }
- (void)onPlay:(MPRemoteCommandEvent*)event { [self sendEvent:@"play"]; }
- (void)onChangePlaybackPosition:(MPChangePlaybackPositionCommandEvent*)event { [self sendEventWithValue:@"changePlaybackPosition" withValue:[NSString stringWithFormat:@"%.15f", event.positionTime]]; }
- (void)onStop:(MPRemoteCommandEvent*)event { [self sendEvent:@"stop"]; }
- (void)onTogglePlayPause:(MPRemoteCommandEvent*)event { [self sendEvent:@"togglePlayPause"]; }
- (void)onEnableLanguageOption:(MPRemoteCommandEvent*)event { [self sendEvent:@"enableLanguageOption"]; }
- (void)onDisableLanguageOption:(MPRemoteCommandEvent*)event { [self sendEvent:@"disableLanguageOption"]; }
- (void)onNextTrack:(MPRemoteCommandEvent*)event { [self sendEvent:@"nextTrack"]; }
- (void)onPreviousTrack:(MPRemoteCommandEvent*)event { [self sendEvent:@"previousTrack"]; }
- (void)onSeekForward:(MPRemoteCommandEvent*)event { [self sendEvent:@"seekForward"]; }
- (void)onSeekBackward:(MPRemoteCommandEvent*)event { [self sendEvent:@"seekBackward"]; }
- (void)onSkipBackward:(MPRemoteCommandEvent*)event { [self sendEvent:@"skipBackward"]; }
- (void)onSkipForward:(MPRemoteCommandEvent*)event { [self sendEvent:@"skipForward"]; }

- (NSArray<NSString *> *)supportedEvents {
    return @[@"RNMusicControlEvent"];
}

- (void)sendEvent:(NSString*)event {
    [self sendEventWithName:@"RNMusicControlEvent"
                       body:@{@"name": event}];
}

- (NSString*)getArtworkUrl:(NSString*)artwork {
  NSString *artworkUrl = nil;

  if (artwork) {
      if ([artwork isKindOfClass:[NSString class]]) {
           artworkUrl = artwork;
      } else if ([[artwork valueForKey: @"uri"] isKindOfClass:[NSString class]]) {
           artworkUrl = [artwork valueForKey: @"uri"];
      }
  }

  return artworkUrl;
}

- (void)sendEventWithValue:(NSString*)event withValue:(NSString*)value{
   [self sendEventWithName:@"RNMusicControlEvent" body:@{@"name": event, @"value":value}];
}

- (void)commitCenter {
    MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];

    center.nowPlayingInfo = self.mediaDict;

    for (NSString *key in self.controlDict) {
        [self enableControl:key enabled:[self.controls containsObject:key] options:nil];
    }
}

- (void)commitArtwork:(id)artworkUrl
{
    // Custom handling of artwork in another thread, will be loaded async
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        UIImage *image = nil;
        // artwork is url download from the interwebs
        if ([artworkUrl hasPrefix: @"http://"] || [artworkUrl hasPrefix: @"https://"]) {
            NSURL *imageURL = [NSURL URLWithString:artworkUrl];
            NSData *imageData = [NSData dataWithContentsOfURL:imageURL];
            image = [UIImage imageWithData:imageData];
        } else {
            NSString *localArtworkUrl = [artworkUrl stringByReplacingOccurrencesOfString:@"file://" withString:@""];
            BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:localArtworkUrl];
            if (fileExists) {
                image = [UIImage imageNamed:localArtworkUrl];
            }
        }

        if (image != nil) {
            // check whether image is loaded
            CGImageRef cgref = [image CGImage];
            CIImage *cim = [image CIImage];

            if (cim == nil && cgref == NULL) {
                image = nil;
            }
        }

        MPMediaItemArtwork *artwork = nil;

        if (image != nil) {
            artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:CGSizeMake(600, 600) requestHandler:^UIImage * _Nonnull(CGSize size) {
                UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
                [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
                UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                return newImage;
            }];
        }

        if ([artworkUrl isEqual:self.artworkUrl]) {
            self.artworkCommited = artworkUrl;
            [self.mediaDict setValue:artwork forKey:MPMediaItemPropertyArtwork];
            [self commitCenter];
        }
    });
}

- (void)audioHardwareRouteChanged:(NSNotification *)notification {
    NSInteger routeChangeReason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
    if (routeChangeReason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        //headphones unplugged or bluetooth device disconnected, iOS will pause audio
        [self sendEvent:@"pause"];
    }
}

- (void)audioInterrupted:(NSNotification *)notification {
    if (!self.audioInterruptionsObserved) {
        return;
    }
    NSInteger interruptionType = [notification.userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
    NSInteger interruptionOption = [notification.userInfo[AVAudioSessionInterruptionOptionKey] integerValue];

    if (interruptionType == AVAudioSessionInterruptionTypeBegan) {
        // Playback interrupted by an incoming phone call.
        [self sendEvent:@"pause"];
    }
    if (interruptionType == AVAudioSessionInterruptionTypeEnded &&
           interruptionOption == AVAudioSessionInterruptionOptionShouldResume) {
        [self sendEvent:@"play"];
    }
}

@end
