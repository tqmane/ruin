#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Persists committed native theme metadata beside the account's Theme Packages
/// directory. archiveName must be a UUID.linetheme filename, without a path.
FOUNDATION_EXPORT BOOL RUINWriteThemeReceipt(
    NSURL *trustedPackagesRoot,
    NSDictionary<NSString *, id> *metadata,
    NSString *archiveName,
    NSError * _Nullable * _Nullable error);

/// Returns validated metadata for one lowercase or uppercase UUID product ID.
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable RUINReadThemeReceipt(
    NSURL *trustedPackagesRoot,
    NSString *productID);

/// Returns validated metadata keyed by lowercase product UUID. Missing or
/// unsafe receipt storage produces an empty dictionary and creates no files.
FOUNDATION_EXPORT NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
    RUINReadThemeReceipts(NSURL *trustedPackagesRoot);

NS_ASSUME_NONNULL_END
