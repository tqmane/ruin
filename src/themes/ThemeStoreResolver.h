#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const RUINThemeStoreResolverErrorDomain;

typedef NS_ENUM(NSInteger, RUINThemeStoreResolverErrorCode) {
    RUINThemeStoreResolverInvalidURL = 1,
    RUINThemeStoreResolverNetworkError,
    RUINThemeStoreResolverBadResponse,
    RUINThemeStoreResolverResponseTooLarge,
    RUINThemeStoreResolverInvalidHTML
};

typedef void (^RUINThemeStoreResolverCompletion)(
    NSDictionary<NSString *, NSString *> * _Nullable theme,
    NSError * _Nullable error
);

/// Returns a URL only for https://store.line.me/themeshop/product/<UUID>/<locale>.
FOUNDATION_EXPORT NSURL * _Nullable RUINValidatedThemeStoreURL(NSString * _Nullable URLText);

/// Parses static HTML without executing scripts and binds metadata to expectedProductID.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> * _Nullable
RUINParseThemeStoreHTML(NSData * _Nullable HTMLData, NSString * _Nullable expectedProductID);

/// Fetches and validates a LINE Store theme page using a cookie-free ephemeral session.
FOUNDATION_EXPORT void RUINResolveThemeStoreURL(
    NSString * _Nullable URLText,
    RUINThemeStoreResolverCompletion completion
);

NS_ASSUME_NONNULL_END
