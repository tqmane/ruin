#import "AppGroupStorage.h"
#import <errno.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <CommonCrypto/CommonDigest.h>

NSString *const RUINAppGroupStorageErrorDomain = @"RUINAppGroupStorage";

static NSString *const RUINBindingMarkerDirectoryName = @"RUINAppGroupBindings";
static NSString *const RUINBindingMarkerVersionKey = @"version";
static NSString *const RUINBindingMarkerPurposeKey = @"purpose";
static const NSInteger RUINBindingMarkerVersion = 1;

typedef NS_ENUM(NSInteger, RUINPathState) {
    RUINPathStateMissing,
    RUINPathStateReadable,
    RUINPathStateInaccessible
};

typedef struct {
    BOOL anyAccountHasLINEData;
    BOOL verifiedAccountHasLINEData;
    BOOL inaccessible;
} RUINContainerContents;

typedef NS_ENUM(NSInteger, RUINMarkerState) {
    RUINMarkerStateMissing,
    RUINMarkerStateValid,
    RUINMarkerStateInvalid,
    RUINMarkerStateInaccessible
};

static void RUINSetStorageError(NSError **error, RUINAppGroupStorageErrorCode code) {
    if (!error) return;
    NSString *description = @"App Group storage resolution failed.";
    *error = [NSError errorWithDomain:RUINAppGroupStorageErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey:description}];
}

static BOOL RUINIsSafeGroupIdentifier(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] ||
        ![identifier hasPrefix:@"group."] || identifier.length > 255) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"] invertedSet];
    return [identifier rangeOfCharacterFromSet:invalid].location == NSNotFound &&
           ![identifier containsString:@".."];
}

static BOOL RUINSameDirectory(NSURL *firstURL, NSURL *secondURL) {
    if (!firstURL.isFileURL || !secondURL.isFileURL) return NO;
    struct stat first, second;
    // Compare filesystem identity after the normal access checks; keep the
    // selected URL unchanged, including OS-provided container aliases.
    return stat(firstURL.fileSystemRepresentation, &first) == 0 &&
           stat(secondURL.fileSystemRepresentation, &second) == 0 &&
           S_ISDIR(first.st_mode) && S_ISDIR(second.st_mode) &&
           first.st_dev == second.st_dev && first.st_ino == second.st_ino;
}

static RUINPathState RUINDirectoryState(NSURL *url) {
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL) return RUINPathStateInaccessible;
    NSError *error = nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&error];
    if (!attributes) {
        if (([error.domain isEqualToString:NSCocoaErrorDomain] &&
             (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)) ||
            ([error.domain isEqualToString:NSPOSIXErrorDomain] && error.code == ENOENT)) return RUINPathStateMissing;
        return RUINPathStateInaccessible;
    }
    if ([attributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink] ||
        ![attributes[NSFileType] isEqualToString:NSFileTypeDirectory] ||
        ![NSFileManager.defaultManager isReadableFileAtPath:url.path] ||
        ![NSFileManager.defaultManager isExecutableFileAtPath:url.path]) return RUINPathStateInaccessible;
    return RUINPathStateReadable;
}

static RUINPathState RUINRegularFileState(NSURL *url) {
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL) return RUINPathStateInaccessible;
    NSError *error = nil;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:&error];
    if (!attributes) {
        if (([error.domain isEqualToString:NSCocoaErrorDomain] &&
             (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)) ||
            ([error.domain isEqualToString:NSPOSIXErrorDomain] && error.code == ENOENT)) return RUINPathStateMissing;
        return RUINPathStateInaccessible;
    }
    if ([attributes[NSFileType] isEqualToString:NSFileTypeSymbolicLink] ||
        ![attributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
        ![NSFileManager.defaultManager isReadableFileAtPath:url.path]) return RUINPathStateInaccessible;
    return RUINPathStateReadable;
}

static NSArray<NSString *> *RUINAccountFolderSuffixes(NSString *accountIdentifier) {
    if (!accountIdentifier.length) return @[];
    NSString *account = accountIdentifier.lowercaseString;
    NSMutableOrderedSet<NSString *> *suffixes = [NSMutableOrderedSet orderedSetWithObject:account];
    if ([account hasPrefix:@"u"] && account.length > 1)
        [suffixes addObject:[account substringFromIndex:1]];
    else
        [suffixes addObject:[@"u" stringByAppendingString:account]];
    return suffixes.array;
}

