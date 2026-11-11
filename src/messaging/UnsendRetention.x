%config(generator=internal);

#import "TargetMetadata.h"
#import "MessagingPrivateAPI.h"
#import "UnsendRetention.h"
#import "MessageHistory.h"
#import "RetainedMedia.h"
#import "Features.h"
#import "../core/Localization.h"
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <sqlite3.h>
#import <limits.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NSString *const RUINUnsendObservationEnabledDefaultsKey = @"RUINUnsendObservationEnabled";

/* LINE 26.16.0 / 2026.1006.1718, manifest-matching Mach-O:
 MessageContentMetadata +UNSENT @16@0:8 0x105440f00 and +SILENTLY_UNSENT
 @16@0:8 0x105440f6c return the literal NSString keys. Native UI function
 0x10461f2c8..0x10461f448 compares SILENTLY_UNSENT's string to "true", then
 checks UNSENT key presence. Native path 0x103e4c2c0..0x103e4c48c writes both
 keys with the string "true" and sets contentType=101. No guessed isUnsent
 Core Data field, messageType string heuristic, or deletion classification.
 Only supported original type-0 text snapshots are rendered; no type/metadata
 getter is changed to force a system message into a different native cell.
 Addresses are evidence, never runtime hook addresses.
 */

typedef NS_ENUM(int, HookStatus) { HookPending, HookGated, HookMissing, HookMismatch, HookInstalled };
typedef struct {
    const char *className, *selectorName, *encoding;
    void (*initialize)(Class);
    atomic_uint_fast64_t calls;
    atomic_int status;
} UnsendHook;

static void InitTalkDidSave(Class cls);
static void InitSquareDidSave(Class cls);
static void InitTalkDisplayedText(Class cls);
static void InitSquareDisplayedText(Class cls);
static void InitTransportSetMetadata(Class cls);
static void InitTransportRead(Class cls);
static UnsendHook hooks[] = {
    {"ManagedMessage", "didSave", "v16@0:8", InitTalkDidSave, ATOMIC_VAR_INIT(0), ATOMIC_VAR_INIT(HookPending)},
    {"ManagedSquareMessage", "didSave", "v16@0:8", InitSquareDidSave, ATOMIC_VAR_INIT(0), ATOMIC_VAR_INIT(HookPending)},
    {"ManagedMessage", "displayedText", "@16@0:8", InitTalkDisplayedText, ATOMIC_VAR_INIT(0), ATOMIC_VAR_INIT(HookPending)},
    {"ManagedSquareMessage", "displayedText", "@16@0:8", InitSquareDisplayedText, ATOMIC_VAR_INIT(0), ATOMIC_VAR_INIT(HookPending)},
    {"LineMessage", "setContentMetadata:", "v24@0:8@16", InitTransportSetMetadata, ATOMIC_VAR_INIT(0), ATOMIC_VAR_INIT(HookPending)},
    {"LineMessage", "read:", "v24@0:8@16", InitTransportRead, ATOMIC_VAR_INIT(0), ATOMIC_VAR_INIT(HookPending)}
};
static os_unfair_lock installLock = OS_UNFAIR_LOCK_INIT;
static atomic_bool targetSupported, keepEnabled, observationEnabled, nativeKeysVerified;
static atomic_uint_fast64_t snapshotRequests, missingOriginals, unsupportedSnapshots, renderedReturns, inspectionFailures;
static _Thread_local unsigned int processingDepth;
enum { FlagAbsent, FlagStringTrue, FlagStringFalse, FlagStringOther, FlagNumberZero,
       FlagNumberOne, FlagNumberOther, FlagNull, FlagOther, FlagShapeCount };
static atomic_uint_fast64_t flagShapes[2][FlagShapeCount];
static atomic_uint_fast64_t transportFlagShapes[2][FlagShapeCount];
static atomic_bool constructorAttempted;
static atomic_bool constructorTargetSupported, constructorTransportReady, constructorPreferenceEnabled;
static atomic_uint_fast64_t filteredMetadataCalls, persistedMarkers, unresolvedMarkerAttempts, markerFailures, ambiguousMarkerSamples;
static char pendingFilteredKey, transportReadingKey;
static os_unfair_lock markerLock = OS_UNFAIR_LOCK_INIT;
static sqlite3 *markerDatabase;

static BOOL MarkerToken(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return NO;
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length > INT_MAX) return NO;
    for (NSUInteger i = 0; i < [value length]; i++) if (![value characterAtIndex:i]) return NO;
    return YES;
}
static NSString *MarkerMessageID(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
    long long result = 0;
    for (NSUInteger i = 0; i < [value length]; i++) {
        unichar digit = [value characterAtIndex:i];
        if (digit < '0' || digit > '9' || result > (LLONG_MAX - (digit - '0')) / 10) return nil;
        result = result * 10 + digit - '0';
    }
    return result > 0 ? [NSString stringWithFormat:@"%lld", result] : nil;
}
static int MarkerBind(sqlite3_stmt *statement, int index, NSString *value) {
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes || bytes.length > INT_MAX) return SQLITE_MISMATCH;
    return sqlite3_bind_text(statement, index, bytes.bytes ?: "", (int)bytes.length, SQLITE_TRANSIENT);
}
// Called only under markerLock, lazily after a real callback (not in a constructor).
static BOOL OpenMarkers(void) {
    if (markerDatabase) return YES;
    NSURL *root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    if (!root) return NO;
    root = [root URLByAppendingPathComponent:@"RUIN" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:NULL]) return NO;
    NSURL *url = [root URLByAppendingPathComponent:@"unsend-markers.sqlite"];
    int status = sqlite3_open_v2(url.fileSystemRepresentation, &markerDatabase,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL);
    if (status == SQLITE_OK) {
        sqlite3_busy_timeout(markerDatabase, 250);
        status = sqlite3_exec(markerDatabase,
            "PRAGMA journal_mode=WAL;CREATE TABLE IF NOT EXISTS events("
            "event_id INTEGER PRIMARY KEY,message TEXT NOT NULL,from_mid TEXT NOT NULL,to_mid TEXT NOT NULL,"
            "UNIQUE(message,from_mid,to_mid));CREATE TABLE IF NOT EXISTS bindings("
            "event_id INTEGER NOT NULL,store TEXT NOT NULL,chat TEXT NOT NULL,PRIMARY KEY(event_id,store,chat));", NULL, NULL, NULL);
    }
    if (status != SQLITE_OK) {
        sqlite3_close_v2(markerDatabase); markerDatabase = NULL; return NO;
    }
#if TARGET_OS_IPHONE
    [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}
        ofItemAtPath:root.path error:NULL];
