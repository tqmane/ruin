%config(generator=internal)

#import "ThemePrivateAPI.h"
#import "ThemeShop.h"
#import "../known/ThemeMappings.h"
#import "../core/Localization.h"
#import "../core/TargetMetadata.h"
#import "../known/VersionMapping.h"

#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

#if !defined(RUIN_THEMESHOP_HOST_CHECK)
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif
#endif

// AppDelegate -openURLForObjC: and the verified native eligibility call chains
// are selected from ThemeMappings for the exact pristine host binary.
static NSString * const RUINThemeShopURLString = @"line://shop/theme";
// LINE Developers documents /R/shop/sticker/hot as the Sticker Shop ranking entry.
static NSString * const RUINStickerShopURLString = @"line://shop/sticker/hot";
static const char * const RUINThemeShopDelegateClass = "_TtC4LINE11AppDelegate";
static const char * const RUINThemeShopSelector = "openURLForObjC:";

typedef NS_ENUM(int, RUINThemeShopStatus) {
    RUINThemeShopNotRequested,
    RUINThemeShopVersionGated,
    RUINThemeShopRouterUnavailable,
    RUINThemeShopRouteAccepted,
    RUINThemeShopRouteRejected,
    RUINThemeShopRouterException,
    RUINThemeShopSourceUnavailable
};

static atomic_int gThemeShopStatus;
static atomic_uint_fast64_t gThemeShopRequests, gThemeShopAccepted, gThemeShopRejected, gThemeShopExceptions;
static const RUINThemeMappings *gThemeShopMappings;

typedef NS_ENUM(unsigned, RUINThemeShopGateScope) {
    RUINThemeShopGateNone, RUINThemeShopGateThemeAction, RUINThemeShopGateRouter,
    RUINThemeShopGateStylesheetPersistence
};
typedef struct { uintptr_t returnPC, callerFrame; } RUINThemeShopFrame;
typedef struct { uintptr_t valueFrame; RUINThemeShopGateScope kind; } RUINThemeShopScope;
static atomic_bool gThemeShopGateReady;
static atomic_uint_fast64_t gThemeShopModeProjections, gThemeShopRoleProjections;
static atomic_uint_fast64_t gThemeShopScopeMisses;
static atomic_int gThemeShopGateStatus;
static atomic_uint_fast64_t gThemePersistenceModeProjections, gThemePersistenceRoleProjections;
static _Thread_local unsigned gThemeShopGateDepth;
static NSString *const RUINThemeShopAccountKey = @"LineAccountType";
static NSString *const RUINThemeShopModeKey = @"LineUtilUserDefaults.userDefaultEncryptionMode";

// Return PCs stay in the exact ordered chain around ONE typed default read.
static RUINThemeShopScope RUINThemeShopClassifyFrames(const RUINThemeShopEligibilityMapping *mapping,
    const RUINThemeShopFrame *frames, size_t count, BOOL mode)
{
    RUINThemeShopScope none = {0};
    uintptr_t leafPC = mapping ? (mode ? mapping->modeReturnPC : mapping->accountReturnPC) : 0;
    if (!mapping || mapping->nativeReadAdapterStatus != RUINMappingStatusVerified ||
        !frames || !count || !leafPC ||
        frames[0].returnPC != leafPC) return none;
    size_t chainStart = 1;
    uintptr_t valueFrame = frames[0].callerFrame;
    if (mode) {
        if (count < 2 || !mapping->modeCopyReturnPC ||
            frames[1].returnPC != mapping->modeCopyReturnPC) return none;
        valueFrame = frames[1].callerFrame;
        chainStart = 2;
    }

    size_t i = chainStart;
    BOOL chainMatched = NO;
    if (mapping->accountChainAlternativeCount) {
        if (!mapping->accountChainAlternatives) return none;
        for (size_t alternative = 0; alternative < mapping->accountChainAlternativeCount; alternative++) {
            const RUINThemeShopReturnChain *chain = &mapping->accountChainAlternatives[alternative];
            if (!chain->returnPCs || !chain->returnPCCount || chain->returnPCCount > count - chainStart) continue;
            BOOL matches = YES;
            for (size_t j = 0; j < chain->returnPCCount; j++) {
                uintptr_t expected = chain->returnPCs[j];
                if (!expected || frames[chainStart + j].returnPC != expected) {
                    matches = NO;
                    break;
                }
            }
            if (matches) {
                i = chainStart + chain->returnPCCount;
                chainMatched = YES;
                break;
            }
        }
    } else {
        chainMatched = YES;
        for (size_t j = 0; j < sizeof(mapping->accountChain) / sizeof(*mapping->accountChain); j++) {
            uintptr_t expected = mapping->accountChain[j];
            if (i >= count || !expected || frames[i++].returnPC != expected) {
                chainMatched = NO;
                break;
            }
        }
    }
    if (!chainMatched || !valueFrame || i >= count) return none;
    // StylesheetManager's injected isPrimaryAccount closure calls the same
    // AccountLevel getter synchronously. Require BOTH the verified closure
    // continuation and the exact stylesheet-save caller, in this order.
    if (mapping->stylesheetEligibilityReturnPC && mapping->stylesheetSaveReturnPC && i + 1 < count &&
        frames[i].returnPC == mapping->stylesheetEligibilityReturnPC &&
        frames[i + 1].returnPC == mapping->stylesheetSaveReturnPC)
        return (RUINThemeShopScope){valueFrame, RUINThemeShopGateStylesheetPersistence};
    if (!mapping->capabilityReturnPC || frames[i++].returnPC != mapping->capabilityReturnPC || i >= count)
        return none;
    if (mapping->themeActionReturnPC && frames[i].returnPC == mapping->themeActionReturnPC)
        return (RUINThemeShopScope){valueFrame, RUINThemeShopGateThemeAction};
    // Exact stack PCs do not prove the URL's feature. Enable this route only
    // when the version mapping separately proves Theme/Sticker ownership.
    if (mapping->shopSchemeScopeStatus != RUINMappingStatusVerified) return none;
    if (i + 1 < count) {
        for (size_t scheme = 0; scheme < 2; scheme++) {
            if (!mapping->shopSchemeReturnPCs[scheme] || frames[i].returnPC != mapping->shopSchemeReturnPCs[scheme])
                continue;
            for (size_t handler = 0; handler < 2; handler++) {
                if (mapping->shopSchemeHandlerReturnPCs[handler] &&
                    frames[i + 1].returnPC == mapping->shopSchemeHandlerReturnPCs[handler])
                    return (RUINThemeShopScope){valueFrame, RUINThemeShopGateRouter};
            }
        }
    }
    return none;
}

