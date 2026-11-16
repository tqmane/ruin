#import "SecondaryLoginTestUI.h"
#import <objc/runtime.h>
#import <assert.h>
#import <stdio.h>
#import "TargetMetadata.h"
#import "FeatureImage.h"
#import <stdatomic.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void NativeLogin(id self, SEL selector);
typedef struct {
    struct mach_header_64 header;
    struct uuid_command uuid;
    struct { struct dylib_command command; char name[8]; } identifier;
    struct segment_command_64 text;
} RUINSecondaryTestImage;
static RUINSecondaryTestImage fixtureGuestImage;
static char fixtureLinePath[PATH_MAX], fixtureProcessPath[PATH_MAX];
static Class fixtureWelcomeOwner;
static BOOL fixtureImageEnabled, fixtureOwnerAvailable, fixturePinAllowed, fixtureNativeImage;
static BOOL fixtureGuestCaller, fixtureProofOnMainThread = YES;
static BOOL fixtureFrameworkCaller;
static BOOL fixtureForeignOwnerPath, fixtureForeignCallerPath;
static NSUInteger fixtureImageProofs;

// Substitute only the environment/lifetime inputs. The production image
// candidate parser still verifies canonical paths, conversion shape and UUID.
static BOOL FixtureResolveLoginImage(const RUINHostIdentity *host, Class owner, RUINFeatureImage *image) {
    fixtureImageProofs++;
    fixtureProofOnMainThread &= NSThread.isMainThread;
    if (!fixtureImageEnabled || !fixtureOwnerAvailable) return NO;
    assert(owner == fixtureWelcomeOwner);
    RUINDyldImageCandidate candidate = {&fixtureGuestImage.header, 0, fixtureLinePath};
    if (!RUINResolveFeatureImageFromCandidates(host, fixtureLinePath,
        fixtureNativeImage ? fixtureLinePath : fixtureProcessPath, fixtureLinePath,
        &fixtureGuestImage.header, &candidate, 1, image)) return NO;
    if (!fixturePinAllowed) { memset(image, 0, sizeof(*image)); return NO; }
    image->loaderReference = dlopen(NULL, RTLD_LAZY);
    assert(image->loaderReference);
    return YES;
}

static int FixtureLoginDladdr(const void *address, Dl_info *info) {
    if (fixtureFrameworkCaller) return dladdr((const void *)NSClassFromString, info);
    int found = dladdr(address, info);
    Dl_info native = {0};
    if (fixtureGuestCaller && found && dladdr((const void *)NativeLogin, &native) &&
        info->dli_fbase == native.dli_fbase) {
        memset(info, 0, sizeof(*info));
        info->dli_fbase = &fixtureGuestImage.header;
        info->dli_fname = fixtureForeignCallerPath ? fixtureProcessPath : fixtureLinePath;
        return 1;
    }
    // The native fixture's caller and Welcome owner describe the same image.
    if (fixtureNativeImage && found && dladdr((const void *)NativeLogin, &native) &&
        info->dli_fbase == native.dli_fbase) info->dli_fname = fixtureLinePath;
    return found;
}

static const char *FixtureLoginClassImageName(Class owner) {
    if (!fixtureImageEnabled) return class_getImageName(owner);
    assert(owner == fixtureWelcomeOwner);
    return fixtureOwnerAvailable ? (fixtureForeignOwnerPath ? fixtureProcessPath : fixtureLinePath) : NULL;
}

static atomic_uint_fast64_t fixtureDyldImageQueries;
static uint32_t FixtureLoginDyldImageCount(void) {
    atomic_fetch_add(&fixtureDyldImageQueries, 1);
    return fixtureGuestCaller ? 1 : _dyld_image_count();
}
static const struct mach_header *FixtureLoginDyldImageHeader(uint32_t index) {
    if (!fixtureGuestCaller) return _dyld_get_image_header(index);
    assert(index == 0);
    return (const void *)&fixtureGuestImage.header;
}
static intptr_t FixtureLoginDyldImageSlide(uint32_t index) {
    if (!fixtureGuestCaller) return _dyld_get_image_vmaddr_slide(index);
    assert(index == 0);
    return 0;
}

