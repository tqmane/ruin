/* Compile with RUIN_KEYCHAIN_HOST_CHECK; all Security operations below are fakes. */
#define RUIN_KEYCHAIN_HOST_CHECK 1
#import "../src/platform/Keychain.m"
#import <assert.h>
#import <stdio.h>

static NSDictionary *gFakePermissions;
static NSDictionary *gFakeAddResult;
static NSDictionary *gFakeAddAttributes;
static NSDictionary *gFakeDeleteQuery;
static OSStatus gFakeAddStatus;
static OSStatus gFakeDeleteStatus;
static NSUInteger gFakeAddCalls;
static NSUInteger gFakeDeleteCalls;

static RUINGroupPermission RUINFakePermission(NSString *group) {
    NSNumber *permission = gFakePermissions[group];
    return permission ? (RUINGroupPermission)permission.integerValue : RUINGroupPermissionUnknown;
}

static OSStatus RUINFakeAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    gFakeAddCalls++;
    gFakeAddAttributes = [(__bridge NSDictionary *)attributes copy];
    if (gFakeAddStatus == errSecSuccess && result && gFakeAddResult)
        *result = CFRetain((__bridge CFTypeRef)gFakeAddResult);
    return gFakeAddStatus;
}

static OSStatus RUINFakeDelete(CFDictionaryRef query) {
    gFakeDeleteCalls++;
    gFakeDeleteQuery = [(__bridge NSDictionary *)query copy];
    return gFakeDeleteStatus;
}

static NSString *RUINFakeDefaultGroup(NSDictionary *result, OSStatus addStatus, OSStatus deleteStatus) {
    gFakeAddResult = result;
    gFakeAddStatus = addStatus;
    gFakeDeleteStatus = deleteStatus;
    gFakeAddAttributes = nil;
    gFakeDeleteQuery = nil;
    gFakeAddCalls = 0;
    gFakeDeleteCalls = 0;
    return RUINDefaultAccessGroupWithOperations(RUINFakeAdd, RUINFakeDelete);
}

static NSDictionary *RUINPermissions(NSArray<NSString *> *allowed, NSArray<NSString *> *denied) {
    NSMutableDictionary *permissions = [NSMutableDictionary dictionary];
    for (NSString *group in allowed) permissions[group] = @(RUINGroupPermissionAllowed);
    for (NSString *group in denied) permissions[group] = @(RUINGroupPermissionDenied);
    return permissions;
}

static NSDictionary *RUINMapWithPermissionsAndProof(NSString *defaultGroup, NSDictionary *metadata,
                                                    NSDictionary *permissions, BOOL *originalGroupsAllowed) {
    gFakePermissions = permissions;
    return RUINBuildAccessGroupMap(defaultGroup, metadata,
        ^RUINGroupPermission(NSString *group) { return RUINFakePermission(group); }, originalGroupsAllowed);
}

static NSDictionary *RUINMapWithPermissions(NSString *defaultGroup, NSDictionary *metadata,
                                             NSDictionary *permissions) {
    return RUINMapWithPermissionsAndProof(defaultGroup, metadata, permissions, NULL);
}