#endif
    return YES;
}
static BOOL RecordMarker(NSString *message, NSString *from, NSString *to) {
    os_unfair_lock_lock(&markerLock);
    BOOL ok = NO;
    @try {
        if (!OpenMarkers()) return NO;
        sqlite3_stmt *statement = NULL;
        int status = sqlite3_prepare_v2(markerDatabase,
            "INSERT OR IGNORE INTO events(message,from_mid,to_mid) VALUES(?,?,?);", -1, &statement, NULL);
        if (status == SQLITE_OK) status = MarkerBind(statement, 1, message);
        if (status == SQLITE_OK) status = MarkerBind(statement, 2, from);
        if (status == SQLITE_OK) status = MarkerBind(statement, 3, to);
        if (status == SQLITE_OK) status = sqlite3_step(statement);
        sqlite3_finalize(statement); ok = status == SQLITE_DONE;
    } @finally { os_unfair_lock_unlock(&markerLock); }
    return ok;
}
// Match the actual message ID and one literal native from/to MID, not a guessed
// sender/recipient role. Persist observed store bindings; conflicting stores or
// multiple native events for the same candidate chat are deliberately unresolved.
static BOOL MarkerForKey(NSDictionary *key) {
    NSString *message = MarkerMessageID(key[@"message"]);
    if (![key[@"kind"] isEqual:@"talk"] || !message || !MarkerToken(key[@"store"]) || !MarkerToken(key[@"chat"])) return NO;
    os_unfair_lock_lock(&markerLock);
    BOOL matched = NO;
    @try {
        if (!OpenMarkers()) { atomic_fetch_add(&markerFailures, 1); return NO; }
        if (sqlite3_exec(markerDatabase, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) { atomic_fetch_add(&markerFailures, 1); return NO; }
        sqlite3_stmt *statement = NULL;
        int status = sqlite3_prepare_v2(markerDatabase,
            "SELECT event_id FROM events WHERE message=?1 AND (from_mid=?2 OR to_mid=?2) LIMIT 2;", -1, &statement, NULL);
        if (status == SQLITE_OK) status = MarkerBind(statement, 1, message);
        if (status == SQLITE_OK) status = MarkerBind(statement, 2, key[@"chat"]);
        if (status == SQLITE_OK) status = sqlite3_step(statement);
        sqlite3_int64 event = status == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0;
        if (status == SQLITE_ROW) status = sqlite3_step(statement);
        sqlite3_finalize(statement); statement = NULL;
        if (status != SQLITE_DONE || !event) {
            if (status == SQLITE_ROW) atomic_fetch_add(&ambiguousMarkerSamples, 1);
            else if (status != SQLITE_DONE) atomic_fetch_add(&markerFailures, 1);
            sqlite3_exec(markerDatabase, "ROLLBACK", NULL, NULL, NULL); return NO;
        }
        status = sqlite3_prepare_v2(markerDatabase, "INSERT OR IGNORE INTO bindings VALUES(?,?,?);", -1, &statement, NULL);
        if (status == SQLITE_OK) status = sqlite3_bind_int64(statement, 1, event);
        if (status == SQLITE_OK) status = MarkerBind(statement, 2, key[@"store"]);
        if (status == SQLITE_OK) status = MarkerBind(statement, 3, key[@"chat"]);
        if (status == SQLITE_OK) status = sqlite3_step(statement);
        sqlite3_finalize(statement); statement = NULL;
        if (status == SQLITE_DONE) status = sqlite3_prepare_v2(markerDatabase,
            "SELECT COUNT(DISTINCT store) FROM bindings WHERE event_id=? AND chat=?;", -1, &statement, NULL);
        if (status == SQLITE_OK) status = sqlite3_bind_int64(statement, 1, event);
        if (status == SQLITE_OK) status = MarkerBind(statement, 2, key[@"chat"]);
        if (status == SQLITE_OK) status = sqlite3_step(statement);
        if (status == SQLITE_ROW) {
            long long count = sqlite3_column_int64(statement, 0); matched = count == 1;
            if (count > 1) atomic_fetch_add(&ambiguousMarkerSamples, 1);
        }
        sqlite3_finalize(statement);
        if (status != SQLITE_ROW || sqlite3_exec(markerDatabase, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) {
            sqlite3_exec(markerDatabase, "ROLLBACK", NULL, NULL, NULL); matched = NO; atomic_fetch_add(&markerFailures, 1);
        }
    } @finally { os_unfair_lock_unlock(&markerLock); }
    return matched;
}
BOOL RUINClearUnsendMarkers(void) {
    os_unfair_lock_lock(&markerLock);
    BOOL ok = NO;
    @try {
        if (!OpenMarkers()) return NO;
        ok = sqlite3_exec(markerDatabase, "BEGIN IMMEDIATE;DELETE FROM bindings;DELETE FROM events;COMMIT;", NULL, NULL, NULL) == SQLITE_OK;
        if (!ok) sqlite3_exec(markerDatabase, "ROLLBACK", NULL, NULL, NULL);
    } @finally { os_unfair_lock_unlock(&markerLock); }
    return ok;
}
static NSDictionary *MarkerCounts(void) {
    os_unfair_lock_lock(&markerLock);
    NSMutableDictionary *counts = [NSMutableDictionary dictionaryWithObject:@(markerDatabase != NULL) forKey:@"ready"];
    @try {
        if (markerDatabase) for (NSString *table in @[@"events", @"bindings"]) {
            sqlite3_stmt *statement = NULL;
            NSString *sql = [NSString stringWithFormat:@"SELECT COUNT(*) FROM %@", table];
            if (sqlite3_prepare_v2(markerDatabase, sql.UTF8String, -1, &statement, NULL) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW)
                counts[table] = @(sqlite3_column_int64(statement, 0));
            sqlite3_finalize(statement);
        }
    } @finally { os_unfair_lock_unlock(&markerLock); }
    return [counts copy];
}

RUINNativeUnsendState RUINUnsendStateForMetadata(NSDictionary *metadata) {
    if (![metadata isKindOfClass:NSDictionary.class]) return RUINNativeUnsendUnsupportedValue;
    id normal = metadata[@"UNSENT"], silent = metadata[@"SILENTLY_UNSENT"];
    if ([silent isKindOfClass:NSString.class] && [silent isEqualToString:@"true"]) return RUINNativeUnsendSilent;
    if ([normal isKindOfClass:NSString.class]) return RUINNativeUnsendNormal;
    if ((normal && ![normal isKindOfClass:NSString.class]) || (silent && ![silent isKindOfClass:NSString.class]))
        return RUINNativeUnsendUnsupportedValue;
    return RUINNativeUnsendNone;
}
static BOOL TargetMatches(void) {
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
}
static BOOL VerifyNativeKeys(void) {
    Class cls = objc_getClass("_TtC19LineSharedMessaging22MessageContentMetadata");
    if (!cls) return NO;
    @try {
        for (NSString *key in @[@"UNSENT", @"SILENTLY_UNSENT"]) {
            SEL selector = sel_registerName(key.UTF8String);
            Method method = class_getClassMethod(cls, selector);
            const char *encoding = method ? method_getTypeEncoding(method) : NULL;
            if (!encoding || strcmp(encoding, "@16@0:8")) return NO;
            id value = ([key isEqual:@"UNSENT"] ? [(Class<RUINMessagingUnsendKeys>)cls UNSENT] : [(Class<RUINMessagingUnsendKeys>)cls SILENTLY_UNSENT]);
            if (![value isKindOfClass:NSString.class] || ![value isEqualToString:key]) return NO;
        }
        return YES;
    } @catch (__unused NSException *exception) { return NO; }
}
static NSDictionary *Metadata(id object) {
    if (![object isKindOfClass:NSManagedObject.class] || [(NSManagedObject *)object isDeleted] ||
        ![(NSManagedObject *)object managedObjectContext]) return nil;
    Class talk = objc_getClass("ManagedMessage"), square = objc_getClass("ManagedSquareMessage");
    if (!(talk && [object isKindOfClass:talk]) && !(square && [object isKindOfClass:square])) return nil;
    SEL selector = sel_registerName("contentMetadataDictionary");
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, "@16@0:8")) return nil;
    id result = [(id<RUINMessagingMessageFields>)object contentMetadataDictionary];
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}
static int FlagShape(id value) {
    if (!value) return FlagAbsent;
    if ([value isKindOfClass:NSString.class]) {
        if ([value isEqualToString:@"true"]) return FlagStringTrue;
        if ([value isEqualToString:@"false"]) return FlagStringFalse;
        return FlagStringOther;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        if ([value isEqualToNumber:@0]) return FlagNumberZero;
        if ([value isEqualToNumber:@1]) return FlagNumberOne;
        return FlagNumberOther;
    }
    return value == NSNull.null ? FlagNull : FlagOther;
}
static void SampleFlags(NSDictionary *metadata, atomic_uint_fast64_t samples[2][FlagShapeCount]) {
    atomic_fetch_add(&samples[0][FlagShape(metadata[@"UNSENT"])], 1);
    atomic_fetch_add(&samples[1][FlagShape(metadata[@"SILENTLY_UNSENT"])], 1);
}
static NSString *RetainedNativePlaintext(id message) {
    NSManagedObject *managed = message;
    NSAttributeDescription *type = managed.entity.attributesByName[@"contentType"];
    if (!type || type.attributeType != NSInteger16AttributeType) return nil;
    id value = [managed valueForKey:@"contentType"];
    if (![value isKindOfClass:NSNumber.class] || [value shortValue] != 0) return nil;
    SEL selector = sel_registerName("plaintext");
    Method method = class_getInstanceMethod(object_getClass(message), selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, "@16@0:8")) return nil;
    id text = [(id<RUINMessagingMessageFields>)message plaintext];
    return [text isKindOfClass:NSString.class] && [text length] ? text : nil;
}
static NSString *InspectAndRetain(id message) {
    if (!atomic_load(&targetSupported) || (!atomic_load(&keepEnabled) && !atomic_load(&observationEnabled))) return nil;
    @try {
        if (![message isKindOfClass:NSManagedObject.class] || [(NSManagedObject *)message isDeleted] ||
            ![(NSManagedObject *)message managedObjectContext]) return nil;
        NSDictionary *metadata = Metadata(message);
        if (metadata && atomic_load(&observationEnabled)) {
            SampleFlags(metadata, flagShapes);
        }
        RUINNativeUnsendState state = metadata ? RUINUnsendStateForMetadata(metadata) : RUINNativeUnsendNone;
        if (!atomic_load(&keepEnabled)) return nil;
        NSDictionary *key = RUINHistoryMessageKey(message);
        if (!key.count) return nil;
        BOOL filteredMarker = MarkerForKey(key);
        if (filteredMarker && state == RUINNativeUnsendNone) {
            // The specific transport filter kept native plaintext intact. Do
            // not replace it with a synthetic body or require a prior snapshot.
            NSString *retained = RetainedNativePlaintext(message);
            if (retained) return [retained stringByAppendingFormat:@"\n%@", RUINLocalizedString(@"取消済")];
        }
        if (!filteredMarker && (!atomic_load(&nativeKeysVerified) ||
            (state != RUINNativeUnsendNormal && state != RUINNativeUnsendSilent))) return nil;
#if TARGET_OS_IPHONE
        RUINCaptureRetainedMedia(message, key);
#endif
        atomic_fetch_add(&snapshotRequests, 1);
        NSDictionary *snapshot = RUINHistoryRetainUnsentSnapshotForKey(key);
        if (!snapshot.count || [snapshot[@"originalUnavailable"] boolValue]) {
            atomic_fetch_add(&missingOriginals, 1); return nil;
        }
        id body = snapshot[@"body"];
        if (![snapshot[@"unsent"] boolValue] || ![body isKindOfClass:NSString.class] || ![body length] ||
            ![snapshot[@"contentType"] isKindOfClass:NSNumber.class] || [snapshot[@"contentType"] longLongValue] != 0) {
            atomic_fetch_add(&unsupportedSnapshots, 1); return nil;
        }
        return [body stringByAppendingFormat:@"\n%@", RUINLocalizedString(@"取消済")];
    } @catch (__unused NSException *exception) {
        atomic_fetch_add(&inspectionFailures, 1); return nil;
    }
}
NSString *RUINRetainedUnsentTextForMessage(id message) {
    if (processingDepth) return nil;
    processingDepth++;
    @try { return InspectAndRetain(message); }
    @finally { processingDepth--; }
}
static void ForwardDidSave(UnsendHook *hook, id self, void (^original)(void)) {
    atomic_fetch_add(&hook->calls, 1);
    BOOL outermost = processingDepth++ == 0;
    @try {
        // Freeze before the prior IMP: MessageHistory captures after forwarding.
        // Never infer unsend from deletion, and never omit the original callback.
        if (outermost) (void)InspectAndRetain(self);
        original();
    } @finally { processingDepth--; }
}
static id ForwardDisplay(UnsendHook *hook, id self, id (^original)(void)) {
    atomic_fetch_add(&hook->calls, 1);
    BOOL outermost = processingDepth++ == 0;
    @try {
        NSString *replacement = outermost ? InspectAndRetain(self) : nil;
        id displayed = original();
        if (replacement) { atomic_fetch_add(&renderedReturns, 1); return replacement; }
        return displayed;
    } @finally { processingDepth--; }
}
%group RUINRetainTalkSave
%hook RUINRetainTalk
- (void)didSave {
    ForwardDidSave(&hooks[0], self, ^{ %orig; });
}
%end
%end
%group RUINRetainSquareSave
%hook RUINRetainSquare
- (void)didSave {
    ForwardDidSave(&hooks[1], self, ^{ %orig; });
}
%end
%end
%group RUINRetainTalkDisplay
%hook RUINRetainTalk
- (id)displayedText {
    return ForwardDisplay(&hooks[2], self, ^id{ return %orig; });
}
%end
%end
%group RUINRetainSquareDisplay
%hook RUINRetainSquare
- (id)displayedText {
    return ForwardDisplay(&hooks[3], self, ^id{ return %orig; });
}
%end
%end
static NSString *TransportString(id object, const char *name) {
    SEL selector = sel_registerName(name);
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, "@16@0:8")) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
    return MarkerToken(value) ? [value copy] : nil;
}
static void PersistFilteredMessage(id message) {
    @try {
        NSString *identifier = MarkerMessageID(TransportString(message, "id"));
        NSString *from = TransportString(message, "from"), *to = TransportString(message, "to");
        if (!identifier || !from || !to) { atomic_fetch_add(&unresolvedMarkerAttempts, 1); return; }
        if (RecordMarker(identifier, from, to)) atomic_fetch_add(&persistedMarkers, 1);
        else atomic_fetch_add(&markerFailures, 1);
    } @catch (__unused NSException *exception) { atomic_fetch_add(&markerFailures, 1); }
}
%group RUINRetainMetadata
%hook RUINRetainTransport
- (void)setContentMetadata:(id)metadata {
    atomic_fetch_add(&hooks[4].calls, 1);
    if (atomic_load(&targetSupported) && atomic_load(&observationEnabled) && [metadata isKindOfClass:NSDictionary.class])
        SampleFlags(metadata, transportFlagShapes);
    id forwarded = metadata;
    BOOL filtered = NO;
    @try {
        // Resolved original CFG: 0xe0d3c tests presence; 0xe0d98 dispatches
        // blockUnsend false/true to unchanged/UNSENT-only-filtered forwarding.
        // RUIN independently uses its existing opt-in preference and removes
        // precisely this key from a copy, without mutating the caller's map.
        if (atomic_load(&targetSupported) && [metadata isKindOfClass:NSDictionary.class] &&
            [metadata objectForKey:@"UNSENT"] != nil &&
            [NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey]) {
            NSMutableDictionary *copy = [metadata mutableCopy];
            [copy removeObjectForKey:@"UNSENT"]; forwarded = copy; filtered = YES;
            atomic_fetch_add(&filteredMetadataCalls, 1);
        }
        objc_setAssociatedObject(self, &pendingFilteredKey, filtered ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *exception) {
        forwarded = metadata; filtered = NO; atomic_fetch_add(&inspectionFailures, 1);
    }
    %orig(forwarded);
    if (filtered && ![objc_getAssociatedObject(self, &transportReadingKey) boolValue]) PersistFilteredMessage(self);

}
%end
%end
%group RUINRetainDecode
%hook RUINRetainTransport
- (void)read:(id)protocol {
    atomic_fetch_add(&hooks[5].calls, 1);
    objc_setAssociatedObject(self, &transportReadingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &pendingFilteredKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        %orig;
        // Thrift may set metadata before id/from/to. Correlate only after the
        // complete native decoder returns; never read message plaintext here.
        if ([objc_getAssociatedObject(self, &pendingFilteredKey) boolValue]) PersistFilteredMessage(self);
    } @finally {
        objc_setAssociatedObject(self, &transportReadingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &pendingFilteredKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

}
%end
%end

static void InitTalkDidSave(Class cls) { %init(RUINRetainTalkSave, RUINRetainTalk = cls); }
static void InitSquareDidSave(Class cls) { %init(RUINRetainSquareSave, RUINRetainSquare = cls); }
static void InitTalkDisplayedText(Class cls) { %init(RUINRetainTalkDisplay, RUINRetainTalk = cls); }
static void InitSquareDisplayedText(Class cls) { %init(RUINRetainSquareDisplay, RUINRetainSquare = cls); }
static void InitTransportSetMetadata(Class cls) { %init(RUINRetainMetadata, RUINRetainTransport = cls); }
static void InitTransportRead(Class cls) { %init(RUINRetainDecode, RUINRetainTransport = cls); }
static void InstallHook(UnsendHook *hook) {
    if (atomic_load(&hook->status) == HookInstalled) return;
    Class cls = objc_getClass(hook->className);
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName(hook->selectorName)) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!method || !method_getImplementation(method)) { atomic_store(&hook->status, HookMissing); return; }
    if (!encoding || strcmp(encoding, hook->encoding)) { atomic_store(&hook->status, HookMismatch); return; }
    hook->initialize(cls);
    atomic_store(&hook->status, HookInstalled);
}
static BOOL RefreshEnablement(void) {
    BOOL supported = TargetMatches();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    atomic_store(&targetSupported, supported);
    atomic_store(&keepEnabled, supported && [defaults boolForKey:RUINKeepUnsentMessagesKey]);
    atomic_store(&observationEnabled, supported && [defaults boolForKey:RUINUnsendObservationEnabledDefaultsKey]);
    atomic_store(&nativeKeysVerified, supported && VerifyNativeKeys());
    return supported;
}
void RUINInstallEarlyUnsendTransport(void) {
    os_unfair_lock_lock(&installLock);
    @try {
        if (RefreshEnablement()) { InstallHook(&hooks[4]); InstallHook(&hooks[5]); }
        else for (NSUInteger i = 4; i < 6; i++)
            if (atomic_load(&hooks[i].status) != HookInstalled) atomic_store(&hooks[i].status, HookGated);
    } @finally { os_unfair_lock_unlock(&installLock); }
}
__attribute__((constructor)) static void RUINEarlyUnsendConstructor(void) {
    @autoreleasepool {
        atomic_store(&constructorAttempted, true);
        RUINInstallEarlyUnsendTransport();
        atomic_store(&constructorTargetSupported, atomic_load(&targetSupported));
        atomic_store(&constructorPreferenceEnabled, atomic_load(&keepEnabled));
        atomic_store(&constructorTransportReady, atomic_load(&hooks[4].status) == HookInstalled && atomic_load(&hooks[5].status) == HookInstalled);
#if TARGET_OS_IPHONE
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil
            usingBlock:^(__unused NSNotification *notification) { RUINInstallUnsendRetention(); }];
#endif
    }
}
void RUINInstallUnsendRetention(void) {
    os_unfair_lock_lock(&installLock);
    @try {
        BOOL supported = RefreshEnablement();
        RUINInstallMessageHistory(); // Refresh shared enablement even when the target becomes unsupported.
        if (!supported) {
            for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++)
                if (atomic_load(&hooks[i].status) != HookInstalled) atomic_store(&hooks[i].status, HookGated);
            return;
        }
        for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) InstallHook(&hooks[i]);
    } @finally { os_unfair_lock_unlock(&installLock); }
}
NSDictionary *RUINUnsendRetentionDiagnostics(void) {
    NSMutableArray *installed = [NSMutableArray array];
    NSArray *statuses = @[@"pending", @"version_gated", @"missing", @"encoding_mismatch", @"installed"];
    for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
        UnsendHook *hook = &hooks[i];
        [installed addObject:@{@"class":[NSString stringWithUTF8String:hook->className],
            @"selector":[NSString stringWithUTF8String:hook->selectorName],
            @"expectedEncoding":[NSString stringWithUTF8String:hook->encoding],
            @"status":statuses[atomic_load(&hook->status)], @"calls":@(atomic_load(&hook->calls))}];
    }
    NSArray *shapeNames = @[@"absent", @"string_true", @"string_false", @"string_other", @"number_zero", @"number_one", @"number_other", @"null", @"other_type"];
    NSMutableDictionary *observations = [NSMutableDictionary dictionary];
    NSMutableDictionary *transportObservations = [NSMutableDictionary dictionary];
    for (NSUInteger flag = 0; flag < 2; flag++) {
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        for (NSUInteger shape = 0; shape < FlagShapeCount; shape++) counts[shapeNames[shape]] = @(atomic_load(&flagShapes[flag][shape]));
        observations[flag == 0 ? @"UNSENT" : @"SILENTLY_UNSENT"] = counts;
        NSMutableDictionary *transportCounts = [NSMutableDictionary dictionary];
        for (NSUInteger shape = 0; shape < FlagShapeCount; shape++) transportCounts[shapeNames[shape]] = @(atomic_load(&transportFlagShapes[flag][shape]));
        transportObservations[flag == 0 ? @"UNSENT" : @"SILENTLY_UNSENT"] = transportCounts;
    }
    return @{@"targetSupported":@(atomic_load(&targetSupported)), @"enabled":@(atomic_load(&keepEnabled)),
        @"preference":RUINKeepUnsentMessagesKey, @"nativeKeysVerified":@(atomic_load(&nativeKeysVerified)), @"hooks":installed,
        @"observationEnabled":@(atomic_load(&observationEnabled)), @"observationPreference":RUINUnsendObservationEnabledDefaultsKey,
        @"testFlagShapeSamples":observations, @"testTransportFlagShapeSamples":transportObservations,
        @"snapshotRequests":@(atomic_load(&snapshotRequests)),
        @"missingOriginalSamples":@(atomic_load(&missingOriginals)), @"unsupportedSnapshotSamples":@(atomic_load(&unsupportedSnapshots)),
        @"displayReplacementReturns":@(atomic_load(&renderedReturns)), @"inspectionFailures":@(atomic_load(&inspectionFailures)),
        @"constructorAttempted":@(atomic_load(&constructorAttempted)),
        @"constructorTargetSupported":@(atomic_load(&constructorTargetSupported)),
        @"constructorTransportReady":@(atomic_load(&constructorTransportReady)),
        @"constructorPreferenceEnabled":@(atomic_load(&constructorPreferenceEnabled)),
        @"earlyTransportHookInstalled":@(atomic_load(&hooks[4].status) == HookInstalled && atomic_load(&hooks[5].status) == HookInstalled),
        @"filteredMetadataCalls":@(atomic_load(&filteredMetadataCalls)), @"persistedMarkerAttempts":@(atomic_load(&persistedMarkers)),
        @"unresolvedMarkerAttempts":@(atomic_load(&unresolvedMarkerAttempts)), @"markerFailures":@(atomic_load(&markerFailures)),
        @"ambiguousMarkerSamples":@(atomic_load(&ambiguousMarkerSamples)), @"markerStore":MarkerCounts(),
        @"recognition":@"string-valued UNSENT presence; SILENTLY_UNSENT exactly string true; unexpected types pass through",
        @"transportFilter":@"Original-CFG condition: retention enabled and UNSENT key present; copy map, remove only UNSENT, call original once. SILENTLY_UNSENT is preserved.",
        @"markerAttribution":@"exact positive message ID plus actual chat MID equal to native from/to, then persisted store binding; multiple known stores or multiple candidate events remain unresolved",
        @"originalHookEvidence":@"Original LineOperation type 55 maps param1 table, param2 MID, incoming param3 MESSAGEID. Parent records complete post-read fields through RUINHistoryRecordType55ReadUpTo; no unsend operation number is inferred.",
        @"nativeUnsendBoundary":@{
            @"installed":@NO,
            @"oldRegistrationCallsite":@"0xde50c",
            @"oldReplacement":@"0xda7f4",
            @"oldOriginalSlot":@"0x4ef778",
            @"installerFourthArgument":@2,
            @"fourthArgumentMeaningVerified":@NO,
            @"disabledBehavior":@"forwards machine registers x0 through x3 to the saved original",
            @"enabledBehavior":@"looks up message by ID/context, updates local text and archive, returns without calling the original",
            @"currentTargetVerified":@NO,
            @"currentABIVerified":@NO,
            @"resolverGap":@"0x101db8 consumes an unresolved runtime target input and uses dyld image enumeration/slide resolution; no LINE 26.16.0 deletion address or source-level signature is established",
            @"installationRequirement":@"verify current target, argument roles/ownership/return ABI, and local-delete versus acknowledgement behavior before adding an independent native shim"
        },
        @"capture":@"MessageHistory didSave captures; native-flag didSave freezes before forwarding, including a non-renderable reservation when original was unavailable",
        @"displayAdapterInstalled":@(atomic_load(&hooks[2].status) == HookInstalled || atomic_load(&hooks[3].status) == HookInstalled),
        @"inChatPixelVerified":@NO, @"nativeDeletionCallbackSkipped":@NO,
        @"metadataModificationScope":@"only the explicitly authorized LineMessage UNSENT input key; no model metadata getters are rewritten",
        @"runtimeQuestion":@"For generated RUIN TEST messages, does early UNSENT filtering retain native plaintext through foreground/background/relaunch sync and does the cell request displayedText for the sidecar label? SILENTLY_UNSENT remains native and may remove the object.",
        @"fullRetentionParityVerified":@NO,
        @"nativeGap":@"transport metadata filtering and remaining-object rendering do not cover an unhooked native path that removes the model object",
        @"mediaRetentionImplemented":@NO,
        @"mediaPlan":@"Resolve verified local imageFileURL/audioFileURL/attachedFileURL/thumbnailFileURL on the owning queue; establish which native cleanup removes each file; copy into the independent archive before that cleanup, then always forward it. Unsend-specific cleanup timing and safe media reattachment are not verified."
    };
}

