#import <Foundation/Foundation.h>
#import <Security/SecItem.h>
#import <stdatomic.h>
#import <stdlib.h>
#import "BundleIdentity.h"
#import "Keychain.h"
#import "../core/TargetMetadata.h"

#if !defined(RUIN_KEYCHAIN_HOST_CHECK)
#import "fishhook.h"
// Imported C symbols intentionally use fishhook: Logos' internal backend does
// not support %hookf, and this jailed-compatible dylib has no Substrate runtime.
// Rebinding imports keeps executable text and the input IPA unchanged.
#endif

static NSString *const RUINOldAppAccessGroup = @"ZW4U99SQQ3.jp.naver.line";
static NSString *const RUINOldSharedAccessGroup = @"ZW4U99SQQ3.com.linecorp.trident.shared";

#if !defined(RUIN_KEYCHAIN_HOST_CHECK)
static OSStatus (*originalSecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*originalSecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*originalSecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*originalSecItemDelete)(CFDictionaryRef);
#endif
static NSDictionary<NSString *, NSString *> *accessGroupMap;
static atomic_uint_fast64_t mappedQueries;
static BOOL compatibilityReady;
static BOOL namespaceBindingPersisted;
static NSString *keychainBindingStatus = @"NotAttempted";

typedef NS_ENUM(NSInteger, RUINGroupPermission) {
    RUINGroupPermissionUnknown = 0,
    RUINGroupPermissionAllowed,
    RUINGroupPermissionDenied
};

typedef NS_ENUM(NSInteger, RUINKeychainBindingAction) {
    RUINKeychainBindingActionPermissionUnproven = 0,
    RUINKeychainBindingActionNativePassthrough,
    RUINKeychainBindingActionRebind,
    RUINKeychainBindingActionUnsupportedAuthenticatedImports
};

#if !defined(RUIN_KEYCHAIN_HOST_CHECK)
static BOOL RUINUsesAuthenticatedImports(void) {
#if defined(__arm64e__)
    return YES;
#else
    return NO;
#endif
}
#endif

static RUINKeychainBindingAction RUINKeychainBindingActionForMap(
    NSDictionary *mapping, BOOL originalGroupsAllowed, BOOL authenticatedImports) {
    if (![mapping isKindOfClass:NSDictionary.class]) return RUINKeychainBindingActionPermissionUnproven;
    if (!mapping.count) return originalGroupsAllowed
        ? RUINKeychainBindingActionNativePassthrough
        : RUINKeychainBindingActionPermissionUnproven;
    return authenticatedImports
        ? RUINKeychainBindingActionUnsupportedAuthenticatedImports
        : RUINKeychainBindingActionRebind;
}

static BOOL RUINKeychainBindingActionNeedsRebind(RUINKeychainBindingAction action) {
    return action == RUINKeychainBindingActionRebind;
}

static BOOL RUINKeychainBindingActionCanReadyWithoutRebind(RUINKeychainBindingAction action) {
    return action == RUINKeychainBindingActionNativePassthrough;
}

typedef RUINGroupPermission (^RUINGroupPermissionProbe)(NSString *group);