#if defined(RUIN_THEMESHOP_HOST_CHECK)
static RUINThemeShopFrame gThemeShopTestFrames[12];
static size_t gThemeShopTestFrameCount;
static uintptr_t gThemeShopTestModeFrame;
static uint32_t gThemeShopTestModeSlot;
static RUINThemeShopScope RUINThemeShopCaptureScope(void *frame, BOOL mode)
{
    (void)frame;
    return RUINThemeShopClassifyFrames(gThemeShopMappings ? &gThemeShopMappings->shopEligibility : NULL,
        gThemeShopTestFrames, gThemeShopTestFrameCount, mode);
}
static BOOL RUINThemeShopFrameUsesPlainMode(uintptr_t frame)
{
    return frame && frame == gThemeShopTestModeFrame && gThemeShopTestModeSlot == 0;
}
#else
static intptr_t gThemeShopSlide;
static RUINThemeShopScope RUINThemeShopCaptureScope(void *frame, BOOL mode)
{
    RUINThemeShopFrame rows[24];
    size_t count = 0;
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    size_t size = pthread_get_stacksize_np(pthread_self());
    if (!top || size < 2 * sizeof(uintptr_t)) return (RUINThemeShopScope){0};
    uintptr_t low = top >= size ? top - size : top;
    uintptr_t current = (uintptr_t)frame;
    while (count < sizeof(rows) / sizeof(*rows) && !(current & 15) &&
        current >= low && current <= top - 2 * sizeof(uintptr_t)) {
        const uintptr_t *record = (const void *)current;
        // Swift marks an async frame link with bit 60; its ordinary FP chain
        // remains on this thread's stack. No async heap/object memory is read.
        uintptr_t previous = record[0] & ~((uintptr_t)1 << 60);
        uintptr_t pc = record[1];
#if __has_feature(ptrauth_calls)
        pc = (uintptr_t)ptrauth_strip((void *)pc, ptrauth_key_return_address);
#endif
        rows[count++] = (RUINThemeShopFrame){pc - gThemeShopSlide, previous};
        if (previous <= current) break;
        current = previous;
    }
    return RUINThemeShopClassifyFrames(gThemeShopMappings ? &gThemeShopMappings->shopEligibility : NULL,
        rows, count, mode);
}
static BOOL RUINThemeShopFrameUsesPlainMode(uintptr_t frame)
{
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    size_t size = pthread_get_stacksize_np(pthread_self());
    uintptr_t offset = gThemeShopMappings ? gThemeShopMappings->shopEligibility.plainModeStackOffset : 0;
    if (!gThemeShopMappings ||
        gThemeShopMappings->shopEligibility.nativeReadAdapterStatus != RUINMappingStatusVerified ||
        !offset || !top || size > top || frame < top - size || frame > top || offset > frame - (top - size)) return NO;
    uint32_t mode;
    memcpy(&mode, (const void *)(frame - offset), sizeof(mode));
    return mode == 0;
}
#endif

static NSInteger RUINThemeShopReadMode(id key, uintptr_t caller, void *frame, NSInteger (^readOriginal)(void))
{
    BOOL outer = gThemeShopGateDepth++ == 0;
    @try {
        NSInteger actual = readOriginal();
        if (!outer || !atomic_load(&gThemeShopGateReady) || !gThemeShopMappings ||
            caller != gThemeShopMappings->shopEligibility.modeReturnPC ||
            ![key isKindOfClass:NSString.class] || ![key isEqual:RUINThemeShopModeKey]) return actual;
        RUINThemeShopScope scope = RUINThemeShopCaptureScope(frame, YES);
        if (!scope.kind) { atomic_fetch_add(&gThemeShopScopeMisses, 1); return actual; }
        atomic_fetch_add(&gThemeShopModeProjections, 1);
        if (scope.kind == RUINThemeShopGateStylesheetPersistence)
            atomic_fetch_add(&gThemePersistenceModeProjections, 1);
        // Native UserDefault mode 0 reads plainDefaults and follows its zero-mode branch
        // skips migration. This return does not change the stored mode setting.
        return 0;
    } @finally { gThemeShopGateDepth--; }
}

static id RUINThemeShopReadAccount(id key, uintptr_t caller, void *frame, id (^readOriginal)(void))
{
    BOOL outer = gThemeShopGateDepth++ == 0;
    @try {
        id actual = readOriginal();
        if (!outer || !atomic_load(&gThemeShopGateReady) || !gThemeShopMappings ||
            caller != gThemeShopMappings->shopEligibility.accountReturnPC ||
            ![key isKindOfClass:NSString.class] || ![key isEqual:RUINThemeShopAccountKey]) return actual;
        RUINThemeShopScope scope = RUINThemeShopCaptureScope(frame, NO);
        // Check the mode actually copied into this native getter frame, rather
        // than assuming our earlier integerForKey: projection was delivered.
        if (!scope.kind || !RUINThemeShopFrameUsesPlainMode(scope.valueFrame)) {
            atomic_fetch_add(&gThemeShopScopeMisses, 1); return actual;
        }
        atomic_fetch_add(&gThemeShopRoleProjections, 1);
        if (scope.kind == RUINThemeShopGateStylesheetPersistence)
            atomic_fetch_add(&gThemePersistenceRoleProjections, 1);
        // UserDefaultConvertible uses a Swift.Int raw value. NSNumber zero
        // bridges to that type; native AccountLevel.isPrimary compares to 0.
        return @0;
    } @finally { gThemeShopGateDepth--; }
}

#if !defined(RUIN_THEMESHOP_HOST_CHECK)
// Capture the native caller in the Logos entry itself. Passing that frame to
// the verifier keeps helper/block frames out of the exact native stack chain.
%group RUINThemeDefaults
%hook RUINThemeDefaultsStore
__attribute__((noinline, disable_tail_calls))
- (NSInteger)integerForKey:(NSString *)key
{
    uintptr_t pc = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
    return RUINThemeShopReadMode(key, pc - gThemeShopSlide, __builtin_frame_address(0),
        ^NSInteger { return %orig; });
}
__attribute__((noinline, disable_tail_calls))
- (id)objectForKey:(NSString *)key
{
    uintptr_t pc = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
    return RUINThemeShopReadAccount(key, pc - gThemeShopSlide, __builtin_frame_address(0),
        ^id { return %orig; });
}
%end
%end
#endif

static const RUINThemeMappings *RUINThemeShopMappingForInfo(NSDictionary *info)
{
    const RUINVersionMapping *versionMapping = RUINMappingForInfo(info);
    const RUINThemeMappings *mapping = versionMapping ? &versionMapping->themes : NULL;
    if (!mapping || mapping->shopNavigation.status != RUINMappingStatusVerified) return NULL;
#if !defined(RUIN_THEMESHOP_HOST_CHECK)
    if (RUINCurrentMapping() != versionMapping) return NULL;
    RUINMainExecutableImage image;
    if (!RUINResolveMainExecutableImage(&image)) return NULL;
    const struct mach_header_64 *header = image.header;
    intptr_t slide = image.slide;
    char actualURL[sizeof("line://shop/theme")];
    if (!RUINVerifyInstructions(header, slide, mapping->shopNavigation.anchors,
            mapping->shopNavigation.anchorCount) ||
        !RUINReadImageBytes(header, slide, mapping->shopNavigation.themeURLString,
            actualURL, sizeof(actualURL), "__TEXT") ||
        memcmp(actualURL, RUINThemeShopURLString.UTF8String, sizeof(actualURL))) return NULL;
    gThemeShopSlide = slide;
#endif
    return mapping;
}

