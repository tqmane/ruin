%config(generator=internal);

#import "TargetMetadata.h"
#import "MessagingPrivateAPI.h"
#import "MessageHistory.h"
#import "Features.h"
#import "../core/Localization.h"
#import "NativeReadPositions.h"
#import <CoreData/CoreData.h>
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>
#import <stdatomic.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#if TARGET_OS_IPHONE
#import "LocalNotifications.h"
#endif

NSString *const RUINKeepUnsentMessagesKey = @"RUINKeepUnsentMessages";
NSString *const RUINTrackReadUsersKey = @"RUINTrackReadUsers";

static BOOL Text(id value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    return bytes != nil && bytes.length <= INT_MAX;
}
static BOOL Token(id value) {
    if (!Text(value) || ![value length]) return NO;
    for (NSUInteger i = 0; i < [value length]; i++) if ([value characterAtIndex:i] == 0) return NO;
    return YES;
}
// Inspect every UTF-16 code unit: UTF8String/strtoll would truncate at an embedded NUL.
static NSString *MessageNumber(id value, BOOL allowZero, sqlite3_int64 *number) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
    NSString *text = [value copy];
    sqlite3_int64 result = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar digit = [text characterAtIndex:i];
        if (digit < '0' || digit > '9' || result > (LLONG_MAX - (digit - '0')) / 10) return nil;
        result = result * 10 + digit - '0';
    }
    if (!allowZero && result == 0) return nil;
    if (number) *number = result;
    return [NSString stringWithFormat:@"%lld", result];
}
static BOOL IntegerNumber(id value, sqlite3_int64 *number) {
    if (!value) { *number = 0; return YES; }
    if (![value isKindOfClass:NSNumber.class]) return NO;
    const char *type = [value objCType];
    if (!type || !type[0] || type[1]) return NO;
    if (strchr("csilq", type[0])) { *number = [value longLongValue]; return YES; }
    if (strchr("CSILQB", type[0]) && [value unsignedLongLongValue] <= LLONG_MAX) {
        *number = (sqlite3_int64)[value unsignedLongLongValue]; return YES;
    }
    return NO;
}
static NSArray<NSDictionary *> *NormalizedRanges(id ranges) {
    if (![ranges isKindOfClass:NSArray.class] || ![ranges count]) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (id range in ranges) {
        if (![range isKindOfClass:NSDictionary.class]) return nil;
        sqlite3_int64 start, end, startTime, endTime, observed;
        if (!MessageNumber(range[@"start"], YES, &start) || !MessageNumber(range[@"end"], NO, &end) || start >= end ||
            !IntegerNumber(range[@"startTime"], &startTime) || !IntegerNumber(range[@"endTime"], &endTime) ||
            !IntegerNumber(range[@"observedAt"], &observed)) return nil;
        startTime = MAX(0, startTime); endTime = MAX(0, endTime); observed = MAX(0, observed);
        sqlite3_int64 known = endTime > 0 ? endTime : startTime;
        id suppliedSource = range[@"timeSource"];
        if (suppliedSource && ![@[@"server_event", @"range", @"observed", @"unknown"] containsObject:suppliedSource]) return nil;
        NSString *source = known > 0 ? ([suppliedSource isEqual:@"server_event"] ? @"server_event" : @"range") :
            (observed > 0 ? @"observed" : @"unknown");
        [result addObject:@{@"start":@(start), @"end":@(end), @"startTime":@(startTime), @"endTime":@(endTime),
            @"readAt":@(known), @"observedAt":@(observed), @"timeSource":source}];
    }
    return [result copy];
}
static int BindText(sqlite3_stmt *statement, int index, NSString *value) {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return SQLITE_MISMATCH;
    if (data.length > INT_MAX) return SQLITE_TOOBIG;
    return sqlite3_bind_text(statement, index, data.bytes ?: "", (int)data.length, SQLITE_TRANSIENT);
}
static int BindStrings(sqlite3_stmt *statement, NSArray<NSString *> *values) {
    for (NSUInteger i = 0; i < values.count; i++) {
        int status = BindText(statement, (int)i + 1, values[i]);
        if (status != SQLITE_OK) return status;
    }
    return SQLITE_OK;
}
static NSString *ColumnText(sqlite3_stmt *statement, int index) {
    const void *bytes = sqlite3_column_text(statement, index);
    return bytes ? [[NSString alloc] initWithBytes:bytes length:sqlite3_column_bytes(statement, index)
        encoding:NSUTF8StringEncoding] ?: @"" : @"";
}
static int ExecuteText(sqlite3 *db, const char *sql, NSArray<NSString *> *values) {
    sqlite3_stmt *statement = NULL;
    int status = sqlite3_prepare_v2(db, sql, -1, &statement, NULL);
    if (status == SQLITE_OK) status = BindStrings(statement, values);
    if (status == SQLITE_OK) status = sqlite3_step(statement);
    sqlite3_finalize(statement);
    return status;
}
static int FinishTransaction(sqlite3 *db, int status) {
    if (status == SQLITE_DONE) status = sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);
    if (status == SQLITE_OK) return SQLITE_DONE;
    sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL); // Also rolls back after a failed COMMIT.
    return status;
}
static int AddTimeColumn(sqlite3 *db, const char *table, const char *column, const char *definition) {
    char sql[256]; snprintf(sql, sizeof(sql), "PRAGMA table_info(%s)", table);
    sqlite3_stmt *statement = NULL; BOOL found = NO;
    int status = sqlite3_prepare_v2(db, sql, -1, &statement, NULL);
    if (status == SQLITE_OK) while ((status = sqlite3_step(statement)) == SQLITE_ROW)
        if ([ColumnText(statement, 1) isEqualToString:@(column)]) found = YES;
    sqlite3_finalize(statement);
    if (status != SQLITE_DONE) return status;
    if (found) return SQLITE_OK;
    snprintf(sql, sizeof(sql), "ALTER TABLE %s ADD COLUMN %s %s", table, column, definition);
    return sqlite3_exec(db, sql, NULL, NULL, NULL);
}
static int InitializeSchema(sqlite3 *db) {
    int status = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", NULL, NULL, NULL);
    if (status != SQLITE_OK) return status;
    sqlite3_stmt *columns = NULL;
    status = sqlite3_prepare_v2(db, "PRAGMA table_info(read_ranges)", -1, &columns, NULL);
    BOOL exists = NO, hasKind = NO;
    if (status == SQLITE_OK) {
        while ((status = sqlite3_step(columns)) == SQLITE_ROW) {
            exists = YES;
            if ([ColumnText(columns, 1) isEqualToString:@"kind"]) hasKind = YES;
        }
    }
    sqlite3_finalize(columns);
    if (status != SQLITE_DONE) return status;
    status = sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL);
    if (status != SQLITE_OK) return status;
    BOOL legacy = exists && !hasKind;
    if (legacy) status = sqlite3_exec(db, "ALTER TABLE read_ranges RENAME TO read_ranges_legacy;", NULL, NULL, NULL);
    if (status == SQLITE_OK) status = sqlite3_exec(db,
        "CREATE TABLE IF NOT EXISTS snapshots("
        "store TEXT NOT NULL,kind TEXT NOT NULL,chat TEXT NOT NULL,message TEXT NOT NULL,"
        "body TEXT NOT NULL,sender TEXT NOT NULL,ts INTEGER NOT NULL,content_type INTEGER NOT NULL,"
        "unsent INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(store,kind,chat,message));"
        "CREATE TABLE IF NOT EXISTS read_ranges("
        "store TEXT NOT NULL,kind TEXT NOT NULL,chat TEXT NOT NULL,reader TEXT NOT NULL,start_id INTEGER NOT NULL,"
        "end_id INTEGER NOT NULL,start_ms INTEGER NOT NULL,end_ms INTEGER NOT NULL,"
        "PRIMARY KEY(store,kind,chat,reader,start_id,end_id));"
        "CREATE TABLE IF NOT EXISTS observed_ranges("
        "kind TEXT NOT NULL,chat TEXT NOT NULL,reader TEXT NOT NULL,start_id INTEGER NOT NULL,"
        "end_id INTEGER NOT NULL,start_ms INTEGER NOT NULL,end_ms INTEGER NOT NULL,"
        "PRIMARY KEY(kind,chat,reader,start_id,end_id));"
        "CREATE TABLE IF NOT EXISTS chat_stores("
        "kind TEXT NOT NULL,chat TEXT NOT NULL,store TEXT NOT NULL,PRIMARY KEY(kind,chat,store));", NULL, NULL, NULL);
    // The previous observer and legacy APIs recorded talk ranges only.
    if (status == SQLITE_OK && legacy) status = sqlite3_exec(db,
        "INSERT INTO read_ranges(store,kind,chat,reader,start_id,end_id,start_ms,end_ms) SELECT store,'talk',chat,reader,start_id,end_id,start_ms,end_ms FROM read_ranges_legacy;"
        "DROP TABLE read_ranges_legacy;", NULL, NULL, NULL);
    for (NSString *table in @[@"read_ranges", @"observed_ranges"]) {
        if (status == SQLITE_OK) status = AddTimeColumn(db, table.UTF8String, "read_at_ms", "INTEGER NOT NULL DEFAULT 0");
        if (status == SQLITE_OK) status = AddTimeColumn(db, table.UTF8String, "observed_ms", "INTEGER NOT NULL DEFAULT 0");
        if (status == SQLITE_OK) status = AddTimeColumn(db, table.UTF8String, "time_source", "TEXT NOT NULL DEFAULT 'legacy'");
        if (status != SQLITE_OK) break;
        NSString *migration = [NSString stringWithFormat:
            @"UPDATE %@ SET read_at_ms=CASE WHEN end_ms>0 THEN end_ms WHEN start_ms>0 THEN start_ms ELSE 0 END WHERE time_source='legacy' AND read_at_ms=0;", table];
        status = sqlite3_exec(db, migration.UTF8String, NULL, NULL, NULL);
        for (NSString *column in @[@"read_at_ms", @"observed_ms"]) {
            if (status != SQLITE_OK) break;
            NSString *trigger = [NSString stringWithFormat:
                @"CREATE TRIGGER IF NOT EXISTS ruin_first_%@_%@ BEFORE UPDATE OF %@ ON %@ "
                 "WHEN OLD.%@>0 AND (NEW.%@<=0 OR NEW.%@>OLD.%@) BEGIN SELECT RAISE(IGNORE); END;",
                table, column, column, table, column, column, column, column];
            status = sqlite3_exec(db, trigger.UTF8String, NULL, NULL, NULL);
        }
    }
    status = FinishTransaction(db, status == SQLITE_OK ? SQLITE_DONE : status);
    return status == SQLITE_DONE ? SQLITE_OK : status;
}

