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
    IMP replacement;
    _Atomic(IMP) original;
    atomic_uint_fast64_t calls;
    atomic_int status;
} RUINAgeHook;

static BOOL RUINAgeVerificationIsNecessary(id self, SEL selector);
static NSInteger RUINUserAgeType(id self, SEL selector);

#define RUIN_AGE_HOOK(selector, types, function) \
    { selector, types, (IMP)function, ATOMIC_VAR_INIT(NULL), ATOMIC_VAR_INIT(0), ATOMIC_VAR_INIT(RUINAgeHookPending) }

// Current LINE exposes the local guard pair on NLAgeVerificationManager's metaclass.
static RUINAgeHook gAgeNecessaryHook = RUIN_AGE_HOOK("ageVerificationIsNecessary", "B16@0:8", RUINAgeVerificationIsNecessary);
static RUINAgeHook gUserAgeTypeHook = RUIN_AGE_HOOK("userAgeType", "q16@0:8", RUINUserAgeType);
static os_unfair_lock gAgeInstallLock = OS_UNFAIR_LOCK_INIT;

#undef RUIN_AGE_HOOK

static BOOL RUINTargetMatches(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    return [info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier] &&
        [info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] &&
        [info[@"CFBundleVersion"] isEqual:RUINTargetBuild];
}

static Method RUINOwnMethod(Class cls, SEL selector)
{
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) { found = methods[index]; break; }
    }
    free(methods);
    return found;
}

static void RUINInstallAgeHook(Class metaclass, RUINAgeHook *hook)
{
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
    Method own = RUINOwnMethod(metaclass, selector);
    if (own) {
        IMP replaced = method_setImplementation(own, hook->replacement);
        if (!replaced) { atomic_store(&hook->status, RUINAgeHookInstallFailed); return; }
        atomic_store_explicit(&hook->original, replaced, memory_order_release);
        atomic_store(&hook->status, RUINAgeHookInstalled);
        return;
    }
    if (class_addMethod(metaclass, selector, hook->replacement, encoding)) {
        atomic_store(&hook->status, RUINAgeHookInstalled);
        return;
    }
    own = RUINOwnMethod(metaclass, selector);
    if (!own) { atomic_store(&hook->status, RUINAgeHookInstallFailed); return; }
    IMP replaced = method_setImplementation(own, hook->replacement);
    if (!replaced) { atomic_store(&hook->status, RUINAgeHookInstallFailed); return; }
    atomic_store_explicit(&hook->original, replaced, memory_order_release);
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
    Class metaclass = target ? object_getClass((id)target) : Nil;
    RUINInstallAgeHook(metaclass, &gAgeNecessaryHook);
    RUINInstallAgeHook(metaclass, &gUserAgeTypeHook);
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
