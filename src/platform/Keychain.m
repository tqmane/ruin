#import <Foundation/Foundation.h>
#import <Security/SecItem.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import "BundleIdentity.h"
#import "Keychain.h"
#import "../core/TargetMetadata.h"
#import "../core/NativeFunctionPointer.h"
#import "../core/StartupProfiler.h"

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
static void *securityFrameworkHandle;
#endif
static NSDictionary<NSString *, NSString *> *accessGroupMap;
static atomic_uint_fast64_t mappedQueries;
static BOOL compatibilityReady;
static BOOL namespaceBindingPersisted;
static NSString *keychainBindingStatus = @"NotAttempted";
static OSStatus lastDefaultProbeStatus = errSecNotAvailable;
static OSStatus lastAppGroupProbeStatus = errSecNotAvailable;
static OSStatus lastSharedGroupProbeStatus = errSecNotAvailable;
static OSStatus lastBindingLoadStatus = errSecNotAvailable;
static OSStatus lastBindingSaveStatus = errSecNotAvailable;
static OSStatus lastBindingResetStatus = errSecNotAvailable;
static NSString *lastBindingRejectReason = @"none";

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
    NSDictionary *mapping, BOOL originalGroupsAllowed, BOOL verifiedPlainMainImage) {
    if (![mapping isKindOfClass:NSDictionary.class]) return RUINKeychainBindingActionPermissionUnproven;
    if (!mapping.count) return originalGroupsAllowed
        ? RUINKeychainBindingActionNativePassthrough
        : RUINKeychainBindingActionPermissionUnproven;
    return verifiedPlainMainImage ? RUINKeychainBindingActionRebind
        : RUINKeychainBindingActionUnsupportedAuthenticatedImports;
}

static BOOL RUINKeychainBindingActionNeedsRebind(RUINKeychainBindingAction action) {
    return action == RUINKeychainBindingActionRebind;
}

static BOOL RUINKeychainBindingActionCanReadyWithoutRebind(RUINKeychainBindingAction action) {
    return action == RUINKeychainBindingActionNativePassthrough;
}

static BOOL RUINKeychainMainImageHasNoAuthenticatedPointerSections(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64 || header->filetype != MH_EXECUTE ||
        header->sizeofcmds > 1024 * 1024 || header->ncmds > header->sizeofcmds / sizeof(struct load_command)) return NO;
    const uint8_t *cursor = (const void *)(header + 1), *end = cursor + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return NO;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) return NO;
        if (command->cmd == LC_SEGMENT_64) {
            if (command->cmdsize < sizeof(struct segment_command_64)) return NO;
            const struct segment_command_64 *segment = (const void *)command;
            size_t sectionBytes = command->cmdsize - sizeof(*segment);
            if (segment->nsects > sectionBytes / sizeof(struct section_64) ||
                !strncmp(segment->segname, "__AUTH", 6)) return NO;
            const struct section_64 *sections = (const void *)(segment + 1);
            for (uint32_t section = 0; section < segment->nsects; section++)
                if (!strncmp(sections[section].sectname, "__auth", 6)) return NO;
        }
        cursor += command->cmdsize;
    }
    return cursor == end;
}

