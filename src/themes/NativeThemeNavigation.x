%config(generator=internal)

#import "TargetMetadata.h"
#import "ThemePrivateAPI.h"
#import "NativeThemeNavigation.h"
#import "ThemeShop.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <string.h>

static NSString *const RUINNativeThemeSettingsClassName =
    @"LineShopProductSettingsUI.ThemeSettingsViewController";
static NSString *const RUINNativeMyThemesClassName =
    @"LineShopProductSettingsUI.ThemePackageManagementViewController";
static NSString *const RUINNativeAppDelegateClassName = @"_TtC4LINE11AppDelegate";
static NSString *const RUINNativeMyThemesURL = @"line://nv/themeSettingsMenu";
static NSString *const RUINNativeThemeNavigationErrorDomain = @"RUINNativeThemeNavigation";
static const NSUInteger RUINNativeThemeNavigationMaxAttempts = 40;
static const NSTimeInterval RUINNativeThemeNavigationRetryDelay = 0.1;

typedef NS_ENUM(NSInteger, RUINNativeThemeNavigationErrorCode) {
    RUINNativeThemeNavigationVersionMismatch = 1,
    RUINNativeThemeNavigationUnavailable,
    RUINNativeThemeNavigationGuardFailed,
    RUINNativeThemeNavigationBusy,
    RUINNativeThemeNavigationTimedOut
};

typedef NS_ENUM(NSUInteger, RUINNativeThemeSelectionResult) {
    RUINNativeThemeSelectionPending,
    RUINNativeThemeSelectionDone,
    RUINNativeThemeSelectionFailed
};

@interface RUINNativeThemeNavigationRequest : NSObject
@property(nonatomic, weak) UIViewController *owner;
@property(nonatomic, weak) UIViewController *oldController;
@property(nonatomic, weak) UINavigationController *navigationController;
@property(nonatomic, weak) UIViewController *settingsController;
@property(nonatomic, copy) RUINNativeMyThemesCompletion completion;
@property(nonatomic) NSUInteger attempts;
@property(nonatomic) BOOL refresh;
@property(nonatomic) BOOL selected;
@property(nonatomic) BOOL finished;
@end

@implementation RUINNativeThemeNavigationRequest
@end

static os_unfair_lock gNativeMyThemesHandlerLock = OS_UNFAIR_LOCK_INIT;
static RUINNativeMyThemesDidAppearHandler gNativeMyThemesDidAppearHandler;
static BOOL gNativeMyThemesHookInstalled;

