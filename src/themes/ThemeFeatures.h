#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const RUINThemeRandomEnabledDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINThemeShopDownloadEnabledDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINThemeAppliedThemeIDDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINThemeDynamicThemeNextUpdateDateDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINThemeErrorDomain;

typedef NS_ENUM(NSInteger, RUINThemeErrorCode) {
    RUINThemeErrorInvalidArgument = 1,
    RUINThemeErrorNativeAPIUnavailable = 2
};

typedef void (^RUINThemeDownloadCompletion)(NSURL * _Nullable packageURL, NSError * _Nullable error);
typedef void (^RUINThemeApplyCompletion)(BOOL applied, NSError * _Nullable error);

/** Installs version-gated display, native-apply observer, and defaults hooks. */
FOUNDATION_EXPORT void RUINInstallThemeFeatures(void);

/** Operation availability, native metadata evidence, and the random-startup preference state. */
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RUINThemeDiagnostics(void);

/**
 Returns structurally validated local .linetheme downloads plus read-only
 Theme 2 OwnedThemeProduct records with positive installedTime when the native
 model is available. Native rows have packageArchiveValidated=NO; downloaded
 archive rows are not marked installed. Returns nil on a catalog scan error.
 */
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> * _Nullable RUINThemeCatalog(NSError * _Nullable * _Nullable error);

/** Applies through LINE's native applier when its callable ABI is available. */
FOUNDATION_EXPORT BOOL RUINApplyDownloadedTheme(NSString *productID, NSError * _Nullable * _Nullable error);

/** Removes through LINE's native package resource remover when callable. */
FOUNDATION_EXPORT BOOL RUINRemoveThemePackage(NSString *productID, NSError * _Nullable * _Nullable error);

/**
 Dispatches LINE's native reset button action when its theme-management screen
 is visible. Completion succeeds only after LINE reports applying its default
 ThemePackage; it does not change a preference to simulate success. If no
 result arrives within 120 seconds, completion reports an unknown outcome.
 */
FOUNDATION_EXPORT void RUINResetTheme(RUINThemeApplyCompletion completion);

/**
 Downloads LINE's statically verified public theme ZIP endpoint using the
 supplied name, product ID, and version. Requires enableThemeDL, but does not
 call a purchase/order API, test ownership, or write entitlements. The
 completion URL is a structurally validated .linetheme archive (CRC and theme
 schema are not checked); it is not installed/applied.
 */
FOUNDATION_EXPORT void RUINDownloadThemeByID(NSString *name,
                                             NSString *productID,
                                             NSString *version,
                                             RUINThemeDownloadCompletion completion);

/** Explicit recovery for an account-bound RUIN receipt, validated by the caller.
 Does not change or require the store purchase-button override preference. */
FOUNDATION_EXPORT void RUINDownloadRegisteredTheme(NSString *name, NSString *productID,
    NSString *version, RUINThemeDownloadCompletion completion);

NS_ASSUME_NONNULL_END
