/* From ruin/:
 xcrun --sdk macosx clang -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror \
   -I. src/core/Features.m src/messaging/MessageHistory.m tests/check_history.m -framework Foundation \
   -framework CoreData -lsqlite3 -o /tmp/ruin-check-history && /tmp/ruin-check-history
 */
#import "MessageHistory.h"
#import <sqlite3.h>
#import <CoreData/CoreData.h>
#import <pthread.h>
#import <stdatomic.h>
#import <limits.h>
#import <stdio.h>

static void CHECK(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"RUINHistoryCheck" reason:message userInfo:nil];
}

static NSDictionary *Snapshot(NSString *store, NSString *kind, NSString *chat, id message, NSString *body) {
    return @{@"store":store, @"kind":kind, @"chat":chat, @"message":message,
        @"body":body, @"sender":@"sender", @"timestamp":@(LLONG_MAX - 7), @"contentType":@1};
}
static NSDictionary *Range(id start, id end, long long startTime, long long endTime) {
    return @{@"start":start, @"end":end, @"startTime":@(startTime), @"endTime":@(endTime)};
}
static NSSet *ReaderIDs(NSArray<NSDictionary *> *readers) {
    NSMutableSet *result = [NSMutableSet set];
    for (NSDictionary *reader in readers) [result addObject:reader[@"readerID"]];
    return result;
}
static void SQL(NSURL *url, const char *sql) {
    sqlite3 *db = NULL;
    int status = sqlite3_open(url.fileSystemRepresentation, &db);
    if (status == SQLITE_OK) status = sqlite3_exec(db, sql, NULL, NULL, NULL);
    NSString *reason = db ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"open failed";
    if (db) sqlite3_close(db);
    CHECK(status == SQLITE_OK, [@"fixture SQL: " stringByAppendingString:reason]);
}
static long long Scalar(NSURL *url, const char *sql) {
    sqlite3 *db = NULL;
    sqlite3_stmt *statement = NULL;
    int status = sqlite3_open(url.fileSystemRepresentation, &db);
    if (status == SQLITE_OK) status = sqlite3_prepare_v2(db, sql, -1, &statement, NULL);
    if (status == SQLITE_OK) status = sqlite3_step(statement);
    long long value = status == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0;
    sqlite3_finalize(statement);
    if (db) sqlite3_close(db);
    CHECK(status == SQLITE_ROW, @"fixture scalar query failed");
    return value;
}
typedef struct {
    __unsafe_unretained RUINHistoryStore *store;
    NSUInteger worker;
    atomic_bool *failed;
} Worker;
static void *WriteWorker(void *argument) {
    Worker *worker = argument;
    @autoreleasepool {
        for (NSUInteger i = 0; i < 24; i++) {
            NSUInteger messageID = 1000 + worker->worker * 24 + i;
            NSString *message = [NSString stringWithFormat:@"%lu", (unsigned long)messageID];
            NSString *start = [NSString stringWithFormat:@"%lu", (unsigned long)(messageID - 1)];
            NSString *reader = [NSString stringWithFormat:@"worker-%lu", (unsigned long)worker->worker];
            if (![worker->store saveSnapshot:Snapshot(@"threads", @"talk", @"shared", message, @"body")] ||
                ![worker->store recordRanges:@[Range(start, message, 1, 2)] inStore:@"threads"
                    kind:@"talk" chat:@"shared" reader:reader]) atomic_store(worker->failed, true);
        }
    }
    return NULL;
}

// Native Core Data fixtures exercise the public queue-marshalling key helper.
@interface ManagedMessage : NSManagedObject {
    BOOL _sendMessageFlag, _receivedMessageFlag;
}
@property (nonatomic) BOOL isSendMessage;
@property (nonatomic) BOOL isReceivedMessage;
@end
@implementation ManagedMessage
- (BOOL)isSendMessage { return _sendMessageFlag; }
- (void)setIsSendMessage:(BOOL)value { _sendMessageFlag = value; }
- (BOOL)isReceivedMessage { return _receivedMessageFlag; }
- (void)setIsReceivedMessage:(BOOL)value { _receivedMessageFlag = value; }
@end
@interface ManagedSquareMessage : NSManagedObject @end
@implementation ManagedSquareMessage @end
@interface ManagedChat : NSManagedObject @end
@implementation ManagedChat @end
@interface ManagedChatMetadata : NSManagedObject @end
@implementation ManagedChatMetadata @end

extern void RUINHistoryHostCheckConfigure(RUINHistoryStore *store, BOOL enabled);
extern void RUINHistoryHostCheckFlush(void);
extern void RUINHistoryHostCheckSetProfileMID(NSString *mid);
@interface LineTMessageReadRangeEntry : NSObject
@property long long startMessageId, endMessageId, startTime, endTime;
@end
@implementation LineTMessageReadRangeEntry @end
@interface LineTMessageReadRange : NSObject
@property(copy) NSString *chatId;
@property(copy) NSDictionary *fixtureRanges;
@property NSUInteger readCalls, rangeCalls;
- (void)read:(id)protocol;
- (NSDictionary *)ranges;
@end
@implementation LineTMessageReadRange
- (void)read:(id)protocol {
    self.readCalls++;
    if ([protocol isEqual:@"throw"]) [NSException raise:@"FixtureDecodeFailure" format:@"decode failed"];
    if ([protocol isKindOfClass:LineTMessageReadRange.class]) [protocol read:nil];
    (void)self.ranges;
}
- (NSDictionary *)ranges { self.rangeCalls++; return self.fixtureRanges; }
@end

static LineTMessageReadRange *ReadRangeFixture(NSString *chat) {
    LineTMessageReadRangeEntry *entry = [LineTMessageReadRangeEntry new];
    entry.startMessageId = 0; entry.endMessageId = 10; entry.startTime = 100; entry.endTime = 200;
    LineTMessageReadRange *model = [LineTMessageReadRange new];
    model.chatId = chat; model.fixtureRanges = @{ @"reader":@[entry] };
    return model;
}
static void CheckReadRanges(RUINHistoryStore *store) {
    RUINHistoryHostCheckConfigure(store, YES);
    CHECK([store bindStore:@"s1" kind:@"talk" chat:@"getter-only"], @"getter fixture binding failed");
    LineTMessageReadRange *getterOnly = ReadRangeFixture(@"getter-only");
    long long before = [store.counts[@"observed_ranges"] longLongValue];
    (void)getterOnly.ranges;
    RUINHistoryHostCheckFlush();
    CHECK(getterOnly.rangeCalls == 1 && [store.counts[@"observed_ranges"] longLongValue] == before + 1 &&
          [store readersInStore:@"s1" chat:@"getter-only" message:@"5"].count == 1,
          @"ranges getter did not persist a read event without read:");

    CHECK([store bindStore:@"s1" kind:@"talk" chat:@"legacy-read"], @"legacy fixture binding failed");
    LineTMessageReadRange *legacy = ReadRangeFixture(@"legacy-read");
    before = [store.counts[@"observed_ranges"] longLongValue];
    [legacy read:nil];
    RUINHistoryHostCheckFlush();
    CHECK(legacy.readCalls == 1 && legacy.rangeCalls == 2 &&
          [store.counts[@"observed_ranges"] longLongValue] == before + 1,
          @"legacy read was repeated or getter decode was captured more than once");

    CHECK([store bindStore:@"s1" kind:@"talk" chat:@"nested-outer"] &&
          [store bindStore:@"s1" kind:@"talk" chat:@"nested-inner"], @"nested fixture binding failed");
    LineTMessageReadRange *outer = ReadRangeFixture(@"nested-outer"), *inner = ReadRangeFixture(@"nested-inner");
    before = [store.counts[@"observed_ranges"] longLongValue];
    [outer read:inner]; RUINHistoryHostCheckFlush();
    CHECK(outer.readCalls == 1 && inner.readCalls == 1 &&
          [store.counts[@"observed_ranges"] longLongValue] == before + 1,
          @"nested decoder exposed an unfinished model");
    (void)inner.ranges; RUINHistoryHostCheckFlush();
    CHECK([store.counts[@"observed_ranges"] longLongValue] == before + 2,
          @"nested decode depth did not unwind for subsequent consumption");
    LineTMessageReadRange *failed = ReadRangeFixture(@"failed-decode");
    before = [store.counts[@"observed_ranges"] longLongValue];
    BOOL threw = NO;
    @try { [failed read:@"throw"]; }
    @catch (NSException *exception) { threw = [exception.name isEqual:@"FixtureDecodeFailure"]; }
    RUINHistoryHostCheckFlush();
    CHECK(threw && failed.readCalls == 1 && [store.counts[@"observed_ranges"] longLongValue] == before,
          @"original decoder exception was swallowed or partial data was recorded");

    RUINHistoryHostCheckConfigure(store, NO);
    LineTMessageReadRange *disabled = ReadRangeFixture(@"disabled");
    before = [store.counts[@"observed_ranges"] longLongValue];
    (void)disabled.ranges; RUINHistoryHostCheckFlush();
    CHECK(disabled.rangeCalls == 1 && [store.counts[@"observed_ranges"] longLongValue] == before,
          @"disabled range tracking wrote an event");
    RUINHistoryHostCheckConfigure(store, YES);
    LineTMessageReadRange *invalid = ReadRangeFixture(@"");
    before = [store.counts[@"observed_ranges"] longLongValue];
    (void)invalid.ranges; RUINHistoryHostCheckFlush();
    CHECK([store.counts[@"observed_ranges"] longLongValue] == before,
          @"invalid model was persisted");
    RUINHistoryHostCheckConfigure(nil, NO);
}