static atomic_uint_fast64_t strictImageResolutions;
static BOOL CountMainExecutableResolution(RUINMainExecutableImage *image) {
    atomic_fetch_add(&strictImageResolutions, 1);
    if (fixtureGuestCaller) return NO;
    return RUINResolveMainExecutableImage(image);
}

static char traitsKey, frameKey, hiddenKey, elementsKey;
static NSUInteger fixtureSynchronizeCount, syncCountAtLastAlertPresentation;
static NSDictionary *fixtureBundleInfo;
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
- (id)accessibilityHitTest:(__unused CGPoint)point withEvent:(__unused id)event { return nil; }
@end
@implementation UIView
- (instancetype)init { if ((self = [super init])) { _alpha = 1; _subviews = @[]; _gestureRecognizers = [NSMutableArray array]; } return self; }
- (void)addGestureRecognizer:(UIGestureRecognizer *)recognizer { recognizer.view = self; [self.gestureRecognizers addObject:recognizer]; }
- (id)accessibilityHitTest:(CGPoint)point withEvent:(__unused id)event {
    id hit = self.fixtureAccessibilityHit;
    return hit && CGRectContainsPoint([(NSObject *)hit accessibilityFrame], point) ? hit : nil;
}
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
@property(nonatomic, readonly) NSString *executablePath;
@end
@implementation RUINSecondaryFixtureBundle
+ (instancetype)mainBundle { static RUINSecondaryFixtureBundle *value; if (!value) value = [self new]; return value; }
- (NSDictionary *)infoDictionary { return fixtureBundleInfo ?: @{@"CFBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"}; }
- (NSString *)executablePath { return fixtureImageEnabled ? @(fixtureLinePath) : NSBundle.mainBundle.executablePath; }
@end
static BOOL storageReady = YES, keychainReady = YES, throwOnLogin;
static NSUInteger storageInstalls, keychainInstalls, loginCalls, qrCalls, primaryDeviceLoginCalls, registrationFlowCalls;
void RUINInstallCompatibility(void) { storageInstalls++; }
void RUINInstallKeychainCompatibility(void) { keychainInstalls++; }
BOOL RUINStorageMigrationReady(void) { return storageReady; }
BOOL RUINKeychainCompatibilityReady(void) { return keychainReady; }

#define NSUserDefaults RUINSecondaryFixtureDefaults
#define NSBundle RUINSecondaryFixtureBundle
#define RUINResolveMainExecutableImage CountMainExecutableResolution
#define RUINResolveFeatureImage FixtureResolveLoginImage
#define dladdr FixtureLoginDladdr
#define class_getImageName FixtureLoginClassImageName
#define _dyld_image_count FixtureLoginDyldImageCount
#define _dyld_get_image_header FixtureLoginDyldImageHeader
#define _dyld_get_image_vmaddr_slide FixtureLoginDyldImageSlide
#import "SecondaryLoginUnderTest.m"
#undef _dyld_get_image_vmaddr_slide
#undef _dyld_get_image_header
#undef _dyld_image_count
#undef class_getImageName
#undef dladdr
#undef RUINResolveFeatureImage
#undef RUINResolveMainExecutableImage
#undef NSBundle
#undef NSUserDefaults

@protocol RUINSecondaryFixtureActions <NSObject>
- (void)loginButtonAction;
- (void)showQRCodeLoginButtonPressed;
- (void)showPrimaryDeviceLoginButtonPressed;
- (void)showRegistrationFlowButtonPressed;
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
static void NativeRegistrationFlow(__unused id self, __unused SEL selector) { registrationFlowCalls++; }
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

