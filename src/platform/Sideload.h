#pragma once
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT void RUINInstallCompatibility(void);
FOUNDATION_EXPORT BOOL RUINStorageMigrationReady(void);
FOUNDATION_EXPORT NSDictionary *RUINCompatibilityDiagnostics(void);
