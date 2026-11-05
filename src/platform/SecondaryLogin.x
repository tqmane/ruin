%config(generator=internal);

#import "SecondaryLogin.h"
#import "Features.h"
#import "LINEPrivateCalls.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <stdatomic.h>

NSString *const RUINSecondaryLoginEnabledKey = @"RUINSecondaryLoginEnabled";
static BOOL activeSecondaryMode, installed, welcomeHookInstalled, secondaryScreenHookInstalled;
static BOOL autoLoginOpened;
static BOOL autoQROpened;
static atomic_ulong appIdiomRequests;
static char gestureKey;
static NSString *lastLoginScreen;

static BOOL Supported(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier] &&
        [info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] && [info[@"CFBundleVersion"] isEqual:RUINTargetBuild];
}
%group RUINSecondaryDeviceRole
%hook UIDevice
- (UIUserInterfaceIdiom)userInterfaceIdiom
{
    if (activeSecondaryMode) {
        Dl_info info;
        // Capture LINE's caller here: a helper function's caller is this dylib.
        void *caller = __builtin_extract_return_addr(__builtin_return_address(0));
        if (dladdr(caller, &info) && info.dli_fbase == (void *)_dyld_get_image_header(0)) {
            atomic_fetch_add(&appIdiomRequests, 1);
            return UIUserInterfaceIdiomPad;
        }
    }
    return %orig;
}
%end
%end

static void ShowRestartNotice(UIViewController *controller) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ログイン方法を切り替えました"
        message:@"LINEを一度完全に終了して開き直してください。次回起動時から選んだログイン方法になります。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"確認" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}
static void ToggleSecondaryLogin(id self, SEL selector, UILongPressGestureRecognizer *gesture) {
    (void)selector;
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIViewController *controller = self;
    if (controller.presentedViewController) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"ログイン方法"
        message:@"サブ端末では、現在のメイン端末でQRコードを読み取り、ログインを承認します。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *enabled in @[@YES, @NO]) {
        NSString *title = enabled.boolValue ? @"iPad扱いでサブ端末ログイン" : @"通常のiPhoneログイン";
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [NSUserDefaults.standardUserDefaults setBool:enabled.boolValue forKey:RUINSecondaryLoginEnabledKey];
            dispatch_async(dispatch_get_main_queue(), ^{ ShowRestartNotice(controller); });
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    if (menu.popoverPresentationController) {
        menu.popoverPresentationController.sourceView = gesture.view;
        menu.popoverPresentationController.sourceRect = gesture.view.bounds;
    }
    [controller presentViewController:menu animated:YES completion:nil];
}
static UIControl *FindLoginControl(UIView *view, id owner) {
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        for (id target in control.allTargets) {
            NSArray *actions = [control actionsForTarget:target forControlEvent:UIControlEventTouchUpInside];
            if (target == owner && [actions containsObject:@"loginButtonAction"]) return control;
        }
    }
    for (UIView *child in view.subviews) {
        UIControl *found = FindLoginControl(child, owner);
        if (found) return found;
    }
    return nil;
}
static void WelcomeDidAppear(id self) {
    lastLoginScreen = @"welcome";
    UIControl *control = FindLoginControl(((UIViewController *)self).view, self);
    if (control && !objc_getAssociatedObject(control, &gestureKey)) {
        UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:sel_registerName("ruin_chooseLoginMode:")];
        gesture.minimumPressDuration = 0.65;
        gesture.cancelsTouchesInView = YES;
        [control addGestureRecognizer:gesture];
        objc_setAssociatedObject(control, &gestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (activeSecondaryMode && !autoLoginOpened &&
        [NSProcessInfo.processInfo.environment[@"RUIN_OPEN_SECONDARY_LOGIN"] isEqual:@"1"]) {
        autoLoginOpened = YES;
        __weak UIViewController *controller = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (controller.view.window && !controller.presentedViewController)
                [(id<RUINLINEWelcomeCalls>)controller loginButtonAction];
        });
    }
}
static void SecondaryDidAppear(id self) {
    lastLoginScreen = @"native_secondary_login";
    if (activeSecondaryMode && !autoQROpened &&
        [NSProcessInfo.processInfo.environment[@"RUIN_OPEN_SECONDARY_LOGIN"] isEqual:@"1"]) {
        autoQROpened = YES;
        __weak UIViewController *controller = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (controller.view.window && !controller.presentedViewController) {
                [(id<RUINLINESecondaryLoginCalls>)controller showQRCodeLoginButtonPressed];
                lastLoginScreen = @"native_secondary_qr_requested";
            }
        });
    }
}
%group RUINWelcomeLogin
%hook RUINWelcomeController
- (void)viewDidAppear:(BOOL)animated
{
    %orig(animated);
    WelcomeDidAppear(self);
}
- (void)loginButtonAction
{
    BOOL requested = [NSUserDefaults.standardUserDefaults boolForKey:RUINSecondaryLoginEnabledKey];
    if (requested != activeSecondaryMode) { ShowRestartNotice(self); return; }
    %orig;
}
%new(v24@0:8@16)
- (void)ruin_chooseLoginMode:(UILongPressGestureRecognizer *)gesture
{
    ToggleSecondaryLogin(self, _cmd, gesture);
}
%end
%end

