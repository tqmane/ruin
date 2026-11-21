/* Compile with RUIN_KEYCHAIN_HOST_CHECK; all Security operations below are fakes. */
#define RUIN_KEYCHAIN_HOST_CHECK 1
#import "../src/platform/Keychain.m"
#import <assert.h>
#import <stdio.h>

extern const RUINVersionMapping RUINLINE26160;
extern const RUINVersionMapping RUINLINE26170;

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

        const RUINVersionMapping *mapping2617 = &RUINLINE26170;
        const RUINVersionMapping *mapping2616 = &RUINLINE26160;
        struct { struct mach_header_64 header; struct uuid_command uuid; } plainMainStorage = {0};
        plainMainStorage.header = (struct mach_header_64){.magic = MH_MAGIC_64, .cputype = CPU_TYPE_ARM64,
            .cpusubtype = CPU_SUBTYPE_ARM64_ALL, .filetype = MH_EXECUTE, .ncmds = 1,
            .sizeofcmds = sizeof(plainMainStorage.uuid)};
        plainMainStorage.uuid.cmd = LC_UUID;
        plainMainStorage.uuid.cmdsize = sizeof(plainMainStorage.uuid);
        struct mach_header_64 *plainMainHeader = &plainMainStorage.header;
        NSUUID *mappingUUID = [[NSUUID alloc] initWithUUIDString:@(mapping2617->host.uuid)];
        [mappingUUID getUUIDBytes:plainMainStorage.uuid.uuid];
        RUINMainExecutableImage plainMain = {.header = plainMainHeader, .cpuType = CPU_TYPE_ARM64,
            .cpuSubtype = CPU_SUBTYPE_ARM64_ALL};
        memcpy(plainMain.uuid, plainMainStorage.uuid.uuid, sizeof(plainMain.uuid));
        assert(mapping2617->host.supportStatus == RUINMappingStatusUnverified);
        assert(RUINKeychainMainImageAllowsRebinding(mapping2617, &plainMain, YES));
        assert(RUINKeychainMainImageAllowsRebinding(mapping2617, &plainMain, NO));

        NSUUID *oldMappingUUID = [[NSUUID alloc] initWithUUIDString:@(mapping2616->host.uuid)];
        [oldMappingUUID getUUIDBytes:plainMainStorage.uuid.uuid];
        memcpy(plainMain.uuid, plainMainStorage.uuid.uuid, sizeof(plainMain.uuid));
        assert(!RUINKeychainMainImageAllowsRebinding(mapping2616, &plainMain, YES));
        assert(RUINKeychainMainImageAllowsRebinding(mapping2616, &plainMain, NO));
        [mappingUUID getUUIDBytes:plainMainStorage.uuid.uuid];
        memcpy(plainMain.uuid, plainMainStorage.uuid.uuid, sizeof(plainMain.uuid));

        assert(!RUINKeychainMainImageAllowsRebinding(NULL, &plainMain, YES));
        plainMainHeader->cpusubtype = CPU_SUBTYPE_ARM64E;
        plainMain.cpuSubtype = CPU_SUBTYPE_ARM64E;
        assert(!RUINKeychainMainImageAllowsRebinding(mapping2617, &plainMain, YES));
        plainMainHeader->cpusubtype = CPU_SUBTYPE_ARM64_ALL;
        plainMain.cpuSubtype = CPU_SUBTYPE_ARM64_ALL;
        plainMainHeader->filetype = MH_DYLIB;
        assert(!RUINKeychainMainImageAllowsRebinding(mapping2617, &plainMain, YES));
        plainMainHeader->filetype = MH_EXECUTE;
        plainMain.uuid[0] ^= 1;
        assert(!RUINKeychainMainImageAllowsRebinding(mapping2617, &plainMain, YES));
        plainMain.uuid[0] ^= 1;

        struct {
            struct mach_header_64 header;
            struct uuid_command uuid;
            struct segment_command_64 segment;
            struct section_64 section;
        } authenticatedMain = {0};
        authenticatedMain.header = *plainMainHeader;
        authenticatedMain.uuid = plainMainStorage.uuid;
        authenticatedMain.header.ncmds = 2;
        authenticatedMain.header.sizeofcmds = sizeof(authenticatedMain.uuid) +
            sizeof(authenticatedMain.segment) + sizeof(authenticatedMain.section);
        authenticatedMain.segment.cmd = LC_SEGMENT_64;
        authenticatedMain.segment.cmdsize = (uint32_t)(sizeof(authenticatedMain.segment) + sizeof(authenticatedMain.section));
        authenticatedMain.segment.nsects = 1;
        strcpy(authenticatedMain.segment.segname, "__AUTH_CONST");
        strcpy(authenticatedMain.section.sectname, "__auth_got");
        RUINMainExecutableImage authenticatedMainImage = plainMain;
        authenticatedMainImage.header = &authenticatedMain.header;
        assert(!RUINKeychainMainImageAllowsRebinding(mapping2617, &authenticatedMainImage, YES));

        NSDictionary *allowedOriginalGroups = RUINPermissions(
            @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup], @[]);
        BOOL originalGroupsAllowed = NO;
        NSDictionary *unchanged = RUINMapWithPermissionsAndProof(
            @"HOSTPREFIX.jp.naver.line", logicalLINE, allowedOriginalGroups, &originalGroupsAllowed);
        assert(unchanged && unchanged.count == 0);
        assert(originalGroupsAllowed);
        NSString *unchangedCanonicalAppGroup = RUINCanonicalAppAccessGroup(@"HOSTPREFIX.jp.naver.line.generic");
        assert(unchangedCanonicalAppGroup && !unchanged[unchangedCanonicalAppGroup]);
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
        NSString *canonicalAppGroup = RUINCanonicalAppAccessGroup(defaultGroup);
        assert([canonicalAppGroup isEqualToString:@"HOSTPREFIX.jp.naver.line"]);
        assert([genericMissingMetadata[canonicalAppGroup] isEqualToString:defaultGroup]);
        NSString *observedDefaultGroup = @"TESTTEAM01.app.example.signed";
        NSDictionary *observedEntitlementMap = RUINMapWithPermissions(observedDefaultGroup, logicalLINE,
            RUINPermissions(@[@"TESTTEAM01.com.linecorp.trident.shared"],
                @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup]));
        assert([observedEntitlementMap[@"TESTTEAM01.jp.naver.line"] isEqual:observedDefaultGroup]);
        // The same jp.naver.line metadata still needs a map when either original ACL is denied.
        assert(!originalGroupsAllowed);
        assert(RUINKeychainBindingActionForMap(genericMissingMetadata, originalGroupsAllowed,
            RUINKeychainMainImageAllowsRebinding(NULL, &plainMain, YES)) ==
            RUINKeychainBindingActionUnsupportedAuthenticatedImports);
        RUINKeychainBindingAction arm64eMappedAction = RUINKeychainBindingActionForMap(
            genericMissingMetadata, originalGroupsAllowed, NO);
        assert(arm64eMappedAction == RUINKeychainBindingActionUnsupportedAuthenticatedImports);
        assert(!RUINKeychainBindingActionNeedsRebind(arm64eMappedAction));
        assert(!RUINKeychainBindingActionCanReadyWithoutRebind(arm64eMappedAction));
        assert(RUINKeychainBindingActionForMap(genericMissingMetadata, originalGroupsAllowed, YES) ==
               RUINKeychainBindingActionRebind);
        assert(RUINKeychainBindingActionNeedsRebind(
            RUINKeychainBindingActionForMap(genericMissingMetadata, originalGroupsAllowed, YES)));
        accessGroupMap = genericMissingMetadata;
        NSDictionary *mappedApp = RUINMappedAttributes((__bridge CFDictionaryRef)originalAttributes);
        assert([mappedApp[(__bridge id)kSecAttrAccessGroup] isEqualToString:defaultGroup]);
        NSDictionary *canonicalAppAttributes = @{(__bridge id)kSecAttrAccessGroup:canonicalAppGroup};
        assert([RUINMappedAttributes((__bridge CFDictionaryRef)canonicalAppAttributes)[(__bridge id)kSecAttrAccessGroup]
            isEqualToString:defaultGroup]);

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
        __block NSDictionary *fallbackBinding;
        NSDictionary *pinnedFallback = RUINApplyAccessGroupBinding(deniedSharedCandidate, nil, defaultGroup,
            ^RUINGroupPermission(NSString *group) { return [group isEqual:defaultGroup]
                ? RUINGroupPermissionAllowed : RUINGroupPermissionDenied; },
            ^BOOL(NSDictionary *mapping) { fallbackBinding = @{@"version":@1, @"groups":mapping}; return YES; });
        assert([pinnedFallback isEqual:deniedSharedCandidate] && fallbackBinding);
        assert([RUINReuseAccessGroupBinding(deniedSharedCandidate, fallbackBinding, defaultGroup,
            ^RUINGroupPermission(NSString *group) { return [group isEqual:defaultGroup]
                ? RUINGroupPermissionAllowed : RUINGroupPermissionDenied; }) isEqual:pinnedFallback]);
        assert(!RUINApplyAccessGroupBinding(deniedSharedCandidate, nil, defaultGroup,
            ^RUINGroupPermission(NSString *group) { (void)group; return RUINGroupPermissionAllowed; },
            ^BOOL(NSDictionary *mapping) { (void)mapping; return NO; }));
        assert(!RUINReuseAccessGroupBinding(deniedSharedCandidate, fallbackBinding, defaultGroup,
            ^RUINGroupPermission(NSString *group) { (void)group; return RUINGroupPermissionUnknown; }));

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
        assert([reused[canonicalAppGroup] isEqual:@"HOSTPREFIX.previous.signed.app"]);
        assert(persistCalls == 1 && accessGroupMap == reused);
        assert([RUINMappedAttributes((__bridge CFDictionaryRef)originalAttributes)[(__bridge id)kSecAttrAccessGroup]
            isEqual:@"HOSTPREFIX.previous.signed.app"]);
        assert([RUINMappedAttributes((__bridge CFDictionaryRef)canonicalAppAttributes)[(__bridge id)kSecAttrAccessGroup]
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

        NSDictionary *partialSaved = @{@"version": @1, @"groups": @{RUINOldAppAccessGroup: @"HOSTPREFIX.previous.signed.app"}};
        gFakePermissions = RUINPermissions(@[@"HOSTPREFIX.previous.signed.app", defaultGroup], @[]);
        NSDictionary *filledPartial = RUINReuseAccessGroupBinding(deniedSharedCandidate, partialSaved, defaultGroup,
            ^RUINGroupPermission(NSString *group) { return RUINFakePermission(group); });
        assert([filledPartial[RUINOldAppAccessGroup] isEqual:@"HOSTPREFIX.previous.signed.app"]);
        assert([filledPartial[RUINOldSharedAccessGroup] isEqual:defaultGroup]);
        assert([lastBindingRejectReason isEqual:@"none"]);

        NSDictionary *deniedPrevious = RUINPermissions(@[defaultShared], @[@"HOSTPREFIX.previous.signed.app"]);
        gFakePermissions = deniedPrevious;
        assert(!RUINReuseAccessGroupBinding(genericMissingMetadata, savedBinding, defaultGroup,
            ^RUINGroupPermission(NSString *group) { return RUINFakePermission(group); }));
        assert([lastBindingRejectReason isEqual:@"denied:HOSTPREFIX.previous.signed.app"]);
        assert(!RUINReuseAccessGroupBinding(genericMissingMetadata, @{@"version": @2}, defaultGroup,
            ^RUINGroupPermission(NSString *group) { return RUINFakePermission(group); }));
        assert([lastBindingRejectReason isEqual:@"malformed:2"]);
        NSDictionary *diag = RUINKeychainDiagnostics();
        assert([diag[@"lastBindingRejectReason"] length] && diag[@"lastBindingResetStatus"] && diag[@"canResetBinding"]);

        // Wildcard keychain-access-groups ("<TEAMID>.*") must resolve its Team prefix and reuse cleanly.
        assert([RUINIdentifierPrefix(@"J36T6YMF29.*") isEqualToString:@"J36T6YMF29"]);
        assert(!RUINIdentifierPrefix(@"BADPREFIX*.bundle"));
        assert(!RUINIdentifierPrefix(@"J36T6YMF29.app*"));
        assert(!RUINIdentifierPrefix(@"*.bundle"));
        NSString *wildcardGroup = @"J36T6YMF29.*";
        gFakePermissions = RUINPermissions(@[wildcardGroup], @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup, @"J36T6YMF29.com.linecorp.trident.shared"]);
        NSDictionary *wildcardMap = RUINMapWithPermissions(wildcardGroup, @{}, RUINPermissions(
            @[wildcardGroup], @[RUINOldAppAccessGroup, RUINOldSharedAccessGroup, @"J36T6YMF29.com.linecorp.trident.shared"]));
        assert([wildcardMap[RUINOldAppAccessGroup] isEqualToString:wildcardGroup]);
        assert([wildcardMap[RUINOldSharedAccessGroup] isEqualToString:wildcardGroup]);
        assert([wildcardMap[@"J36T6YMF29.jp.naver.line"] isEqualToString:wildcardGroup]);
        NSDictionary *wildcardSaved = @{@"version": @1, @"groups": @{
            RUINOldAppAccessGroup: wildcardGroup,
            RUINOldSharedAccessGroup: wildcardGroup}};
        NSDictionary *wildcardReused = RUINReuseAccessGroupBinding(wildcardMap, wildcardSaved, wildcardGroup,
            ^RUINGroupPermission(NSString *group) { return RUINFakePermission(group); });
        assert([wildcardReused isEqual:wildcardMap] && [lastBindingRejectReason isEqualToString:@"none"]);

        puts("PASS keychain identity gates, scoped group mapping and probe cleanup");
    }
    return 0;
}