static void CheckRegistrationReturn(Class secondaryClass, BOOL enabled) {
    // Reproduce a screen whose appearance predates hook installation. Returning
    // must not depend on Welcome, a gesture, AX initialization or preflight.
    UIViewController *controller = [secondaryClass new];
    RUINSecondaryFixtureDefaults *defaults = RUINSecondaryFixtureDefaults.standardUserDefaults;
    NSUInteger nativeBefore = registrationFlowCalls, syncBefore = fixtureSynchronizeCount;
    NSUInteger storageBefore = storageInstalls, keychainBefore = keychainInstalls;
    storageReady = keychainReady = NO;
    [(id<RUINSecondaryFixtureActions>)controller showRegistrationFlowButtonPressed];
    assert(registrationFlowCalls == nativeBefore + (enabled ? 0 : 1));
    assert(fixtureSynchronizeCount == syncBefore + (enabled ? 1 : 0));
    assert(![defaults boolForKey:RUINSecondaryLoginEnabledKey]);
    assert(activeSecondaryMode == enabled); // No live/native role mutation.
    DrainMainQueue();
    if (enabled) {
        assert([((UIAlertController *)controller.presentedViewController).title isEqual:@"ログイン方法を切り替えました"]);
        assert(syncCountAtLastAlertPresentation == syncBefore + 1);
    } else assert(!controller.presentedViewController);
    assert(storageInstalls == storageBefore && keychainInstalls == keychainBefore);
    assert([defaults.values[@"nativeRole"] isEqual:@"primary"] && defaults.values.count == 2);
    storageReady = keychainReady = YES;
    [defaults setBool:enabled forKey:RUINSecondaryLoginEnabledKey]; // Reset only the fixture.
    puts("PASS native bottom return: persisted RUIN OFF before restart notice; native original once when mode OFF");
}

static void ResetLoginGuestProof(void) {
    // Test-only process reset. Production keeps a published proof for hook lifetime.
    assert(!atomic_load(&loginGuestProofScheduled));
    atomic_store(&verifiedLoginGuestImage, NULL);
    RUINReleaseFeatureImage(&loginGuestImage);
}

