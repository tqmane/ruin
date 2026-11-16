%config(generator=internal);

#import "LegacyHome.h"
#import "VersionMapping.h"
#import "../core/NativeFunctionPointer.h"
#include <stdatomic.h>
#include <string.h>

NSString *const RUINLegacyHomeEnabledDefaultsKey = @"RUINLegacyHomeEnabled";

// These are Swift protocol witnesses, not ObjC methods expressible with %hook.
// Forward the native decoder, including Swift's error register. Project only
// its successful caller-owned result; never modify raw configuration or cache.
typedef void (*HomeDecoder)(uint8_t * __attribute__((swift_indirect_result)), uintptr_t, uintptr_t,
    const void *, const void *, void * __attribute__((swift_context)),
    void ** __attribute__((swift_error_result))) __attribute__((swiftcall));
typedef void (*GlobalDecoder)(uint8_t * __attribute__((swift_indirect_result)), const void *,
    const void *, const void *, void * __attribute__((swift_context)),
    void ** __attribute__((swift_error_result))) __attribute__((swiftcall));
static atomic_uintptr_t originalHome, originalGlobal;
static atomic_bool optionEnabled, adapterReady;
static atomic_bool protectionIncomplete;
static uintptr_t homeMetadata, homeWitness, globalMetadata, globalWitness;
static atomic_uint_fast64_t homeReads, globalReads, projectedReads;
static atomic_int launchPhase, installPhase;
static atomic_int firstHomePhase = ATOMIC_VAR_INIT(-1), firstGlobalPhase = ATOMIC_VAR_INIT(-1);
static _Atomic(const char *) adapterStatus = "pending";

static BOOL ShouldProject(uint8_t *output, void **error, const void *metadata,
    const void *witness, uintptr_t expectedMetadata, uintptr_t expectedWitness) {
    return error && !*error && output && atomic_load_explicit(&adapterReady, memory_order_acquire) &&
        atomic_load_explicit(&optionEnabled, memory_order_relaxed) &&
        (uintptr_t)metadata == expectedMetadata && (uintptr_t)witness == expectedWitness && *output <= 1;
}

static void __attribute__((swiftcall,noinline,disable_tail_calls)) HomeGate(
    uint8_t *output __attribute__((swift_indirect_result)), uintptr_t string0, uintptr_t string1,
    const void *metadata, const void *witness, void *context __attribute__((swift_context)),
    void **error __attribute__((swift_error_result))) {
    HomeDecoder original = (HomeDecoder)RUINNativeFunctionPointerForCall(atomic_load(&originalHome));
    if (!original) return;
    original(output, string0, string1, metadata, witness, context, error);
    if (atomic_fetch_add(&homeReads, 1) == 0) atomic_store(&firstHomePhase, atomic_load(&launchPhase));
    if (!atomic_load_explicit(&adapterReady, memory_order_acquire)) return;
    if (ShouldProject(output, error, metadata, witness, homeMetadata, homeWitness)) {
        if (*output) atomic_fetch_add(&projectedReads, 1);
        *output = 0;
    }
}

static void __attribute__((swiftcall,noinline,disable_tail_calls)) GlobalGate(
    uint8_t *output __attribute__((swift_indirect_result)), const void *decoder,
    const void *metadata, const void *witness, void *context __attribute__((swift_context)),
    void **error __attribute__((swift_error_result))) {
    GlobalDecoder original = (GlobalDecoder)RUINNativeFunctionPointerForCall(atomic_load(&originalGlobal));
    if (!original) return;
    original(output, decoder, metadata, witness, context, error);
    if (atomic_fetch_add(&globalReads, 1) == 0) atomic_store(&firstGlobalPhase, atomic_load(&launchPhase));
    if (!atomic_load_explicit(&adapterReady, memory_order_acquire)) return;
    if (ShouldProject(output, error, metadata, witness, globalMetadata, globalWitness)) {
        // GlobalHome has five Bool fields. Preserve the other four, including
        // onboarding, scrolling, friend-list tooltip and birthday effects.
        if (*output) atomic_fetch_add(&projectedReads, 1);
        *output = 0;
    }
}

