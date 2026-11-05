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
static _Atomic(IMP) gOriginalType = ATOMIC_VAR_INIT(NULL);
static _Atomic(IMP) gOriginalOwned = ATOMIC_VAR_INIT(NULL);
static _Atomic(IMP) gOriginalAvailable = ATOMIC_VAR_INIT(NULL);
static _Atomic(IMP) gOriginalPrice = ATOMIC_VAR_INIT(NULL);
static _Atomic(IMP) gOriginalButtonLabel = ATOMIC_VAR_INIT(NULL);
static _Atomic(IMP) gOriginalRead = ATOMIC_VAR_INIT(NULL);
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
    IMP original = atomic_load_explicit(&gOriginalType, memory_order_acquire);
    if (!original) return NO;
    id type = ((id (*)(id, SEL))original)(object, sel_registerName("type"));
    return [type isKindOfClass:NSString.class] &&
        [(NSString *)type caseInsensitiveCompare:@"theme"] == NSOrderedSame;
}

static BOOL RUINThemeStoreDownloadShouldProject(id object)
{
    return atomic_load_explicit(&gStatus, memory_order_acquire) == RUINThemeStoreDownloadInstalled &&
        RUINThemeStoreDownloadEnabled() && RUINThemeStoreDownloadIsTheme(object);
}

static _Bool RUINThemeStoreDownloadOwned(id self, SEL selector)
{
    atomic_fetch_add_explicit(&gOwnedCalls, 1, memory_order_relaxed);
    IMP original = atomic_load_explicit(&gOriginalOwned, memory_order_acquire);
    _Bool value = original ? ((_Bool (*)(id, SEL))original)(self, selector) : NO;
    if (!RUINThemeStoreDownloadShouldProject(self)) return value;
    atomic_fetch_add_explicit(&gOwnedProjections, 1, memory_order_relaxed);
    return YES;
}

static _Bool RUINThemeStoreDownloadAvailable(id self, SEL selector)
{
    atomic_fetch_add_explicit(&gAvailableCalls, 1, memory_order_relaxed);
    IMP original = atomic_load_explicit(&gOriginalAvailable, memory_order_acquire);
    _Bool value = original ? ((_Bool (*)(id, SEL))original)(self, selector) : NO;
    if (!RUINThemeStoreDownloadShouldProject(self)) return value;
    atomic_fetch_add_explicit(&gAvailableProjections, 1, memory_order_relaxed);
    return YES;
}

static id RUINThemeStoreDownloadPrice(id self, SEL selector)
{
    atomic_fetch_add_explicit(&gPriceCalls, 1, memory_order_relaxed);
    IMP original = atomic_load_explicit(&gOriginalPrice, memory_order_acquire);
    id value = original ? ((id (*)(id, SEL))original)(self, selector) : nil;
    if (!RUINThemeStoreDownloadShouldProject(self)) return value;
    atomic_fetch_add_explicit(&gPriceProjections, 1, memory_order_relaxed);
    return @"0";
}

static id RUINThemeStoreDownloadButtonLabel(id self, SEL selector)
{
    atomic_fetch_add_explicit(&gButtonLabelCalls, 1, memory_order_relaxed);
    IMP original = atomic_load_explicit(&gOriginalButtonLabel, memory_order_acquire);
    id value = original ? ((id (*)(id, SEL))original)(self, selector) : nil;
    if (!RUINThemeStoreDownloadShouldProject(self)) return value;
    atomic_fetch_add_explicit(&gButtonLabelProjections, 1, memory_order_relaxed);
    return nil;
}

static void RUINThemeStoreDownloadRead(id self, SEL selector, id reader)
{
    atomic_fetch_add_explicit(&gReadCalls, 1, memory_order_relaxed);
    IMP original = atomic_load_explicit(&gOriginalRead, memory_order_acquire);
    if (!original) return;
    ((void (*)(id, SEL, id))original)(self, selector, reader);
    if (RUINThemeStoreDownloadIsTheme(self))
        atomic_fetch_add_explicit(&gPostReadThemeObservations, 1, memory_order_relaxed);
}

typedef struct {
    SEL selector;
    const char *encoding;
    Method method;
    IMP original;
    IMP replacement;
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
        { sel_registerName("type"), "@16@0:8", NULL, NULL, NULL },
        { sel_registerName("isOwned"), "B16@0:8", NULL, NULL, (IMP)RUINThemeStoreDownloadOwned },
        { sel_registerName("isAvailableForMyself"), "B16@0:8", NULL, NULL, (IMP)RUINThemeStoreDownloadAvailable },
        { sel_registerName("priceInLineCoin"), "@16@0:8", NULL, NULL, (IMP)RUINThemeStoreDownloadPrice },
        { sel_registerName("customDownloadButtonLabel"), "@16@0:8", NULL, NULL, (IMP)RUINThemeStoreDownloadButtonLabel },
        { sel_registerName("read:"), "v24@0:8@16", NULL, NULL, (IMP)RUINThemeStoreDownloadRead }
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

    atomic_store_explicit(&gOriginalType, methods[0].original, memory_order_release);
    atomic_store_explicit(&gOriginalOwned, methods[1].original, memory_order_release);
    atomic_store_explicit(&gOriginalAvailable, methods[2].original, memory_order_release);
    atomic_store_explicit(&gOriginalPrice, methods[3].original, memory_order_release);
    atomic_store_explicit(&gOriginalButtonLabel, methods[4].original, memory_order_release);
    atomic_store_explicit(&gOriginalRead, methods[5].original, memory_order_release);

    for (size_t index = 1; index < methodCount; index++) {
        IMP previous = method_setImplementation(methods[index].method, methods[index].replacement);
        if (previous == methods[index].original) continue;
        if (previous) method_setImplementation(methods[index].method, previous);
        for (size_t rollback = index + 1; rollback-- > 1;) {
            if (method_getImplementation(methods[rollback].method) == methods[rollback].replacement)
                method_setImplementation(methods[rollback].method, methods[rollback].original);
        }
        atomic_store_explicit(&gStatus, RUINThemeStoreDownloadInstallFailed, memory_order_release);
        return;
    }
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
