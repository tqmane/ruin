#import "SecondaryLoginTestUI.h"
#import <objc/runtime.h>
#import <assert.h>
#import <stdio.h>
#import "TargetMetadata.h"

static char traitsKey, frameKey, hiddenKey, elementsKey;
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
- (void)presentViewController:(UIViewController *)controller animated:(__unused BOOL)animated completion:(void (^)(void))completion { self.presentedViewController = controller; if (completion) completion(); }
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
+ (instancetype)alertControllerWithTitle:(__unused NSString *)title message:(__unused NSString *)message preferredStyle:(__unused UIAlertControllerStyle)style { UIAlertController *controller = [self new]; controller.actions = [NSMutableArray array]; controller.popoverPresentationController = [UIPopoverPresentationController new]; return controller; }
- (void)addAction:(UIAlertAction *)action { [self.actions addObject:action]; }
@end

// Replace only external Foundation dependencies in this translation unit.
// No real preference domain, storage migration, keychain, network or UIKit UI.
@interface RUINSecondaryFixtureDefaults : NSObject
@property(nonatomic, strong) NSMutableDictionary *values;
+ (instancetype)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
@end
@implementation RUINSecondaryFixtureDefaults
+ (instancetype)standardUserDefaults { static RUINSecondaryFixtureDefaults *value; if (!value) { value = [self new]; value.values = [NSMutableDictionary dictionary]; } return value; }
- (BOOL)boolForKey:(NSString *)key { return [self.values[key] boolValue]; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.values[key] = @(value); }
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
static NSUInteger storageInstalls, keychainInstalls, loginCalls, qrCalls;
void RUINInstallCompatibility(void) { storageInstalls++; }
void RUINInstallKeychainCompatibility(void) { keychainInstalls++; }
BOOL RUINStorageMigrationReady(void) { return storageReady; }
BOOL RUINKeychainCompatibilityReady(void) { return keychainReady; }

#define NSUserDefaults RUINSecondaryFixtureDefaults
#define NSBundle RUINSecondaryFixtureBundle
#import "SecondaryLoginUnderTest.m"
#undef NSBundle
#undef NSUserDefaults

@protocol RUINSecondaryFixtureActions <NSObject>
- (void)loginButtonAction;
- (void)showQRCodeLoginButtonPressed;
- (void)ruin_loginTap:(UITapGestureRecognizer *)recognizer;
- (void)ruin_chooseLoginMode:(UILongPressGestureRecognizer *)recognizer;
@end
@interface RUINFixtureSwiftUINode : NSObject <UIAccessibilityIdentification>
@property(nonatomic, copy) NSString *accessibilityIdentifier;
@end
@implementation RUINFixtureSwiftUINode @end
static void NativeLogin(__unused id self, __unused SEL selector) {
    loginCalls++; actionIdiom = UIDevice.currentDevice.userInterfaceIdiom;
    if (throwOnLogin) @throw [NSException exceptionWithName:@"Fixture" reason:nil userInfo:nil];
}
static void NativeQR(__unused id self, __unused SEL selector) { qrCalls++; actionIdiom = UIDevice.currentDevice.userInterfaceIdiom; }
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

