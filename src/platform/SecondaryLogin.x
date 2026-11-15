%config(generator=internal);

#import "SecondaryLogin.h"
#import "Sideload.h"
#import "Keychain.h"
#import "../core/Localization.h"
#import "Features.h"
#import "../core/TargetMetadata.h"
#import "LINEPrivateCalls.h"
#import "BinaryVerifier.h"
#import "FeatureImage.h"
#import <UIKit/UIKit.h>
#import <UIKit/UIGestureRecognizerSubclass.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <string.h>

NSString *const RUINSecondaryLoginEnabledKey = @"RUINSecondaryLoginEnabled";
@protocol RUINAccessibilityElementsProviding <NSObject>
- (NSArray *)accessibilityElements;
@end

static BOOL activeSecondaryMode;
static BOOL deviceIdiomHookInstalled, welcomeHookInstalled, secondaryScreenHookInstalled;
static BOOL secondaryRegistrationReturnHookInstalled;
static BOOL autoLoginOpened;
static BOOL autoQROpened;
static atomic_ulong appIdiomRequests, enabledIdiomQueries, LINEIdiomQueries;
static atomic_ulong unscopedLINEQueries, backgroundLINEQueries, otherImageQueries;
static _Atomic(const void *) verifiedLoginGuestImage;
static RUINFeatureImage loginGuestImage;
static atomic_bool loginGuestProofScheduled = ATOMIC_VAR_INIT(false);
static char gestureKey, welcomeVisibleKey;
static NSString *lastLoginScreen;
static __weak UIViewController *loginProjectionOwner;
static _Thread_local NSUInteger loginProjectionDepth;
static atomic_ulong swiftUILoginBindings;
static atomic_bool welcomeHooksReady = ATOMIC_VAR_INIT(false);
static atomic_bool secondaryHooksReady = ATOMIC_VAR_INIT(false);
static atomic_bool welcomeCatchUpScheduled = ATOMIC_VAR_INIT(false);
static atomic_bool secondaryLoginRetryScheduled = ATOMIC_VAR_INIT(false);
static atomic_uint secondaryLoginRetryCount = ATOMIC_VAR_INIT(0);

static void RUINScheduleWelcomeCatchUp(void);
static void RUINSecondaryLoginImageAdded(const struct mach_header *header, intptr_t slide);

static BOOL RUINHasLoginProjectionScope(void) {
    if (!activeSecondaryMode || !NSThread.isMainThread) return NO;
    return loginProjectionDepth || loginProjectionOwner.viewIfLoaded.window != nil;
}

static BOOL RUINMigrationPreflight(UIViewController *controller) {
    RUINInstallCompatibility();
    RUINInstallKeychainCompatibility();
    if (RUINStorageMigrationReady() && RUINKeychainCompatibilityReady()) return YES;
    if (!controller.presentedViewController) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"login.data_protection_title")
            message:RUINLocalizedString(@"login.data_protection_message")
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.confirm") style:UIAlertActionStyleDefault handler:nil]];
        [controller presentViewController:alert animated:YES completion:nil];
    }
    return NO;
}

static BOOL RUINSecondaryLoginTargetMatches(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return RUINTargetMetadataMatchesInfo(info);
}

// Resolve the class owner, not its replaceable login action IMP. Run loader
// lifetime proof after initialization/dyld callbacks have returned; a failed
// attempt can be retried by the next explicit install or activation.
static void RUINScheduleLoginGuestImageProof(Class welcome) {
    if (!welcome || atomic_load_explicit(&verifiedLoginGuestImage, memory_order_acquire)) return;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&loginGuestProofScheduled, &expected, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&loginGuestProofScheduled, false);
        if (atomic_load_explicit(&verifiedLoginGuestImage, memory_order_acquire)) return;
        const RUINVersionMapping *mapping = RUINMappingForInfo(NSBundle.mainBundle.infoDictionary);
        RUINFeatureImage image = {0};
        if (!mapping || !RUINResolveFeatureImage(&mapping->host, welcome, &image)) return;
        if (!image.convertedExecutable) {
            // Native/JB/sideload callers retain the existing strict resolver,
            // including version-independent public UIKit support.
            RUINReleaseFeatureImage(&image);
            return;
        }
        loginGuestImage = image; // Retain the guest while the idiom hook uses it.
        atomic_store_explicit(&verifiedLoginGuestImage, image.image.header, memory_order_release);
    });
}

