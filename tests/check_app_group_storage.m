#import "../src/platform/AppGroupStorage.h"
#import <assert.h>
#import <stdio.h>

static NSURL *Directory(NSURL *base, NSString *relativePath) {
    NSURL *url = [base URLByAppendingPathComponent:relativePath isDirectory:YES];
    assert([NSFileManager.defaultManager createDirectoryAtURL:url
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL]);
    return url;
}

static void AddLINEStore(NSURL *container, NSString *storeName) {
    NSURL *messages = [container URLByAppendingPathComponent:@"Library/Application Support/PrivateStore"
                                                isDirectory:YES];
    messages = [messages URLByAppendingPathComponent:storeName isDirectory:YES];
    messages = [messages URLByAppendingPathComponent:@"Messages" isDirectory:YES];
    assert([NSFileManager.defaultManager createDirectoryAtURL:messages
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL]);
    assert([storeName hasPrefix:@"P_"] || [storeName hasPrefix:@"S_"]);
    NSURL *marker = [messages URLByAppendingPathComponent:@"E2EEData.sqlite"];
    assert([[NSData data] writeToURL:marker options:NSDataWritingAtomic error:NULL]);
}

static BOOL Resolve(NSString *account,
                    NSURL *nativeURL,
                    NSURL *fallbackURL,
                    NSDictionary *explicitMap,
                    NSDictionary *authorized,
                    NSArray<NSURL *> *legacyCandidates,
                    NSURL **resolvedURL,
                    NSString **suiteName,
                    RUINAppGroupStorageDisposition *disposition) {
    return RUINResolveAppGroupStorage(@"group.com.linecorp.line", account, nativeURL, fallbackURL,
                                      explicitMap, authorized, legacyCandidates,
                                      resolvedURL, suiteName, disposition, NULL);
}

static void AssertUnsafePreservesFallback(NSURL *fallbackURL,
                                          NSString *account,
                                          NSDictionary *explicitMap,
                                          NSDictionary *authorized,
                                          NSArray<NSURL *> *legacyCandidates) {
    NSURL *resolved = nil;
    NSString *suite = nil;
    RUINAppGroupStorageDisposition status = RUINAppGroupStorageDispositionNewFallback;
    BOOL available = Resolve(account, nil, fallbackURL, explicitMap, authorized,
                             legacyCandidates, &resolved, &suite, &status);
    assert(available);
    assert(status == RUINAppGroupStorageDispositionUnsafe);
    assert([resolved.path isEqualToString:fallbackURL.path]);
    assert(!suite);
}

