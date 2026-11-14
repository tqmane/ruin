%config(generator=internal);

#import "BundleIdentity.h"
#import "BinaryVerifier.h"
#import "TargetMetadata.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <string.h>

static NSString *const originalIdentifier = @"jp.naver.line";
static NSString *const identifierKey = @"CFBundleIdentifier";
static NSBundle *identityMainBundle;
static NSDictionary *actualMainInfo;
static const void *lineImage, *ruinImage;
static atomic_bool identityReady;
static atomic_uint_fast64_t identifierReads, valueReads, dictionaryReads, cfReads, lineReads;
static NSString *identityStatus = @"not_requested";
static NSString *cfBindingStatus = @"NotAttempted";
static BOOL cfBindingInstalled;
static BOOL verifiedBinary;
static NSString *mainPreferenceIdentifier;
static BOOL mainPreferencesInstalled;
static NSString *mainPreferencesStatus = @"not_requested";

typedef NS_ENUM(NSInteger, RUINCFBindingPlan) {
    RUINCFBindingPlanNativePassthrough = 0,
    RUINCFBindingPlanRebind,
    RUINCFBindingPlanUnsupportedAuthenticatedImports
};

#if !defined(RUIN_BUNDLE_IDENTITY_HOST_CHECK)
static BOOL RUINUsesAuthenticatedImports(void) {
#if defined(__arm64e__)
    return YES;
#else
    return NO;
#endif
}
#endif

static RUINCFBindingPlan RUINCFBindingPlanFor(BOOL needsProjection, BOOL authenticatedImports) {
    if (!needsProjection) return RUINCFBindingPlanNativePassthrough;
    return authenticatedImports ? RUINCFBindingPlanUnsupportedAuthenticatedImports
                                : RUINCFBindingPlanRebind;
}

static NSString *RUINCFBindingStatusForPlan(RUINCFBindingPlan plan) {
    switch (plan) {
        case RUINCFBindingPlanNativePassthrough: return @"NativePassthrough";
        case RUINCFBindingPlanUnsupportedAuthenticatedImports: return @"UnsupportedAuthenticatedImports";
        case RUINCFBindingPlanRebind: return @"Rebind";
    }
    return @"Unavailable";
}

static BOOL IdentityBinaryMatches(const struct mach_header_64 *header, NSDictionary *info) {
#if defined(RUIN_BUNDLE_IDENTITY_HOST_CHECK)
    const RUINVersionMapping *mapping = RUINMappingForInfo(info);
#else
    const RUINVersionMapping *mapping = RUINCurrentMapping();
#endif
    id version = info[@"CFBundleShortVersionString"], build = info[@"CFBundleVersion"];
    return mapping && [version isKindOfClass:NSString.class] && [build isKindOfClass:NSString.class] &&
        [version isEqualToString:@(mapping->host.version)] &&
        [build isEqualToString:@(mapping->host.build)] && RUINVerifyHostImage(&mapping->host, header);
}

static BOOL IdentityScope(NSBundle *bundle, const void *image) {
    return atomic_load(&identityReady) && bundle == identityMainBundle && image &&
        (image == lineImage || image == ruinImage);
}

static id IdentityValue(BOOL scoped, NSString *key, id actual) {
    return scoped && [key isEqual:identifierKey] && [actual isKindOfClass:NSString.class]
        ? originalIdentifier : actual;
}

static NSDictionary *IdentityDictionary(BOOL scoped, NSDictionary *actual) {
    if (!scoped || ![actual[identifierKey] isKindOfClass:NSString.class] ||
        [actual[identifierKey] isEqual:originalIdentifier]) return actual;
    NSMutableDictionary *copy = [actual mutableCopy];
    copy[identifierKey] = originalIdentifier;
    return [copy copy];
}

NSDictionary *RUINActualMainBundleInfo(void) {
    // Captured before installation. Signing and keychain consumers must use
    // this view, rather than the identity projected to application code.
    return actualMainInfo ?: NSBundle.mainBundle.infoDictionary ?: @{};
}