static BOOL RUINKeychainMainImageAllowsRebinding(const RUINVersionMapping *mapping,
    const RUINMainExecutableImage *image, BOOL authenticatedProducer) {
    if (!mapping || !mapping->host.version || !mapping->host.build || !mapping->host.uuid ||
        !image || !image->header || image->header->magic != MH_MAGIC_64 || image->header->filetype != MH_EXECUTE ||
        image->header->cputype != CPU_TYPE_ARM64 || image->header->cpusubtype != CPU_SUBTYPE_ARM64_ALL ||
        image->cpuType != CPU_TYPE_ARM64 || image->cpuSubtype != CPU_SUBTYPE_ARM64_ALL ||
        !RUINVerifyHostImage(&mapping->host, image->header)) return NO;

    NSUUID *expectedUUID = [[NSUUID alloc] initWithUUIDString:@(mapping->host.uuid)];
    if (!expectedUUID) return NO;
    uuid_t expectedBytes;
    [expectedUUID getUUIDBytes:expectedBytes];
    if (memcmp(image->uuid, expectedBytes, sizeof(expectedBytes))) return NO;

    // The arm64e producer has verified ABI coverage only for the plain 26.17 main image.
    if (authenticatedProducer &&
        (strcmp(mapping->host.version, "26.17.0") || strcmp(mapping->host.build, "2026.1103.1841"))) return NO;
    return RUINKeychainMainImageHasNoAuthenticatedPointerSections(image->header);
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

static NSString *RUINCanonicalAppAccessGroup(NSString *defaultGroup) {
    NSString *prefix = RUINIdentifierPrefix(defaultGroup);
    return prefix ? [prefix stringByAppendingString:@".jp.naver.line"] : nil;
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
    if (appPermission == RUINGroupPermissionDenied && ![defaultGroup isEqualToString:RUINOldAppAccessGroup]) {
        map[RUINOldAppAccessGroup] = defaultGroup;
        // LINE may also request its canonical bundle group with this signature's team prefix.
        NSString *canonicalAppGroup = RUINCanonicalAppAccessGroup(defaultGroup);
        if (canonicalAppGroup && ![canonicalAppGroup isEqualToString:defaultGroup] &&
            ![canonicalAppGroup isEqualToString:RUINOldAppAccessGroup])
            map[canonicalAppGroup] = defaultGroup;
    }

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
    lastBindingRejectReason = @"none";
    if (!saved) return mapping;
    if (![saved isKindOfClass:NSDictionary.class] || ![saved[@"version"] isKindOfClass:NSNumber.class] ||
        [saved[@"version"] integerValue] != 1 ||
        ![saved[@"groups"] isKindOfClass:NSDictionary.class]) {
        lastBindingRejectReason = [saved isKindOfClass:NSDictionary.class]
            ? [NSString stringWithFormat:@"malformed:%@", saved[@"version"] ?: @"missing_groups"]
            : @"malformed:non_dict";
        return nil;
    }
    NSString *prefix = RUINIdentifierPrefix(defaultGroup);
    NSMutableDictionary *result = [mapping mutableCopy];
    for (NSString *logical in @[RUINOldAppAccessGroup,RUINOldSharedAccessGroup]) {
        if (!mapping[logical]) continue; // Native entitlement access stays native.
        id previous = saved[@"groups"][logical];
        if (!previous) {
            // An earlier install may have mapped only a subset of namespaces
            // (for example, shared access was native previously). Keep the
            // newly resolved group in result and preserve the rest.
            continue;
        }
        if (![previous isKindOfClass:NSString.class]) {
            lastBindingRejectReason = [NSString stringWithFormat:@"missing_group:%@", logical];
            return nil;
        }
        if (![RUINIdentifierPrefix(previous) isEqual:prefix]) {
            lastBindingRejectReason = [NSString stringWithFormat:@"foreign_prefix:%@", previous];
            return nil;
        }
        RUINGroupPermission permission = probe(previous);
        if (permission != RUINGroupPermissionAllowed) {
            lastBindingRejectReason = [NSString stringWithFormat:@"%@:%@",
                permission == RUINGroupPermissionDenied ? @"denied" : @"unknown", previous];
            return nil;
        }
        result[logical] = previous;
    }
    NSString *canonicalAppGroup = RUINCanonicalAppAccessGroup(defaultGroup);
    if (canonicalAppGroup && result[canonicalAppGroup] && result[RUINOldAppAccessGroup])
        result[canonicalAppGroup] = result[RUINOldAppAccessGroup];
    return result;
}

static NSDictionary *RUINApplyAccessGroupBinding(NSDictionary *mapping, NSDictionary *saved,
    NSString *defaultGroup, RUINGroupPermissionProbe probe, BOOL (^persist)(NSDictionary *)) {
    NSDictionary *reconciled = RUINReuseAccessGroupBinding(mapping, saved, defaultGroup, probe);
    if (!reconciled || !persist || !persist(reconciled)) return nil;
    accessGroupMap = reconciled;
    return reconciled;
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
    lastDefaultProbeStatus = addStatus;
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
    if (!data) { lastBindingSaveStatus = errSecParam; return NO; }
    NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"com.tqmane.ruin.keychain-namespace",
        (__bridge id)kSecAttrAccount:@"line-api-groups-v1",(__bridge id)kSecAttrAccessGroup:group};
    NSMutableDictionary *item = [query mutableCopy];
    item[(__bridge id)kSecValueData] = data;
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    // Only RUIN's non-secret namespace metadata is created/updated; all LINE
    // credentials and keys are left untouched.
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status == errSecDuplicateItem) {
        NSDictionary *update = @{(__bridge id)kSecValueData:data,
            (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
        status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
    }
    lastBindingSaveStatus = status;
    return status == errSecSuccess;
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
    if ([group isEqualToString:RUINOldAppAccessGroup]) lastAppGroupProbeStatus = status;
    else if ([group isEqualToString:RUINOldSharedAccessGroup]) lastSharedGroupProbeStatus = status;
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

static BOOL RUINResolveSecurityItemOperations(void) {
    if (!securityFrameworkHandle)
        securityFrameworkHandle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
    if (!securityFrameworkHandle) return NO;
    originalSecItemCopyMatching = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))RUINNativeFunctionPointerForCall(
        RUINNativeFunctionPointerRaw(dlsym(securityFrameworkHandle, "SecItemCopyMatching")));
    originalSecItemAdd = (OSStatus (*)(CFDictionaryRef, CFTypeRef *))RUINNativeFunctionPointerForCall(
        RUINNativeFunctionPointerRaw(dlsym(securityFrameworkHandle, "SecItemAdd")));
    originalSecItemUpdate = (OSStatus (*)(CFDictionaryRef, CFDictionaryRef))RUINNativeFunctionPointerForCall(
        RUINNativeFunctionPointerRaw(dlsym(securityFrameworkHandle, "SecItemUpdate")));
    originalSecItemDelete = (OSStatus (*)(CFDictionaryRef))RUINNativeFunctionPointerForCall(
        RUINNativeFunctionPointerRaw(dlsym(securityFrameworkHandle, "SecItemDelete")));
    return originalSecItemCopyMatching && originalSecItemAdd && originalSecItemUpdate && originalSecItemDelete;
}

