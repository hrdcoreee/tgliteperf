#import "TGLitePerfPrefsController.h"
#import "TGLitePerfSettings.h"

typedef NS_ENUM(NSInteger, TGLiteRowType) {
    TGLiteRowMasterEnable = 0,
    TGLiteRowDisableAllBlurs,
    TGLiteRowDisableBlurAndGlass,
    TGLiteRowForceLowPower,
    TGLiteRowThrottleParticles,
    TGLiteRowDisableOffscreenShadows,
    TGLiteRowDisableGalleryLiveCamera,
    TGLiteRowHideGalleryCamera,
    TGLiteRowDisableSwipeToStory,
    TGLiteRowDisableSnapDeletion,
    TGLiteRowDisableUpdateChecks,
    TGLiteRowRestartApp
};

@interface TGLitePerfPrefsController ()
@property (nonatomic, assign) BOOL isRussian;
@end

@implementation TGLitePerfPrefsController

static UIWindow *TGLiteFindActiveKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            (scene.activationState == UISceneActivationStateForegroundActive ||
             scene.activationState == UISceneActivationStateForegroundInactive)) {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow && !window.isHidden) {
                    return window;
                }
            }
            for (UIWindow *window in windowScene.windows) {
                if (!window.isHidden) {
                    return window;
                }
            }
        }
    }
    return nil;
}

static UIViewController *TGLiteTopViewController(UIViewController *root) {
    UIViewController *current = root;
    while (current.presentedViewController && !current.presentedViewController.isBeingDismissed) {
        current = current.presentedViewController;
    }
    return current;
}

+ (void)presentFromTopViewController {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = TGLiteFindActiveKeyWindow();
        if (!window || !window.rootViewController) {
            return;
        }
        UIViewController *topVC = TGLiteTopViewController(window.rootViewController);
        if ([topVC isKindOfClass:[UINavigationController class]] &&
            [[(UINavigationController *)topVC topViewController] isKindOfClass:[TGLitePerfPrefsController class]]) {
            return;
        }

        TGLitePerfPrefsController *vc = [[TGLitePerfPrefsController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        if (@available(iOS 15.0, *)) {
            nav.modalPresentationStyle = UIModalPresentationPageSheet;
        }
        [topVC presentViewController:nav animated:YES completion:nil];
    });
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        NSString *lang = [NSLocale preferredLanguages].firstObject ?: @"en";
        _isRussian = [lang hasPrefix:@"ru"] || [lang hasPrefix:@"uk"] || [lang hasPrefix:@"be"];
    }
    return self;
}

- (NSString *)t:(NSString *)ru en:(NSString *)en {
    return self.isRussian ? ru : en;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TGLitePerf";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(dismissSelf)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56.0;
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table Structure

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1; // Master toggle
        case 1: return 5; // Graphics & Animations
        case 2: return 5; // Camera, Swiftgram Extras & Updates
        case 3: return 1; // Restart button
        default: return 0;
    }
}

