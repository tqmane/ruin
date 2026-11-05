%config(generator=internal)

#import "ThemePrivateAPI.h"
#import "ThemeStoreDownload.h"
#import "ThemeFeatures.h"

#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

typedef enum {
    RUINThemeStoreDownloadPending,
    RUINThemeStoreDownloadInstalling,
    RUINThemeStoreDownloadVersionGated,
    RUINThemeStoreDownloadMissingClass,
    RUINThemeStoreDownloadMissingSelector,
    RUINThemeStoreDownloadEncodingMismatch,
    RUINThemeStoreDownloadInstallFailed,
    RUINThemeStoreDownloadInstalled
} RUINThemeStoreDownloadStatus;

static atomic_int gStatus = ATOMIC_VAR_INIT(RUINThemeStoreDownloadPending);
static atomic_uint_fast64_t gOwnedCalls = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gAvailableCalls = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gPriceCalls = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gButtonLabelCalls = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gReadCalls = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gOwnedProjections = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gAvailableProjections = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gPriceProjections = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gButtonLabelProjections = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gPostReadThemeObservations = ATOMIC_VAR_INIT(0);

#if defined(RUIN_THEME_STORE_DOWNLOAD_HOST_CHECK)
static atomic_bool gTestEnabled = ATOMIC_VAR_INIT(false);
void RUINThemeStoreDownloadSetTestEnabled(BOOL enabled)
{
    atomic_store_explicit(&gTestEnabled, enabled, memory_order_release);
}
#endif

static BOOL RUINThemeStoreDownloadTargetMatches(void)
{
#if defined(RUIN_THEME_STORE_DOWNLOAD_HOST_CHECK)
    return YES;
#else
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    BOOL bundleMatches = [bundleID isEqualToString:@"jp.naver.line"] ||
        [info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"];
    return bundleMatches &&
        [info[@"CFBundleShortVersionString"] isEqual:@"26.16.0"] &&
        [info[@"CFBundleVersion"] isEqual:@"2026.1006.1718"];
#endif
}

static BOOL RUINThemeStoreDownloadEnabled(void)
{
#if defined(RUIN_THEME_STORE_DOWNLOAD_HOST_CHECK)
    return atomic_load_explicit(&gTestEnabled, memory_order_acquire);
#else
    return [NSUserDefaults.standardUserDefaults boolForKey:RUINThemeShopDownloadEnabledDefaultsKey];
#endif
}

static BOOL RUINThemeStoreDownloadIsTheme(id object)
{
    id type = [(LineShopProductDetail *)object type];
    return [type isKindOfClass:NSString.class] &&
        [(NSString *)type caseInsensitiveCompare:@"theme"] == NSOrderedSame;
}

static BOOL RUINThemeStoreDownloadShouldProject(id object)
{
    return atomic_load_explicit(&gStatus, memory_order_acquire) == RUINThemeStoreDownloadInstalled &&
        RUINThemeStoreDownloadEnabled() && RUINThemeStoreDownloadIsTheme(object);
}

%group RUINThemeStoreDownload
%hook LineShopProductDetail
- (_Bool)isOwned
{
    atomic_fetch_add_explicit(&gOwnedCalls, 1, memory_order_relaxed);
    _Bool value = %orig;
    if (!RUINThemeStoreDownloadShouldProject(self)) return value;
    atomic_fetch_add_explicit(&gOwnedProjections, 1, memory_order_relaxed);
    return YES;
}

- (_Bool)isAvailableForMyself
{
    atomic_fetch_add_explicit(&gAvailableCalls, 1, memory_order_relaxed);
    _Bool value = %orig;
    if (!RUINThemeStoreDownloadShouldProject(self)) return value;
    atomic_fetch_add_explicit(&gAvailableProjections, 1, memory_order_relaxed);
    return YES;
}

- (id)priceInLineCoin
{
    atomic_fetch_add_explicit(&gPriceCalls, 1, memory_order_relaxed);
    id value = %orig;
    if (!RUINThemeStoreDownloadShouldProject(self)) return value;
    atomic_fetch_add_explicit(&gPriceProjections, 1, memory_order_relaxed);
    return @"0";
}

- (id)customDownloadButtonLabel
{
    atomic_fetch_add_explicit(&gButtonLabelCalls, 1, memory_order_relaxed);
    id value = %orig;
    if (!RUINThemeStoreDownloadShouldProject(self)) return value;
    atomic_fetch_add_explicit(&gButtonLabelProjections, 1, memory_order_relaxed);
    return nil;
}

- (void)read:(id)reader
{
    atomic_fetch_add_explicit(&gReadCalls, 1, memory_order_relaxed);
    %orig;
    if (RUINThemeStoreDownloadIsTheme(self))
        atomic_fetch_add_explicit(&gPostReadThemeObservations, 1, memory_order_relaxed);
}
%end
%end

typedef struct {
    SEL selector;
    const char *encoding;
    Method method;
    IMP original;
} RUINThemeStoreDownloadMethod;

static Method RUINThemeStoreDownloadOwnMethod(Class cls, SEL selector)
{
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            found = methods[index];
            break;
        }
    }
    free(methods);
    return found;
}

