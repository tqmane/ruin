#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const RUINHideVOOMTabDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINHideWalletTabDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINHideShoppingTabDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINHideNewsCallTabsDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINHideSettingsTabDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINStartupTabFixedDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINStartupTabDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINHideAdsDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINHideRecommendationsDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINHideVoiceInputDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINHideAgentIBarDefaultsKey;

/** RUINStartupTabDefaultsKey stores one of these IDs; fixed startup selection defaults off. */
FOUNDATION_EXPORT NSString * const RUINInterfaceTabHome;
FOUNDATION_EXPORT NSString * const RUINInterfaceTabTalk;
FOUNDATION_EXPORT NSString * const RUINInterfaceTabVOOM;
FOUNDATION_EXPORT NSString * const RUINInterfaceTabWallet;
FOUNDATION_EXPORT NSString * const RUINInterfaceTabShopping;
FOUNDATION_EXPORT NSString * const RUINInterfaceTabNews;
FOUNDATION_EXPORT NSString * const RUINInterfaceTabCall;
FOUNDATION_EXPORT NSString * const RUINInterfaceTabSettings;

/** Installs version-gated LINE interface hooks. All preferences default off. */
FOUNDATION_EXPORT void RUINInstallInterfaceFeatures(void);

/** Reloads preferences and reapplies them to live LINE views and tab controllers. */
FOUNDATION_EXPORT void RUINRefreshInterfaceFeatures(void);

/** Current semantic startup choices, as stable identifiers only. */
FOUNDATION_EXPORT NSArray<NSString *> *RUINAvailableTabs(void);

/** IDs present in the generated root-tab controller catalog, regardless of hide preferences. Settings requires Home. */
FOUNDATION_EXPORT NSArray<NSString *> *RUINNativeTabIdentifiers(void);

/** Hook statuses and counters only; never includes chat or account content. */
FOUNDATION_EXPORT NSDictionary *RUINInterfaceDiagnostics(void);

NS_ASSUME_NONNULL_END