static BOOL RUINStoreFolderMatchesAccount(NSString *folder, NSString *accountIdentifier) {
    if (!accountIdentifier.length || (![folder hasPrefix:@"P_"] && ![folder hasPrefix:@"S_"])) return NO;
    NSString *suffix = [[folder substringFromIndex:2] lowercaseString];
    for (NSString *candidate in RUINAccountFolderSuffixes(accountIdentifier))
        if ([suffix isEqualToString:candidate]) return YES;
    return NO;
}

static RUINPathState RUINInspectMessageStore(NSURL *containerURL,
                                             NSString *verifiedAccountIdentifier,
                                             RUINContainerContents *contents) {
    *contents = (RUINContainerContents){0};
    RUINPathState containerState = RUINDirectoryState(containerURL);
    if (containerState != RUINPathStateReadable) return containerState;

    NSURL *privateStore = [[containerURL URLByAppendingPathComponent:@"Library" isDirectory:YES]
        URLByAppendingPathComponent:@"Application Support" isDirectory:YES];
    privateStore = [privateStore URLByAppendingPathComponent:@"PrivateStore" isDirectory:YES];
    RUINPathState privateStoreState = RUINDirectoryState(privateStore);
    if (privateStoreState == RUINPathStateMissing) return RUINPathStateReadable;
    if (privateStoreState != RUINPathStateReadable) return privateStoreState;

    NSError *error = nil;
    NSArray<NSURL *> *stores = [NSFileManager.defaultManager contentsOfDirectoryAtURL:privateStore
                                                            includingPropertiesForKeys:nil
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:&error];
    if (!stores) return RUINPathStateInaccessible;

    for (NSURL *store in stores) {
        NSString *name = store.lastPathComponent;
        if (![name hasPrefix:@"P_"] && ![name hasPrefix:@"S_"]) continue;
        RUINPathState storeState = RUINDirectoryState(store);
        if (storeState == RUINPathStateMissing) continue;
        if (storeState != RUINPathStateReadable) return storeState;

        NSURL *messages = [store URLByAppendingPathComponent:@"Messages" isDirectory:YES];
        RUINPathState messagesState = RUINDirectoryState(messages);
        if (messagesState == RUINPathStateMissing) continue;
        if (messagesState != RUINPathStateReadable) return messagesState;

        NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:messages
            includingPropertiesForKeys:nil options:0 error:&error];
        if (!entries) return RUINPathStateInaccessible;
        // Treat every populated Messages directory as data. A partial restore
        // may contain only a side database, WAL, or attachment directory.
        if (entries.count) {
            contents->anyAccountHasLINEData = YES;
            if (RUINStoreFolderMatchesAccount(name, verifiedAccountIdentifier))
                contents->verifiedAccountHasLINEData = YES;
        }
    }
    return RUINPathStateReadable;
}

static NSURL *RUINMarkerDirectoryURL(NSURL *containerURL) {
    NSURL *directory = [containerURL URLByAppendingPathComponent:@"Library" isDirectory:YES];
    directory = [directory URLByAppendingPathComponent:@"Application Support" isDirectory:YES];
    return [directory URLByAppendingPathComponent:RUINBindingMarkerDirectoryName isDirectory:YES];
}

static NSURL *RUINMarkerURL(NSURL *containerURL, NSString *logicalGroupIdentifier) {
    NSURL *directory = RUINMarkerDirectoryURL(containerURL);
    return [directory URLByAppendingPathComponent:[logicalGroupIdentifier stringByAppendingPathExtension:@"plist"]
                                       isDirectory:NO];
}

static RUINMarkerState RUINReadMarkerContents(NSURL *containerURL,
    NSString *logicalGroupIdentifier, NSDictionary **contents, NSError **error) {
    if (contents) *contents = nil;
    NSURL *markerURL = RUINMarkerURL(containerURL, logicalGroupIdentifier);
    RUINPathState state = RUINRegularFileState(markerURL);
    if (state == RUINPathStateMissing) return RUINMarkerStateMissing;
    if (state != RUINPathStateReadable) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorInaccessibleContainer);
        return RUINMarkerStateInaccessible;
    }

    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:markerURL.path error:NULL];
    if (([attributes[NSFilePosixPermissions] unsignedShortValue] & 077) != 0) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorInvalidMarker);
        return RUINMarkerStateInvalid;
    }

    NSData *data = [NSData dataWithContentsOfURL:markerURL options:NSDataReadingUncached error:NULL];
    id object = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                 options:NSPropertyListImmutable
                                                                  format:NULL
                                                                   error:NULL] : nil;
    if (![object isKindOfClass:NSDictionary.class] ||
        ![object[RUINBindingMarkerPurposeKey] isEqualToString:logicalGroupIdentifier] ||
        [object[RUINBindingMarkerVersionKey] integerValue] != RUINBindingMarkerVersion) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorInvalidMarker);
        return RUINMarkerStateInvalid;
    }
    if (contents) *contents = object;
    return RUINMarkerStateValid;
}