@implementation RUINHistoryStore {
    sqlite3 *_database;
    int _lastError;
}
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    if (!(self = [super init])) return nil;
    if (error) *error = nil;
    if (!url.isFileURL) {
        if (error) *error = [NSError errorWithDomain:@"RUINHistorySQLite" code:SQLITE_MISUSE userInfo:nil];
        return nil;
    }
    if (![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    int status = sqlite3_open_v2(url.fileSystemRepresentation, &_database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL);
    if (status == SQLITE_OK) {
        sqlite3_busy_timeout(_database, 1500);
        status = InitializeSchema(_database);
    }
    if (status != SQLITE_OK) {
        if (error) *error = [NSError errorWithDomain:@"RUINHistorySQLite" code:status userInfo:nil];
        return nil;
    }
#if TARGET_OS_IPHONE
    [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}
                                  ofItemAtPath:url.URLByDeletingLastPathComponent.path error:NULL];
#endif
    return self;
}
- (void)dealloc { if (_database) sqlite3_close_v2(_database); }
- (BOOL)saveSnapshot:(NSDictionary *)snapshot {
    if (![snapshot isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[@"store", @"kind", @"chat"]) if (!Token(snapshot[key])) return NO;
    NSString *message = MessageNumber(snapshot[@"message"], NO, NULL);
    if (!message || !Text(snapshot[@"body"]) || (snapshot[@"sender"] &&
        (!Text(snapshot[@"sender"]) || ([snapshot[@"sender"] length] && !Token(snapshot[@"sender"]))))) return NO;
    sqlite3_int64 timestamp, contentType;
    if (!IntegerNumber(snapshot[@"timestamp"], &timestamp) || !IntegerNumber(snapshot[@"contentType"], &contentType)) return NO;
    NSArray *values = @[[snapshot[@"store"] copy], [snapshot[@"kind"] copy], [snapshot[@"chat"] copy],
        message, [snapshot[@"body"] copy], [snapshot[@"sender"] copy] ?: @""];
    @synchronized (self) {
        sqlite3_stmt *statement = NULL;
        _lastError = sqlite3_prepare_v2(_database,
            "INSERT INTO snapshots(store,kind,chat,message,body,sender,ts,content_type) VALUES(?,?,?,?,?,?,?,?) "
            "ON CONFLICT(store,kind,chat,message) DO UPDATE SET body=excluded.body,sender=excluded.sender,"
            "ts=excluded.ts,content_type=excluded.content_type WHERE snapshots.unsent=0;", -1, &statement, NULL);
        if (_lastError == SQLITE_OK) _lastError = BindStrings(statement, values);
        if (_lastError == SQLITE_OK) _lastError = sqlite3_bind_int64(statement, 7, timestamp);
        if (_lastError == SQLITE_OK) _lastError = sqlite3_bind_int64(statement, 8, contentType);
        if (_lastError == SQLITE_OK) _lastError = sqlite3_step(statement);
        sqlite3_finalize(statement);
        return _lastError == SQLITE_DONE;
    }
}
- (BOOL)markUnsentInStore:(NSString *)store kind:(NSString *)kind chat:(NSString *)chat message:(NSString *)message {
    NSString *canonical = MessageNumber(message, NO, NULL);
    if (!Token(store) || !Token(kind) || !Token(chat) || !canonical) return NO;
    @synchronized (self) {
        _lastError = ExecuteText(_database, "UPDATE snapshots SET unsent=1 WHERE store=? AND kind=? AND chat=? AND message=?;",
            @[store, kind, chat, canonical]);
        return _lastError == SQLITE_DONE && sqlite3_changes(_database) > 0;
    }
}
- (NSDictionary *)snapshotInStore:(NSString *)store kind:(NSString *)kind chat:(NSString *)chat message:(NSString *)message {
    NSString *canonical = MessageNumber(message, NO, NULL);
    if (!Token(store) || !Token(kind) || !Token(chat) || !canonical) return nil;
    @synchronized (self) {
        sqlite3_stmt *statement = NULL;
        _lastError = sqlite3_prepare_v2(_database,
            "SELECT body,sender,ts,content_type,unsent FROM snapshots WHERE store=? AND kind=? AND chat=? AND message=?;", -1, &statement, NULL);
        if (_lastError == SQLITE_OK) _lastError = BindStrings(statement, @[store, kind, chat, canonical]);
        if (_lastError == SQLITE_OK) _lastError = sqlite3_step(statement);
        NSDictionary *result = nil;
        if (_lastError == SQLITE_ROW) result = @{
            @"body":ColumnText(statement, 0), @"sender":ColumnText(statement, 1),
            @"timestamp":@(sqlite3_column_int64(statement, 2)), @"contentType":@(sqlite3_column_int64(statement, 3)),
            @"unsent":@(sqlite3_column_int(statement, 4) != 0)};
        sqlite3_finalize(statement);
        return result;
    }
}
- (BOOL)writeRangesByReader:(NSDictionary *)readers store:(NSString *)store kind:(NSString *)kind chat:(NSString *)chat {
    if (!Token(kind) || !Token(chat) || (store && !Token(store)) ||
        ![readers isKindOfClass:NSDictionary.class] || !readers.count) return NO;
    NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
    for (id reader in readers) {
        NSArray *ranges = NormalizedRanges(readers[reader]);
        if (!Token(reader) || !ranges) return NO;
        normalized[[reader copy]] = ranges;
    }
    @synchronized (self) {
        _lastError = sqlite3_exec(_database, "BEGIN IMMEDIATE", NULL, NULL, NULL);
        if (_lastError != SQLITE_OK) return NO;
        sqlite3_stmt *statement = NULL;
        const char *sql = store ?
            "INSERT INTO read_ranges(store,kind,chat,reader,start_id,end_id,start_ms,end_ms,read_at_ms,observed_ms,time_source) VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(store,kind,chat,reader,start_id,end_id) "
            "DO UPDATE SET " :
            "INSERT INTO observed_ranges(kind,chat,reader,start_id,end_id,start_ms,end_ms,read_at_ms,observed_ms,time_source) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(kind,chat,reader,start_id,end_id) "
            "DO UPDATE SET ";
        NSString *upsert = [@(sql) stringByAppendingString:
            @"start_ms=CASE WHEN start_ms=0 THEN excluded.start_ms WHEN excluded.start_ms=0 THEN start_ms ELSE MIN(start_ms,excluded.start_ms) END,"
             "end_ms=CASE WHEN end_ms=0 THEN excluded.end_ms WHEN excluded.end_ms=0 THEN end_ms ELSE MIN(end_ms,excluded.end_ms) END,"
             "time_source=CASE WHEN excluded.read_at_ms>0 AND (read_at_ms=0 OR excluded.read_at_ms<read_at_ms) THEN excluded.time_source "
             "WHEN excluded.read_at_ms>0 AND excluded.read_at_ms=read_at_ms AND excluded.time_source='server_event' THEN 'server_event' "
             "WHEN read_at_ms=0 AND observed_ms=0 AND excluded.observed_ms>0 THEN 'observed' ELSE time_source END,"
             "read_at_ms=CASE WHEN read_at_ms=0 THEN excluded.read_at_ms WHEN excluded.read_at_ms=0 THEN read_at_ms ELSE MIN(read_at_ms,excluded.read_at_ms) END,"
             "observed_ms=CASE WHEN observed_ms=0 THEN excluded.observed_ms WHEN excluded.observed_ms=0 THEN observed_ms ELSE MIN(observed_ms,excluded.observed_ms) END;"];
        _lastError = sqlite3_prepare_v2(_database, upsert.UTF8String, -1, &statement, NULL);
        for (NSString *reader in normalized) {
            for (NSDictionary *range in normalized[reader]) {
                if (_lastError != SQLITE_OK && _lastError != SQLITE_DONE) break;
                _lastError = sqlite3_reset(statement);
                if (_lastError == SQLITE_OK) _lastError = sqlite3_clear_bindings(statement);
                NSArray *strings = store ? @[store, kind, chat, reader] : @[kind, chat, reader];
                if (_lastError == SQLITE_OK) _lastError = BindStrings(statement, strings);
                NSArray *keys = @[@"start", @"end", @"startTime", @"endTime", @"readAt", @"observedAt"];
                for (NSUInteger i = 0; i < keys.count && _lastError == SQLITE_OK; i++)
                    _lastError = sqlite3_bind_int64(statement, (int)(strings.count + i + 1), [range[keys[i]] longLongValue]);
                if (_lastError == SQLITE_OK) _lastError = BindText(statement, (int)(strings.count + keys.count + 1), range[@"timeSource"]);
                if (_lastError == SQLITE_OK) _lastError = sqlite3_step(statement);
            }
            if (_lastError != SQLITE_DONE) break;
        }
        sqlite3_finalize(statement);
        _lastError = FinishTransaction(_database, _lastError);
        return _lastError == SQLITE_DONE;
    }
}
- (BOOL)recordRanges:(NSArray<NSDictionary *> *)ranges inStore:(NSString *)store kind:(NSString *)kind chat:(NSString *)chat reader:(NSString *)reader {
    if (!Token(store) || !Token(reader)) return NO;
    return [self writeRangesByReader:@{reader:ranges ?: @[]} store:store kind:kind chat:chat];
}
- (BOOL)recordRanges:(NSArray<NSDictionary *> *)ranges inStore:(NSString *)store chat:(NSString *)chat reader:(NSString *)reader {
    return [self recordRanges:ranges inStore:store kind:@"talk" chat:chat reader:reader];
}
- (BOOL)recordObservedRangesByReader:(NSDictionary<NSString *,NSArray<NSDictionary *> *> *)ranges kind:(NSString *)kind chat:(NSString *)chat {
    return [self writeRangesByReader:ranges store:nil kind:kind chat:chat];
}
- (BOOL)bindStore:(NSString *)store kind:(NSString *)kind chat:(NSString *)chat {
    if (!Token(store) || !Token(kind) || !Token(chat)) return NO;
    @synchronized (self) {
        _lastError = ExecuteText(_database, "INSERT OR IGNORE INTO chat_stores(kind,chat,store) VALUES(?,?,?);", @[kind, chat, store]);
        return _lastError == SQLITE_DONE;
    }
}
- (NSArray<NSDictionary *> *)readersInStore:(NSString *)store kind:(NSString *)kind chat:(NSString *)chat message:(NSString *)message {
    sqlite3_int64 number;
    if (!Token(store) || !Token(kind) || !Token(chat) || !MessageNumber(message, NO, &number)) return @[];
    @synchronized (self) {
        sqlite3_stmt *statement = NULL;
        _lastError = sqlite3_prepare_v2(_database,
            "WITH candidates AS ("
            "SELECT reader,start_id,end_id,read_at_ms,observed_ms,time_source FROM read_ranges WHERE store=?1 AND kind=?2 AND chat=?3 "
            "UNION ALL SELECT reader,start_id,end_id,read_at_ms,observed_ms,time_source FROM observed_ranges o WHERE kind=?2 AND chat=?3 "
            "AND (SELECT COUNT(*) FROM chat_stores b WHERE b.kind=o.kind AND b.chat=o.chat)=1 "
            "AND EXISTS(SELECT 1 FROM chat_stores b WHERE b.kind=o.kind AND b.chat=o.chat AND b.store=?1)) "
            ", spans AS (SELECT reader,MIN(start_id) AS floor_id,MAX(end_id) AS ceiling_id FROM candidates GROUP BY reader), "
            "members AS (SELECT reader FROM spans WHERE floor_id<?4 AND ceiling_id>=?4), "
            "relevant AS (SELECT * FROM candidates WHERE start_id<?4 AND end_id>=?4), "
            "first_times AS (SELECT reader,MIN(CASE WHEN read_at_ms>0 AND (time_source!='server_event' OR end_id=?4) THEN read_at_ms END) AS known_ms,"
            "MIN(NULLIF(observed_ms,0)) AS seen_ms FROM relevant GROUP BY reader), "
            "chosen AS (SELECT m.reader,CASE WHEN f.known_ms>0 AND (f.seen_ms IS NULL OR f.known_ms<=f.seen_ms) THEN f.known_ms END AS read_ms,f.seen_ms "
            "FROM members m LEFT JOIN first_times f ON f.reader=m.reader) "
            "SELECT f.reader,COALESCE(f.read_ms,0),COALESCE(f.seen_ms,0),"
            "COALESCE((SELECT CASE WHEN r.time_source='server_event' THEN 'server_event' ELSE 'range' END FROM relevant r "
            "WHERE r.reader=f.reader AND r.read_at_ms=f.read_ms AND (r.time_source!='server_event' OR r.end_id=?4) "
            "ORDER BY CASE WHEN r.time_source='server_event' THEN 0 ELSE 1 END LIMIT 1),"
            "CASE WHEN f.seen_ms>0 THEN 'observed' ELSE 'unknown' END) "
            "FROM chosen f ORDER BY CASE WHEN COALESCE(f.read_ms,f.seen_ms,0)>0 THEN 0 ELSE 1 END,COALESCE(f.read_ms,f.seen_ms),f.reader;", -1, &statement, NULL);
        if (_lastError == SQLITE_OK) _lastError = BindStrings(statement, @[store, kind, chat]);
        if (_lastError == SQLITE_OK) _lastError = sqlite3_bind_int64(statement, 4, number);
        NSMutableArray *result = [NSMutableArray array];
        if (_lastError == SQLITE_OK) {
            while ((_lastError = sqlite3_step(statement)) == SQLITE_ROW)
                [result addObject:@{@"readerID":ColumnText(statement, 0), @"readAtMilliseconds":@(sqlite3_column_int64(statement, 1)),
                    @"observedAtMilliseconds":@(sqlite3_column_int64(statement, 2)), @"timeSource":ColumnText(statement, 3)}];
        }
        sqlite3_finalize(statement);
        return _lastError == SQLITE_DONE ? [result copy] : @[];
    }
}
- (NSArray<NSDictionary *> *)readersInStore:(NSString *)store chat:(NSString *)chat message:(NSString *)message {
    return [self readersInStore:store kind:@"talk" chat:chat message:message];
}
- (BOOL)removeAll {
    @synchronized (self) {
        _lastError = sqlite3_exec(_database, "BEGIN IMMEDIATE", NULL, NULL, NULL);
        if (_lastError != SQLITE_OK) return NO;
        _lastError = sqlite3_exec(_database, "DELETE FROM snapshots;DELETE FROM read_ranges;DELETE FROM observed_ranges;DELETE FROM chat_stores;", NULL, NULL, NULL);
        _lastError = FinishTransaction(_database, _lastError == SQLITE_OK ? SQLITE_DONE : _lastError);
        return _lastError == SQLITE_DONE;
    }
}
- (NSDictionary *)ruinRetainUnsentKey:(NSDictionary *)key {
    @synchronized (self) {
        // One statement freezes an existing original or inserts a frozen,
        // non-renderable reservation. There is no editable intermediate row.
        _lastError = ExecuteText(_database,
            "INSERT INTO snapshots(store,kind,chat,message,body,sender,ts,content_type,unsent) "
            "VALUES(?,?,?,?,'','',0,-1,1) ON CONFLICT(store,kind,chat,message) DO UPDATE SET unsent=1;",
            @[key[@"store"], key[@"kind"], key[@"chat"], key[@"message"]]);
        if (_lastError != SQLITE_DONE) return @{};
        return [self snapshotInStore:key[@"store"] kind:key[@"kind"] chat:key[@"chat"] message:key[@"message"]] ?: @{};
    }
}
- (NSDictionary *)counts {
    @synchronized (self) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        NSDictionary *queries = @{
            @"snapshots":@"SELECT COUNT(*) FROM snapshots", @"read_ranges":@"SELECT COUNT(*) FROM read_ranges",
            @"observed_ranges":@"SELECT COUNT(*) FROM observed_ranges", @"chat_store_bindings":@"SELECT COUNT(*) FROM chat_stores",
            @"pendingReadRanges":@"SELECT COUNT(*) FROM observed_ranges o WHERE (SELECT COUNT(*) FROM chat_stores b WHERE b.kind=o.kind AND b.chat=o.chat)=0",
            @"ambiguousReadRanges":@"SELECT COUNT(*) FROM observed_ranges o WHERE (SELECT COUNT(*) FROM chat_stores b WHERE b.kind=o.kind AND b.chat=o.chat)>1"
        };
        for (NSString *key in queries) {
            sqlite3_stmt *statement = NULL;
            if (sqlite3_prepare_v2(_database, [queries[key] UTF8String], -1, &statement, NULL) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW)
                result[key] = @(sqlite3_column_int64(statement, 0));
            sqlite3_finalize(statement);
        }
        result[@"lastSQLiteStatus"] = @(_lastError);
        return [result copy];
    }
}
@end