NSDictionary *RUINBundleIdentityDiagnostics(void) {
    return @{@"status":identityStatus, @"installed":@(atomic_load(&identityReady)),
        @"verifiedBinary":@(verifiedBinary),
        @"actualSignedIdentifier":RUINActualMainBundleInfo()[identifierKey] ?: (id)NSNull.null,
        @"applicationIdentifier":originalIdentifier,
        @"bundleIdentifierReads":@(atomic_load(&identifierReads)),
        @"infoValueReads":@(atomic_load(&valueReads)),
        @"infoDictionaryReads":@(atomic_load(&dictionaryReads)),
        @"cfInfoDictionaryReads":@(atomic_load(&cfReads)),
        @"lineCallerReads":@(atomic_load(&lineReads)),
        @"cfMainImageBinding":@(cfBindingInstalled), @"cfBindingStatus":cfBindingStatus,
        @"mainPreferenceDomainAlias":mainPreferencesStatus,
        @"mainPreferenceDomainAliasInstalled":@(mainPreferencesInstalled),
        @"signingMetadataChanged":@NO, @"scope":@"main bundle; verified LINE and RUIN callers only"};
}

static BOOL IdentityCaller(NSBundle *bundle, void *address) {
    Dl_info caller;
    if (bundle != identityMainBundle || !dladdr(address, &caller) ||
        !IdentityScope(bundle, caller.dli_fbase)) return NO;
    if (caller.dli_fbase == lineImage) atomic_fetch_add(&lineReads, 1);
    return YES;
}

static NSString *IdentityPreferenceName(id defaults, NSString *name, BOOL scoped) {
    return scoped && mainPreferencesInstalled && [name isEqual:originalIdentifier] &&
        defaults == NSUserDefaults.standardUserDefaults ? mainPreferenceIdentifier : name;
}

%group RUINMainPreferenceIdentity
%hook RUINIdentityDefaults
__attribute__((noinline, disable_tail_calls))
- (NSDictionary *)persistentDomainForName:(NSString *)name {
    return %orig(IdentityPreferenceName(self, name, IdentityCaller(identityMainBundle,
        __builtin_extract_return_addr(__builtin_return_address(0)))));
}
__attribute__((noinline, disable_tail_calls))
- (void)setPersistentDomain:(NSDictionary *)domain forName:(NSString *)name {
    %orig(domain, IdentityPreferenceName(self, name, IdentityCaller(identityMainBundle,
        __builtin_extract_return_addr(__builtin_return_address(0)))));
}
__attribute__((noinline, disable_tail_calls))
- (void)removePersistentDomainForName:(NSString *)name {
    %orig(IdentityPreferenceName(self, name, IdentityCaller(identityMainBundle,
        __builtin_extract_return_addr(__builtin_return_address(0)))));
}
%end
%end

static void IdentityInstallMainPreferences(Class cls, BOOL lcGuestDomain) {
    if (mainPreferencesInstalled) return;
    if (lcGuestDomain) { mainPreferencesStatus = @"live_container_owned"; return; }
    id actual = actualMainInfo[identifierKey];
    if (![actual isKindOfClass:NSString.class] || ![actual length] || [actual isEqual:originalIdentifier]) {
        mainPreferencesStatus = @"native_passthrough"; return;
    }
    if (!atomic_load(&identityReady) || !verifiedBinary) return;
    const SEL selectors[] = {@selector(persistentDomainForName:), @selector(setPersistentDomain:forName:),
        @selector(removePersistentDomainForName:)};
    const char *types[] = {"@24@0:8@16", "v32@0:8@16@24", "v24@0:8@16"};
    for (unsigned i = 0; i < 3; i++) {
        Method method = cls ? class_getInstanceMethod(cls, selectors[i]) : NULL;
        if (!method || strcmp(method_getTypeEncoding(method), types[i]) || !method_getImplementation(method)) {
            mainPreferencesStatus = @"preferences_abi_mismatch"; return;
        }
    }
    mainPreferenceIdentifier = [actual copy];
    %init(RUINMainPreferenceIdentity, RUINIdentityDefaults=cls);
    mainPreferencesInstalled = YES;
    mainPreferencesStatus = @"installed";
}

#if !defined(RUIN_BUNDLE_IDENTITY_HOST_CHECK)
#import "fishhook.h"