int main(int argc, const char **argv) { @autoreleasepool {
    BOOL enabled = argc < 2 || strcmp(argv[1], "normal") != 0;
    BOOL mismatch = argc > 1 && strcmp(argv[1], "abi") == 0;
    RUINSecondaryFixtureDefaults *defaults = RUINSecondaryFixtureDefaults.standardUserDefaults;
    defaults.values[@"nativeRole"] = @"primary";
    [defaults setBool:enabled forKey:RUINSecondaryLoginEnabledKey];
    Class welcomeClass = RegisterController("_TtC18LineRegistrationUI21WelcomeViewController",
        @selector(loginButtonAction), (IMP)NativeLogin, "v16@0:8");
    Class secondaryClass = RegisterController("_TtC20LineSecondaryLoginUI28SecondaryLoginViewController",
        @selector(showQRCodeLoginButtonPressed), (IMP)NativeQR, mismatch ? "q16@0:8" : "v16@0:8");
    RUINInstallSecondaryLogin(); RUINInstallSecondaryLogin();
    assert(deviceIdiomHookInstalled && welcomeHookInstalled);
    assert(secondaryScreenHookInstalled == !mismatch);
    NSUInteger original = deviceQueries;
    assert(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    assert(deviceQueries == original + 1); // Enabled preference alone never projects.
    if (mismatch) { puts("PASS secondary ABI mismatch rejected before group init"); return 0; }

    UIViewController *welcome = [welcomeClass new];
    [welcome viewDidLoad]; assert(welcome.loads == 1 && loginProjectionDepth == 0);
    assert(lifecycleIdiom == (enabled ? UIUserInterfaceIdiomPad : physicalIdiom));
    welcome.view.window = [UIWindow new];
    UIAccessibilityElement *button = LoginElement();
    welcome.view.fixtureAccessibilityElements = @[button];
    [welcome viewDidAppear:NO]; [welcome viewDidAppear:NO];
    assert(welcome.appearances == 2 && welcome.view.gestureRecognizers.count == 2);
    UITapGestureRecognizer *tap = (id)welcome.view.gestureRecognizers[0];
    UILongPressGestureRecognizer *press = (id)welcome.view.gestureRecognizers[1];
    assert([tap isKindOfClass:UITapGestureRecognizer.class] && tap.requiredFailure == press);
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
    NSObject *container = [NSObject new]; container.fixtureAccessibilityElements = @[node];
    welcome.view.fixtureAccessibilityElements = @[container];
    assert(RUINPointIsOnNativeLoginButton(welcome, touch.point));
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
    assert(backgroundIdiom == UIUserInterfaceIdiomPhone);

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
    assert(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    assert(!RUINPointIsOnNativeLoginButton(welcome, touch.point));

    UIViewController *secondary = [secondaryClass new];
    [secondary viewDidLoad]; secondary.view.window = [UIWindow new]; [secondary viewDidAppear:NO];
    [(id<RUINSecondaryFixtureActions>)secondary showQRCodeLoginButtonPressed];
    assert(qrCalls == 1 && actionIdiom == (enabled ? UIUserInterfaceIdiomPad : physicalIdiom));
    storageReady = NO;
    [(id<RUINSecondaryFixtureActions>)secondary showQRCodeLoginButtonPressed];
    assert(qrCalls == 1);
    storageReady = YES; secondary.presentedViewController = nil;
    [secondary viewDidDisappear:NO];
    assert(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone);
    physicalIdiom = UIUserInterfaceIdiomPad;
    assert(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad);
    physicalIdiom = UIUserInterfaceIdiomPhone;

    // Existing UIKit target/action path remains a single long-press attachment.
    UIViewController *legacy = [welcomeClass new];
    UIControl *control = [UIControl new]; control.actionOwner = legacy;
    legacy.view.subviews = @[control]; legacy.view.window = [UIWindow new];
    [legacy viewDidAppear:NO]; [legacy viewDidAppear:NO];
    assert(control.gestureRecognizers.count == 1 && legacy.view.gestureRecognizers.count == 0);
    UILongPressGestureRecognizer *legacyPress = (id)control.gestureRecognizers[0];
    legacyPress.state = UIGestureRecognizerStateChanged;
    [(id<RUINSecondaryFixtureActions>)legacy ruin_chooseLoginMode:legacyPress];
    assert(!legacy.presentedViewController);
    legacyPress.state = UIGestureRecognizerStateBegan;
    [(id<RUINSecondaryFixtureActions>)legacy ruin_chooseLoginMode:legacyPress];
    UIAlertController *menu = (id)legacy.presentedViewController;
    assert(menu.actions.count == 3 && [menu.actions[0].title isEqual:@"iPad扱いでサブ端末ログイン"]);
    menu.actions[0].handler(menu.actions[0]);
    assert([defaults boolForKey:RUINSecondaryLoginEnabledKey]);
    assert([defaults.values[@"nativeRole"] isEqual:@"primary"] && defaults.values.count == 2);
    puts("PASS secondary login native hooks: SwiftUI exact button/bounds, normal+QR preflight, role scope/cleanup, original-once, UIKit fallback, restart mismatch, no native-role preference writes");
} return 0; }
