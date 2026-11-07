#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void RUINInstallNativeTabAvailability(void);
FOUNDATION_EXPORT NSArray<NSString *> *RUINObservedNativeTabChoices(void);
FOUNDATION_EXPORT NSDictionary *RUINNativeTabAvailabilityDiagnostics(void);
FOUNDATION_EXPORT BOOL RUINNativeTabCanHideService(NSString *preferenceKey);
NS_ASSUME_NONNULL_END