static const char *RUINThemeStoreDownloadStatusName(int status)
{
    switch (status) {
        case RUINThemeStoreDownloadInstalling: return "installing";
        case RUINThemeStoreDownloadVersionGated: return "version_gated";
        case RUINThemeStoreDownloadMissingClass: return "missing_class";
        case RUINThemeStoreDownloadMissingSelector: return "missing_selector";
        case RUINThemeStoreDownloadEncodingMismatch: return "encoding_mismatch";
        case RUINThemeStoreDownloadInstallFailed: return "install_failed";
        case RUINThemeStoreDownloadInstalled: return "installed";
        default: return "pending";
    }
}

void RUINInstallThemeStoreDownload(void)
{
    int expected = RUINThemeStoreDownloadPending;
    if (!atomic_compare_exchange_strong_explicit(&gStatus, &expected,
            RUINThemeStoreDownloadInstalling, memory_order_acq_rel, memory_order_acquire)) return;

    if (!RUINThemeStoreDownloadTargetMatches()) {
        atomic_store_explicit(&gStatus, RUINThemeStoreDownloadVersionGated, memory_order_release);
        return;
    }
    Class cls = objc_lookUpClass("LineShopProductDetail");
    if (!cls) {
        atomic_store_explicit(&gStatus, RUINThemeStoreDownloadMissingClass, memory_order_release);
        return;
    }

    RUINThemeStoreDownloadMethod methods[] = {
        { sel_registerName("type"), "@16@0:8", NULL, NULL },
        { sel_registerName("isOwned"), "B16@0:8", NULL, NULL },
        { sel_registerName("isAvailableForMyself"), "B16@0:8", NULL, NULL },
        { sel_registerName("priceInLineCoin"), "@16@0:8", NULL, NULL },
        { sel_registerName("customDownloadButtonLabel"), "@16@0:8", NULL, NULL },
        { sel_registerName("read:"), "v24@0:8@16", NULL, NULL }
    };
    const size_t methodCount = sizeof(methods) / sizeof(methods[0]);
    for (size_t index = 0; index < methodCount; index++) {
        methods[index].method = RUINThemeStoreDownloadOwnMethod(cls, methods[index].selector);
        if (!methods[index].method) {
            atomic_store_explicit(&gStatus, RUINThemeStoreDownloadMissingSelector, memory_order_release);
            return;
        }
        const char *actual = method_getTypeEncoding(methods[index].method);
        if (!actual || strcmp(actual, methods[index].encoding) != 0) {
            atomic_store_explicit(&gStatus, RUINThemeStoreDownloadEncodingMismatch, memory_order_release);
            return;
        }
        methods[index].original = method_getImplementation(methods[index].method);
        if (!methods[index].original) {
            atomic_store_explicit(&gStatus, RUINThemeStoreDownloadInstallFailed, memory_order_release);
            return;
        }
    }

    %init(RUINThemeStoreDownload, LineShopProductDetail=cls);
    atomic_store_explicit(&gStatus, RUINThemeStoreDownloadInstalled, memory_order_release);
}

NSDictionary<NSString *, id> *RUINThemeStoreDownloadDiagnostics(void)
{
    int status = atomic_load_explicit(&gStatus, memory_order_acquire);
    return @{
        @"targetVersionMatches": @(RUINThemeStoreDownloadTargetMatches()),
        @"enabled": @(RUINThemeStoreDownloadEnabled()),
        @"hookStatus": [NSString stringWithUTF8String:RUINThemeStoreDownloadStatusName(status)],
        @"calls": @{
            @"isOwned": @(atomic_load_explicit(&gOwnedCalls, memory_order_relaxed)),
            @"isAvailableForMyself": @(atomic_load_explicit(&gAvailableCalls, memory_order_relaxed)),
            @"priceInLineCoin": @(atomic_load_explicit(&gPriceCalls, memory_order_relaxed)),
            @"customDownloadButtonLabel": @(atomic_load_explicit(&gButtonLabelCalls, memory_order_relaxed)),
            @"read": @(atomic_load_explicit(&gReadCalls, memory_order_relaxed))
        },
        @"projections": @{
            @"isOwned": @(atomic_load_explicit(&gOwnedProjections, memory_order_relaxed)),
            @"isAvailableForMyself": @(atomic_load_explicit(&gAvailableProjections, memory_order_relaxed)),
            @"priceInLineCoin": @(atomic_load_explicit(&gPriceProjections, memory_order_relaxed)),
            @"customDownloadButtonLabel": @(atomic_load_explicit(&gButtonLabelProjections, memory_order_relaxed))
        },
        @"postReadThemeObservations": @(atomic_load_explicit(&gPostReadThemeObservations, memory_order_relaxed)),
        @"purchaseOrOrderCalls": @0,
        @"downloadSuccessClaimed": @NO
    };
}
