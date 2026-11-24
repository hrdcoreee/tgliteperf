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
static Class gUIKBBackdropViewClass = Nil;
static Class gUIKBInputBackdropViewClass = Nil;
static Class gUIBackdropViewClass = Nil;
static Class gUIInputAssistantHostViewClass = Nil;
static Class gTUISystemInputAssistantViewClass = Nil;
static char kTGLiteGesturesAttachedKey;
static char kTGLiteNeutralizedEffectKey;

static NSString *gMainBundlePath = nil;
static const char *gSelfImageName = NULL;

static __weak UIResponder *gTGLiteCurrentFirstResponder = nil;

@interface UIResponder (TGLitePerfFirstResponder)
- (void)tgLite_captureFirstResponder:(id)sender;
@end

@implementation UIResponder (TGLitePerfFirstResponder)
- (void)tgLite_captureFirstResponder:(id)sender {
    gTGLiteCurrentFirstResponder = self;
}
@end

static BOOL (*orig_UIAccessibilityIsReduceTransparencyEnabled)(void) = NULL;

static BOOL hooked_UIAccessibilityIsReduceTransparencyEnabled(void) {
    if ([TGLitePerfSettings shared].effectiveDisableBlurAndGlass || [TGLitePerfSettings shared].effectiveDisableAllBlurs) {
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
    if ([key isEqualToString:@"meshTransform"] && ([TGLitePerfSettings shared].effectiveDisableBlurAndGlass || [TGLitePerfSettings shared].effectiveDisableAllBlurs)) {
        return;
    }
    orig_CALayer_setValueForKey(self, _cmd, value, key);
}

static void (*orig_CALayer_addAnimationForKey)(id, SEL, CAAnimation *, NSString *) = NULL;
static void hooked_CALayer_addAnimationForKey(CALayer *self, SEL _cmd, CAAnimation *anim, NSString *key) {
    if ([key isEqualToString:@"meshTransform"] && ([TGLitePerfSettings shared].effectiveDisableBlurAndGlass || [TGLitePerfSettings shared].effectiveDisableAllBlurs)) {
        return;
    }
    orig_CALayer_addAnimationForKey(self, _cmd, anim, key);
}

static BOOL TGLiteIsKeyboardView(UIView *view);
static BOOL TGLiteIsTelegramDarkTheme(UIView *view);
static UIColor *TGLiteKeyboardColorForDark(BOOL isDark);

static void TGLiteApplyKeyboardBackdropLayerColorIfNeeded(CALayer *layer) {
    if (![NSThread isMainThread] || !layer) {
        return;
    }
    id delegate = layer.delegate;
    if ([delegate isKindOfClass:[UIView class]] && TGLiteIsKeyboardView((UIView *)delegate)) {
        NSString *clsName = NSStringFromClass([delegate class]);
        if ([clsName containsString:@"Backdrop"] ||
            [clsName containsString:@"Assistant"] ||
            [clsName containsString:@"Prediction"] ||
            [clsName containsString:@"Candidate"]) {
            layer.backgroundColor = TGLiteKeyboardColorForDark(TGLiteIsTelegramDarkTheme((UIView *)delegate)).CGColor;
        }
    }
}

static void (*orig_CALayer_setFilters)(id, SEL, NSArray *) = NULL;
static void hooked_CALayer_setFilters(CALayer *self, SEL _cmd, NSArray *filters) {
    if (gCABackdropLayerClass && [self isKindOfClass:gCABackdropLayerClass] &&
        ([TGLitePerfSettings shared].effectiveDisableBlurAndGlass || [TGLitePerfSettings shared].effectiveDisableAllBlurs)) {
        orig_CALayer_setFilters(self, _cmd, nil);
        TGLiteApplyKeyboardBackdropLayerColorIfNeeded(self);
        return;
    }
    orig_CALayer_setFilters(self, _cmd, filters);
}

static void (*orig_CABackdropLayer_setEnabled)(id, SEL, BOOL) = NULL;
static void hooked_CABackdropLayer_setEnabled(id self, SEL _cmd, BOOL enabled) {
    if ([TGLitePerfSettings shared].effectiveDisableBlurAndGlass || [TGLitePerfSettings shared].effectiveDisableAllBlurs) {
        orig_CABackdropLayer_setEnabled(self, _cmd, NO);
        if ([self isKindOfClass:[CALayer class]]) {
            TGLiteApplyKeyboardBackdropLayerColorIfNeeded((CALayer *)self);
        }
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

#pragma mark - UIVisualEffectView (Complete Blur Disable, Keyboard Theme Fill & iOS 26+ UIGlassEffect fallback)

static void (*orig_UIVisualEffectView_setEffect)(id, SEL, UIVisualEffect *) = NULL;
static void (*orig_UIVisualEffectView_setBackgroundColor)(id, SEL, UIColor *) = NULL;

static UIWindow *TGLiteFindMainAppWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *win in windowScene.windows) {
            if (win.isHidden || !win.rootViewController) continue;
            NSString *winClass = NSStringFromClass([win class]);
            if ([winClass containsString:@"Keyboard"] ||
                [winClass containsString:@"TextEffects"] ||
                [winClass containsString:@"StatusBar"]) {
                continue;
            }
            if (win.isKeyWindow) {
                return win;
            }
            if (!fallback) {
                fallback = win;
            }
        }
    }
    return fallback;
}

