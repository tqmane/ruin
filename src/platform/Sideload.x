%config(generator=internal);

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "BundleIdentity.h"
#import "Sideload.h"
#import "AppGroupStorage.h"
#import "../core/TargetMetadata.h"
#include <stdatomic.h>

static NSDictionary<NSString *, NSString *> *groupMap;
static atomic_uint mappedGroupRequests;
static atomic_uint mappedSuiteRequests;
static BOOL installed;
static BOOL suitesInstalled;
static atomic_uint localContainerRequests;
static NSDictionary<NSString *, NSURL *> *resolvedGroupURLs;
static BOOL migrationReady;
static NSUInteger unsafeStorageCount;

static BOOL RUINLineGroupIdentifier(id identifier) {
    return [identifier isKindOfClass:NSString.class] && [@[
        @"group.com.linecorp.line", @"group.com.linecorp.Line.encrypted.app",
        @"group.share.com.linecorp.line", @"group.com.linecorp.Line.encrypted.share",
        @"group.ly-app.family"
    ] containsObject:identifier];
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
static NSArray<NSString *> *RUINOriginalGroups(void) {
    return @[@"group.com.linecorp.line",@"group.com.linecorp.Line.encrypted.app",
        @"group.share.com.linecorp.line",@"group.com.linecorp.Line.encrypted.share",@"group.ly-app.family"];
}

static NSArray *RUINProfileGroups(void) {
    NSURL *url = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"embedded.mobileprovision"];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data.length || data.length > 1024*1024) return @[];
    NSData *start = [@"<plist" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *end = [@"</plist>" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange left = [data rangeOfData:start options:0 range:NSMakeRange(0,data.length)];
    if (left.location == NSNotFound) return @[];
    NSRange right = [data rangeOfData:end options:0 range:NSMakeRange(left.location,data.length-left.location)];
    if (right.location == NSNotFound) return @[];
    NSData *plist = [data subdataWithRange:NSMakeRange(left.location,NSMaxRange(right)-left.location)];
    id profile = [NSPropertyListSerialization propertyListWithData:plist options:NSPropertyListImmutable format:NULL error:NULL];
    id entitlements = [profile isKindOfClass:NSDictionary.class] ? profile[@"Entitlements"] : nil;
    id groups = [entitlements isKindOfClass:NSDictionary.class] ? entitlements[@"com.apple.security.application-groups"] : nil;
    return [groups isKindOfClass:NSArray.class] ? groups : @[];
}

static void RUINPrepareStorageBindings(NSDictionary *requestedMap) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *support = [manager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    if (!support) { unsafeStorageCount++; return; }
    NSMutableSet *identifiers = [NSMutableSet setWithArray:RUINOriginalGroups()];
    [identifiers addObjectsFromArray:RUINProfileGroups()];
    [identifiers addObjectsFromArray:requestedMap.allValues];
    NSMutableDictionary<NSString *,NSURL *> *authorized = [NSMutableDictionary dictionary];
    // Runs before installing the FileManager hook, so these are OS-authorized
    // URLs rather than aliases projected by RUIN.
    for (id identifier in identifiers) {
        if (![identifier isKindOfClass:NSString.class] || ![identifier hasPrefix:@"group."] ||
            [identifier containsString:@"/"] || [identifier containsString:@".."] || [identifier length] > 255) continue;
        NSURL *url = [manager containerURLForSecurityApplicationGroupIdentifier:identifier];
        if (url.isFileURL) authorized[identifier] = url;
    }
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"mid"];
    NSString *account = [value isKindOfClass:NSString.class] ? value : @"";
    NSMutableDictionary *URLs = [NSMutableDictionary dictionary], *suites = [NSMutableDictionary dictionary];
    for (NSString *logical in RUINOriginalGroups()) {
        NSURL *fallback = [[support URLByAppendingPathComponent:@"RUIN/AppGroups" isDirectory:YES]
            URLByAppendingPathComponent:logical isDirectory:YES];
        NSURL *resolved = nil; NSString *suite = nil; NSError *error = nil;
        RUINAppGroupStorageDisposition disposition;
        NSArray *legacy = [logical isEqual:@"group.com.linecorp.line"] && account.length ? authorized.allValues : @[];
        BOOL ok = RUINResolveAppGroupStorage(logical,account,authorized[logical],fallback,
            requestedMap,authorized,legacy,&resolved,&suite,&disposition,&error);
        if (!ok || disposition == RUINAppGroupStorageDispositionUnsafe ||
            disposition == RUINAppGroupStorageDispositionLegacyMainCandidate) {
            // Keep the current sandbox available for diagnostics. The login
            // guard stops a new migration while bindings are ambiguous/denied.
            unsafeStorageCount++;
            resolved = fallback;
            suite = nil;
        }
        // Sandbox-only storage cannot follow a changed application identifier.
        // Keep active sessions on that path, but require a native or explicitly
        // pinned group before starting another login/transfer.
        if (disposition == RUINAppGroupStorageDispositionNewFallback ||
            disposition == RUINAppGroupStorageDispositionExistingFallback) unsafeStorageCount++;
        if (!resolved.isFileURL || ![manager createDirectoryAtURL:resolved withIntermediateDirectories:YES attributes:nil error:NULL]) {
            unsafeStorageCount++;
            continue;
        }
        URLs[logical] = resolved;
        if (suite.length && ![suite isEqual:logical]) suites[logical] = suite;
        if (ok && disposition == RUINAppGroupStorageDispositionExplicitMap &&
            !RUINRecordExplicitAppGroupBinding(logical,suite,authorized,NULL)) unsafeStorageCount++;
    }
    resolvedGroupURLs = [URLs copy];
    groupMap = [suites copy];
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
    NSString *mapped = [name isKindOfClass:NSString.class] ? groupMap[name] : nil;
    if (mapped) atomic_fetch_add(&mappedSuiteRequests, 1);
    return %orig(mapped ?: name);
}
%end
%end