static BOOL RUINIsIdentifierPrefix(NSString *prefix) {
    if (![prefix isKindOfClass:NSString.class] || !prefix.length) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"] invertedSet];
    return [prefix rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static NSString *RUINIdentifierPrefix(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || [identifier containsString:@"*"]) return nil;
    NSRange separator = [identifier rangeOfString:@"."];
    if (separator.location == NSNotFound || !separator.location || separator.location + 1 >= identifier.length)
        return nil;
    NSString *prefix = [identifier substringToIndex:separator.location];
    return RUINIsIdentifierPrefix(prefix) ? prefix : nil;
}

static NSArray<NSString *> *RUINSharedGroupsFromMetadata(NSDictionary *metadata) {
    NSMutableArray<NSString *> *groups = [NSMutableArray arrayWithCapacity:2];
    id teamValue = metadata[@"RUINSignedTeamIdentifier"];
    if ([teamValue isKindOfClass:NSString.class] && RUINIsIdentifierPrefix(teamValue))
        [groups addObject:[teamValue stringByAppendingString:@".com.linecorp.trident.shared"]];

    NSString *prefix = RUINIdentifierPrefix(metadata[@"RUINSigningApplicationIdentifier"]);
    NSString *applicationGroup = prefix ? [prefix stringByAppendingString:@".com.linecorp.trident.shared"] : nil;
    if (applicationGroup && ![groups containsObject:applicationGroup]) [groups addObject:applicationGroup];
    return groups;
}

static RUINGroupPermission RUINCachedGroupPermission(NSString *group,
                                                       RUINGroupPermissionProbe probe,
                                                       NSMutableDictionary<NSString *, NSNumber *> *cache) {
    NSNumber *cached = cache[group];
    if (cached) return (RUINGroupPermission)cached.integerValue;
    RUINGroupPermission permission = probe(group);
    cache[group] = @(permission);
    return permission;
}

static RUINGroupPermission RUINGroupPermissionForStatus(OSStatus status) {
    if (status == errSecSuccess) return RUINGroupPermissionAllowed;
    if (status == errSecMissingEntitlement) return RUINGroupPermissionDenied;
    return RUINGroupPermissionUnknown;
}

static NSDictionary<NSString *, NSString *> *RUINBuildAccessGroupMap(
    NSString *defaultGroup, NSDictionary *metadata, RUINGroupPermissionProbe probe,
    BOOL *originalGroupsAllowed) {
    if (originalGroupsAllowed) *originalGroupsAllowed = NO;
    if (![defaultGroup isKindOfClass:NSString.class] || !defaultGroup.length || !probe) return nil;

    NSMutableDictionary<NSString *, NSNumber *> *permissionCache = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    RUINGroupPermission appPermission = RUINCachedGroupPermission(RUINOldAppAccessGroup, probe, permissionCache);
    if (appPermission != RUINGroupPermissionAllowed && appPermission != RUINGroupPermissionDenied) return nil;
    if (appPermission == RUINGroupPermissionDenied && ![defaultGroup isEqualToString:RUINOldAppAccessGroup])
        map[RUINOldAppAccessGroup] = defaultGroup;

    RUINGroupPermission sharedPermission = RUINCachedGroupPermission(RUINOldSharedAccessGroup, probe, permissionCache);
    if (sharedPermission != RUINGroupPermissionAllowed && sharedPermission != RUINGroupPermissionDenied) return nil;
    if (originalGroupsAllowed)
        *originalGroupsAllowed = appPermission == RUINGroupPermissionAllowed &&
            sharedPermission == RUINGroupPermissionAllowed;
    if (sharedPermission == RUINGroupPermissionDenied) {
        NSString *replacement = nil;
        for (NSString *explicitGroup in RUINSharedGroupsFromMetadata(metadata)) {
            if ([explicitGroup isEqualToString:RUINOldSharedAccessGroup]) continue;
            RUINGroupPermission permission = RUINCachedGroupPermission(explicitGroup, probe, permissionCache);
            if (permission != RUINGroupPermissionAllowed && permission != RUINGroupPermissionDenied) return nil;
            if (permission == RUINGroupPermissionAllowed) {
                replacement = explicitGroup;
                break;
            }
        }

        if (!replacement) {
            NSString *prefix = RUINIdentifierPrefix(defaultGroup);
            NSString *candidate = prefix ? [prefix stringByAppendingString:@".com.linecorp.trident.shared"] : nil;
            if (candidate && ![candidate isEqualToString:RUINOldSharedAccessGroup]) {
                RUINGroupPermission permission = RUINCachedGroupPermission(candidate, probe, permissionCache);
                if (permission != RUINGroupPermissionAllowed && permission != RUINGroupPermissionDenied) return nil;
                if (permission == RUINGroupPermissionAllowed) replacement = candidate;
            }
        }

        replacement = replacement ?: defaultGroup;
        if (![replacement isEqualToString:RUINOldSharedAccessGroup]) map[RUINOldSharedAccessGroup] = replacement;
    }

    return [map copy];
}

static NSDictionary *RUINReuseAccessGroupBinding(NSDictionary *mapping, NSDictionary *saved,
    NSString *defaultGroup, RUINGroupPermissionProbe probe) {
    if (!saved) return mapping;
    if (![saved isKindOfClass:NSDictionary.class] || ![saved[@"version"] isKindOfClass:NSNumber.class] ||
        [saved[@"version"] integerValue] != 1 ||
        ![saved[@"groups"] isKindOfClass:NSDictionary.class]) return nil;
    NSString *prefix = RUINIdentifierPrefix(defaultGroup);
    NSMutableDictionary *result = [mapping mutableCopy];
    for (NSString *logical in @[RUINOldAppAccessGroup,RUINOldSharedAccessGroup]) {
        if (!mapping[logical]) continue; // Native entitlement access stays native.
        id previous = saved[@"groups"][logical];
        if (![previous isKindOfClass:NSString.class] ||
            ![RUINIdentifierPrefix(previous) isEqual:prefix] ||
            probe(previous) != RUINGroupPermissionAllowed) return nil;
        result[logical] = previous;
    }
    return result;
}

static NSDictionary *RUINApplyAccessGroupBinding(NSDictionary *mapping, NSDictionary *saved,
    NSString *defaultGroup, RUINGroupPermissionProbe probe, BOOL (^persist)(NSDictionary *)) {
    NSDictionary *reconciled = RUINReuseAccessGroupBinding(mapping, saved, defaultGroup, probe);
    if (!reconciled || !persist || !persist(reconciled)) return nil;
    accessGroupMap = reconciled;
    return reconciled;
}

static BOOL RUINHasStableSharedNamespace(NSDictionary *mapping) {
    NSString *group = mapping[RUINOldSharedAccessGroup] ?: RUINOldSharedAccessGroup;
    return [group hasSuffix:@".com.linecorp.trident.shared"];
}

static BOOL RUINKeychainTargetEligible(NSString *identityStatus, NSDictionary *logicalInfo) {
    return [identityStatus isKindOfClass:NSString.class] &&
           ([identityStatus isEqualToString:@"installed"] ||
            [identityStatus isEqualToString:@"already_original"]) &&
           [logicalInfo isKindOfClass:NSDictionary.class] &&
           RUINTargetMetadataMatchesInfo(logicalInfo);
}

static NSDictionary *RUINMappedAttributes(CFDictionaryRef attributes) {
    if (!attributes || !accessGroupMap) return nil;

    NSDictionary *dictionary = (__bridge NSDictionary *)attributes;
    id group = dictionary[(__bridge id)kSecAttrAccessGroup];
    if (![group isKindOfClass:NSString.class]) return nil;

    NSString *replacement = accessGroupMap[group];
    if (!replacement) return nil;

    NSMutableDictionary *mapped = [dictionary mutableCopy];
    mapped[(__bridge id)kSecAttrAccessGroup] = replacement;
    return mapped;
}

typedef OSStatus (*RUINKeychainAddOperation)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*RUINKeychainDeleteOperation)(CFDictionaryRef);