#if !defined(RUIN_LEGACY_HOME_HOST_CHECK)
#import "TargetMetadata.h"
#import "FeatureImage.h"
#import <mach/mach.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

static RUINFeatureImage pinnedImage;
static BOOL launchHooksInstalled, nativeLaunchEntered, incompleteBinding;

%group RUINLegacyHomeWillLaunch
%hook RUINLegacyHomeDelegate
- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)options {
    nativeLaunchEntered = YES;
    atomic_store(&launchPhase, 1);
    RUINInstallLegacyHome();
    BOOL result = %orig(application, options);
    atomic_store(&launchPhase, 2);
    return result;
}
%end
%end

%group RUINLegacyHomeDidLaunch
%hook RUINLegacyHomeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    nativeLaunchEntered = YES;
    atomic_store(&launchPhase, 1);
    RUINInstallLegacyHome();
    BOOL result = %orig(application, options);
    atomic_store(&launchPhase, 2);
    return result;
}
%end
%end

static BOOL InstallLaunchHooks(Class factory) {
    if (launchHooksInstalled) return YES;
    Class delegate = NSClassFromString(@"_TtC4LINE11AppDelegate");
    const char *owner = factory ? class_getImageName(factory) : NULL;
    const char *delegateOwner = delegate ? class_getImageName(delegate) : NULL;
    if (!owner || !delegateOwner || strcmp(owner, delegateOwner)) return NO;
    Method will = class_getInstanceMethod(delegate, @selector(application:willFinishLaunchingWithOptions:));
    Method did = class_getInstanceMethod(delegate, @selector(application:didFinishLaunchingWithOptions:));
    BOOL hasWill = will && !strcmp(method_getTypeEncoding(will), "B32@0:8@16@24") && method_getImplementation(will);
    BOOL hasDid = did && !strcmp(method_getTypeEncoding(did), "B32@0:8@16@24") && method_getImplementation(did);
    if (!hasWill && !hasDid) return NO;
    if (hasWill) { %init(RUINLegacyHomeWillLaunch, RUINLegacyHomeDelegate = delegate); }
    if (hasDid) { %init(RUINLegacyHomeDidLaunch, RUINLegacyHomeDelegate = delegate); }
    launchHooksInstalled = YES;
    return YES;
}

static BOOL CopyMemory(uintptr_t address, void *output, size_t length) {
    vm_size_t copied = 0;
    return address && length && address <= UINTPTR_MAX - length &&
        vm_read_overwrite(mach_task_self(), address, length, (vm_address_t)output, &copied) == KERN_SUCCESS && copied == length;
}

