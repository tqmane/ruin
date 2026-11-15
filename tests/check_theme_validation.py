#!/usr/bin/env python3
"""Production apply observer/validator with wrapped IMPs and P_/S_ local packages."""
import json
from pathlib import Path
import subprocess
import tempfile

import check_theme_image as bridge

ROOT = Path(__file__).resolve().parents[1]
THEMES = ROOT / "src/themes"

CLASSES = r'''
static BOOL validationWrongOwner, nativeReply;
static unsigned originalCalls, wrapperCalls, validationHooks, priorEvents;
static uintptr_t validationCaller;
static IMP validationOriginal;
@interface LineShopProductValidationResult : NSObject
- (_Bool)isValidated;
@end
@implementation LineShopProductValidationResult
- (_Bool)isValidated { originalCalls++; return nativeReply; }
@end
@interface ValidationInherited : LineShopProductValidationResult @end
@implementation ValidationInherited @end
@interface ValidationWrongABI : NSObject
- (int)isValidated;
@end
@implementation ValidationWrongABI
- (int)isValidated { return 0; }
@end
static Class validationClass;
static Class FixtureFindClass(NSString *name) {
    assert([name isEqual:@"LineShopProductValidationResult"]); return validationClass;
}
static BOOL (*nativeGetter)(id, SEL);
static BOOL PriorWrapper(id object, SEL selector) {
    wrapperCalls++; return nativeGetter(object, selector);
}
@interface _TtC22LineShopThemeInterface12ThemePackage : NSObject
@property(nonatomic, strong) id defaultField;
@property(nonatomic, strong) id productField;
@end
@implementation _TtC22LineShopThemeInterface12ThemePackage @end
'''

SEAMS = r'''
#import "NativeThemeLocalPolicy.h"
#import "ThemeAccountNamespace.h"
#import "ThemeApplyEvent.h"
#import <os/lock.h>
static os_unfair_lock gCaptureLock = OS_UNFAIR_LOCK_INIT;
static NSString *gNativeAccount;
static id gScopeToken;
static NSURL *groupRoot;
static NSURL *RUINMappedGroupContainerURL(void) { return groupRoot; }
static NSUserDefaults *testDefaults;
@interface ValidationDefaults : NSUserDefaults
+ (instancetype)standardUserDefaults;
@end
@implementation ValidationDefaults
+ (instancetype)standardUserDefaults { return (id)testDefaults; }
@end
static id RUINCopySwiftField(id object, const char *field) {
    _TtC22LineShopThemeInterface12ThemePackage *package = object;
    return !strcmp(field, "productId") ? package.productField : package.defaultField;
}
static void RUINRecordThemePackageInspection(id event, NSString *source) {
    assert(event && [source isEqual:@"didApplyPackage"]);
}
static void RUINThemeFinishPendingReset(uint64_t request, BOOL applied, NSError *error) {
    assert(!request && applied && !error);
}
static BOOL FixtureValidationHook(id self, SEL _cmd);
static void FixtureInstallValidation(Class cls) {
    validationHooks++;
    validationOriginal = method_setImplementation(class_getInstanceMethod(cls, @selector(isValidated)),
        (IMP)FixtureValidationHook);
}
NSDictionary *RUINThemePersistenceDiagnostics(void) {
    return @{@"installed":@(atomic_load(&gThemeShopGateReady))};
}
#define NSUserDefaults ValidationDefaults
#define NSClassFromString FixtureFindClass
'''

