%config(generator=internal);

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "BundleIdentity.h"
#import "Sideload.h"
#import "AppGroupStorage.h"
#import "../core/TargetMetadata.h"
#import "../core/StartupProfiler.h"
#include <stdatomic.h>

static NSDictionary<NSString *, NSString *> *groupMap;
static atomic_uint mappedGroupRequests;
static atomic_uint mappedSuiteRequests;
static BOOL installed;
static BOOL suitesInstalled;
static BOOL preferenceDomainsInstalled;
static atomic_uint localContainerRequests;
static NSDictionary<NSString *, NSURL *> *resolvedGroupURLs;
static BOOL migrationReady;
static NSUInteger unsafeStorageCount;
static NSArray *storageBindingErrors;
static NSString *signingIdentifierSource = @"not_queried";

static BOOL RUINLineGroupIdentifier(id identifier) {
    return [identifier isKindOfClass:NSString.class] && [@[
        @"group.com.linecorp.line", @"group.com.linecorp.Line.encrypted.app",
        @"group.share.com.linecorp.line", @"group.com.linecorp.Line.encrypted.share",
        @"group.ly-app.family"
    ] containsObject:identifier];
}

static NSString *RUINMappedPreferencesDomain(NSString *name) {
    NSString *mapped = [name isKindOfClass:NSString.class] ? groupMap[name] : nil;
    if (mapped) atomic_fetch_add(&mappedSuiteRequests, 1);
    return mapped ?: name;
}

static BOOL RUINPreferencesDomainMethodsMatch(Class cls) {
    const SEL selectors[] = {@selector(persistentDomainForName:),
        @selector(setPersistentDomain:forName:), @selector(removePersistentDomainForName:)};
    const char *types[] = {"@24@0:8@16", "v32@0:8@16@24", "v24@0:8@16"};
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        Method method = cls ? class_getInstanceMethod(cls, selectors[i]) : NULL;
        const char *encoding = method ? method_getTypeEncoding(method) : NULL;
        if (!encoding || strcmp(encoding, types[i]) || !method_getImplementation(method)) return NO;
    }
    return YES;
}

static NSURL *RUINResolveGroupURL(NSFileManager *manager, NSString *identifier, NSURL *native, NSURL *support) {
    if (native || !RUINLineGroupIdentifier(identifier)) return native;
    if (!support.isFileURL) return nil;
    NSURL *root = [[support URLByAppendingPathComponent:@"RUIN/AppGroups" isDirectory:YES]
        URLByAppendingPathComponent:identifier isDirectory:YES];
    // A denied App Group has no usable source container. Keep every namespace
    // separate inside this application's sandbox; never move/delete old stores.
    if (![manager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:NULL]) return nil;
    atomic_fetch_add(&localContainerRequests, 1);
    return root;
}

#if !defined(RUIN_SIDELOAD_HOST_CHECK)
// Security exports are present in the iOS SDK's Security.tbd. The weak
// declarations keep an unavailable entitlement reader fail-closed.
typedef struct __SecTask *RUINSecTaskRef;
extern RUINSecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) __attribute__((weak_import));
extern CFTypeRef SecTaskCopyValueForEntitlement(RUINSecTaskRef task, CFStringRef entitlement,
    CFErrorRef *error) __attribute__((weak_import));
static NSString *const RUINSigningIdentifierSourceUnavailable = @"unavailable";
static NSString *const RUINSigningIdentifierSourceSecTask = @"sec_task_entitlement";
static NSString *const RUINSigningIdentifierSourceBundleInfo = @"bundle_info";
static NSString *const RUINSigningIdentifierSourceProvision = @"embedded_mobileprovision";

