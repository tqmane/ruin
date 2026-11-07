#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RUINAppGroupStorageDisposition) {
    RUINAppGroupStorageDispositionNative = 1,
    RUINAppGroupStorageDispositionExplicitMap,
    RUINAppGroupStorageDispositionPersistedMap,
    RUINAppGroupStorageDispositionExistingFallback,
    RUINAppGroupStorageDispositionLegacyMainCandidate,
    RUINAppGroupStorageDispositionNewFallback,
    RUINAppGroupStorageDispositionUnsafe
};

typedef NS_ENUM(NSInteger, RUINAppGroupStorageErrorCode) {
    RUINAppGroupStorageErrorInvalidArgument = 1,
    RUINAppGroupStorageErrorInaccessibleContainer,
    RUINAppGroupStorageErrorUnauthorizedMapping,
    RUINAppGroupStorageErrorAmbiguousBinding,
    RUINAppGroupStorageErrorConflictingStores,
    RUINAppGroupStorageErrorInvalidMarker,
    RUINAppGroupStorageErrorMarkerWrite
};

FOUNDATION_EXPORT NSString *const RUINAppGroupStorageErrorDomain;

// legacyMainLINECandidates must already be restricted by the caller to
// profile-authorized containers. A non-empty verifiedAccountIdentifier is
// required to select one. Empty is allowed for native/map/marker/fallback
// resolution, but never selects a legacy-account store.
// A LegacyMainCandidate disposition is review-only; callers must not migrate
// or copy it automatically.
//
// Returns YES when resolvedContainerURL contains the safe selection or, for an
// unsafe/ambiguous result, the current fallback URL to preserve. Callers must
// gate login/use on disposition != RUINAppGroupStorageDispositionUnsafe.
// This function never copies or merges store contents.
FOUNDATION_EXPORT BOOL RUINResolveAppGroupStorage(
    NSString *logicalGroupIdentifier,
    NSString * _Nullable verifiedAccountIdentifier,
    NSURL * _Nullable nativeContainerURL,
    NSURL *currentFallbackURL,
    NSDictionary<NSString *, NSString *> * _Nullable explicitGroupMap,
    NSDictionary<NSString *, NSURL *> * _Nullable authorizedGroupContainers,
    NSArray<NSURL *> * _Nullable legacyMainLINECandidates,
    NSURL * _Nullable * _Nonnull resolvedContainerURL,
    NSString * _Nullable * _Nullable suiteName,
    RUINAppGroupStorageDisposition * _Nullable disposition,
    NSError * _Nullable * _Nullable error);

// Call only after an explicit, validated RUINAppGroupMap binding is selected.
// The target group must be in the runtime authorized-container map. The marker
// contains the logical purpose and format version, never signing identifiers,
// account IDs, or store contents.
FOUNDATION_EXPORT BOOL RUINRecordExplicitAppGroupBinding(
    NSString *logicalGroupIdentifier,
    NSString *authorizedGroupIdentifier,
    NSDictionary<NSString *, NSURL *> *authorizedGroupContainers,
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