static void CheckLoginGuestImageProof(Class welcomeClass) {
    char directory[PATH_MAX];
    int length = snprintf(directory, sizeof(directory), "%sruin-login-XXXXXX", NSTemporaryDirectory().fileSystemRepresentation);
    assert(length > 0 && (size_t)length < sizeof(directory) && mkdtemp(directory));
    length = snprintf(fixtureLinePath, sizeof(fixtureLinePath), "%s/LINE", directory);
    assert(length > 0 && (size_t)length < sizeof(fixtureLinePath));
    length = snprintf(fixtureProcessPath, sizeof(fixtureProcessPath), "%s/Container", directory);
    assert(length > 0 && (size_t)length < sizeof(fixtureProcessPath));
    int line = open(fixtureLinePath, O_CREAT | O_EXCL | O_WRONLY, 0600);
    int process = open(fixtureProcessPath, O_CREAT | O_EXCL | O_WRONLY, 0600);
    assert(line >= 0 && process >= 0); close(line); close(process);
    const RUINVersionMapping *mapping = RUINMappingForInfo(RUINSecondaryFixtureBundle.mainBundle.infoDictionary);
    assert(mapping && welcomeHookInstalled);
    fixtureGuestImage.header = (struct mach_header_64){.magic=MH_MAGIC_64, .cputype=CPU_TYPE_ARM64,
        .cpusubtype=CPU_SUBTYPE_ARM64_ALL, .filetype=MH_DYLIB, .ncmds=3,
        .sizeofcmds=sizeof(fixtureGuestImage)-sizeof(fixtureGuestImage.header), .flags=MH_NO_REEXPORTED_DYLIBS};
    fixtureGuestImage.uuid = (struct uuid_command){.cmd=LC_UUID, .cmdsize=sizeof(fixtureGuestImage.uuid)};
    [[[NSUUID alloc] initWithUUIDString:@(mapping->host.uuid)] getUUIDBytes:fixtureGuestImage.uuid.uuid];
    fixtureGuestImage.identifier.command = (struct dylib_command){.cmd=LC_ID_DYLIB,
        .cmdsize=sizeof(fixtureGuestImage.identifier), .dylib.name.offset=sizeof(struct dylib_command)};
    strcpy(fixtureGuestImage.identifier.name, "LINE");
    fixtureGuestImage.text = (struct segment_command_64){.cmd=LC_SEGMENT_64,
        .cmdsize=sizeof(fixtureGuestImage.text), .vmaddr=(uintptr_t)&fixtureGuestImage,
        .vmsize=sizeof(fixtureGuestImage), .initprot=VM_PROT_READ};
    strcpy(fixtureGuestImage.text.segname, "__TEXT");
    fixtureWelcomeOwner = welcomeClass;
    fixtureImageEnabled = fixturePinAllowed = YES;
    fixtureOwnerAvailable = NO;

    // Hooks are already installed: an initially missing owner still gets a
    // later proof attempt, and no loader API runs in an initializer/callback.
    NSUInteger before = fixtureImageProofs;
    RUINInstallSecondaryLogin(); RUINInstallSecondaryLogin();
    assert(fixtureImageProofs == before);
    DrainMainQueue();
    assert(fixtureImageProofs == before + 1 && !atomic_load(&verifiedLoginGuestImage));
    fixtureOwnerAvailable = YES;
    fixtureGuestImage.uuid.uuid[0] ^= 1;
    RUINInstallSecondaryLogin(); DrainMainQueue();
    assert(!atomic_load(&verifiedLoginGuestImage));
    fixtureGuestImage.uuid.uuid[0] ^= 1;
    fixturePinAllowed = NO;
    RUINInstallSecondaryLogin(); DrainMainQueue();
    assert(!atomic_load(&verifiedLoginGuestImage));
    fixturePinAllowed = YES;

    // LC's queued pin has not succeeded. Model UIKit repeatedly asking the
    // actual hooked getter while LINE creates buttons/traits. Neither strict
    // resolution nor the unpinned guest dyld scan may run for these callers.
    assert(!atomic_load(&verifiedLoginGuestImage));
    fixtureFrameworkCaller = YES;
    uint64_t strictBeforeUIKit = atomic_load(&strictImageResolutions);
    uint64_t dyldBeforeUIKit = atomic_load(&fixtureDyldImageQueries);
    for (NSUInteger query = 0; query < 1000; query++)
        assert(UIDevice.currentDevice.userInterfaceIdiom == physicalIdiom);
    assert(atomic_load(&strictImageResolutions) == strictBeforeUIKit);
    assert(atomic_load(&fixtureDyldImageQueries) == dyldBeforeUIKit);
    fixtureFrameworkCaller = NO;
    puts("PASS unpinned LC getter: 1000 UIKit idiom queries, zero strict/dyld scans, physical idiom retained");

    // The action IMP now belongs to Foundation, while the original class owner
    // remains LINE. Never invoke this temporary replacement; only resolve owner.
    Method action = class_getInstanceMethod(welcomeClass, @selector(loginButtonAction));
    IMP savedAction = method_setImplementation(action,
        class_getMethodImplementation(NSObject.class, @selector(description)));
    for (NSUInteger i = 0; i < 2; i++) {
        fixtureGuestImage.header.filetype = i ? MH_EXECUTE : MH_DYLIB;
        before = fixtureImageProofs;
        RUINInstallSecondaryLogin();
        assert(fixtureImageProofs == before);
        // Startup can cache the idiom before the main queue/pin runs. The live
        // caller gets a temporary verified answer without a loader reference.
        fixtureGuestCaller = YES;
        assert(RUINLoginCallerIsLINE((void *)NativeLogin));
        assert(UIDevice.currentDevice.userInterfaceIdiom ==
            (activeSecondaryMode ? UIUserInterfaceIdiomPad : physicalIdiom));
        assert(!RUINLoginCallerIsLINE((void *)NSClassFromString));
        assert(!atomic_load(&verifiedLoginGuestImage) && !loginGuestImage.loaderReference);
        fixtureGuestImage.uuid.uuid[0] ^= 1;
        assert(!RUINLoginCallerIsLINE((void *)NativeLogin));
        fixtureGuestImage.uuid.uuid[0] ^= 1;
        fixtureForeignOwnerPath = YES;
        assert(!RUINLoginCallerIsLINE((void *)NativeLogin));
        fixtureForeignOwnerPath = NO;
        fixtureForeignCallerPath = YES;
        assert(!RUINLoginCallerIsLINE((void *)NativeLogin));
        fixtureForeignCallerPath = NO;
        assert(fixtureImageProofs == before);
        fixtureGuestCaller = NO;
        DrainMainQueue();
        assert(fixtureImageProofs == before + 1);
        assert(atomic_load(&verifiedLoginGuestImage) == &fixtureGuestImage.header);
        assert(loginGuestImage.convertedExecutable && loginGuestImage.loaderReference);
        fixtureGuestCaller = YES;
        uint64_t resolutions = atomic_load(&strictImageResolutions);
        for (NSUInteger query = 0; query < 1000; query++) {
            assert(RUINLoginCallerIsLINE((void *)NativeLogin));
            assert(!RUINLoginCallerIsLINE((void *)NSClassFromString));
        }
        assert(atomic_load(&strictImageResolutions) == resolutions);
        RUINInstallSecondaryLogin(); DrainMainQueue();
        assert(fixtureImageProofs == before + 1); // One pin, no repeated scans.
        fixtureGuestCaller = NO;
        ResetLoginGuestProof();
    }
    method_setImplementation(action, savedAction);

    // A real native process image keeps the original strict native fallback.
    fixtureNativeImage = YES;
    fixtureGuestImage.header.filetype = MH_EXECUTE;
    fixtureGuestImage.header.flags = MH_PIE;
    RUINInstallSecondaryLogin(); DrainMainQueue();
    assert(!atomic_load(&verifiedLoginGuestImage) && !loginGuestImage.loaderReference);
    uint64_t resolutions = atomic_load(&strictImageResolutions);
    assert(RUINLoginCallerIsLINE((void *)NativeLogin));
    assert(atomic_load(&strictImageResolutions) == resolutions + 1);
    assert(fixtureProofOnMainThread);
    fixtureImageEnabled = fixtureNativeImage = NO;
    assert(!unlink(fixtureLinePath) && !unlink(fixtureProcessPath) && !rmdir(directory));
    puts("PASS login image proof: early live caller, hooked action, converted/retyped guests, UUID/path/lifetime gates, queued retries, native fallback");
}

