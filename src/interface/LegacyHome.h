#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const RUINLegacyHomeEnabledDefaultsKey;
// Main queue, constructor-safe bootstrap. Decoder installation occurs before
// forwarding the native launch callback; no dlopen from a dyld constructor.
// Refreshes the option; existing native Home controllers are kept.
// Changing the option takes effect when LINE constructs Home after a restart.
FOUNDATION_EXPORT void RUINInstallLegacyHome(void);
FOUNDATION_EXPORT BOOL RUINLegacyHomeAvailable(void);
FOUNDATION_EXPORT NSDictionary *RUINLegacyHomeDiagnostics(void);
