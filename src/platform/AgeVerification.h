#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const RUINBypassAgeVerificationDefaultsKey;
FOUNDATION_EXPORT void RUINInstallAgeVerification(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RUINAgeVerificationDiagnostics(void);

NS_ASSUME_NONNULL_END
