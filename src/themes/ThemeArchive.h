#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const RUINThemeArchiveErrorDomain;

/**
 Validates and extracts a downloaded .linetheme into a new protected UUID
 directory beneath an existing trusted staging root. The returned URL is the
 staged package directory; this function does not import, install, or apply it.
 */
FOUNDATION_EXPORT NSURL * _Nullable RUINStageThemeArchiveAtURL(NSURL *archiveURL,
                                                               NSURL *trustedStagingRoot,
                                                               NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
