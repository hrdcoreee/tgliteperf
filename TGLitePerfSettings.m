#import "TGLitePerfSettings.h"
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

static NSString * const kKeyTweakEnabled              = @"TGLitePerf_tweakEnabled";
static NSString * const kKeyDisableAllBlurs          = @"TGLitePerf_disableAllBlurs";
static NSString * const kKeyDisableBlurAndGlass       = @"TGLitePerf_disableBlurAndGlass";
static NSString * const kKeyForceLowPower             = @"TGLitePerf_forceLowPowerOptimizations";
static NSString * const kKeyDisableGalleryLiveCamera  = @"TGLitePerf_disableGalleryLiveCamera";
static NSString * const kKeyHideGalleryCamera         = @"TGLitePerf_hideGalleryCamera";
static NSString * const kKeyDisableSwipeToStory       = @"TGLitePerf_disableSwipeToStoryCamera";
static NSString * const kKeyDisableSnapDeletion       = @"TGLitePerf_disableSnapDeletionEffect";
static NSString * const kKeyThrottleParticles         = @"TGLitePerf_throttleParticles";
static NSString * const kKeyDisableOffscreenShadows   = @"TGLitePerf_disableOffscreenShadows";
static NSString * const kKeyDisableUpdateChecks       = @"TGLitePerf_disableUpdateChecks";

@implementation TGLitePerfSettings {
    BOOL _tweakEnabled;
    BOOL _disableAllBlurs;
    BOOL _disableBlurAndGlass;
    BOOL _forceLowPowerOptimizations;
    BOOL _disableGalleryLiveCamera;
    BOOL _hideGalleryCamera;
    BOOL _disableSwipeToStoryCamera;
    BOOL _disableSnapDeletionEffect;
    BOOL _throttleParticles;
    BOOL _disableOffscreenShadows;
    BOOL _disableUpdateChecks;

    BOOL _isOlderDeviceDetected;
    NSString *_deviceSummary;
}

+ (instancetype)shared {
    static TGLitePerfSettings *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TGLitePerfSettings alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self detectHardware];
        [self loadPreferences];
        [self syncSwiftgramDefaults];
    }
    return self;
}

- (void)detectHardware {
    uint64_t memSize = 0;
    size_t memLen = sizeof(memSize);
    sysctlbyname("hw.memsize", &memSize, &memLen, NULL, 0);
    double ramGB = (double)memSize / (1024.0 * 1024.0 * 1024.0);

    struct utsname sysInfo;
    uname(&sysInfo);
    NSString *machine = [NSString stringWithUTF8String:sysInfo.machine] ?: @"unknown";

    BOOL olderModel = NO;
    if ([machine hasPrefix:@"iPod"]) {
        olderModel = YES;
    } else if ([machine hasPrefix:@"iPhone"]) {
        NSString *versionPart = [machine substringFromIndex:6];
        NSArray<NSString *> *parts = [versionPart componentsSeparatedByString:@","];
        if (parts.count > 0) {
            NSInteger major = [parts[0] integerValue];
            // iPhone12,* = iPhone 11 / 11 Pro / SE 2nd Gen (A13) and older
            if (major > 0 && major <= 12) {
                olderModel = YES;
            }
        }
    }

    _isOlderDeviceDetected = (ramGB < 3.5) || olderModel;
    NSString *iosVersion = [UIDevice currentDevice].systemVersion ?: @"?";
    _deviceSummary = [NSString stringWithFormat:@"%@ • %.1f GB RAM • iOS %@", machine, ramGB, iosVersion];
}

