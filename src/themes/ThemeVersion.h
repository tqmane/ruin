#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Converts a displayed theme version to LINE's internal decimal version.
/// Raw ASCII decimal versions pass through after trimming, preserving leading
/// zeros (for example, raw `328` stays `328`). Displayed `V4.27` maps to `328`.
/// The leading `V` may be uppercase, lowercase, or omitted.
FOUNDATION_EXPORT NSString * _Nullable RUINThemeDownloadVersion(NSString * _Nullable input);

/// Converts an internal positive decimal version such as 328 to V4.27.
FOUNDATION_EXPORT NSString * _Nullable RUINThemeDisplayVersion(NSString * _Nullable version);

NS_ASSUME_NONNULL_END