- (TGLiteRowType)rowTypeForIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            return TGLiteRowMasterEnable;
        case 1:
            switch (indexPath.row) {
                case 0: return TGLiteRowDisableAllBlurs;
                case 1: return TGLiteRowDisableBlurAndGlass;
                case 2: return TGLiteRowForceLowPower;
                case 3: return TGLiteRowThrottleParticles;
                default: return TGLiteRowDisableOffscreenShadows;
            }
        case 2:
            switch (indexPath.row) {
                case 0: return TGLiteRowDisableGalleryLiveCamera;
                case 1: return TGLiteRowHideGalleryCamera;
                case 2: return TGLiteRowDisableSwipeToStory;
                case 3: return TGLiteRowDisableSnapDeletion;
                default: return TGLiteRowDisableUpdateChecks;
            }
        default:
            return TGLiteRowRestartApp;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return [self t:@"Общее" en:@"General"];
        case 1:
            return [self t:@"Графика, блюр и анимации" en:@"Graphics, Blur & Animations"];
        case 2:
            return [self t:@"Камера и эффекты" en:@"Camera & Effects"];
        default:
            return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    TGLitePerfSettings *s = [TGLitePerfSettings shared];
    if (section == 0) {
        NSString *profile = s.isOlderDeviceDetected
            ? [self t:@"Определено слабое/старое устройство — оптимизации рекомендованы." en:@"Older/low-RAM device detected — optimizations recommended."]
            : [self t:@"Современное устройство." en:@"Modern device detected."];
        return [NSString stringWithFormat:@"%@\n%@", s.deviceSummary, profile];
    }
    if (section == 3) {
        return [self t:@"После изменения настроек прозрачности/камеры перезапустите приложение, чтобы сбросить кэшированные слои."
                       en:@"Restart the app after changing transparency/camera toggles to apply cached layer states."];
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    TGLiteRowType rowType = [self rowTypeForIndexPath:indexPath];
    TGLitePerfSettings *s = [TGLitePerfSettings shared];

    if (rowType == TGLiteRowRestartApp) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = [self t:@"Перезапустить приложение" en:@"Restart App"];
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.tag = rowType;
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];

    BOOL enabled = s.tweakEnabled;

    switch (rowType) {
        case TGLiteRowMasterEnable:
            cell.textLabel.text = [self t:@"Включить TGLitePerf" en:@"Enable TGLitePerf"];
            cell.detailTextLabel.text = [self t:@"Глобальный переключатель всех оптимизаций" en:@"Master switch for all performance tweaks"];
            toggle.on = s.tweakEnabled;
            toggle.enabled = YES;
            break;
        case TGLiteRowDisableAllBlurs:
            cell.textLabel.text = [self t:@"Полное отключение блюра (Все размытия -> Flat)" en:@"Disable All Blurs (Flat UI)"];
            cell.detailTextLabel.text = [self t:@"Отключает UIVisualEffectView (алерты, шторки, меню) и заменяет на плоский цвет" en:@"Replaces all UIVisualEffectViews (alerts, sheets, menus) with flat background"];
            toggle.on = s.disableAllBlurs;
            toggle.enabled = enabled;
            break;
        case TGLiteRowDisableBlurAndGlass:
            cell.textLabel.text = [self t:@"Отключить стекло и деформацию (Glass & Mesh)" en:@"Disable Glass & 3D Mesh Effects"];
            cell.detailTextLabel.text = [self t:@"Убирает CABackdropLayer, 3D meshTransform, UIGlassEffect и блюр дат в чате" en:@"Disables CABackdropLayer, 3D meshTransform, UIGlassEffect & chat date blurs"];
            toggle.on = s.disableBlurAndGlass;
            toggle.enabled = enabled;
            break;
        case TGLiteRowForceLowPower:
            cell.textLabel.text = [self t:@"Облегчённые эмодзи (30 FPS)" en:@"Low-Power Emoji & Animations (30 FPS)"];
            cell.detailTextLabel.text = [self t:@"Включает frame-skip (30 FPS) для кастомных эмодзи и снижает фоновую нагрузку" en:@"Enables 30 FPS frame-skip for custom emoji renderers and reduces background work"];
            toggle.on = s.forceLowPowerOptimizations;
            toggle.enabled = enabled;
            break;
        case TGLiteRowThrottleParticles:
            cell.textLabel.text = [self t:@"Ограничить частицы (спойлеры / звёзды)" en:@"Throttle Particle Emitters"];
            cell.detailTextLabel.text = [self t:@"Уменьшает частоту генерации частиц CAEmitterLayer на 75%" en:@"Reduces CAEmitterLayer particle birth rate by 75%"];
            toggle.on = s.throttleParticles;
            toggle.enabled = enabled;
            break;
        case TGLiteRowDisableOffscreenShadows:
            cell.textLabel.text = [self t:@"Убрать тяжёлые тени (Shadow Pass)" en:@"Disable Uncached Shadows"];
            cell.detailTextLabel.text = [self t:@"Убирает оффскрин-тени в SwiftUI-тулбаре и кнопках" en:@"Removes expensive offscreen shadows in SwiftUI toolbars & buttons"];
            toggle.on = s.disableOffscreenShadows;
            toggle.enabled = enabled;
            break;
        case TGLiteRowDisableGalleryLiveCamera:
            cell.textLabel.text = [self t:@"Отключить живую камеру в галерее" en:@"Disable Live Camera in Gallery"];
            cell.detailTextLabel.text = [self t:@"Предотвращает фоновый запуск AVCaptureSession при открытии скрепки" en:@"Stops live AVCaptureSession preview when opening photo picker"];
            toggle.on = s.disableGalleryLiveCamera;
            toggle.enabled = enabled;
            break;
        case TGLiteRowHideGalleryCamera:
            cell.textLabel.text = [self t:@"Скрыть ячейку камеры в галерее (Swiftgram)" en:@"Hide Gallery Camera Cell (Swiftgram)"];
            cell.detailTextLabel.text = [self t:@"Полностью убирает плитку камеры из сетки выбора фото" en:@"Removes the camera tile from the media picker grid"];
            toggle.on = s.hideGalleryCamera;
            toggle.enabled = enabled;
            break;
        case TGLiteRowDisableSwipeToStory:
            cell.textLabel.text = [self t:@"Отключить свайп на камеру историй (Swiftgram)" en:@"Disable Swipe to Story Camera (Swiftgram)"];
            cell.detailTextLabel.text = [self t:@"Убирает случайное открытие камеры при свайпе списка чатов" en:@"Prevents opening story camera on chat list swipe"];
            toggle.on = s.disableSwipeToStoryCamera;
            toggle.enabled = enabled;
            break;
        case TGLiteRowDisableSnapDeletion:
            cell.textLabel.text = [self t:@"Отключить анимацию рассыпания сообщений" en:@"Disable Message Snap Deletion Effect"];
            cell.detailTextLabel.text = [self t:@"Убирает ресурсоёмкую анимацию частиц при удалении" en:@"Skips heavy particle dissolve animation on delete"];
            toggle.on = s.disableSnapDeletionEffect;
            toggle.enabled = enabled;
            break;
        case TGLiteRowDisableUpdateChecks:
            cell.textLabel.text = [self t:@"Отключить проверку обновлений" en:@"Disable App Update Prompts"];
            cell.detailTextLabel.text = [self t:@"Скрывает окно обновления при входе и баннер в списке чатов (не затрагивает сообщения в чатах)" en:@"Hides launch update sheets and top chat list update banners (keeps in-chat messages)"];
            toggle.on = s.disableUpdateChecks;
            toggle.enabled = enabled;
            break;
        default:
            break;
    }

    cell.accessoryView = toggle;
    return cell;
}