#if !defined(RUIN_THEMESHOP_HOST_CHECK)
static BOOL RUINThemeShopVerifyEligibility(const RUINThemeMappings *mapping)
{
    if (!mapping || mapping->shopEligibility.nativeReadAdapterStatus != RUINMappingStatusVerified) return NO;
    const RUINVersionMapping *versionMapping = RUINCurrentMapping();
    if (!versionMapping || &versionMapping->themes != mapping) return NO;
    RUINMainExecutableImage image;
    if (!RUINResolveMainExecutableImage(&image)) return NO;
    return RUINVerifyInstructions(image.header, image.slide, mapping->shopEligibility.anchors,
            mapping->shopEligibility.anchorCount);
}
#endif

#if !defined(RUIN_THEMESHOP_HOST_CHECK)
static void RUINThemeShopInstallGate(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!gThemeShopMappings ||
            gThemeShopMappings->shopEligibility.nativeReadAdapterStatus != RUINMappingStatusVerified) {
            atomic_store(&gThemeShopGateStatus, 5); return;
        }
        if (!RUINThemeShopVerifyEligibility(gThemeShopMappings)) {
            atomic_store(&gThemeShopGateStatus, 1); return;
        }
        Class cls = object_getClass(NSUserDefaults.standardUserDefaults);
        Method integer = class_getInstanceMethod(cls, @selector(integerForKey:));
        Method object = class_getInstanceMethod(cls, @selector(objectForKey:));
        if (!integer || !object || strcmp(method_getTypeEncoding(integer), "q24@0:8@16") ||
            strcmp(method_getTypeEncoding(object), "@24@0:8@16")) {
            atomic_store(&gThemeShopGateStatus, 2); return;
        }
        if (!method_getImplementation(integer) || !method_getImplementation(object)) {
            atomic_store(&gThemeShopGateStatus, 4); return;
        }
        %init(RUINThemeDefaults, RUINThemeDefaultsStore=cls);
        atomic_store(&gThemeShopGateStatus, 3);
        atomic_store(&gThemeShopGateReady, YES);
    });
}
#endif

#if !defined(RUIN_THEMESHOP_HOST_CHECK)
static NSNumber *gThemeShopUnscopedPrimaryBefore;
static NSNumber *RUINThemeShopUnscopedPrimary(void)
{
    Class cls = objc_getClass("AccountLevel");
    SEL selector = sel_registerName("isPrimary");
    Method method = cls ? class_getClassMethod(cls, selector) : NULL;
    if (!method || strcmp(method_getTypeEncoding(method), "B16@0:8")) return nil;
    return @([(Class<RUINThemeAccountLevelReading>)cls isPrimary]);
}
#endif

static BOOL RUINThemeShopTargetMatches(NSDictionary *info)
{
    return RUINTargetMetadataMatchesInfo(info);
}

void RUINInstallThemePersistenceAdapter(void)
{
#if !defined(RUIN_THEMESHOP_HOST_CHECK)
    gThemeShopMappings = RUINThemeShopMappingForInfo(NSBundle.mainBundle.infoDictionary);
    if (gThemeShopMappings)
        RUINThemeShopInstallGate();
#endif
}

NSDictionary *RUINThemePersistenceDiagnostics(void)
{
    return @{@"installed": @(atomic_load(&gThemeShopGateReady)),
        @"modeReadProjections": @(atomic_load(&gThemePersistenceModeProjections)),
        @"roleReadProjections": @(atomic_load(&gThemePersistenceRoleProjections)),
        @"scope": @"verified StylesheetManager settings-save caller chain",
        @"storedAccountRoleModified": @NO, @"executableCodeModified": @NO};
}

#if !defined(RUIN_THEMESHOP_HOST_CHECK)
static uintptr_t RUINThemeShopCanonicalIMP(IMP implementation)
{
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)implementation, ptrauth_key_function_pointer);
#else
    return (uintptr_t)implementation;
#endif
}
#endif

static BOOL RUINThemeShopRouterAvailable(id delegate, const RUINThemeMappings *mapping)
{
    (void)mapping;
    Class cls = objc_getClass(RUINThemeShopDelegateClass);
    if (!cls || !delegate || object_getClass(delegate) != cls) return NO;
    Method method = class_getInstanceMethod(cls, sel_registerName(RUINThemeShopSelector));
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    IMP implementation = method ? method_getImplementation(method) : NULL;
    if (!types || strcmp(types, "B24@0:8@16") || !implementation) return NO;
#if !defined(RUIN_THEMESHOP_HOST_CHECK)
    // Missing numeric mappings still allow the guarded Objective-C route.
    if (mapping && mapping->shopNavigation.status == RUINMappingStatusVerified)
        return RUINThemeShopCanonicalIMP(implementation) == mapping->shopNavigation.methodIMP + gThemeShopSlide;
#endif
    return YES;
}

static RUINThemeShopStatus RUINThemeShopRecord(RUINThemeShopStatus status)
{
    atomic_store(&gThemeShopStatus, status);
    return status;
}

static NSString *RUINThemeShopStatusName(RUINThemeShopStatus status)
{
    switch (status) {
        case RUINThemeShopVersionGated: return @"version_gated";
        case RUINThemeShopRouterUnavailable: return @"native_router_unavailable_or_abi_mismatch";
        case RUINThemeShopRouteAccepted: return @"native_route_accepted";
        case RUINThemeShopRouteRejected: return @"native_route_rejected";
        case RUINThemeShopRouterException: return @"native_router_exception";
        case RUINThemeShopSourceUnavailable: return @"visible_navigation_source_required";
        default: return @"not_requested";
    }
}

static NSString *RUINThemeShopGateStatusName(void)
{
    switch (atomic_load(&gThemeShopGateStatus)) {
        case 1: return @"native_site_fingerprint_mismatch";
        case 2: return @"defaults_boundary_abi_mismatch";
        case 3: return @"installed_native_ui_eligibility_projection";
        case 4: return @"defaults_boundary_install_failed_passthrough";
        case 5: return @"shop_read_adapter_unported_for_host";
        default: return @"not_requested";
    }
}