%group RUINSecondaryLoginScreen
%hook RUINSecondaryController
- (void)viewDidAppear:(BOOL)animated
{
    %orig(animated);
    SecondaryDidAppear(self);
}
%end
%end

static BOOL RUINSecondaryMethodMatches(Class cls, const char *name, const char *types)
{
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName(name)) : NULL;
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && !strcmp(actual, types) && method_getImplementation(method) != NULL;
}

void RUINInstallSecondaryLogin(void) {
    if (!Supported()) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *requested = NSProcessInfo.processInfo.environment[@"RUIN_SECONDARY_LOGIN"];
        if ([requested isEqual:@"1"] || [requested isEqual:@"0"])
            [NSUserDefaults.standardUserDefaults setBool:[requested isEqual:@"1"] forKey:RUINSecondaryLoginEnabledKey];
        activeSecondaryMode = [NSUserDefaults.standardUserDefaults boolForKey:RUINSecondaryLoginEnabledKey];
        if (RUINSecondaryMethodMatches(UIDevice.class, "userInterfaceIdiom", "q16@0:8")) {
            %init(RUINSecondaryDeviceRole);
            installed = YES;
        }
    });
    if (!welcomeHookInstalled) {
        Class welcome = objc_getClass("_TtC18LineRegistrationUI21WelcomeViewController");
        // Validate the complete group before adding the action or any hook.
        if (RUINSecondaryMethodMatches(welcome, "viewDidAppear:", "v20@0:8B16") &&
            RUINSecondaryMethodMatches(welcome, "loginButtonAction", "v16@0:8") &&
            !class_getInstanceMethod(welcome, sel_registerName("ruin_chooseLoginMode:"))) {
            %init(RUINWelcomeLogin, RUINWelcomeController = welcome);
            welcomeHookInstalled = YES;
        }
    }
    if (!secondaryScreenHookInstalled) {
        Class secondary = objc_getClass("_TtC20LineSecondaryLoginUI28SecondaryLoginViewController");
        if (RUINSecondaryMethodMatches(secondary, "viewDidAppear:", "v20@0:8B16")) {
            %init(RUINSecondaryLoginScreen, RUINSecondaryController = secondary);
            secondaryScreenHookInstalled = YES;
        }
    }
}
NSDictionary *RUINSecondaryLoginDiagnostics(void) {
    return @{@"activeTabletRole":@(activeSecondaryMode), @"requestedTabletRole":@([NSUserDefaults.standardUserDefaults boolForKey:RUINSecondaryLoginEnabledKey]),
        @"deviceIdiomHookInstalled":@(installed), @"welcomeHooksInstalled":@(welcomeHookInstalled),
        @"secondaryScreenHookInstalled":@(secondaryScreenHookInstalled), @"tabletQueriesFromLINE":@(atomic_load(&appIdiomRequests)),
        @"lastLoginScreen":lastLoginScreen ?: @"not_observed", @"accountCoexistenceVerified":@NO};
}