CHECK = r'''
#undef NSUserDefaults
#undef NSClassFromString
#undef NSBundle
#undef RUINMappingForInfo
#undef RUINCurrentMapping
#undef RUINResolveMainExecutableImage
#undef RUINResolveFeatureImage
#undef dispatch_async

static void CheckStatus(NSString *expected) {
    NSDictionary *status = RUINNativeThemeValidationDiagnostics();
    assert([status[@"status"] isEqual:expected] && ![status[@"installed"] boolValue]);
    assert(!validationHooks);
}
static void WritePackage(NSString *account, NSString *productID) {
    NSURL *URL = RUINPackageDirectory(groupRoot, account, productID);
    assert(URL && [NSFileManager.defaultManager createDirectoryAtURL:URL
        withIntermediateDirectories:YES attributes:nil error:nil]);
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"manifest":@{
        @"platform":@"iOS", @"revision":@7}} options:0 error:nil];
    assert([json writeToURL:[URL URLByAppendingPathComponent:@"theme.json"] atomically:YES]);
    assert(RUINWriteNativeLocalThemeMarker(URL, @{@"productID":productID, @"rawVersion":@7}, nil));
}
int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2); nativeProcess = !strcmp(argv[1], "native");
    char directory[] = "/tmp/ruin-theme-validation.XXXXXX"; assert(mkdtemp(directory));
    snprintf(linePath, sizeof(linePath), "%s/LINE", directory);
    snprintf(containerPath, sizeof(containerPath), "%s/Container", directory);
    snprintf(aliasPath, sizeof(aliasPath), "%s/current", directory);
    int fd = open(linePath, O_CREAT|O_WRONLY, 0600); assert(fd >= 0); close(fd);
    fd = open(containerPath, O_CREAT|O_WRONLY, 0600); assert(fd >= 0); close(fd);
    assert(!symlink(linePath, aliasPath));
    ownerPath = aliasPath; processPath = nativeProcess ? linePath : containerPath;
    bundleInfo = @{@"CFBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.17.0",
        @"CFBundleVersion":@"2026.1103.1841"};
    ConfigureMapping();
    fixtureVersion.themes.validation.resultMethodIMP = baseAddress + offsetof(TestImage, words[2]);
    fixtureVersion.themes.validation.resultReturnPC = baseAddress + offsetof(TestImage, words[3]);
    MakeImage(&lineImage, !nativeProcess, !strcmp(argv[1], "lc-rewritten"));
    MakeImage(&containerImage, NO, NO); containerImage.uuid.uuid[0]++;
    RUINInstallThemePersistenceAdapter(); Drain();
    assert(atomic_load(&gThemeShopGateReady));
    unsigned retainedPins = pins;
    validationClass = LineShopProductValidationResult.class;
    Method getter = class_getInstanceMethod(validationClass, @selector(isValidated));
    nativeGetter = (BOOL (*)(id, SEL))method_setImplementation(getter, (IMP)PriorWrapper);

    lineImage.uuid.uuid[0]++;
    RUINInstallNativeThemeValidation(); CheckStatus(@"verified_mapping_unavailable");
    lineImage.uuid.uuid[0]--;
    lineImage.words[2]++;
    RUINInstallNativeThemeValidation(); CheckStatus(@"native_site_fingerprint_mismatch");
    lineImage.words[2]--;
    lineImage.validationLog[0]++;
    RUINInstallNativeThemeValidation(); CheckStatus(@"native_site_fingerprint_mismatch");
    lineImage.validationLog[0]--;
    validationClass = ValidationWrongABI.class;
    RUINInstallNativeThemeValidation(); CheckStatus(@"result_method_abi_mismatch");
    validationClass = ValidationInherited.class;
    RUINInstallNativeThemeValidation(); CheckStatus(@"result_method_abi_mismatch");
    validationClass = LineShopProductValidationResult.class;
    validationWrongOwner = YES;
    RUINInstallNativeThemeValidation(); CheckStatus(@"result_class_owner_mismatch");
    validationWrongOwner = NO;
    uintptr_t savedMethod = fixtureVersion.themes.validation.resultMethodIMP;
    fixtureVersion.themes.validation.resultMethodIMP = baseAddress + sizeof(TestImage);
    RUINInstallNativeThemeValidation(); CheckStatus(@"result_class_owner_mismatch");
    fixtureVersion.themes.validation.resultMethodIMP = savedMethod;
    assert(pins == retainedPins);
    RUINInstallNativeThemeValidation();
    assert(gInstalled && validationHooks == 1 && pins == retainedPins);
    NSDictionary *diagnostics = RUINNativeThemeValidationDiagnostics();
    assert([diagnostics[@"status"] isEqual:@"installed"] && [diagnostics[@"chainedExistingHook"] boolValue]);
    RUINInstallNativeThemeValidation(); assert(validationHooks == 1);

    NSString *suite = [@"ruin-theme-validation-" stringByAppendingString:NSUUID.UUID.UUIDString];
    testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    groupRoot = [NSURL fileURLWithPath:@(directory) isDirectory:YES];
    NSString *primary = @"P_uaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    NSString *secondary = @"S_uaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    NSString *product = @"e0768339-c2d3-4189-9653-2909e9bb6f58";
    gNativeAccount = primary; gScopeToken = NSObject.new;
    WritePackage(primary, product);
    LineShopProductValidationResult *result = [LineShopProductValidationResult new];
    validationCaller = fixtureVersion.themes.validation.resultReturnPC + Slide(&lineImage);
    assert(RUINIsRegisteredNativeThemeID(product) && ![result isValidated]); // No success marker yet.
    _TtC22LineShopThemeInterface12ThemePackage *package = [_TtC22LineShopThemeInterface12ThemePackage new];
    package.defaultField = @NO; package.productField = product.uppercaseString;
    FixtureDidApply(package);
    assert(priorEvents == 1 && [[testDefaults stringForKey:RUINThemeAppliedThemeIDDefaultsKey]
        isEqual:product.uppercaseString] && [result isValidated]);
    validationCaller += 4; assert(![result isValidated]); validationCaller -= 4;
    gNativeAccount = secondary; gScopeToken = NSObject.new;
    assert(!RUINIsRegisteredNativeThemeID(product) && ![result isValidated]);
    WritePackage(secondary, product);
    assert(RUINIsRegisteredNativeThemeID(product) && [result isValidated]);
    gNativeAccount = primary; gScopeToken = NSObject.new;
    assert([result isValidated]);
    package.defaultField = @YES; FixtureDidApply(package);
    assert(![testDefaults objectForKey:RUINThemeAppliedThemeIDDefaultsKey] && ![result isValidated]);
    nativeReply = YES; validationCaller += 4; assert([result isValidated]);
    assert(originalCalls && originalCalls == wrapperCalls);
    [testDefaults removePersistentDomainForName:suite];
    RUINReleaseFeatureImage(&gThemeShopImage); assert(!pins);
    assert([NSFileManager.defaultManager removeItemAtURL:groupRoot error:nil]);
    printf("PASS wrapped validation, anchors, success marker and P_/S_ account isolation: %s\n", argv[1]);
} return 0; }
'''