static BOOL RUINLoginCallerIsUnpinnedGuest(const Dl_info *caller) {
    Class welcome = objc_getClass("_TtC18LineRegistrationUI21WelcomeViewController");
    const char *ownerPath = welcome ? class_getImageName(welcome) : NULL;
    const RUINVersionMapping *mapping = RUINMappingForInfo(NSBundle.mainBundle.infoDictionary);
    if (!mapping || !ownerPath || !caller->dli_fbase || !caller->dli_fname) return NO;

    // This caller is executing now, so its image must remain alive through the
    // public idiom query. Borrow that lifetime only for this call, never cache
    // its base or open a loader handle while LINE/LC may still be initializing.
    // Compare headers first; do not canonicalize every unrelated dyld path.
    RUINDyldImageCandidate candidate = {0};
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        if (header != caller->dli_fbase) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (candidate.header && candidate.slide != slide) return NO;
        candidate = (RUINDyldImageCandidate){header, slide, caller->dli_fname};
    }
    if (!candidate.header || count != _dyld_image_count()) return NO;
    RUINFeatureImage image = {0};
    // A null process path deliberately requires the converted-guest shape.
    // The shared parser safely copies/validates commands, canonical paths,
    // architecture, UUID and slide; this proof authorizes no numeric calls.
    return RUINResolveFeatureImageFromCandidates(&mapping->host,
        NSBundle.mainBundle.executablePath.fileSystemRepresentation, NULL, ownerPath,
        candidate.header, &candidate, 1, &image) && image.convertedExecutable;
}

static BOOL RUINLoginCallerIsLINE(void *caller) {
    Dl_info info;
    if (!dladdr(caller, &info)) return NO;
    // The verified guest already identifies LINE. A strict MH_EXECUTE lookup
    // cannot resolve this MH_DYLIB and must not run on every UIKit idiom query.
    const void *guest = atomic_load_explicit(&verifiedLoginGuestImage, memory_order_acquire);
    if (guest) return info.dli_fbase == guest;
    RUINMainExecutableImage image;
    if (RUINResolveMainExecutableImage(&image) && info.dli_fbase == (const void *)image.header) return YES;
    // LINE can cache its role before the queued guest pin is able to run.
    return RUINLoginCallerIsUnpinnedGuest(&info);
}

%group RUINSecondaryDeviceRole
%hook UIDevice
- (UIUserInterfaceIdiom)userInterfaceIdiom {
    UIUserInterfaceIdiom nativeIdiom = %orig;
    if (!activeSecondaryMode) return nativeIdiom;
    atomic_fetch_add(&enabledIdiomQueries, 1);
    void *caller = __builtin_extract_return_addr(__builtin_return_address(0));
    if (!RUINLoginCallerIsLINE(caller)) { atomic_fetch_add(&otherImageQueries, 1); return nativeIdiom; }
    atomic_fetch_add(&LINEIdiomQueries, 1);
    if (!RUINHasLoginProjectionScope()) atomic_fetch_add(&unscopedLINEQueries, 1);
    if (!NSThread.isMainThread) atomic_fetch_add(&backgroundLINEQueries, 1);
    // LINE caches its device role before Welcome and queries it again from
    // async login tasks. UIKit/SwiftUI callers still receive the physical idiom.
    atomic_fetch_add(&appIdiomRequests, 1);
    return UIUserInterfaceIdiomPad;
}
%end
%end

static void RUINShowLoginRestartNotice(UIViewController *controller) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"login.method_changed")
        message:RUINLocalizedString(@"login.restart_message")
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.confirm") style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static BOOL RUINRequestPrimaryLoginAfterRestart(UIViewController *controller) {
    if (!activeSecondaryMode) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:NO forKey:RUINSecondaryLoginEnabledKey];
    [defaults synchronize];
    lastLoginScreen = @"primary_restart_requested";
    __weak UIViewController *weakController = controller;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakController) RUINShowLoginRestartNotice(weakController);
    });
    return YES;
}