- (void)switchChanged:(UISwitch *)sender {
    TGLitePerfSettings *s = [TGLitePerfSettings shared];
    BOOL val = sender.isOn;
    switch ((TGLiteRowType)sender.tag) {
        case TGLiteRowMasterEnable:
            s.tweakEnabled = val;
            [self.tableView reloadData];
            break;
        case TGLiteRowDisableAllBlurs:
            s.disableAllBlurs = val;
            break;
        case TGLiteRowDisableBlurAndGlass:
            s.disableBlurAndGlass = val;
            break;
        case TGLiteRowForceLowPower:
            s.forceLowPowerOptimizations = val;
            break;
        case TGLiteRowThrottleParticles:
            s.throttleParticles = val;
            break;
        case TGLiteRowDisableOffscreenShadows:
            s.disableOffscreenShadows = val;
            break;
        case TGLiteRowDisableGalleryLiveCamera:
            s.disableGalleryLiveCamera = val;
            break;
        case TGLiteRowHideGalleryCamera:
            s.hideGalleryCamera = val;
            break;
        case TGLiteRowDisableSwipeToStory:
            s.disableSwipeToStoryCamera = val;
            break;
        case TGLiteRowDisableSnapDeletion:
            s.disableSnapDeletionEffect = val;
            break;
        case TGLiteRowDisableUpdateChecks:
            s.disableUpdateChecks = val;
            break;
        default:
            break;
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self rowTypeForIndexPath:indexPath] == TGLiteRowRestartApp) {
        [[NSUserDefaults standardUserDefaults] synchronize];
        exit(0);
    }
}

@end