static RUINHistoryStore *historyStore;
static dispatch_queue_t historyQueue;
static char historyQueueKey;
static NSMutableDictionary *historyHooks;
static atomic_bool retainEnabled = ATOMIC_VAR_INIT(false), readersEnabled = ATOMIC_VAR_INIT(false);
static atomic_ulong capturedSnapshots, observedRanges, rejectedReadEvents, archiveWriteFailures;
static atomic_ulong observedType55Events;
static atomic_ulong nativePositionSnapshots, nativePositionRows, nativePositionRejected;
#if defined(RUIN_MESSAGE_HISTORY_HOST_CHECK)
static NSString *hostProfileMID;
void RUINHistoryHostCheckSetProfileMID(NSString *mid) { hostProfileMID = [mid copy]; }
#endif

// All managed-object reads below are performed on their context's queue.
static id ManagedValue(NSManagedObject *object, NSString *key) {
    return object.entity.propertiesByName[key] ? [object valueForKey:key] : nil;
}
static id ObjectGetter(id object, const char *name) {
    Method method = object ? class_getInstanceMethod(object_getClass(object), sel_registerName(name)) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, "@16@0:8")) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
}
static BOOL BooleanGetter(id object, const char *name, BOOL *value) {
    Method method = object ? class_getInstanceMethod(object_getClass(object), sel_registerName(name)) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || (strcmp(encoding, "B16@0:8") && strcmp(encoding, "c16@0:8"))) return NO;
    *value = ((BOOL (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
    return YES;
}
static NSString *StoreNamespace(NSManagedObject *object) {
    if (object.objectID.isTemporaryID) return nil;
    NSPersistentStore *store = object.objectID.persistentStore;
    if (!store) return nil;
    NSString *uuid = store.metadata[NSStoreUUIDKey];
    NSString *source = Token(uuid) ? uuid : store.identifier;
    NSString *path = store.URL.path ?: @"";
    NSString *home = NSHomeDirectory();
    if ([path hasPrefix:[home stringByAppendingString:@"/"]]) path = [path substringFromIndex:home.length];
    NSString *tag = @"uuid";
    if (!Token(source)) {
        source = path;
        if (!Token(source)) return nil;
        tag = @"path-fallback";
    }
    // Include location too: cloned files can carry the same store UUID and later diverge.
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:@[tag, store.type ?: @"", source, path] options:0 error:NULL];
    if (!bytes || bytes.length > UINT_MAX) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, hash);
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(hash); i++) [result appendFormat:@"%02x", hash[i]];
    return result;
}