%group RUINBundleIdentity
%hook RUINIdentityBundle
__attribute__((noinline, disable_tail_calls))
- (NSString *)bundleIdentifier {
    NSString *actual = %orig;
    BOOL scoped = IdentityCaller(self, __builtin_extract_return_addr(__builtin_return_address(0)));
    if (scoped) atomic_fetch_add(&identifierReads, 1);
    return IdentityValue(scoped, identifierKey, actual);
}
__attribute__((noinline, disable_tail_calls))
- (id)objectForInfoDictionaryKey:(NSString *)key {
    id actual = %orig;
    BOOL scoped = [key isEqual:identifierKey] && IdentityCaller(self,
        __builtin_extract_return_addr(__builtin_return_address(0)));
    if (scoped) atomic_fetch_add(&valueReads, 1);
    return IdentityValue(scoped, key, actual);
}
__attribute__((noinline, disable_tail_calls))
- (NSDictionary *)infoDictionary {
    NSDictionary *actual = %orig;
    BOOL scoped = IdentityCaller(self, __builtin_extract_return_addr(__builtin_return_address(0)));
    if (scoped) atomic_fetch_add(&dictionaryReads, 1);
    return IdentityDictionary(scoped, actual);
}
%end
%end

// LINE imports this public C API directly. Internal Logos cannot %hookf;
// fishhook changes only the verified main image's import, never executable code.
static CFDictionaryRef (*originalCFInfo)(CFBundleRef);
__attribute__((noinline, disable_tail_calls))
static CFDictionaryRef IdentityCFInfo(CFBundleRef bundle) {
    CFDictionaryRef actual = originalCFInfo ? originalCFInfo(bundle) : NULL;
    if (!actual || bundle != CFBundleGetMainBundle() ||
        !IdentityCaller(identityMainBundle, __builtin_extract_return_addr(__builtin_return_address(0)))) return actual;
    atomic_fetch_add(&cfReads, 1);
    // Get-rule lifetime: main bundle metadata is immutable; retain its single
    // projected copy for the lifetime of the process, without changing CF's cache.
    static NSDictionary *projection;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ projection = IdentityDictionary(YES, (__bridge NSDictionary *)actual); });
    return (__bridge CFDictionaryRef)projection;
}

