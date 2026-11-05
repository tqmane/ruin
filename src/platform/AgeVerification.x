%config(generator=internal);

#import "AgeVerification.h"

#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

#import "Features.h"

NSString * const RUINBypassAgeVerificationDefaultsKey = @"RUINBypassAgeVerificationEnabled";

typedef enum {
    RUINAgeHookPending,
    RUINAgeHookVersionGated,
    RUINAgeHookMissingClass,
    RUINAgeHookMissingSelector,
    RUINAgeHookEncodingMismatch,
    RUINAgeHookInstallFailed,
    RUINAgeHookInstalled
} RUINAgeHookStatus;

typedef struct {
    const char *selectorName;
    const char *encoding;
    _Atomic(IMP) original;
    atomic_uint_fast64_t calls;
    atomic_int status;
} RUINAgeHook;

static BOOL RUINAgeVerificationIsNecessary(id self, SEL selector);
static NSInteger RUINUserAgeType(id self, SEL selector);

#define RUIN_AGE_HOOK(selector, types) \
    { selector, types, ATOMIC_VAR_INIT(NULL), ATOMIC_VAR_INIT(0), ATOMIC_VAR_INIT(RUINAgeHookPending) }

// Current LINE exposes the local guard pair on NLAgeVerificationManager's metaclass.
static RUINAgeHook gAgeNecessaryHook = RUIN_AGE_HOOK("ageVerificationIsNecessary", "B16@0:8");
static RUINAgeHook gUserAgeTypeHook = RUIN_AGE_HOOK("userAgeType", "q16@0:8");
static os_unfair_lock gAgeInstallLock = OS_UNFAIR_LOCK_INIT;

#undef RUIN_AGE_HOOK

static BOOL RUINTargetMatches(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    return [info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier] &&
        [info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] &&
        [info[@"CFBundleVersion"] isEqual:RUINTargetBuild];
}

%group RUINAgeNecessary
%hook RUINAgeNecessaryTarget
+ (BOOL)ageVerificationIsNecessary
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&gAgeNecessaryHook.original, original, memory_order_release);
    return RUINAgeVerificationIsNecessary(self, _cmd);
}
%end
%end

%group RUINAgeType
%hook RUINAgeTypeTarget
+ (NSInteger)userAgeType
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&gUserAgeTypeHook.original, original, memory_order_release);
    return RUINUserAgeType(self, _cmd);
}
%end
%end

static void RUINInstallAgeHook(Class target, RUINAgeHook *hook)
{
    Class metaclass = target ? object_getClass((id)target) : Nil;
    if (atomic_load(&hook->status) == RUINAgeHookInstalled) return;
    if (!metaclass) { atomic_store(&hook->status, RUINAgeHookMissingClass); return; }
    SEL selector = sel_registerName(hook->selectorName);
    Method method = class_getInstanceMethod(metaclass, selector);
    if (!method) { atomic_store(&hook->status, RUINAgeHookMissingSelector); return; }
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || strcmp(encoding, hook->encoding) != 0) {
        atomic_store(&hook->status, RUINAgeHookEncodingMismatch);
        return;
    }
    IMP original = method_getImplementation(method);
    if (!original) { atomic_store(&hook->status, RUINAgeHookInstallFailed); return; }

    atomic_store_explicit(&hook->original, original, memory_order_release);
    if (hook == &gAgeNecessaryHook) {
        %init(RUINAgeNecessary, RUINAgeNecessaryTarget = target);
    } else if (hook == &gUserAgeTypeHook) {
        %init(RUINAgeType, RUINAgeTypeTarget = target);
    } else {
        atomic_store(&hook->status, RUINAgeHookInstallFailed);
        return;
    }
    atomic_store(&hook->status, RUINAgeHookInstalled);
}

void RUINInstallAgeVerification(void)
{
    os_unfair_lock_lock(&gAgeInstallLock);
    if (!RUINTargetMatches()) {
        atomic_store(&gAgeNecessaryHook.status, RUINAgeHookVersionGated);
        atomic_store(&gUserAgeTypeHook.status, RUINAgeHookVersionGated);
        os_unfair_lock_unlock(&gAgeInstallLock);
        return;
    }
    Class target = objc_getClass("NLAgeVerificationManager");
    RUINInstallAgeHook(target, &gAgeNecessaryHook);
    RUINInstallAgeHook(target, &gUserAgeTypeHook);
    os_unfair_lock_unlock(&gAgeInstallLock);
}

static BOOL RUINAgeVerificationIsNecessary(id self, SEL selector)
{
    atomic_fetch_add_explicit(&gAgeNecessaryHook.calls, 1, memory_order_relaxed);
    if ([NSUserDefaults.standardUserDefaults boolForKey:RUINBypassAgeVerificationDefaultsKey]) return NO;
    IMP original = atomic_load_explicit(&gAgeNecessaryHook.original, memory_order_acquire);
    return original ? ((BOOL (*)(id, SEL))original)(self, selector) : NO;
}

static NSInteger RUINUserAgeType(id self, SEL selector)
{
    atomic_fetch_add_explicit(&gUserAgeTypeHook.calls, 1, memory_order_relaxed);
    if ([NSUserDefaults.standardUserDefaults boolForKey:RUINBypassAgeVerificationDefaultsKey]) return 1;
    IMP original = atomic_load_explicit(&gUserAgeTypeHook.original, memory_order_acquire);
    return original ? ((NSInteger (*)(id, SEL))original)(self, selector) : 0;
}

static NSString *RUINAgeHookStatusName(RUINAgeHookStatus status)
{
    switch (status) {
        case RUINAgeHookVersionGated: return @"version_gated";
        case RUINAgeHookMissingClass: return @"missing_class";
        case RUINAgeHookMissingSelector: return @"missing_selector";
        case RUINAgeHookEncodingMismatch: return @"encoding_mismatch";
        case RUINAgeHookInstallFailed: return @"install_failed";
        case RUINAgeHookInstalled: return @"installed";
        default: return @"pending";
    }
}

NSDictionary<NSString *, id> *RUINAgeVerificationDiagnostics(void)
{
    return @{
        @"targetMatches": @(RUINTargetMatches()),
        @"bypassEnabled": @([NSUserDefaults.standardUserDefaults boolForKey:RUINBypassAgeVerificationDefaultsKey]),
        @"ageVerificationIsNecessary": RUINAgeHookStatusName(atomic_load(&gAgeNecessaryHook.status)),
        @"userAgeType": RUINAgeHookStatusName(atomic_load(&gUserAgeTypeHook.status)),
        @"ageVerificationCalls": @(atomic_load(&gAgeNecessaryHook.calls)),
        @"userAgeTypeCalls": @(atomic_load(&gUserAgeTypeHook.calls))
    };
}