static NSString *RUINDefaultAccessGroupWithOperations(RUINKeychainAddOperation add,
                                                       RUINKeychainDeleteOperation deleteItem) {
    if (!add || !deleteItem) return nil;

    NSString *service = [@"RUINKeychainDefaultProbe-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *account = NSUUID.UUID.UUIDString;
    NSMutableData *value = [NSMutableData dataWithLength:32];
    arc4random_buf(value.mutableBytes, value.length);
    NSDictionary *probe = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        (__bridge id)kSecValueData: value,
        (__bridge id)kSecReturnAttributes: @YES
    };

    CFTypeRef result = NULL;
    OSStatus addStatus = add((__bridge CFDictionaryRef)probe, &result);
    OSStatus deleteStatus = errSecNotAvailable;
    NSString *group = nil;
    @try {
        if (addStatus == errSecSuccess && result && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
            id candidate = ((__bridge NSDictionary *)result)[(__bridge id)kSecAttrAccessGroup];
            if ([candidate isKindOfClass:NSString.class] && [candidate length]) group = [candidate copy];
        }
    } @catch (__unused NSException *exception) {
    } @finally {
        if (result) CFRelease(result);
        if (addStatus == errSecSuccess) {
            NSMutableDictionary *cleanup = [@{
                (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService: service,
                (__bridge id)kSecAttrAccount: account
            } mutableCopy];
            if (group) cleanup[(__bridge id)kSecAttrAccessGroup] = group;
            deleteStatus = deleteItem((__bridge CFDictionaryRef)cleanup);
        }
    }

    if (addStatus != errSecSuccess || !group ||
        (deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound)) return nil;
    return group;
}

#if !defined(RUIN_KEYCHAIN_HOST_CHECK)
static NSDictionary *RUINLoadNamespaceBinding(NSString *group, OSStatus *status) {
    NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"com.tqmane.ruin.keychain-namespace",
        (__bridge id)kSecAttrAccount:@"line-api-groups-v1", (__bridge id)kSecAttrAccessGroup:group,
        (__bridge id)kSecReturnData:@YES, (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitOne};
    CFTypeRef value = NULL;
    *status = SecItemCopyMatching((__bridge CFDictionaryRef)query,&value);
    NSDictionary *saved = nil;
    if (*status == errSecSuccess && value && CFGetTypeID(value) == CFDataGetTypeID() &&
        CFDataGetLength(value) <= 4096) {
        id object = [NSPropertyListSerialization propertyListWithData:(__bridge NSData *)value
            options:NSPropertyListImmutable format:NULL error:NULL];
        if ([object isKindOfClass:NSDictionary.class]) saved = object;
    }
    if (value) CFRelease(value);
    if (*status == errSecSuccess && !saved) *status = errSecDecode;
    return saved;
}

static BOOL RUINSaveNamespaceBinding(NSString *group, NSDictionary *mapping) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"version":@1,@"groups":mapping}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (!data) return NO;
    NSDictionary *item = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"com.tqmane.ruin.keychain-namespace",
        (__bridge id)kSecAttrAccount:@"line-api-groups-v1",(__bridge id)kSecAttrAccessGroup:group,
        (__bridge id)kSecValueData:data,
        (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    // Only RUIN's non-secret namespace metadata is created; existing bindings
    // and all LINE credentials/keys are left untouched.
    return SecItemAdd((__bridge CFDictionaryRef)item,NULL) == errSecSuccess;
}