static NSAttributeDescription *Attribute(NSString *name, NSAttributeType type) {
    NSAttributeDescription *attribute = [NSAttributeDescription new];
    attribute.name = name; attribute.attributeType = type; attribute.optional = YES;
    return attribute;
}
static NSRelationshipDescription *Relationship(NSString *name, NSEntityDescription *destination) {
    NSRelationshipDescription *r = [NSRelationshipDescription new];
    r.name = name; r.destinationEntity = destination; r.maxCount = 1; r.optional = YES;
    return r;
}
static void CheckNativePositions(NSURL *directory, RUINHistoryStore *store, NSString *rolePrefix) {
    NSString *own = @"uaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", *peer = @"ubbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    NSEntityDescription *chatEntity = [NSEntityDescription new], *metaEntity = [NSEntityDescription new];
    NSEntityDescription *messageEntity = [NSEntityDescription new], *userEntity = [NSEntityDescription new];
    chatEntity.name = @"Chat"; chatEntity.managedObjectClassName = @"ManagedChat";
    metaEntity.name = @"ChatMetadata"; metaEntity.managedObjectClassName = @"ManagedChatMetadata";
    messageEntity.name = @"Message"; messageEntity.managedObjectClassName = @"ManagedMessage";
    userEntity.name = @"User"; userEntity.managedObjectClassName = @"NSManagedObject";
    userEntity.properties = @[Attribute(@"mid", NSStringAttributeType)];
    chatEntity.properties = @[Attribute(@"mid", NSStringAttributeType), Attribute(@"readUpToMessageIDSynced", NSInteger64AttributeType), Relationship(@"metadata", metaEntity)];
    metaEntity.properties = @[Attribute(@"memberData", NSBinaryDataAttributeType), Attribute(@"lastReadIDData", NSBinaryDataAttributeType),
        Attribute(@"memberEntryData", NSBinaryDataAttributeType), Relationship(@"chat", chatEntity), Relationship(@"formerMemberMetadata", metaEntity)];
    messageEntity.properties = @[Attribute(@"id", NSStringAttributeType), Relationship(@"chat", chatEntity), Relationship(@"sender", userEntity)];
    NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[chatEntity,metaEntity,messageEntity,userEntity];
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSURL *folder = [[[[[directory URLByAppendingPathComponent:@"Library/Application Support" isDirectory:YES]
        URLByAppendingPathComponent:@"PrivateStore" isDirectory:YES]
        URLByAppendingPathComponent:[rolePrefix stringByAppendingString:own] isDirectory:YES]
        URLByAppendingPathComponent:@"Messages" isDirectory:YES] standardizedURL];
    CHECK([NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil], @"native cursor directory failed");
    CHECK([psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[folder URLByAppendingPathComponent:@"Line.sqlite"] options:nil error:nil] != nil, @"native cursor store failed");
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = psc;
    __block NSManagedObject *chat, *metadata, *message, *outgoing, *ambiguous, *unknown;
    [context performBlockAndWait:^{
        chat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context];
        metadata = [NSEntityDescription insertNewObjectForEntityForName:@"ChatMetadata" inManagedObjectContext:context];
        message = [NSEntityDescription insertNewObjectForEntityForName:@"Message" inManagedObjectContext:context];
        NSManagedObject *author = [NSEntityDescription insertNewObjectForEntityForName:@"User" inManagedObjectContext:context];
        [author setValue:peer forKey:@"mid"];
        [chat setValue:@"cdddddddddddddddddddddddddddddddd" forKey:@"mid"]; [chat setValue:@25 forKey:@"readUpToMessageIDSynced"];
        [chat setValue:metadata forKey:@"metadata"]; [metadata setValue:chat forKey:@"chat"];
        uint8_t member[16]; memset(member, 0xbb, sizeof(member)); uint64_t end = 20, entry = 10;
        [metadata setValue:[NSData dataWithBytes:member length:16] forKey:@"memberData"];
        [metadata setValue:[NSData dataWithBytes:&end length:8] forKey:@"lastReadIDData"];
        [metadata setValue:[NSData dataWithBytes:&entry length:8] forKey:@"memberEntryData"];
        [message setValue:@"18" forKey:@"id"]; [message setValue:chat forKey:@"chat"]; [message setValue:author forKey:@"sender"];
        outgoing = [NSEntityDescription insertNewObjectForEntityForName:@"Message" inManagedObjectContext:context];
        [outgoing setValue:@"19" forKey:@"id"]; [outgoing setValue:chat forKey:@"chat"];
        ((ManagedMessage *)outgoing).isSendMessage = YES;
        ambiguous = [NSEntityDescription insertNewObjectForEntityForName:@"Message" inManagedObjectContext:context];
        [ambiguous setValue:@"19" forKey:@"id"]; [ambiguous setValue:chat forKey:@"chat"];
        ((ManagedMessage *)ambiguous).isSendMessage = YES; ((ManagedMessage *)ambiguous).isReceivedMessage = YES;
        unknown = [NSEntityDescription insertNewObjectForEntityForName:@"Message" inManagedObjectContext:context];
        [unknown setValue:@"19" forKey:@"id"]; [unknown setValue:chat forKey:@"chat"];
        CHECK([context save:nil], @"native cursor fixture save failed");
    }];
    RUINHistoryHostCheckConfigure(store, YES); RUINHistoryHostCheckSetProfileMID(own);
    NSDictionary *key = RUINHistoryMessageKey(message);
    CHECK(RUINHistoryValidateReadChatKey(key, chat), @"active primary/secondary chat binding was rejected");
    NSDictionary *outgoingKey = RUINHistoryMessageKey(outgoing);
    NSDictionary *ambiguousKey = RUINHistoryMessageKey(ambiguous), *unknownKey = RUINHistoryMessageKey(unknown);
    CHECK([key[@"sender"] isEqual:peer], @"incoming sender relationship was not copied as author");
    CHECK([outgoingKey[@"sender"] isEqual:own], @"verified outgoing message did not use its scoped account author");
    CHECK(!ambiguousKey[@"sender"] && !unknownKey[@"sender"], @"ambiguous direction flags guessed an author");
    RUINHistoryHostCheckSetProfileMID(peer);
    CHECK(!RUINHistoryValidateReadChatKey(key, chat), @"foreign profile acquired the active chat binding");
    CHECK(!RUINHistoryMessageKey(outgoing)[@"sender"], @"outgoing flag used a mismatched active profile");
    RUINHistoryHostCheckSetProfileMID(own);
    NSMutableDictionary *wrong = [key mutableCopy]; wrong[@"store"] = @"foreign-store";
    RUINObserveNativeReadPositionsForMessageKey(wrong, chat);
    CHECK(RUINReadUsersForMessageKey(wrong).count == 0, @"native cursors crossed a store namespace");
    wrong = [key mutableCopy]; wrong[@"chat"] = @"ceeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    RUINObserveNativeReadPositionsForMessageKey(wrong, chat);
    CHECK(RUINReadUsersForMessageKey(wrong).count == 0, @"native cursors crossed a chat identity");
    RUINObserveNativeReadPositionsForMessageKey(key, chat);
    NSArray *rows = RUINReadUsersForMessageKey(key);
    CHECK([ReaderIDs(rows) isEqual:[NSSet setWithObject:own]], @"incoming author was not excluded or current account was blanket-excluded");
    CHECK([ReaderIDs(RUINReadUsersForMessageKey(outgoingKey)) isEqual:[NSSet setWithObject:peer]],
          @"outgoing account author was not excluded");
    NSSet *both = [NSSet setWithArray:@[own, peer]];
    CHECK([ReaderIDs(RUINReadUsersForMessageKey(ambiguousKey)) isEqual:both] &&
          [ReaderIDs(RUINReadUsersForMessageKey(unknownKey)) isEqual:both],
          @"ambiguous direction did not remain fail-closed");
    for (NSDictionary *row in rows) CHECK([row[@"readAtMilliseconds"] longLongValue] == 0 &&
        [row[@"observedAtMilliseconds"] longLongValue] > 0, @"cached cursor invented a read timestamp");
    NSMutableDictionary *query = [key mutableCopy]; query[@"message"] = @"10";
    CHECK([ReaderIDs(RUINReadUsersForMessageKey(query)) isEqual:[NSSet setWithObject:own]], @"member entry lower bound was included");
    query[@"message"] = @"11";
    CHECK(RUINReadUsersForMessageKey(query).count == 1, @"first message after member entry or author filtering failed");
    query[@"message"] = @"18";
    CHECK([ReaderIDs(RUINReadUsersForMessageKey(query)) isEqual:[NSSet setWithObject:own]], @"incoming author was returned as a reader");
    [context performBlockAndWait:^{ [chat setValue:@30 forKey:@"readUpToMessageIDSynced"]; }];
    RUINObserveNativeReadPositionsForMessageKey(key, chat); query[@"message"] = @"28";
    CHECK(RUINReadUsersForMessageKey(query).count == 0, @"uncommitted own cursor became a read receipt");
    [context performBlockAndWait:^{
        [context rollback]; uint64_t end = 40;
        [metadata setValue:[NSData dataWithBytes:&end length:8] forKey:@"lastReadIDData"]; CHECK([context save:nil], @"cursor update failed");
    }];
    RUINHistoryHostCheckSetProfileMID(peer); RUINObserveNativeReadPositionsForMessageKey(key,chat);
    query[@"message"] = @"35"; [query removeObjectForKey:@"sender"];
    CHECK(RUINReadUsersForMessageKey(query).count == 0, @"foreign active profile consumed another account's native cache");
    RUINHistoryHostCheckSetProfileMID(own); RUINObserveNativeReadPositionsForMessageKey(key,chat);
    CHECK([ReaderIDs(RUINReadUsersForMessageKey(query)) isEqual:[NSSet setWithObject:peer]], @"restored account did not consume its native cache");
    RUINHistoryHostCheckSetProfileMID(nil); RUINHistoryHostCheckConfigure(nil,NO);
}
static NSDictionary *CheckOldMessageCallbackBinding(NSURL *directory, RUINHistoryStore *store,
                                                       NSString *rolePrefix, NSString *chatID,
                                                       BOOL recordCallback) {
    NSString *own = @"udddddddddddddddddddddddddddddddd";
    NSEntityDescription *chatEntity = [NSEntityDescription new];
    chatEntity.name = @"Chat"; chatEntity.managedObjectClassName = @"ManagedChat";
    chatEntity.properties = @[Attribute(@"mid", NSStringAttributeType)];
    NSEntityDescription *messageEntity = [NSEntityDescription new];
    messageEntity.name = @"Message"; messageEntity.managedObjectClassName = @"ManagedMessage";
    messageEntity.properties = @[Attribute(@"id", NSStringAttributeType), Relationship(@"chat", chatEntity)];
    NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[chatEntity, messageEntity];
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSURL *folder = [[[[[directory URLByAppendingPathComponent:@"Library/Application Support" isDirectory:YES]
        URLByAppendingPathComponent:@"PrivateStore" isDirectory:YES]
        URLByAppendingPathComponent:[rolePrefix stringByAppendingString:own] isDirectory:YES]
        URLByAppendingPathComponent:@"Messages" isDirectory:YES] standardizedURL];
    CHECK([NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil],
          @"old-message root creation failed");
    CHECK([psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
        URL:[folder URLByAppendingPathComponent:@"Line.sqlite"] options:nil error:nil] != nil,
        @"old-message native store failed");
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = psc;
    __block NSManagedObject *chat, *message;
    [context performBlockAndWait:^{
        chat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context];
        message = [NSEntityDescription insertNewObjectForEntityForName:@"Message" inManagedObjectContext:context];
        [chat setValue:chatID forKey:@"mid"];
        [message setValue:@"9" forKey:@"id"]; [message setValue:chat forKey:@"chat"];
        CHECK([context save:nil], @"old-message fixture save failed");
    }];

    RUINHistoryHostCheckConfigure(store, YES); RUINHistoryHostCheckSetProfileMID(own);
    NSDictionary *key = RUINHistoryMessageKey(message);
    CHECK(RUINHistoryValidateReadChatKey(key, chat), @"selected S/P live scope was rejected");
    if (recordCallback) {
        long long pendingBefore = [store.counts[@"pendingReadRanges"] longLongValue];
        NSString *callbackReader = @"ucccccccccccccccccccccccccccccccc";
        CHECK(RUINHistoryRecordType55ReadUpToWithTime(chatID, callbackReader, @"9", 0, 1700000000000),
              @"old-message callback was not recorded");
        CHECK(RUINReadUsersForMessageKey(key).count == 0 &&
              [store.counts[@"pendingReadRanges"] longLongValue] == pendingBefore + 1,
              @"old callback was attributed before selected-chat resolution");
    }

    // Mirrors MenuExtras' validated selection observer before its local query.
    RUINObserveNativeReadPositionsForMessageKey(key, chat);
    if (recordCallback)
        CHECK([ReaderIDs(RUINReadUsersForMessageKey(key)) containsObject:@"ucccccccccccccccccccccccccccccccc"],
              @"selected S_ scope did not resolve the old callback without a new message save");
    return key;
}
static void CheckOldSecondaryCallbackAndDualScope(NSURL *directory, RUINHistoryStore *store) {
    NSString *chatID = @"cffffffffffffffffffffffffffffffff";
    NSDictionary *secondary = CheckOldMessageCallbackBinding(directory, store, @"S_", chatID, YES);
    CHECK([ReaderIDs(RUINReadUsersForMessageKey(secondary)) containsObject:@"ucccccccccccccccccccccccccccccccc"],
          @"S_ callback was not visible after the selected-message binding");
    NSDictionary *primary = CheckOldMessageCallbackBinding(directory, store, @"P_", chatID, NO);
    CHECK(![secondary[@"store"] isEqual:primary[@"store"]], @"P_/S_ fixture scopes unexpectedly matched");

    NSSet *secondaryRows = ReaderIDs(RUINReadUsersForMessageKey(secondary));
    NSSet *primaryRows = ReaderIDs(RUINReadUsersForMessageKey(primary));
    CHECK(![secondaryRows containsObject:@"ucccccccccccccccccccccccccccccccc"] &&
          ![primaryRows containsObject:@"ucccccccccccccccccccccccccccccccc"],
          @"ambiguous P_/S_ callback was attributed to either scope");
    CHECK([store recordRanges:@[Range(@"0", @"9", 0, 0)] inStore:secondary[@"store"]
        kind:@"talk" chat:chatID reader:@"secondary-only"] &&
          [store recordRanges:@[Range(@"0", @"9", 0, 0)] inStore:primary[@"store"]
        kind:@"talk" chat:chatID reader:@"primary-only"], @"explicit dual-scope rows failed");
    secondaryRows = ReaderIDs(RUINReadUsersForMessageKey(secondary));
    primaryRows = ReaderIDs(RUINReadUsersForMessageKey(primary));
    CHECK([secondaryRows containsObject:@"secondary-only"] && ![secondaryRows containsObject:@"primary-only"] &&
          [primaryRows containsObject:@"primary-only"] && ![primaryRows containsObject:@"secondary-only"],
          @"explicit P_/S_ rows crossed the selected store scope");
    RUINHistoryHostCheckSetProfileMID(nil); RUINHistoryHostCheckConfigure(nil, NO);
}
static void CheckManagedKeys(NSURL *directory) {
    NSEntityDescription *chatEntity = [NSEntityDescription new];
    chatEntity.name = @"Chat"; chatEntity.managedObjectClassName = @"NSManagedObject";
    chatEntity.properties = @[Attribute(@"mid", NSStringAttributeType)];
    NSEntityDescription *userEntity = [NSEntityDescription new];
    userEntity.name = @"User"; userEntity.managedObjectClassName = @"NSManagedObject";
    userEntity.properties = @[Attribute(@"mid", NSStringAttributeType)];
    NSMutableArray *entities = [NSMutableArray arrayWithObjects:chatEntity, userEntity, nil];
    for (NSString *name in @[@"ManagedMessage", @"ManagedSquareMessage"]) {
        NSEntityDescription *entity = [NSEntityDescription new];
        entity.name = name; entity.managedObjectClassName = name;
        NSRelationshipDescription *chat = [NSRelationshipDescription new];
        chat.name = @"chat"; chat.destinationEntity = chatEntity; chat.minCount = 0; chat.maxCount = 1; chat.optional = YES;
        NSRelationshipDescription *sender = [NSRelationshipDescription new];
        sender.name = @"sender"; sender.destinationEntity = userEntity; sender.minCount = 0; sender.maxCount = 1; sender.optional = YES;
        entity.properties = @[Attribute(@"id", NSStringAttributeType), chat, sender];
        [entities addObject:entity];
    }
    NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = entities;
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = coordinator;
    @try {
        NSError *error = nil;
        NSPersistentStore *one = [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
            URL:[directory URLByAppendingPathComponent:@"model-one.sqlite"] options:nil error:&error];
        NSPersistentStore *two = [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
            URL:[directory URLByAppendingPathComponent:@"model-two.sqlite"] options:nil error:&error];
        CHECK(one && two, @"native Core Data fixture stores failed");
        __block NSManagedObject *first, *second, *square, *firstChat, *firstSender, *wrongScope;
        __block BOOL saved = NO;
        [context performBlockAndWait:^{
            for (NSUInteger i = 0; i < 2; i++) {
                NSPersistentStore *destination = i == 0 ? one : two;
                NSManagedObject *chat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context];
                [chat setValue:@"same-chat" forKey:@"mid"];
                [context assignObject:chat toPersistentStore:destination];
                NSManagedObject *sender = [NSEntityDescription insertNewObjectForEntityForName:@"User" inManagedObjectContext:context];
                [sender setValue:[NSString stringWithFormat:@"author-%lu", (unsigned long)i] forKey:@"mid"];
                [context assignObject:sender toPersistentStore:destination];
                NSManagedObject *message = [NSEntityDescription insertNewObjectForEntityForName:@"ManagedMessage" inManagedObjectContext:context];
                [message setValue:@"9007199254740993" forKey:@"id"]; [message setValue:chat forKey:@"chat"];
                [message setValue:sender forKey:@"sender"];
                [context assignObject:message toPersistentStore:destination];
                if (i == 0) { first = message; firstChat = chat; firstSender = sender; } else second = message;
            }
            square = [NSEntityDescription insertNewObjectForEntityForName:@"ManagedSquareMessage" inManagedObjectContext:context];
            [square setValue:@"9007199254740993" forKey:@"id"]; [square setValue:firstChat forKey:@"chat"];
            [square setValue:firstSender forKey:@"sender"];
            [context assignObject:square toPersistentStore:one];
            wrongScope = [NSEntityDescription insertNewObjectForEntityForName:@"ManagedMessage" inManagedObjectContext:context];
            [wrongScope setValue:@"9007199254740994" forKey:@"id"]; [wrongScope setValue:firstChat forKey:@"chat"];
            ((ManagedMessage *)wrongScope).isSendMessage = YES;
            [context assignObject:wrongScope toPersistentStore:one];
            saved = [context save:NULL];
        }];
        CHECK(saved, @"native Core Data fixture save failed");
        NSDictionary *firstKey = RUINHistoryMessageKey(first), *secondKey = RUINHistoryMessageKey(second);
        CHECK(firstKey.count == 5 && [firstKey[@"kind"] isEqual:@"talk"] &&
              [firstKey[@"chat"] isEqual:@"same-chat"] && [firstKey[@"message"] isEqual:@"9007199254740993"] &&
              [firstKey[@"sender"] isEqual:@"author-0"], @"native message-key extraction lost identity, sender or precision");
        CHECK(secondKey.count == 5 && [secondKey[@"sender"] isEqual:@"author-1"] &&
              ![firstKey[@"store"] isEqual:secondKey[@"store"]], @"two native stores shared a namespace or sender");
        NSDictionary *squareKey = RUINHistoryMessageKey(square);
        CHECK([squareKey[@"kind"] isEqual:@"square"] && [squareKey[@"sender"] isEqual:@"author-0"],
              @"native square class or message sender was lost");
        RUINHistoryHostCheckSetProfileMID(@"uaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        CHECK(!RUINHistoryMessageKey(wrongScope)[@"sender"], @"unscoped store used the active profile as author");
        RUINHistoryHostCheckSetProfileMID(nil);
        __block NSDictionary *nestedKey, *temporaryKey;
        [context performBlockAndWait:^{
            nestedKey = RUINHistoryMessageKey(first);
            NSManagedObject *temporary = [NSEntityDescription insertNewObjectForEntityForName:@"ManagedMessage" inManagedObjectContext:context];
            [temporary setValue:@"1" forKey:@"id"]; [temporary setValue:firstChat forKey:@"chat"];
            temporaryKey = RUINHistoryMessageKey(temporary);
            [context deleteObject:temporary];
            unichar characters[] = {'1', 0, '2'};
            [first setValue:[NSString stringWithCharacters:characters length:3] forKey:@"id"];
        }];
        CHECK([nestedKey isEqual:firstKey] && temporaryKey.count == 0, @"reentrant owning-queue lookup or temporary-ID rejection failed");
        CHECK(RUINHistoryMessageKey(first).count == 0 && RUINHistoryMessageKey(firstChat).count == 0,
              @"native helper accepted an embedded-NUL ID or non-message entity");
    } @finally {
        RUINHistoryHostCheckSetProfileMID(nil);
        [context performBlockAndWait:^{ [context reset]; }];
        for (NSPersistentStore *persistent in coordinator.persistentStores) [coordinator removePersistentStore:persistent error:NULL];
    }
}