static void RUINPresentLoginModeMenu(UIViewController *controller, UILongPressGestureRecognizer *gesture) {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (controller.presentedViewController) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"login.method_title")
        message:RUINLocalizedString(@"login.secondary_help")
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *enabled in @[@YES, @NO]) {
        NSString *title = enabled.boolValue ? RUINLocalizedString(@"login.secondary_action") : RUINLocalizedString(@"login.primary_action");
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            [defaults setBool:enabled.boolValue forKey:RUINSecondaryLoginEnabledKey];
            [defaults synchronize];
            dispatch_async(dispatch_get_main_queue(), ^{ RUINShowLoginRestartNotice(controller); });
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    if (menu.popoverPresentationController) {
        menu.popoverPresentationController.sourceView = gesture.view;
        menu.popoverPresentationController.sourceRect = gesture.view.bounds;
    }
    [controller presentViewController:menu animated:YES completion:nil];
}

static UIControl *RUINFindLoginControl(UIView *view, id owner) {
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        for (id target in control.allTargets) {
            NSArray *actions = [control actionsForTarget:target forControlEvent:UIControlEventTouchUpInside];
            if (target == owner && [actions containsObject:@"loginButtonAction"]) return control;
        }
    }
    for (UIView *child in view.subviews) {
        UIControl *found = RUINFindLoginControl(child, owner);
        if (found) return found;
    }
    return nil;
}

static BOOL RUINIsNativeLoginElement(id object) {
    if (![object isKindOfClass:NSObject.class]) return NO;
    NSObject *element = object;
    if ([element isKindOfClass:UIView.class] && ([(UIView *)element isHidden] || [(UIView *)element alpha] <= 0.01)) return NO;
    return !element.accessibilityElementsHidden &&
        [element respondsToSelector:@selector(accessibilityIdentifier)] &&
        [[(id<UIAccessibilityIdentification>)element accessibilityIdentifier] isEqualToString:@"login"] &&
        (element.accessibilityTraits & UIAccessibilityTraitButton) &&
        !(element.accessibilityTraits & UIAccessibilityTraitNotEnabled) &&
        !CGRectIsEmpty(element.accessibilityFrame);
}

static void RUINFindLoginAccessibilityElement(id object, NSHashTable *visited,
    NSUInteger depth, NSUInteger *budget, id *match, BOOL *ambiguous) {
    if (!object || [visited containsObject:object]) return;
    if (!*budget || depth > 16) { *ambiguous = YES; return; }
    (*budget)--;
    [visited addObject:object];
    if ([object isKindOfClass:UIView.class] && ([(UIView *)object isHidden] || [(UIView *)object alpha] <= 0.01)) return;
    // WelcomeView's native SwiftUI identifier, button trait and unique element.
    if ([object isKindOfClass:NSObject.class]) {
        NSObject *element = object;
        if (element.accessibilityElementsHidden) return;
        if (RUINIsNativeLoginElement(element)) {
            if (*match && *match != object) *ambiguous = YES;
            *match = object;
        }
        if ([element respondsToSelector:@selector(accessibilityElements)]) {
            NSArray *children = [(id<RUINAccessibilityElementsProviding>)element accessibilityElements];
            if ([children isKindOfClass:NSArray.class]) {
                if (children.count > 128) *ambiguous = YES;
                else for (id child in children) {
                    if (!*budget) break;
                    RUINFindLoginAccessibilityElement(child, visited, depth + 1, budget, match, ambiguous);
                }
            }
        }
        NSInteger count = [element accessibilityElementCount];
        if (count != NSNotFound && count > 128) *ambiguous = YES;
        if (count != NSNotFound && count > 0 && count <= 128)
            for (NSInteger index = 0; index < count && *budget; index++)
                RUINFindLoginAccessibilityElement([element accessibilityElementAtIndex:index],
                    visited, depth + 1, budget, match, ambiguous);
    }
    if ([object isKindOfClass:UIView.class])
        for (UIView *child in [(UIView *)object subviews])
            RUINFindLoginAccessibilityElement(child, visited, depth + 1, budget, match, ambiguous);
}