static RUINThemeShopStatus RUINThemeShopDispatchURL(id delegate, NSDictionary *info, NSString *URLString)
{
    if (![URLString isEqual:RUINThemeShopURLString] && ![URLString isEqual:RUINStickerShopURLString])
        return RUINThemeShopRecord(RUINThemeShopRouteRejected);
    if (!RUINThemeShopTargetMatches(info)) return RUINThemeShopRecord(RUINThemeShopVersionGated);
    const RUINThemeMappings *mapping = RUINThemeShopMappingForInfo(info);
    gThemeShopMappings = mapping;
    if (!RUINThemeShopRouterAvailable(delegate, mapping))
        return RUINThemeShopRecord(RUINThemeShopRouterUnavailable);
#if !defined(RUIN_THEMESHOP_HOST_CHECK)
    if (!atomic_load(&gThemeShopRequests)) gThemeShopUnscopedPrimaryBefore = RUINThemeShopUnscopedPrimary();
    RUINThemeShopInstallGate();
#endif
    atomic_fetch_add(&gThemeShopRequests, 1);
    @try {
        BOOL accepted = [(id<RUINThemeURLRouting>)delegate
            openURLForObjC:[NSURL URLWithString:URLString]];
        atomic_fetch_add(accepted ? &gThemeShopAccepted : &gThemeShopRejected, 1);
        return RUINThemeShopRecord(accepted ? RUINThemeShopRouteAccepted : RUINThemeShopRouteRejected);
    } @catch (__unused NSException *exception) {
        atomic_fetch_add(&gThemeShopExceptions, 1);
        return RUINThemeShopRecord(RUINThemeShopRouterException);
    }
}

#if defined(RUIN_THEMESHOP_HOST_CHECK)
static RUINThemeShopStatus RUINThemeShopDispatch(id delegate, NSDictionary *info) {
    return RUINThemeShopDispatchURL(delegate, info, RUINThemeShopURLString);
}
#endif

NSDictionary<NSString *, id> *RUINThemeShopDiagnostics(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    const RUINVersionMapping *versionMapping = RUINMappingForInfo(info);
    const RUINThemeMappings *mapping = versionMapping ? &versionMapping->themes : NULL;
    NSMutableDictionary *result = [@{
        @"targetMatches": @(RUINThemeShopTargetMatches(info)),
        @"expectedVersion": versionMapping ? [NSString stringWithUTF8String:versionMapping->host.version]
            : info[@"CFBundleShortVersionString"] ?: (id)NSNull.null,
        @"expectedBuild": versionMapping ? [NSString stringWithUTF8String:versionMapping->host.build]
            : info[@"CFBundleVersion"] ?: (id)NSNull.null,
        @"fixedURL": RUINThemeShopURLString,
        @"stickerURL": RUINStickerShopURLString,
        @"nativeEntry": @"AppDelegate -openURLForObjC:",
        @"nativeABI": @"B24@0:8@16",
        @"lastStatus": RUINThemeShopStatusName(atomic_load(&gThemeShopStatus)),
        @"requests": @(atomic_load(&gThemeShopRequests)),
        @"nativeRouteAccepted": @(atomic_load(&gThemeShopAccepted)),
        @"nativeRouteRejected": @(atomic_load(&gThemeShopRejected)),
        @"nativeExceptions": @(atomic_load(&gThemeShopExceptions)),
        @"storeLoadVerified": @NO,
        @"themeDownloadVerified": @NO,
        @"themeApplyVerified": @NO,
        @"externalURLFallback": @NO,
        @"gateOverrideInstalled": @(atomic_load(&gThemeShopGateReady)),
        @"gateOverrideStatus": RUINThemeShopGateStatusName(),
        @"gateScope": mapping && mapping->shopEligibility.nativeReadAdapterStatus == RUINMappingStatusVerified
            ? mapping->shopEligibility.shopSchemeScopeStatus == RUINMappingStatusVerified
                ? @"verified theme capability, Theme/Sticker router and StylesheetManager settings-save caller chains"
                : @"verified native-read mapping; StylesheetManager save scope enabled; ShopScheme route scope unverified"
            : mapping ? @"Shop navigation binary verified; numeric eligibility adapter unavailable for this host"
            : @"Shop navigation uses structural Objective-C ABI guard; numeric eligibility scope unavailable",
        @"shopNavigationMappingVerified": @(mapping && mapping->shopNavigation.status == RUINMappingStatusVerified),
        @"shopReadAdapterVerified": @(mapping &&
            mapping->shopEligibility.nativeReadAdapterStatus == RUINMappingStatusVerified),
        @"shopSchemeScopeVerified": @(mapping &&
            mapping->shopEligibility.shopSchemeScopeStatus == RUINMappingStatusVerified),
        @"gateModeProjections": @(atomic_load(&gThemeShopModeProjections)),
        @"gateRoleReadProjections": @(atomic_load(&gThemeShopRoleProjections)),
        @"gateScopeMisses": @(atomic_load(&gThemeShopScopeMisses)),
        @"stylesheetPersistence": RUINThemePersistenceDiagnostics(),
        @"storedRoleModifiedByAdapter": @NO
    } mutableCopy];
#if !defined(RUIN_THEMESHOP_HOST_CHECK)
    if (NSThread.isMainThread) {
        BOOL routerAvailable = RUINThemeShopRouterAvailable(UIApplication.sharedApplication.delegate, mapping);
        result[@"nativeRouterAvailable"] = @(routerAvailable);
        if (atomic_load(&gThemeShopRequests)) {
            NSNumber *actual = RUINThemeShopUnscopedPrimary();
            result[@"unscopedPrimaryBeforeRequest"] = gThemeShopUnscopedPrimaryBefore ?: (id)NSNull.null;
            result[@"unscopedPrimaryNow"] = actual ?: (id)NSNull.null;
            result[@"unscopedRolePreserved"] = @(actual && gThemeShopUnscopedPrimaryBefore &&
                [actual isEqual:gThemeShopUnscopedPrimaryBefore]);
        }
        result[@"entryAvailable"] = @(routerAvailable && [result[@"targetMatches"] boolValue]);
    } else result[@"nativeRouterStatus"] = @"main_thread_check_required";
#endif
    return result;
}

#if !defined(RUIN_THEMESHOP_HOST_CHECK)

static void RUINOpenShop(UIViewController *source, BOOL sticker)
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINOpenShop(source, sticker); });
        return;
    }
    UINavigationController *navigation = [source isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)source : source.navigationController;
    UIViewController *visible = navigation.topViewController;
    BOOL sourceMatches = source == navigation;
    for (UIViewController *candidate = source; candidate; candidate = candidate.parentViewController) {
        if (candidate == visible) { sourceMatches = YES; break; }
    }
    if (!navigation || !sourceMatches || !visible.viewIfLoaded.window ||
        navigation.presentedViewController || visible.presentedViewController || navigation.transitionCoordinator) {
        RUINThemeShopRecord(RUINThemeShopSourceUnavailable);
        return;
    }
    RUINThemeShopStatus status = RUINThemeShopDispatchURL(UIApplication.sharedApplication.delegate,
        NSBundle.mainBundle.infoDictionary, sticker ? RUINStickerShopURLString : RUINThemeShopURLString);
    if (status == RUINThemeShopRouteAccepted) return;
    if (navigation.topViewController != visible || visible.presentedViewController || !visible.viewIfLoaded.window) return;
    NSString *message = sticker ? RUINLocalizedString(@"スタンプショップを開けませんでした") :
        status == RUINThemeShopVersionGated || status == RUINThemeShopRouterUnavailable
        ? RUINLocalizedString(@"このLINEバージョンでは着せかえショップへの移動を利用できません。")
        : RUINLocalizedString(@"LINEに着せかえショップの表示を要求しましたが、受け付けられませんでした。");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINLocalizedString(sticker ? @"スタンプショップを開けませんでした" : @"着せかえショップを開けませんでした")
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"閉じる") style:UIAlertActionStyleCancel handler:nil]];
    [visible presentViewController:alert animated:YES completion:nil];
}

