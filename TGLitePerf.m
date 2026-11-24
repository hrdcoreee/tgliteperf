#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <string.h>

#import "fishhook.h"
#import "TGLitePerfSettings.h"
#import "TGLitePerfPrefsController.h"

#pragma mark - Globals & Helpers

static Class gCABackdropLayerClass = Nil;
static Class gUIGlassEffectClass = Nil;
static char kTGLiteGesturesAttachedKey;

static NSString *gMainBundlePath = nil;
static const char *gSelfImageName = NULL;

static BOOL (*orig_UIAccessibilityIsReduceTransparencyEnabled)(void) = NULL;

static BOOL hooked_UIAccessibilityIsReduceTransparencyEnabled(void) {
    if ([TGLitePerfSettings shared].effectiveDisableBlurAndGlass) {
        return YES;
    }
    if (orig_UIAccessibilityIsReduceTransparencyEnabled) {
        return orig_UIAccessibilityIsReduceTransparencyEnabled();
    }
    return NO;
}

static void TGLiteRebindForImage(const struct mach_header *header, intptr_t slide) {
    if (!header || !gMainBundlePath) {
        return;
    }
    Dl_info info;
    if (dladdr(header, &info) == 0 || !info.dli_fname) {
        return;
    }
    if (gSelfImageName && strcmp(info.dli_fname, gSelfImageName) == 0) {
        return;
    }
    // Only patch images inside the main app bundle (App executable + TelegramUIFramework + Display, etc.)
    if (strncmp(info.dli_fname, gMainBundlePath.UTF8String, strlen(gMainBundlePath.UTF8String)) != 0) {
        return;
    }
    struct rebinding rebindings[1] = {
        {
            "UIAccessibilityIsReduceTransparencyEnabled",
            (void *)hooked_UIAccessibilityIsReduceTransparencyEnabled,
            (void **)&orig_UIAccessibilityIsReduceTransparencyEnabled
        }
    };
    rebind_symbols_image((void *)header, slide, rebindings, 1);
}

static IMP TGLiteSwizzleMethod(Class cls, SEL selector, IMP replacement) {
    if (!cls) return NULL;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    } else {
        method_setImplementation(method, replacement);
    }
    return original;
}

#pragma mark - CALayer & CABackdropLayer Hooks

static void (*orig_CALayer_setValueForKey)(id, SEL, id, NSString *) = NULL;
static void hooked_CALayer_setValueForKey(CALayer *self, SEL _cmd, id value, NSString *key) {
    if ([key isEqualToString:@"meshTransform"] && [TGLitePerfSettings shared].effectiveDisableBlurAndGlass) {
        return;
    }
    orig_CALayer_setValueForKey(self, _cmd, value, key);
}

static void (*orig_CALayer_addAnimationForKey)(id, SEL, CAAnimation *, NSString *) = NULL;
static void hooked_CALayer_addAnimationForKey(CALayer *self, SEL _cmd, CAAnimation *anim, NSString *key) {
    if ([key isEqualToString:@"meshTransform"] && [TGLitePerfSettings shared].effectiveDisableBlurAndGlass) {
        return;
    }
    orig_CALayer_addAnimationForKey(self, _cmd, anim, key);
}

static void (*orig_CALayer_setFilters)(id, SEL, NSArray *) = NULL;
static void hooked_CALayer_setFilters(CALayer *self, SEL _cmd, NSArray *filters) {
    if (gCABackdropLayerClass && [self isKindOfClass:gCABackdropLayerClass] &&
        [TGLitePerfSettings shared].effectiveDisableBlurAndGlass) {
        orig_CALayer_setFilters(self, _cmd, nil);
        return;
    }
    orig_CALayer_setFilters(self, _cmd, filters);
}