static BOOL RUINPointIsOnNativeLoginButton(UIViewController *owner, CGPoint point) {
    UIView *root = owner.viewIfLoaded;
    if (!root.window || root.hidden || root.alpha <= 0.01 || root.accessibilityElementsHidden || owner.presentedViewController ||
        ![objc_getAssociatedObject(owner, &welcomeVisibleKey) boolValue]) return NO;
    CGRect screenPoint = UIAccessibilityConvertFrameToScreenCoordinates((CGRect){point, CGSizeZero}, root);
    // Ask the native container for this touch before enumerating its children.
    // SwiftUI may materialize an AX hit without exposing a full child graph;
    // distinct wrappers in that graph need not be distinct buttons. iOS 18+.
    id hit = [root accessibilityHitTest:screenPoint.origin withEvent:nil];
    NSString *hitIdentifier = [hit respondsToSelector:@selector(accessibilityIdentifier)] ?
        [(id<UIAccessibilityIdentification>)hit accessibilityIdentifier] : nil;
    // Some containers return themselves without identifying a button; preserve
    // the existing child traversal in that case. An identified hit is decisive.
    if (hitIdentifier.length) return RUINIsNativeLoginElement(hit) &&
        CGRectContainsPoint([(NSObject *)hit accessibilityFrame], screenPoint.origin);
    NSUInteger budget = 256;
    BOOL ambiguous = NO;
    id match = nil;
    RUINFindLoginAccessibilityElement(root,
        [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality],
        0, &budget, &match, &ambiguous);
    if (!match || ambiguous || !budget) return NO;
    return CGRectContainsPoint([(NSObject *)match accessibilityFrame], screenPoint.origin);
}

@interface RUINLoginGestureDelegate : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIViewController *owner;
@end
@implementation RUINLoginGestureDelegate
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    return RUINPointIsOnNativeLoginButton(self.owner, [touch locationInView:recognizer.view]);
}
@end

@interface RUINLoginTapGestureRecognizer : UITapGestureRecognizer
@property(nonatomic, weak) UIGestureRecognizer *modeGesture;
@end
@implementation RUINLoginTapGestureRecognizer
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other {
    BOOL native = [super canBePreventedByGestureRecognizer:other];
    // The native SwiftUI tap must not bypass preflight or enqueue a second login.
    // Our long press still wins; the delegate rejects every non-login touch.
    return other == self.modeGesture ? native : NO;
}
@end

@interface RUINLoginLongPressGestureRecognizer : UILongPressGestureRecognizer
@end
@implementation RUINLoginLongPressGestureRecognizer
- (BOOL)canBePreventedByGestureRecognizer:(__unused UIGestureRecognizer *)other { return NO; }
@end

static void RUINWelcomeDidAppear(UIViewController *controller) {
    lastLoginScreen = @"welcome";
    loginProjectionOwner = controller;
    objc_setAssociatedObject(controller, &welcomeVisibleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIControl *control = RUINFindLoginControl(controller.view, controller);
    UIView *targetView = control ?: controller.view;
    if (!objc_getAssociatedObject(targetView, &gestureKey)) {
        UILongPressGestureRecognizer *gesture = [[RUINLoginLongPressGestureRecognizer alloc]
            initWithTarget:controller action:sel_registerName("ruin_chooseLoginMode:")];
        gesture.minimumPressDuration = 0.65;
        gesture.cancelsTouchesInView = YES;
        if (!control) {
            RUINLoginGestureDelegate *delegate = [RUINLoginGestureDelegate new];
            delegate.owner = controller;
            gesture.delegate = delegate;
            RUINLoginTapGestureRecognizer *tap = [[RUINLoginTapGestureRecognizer alloc]
                initWithTarget:controller action:sel_registerName("ruin_loginTap:")];
            tap.modeGesture = gesture;
            tap.delegate = delegate;
            tap.cancelsTouchesInView = YES;
            [tap requireGestureRecognizerToFail:gesture];
            [targetView addGestureRecognizer:tap];
            objc_setAssociatedObject(gesture, &gestureKey, delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            atomic_fetch_add(&swiftUILoginBindings, 1);
        }
        [targetView addGestureRecognizer:gesture];
        objc_setAssociatedObject(targetView, &gestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (activeSecondaryMode && !autoLoginOpened &&
        [NSProcessInfo.processInfo.environment[@"RUIN_OPEN_SECONDARY_LOGIN"] isEqual:@"1"]) {
        autoLoginOpened = YES;
        __weak UIViewController *weakController = controller;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (weakController.view.window && !weakController.presentedViewController)
                [(id<RUINLINEWelcomeCalls>)weakController loginButtonAction];
        });
    }
}

static void RUINSecondaryLoginDidAppear(UIViewController *controller) {
    lastLoginScreen = @"native_secondary_login";
    loginProjectionOwner = controller;
    if (activeSecondaryMode && !autoQROpened &&
        [NSProcessInfo.processInfo.environment[@"RUIN_OPEN_SECONDARY_LOGIN"] isEqual:@"1"]) {
        autoQROpened = YES;
        __weak UIViewController *weakController = controller;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (weakController.view.window && !weakController.presentedViewController) {
                [(id<RUINLINESecondaryLoginCalls>)weakController showQRCodeLoginButtonPressed];
                lastLoginScreen = @"native_secondary_qr_requested";
            }
        });
    }
}

