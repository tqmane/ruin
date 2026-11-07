%config(generator=internal)

#import "ThemePrivateAPI.h"
#import "NativeThemeValidation.h"
#import "NativeThemeRegistration.h"
#import "ThemeShop.h"
#import "../known/ThemeMappings.h"
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

static BOOL Result(BOOL original, uintptr_t returnPC, BOOL registered,
    const RUINThemeValidationMapping *mapping)
{
    return original || (mapping && mapping->verified && returnPC == mapping->resultReturnPC && registered);
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
    pc -= _dyld_get_image_vmaddr_slide(0);
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
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    const RUINHostIdentity *host = RUINKnownHostForInfo(info);
    const RUINThemeMappings *mapping = RUINThemeMappingsForHost(host);
    if (!mapping || !mapping->validation.verified) return;
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    char logString[sizeof("validateTheme result:")];
    if (!RUINVerifyHostImage(host, header) ||
        !RUINVerifyInstructions(header, slide, mapping->validation.anchors,
            mapping->validation.anchorCount) ||
        !RUINReadImageBytes(header, slide, mapping->validation.resultLogString,
            logString, sizeof(logString), "__TEXT") ||
        memcmp(logString, "validateTheme result:", sizeof(logString))) return;
    Class cls = NSClassFromString(@"LineShopProductValidationResult");
    Method method = cls ? class_getInstanceMethod(cls, @selector(isValidated)) : NULL;
    if (!method || strcmp(method_getTypeEncoding(method), "B16@0:8") ||
        RUINThemeValidationCanonicalIMP(method_getImplementation(method)) !=
            mapping->validation.resultMethodIMP + slide) return;
    gThemeMappings = mapping;
    %init(RUINNativeThemeValidation, LineShopProductValidationResult=cls);
    gInstalled = YES;
}

NSDictionary *RUINNativeThemeValidationDiagnostics(void)
{
    const RUINThemeMappings *mapping = RUINThemeMappingsForHost(
        RUINKnownHostForInfo(NSBundle.mainBundle.infoDictionary));
#if defined(RUIN_NATIVE_THEME_VALIDATION_HOST_CHECK)
    NSDictionary *persistence = @{@"installed": @NO};
#else
    NSDictionary *persistence = RUINThemePersistenceDiagnostics();
#endif
    return @{@"installed":@(gInstalled), @"calls":@(atomic_load(&gCalls)),
        @"localResultsAccepted":@(atomic_load(&gOverrides)),
        @"mappingAvailable":@(mapping && mapping->validation.verified),
        @"secondaryStylesheetPersistence":persistence[@"installed"],
        @"secondaryStylesheetPersistenceAdapter":persistence,
        @"scope":@"native validateTheme result; applied registered local theme only"};
}

#if defined(RUIN_NATIVE_THEME_VALIDATION_HOST_CHECK)
#include <assert.h>
BOOL RUINIsRegisteredNativeThemeID(NSString *productID) { (void)productID; return NO; }
int main(void) { @autoreleasepool {
    const RUINThemeMappings *mapping = RUINThemeMappingsForHost(
        RUINKnownHostForVersion(@"26.16.0", @"2026.1006.1718"));
    assert(mapping && mapping->validation.verified);
    assert(Result(NO, mapping->validation.resultReturnPC, YES, &mapping->validation));
    assert(!Result(NO, mapping->validation.resultReturnPC, NO, &mapping->validation));
    assert(!Result(NO, mapping->validation.resultReturnPC + 4, YES, &mapping->validation));
    assert(Result(YES, mapping->validation.resultReturnPC + 4, NO, &mapping->validation));
    const RUINThemeMappings *newMapping = RUINThemeMappingsForHost(
        RUINKnownHostForVersion(@"26.17.0", @"2026.1103.1841"));
    assert(newMapping && newMapping->validation.verified &&
        !newMapping->shopEligibility.verified && newMapping->localPolicy.verified);
    assert(Result(NO, newMapping->validation.resultReturnPC, YES, &newMapping->validation));
    assert(!Result(NO, newMapping->validation.resultReturnPC + 4, YES, &newMapping->validation));
    puts("PASS theme validation caller and registered-package isolation");
} return 0; }
#endif