int main(void) {
    @autoreleasepool {
        assert(RUINGroupPermissionForStatus(errSecSuccess) == RUINGroupPermissionAllowed);
        assert(RUINGroupPermissionForStatus(errSecItemNotFound) == RUINGroupPermissionUnknown);
        assert(RUINGroupPermissionForStatus(errSecMissingEntitlement) == RUINGroupPermissionDenied);
        assert(RUINGroupPermissionForStatus(errSecInteractionNotAllowed) == RUINGroupPermissionUnknown);

        NSDictionary *logicalLINE = @{
            @"CFBundleIdentifier": @"jp.naver.line",
            @"CFBundleShortVersionString": @"26.16.0",
            @"CFBundleVersion": @"2026.1006.1718"
        };
        assert(RUINKeychainTargetEligible(@"installed", logicalLINE));
        assert(RUINKeychainTargetEligible(@"already_original", logicalLINE));
        assert(!RUINKeychainTargetEligible(@"unsupported_binary", logicalLINE));
        assert(!RUINKeychainTargetEligible(@"installed", @{
            @"CFBundleIdentifier": @"generic.signed.app",
            @"CFBundleShortVersionString": @"26.16.0",
            @"CFBundleVersion": @"2026.1006.1718"
        }));

        NSDictionary *allowedOriginalGroups = RUINPermissions(
            @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup], @[]);
        BOOL originalGroupsAllowed = NO;
        NSDictionary *unchanged = RUINMapWithPermissionsAndProof(
            @"HOSTPREFIX.jp.naver.line", logicalLINE, allowedOriginalGroups, &originalGroupsAllowed);
        assert(unchanged && unchanged.count == 0);
        assert(originalGroupsAllowed);
        assert(RUINKeychainBindingActionForMap(unchanged, originalGroupsAllowed, YES) ==
               RUINKeychainBindingActionNativePassthrough);
        assert(RUINKeychainBindingActionCanReadyWithoutRebind(
            RUINKeychainBindingActionForMap(unchanged, originalGroupsAllowed, YES)));
        assert(RUINKeychainBindingActionForMap(unchanged, originalGroupsAllowed, NO) ==
               RUINKeychainBindingActionNativePassthrough);
        assert(RUINKeychainBindingActionCanReadyWithoutRebind(
            RUINKeychainBindingActionForMap(unchanged, originalGroupsAllowed, NO)));
        assert(RUINKeychainBindingActionForMap(@{}, NO, YES) ==
               RUINKeychainBindingActionPermissionUnproven);
        assert(!RUINKeychainBindingActionCanReadyWithoutRebind(
            RUINKeychainBindingActionForMap(@{}, NO, YES)));
        accessGroupMap = unchanged;
        NSDictionary *originalAttributes = @{
            (__bridge id)kSecAttrAccessGroup: RUINOldAppAccessGroup,
            @"value": @"preserve"
        };
        assert(!RUINMappedAttributes((__bridge CFDictionaryRef)originalAttributes));
        NSDictionary *unknownGroup = @{(__bridge id)kSecAttrAccessGroup: @"HOSTPREFIX.jp.naver.other"};
        assert(!RUINMappedAttributes((__bridge CFDictionaryRef)unknownGroup));

        NSString *defaultGroup = @"HOSTPREFIX.jp.naver.line.generic";
        NSString *defaultShared = @"HOSTPREFIX.com.linecorp.trident.shared";
        originalGroupsAllowed = YES;
        NSDictionary *genericMissingMetadata = RUINMapWithPermissionsAndProof(defaultGroup, logicalLINE,
            RUINPermissions(@[defaultShared], @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup]),
            &originalGroupsAllowed);
        assert([genericMissingMetadata[RUINOldAppAccessGroup] isEqualToString:defaultGroup]);
        assert([genericMissingMetadata[RUINOldSharedAccessGroup] isEqualToString:defaultShared]);
        // The same jp.naver.line metadata still needs a map when either original ACL is denied.
        assert(!originalGroupsAllowed);
        RUINKeychainBindingAction arm64eMappedAction = RUINKeychainBindingActionForMap(
            genericMissingMetadata, originalGroupsAllowed, YES);
        assert(arm64eMappedAction == RUINKeychainBindingActionUnsupportedAuthenticatedImports);
        assert(!RUINKeychainBindingActionNeedsRebind(arm64eMappedAction));
        assert(!RUINKeychainBindingActionCanReadyWithoutRebind(arm64eMappedAction));
        assert(RUINKeychainBindingActionForMap(genericMissingMetadata, originalGroupsAllowed, NO) ==
               RUINKeychainBindingActionRebind);
        assert(RUINKeychainBindingActionNeedsRebind(
            RUINKeychainBindingActionForMap(genericMissingMetadata, originalGroupsAllowed, NO)));
        accessGroupMap = genericMissingMetadata;
        NSDictionary *mappedApp = RUINMappedAttributes((__bridge CFDictionaryRef)originalAttributes);
        assert([mappedApp[(__bridge id)kSecAttrAccessGroup] isEqualToString:defaultGroup]);

        NSDictionary *oldMetadata = @{
            @"CFBundleIdentifier": @"generic.signed.app",
            @"RUINSignedBundleIdentifier": @"old.metadata.bundle",
            @"RUINSignedTeamIdentifier": @"PROFILETEAM",
            @"RUINSigningApplicationIdentifier": @"PROFILETEAM.jp.naver.line"
        };
        NSString *metadataShared = @"PROFILETEAM.com.linecorp.trident.shared";
        NSDictionary *oldProfileMap = RUINMapWithPermissions(defaultGroup, oldMetadata, RUINPermissions(
            @[metadataShared], @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup]));
        assert([oldProfileMap[RUINOldSharedAccessGroup] isEqualToString:metadataShared]);

        NSDictionary *applicationIDMetadata = @{
            @"RUINSigningApplicationIdentifier": @"APPIDPREFIX.jp.naver.line"
        };
        NSString *applicationIDShared = @"APPIDPREFIX.com.linecorp.trident.shared";
        NSDictionary *applicationIDMap = RUINMapWithPermissions(defaultGroup, applicationIDMetadata, RUINPermissions(
            @[applicationIDShared], @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup]));
        assert([applicationIDMap[RUINOldSharedAccessGroup] isEqualToString:applicationIDShared]);

        NSDictionary *wrongPrefixMetadata = @{@"RUINSignedTeamIdentifier": @"WRONGPREFIX"};
        NSString *wrongShared = @"WRONGPREFIX.com.linecorp.trident.shared";
        NSDictionary *wrongPrefixMap = RUINMapWithPermissions(defaultGroup, wrongPrefixMetadata, RUINPermissions(
            @[defaultShared], @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup, wrongShared]));
        assert([wrongPrefixMap[RUINOldSharedAccessGroup] isEqualToString:defaultShared]);

        NSDictionary *malformedMetadata = @{
            @"RUINSignedTeamIdentifier": @"BAD-PREFIX!",
            @"RUINSigningApplicationIdentifier": @"BADPREFIX*.bundle"
        };
        NSDictionary *malformedMap = RUINMapWithPermissions(defaultGroup, malformedMetadata,
            RUINPermissions(@[defaultShared], @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup]));
        assert([malformedMap[RUINOldSharedAccessGroup] isEqualToString:defaultShared]);

        NSDictionary *deniedSharedCandidate = RUINMapWithPermissions(defaultGroup, @{}, RUINPermissions(
            @[], @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup, defaultShared]));
        assert([deniedSharedCandidate[RUINOldSharedAccessGroup] isEqualToString:defaultGroup]);
        assert(!RUINHasStableSharedNamespace(deniedSharedCandidate));
        assert(RUINHasStableSharedNamespace(genericMissingMetadata));
        assert(RUINHasStableSharedNamespace(@{}));

        NSDictionary *unknownProbe = RUINMapWithPermissions(defaultGroup, @{}, RUINPermissions(
            @[defaultShared], @[RUINOldSharedAccessGroup]));
        assert(unknownProbe == nil);
        NSDictionary *unknownMetadataProbe = RUINMapWithPermissions(defaultGroup,
            @{@"RUINSignedTeamIdentifier": @"UNKNOWNPREFIX"}, RUINPermissions(
                @[defaultShared], @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup]));
        assert(unknownMetadataProbe == nil);
        NSDictionary *savedBinding = @{@"version":@1,@"groups":@{
            RUINOldAppAccessGroup:@"HOSTPREFIX.previous.signed.app",
            RUINOldSharedAccessGroup:defaultShared}};
        gFakePermissions = RUINPermissions(@[@"HOSTPREFIX.previous.signed.app",defaultShared],@[]);
        __block NSUInteger persistCalls = 0;
        accessGroupMap = genericMissingMetadata;
        NSDictionary *reused = RUINApplyAccessGroupBinding(genericMissingMetadata,savedBinding,
            defaultGroup,^RUINGroupPermission(NSString *group){return RUINFakePermission(group);},
            ^BOOL(NSDictionary *reconciled) {
                persistCalls++;
                assert(accessGroupMap == genericMissingMetadata);
                assert([reconciled[RUINOldAppAccessGroup] isEqual:@"HOSTPREFIX.previous.signed.app"]);
                return YES;
            });
        assert([reused[RUINOldAppAccessGroup] isEqual:@"HOSTPREFIX.previous.signed.app"]);
        assert(persistCalls == 1 && accessGroupMap == reused);
        assert([RUINMappedAttributes((__bridge CFDictionaryRef)originalAttributes)[(__bridge id)kSecAttrAccessGroup]
            isEqual:@"HOSTPREFIX.previous.signed.app"]);

        accessGroupMap = genericMissingMetadata;
        assert(!RUINApplyAccessGroupBinding(genericMissingMetadata,savedBinding,defaultGroup,
            ^RUINGroupPermission(NSString *group){return RUINFakePermission(group);},
            ^BOOL(__unused NSDictionary *reconciled) { persistCalls++; return NO; }));
        assert(persistCalls == 2 && accessGroupMap == genericMissingMetadata);
        gFakePermissions = RUINPermissions(@[defaultShared],@[@"HOSTPREFIX.previous.signed.app"]);
        assert(!RUINApplyAccessGroupBinding(genericMissingMetadata,savedBinding,defaultGroup,
            ^RUINGroupPermission(NSString *group){return RUINFakePermission(group);},
            ^BOOL(__unused NSDictionary *reconciled) { persistCalls++; return YES; }));
        assert(persistCalls == 2 && accessGroupMap == genericMissingMetadata);
        assert(!RUINReuseAccessGroupBinding(genericMissingMetadata,@{@"version":@2},defaultGroup,
            ^RUINGroupPermission(NSString *group){return RUINFakePermission(group);}));

        // Native entitlement access has always taken priority over saved overrides.
        NSString *changedDefaultGroup = @"OTHERPREFIX.changed.native.app";
        BOOL nativePermissionProof = NO;
        NSDictionary *nativeMap = RUINMapWithPermissionsAndProof(changedDefaultGroup, logicalLINE,
            allowedOriginalGroups, &nativePermissionProof);
        gFakePermissions = RUINPermissions(@[RUINOldAppAccessGroup,RUINOldSharedAccessGroup],
            @[@"HOSTPREFIX.previous.signed.app",defaultShared]);
        NSDictionary *nativeReused = RUINReuseAccessGroupBinding(nativeMap,savedBinding,changedDefaultGroup,
            ^RUINGroupPermission(NSString *group){return RUINFakePermission(group);});
        assert(nativeReused && nativeReused.count == 0 && nativePermissionProof);
        assert(RUINKeychainBindingActionCanReadyWithoutRebind(
            RUINKeychainBindingActionForMap(nativeReused,nativePermissionProof,YES)));
        assert(RUINKeychainBindingActionCanReadyWithoutRebind(
            RUINKeychainBindingActionForMap(nativeReused,nativePermissionProof,NO)));
        assert(!RUINKeychainBindingActionNeedsRebind(
            RUINKeychainBindingActionForMap(nativeReused,nativePermissionProof,YES)));

        gFakePermissions = RUINPermissions(@[RUINOldAppAccessGroup,defaultShared],
            @[@"HOSTPREFIX.previous.signed.app"]);
        NSDictionary *sharedOnly = RUINReuseAccessGroupBinding(@{RUINOldSharedAccessGroup:defaultShared},
            savedBinding,defaultGroup,^RUINGroupPermission(NSString *group){return RUINFakePermission(group);});
        assert(sharedOnly && !sharedOnly[RUINOldAppAccessGroup]);
        assert([sharedOnly[RUINOldSharedAccessGroup] isEqual:defaultShared]);

        NSString *detectedGroup = RUINFakeDefaultGroup(
            @{(__bridge id)kSecAttrAccessGroup: @"PROBEPREFIX.default.app"}, errSecSuccess, errSecSuccess);
        assert([detectedGroup isEqualToString:@"PROBEPREFIX.default.app"]);
        assert(gFakeAddCalls == 1 && gFakeDeleteCalls == 1);
        assert(!gFakeAddAttributes[(__bridge id)kSecAttrAccessGroup]);
        assert([gFakeAddAttributes[(__bridge id)kSecValueData] length] == 32);
        assert([gFakeAddAttributes[(__bridge id)kSecReturnAttributes] boolValue]);
        assert([gFakeAddAttributes[(__bridge id)kSecAttrAccessible] isEqual:
                (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]);
        assert([gFakeDeleteQuery[(__bridge id)kSecAttrService] isEqual:
                gFakeAddAttributes[(__bridge id)kSecAttrService]]);
        assert([gFakeDeleteQuery[(__bridge id)kSecAttrAccount] isEqual:
                gFakeAddAttributes[(__bridge id)kSecAttrAccount]]);
        assert([gFakeDeleteQuery[(__bridge id)kSecAttrAccessGroup] isEqual:detectedGroup]);
        assert(!gFakeDeleteQuery[(__bridge id)kSecValueData]);

        assert(!RUINFakeDefaultGroup(@{}, errSecSuccess, errSecSuccess));
        assert(gFakeDeleteCalls == 1 && !gFakeDeleteQuery[(__bridge id)kSecAttrAccessGroup]);
        assert(!RUINFakeDefaultGroup(@{(__bridge id)kSecAttrAccessGroup: @"PROBEPREFIX.default.app"},
                                      errSecSuccess, errSecInteractionNotAllowed));
        assert(gFakeDeleteCalls == 1);
        assert(!RUINFakeDefaultGroup(nil, errSecNotAvailable, errSecSuccess));
        assert(gFakeDeleteCalls == 0);

        puts("PASS keychain identity gates, scoped group mapping and probe cleanup");
    }
    return 0;
}
