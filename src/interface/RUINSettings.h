#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const RUINVersion;
FOUNDATION_EXPORT BOOL RUINIsCompatible(void);
FOUNDATION_EXPORT NSDictionary *RUINRuntimeDiagnostics(void);
FOUNDATION_EXPORT void RUINRefreshRuntimeReport(void);
FOUNDATION_EXPORT void RUINRefreshSettingsFeatures(void);
FOUNDATION_EXPORT void RUINRefreshSettingsFeature(NSString *key);
FOUNDATION_EXPORT void RUINOpenSettingsInLINE(UIViewController *owner);
FOUNDATION_EXPORT BOOL RUINPresentSettings(void);
FOUNDATION_EXPORT BOOL RUINMaybeShowCompatibilityWarning(void);
