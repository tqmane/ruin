#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Constructor also installs early. Safe to repeat at startup/preference reload.
// Uses existing RUINKeepUnsentMessagesKey, default NO, checked live.
FOUNDATION_EXPORT void RUINInstallUnsendOperation(void);
FOUNDATION_EXPORT NSDictionary *RUINUnsendOperationDiagnostics(void);
// Include in the parent's clear-local-data action, alongside History/retention.
FOUNDATION_EXPORT BOOL RUINClearUnsendOperationMarkers(void);

// UI adapter only: accepts the copied {store,kind,chat,message} key returned by
// RUINHistoryMessageKey for a verified bound message. Reads an exact marker;
// never creates a file/schema/marker, changes a preference, or freezes History.
// Returns NO when disabled/gated, invalid, unavailable or ambiguous to caller.
FOUNDATION_EXPORT BOOL RUINUnsendOperationHasRetainedMarker(NSDictionary *messageKey);

// Uses only a verified version/UUID mapping and exact parser fingerprints;
// converted guests additionally require the feature-local class-owner proof.
// Installed hooks retain that image's lifetime proof across repeated installs.
// No Swift IMP/ABI replacement. The
// original Core Data fetch runs once. Only its exact, fingerprinted incoming
// destroy-operation lookup, matching the native parser's copied chat/message
// identity on the same thread, sees an empty result before local cleanup/delete
// or tombstone creation. The actual permanent message's store/chat/ID is
// recorded; ordinary queries and manual deletion see the original result.
// Existing type-0 plaintext may be presented with "取消済" through displayedText.
// All enclosing native operation handling/notification/ack callbacks continue.
// Other native routes, OpenChat, media bytes and actual pixels need validation.

NS_ASSUME_NONNULL_END