void RUINInstallKeychainCompatibility(void) {
    // Protected keychain data or bundle identity may be unavailable during
    // early launch. A failed probe must not disable login for this process.
    @synchronized (NSProcessInfo.processInfo) {
        if (compatibilityReady) { RUIN_PROFILE_INSTANT("keychain.already_ready", RUINProfileStatusSkipped); return; }
        RUINInstallBundleIdentity();
        NSDictionary *logicalInfo = NSBundle.mainBundle.infoDictionary;
        NSString *status = RUINBundleIdentityDiagnostics()[@"status"];
        if (!RUINKeychainTargetEligible(status, logicalInfo)) { RUIN_PROFILE_INSTANT("keychain.ineligible", RUINProfileStatusSkipped); return; }

        NSDictionary *metadata = RUINActualMainBundleInfo();
        RUIN_PROFILE_BEGIN("keychain.default_group_probe");
        NSString *defaultGroup = RUINDefaultAccessGroupWithOperations(SecItemAdd, SecItemDelete);
        RUIN_PROFILE_END(defaultGroup ? RUINProfileStatusOK : RUINProfileStatusFailed);
        if (!defaultGroup) { keychainBindingStatus = @"DefaultAccessGroupUnavailable"; return; }
        BOOL originalGroupsAllowed = NO;
        RUIN_PROFILE_BEGIN("keychain.build_access_group_map");
        NSDictionary *mapping = RUINBuildAccessGroupMap(defaultGroup, metadata,
            ^RUINGroupPermission(NSString *group) { return RUINProbeAccessGroupPermission(group); },
            &originalGroupsAllowed);
        RUIN_PROFILE_END(mapping ? RUINProfileStatusOK : RUINProfileStatusFailed);
        if (!mapping) { keychainBindingStatus = @"PermissionUnproven"; return; }
        accessGroupMap = mapping;

        RUINMainExecutableImage mainImage = {0};
        const RUINVersionMapping *currentMapping = NULL;
        BOOL verifiedPlainMainImage = NO;
        RUIN_PROFILE_BEGIN("keychain.verify_main_image");
        if (mapping.count) {
            currentMapping = RUINCurrentMapping();
            verifiedPlainMainImage = currentMapping && RUINResolveMainExecutableImage(&mainImage) &&
                RUINKeychainMainImageAllowsRebinding(currentMapping, &mainImage, RUINUsesAuthenticatedImports());
        }
        RUIN_PROFILE_END(mapping.count ? (verifiedPlainMainImage ? RUINProfileStatusOK : RUINProfileStatusFailed) : RUINProfileStatusSkipped);
        RUINKeychainBindingAction action = RUINKeychainBindingActionForMap(
            mapping, originalGroupsAllowed, verifiedPlainMainImage);
        if (RUINKeychainBindingActionCanReadyWithoutRebind(action)) {
            keychainBindingStatus = @"NativePassthrough";
            compatibilityReady = YES;
            RUIN_PROFILE_INSTANT("keychain.binding.native_passthrough", RUINProfileStatusOK);
            return;
        }
        if (action == RUINKeychainBindingActionUnsupportedAuthenticatedImports) {
            // This fork's fishhook does not authenticate or re-sign auth-GOT slots.
            compatibilityReady = NO;
            keychainBindingStatus = @"UnsupportedAuthenticatedImports";
            RUIN_PROFILE_INSTANT("keychain.binding.unsupported_authenticated_imports", RUINProfileStatusSkipped);
            return;
        }
        if (!RUINKeychainBindingActionNeedsRebind(action)) {
            keychainBindingStatus = @"PermissionUnproven";
            RUIN_PROFILE_INSTANT("keychain.binding.permission_unproven", RUINProfileStatusSkipped);
            return;
        }

        // Personal signing profiles can authorize only the application's own
        // group. Pin that proven mapping too, rather than requiring a specific
        // shared-group suffix which grants no additional access or stability.
        if (mapping.count) {
            RUIN_PROFILE_BEGIN("keychain.namespace_binding");
            NSString *bindingGroup = mapping[RUINOldSharedAccessGroup] ?: RUINOldSharedAccessGroup;
            OSStatus bindingStatus = errSecNotAvailable;
            lastBindingRejectReason = @"none";
            NSDictionary *saved = RUINLoadNamespaceBinding(bindingGroup,&bindingStatus);
            lastBindingLoadStatus = bindingStatus;
            if (bindingStatus == errSecDecode) {
                saved = nil;
                bindingStatus = errSecItemNotFound;
            }
            if (bindingStatus != errSecSuccess && bindingStatus != errSecItemNotFound) {
                lastBindingRejectReason = [NSString stringWithFormat:@"load_error:%d", (int)bindingStatus];
                keychainBindingStatus = @"NamespaceBindingUnavailable";
                RUIN_PROFILE_END(RUINProfileStatusFailed);
                return;
            }
            mapping = RUINApplyAccessGroupBinding(mapping,saved,defaultGroup,
                ^RUINGroupPermission(NSString *group) { return RUINProbeAccessGroupPermission(group); },
                ^BOOL(NSDictionary *reconciled) {
                    BOOL needsSave = !saved || ![saved[@"groups"] isEqualToDictionary:reconciled];
                    namespaceBindingPersisted = !needsSave || RUINSaveNamespaceBinding(bindingGroup,reconciled);
                    return namespaceBindingPersisted;
                });
            if (!mapping) { keychainBindingStatus = @"NamespaceBindingUnavailable"; RUIN_PROFILE_END(RUINProfileStatusFailed); return; }
            RUIN_PROFILE_END(RUINProfileStatusOK);
        }

        RUIN_PROFILE_BEGIN("keychain.resolve_operations");
        BOOL operationsResolved = RUINResolveSecurityItemOperations();
        RUIN_PROFILE_END(operationsResolved ? RUINProfileStatusOK : RUINProfileStatusFailed);
        if (!operationsResolved) {
            compatibilityReady = NO;
            keychainBindingStatus = @"RebindUnavailable";
            return;
        }
        struct rebinding rebindings[] = {
            {"SecItemCopyMatching", (void *)RUINNativeFunctionPointerRaw((const void *)RUINSecItemCopyMatching), NULL},
            {"SecItemAdd", (void *)RUINNativeFunctionPointerRaw((const void *)RUINSecItemAdd), NULL},
            {"SecItemUpdate", (void *)RUINNativeFunctionPointerRaw((const void *)RUINSecItemUpdate), NULL},
            {"SecItemDelete", (void *)RUINNativeFunctionPointerRaw((const void *)RUINSecItemDelete), NULL}
        };
        RUIN_PROFILE_BEGIN("keychain.rebind_symbols");
        int result = rebind_symbols_image((void *)mainImage.header, mainImage.slide,
            rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
        RUIN_PROFILE_END(result == 0 ? RUINProfileStatusOK : RUINProfileStatusFailed);
        compatibilityReady = namespaceBindingPersisted && result == 0 && originalSecItemCopyMatching && originalSecItemAdd &&
            originalSecItemUpdate && originalSecItemDelete;
        keychainBindingStatus = compatibilityReady ? @"RebindReady" : @"RebindUnavailable";
    }
}
#endif

NSDictionary *RUINKeychainDiagnostics(void) {
    BOOL canReset = !compatibilityReady &&
        [keychainBindingStatus isEqualToString:@"NamespaceBindingUnavailable"] &&
        lastDefaultProbeStatus == errSecSuccess &&
        lastBindingLoadStatus != errSecInteractionNotAllowed;
    return @{@"mappedKeychainQueries": @(atomic_load_explicit(&mappedQueries, memory_order_relaxed)),
        @"accessGroupMappingCount":@(accessGroupMap.count), @"ready":@(compatibilityReady),
        @"namespaceBindingPersisted":@(namespaceBindingPersisted),
        @"bindingStatus":keychainBindingStatus,
        @"lastDefaultProbeStatus":@(lastDefaultProbeStatus),
        @"lastAppGroupProbeStatus":@(lastAppGroupProbeStatus),
        @"lastSharedGroupProbeStatus":@(lastSharedGroupProbeStatus),
        @"lastBindingLoadStatus":@(lastBindingLoadStatus),
        @"lastBindingSaveStatus":@(lastBindingSaveStatus),
        @"lastBindingResetStatus":@(lastBindingResetStatus),
        @"lastBindingRejectReason":lastBindingRejectReason ?: @"none",
        @"canResetBinding":@(canReset)};
}

BOOL RUINKeychainCompatibilityReady(void) { return compatibilityReady; }

#if !defined(RUIN_KEYCHAIN_HOST_CHECK)
BOOL RUINResetKeychainNamespaceBinding(void) {
    @synchronized (NSProcessInfo.processInfo) {
        if (compatibilityReady) return YES;
        NSMutableArray<NSString *> *groups = [NSMutableArray array];
        for (NSString *logical in @[RUINOldSharedAccessGroup, RUINOldAppAccessGroup]) {
            id group = accessGroupMap[logical];
            if ([group isKindOfClass:NSString.class] && [group length] && ![groups containsObject:group])
                [groups addObject:group];
        }
        NSString *defaultGroup = RUINDefaultAccessGroupWithOperations(SecItemAdd, SecItemDelete);
        if (defaultGroup.length && ![groups containsObject:defaultGroup])
            [groups addObject:defaultGroup];
        OSStatus deleteStatus = errSecItemNotFound;
        for (NSString *group in groups) {
            NSDictionary *query = @{
                (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService: @"com.tqmane.ruin.keychain-namespace",
                (__bridge id)kSecAttrAccount: @"line-api-groups-v1",
                (__bridge id)kSecAttrAccessGroup: group
            };
            OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
            if (status == errSecSuccess || (deleteStatus == errSecItemNotFound && status != errSecItemNotFound))
                deleteStatus = status;
        }
        if (deleteStatus == errSecItemNotFound) {
            NSDictionary *fallbackQuery = @{
                (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService: @"com.tqmane.ruin.keychain-namespace",
                (__bridge id)kSecAttrAccount: @"line-api-groups-v1"
            };
            deleteStatus = SecItemDelete((__bridge CFDictionaryRef)fallbackQuery);
        }
        lastBindingResetStatus = deleteStatus;
        accessGroupMap = nil;
        namespaceBindingPersisted = NO;
        lastBindingRejectReason = @"none";
        keychainBindingStatus = @"NotAttempted";
    }
    RUINInstallKeychainCompatibility();
    return compatibilityReady;
}
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