static void (*orig_CABackdropLayer_setEnabled)(id, SEL, BOOL) = NULL;
static void hooked_CABackdropLayer_setEnabled(id self, SEL _cmd, BOOL enabled) {
    if ([TGLitePerfSettings shared].effectiveDisableBlurAndGlass) {
        orig_CABackdropLayer_setEnabled(self, _cmd, NO);
        return;
    }
    orig_CABackdropLayer_setEnabled(self, _cmd, enabled);
}

static void (*orig_CALayer_setShadowOpacity)(id, SEL, float) = NULL;
static void hooked_CALayer_setShadowOpacity(CALayer *self, SEL _cmd, float opacity) {
    if (opacity > 0.0f && !self.shadowPath && [TGLitePerfSettings shared].effectiveDisableOffscreenShadows) {
        id delegate = self.delegate;
        if ([delegate isKindOfClass:[UIView class]]) {
            NSString *clsName = NSStringFromClass([delegate class]);
            if ([clsName containsString:@"Hosting"] ||
                [clsName containsString:@"CGDrawing"] ||
                [clsName containsString:@"PlatformView"] ||
                [clsName containsString:@"LegacyGlass"]) {
                orig_CALayer_setShadowOpacity(self, _cmd, 0.0f);
                return;
            }
        }
    }
    orig_CALayer_setShadowOpacity(self, _cmd, opacity);
}

#pragma mark - UIVisualEffectView (iOS 26+ UIGlassEffect fallback)

