%config(generator=internal)

#import "ThemeShop.h"

#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

#if !defined(RUIN_THEMESHOP_HOST_CHECK)
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <pthread.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif
#endif

// LINE 26.16.0 / 2026.1006.1718: AppDelegate -openURLForObjC:
// B24@0:8@16 at 0x100043398, with an NSURL argument boxed by 0x100043274.
// The complete fixed shop URL is in this binary at 0x10a44eb50.
// See tools/theme-shop-evidence.json. No native theme/purchase model is edited.
static NSString * const RUINThemeShopURLString = @"line://shop/theme";
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
static const uintptr_t RUINThemeShopModeReturnPC = 0x10694677c;
static const uintptr_t RUINThemeShopObjectReturnPC = 0x10692e7dc;
static NSString *const RUINThemeShopAccountKey = @"LineAccountType";
static NSString *const RUINThemeShopModeKey = @"LineUtilUserDefaults.userDefaultEncryptionMode";

// Return PCs are the synchronous chain around ONE typed default read. The
// preflight account read at 0x10285e208 deliberately does not match this chain.
static RUINThemeShopScope RUINThemeShopClassifyFrames(const RUINThemeShopFrame *frames,
    size_t count, BOOL mode)
{
    RUINThemeShopScope none = {0};
    if (!frames || count < (mode ? 7u : 6u) || frames[0].returnPC !=
        (mode ? RUINThemeShopModeReturnPC : RUINThemeShopObjectReturnPC)) return none;
    size_t i = 1;
    uintptr_t valueFrame = frames[0].callerFrame;
    if (mode) {
        if (frames[i].returnPC != 0x10692e638) return none;
        valueFrame = frames[i++].callerFrame;
    }
    static const uintptr_t accountChain[] = {
        0x10285e8a0, 0x10285e1c0, 0x10285e440
    };
    for (size_t j = 0; j < sizeof(accountChain) / sizeof(*accountChain); j++) {
        if (i >= count || frames[i++].returnPC != accountChain[j]) return none;
    }
    if (!valueFrame || i + 1 >= count) return none;
    // StylesheetManager's injected isPrimaryAccount closure calls the same
    // AccountLevel getter synchronously. Require BOTH the verified closure
    // continuation and the exact stylesheet-save caller, in this order.
    if (frames[i].returnPC == 0x100233a38 && frames[i + 1].returnPC == 0x105df1838)
        return (RUINThemeShopScope){valueFrame, RUINThemeShopGateStylesheetPersistence};
    if (frames[i++].returnPC != 0x100753658) return none;
    if (frames[i].returnPC == 0x1003e06c8)
        return (RUINThemeShopScope){valueFrame, RUINThemeShopGateThemeAction};
    // Both the native scheme matcher and its async handler use this predicate.
    // Later actions' role checks do not have either verified router call chain.
    if ((frames[i].returnPC == 0x1003a33ac || frames[i].returnPC == 0x1003a33b8) &&
        i + 1 < count && (frames[i + 1].returnPC == 0x1003a3f88 ||
                          frames[i + 1].returnPC == 0x1003a3e00))
        return (RUINThemeShopScope){valueFrame, RUINThemeShopGateRouter};
    return none;
}

#if defined(RUIN_THEMESHOP_HOST_CHECK)
static RUINThemeShopFrame gThemeShopTestFrames[12];
static size_t gThemeShopTestFrameCount;
static uint32_t gThemeShopTestReadMode;
static RUINThemeShopScope RUINThemeShopCaptureScope(void *frame, BOOL mode)
{
    (void)frame;
    return RUINThemeShopClassifyFrames(gThemeShopTestFrames, gThemeShopTestFrameCount, mode);
}
static BOOL RUINThemeShopFrameUsesPlainMode(uintptr_t frame)
{
    return frame && gThemeShopTestReadMode == 0;
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
    return RUINThemeShopClassifyFrames(rows, count, mode);
}
static BOOL RUINThemeShopFrameUsesPlainMode(uintptr_t frame)
{
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    size_t size = pthread_get_stacksize_np(pthread_self());
    if (!top || size > top || frame < top - size + 0xb4 || frame > top) return NO;
    uint32_t mode;
    memcpy(&mode, (const void *)(frame - 0xb4), sizeof(mode));
    return mode == 0;
}
#endif