static RUINGroupPermission RUINProbeAccessGroupPermission(NSString *group) {
    if (![group isKindOfClass:NSString.class] || !group.length) return RUINGroupPermissionUnknown;
    NSString *nonce = NSUUID.UUID.UUIDString;
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: [@"RUINKeychainPermissionProbe-" stringByAppendingString:nonce],
        (__bridge id)kSecAttrAccount: nonce,
        (__bridge id)kSecAttrAccessGroup: group
    };
    NSMutableDictionary *attributes = [query mutableCopy];
    attributes[(__bridge id)kSecValueData] = [nonce dataUsingEncoding:NSUTF8StringEncoding];
    attributes[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    // A failed lookup cannot distinguish an empty group from an inaccessible
    // one on every OS. An isolated add/delete proves the actual permission.
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
    if (status == errSecSuccess) {
        OSStatus cleanup = SecItemDelete((__bridge CFDictionaryRef)query);
        return cleanup == errSecSuccess || cleanup == errSecItemNotFound ? RUINGroupPermissionAllowed : RUINGroupPermissionUnknown;
    }
    return RUINGroupPermissionForStatus(status);
}

static OSStatus RUINSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!originalSecItemCopyMatching) return errSecNotAvailable;
    NSDictionary *mapped = RUINMappedAttributes(query);
    if (mapped) atomic_fetch_add_explicit(&mappedQueries, 1, memory_order_relaxed);
    return originalSecItemCopyMatching(mapped ? (__bridge CFDictionaryRef)mapped : query, result);
}

static OSStatus RUINSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!originalSecItemAdd) return errSecNotAvailable;
    NSDictionary *mapped = RUINMappedAttributes(attributes);
    if (mapped) atomic_fetch_add_explicit(&mappedQueries, 1, memory_order_relaxed);
    return originalSecItemAdd(mapped ? (__bridge CFDictionaryRef)mapped : attributes, result);
}

