#import <Foundation/Foundation.h>
FOUNDATION_EXPORT void RUINInstallAutomaticReadGate(void);
FOUNDATION_EXPORT void RUINRefreshAutomaticReadGate(void);
FOUNDATION_EXPORT void RUINAllowAutomaticReadForReply(NSDictionary *token);
FOUNDATION_EXPORT NSDictionary *RUINAutomaticReadGateDiagnostics(void);