void RUINInstallBundleIdentity(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *info = [bundle.infoDictionary copy] ?: @{};
    if (![info[identifierKey] isKindOfClass:NSString.class]) {
        identityStatus = @"missing_identity";
        return;
    }
    BOOL alreadyOriginal = [info[identifierKey] isEqual:originalIdentifier];
    BOOL metadataValid = RUINTargetMetadataMatchesInfo(info);
    RUINCFBindingPlan cfPlan = RUINCFBindingPlanFor(!alreadyOriginal, RUINUsesAuthenticatedImports());
    RUINMainExecutableImage image;
    BOOL mainResolved = RUINResolveMainExecutableImage(&image);
    const struct mach_header_64 *header = mainResolved ? image.header : NULL;
    BOOL imageMatches = mainResolved && IdentityBinaryMatches(header, info);
    if (!alreadyOriginal && !imageMatches) {
        identityStatus = header ? @"unsupported_binary" : @"mapping_unavailable";
        return;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        identityMainBundle = bundle;
        actualMainInfo = info;
        verifiedBinary = imageMatches;
        // No projection is needed for the original identity. Keep public API
        // compatibility available on new builds; private code maps stay gated.
        if (alreadyOriginal && metadataValid) {
            cfBindingStatus = RUINCFBindingStatusForPlan(cfPlan);
            identityStatus = @"already_original";
            return;
        }
        if (!verifiedBinary) { identityStatus = @"unsupported_binary"; return; }
        Class cls = object_getClass(identityMainBundle);
        const SEL selectors[] = {@selector(bundleIdentifier), @selector(objectForInfoDictionaryKey:), @selector(infoDictionary)};
        const char *types[] = {"@16@0:8", "@24@0:8@16", "@16@0:8"};
        for (unsigned i = 0; i < 3; i++) {
            Method method = class_getInstanceMethod(cls, selectors[i]);
            if (!method || strcmp(method_getTypeEncoding(method), types[i]) || !method_getImplementation(method)) {
                identityStatus = @"bundle_abi_mismatch"; return;
            }
        }
        Dl_info own;
        if (!dladdr((const void *)RUINInstallBundleIdentity, &own)) { identityStatus = @"own_image_missing"; return; }
        lineImage = header;
        ruinImage = own.dli_fbase;
        %init(RUINBundleIdentity, RUINIdentityBundle=cls);
        if (cfPlan == RUINCFBindingPlanUnsupportedAuthenticatedImports) {
            // Keep the Objective-C identity hooks; only the C import projection is unavailable.
            cfBindingStatus = RUINCFBindingStatusForPlan(cfPlan);
            atomic_store(&identityReady, YES);
            identityStatus = @"installed";
            IdentityInstallMainPreferences(NSUserDefaults.class,
                class_getClassMethod(NSUserDefaults.class, sel_registerName("lcGuestAppId")) != NULL);
            return;
        }
        struct rebinding binding = {"CFBundleGetInfoDictionary", (void *)IdentityCFInfo, (void **)&originalCFInfo};
        int result = rebind_symbols_image((void *)header, image.slide, &binding, 1);
        cfBindingInstalled = result == 0 && originalCFInfo;
        cfBindingStatus = cfBindingInstalled ? @"Installed" : @"Unavailable";
        if (!cfBindingInstalled) { identityStatus = @"cf_binding_unavailable"; return; }
        atomic_store(&identityReady, YES);
        identityStatus = @"installed";
        IdentityInstallMainPreferences(NSUserDefaults.class,
            class_getClassMethod(NSUserDefaults.class, sel_registerName("lcGuestAppId")) != NULL);
    });
}
#else
#import <assert.h>
@interface RUINIdentityTestDefaults : NSObject
@property(nonatomic, strong) NSMutableDictionary *domains;
@property(nonatomic, copy) NSString *lastDomain;
@property(nonatomic) NSUInteger reads, writes, removes;
- (NSDictionary *)persistentDomainForName:(NSString *)name;
- (void)setPersistentDomain:(NSDictionary *)domain forName:(NSString *)name;
- (void)removePersistentDomainForName:(NSString *)name;
@end
@implementation RUINIdentityTestDefaults
- (instancetype)init { if ((self=[super init])) _domains=[NSMutableDictionary dictionary]; return self; }
- (NSDictionary *)persistentDomainForName:(NSString *)name { self.reads++; self.lastDomain=name; return self.domains[name]; }
- (void)setPersistentDomain:(NSDictionary *)domain forName:(NSString *)name { self.writes++; self.lastDomain=name; self.domains[name]=domain; }
- (void)removePersistentDomainForName:(NSString *)name { self.removes++; self.lastDomain=name; [self.domains removeObjectForKey:name]; }
@end
static RUINIdentityTestDefaults *identityTestStandard;
%group RUINIdentityTestStandardProvider
%hook RUINIdentityTestDefaultsProvider
+ (NSUserDefaults *)standardUserDefaults { return (id)identityTestStandard; }
%end
%end

