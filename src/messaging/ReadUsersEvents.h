#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Call during startup, before LINE's initial operation decode; safe to repeat
// if classes were unavailable. Uses MessageHistory's RUINTrackReadUsersKey
// (default NO), checked live after each successful original read:. No new key.
FOUNDATION_EXPORT void RUINInstallReadUsersEvents(void);

// Selector metadata, installation state and aggregate counts only. No event
// fields, chat/user/message identifiers, content, or filesystem paths.
FOUNDATION_EXPORT NSDictionary *RUINReadUsersEventsDiagnostics(void);

// Captures only complete LineOperation type 55, after read: returns normally,
// on that callback's queue. Copies param1/2/3 to the existing History bridge:
// talk chat / reader MID / positive exact Int64 read-up-to ID. No managed
// objects, operation mutation, acknowledgement suppression, or invented time.
// Store attribution and (start, end] range semantics remain History's policy,
// matching the Android reference query. The iOS wire mapping/device behavior
// and OpenChat coverage remain unverified.

NS_ASSUME_NONNULL_END