void RUINOpenThemeShop(UIViewController *source) { RUINOpenShop(source, NO); }
void RUINOpenStickerShop(UIViewController *source) { RUINOpenShop(source, YES); }

#else
#import <assert.h>

static NSInteger testStoredMode;
static NSNumber *testStoredLevel;
static BOOL testDefaultsThrow;
static unsigned testNativeMigrations;

static NSInteger RUINThemeShopTestInteger(id object, SEL selector, id key)
{
    (void)object; (void)selector; (void)key;
    return testStoredMode;
}
static id RUINThemeShopTestObject(id object, SEL selector, id key)
{
    (void)object; (void)selector; (void)key;
    if (testDefaultsThrow) @throw [NSException exceptionWithName:@"DefaultsProbe" reason:nil userInfo:nil];
    return testStoredLevel;
}
static NSInteger RUINThemeShopTestReadMode(id object, SEL selector, id key, uintptr_t caller, void *frame)
{
    return RUINThemeShopReadMode(key, caller, frame,
        ^NSInteger { return RUINThemeShopTestInteger(object, selector, key); });
}
static id RUINThemeShopTestReadAccount(id object, SEL selector, id key, uintptr_t caller, void *frame)
{
    return RUINThemeShopReadAccount(key, caller, frame,
        ^id { return RUINThemeShopTestObject(object, selector, key); });
}
static void RUINThemeShopTestStackFor(BOOL mode, RUINThemeShopGateScope kind,
    size_t chainAlternative, size_t schemeIndex, size_t handlerIndex)
{
    const RUINThemeShopEligibilityMapping *mapping = &gThemeShopMappings->shopEligibility;
    const uintptr_t *chainPCs = mapping->accountChain;
    size_t chainCount = sizeof(mapping->accountChain) / sizeof(*mapping->accountChain);
    if (mapping->accountChainAlternativeCount) {
        assert(chainAlternative < mapping->accountChainAlternativeCount);
        assert(mapping->accountChainAlternatives);
        chainPCs = mapping->accountChainAlternatives[chainAlternative].returnPCs;
        chainCount = mapping->accountChainAlternatives[chainAlternative].returnPCCount;
    }
    size_t n = 0;
    gThemeShopTestFrames[n++] = (RUINThemeShopFrame){
        mode ? mapping->modeReturnPC : mapping->accountReturnPC, mode ? 0x1000 : 0x2000};
    if (mode) gThemeShopTestFrames[n++] = (RUINThemeShopFrame){mapping->modeCopyReturnPC, 0x2000};
    for (size_t i = 0; i < chainCount; i++)
        gThemeShopTestFrames[n++] = (RUINThemeShopFrame){chainPCs[i], 0x3000 + i * 0x100};
    if (kind == RUINThemeShopGateStylesheetPersistence) {
        gThemeShopTestFrames[n++] = (RUINThemeShopFrame){mapping->stylesheetEligibilityReturnPC, 0x4000};
        gThemeShopTestFrames[n++] = (RUINThemeShopFrame){mapping->stylesheetSaveReturnPC, 0x5000};
    } else {
        gThemeShopTestFrames[n++] = (RUINThemeShopFrame){mapping->capabilityReturnPC, 0x4000};
        if (kind == RUINThemeShopGateThemeAction)
            gThemeShopTestFrames[n++] = (RUINThemeShopFrame){mapping->themeActionReturnPC, 0x5000};
        else if (kind == RUINThemeShopGateRouter) {
            gThemeShopTestFrames[n++] = (RUINThemeShopFrame){mapping->shopSchemeReturnPCs[schemeIndex], 0x5000};
            gThemeShopTestFrames[n++] = (RUINThemeShopFrame){mapping->shopSchemeHandlerReturnPCs[handlerIndex], 0x6000};
        } else gThemeShopTestFrames[n++] = (RUINThemeShopFrame){1, 0x5000};
    }
    gThemeShopTestFrameCount = n;
}

static void RUINThemeShopTestStack(BOOL mode, RUINThemeShopGateScope kind)
{
    RUINThemeShopTestStackFor(mode, kind, 0, 0, 0);
}

static void RUINThemeShopTestSetModeSlot(uintptr_t frame, uint32_t mode)
{
    gThemeShopTestModeFrame = frame;
    gThemeShopTestModeSlot = mode;
}

static NSNumber *RUINThemeShopTestNativeReadFor(RUINThemeShopGateScope kind,
    size_t chainAlternative, size_t schemeIndex, size_t handlerIndex, BOOL deliverModeProjection)
{
    RUINThemeShopTestStackFor(YES, kind, chainAlternative, schemeIndex, handlerIndex);
    NSInteger rawMode = RUINThemeShopTestReadMode(nil, @selector(integerForKey:), RUINThemeShopModeKey,
        gThemeShopMappings->shopEligibility.modeReturnPC, NULL);
    RUINThemeShopScope modeScope = RUINThemeShopCaptureScope(NULL, YES);
    RUINThemeShopTestSetModeSlot(modeScope.kind ? modeScope.valueFrame : 0,
        deliverModeProjection ? (uint32_t)rawMode : (uint32_t)testStoredMode);
    RUINThemeShopTestStackFor(NO, kind, chainAlternative, schemeIndex, handlerIndex);
    NSNumber *value = RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
        gThemeShopMappings->shopEligibility.accountReturnPC, NULL);
    // Model the recovered CBZ: a nonzero mode may migrate the decoded value.
    // A synthesized eligibility value must never reach that writer.
    if (gThemeShopTestModeSlot && value) { testNativeMigrations++; testStoredLevel = value; }
    return value;
}

static NSNumber *RUINThemeShopTestNativeRead(RUINThemeShopGateScope kind)
{
    return RUINThemeShopTestNativeReadFor(kind, 0, 0, 0, YES);
}