int main(void) {
    @autoreleasepool {
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"ruin-history-check-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
        NSURL *url = [directory URLByAppendingPathComponent:@"history.sqlite"];
        __strong RUINHistoryStore *store = nil;
        int result = 0;
        @try {
            NSError *error = nil;
            store = [[RUINHistoryStore alloc] initWithURL:url error:&error];
            CHECK(store && !error, @"could not create fixture history store");
            unichar bodyCharacters[] = {'A', 0, 'B'};
            NSString *body = [NSString stringWithCharacters:bodyCharacters length:3];
            CHECK([store saveSnapshot:Snapshot(@"s1", @"talk", @"c1", @"42", body)], @"embedded-NUL text save failed");
            NSDictionary *saved = [store snapshotInStore:@"s1" kind:@"talk" chat:@"c1" message:@"42"];
            CHECK([saved[@"body"] isEqualToString:body] && [saved[@"body"] length] == 3, @"embedded-NUL text was truncated");
            CHECK([saved[@"timestamp"] longLongValue] == LLONG_MAX - 7, @"64-bit timestamp was rounded");

            CHECK([store saveSnapshot:Snapshot(@"s2", @"talk", @"c1", @"42", @"other store")], @"store isolation fixture failed");
            CHECK([store saveSnapshot:Snapshot(@"s1", @"square", @"c1", @"42", @"other kind")], @"kind isolation fixture failed");
            CHECK([store saveSnapshot:Snapshot(@"s1", @"talk", @"c2", @"42", @"other chat")], @"chat isolation fixture failed");
            CHECK([[store snapshotInStore:@"s2" kind:@"talk" chat:@"c1" message:@"42"][@"body"] isEqual:@"other store"], @"snapshot stores collided");
            CHECK([[store snapshotInStore:@"s1" kind:@"square" chat:@"c1" message:@"42"][@"body"] isEqual:@"other kind"], @"snapshot kinds collided");
            CHECK([[store snapshotInStore:@"s1" kind:@"talk" chat:@"c2" message:@"42"][@"body"] isEqual:@"other chat"], @"snapshot chats collided");
            CHECK([store markUnsentInStore:@"s1" kind:@"talk" chat:@"c1" message:@"00042"], @"canonical ID did not mark original snapshot");
            NSMutableDictionary *replacement = [Snapshot(@"s1", @"talk", @"c1", @"42", @"replacement") mutableCopy];
            replacement[@"sender"] = @"different"; replacement[@"timestamp"] = @1; replacement[@"contentType"] = @2;
            CHECK([store saveSnapshot:replacement], @"frozen snapshot save was not accepted as a no-op");
            CHECK([[store snapshotInStore:@"s1" kind:@"talk" chat:@"c1" message:@"42"][@"body"] isEqual:body], @"unsent original was overwritten");
            NSDictionary *frozen = [store snapshotInStore:@"s1" kind:@"talk" chat:@"c1" message:@"42"];
            CHECK([frozen[@"sender"] isEqual:@"sender"] && [frozen[@"timestamp"] longLongValue] == LLONG_MAX - 7 &&
                  [frozen[@"contentType"] integerValue] == 1, @"unsent metadata was overwritten");
            CHECK([[store snapshotInStore:@"s1" kind:@"talk" chat:@"c1" message:@"42"][@"unsent"] boolValue], @"unsent marker was lost");
            CHECK(![store markUnsentInStore:@"s1" kind:@"talk" chat:@"c1" message:@"999"], @"missing snapshot reported as marked");

            NSArray *largeIDs = @[@"9007199254740992", @"9007199254740993", @"9223372036854775806", @"9223372036854775807"];
            for (NSString *message in largeIDs) {
                CHECK([store saveSnapshot:Snapshot(@"s1", @"talk", @"large", message, message)], @"large message ID save failed");
                CHECK([[store snapshotInStore:@"s1" kind:@"talk" chat:@"large" message:message][@"body"] isEqual:message], @"large message IDs collided or rounded");
            }
            unichar badCharacters[] = {'1', '2', 0, '3'};
            NSString *nulID = [NSString stringWithCharacters:badCharacters length:4];
            NSArray *invalid = @[@"", @"0", @"-1", @"+1", @" 1", @"1 ", @"1.0", @"1e3", @"１２", nulID,
                @"9223372036854775808", @"999999999999999999999999999999999999", @1];
            NSUInteger snapshotCount = [store.counts[@"snapshots"] unsignedIntegerValue];
            for (id message in invalid) {
                CHECK(![store saveSnapshot:Snapshot(@"s1", @"talk", @"invalid", message, @"bad")], @"malformed or overflowing ID was saved");
                CHECK(![store markUnsentInStore:@"s1" kind:@"talk" chat:@"c1" message:message], @"malformed ID was accepted for mark");
                CHECK(![store snapshotInStore:@"s1" kind:@"talk" chat:@"c1" message:message], @"malformed ID was accepted for lookup");
                CHECK([store readersInStore:@"s1" chat:@"c1" message:message].count == 0, @"malformed ID was accepted for reader lookup");
                CHECK(![store recordRanges:@[Range(@"1", message, 0, 0)] inStore:@"s1" chat:@"invalid" reader:@"r"], @"malformed range end was accepted");
                if (![message isEqual:@"0"])
                    CHECK(![store recordRanges:@[Range(message, @"100", 0, 0)] inStore:@"s1" chat:@"invalid" reader:@"r"], @"malformed range start was accepted");
            }
            CHECK([store.counts[@"snapshots"] unsignedIntegerValue] == snapshotCount, @"rejected ID inserted a snapshot");
            CHECK([store saveSnapshot:Snapshot(@"s1", @"talk", @"canonical", @"0007", @"canonical")], @"leading-zero ID was not canonicalized");
            CHECK([[store snapshotInStore:@"s1" kind:@"talk" chat:@"canonical" message:@"7"][@"body"] isEqual:@"canonical"], @"canonical lookup failed");

            CHECK([store recordRanges:@[Range(@"10", @"20", 100, 200)] inStore:@"s1" chat:@"bounds" reader:@"r"], @"range insert failed");
            CHECK([store readersInStore:@"s1" chat:@"bounds" message:@"9"].count == 0, @"range included before start");
            CHECK([store readersInStore:@"s1" chat:@"bounds" message:@"10"].count == 0, @"exclusive range start was included");
            CHECK([store readersInStore:@"s1" chat:@"bounds" message:@"11"].count == 1, @"range omitted a message after its start");
            CHECK([store readersInStore:@"s1" chat:@"bounds" message:@"20"].count == 1, @"inclusive adapter end excluded");
            CHECK([store readersInStore:@"s1" chat:@"bounds" message:@"21"].count == 0, @"range included after end");
            CHECK([store recordRanges:@[Range(@"0", @"5", 1, 2)] inStore:@"s1" chat:@"zero" reader:@"z"], @"zero lower boundary rejected");
            CHECK([store readersInStore:@"s1" chat:@"zero" message:@"1"].count == 1 &&
                  [store readersInStore:@"s1" chat:@"zero" message:@"5"].count == 1, @"zero-boundary positive message lookup failed");
            CHECK([store readersInStore:@"s1" chat:@"zero" message:@"0"].count == 0, @"message zero became valid");
            CHECK(![store recordRanges:@[Range(@"20", @"10", 0, 0)] inStore:@"s1" chat:@"bounds" reader:@"r"], @"reversed range accepted");
            CHECK(![store recordRanges:@[Range(@"20", @"20", 0, 0)] inStore:@"s1" chat:@"bounds" reader:@"r"], @"empty exclusive range accepted");
            CHECK([store recordRanges:@[Range(@"9007199254740992", @"9007199254740993", 1, LLONG_MAX)]
                inStore:@"s1" chat:@"precise" reader:@"large"], @"precise exclusive/inclusive boundary failed");
            CHECK([store readersInStore:@"s1" chat:@"precise" message:@"9007199254740992"].count == 0 &&
                  [store readersInStore:@"s1" chat:@"precise" message:@"9007199254740993"].count == 1, @"read-range IDs used floating point");
            CHECK([store recordRanges:@[Range(@"9223372036854775806", @"9223372036854775807", 0, 1)]
                inStore:@"s1" chat:@"max" reader:@"max"], @"Int64 maximum boundary failed");

            long long rangesBeforeDuplicate = [store.counts[@"read_ranges"] longLongValue];
            CHECK([store recordRanges:@[Range(@"10", @"20", 50, 300), Range(@"10", @"20", 80, 250)]
                inStore:@"s1" chat:@"bounds" reader:@"r"], @"duplicate range update failed");
            CHECK([store.counts[@"read_ranges"] longLongValue] == rangesBeforeDuplicate, @"duplicate range created rows");
            CHECK(Scalar(url, "SELECT start_ms FROM read_ranges WHERE chat='bounds'") == 50 &&
                  Scalar(url, "SELECT end_ms FROM read_ranges WHERE chat='bounds'") == 200, @"later duplicate overwrote earliest range time");
            CHECK([store recordRanges:@[Range(@"15", @"25", 70, 400)] inStore:@"s1" chat:@"bounds" reader:@"r"], @"overlap insert failed");
            CHECK([store readersInStore:@"s1" chat:@"bounds" message:@"20"].count == 1 &&
                  [[store readersInStore:@"s1" chat:@"bounds" message:@"20"].firstObject[@"readAtMilliseconds"] longLongValue] == 200,
                  @"later cursor overwrote an earlier message read time");
            CHECK([store recordRanges:@[Range(@"10", @"20", 0, 0)] inStore:@"s1" chat:@"bounds" reader:@"r"] &&
                  [[store readersInStore:@"s1" chat:@"bounds" message:@"20"].firstObject[@"readAtMilliseconds"] longLongValue] == 200,
                  @"unknown duplicate erased known read time");
            SQL(url, "UPDATE read_ranges SET read_at_ms=999 WHERE chat='bounds' AND end_id=20;");
            CHECK(Scalar(url, "SELECT read_at_ms FROM read_ranges WHERE chat='bounds' AND end_id=20") == 200,
                  @"database allowed a later timestamp overwrite");
            SQL(url, "UPDATE read_ranges SET read_at_ms=0 WHERE chat='bounds' AND end_id=20;");
            CHECK(Scalar(url, "SELECT read_at_ms FROM read_ranges WHERE chat='bounds' AND end_id=20") == 200,
                  @"database allowed known timestamp erasure");
            CHECK([store recordRanges:@[Range(@"10", @"20", 50, 150)] inStore:@"s1" chat:@"bounds" reader:@"r"] &&
                  [[store readersInStore:@"s1" chat:@"bounds" message:@"20"].firstObject[@"readAtMilliseconds"] longLongValue] == 150,
                  @"earlier reliable time could not refine the record");
            NSDictionary *observation = @{@"start":@"0", @"end":@"9", @"startTime":@0, @"endTime":@0,
                @"observedAt":@1700000000000, @"timeSource":@"observed"};
            CHECK([store recordObservedRangesByReader:@{@"reader":@[observation]} kind:@"talk" chat:@"time-provenance"] &&
                  [store bindStore:@"s1" kind:@"talk" chat:@"time-provenance"], @"observation fixture failed");
            NSMutableDictionary *laterObservation = [observation mutableCopy]; laterObservation[@"observedAt"] = @1700000009000;
            CHECK([store recordObservedRangesByReader:@{@"reader":@[laterObservation]} kind:@"talk" chat:@"time-provenance"], @"duplicate observation failed");
            NSDictionary *timeRow = [store readersInStore:@"s1" chat:@"time-provenance" message:@"7"].firstObject;
            CHECK([timeRow[@"readAtMilliseconds"] longLongValue] == 0 &&
                  [timeRow[@"observedAtMilliseconds"] longLongValue] == 1700000000000 && [timeRow[@"timeSource"] isEqual:@"observed"],
                  @"local observation moved or was fabricated into server read time");
            NSDictionary *eventTime = @{@"start":@"0", @"end":@"9", @"startTime":@1700000001000,
                @"endTime":@1700000001000, @"observedAt":@1700000002000, @"timeSource":@"server_event"};
            CHECK([store recordObservedRangesByReader:@{@"reader":@[eventTime]} kind:@"talk" chat:@"cursor-time"] &&
                  [store bindStore:@"s1" kind:@"talk" chat:@"cursor-time"], @"cursor time fixture failed");
            NSDictionary *exactTime = [store readersInStore:@"s1" chat:@"cursor-time" message:@"9"].firstObject;
            NSDictionary *inheritedTime = [store readersInStore:@"s1" chat:@"cursor-time" message:@"7"].firstObject;
            CHECK([exactTime[@"readAtMilliseconds"] longLongValue] == 1700000001000 &&
                  [inheritedTime[@"readAtMilliseconds"] longLongValue] == 0 &&
                  [inheritedTime[@"timeSource"] isEqual:@"observed"], @"cursor endpoint time was falsely assigned to an earlier message");
            NSMutableDictionary *laterCursor = [eventTime mutableCopy]; laterCursor[@"end"] = @"12";
            laterCursor[@"startTime"] = @1700000009000; laterCursor[@"endTime"] = @1700000009000;
            laterCursor[@"observedAt"] = @1700000010000;
            CHECK([store recordObservedRangesByReader:@{@"reader":@[laterCursor]} kind:@"talk" chat:@"cursor-time"], @"later cursor fixture failed");
            exactTime = [store readersInStore:@"s1" chat:@"cursor-time" message:@"9"].firstObject;
            CHECK([exactTime[@"readAtMilliseconds"] longLongValue] == 1700000001000,
                  @"later cursor advanced an earlier message's original read time");
            NSDictionary *widerSnapshot = @{ @"start":@"0", @"end":@"9", @"startTime":@1700000001000,
                @"endTime":@1700000001000, @"observedAt":@1700000003000, @"timeSource":@"range" };
            CHECK([store recordObservedRangesByReader:@{@"reader":@[widerSnapshot]} kind:@"talk" chat:@"cursor-time"],
                  @"range snapshot after exact event failed");
            exactTime = [store readersInStore:@"s1" chat:@"cursor-time" message:@"9"].firstObject;
            CHECK([exactTime[@"readAtMilliseconds"] longLongValue] == 1700000001000 &&
                  [exactTime[@"timeSource"] isEqual:@"server_event"],
                  @"a range snapshot downgraded the exact event date");
            NSMutableDictionary *lowerCursor = [eventTime mutableCopy]; lowerCursor[@"end"] = @"5";
            lowerCursor[@"startTime"] = @1700000020000; lowerCursor[@"endTime"] = @1700000020000;
            lowerCursor[@"observedAt"] = @1700000021000;
            CHECK([store recordObservedRangesByReader:@{@"reader":@[lowerCursor]} kind:@"talk" chat:@"cursor-time"], @"lower cursor fixture failed");
            NSDictionary *stillRead = [store readersInStore:@"s1" chat:@"cursor-time" message:@"7"].firstObject;
            CHECK(stillRead && [stillRead[@"readAtMilliseconds"] longLongValue] == 0 &&
                  [stillRead[@"observedAtMilliseconds"] longLongValue] == 1700000002000,
                  @"lower read-up cursor erased prior coverage or advanced its first observation");

            NSDictionary *firstWideRange = @{ @"start":@"0", @"end":@"100", @"startTime":@10000,
                @"endTime":@10000, @"observedAt":@10001, @"timeSource":@"range" };
            CHECK([store recordRanges:@[firstWideRange] inStore:@"s1" kind:@"talk" chat:@"cumulative-refresh" reader:@"reader"],
                  @"initial cumulative range failed");
            NSDictionary *firstCovered = [store readersInStore:@"s1" kind:@"talk" chat:@"cumulative-refresh" message:@"100"].firstObject;
            CHECK([firstCovered[@"readAtMilliseconds"] longLongValue] == 10000 &&
                  [firstCovered[@"observedAtMilliseconds"] longLongValue] == 10001,
                  @"initial cumulative range time was not established");
            NSDictionary *widerRange = @{ @"start":@"0", @"end":@"200", @"startTime":@11000,
                @"endTime":@11000, @"observedAt":@12000, @"timeSource":@"range" };
            CHECK([store recordRanges:@[widerRange] inStore:@"s1" kind:@"talk" chat:@"cumulative-refresh" reader:@"reader"],
                  @"wider cumulative range refresh failed");
            NSDictionary *oldCovered = [store readersInStore:@"s1" kind:@"talk" chat:@"cumulative-refresh" message:@"100"].firstObject;
            NSDictionary *newlyCovered = [store readersInStore:@"s1" kind:@"talk" chat:@"cumulative-refresh" message:@"200"].firstObject;
            CHECK([oldCovered[@"readAtMilliseconds"] longLongValue] == 10000 &&
                  [oldCovered[@"observedAtMilliseconds"] longLongValue] == 10001 &&
                  [newlyCovered[@"readAtMilliseconds"] longLongValue] == 11000 &&
                  [newlyCovered[@"observedAtMilliseconds"] longLongValue] == 12000,
                  @"wider refresh changed an established date or lost the new message date");

            NSDictionary *priorObservation = @{ @"start":@"0", @"end":@"100", @"startTime":@0,
                @"endTime":@0, @"observedAt":@10000, @"timeSource":@"observed" };
            CHECK([store recordRanges:@[priorObservation] inStore:@"s1" kind:@"talk" chat:@"observed-before-known" reader:@"reader"],
                  @"initial observation-only range failed");
            NSDictionary *unknownFirst = [store readersInStore:@"s1" kind:@"talk" chat:@"observed-before-known" message:@"100"].firstObject;
            CHECK([unknownFirst[@"readAtMilliseconds"] longLongValue] == 0 &&
                  [unknownFirst[@"observedAtMilliseconds"] longLongValue] == 10000,
                  @"observation-only read was assigned a server date");
            NSDictionary *knownRefresh = @{ @"start":@"0", @"end":@"200", @"startTime":@12000,
                @"endTime":@12000, @"observedAt":@13000, @"timeSource":@"range" };
            CHECK([store recordRanges:@[knownRefresh] inStore:@"s1" kind:@"talk" chat:@"observed-before-known" reader:@"reader"],
                  @"known cumulative refresh after observation failed");
            NSDictionary *stillUnknown = [store readersInStore:@"s1" kind:@"talk" chat:@"observed-before-known" message:@"100"].firstObject;
            NSDictionary *firstKnown = [store readersInStore:@"s1" kind:@"talk" chat:@"observed-before-known" message:@"200"].firstObject;
            CHECK([stillUnknown[@"readAtMilliseconds"] longLongValue] == 0 &&
                  [stillUnknown[@"observedAtMilliseconds"] longLongValue] == 10000 &&
                  [firstKnown[@"readAtMilliseconds"] longLongValue] == 12000,
                  @"a later cumulative timestamp replaced an earlier unknown observation");

            CHECK([store recordRanges:@[Range(@"0", @"200", 10000, 10000)]
                inStore:@"s1" kind:@"talk" chat:@"range-before-event" reader:@"reader"],
                  @"initial dated range before point event failed");
            CHECK([store bindStore:@"s1" kind:@"talk" chat:@"range-before-event"], @"point event binding failed");
            NSDictionary *laterPointEvent = @{ @"start":@"0", @"end":@"100", @"startTime":@11000,
                @"endTime":@11000, @"observedAt":@12000, @"timeSource":@"server_event" };
            CHECK([store recordObservedRangesByReader:@{@"reader":@[laterPointEvent]} kind:@"talk" chat:@"range-before-event"],
                  @"later point event failed");
            NSDictionary *firstEventQuery = [store readersInStore:@"s1" kind:@"talk" chat:@"range-before-event" message:@"100"].firstObject;
            CHECK([firstEventQuery[@"readAtMilliseconds"] longLongValue] == 10000 &&
                  [firstEventQuery[@"timeSource"] isEqual:@"range"],
                  @"a later exact event advanced the established range date");
            NSMutableDictionary *equalPointEvent = [laterPointEvent mutableCopy];
            equalPointEvent[@"startTime"] = @10000; equalPointEvent[@"endTime"] = @10000;
            CHECK([store recordObservedRangesByReader:@{@"reader":@[equalPointEvent]} kind:@"talk" chat:@"range-before-event"],
                  @"equal-time point event failed");
            NSDictionary *equalEventQuery = [store readersInStore:@"s1" kind:@"talk" chat:@"range-before-event" message:@"100"].firstObject;
            CHECK([equalEventQuery[@"readAtMilliseconds"] longLongValue] == 10000 &&
                  [equalEventQuery[@"timeSource"] isEqual:@"server_event"],
                  @"exact event did not win an equal earliest timestamp");

            CHECK([store recordRanges:@[Range(@"0", @"100", 10000, 10000)]
                inStore:@"s1" kind:@"talk" chat:@"gapped-cursor" reader:@"reader"], @"initial gapped cursor failed");
            NSDictionary *gappedFirst = [store readersInStore:@"s1" kind:@"talk" chat:@"gapped-cursor" message:@"50"].firstObject;
            CHECK([gappedFirst[@"readAtMilliseconds"] longLongValue] == 10000, @"first gapped cursor date missing");
            CHECK([store recordRanges:@[Range(@"150", @"200", 11000, 11000)]
                inStore:@"s1" kind:@"talk" chat:@"gapped-cursor" reader:@"reader"], @"wider gapped cursor failed");
            NSDictionary *gapMember = [store readersInStore:@"s1" kind:@"talk" chat:@"gapped-cursor" message:@"120"].firstObject;
            NSDictionary *keptFirst = [store readersInStore:@"s1" kind:@"talk" chat:@"gapped-cursor" message:@"50"].firstObject;
            NSDictionary *newlyCoveredGap = [store readersInStore:@"s1" kind:@"talk" chat:@"gapped-cursor" message:@"151"].firstObject;
            CHECK(gapMember && [gapMember[@"readAtMilliseconds"] longLongValue] == 0 &&
                  [gapMember[@"observedAtMilliseconds"] longLongValue] == 0 && [gapMember[@"timeSource"] isEqual:@"unknown"] &&
                  [store readersInStore:@"s1" kind:@"talk" chat:@"gapped-cursor" message:@"0"].count == 0 &&
                  [keptFirst[@"readAtMilliseconds"] longLongValue] == 10000 &&
                  [newlyCoveredGap[@"readAtMilliseconds"] longLongValue] == 11000,
                  @"monotonic reader membership fabricated a gap date or changed an established date");

            CHECK([store recordRanges:@[Range(@"1", @"9", 1, 2)] inStore:@"s1" kind:@"talk" chat:@"isolation" reader:@"talk"], @"talk range fixture failed");
            CHECK([store recordRanges:@[Range(@"1", @"9", 1, 2)] inStore:@"s1" kind:@"square" chat:@"isolation" reader:@"square"], @"square range fixture failed");
            CHECK([store recordRanges:@[Range(@"1", @"9", 1, 2)] inStore:@"s2" kind:@"talk" chat:@"isolation" reader:@"store2"], @"second-store range fixture failed");
            CHECK([store recordRanges:@[Range(@"1", @"9", 1, 2)] inStore:@"s1" kind:@"talk" chat:@"other" reader:@"other"], @"other-chat range fixture failed");
            CHECK([ReaderIDs([store readersInStore:@"s1" kind:@"talk" chat:@"isolation" message:@"5"]) isEqual:[NSSet setWithObject:@"talk"]], @"range namespace isolation failed");
            CHECK([ReaderIDs([store readersInStore:@"s1" kind:@"square" chat:@"isolation" message:@"5"]) isEqual:[NSSet setWithObject:@"square"]], @"range kind isolation failed");
            CHECK([ReaderIDs([store readersInStore:@"s2" kind:@"talk" chat:@"isolation" message:@"5"]) isEqual:[NSSet setWithObject:@"store2"]], @"range store isolation failed");

            long long beforeTransaction = [store.counts[@"read_ranges"] longLongValue];
            CHECK(![store recordRanges:@[Range(@"1", @"10", 0, 0), Range(@"21", @"20", 0, 0)]
                inStore:@"s1" chat:@"validation-tx" reader:@"r"], @"invalid batch accepted");
            CHECK([store.counts[@"read_ranges"] longLongValue] == beforeTransaction, @"validation failure partially wrote a batch");
            SQL(url, "CREATE TRIGGER fail_range BEFORE INSERT ON read_ranges WHEN NEW.chat='tx' AND NEW.end_id=20 BEGIN SELECT RAISE(ABORT,'fixture'); END;");
            CHECK(![store recordRanges:@[Range(@"1", @"10", 0, 0), Range(@"11", @"20", 0, 0)]
                inStore:@"s1" chat:@"tx" reader:@"r"], @"injected SQL failure was ignored");
            CHECK([store.counts[@"read_ranges"] longLongValue] == beforeTransaction &&
                  [store readersInStore:@"s1" chat:@"tx" message:@"5"].count == 0, @"SQL failure did not roll back first inserted range");
            SQL(url, "DROP TRIGGER fail_range;");
            CHECK([store recordRanges:@[Range(@"1", @"10", 0, 0), Range(@"11", @"20", 0, 0)]
                inStore:@"s1" chat:@"tx" reader:@"r"], @"connection was left inside failed transaction");

            CHECK([store recordObservedRangesByReader:@{@"pending":@[Range(@"0", @"10", 1, 2)]} kind:@"talk" chat:@"pending"], @"unbound range was not persisted");
            CHECK([store.counts[@"pendingReadRanges"] integerValue] == 1 &&
                  [store readersInStore:@"s1" chat:@"pending" message:@"5"].count == 0, @"unbound event was attributed");
            store = nil;
            store = [[RUINHistoryStore alloc] initWithURL:url error:&error];
            CHECK(store && [store.counts[@"pendingReadRanges"] integerValue] == 1, @"pending range did not survive reopen");
            oldCovered = [store readersInStore:@"s1" kind:@"talk" chat:@"cumulative-refresh" message:@"100"].firstObject;
            newlyCovered = [store readersInStore:@"s1" kind:@"talk" chat:@"cumulative-refresh" message:@"200"].firstObject;
            CHECK([oldCovered[@"readAtMilliseconds"] longLongValue] == 10000 &&
                  [oldCovered[@"observedAtMilliseconds"] longLongValue] == 10001 &&
                  [newlyCovered[@"readAtMilliseconds"] longLongValue] == 11000 &&
                  [newlyCovered[@"observedAtMilliseconds"] longLongValue] == 12000,
                  @"cumulative first-read dates did not survive database reopen");
            CHECK([[store snapshotInStore:@"s1" kind:@"talk" chat:@"c1" message:@"42"][@"body"] isEqual:body] &&
                  [[store snapshotInStore:@"s1" kind:@"talk" chat:@"c1" message:@"42"][@"unsent"] boolValue], @"snapshot content/unsent state did not survive reopen");
            CHECK([store bindStore:@"s1" kind:@"talk" chat:@"pending"] && [store bindStore:@"s1" kind:@"talk" chat:@"pending"], @"binding or duplicate binding failed");
            CHECK([store readersInStore:@"s1" chat:@"pending" message:@"5"].count == 1 &&
                  [store readersInStore:@"s2" chat:@"pending" message:@"5"].count == 0 &&
                  [store readersInStore:@"s1" kind:@"square" chat:@"pending" message:@"5"].count == 0, @"unique binding lost isolation");
            long long observedBeforeDuplicate = [store.counts[@"observed_ranges"] longLongValue];
            CHECK([store recordObservedRangesByReader:@{@"pending":@[Range(@"0", @"10", 0, 9)]} kind:@"talk" chat:@"pending"], @"observed duplicate failed");
            CHECK([store.counts[@"observed_ranges"] longLongValue] == observedBeforeDuplicate &&
                  [[store readersInStore:@"s1" chat:@"pending" message:@"5"].firstObject[@"readAtMilliseconds"] longLongValue] == 2, @"observed duplicate replaced earliest known time");
            store = nil;
            store = [[RUINHistoryStore alloc] initWithURL:url error:&error];
            CHECK(store && [store readersInStore:@"s1" chat:@"pending" message:@"5"].count == 1, @"binding did not survive reopen");
            NSDictionary *reopenedTime = [store readersInStore:@"s1" chat:@"time-provenance" message:@"7"].firstObject;
            CHECK([reopenedTime[@"observedAtMilliseconds"] longLongValue] == 1700000000000 &&
                  [reopenedTime[@"readAtMilliseconds"] longLongValue] == 0, @"reopen changed first observation or fabricated a read time");
            CHECK([store bindStore:@"s2" kind:@"talk" chat:@"pending"], @"second binding failed");
            CHECK([store.counts[@"ambiguousReadRanges"] integerValue] == 1 &&
                  [store readersInStore:@"s1" chat:@"pending" message:@"5"].count == 0 &&
                  [store readersInStore:@"s2" chat:@"pending" message:@"5"].count == 0, @"multiple stores retained guessed event attribution");
            CHECK([store recordRanges:@[Range(@"1", @"9", 0, 10)] inStore:@"s1" chat:@"pending" reader:@"explicit"], @"explicit range failed for ambiguous chat");
            CHECK([ReaderIDs([store readersInStore:@"s1" chat:@"pending" message:@"5"]) isEqual:[NSSet setWithObject:@"explicit"]], @"ambiguous event leaked beside explicit data");
            CHECK([store bindStore:@"s1" kind:@"square" chat:@"pending"] &&
                  [store recordObservedRangesByReader:@{@"square":@[Range(@"1", @"9", 1, 2)]} kind:@"square" chat:@"pending"], @"independent kind binding failed");
            CHECK([ReaderIDs([store readersInStore:@"s1" kind:@"square" chat:@"pending" message:@"5"]) isEqual:[NSSet setWithObject:@"square"]], @"talk ambiguity corrupted square binding");
            long long observations = [store.counts[@"observed_ranges"] longLongValue];
            CHECK(![store recordObservedRangesByReader:@{@"ok":@[Range(@"1", @"2", 0, 0)], @"bad":@[Range(@"2", nulID, 0, 0)]}
                kind:@"talk" chat:@"batch"], @"malformed multi-reader batch accepted");
            CHECK([store.counts[@"observed_ranges"] longLongValue] == observations, @"malformed event partially committed readers");

            pthread_t threads[4]; Worker workers[4]; atomic_bool failed = ATOMIC_VAR_INIT(false);
            NSUInteger created = 0;
            for (; created < 4; created++) {
                workers[created] = (Worker){store, created, &failed};
                if (pthread_create(&threads[created], NULL, WriteWorker, &workers[created])) break;
            }
            for (NSUInteger i = 0; i < created; i++) pthread_join(threads[i], NULL);
            CHECK(created == 4 && !atomic_load(&failed), @"concurrent real-store writes failed");
            CHECK(Scalar(url, "SELECT COUNT(*) FROM snapshots WHERE store='threads'") == 96 &&
                  Scalar(url, "SELECT COUNT(*) FROM read_ranges WHERE store='threads'") == 96, @"concurrent writes were lost");
            CheckReadRanges(store);
            CheckNativePositions(directory, store, @"S_");
            CheckNativePositions(directory, store, @"P_");
            store = nil;
            store = [[RUINHistoryStore alloc] initWithURL:url error:&error];
            CHECK(store && [store.counts[@"ambiguousReadRanges"] integerValue] == 1 &&
                  [ReaderIDs([store readersInStore:@"s1" chat:@"pending" message:@"5"]) isEqual:[NSSet setWithObject:@"explicit"]], @"reopen forgot ambiguity");
            CheckOldSecondaryCallbackAndDualScope(directory, store);

            long long snapshotsBeforeClear = [store.counts[@"snapshots"] longLongValue];
            SQL(url, "CREATE TRIGGER fail_clear BEFORE DELETE ON read_ranges WHEN OLD.chat='tx' BEGIN SELECT RAISE(ABORT,'fixture'); END;");
            CHECK(![store removeAll] && [store.counts[@"snapshots"] longLongValue] == snapshotsBeforeClear, @"clear failure was not atomic");
            SQL(url, "DROP TRIGGER fail_clear;");
            CHECK([store removeAll], @"clear failed");
            for (NSString *key in @[@"snapshots", @"read_ranges", @"observed_ranges", @"chat_store_bindings"])
                CHECK([store.counts[key] integerValue] == 0, @"clear retained rows or bindings");
            store = nil;
            store = [[RUINHistoryStore alloc] initWithURL:url error:&error];
            CHECK(store && [store.counts[@"snapshots"] integerValue] == 0 && [store.counts[@"chat_store_bindings"] integerValue] == 0, @"clear did not persist");

            NSURL *legacyURL = [directory URLByAppendingPathComponent:@"legacy.sqlite"];
            SQL(legacyURL, "CREATE TABLE read_ranges(store TEXT,chat TEXT,reader TEXT,start_id INTEGER,end_id INTEGER,start_ms INTEGER,end_ms INTEGER,PRIMARY KEY(store,chat,reader,start_id,end_id));INSERT INTO read_ranges VALUES('legacy','chat','reader',1,9,10,20);");
            RUINHistoryStore *legacy = [[RUINHistoryStore alloc] initWithURL:legacyURL error:&error];
            CHECK(legacy && [legacy readersInStore:@"legacy" kind:@"talk" chat:@"chat" message:@"5"].count == 1 &&
                  [legacy readersInStore:@"legacy" kind:@"square" chat:@"chat" message:@"5"].count == 0, @"legacy talk-range migration lost isolation");
            CheckManagedKeys(directory);
            CHECK(![RUINMessageHistoryDiagnostics()[@"unsendRenderingImplemented"] boolValue], @"diagnostics claimed unsend rendering");
            legacy = nil;
        } @catch (NSException *exception) {
            fprintf(stderr, "RUIN history check failed: %s\n", exception.reason.UTF8String ?: "unknown error");
            result = 1;
        } @finally {
            store = nil;
            [NSFileManager.defaultManager removeItemAtURL:directory error:NULL];
        }
        if (!result) puts("RUIN History host checks passed");
        return result;
    }
}