static void TGLiteApplyFlatGlassFallback(UIVisualEffectView *view) {
    BOOL isDark = (view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    view.backgroundColor = isDark
        ? [UIColor colorWithWhite:0.14 alpha:0.86]
        : [UIColor colorWithWhite:0.96 alpha:0.86];
}

static id (*orig_UIVisualEffectView_initWithEffect)(id, SEL, UIVisualEffect *) = NULL;
static id hooked_UIVisualEffectView_initWithEffect(UIVisualEffectView *self, SEL _cmd, UIVisualEffect *effect) {
    BOOL isGlass = (gUIGlassEffectClass && effect && [effect isKindOfClass:gUIGlassEffectClass]);
    if (isGlass && [TGLitePerfSettings shared].effectiveDisableBlurAndGlass) {
        UIVisualEffectView *res = orig_UIVisualEffectView_initWithEffect(self, _cmd, nil);
        if (res) {
            TGLiteApplyFlatGlassFallback(res);
        }
        return res;
    }
    return orig_UIVisualEffectView_initWithEffect(self, _cmd, effect);
}

static void (*orig_UIVisualEffectView_setEffect)(id, SEL, UIVisualEffect *) = NULL;
static void hooked_UIVisualEffectView_setEffect(UIVisualEffectView *self, SEL _cmd, UIVisualEffect *effect) {
    BOOL isGlass = (gUIGlassEffectClass && effect && [effect isKindOfClass:gUIGlassEffectClass]);
    if (isGlass && [TGLitePerfSettings shared].effectiveDisableBlurAndGlass) {
        orig_UIVisualEffectView_setEffect(self, _cmd, nil);
        TGLiteApplyFlatGlassFallback(self);
        return;
    }
    orig_UIVisualEffectView_setEffect(self, _cmd, effect);
}

#pragma mark - NSProcessInfo (30 FPS Emoji / Low-Power Code Paths)

static BOOL (*orig_NSProcessInfo_isLowPowerModeEnabled)(id, SEL) = NULL;
static BOOL hooked_NSProcessInfo_isLowPowerModeEnabled(NSProcessInfo *self, SEL _cmd) {
    if ([TGLitePerfSettings shared].effectiveLowPowerOptimizations) {
        return YES;
    }
    return orig_NSProcessInfo_isLowPowerModeEnabled(self, _cmd);
}

#pragma mark - CAEmitterLayer Throttling

static void (*orig_CAEmitterLayer_setBirthRate)(id, SEL, float) = NULL;
static void hooked_CAEmitterLayer_setBirthRate(CAEmitterLayer *self, SEL _cmd, float birthRate) {
    if (birthRate > 0.0f && [TGLitePerfSettings shared].effectiveThrottleParticles) {
        birthRate = fmaxf(0.15f, birthRate * 0.25f);
    }
    orig_CAEmitterLayer_setBirthRate(self, _cmd, birthRate);
}

static void (*orig_CAEmitterLayer_setSpeed)(id, SEL, float) = NULL;
static void hooked_CAEmitterLayer_setSpeed(CAEmitterLayer *self, SEL _cmd, float speed) {
    if (speed > 0.4f && [TGLitePerfSettings shared].effectiveThrottleParticles) {
        speed = 0.4f;
    }
    orig_CAEmitterLayer_setSpeed(self, _cmd, speed);
}

#pragma mark - AVCaptureVideoPreviewLayer (Gallery Live Camera Suppression)

static BOOL TGLiteIsInsideMediaPickerCell(CALayer *layer) {
    id delegate = layer.delegate;
    if (![delegate isKindOfClass:[UIView class]]) {
        return NO;
    }
    UIResponder *responder = (UIView *)delegate;
    for (int i = 0; i < 14 && responder != nil; i++) {
        NSString *clsName = NSStringFromClass([responder class]);
        if ([clsName containsString:@"CameraScreen"] ||
            [clsName containsString:@"VideoMessageCamera"] ||
            [clsName containsString:@"QrCodeScan"]) {
            return NO;
        }
        if ([clsName containsString:@"MediaPicker"]) {
            return YES;
        }
        responder = [responder nextResponder];
    }
    return NO;
}

static void (*orig_AVCaptureVideoPreviewLayer_layoutSublayers)(id, SEL) = NULL;
static void hooked_AVCaptureVideoPreviewLayer_layoutSublayers(AVCaptureVideoPreviewLayer *self, SEL _cmd) {
    orig_AVCaptureVideoPreviewLayer_layoutSublayers(self, _cmd);
    if ([TGLitePerfSettings shared].effectiveDisableGalleryLiveCamera && TGLiteIsInsideMediaPickerCell(self)) {
        if (self.connection.isEnabled) {
            self.connection.enabled = NO;
        }
        if (!self.isHidden) {
            self.hidden = YES;
        }
    }
}

#pragma mark - Settings Gesture & Onboarding Toast

@interface TGLiteGestureDelegate : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@end

@implementation TGLiteGestureDelegate

+ (instancetype)shared {
    static TGLiteGestureDelegate *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TGLiteGestureDelegate alloc] init];
    });
    return instance;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if ([gestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
        UIView *view = gestureRecognizer.view;
        if (!view) return NO;
        CGPoint location = [gestureRecognizer locationInView:view];
        // Bottom tab bar zone only
        return location.y >= (view.bounds.size.height - 95.0);
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end

@interface TGLiteWindowHelper : NSObject
+ (void)attachToWindow:(UIWindow *)window;
@end

@implementation TGLiteWindowHelper

+ (void)handleOpenPrefsGesture:(UIGestureRecognizer *)gesture {
    if ([gesture isKindOfClass:[UILongPressGestureRecognizer class]]) {
        if (gesture.state != UIGestureRecognizerStateBegan) {
            return;
        }
    } else if (gesture.state != UIGestureRecognizerStateEnded) {
        return;
    }
    [TGLitePerfPrefsController presentFromTopViewController];
}

+ (void)attachToWindow:(UIWindow *)window {
    if (!window || objc_getAssociatedObject(window, &kTGLiteGesturesAttachedKey)) {
        return;
    }
    NSString *winClass = NSStringFromClass([window class]);
    if ([winClass containsString:@"Keyboard"] || [winClass containsString:@"StatusBar"] || [winClass containsString:@"TextEffects"]) {
        return;
    }
    objc_setAssociatedObject(window, &kTGLiteGesturesAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UITapGestureRecognizer *twoFingerTripleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleOpenPrefsGesture:)];
    twoFingerTripleTap.numberOfTouchesRequired = 2;
    twoFingerTripleTap.numberOfTapsRequired = 3;
    twoFingerTripleTap.cancelsTouchesInView = NO;
    twoFingerTripleTap.delaysTouchesBegan = NO;
    twoFingerTripleTap.delegate = [TGLiteGestureDelegate shared];
    [window addGestureRecognizer:twoFingerTripleTap];

    UILongPressGestureRecognizer *tabBarLongPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleOpenPrefsGesture:)];
    tabBarLongPress.minimumPressDuration = 0.85;
    tabBarLongPress.cancelsTouchesInView = NO;
    tabBarLongPress.delegate = [TGLiteGestureDelegate shared];
    [window addGestureRecognizer:tabBarLongPress];

    [self showOnboardingToastIfNeededInWindow:window];
}