static NSError *RUINNativeThemeNavigationError(RUINNativeThemeNavigationErrorCode code,
    NSString *description)
{
    return [NSError errorWithDomain:RUINNativeThemeNavigationErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL RUINNativeThemeNavigationTargetMatches(void)
{
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
}

static Class RUINNativeClass(NSString *name)
{
    return NSClassFromString(name) ?: objc_lookUpClass(name.UTF8String);
}

static BOOL RUINObjectHasExactClass(id object, NSString *name)
{
    Class cls = RUINNativeClass(name);
    return object && cls && object_getClass(object) == cls;
}

static UIViewController *RUINVisibleController(UIViewController *root)
{
    UIViewController *controller = root;
    for (NSUInteger depth = 0; controller && depth < 32; depth++) {
        UIViewController *presented = controller.presentedViewController;
        if (presented && !presented.isBeingDismissed) {
            controller = presented;
        } else if ([controller isKindOfClass:UINavigationController.class]) {
            controller = ((UINavigationController *)controller).topViewController;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            controller = ((UITabBarController *)controller).selectedViewController;
        } else {
            return controller;
        }
    }
    return controller;
}

static UIWindow *RUINVisibleWindow(UIWindowScene *scene)
{
    UIWindow *fallback = nil;
    for (UIWindow *window in scene.windows) {
        if (window.hidden || window.alpha <= 0 || !window.rootViewController) continue;
        if (window.isKeyWindow) return window;
        fallback = fallback ?: window;
    }
    return fallback;
}

static UIViewController *RUINVisibleControllerInScene(UIWindowScene *scene)
{
    if (!scene || scene.activationState != UISceneActivationStateForegroundActive) return nil;
    return RUINVisibleController(RUINVisibleWindow(scene).rootViewController);
}

static UIViewController *RUINFindVisibleNativeController(NSString *className,
    UIWindowScene *preferredScene)
{
    if (preferredScene) {
        UIViewController *visible = RUINVisibleControllerInScene(preferredScene);
        if (RUINObjectHasExactClass(visible, className)) return visible;
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene == preferredScene) continue;
        UIViewController *visible = RUINVisibleControllerInScene((UIWindowScene *)scene);
        if (RUINObjectHasExactClass(visible, className)) return visible;
    }
    return nil;
}

static BOOL RUINOwnerIsVisible(UIViewController *owner)
{
    // LINE's MainRootViewController is a custom container. Its navigation
    // child is not reachable by following only UIKit's standard containers.
    UINavigationController *navigation = [owner isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)owner : owner.navigationController;
    UIViewController *top = navigation.topViewController;
    BOOL matches = owner == navigation;
    for (UIViewController *parent = owner; parent; parent = parent.parentViewController)
        if (parent == top) { matches = YES; break; }
    if (navigation && matches && top.viewIfLoaded.window &&
        !navigation.presentedViewController && !top.presentedViewController &&
        !navigation.transitionCoordinator) return YES;
    UIWindowScene *scene = owner.viewIfLoaded.window.windowScene;
    UIViewController *visible = RUINVisibleControllerInScene(scene);
    if (!visible) return NO;
    if (visible == owner || visible.navigationController == owner || visible.tabBarController == owner)
        return YES;
    for (UIViewController *parent = visible.parentViewController; parent;
         parent = parent.parentViewController) if (parent == owner) return YES;
    return NO;
}

static UITableView *RUINFindTableView(UIView *view, NSUInteger *budget, NSUInteger depth)
{
    if (!view || !*budget || depth > 32) return nil;
    (*budget)--;
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for (UIView *child in view.subviews) {
        UITableView *table = RUINFindTableView(child, budget, depth + 1);
        if (table) return table;
    }
    return nil;
}

static BOOL RUINNativeMyThemesTitle(NSString *text) {
    if (!text.length) return NO;
    for (NSString *key in @[@"settings.theme.mine", @"settings.theme.goto.mine"]) {
        NSString *title = [NSBundle.mainBundle localizedStringForKey:key value:@"マイ着せかえ" table:nil];
        if ([text isEqual:title]) return YES;
    }
    return [text isEqual:@"マイ着せかえ"] || [text isEqual:@"My Themes"];
}

static BOOL RUINLabelContainsMyThemes(UIView *view)
{
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = [(UILabel *)view text];
        if (RUINNativeMyThemesTitle(text)) return YES;
    }
    for (UIView *child in view.subviews) if (RUINLabelContainsMyThemes(child)) return YES;
    return NO;
}

static RUINNativeThemeSelectionResult RUINSelectNativeMyThemes(
    UIViewController *settings, NSError **error)
{
    if (!RUINObjectHasExactClass(settings, RUINNativeThemeSettingsClassName)) {
        if (error) *error = RUINNativeThemeNavigationError(
            RUINNativeThemeNavigationGuardFailed, @"The native theme settings screen changed.");
        return RUINNativeThemeSelectionFailed;
    }
    UINavigationController *navigation = settings.navigationController;
    if ((navigation && (navigation.topViewController != settings || navigation.transitionCoordinator)) ||
        settings.transitionCoordinator || settings.presentedViewController) return RUINNativeThemeSelectionPending;

    if (!settings.isViewLoaded) return RUINNativeThemeSelectionPending;
    NSUInteger budget = 1600;
    UITableView *table = RUINFindTableView(settings.view, &budget, 0);
    id<UITableViewDataSource> dataSource = table.dataSource;
    id<UITableViewDelegate> delegate = table.delegate;
    SEL rowCount = @selector(tableView:numberOfRowsInSection:);
    SEL didSelect = @selector(tableView:didSelectRowAtIndexPath:);
    if (!table || !dataSource || ![dataSource respondsToSelector:rowCount] ||
        !delegate || ![delegate respondsToSelector:didSelect]) return RUINNativeThemeSelectionPending;
    if ([dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)] &&
        [dataSource numberOfSectionsInTableView:table] < 1) {
        if (error) *error = RUINNativeThemeNavigationError(
            RUINNativeThemeNavigationGuardFailed, @"The native theme settings list is empty.");
        return RUINNativeThemeSelectionFailed;
    }
    if ([dataSource tableView:table numberOfRowsInSection:0] < 1) {
        if (error) *error = RUINNativeThemeNavigationError(
            RUINNativeThemeNavigationGuardFailed, @"The native theme settings list has no first row.");
        return RUINNativeThemeSelectionFailed;
    }

    NSIndexPath *firstRow = [NSIndexPath indexPathForRow:0 inSection:0];
    UITableViewCell *cell = [table cellForRowAtIndexPath:firstRow];
    if (!cell) return RUINNativeThemeSelectionPending;
    NSString *accessibilityLabel = cell.accessibilityLabel;
    BOOL titleMatches = RUINNativeMyThemesTitle(cell.textLabel.text) ||
        RUINNativeMyThemesTitle(accessibilityLabel) ||
        RUINLabelContainsMyThemes(cell.contentView);
    if (!titleMatches) {
        if (error) *error = RUINNativeThemeNavigationError(
            RUINNativeThemeNavigationGuardFailed, @"The native first row is not My Themes.");
        return RUINNativeThemeSelectionFailed;
    }

    [delegate tableView:table didSelectRowAtIndexPath:firstRow];
    return RUINNativeThemeSelectionDone;
}