static void RUINThemeShopCheck26170(const RUINVersionMapping *version17)
{
    assert(version17 && version17->host.supportStatus == RUINMappingStatusUnverified);
    assert(!strcmp(version17->host.uuid, "614CED59-07E5-372D-94B2-D4901870C7A0"));
    assert(version17->themes.shopEligibility.status == RUINMappingStatusUnsupported &&
        version17->themes.shopEligibility.nativeReadAdapterStatus == RUINMappingStatusVerified &&
        version17->themes.shopEligibility.shopSchemeScopeStatus == RUINMappingStatusUnverified);
    const RUINThemeShopEligibilityMapping *mapping = &version17->themes.shopEligibility;
    assert(mapping->modeReturnPC == 0x106af1c60 && mapping->modeCopyReturnPC == 0x106ad9b30 &&
        mapping->accountReturnPC == 0x106ad9cd4 && mapping->plainModeStackOffset == 0xb4);
    assert(mapping->preflightAccountReturnPC == 0 && mapping->themeActionReturnPC == 0 &&
        mapping->accountChain[0] == 0 && mapping->accountChainAlternativeCount == 2 &&
        mapping->anchors && mapping->anchorCount > 0);
    assert(mapping->shopSchemeReturnPCs[0] == 0x1003ac4ac && mapping->shopSchemeReturnPCs[1] == 0x1003ac4b8 &&
        mapping->shopSchemeHandlerReturnPCs[0] == 0x1003acd98 &&
        mapping->shopSchemeHandlerReturnPCs[1] == 0x1003acf20);
    assert(mapping->accountChainAlternatives[0].returnPCCount == 4 &&
        mapping->accountChainAlternatives[1].returnPCCount == 3);
    assert(mapping->capabilityReturnPC == 0x1007642a4 &&
        mapping->stylesheetEligibilityReturnPC == 0x1002387e0 &&
        mapping->stylesheetSaveReturnPC == 0x105f7d7d8);

    const RUINThemeMappings *previousMappings = gThemeShopMappings;
    BOOL gateWasReady = atomic_exchange(&gThemeShopGateReady, YES);
    gThemeShopMappings = &version17->themes;
    for (size_t chain = 0; chain < mapping->accountChainAlternativeCount; chain++) {
        for (size_t scheme = 0; scheme < 2; scheme++) {
            for (size_t handler = 0; handler < 2; handler++) {
                RUINThemeShopTestStackFor(YES, RUINThemeShopGateRouter, chain, scheme, handler);
                assert(!RUINThemeShopCaptureScope(NULL, YES).kind);
                RUINThemeShopTestStackFor(NO, RUINThemeShopGateRouter, chain, scheme, handler);
                assert(!RUINThemeShopCaptureScope(NULL, NO).kind);
            }
        }
        RUINThemeShopTestStackFor(YES, RUINThemeShopGateStylesheetPersistence, chain, 0, 0);
        RUINThemeShopScope modeScope = RUINThemeShopCaptureScope(NULL, YES);
        assert(modeScope.kind == RUINThemeShopGateStylesheetPersistence &&
            modeScope.valueFrame == gThemeShopTestFrames[1].callerFrame);
        RUINThemeShopTestStackFor(NO, RUINThemeShopGateStylesheetPersistence, chain, 0, 0);
        RUINThemeShopScope accountScope = RUINThemeShopCaptureScope(NULL, NO);
        assert(accountScope.kind == RUINThemeShopGateStylesheetPersistence &&
            accountScope.valueFrame == gThemeShopTestFrames[0].callerFrame);
    }

    testStoredMode = 1; testStoredLevel = @1; testNativeMigrations = 0;
    assert(RUINThemeShopTestNativeReadFor(RUINThemeShopGateStylesheetPersistence, 0, 0, 0, YES).longLongValue == 0);
    assert(gThemeShopTestModeSlot == 0 && testStoredMode == 1 && testStoredLevel.longLongValue == 1 &&
        !testNativeMigrations);
    testStoredMode = 0; testStoredLevel = @1; testNativeMigrations = 0;
    assert(RUINThemeShopTestNativeReadFor(RUINThemeShopGateStylesheetPersistence, 1, 0, 0, YES).longLongValue == 0);
    assert(gThemeShopTestModeSlot == 0 && testStoredMode == 0 && testStoredLevel.longLongValue == 1 &&
        !testNativeMigrations);

    RUINThemeShopTestStackFor(YES, RUINThemeShopGateStylesheetPersistence, 0, 0, 0);
    gThemeShopTestFrames[2].returnPC ^= 4;
    assert(!RUINThemeShopCaptureScope(NULL, YES).kind);
    RUINThemeShopTestStackFor(NO, RUINThemeShopGateStylesheetPersistence, 1, 0, 0);
    gThemeShopTestFrames[2].returnPC ^= 4;
    assert(!RUINThemeShopCaptureScope(NULL, NO).kind);
    RUINThemeShopTestStackFor(NO, RUINThemeShopGateStylesheetPersistence, 0, 0, 0);
    gThemeShopTestFrames[0].returnPC = 0x106ada49c; // cipher-side read is never the role leaf
    assert(!RUINThemeShopCaptureScope(NULL, NO).kind);
    RUINThemeShopTestStackFor(YES, RUINThemeShopGateThemeAction, 0, 0, 0);
    assert(!RUINThemeShopCaptureScope(NULL, YES).kind); // zero is not a positive theme-action caller
    RUINThemeShopTestStackFor(NO, RUINThemeShopGateStylesheetPersistence, 0, 0, 0);
    gThemeShopTestFrames[2].returnPC = mapping->preflightAccountReturnPC;
    assert(!RUINThemeShopCaptureScope(NULL, NO).kind); // zero preflight is not a caller
    RUINThemeShopTestStackFor(NO, RUINThemeShopGateRouter, 0, 0, 0);
    gThemeShopTestFrames[gThemeShopTestFrameCount - 1].returnPC += 4;
    assert(!RUINThemeShopCaptureScope(NULL, NO).kind); // observed route PCs remain unenabled

    testStoredMode = 1; testStoredLevel = @1; testNativeMigrations = 0;
    assert(RUINThemeShopTestNativeReadFor(RUINThemeShopGateStylesheetPersistence, 0, 0, 0, NO).longLongValue == 1);
    assert(testStoredMode == 1 && testStoredLevel.longLongValue == 1 && testNativeMigrations == 1);

    testStoredMode = 1; testStoredLevel = @1; testNativeMigrations = 0;
    RUINThemeShopTestStackFor(YES, RUINThemeShopGateStylesheetPersistence, 0, 0, 0);
    assert(RUINThemeShopTestReadMode(nil, @selector(integerForKey:), RUINThemeShopModeKey,
        mapping->modeReturnPC, NULL) == 0);
    RUINThemeShopScope modeScope = RUINThemeShopCaptureScope(NULL, YES);
    RUINThemeShopTestSetModeSlot(modeScope.valueFrame, 2); // copied slot is not plain mode
    RUINThemeShopTestStackFor(NO, RUINThemeShopGateStylesheetPersistence, 0, 0, 0);
    assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
        mapping->accountReturnPC, NULL) isEqual:@1]);
    assert(testStoredLevel.longLongValue == 1 && !testNativeMigrations);

    RUINThemeShopTestStackFor(YES, RUINThemeShopGateStylesheetPersistence, 1, 0, 0);
    RUINThemeShopScope stylesheetMode = RUINThemeShopCaptureScope(NULL, YES);
    assert(stylesheetMode.kind == RUINThemeShopGateStylesheetPersistence &&
        stylesheetMode.valueFrame == gThemeShopTestFrames[1].callerFrame);
    RUINThemeShopTestStackFor(NO, RUINThemeShopGateStylesheetPersistence, 0, 0, 0);
    RUINThemeShopScope stylesheetAccount = RUINThemeShopCaptureScope(NULL, NO);
    assert(stylesheetAccount.kind == RUINThemeShopGateStylesheetPersistence &&
        stylesheetAccount.valueFrame == gThemeShopTestFrames[0].callerFrame);
    gThemeShopMappings = previousMappings;
    atomic_store(&gThemeShopGateReady, gateWasReady);
}