static NSInteger RUINThemeShopReadMode(id key, uintptr_t caller, void *frame, NSInteger (^readOriginal)(void))
{
    BOOL outer = gThemeShopGateDepth++ == 0;
    @try {
        NSInteger actual = readOriginal();
        if (!outer || !atomic_load(&gThemeShopGateReady) || caller != RUINThemeShopModeReturnPC ||
            ![key isKindOfClass:NSString.class] || ![key isEqual:RUINThemeShopModeKey]) return actual;
        RUINThemeShopScope scope = RUINThemeShopCaptureScope(frame, YES);
        if (!scope.kind) { atomic_fetch_add(&gThemeShopScopeMisses, 1); return actual; }
        atomic_fetch_add(&gThemeShopModeProjections, 1);
        if (scope.kind == RUINThemeShopGateStylesheetPersistence)
            atomic_fetch_add(&gThemePersistenceModeProjections, 1);
        // Native UserDefault mode 0 reads plainDefaults and CBZ at 0x10692e94c
        // skips migration. This return does not change the stored mode setting.
        return 0;
    } @finally { gThemeShopGateDepth--; }
}

static id RUINThemeShopReadAccount(id key, uintptr_t caller, void *frame, id (^readOriginal)(void))
{
    BOOL outer = gThemeShopGateDepth++ == 0;
    @try {
        id actual = readOriginal();
        if (!outer || !atomic_load(&gThemeShopGateReady) || caller != RUINThemeShopObjectReturnPC ||
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

static BOOL RUINThemeShopVerifySites(void)
{
    static const struct { uintptr_t pc; uint32_t count, words[4]; } sites[] = {
        // Verified from the supplied pristine LINE 26.16.0 arm64 executable.
        // These checks require the original TBZ and the independent validity
        // branch to remain present; no instruction or Swift closure is edited.
        {0x105df505c, 2, {0xd0fd21e3, 0x91287063}},
        {0x100233a28, 4, {0xd2800000, 0x9498ab76, 0xaa0003f4, 0x9498aa7c}},
        {0x105df1824, 4, {0xd003aa68, 0xf940a508, 0x8b080288, 0xa9405109}},
        {0x105df1834, 4, {0xd63f0120, 0x360002c0, 0xaa1803e0, 0xaa1703e1}},
        {0x105df1844, 3, {0xaa1903f4, 0x94000018, 0x36000220}},
        {0x106946774, 3, {0xaa1403e2, 0x94abda32, 0xaa0003f3}},
        {0x10692e634, 2, {0x94006042, 0xb814c3a0}},
        {0x10692e63c, 3, {0x72001c1f, 0xf81403b4, 0x540000c0}},
        {0x10692e7d4, 3, {0xaa1503e2, 0x94ac9ee2, 0xaa1d03fd}},
        {0x10692e924, 2, {0xb854c3a8, 0x12001d14}},
        {0x10692e94c, 3, {0x340000b4, 0xaa1603e0, 0xaa1803e1}},
        {0x10285e89c, 1, {0x95033ee1}}, {0x10285e1bc, 1, {0x940001aa}},
        {0x10285e43c, 3, {0x940000ff, 0x7100001f, 0x1a9f17e0}},
        {0x100753654, 2, {0x94842b74, 0x12000000}},
        {0x1003e06c0, 3, {0x52800020, 0x940dcbd2, 0xf94006c1}},
        {0x1003a33a4, 4, {0xd2800000, 0x940ec099, 0x360000a0, 0x52800020}},
        {0x1003a33b4, 2, {0x940ec096, 0x12000000}},
        {0x1003a3df4, 4, {0xa9405296, 0x97f1a542, 0xd63f02c0, 0xaa0003f6}},
        {0x1003a3f7c, 4, {0xa9405295, 0x97f1a4e0, 0xd63f02a0, 0xaa0003f5}},
        {0x10285f9c0, 3, {0xf9400008, 0xf90007e8, 0x94000045}},
        {0x10285f9e0, 1, {0x9503490a}},
        {0x106931ee4, 1, {0x94aad524}}
    };
    static const uint8_t expectedUUID[16] = {
        0x29,0x28,0x83,0xe8,0xe0,0x11,0x35,0x83,0xad,0xf5,0xf0,0x22,0x41,0xe3,0x27,0x7b
    };
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
        header->sizeofcmds > 1024 * 1024) return NO;
    gThemeShopSlide = _dyld_get_image_vmaddr_slide(0);
    const uint8_t *p = (const void *)(header + 1), *end = p + header->sizeofcmds;
    const struct segment_command_64 *text = NULL;
    BOOL uuidMatches = NO;
    for (uint32_t i = 0; i < header->ncmds && p + sizeof(struct load_command) <= end; i++) {
        const struct load_command *command = (const void *)p;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - p)) return NO;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(struct uuid_command))
            uuidMatches = memcmp(((const struct uuid_command *)command)->uuid, expectedUUID, sizeof(expectedUUID)) == 0;
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const void *)p;
            if (!strncmp(segment->segname, "__TEXT", sizeof(segment->segname))) text = segment;
        }
        p += command->cmdsize;
    }
    if (!uuidMatches || !text) return NO;
    for (size_t j = 0; j < sizeof(sites) / sizeof(*sites); j++) {
        size_t n = sites[j].count * sizeof(uint32_t);
        if (sites[j].pc < text->vmaddr || sites[j].pc - text->vmaddr > text->vmsize ||
            n > text->vmsize - (sites[j].pc - text->vmaddr) ||
            memcmp((const void *)(sites[j].pc + gThemeShopSlide), sites[j].words, n)) return NO;
    }
    return YES;
}

