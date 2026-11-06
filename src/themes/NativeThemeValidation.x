%config(generator=internal)

#import "ThemePrivateAPI.h"
#import "NativeThemeValidation.h"
#import "NativeThemeRegistration.h"
#import "ThemeShop.h"
#import "../core/TargetMetadata.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>
#include <string.h>

// LINE 26.16.0: ShopService.validateTheme's result continuation logs
// "validateTheme result:" then calls -isValidated at 0x1056453d4.
// Only that caller, with the currently applied registered local package, may
// override the server's result. ZIP CRC/schema checks remain in the importer.
static const uintptr_t kResultReturnPC = 0x1056453d8;
static BOOL gInstalled;
static atomic_uint_fast64_t gCalls, gOverrides;

static BOOL Result(BOOL original, uintptr_t returnPC, BOOL registered)
{
    return original || (returnPC == kResultReturnPC && registered);
}

%group RUINNativeThemeValidation
%hook LineShopProductValidationResult
- (_Bool)isValidated
{
    BOOL original = %orig;
    atomic_fetch_add(&gCalls, 1);
    uintptr_t pc = (uintptr_t)__builtin_return_address(0) - _dyld_get_image_vmaddr_slide(0);
    if (original || pc != kResultReturnPC) return original;
    NSString *productID = [NSUserDefaults.standardUserDefaults stringForKey:@"app.ruin.theme.appliedProductID"];
    BOOL value = Result(original, pc, RUINIsRegisteredNativeThemeID(productID));
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
    if (!RUINTargetMetadataMatchesInfo(info)) return;
    // Check the actual call and the surrounding native continuation before
    // accepting its return address; different code always keeps LINE's result.
    const uint32_t expected[] = {0xaa1303e0, 0x94f800f3, 0xaa0003f4, 0x94f6ad09};
    const void *site = (const void *)(0x1056453d0 + _dyld_get_image_vmaddr_slide(0));
    if (memcmp(site, expected, sizeof(expected))) return;
    Class cls = NSClassFromString(@"LineShopProductValidationResult");
    Method method = cls ? class_getInstanceMethod(cls, @selector(isValidated)) : NULL;
    if (!method || strcmp(method_getTypeEncoding(method), "B16@0:8")) return;
    if (!method_getImplementation(method)) return;
    %init(RUINNativeThemeValidation, LineShopProductValidationResult=cls);
    gInstalled = YES;
}

NSDictionary *RUINNativeThemeValidationDiagnostics(void)
{
#if defined(RUIN_NATIVE_THEME_VALIDATION_HOST_CHECK)
    NSDictionary *persistence = @{@"installed": @NO};
#else
    NSDictionary *persistence = RUINThemePersistenceDiagnostics();
#endif
    return @{@"installed":@(gInstalled), @"calls":@(atomic_load(&gCalls)),
        @"localResultsAccepted":@(atomic_load(&gOverrides)),
        @"secondaryStylesheetPersistence":persistence[@"installed"],
        @"secondaryStylesheetPersistenceAdapter":persistence,
        @"scope":@"native validateTheme result; applied registered local theme only"};
}

#if defined(RUIN_NATIVE_THEME_VALIDATION_HOST_CHECK)
#include <assert.h>
BOOL RUINIsRegisteredNativeThemeID(NSString *productID) { (void)productID; return NO; }
int main(void) { @autoreleasepool {
    assert(Result(NO,kResultReturnPC,YES));
    assert(!Result(NO,kResultReturnPC,NO));
    assert(!Result(NO,kResultReturnPC+4,YES));
    assert(Result(YES,kResultReturnPC+4,NO));
    puts("PASS theme validation caller and registered-package isolation");
} return 0; }
#endif