static void TestNativeAndFallbackPolicy(NSURL *root) {
    NSURL *native = Directory(root, @"native");
    NSURL *fallback = Directory(root, @"fallback");
    NSURL *resolved = nil;
    NSString *suite = nil;
    RUINAppGroupStorageDisposition status = RUINAppGroupStorageDispositionUnsafe;
    assert(Resolve(@"fixture-account", native, fallback, nil, nil, nil,
                   &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionNative);
    assert([resolved.path isEqualToString:native.path]);
    assert([suite isEqualToString:@"group.com.linecorp.line"]);

    AddLINEStore(fallback, @"P_fixture-account");
    assert(Resolve(@"fixture-account", native, fallback, nil, nil, nil,
                   &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionUnsafe);
    assert([resolved.path isEqualToString:fallback.path]);
}

static void TestExplicitMapAndPersistedBinding(NSURL *root) {
    NSURL *fallback = Directory(root, @"fallback");
    NSURL *authorizedRoot = Directory(root, @"authorized");
    NSURL *mapped = [authorizedRoot URLByAppendingPathComponent:@"group-one" isDirectory:YES];
    NSString *group = @"group.profile.one";
    NSDictionary *authorized = @{group:mapped};
    NSDictionary *explicitMap = @{@"group.com.linecorp.line":group};
    NSURL *resolved = nil;
    NSString *suite = nil;
    RUINAppGroupStorageDisposition status = RUINAppGroupStorageDispositionUnsafe;

    assert(Resolve(@"fixture-account", nil, fallback, explicitMap, authorized, nil,
                   &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionExplicitMap);
    assert([resolved.path isEqualToString:mapped.path]);
    assert([suite isEqualToString:group]);
    assert(RUINRecordExplicitAppGroupBinding(@"group.com.linecorp.line", group, authorized, NULL));
    assert(RUINRecordExplicitAppGroupBinding(@"group.com.linecorp.line", group, authorized, NULL));

    NSURL *markerDirectory = [mapped URLByAppendingPathComponent:@"Library" isDirectory:YES];
    markerDirectory = [markerDirectory URLByAppendingPathComponent:@"Application Support" isDirectory:YES];
    markerDirectory = [markerDirectory URLByAppendingPathComponent:@"RUINAppGroupBindings" isDirectory:YES];
    NSURL *marker = [markerDirectory URLByAppendingPathComponent:@"group.com.linecorp.line.plist"];
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfURL:marker];
    assert(values.count == 2);
    assert([values[@"purpose"] isEqualToString:@"group.com.linecorp.line"]);
    assert([values[@"version"] integerValue] == 1);
    assert(!values[@"teamIdentifier"] && !values[@"account"]);
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:marker.path error:NULL];
    assert([attributes[NSFilePosixPermissions] unsignedShortValue] == 0600);

    assert(Resolve(@"fixture-account", nil, fallback, nil, authorized, nil,
                   &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionPersistedMap);
    assert([resolved.path isEqualToString:mapped.path]);
    assert([suite isEqualToString:group]);
}

static void TestEmptyAccountResolution(NSURL *root) {
    NSURL *fallback = Directory(root, @"fallback");
    NSURL *native = Directory(root, @"native");
    NSURL *resolved = nil;
    NSString *suite = nil;
    RUINAppGroupStorageDisposition status = RUINAppGroupStorageDispositionUnsafe;

    assert(Resolve(nil, native, fallback, nil, nil, nil, &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionNative);
    assert([resolved.path isEqualToString:native.path]);

    NSURL *authorizedRoot = Directory(root, @"authorized");
    NSURL *mapped = [authorizedRoot URLByAppendingPathComponent:@"group-one" isDirectory:YES];
    NSDictionary *authorized = @{ @"group.profile.one":mapped };
    NSDictionary *explicitMap = @{ @"group.com.linecorp.line":@"group.profile.one" };
    assert(Resolve(@"", nil, fallback, explicitMap, authorized, nil, &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionExplicitMap);
    assert(RUINRecordExplicitAppGroupBinding(@"group.com.linecorp.line", @"group.profile.one", authorized, NULL));
    assert(Resolve(@"", nil, fallback, nil, authorized, nil, &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionPersistedMap);
    assert([resolved.path isEqualToString:mapped.path]);

    NSURL *existingFallback = Directory(root, @"existing-fallback");
    AddLINEStore(existingFallback, @"P_fixture-account");
    assert(Resolve(nil, nil, existingFallback, nil, nil, nil, &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionExistingFallback);
    assert([resolved.path isEqualToString:existingFallback.path]);

    NSURL *freshFallback = Directory(root, @"fresh-fallback");
    assert(Resolve(@"", nil, freshFallback, nil, nil, nil, &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionNewFallback);
    assert([resolved.path isEqualToString:freshFallback.path]);
}

static void TestFallbackPreservedAndLegacyCandidate(NSURL *root) {
    NSURL *fallback = Directory(root, @"fallback");
    NSURL *legacy = Directory(root, @"legacy/S_fixture-account");
    AddLINEStore(fallback, @"P_fixture-account");
    AddLINEStore(legacy, @"S_fixture-account");
    NSURL *mapped = Directory(root, @"mapped-empty");
    AssertUnsafePreservesFallback(fallback, @"fixture-account",
        @{@"group.com.linecorp.line":@"group.profile.empty"},
        @{@"group.profile.empty":mapped}, nil);
    NSURL *resolved = nil;
    NSString *suite = nil;
    RUINAppGroupStorageDisposition status = RUINAppGroupStorageDispositionUnsafe;

    assert(Resolve(@"fixture-account", nil, fallback, nil, nil, @[legacy],
                   &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionUnsafe);
    assert([resolved.path isEqualToString:fallback.path]);

    NSURL *emptyFallback = Directory(root, @"empty-fallback");
    assert(Resolve(@"fixture-account", nil, emptyFallback, nil, nil, @[legacy],
                   &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionLegacyMainCandidate);
    assert([resolved.path isEqualToString:legacy.path]);
    assert(!suite);

    NSURL *otherLegacy = Directory(root, @"legacy-two/S_fixture-account");
    AddLINEStore(otherLegacy, @"S_fixture-account");
    AssertUnsafePreservesFallback(emptyFallback, @"fixture-account", nil, nil, @[legacy, otherLegacy]);
    AssertUnsafePreservesFallback(emptyFallback, @"", nil, nil, @[legacy]);

    NSURL *wrongAccount = Directory(root, @"wrong-account/S_other-account");
    AddLINEStore(wrongAccount, @"S_other-account");
    AssertUnsafePreservesFallback(emptyFallback, @"fixture-account", nil, nil, @[wrongAccount]);
    assert(Resolve(@"", nil, fallback, nil, nil, nil, &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionExistingFallback);
    assert([resolved.path isEqualToString:fallback.path]);
}

static void TestUnsafeMappingsAndMarkers(NSURL *root) {
    NSURL *fallback = Directory(root, @"fallback");
    NSURL *groupOne = Directory(root, @"authorized/group-one");
    NSURL *groupTwo = Directory(root, @"authorized/group-two");
    NSDictionary *authorized = @{ @"group.profile.one":groupOne, @"group.profile.two":groupTwo };

    assert(!RUINRecordExplicitAppGroupBinding(@"group.com.linecorp.line", @"group.profile.missing", authorized, NULL));
    AssertUnsafePreservesFallback(fallback, @"fixture-account",
        @{@"group.com.linecorp.line":@"group.profile.missing"}, authorized, nil);
    NSDictionary *deniedContainer = @{ @"group.profile.denied":[NSURL URLWithString:@"https://invalid.example/"] };
    AssertUnsafePreservesFallback(fallback, @"fixture-account",
        @{@"group.com.linecorp.line":@"group.profile.denied"}, deniedContainer, nil);

    assert(RUINRecordExplicitAppGroupBinding(@"group.com.linecorp.line", @"group.profile.one", authorized, NULL));
    assert(RUINRecordExplicitAppGroupBinding(@"group.com.linecorp.line", @"group.profile.two", authorized, NULL));
    AssertUnsafePreservesFallback(fallback, @"fixture-account", nil, authorized, nil);

    NSURL *conflictFallback = Directory(root, @"fallback-with-data");
    AddLINEStore(conflictFallback, @"P_fixture-account");
    AddLINEStore(groupOne, @"P_fixture-account");
    AssertUnsafePreservesFallback(conflictFallback, @"fixture-account", nil,
                                  @{@"group.profile.one":groupOne}, nil);

    NSURL *invalidMarkerGroup = Directory(root, @"authorized/invalid-marker");
    NSURL *invalidMarkerDirectory = [invalidMarkerGroup URLByAppendingPathComponent:@"Library" isDirectory:YES];
    invalidMarkerDirectory = [invalidMarkerDirectory URLByAppendingPathComponent:@"Application Support" isDirectory:YES];
    invalidMarkerDirectory = [invalidMarkerDirectory URLByAppendingPathComponent:@"RUINAppGroupBindings" isDirectory:YES];
    assert([NSFileManager.defaultManager createDirectoryAtURL:invalidMarkerDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL]);
    NSURL *invalidMarker = [invalidMarkerDirectory URLByAppendingPathComponent:@"group.com.linecorp.line.plist"];
    assert([[NSData dataWithBytes:"invalid" length:7] writeToURL:invalidMarker
                                                         options:NSDataWritingAtomic error:NULL]);
    AssertUnsafePreservesFallback(fallback, @"fixture-account", nil,
                                  @{@"group.profile.invalid":invalidMarkerGroup}, nil);
}

static void TestContainerAliases(NSURL *root) {
    NSURL *container = Directory(root, @"store");
    NSURL *emptyFallback = Directory(root, @"empty");
    Directory(root, @"sibling");
    AddLINEStore(container, @"P_fixture-account");
    NSURL *parentAlias = [root URLByAppendingPathComponent:@"parent-alias" isDirectory:YES];
    assert([NSFileManager.defaultManager createSymbolicLinkAtURL:parentAlias
        withDestinationURL:root error:NULL]);
    NSArray<NSURL *> *aliases = @[
        [parentAlias URLByAppendingPathComponent:@"store" isDirectory:YES],
        [NSURL fileURLWithPath:[root.path stringByAppendingString:@"/sibling/../store/"]],
        [NSURL fileURLWithPath:[container.path stringByAppendingString:@"/"]]
    ];
    NSURL *resolved = nil;
    NSString *suite = nil;
    RUINAppGroupStorageDisposition status;
    for (NSURL *alias in aliases) {
        assert(Resolve(@"fixture-account", container, alias, nil, nil, nil,
                       &resolved, &suite, &status));
        assert(status == RUINAppGroupStorageDispositionNative);
        assert([resolved isEqual:container]);
        assert(Resolve(@"fixture-account", alias, container, nil, nil, nil,
                       &resolved, &suite, &status));
        assert(status == RUINAppGroupStorageDispositionNative);
        assert([resolved isEqual:alias]);
        assert(Resolve(@"fixture-account", nil, emptyFallback, nil, nil, @[container, alias],
                       &resolved, &suite, &status));
        assert(status == RUINAppGroupStorageDispositionLegacyMainCandidate);
        assert([resolved isEqual:container]);
        assert(Resolve(@"fixture-account", nil, container, nil, nil, @[alias],
                       &resolved, &suite, &status));
        assert(status == RUINAppGroupStorageDispositionExistingFallback);
        assert([resolved isEqual:container]);
        assert(!suite);
    }

    NSString *group = @"group.profile.alias";
    NSDictionary *authorized = @{group:container};
    NSDictionary *mapping = @{@"group.com.linecorp.line":group};
    assert(RUINRecordExplicitAppGroupBinding(@"group.com.linecorp.line", group, authorized, NULL));
    for (NSURL *alias in aliases) {
        assert(Resolve(@"fixture-account", alias, emptyFallback, mapping, authorized, nil,
                       &resolved, &suite, &status));
        assert(status == RUINAppGroupStorageDispositionNative);
        assert([resolved isEqual:alias]);
        assert(Resolve(@"fixture-account", nil, alias, mapping, authorized, nil,
                       &resolved, &suite, &status));
        assert(status == RUINAppGroupStorageDispositionExplicitMap);
        assert([resolved isEqual:container]);
        assert(Resolve(@"fixture-account", nil, alias, nil, authorized, nil,
                       &resolved, &suite, &status));
        assert(status == RUINAppGroupStorageDispositionPersistedMap);
        assert([resolved isEqual:container]);
    }

    // Comparing identities must not admit a symlink as a container root.
    NSURL *rootAlias = [root URLByAppendingPathComponent:@"root-alias" isDirectory:YES];
    assert([NSFileManager.defaultManager createSymbolicLinkAtURL:rootAlias
        withDestinationURL:container error:NULL]);
    assert(Resolve(@"fixture-account", rootAlias, emptyFallback, nil, nil, nil,
                   &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionUnsafe);
    assert([resolved isEqual:emptyFallback]);
    AssertUnsafePreservesFallback(emptyFallback, @"fixture-account", nil, nil, @[rootAlias]);
}

static void TestDistinctStoresThroughParentAlias(NSURL *root) {
    NSURL *native = Directory(root, @"left/store");
    NSURL *other = Directory(root, @"right/store");
    NSURL *destination = Directory(root, @"right/nested");
    AddLINEStore(native, @"P_fixture-account");
    AddLINEStore(other, @"P_fixture-account");
    NSURL *link = [root URLByAppendingPathComponent:@"left/jump" isDirectory:YES];
    assert([NSFileManager.defaultManager createSymbolicLinkAtURL:link
        withDestinationURL:destination error:NULL]);
    NSURLComponents *components = [NSURLComponents componentsWithURL:link resolvingAgainstBaseURL:NO];
    components.path = [link.path stringByAppendingString:@"/../store"];
    NSURL *fallback = components.URL;
    // Resolve '..' through the real parent: this is right/store, not left/store.
    NSURL *resolved = nil;
    NSString *suite = nil;
    RUINAppGroupStorageDisposition status;
    NSError *error = nil;
    assert(RUINResolveAppGroupStorage(@"group.com.linecorp.line", @"fixture-account",
        native, fallback, nil, nil, nil, &resolved, &suite, &status, &error));
    assert(status == RUINAppGroupStorageDispositionUnsafe);
    assert([error.domain isEqualToString:RUINAppGroupStorageErrorDomain] &&
           error.code == RUINAppGroupStorageErrorConflictingStores);
    assert([resolved isEqual:fallback]);
    assert(!suite);
}

static void TestSandboxOwnerBinding(NSURL *root) {
    NSURL *fresh = [root URLByAppendingPathComponent:@"fresh" isDirectory:YES];
    NSString *logical = @"group.com.linecorp.line";
    assert(!RUINVerifySandboxAppGroupStorageBinding(logical, @"TEAM.fixture.app", fresh, NULL));
    assert(![NSFileManager.defaultManager fileExistsAtPath:fresh.path]);
    NSURL *empty = Directory(root, @"empty");
    assert(!RUINVerifySandboxAppGroupStorageBinding(logical, @"TEAM.fixture.app", empty, NULL));
    assert([NSFileManager.defaultManager contentsOfDirectoryAtPath:empty.path error:NULL].count == 0);

    assert(RUINPinSandboxAppGroupStorage(logical, @"TEAM.fixture.app", fresh, NULL));
    NSURL *marker = [fresh URLByAppendingPathComponent:
        @"Library/Application Support/RUINAppGroupBindings/group.com.linecorp.line.plist"];
    NSData *originalMarker = [NSData dataWithContentsOfURL:marker];
    assert(originalMarker.length && RUINVerifySandboxAppGroupStorageBinding(logical, @"TEAM.fixture.app", fresh, NULL));
    AddLINEStore(fresh, @"P_fixture-account");
    assert(RUINVerifySandboxAppGroupStorageBinding(logical, @"TEAM.fixture.app", fresh, NULL));
    assert(RUINPinSandboxAppGroupStorage(logical, @"TEAM.fixture.app", fresh, NULL));
    assert(!RUINVerifySandboxAppGroupStorageBinding(logical, @"OTHER.fixture.app", fresh, NULL));
    assert(!RUINPinSandboxAppGroupStorage(logical, @"OTHER.fixture.app", fresh, NULL));
    assert([[NSData dataWithContentsOfURL:marker] isEqual:originalMarker]);
    NSURL *unmarked = Directory(root, @"unmarked"); AddLINEStore(unmarked, @"P_fixture-account");
    assert(!RUINVerifySandboxAppGroupStorageBinding(logical, @"TEAM.fixture.app", unmarked, NULL));
    assert(!RUINPinSandboxAppGroupStorage(logical, @"TEAM.fixture.app", unmarked, NULL));
    assert(!RUINPinSandboxAppGroupStorage(logical, @"", fresh, NULL));

    NSURL *ownerless = Directory(root, @"ownerless");
    assert(RUINRecordExplicitAppGroupBinding(logical, @"group.fixture.ownerless",
        @{@"group.fixture.ownerless":ownerless}, NULL));
    assert(!RUINVerifySandboxAppGroupStorageBinding(logical, @"TEAM.fixture.app", ownerless, NULL));
    assert(!RUINPinSandboxAppGroupStorage(logical, @"TEAM.fixture.app", ownerless, NULL));
}

static void TestPinnedFallbackWithUnrelatedLegacy(NSURL *root) {
    NSString *logical = @"group.com.linecorp.line", *owner = @"TEAM.fixture.app";
    NSURL *fallback = [root URLByAppendingPathComponent:@"pinned" isDirectory:YES];
    assert(RUINPinSandboxAppGroupStorage(logical, owner, fallback, NULL));
    AddLINEStore(fallback, @"P_fixture-account");
    NSURL *legacy = Directory(root, @"authorized-legacy"); AddLINEStore(legacy, @"S_unrelated-account");
    NSDictionary *authorized = @{@"group.profile.legacy":legacy};
    NSArray *candidates = authorized.allValues;
    // The resolver's conflict guard remains in force when legacy discovery is requested.
    AssertUnsafePreservesFallback(fallback, @"fixture-account", nil, authorized, candidates);
    BOOL pinned = RUINVerifySandboxAppGroupStorageBinding(logical, owner, fallback, NULL);
    assert(pinned);
    NSURL *resolved = nil; NSString *suite = nil;
    RUINAppGroupStorageDisposition status;
    assert(Resolve(@"fixture-account", nil, fallback, nil, authorized, pinned ? @[] : candidates,
        &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionExistingFallback && [resolved isEqual:fallback] && !suite);

    NSURL *unmarked = Directory(root, @"unmarked"); AddLINEStore(unmarked, @"P_fixture-account");
    NSURL *otherOwner = [root URLByAppendingPathComponent:@"other-owner" isDirectory:YES];
    assert(RUINPinSandboxAppGroupStorage(logical, @"OTHER.fixture.app", otherOwner, NULL));
    AddLINEStore(otherOwner, @"P_fixture-account");
    NSURL *invalid = [root URLByAppendingPathComponent:@"invalid" isDirectory:YES];
    assert(RUINPinSandboxAppGroupStorage(logical, owner, invalid, NULL));
    AddLINEStore(invalid, @"P_fixture-account");
    NSURL *invalidMarker = [invalid URLByAppendingPathComponent:
        @"Library/Application Support/RUINAppGroupBindings/group.com.linecorp.line.plist"];
    assert([[@"invalid marker" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:invalidMarker options:0 error:NULL]);
    for (NSURL *rejected in @[unmarked, otherOwner, invalid]) {
        BOOL bound = RUINVerifySandboxAppGroupStorageBinding(logical, owner, rejected, NULL);
        assert(!bound);
        AssertUnsafePreservesFallback(rejected, @"fixture-account", nil, authorized, bound ? @[] : candidates);
    }

    // A sandbox pin does not bypass native, explicit-map, or persisted-map conflicts.
    assert(Resolve(@"fixture-account", Directory(root, @"native"), fallback, nil, authorized, @[],
        &resolved, &suite, &status));
    assert(status == RUINAppGroupStorageDispositionUnsafe && [resolved isEqual:fallback]);
    AssertUnsafePreservesFallback(fallback, @"fixture-account", @{logical:@"group.profile.legacy"}, authorized, @[]);
    assert(RUINRecordExplicitAppGroupBinding(logical, @"group.profile.legacy", authorized, NULL));
    AssertUnsafePreservesFallback(fallback, @"fixture-account", nil, authorized, @[]);
}

int main(void) {
    @autoreleasepool {
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                                isDirectory:YES];
        assert([NSFileManager.defaultManager createDirectoryAtURL:root
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL]);
        TestNativeAndFallbackPolicy(Directory(root, @"native-test"));
        TestSandboxOwnerBinding(Directory(root, @"sandbox-owner-test"));
        TestPinnedFallbackWithUnrelatedLegacy(Directory(root, @"pinned-legacy-test"));
        TestExplicitMapAndPersistedBinding(Directory(root, @"marker-test"));
        TestEmptyAccountResolution(Directory(root, @"empty-account-test"));
        TestFallbackPreservedAndLegacyCandidate(Directory(root, @"legacy-test"));
        TestUnsafeMappingsAndMarkers(Directory(root, @"unsafe-test"));
        TestContainerAliases(Directory(root, @"alias-test"));
        TestDistinctStoresThroughParentAlias(Directory(root, @"distinct-alias-test"));
        NSURL *partial = Directory(root, @"partial-fallback");
        NSURL *messages = Directory(partial, @"Library/Application Support/PrivateStore/P_fixture-account/Messages");
        assert([[NSData data] writeToURL:[messages URLByAppendingPathComponent:@"ChatExt.sqlite-wal"]
            options:NSDataWritingAtomic error:NULL]);
        AssertUnsafePreservesFallback(partial, @"fixture-account",
            @{@"group.com.linecorp.line":@"group.profile.one"},
            @{@"group.profile.one":Directory(root,@"partial-authorized")}, nil);
        [NSFileManager.defaultManager removeItemAtURL:root error:NULL];
        puts("PASS App Group namespace selection, directory identity and binding-marker policy");
    }
    return 0;
}