+ (void)showOnboardingToastIfNeededInWindow:(UIWindow *)window {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *shownKey = @"TGLitePerf_onboardingToastShown_v1";
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if ([ud boolForKey:shownKey]) {
            return;
        }
        [ud setBool:YES forKey:shownKey];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!window.windowScene) return;
            NSString *lang = [NSLocale preferredLanguages].firstObject ?: @"en";
            BOOL isRu = [lang hasPrefix:@"ru"] || [lang hasPrefix:@"uk"] || [lang hasPrefix:@"be"];
            NSString *text = isRu
                ? @"TGLitePerf активен • Удерживайте низ экрана для меню"
                : @"TGLitePerf active • Hold bottom bar for settings";

            UILabel *label = [[UILabel alloc] init];
            label.text = text;
            label.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
            label.textColor = [UIColor whiteColor];
            label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
            label.textAlignment = NSTextAlignmentCenter;
            label.layer.cornerRadius = 16.0;
            label.layer.masksToBounds = YES;
            label.alpha = 0.0;

            CGSize size = [label sizeThatFits:CGSizeMake(window.bounds.size.width - 48.0, 44.0)];
            CGFloat w = MIN(window.bounds.size.width - 32.0, size.width + 28.0);
            CGFloat topInset = window.safeAreaInsets.top > 0 ? window.safeAreaInsets.top : 24.0;
            label.frame = CGRectMake((window.bounds.size.width - w) * 0.5, topInset + 8.0, w, 34.0);
            [window addSubview:label];

            [UIView animateWithDuration:0.25 animations:^{
                label.alpha = 1.0;
            } completion:^(BOOL finished) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:0.3 animations:^{
                        label.alpha = 0.0;
                    } completion:^(BOOL done) {
                        [label removeFromSuperview];
                    }];
                });
            }];
        });
    });
}

@end

static void (*orig_UIWindow_makeKeyAndVisible)(id, SEL) = NULL;
static void hooked_UIWindow_makeKeyAndVisible(UIWindow *self, SEL _cmd) {
    orig_UIWindow_makeKeyAndVisible(self, _cmd);
    [TGLiteWindowHelper attachToWindow:self];
}

static void (*orig_UIWindow_becomeKeyWindow)(id, SEL) = NULL;
static void hooked_UIWindow_becomeKeyWindow(UIWindow *self, SEL _cmd) {
    orig_UIWindow_becomeKeyWindow(self, _cmd);
    [TGLiteWindowHelper attachToWindow:self];
}

#pragma mark - Constructor