static NSDictionary *RUINProvisioningEntitlements(void) {
    NSURL *url = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"embedded.mobileprovision"];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data.length || data.length > 1024*1024) return nil;
    NSData *start = [@"<plist" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *end = [@"</plist>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange left = [data rangeOfData:start options:0 range:NSMakeRange(0,data.length)];
    if (left.location == NSNotFound) return nil;
    NSRange right = [data rangeOfData:end options:0 range:NSMakeRange(left.location,data.length-left.location)];
    if (right.location == NSNotFound) return nil;
    NSData *plist = [data subdataWithRange:NSMakeRange(left.location,NSMaxRange(right)-left.location)];
    id profile = [NSPropertyListSerialization propertyListWithData:plist options:NSPropertyListImmutable format:NULL error:NULL];
    id entitlements = [profile isKindOfClass:NSDictionary.class] ? profile[@"Entitlements"] : nil;
    return [entitlements isKindOfClass:NSDictionary.class] ? entitlements : nil;
}

static NSString *RUINSandboxSigningIdentifier(void) {
    if (SecTaskCreateFromSelf && SecTaskCopyValueForEntitlement) {
        RUINSecTaskRef task = SecTaskCreateFromSelf(NULL);
        if (task) {
            id identifier = CFBridgingRelease(SecTaskCopyValueForEntitlement(task, CFSTR("application-identifier"), NULL));
            CFRelease(task);
            if ([identifier isKindOfClass:NSString.class] && [identifier length]) {
                signingIdentifierSource = RUINSigningIdentifierSourceSecTask;
                return identifier;
            }
        }
    }
    id infoIdentifier = RUINActualMainBundleInfo()[@"RUINSigningApplicationIdentifier"];
    if ([infoIdentifier isKindOfClass:NSString.class] && [infoIdentifier length]) {
        signingIdentifierSource = RUINSigningIdentifierSourceBundleInfo;
        return infoIdentifier;
    }
    id provisioned = RUINProvisioningEntitlements()[@"application-identifier"];
    if ([provisioned isKindOfClass:NSString.class] && [provisioned length]) {
        signingIdentifierSource = RUINSigningIdentifierSourceProvision;
        return provisioned;
    }
    signingIdentifierSource = RUINSigningIdentifierSourceUnavailable;
    return nil;
}

static NSArray<NSString *> *RUINOriginalGroups(void) {
    return @[@"group.com.linecorp.line",@"group.com.linecorp.Line.encrypted.app",
        @"group.share.com.linecorp.line",@"group.com.linecorp.Line.encrypted.share",@"group.ly-app.family"];
}

static NSArray *RUINProfileGroups(void) {
    id groups = RUINProvisioningEntitlements()[@"com.apple.security.application-groups"];
    return [groups isKindOfClass:NSArray.class] ? groups : @[];
}

static void RUINPrepareStorageBindings(NSDictionary *requestedMap) {
    RUIN_PROFILE_BEGIN("sideload.prepare_storage");
    unsafeStorageCount = 0;
    storageBindingErrors = nil;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *support = [manager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    if (!support) { unsafeStorageCount++; RUIN_PROFILE_END(RUINProfileStatusFailed); return; }
    NSMutableSet *identifiers = [NSMutableSet setWithArray:RUINOriginalGroups()];
    RUIN_PROFILE_BEGIN("sideload.parse_provision");
    NSArray *profileGroups = RUINProfileGroups();
    RUIN_PROFILE_END(RUINProfileStatusOK);
    [identifiers addObjectsFromArray:profileGroups];
    [identifiers addObjectsFromArray:requestedMap.allValues];
    NSMutableDictionary<NSString *,NSURL *> *authorized = [NSMutableDictionary dictionary];
    // Runs before installing the FileManager hook, so these are OS-authorized
    // URLs rather than aliases projected by RUIN.
    RUIN_PROFILE_BEGIN("sideload.resolve_containers");
    for (id identifier in identifiers) {
        if (![identifier isKindOfClass:NSString.class] || ![identifier hasPrefix:@"group."] ||
            [identifier containsString:@"/"] || [identifier containsString:@".."] || [identifier length] > 255) continue;
        NSURL *url = [manager containerURLForSecurityApplicationGroupIdentifier:identifier];
        if (url.isFileURL) authorized[identifier] = url;
    }
    RUIN_PROFILE_END(RUINProfileStatusOK);
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"mid"];
    NSString *account = [value isKindOfClass:NSString.class] ? value : @"";
    NSString *signingIdentifier = RUINSandboxSigningIdentifier();
    NSMutableDictionary *URLs = [NSMutableDictionary dictionary], *suites = [NSMutableDictionary dictionary];
    NSMutableArray *errors = [NSMutableArray array];
    RUIN_PROFILE_BEGIN("sideload.resolve_groups");
    for (NSString *logical in RUINOriginalGroups()) {
        NSURL *fallback = [[support URLByAppendingPathComponent:@"RUIN/AppGroups" isDirectory:YES]
            URLByAppendingPathComponent:logical isDirectory:YES];
        NSURL *resolved = nil; NSString *suite = nil; NSError *error = nil;
        RUINAppGroupStorageDisposition disposition;
        // An existing owner pin keeps unrelated profile stores out of legacy
        // discovery. The resolver also verifies it before retaining a populated
        // sandbox over a newly introduced empty explicit target.
        NSArray *legacy = [logical isEqual:@"group.com.linecorp.line"] && account.length &&
            !RUINVerifySandboxAppGroupStorageBinding(logical, signingIdentifier, fallback, NULL)
            ? authorized.allValues : @[];
        BOOL ok = RUINResolveAppGroupStorage(logical,account,authorized[logical],fallback,signingIdentifier,
            requestedMap,authorized,legacy,&resolved,&suite,&disposition,&error);
        if (!ok || disposition == RUINAppGroupStorageDispositionUnsafe ||
            disposition == RUINAppGroupStorageDispositionLegacyMainCandidate) {
            // Keep the current sandbox available for diagnostics. The login
            // guard stops a new migration while bindings are ambiguous/denied.
            unsafeStorageCount++;
            [errors addObject:@{@"namespace":logical, @"disposition":@(disposition), @"errorCode":@(error.code)}];
            resolved = fallback;
            suite = nil;
        }
        // A fresh app-owned sandbox is usable after pinning its purpose and
        // signing owner. Never adopt unmarked old history or another identity.
        if (disposition == RUINAppGroupStorageDispositionNewFallback ||
            disposition == RUINAppGroupStorageDispositionExistingFallback) {
            if (!RUINPinSandboxAppGroupStorage(logical, signingIdentifier, resolved, &error)) {
                unsafeStorageCount++;
                [errors addObject:@{@"namespace":logical, @"disposition":@(disposition), @"errorCode":@(error.code)}];
            }
        }
        if (!resolved.isFileURL || ![manager createDirectoryAtURL:resolved withIntermediateDirectories:YES attributes:nil error:NULL]) {
            unsafeStorageCount++;
            [errors addObject:@{@"namespace":logical, @"disposition":@(disposition), @"errorCode":@(error.code)}];
            continue;
        }
        URLs[logical] = resolved;
        if (suite.length && ![suite isEqual:logical]) suites[logical] = suite;
        if (ok && disposition == RUINAppGroupStorageDispositionExplicitMap &&
            !RUINRecordExplicitAppGroupBinding(logical,suite,authorized,&error)) {
            unsafeStorageCount++;
            [errors addObject:@{@"namespace":logical, @"disposition":@(disposition),
                @"errorCode":@(error.code), @"stage":@"recordExplicitMap"}];
        }
    }
    RUIN_PROFILE_END(RUINProfileStatusOK);
    storageBindingErrors = [errors copy];
    resolvedGroupURLs = [URLs copy];
    groupMap = [suites copy];
    RUIN_PROFILE_END(RUINProfileStatusOK);
}

%group RUINAppGroupMapping
%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier
{
    NSURL *resolved = [identifier isKindOfClass:NSString.class] ? resolvedGroupURLs[identifier] : nil;
    if (resolved) {
        if (groupMap[identifier]) atomic_fetch_add(&mappedGroupRequests,1);
        return resolved;
    }
    NSString *mapped = [identifier isKindOfClass:NSString.class] ? groupMap[identifier] : nil;
    if (mapped) atomic_fetch_add(&mappedGroupRequests, 1);
    NSURL *native = %orig(mapped ?: identifier);
    if (native || !RUINLineGroupIdentifier(identifier)) return native;
    NSURL *support = [self URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return RUINResolveGroupURL(self, identifier, native, support);
}
%end
%end

%group RUINPreferencesSuiteMapping
%hook NSUserDefaults
- (instancetype)initWithSuiteName:(NSString *)name
{
    return %orig(RUINMappedPreferencesDomain(name));
}
%end
%end

%group RUINPreferencesDomainMapping
%hook NSUserDefaults
- (NSDictionary *)persistentDomainForName:(NSString *)name
{
    return %orig(RUINMappedPreferencesDomain(name));
}
- (void)setPersistentDomain:(NSDictionary *)domain forName:(NSString *)name
{
    %orig(domain, RUINMappedPreferencesDomain(name));
}
- (void)removePersistentDomainForName:(NSString *)name
{
    %orig(RUINMappedPreferencesDomain(name));
}
%end
%end

void RUINInstallCompatibility(void) {
    if (installed && migrationReady) return;
    // Generic injectors need not supply RUIN's optional signing metadata.
    // Identity may not resolve in this dylib's early constructor. Keep hook
    // installation one-time while allowing storage preparation to retry.
    @synchronized (NSProcessInfo.processInfo) {
        if (installed && migrationReady) return;
        RUINInstallBundleIdentity();
        NSString *status = RUINBundleIdentityDiagnostics()[@"status"];
        if (![@[@"installed", @"already_original"] containsObject:status]) return;
        if (!RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary)) return;

        NSDictionary *info = RUINActualMainBundleInfo();
        id mapping = info[@"RUINAppGroupMap"];
        if (![mapping isKindOfClass:NSDictionary.class]) mapping = @{};
        NSMutableDictionary *validated = [NSMutableDictionary dictionary];
        for (id key in mapping) {
            if ([key isKindOfClass:NSString.class] && [mapping[key] isKindOfClass:NSString.class] && [mapping[key] length])
                validated[key] = mapping[key];
        }
        if (!migrationReady) {
            RUINPrepareStorageBindings(validated);
            migrationReady = !unsafeStorageCount && resolvedGroupURLs.count == RUINOriginalGroups().count;
        }
        static BOOL hooksInstalled = NO;
        if (!hooksInstalled) {
            Method method = class_getInstanceMethod(NSFileManager.class,
                @selector(containerURLForSecurityApplicationGroupIdentifier:));
            if (!method || strcmp(method_getTypeEncoding(method), "@24@0:8@16")) return;
            %init(RUINAppGroupMapping);
            hooksInstalled = YES;
            installed = YES;
        }
        if (!suitesInstalled) {
            Method suite = class_getInstanceMethod(NSUserDefaults.class, @selector(initWithSuiteName:));
            if (groupMap.count && suite && !strcmp(method_getTypeEncoding(suite), "@24@0:8@16")) {
                %init(RUINPreferencesSuiteMapping);
                suitesInstalled = YES;
            }
        }
        // A missing domain API must not disable the existing suite-init mapping.
        if (suitesInstalled && !preferenceDomainsInstalled && RUINPreferencesDomainMethodsMatch(NSUserDefaults.class)) {
            %init(RUINPreferencesDomainMapping);
            preferenceDomainsInstalled = YES;
        }
    }
}
#endif

NSDictionary *RUINCompatibilityDiagnostics(void) {
    return @{@"appGroupMappingInstalled": @(installed),
             @"appGroupMappingCount": @(groupMap.count),
             @"mappedAppGroupRequests": @(atomic_load(&mappedGroupRequests)),
             @"localAppGroupFallbackRequests": @(atomic_load(&localContainerRequests)),
             @"appGroupPreferencesMappingInstalled": @(suitesInstalled),
             @"appGroupPreferencesDomainMappingInstalled": @(preferenceDomainsInstalled),
             @"mappedPreferencesRequests": @(atomic_load(&mappedSuiteRequests)),
             @"storageMigrationReady":@(migrationReady), @"unsafeStorageBindings":@(unsafeStorageCount),
             @"resolvedStorageNamespaces":@(resolvedGroupURLs.count), @"storageBindingErrors":storageBindingErrors ?: @[],
             @"signingIdentifierSource":signingIdentifierSource ?: @"not_queried"};
}

BOOL RUINStorageMigrationReady(void) { return migrationReady; }

#if !defined(RUIN_SIDELOAD_HOST_CHECK)
__attribute__((constructor)) static void RUINPrepareSideload(void) {
    @autoreleasepool { RUINInstallCompatibility(); }
}
#else
#import <assert.h>
int main(void) { @autoreleasepool {
    groupMap = @{@"group.com.linecorp.line":@"group.fixture.authorized"};
    assert([RUINMappedPreferencesDomain(@"group.com.linecorp.line") isEqual:@"group.fixture.authorized"]);
    for (NSString *name in @[@"jp.naver.line", @"group.fixture.authorized", @"group.unrelated",
        @"group.com.linecorp.line.extra", @"NSGlobalDomain", @"com.apple.fixture"]) {
        assert(RUINMappedPreferencesDomain(name) == name);
    }
    assert(RUINMappedPreferencesDomain(nil) == nil);
    assert(RUINPreferencesDomainMethodsMatch(NSUserDefaults.class));
    assert(!RUINPreferencesDomainMethodsMatch(NSObject.class));
    assert(!RUINPreferencesDomainMethodsMatch(Nil));
    groupMap = nil;
    assert([RUINMappedPreferencesDomain(@"group.com.linecorp.line") isEqual:@"group.com.linecorp.line"]);
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *support = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSURL *native = [support URLByAppendingPathComponent:@"native" isDirectory:YES];
    assert(RUINResolveGroupURL(manager,@"group.com.linecorp.line",native,support) == native);
    assert(![manager fileExistsAtPath:support.path]);
    assert(!RUINResolveGroupURL(manager,@"group.other.app",nil,support));
    assert(![manager fileExistsAtPath:support.path]);
    NSURL *one = RUINResolveGroupURL(manager,@"group.com.linecorp.line",nil,support);
    NSURL *two = RUINResolveGroupURL(manager,@"group.com.linecorp.Line.encrypted.app",nil,support);
    assert(one && two && ![one isEqual:two]);
    NSURL *marker = [one URLByAppendingPathComponent:@"existing-store"];
    NSData *data = [@"keep" dataUsingEncoding:NSUTF8StringEncoding];
    assert([data writeToURL:marker atomically:YES]);
    assert([RUINResolveGroupURL(manager,@"group.com.linecorp.line",nil,support) isEqual:one]);
    assert([[NSData dataWithContentsOfURL:marker] isEqual:data]);
    [manager removeItemAtURL:support error:NULL];
    puts("PASS native group containers preserved; denied LINE groups isolated locally; no unknown groups or data deletion");
} }
#endif
