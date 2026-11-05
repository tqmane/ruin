#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Parent calls at UI startup and after preference edits. Existing
// RUINKeepUnsentMessagesKey controls this adapter; no additional switch.
FOUNDATION_EXPORT void RUINInstallUnsendMarkerUI(void);
// Main-thread refresh is scheduled when called from another queue. Also
// refreshes on native layout/reuse, foregrounding and defaults changes.
FOUNDATION_EXPORT void RUINRefreshUnsendMarkerUI(void);
// Aggregate counts and bounded exact-cell field names/value classes only;
// never message text, identity values, object descriptions or file paths.
FOUNDATION_EXPORT NSDictionary *RUINUnsendMarkerUIDiagnostics(void);

NS_ASSUME_NONNULL_END