static void RUINThemeShopCheckGate(void)
{
    const RUINVersionMapping *version16 = RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"});
    const RUINVersionMapping *version17 = RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"});
    const RUINThemeMappings *mapping16 = version16 ? &version16->themes : NULL;
    const RUINThemeMappings *mapping17 = version17 ? &version17->themes : NULL;
    assert(mapping16 && mapping16->shopNavigation.status == RUINMappingStatusVerified &&
        mapping16->shopEligibility.status == RUINMappingStatusVerified &&
        mapping16->validation.status == RUINMappingStatusVerified &&
        mapping16->localPolicy.status == RUINMappingStatusVerified);
    assert(mapping17 && mapping17->shopNavigation.status == RUINMappingStatusVerified &&
        mapping17->shopEligibility.status == RUINMappingStatusUnsupported &&
        mapping17->shopEligibility.nativeReadAdapterStatus == RUINMappingStatusVerified &&
        mapping17->shopEligibility.shopSchemeScopeStatus == RUINMappingStatusUnverified &&
        mapping17->validation.status == RUINMappingStatusVerified &&
        mapping17->localPolicy.status == RUINMappingStatusVerified);
    assert(version17->host.supportStatus == RUINMappingStatusUnverified);
    assert(!RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.18.0", @"CFBundleVersion":@"unsupported"}));
    gThemeShopMappings = mapping16;
    Method integer = class_getInstanceMethod(NSUserDefaults.class, @selector(integerForKey:));
    Method object = class_getInstanceMethod(NSUserDefaults.class, @selector(objectForKey:));
    assert(integer && !strcmp(method_getTypeEncoding(integer), "q24@0:8@16"));
    assert(object && !strcmp(method_getTypeEncoding(object), "@24@0:8@16"));
    atomic_store(&gThemeShopGateReady, YES);
    for (unsigned kind = RUINThemeShopGateThemeAction; kind <= RUINThemeShopGateStylesheetPersistence; kind++) {
        for (NSInteger mode = 0; mode <= 2; mode++) {
            testStoredMode = mode; testStoredLevel = @1; testNativeMigrations = 0;
            assert(RUINThemeShopTestNativeRead(kind).longLongValue == 0);
            assert(testStoredLevel.longLongValue == 1 && testStoredMode == mode && !testNativeMigrations);
        }
    }
    testStoredMode = 2; testStoredLevel = nil; testNativeMigrations = 0;
    assert(RUINThemeShopTestNativeRead(RUINThemeShopGateThemeAction).longLongValue == 0);
    assert(testStoredLevel == nil && !testNativeMigrations && testStoredMode == 2);
    testStoredMode = 1; testStoredLevel = @1;
    assert(RUINThemeShopTestNativeRead(RUINThemeShopGateNone).longLongValue == 1);
    assert(testStoredLevel.longLongValue == 1); // native role is still secondary

    RUINThemeShopTestStack(YES, RUINThemeShopGateRouter);
    gThemeShopTestFrames[gThemeShopTestFrameCount - 2].returnPC =
        gThemeShopMappings->shopEligibility.shopSchemeReturnPCs[1];
    assert(RUINThemeShopTestReadMode(nil, @selector(integerForKey:), RUINThemeShopModeKey,
        gThemeShopMappings->shopEligibility.modeReturnPC, NULL) == 0);
    RUINThemeShopTestStack(NO, RUINThemeShopGateRouter);
    gThemeShopTestFrames[gThemeShopTestFrameCount - 2].returnPC =
        gThemeShopMappings->shopEligibility.shopSchemeReturnPCs[1];
    RUINThemeShopTestSetModeSlot(gThemeShopTestFrames[0].callerFrame, 0);
    assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
        gThemeShopMappings->shopEligibility.accountReturnPC, NULL) isEqual:@0]);
    assert(testStoredLevel.longLongValue == 1);

    for (unsigned secondFeature = 0; secondFeature < 2; secondFeature++) {
        for (unsigned mode = 0; mode < 2; mode++) {
            RUINThemeShopTestStack(mode, RUINThemeShopGateRouter);
            gThemeShopTestFrames[gThemeShopTestFrameCount - 1].returnPC =
                gThemeShopMappings->shopEligibility.shopSchemeHandlerReturnPCs[1];
            gThemeShopTestFrames[gThemeShopTestFrameCount - 2].returnPC =
                gThemeShopMappings->shopEligibility.shopSchemeReturnPCs[secondFeature];
            if (mode) assert(RUINThemeShopTestReadMode(nil, @selector(integerForKey:),
                RUINThemeShopModeKey, gThemeShopMappings->shopEligibility.modeReturnPC, NULL) == 0);
            else {
                RUINThemeShopTestSetModeSlot(gThemeShopTestFrames[0].callerFrame, 0);
                assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:),
                    RUINThemeShopAccountKey, gThemeShopMappings->shopEligibility.accountReturnPC, NULL) isEqual:@0]);
            }
            assert(testStoredLevel.longLongValue == 1 && testStoredMode == 1);
            gThemeShopTestFrames[gThemeShopTestFrameCount - 1].returnPC += 4;
            assert(!RUINThemeShopCaptureScope(NULL, mode).kind);
        }
    }

    NSUInteger migrationsBeforePersistenceChecks = testNativeMigrations;
    for (unsigned mode = 0; mode < 2; mode++) {
        RUINThemeShopTestStack(mode, RUINThemeShopGateStylesheetPersistence);
        assert(RUINThemeShopCaptureScope(NULL, mode).kind == RUINThemeShopGateStylesheetPersistence);
        for (size_t i = 0; i < gThemeShopTestFrameCount; i++) {
            uintptr_t old = gThemeShopTestFrames[i].returnPC;
            gThemeShopTestFrames[i].returnPC += 4;
            assert(!RUINThemeShopCaptureScope(NULL, mode).kind);
            gThemeShopTestFrames[i].returnPC = old;
        }
        gThemeShopTestFrameCount--;
        assert(!RUINThemeShopCaptureScope(NULL, mode).kind);
    }
    assert([RUINThemePersistenceDiagnostics()[@"roleReadProjections"] unsignedLongLongValue] > 0);
    assert(testStoredLevel.longLongValue == 1 && testStoredMode == 1 &&
        testNativeMigrations == migrationsBeforePersistenceChecks);

    RUINThemeShopTestStack(YES, RUINThemeShopGateThemeAction);
    assert(RUINThemeShopTestReadMode(nil, @selector(integerForKey:), @"otherModeKey",
        gThemeShopMappings->shopEligibility.modeReturnPC, NULL) == 1);
    assert(RUINThemeShopTestReadMode(nil, @selector(integerForKey:), RUINThemeShopModeKey,
        gThemeShopMappings->shopEligibility.modeReturnPC + 4, NULL) == 1);
    gThemeShopTestFrames[1].returnPC ^= 4;
    assert(RUINThemeShopTestReadMode(nil, @selector(integerForKey:), RUINThemeShopModeKey,
        gThemeShopMappings->shopEligibility.modeReturnPC, NULL) == 1);

    RUINThemeShopTestStack(NO, RUINThemeShopGateThemeAction);
    for (size_t i = 0; i < gThemeShopTestFrameCount; i++) {
        uintptr_t old = gThemeShopTestFrames[i].returnPC;
        gThemeShopTestFrames[i].returnPC ^= 4;
        assert(!RUINThemeShopClassifyFrames(&gThemeShopMappings->shopEligibility,
            gThemeShopTestFrames, gThemeShopTestFrameCount, NO).kind);
        gThemeShopTestFrames[i].returnPC = old;
    }
    gThemeShopTestFrames[2].returnPC = gThemeShopMappings->shopEligibility.preflightAccountReturnPC;
    assert(!RUINThemeShopCaptureScope(NULL, NO).kind);
    RUINThemeShopTestStack(NO, RUINThemeShopGateRouter);
    gThemeShopTestFrameCount--; // router helper without its shop handler is insufficient
    assert(!RUINThemeShopCaptureScope(NULL, NO).kind);
    RUINThemeShopTestStack(NO, RUINThemeShopGateThemeAction);
    for (uint32_t mode = 1; mode <= 2; mode++) {
        RUINThemeShopTestSetModeSlot(gThemeShopTestFrames[0].callerFrame, mode);
        assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
            gThemeShopMappings->shopEligibility.accountReturnPC, NULL) longLongValue] == 1);
    }
    RUINThemeShopTestSetModeSlot(gThemeShopTestFrames[0].callerFrame, 0);
    assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), @"otherKey",
        gThemeShopMappings->shopEligibility.accountReturnPC, NULL) isEqual:@1]);
    assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
        gThemeShopMappings->shopEligibility.accountReturnPC + 4, NULL) isEqual:@1]);
    gThemeShopGateDepth = 1;
    assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
        gThemeShopMappings->shopEligibility.accountReturnPC, NULL) isEqual:@1]);
    assert(gThemeShopGateDepth == 1); gThemeShopGateDepth = 0;
    testDefaultsThrow = YES;
    @try {
        RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
            gThemeShopMappings->shopEligibility.accountReturnPC, NULL);
        assert(!"expected native defaults exception");
    } @catch (NSException *exception) { assert([exception.name isEqual:@"DefaultsProbe"]); }
    assert(!gThemeShopGateDepth); testDefaultsThrow = NO;
    atomic_store(&gThemeShopGateReady, NO);
    assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
        gThemeShopMappings->shopEligibility.accountReturnPC, NULL) isEqual:@1]);
    RUINThemeShopCheck26170(version17);
    puts("PASS exact native caller chains, mode-0-only primary projection, migration exclusion, unchanged stored role, reentry and exception cleanup");
}