def main():
    shop = (THEMES / "ThemeShop.x").read_text()
    validation = (THEMES / "NativeThemeValidation.x").read_text()
    features = (THEMES / "ThemeFeatures.x").read_text()
    registration = (THEMES / "NativeThemeRegistration.x").read_text()
    extract = bridge.extract
    preamble = bridge.PREAMBLE.replace("typedef struct {", CLASSES + "\ntypedef struct {", 1)
    preamble = preamble.replace(
        "return !missingOwner && cls == _TtC4LINE11AppDelegate.class ? ownerPath : NULL;",
        'if (cls == LineShopProductValidationResult.class) return validationWrongOwner ? containerPath : ownerPath;\n'
        '    return !missingOwner && cls == _TtC4LINE11AppDelegate.class ? ownerPath : NULL;')
    declarations = "\n".join(line for line in shop.splitlines() if line.startswith((
        "static NSString * const RUINThemeShopURLString =", "static const char * const RUINThemeShopDelegateClass =",
        "static const RUINThemeMappings *gThemeShopMappings;", "static atomic_bool gThemeShopGateReady;",
        "static atomic_int gThemeShopGateStatus;", "static intptr_t gThemeShopSlide;",
        "static RUINFeatureImage gThemeShopImage;", "static const RUINVersionMapping *gThemeShopImageVersion;",
        "static atomic_bool gThemeShopImageReady;"))) + "\n"
    mapping = extract(shop, "static const RUINThemeMappings *RUINThemeShopMappingForInfo(",
        "#if !defined(RUIN_THEMESHOP_HOST_CHECK)\nstatic void RUINThemeShopInstallGate(")
    gate = extract(shop, "#if !defined(RUIN_THEMESHOP_HOST_CHECK)\nstatic void RUINThemeShopInstallGate(",
        "#if !defined(RUIN_THEMESHOP_HOST_CHECK)\nstatic NSNumber *gThemeShopUnscopedPrimaryBefore;")
    gate = gate.replace("%init(RUINThemeDefaults, RUINThemeDefaultsStore=cls);", "FixtureInstallDefaults(cls);")
    image_bridge = extract(shop, "#if !defined(RUIN_THEMESHOP_HOST_CHECK)\nstatic void RUINInstallThemePersistenceOnMain(",
        "NSDictionary *RUINThemePersistenceDiagnostics(")
    globals_ = extract(validation, "// Only the mapped", "%group RUINNativeThemeValidation")
    hook = extract(validation, "- (_Bool)isValidated\n", "\n%end")
    hook = hook.replace("- (_Bool)isValidated", "static BOOL FixtureValidationHook(id self, SEL _cmd)")
    hook = hook.replace("%orig", "((BOOL (*)(id, SEL))validationOriginal)(self, _cmd)")
    hook = hook.replace("__builtin_return_address(0)", "(void *)validationCaller")
    installer = extract(validation, "void RUINInstallNativeThemeValidation(void)",
        "#if defined(RUIN_NATIVE_THEME_VALIDATION_HOST_CHECK)\n#include <assert.h>")
    installer = installer.replace("%init(RUINNativeThemeValidation, LineShopProductValidationResult=cls);",
        "FixtureInstallValidation(cls);")
    observer_globals = extract(features, "typedef enum {", "static atomic_int gThemePriceTierStatus")
    observer_globals += "\n".join(line for line in features.splitlines() if line.startswith((
        "NSString * const RUINThemeAppliedThemeIDDefaultsKey =", "static atomic_int gThemeApplyMarkerStatus =",
        "static atomic_uint_fast64_t gThemeApplyEvents ="))) + "\n"
    observer = extract(features, "- (void)didApplyPackage:(id)event", "\n%end")
    observer = observer.replace("- (void)didApplyPackage:(id)event", "static void FixtureDidApply(id event)")
    observer = observer.replace("%orig;", "priorEvents++;")
    account_read = extract(registration, "id RUINNativeThemeRegistrationScopeToken(void)",
        "static NSURL *RUINNativeApplicationSupportURL(void)")
    account_read += extract(registration, "static NSURL *RUINPackageDirectory(NSURL *container, NSString *account, NSString *productID)\n{",
        "static BOOL RUINPackageURLMatchesSnapshot(")
    make_images = "\n#undef RUINMappingForInfo\n" + extract(bridge.CHECK,
        "static void MakeImage(", "static void CheckBorrowedImage(") + "\n#define RUINMappingForInfo FixtureMapping\n"
    with tempfile.TemporaryDirectory(prefix="ruin-theme-validation-") as temporary:
        fixture = Path(temporary) / "check.m"
        fixture.write_text(preamble + f'\n#include {json.dumps(str(ROOT / "src/known/FeatureImage.m"))}\n' +
            bridge.BRIDGE_SEAMS + declarations + mapping + gate + image_bridge + make_images + SEAMS +
            account_read + observer_globals + observer + globals_ + hook + installer + CHECK)
        executable = Path(temporary) / "check"
        sources = [ROOT / "src/known" / name for name in ("BinaryVerifier.m", "KnownMappings.m", "ThemeMappings.m")]
        sources += sorted((ROOT / "src/known/versions").glob("*.m"))
        sources += [THEMES / name for name in ("ThemeApplyEvent.m", "NativeThemeLocalPolicy.m", "NativeThemeReceipt.m")]
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11",
            "-Wall", "-Wextra", "-Werror", "-Wno-incompatible-pointer-types", "-I", str(ROOT / "src/known"),
            "-I", str(THEMES), str(fixture), *map(str, sources), "-framework", "Foundation",
            "-framework", "CoreData", "-o", str(executable)], check=True, timeout=30)
        subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True)
        for scenario in ("native", "lc-dylib", "lc-rewritten"):
            subprocess.run([str(executable), scenario], check=True, timeout=15)


if __name__ == "__main__":
    main()