static RUINMarkerState RUINReadMarker(NSURL *containerURL,
    NSString *logicalGroupIdentifier, NSError **error) {
    return RUINReadMarkerContents(containerURL, logicalGroupIdentifier, NULL, error);
}

static BOOL RUINSetResolution(NSURL *url,
                              NSString *suiteName,
                              RUINAppGroupStorageDisposition disposition,
                              NSURL **resolvedContainerURL,
                              NSString **resolvedSuiteName,
                              RUINAppGroupStorageDisposition *dispositionOut) {
    if (resolvedContainerURL) *resolvedContainerURL = url;
    if (resolvedSuiteName) *resolvedSuiteName = suiteName;
    if (dispositionOut) *dispositionOut = disposition;
    return YES;
}

static BOOL RUINFailResolution(RUINAppGroupStorageErrorCode code,
                               NSURL *preservedFallbackURL,
                               NSURL **resolvedContainerURL,
                               NSString **resolvedSuiteName,
                               RUINAppGroupStorageDisposition *dispositionOut,
                               NSError **error) {
    if (resolvedContainerURL) *resolvedContainerURL = preservedFallbackURL.isFileURL ? preservedFallbackURL : nil;
    if (resolvedSuiteName) *resolvedSuiteName = nil;
    if (dispositionOut) *dispositionOut = RUINAppGroupStorageDispositionUnsafe;
    RUINSetStorageError(error, code);
    return preservedFallbackURL.isFileURL;
}

