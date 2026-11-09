#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const RUINKeepUnsentMessagesKey;
FOUNDATION_EXPORT NSString *const RUINTrackReadUsersKey;

// Independent archive. Message IDs are positive ASCII-decimal signed Int64
// strings (leading zeros canonicalize); read ranges use LINE's (start, end]
// boundary, so a zero start covers positive IDs through the inclusive end.
// All methods serialize access to the SQLite connection.
// Reader rows retain earliest positive known/observed times independently;
// later cursors/duplicates cannot advance an earlier message's original date.
@interface RUINHistoryStore : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
- (BOOL)saveSnapshot:(NSDictionary *)snapshot;
- (BOOL)markUnsentInStore:(NSString *)store kind:(NSString *)kind chat:(NSString *)chat message:(NSString *)message;
- (nullable NSDictionary *)snapshotInStore:(NSString *)store kind:(NSString *)kind chat:(NSString *)chat message:(NSString *)message;
- (BOOL)recordRanges:(NSArray<NSDictionary *> *)ranges inStore:(NSString *)store chat:(NSString *)chat reader:(NSString *)reader;
- (NSArray<NSDictionary *> *)readersInStore:(NSString *)store chat:(NSString *)chat message:(NSString *)message;
// The two legacy methods above mean kind="talk". Prefer the explicit kind APIs.
- (BOOL)recordRanges:(NSArray<NSDictionary *> *)ranges inStore:(NSString *)store kind:(NSString *)kind chat:(NSString *)chat reader:(NSString *)reader;
- (NSArray<NSDictionary *> *)readersInStore:(NSString *)store kind:(NSString *)kind chat:(NSString *)chat message:(NSString *)message;
// Store-less events persist independently. A unique observed binding makes
// them queryable; multiple bindings hide them from every store, including
// previously unique bindings. No latest-store or display-name attribution.
- (BOOL)bindStore:(NSString *)store kind:(NSString *)kind chat:(NSString *)chat;
- (BOOL)recordObservedRangesByReader:(NSDictionary<NSString *, NSArray<NSDictionary *> *> *)ranges kind:(NSString *)kind chat:(NSString *)chat;
- (BOOL)removeAll;
- (NSDictionary *)counts;
@end

FOUNDATION_EXPORT void RUINInstallMessageHistory(void);
FOUNDATION_EXPORT NSDictionary *RUINMessageHistoryDiagnostics(void);
// Marshals to the managed object's context; returns copied identity fields
// and its known author MID for reader-list exclusion. A missing sender link is
// resolved only when native flags prove outgoing and the store account matches
// the active profile. Never returns a managed object.
FOUNDATION_EXPORT NSDictionary *RUINHistoryMessageKey(id message);
FOUNDATION_EXPORT NSArray<NSDictionary *> *RUINReadUsersForMessage(id message);
// Same read-only query for a copied, validated store/kind/chat/message key;
// an optional `sender` MID excludes only that message's author.
FOUNDATION_EXPORT NSArray<NSDictionary *> *RUINReadUsersForMessageKey(NSDictionary *key);
FOUNDATION_EXPORT BOOL RUINHistoryValidateReadChatKey(NSDictionary *key, id chat);
FOUNDATION_EXPORT void RUINHistoryRecordServerReadRanges(NSDictionary *key, NSDictionary *readers,
    void (^completion)(BOOL success));
// Validates the live active-account chat, binds this exact store/chat scope,
// then snapshots native cursors before the reader query. Cached positions carry
// only a first-observation time, never an invented historical read timestamp.
FOUNDATION_EXPORT void RUINObserveNativeReadPositionsForMessageKey(NSDictionary *key, id chat);
// Retention adapter bridge only: caller must already have recognized a native
// unsend flag and copied a verified key. Serializes behind prior captures and
// freezes the existing snapshot. If absent, reserves an empty contentType=-1
// row so later tombstone text cannot become a false "original". Returns {} on
// failure/disabled retention; originalUnavailable marks the non-renderable row.
FOUNDATION_EXPORT NSDictionary *RUINHistoryRetainUnsentSnapshotForKey(NSDictionary *key);
// Parent calls after a complete LineOperation.read: with type==55. Original
// replacement 0x1277d8 maps param1 -> per-chat table, param2 -> MID, incoming
// param3 -> MESSAGEID. This bridge stores observed read-up-to [0,param3] with
// time=0 (unknown), pending a validated selected-chat store binding. No
// operation is altered.
FOUNDATION_EXPORT BOOL RUINHistoryRecordType55ReadUpTo(NSString *param1, NSString *param2, NSString *param3);
// Known server event time and local observation time remain separate. Zero is unknown.
FOUNDATION_EXPORT BOOL RUINHistoryRecordType55ReadUpToWithTime(NSString *param1, NSString *param2, NSString *param3,
                                                              long long serverTime, long long observedTime);
NS_ASSUME_NONNULL_END