static OSStatus RUINSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (!originalSecItemUpdate) return errSecNotAvailable;
    NSDictionary *mappedQuery = RUINMappedAttributes(query);
    NSDictionary *mappedAttributes = RUINMappedAttributes(attributesToUpdate);
    if (mappedQuery || mappedAttributes) atomic_fetch_add_explicit(&mappedQueries, 1, memory_order_relaxed);
    return originalSecItemUpdate(mappedQuery ? (__bridge CFDictionaryRef)mappedQuery : query,
                                 mappedAttributes ? (__bridge CFDictionaryRef)mappedAttributes : attributesToUpdate);
}

static OSStatus RUINSecItemDelete(CFDictionaryRef query) {
    if (!originalSecItemDelete) return errSecNotAvailable;
    NSDictionary *mapped = RUINMappedAttributes(query);
    if (mapped) atomic_fetch_add_explicit(&mappedQueries, 1, memory_order_relaxed);
    return originalSecItemDelete(mapped ? (__bridge CFDictionaryRef)mapped : query);
}

void RUINInstallKeychainCompatibility(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RUINInstallBundleIdentity();
        NSDictionary *logicalInfo = NSBundle.mainBundle.infoDictionary;
        NSString *status = RUINBundleIdentityDiagnostics()[@"status"];
        if (!RUINKeychainTargetEligible(status, logicalInfo)) return;

        NSDictionary *metadata = RUINActualMainBundleInfo();
        NSString *defaultGroup = RUINDefaultAccessGroupWithOperations(SecItemAdd, SecItemDelete);
        if (!defaultGroup) { keychainBindingStatus = @"DefaultAccessGroupUnavailable"; return; }
        BOOL originalGroupsAllowed = NO;
        NSDictionary *mapping = RUINBuildAccessGroupMap(defaultGroup, metadata,
            ^RUINGroupPermission(NSString *group) { return RUINProbeAccessGroupPermission(group); },
            &originalGroupsAllowed);
        if (!mapping) { keychainBindingStatus = @"PermissionUnproven"; return; }
        accessGroupMap = mapping;

        RUINKeychainBindingAction action = RUINKeychainBindingActionForMap(
            mapping, originalGroupsAllowed, RUINUsesAuthenticatedImports());
        if (RUINKeychainBindingActionCanReadyWithoutRebind(action)) {
            keychainBindingStatus = @"NativePassthrough";
            compatibilityReady = YES;
            return;
        }
        if (action == RUINKeychainBindingActionUnsupportedAuthenticatedImports) {
            // This fork's fishhook does not authenticate or re-sign auth-GOT slots.
            compatibilityReady = NO;
            keychainBindingStatus = @"UnsupportedAuthenticatedImports";
            return;
        }
        if (!RUINKeychainBindingActionNeedsRebind(action)) {
            keychainBindingStatus = @"PermissionUnproven";
            return;
        }

        BOOL stableNamespace = RUINHasStableSharedNamespace(mapping);
        if (mapping.count && stableNamespace) {
            NSString *bindingGroup = mapping[RUINOldSharedAccessGroup] ?: RUINOldSharedAccessGroup;
            OSStatus bindingStatus = errSecNotAvailable;
            NSDictionary *saved = RUINLoadNamespaceBinding(bindingGroup,&bindingStatus);
            if (bindingStatus != errSecSuccess && bindingStatus != errSecItemNotFound) {
                keychainBindingStatus = @"NamespaceBindingUnavailable";
                return;
            }
            mapping = RUINApplyAccessGroupBinding(mapping,saved,defaultGroup,
                ^RUINGroupPermission(NSString *group) { return RUINProbeAccessGroupPermission(group); },
                ^BOOL(NSDictionary *reconciled) {
                    namespaceBindingPersisted = saved != nil || RUINSaveNamespaceBinding(bindingGroup,reconciled);
                    return namespaceBindingPersisted;
                });
            if (!mapping) { keychainBindingStatus = @"NamespaceBindingUnavailable"; return; }
        }

        struct rebinding rebindings[] = {
            {"SecItemCopyMatching", (void *)RUINSecItemCopyMatching, (void **)&originalSecItemCopyMatching},
            {"SecItemAdd", (void *)RUINSecItemAdd, (void **)&originalSecItemAdd},
            {"SecItemUpdate", (void *)RUINSecItemUpdate, (void **)&originalSecItemUpdate},
            {"SecItemDelete", (void *)RUINSecItemDelete, (void **)&originalSecItemDelete}
        };
        int result = rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
        compatibilityReady = stableNamespace && result == 0 && originalSecItemCopyMatching && originalSecItemAdd &&
            originalSecItemUpdate && originalSecItemDelete;
        keychainBindingStatus = compatibilityReady ? @"RebindReady" : @"RebindUnavailable";
    });
}
#endif