static void IdentityCheckMainPreferences(void) {
    identityTestStandard=[RUINIdentityTestDefaults new];
    %init(RUINIdentityTestStandardProvider, RUINIdentityTestDefaultsProvider=NSUserDefaults.class);
    Dl_info caller;
    assert(dladdr((const void *)IdentityCheckMainPreferences, &caller));
    lineImage=caller.dli_fbase; ruinImage=(void *)1;
    atomic_store(&identityReady, YES); verifiedBinary=YES;
    IdentityInstallMainPreferences(RUINIdentityTestDefaults.class, YES);
    assert(!mainPreferencesInstalled && [mainPreferencesStatus isEqual:@"live_container_owned"] && atomic_load(&identityReady));
    NSDictionary *saved=actualMainInfo;
    actualMainInfo=@{identifierKey:originalIdentifier};
    IdentityInstallMainPreferences(RUINIdentityTestDefaults.class, NO);
    assert(!mainPreferencesInstalled && [mainPreferencesStatus isEqual:@"native_passthrough"]);
    actualMainInfo=saved;
    IdentityInstallMainPreferences(NSObject.class, NO);
    assert(!mainPreferencesInstalled && atomic_load(&identityReady));
    const SEL selectors[]={@selector(persistentDomainForName:),@selector(setPersistentDomain:forName:),@selector(removePersistentDomainForName:)};
    const char *wrong[]={"v24@0:8@16","@32@0:8@16@24","@24@0:8@16"};
    for (unsigned bad=0;bad<3;bad++) {
        Class cls=objc_allocateClassPair(NSObject.class, [[NSString stringWithFormat:@"RUINIdentityBadDefaults%u",bad] UTF8String],0);
        assert(cls);
        for (unsigned i=0;i<3;i++) {
            Method method=class_getInstanceMethod(RUINIdentityTestDefaults.class,selectors[i]);
            assert(class_addMethod(cls,selectors[i],method_getImplementation(method),bad==i ? wrong[i] : method_getTypeEncoding(method)));
        }
        objc_registerClassPair(cls);
        IdentityInstallMainPreferences(cls,NO);
        assert(!mainPreferencesInstalled && atomic_load(&identityReady) && [mainPreferencesStatus isEqual:@"preferences_abi_mismatch"]);
    }
    IdentityInstallMainPreferences(RUINIdentityTestDefaults.class, NO);
    IdentityInstallMainPreferences(RUINIdentityTestDefaults.class, NO); // No second Logos replacement.
    assert(mainPreferencesInstalled && [mainPreferenceIdentifier isEqual:@"example.signed.line"]);
    NSDictionary *value=@{@"fixture":@YES};
    RUINIdentityTestDefaults *defaults=identityTestStandard, *suite=[RUINIdentityTestDefaults new];
    [defaults setPersistentDomain:value forName:originalIdentifier];
    assert(defaults.writes==1 && [defaults.lastDomain isEqual:mainPreferenceIdentifier]);
    assert([defaults persistentDomainForName:originalIdentifier]==value && defaults.reads==1);
    [defaults removePersistentDomainForName:originalIdentifier];
    assert(defaults.removes==1 && [defaults.lastDomain isEqual:mainPreferenceIdentifier] && !defaults.domains.count);
    lineImage=(void *)1; ruinImage=caller.dli_fbase; // Chained RUIN forwarding is in scope too.
    [defaults setPersistentDomain:value forName:originalIdentifier];
    assert(defaults.writes==2 && [defaults.lastDomain isEqual:mainPreferenceIdentifier]);
    lineImage=(void *)1; ruinImage=(void *)2;
    [defaults setPersistentDomain:value forName:originalIdentifier];
    assert(defaults.writes==3 && [defaults.lastDomain isEqual:originalIdentifier]);
    assert([defaults persistentDomainForName:originalIdentifier]==value && defaults.reads==2);
    [defaults removePersistentDomainForName:originalIdentifier];
    assert(defaults.removes==2 && [defaults.lastDomain isEqual:originalIdentifier]);
    lineImage=caller.dli_fbase;
    [suite setPersistentDomain:value forName:originalIdentifier];
    assert(suite.writes==1 && [suite.lastDomain isEqual:originalIdentifier]);
    for (NSString *name in @[@"group.com.linecorp.line",@"other.application",@"jp.naver.line.extra"]) {
        NSUInteger reads=defaults.reads,writes=defaults.writes,removes=defaults.removes;
        [defaults setPersistentDomain:value forName:name];
        assert([defaults persistentDomainForName:name]==value);
        [defaults removePersistentDomainForName:name];
        assert([defaults.lastDomain isEqual:name] && defaults.reads==reads+1 && defaults.writes==writes+1 && defaults.removes==removes+1);
    }
    atomic_store(&identityReady,NO);
    [defaults setPersistentDomain:value forName:originalIdentifier];
    assert([defaults.lastDomain isEqual:originalIdentifier]);
    puts("PASS main preference alias: generated get/set/remove original once; standard-only; LINE/RUIN scope; LC/native/ABI isolation");
}
void RUINInstallBundleIdentity(void) {}
int main(void) {
    @autoreleasepool {
        RUINCFBindingPlan nativeArm64ePlan = RUINCFBindingPlanFor(NO, YES);
        RUINCFBindingPlan renamedArm64ePlan = RUINCFBindingPlanFor(YES, YES);
        RUINCFBindingPlan renamedArm64Plan = RUINCFBindingPlanFor(YES, NO);
        assert(nativeArm64ePlan == RUINCFBindingPlanNativePassthrough);
        assert([RUINCFBindingStatusForPlan(nativeArm64ePlan) isEqual:@"NativePassthrough"]);
        assert(renamedArm64ePlan == RUINCFBindingPlanUnsupportedAuthenticatedImports);
        assert([RUINCFBindingStatusForPlan(renamedArm64ePlan) isEqual:@"UnsupportedAuthenticatedImports"]);
        assert(renamedArm64Plan == RUINCFBindingPlanRebind);

        actualMainInfo = @{identifierKey:@"example.signed.line", @"RUINOriginalBundleIdentifier":originalIdentifier,
            @"CFBundleVersion":@"2026.1006.1718",
            @"CFBundleShortVersionString":@"26.16.0", @"unchanged":@"value"};
        struct { struct mach_header_64 header; struct uuid_command uuid; } image = {0};
        image.header = (struct mach_header_64){.magic=MH_MAGIC_64, .cputype=CPU_TYPE_ARM64,
            .filetype=MH_EXECUTE, .ncmds=1, .sizeofcmds=sizeof(image.uuid)};
        image.uuid.cmd = LC_UUID; image.uuid.cmdsize = sizeof(image.uuid);
        const uint8_t uuid[] = {0x29,0x28,0x83,0xe8,0xe0,0x11,0x35,0x83,0xad,0xf5,0xf0,0x22,0x41,0xe3,0x27,0x7b};
        memcpy(image.uuid.uuid, uuid, sizeof(uuid));
        assert(IdentityBinaryMatches(&image.header, actualMainInfo));
        NSMutableDictionary *nativeInfo = [actualMainInfo mutableCopy];
        nativeInfo[identifierKey] = originalIdentifier;
        assert(IdentityBinaryMatches(&image.header, nativeInfo));
        assert(RUINTargetMetadataMatchesInfo(nativeInfo)); // Native CF plan returns before ObjC installation.
        nativeInfo[@"CFBundleVersion"] = @"unknown";
        assert(!RUINTargetMetadataMatchesInfo(nativeInfo));
        assert(!IdentityBinaryMatches(&image.header, nativeInfo));
        image.uuid.uuid[0] ^= 1;
        assert(!IdentityBinaryMatches(&image.header, actualMainInfo));
        image.uuid.uuid[0] ^= 1;
        NSMutableDictionary *wrong = [actualMainInfo mutableCopy]; wrong[@"CFBundleVersion"] = @"unknown";
        assert(!IdentityBinaryMatches(&image.header, wrong));
        wrong[@"CFBundleVersion"] = @"2026.1006.1718"; wrong[@"CFBundleShortVersionString"] = @"26.15.0";
        assert(!IdentityBinaryMatches(&image.header, wrong));
        identityMainBundle = NSBundle.mainBundle;
        lineImage = &image; ruinImage = &uuid;
        atomic_store(&identityReady, YES);
        assert(IdentityScope(identityMainBundle, lineImage));
        assert(IdentityScope(identityMainBundle, ruinImage));
        assert(!IdentityScope(identityMainBundle, (void *)1));
        NSBundle *otherBundle = [NSBundle bundleForClass:NSObject.class];
        assert(otherBundle != identityMainBundle && !IdentityScope(otherBundle, lineImage));
        assert(!IdentityScope(nil, lineImage));
        assert([IdentityValue(YES, identifierKey, @"example.signed.line") isEqual:originalIdentifier]);
        assert([IdentityValue(NO, identifierKey, @"example.signed.line") isEqual:@"example.signed.line"]);
        NSNumber *unchanged = @7;
        assert(IdentityValue(YES, @"other", unchanged) == unchanged);
        assert(IdentityValue(YES, identifierKey, nil) == nil);
        NSDictionary *projected = IdentityDictionary(YES, actualMainInfo);
        assert([projected[identifierKey] isEqual:originalIdentifier]);
        assert([projected[@"unchanged"] isEqual:@"value"]);
        assert([RUINActualMainBundleInfo()[identifierKey] isEqual:@"example.signed.line"]);
        assert(IdentityDictionary(NO, actualMainInfo) == actualMainInfo);
        atomic_store(&identityReady, NO);
        assert(!IdentityScope(identityMainBundle, lineImage));
        IdentityCheckMainPreferences();
        puts("PASS original bundle identity projection, raw signing view, caller/bundle isolation and binary gates");
    }
}
#endif