int main(int argc, const char **argv) { @autoreleasepool {
    CheckVerifiedGuestCallerFastPath();
    BOOL ipad = argc > 1 && strcmp(argv[1], "ipad") == 0;
    BOOL enabled = !ipad && (argc < 2 || strcmp(argv[1], "normal") != 0);
    BOOL mismatch = argc > 1 && strcmp(argv[1], "abi") == 0;
    BOOL returnMismatch = argc > 1 && strcmp(argv[1], "return-abi") == 0;
    BOOL unknown = argc > 1 && strcmp(argv[1], "unknown") == 0;
    BOOL renamed = argc > 1 && strcmp(argv[1], "renamed") == 0;
    if (unknown || renamed) {
        fixtureBundleInfo = @{@"CFBundleIdentifier": renamed ? @"test.sideload.line" : @"jp.naver.line",
            @"RUINOriginalBundleIdentifier": @"jp.naver.line",
            @"CFBundleShortVersionString": unknown ? @"99.0.0" : @"26.17.0",
            @"CFBundleVersion": unknown ? @"2099.0101.1234" : @"2026.1103.1841"};
    }
    if (ipad) physicalIdiom = UIUserInterfaceIdiomPad;
    RUINSecondaryFixtureDefaults *defaults = RUINSecondaryFixtureDefaults.standardUserDefaults;
    defaults.values[@"nativeRole"] = @"primary";
    [defaults setBool:enabled forKey:RUINSecondaryLoginEnabledKey];
    RUINInstallSecondaryLogin(); RUINInstallSecondaryLogin();
    assert(deviceIdiomHookInstalled && !welcomeHookInstalled && !secondaryScreenHookInstalled);
    assert(imageCallbackRegistrations == 1 && registeredImageCallback);
    NSUInteger original = deviceQueries;
    assert(UIDevice.currentDevice.userInterfaceIdiom == (enabled ? UIUserInterfaceIdiomPad : physicalIdiom));
    assert(deviceQueries == original + 1); // LINE-owned startup queries participate before Welcome is visible.

    // Unrelated loads can occur in more than eight separate main-queue turns
    // before the guest/registration image arrives. None may consume its retry.
    for (NSUInteger load = 0; load < 10; load++) {
        registeredImageCallback(NULL, 0);
        DrainMainQueue();
    }
    Class welcomeClass = RegisterController("_TtC18LineRegistrationUI21WelcomeViewController",
        @selector(loginButtonAction), (IMP)NativeLogin, "v16@0:8");

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
    assert(!secondaryScreenHookInstalled);

    // The secondary module may arrive after Welcome has already been hooked.
    Class secondaryClass = RegisterController("_TtC20LineSecondaryLoginUI28SecondaryLoginViewController",
        @selector(showQRCodeLoginButtonPressed), (IMP)NativeQR, "v16@0:8");
    assert(class_addMethod(secondaryClass, @selector(showPrimaryDeviceLoginButtonPressed),
        (IMP)NativePrimaryDeviceLogin, mismatch ? "q16@0:8" : "v16@0:8"));
    assert(class_addMethod(secondaryClass, @selector(showRegistrationFlowButtonPressed),
        (IMP)NativeRegistrationFlow, returnMismatch ? "q16@0:8" : "v16@0:8"));
    registeredImageCallback(NULL, 0);
    DrainMainQueue();
    assert(secondaryScreenHookInstalled == !mismatch);
    assert(secondaryRegistrationReturnHookInstalled == !returnMismatch);
    if (returnMismatch) assert(class_getMethodImplementation(secondaryClass,
        @selector(showRegistrationFlowButtonPressed)) == (IMP)NativeRegistrationFlow);
    if (!mismatch) {
        registeredImageCallback(NULL, 0);
        assert(!atomic_load(&secondaryLoginRetryScheduled));
    }
    assert(imageCallbackRegistrations == 1);
    assert(!applicationAccessedOffMainThread); // The dyld callback never touches UIKit off-main.
    assert(welcome.view.gestureRecognizers.count == 2); // Catch-up attached the already-visible exact Welcome.
    assert(backgroundWelcome.view.gestureRecognizers.count == 0); // Background scenes are excluded.
    RUINInstallSecondaryLogin(); RUINInstallSecondaryLogin(); DrainMainQueue();
    assert(welcome.view.gestureRecognizers.count == 2); // Repeated install/catch-up is idempotent.
    if (!unknown) CheckLoginGuestImageProof(welcomeClass);
    if (!returnMismatch) CheckRegistrationReturn(secondaryClass, enabled);
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

    // A hosting view can answer the native hit query before exposing enumerable
    // AX children. Exercise actual gesture admission and menu presentation with
    // that graph absent, including a nonzero screen origin (iPad/window layout).
    welcome.view.fixtureAccessibilityElements = @[];
    welcome.view.fixtureScreenOrigin = CGPointMake(200, 300);
    button.accessibilityFrame = CGRectMake(210, 320, 120, 50);
    welcome.view.fixtureAccessibilityHit = button;
    assert([press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
    storageReady = keychainReady = NO;
    press.state = UIGestureRecognizerStateBegan;
    [(id<RUINSecondaryFixtureActions>)welcome ruin_chooseLoginMode:press];
    UIAlertController *swiftUIMenu = (id)welcome.presentedViewController;
    assert(swiftUIMenu.actions.count == 3);
    assert(swiftUIMenu.popoverPresentationController.sourceView == welcome.view);
    assert(loginCalls == 0 && storageInstalls == 0 && keychainInstalls == 0);
    storageReady = keychainReady = YES;
    welcome.presentedViewController = nil;
    assert(!RUINPointIsOnNativeLoginButton(welcome, CGPointMake(300, 300)));
    button.accessibilityIdentifier = @"register";
    assert(![press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
    button.accessibilityIdentifier = @"login";
    button.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
    assert(![press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
    button.accessibilityTraits = UIAccessibilityTraitButton;
    button.accessibilityElementsHidden = YES;
    assert(![press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
    button.accessibilityElementsHidden = NO;
    welcome.view.accessibilityElementsHidden = YES;
    assert(![press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
    welcome.view.accessibilityElementsHidden = NO;
    welcome.view.hidden = YES;
    assert(![press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
    welcome.view.hidden = NO;
    welcome.view.alpha = 0;
    assert(![press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
    welcome.view.alpha = 1;
    // Equivalent wrappers in the graph do not override the native hit result.
    UIAccessibilityElement *wrapper = LoginElement(); wrapper.accessibilityFrame = button.accessibilityFrame;
    welcome.view.fixtureAccessibilityElements = @[button, wrapper];
    assert([press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
    // An unidentified container result must preserve the established traversal
    // fallback instead of regressing devices where that graph is available.
    NSObject *unidentifiedHit = [NSObject new]; unidentifiedHit.accessibilityFrame = button.accessibilityFrame;
    welcome.view.fixtureAccessibilityHit = unidentifiedHit;
    welcome.view.fixtureAccessibilityElements = @[button];
    assert([press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
    welcome.view.fixtureAccessibilityHit = nil;
    welcome.view.fixtureAccessibilityElements = @[];
    assert(![press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
    welcome.view.fixtureScreenOrigin = CGPointZero;
    button.accessibilityFrame = CGRectMake(10, 20, 120, 50);
    welcome.view.fixtureAccessibilityElements = @[button];

    // Two visible Welcome controllers must not disable each other's recognizers.
    UIViewController *otherWelcome = [welcomeClass new];
    otherWelcome.view.window = activeWindow;
    otherWelcome.view.fixtureAccessibilityElements = @[LoginElement()];
    [otherWelcome viewDidAppear:NO];
    assert([press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
    [otherWelcome viewDidDisappear:NO];
    assert([press.delegate gestureRecognizer:press shouldReceiveTouch:touch]);
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
    assert(backgroundIdiom == (enabled ? UIUserInterfaceIdiomPad : physicalIdiom));

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
    assert(UIDevice.currentDevice.userInterfaceIdiom == (enabled ? UIUserInterfaceIdiomPad : physicalIdiom));
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
    assert(UIDevice.currentDevice.userInterfaceIdiom == (enabled ? UIUserInterfaceIdiomPad : physicalIdiom));
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
    NSUInteger syncBeforeModeMenu = fixtureSynchronizeCount;
    legacyPress.state = UIGestureRecognizerStateChanged;
    [(id<RUINSecondaryFixtureActions>)legacy ruin_chooseLoginMode:legacyPress];
    assert(!legacy.presentedViewController);
    legacyPress.state = UIGestureRecognizerStateBegan;
    [(id<RUINSecondaryFixtureActions>)legacy ruin_chooseLoginMode:legacyPress];
    UIAlertController *menu = (id)legacy.presentedViewController;
    assert(menu.actions.count == 3 && [menu.actions[0].title isEqual:@"iPad扱いでサブ端末ログイン"]);
    menu.actions[0].handler(menu.actions[0]);
    assert(fixtureSynchronizeCount == syncBeforeModeMenu + 1);
    assert([defaults boolForKey:RUINSecondaryLoginEnabledKey]);
    assert([defaults.values[@"nativeRole"] isEqual:@"primary"] && defaults.values.count == 2);
    DrainMainQueue();
    assert([lastPresentedAlertTitle isEqual:@"ログイン方法を切り替えました"]);
    assert(syncCountAtLastAlertPresentation == fixtureSynchronizeCount); // Persisted before the restart notice.
    assert([defaults.values[@"nativeRole"] isEqual:@"primary"] && defaults.values.count == 2);
    puts("PASS secondary login: late Welcome/secondary hooks, native AX hits without child graph, multi-window gestures, preflight, persisted preference, no native-role writes");
} return 0; }