static void RUINCompleteNativeThemeNavigation(RUINNativeThemeNavigationRequest *request,
    NSError *error)
{
    if (request.finished) return;
    request.finished = YES;
    RUINNativeMyThemesCompletion completion = request.completion;
    request.completion = nil;
    if (completion) completion(error);
}

static void RUINRetryNativeThemeNavigation(RUINNativeThemeNavigationRequest *request)
{
    if (request.finished) return;
    request.attempts++;
    UIWindowScene *preferredScene = request.owner.viewIfLoaded.window.windowScene;
    UIViewController *myThemes = RUINFindVisibleNativeController(RUINNativeMyThemesClassName, preferredScene);
    if (myThemes && (!request.refresh || !request.oldController || myThemes != request.oldController)) {
        RUINCompleteNativeThemeNavigation(request, nil);
        return;
    }

    if (!request.selected) {
        UIViewController *settings = RUINFindVisibleNativeController(RUINNativeThemeSettingsClassName, preferredScene);
        if (settings) {
            NSError *error = nil;
            RUINNativeThemeSelectionResult result = RUINSelectNativeMyThemes(settings, &error);
            if (result == RUINNativeThemeSelectionFailed) {
                RUINCompleteNativeThemeNavigation(request, error);
                return;
            }
            if (result == RUINNativeThemeSelectionDone) request.selected = YES;
        }
    }

    if (request.attempts >= RUINNativeThemeNavigationMaxAttempts) {
        RUINCompleteNativeThemeNavigation(request, RUINNativeThemeNavigationError(
            RUINNativeThemeNavigationTimedOut, @"LINE did not present My Themes in time."));
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(RUINNativeThemeNavigationRetryDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RUINRetryNativeThemeNavigation(request);
    });
}

static BOOL RUINDispatchNativeThemeSettingsRoute(NSError **error)
{
    id delegate = UIApplication.sharedApplication.delegate;
    Class appDelegateClass = RUINNativeClass(RUINNativeAppDelegateClassName);
    SEL selector = sel_registerName("openURLForObjC:");
    Method method = appDelegateClass ? class_getInstanceMethod(appDelegateClass, selector) : NULL;
    if (!RUINNativeThemeNavigationTargetMatches()) {
        if (error) *error = RUINNativeThemeNavigationError(
            RUINNativeThemeNavigationVersionMismatch, @"This LINE build is not supported.");
        return NO;
    }
    if (!delegate || object_getClass(delegate) != appDelegateClass || !method ||
        strcmp(method_getTypeEncoding(method), "B24@0:8@16")) {
        if (error) *error = RUINNativeThemeNavigationError(
            RUINNativeThemeNavigationUnavailable, @"LINE's native theme route is unavailable.");
        return NO;
    }
    @try {
        BOOL (^dispatch)(void) = ^BOOL {
            return [(id<RUINThemeURLRouting>)delegate openURLForObjC:[NSURL URLWithString:RUINNativeMyThemesURL]];
        };
        BOOL accepted = RUINDispatchOwnedThemeRoute(3, dispatch);
        if (!accepted && error) *error = RUINNativeThemeNavigationError(
            RUINNativeThemeNavigationUnavailable, @"LINE rejected the native theme route.");
        return accepted;
    } @catch (__unused NSException *exception) {
        if (error) *error = RUINNativeThemeNavigationError(
            RUINNativeThemeNavigationUnavailable, @"LINE's native theme route raised an exception.");
        return NO;
    }
}

void RUINOpenNativeMyThemes(UIViewController *owner, RUINNativeMyThemesCompletion completion)
{
    __weak UIViewController *weakOwner = owner;
    dispatch_block_t open = ^{
        UIViewController *strongOwner = weakOwner;
        if (!strongOwner || !RUINOwnerIsVisible(strongOwner)) {
            if (completion) completion(RUINNativeThemeNavigationError(
                RUINNativeThemeNavigationUnavailable, @"A visible LINE screen is required."));
            return;
        }
        NSError *error = nil;
        if (!RUINDispatchNativeThemeSettingsRoute(&error)) {
            if (completion) completion(error);
            return;
        }
        RUINNativeThemeNavigationRequest *request = [RUINNativeThemeNavigationRequest new];
        request.owner = strongOwner;
        request.completion = completion;
        RUINRetryNativeThemeNavigation(request);
    };
    if (NSThread.isMainThread) open();
    else dispatch_async(dispatch_get_main_queue(), open);
}