NSDictionary *RUINKeychainDiagnostics(void) {
    return @{@"mappedKeychainQueries": @(atomic_load_explicit(&mappedQueries, memory_order_relaxed)),
        @"accessGroupMappingCount":@(accessGroupMap.count), @"ready":@(compatibilityReady),
        @"namespaceBindingPersisted":@(namespaceBindingPersisted),
        @"bindingStatus":keychainBindingStatus};
}

BOOL RUINKeychainCompatibilityReady(void) { return compatibilityReady; }

#if !defined(RUIN_KEYCHAIN_HOST_CHECK)
static BOOL RUINCopyMatches(CFDictionaryRef query, NSData *expected, OSStatus *status) {
    NSMutableDictionary *copyQuery = [(__bridge NSDictionary *)query mutableCopy];
    copyQuery[(__bridge id)kSecReturnData] = (__bridge id)kCFBooleanTrue;
    copyQuery[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    *status = SecItemCopyMatching((__bridge CFDictionaryRef)copyQuery, &result);
    BOOL matches = *status == errSecSuccess && result && CFGetTypeID(result) == CFDataGetTypeID() &&
                   CFEqual(result, (__bridge CFDataRef)expected);
    if (result) CFRelease(result);
    return matches;
}

NSDictionary *RUINKeychainSelfTest(void) {
    RUINInstallKeychainCompatibility();

    NSString *account = [@"RUINKeychainSelfTest-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSData *initialValue = [NSUUID.UUID.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
    NSData *updatedValue = [NSUUID.UUID.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.ruin.keychain-self-test",
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecAttrAccessGroup: RUINOldAppAccessGroup
    };
    NSMutableDictionary *attributes = [query mutableCopy];
    attributes[(__bridge id)kSecValueData] = initialValue;

    OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
    NSMutableDictionary *result = [@{@"addStatus": @(addStatus), @"passed": @NO} mutableCopy];
    if (addStatus != errSecSuccess) return result;

    OSStatus copyStatus = errSecNotAvailable;
    OSStatus updateStatus = errSecNotAvailable;
    OSStatus verifyStatus = errSecNotAvailable;
    OSStatus deleteStatus = errSecNotAvailable;
    BOOL initialValueMatched = NO;
    BOOL updatedValueMatched = NO;
    @try {
        initialValueMatched = RUINCopyMatches((__bridge CFDictionaryRef)query, initialValue, &copyStatus);
        NSDictionary *update = @{(__bridge id)kSecValueData: updatedValue};
        updateStatus = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
        updatedValueMatched = RUINCopyMatches((__bridge CFDictionaryRef)query, updatedValue, &verifyStatus);
    } @catch (__unused NSException *exception) {
    } @finally {
        deleteStatus = SecItemDelete((__bridge CFDictionaryRef)query);
    }

    BOOL passed = initialValueMatched && updatedValueMatched && addStatus == errSecSuccess &&
                  copyStatus == errSecSuccess && updateStatus == errSecSuccess &&
                  verifyStatus == errSecSuccess && deleteStatus == errSecSuccess;
    [result addEntriesFromDictionary:@{
        @"copyStatus": @(copyStatus),
        @"updateStatus": @(updateStatus),
        @"verifyStatus": @(verifyStatus),
        @"deleteStatus": @(deleteStatus),
        @"passed": @(passed)
    }];
    return result;
}

__attribute__((constructor)) static void RUINInstallKeychainAtLoad(void) {
    @autoreleasepool { RUINInstallKeychainCompatibility(); }
}
#endif