#if defined(RUIN_UNSEND_HOST_CHECK) && RUIN_UNSEND_HOST_CHECK
/* Native host check, from ruin/ (temporary fixture databases only):
 xcrun --sdk macosx clang -DRUIN_UNSEND_HOST_CHECK=1 -fobjc-arc -fblocks \
   -std=gnu11 -Wall -Wextra -Werror -I. Features.m MessageHistory.m \
   UnsendRetention.m -framework Foundation -framework CoreData -lsqlite3 \
   -o /tmp/ruin-check-unsend && /tmp/ruin-check-unsend
 */
#import <stdio.h>

static void Check(BOOL condition, NSString *reason) {
    if (!condition) @throw [NSException exceptionWithName:@"RUINUnsendCheck" reason:reason userInfo:nil];
}
static NSDictionary *testInfo;
static NSURL *testSupport;
static IMP originalDirectories;
static id testTransportArgument;
static atomic_uint_fast64_t testDidSaveCalls, testDisplayCalls, testTransportSetterCalls, testTransportReadCalls;
static NSDictionary *TestBundleInfo(id self, SEL selector) { (void)self; (void)selector; return testInfo; }
static NSArray *TestDirectories(id self, SEL selector, NSSearchPathDirectory directory, NSSearchPathDomainMask mask) {
    if (directory == NSApplicationSupportDirectory && mask == NSUserDomainMask) return @[testSupport];
    return ((id (*)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask))originalDirectories)(self, selector, directory, mask);
}
static id TestNormalKey(id self, SEL selector) { (void)self; (void)selector; return @"UNSENT"; }
static id TestSilentKey(id self, SEL selector) { (void)self; (void)selector; return @"SILENTLY_UNSENT"; }