void RUINInstallCompatibility(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Generic injectors need not supply RUIN's optional signing metadata.
        // The host UUID was verified by the identity adapter before this call.
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
        RUINPrepareStorageBindings(validated);
        Method method = class_getInstanceMethod(NSFileManager.class,
            @selector(containerURLForSecurityApplicationGroupIdentifier:));
        if (!method || strcmp(method_getTypeEncoding(method), "@24@0:8@16")) return;
        %init(RUINAppGroupMapping);
        installed = YES;
        migrationReady = !unsafeStorageCount && resolvedGroupURLs.count == RUINOriginalGroups().count;
        Method suite = class_getInstanceMethod(NSUserDefaults.class, @selector(initWithSuiteName:));
        if (groupMap.count && suite && !strcmp(method_getTypeEncoding(suite), "@24@0:8@16")) {
            %init(RUINPreferencesSuiteMapping);
            suitesInstalled = YES;
        }
    });
}
#endif

NSDictionary *RUINCompatibilityDiagnostics(void) {
    return @{@"appGroupMappingInstalled": @(installed),
             @"appGroupMappingCount": @(groupMap.count),
             @"mappedAppGroupRequests": @(atomic_load(&mappedGroupRequests)),
             @"localAppGroupFallbackRequests": @(atomic_load(&localContainerRequests)),
             @"appGroupPreferencesMappingInstalled": @(suitesInstalled),
             @"mappedPreferencesRequests": @(atomic_load(&mappedSuiteRequests)),
             @"storageMigrationReady":@(migrationReady), @"unsafeStorageBindings":@(unsafeStorageCount),
             @"resolvedStorageNamespaces":@(resolvedGroupURLs.count)};
}

BOOL RUINStorageMigrationReady(void) { return migrationReady; }

#if !defined(RUIN_SIDELOAD_HOST_CHECK)
__attribute__((constructor)) static void RUINPrepareSideload(void) {
    @autoreleasepool { RUINInstallCompatibility(); }
}
#else
#import <assert.h>
int main(void) { @autoreleasepool {
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
