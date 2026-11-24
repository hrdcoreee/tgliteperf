#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TGLitePerfSettings : NSObject

+ (instancetype)shared;

@property (nonatomic, assign) BOOL tweakEnabled;
@property (nonatomic, assign) BOOL disableAllBlurs;
@property (nonatomic, assign) BOOL disableBlurAndGlass;
@property (nonatomic, assign) BOOL forceLowPowerOptimizations;
@property (nonatomic, assign) BOOL disableGalleryLiveCamera;
@property (nonatomic, assign) BOOL hideGalleryCamera;
@property (nonatomic, assign) BOOL disableSwipeToStoryCamera;
@property (nonatomic, assign) BOOL disableSnapDeletionEffect;
@property (nonatomic, assign) BOOL throttleParticles;
@property (nonatomic, assign) BOOL disableOffscreenShadows;
@property (nonatomic, assign) BOOL disableUpdateChecks;

@property (nonatomic, readonly) BOOL isOlderDeviceDetected;
@property (nonatomic, readonly) NSString *deviceSummary;

// Cached fast-path getters (no UserDefaults overhead in CALayer/render hot paths)
- (BOOL)effectiveDisableAllBlurs;
- (BOOL)effectiveDisableBlurAndGlass;
- (BOOL)effectiveLowPowerOptimizations;
- (BOOL)effectiveDisableGalleryLiveCamera;
- (BOOL)effectiveThrottleParticles;
- (BOOL)effectiveDisableOffscreenShadows;
- (BOOL)effectiveDisableUpdateChecks;

- (void)syncSwiftgramDefaults;

@end

NS_ASSUME_NONNULL_END
