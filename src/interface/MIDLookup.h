#import <Foundation/Foundation.h>

@class UIViewController;

NS_ASSUME_NONNULL_BEGIN

/// Pushes the Japanese MID lookup screen on the source's existing navigation stack.
/// Lookup is user initiated; no MID is persisted or included in diagnostics.
FOUNDATION_EXPORT void RUINOpenMIDLookup(UIViewController *source);
// User-tapped profile action from another RUIN screen; validates the MID and foreground source.
FOUNDATION_EXPORT void RUINOpenMIDProfile(UIViewController *source, NSString *mid);

/// Availability and routing counters only. Accepted routing is not lookup success.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RUINMIDLookupDiagnostics(void);

NS_ASSUME_NONNULL_END