- (void)loadPreferences {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud registerDefaults:@{
        kKeyTweakEnabled: @YES,
        kKeyDisableAllBlurs: @YES,
        kKeyDisableBlurAndGlass: @YES,
        kKeyForceLowPower: @YES,
        kKeyDisableGalleryLiveCamera: @YES,
        kKeyHideGalleryCamera: @NO,
        kKeyDisableSwipeToStory: @NO,
        kKeyDisableSnapDeletion: @YES,
        kKeyThrottleParticles: @YES,
        kKeyDisableOffscreenShadows: @YES,
        kKeyDisableUpdateChecks: @YES,
    }];

    _tweakEnabled = [ud boolForKey:kKeyTweakEnabled];
    _disableAllBlurs = [ud boolForKey:kKeyDisableAllBlurs];
    _disableBlurAndGlass = [ud boolForKey:kKeyDisableBlurAndGlass];
    _forceLowPowerOptimizations = [ud boolForKey:kKeyForceLowPower];
    _disableGalleryLiveCamera = [ud boolForKey:kKeyDisableGalleryLiveCamera];
    _hideGalleryCamera = [ud boolForKey:kKeyHideGalleryCamera];
    _disableSwipeToStoryCamera = [ud boolForKey:kKeyDisableSwipeToStory];
    _disableSnapDeletionEffect = [ud boolForKey:kKeyDisableSnapDeletion];
    _throttleParticles = [ud boolForKey:kKeyThrottleParticles];
    _disableOffscreenShadows = [ud boolForKey:kKeyDisableOffscreenShadows];
    _disableUpdateChecks = [ud boolForKey:kKeyDisableUpdateChecks];
}

- (void)syncSwiftgramDefaults {
    if (!_tweakEnabled) {
        return;
    }
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:_disableGalleryLiveCamera forKey:@"disableGalleryCameraPreview"];
    [ud setBool:_hideGalleryCamera forKey:@"disableGalleryCamera"];
    [ud setBool:_disableSwipeToStoryCamera forKey:@"disableSwipeToRecordStory"];
    [ud setBool:_disableSnapDeletionEffect forKey:@"disableSnapDeletionEffect"];
    [ud setBool:(_disableBlurAndGlass || _disableAllBlurs) forKey:@"disableGlassEffects"];
}

#pragma mark - Fast Getters

- (BOOL)effectiveDisableAllBlurs {
    return _tweakEnabled && _disableAllBlurs;
}

- (BOOL)effectiveDisableBlurAndGlass {
    return _tweakEnabled && (_disableBlurAndGlass || _disableAllBlurs);
}

- (BOOL)effectiveLowPowerOptimizations {
    return _tweakEnabled && _forceLowPowerOptimizations;
}

- (BOOL)effectiveDisableGalleryLiveCamera {
    return _tweakEnabled && _disableGalleryLiveCamera;
}

- (BOOL)effectiveThrottleParticles {
    return _tweakEnabled && _throttleParticles;
}

- (BOOL)effectiveDisableOffscreenShadows {
    return _tweakEnabled && _disableOffscreenShadows;
}

- (BOOL)effectiveDisableUpdateChecks {
    return _tweakEnabled && _disableUpdateChecks;
}

#pragma mark - Setters

- (void)setTweakEnabled:(BOOL)value {
    _tweakEnabled = value;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kKeyTweakEnabled];
    [self syncSwiftgramDefaults];
}

- (void)setDisableAllBlurs:(BOOL)value {
    _disableAllBlurs = value;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kKeyDisableAllBlurs];
    [self syncSwiftgramDefaults];
}

- (void)setDisableBlurAndGlass:(BOOL)value {
    _disableBlurAndGlass = value;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kKeyDisableBlurAndGlass];
    [self syncSwiftgramDefaults];
}

- (void)setForceLowPowerOptimizations:(BOOL)value {
    _forceLowPowerOptimizations = value;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kKeyForceLowPower];
}

- (void)setDisableGalleryLiveCamera:(BOOL)value {
    _disableGalleryLiveCamera = value;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kKeyDisableGalleryLiveCamera];
    [self syncSwiftgramDefaults];
}

- (void)setHideGalleryCamera:(BOOL)value {
    _hideGalleryCamera = value;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kKeyHideGalleryCamera];
    [self syncSwiftgramDefaults];
}

- (void)setDisableSwipeToStoryCamera:(BOOL)value {
    _disableSwipeToStoryCamera = value;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kKeyDisableSwipeToStory];
    [self syncSwiftgramDefaults];
}

- (void)setDisableSnapDeletionEffect:(BOOL)value {
    _disableSnapDeletionEffect = value;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kKeyDisableSnapDeletion];
    [self syncSwiftgramDefaults];
}

- (void)setThrottleParticles:(BOOL)value {
    _throttleParticles = value;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kKeyThrottleParticles];
}

- (void)setDisableOffscreenShadows:(BOOL)value {
    _disableOffscreenShadows = value;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kKeyDisableOffscreenShadows];
}

- (void)setDisableUpdateChecks:(BOOL)value {
    _disableUpdateChecks = value;
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:kKeyDisableUpdateChecks];
}

@end