// Copy-on-write runtime data only. Restore both the slot and protection after
// a failed transaction; never overwrite another hook's slot on a collision.
static BOOL SwapSlot(uintptr_t *slot, uintptr_t expected, uintptr_t replacement) {
    if (!slot || (uintptr_t)slot % sizeof(*slot)) return NO;
    vm_address_t page = (uintptr_t)slot & ~((vm_address_t)vm_page_size - 1), region = page;
    vm_size_t length = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(mach_task_self(), &region, &length, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || region > page || length < vm_page_size || region > UINTPTR_MAX - length ||
        region + length < page + vm_page_size || !(info.protection & VM_PROT_READ) || (info.protection & VM_PROT_EXECUTE)) return NO;
    BOOL protect = !(info.protection & VM_PROT_WRITE);
    if (protect && vm_protect(mach_task_self(), page, vm_page_size, FALSE,
        info.protection | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return NO;
    uintptr_t wanted = expected;
    BOOL changed = __atomic_compare_exchange_n(slot, &wanted, replacement, NO, __ATOMIC_RELEASE, __ATOMIC_RELAXED);
    if (protect && vm_protect(mach_task_self(), page, vm_page_size, FALSE, info.protection) != KERN_SUCCESS) {
        if (changed) {
            uintptr_t ours = replacement;
            __atomic_compare_exchange_n(slot, &ours, expected, NO, __ATOMIC_RELEASE, __ATOMIC_RELAXED);
        }
        if (vm_protect(mach_task_self(), page, vm_page_size, FALSE, info.protection) != KERN_SUCCESS)
            atomic_store(&protectionIncomplete, true);
        return NO;
    }
    return changed;
}

static BOOL VerifyRoute(const RUINVersionMapping *version, Class factory, RUINFeatureImage *image) {
    const RUINLegacyHomeMapping *m = &version->legacyHome;
    if (m->status != RUINMappingStatusVerified || !m->anchors || !m->anchorCount ||
        !m->factoryClassVA || !m->homeWitnessVA || !m->homeConformanceVA || !m->homeMetadataVA ||
        !m->homeDecoderVA || !m->globalWitnessAccessorVA || !m->globalConformanceVA ||
        !m->globalMetadataVA || !m->globalDecoderVA || !m->homeFlagStringVA || !m->globalHomeFlagStringVA ||
        !RUINResolveFeatureImage(&version->host, factory, image)) return NO;
    // Only the proven plain ARM64 consumer is supported. arm64e RUIN callers
    // sign callable pointers, while the native BR/BLR witness slots stay raw.
    if (image->image.cpuSubtype != CPU_SUBTYPE_ARM64_ALL ||
        (uintptr_t)factory != (uintptr_t)(image->image.slide + m->factoryClassVA) ||
        !RUINVerifyFeatureInstructions(image, m->anchors, m->anchorCount)) return NO;
    char home[sizeof("function.maintab.line_home")], global[sizeof("function.maintab.line_home_global")];
    return RUINReadFeatureImageBytes(image, m->homeFlagStringVA, home, sizeof(home), "__TEXT") &&
        RUINReadFeatureImageBytes(image, m->globalHomeFlagStringVA, global, sizeof(global), "__TEXT") &&
        !memcmp(home, "function.maintab.line_home", sizeof(home)) &&
        !memcmp(global, "function.maintab.line_home_global", sizeof(global));
}

void RUINInstallLegacyHome(void) {
    if (!NSThread.isMainThread) return;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    BOOL target = RUINTargetMetadataMatchesInfo(info);
    atomic_store(&optionEnabled, target && [NSUserDefaults.standardUserDefaults boolForKey:RUINLegacyHomeEnabledDefaultsKey]);
    if (!target) { atomic_store(&adapterStatus, "unsupported_target"); return; }
    if (atomic_load(&adapterReady)) return;
    if (incompleteBinding) return;
    const RUINVersionMapping *version = RUINMappingForInfo(info);
    if (!version || version->legacyHome.status != RUINMappingStatusVerified) {
        atomic_store(&adapterStatus, "unsupported_host"); return;
    }
    RUINFeatureImage image = {0};
    Class factory = NSClassFromString(@"_TtC4LINE24HomeTabControllerFactory");
    // Constructor-safe phase: no dyld lookup/dlopen or witness realization.
    // UIKit's native launch delegate entry then installs synchronously BEFORE
    // forwarding to LINE, rather than queueing after native Home construction.
    if (!nativeLaunchEntered) {
        atomic_store(&adapterStatus, InstallLaunchHooks(factory) ? "awaiting_native_launch" : "launch_hook_unavailable");
        return;
    }
    if (!factory || !VerifyRoute(version, factory, &image)) {
        RUINReleaseFeatureImage(&image); atomic_store(&adapterStatus, "unverified_native_route"); return;
    }
    const RUINLegacyHomeMapping *m = &version->legacyHome;
    intptr_t slide = image.image.slide;
    uintptr_t home[6], global[2];
    if (!RUINReadFeatureImageBytes(&image, m->homeWitnessVA, home, sizeof(home), "__DATA") ||
        home[0] != (uintptr_t)(slide + m->homeConformanceVA) || home[4] != (uintptr_t)(slide + m->homeDecoderVA)) {
        RUINReleaseFeatureImage(&image); atomic_store(&adapterStatus, "home_witness_mismatch"); return;
    }
    // A verified no-argument accessor realizes only Swift's Decodable witness
    // metadata. It does not construct Home, read configuration or change role.
    typedef const uintptr_t *(*WitnessAccessor)(void) __attribute__((swiftcall));
    WitnessAccessor accessor = (WitnessAccessor)RUINNativeFunctionPointerForCall(slide + m->globalWitnessAccessorVA);
    const uintptr_t *table = accessor();
    if (!CopyMemory((uintptr_t)table, global, sizeof(global)) ||
        global[0] != (uintptr_t)(slide + m->globalConformanceVA) || global[1] != (uintptr_t)(slide + m->globalDecoderVA)) {
        RUINReleaseFeatureImage(&image); atomic_store(&adapterStatus, "global_witness_mismatch"); return;
    }
    homeMetadata = slide + m->homeMetadataVA; homeWitness = slide + m->homeWitnessVA;
    globalMetadata = slide + m->globalMetadataVA; globalWitness = (uintptr_t)table;
    atomic_store(&originalHome, home[4]); atomic_store(&originalGlobal, global[1]);
    uintptr_t homeGate = RUINNativeFunctionPointerRaw((const void *)HomeGate);
    uintptr_t globalGate = RUINNativeFunctionPointerRaw((const void *)GlobalGate);
    uintptr_t *homeSlot = (uintptr_t *)(homeWitness + 4 * sizeof(uintptr_t));
    if (!SwapSlot(homeSlot, home[4], homeGate)) {
        uintptr_t value = 0;
        incompleteBinding = !CopyMemory((uintptr_t)homeSlot, &value, sizeof(value)) ||
            value == homeGate || atomic_load(&protectionIncomplete);
        if (incompleteBinding) pinnedImage = image; else RUINReleaseFeatureImage(&image);
        atomic_store(&adapterStatus, incompleteBinding ? "rollback_incomplete" : "home_binding_failed"); return;
    }
    if (!SwapSlot((uintptr_t *)table + 1, global[1], globalGate)) {
        BOOL restored = SwapSlot(homeSlot, homeGate, home[4]);
        // A published wrapper must keep its native code image alive even when
        // rollback fails. It forwards unchanged until adapterReady is true.
        uintptr_t value = 0;
        incompleteBinding = !restored || !CopyMemory((uintptr_t)(table + 1), &value, sizeof(value)) ||
            value == globalGate || atomic_load(&protectionIncomplete);
        if (incompleteBinding) pinnedImage = image; else RUINReleaseFeatureImage(&image);
        atomic_store(&adapterStatus, incompleteBinding ? "rollback_incomplete" : "global_binding_failed"); return;
    }
    pinnedImage = image;
    atomic_store(&installPhase, atomic_load(&launchPhase));
    atomic_store_explicit(&adapterReady, true, memory_order_release);
    atomic_store(&adapterStatus, "installed");
}
#endif

BOOL RUINLegacyHomeAvailable(void) { return atomic_load_explicit(&adapterReady, memory_order_acquire); }
NSDictionary *RUINLegacyHomeDiagnostics(void) {
    return @{@"status":@(atomic_load(&adapterStatus)), @"enabled":@(atomic_load(&optionEnabled)),
        @"available":@(RUINLegacyHomeAvailable()), @"homeReads":@(atomic_load(&homeReads)),
        @"globalHomeReads":@(atomic_load(&globalReads)), @"projectedReads":@(atomic_load(&projectedReads)),
        @"installPhase":@(atomic_load(&installPhase)), @"firstHomeDecodePhase":@(atomic_load(&firstHomePhase)),
        @"firstGlobalHomeDecodePhase":@(atomic_load(&firstGlobalPhase)),
        @"restartRequired":@YES, @"writesConfigurationToDisk":@NO, @"changesAccountRole":@NO};
}