__attribute__((constructor))
static void TGLitePerfInit(void) {
    @autoreleasepool {
        // Initialize settings & sync Swiftgram UserDefaults before app delegates initialize
        [TGLitePerfSettings shared];

        gCABackdropLayerClass = NSClassFromString(@"CABackdropLayer");
        gUIGlassEffectClass = NSClassFromString(@"UIGlassEffect");

        gMainBundlePath = [[NSBundle mainBundle].bundlePath stringByResolvingSymlinksInPath];
        Dl_info selfInfo;
        if (dladdr((void *)TGLitePerfInit, &selfInfo) != 0) {
            gSelfImageName = selfInfo.dli_fname;
        }

        // 1. Fishhook UIAccessibilityIsReduceTransparencyEnabled across app images
        _dyld_register_func_for_add_image(TGLiteRebindForImage);

        // 2. Swizzle CALayer / CABackdropLayer
        orig_CALayer_setValueForKey = (void *)TGLiteSwizzleMethod(
            [CALayer class], @selector(setValue:forKey:), (IMP)hooked_CALayer_setValueForKey);
        orig_CALayer_addAnimationForKey = (void *)TGLiteSwizzleMethod(
            [CALayer class], @selector(addAnimation:forKey:), (IMP)hooked_CALayer_addAnimationForKey);
        orig_CALayer_setFilters = (void *)TGLiteSwizzleMethod(
            [CALayer class], @selector(setFilters:), (IMP)hooked_CALayer_setFilters);
        orig_CALayer_setShadowOpacity = (void *)TGLiteSwizzleMethod(
            [CALayer class], @selector(setShadowOpacity:), (IMP)hooked_CALayer_setShadowOpacity);

        if (gCABackdropLayerClass) {
            orig_CABackdropLayer_setEnabled = (void *)TGLiteSwizzleMethod(
                gCABackdropLayerClass, NSSelectorFromString(@"setEnabled:"), (IMP)hooked_CABackdropLayer_setEnabled);
        }

        // 3. Swizzle UIVisualEffectView for iOS 26+ UIGlassEffect
        if (gUIGlassEffectClass) {
            orig_UIVisualEffectView_initWithEffect = (void *)TGLiteSwizzleMethod(
                [UIVisualEffectView class], @selector(initWithEffect:), (IMP)hooked_UIVisualEffectView_initWithEffect);
            orig_UIVisualEffectView_setEffect = (void *)TGLiteSwizzleMethod(
                [UIVisualEffectView class], @selector(setEffect:), (IMP)hooked_UIVisualEffectView_setEffect);
        }

        // 4. Swizzle NSProcessInfo isLowPowerModeEnabled
        orig_NSProcessInfo_isLowPowerModeEnabled = (void *)TGLiteSwizzleMethod(
            [NSProcessInfo class], @selector(isLowPowerModeEnabled), (IMP)hooked_NSProcessInfo_isLowPowerModeEnabled);

        // 5. Swizzle CAEmitterLayer
        orig_CAEmitterLayer_setBirthRate = (void *)TGLiteSwizzleMethod(
            [CAEmitterLayer class], @selector(setBirthRate:), (IMP)hooked_CAEmitterLayer_setBirthRate);
        orig_CAEmitterLayer_setSpeed = (void *)TGLiteSwizzleMethod(
            [CAEmitterLayer class], @selector(setSpeed:), (IMP)hooked_CAEmitterLayer_setSpeed);

        // 6. Swizzle AVCaptureVideoPreviewLayer
        orig_AVCaptureVideoPreviewLayer_layoutSublayers = (void *)TGLiteSwizzleMethod(
            [AVCaptureVideoPreviewLayer class], @selector(layoutSublayers), (IMP)hooked_AVCaptureVideoPreviewLayer_layoutSublayers);

        // 7. Attach gesture triggers to UIWindows
        orig_UIWindow_makeKeyAndVisible = (void *)TGLiteSwizzleMethod(
            [UIWindow class], @selector(makeKeyAndVisible), (IMP)hooked_UIWindow_makeKeyAndVisible);
        orig_UIWindow_becomeKeyWindow = (void *)TGLiteSwizzleMethod(
            [UIWindow class], @selector(becomeKeyWindow), (IMP)hooked_UIWindow_becomeKeyWindow);
    }
}
