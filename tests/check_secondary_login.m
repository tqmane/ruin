#import "SecondaryLoginTestUI.h"
#import <objc/runtime.h>
#import <assert.h>
#import <stdio.h>
#import "TargetMetadata.h"
#import <stdatomic.h>
#import <dlfcn.h>

static atomic_uint_fast64_t strictImageResolutions;
static BOOL CountMainExecutableResolution(RUINMainExecutableImage *image) {
    atomic_fetch_add(&strictImageResolutions, 1);
    return RUINResolveMainExecutableImage(image);
}

static char traitsKey, frameKey, hiddenKey, elementsKey;
static NSUInteger fixtureSynchronizeCount, syncCountAtLastAlertPresentation;
static NSString *lastPresentedAlertTitle;
static void (*registeredImageCallback)(const struct mach_header *, intptr_t);
static NSUInteger imageCallbackRegistrations;
static BOOL applicationAccessedOffMainThread;

void RUINTestRegisterFuncForAddImage(void (*callback)(const struct mach_header *, intptr_t)) {
    registeredImageCallback = callback;
    imageCallbackRegistrations++;
}

@implementation NSObject (RUINSecondaryTestAccessibility)
- (UIAccessibilityTraits)accessibilityTraits { return [objc_getAssociatedObject(self, &traitsKey) unsignedLongLongValue]; }
- (void)setAccessibilityTraits:(UIAccessibilityTraits)value { objc_setAssociatedObject(self, &traitsKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (CGRect)accessibilityFrame { CGRect value = CGRectZero; [objc_getAssociatedObject(self, &frameKey) getValue:&value size:sizeof(value)]; return value; }
- (void)setAccessibilityFrame:(CGRect)value { objc_setAssociatedObject(self, &frameKey, [NSValue valueWithBytes:&value objCType:@encode(CGRect)], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (BOOL)accessibilityElementsHidden { return [objc_getAssociatedObject(self, &hiddenKey) boolValue]; }
- (void)setAccessibilityElementsHidden:(BOOL)value { objc_setAssociatedObject(self, &hiddenKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSArray *)fixtureAccessibilityElements { return objc_getAssociatedObject(self, &elementsKey) ?: @[]; }
- (void)setFixtureAccessibilityElements:(NSArray *)value { objc_setAssociatedObject(self, &elementsKey, [value copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSInteger)accessibilityElementCount { return (NSInteger)self.fixtureAccessibilityElements.count; }
- (id)accessibilityElementAtIndex:(NSInteger)index { return self.fixtureAccessibilityElements[(NSUInteger)index]; }
@end
@implementation UIView
- (instancetype)init { if ((self = [super init])) { _alpha = 1; _subviews = @[]; _gestureRecognizers = [NSMutableArray array]; } return self; }
- (void)addGestureRecognizer:(UIGestureRecognizer *)recognizer { recognizer.view = self; [self.gestureRecognizers addObject:recognizer]; }
@end
@implementation UIWindow @end
@implementation UIAccessibilityElement @end
@implementation UIControl
- (NSSet *)allTargets { return self.actionOwner ? [NSSet setWithObject:self.actionOwner] : [NSSet set]; }
- (NSArray *)actionsForTarget:(id)target forControlEvent:(UIControlEvents)event { return target == self.actionOwner && event == UIControlEventTouchUpInside ? @[@"loginButtonAction"] : @[]; }
@end
static NSUInteger deviceQueries;
static UIUserInterfaceIdiom physicalIdiom, lifecycleIdiom, actionIdiom;
@implementation UIDevice
+ (instancetype)currentDevice { static UIDevice *device; if (!device) device = [self new]; return device; }
- (UIUserInterfaceIdiom)userInterfaceIdiom { deviceQueries++; return physicalIdiom; }
@end
@implementation UIViewController
- (instancetype)init { if ((self = [super init])) _view = [UIView new]; return self; }
- (UIView *)viewIfLoaded { return self.view; }
- (void)viewDidLoad { self.loads++; lifecycleIdiom = UIDevice.currentDevice.userInterfaceIdiom; }
- (void)viewDidAppear:(__unused _Bool)animated { self.appearances++; lifecycleIdiom = UIDevice.currentDevice.userInterfaceIdiom; }
- (void)viewDidDisappear:(__unused _Bool)animated { self.disappearances++; }
- (void)presentViewController:(UIViewController *)controller animated:(__unused BOOL)animated completion:(void (^)(void))completion {
    self.presentedViewController = controller;
    if ([controller isKindOfClass:UIAlertController.class]) {
        lastPresentedAlertTitle = ((UIAlertController *)controller).title;
        syncCountAtLastAlertPresentation = fixtureSynchronizeCount;
    }
    if (completion) completion();
}
@end
@implementation UIScene @end
@implementation UIWindowScene @end
@implementation UIApplication
+ (instancetype)sharedApplication {
    if (!NSThread.isMainThread) applicationAccessedOffMainThread = YES;
    static UIApplication *application; if (!application) application = [self new]; return application;
}
@end
@implementation UIGestureRecognizer
- (instancetype)initWithTarget:(id)target action:(SEL)action { if ((self = [super init])) { _target = target; _action = action; } return self; }
- (void)requireGestureRecognizerToFail:(UIGestureRecognizer *)recognizer { self.requiredFailure = recognizer; }
- (CGPoint)locationInView:(__unused UIView *)view { return self.fixturePoint; }
- (BOOL)canBePreventedByGestureRecognizer:(__unused UIGestureRecognizer *)recognizer { return YES; }
@end
@implementation UILongPressGestureRecognizer @end
@implementation UITapGestureRecognizer @end
@implementation UITouch
- (CGPoint)locationInView:(__unused UIView *)view { return self.point; }
@end
@implementation UIPopoverPresentationController @end
@implementation UIAlertAction
+ (instancetype)actionWithTitle:(NSString *)title style:(UIAlertActionStyle)style handler:(void (^)(UIAlertAction *))handler { UIAlertAction *action = [self new]; action.title = title; action.style = style; action.handler = handler; return action; }
@end
@implementation UIAlertController
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(__unused NSString *)message preferredStyle:(__unused UIAlertControllerStyle)style { UIAlertController *controller = [self new]; controller.title = title; controller.actions = [NSMutableArray array]; controller.popoverPresentationController = [UIPopoverPresentationController new]; return controller; }
- (void)addAction:(UIAlertAction *)action { [self.actions addObject:action]; }
@end

// Replace only external Foundation dependencies in this translation unit.
// No real preference domain, storage migration, keychain, network or UIKit UI.
@interface RUINSecondaryFixtureDefaults : NSObject
@property(nonatomic, strong) NSMutableDictionary *values;
+ (instancetype)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (BOOL)synchronize;
@end
@implementation RUINSecondaryFixtureDefaults
+ (instancetype)standardUserDefaults { static RUINSecondaryFixtureDefaults *value; if (!value) { value = [self new]; value.values = [NSMutableDictionary dictionary]; } return value; }
- (BOOL)boolForKey:(NSString *)key { return [self.values[key] boolValue]; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.values[key] = @(value); }
- (BOOL)synchronize { fixtureSynchronizeCount++; return YES; }
@end
@interface RUINSecondaryFixtureBundle : NSObject
+ (instancetype)mainBundle;
@property(nonatomic, readonly) NSDictionary *infoDictionary;
@end
@implementation RUINSecondaryFixtureBundle
+ (instancetype)mainBundle { static RUINSecondaryFixtureBundle *value; if (!value) value = [self new]; return value; }
- (NSDictionary *)infoDictionary { return @{@"CFBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"}; }
@end
static BOOL storageReady = YES, keychainReady = YES, throwOnLogin;
static NSUInteger storageInstalls, keychainInstalls, loginCalls, qrCalls, primaryDeviceLoginCalls;
void RUINInstallCompatibility(void) { storageInstalls++; }
void RUINInstallKeychainCompatibility(void) { keychainInstalls++; }
BOOL RUINStorageMigrationReady(void) { return storageReady; }
BOOL RUINKeychainCompatibilityReady(void) { return keychainReady; }

#define NSUserDefaults RUINSecondaryFixtureDefaults
#define NSBundle RUINSecondaryFixtureBundle
#define RUINResolveMainExecutableImage CountMainExecutableResolution
#import "SecondaryLoginUnderTest.m"
#undef RUINResolveMainExecutableImage
#undef NSBundle
#undef NSUserDefaults

@protocol RUINSecondaryFixtureActions <NSObject>
- (void)loginButtonAction;
- (void)showQRCodeLoginButtonPressed;
- (void)showPrimaryDeviceLoginButtonPressed;
- (void)ruin_loginTap:(UITapGestureRecognizer *)recognizer;
- (void)ruin_chooseLoginMode:(UILongPressGestureRecognizer *)recognizer;
@end
@interface RUINFixtureSwiftUINode : NSObject
@property(nonatomic, copy) NSString *accessibilityIdentifier;
@end
@implementation RUINFixtureSwiftUINode @end
@interface RUINFixtureAccessibilityArrayContainer : NSObject
@property(nonatomic, copy) NSArray *accessibilityElements;
@end
@implementation RUINFixtureAccessibilityArrayContainer
- (NSInteger)accessibilityElementCount { return NSNotFound; }
@end
static void NativeLogin(__unused id self, __unused SEL selector) {
    loginCalls++; actionIdiom = UIDevice.currentDevice.userInterfaceIdiom;
    if (throwOnLogin) @throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];
}
static void NativeQR(__unused id self, __unused SEL selector) { qrCalls++; actionIdiom = UIDevice.currentDevice.userInterfaceIdiom; }
static void NativePrimaryDeviceLogin(__unused id self, __unused SEL selector) { primaryDeviceLoginCalls++; }
static void CheckVerifiedGuestCallerFastPath(void) {
    Dl_info guest, framework;
    assert(dladdr((const void *)NativeLogin, &guest));
    assert(dladdr((const void *)NSClassFromString, &framework));
    assert(guest.dli_fbase != framework.dli_fbase);
    const struct mach_header_64 *saved = verifiedLoginGuestImage;
    // Model an already-verified owner. UUID/type verification remains in the
    // production discovery path; this fixture checks subsequent caller queries.
    verifiedLoginGuestImage = guest.dli_fbase;
    uint64_t before = atomic_load(&strictImageResolutions);
    for (NSUInteger i = 0; i < 1000; i++) {
        assert(RUINLoginCallerIsLINE((void *)NativeLogin));
        assert(!RUINLoginCallerIsLINE((void *)NSClassFromString));
    }
    assert(atomic_load(&strictImageResolutions) == before);
    verifiedLoginGuestImage = saved;
    assert(RUINLoginCallerIsLINE((void *)NativeLogin));
    assert(atomic_load(&strictImageResolutions) == before + 1);
    puts("PASS verified guest: 2000 caller queries, zero strict image scans; native fallback preserved");
}
static Class RegisterController(const char *name, SEL selector, IMP implementation, const char *encoding) {
    Class cls = objc_allocateClassPair(UIViewController.class, name, 0);
    assert(cls && class_addMethod(cls, selector, implementation, encoding));
    objc_registerClassPair(cls); return cls;
}
static UIAccessibilityElement *LoginElement(void) {
    UIAccessibilityElement *button = [UIAccessibilityElement new];
    button.accessibilityIdentifier = @"login";
    button.accessibilityTraits = UIAccessibilityTraitButton;
    button.accessibilityFrame = CGRectMake(10, 20, 120, 50);
    return button;
}
static void Tap(id<RUINSecondaryFixtureActions> owner, UITapGestureRecognizer *tap) {
    tap.state = UIGestureRecognizerStateRecognized; tap.fixturePoint = CGPointMake(40, 40);
    [owner ruin_loginTap:tap];
}

static void DrainMainQueue(void) {
    for (NSUInteger i = 0; i < 20; i++)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);
}

int main(int argc, const char **argv) { @autoreleasepool {
    CheckVerifiedGuestCallerFastPath();
    BOOL enabled = argc < 2 || strcmp(argv[1], "normal") != 0;
    BOOL mismatch = argc > 1 && strcmp(argv[1], "abi") == 0;
    RUINSecondaryFixtureDefaults *defaults = RUINSecondaryFixtureDefaults.standardUserDefaults;
    defaults.values[@"nativeRole"] = @"primary";
    [defaults setBool:enabled forKey:RUINSecondaryLoginEnabledKey];
    RUINInstallSecondaryLogin(); RUINInstallSecondaryLogin();
    assert(deviceIdiomHookInstalled && !welcomeHookInstalled && !secondaryScreenHookInstalled);
    assert(imageCallbackRegistrations == 1 && registeredImageCallback);
    NSUInteger original = deviceQueries;
    assert(UIDevice.currentDevice.userInterfaceIdiom == (enabled ? UIUserInterfaceIdiomPad : UIUserInterfaceIdiomPhone));
    assert(deviceQueries == original + 1); // LINE-owned startup queries participate before Welcome is visible.

    Class welcomeClass = RegisterController("_TtC18LineRegistrationUI21WelcomeViewController",
        @selector(loginButtonAction), (IMP)NativeLogin, "v16@0:8");
    Class secondaryClass = RegisterController("_TtC20LineSecondaryLoginUI28SecondaryLoginViewController",
        @selector(showQRCodeLoginButtonPressed), (IMP)NativeQR, "v16@0:8");
    assert(class_addMethod(secondaryClass, @selector(showPrimaryDeviceLoginButtonPressed),
        (IMP)NativePrimaryDeviceLogin, mismatch ? "q16@0:8" : "v16@0:8"));

    UIApplication *application = UIApplication.sharedApplication;
    UIWindowScene *activeScene = [UIWindowScene new]; activeScene.activationState = UISceneActivationStateForegroundActive;
    UIWindow *activeWindow = [UIWindow new]; activeWindow.windowScene = activeScene; activeScene.windows = @[activeWindow];
    UIWindowScene *backgroundScene = [UIWindowScene new]; backgroundScene.activationState = UISceneActivationStateBackground;
    UIWindow *backgroundWindow = [UIWindow new]; backgroundWindow.windowScene = backgroundScene; backgroundScene.windows = @[backgroundWindow];
    application.connectedScenes = [NSSet setWithObjects:activeScene, backgroundScene, nil];

    UIViewController *container = [UIViewController new]; container.view.window = activeWindow;
    UIViewController *welcome = [welcomeClass new];
    welcome.view.window = activeWindow;
    welcome.view.fixtureAccessibilityElements = @[LoginElement()];
    [welcome viewDidLoad]; [welcome viewDidAppear:NO]; // Visible before the class hooks are installed.
    container.childViewControllers = @[welcome]; activeWindow.rootViewController = container;
    UIViewController *backgroundWelcome = [welcomeClass new];
    backgroundWelcome.view.window = backgroundWindow;
    backgroundWelcome.view.fixtureAccessibilityElements = @[LoginElement()];
    UIViewController *backgroundRoot = [UIViewController new]; backgroundRoot.childViewControllers = @[backgroundWelcome];
    backgroundRoot.view.window = backgroundWindow; backgroundWindow.rootViewController = backgroundRoot;

    dispatch_semaphore_t callbackReturned = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        registeredImageCallback(NULL, 0); dispatch_semaphore_signal(callbackReturned);
    });
    assert(dispatch_semaphore_wait(callbackReturned, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    registeredImageCallback(NULL, 0); registeredImageCallback(NULL, 0); // Coalesced while the main-queue retry is pending.
    DrainMainQueue();
    assert(deviceIdiomHookInstalled && welcomeHookInstalled);
    assert(secondaryScreenHookInstalled == !mismatch);
    assert(imageCallbackRegistrations == 1);
    assert(!applicationAccessedOffMainThread); // The dyld callback never touches UIKit off-main.
    assert(welcome.view.gestureRecognizers.count == 2); // Catch-up attached the already-visible exact Welcome.
    assert(backgroundWelcome.view.gestureRecognizers.count == 0); // Background scenes are excluded.
    RUINInstallSecondaryLogin(); RUINInstallSecondaryLogin(); DrainMainQueue();
    assert(welcome.view.gestureRecognizers.count == 2); // Repeated install/catch-up is idempotent.
    if (mismatch) { puts("PASS secondary ABI mismatch rejected before group init"); return 0; }

    [welcome viewDidLoad]; assert(welcome.loads == 2 && loginProjectionDepth == 0);
    assert(lifecycleIdiom == (enabled ? UIUserInterfaceIdiomPad : physicalIdiom));
    UIAccessibilityElement *button = LoginElement();
    welcome.view.fixtureAccessibilityElements = @[button];
    [welcome viewDidAppear:NO]; [welcome viewDidAppear:NO];
    assert(welcome.appearances == 3 && welcome.view.gestureRecognizers.count == 2);
    UITapGestureRecognizer *tap = (id)welcome.view.gestureRecognizers[0];
    UILongPressGestureRecognizer *press = (id)welcome.view.gestureRecognizers[1];
    assert([tap isKindOfClass:UITapGestureRecognizer.class] && tap.requiredFailure == press);
    assert([press isKindOfClass:RUINLoginLongPressGestureRecognizer.class]);
    assert(![press canBePreventedByGestureRecognizer:[UITapGestureRecognizer new]]);
    assert(![tap canBePreventedByGestureRecognizer:[UITapGestureRecognizer new]]);
    assert([tap canBePreventedByGestureRecognizer:press]);
    assert(tap.cancelsTouchesInView && press.cancelsTouchesInView && press.minimumPressDuration == 0.65);
    UITouch *touch = [UITouch new]; touch.point = CGPointMake(40, 40);
    assert([tap.delegate gestureRecognizer:tap shouldReceiveTouch:touch]);
    assert(!RUINPointIsOnNativeLoginButton(welcome, CGPointMake(300, 300)));
    button.accessibilityIdentifier = @"login.suffix";
    assert(![tap.delegate gestureRecognizer:tap shouldReceiveTouch:touch]);
    button.accessibilityIdentifier = @"login";
    button.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
    Tap((id)welcome, tap); assert(loginCalls == 0);
    button.accessibilityTraits = UIAccessibilityTraitButton;
    welcome.view.fixtureAccessibilityElements = @[button, LoginElement()];
    assert(!RUINPointIsOnNativeLoginButton(welcome, touch.point));
    welcome.view.fixtureAccessibilityElements = @[button];
    RUINFixtureSwiftUINode *node = [RUINFixtureSwiftUINode new];
    node.accessibilityIdentifier = @"login"; node.accessibilityTraits = UIAccessibilityTraitButton;
    node.accessibilityFrame = button.accessibilityFrame;
    RUINFixtureAccessibilityArrayContainer *arrayContainer = [RUINFixtureAccessibilityArrayContainer new];
    arrayContainer.accessibilityElements = @[node];
    welcome.view.fixtureAccessibilityElements = @[arrayContainer];
    assert(![node conformsToProtocol:@protocol(UIAccessibilityIdentification)]);
    assert(RUINPointIsOnNativeLoginButton(welcome, touch.point));
    arrayContainer.accessibilityElementsHidden = YES;
    assert(!RUINPointIsOnNativeLoginButton(welcome, touch.point));
    arrayContainer.accessibilityElementsHidden = NO;
    welcome.view.fixtureAccessibilityElements = @[button];
    button.accessibilityElementsHidden = YES;
    assert(!RUINPointIsOnNativeLoginButton(welcome, touch.point));
    button.accessibilityElementsHidden = NO;
    Tap((id)welcome, tap);
    assert(loginCalls == 1 && storageInstalls == 1 && keychainInstalls == 1);
    assert(actionIdiom == (enabled ? UIUserInterfaceIdiomPad : physicalIdiom));
    assert(loginProjectionDepth == 0);
    __block UIUserInterfaceIdiom backgroundIdiom = UIUserInterfaceIdiomPad;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        backgroundIdiom = UIDevice.currentDevice.userInterfaceIdiom; dispatch_semaphore_signal(done);
    });
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    assert(backgroundIdiom == (enabled ? UIUserInterfaceIdiomPad : UIUserInterfaceIdiomPhone));

    for (NSUInteger failure = 0; failure < 2; failure++) {
        storageReady = failure != 0; keychainReady = failure == 0;
        Tap((id)welcome, tap); assert(loginCalls == 1 && welcome.presentedViewController);
        welcome.presentedViewController = nil;
    }
    storageReady = keychainReady = YES;
    [defaults setBool:!enabled forKey:RUINSecondaryLoginEnabledKey];
    Tap((id)welcome, tap); assert(loginCalls == 1 && welcome.presentedViewController);
    welcome.presentedViewController = nil;
    [defaults setBool:enabled forKey:RUINSecondaryLoginEnabledKey];
    throwOnLogin = YES;
    @try { Tap((id)welcome, tap); assert(NO); } @catch (__unused NSException *exception) {}
    throwOnLogin = NO; assert(loginProjectionDepth == 0);
    [welcome viewDidDisappear:NO]; assert(welcome.disappearances == 1);
    assert(UIDevice.currentDevice.userInterfaceIdiom == (enabled ? UIUserInterfaceIdiomPad : UIUserInterfaceIdiomPhone));
    assert(!RUINPointIsOnNativeLoginButton(welcome, touch.point));

    UIViewController *secondary = [secondaryClass new];
    [secondary viewDidLoad]; secondary.view.window = [UIWindow new]; [secondary viewDidAppear:NO];
    [(id<RUINSecondaryFixtureActions>)secondary showQRCodeLoginButtonPressed];
    assert(qrCalls == 1 && actionIdiom == (enabled ? UIUserInterfaceIdiomPad : physicalIdiom));
    storageReady = NO;
    [(id<RUINSecondaryFixtureActions>)secondary showQRCodeLoginButtonPressed];
    assert(qrCalls == 1);
    storageReady = YES; secondary.presentedViewController = nil;
    NSUInteger syncBeforeReturn = fixtureSynchronizeCount;
    [(id<RUINSecondaryFixtureActions>)secondary showPrimaryDeviceLoginButtonPressed];
    if (enabled) {
        assert(primaryDeviceLoginCalls == 0);
        assert(![defaults boolForKey:RUINSecondaryLoginEnabledKey]);
        assert(activeSecondaryMode); // The live role changes only after restart.
        assert(fixtureSynchronizeCount == syncBeforeReturn + 1);
        DrainMainQueue();
        assert([lastPresentedAlertTitle isEqual:@"ログイン方法を切り替えました"]);
        assert(syncCountAtLastAlertPresentation == fixtureSynchronizeCount);
        secondary.presentedViewController = nil;
    } else {
        assert(primaryDeviceLoginCalls == 1);
        assert(fixtureSynchronizeCount == syncBeforeReturn);
        assert(!secondary.presentedViewController);
    }
    [secondary viewDidDisappear:NO];
    assert(UIDevice.currentDevice.userInterfaceIdiom == (enabled ? UIUserInterfaceIdiomPad : UIUserInterfaceIdiomPhone));
    physicalIdiom = UIUserInterfaceIdiomPad;
    assert(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad);
    physicalIdiom = UIUserInterfaceIdiomPhone;

    // Existing UIKit target/action path remains a single long-press attachment.
    UIViewController *legacy = [welcomeClass new];
    UIControl *control = [UIControl new]; control.actionOwner = legacy;
    UIControl *unrelatedControl = [UIControl new]; unrelatedControl.actionOwner = [NSObject new];
    legacy.view.subviews = @[control, unrelatedControl]; legacy.view.window = [UIWindow new];
    [legacy viewDidAppear:NO]; [legacy viewDidAppear:NO];
    assert(control.gestureRecognizers.count == 1 && unrelatedControl.gestureRecognizers.count == 0 &&
        legacy.view.gestureRecognizers.count == 0);
    UILongPressGestureRecognizer *legacyPress = (id)control.gestureRecognizers[0];
    legacyPress.state = UIGestureRecognizerStateChanged;
    [(id<RUINSecondaryFixtureActions>)legacy ruin_chooseLoginMode:legacyPress];
    assert(!legacy.presentedViewController);
    legacyPress.state = UIGestureRecognizerStateBegan;
    [(id<RUINSecondaryFixtureActions>)legacy ruin_chooseLoginMode:legacyPress];
    UIAlertController *menu = (id)legacy.presentedViewController;
    assert(menu.actions.count == 3 && [menu.actions[0].title isEqual:@"iPad扱いでサブ端末ログイン"]);
    menu.actions[0].handler(menu.actions[0]);
    assert(fixtureSynchronizeCount == (enabled ? 2 : 1));
    assert([defaults boolForKey:RUINSecondaryLoginEnabledKey]);
    assert([defaults.values[@"nativeRole"] isEqual:@"primary"] && defaults.values.count == 2);
    DrainMainQueue();
    assert([lastPresentedAlertTitle isEqual:@"ログイン方法を切り替えました"]);
    assert(syncCountAtLastAlertPresentation == fixtureSynchronizeCount); // Persisted before the restart notice.
    assert([defaults.values[@"nativeRole"] isEqual:@"primary"] && defaults.values.count == 2);
    puts("PASS secondary login: late-hook catch-up/retry, AX arrays/getters, idempotence, preflight, persisted preference, no native-role writes");
} return 0; }