static void RUINThemeShopInstallGate(void)
{
    static BOOL attempted;
    if (attempted) return;
    attempted = YES;
    if (!RUINThemeShopVerifySites()) { atomic_store(&gThemeShopGateStatus, 1); return; }
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
    return @(((BOOL (*)(id, SEL))method_getImplementation(method))((id)cls, selector));
}
#endif

static BOOL RUINThemeShopTargetMatches(NSDictionary *info)
{
    BOOL originalLINE = [info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"] ||
        [info[@"CFBundleIdentifier"] isEqual:@"jp.naver.line"];
    return originalLINE && [info[@"CFBundleShortVersionString"] isEqual:@"26.16.0"] &&
        [info[@"CFBundleVersion"] isEqual:@"2026.1006.1718"];
}

void RUINInstallThemePersistenceAdapter(void)
{
#if !defined(RUIN_THEMESHOP_HOST_CHECK)
    if (RUINThemeShopTargetMatches(NSBundle.mainBundle.infoDictionary))
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

static IMP RUINThemeShopRouter(id delegate)
{
    Class cls = objc_getClass(RUINThemeShopDelegateClass);
    if (!cls || !delegate || object_getClass(delegate) != cls) return NULL;
    Method method = class_getInstanceMethod(cls, sel_registerName(RUINThemeShopSelector));
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    return types && strcmp(types, "B24@0:8@16") == 0 ? method_getImplementation(method) : NULL;
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
        default: return @"not_requested";
    }
}

static RUINThemeShopStatus RUINThemeShopDispatch(id delegate, NSDictionary *info)
{
    if (!RUINThemeShopTargetMatches(info)) return RUINThemeShopRecord(RUINThemeShopVersionGated);
    IMP router = RUINThemeShopRouter(delegate);
    if (!router) return RUINThemeShopRecord(RUINThemeShopRouterUnavailable);
#if !defined(RUIN_THEMESHOP_HOST_CHECK)
    if (!atomic_load(&gThemeShopRequests)) gThemeShopUnscopedPrimaryBefore = RUINThemeShopUnscopedPrimary();
    RUINThemeShopInstallGate();
#endif
    atomic_fetch_add(&gThemeShopRequests, 1);
    @try {
        BOOL accepted = ((BOOL (*)(id, SEL, NSURL *))router)(delegate,
            sel_registerName(RUINThemeShopSelector), [NSURL URLWithString:RUINThemeShopURLString]);
        atomic_fetch_add(accepted ? &gThemeShopAccepted : &gThemeShopRejected, 1);
        return RUINThemeShopRecord(accepted ? RUINThemeShopRouteAccepted : RUINThemeShopRouteRejected);
    } @catch (__unused NSException *exception) {
        atomic_fetch_add(&gThemeShopExceptions, 1);
        return RUINThemeShopRecord(RUINThemeShopRouterException);
    }
}

NSDictionary<NSString *, id> *RUINThemeShopDiagnostics(void)
{
    NSMutableDictionary *result = [@{
        @"targetMatches": @(RUINThemeShopTargetMatches(NSBundle.mainBundle.infoDictionary)),
        @"expectedVersion": @"26.16.0",
        @"expectedBuild": @"2026.1006.1718",
        @"fixedURL": RUINThemeShopURLString,
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
        @"gateScope": @"theme capability, ShopScheme router and StylesheetManager settings-save caller chains",
        @"gateModeProjections": @(atomic_load(&gThemeShopModeProjections)),
        @"gateRoleReadProjections": @(atomic_load(&gThemeShopRoleProjections)),
        @"gateScopeMisses": @(atomic_load(&gThemeShopScopeMisses)),
        @"stylesheetPersistence": RUINThemePersistenceDiagnostics(),
        @"storedRoleModifiedByAdapter": @NO
    } mutableCopy];
#if !defined(RUIN_THEMESHOP_HOST_CHECK)
    if (NSThread.isMainThread) {
        BOOL routerAvailable = RUINThemeShopRouter(UIApplication.sharedApplication.delegate) != NULL;
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

void RUINOpenThemeShop(UIViewController *source)
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINOpenThemeShop(source); });
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
    RUINThemeShopStatus status = RUINThemeShopDispatch(UIApplication.sharedApplication.delegate,
        NSBundle.mainBundle.infoDictionary);
    if (status == RUINThemeShopRouteAccepted) return;
    if (navigation.topViewController != visible || visible.presentedViewController || !visible.viewIfLoaded.window) return;
    NSString *message = status == RUINThemeShopVersionGated || status == RUINThemeShopRouterUnavailable
        ? @"このLINEバージョンでは着せかえショップへの移動を利用できません。"
        : @"LINEに着せかえショップの表示を要求しましたが、受け付けられませんでした。";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"着せかえショップを開けませんでした"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [visible presentViewController:alert animated:YES completion:nil];
}

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
static void RUINThemeShopTestStack(BOOL mode, RUINThemeShopGateScope kind)
{
    size_t n = 0;
    gThemeShopTestFrames[n++] = (RUINThemeShopFrame){
        mode ? RUINThemeShopModeReturnPC : RUINThemeShopObjectReturnPC, mode ? 0x1000 : 0x2000};
    if (mode) gThemeShopTestFrames[n++] = (RUINThemeShopFrame){0x10692e638, 0x2000};
    const uintptr_t pcs[] = {0x10285e8a0, 0x10285e1c0, 0x10285e440,
        kind == RUINThemeShopGateStylesheetPersistence ? 0x100233a38 : 0x100753658};
    for (size_t i = 0; i < sizeof(pcs) / sizeof(*pcs); i++)
        gThemeShopTestFrames[n++] = (RUINThemeShopFrame){pcs[i], 0x3000 + i * 0x100};
    gThemeShopTestFrames[n++] = (RUINThemeShopFrame){kind == RUINThemeShopGateThemeAction
        ? 0x1003e06c8 : kind == RUINThemeShopGateRouter ? 0x1003a33ac :
        kind == RUINThemeShopGateStylesheetPersistence ? 0x105df1838 : 0x100111111, 0x4000};
    if (kind == RUINThemeShopGateRouter)
        gThemeShopTestFrames[n++] = (RUINThemeShopFrame){0x1003a3f88, 0x5000};
    gThemeShopTestFrameCount = n;
}
static NSNumber *RUINThemeShopTestNativeRead(RUINThemeShopGateScope kind)
{
    RUINThemeShopTestStack(YES, kind);
    NSInteger rawMode = RUINThemeShopTestReadMode(nil, @selector(integerForKey:), RUINThemeShopModeKey,
        RUINThemeShopModeReturnPC, NULL);
    gThemeShopTestReadMode = rawMode >= 0 && rawMode < 3 ? (uint32_t)rawMode : 0;
    RUINThemeShopTestStack(NO, kind);
    NSNumber *value = RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
        RUINThemeShopObjectReturnPC, NULL);
    // Model the recovered CBZ: a nonzero mode may migrate the decoded value.
    // A synthesized eligibility value must never reach that writer.
    if (gThemeShopTestReadMode && value) { testNativeMigrations++; testStoredLevel = value; }
    return value;
}
static void RUINThemeShopCheckGate(void)
{
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
    gThemeShopTestFrames[gThemeShopTestFrameCount - 2].returnPC = 0x1003a33b8;
    assert(RUINThemeShopTestReadMode(nil, @selector(integerForKey:), RUINThemeShopModeKey,
        RUINThemeShopModeReturnPC, NULL) == 0);
    RUINThemeShopTestStack(NO, RUINThemeShopGateRouter);
    gThemeShopTestFrames[gThemeShopTestFrameCount - 2].returnPC = 0x1003a33b8;
    gThemeShopTestReadMode = 0;
    assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
        RUINThemeShopObjectReturnPC, NULL) isEqual:@0]);
    assert(testStoredLevel.longLongValue == 1);

    for (unsigned secondFeature = 0; secondFeature < 2; secondFeature++) {
        for (unsigned mode = 0; mode < 2; mode++) {
            RUINThemeShopTestStack(mode, RUINThemeShopGateRouter);
            gThemeShopTestFrames[gThemeShopTestFrameCount - 1].returnPC = 0x1003a3e00;
            gThemeShopTestFrames[gThemeShopTestFrameCount - 2].returnPC =
                secondFeature ? 0x1003a33b8 : 0x1003a33ac;
            gThemeShopTestReadMode = 0;
            if (mode) assert(RUINThemeShopTestReadMode(nil, @selector(integerForKey:),
                RUINThemeShopModeKey, RUINThemeShopModeReturnPC, NULL) == 0);
            else assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:),
                RUINThemeShopAccountKey, RUINThemeShopObjectReturnPC, NULL) isEqual:@0]);
            assert(testStoredLevel.longLongValue == 1 && testStoredMode == 1);
            gThemeShopTestFrames[gThemeShopTestFrameCount - 1].returnPC += 4;
            assert(!RUINThemeShopCaptureScope(NULL, mode).kind);
        }
    }

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
    assert(testStoredLevel.longLongValue == 1 && testStoredMode == 1 && testNativeMigrations == 0);

    RUINThemeShopTestStack(YES, RUINThemeShopGateThemeAction);
    assert(RUINThemeShopTestReadMode(nil, @selector(integerForKey:), @"otherModeKey",
        RUINThemeShopModeReturnPC, NULL) == 1);
    assert(RUINThemeShopTestReadMode(nil, @selector(integerForKey:), RUINThemeShopModeKey,
        RUINThemeShopModeReturnPC + 4, NULL) == 1);
    gThemeShopTestFrames[1].returnPC ^= 4;
    assert(RUINThemeShopTestReadMode(nil, @selector(integerForKey:), RUINThemeShopModeKey,
        RUINThemeShopModeReturnPC, NULL) == 1);

    RUINThemeShopTestStack(NO, RUINThemeShopGateThemeAction);
    for (size_t i = 0; i < gThemeShopTestFrameCount; i++) {
        uintptr_t old = gThemeShopTestFrames[i].returnPC;
        gThemeShopTestFrames[i].returnPC ^= 4;
        assert(!RUINThemeShopClassifyFrames(gThemeShopTestFrames, gThemeShopTestFrameCount, NO).kind);
        gThemeShopTestFrames[i].returnPC = old;
    }
    gThemeShopTestFrames[2].returnPC = 0x10285e208; // preflight read is untouched
    assert(!RUINThemeShopCaptureScope(NULL, NO).kind);
    RUINThemeShopTestStack(NO, RUINThemeShopGateRouter);
    gThemeShopTestFrameCount--; // router helper without its shop handler is insufficient
    assert(!RUINThemeShopCaptureScope(NULL, NO).kind);
    RUINThemeShopTestStack(NO, RUINThemeShopGateThemeAction);
    for (uint32_t mode = 1; mode <= 2; mode++) {
        gThemeShopTestReadMode = mode;
        assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
            RUINThemeShopObjectReturnPC, NULL) longLongValue] == 1);
    }
    gThemeShopTestReadMode = 0;
    assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), @"otherKey",
        RUINThemeShopObjectReturnPC, NULL) isEqual:@1]);
    assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
        RUINThemeShopObjectReturnPC + 4, NULL) isEqual:@1]);
    gThemeShopGateDepth = 1;
    assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
        RUINThemeShopObjectReturnPC, NULL) isEqual:@1]);
    assert(gThemeShopGateDepth == 1); gThemeShopGateDepth = 0;
    testDefaultsThrow = YES;
    @try {
        RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
            RUINThemeShopObjectReturnPC, NULL);
        assert(!"expected native defaults exception");
    } @catch (NSException *exception) { assert([exception.name isEqual:@"DefaultsProbe"]); }
    assert(!gThemeShopGateDepth); testDefaultsThrow = NO;
    atomic_store(&gThemeShopGateReady, NO);
    assert([RUINThemeShopTestReadAccount(nil, @selector(objectForKey:), RUINThemeShopAccountKey,
        RUINThemeShopObjectReturnPC, NULL) isEqual:@1]);
    puts("PASS exact native caller chains, mode-0-only primary projection, migration exclusion, unchanged stored role, reentry and exception cleanup");
}

static NSUInteger testCalls;
static BOOL testReply = YES, testThrows;
static BOOL RUINThemeShopTestRouter(id receiver, SEL selector, NSURL *url)
{
    (void)receiver; (void)selector;
    assert([url isKindOfClass:NSURL.class] && [url.absoluteString isEqual:@"line://shop/theme"]);
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
        }
        puts("PASS fixed in-process theme-shop URL, version/class/ABI gates, acceptance/rejection/exception accounting");
    }
    return 0;
}
#endif