static BOOL TGLiteIsTelegramDarkTheme(UIView *view) {
    if ([NSThread isMainThread]) {
        gTGLiteCurrentFirstResponder = nil;
        [[UIApplication sharedApplication] sendAction:@selector(tgLite_captureFirstResponder:) to:nil from:nil forEvent:nil];
        UIResponder *responder = gTGLiteCurrentFirstResponder;
        gTGLiteCurrentFirstResponder = nil;
        if (responder && [responder respondsToSelector:@selector(keyboardAppearance)]) {
            UIKeyboardAppearance appearance = [(id<UITextInputTraits>)responder keyboardAppearance];
            if (appearance == UIKeyboardAppearanceDark) {
                return YES;
            }
            if (appearance == UIKeyboardAppearanceLight) {
                return NO;
            }
        }
    }

    UIWindow *mainWindow = TGLiteFindMainAppWindow();
    if (mainWindow) {
        if (mainWindow.overrideUserInterfaceStyle == UIUserInterfaceStyleDark) {
            return YES;
        }
        if (mainWindow.overrideUserInterfaceStyle == UIUserInterfaceStyleLight) {
            return NO;
        }
        UIViewController *rootVC = mainWindow.rootViewController;
        if (rootVC) {
            if (rootVC.overrideUserInterfaceStyle == UIUserInterfaceStyleDark) {
                return YES;
            }
            if (rootVC.overrideUserInterfaceStyle == UIUserInterfaceStyleLight) {
                return NO;
            }
        }
        if (mainWindow.traitCollection.userInterfaceStyle != UIUserInterfaceStyleUnspecified) {
            return mainWindow.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        }
    }

    if (view) {
        return view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

static UIColor *TGLiteKeyboardColorForDark(BOOL isDark) {
    if (isDark) {
        // Classic iOS dark gray keyboard backdrop
        return [UIColor colorWithRed:40.0/255.0 green:40.0/255.0 blue:42.0/255.0 alpha:1.0];
    }
    // Classic iOS light ("white") keyboard backdrop
    return [UIColor colorWithRed:209.0/255.0 green:212.0/255.0 blue:217.0/255.0 alpha:1.0];
}

static BOOL TGLiteIsKeyboardView(UIView *view) {
    if (!view) return NO;
    if (gUIKBBackdropViewClass && [view isKindOfClass:gUIKBBackdropViewClass]) {
        return YES;
    }
    if (gTUISystemInputAssistantViewClass && [view isKindOfClass:gTUISystemInputAssistantViewClass]) {
        return YES;
    }
    if (gUIInputAssistantHostViewClass && [view isKindOfClass:gUIInputAssistantHostViewClass]) {
        return YES;
    }

    UIWindow *win = view.window;
    if (win) {
        NSString *winClass = NSStringFromClass([win class]);
        if ([winClass containsString:@"RemoteKeyboard"]) {
            return YES;
        }
        if (![winClass containsString:@"Keyboard"] && ![winClass containsString:@"TextEffects"]) {
            return NO;
        }
        UIView *cur = view;
        for (int i = 0; i < 16 && cur != nil; i++) {
            NSString *clsName = NSStringFromClass([cur class]);
            if ([clsName hasPrefix:@"UIKB"] ||
                [clsName hasPrefix:@"TUI"] ||
                [clsName containsString:@"Keyboard"] ||
                [clsName containsString:@"InputBackdrop"] ||
                [clsName containsString:@"InputSet"] ||
                [clsName containsString:@"InputAssistant"] ||
                [clsName containsString:@"InputWindow"] ||
                [clsName containsString:@"Prediction"] ||
                [clsName containsString:@"Candidate"]) {
                return YES;
            }
            cur = cur.superview;
        }
        return NO;
    }

    NSString *clsName = NSStringFromClass([view class]);
    return [clsName hasPrefix:@"UIKB"] ||
           [clsName hasPrefix:@"UIKeyboard"] ||
           [clsName hasPrefix:@"TUI"];
}

static void TGLiteSetVisualEffectViewBackground(UIVisualEffectView *view, UIColor *color) {
    if (!view) return;
    if (orig_UIVisualEffectView_setBackgroundColor) {
        orig_UIVisualEffectView_setBackgroundColor(view, @selector(setBackgroundColor:), color);
    } else {
        view.backgroundColor = color;
    }
}

static void (*orig_TUISystemInputAssistantView_setBackgroundColor)(id, SEL, UIColor *) = NULL;

static void TGLiteStyleUIBackdropView(UIView *backdropView, UIColor *kbColor) {
    if (!backdropView) return;
    backdropView.backgroundColor = kbColor;
    if (gCABackdropLayerClass && [backdropView.layer isKindOfClass:gCABackdropLayerClass]) {
        backdropView.layer.backgroundColor = kbColor.CGColor;
    }
    for (UIView *sub in backdropView.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls containsString:@"Tint"]) {
            sub.backgroundColor = [UIColor clearColor];
        } else if ([cls containsString:@"Effect"]) {
            sub.backgroundColor = kbColor;
            if (gCABackdropLayerClass && [sub.layer isKindOfClass:gCABackdropLayerClass]) {
                sub.layer.backgroundColor = kbColor.CGColor;
            }
        }
    }
}