static void RUINScanWelcomeControllerTree(UIViewController *controller, Class welcomeClass,
    NSHashTable *visited, NSUInteger depth, NSUInteger *budget) {
    if (!controller || depth > 32 || !*budget || [visited containsObject:controller]) return;
    (*budget)--;
    [visited addObject:controller];

    if ([controller class] == welcomeClass) {
        UIView *view = controller.viewIfLoaded;
        if (view.window && !view.hidden && view.alpha > 0.01) RUINWelcomeDidAppear(controller);
    }
    RUINScanWelcomeControllerTree(controller.presentedViewController, welcomeClass, visited, depth + 1, budget);
    for (UIViewController *child in controller.childViewControllers) {
        if (!*budget) break;
        RUINScanWelcomeControllerTree(child, welcomeClass, visited, depth + 1, budget);
    }
}

static void RUINScanForegroundWelcomeControllers(void) {
    Class welcomeClass = objc_getClass("_TtC18LineRegistrationUI21WelcomeViewController");
    if (!welcomeClass) return;
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    NSUInteger budget = 512;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || !window.rootViewController || !budget) continue;
            RUINScanWelcomeControllerTree(window.rootViewController, welcomeClass, visited, 0, &budget);
        }
    }
}

static void RUINScheduleWelcomeCatchUp(void) {
    if (!atomic_load(&welcomeHooksReady)) return;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&welcomeCatchUpScheduled, &expected, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&welcomeCatchUpScheduled, false);
        if (atomic_load(&welcomeHooksReady)) RUINScanForegroundWelcomeControllers();
    });
}

