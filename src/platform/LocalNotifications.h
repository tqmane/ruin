#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const RUINLocalNotificationsEnabledDefaultsKey;

// Install after LINE assigns its notification-center delegate and before app
// launch finishes, so cold-launch taps reach this proxy. Call again immediately
// after any later delegate replacement and on activation. Activation-only
// installation can miss a cold-launch response.
FOUNDATION_EXPORT void RUINInstallLocalNotifications(void);

// Pass copied Foundation values only; never pass managed objects. Required
// Exact keys: store, kind, chat, message, title, body, timestampMs, contentType,
// isOutgoing, muted. `timestampMs` is integer milliseconds and must be at/after
// this process's last activation and the last OFF->ON transition, at most 5
// minutes old, and no more than 60 seconds in the future. `contentType` is an
// integer. Both flags must be actual CFBoolean-backed NSNumbers. `muted` is true
// when !Chat.alert, !native notification availability, or per-message silent is
// true/unknown. Set it false only when all inputs are known false. Empty body
// uses a named generic media fallback.
FOUNDATION_EXPORT void RUINObserveLocalIncomingSnapshot(NSDictionary *copiedFoundationData);

// Aggregated counters only; never contains notification text or message identity.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RUINLocalNotificationDiagnostics(void);

NS_ASSUME_NONNULL_END