@interface LineMessage : NSObject {
    NSDictionary *_contentMetadata;
}
@property (nonatomic, copy) NSDictionary *contentMetadata;
@property (nonatomic, copy) NSString *id;
@property (nonatomic, copy) NSString *from;
@property (nonatomic, copy) NSString *to;
- (void)read:(id)protocol;
@end
@implementation LineMessage
- (void)setContentMetadata:(NSDictionary *)metadata {
    atomic_fetch_add(&testTransportSetterCalls, 1); testTransportArgument = metadata; _contentMetadata = [metadata copy];
}
- (NSDictionary *)contentMetadata { return _contentMetadata; }
- (void)read:(id)protocol {
    atomic_fetch_add(&testTransportReadCalls, 1);
    [self setContentMetadata:protocol[@"metadata"]]; // Deliberately before identity fields.
    self.id = protocol[@"id"]; self.from = protocol[@"from"]; self.to = protocol[@"to"];
}
@end

@interface RUINFixtureMessageBase : NSManagedObject
@property (nonatomic, readonly) NSDictionary *contentMetadataDictionary;
@property (nonatomic, readonly) NSString *plaintext;
@property (nonatomic, readonly) NSString *displayedText;
@property (nonatomic, readonly) id chatObject;
@property (nonatomic, readonly) id senderObject;
@end
@implementation RUINFixtureMessageBase
- (NSDictionary *)contentMetadataDictionary {
    NSData *data = [self valueForKey:@"contentMetadata"];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : @{};
}
- (NSString *)plaintext { return [self valueForKey:@"text"]; }
- (NSString *)displayedText { atomic_fetch_add(&testDisplayCalls, 1); return @"native display"; }
- (id)chatObject { return [self valueForKey:@"chat"]; }
- (id)senderObject { return [self valueForKey:@"sender"]; }
- (void)didSave { [super didSave]; atomic_fetch_add(&testDidSaveCalls, 1); }
@end
@interface ManagedMessage : RUINFixtureMessageBase @end
@implementation ManagedMessage @end
@interface ManagedSquareMessage : RUINFixtureMessageBase @end
@implementation ManagedSquareMessage @end