%group RUINWelcomeLogin
%hook RUINWelcomeController
- (void)viewDidLoad
{
    loginProjectionDepth++;
    @try { %orig; } @finally { loginProjectionDepth--; }
}
- (void)viewDidAppear:(BOOL)animated
{
    loginProjectionDepth++;
    @try { %orig(animated); } @finally { loginProjectionDepth--; }
    RUINWelcomeDidAppear(self);
}
- (void)viewDidDisappear:(BOOL)animated
{
    %orig(animated);
    objc_setAssociatedObject(self, &welcomeVisibleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (loginProjectionOwner == self) loginProjectionOwner = nil;
}
- (void)loginButtonAction
{
    if (!RUINMigrationPreflight(self)) return;
    BOOL requested = [NSUserDefaults.standardUserDefaults boolForKey:RUINSecondaryLoginEnabledKey];
    if (requested != activeSecondaryMode) {
        RUINShowLoginRestartNotice(self);
        return;
    }
    loginProjectionDepth++;
    @try { %orig; } @finally { loginProjectionDepth--; }
}
%new(v24@0:8@16)
- (void)ruin_loginTap:(UITapGestureRecognizer *)gesture
{
    UIViewController *owner = (UIViewController *)self;
    if (gesture.state == UIGestureRecognizerStateRecognized &&
        RUINPointIsOnNativeLoginButton(owner, [gesture locationInView:owner.view]))
        [(id<RUINLINEWelcomeCalls>)self loginButtonAction];
}
%new(v24@0:8@16)
- (void)ruin_chooseLoginMode:(UILongPressGestureRecognizer *)gesture
{
    RUINPresentLoginModeMenu(self, gesture);
}
%end
%end

%group RUINSecondaryLoginScreen
%hook RUINSecondaryController
- (void)viewDidLoad
{
    loginProjectionDepth++;
    @try { %orig; } @finally { loginProjectionDepth--; }
}
- (void)viewDidAppear:(BOOL)animated
{
    loginProjectionDepth++;
    @try { %orig(animated); } @finally { loginProjectionDepth--; }
    RUINSecondaryLoginDidAppear(self);
}
- (void)viewDidDisappear:(BOOL)animated
{
    %orig(animated);
    if (loginProjectionOwner == self) loginProjectionOwner = nil;
}
- (void)showQRCodeLoginButtonPressed {
    if (!RUINMigrationPreflight(self)) return;
    loginProjectionDepth++;
    @try { %orig; } @finally { loginProjectionDepth--; }
}
- (void)showPrimaryDeviceLoginButtonPressed {
    if (!RUINRequestPrimaryLoginAfterRestart(self)) %orig;
}
%end
%end

%group RUINSecondaryRegistrationReturn
%hook RUINSecondaryRegistrationController
- (void)showRegistrationFlowButtonPressed {
    if (!RUINRequestPrimaryLoginAfterRestart(self)) %orig;
}
%end
%end

static BOOL RUINSecondaryMethodMatches(Class cls, const char *name, const char *types)
{
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName(name)) : NULL;
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && !strcmp(actual, types) && method_getImplementation(method) != NULL;
}

static void RUINSecondaryLoginImageAdded(__unused const struct mach_header *header, __unused intptr_t slide) {
    if (atomic_load(&welcomeHooksReady) && atomic_load(&secondaryHooksReady)) return;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&secondaryLoginRetryScheduled, &expected, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&secondaryLoginRetryScheduled, false);
        if (atomic_load(&welcomeHooksReady) && atomic_load(&secondaryHooksReady)) return;
        // Unrelated dyld loads must not exhaust retries before LINE arrives,
        // and Welcome being ready does not prove the secondary module is ready.
        atomic_fetch_add(&secondaryLoginRetryCount, 1);
        RUINInstallSecondaryLogin();
    });
}

