%config(generator=internal)

#import "ThemePrivateAPI.h"
#import "NativeThemeValidation.h"
#import "NativeThemeRegistration.h"
#import "ThemeShop.h"
#import "../known/ThemeMappings.h"
#import "../known/VersionMapping.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif
#include <string.h>

// Only the mapped native result continuation, with the currently applied
// registered local package, may override the server's result.
static BOOL gInstalled;
static atomic_uint_fast64_t gCalls, gOverrides;
static const RUINThemeMappings *gThemeMappings;
static intptr_t gThemeImageSlide;

static BOOL Result(BOOL original, uintptr_t returnPC, BOOL registered,
    const RUINThemeValidationMapping *mapping)
{
    return original || (mapping && mapping->status == RUINMappingStatusVerified &&
        returnPC == mapping->resultReturnPC && registered);
}

static uintptr_t RUINThemeValidationCanonicalIMP(IMP implementation)
{
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)implementation, ptrauth_key_function_pointer);
#else
    return (uintptr_t)implementation;
#endif
}

%group RUINNativeThemeValidation
%hook LineShopProductValidationResult
- (_Bool)isValidated
{
    BOOL original = %orig;
    atomic_fetch_add(&gCalls, 1);
    uintptr_t pc = (uintptr_t)__builtin_return_address(0);
#if __has_feature(ptrauth_calls)
    pc = (uintptr_t)ptrauth_strip((void *)pc, ptrauth_key_return_address);
#endif
    pc -= gThemeImageSlide;
    if (original || !gThemeMappings || pc != gThemeMappings->validation.resultReturnPC) return original;
    NSString *productID = [NSUserDefaults.standardUserDefaults stringForKey:@"app.ruin.theme.appliedProductID"];
    BOOL value = Result(original, pc, RUINIsRegisteredNativeThemeID(productID),
        &gThemeMappings->validation);
    if (value) atomic_fetch_add(&gOverrides, 1);
    return value;
}
%end
%end

void RUINInstallNativeThemeValidation(void)
{
#if !defined(RUIN_NATIVE_THEME_VALIDATION_HOST_CHECK)
    RUINInstallThemePersistenceAdapter();
#endif
    if (gInstalled) return;
#if defined(RUIN_NATIVE_THEME_VALIDATION_HOST_CHECK)
    const RUINVersionMapping *versionMapping = RUINMappingForInfo(NSBundle.mainBundle.infoDictionary);
#else
    RUINFeatureImage themeImage;
    const RUINVersionMapping *versionMapping = RUINCopyVerifiedThemeImage(&themeImage);
#endif
    const RUINThemeMappings *mapping = versionMapping ? &versionMapping->themes : NULL;
    if (!mapping || mapping->validation.status != RUINMappingStatusVerified) return;
    char logString[sizeof("validateTheme result:")];
#if defined(RUIN_NATIVE_THEME_VALIDATION_HOST_CHECK)
    RUINMainExecutableImage image;
    if (!RUINResolveMainExecutableImage(&image)) return;
    intptr_t slide = image.slide;
    BOOL verified = RUINVerifyInstructions(image.header, slide, mapping->validation.anchors,
        mapping->validation.anchorCount) && RUINReadImageBytes(image.header, slide,
        mapping->validation.resultLogString, logString, sizeof(logString), "__TEXT");
#else
    intptr_t slide = themeImage.image.slide;
    BOOL verified = RUINVerifyFeatureInstructions(&themeImage, mapping->validation.anchors,
        mapping->validation.anchorCount) && RUINReadFeatureImageBytes(&themeImage,
        mapping->validation.resultLogString, logString, sizeof(logString), "__TEXT");
#endif
    if (!verified || memcmp(logString, "validateTheme result:", sizeof(logString))) return;
    Class cls = NSClassFromString(@"LineShopProductValidationResult");
    Method method = cls ? class_getInstanceMethod(cls, @selector(isValidated)) : NULL;
    if (!method || strcmp(method_getTypeEncoding(method), "B16@0:8") ||
        RUINThemeValidationCanonicalIMP(method_getImplementation(method)) !=
            mapping->validation.resultMethodIMP + slide) return;
    gThemeMappings = mapping;
    gThemeImageSlide = slide;
    %init(RUINNativeThemeValidation, LineShopProductValidationResult=cls);
    gInstalled = YES;
}

NSDictionary *RUINNativeThemeValidationDiagnostics(void)
{
#if defined(RUIN_NATIVE_THEME_VALIDATION_HOST_CHECK)
    const RUINVersionMapping *versionMapping = RUINMappingForInfo(NSBundle.mainBundle.infoDictionary);
    NSDictionary *persistence = @{@"installed": @NO};
#else
    RUINFeatureImage themeImage;
    const RUINVersionMapping *versionMapping = RUINCopyVerifiedThemeImage(&themeImage);
    NSDictionary *persistence = RUINThemePersistenceDiagnostics();
#endif
    const RUINThemeMappings *mapping = versionMapping ? &versionMapping->themes : NULL;
    return @{@"installed":@(gInstalled), @"calls":@(atomic_load(&gCalls)),
        @"localResultsAccepted":@(atomic_load(&gOverrides)),
        @"mappingAvailable":@(mapping && mapping->validation.status == RUINMappingStatusVerified),
        @"secondaryStylesheetPersistence":persistence[@"installed"],
        @"secondaryStylesheetPersistenceAdapter":persistence,
        @"scope":@"native validateTheme result; applied registered local theme only"};
}

#if defined(RUIN_NATIVE_THEME_VALIDATION_HOST_CHECK)
#include <assert.h>
BOOL RUINIsRegisteredNativeThemeID(NSString *productID) { (void)productID; return NO; }
int main(void) { @autoreleasepool {
    const RUINVersionMapping *version16 = RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"});
    const RUINThemeMappings *mapping = version16 ? &version16->themes : NULL;
    assert(mapping && mapping->validation.status == RUINMappingStatusVerified);
    assert(Result(NO, mapping->validation.resultReturnPC, YES, &mapping->validation));
    assert(!Result(NO, mapping->validation.resultReturnPC, NO, &mapping->validation));
    assert(!Result(NO, mapping->validation.resultReturnPC + 4, YES, &mapping->validation));
    assert(Result(YES, mapping->validation.resultReturnPC + 4, NO, &mapping->validation));
    const RUINVersionMapping *version17 = RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"});
    const RUINThemeMappings *newMapping = version17 ? &version17->themes : NULL;
    assert(newMapping && newMapping->validation.status == RUINMappingStatusVerified &&
        newMapping->shopEligibility.status == RUINMappingStatusUnsupported &&
        newMapping->localPolicy.status == RUINMappingStatusVerified);
    assert(Result(NO, newMapping->validation.resultReturnPC, YES, &newMapping->validation));
    assert(!Result(NO, newMapping->validation.resultReturnPC + 4, YES, &newMapping->validation));
    puts("PASS theme validation caller and registered-package isolation");
} return 0; }
#endif