static BOOL NativeUserMID(NSString *mid) {
    if (![mid isKindOfClass:NSString.class] || mid.length != 33 || ![mid hasPrefix:@"u"]) return NO;
    for (NSUInteger i = 1; i < mid.length; i++) {
        unichar c = [mid characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return NO;
    }
    return YES;
}

static NSString *NativeProfileMID(void) {
#if defined(RUIN_MESSAGE_HISTORY_HOST_CHECK)
    return hostProfileMID;
#else
    // Public native profile value in the current signed app-group domain.
    NSUserDefaults *profile = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.linecorp.line"];
    id mid = [profile objectForKey:@"mid"];
    return NativeUserMID(mid) ? [mid copy] : nil;
#endif
}

static NSString *NativeAccountMIDForStore(NSPersistentStore *store) {
    if (!store.URL.isFileURL || ![store.URL.lastPathComponent isEqual:@"Line.sqlite"]) return nil;
    NSArray *parts = store.URL.path.pathComponents;
    NSString *result = nil;
    for (NSUInteger i = 0; i + 2 < parts.count; i++) {
        if (![parts[i] isEqual:@"PrivateStore"] || ![parts[i + 2] isEqual:@"Messages"]) continue;
        NSString *account = parts[i + 1];
        if (!([account hasPrefix:@"P_"] || [account hasPrefix:@"S_"]) ||
            !NativeUserMID([account substringFromIndex:2]) || result) return nil;
        result = [account substringFromIndex:2];
    }
    return result;
}
BOOL RUINHistoryValidateReadChatKey(NSDictionary *key, id value) {
    if (![key isKindOfClass:NSDictionary.class] || ![key[@"kind"] isEqual:@"talk"] ||
        !Token(key[@"store"]) || !Token(key[@"chat"]) || ![value isKindOfClass:NSManagedObject.class]) return NO;
    NSManagedObject *chat = value;
    NSManagedObjectContext *context = chat.managedObjectContext;
    if (!context) return NO;
    __block BOOL valid = NO;
    [context performBlockAndWait:^{ @try {
        Class cls = objc_getClass("ManagedChat");
        valid = cls && [chat isKindOfClass:cls] && !chat.isDeleted && !chat.objectID.isTemporaryID &&
            [chat.entity.name isEqual:@"Chat"] &&
            [NativeAccountMIDForStore(chat.objectID.persistentStore) isEqual:NativeProfileMID()] &&
            [StoreNamespace(chat) isEqual:key[@"store"]] && [ManagedValue(chat,@"mid") isEqual:key[@"chat"]];
    } @catch (__unused NSException *exception) { valid = NO; } }];
    return valid;
}

void RUINHistoryRecordServerReadRanges(NSDictionary *key, NSDictionary *readers, void (^completion)(BOOL)) {
    void (^finish)(BOOL) = ^(BOOL success) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(success); });
    };
    if (![key isKindOfClass:NSDictionary.class] || ![key[@"kind"] isEqual:@"talk"] ||
        !Token(key[@"store"]) || !Token(key[@"chat"]) || ![readers isKindOfClass:NSDictionary.class]) { finish(NO); return; }
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    long long observed = (long long)(NSDate.date.timeIntervalSince1970 * 1000.0);
    for (id reader in readers) {
        if (!NativeUserMID(reader) || ![readers[reader] isKindOfClass:NSArray.class]) { finish(NO); return; }
        NSMutableArray *ranges = [NSMutableArray array];
        for (id range in readers[reader]) {
            if (![range isKindOfClass:NSDictionary.class]) { finish(NO); return; }
            NSMutableDictionary *copy = [range mutableCopy];
            copy[@"observedAt"] = @(observed); copy[@"timeSource"] = @"range";
            [ranges addObject:[copy copy]];
        }
        snapshot[[reader copy]] = [ranges copy];
    }
    NSDictionary *scope = [key copy], *copied = [snapshot copy];
    RUINHistoryStore *store; dispatch_queue_t queue;
    @synchronized (RUINHistoryStore.class) { store = historyStore; queue = historyQueue; }
    if (!store || !queue) { finish(NO); return; }
    dispatch_async(queue, ^{
        if (!atomic_load(&readersEnabled)) { finish(NO); return; }
        BOOL success = !copied.count || [store writeRangesByReader:copied store:scope[@"store"] kind:@"talk" chat:scope[@"chat"]];
        if (!success) atomic_fetch_add(&archiveWriteFailures,1);
        finish(success);
    });
}
static NSString *MessageAuthorMIDOnContextQueue(NSManagedObject *message) {
    id sender = ObjectGetter(message, "senderObject") ?: ManagedValue(message, @"sender");
    if (sender) {
        if (![sender isKindOfClass:NSManagedObject.class]) return nil;
        id mid = ManagedValue(sender, @"mid");
        return Token(mid) ? [mid copy] : nil;
    }
    BOOL isSendMessage = NO, isReceivedMessage = NO;
    if (!BooleanGetter(message, "isSendMessage", &isSendMessage) ||
        !BooleanGetter(message, "isReceivedMessage", &isReceivedMessage) ||
        isSendMessage == isReceivedMessage || !isSendMessage) return nil;
    NSString *accountMID = NativeAccountMIDForStore(message.objectID.persistentStore);
    return [accountMID isEqual:NativeProfileMID()] ? accountMID : nil;
}