static BOOL TGLiteStyleKeyboardBackdropDescendants(UIView *root, CGFloat containerWidth, UIColor *kbColor, int depth) {
    if (!root || depth > 8) return NO;
    BOOL foundMainRoundedPill = NO;
    for (UIView *subview in root.subviews) {
        NSString *cls = NSStringFromClass([subview class]);
        BOOL isBackdropLike = NO;

        if ([subview isKindOfClass:[UIVisualEffectView class]]) {
            UIVisualEffectView *vev = (UIVisualEffectView *)subview;
            if (vev.effect != nil && orig_UIVisualEffectView_setEffect) {
                orig_UIVisualEffectView_setEffect(vev, @selector(setEffect:), nil);
            }
            objc_setAssociatedObject(vev, &kTGLiteNeutralizedEffectKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            TGLiteSetVisualEffectViewBackground(vev, kbColor);
            vev.contentView.backgroundColor = [UIColor clearColor];
            isBackdropLike = YES;
        } else if (gUIBackdropViewClass && [subview isKindOfClass:gUIBackdropViewClass]) {
            TGLiteStyleUIBackdropView(subview, kbColor);
            isBackdropLike = YES;
        } else if ([cls containsString:@"Backdrop"]) {
            subview.backgroundColor = kbColor;
            if (gCABackdropLayerClass && [subview.layer isKindOfClass:gCABackdropLayerClass]) {
                subview.layer.backgroundColor = kbColor.CGColor;
            }
            isBackdropLike = YES;
        } else if (gCABackdropLayerClass && [subview.layer isKindOfClass:gCABackdropLayerClass]) {
            subview.layer.backgroundColor = kbColor.CGColor;
            isBackdropLike = YES;
        }

        if (isBackdropLike &&
            !subview.isHidden &&
            subview.alpha > 0.01 &&
            subview.layer.cornerRadius > 2.0 &&
            subview.bounds.size.height > 10.0 &&
            containerWidth > 0.0 &&
            subview.bounds.size.width >= containerWidth * 0.5) {
            foundMainRoundedPill = YES;
        }

        if (TGLiteStyleKeyboardBackdropDescendants(subview, containerWidth, kbColor, depth + 1)) {
            foundMainRoundedPill = YES;
        }
    }
    return foundMainRoundedPill;
}

static void TGLiteApplyAssistantBarBackground(UIView *assistantView, UIColor *kbColor) {
    if (!assistantView) return;
    BOOL hasMainRoundedPill = TGLiteStyleKeyboardBackdropDescendants(
        assistantView, assistantView.bounds.size.width, kbColor, 0);
    UIColor *containerColor = hasMainRoundedPill ? [UIColor clearColor] : kbColor;
    if (gTUISystemInputAssistantViewClass &&
        [assistantView isKindOfClass:gTUISystemInputAssistantViewClass] &&
        orig_TUISystemInputAssistantView_setBackgroundColor) {
        orig_TUISystemInputAssistantView_setBackgroundColor(
            assistantView, @selector(setBackgroundColor:), containerColor);
    } else {
        assistantView.backgroundColor = containerColor;
    }
}

static void TGLiteInstallAssistantHooksIfNeeded(void);

static void TGLiteApplyFlatGlassFallback(UIVisualEffectView *view) {
    if (!view) return;
    if (TGLiteIsKeyboardView(view)) {
        BOOL isDark = TGLiteIsTelegramDarkTheme(view);
        TGLiteSetVisualEffectViewBackground(view, TGLiteKeyboardColorForDark(isDark));
        view.contentView.backgroundColor = [UIColor clearColor];
        return;
    }

    BOOL isDark = NO;
    if (view.window != nil && view.traitCollection.userInterfaceStyle != UIUserInterfaceStyleUnspecified) {
        isDark = (view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    } else {
        isDark = TGLiteIsTelegramDarkTheme(view);
    }
    TGLiteSetVisualEffectViewBackground(view, isDark
        ? [UIColor colorWithWhite:0.14 alpha:0.86]
        : [UIColor colorWithWhite:0.96 alpha:0.86]);
}

static void TGLiteRefreshKeyboardViewsInTree(UIView *view, UIColor *kbColor, int depth) {
    if (!view || depth > 24) return;
    if ([view isKindOfClass:[UIVisualEffectView class]] && TGLiteIsKeyboardView(view)) {
        UIVisualEffectView *vev = (UIVisualEffectView *)view;
        if (vev.effect != nil && orig_UIVisualEffectView_setEffect) {
            orig_UIVisualEffectView_setEffect(vev, @selector(setEffect:), nil);
        }
        objc_setAssociatedObject(vev, &kTGLiteNeutralizedEffectKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TGLiteSetVisualEffectViewBackground(vev, kbColor);
        vev.contentView.backgroundColor = [UIColor clearColor];
    } else if (gTUISystemInputAssistantViewClass && [view isKindOfClass:gTUISystemInputAssistantViewClass]) {
        TGLiteApplyAssistantBarBackground(view, kbColor);
    } else if (gUIInputAssistantHostViewClass && [view isKindOfClass:gUIInputAssistantHostViewClass]) {
        TGLiteApplyAssistantBarBackground(view, kbColor);
    } else if (gUIBackdropViewClass && [view isKindOfClass:gUIBackdropViewClass] && TGLiteIsKeyboardView(view)) {
        TGLiteStyleUIBackdropView(view, kbColor);
    } else if (gCABackdropLayerClass && [view.layer isKindOfClass:gCABackdropLayerClass] && TGLiteIsKeyboardView(view)) {
        NSString *clsName = NSStringFromClass([view class]);
        if ([clsName containsString:@"Backdrop"] ||
            [clsName containsString:@"Assistant"] ||
            [clsName containsString:@"Prediction"] ||
            [clsName containsString:@"Candidate"]) {
            view.backgroundColor = kbColor;
            view.layer.backgroundColor = kbColor.CGColor;
        }
    }
    for (UIView *subview in view.subviews) {
        TGLiteRefreshKeyboardViewsInTree(subview, kbColor, depth + 1);
    }
}

static void TGLiteRefreshKeyboardBackdrops(void) {
    TGLiteInstallAssistantHooksIfNeeded();
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if (!settings.effectiveDisableAllBlurs && !settings.effectiveDisableBlurAndGlass) {
        return;
    }
    UIColor *kbColor = TGLiteKeyboardColorForDark(TGLiteIsTelegramDarkTheme(nil));
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *win in windowScene.windows) {
            NSString *winClass = NSStringFromClass([win class]);
            if ([winClass containsString:@"Keyboard"] || [winClass containsString:@"TextEffects"]) {
                TGLiteRefreshKeyboardViewsInTree(win, kbColor, 0);
            }
        }
    }
}

static id (*orig_UIVisualEffectView_initWithEffect)(id, SEL, UIVisualEffect *) = NULL;
static id hooked_UIVisualEffectView_initWithEffect(UIVisualEffectView *self, SEL _cmd, UIVisualEffect *effect) {
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    BOOL isKeyboard = TGLiteIsKeyboardView(self);
    BOOL isGlass = (gUIGlassEffectClass && effect && [effect isKindOfClass:gUIGlassEffectClass]);
    BOOL shouldNeutralize = (effect != nil) && (
        settings.effectiveDisableAllBlurs ||
        (isGlass && settings.effectiveDisableBlurAndGlass) ||
        (isKeyboard && settings.effectiveDisableBlurAndGlass)
    );
    if (shouldNeutralize) {
        UIVisualEffectView *res = orig_UIVisualEffectView_initWithEffect(self, _cmd, nil);
        if (res) {
            objc_setAssociatedObject(res, &kTGLiteNeutralizedEffectKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            TGLiteApplyFlatGlassFallback(res);
        }
        return res;
    }
    return orig_UIVisualEffectView_initWithEffect(self, _cmd, effect);
}

static void hooked_UIVisualEffectView_setEffect(UIVisualEffectView *self, SEL _cmd, UIVisualEffect *effect) {
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    BOOL isKeyboard = TGLiteIsKeyboardView(self);
    BOOL isGlass = (gUIGlassEffectClass && effect && [effect isKindOfClass:gUIGlassEffectClass]);
    BOOL shouldNeutralize = (effect != nil) && (
        settings.effectiveDisableAllBlurs ||
        (isGlass && settings.effectiveDisableBlurAndGlass) ||
        (isKeyboard && settings.effectiveDisableBlurAndGlass)
    );
    if (shouldNeutralize) {
        orig_UIVisualEffectView_setEffect(self, _cmd, nil);
        objc_setAssociatedObject(self, &kTGLiteNeutralizedEffectKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TGLiteApplyFlatGlassFallback(self);
        return;
    }
    orig_UIVisualEffectView_setEffect(self, _cmd, effect);
}

static void hooked_UIVisualEffectView_setBackgroundColor(UIVisualEffectView *self, SEL _cmd, UIColor *color) {
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if ((settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass) &&
        TGLiteIsKeyboardView(self)) {
        UIColor *kbColor = TGLiteKeyboardColorForDark(TGLiteIsTelegramDarkTheme(self));
        orig_UIVisualEffectView_setBackgroundColor(self, _cmd, kbColor);
        return;
    }
    orig_UIVisualEffectView_setBackgroundColor(self, _cmd, color);
}

static void (*orig_UIVisualEffectView_didMoveToWindow)(id, SEL) = NULL;
static void hooked_UIVisualEffectView_didMoveToWindow(UIVisualEffectView *self, SEL _cmd) {
    if (orig_UIVisualEffectView_didMoveToWindow) {
        orig_UIVisualEffectView_didMoveToWindow(self, _cmd);
    }
    if (!self.window) {
        return;
    }
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    BOOL blurDisabled = settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass;
    if (blurDisabled && TGLiteIsKeyboardView(self)) {
        if (self.effect != nil && orig_UIVisualEffectView_setEffect) {
            orig_UIVisualEffectView_setEffect(self, @selector(setEffect:), nil);
        }
        objc_setAssociatedObject(self, &kTGLiteNeutralizedEffectKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TGLiteApplyFlatGlassFallback(self);
    } else if (settings.effectiveDisableAllBlurs &&
               objc_getAssociatedObject(self, &kTGLiteNeutralizedEffectKey) &&
               self.effect == nil) {
        TGLiteApplyFlatGlassFallback(self);
    }
}

static void (*orig_UIVisualEffectView_traitCollectionDidChange)(id, SEL, UITraitCollection *) = NULL;
static void hooked_UIVisualEffectView_traitCollectionDidChange(UIVisualEffectView *self, SEL _cmd, UITraitCollection *prev) {
    if (orig_UIVisualEffectView_traitCollectionDidChange) {
        orig_UIVisualEffectView_traitCollectionDidChange(self, _cmd, prev);
    }
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    BOOL blurDisabled = settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass;
    if (blurDisabled && TGLiteIsKeyboardView(self)) {
        if (self.effect != nil && orig_UIVisualEffectView_setEffect) {
            orig_UIVisualEffectView_setEffect(self, @selector(setEffect:), nil);
        }
        objc_setAssociatedObject(self, &kTGLiteNeutralizedEffectKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TGLiteApplyFlatGlassFallback(self);
    } else if (settings.effectiveDisableAllBlurs &&
               objc_getAssociatedObject(self, &kTGLiteNeutralizedEffectKey) &&
               self.effect == nil) {
        TGLiteApplyFlatGlassFallback(self);
    }
}

static void (*orig_UIKBBackdropView_transitionToStyle)(id, SEL, NSInteger) = NULL;
static void hooked_UIKBBackdropView_transitionToStyle(UIVisualEffectView *self, SEL _cmd, NSInteger style) {
    if (orig_UIKBBackdropView_transitionToStyle) {
        orig_UIKBBackdropView_transitionToStyle(self, _cmd, style);
    }
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if (settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass) {
        if (self.effect != nil && orig_UIVisualEffectView_setEffect) {
            orig_UIVisualEffectView_setEffect(self, @selector(setEffect:), nil);
        }
        objc_setAssociatedObject(self, &kTGLiteNeutralizedEffectKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TGLiteApplyFlatGlassFallback(self);
    }
}

static void (*orig_UIKBBackdropView_layoutSubviews)(id, SEL) = NULL;
static void hooked_UIKBBackdropView_layoutSubviews(UIVisualEffectView *self, SEL _cmd) {
    if (orig_UIKBBackdropView_layoutSubviews) {
        orig_UIKBBackdropView_layoutSubviews(self, _cmd);
    }
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if (settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass) {
        if (self.effect != nil && orig_UIVisualEffectView_setEffect) {
            orig_UIVisualEffectView_setEffect(self, @selector(setEffect:), nil);
        }
        TGLiteApplyFlatGlassFallback(self);
    }
}

static void (*orig_UIKBInputBackdropView_layoutSubviews)(id, SEL) = NULL;
static void hooked_UIKBInputBackdropView_layoutSubviews(UIView *self, SEL _cmd) {
    if (orig_UIKBInputBackdropView_layoutSubviews) {
        orig_UIKBInputBackdropView_layoutSubviews(self, _cmd);
    }
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if (settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass) {
        UIColor *kbColor = TGLiteKeyboardColorForDark(TGLiteIsTelegramDarkTheme(self));
        TGLiteStyleKeyboardBackdropDescendants(self, self.bounds.size.width, kbColor, 0);
    }
}

static void (*orig_UIBackdropView_didMoveToWindow)(id, SEL) = NULL;
static void hooked_UIBackdropView_didMoveToWindow(UIView *self, SEL _cmd) {
    if (orig_UIBackdropView_didMoveToWindow) {
        orig_UIBackdropView_didMoveToWindow(self, _cmd);
    }
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if ((settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass) &&
        self.window && TGLiteIsKeyboardView(self)) {
        UIColor *kbColor = TGLiteKeyboardColorForDark(TGLiteIsTelegramDarkTheme(self));
        TGLiteStyleUIBackdropView(self, kbColor);
    }
}

static void (*orig_UIBackdropView_layoutSubviews)(id, SEL) = NULL;
static void hooked_UIBackdropView_layoutSubviews(UIView *self, SEL _cmd) {
    if (orig_UIBackdropView_layoutSubviews) {
        orig_UIBackdropView_layoutSubviews(self, _cmd);
    }
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if ((settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass) &&
        self.window && TGLiteIsKeyboardView(self)) {
        UIColor *kbColor = TGLiteKeyboardColorForDark(TGLiteIsTelegramDarkTheme(self));
        TGLiteStyleUIBackdropView(self, kbColor);
    }
}

static void hooked_TUISystemInputAssistantView_setBackgroundColor(UIView *self, SEL _cmd, UIColor *color) {
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if (settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass) {
        UIColor *kbColor = TGLiteKeyboardColorForDark(TGLiteIsTelegramDarkTheme(self));
        BOOL hasMainRoundedPill = TGLiteStyleKeyboardBackdropDescendants(
            self, self.bounds.size.width, kbColor, 0);
        orig_TUISystemInputAssistantView_setBackgroundColor(
            self, _cmd, hasMainRoundedPill ? [UIColor clearColor] : kbColor);
        return;
    }
    orig_TUISystemInputAssistantView_setBackgroundColor(self, _cmd, color);
}

static void (*orig_TUISystemInputAssistantView_didMoveToWindow)(id, SEL) = NULL;
static void hooked_TUISystemInputAssistantView_didMoveToWindow(UIView *self, SEL _cmd) {
    if (orig_TUISystemInputAssistantView_didMoveToWindow) {
        orig_TUISystemInputAssistantView_didMoveToWindow(self, _cmd);
    }
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if ((settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass) && self.window) {
        UIColor *kbColor = TGLiteKeyboardColorForDark(TGLiteIsTelegramDarkTheme(self));
        TGLiteApplyAssistantBarBackground(self, kbColor);
    }
}

static void (*orig_TUISystemInputAssistantView_layoutSubviews)(id, SEL) = NULL;
static void hooked_TUISystemInputAssistantView_layoutSubviews(UIView *self, SEL _cmd) {
    if (orig_TUISystemInputAssistantView_layoutSubviews) {
        orig_TUISystemInputAssistantView_layoutSubviews(self, _cmd);
    }
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if ((settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass) && self.window) {
        UIColor *kbColor = TGLiteKeyboardColorForDark(TGLiteIsTelegramDarkTheme(self));
        TGLiteApplyAssistantBarBackground(self, kbColor);
    }
}

static void (*orig_UIInputAssistantHostView_didMoveToWindow)(id, SEL) = NULL;
static void hooked_UIInputAssistantHostView_didMoveToWindow(UIView *self, SEL _cmd) {
    if (orig_UIInputAssistantHostView_didMoveToWindow) {
        orig_UIInputAssistantHostView_didMoveToWindow(self, _cmd);
    }
    TGLiteInstallAssistantHooksIfNeeded();
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if ((settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass) && self.window) {
        UIColor *kbColor = TGLiteKeyboardColorForDark(TGLiteIsTelegramDarkTheme(self));
        TGLiteApplyAssistantBarBackground(self, kbColor);
    }
}

static void (*orig_UIInputAssistantHostView_layoutSubviews)(id, SEL) = NULL;
static void hooked_UIInputAssistantHostView_layoutSubviews(UIView *self, SEL _cmd) {
    if (orig_UIInputAssistantHostView_layoutSubviews) {
        orig_UIInputAssistantHostView_layoutSubviews(self, _cmd);
    }
    TGLiteInstallAssistantHooksIfNeeded();
    TGLitePerfSettings *settings = [TGLitePerfSettings shared];
    if ((settings.effectiveDisableAllBlurs || settings.effectiveDisableBlurAndGlass) && self.window) {
        UIColor *kbColor = TGLiteKeyboardColorForDark(TGLiteIsTelegramDarkTheme(self));
        TGLiteApplyAssistantBarBackground(self, kbColor);
    }
}

static void TGLiteInstallAssistantHooksIfNeeded(void) {
    static BOOL assistantHooked = NO;
    if (assistantHooked) {
        return;
    }
    Class cls = NSClassFromString(@"TUISystemInputAssistantView");
    if (cls) {
        gTUISystemInputAssistantViewClass = cls;
        orig_TUISystemInputAssistantView_setBackgroundColor = (void *)TGLiteSwizzleMethod(
            cls, @selector(setBackgroundColor:), (IMP)hooked_TUISystemInputAssistantView_setBackgroundColor);
        orig_TUISystemInputAssistantView_didMoveToWindow = (void *)TGLiteSwizzleMethod(
            cls, @selector(didMoveToWindow), (IMP)hooked_TUISystemInputAssistantView_didMoveToWindow);
        orig_TUISystemInputAssistantView_layoutSubviews = (void *)TGLiteSwizzleMethod(
            cls, @selector(layoutSubviews), (IMP)hooked_TUISystemInputAssistantView_layoutSubviews);
        assistantHooked = YES;
    }
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
        gUIKBBackdropViewClass = NSClassFromString(@"UIKBBackdropView");
        gUIKBInputBackdropViewClass = NSClassFromString(@"UIKBInputBackdropView");
        gUIBackdropViewClass = NSClassFromString(@"_UIBackdropView");
        gUIInputAssistantHostViewClass = NSClassFromString(@"UIInputAssistantHostView");

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

        // 3. Swizzle UIVisualEffectView & UIKBBackdropView (flat fallback & Telegram-themed solid keyboard)
        orig_UIVisualEffectView_initWithEffect = (void *)TGLiteSwizzleMethod(
            [UIVisualEffectView class], @selector(initWithEffect:), (IMP)hooked_UIVisualEffectView_initWithEffect);
        orig_UIVisualEffectView_setEffect = (void *)TGLiteSwizzleMethod(
            [UIVisualEffectView class], @selector(setEffect:), (IMP)hooked_UIVisualEffectView_setEffect);
        orig_UIVisualEffectView_setBackgroundColor = (void *)TGLiteSwizzleMethod(
            [UIVisualEffectView class], @selector(setBackgroundColor:), (IMP)hooked_UIVisualEffectView_setBackgroundColor);
        orig_UIVisualEffectView_didMoveToWindow = (void *)TGLiteSwizzleMethod(
            [UIVisualEffectView class], @selector(didMoveToWindow), (IMP)hooked_UIVisualEffectView_didMoveToWindow);
        orig_UIVisualEffectView_traitCollectionDidChange = (void *)TGLiteSwizzleMethod(
            [UIVisualEffectView class], @selector(traitCollectionDidChange:), (IMP)hooked_UIVisualEffectView_traitCollectionDidChange);

        if (gUIKBBackdropViewClass) {
            orig_UIKBBackdropView_transitionToStyle = (void *)TGLiteSwizzleMethod(
                gUIKBBackdropViewClass, NSSelectorFromString(@"transitionToStyle:"), (IMP)hooked_UIKBBackdropView_transitionToStyle);
            orig_UIKBBackdropView_layoutSubviews = (void *)TGLiteSwizzleMethod(
                gUIKBBackdropViewClass, @selector(layoutSubviews), (IMP)hooked_UIKBBackdropView_layoutSubviews);
        }

        if (gUIKBInputBackdropViewClass) {
            orig_UIKBInputBackdropView_layoutSubviews = (void *)TGLiteSwizzleMethod(
                gUIKBInputBackdropViewClass, @selector(layoutSubviews), (IMP)hooked_UIKBInputBackdropView_layoutSubviews);
        }

        if (gUIBackdropViewClass) {
            orig_UIBackdropView_didMoveToWindow = (void *)TGLiteSwizzleMethod(
                gUIBackdropViewClass, @selector(didMoveToWindow), (IMP)hooked_UIBackdropView_didMoveToWindow);
            orig_UIBackdropView_layoutSubviews = (void *)TGLiteSwizzleMethod(
                gUIBackdropViewClass, @selector(layoutSubviews), (IMP)hooked_UIBackdropView_layoutSubviews);
        }

        if (gUIInputAssistantHostViewClass) {
            orig_UIInputAssistantHostView_didMoveToWindow = (void *)TGLiteSwizzleMethod(
                gUIInputAssistantHostViewClass, @selector(didMoveToWindow), (IMP)hooked_UIInputAssistantHostView_didMoveToWindow);
            orig_UIInputAssistantHostView_layoutSubviews = (void *)TGLiteSwizzleMethod(
                gUIInputAssistantHostViewClass, @selector(layoutSubviews), (IMP)hooked_UIInputAssistantHostView_layoutSubviews);
        }

        TGLiteInstallAssistantHooksIfNeeded();

        void (^refreshKeyboard)(NSNotification *) = ^(NSNotification *note) {
            if ([NSThread isMainThread]) {
                TGLiteRefreshKeyboardBackdrops();
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    TGLiteRefreshKeyboardBackdrops();
                });
            }
        };
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillShowNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:refreshKeyboard];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:refreshKeyboard];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillChangeFrameNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:refreshKeyboard];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidChangeFrameNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:refreshKeyboard];

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