void RUINInstallSecondaryLogin(void) {
    if (!RUINSecondaryLoginTargetMatches()) return;
    static dispatch_once_t imageCallbackOnce;
    dispatch_once(&imageCallbackOnce, ^{
        _dyld_register_func_for_add_image(RUINSecondaryLoginImageAdded);
    });
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *requested = NSProcessInfo.processInfo.environment[@"RUIN_SECONDARY_LOGIN"];
        if ([requested isEqual:@"1"] || [requested isEqual:@"0"])
            [NSUserDefaults.standardUserDefaults setBool:[requested isEqual:@"1"] forKey:RUINSecondaryLoginEnabledKey];
        activeSecondaryMode = [NSUserDefaults.standardUserDefaults boolForKey:RUINSecondaryLoginEnabledKey];
        if (RUINSecondaryMethodMatches(UIDevice.class, "userInterfaceIdiom", "q16@0:8")) {
            %init(RUINSecondaryDeviceRole);
            deviceIdiomHookInstalled = YES;
        }
    });
    if (!welcomeHookInstalled) {
        Class welcome = objc_getClass("_TtC18LineRegistrationUI21WelcomeViewController");
        // Validate the complete group before adding the action or any hook.
        if ([welcome isSubclassOfClass:UIViewController.class] &&
            RUINSecondaryMethodMatches(welcome, "viewDidLoad", "v16@0:8") &&
            RUINSecondaryMethodMatches(welcome, "viewDidAppear:", "v20@0:8B16") &&
            RUINSecondaryMethodMatches(welcome, "viewDidDisappear:", "v20@0:8B16") &&
            RUINSecondaryMethodMatches(welcome, "loginButtonAction", "v16@0:8") &&
            !class_getInstanceMethod(welcome, sel_registerName("ruin_chooseLoginMode:")) &&
            !class_getInstanceMethod(welcome, sel_registerName("ruin_loginTap:"))) {
            %init(RUINWelcomeLogin, RUINWelcomeController = welcome);
            welcomeHookInstalled = YES;
            atomic_store(&welcomeHooksReady, true);
        }
    }
    if (!secondaryScreenHookInstalled) {
        Class secondary = objc_getClass("_TtC20LineSecondaryLoginUI28SecondaryLoginViewController");
        if ([secondary isSubclassOfClass:UIViewController.class] &&
            RUINSecondaryMethodMatches(secondary, "viewDidLoad", "v16@0:8") &&
            RUINSecondaryMethodMatches(secondary, "viewDidAppear:", "v20@0:8B16") &&
            RUINSecondaryMethodMatches(secondary, "viewDidDisappear:", "v20@0:8B16") &&
            RUINSecondaryMethodMatches(secondary, "showQRCodeLoginButtonPressed", "v16@0:8") &&
            RUINSecondaryMethodMatches(secondary, "showPrimaryDeviceLoginButtonPressed", "v16@0:8")) {
            %init(RUINSecondaryLoginScreen, RUINSecondaryController = secondary);
            secondaryScreenHookInstalled = YES;
            atomic_store(&secondaryHooksReady, true);
        }
    }
    // The native bottom return button targets this selector, independently of
    // the phone/QR content-mode actions. Keep it optional and validate its ABI.
    if (!secondaryRegistrationReturnHookInstalled) {
        Class secondary = objc_getClass("_TtC20LineSecondaryLoginUI28SecondaryLoginViewController");
        if ([secondary isSubclassOfClass:UIViewController.class] &&
            RUINSecondaryMethodMatches(secondary, "showRegistrationFlowButtonPressed", "v16@0:8")) {
            %init(RUINSecondaryRegistrationReturn, RUINSecondaryRegistrationController = secondary);
            secondaryRegistrationReturnHookInstalled = YES;
        }
    }
    if (welcomeHookInstalled)
        RUINScheduleLoginGuestImageProof(objc_getClass("_TtC18LineRegistrationUI21WelcomeViewController"));
    RUINScheduleWelcomeCatchUp();
}

NSDictionary *RUINSecondaryLoginDiagnostics(void) {
    return @{
        @"activeTabletRole": @(activeSecondaryMode),
        @"requestedTabletRole": @([NSUserDefaults.standardUserDefaults boolForKey:RUINSecondaryLoginEnabledKey]),
        @"deviceIdiomHookInstalled": @(deviceIdiomHookInstalled),
        @"welcomeHooksInstalled": @(welcomeHookInstalled),
        @"secondaryScreenHookInstalled": @(secondaryScreenHookInstalled),
        @"secondaryRegistrationReturnHookInstalled": @(secondaryRegistrationReturnHookInstalled),
        @"hookRetryCount": @(atomic_load(&secondaryLoginRetryCount)),
        @"tabletQueriesFromLINE": @(atomic_load(&appIdiomRequests)),
        @"enabledIdiomQueries":@(atomic_load(&enabledIdiomQueries)),
        @"queriesFromLINE":@(atomic_load(&LINEIdiomQueries)),
        @"queriesFromLINEOutsideVisibleLogin":@(atomic_load(&unscopedLINEQueries)),
        @"queriesFromLINEBackgroundThread":@(atomic_load(&backgroundLINEQueries)),
        @"queriesFromOtherImages":@(atomic_load(&otherImageQueries)),
        @"verifiedLoginGuestImage":@(atomic_load_explicit(&verifiedLoginGuestImage, memory_order_acquire) != NULL),
        @"loginProjectionActive": @(RUINHasLoginProjectionScope()),
        @"swiftUILoginBindings": @(atomic_load(&swiftUILoginBindings)),
        @"lastLoginScreen": lastLoginScreen ?: @"not_observed",
        @"accountCoexistenceVerified": @NO
    };
}