void RUINObserveNativeReadPositionsForMessageKey(NSDictionary *key, id value) {
    if (!atomic_load(&readersEnabled) || ![key isKindOfClass:NSDictionary.class] ||
        ![key[@"kind"] isEqual:@"talk"] || !Token(key[@"store"]) || !Token(key[@"chat"]) ||
        !MessageNumber(key[@"message"], NO, NULL) || ![value isKindOfClass:NSManagedObject.class]) return;
    NSManagedObject *chat = value;
    NSManagedObjectContext *context = chat.managedObjectContext;
    if (!context) return;
    NSDictionary *copiedKey = [key copy];
    [context performBlockAndWait:^{ @try {
        Class cls = objc_getClass("ManagedChat");
        NSPersistentStore *nativeStore = chat.objectID.persistentStore;
        NSString *ownMID = NativeAccountMIDForStore(nativeStore), *profileMID = NativeProfileMID();
        if (!cls || ![chat isKindOfClass:cls] || chat.isDeleted || chat.objectID.isTemporaryID ||
            ![chat.entity.name isEqual:@"Chat"] || ![ownMID isEqual:profileMID] ||
            ![StoreNamespace(chat) isEqual:copiedKey[@"store"]] ||
            ![ManagedValue(chat, @"mid") isEqual:copiedKey[@"chat"]]) {
            atomic_fetch_add(&nativePositionRejected, 1); return;
        }
        long long observed = (long long)(NSDate.date.timeIntervalSince1970 * 1000.0);
        NSMutableDictionary<NSString *, NSMutableArray *> *positions = [NSMutableDictionary dictionary];
        NSManagedObject *metadata = ManagedValue(chat, @"metadata");
        NSMutableSet *visited = [NSMutableSet set];
        Class metadataClass = objc_getClass("ManagedChatMetadata");
        for (NSUInteger depth = 0; metadata && depth < 32; depth++) {
            if (!metadataClass || ![metadata isKindOfClass:metadataClass] || metadata.isDeleted ||
                metadata.managedObjectContext != context || metadata.objectID.persistentStore != nativeStore ||
                metadata.objectID.isTemporaryID || ![metadata.entity.name isEqual:@"ChatMetadata"] ||
                [visited containsObject:metadata.objectID]) break;
            [visited addObject:metadata.objectID];
            id metadataChat = ManagedValue(metadata, @"chat");
            if (metadataChat && (![metadataChat isKindOfClass:NSManagedObject.class] ||
                ![[metadataChat objectID] isEqual:chat.objectID])) break;
            NSDictionary *attributes = metadata.entity.attributesByName;
            if ([attributes[@"memberData"] attributeType] != NSBinaryDataAttributeType ||
                [attributes[@"lastReadIDData"] attributeType] != NSBinaryDataAttributeType ||
                [attributes[@"memberEntryData"] attributeType] != NSBinaryDataAttributeType) break;
            NSDictionary *ranges = RUINNativeReadPositions(ManagedValue(metadata, @"memberData"),
                ManagedValue(metadata, @"lastReadIDData"), ManagedValue(metadata, @"memberEntryData"), observed);
            for (NSString *reader in ranges) {
                if (!positions[reader]) positions[reader] = [NSMutableArray array];
                [positions[reader] addObjectsFromArray:ranges[reader]];
            }
            metadata = ManagedValue(metadata, @"formerMemberMetadata");
        }
        // The account's own position is stored on Chat, separately from the
        // packed member array. Use its committed synced cursor, not the local
        // optimistic read position and not RUIN's masked send-boundary getter.
        if ([chat.entity.attributesByName[@"readUpToMessageIDSynced"] attributeType] == NSInteger64AttributeType) {
            id number = [chat committedValuesForKeys:@[@"readUpToMessageIDSynced"]][@"readUpToMessageIDSynced"];
            sqlite3_int64 end = 0;
            if ([number isKindOfClass:NSNumber.class] && IntegerNumber(number, &end) && end > 0) {
                if (!positions[ownMID]) positions[ownMID] = [NSMutableArray array];
                [positions[ownMID] addObject:@{@"start":@"0", @"end":[NSString stringWithFormat:@"%lld", end],
                    @"startTime":@0, @"endTime":@0, @"observedAt":@(observed), @"timeSource":@"observed"}];
            }
        }
        if (!positions.count) return;
        NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
        for (NSString *reader in positions) snapshot[reader] = [positions[reader] copy];
        RUINHistoryStore *store; dispatch_queue_t queue;
        @synchronized (RUINHistoryStore.class) { store = historyStore; queue = historyQueue; }
        if (!store || !queue) return;
        dispatch_async(queue, ^{
            if (!atomic_load(&readersEnabled)) return;
            if ([store writeRangesByReader:snapshot store:copiedKey[@"store"] kind:@"talk" chat:copiedKey[@"chat"]]) {
                atomic_fetch_add(&nativePositionSnapshots, 1);
                atomic_fetch_add(&nativePositionRows, snapshot.count);
            } else atomic_fetch_add(&archiveWriteFailures, 1);
        });
    } @catch (__unused NSException *exception) { atomic_fetch_add(&nativePositionRejected, 1); } }];
}
static NSDictionary *MessageKeyOnContextQueue(NSManagedObject *message) {
    if (message.isDeleted) return @{};
    Class talkClass = objc_getClass("ManagedMessage"), squareClass = objc_getClass("ManagedSquareMessage");
    NSString *kind = squareClass && [message isKindOfClass:squareClass] ? @"square" :
        (talkClass && [message isKindOfClass:talkClass] ? @"talk" : nil);
    if (!kind) return @{};
    id chat = ObjectGetter(message, "chatObject") ?: ManagedValue(message, @"chat");
    NSString *chatID = [chat isKindOfClass:NSManagedObject.class] ? ManagedValue(chat, @"mid") : nil;
    NSString *messageID = MessageNumber(ManagedValue(message, @"id"), NO, NULL);
    NSString *store = StoreNamespace(message);
    if (!Token(chatID) || !messageID || !store) return @{};
    NSMutableDictionary *key = [@{@"store":store, @"kind":kind, @"chat":[chatID copy], @"message":messageID} mutableCopy];
    NSString *senderID = MessageAuthorMIDOnContextQueue(message);
    if (Token(senderID)) key[@"sender"] = senderID;
    return [key copy];
}
NSDictionary *RUINHistoryMessageKey(id value) {
    if (![value isKindOfClass:NSManagedObject.class]) return @{};
    NSManagedObject *message = value;
    NSManagedObjectContext *context = message.managedObjectContext;
    if (!context) return @{};
    __block NSDictionary *key = @{};
    [context performBlockAndWait:^{
        @try { key = MessageKeyOnContextQueue(message); }
        @catch (__unused NSException *exception) { key = @{}; }
    }];
    return key;
}
static void CaptureMessage(id object) {
    BOOL retain = atomic_load(&retainEnabled), readers = atomic_load(&readersEnabled);
    if ((!retain && !readers) || ![object isKindOfClass:NSManagedObject.class]) return;
    @try {
        // didSave runs on the context's queue. Copy every value here; enqueue no managed objects.
        NSManagedObject *message = object;
        NSDictionary *key = MessageKeyOnContextQueue(message);
        if (!key.count) return;
        NSMutableDictionary *snapshot = nil;
        if (retain) {
            NSString *text = ObjectGetter(message, "plaintext") ?: ManagedValue(message, @"text");
            snapshot = [key mutableCopy];
            snapshot[@"body"] = Text(text) ? [text copy] : @"";
            snapshot[@"sender"] = key[@"sender"] ?: @"";
            sqlite3_int64 timestamp, contentType;
            if (!IntegerNumber(ManagedValue(message, @"timestamp"), &timestamp) ||
                !IntegerNumber(ManagedValue(message, @"contentType"), &contentType)) {
                atomic_fetch_add(&archiveWriteFailures, 1); return;
            }
            snapshot[@"timestamp"] = @(timestamp);
            snapshot[@"contentType"] = @(contentType);
        }
        NSDictionary *copiedSnapshot = [snapshot copy];
        RUINHistoryStore *store;
        dispatch_queue_t queue;
        @synchronized (RUINHistoryStore.class) { store = historyStore; queue = historyQueue; }
        if (!store || !queue) return;
        dispatch_async(queue, ^{
            if (![store bindStore:key[@"store"] kind:key[@"kind"] chat:key[@"chat"]]) atomic_fetch_add(&archiveWriteFailures, 1);
            if (retain) {
                if ([store saveSnapshot:copiedSnapshot]) atomic_fetch_add(&capturedSnapshots, 1);
                else atomic_fetch_add(&archiveWriteFailures, 1);
            }
        });
    } @catch (__unused NSException *exception) {
        atomic_fetch_add(&archiveWriteFailures, 1);
    }
}
#if TARGET_OS_IPHONE
static void CaptureLocalIncomingNotification(id value) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:RUINLocalNotificationsEnabledDefaultsKey] ||
        ![value isKindOfClass:NSManagedObject.class]) return;
    @try {
        // didSave is already on the owning context. Only copied values cross
        // into the notification service; no context wait or managed object.
        NSManagedObject *message = value;
        NSDictionary *key = MessageKeyOnContextQueue(message);
        if (![key[@"kind"] isEqual:@"talk"] || message.isDeleted ||
            ![NativeAccountMIDForStore(message.objectID.persistentStore) isEqual:NativeProfileMID()]) return;
        BOOL outgoing = YES, received = NO, system = YES, available = NO;
        if (!BooleanGetter(message, "isSendMessage", &outgoing) || outgoing ||
            !BooleanGetter(message, "isReceivedMessage", &received) || !received ||
            !BooleanGetter(message, "isSystemMessage", &system) || system) return;
        id chat = ObjectGetter(message, "chatObject");
        if (![chat isKindOfClass:NSManagedObject.class] ||
            [chat managedObjectContext] != message.managedObjectContext ||
            [chat objectID].persistentStore != message.objectID.persistentStore ||
            ![ManagedValue(chat, @"mid") isEqual:key[@"chat"]] ||
            !BooleanGetter(chat, "isNotificationAvailable", &available)) return;
        NSAttributeDescription *alertAttribute = [chat entity].attributesByName[@"alert"];
        id alert = ManagedValue(chat, @"alert");
        if (alertAttribute.attributeType != NSBooleanAttributeType || ![alert isKindOfClass:NSNumber.class]) return;
        SEL metadataSelector = sel_registerName("contentMetadataDictionary");
        Method metadataGetter = class_getInstanceMethod(object_getClass(message), metadataSelector);
        if (!metadataGetter || strcmp(method_getTypeEncoding(metadataGetter), "@16@0:8")) return;
        id metadata = [(id<RUINMessagingMessageFields>)message contentMetadataDictionary];
        if (metadata && ![metadata isKindOfClass:NSDictionary.class]) return;
        id silentFlag = metadata[@"NOTIFICATION_DISABLED"];
        // Native metadata is string-valued; absent means normal. Unknown
        // representations stay quiet rather than defeating silent sending.
        BOOL silent = silentFlag && !([silentFlag isKindOfClass:NSString.class] && [silentFlag isEqual:@"false"]);
        sqlite3_int64 timestamp = 0, contentType = 0;
        if (!IntegerNumber(ManagedValue(message, @"timestamp"), &timestamp) || timestamp <= 0 ||
            !IntegerNumber(ManagedValue(message, @"contentType"), &contentType) || contentType < 0) return;
        NSString *title = ObjectGetter(message, "displayUserNameOfSender");
        NSString *body = ObjectGetter(message, "plaintext");
        NSMutableDictionary *snapshot = [key mutableCopy];
        snapshot[@"title"] = Text(title) && title.length ? [title copy] : @"LINE";
        snapshot[@"body"] = Text(body) && body.length ? [body copy] :
            (contentType ? RUINLocalizedString(@"添付ファイルを受信しました") : RUINLocalizedString(@"新着メッセージを受信しました"));
        snapshot[@"timestampMs"] = @(timestamp);
        snapshot[@"contentType"] = @(contentType);
        snapshot[@"isOutgoing"] = @NO;
        snapshot[@"muted"] = @((BOOL)(!available || ![alert boolValue] || silent));
        RUINObserveLocalIncomingSnapshot([snapshot copy]);
    } @catch (__unused NSException *exception) {
        // An unrecognized native value must not create a notification.
    }
}
#endif
%group RUINHistoryTalk
%hook RUINHistoryMessage
- (void)didSave {
    %orig;
#if TARGET_OS_IPHONE
    CaptureLocalIncomingNotification(self);
#endif
    CaptureMessage(self);

}
%end
%end
%group RUINHistorySquare
%hook RUINHistorySquareMessage
- (void)didSave {
    %orig;
    CaptureMessage(self);

}
%end
%end
static BOOL IntegerGetter(id object, const char *name, long long *value) {
    Method method = class_getInstanceMethod(object_getClass(object), sel_registerName(name));
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, "q16@0:8")) return NO;
    *value = ((long long (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
    return YES;
}
static _Thread_local unsigned readRangeDecodeDepth, readRangeCaptureDepth;
static void CaptureReadRanges(id chatID, id ranges) {
    if (!atomic_load(&readersEnabled) || readRangeDecodeDepth || readRangeCaptureDepth) return;
    readRangeCaptureDepth++;
    @try {
        if (!Token(chatID) || ![ranges isKindOfClass:NSDictionary.class] || ![ranges count]) return;
        Class entryClass = objc_getClass("LineTMessageReadRangeEntry");
        if (!entryClass) { atomic_fetch_add(&rejectedReadEvents, 1); return; }
        NSMutableDictionary *copied = [NSMutableDictionary dictionary];
        NSUInteger rangeCount = 0;
        for (id reader in ranges) {
            if (!Token(reader) || ![ranges[reader] isKindOfClass:NSArray.class] || ![ranges[reader] count]) {
                atomic_fetch_add(&rejectedReadEvents, 1); return;
            }
            NSMutableArray *entries = [NSMutableArray array];
            for (id entry in ranges[reader]) {
                long long start, end, startTime, endTime;
                if (![entry isKindOfClass:entryClass] || !IntegerGetter(entry, "startMessageId", &start) ||
                    !IntegerGetter(entry, "endMessageId", &end) || !IntegerGetter(entry, "startTime", &startTime) ||
                    !IntegerGetter(entry, "endTime", &endTime) || start < 0 || end <= 0 || end <= start) {
                    atomic_fetch_add(&rejectedReadEvents, 1); return;
                }
                [entries addObject:@{@"start":[NSString stringWithFormat:@"%lld", start], @"end":[NSString stringWithFormat:@"%lld", end],
                    @"startTime":@(startTime), @"endTime":@(endTime),
                    @"observedAt":@((long long)(NSDate.date.timeIntervalSince1970 * 1000.0)), @"timeSource":@"range"}];
            }
            rangeCount += entries.count;
            copied[[reader copy]] = [entries copy];
        }
        NSString *copiedChat = [chatID copy];
        NSDictionary *copiedReaders = [copied copy];
        RUINHistoryStore *store;
        dispatch_queue_t queue;
        @synchronized (RUINHistoryStore.class) { store = historyStore; queue = historyQueue; }
        if (!store || !queue) return;
        dispatch_async(queue, ^{
            if ([store recordObservedRangesByReader:copiedReaders kind:@"talk" chat:copiedChat]) atomic_fetch_add(&observedRanges, rangeCount);
            else atomic_fetch_add(&archiveWriteFailures, 1);
        });
    } @catch (__unused NSException *exception) {
        atomic_fetch_add(&rejectedReadEvents, 1);
    } @finally {
        readRangeCaptureDepth--;
    }
}
%group RUINHistoryRanges
%hook RUINHistoryReadRange
- (id)ranges {
    id ranges = %orig;
    if (atomic_load(&readersEnabled) && !readRangeDecodeDepth && !readRangeCaptureDepth) {
        id chatID;
        readRangeCaptureDepth++;
        @try { chatID = ObjectGetter(self, "chatId"); }
        @catch (__unused NSException *exception) { atomic_fetch_add(&rejectedReadEvents, 1); }
        @finally { readRangeCaptureDepth--; }
        CaptureReadRanges(chatID, ranges);
    }
    return ranges;

}
%end
%end
// Verified build/event-objc.json: LineTMessageReadRange read: v24@0:8@16;
// chatId/ranges @16@0:8; LineTMessageReadRangeEntry's four scalar getters q16@0:8.
// Signed Int64 allows the zero lower boundary. Endpoint inclusion is not established by metadata.
%group RUINHistoryRead
%hook RUINHistoryReadRange
- (void)read:(id)protocol {
    readRangeDecodeDepth++;
    @try { %orig; }
    @finally { readRangeDecodeDepth--; }
    if (!atomic_load(&readersEnabled)) return;
    id chatID = nil, ranges = nil;
    readRangeDecodeDepth++;
    @try {
        chatID = ObjectGetter(self, "chatId"); ranges = ObjectGetter(self, "ranges");
    } @catch (__unused NSException *exception) { atomic_fetch_add(&rejectedReadEvents, 1); }
    @finally { readRangeDecodeDepth--; }
    CaptureReadRanges(chatID, ranges);

}
%end
%end

// Shared by normal installation and host fixtures: Logos permits one %init
// source location per group, even when multiple callers need the same hook.
static void InitRUINHistoryTalk(Class cls) {
    %init(RUINHistoryTalk, RUINHistoryMessage = cls);
}
static void InitRUINHistorySquare(Class cls) {
    %init(RUINHistorySquare, RUINHistorySquareMessage = cls);
}
static void InitRUINHistoryRead(Class cls) {
    %init(RUINHistoryRead, RUINHistoryReadRange = cls);
}
static void InitRUINHistoryRanges(Class cls) {
    %init(RUINHistoryRanges, RUINHistoryReadRange = cls);
}

static void InstallHistoryHook(const char *className, const char *selectorName, const char *encoding, void (*initialize)(Class)) {
    NSString *key = [NSString stringWithFormat:@"%s.%s", className, selectorName];
    if ([historyHooks[key] isEqual:@"installed"]) return;
    Class cls = objc_getClass(className);
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName(selectorName)) : NULL;
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    if (!actual || strcmp(actual, encoding)) { historyHooks[key] = @"unavailable_or_encoding_mismatch"; return; }
    if (!method_getImplementation(method)) { historyHooks[key] = @"missing_implementation"; return; }
    initialize(cls);
    historyHooks[key] = @"installed";
}
#if defined(RUIN_MESSAGE_HISTORY_HOST_CHECK)
// Host fixture seam: installs the same runtime hooks against its native model classes.
void RUINHistoryHostCheckConfigure(RUINHistoryStore *store, BOOL enabled) {
    @synchronized (RUINHistoryStore.class) {
        historyStore = store;
        if (!historyQueue) {
            historyQueue = dispatch_queue_create("ruin.message-history.host-check", DISPATCH_QUEUE_SERIAL);
            dispatch_queue_set_specific(historyQueue, &historyQueueKey, &historyQueueKey, NULL);
        }
        if (!historyHooks) historyHooks = [NSMutableDictionary dictionary];
    }
    atomic_store(&readersEnabled, enabled);
    InstallHistoryHook("LineTMessageReadRange", "read:", "v24@0:8@16", InitRUINHistoryRead);
    InstallHistoryHook("LineTMessageReadRange", "ranges", "@16@0:8", InitRUINHistoryRanges);
}
void RUINHistoryHostCheckFlush(void) {
    dispatch_queue_t queue;
    @synchronized (RUINHistoryStore.class) { queue = historyQueue; }
    if (queue) dispatch_sync(queue, ^{});
}
#endif
void RUINInstallMessageHistory(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    BOOL supported = RUINTargetMetadataMatchesInfo(info);
    atomic_store(&retainEnabled, supported && [NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey]);
    atomic_store(&readersEnabled, supported && [NSUserDefaults.standardUserDefaults boolForKey:RUINTrackReadUsersKey]);
    if (!supported) return;
    @synchronized (RUINHistoryStore.class) {
        if (!historyQueue) {
            historyQueue = dispatch_queue_create("ruin.message-history", DISPATCH_QUEUE_SERIAL);
            dispatch_queue_set_specific(historyQueue, &historyQueueKey, &historyQueueKey, NULL);
            historyHooks = [NSMutableDictionary dictionary];
        }
        if (!historyStore) {
            NSURL *root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
            historyStore = [[RUINHistoryStore alloc] initWithURL:[root URLByAppendingPathComponent:@"RUIN/history.sqlite"] error:NULL];
        }
        if (!historyStore) return;
        InstallHistoryHook("ManagedMessage", "didSave", "v16@0:8", InitRUINHistoryTalk);
        InstallHistoryHook("ManagedSquareMessage", "didSave", "v16@0:8", InitRUINHistorySquare);
        InstallHistoryHook("LineTMessageReadRange", "read:", "v24@0:8@16", InitRUINHistoryRead);
        InstallHistoryHook("LineTMessageReadRange", "ranges", "@16@0:8", InitRUINHistoryRanges);
    }
}
NSArray<NSDictionary *> *RUINReadUsersForMessage(id message) {
    return RUINReadUsersForMessageKey(RUINHistoryMessageKey(message));
}
NSArray<NSDictionary *> *RUINReadUsersForMessageKey(NSDictionary *key) {
    if (![key isKindOfClass:NSDictionary.class]) return @[];
    for (NSString *field in @[@"store", @"kind", @"chat"]) if (!Token(key[field])) return @[];
    NSString *message = MessageNumber(key[@"message"], NO, NULL);
    if (![@[@"talk", @"square"] containsObject:key[@"kind"]] || !message) return @[];
    id suppliedSender = key[@"sender"];
    if (suppliedSender && (!Token(suppliedSender) || [suppliedSender length] > 256)) return @[];
    NSString *senderID = [suppliedSender copy];
    key = @{@"store":[key[@"store"] copy], @"kind":[key[@"kind"] copy],
            @"chat":[key[@"chat"] copy], @"message":message};
    RUINHistoryStore *store;
    dispatch_queue_t queue;
    @synchronized (RUINHistoryStore.class) { store = historyStore; queue = historyQueue; }
    if (!key.count || !store || !queue) return @[];
    __block NSArray *result;
    void (^query)(void) = ^{ result = [store readersInStore:key[@"store"] kind:key[@"kind"] chat:key[@"chat"] message:key[@"message"]]; };
    if (dispatch_get_specific(&historyQueueKey)) query();
    else dispatch_sync(queue, query);
    if (!senderID.length || !result.count) return result ?: @[];
    NSMutableArray *readers = [NSMutableArray arrayWithCapacity:result.count];
    for (NSDictionary *reader in result)
        if (![reader[@"readerID"] isEqualToString:senderID]) [readers addObject:reader];
    return [readers copy];
}
NSDictionary *RUINHistoryRetainUnsentSnapshotForKey(NSDictionary *key) {
    if (!atomic_load(&retainEnabled) || ![key isKindOfClass:NSDictionary.class]) return @{};
    for (NSString *field in @[@"store", @"kind", @"chat"]) if (!Token(key[field])) return @{};
    NSString *message = MessageNumber(key[@"message"], NO, NULL);
    if (!message) return @{};
    NSDictionary *copiedKey = @{@"store":[key[@"store"] copy], @"kind":[key[@"kind"] copy],
        @"chat":[key[@"chat"] copy], @"message":message};
    RUINHistoryStore *store;
    dispatch_queue_t queue;
    @synchronized (RUINHistoryStore.class) { store = historyStore; queue = historyQueue; }
    if (!store || !queue) return @{};
    __block NSDictionary *result = @{};
    void (^freeze)(void) = ^{
        if (!atomic_load(&retainEnabled)) return;
        NSDictionary *snapshot = [store ruinRetainUnsentKey:copiedKey];
        if (snapshot.count) {
            NSMutableDictionary *copy = [snapshot mutableCopy];
            copy[@"originalUnavailable"] = @([snapshot[@"contentType"] longLongValue] == -1 && [snapshot[@"body"] length] == 0);
            result = [copy copy];
        } else atomic_fetch_add(&archiveWriteFailures, 1);
    };
    if (dispatch_get_specific(&historyQueueKey)) freeze();
    else dispatch_sync(queue, freeze);
    return result;
}
BOOL RUINHistoryRecordType55ReadUpTo(NSString *param1, NSString *param2, NSString *param3) {
    return RUINHistoryRecordType55ReadUpToWithTime(param1, param2, param3, 0, 0);
}
BOOL RUINHistoryRecordType55ReadUpToWithTime(NSString *param1, NSString *param2, NSString *param3,
                                           long long serverTime, long long observedTime) {
    NSString *message = MessageNumber(param3, NO, NULL);
    if (!Token(param1) || !Token(param2) || !message) return NO;
    NSString *chat = [param1 copy], *reader = [param2 copy];
    RUINInstallMessageHistory();
    if (!atomic_load(&readersEnabled)) return NO;
    RUINHistoryStore *store;
    dispatch_queue_t queue;
    @synchronized (RUINHistoryStore.class) { store = historyStore; queue = historyQueue; }
    if (!store || !queue) return NO;
    __block BOOL recorded = NO;
    void (^record)(void) = ^{
        if (!atomic_load(&readersEnabled)) return;
        recorded = [store recordObservedRangesByReader:@{reader:@[@{@"start":@"0", @"end":message,
            @"startTime":@(MAX(0, serverTime)), @"endTime":@(MAX(0, serverTime)),
            @"observedAt":@(MAX(0, observedTime)), @"timeSource":@"server_event"}]} kind:@"talk" chat:chat];
        if (recorded) atomic_fetch_add(&observedType55Events, 1);
        else atomic_fetch_add(&archiveWriteFailures, 1);
    };
    if (dispatch_get_specific(&historyQueueKey)) record();
    else dispatch_sync(queue, record);
    return recorded;
}
NSDictionary *RUINMessageHistoryDiagnostics(void) {
    RUINHistoryStore *store;
    NSDictionary *hooks;
    @synchronized (RUINHistoryStore.class) { store = historyStore; hooks = [historyHooks copy] ?: @{}; }
    NSDictionary *counts = store.counts ?: @{};
    NSUInteger unattributed = [counts[@"pendingReadRanges"] unsignedIntegerValue] + [counts[@"ambiguousReadRanges"] unsignedIntegerValue];
    return @{@"hooks":hooks, @"storageReady":@(store != nil),
        @"retainEnabled":@(atomic_load(&retainEnabled)), @"trackReadersEnabled":@(atomic_load(&readersEnabled)),
        @"capturedSnapshots":@(atomic_load(&capturedSnapshots)), @"observedReadRanges":@(atomic_load(&observedRanges)),
        @"observedType55Events":@(atomic_load(&observedType55Events)),
        @"nativeReadPositionSnapshots":@(atomic_load(&nativePositionSnapshots)),
        @"nativeReadPositionReaders":@(atomic_load(&nativePositionRows)),
        @"nativeReadPositionScopeRejected":@(atomic_load(&nativePositionRejected)),
        @"unattributedReadRanges":@(unattributed), @"rejectedReadEvents":@(atomic_load(&rejectedReadEvents)),
        @"archiveWriteFailures":@(atomic_load(&archiveWriteFailures)), @"storedCounts":counts,
        @"readAttribution":@"persisted kind/chat/store bindings; store-less events visible only with one known binding; multiple stores hide them",
        @"readObserverKind":@"talk; OpenChat read-event source not verified",
        @"readRangeCaptureBoundary":@"LineTMessageReadRange.ranges getter returns a completed model; read: decode getters are suppressed",
        @"rangeBoundaryConvention":@"start<message<=end per Android reference; iOS wire boundary/device behavior remains unverified",
        @"unsendRenderingImplemented":@NO,
        @"pending":@[@"verified unsend classification and in-chat retained rendering", @"media retention", @"iOS read-range boundary/device verification", @"OpenChat read-event source", @"read-user menu integration"]};
}
