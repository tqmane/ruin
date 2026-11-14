#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Call after bundle identity setup, before LINE can schedule vocabulary updates.
// Safe to retry if the native class/image is not yet available. No constructor.
FOUNDATION_EXPORT void RUINInstallSiriCompatibility(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RUINSiriCompatibilityDiagnostics(void);

NS_ASSUME_NONNULL_END