static NSString *testExpectedShopURL = @"line://shop/theme";
static NSUInteger testCalls;
static BOOL testReply = YES, testThrows;
static BOOL RUINThemeShopTestRouter(id receiver, SEL selector, NSURL *url)
{
    (void)receiver; (void)selector;
    assert([url isKindOfClass:NSURL.class] && [url.absoluteString isEqual:testExpectedShopURL]);
    assert(!url.query && !url.fragment && !url.user && !url.password);
    testCalls++;
    if (testThrows) @throw [NSException exceptionWithName:@"HostProbe" reason:nil userInfo:nil];
    return testReply;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        RUINThemeShopCheckGate();
        BOOL mismatch = argc == 2 && strcmp(argv[1], "mismatch") == 0;
        Class cls = objc_allocateClassPair(NSObject.class, RUINThemeShopDelegateClass, 0);
        assert(cls && class_addMethod(cls, sel_registerName(RUINThemeShopSelector),
            (IMP)RUINThemeShopTestRouter, mismatch ? "q24@0:8@16" : "B24@0:8@16"));
        objc_registerClassPair(cls);
        id delegate = [cls new];
        NSDictionary *info = @{@"RUINOriginalBundleIdentifier": @"jp.naver.line",
            @"CFBundleShortVersionString": @"26.16.0", @"CFBundleVersion": @"2026.1006.1718"};
        NSDictionary *info17 = @{@"RUINOriginalBundleIdentifier": @"jp.naver.line",
            @"CFBundleShortVersionString": @"26.17.0", @"CFBundleVersion": @"2026.1103.1841"};
        NSDictionary *unknownInfo = @{@"RUINOriginalBundleIdentifier": @"jp.naver.line",
            @"CFBundleShortVersionString": @"99.0.0", @"CFBundleVersion": @"2027.0101.0001"};
        assert(RUINThemeShopDispatch(delegate, @{}) == RUINThemeShopVersionGated);
        assert(RUINThemeShopDispatch(NSObject.new, info) == RUINThemeShopRouterUnavailable);
        assert(RUINThemeShopDispatch(nil, info) == RUINThemeShopRouterUnavailable);
        assert(testCalls == 0);
        if (mismatch) {
            assert(RUINThemeShopDispatch(delegate, info) == RUINThemeShopRouterUnavailable && testCalls == 0);
        } else {
            assert(RUINThemeShopDispatch(delegate, info) == RUINThemeShopRouteAccepted && testCalls == 1);
            testReply = NO;
            assert(RUINThemeShopDispatch(delegate, info) == RUINThemeShopRouteRejected && testCalls == 2);
            testThrows = YES;
            assert(RUINThemeShopDispatch(delegate, info) == RUINThemeShopRouterException && testCalls == 3);
            NSDictionary *diagnostics = RUINThemeShopDiagnostics();
            assert([diagnostics[@"nativeRouteAccepted"] unsignedIntegerValue] == 1);
            assert([diagnostics[@"nativeRouteRejected"] unsignedIntegerValue] == 1);
            assert([diagnostics[@"nativeExceptions"] unsignedIntegerValue] == 1);
            assert(![diagnostics[@"storeLoadVerified"] boolValue] && ![diagnostics[@"gateOverrideInstalled"] boolValue]);
            testThrows = NO; testReply = YES;
            assert(RUINThemeShopDispatch(delegate, info17) == RUINThemeShopRouteAccepted && testCalls == 4);
            assert(RUINThemeShopDispatch(delegate, unknownInfo) == RUINThemeShopRouteAccepted && testCalls == 5);
            testExpectedShopURL = RUINStickerShopURLString;
            assert(RUINThemeShopDispatchURL(delegate, info, RUINStickerShopURLString) == RUINThemeShopRouteAccepted && testCalls == 6);
            assert(RUINThemeShopDispatchURL(delegate, info, @"line://unrelated") == RUINThemeShopRouteRejected && testCalls == 6);
        }
        puts("PASS fixed in-process theme-shop URL, version/class/ABI gates, acceptance/rejection/exception accounting");
    }
    return 0;
}
#endif