void RUINRefreshNativeMyThemes(UIViewController *controller, RUINNativeMyThemesCompletion completion)
{
    __weak UIViewController *weakController = controller;
    dispatch_block_t refresh = ^{
        UIViewController *current = weakController;
        UINavigationController *navigation = current.navigationController;
        if (!RUINObjectHasExactClass(current, RUINNativeMyThemesClassName) ||
            !current.viewIfLoaded.window || !navigation || navigation.topViewController != current) {
            if (completion) completion(RUINNativeThemeNavigationError(
                RUINNativeThemeNavigationUnavailable, @"The current My Themes screen changed."));
            return;
        }
        if (navigation.transitionCoordinator || current.transitionCoordinator ||
            navigation.presentedViewController || current.presentedViewController) {
            if (completion) completion(RUINNativeThemeNavigationError(
                RUINNativeThemeNavigationBusy, @"The native theme navigation is busy."));
            return;
        }
        NSArray<UIViewController *> *stack = navigation.viewControllers;
        NSInteger currentIndex = (NSInteger)[stack indexOfObjectIdenticalTo:current];
        UIViewController *settings = nil;
        Class settingsClass = RUINNativeClass(RUINNativeThemeSettingsClassName);
        for (NSInteger i = currentIndex - 1; i >= 0; i--) {
            if (settingsClass && object_getClass(stack[(NSUInteger)i]) == settingsClass) {
                settings = stack[(NSUInteger)i];
                break;
            }
        }
        if (currentIndex < 1 || !settings) {
            if (completion) completion(RUINNativeThemeNavigationError(
                RUINNativeThemeNavigationUnavailable, @"The native theme settings parent was not found."));
            return;
        }

        RUINNativeThemeNavigationRequest *request = [RUINNativeThemeNavigationRequest new];
        request.refresh = YES;
        request.oldController = current;
        request.navigationController = navigation;
        request.settingsController = settings;
        request.completion = completion;
        request.owner = settings;
        [navigation popToViewController:settings animated:YES];
        // Let LINE complete its normal pop transition before selecting its row.
        // Preserve the native navigation transition before pushing a fresh model.
        dispatch_async(dispatch_get_main_queue(), ^{ RUINRetryNativeThemeNavigation(request); });
    };
    if (NSThread.isMainThread) refresh();
    else dispatch_async(dispatch_get_main_queue(), refresh);
}

@interface RUINNativeMyThemesController : UIViewController @end

%group RUINNativeMyThemes
%hook RUINNativeMyThemesController
- (void)viewDidAppear:(BOOL)animated
{
    %orig;
    id object = self;

    os_unfair_lock_lock(&gNativeMyThemesHandlerLock);
    RUINNativeMyThemesDidAppearHandler handler = gNativeMyThemesDidAppearHandler;
    os_unfair_lock_unlock(&gNativeMyThemesHandlerLock);
    if (!handler || !RUINObjectHasExactClass(object, RUINNativeMyThemesClassName)) return;
    __weak UIViewController *weakController = object;
    dispatch_block_t notify = ^{
        UIViewController *controller = weakController;
        if (!controller) return;
        @try { handler(controller); }
        @catch (__unused NSException *exception) {}
    };
    if (NSThread.isMainThread) notify();
    else dispatch_async(dispatch_get_main_queue(), notify);
}
%end
%end

void RUINSetNativeMyThemesDidAppearHandler(RUINNativeMyThemesDidAppearHandler handler)
{
    os_unfair_lock_lock(&gNativeMyThemesHandlerLock);
    gNativeMyThemesDidAppearHandler = [handler copy];
    os_unfair_lock_unlock(&gNativeMyThemesHandlerLock);
}

static BOOL RUINClassOwnsSelector(Class cls, SEL selector)
{
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL owns = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            owns = YES;
            break;
        }
    }
    free(methods);
    return owns;
}

void RUINInstallNativeMyThemesDidAppearHook(void)
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINInstallNativeMyThemesDidAppearHook(); });
        return;
    }
    if (gNativeMyThemesHookInstalled || !RUINNativeThemeNavigationTargetMatches()) return;
    Class cls = RUINNativeClass(RUINNativeMyThemesClassName);
    SEL selector = @selector(viewDidAppear:);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!cls || !method || !encoding || strcmp(encoding, "v20@0:8B16") ||
        RUINClassOwnsSelector(cls, selector)) return;

    if (!method_getImplementation(method)) return;
    %init(RUINNativeMyThemes, RUINNativeMyThemesController=cls);
    gNativeMyThemesHookInstalled = YES;
}