BOOL RUINResolveAppGroupStorage(NSString *logicalGroupIdentifier,
                                NSString * _Nullable verifiedAccountIdentifier,
                                NSURL *nativeContainerURL,
                                NSURL *currentFallbackURL,
                                NSDictionary<NSString *,NSString *> *explicitGroupMap,
                                NSDictionary<NSString *,NSURL *> *authorizedGroupContainers,
                                NSArray<NSURL *> *legacyMainLINECandidates,
                                NSURL **resolvedContainerURL,
                                NSString **suiteName,
                                RUINAppGroupStorageDisposition *disposition,
                                NSError **error) {
    if (resolvedContainerURL) *resolvedContainerURL = nil;
    if (suiteName) *suiteName = nil;
    if (disposition) *disposition = RUINAppGroupStorageDispositionUnsafe;
    if (error) *error = nil;

    if (!resolvedContainerURL) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorInvalidArgument);
        return NO;
    }
    if (!currentFallbackURL.isFileURL) {
        return RUINFailResolution(RUINAppGroupStorageErrorInvalidArgument,
                                  nil, resolvedContainerURL, suiteName, disposition, error);
    }
    if (!RUINIsSafeGroupIdentifier(logicalGroupIdentifier) ||
        (verifiedAccountIdentifier && ![verifiedAccountIdentifier isKindOfClass:NSString.class])) {
        return RUINFailResolution(RUINAppGroupStorageErrorInvalidArgument,
                                  currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
    }

    RUINContainerContents fallbackContents = {0};
    RUINPathState fallbackState = RUINInspectMessageStore(currentFallbackURL,
                                                          verifiedAccountIdentifier,
                                                          &fallbackContents);
    if (fallbackState == RUINPathStateInaccessible) {
        return RUINFailResolution(RUINAppGroupStorageErrorInaccessibleContainer,
                                  currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
    }

    RUINPathState nativeState = nativeContainerURL ? RUINDirectoryState(nativeContainerURL) : RUINPathStateMissing;
    if (nativeState == RUINPathStateInaccessible) {
        return RUINFailResolution(RUINAppGroupStorageErrorInaccessibleContainer,
                                  currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
    }
    NSDictionary<NSString *,NSURL *> *authorized = authorizedGroupContainers ?: @{};
    NSMutableArray<NSDictionary *> *markers = [NSMutableArray array];
    for (NSString *groupIdentifier in [[authorized allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (!RUINIsSafeGroupIdentifier(groupIdentifier)) continue;
        NSURL *groupURL = authorized[groupIdentifier];
        RUINPathState groupState = RUINDirectoryState(groupURL);
        if (groupState == RUINPathStateMissing) continue;
        if (groupState != RUINPathStateReadable) {
            return RUINFailResolution(RUINAppGroupStorageErrorInaccessibleContainer,
                                      currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
        }
        RUINMarkerState markerState = RUINReadMarker(groupURL, logicalGroupIdentifier, error);
        if (markerState == RUINMarkerStateInaccessible || markerState == RUINMarkerStateInvalid) {
            return RUINFailResolution(RUINAppGroupStorageErrorInvalidMarker,
                                      currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
        }
        if (markerState != RUINMarkerStateValid) continue;

        RUINContainerContents markerContents = {0};
        if (RUINInspectMessageStore(groupURL, verifiedAccountIdentifier, &markerContents) != RUINPathStateReadable) {
            return RUINFailResolution(RUINAppGroupStorageErrorInaccessibleContainer,
                                      currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
        }
        [markers addObject:@{@"group":groupIdentifier, @"url":groupURL,
                             @"hasData":@(markerContents.anyAccountHasLINEData)}];
    }
    if (markers.count > 1) {
        return RUINFailResolution(RUINAppGroupStorageErrorAmbiguousBinding,
                                  currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
    }

    BOOL hasExplicitMapping = [explicitGroupMap objectForKey:logicalGroupIdentifier] != nil;
    NSString *mappedGroupIdentifier = hasExplicitMapping ? explicitGroupMap[logicalGroupIdentifier] : nil;
    NSURL *mappedURL = nil;
    RUINContainerContents mappedContents = {0};
    if (hasExplicitMapping) {
        if (!RUINIsSafeGroupIdentifier(mappedGroupIdentifier) || !(mappedURL = authorized[mappedGroupIdentifier])) {
            return RUINFailResolution(RUINAppGroupStorageErrorUnauthorizedMapping,
                                      currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
        }
        RUINPathState mapState = RUINInspectMessageStore(mappedURL, verifiedAccountIdentifier, &mappedContents);
        if (mapState == RUINPathStateInaccessible) {
            return RUINFailResolution(RUINAppGroupStorageErrorInaccessibleContainer,
                                      currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
        }
    }

    NSDictionary *marker = markers.firstObject;
    NSURL *markerURL = marker[@"url"];
    BOOL markerHasData = [marker[@"hasData"] boolValue];
    BOOL fallbackHasData = fallbackContents.anyAccountHasLINEData;
    BOOL mappedHasData = mappedContents.anyAccountHasLINEData;

    if (nativeState == RUINPathStateReadable) {
        if ((markerURL && !RUINSameDirectory(markerURL, nativeContainerURL) && markerHasData) ||
            (hasExplicitMapping && !RUINSameDirectory(mappedURL, nativeContainerURL) && mappedHasData)) {
            return RUINFailResolution(RUINAppGroupStorageErrorConflictingStores,
                                      currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
        }
        if (fallbackHasData && !RUINSameDirectory(currentFallbackURL, nativeContainerURL)) {
            return RUINFailResolution(RUINAppGroupStorageErrorConflictingStores,
                                      currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
        }
        return RUINSetResolution(nativeContainerURL, logicalGroupIdentifier,
                                 RUINAppGroupStorageDispositionNative,
                                 resolvedContainerURL, suiteName, disposition);
    }

    if (hasExplicitMapping) {
        if (markerURL && !RUINSameDirectory(markerURL, mappedURL)) {
            return RUINFailResolution(RUINAppGroupStorageErrorConflictingStores,
                                      currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
        }
        if (fallbackHasData && !RUINSameDirectory(currentFallbackURL, mappedURL)) {
            return RUINFailResolution(RUINAppGroupStorageErrorConflictingStores,
                                      currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
        }
        return RUINSetResolution(mappedURL, mappedGroupIdentifier,
                                 RUINAppGroupStorageDispositionExplicitMap,
                                 resolvedContainerURL, suiteName, disposition);
    }

    if (markerURL) {
        if (fallbackHasData && !RUINSameDirectory(currentFallbackURL, markerURL)) {
            return RUINFailResolution(RUINAppGroupStorageErrorConflictingStores,
                                      currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
        }
        return RUINSetResolution(markerURL, marker[@"group"],
                                 RUINAppGroupStorageDispositionPersistedMap,
                                 resolvedContainerURL, suiteName, disposition);
    }

    NSMutableArray<NSURL *> *legacyCandidates = [NSMutableArray array];
    BOOL foreignLegacyData = NO;
    for (NSURL *candidate in legacyMainLINECandidates ?: @[]) {
        RUINContainerContents candidateContents = {0};
        RUINPathState candidateState = RUINInspectMessageStore(candidate, verifiedAccountIdentifier,
                                                               &candidateContents);
        if (candidateState == RUINPathStateInaccessible) {
            return RUINFailResolution(RUINAppGroupStorageErrorInaccessibleContainer,
                                      currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
        }
        if (RUINSameDirectory(candidate, currentFallbackURL)) continue;
        if (candidateContents.verifiedAccountHasLINEData) {
            BOOL alreadyAdded = NO;
            for (NSURL *existing in legacyCandidates)
                if (RUINSameDirectory(existing, candidate)) {
                    alreadyAdded = YES;
                    break;
                }
            if (!alreadyAdded) [legacyCandidates addObject:candidate];
        } else if (candidateContents.anyAccountHasLINEData) {
            foreignLegacyData = YES;
        }
    }
    if (fallbackHasData && (foreignLegacyData || legacyCandidates.count)) {
        return RUINFailResolution(RUINAppGroupStorageErrorConflictingStores,
                                  currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
    }
    if (fallbackHasData) {
        return RUINSetResolution(currentFallbackURL, nil,
                                 RUINAppGroupStorageDispositionExistingFallback,
                                 resolvedContainerURL, suiteName, disposition);
    }
    if (foreignLegacyData || legacyCandidates.count > 1) {
        return RUINFailResolution(RUINAppGroupStorageErrorAmbiguousBinding,
                                  currentFallbackURL, resolvedContainerURL, suiteName, disposition, error);
    }
    if (legacyCandidates.count == 1) {
        return RUINSetResolution(legacyCandidates.firstObject, nil,
                                 RUINAppGroupStorageDispositionLegacyMainCandidate,
                                 resolvedContainerURL, suiteName, disposition);
    }
    return RUINSetResolution(currentFallbackURL, nil,
                             RUINAppGroupStorageDispositionNewFallback,
                             resolvedContainerURL, suiteName, disposition);
}

static BOOL RUINWriteStorageBinding(NSString *logicalGroupIdentifier, NSURL *containerURL,
    NSDictionary *additionalFields, NSError **error) {
    RUINPathState containerState = RUINDirectoryState(containerURL);
    if (containerState == RUINPathStateInaccessible ||
        (containerState == RUINPathStateReadable &&
         ![NSFileManager.defaultManager isWritableFileAtPath:containerURL.path])) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorInaccessibleContainer);
        return NO;
    }

    NSURL *directory = RUINMarkerDirectoryURL(containerURL);
    NSFileManager *manager = NSFileManager.defaultManager;
    RUINPathState directoryState = RUINDirectoryState(directory);
    if (directoryState == RUINPathStateInaccessible) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorMarkerWrite);
        return NO;
    }
    if (directoryState == RUINPathStateMissing &&
        ![manager createDirectoryAtURL:directory
           withIntermediateDirectories:YES
                            attributes:@{NSFilePosixPermissions:@0700}
                                 error:NULL]) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorMarkerWrite);
        return NO;
    }

    RUINMarkerState existing = RUINReadMarker(containerURL, logicalGroupIdentifier, error);
    if (existing == RUINMarkerStateValid) return YES;
    if (existing != RUINMarkerStateMissing) return NO;

    NSMutableDictionary *marker = [@{RUINBindingMarkerVersionKey:@(RUINBindingMarkerVersion),
        RUINBindingMarkerPurposeKey:logicalGroupIdentifier} mutableCopy];
    [marker addEntriesFromDictionary:additionalFields];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:marker
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:NULL];
    if (!data) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorMarkerWrite);
        return NO;
    }
    NSURL *markerURL = RUINMarkerURL(containerURL, logicalGroupIdentifier);
    int descriptor = open(markerURL.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (descriptor < 0) {
        if (errno == EEXIST && RUINReadMarker(containerURL, logicalGroupIdentifier, error) == RUINMarkerStateValid)
            return YES;
        if (!error || !*error) RUINSetStorageError(error, RUINAppGroupStorageErrorMarkerWrite);
        return NO;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    BOOL wrote = YES;
    while (offset < data.length) {
        ssize_t count = write(descriptor, bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { wrote = NO; break; }
        offset += (NSUInteger)count;
    }
    if (wrote && fsync(descriptor) != 0) wrote = NO;
    if (close(descriptor) != 0) wrote = NO;
    if (!wrote) {
        unlink(markerURL.fileSystemRepresentation);
        RUINSetStorageError(error, RUINAppGroupStorageErrorMarkerWrite);
        return NO;
    }
    return YES;
}

BOOL RUINRecordExplicitAppGroupBinding(NSString *logicalGroupIdentifier,
                                       NSString *authorizedGroupIdentifier,
                                       NSDictionary<NSString *,NSURL *> *authorizedGroupContainers,
                                       NSError **error) {
    if (error) *error = nil;
    if (!RUINIsSafeGroupIdentifier(logicalGroupIdentifier) ||
        !RUINIsSafeGroupIdentifier(authorizedGroupIdentifier) ||
        ![authorizedGroupContainers isKindOfClass:NSDictionary.class]) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorInvalidArgument);
        return NO;
    }
    NSURL *containerURL = authorizedGroupContainers[authorizedGroupIdentifier];
    if (![containerURL isKindOfClass:NSURL.class] || !containerURL.isFileURL) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorUnauthorizedMapping);
        return NO;
    }
    return RUINWriteStorageBinding(logicalGroupIdentifier, containerURL, @{}, error);
}

static NSString *RUINSandboxOwnerDigest(NSString *logicalGroupIdentifier, NSString *signingIdentifier,
    NSURL *sandboxURL, NSError **error) {
    if (!RUINIsSafeGroupIdentifier(logicalGroupIdentifier) ||
        ![sandboxURL isKindOfClass:NSURL.class] || !sandboxURL.isFileURL ||
        ![signingIdentifier isKindOfClass:NSString.class] || !signingIdentifier.length || signingIdentifier.length > 1024) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorInvalidArgument); return nil;
    }
    NSData *owner = [signingIdentifier dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(owner.bytes, (CC_LONG)owner.length, hash);
    NSMutableString *digest = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(hash); i++) [digest appendFormat:@"%02x", hash[i]];
    return digest;
}

static RUINMarkerState RUINReadSandboxOwnerBinding(NSString *logicalGroupIdentifier,
    NSString *digest, NSURL *sandboxURL, NSError **error) {
    NSDictionary *stored = nil;
    RUINMarkerState marker = RUINReadMarkerContents(sandboxURL, logicalGroupIdentifier, &stored, error);
    if (marker == RUINMarkerStateValid) {
        if ([stored[@"sandboxOwnerDigest"] isEqual:digest]) return RUINMarkerStateValid;
        RUINSetStorageError(error, RUINAppGroupStorageErrorAmbiguousBinding);
        return RUINMarkerStateInvalid;
    }
    return marker;
}

BOOL RUINVerifySandboxAppGroupStorageBinding(NSString *logicalGroupIdentifier, NSString *signingIdentifier,
    NSURL *sandboxURL, NSError **error) {
    if (error) *error = nil;
    NSString *digest = RUINSandboxOwnerDigest(logicalGroupIdentifier, signingIdentifier, sandboxURL, error);
    return digest && RUINReadSandboxOwnerBinding(logicalGroupIdentifier, digest, sandboxURL, error) == RUINMarkerStateValid;
}

BOOL RUINPinSandboxAppGroupStorage(NSString *logicalGroupIdentifier, NSString *signingIdentifier,
    NSURL *sandboxURL, NSError **error) {
    if (error) *error = nil;
    NSString *digest = RUINSandboxOwnerDigest(logicalGroupIdentifier, signingIdentifier, sandboxURL, error);
    if (!digest) return NO;
    RUINMarkerState marker = RUINReadSandboxOwnerBinding(logicalGroupIdentifier, digest, sandboxURL, error);
    if (marker == RUINMarkerStateValid) return YES;
    if (marker != RUINMarkerStateMissing) return NO;
    RUINContainerContents contents;
    RUINPathState state = RUINInspectMessageStore(sandboxURL, @"", &contents);
    if (state == RUINPathStateInaccessible || contents.anyAccountHasLINEData) {
        RUINSetStorageError(error, RUINAppGroupStorageErrorAmbiguousBinding); return NO;
    }
    return RUINWriteStorageBinding(logicalGroupIdentifier, sandboxURL, @{@"sandboxOwnerDigest":digest}, error) &&
        RUINReadSandboxOwnerBinding(logicalGroupIdentifier, digest, sandboxURL, error) == RUINMarkerStateValid;
}
