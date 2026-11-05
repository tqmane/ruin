#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RUINNativeUnsendState) {
    RUINNativeUnsendNone,
    RUINNativeUnsendNormal,
    RUINNativeUnsendSilent,
    RUINNativeUnsendUnsupportedValue
};

// Explicit diagnostic/test mode; default NO. Records only the two native flag
// value/type categories and counters, never message text, identifiers, or paths.
FOUNDATION_EXPORT NSString *const RUINUnsendObservationEnabledDefaultsKey;
// Constructor-safe transport installation; no history store or UI startup.
FOUNDATION_EXPORT void RUINInstallEarlyUnsendTransport(void);
FOUNDATION_EXPORT void RUINInstallUnsendRetention(void);
FOUNDATION_EXPORT NSDictionary *RUINUnsendRetentionDiagnostics(void);
FOUNDATION_EXPORT BOOL RUINClearUnsendMarkers(void);

// Pure native-map recognition. UNSENT requires a string-valued key; the native
// UI checks its presence. SILENTLY_UNSENT requires the exact string "true".
// NSNumber/NSNull/unknown shapes do not authorize archive display through this
// recognizer. The transport filter separately follows the confirmed original
// condition: any non-nil UNSENT value, with the retention preference enabled.
FOUNDATION_EXPORT RUINNativeUnsendState RUINUnsendStateForMetadata(NSDictionary *metadata);

// Display adapter for a remaining model object, on its owning context queue.
// Returns retained type-0 plaintext + "取消済" for a matched, filtered-UNSENT
// sidecar marker, or an earlier archive snapshot for a remaining tombstone.
// The transport filter removes only UNSENT, and only when retention is enabled.
// Markers match message ID + a literal native from/to MID to the actual chat,
// then bind a store; known conflicting stores/events do not authorize a label.
// SILENTLY_UNSENT, all other metadata, callbacks, and server ack paths remain
// native. No deleted object or never-received original is reconstructed here.
FOUNDATION_EXPORT NSString * _Nullable RUINRetainedUnsentTextForMessage(id message);

NS_ASSUME_NONNULL_END