static NSAttributeDescription *TestAttribute(NSString *name, NSAttributeType type) {
    NSAttributeDescription *attribute = [NSAttributeDescription new];
    attribute.name = name; attribute.attributeType = type; attribute.optional = YES;
    return attribute;
}
static NSManagedObjectModel *TestModel(void) {
    NSEntityDescription *chat = [NSEntityDescription new], *sender = [NSEntityDescription new];
    chat.name = @"Chat"; chat.managedObjectClassName = @"NSManagedObject"; chat.properties = @[TestAttribute(@"mid", NSStringAttributeType)];
    sender.name = @"Sender"; sender.managedObjectClassName = @"NSManagedObject"; sender.properties = @[TestAttribute(@"mid", NSStringAttributeType)];
    NSMutableArray *entities = [NSMutableArray arrayWithObjects:chat, sender, nil];
    for (NSString *name in @[@"ManagedMessage", @"ManagedSquareMessage"]) {
        NSEntityDescription *entity = [NSEntityDescription new]; entity.name = name; entity.managedObjectClassName = name;
        NSRelationshipDescription *chatRelation = [NSRelationshipDescription new], *senderRelation = [NSRelationshipDescription new];
        chatRelation.name = @"chat"; chatRelation.destinationEntity = chat; chatRelation.maxCount = 1; chatRelation.optional = YES;
        senderRelation.name = @"sender"; senderRelation.destinationEntity = sender; senderRelation.maxCount = 1; senderRelation.optional = YES;
        entity.properties = @[TestAttribute(@"id", NSStringAttributeType), TestAttribute(@"text", NSStringAttributeType),
            TestAttribute(@"contentType", NSInteger16AttributeType), TestAttribute(@"timestamp", NSInteger64AttributeType),
            TestAttribute(@"messageType", NSStringAttributeType), TestAttribute(@"contentMetadata", NSBinaryDataAttributeType),
            chatRelation, senderRelation];
        [entities addObject:entity];
    }
    NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = entities; return model;
}
static void TestMetadata(NSManagedObject *message, NSDictionary *metadata) {
    [message setValue:[NSJSONSerialization dataWithJSONObject:metadata options:0 error:NULL] forKey:@"contentMetadata"];
}
static RUINFixtureMessageBase *TestInsert(NSManagedObjectContext *context, NSString *className, NSString *identifier,
                                         NSString *text, NSManagedObject *chat, NSManagedObject *sender) {
    RUINFixtureMessageBase *message = [NSEntityDescription insertNewObjectForEntityForName:className inManagedObjectContext:context];
    [message setValue:identifier forKey:@"id"]; [message setValue:text forKey:@"text"];
    [message setValue:@0 forKey:@"contentType"]; [message setValue:@1 forKey:@"timestamp"];
    [message setValue:@"USER" forKey:@"messageType"]; [message setValue:chat forKey:@"chat"]; [message setValue:sender forKey:@"sender"];
    TestMetadata(message, @{}); return message;
}
int main(void) {
    @autoreleasepool {
        NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"ruin-unsend-check-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id oldKeep = [defaults objectForKey:RUINKeepUnsentMessagesKey];
        id oldObserve = [defaults objectForKey:RUINUnsendObservationEnabledDefaultsKey];
        id oldReaders = [defaults objectForKey:RUINTrackReadUsersKey];
        Method infoMethod = NULL, directoriesMethod = NULL;
        IMP oldInfo = NULL;
        NSPersistentStoreCoordinator *coordinator = nil;
        NSManagedObjectContext *context = nil;
        RUINHistoryStore *archive = nil;
        int result = 0;
        @try {
            Check(RUINUnsendStateForMetadata(@{}) == RUINNativeUnsendNone, @"empty metadata classified as unsend");
            Check(RUINUnsendStateForMetadata(@{@"UNSENT":@"true"}) == RUINNativeUnsendNormal, @"normal native flag not recognized");
            Check(RUINUnsendStateForMetadata(@{@"UNSENT":@"false"}) == RUINNativeUnsendNormal, @"native presence rule changed into a guessed truth conversion");
            Check(RUINUnsendStateForMetadata(@{@"SILENTLY_UNSENT":@"true"}) == RUINNativeUnsendSilent, @"silent native flag not recognized");
            Check(RUINUnsendStateForMetadata(@{@"SILENTLY_UNSENT":@"false"}) == RUINNativeUnsendNone, @"silent false classified as unsend");
            Check(RUINUnsendStateForMetadata(@{@"UNSENT":@YES}) == RUINNativeUnsendUnsupportedValue, @"numeric flag guessed as native string");
            Check(RUINUnsendStateForMetadata(@{@"DELETED":@"true"}) == RUINNativeUnsendNone, @"manual deletion heuristic was used");
            [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:NULL];
            testSupport = root;
            testInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
            infoMethod = class_getInstanceMethod(object_getClass(NSBundle.mainBundle), @selector(infoDictionary));
            oldInfo = method_setImplementation(infoMethod, (IMP)TestBundleInfo);
            directoriesMethod = class_getInstanceMethod(object_getClass(NSFileManager.defaultManager), @selector(URLsForDirectory:inDomains:));
            originalDirectories = method_setImplementation(directoriesMethod, (IMP)TestDirectories);
            Class keys = objc_allocateClassPair(NSObject.class, "_TtC19LineSharedMessaging22MessageContentMetadata", 0);
            Check(keys != Nil, @"native key fixture class already exists");
            class_addMethod(object_getClass(keys), sel_registerName("UNSENT"), (IMP)TestNormalKey, "@16@0:8");
            class_addMethod(object_getClass(keys), sel_registerName("SILENTLY_UNSENT"), (IMP)TestSilentKey, "@16@0:8");
            objc_registerClassPair(keys);
            [defaults setBool:NO forKey:RUINTrackReadUsersKey];
            [defaults setBool:NO forKey:RUINKeepUnsentMessagesKey];
            [defaults setBool:YES forKey:RUINUnsendObservationEnabledDefaultsKey];
            IMP baseDisplay = method_getImplementation(class_getInstanceMethod(RUINFixtureMessageBase.class, @selector(displayedText)));
            RUINInstallEarlyUnsendTransport();
            Check([RUINUnsendRetentionDiagnostics()[@"constructorAttempted"] boolValue] &&
                [RUINUnsendRetentionDiagnostics()[@"earlyTransportHookInstalled"] boolValue] &&
                ![RUINMessageHistoryDiagnostics()[@"storageReady"] boolValue], @"early transport install required UI/history startup or missed the constructor");
            Check(method_getImplementation(class_getInstanceMethod(RUINFixtureMessageBase.class, @selector(displayedText))) == baseDisplay,
                @"inherited model hook changed the superclass");
            LineMessage *transport = [LineMessage new];
            NSDictionary *incoming = @{@"UNSENT":@"true", @"SILENTLY_UNSENT":@"true", @"fixture":@"unchanged"};
            [transport setContentMetadata:incoming];
            Check(testTransportArgument == incoming && [transport.contentMetadata isEqual:incoming], @"transport metadata was changed or original setter skipped");
            Check([RUINUnsendRetentionDiagnostics()[@"testTransportFlagShapeSamples"][@"UNSENT"][@"string_true"] integerValue] == 1,
                @"explicit transport observation did not record the flag shape");

            // No UI/full installer: the constructor-installed setter reads the
            // current preference at the call, as the original CFG does.
            [defaults setBool:YES forKey:RUINKeepUnsentMessagesKey];
            NSDictionary *payload = @{@"id":@"9007199254740993", @"from":@"private-sender-sentinel", @"to":@"private-chat-sentinel",
                @"metadata":@{@"UNSENT":@"true", @"SILENTLY_UNSENT":@"false", @"fixture":@"unchanged"}};
            uint_fast64_t settersBefore = atomic_load(&testTransportSetterCalls), readsBefore = atomic_load(&testTransportReadCalls);
            [transport read:payload];
            Check(atomic_load(&testTransportSetterCalls) == settersBefore + 1 && atomic_load(&testTransportReadCalls) == readsBefore + 1,
                @"transport original setter/decoder was skipped or duplicated");
            Check([payload[@"metadata"] objectForKey:@"UNSENT"] != nil && transport.contentMetadata[@"UNSENT"] == nil &&
                [transport.contentMetadata[@"SILENTLY_UNSENT"] isEqual:@"false"] && [transport.contentMetadata[@"fixture"] isEqual:@"unchanged"],
                @"specific UNSENT filter mutated the input or another metadata field");
            Check([RUINUnsendRetentionDiagnostics()[@"markerStore"][@"events"] integerValue] == 1 &&
                ![RUINMessageHistoryDiagnostics()[@"storageReady"] boolValue], @"post-read marker was missing or required history startup");
            NSDictionary *silentMap = @{@"UNSENT":@NO, @"SILENTLY_UNSENT":@"true", @"other":@[@1, @2]};
            [transport setContentMetadata:silentMap];
            Check(transport.contentMetadata[@"UNSENT"] == nil && [transport.contentMetadata[@"SILENTLY_UNSENT"] isEqual:@"true"] &&
                [transport.contentMetadata[@"other"] isEqual:silentMap[@"other"]] && silentMap[@"UNSENT"] != nil,
                @"presence filter altered SILENTLY_UNSENT/other fields or coerced the flag's value");
            [defaults setBool:NO forKey:RUINKeepUnsentMessagesKey];
            [transport setContentMetadata:incoming];
            Check(testTransportArgument == incoming && [transport.contentMetadata isEqual:incoming], @"live disabled preference did not pass the original input");
            [defaults setBool:YES forKey:RUINKeepUnsentMessagesKey];
            [transport read:payload];
            RUINInstallUnsendRetention();
            Check(method_getImplementation(class_getInstanceMethod(RUINFixtureMessageBase.class, @selector(displayedText))) == baseDisplay,
                @"full inherited renderer installation changed the superclass");
            Check([RUINUnsendRetentionDiagnostics()[@"nativeKeysVerified"] boolValue], @"native key ABI/value verification failed");
            coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:TestModel()];
            Check([coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[root URLByAppendingPathComponent:@"source.sqlite"] options:nil error:NULL] != nil,
                @"source fixture store failed");
            context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType]; context.persistentStoreCoordinator = coordinator;
            __block NSManagedObject *chat, *sender;
            __block RUINFixtureMessageBase *message, *silent, *manual, *missing;
            __block NSDictionary *messageKey, *manualKey;
            __block BOOL saved;
            [context performBlockAndWait:^{
                chat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context]; [chat setValue:@"private-chat-sentinel" forKey:@"mid"];
                sender = [NSEntityDescription insertNewObjectForEntityForName:@"Sender" inManagedObjectContext:context]; [sender setValue:@"private-sender-sentinel" forKey:@"mid"];
                message = TestInsert(context, @"ManagedMessage", @"9007199254740993", @"RUIN TEST private-original-sentinel", chat, sender);
                silent = TestInsert(context, @"ManagedSquareMessage", @"9007199254740994", @"RUIN TEST silent original", chat, sender);
                manual = TestInsert(context, @"ManagedMessage", @"9007199254740995", @"RUIN TEST manual original", chat, sender);
                saved = [context save:NULL]; messageKey = RUINHistoryMessageKey(message); manualKey = RUINHistoryMessageKey(manual);
            }];
            Check(saved && messageKey.count == 5 && [messageKey[@"sender"] isEqual:@"private-sender-sentinel"],
                @"normal fixture save/key or author identity failed");
            (void)RUINReadUsersForMessage(message); // Drain the actual history capture queue without marking anything.
            archive = [[RUINHistoryStore alloc] initWithURL:[root URLByAppendingPathComponent:@"RUIN/history.sqlite"] error:NULL];
            Check(archive != nil, @"archive fixture open failed");
            __block NSString *nativeRetained;
            [context performBlockAndWait:^{ nativeRetained = [message displayedText]; }];
            Check([nativeRetained isEqual:@"RUIN TEST private-original-sentinel\n取消済"], @"filtered marker did not label retained native plaintext");
            os_unfair_lock_lock(&markerLock); sqlite3_close_v2(markerDatabase); markerDatabase = NULL; os_unfair_lock_unlock(&markerLock);
            [context performBlockAndWait:^{ nativeRetained = [message displayedText]; }];
            Check([nativeRetained isEqual:@"RUIN TEST private-original-sentinel\n取消済"], @"marker/rebinding did not survive database reopen");
            NSMutableDictionary *conflict = [messageKey mutableCopy]; conflict[@"store"] = @"other-store";
            Check(!MarkerForKey(conflict) && !MarkerForKey(messageKey), @"marker silently attributed across known stores");
            Check(RUINClearUnsendMarkers(), @"marker clear failed");
            [context performBlockAndWait:^{ nativeRetained = [message displayedText]; }];
            Check([nativeRetained isEqual:@"native display"], @"cleared marker still supplied a sidecar label");
            [transport read:payload];

            [defaults setBool:YES forKey:RUINTrackReadUsersKey];
            Check(RUINHistoryRecordType55ReadUpTo(@"private-chat-sentinel", @"private-reader-sentinel", @"9007199254740993"),
                @"raw type-55 fields did not persist");
            Check(RUINHistoryRecordType55ReadUpTo(@"private-chat-sentinel", @"private-reader-sentinel", @"9007199254740993"),
                @"duplicate type-55 observation failed");
            NSArray *readers = RUINReadUsersForMessage(message);
            Check(readers.count == 1 && [readers.firstObject[@"readerID"] isEqual:@"private-reader-sentinel"] &&
                [readers.firstObject[@"readAtMilliseconds"] longLongValue] == 0, @"type-55 field mapping or unknown read time changed");
            unichar invalidID[] = {'1', 0, '2'};
            Check(!RUINHistoryRecordType55ReadUpTo(@"private-chat-sentinel", @"private-reader-sentinel",
                [NSString stringWithCharacters:invalidID length:3]), @"type-55 bridge accepted a truncated ID");
            uint_fast64_t beforeSave = atomic_load(&testDidSaveCalls);
            uint_fast64_t beforeDisplay = atomic_load(&testDisplayCalls);
            __block NSString *rendered, *raw;
            [context performBlockAndWait:^{
                TestMetadata(message, @{@"UNSENT":@"true"}); [message setValue:@"native tombstone" forKey:@"text"];
                [message setValue:@101 forKey:@"contentType"]; [message setValue:@"native type" forKey:@"messageType"];
                saved = [context save:NULL];
                rendered = [message displayedText]; raw = [message plaintext];
            }];
            Check(saved && atomic_load(&testDidSaveCalls) == beforeSave + 1, @"original didSave was omitted or called twice");
            Check(atomic_load(&testDisplayCalls) == beforeDisplay + 1, @"original display getter was omitted or called twice");
            Check([rendered isEqual:@"RUIN TEST private-original-sentinel\n取消済"] && [raw isEqual:@"native tombstone"], @"retained text adapter failed or mutated plaintext");
            NSDictionary *frozen = [archive snapshotInStore:messageKey[@"store"] kind:messageKey[@"kind"] chat:messageKey[@"chat"] message:messageKey[@"message"]];
            Check([frozen[@"body"] isEqual:@"RUIN TEST private-original-sentinel"] && [frozen[@"unsent"] boolValue], @"tombstone capture overwrote the archive before freezing");
            __block BOOL fieldsUnchanged;
            [context performBlockAndWait:^{
                fieldsUnchanged = [[message contentMetadataDictionary][@"UNSENT"] isEqual:@"true"] &&
                    [[message valueForKey:@"contentType"] integerValue] == 101 && [[message valueForKey:@"messageType"] isEqual:@"native type"];
                TestMetadata(silent, @{@"SILENTLY_UNSENT":@"true"}); [silent setValue:@"" forKey:@"text"]; [silent setValue:@101 forKey:@"contentType"];
                saved = [context save:NULL]; rendered = [silent displayedText];
            }];
            Check(fieldsUnchanged, @"native metadata/type was changed");
            Check(saved && [rendered isEqual:@"RUIN TEST silent original\n取消済"], @"remaining silent tombstone was not adapted");
            [context performBlockAndWait:^{
                missing = TestInsert(context, @"ManagedMessage", @"9007199254740996", @"tombstone without original", chat, sender);
                TestMetadata(missing, @{@"UNSENT":@"true"}); // Deliberately type 0: a missing original must still never render as retained.
                saved = [context save:NULL]; rendered = [missing displayedText];
            }];
            Check(saved && [rendered isEqual:@"native display"], @"a first-seen tombstone was mislabeled as retained original");
            NSDictionary *missingKey = RUINHistoryMessageKey(missing);
            NSDictionary *reservation = [archive snapshotInStore:missingKey[@"store"] kind:missingKey[@"kind"] chat:missingKey[@"chat"] message:missingKey[@"message"]];
            Check([reservation[@"body"] length] == 0 && [reservation[@"contentType"] integerValue] == -1 && [reservation[@"unsent"] boolValue], @"missing-original reservation was not frozen");
            [context performBlockAndWait:^{ [context deleteObject:manual]; saved = [context save:NULL]; }];
            Check(saved && ![[archive snapshotInStore:manualKey[@"store"] kind:manualKey[@"kind"] chat:manualKey[@"chat"] message:manualKey[@"message"]][@"unsent"] boolValue],
                @"manual deletion was treated as remote unsend");
            NSString *diagnostics = [RUINUnsendRetentionDiagnostics() description];
            Check([diagnostics rangeOfString:@"private-original-sentinel"].location == NSNotFound &&
                  [diagnostics rangeOfString:@"private-chat-sentinel"].location == NSNotFound &&
                  [diagnostics rangeOfString:@"private-reader-sentinel"].location == NSNotFound &&
                  [diagnostics rangeOfString:@"9007199254740993"].location == NSNotFound, @"diagnostics exposed message text or identifiers");
            NSDictionary *samples = RUINUnsendRetentionDiagnostics()[@"testTransportFlagShapeSamples"];
            [defaults setBool:NO forKey:RUINKeepUnsentMessagesKey]; [defaults setBool:NO forKey:RUINUnsendObservationEnabledDefaultsKey]; RUINInstallUnsendRetention();
            [transport setContentMetadata:incoming];
            [context performBlockAndWait:^{ rendered = [message displayedText]; }];
            Check([rendered isEqual:@"native display"] && [samples isEqual:RUINUnsendRetentionDiagnostics()[@"testTransportFlagShapeSamples"]],
                @"disabled retention/observation changed original behavior or continued sampling");
            testInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"unsupported"};
            [defaults setBool:YES forKey:RUINKeepUnsentMessagesKey]; RUINInstallUnsendRetention();
            [context performBlockAndWait:^{ rendered = [message displayedText]; }];
            Check([rendered isEqual:@"native display"] && ![RUINUnsendRetentionDiagnostics()[@"targetSupported"] boolValue], @"unsupported build did not pass through");
            (void)RUINReadUsersForMessage(message);
        } @catch (NSException *exception) {
            fprintf(stderr, "RUIN unsend check failed: %s\n", exception.reason.UTF8String ?: "unknown error"); result = 1;
        } @finally {
            if (context) [context performBlockAndWait:^{ [context reset]; }];
            for (NSPersistentStore *store in coordinator.persistentStores) [coordinator removePersistentStore:store error:NULL];
            archive = nil;
            if (oldKeep) [defaults setObject:oldKeep forKey:RUINKeepUnsentMessagesKey]; else [defaults removeObjectForKey:RUINKeepUnsentMessagesKey];
            if (oldObserve) [defaults setObject:oldObserve forKey:RUINUnsendObservationEnabledDefaultsKey]; else [defaults removeObjectForKey:RUINUnsendObservationEnabledDefaultsKey];
            if (oldReaders) [defaults setObject:oldReaders forKey:RUINTrackReadUsersKey]; else [defaults removeObjectForKey:RUINTrackReadUsersKey];
            if (oldInfo) method_setImplementation(infoMethod, oldInfo);
            if (originalDirectories) method_setImplementation(directoriesMethod, originalDirectories);
            os_unfair_lock_lock(&markerLock);
            if (markerDatabase) sqlite3_close_v2(markerDatabase);
            markerDatabase = NULL;
            os_unfair_lock_unlock(&markerLock);
            testTransportArgument = nil;
            [NSFileManager.defaultManager removeItemAtURL:root error:NULL];
        }
        if (!result) puts("RUIN Unsend native host checks passed");
        return result;
    }
}
#endif
