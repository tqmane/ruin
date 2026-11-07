#pragma once
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void RUINInstallKeychainCompatibility(void);
FOUNDATION_EXPORT BOOL RUINKeychainCompatibilityReady(void);
FOUNDATION_EXPORT NSDictionary *RUINKeychainDiagnostics(void);
FOUNDATION_EXPORT NSDictionary *RUINKeychainSelfTest(void);
