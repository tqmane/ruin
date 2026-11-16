#!/usr/bin/env python3
"""Exercise the production display-only badge policy against a real Core Data store."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SHIM = r'''
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#include <assert.h>
static BOOL suppressRead = YES;
BOOL RUINShouldSuppressReadForChat(__unused id chat) { return suppressRead; }
@interface ManagedChat : NSManagedObject
@property(nonatomic, strong) NSNumber *unread;
@property(nonatomic, strong) NSNumber *enable;
@property(nonatomic, strong) NSNumber *type;
@end
@implementation ManagedChat
@dynamic unread, enable, type;
@end
@interface ManagedMessage : NSManagedObject
- (BOOL)shouldIncrementChatMessagesUnread;
- (BOOL)isReceivedMessage;
- (BOOL)isSendMessage;
@end
@implementation ManagedMessage
- (BOOL)shouldIncrementChatMessagesUnread { return [[self valueForKey:@"eligible"] boolValue]; }
- (BOOL)isReceivedMessage { return [[self valueForKey:@"received"] boolValue]; }
- (BOOL)isSendMessage { return [[self valueForKey:@"outgoing"] boolValue]; }
@end
'''
CHECK = r'''
static NSAttributeDescription *Attribute(NSString *name, NSAttributeType type) {
    NSAttributeDescription *value = [NSAttributeDescription new]; value.name = name;
    value.attributeType = type; value.optional = NO; value.defaultValue = @0; return value;
}
static NSManagedObject *Message(NSManagedObjectContext *context, NSManagedObject *chat, long long number, BOOL eligible) {
    NSManagedObject *message = [NSEntityDescription insertNewObjectForEntityForName:@"Message" inManagedObjectContext:context];
    [message setValue:@(number) forKey:@"id"]; [message setValue:@(eligible) forKey:@"eligible"];
    [message setValue:chat forKey:@"chat"];
    [message setValue:@YES forKey:@"received"];
    return message;
}
static void State(NSManagedObject *chat, NSInteger unread, long long received, long long cursor) {
    [chat setValue:@(unread) forKey:@"unread"];
    [chat setValue:@(received) forKey:@"lastReceivedMessageID"];
    [chat setValue:@(cursor) forKey:@"readUpToMessageID"];
    assert([chat.managedObjectContext save:NULL]);
}
static void CheckRestoredSnapshots(NSManagedObjectContext *context, NSString *account) {
    NSManagedObject *chat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context];
    [chat setValue:@YES forKey:@"enable"];
    for (long long number = 251; number <= 260; number++) Message(context, chat, number, YES);
    NSManagedObject *oldestViewed = nil;
    for (long long number = 301; number <= 303; number++) {
        NSManagedObject *message = Message(context, chat, number, YES);
        if (number == 301) oldestViewed = message;
    }
    State(chat, 3, 303, 0); // Thirteen received history rows; only A/B/C contribute to native unread.
    NSDictionary *viewed = ViewedSnapshot(chat);
    assert(ValidViewedMarker(viewed) && [viewed[@"nativeUnread"] integerValue] == 3);
    assert(BadgeCount(chat, viewed) == 0 && BadgeCount(chat, @303) == 0);
    assert(!ValidBoundary(@YES) && ValidBoundary(@(LLONG_MAX)) && !ValidBoundary(@(ULLONG_MAX)));
    assert(!ValidViewedMarker(@{@"boundary":@303}));
    assert(!ValidViewedMarker(@{@"boundary":@303,@"nativeUnread":@YES,@"readCursor":@0}));
    assert(!ValidViewedMarker(@{@"boundary":@303,@"nativeUnread":@(-1),@"readCursor":@0}));
    assert(!ValidViewedMarker(@{@"boundary":@303,@"nativeUnread":@3,@"readCursor":@0.5}));
    NSManagedObject *newest = Message(context, chat, 304, YES);
    State(chat, 4, 304, 0);
    assert(BadgeCount(chat, @303) == 4); // Never infer the missing baseline of a legacy scalar marker.
    assert([BadgeCountDiagnostics()[@"viewedUnread"] integerValue] == -1);
    assert(BadgeCount(chat, viewed) == 1 && !context.hasChanges);
    NSDictionary *decision = BadgeCountDiagnostics();
    assert([decision[@"reason"] isEqual:@"snapshot_delta"] && [decision[@"nativeDelta"] integerValue] == 1 &&
        [decision[@"eligibleNewTail"] integerValue] == 1 && [decision[@"viewedUnread"] integerValue] == 3);
    NSString *key = BadgeScope(chat, account);
    NSUInteger correction = BadgeCorrection(context, chat.objectID.persistentStore, account, @{key:viewed});
    assert(correction == 3 && 47 - correction == 44);
    NSData *saved = [NSPropertyListSerialization dataWithPropertyList:@{@"new":viewed,@"old":@303}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    NSDictionary *loaded = [NSPropertyListSerialization propertyListWithData:saved options:NSPropertyListImmutable format:NULL error:NULL];
    assert(ValidViewedMarker(loaded[@"new"]) && ValidViewedMarker(loaded[@"old"]));
    assert(BadgeCount(chat, loaded[@"new"]) == 1 && BadgeCount(chat, loaded[@"old"]) == 4);
    assert([loaded[@"old"] isKindOfClass:NSNumber.class]);
    assert(BadgeCount(chat, @{@"boundary":@303}) == 4); // A partial snapshot is not a legacy marker.

    State(chat, 5, 305, 0); // Newest server ID is absent locally.
    assert(BadgeCount(chat, viewed) == 5);
    assert([BadgeCountDiagnostics()[@"reason"] isEqual:@"snapshot_latest_missing"]);
    State(chat, 3, 304, 0); // D exists but the native count has not incremented (or an old unread was deleted).
    assert(BadgeCount(chat, viewed) == 3);
    assert([BadgeCountDiagnostics()[@"reason"] isEqual:@"snapshot_tail_delta_mismatch"]);
    [context deleteObject:oldestViewed]; State(chat, 3, 304, 0);
    assert(BadgeCount(chat, viewed) == 3); // A counted old unread was actually deleted while D arrived.
    assert([BadgeCountDiagnostics()[@"reason"] isEqual:@"snapshot_tail_delta_mismatch"]);
    Message(context, chat, 301, YES); State(chat, 4, 304, 0);
    State(chat, 2, 304, 0); // Native unread decreased independently of the viewed marker.
    assert(BadgeCount(chat, viewed) == 2);
    assert([BadgeCountDiagnostics()[@"reason"] isEqual:@"snapshot_native_decreased"]);
    State(chat, 4, 304, 250); // Changed cursor, restored extra rows still prevent an exact full-window proof.
    assert(BadgeCount(chat, viewed) == 4);
    assert([BadgeCountDiagnostics()[@"reason"] isEqual:@"snapshot_read_cursor_changed"]);
    State(chat, 4, 304, -1);
    assert(!ViewedSnapshot(chat) && BadgeCount(chat, viewed) == 4);
    assert([BadgeCountDiagnostics()[@"reason"] isEqual:@"invalid_live_cursor"]);
    State(chat, 4, 304, 300); // A native cursor change can use the old exact-window proof when it truly matches.
    assert(BadgeCount(chat, viewed) == 1);
    assert([BadgeCountDiagnostics()[@"reason"] isEqual:@"full_window_verified"]);

    State(chat, 3, 303, 303);
    NSDictionary *atCursor = ViewedSnapshot(chat);
    State(chat, 4, 304, 303);
    assert(BadgeCount(chat, atCursor) == 1); // Stable captured cursor, even when it equals the viewed boundary.
    assert(BadgeCount(chat, @303) == 4); // Preserve the legacy cursor guard.
    State(chat, 1, 304, 304); assert(BadgeCount(chat, atCursor) == 1);
    State(chat, 2, 303, 0); assert(BadgeCount(chat, viewed) == 0); // Same viewed boundary still clears.
    State(chat, 4, 302, 0); assert(BadgeCount(chat, viewed) == 4); // A rebased/future marker never hides a badge.

    [newest setValue:@NO forKey:@"eligible"]; State(chat, 3, 304, 0);
    assert(BadgeCount(chat, viewed) == 0); // A known non-incrementing incoming control row does not create unread.
    [newest setValue:@YES forKey:@"eligible"]; State(chat, 1004, 304, 0);
    assert(BadgeCount(chat, viewed) == 1004); // An unbounded delta stays native.
    State(chat, 2000, 303, 0); NSDictionary *large = ViewedSnapshot(chat);
    State(chat, 2001, 304, 0); assert(BadgeCount(chat, large) == 1); // Bound only the new tail, not restored old history.

    [context deleteObject:newest]; Message(context, chat, 305, YES); State(chat, 5, 305, 0);
    assert(BadgeCount(chat, viewed) == 5); // A missing intermediate new row fails the delta proof too.
    assert([BadgeCountDiagnostics()[@"reason"] isEqual:@"snapshot_tail_delta_mismatch"]);
    assert(!context.hasChanges && [[chat valueForKey:@"unread"] integerValue] == 5 &&
        [[chat valueForKey:@"readUpToMessageID"] longLongValue] == 0);
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    assert(argc == 2);
    NSEntityDescription *chatEntity = [NSEntityDescription new]; chatEntity.name = @"Chat";
    chatEntity.managedObjectClassName = @"ManagedChat";
    chatEntity.properties = @[Attribute(@"unread", NSInteger32AttributeType), Attribute(@"enable", NSBooleanAttributeType), Attribute(@"type", NSInteger16AttributeType),
        Attribute(@"lastReceivedMessageID", NSInteger64AttributeType), Attribute(@"readUpToMessageID", NSInteger64AttributeType)];
    NSEntityDescription *messageEntity = [NSEntityDescription new]; messageEntity.name = @"Message";
    messageEntity.managedObjectClassName = @"ManagedMessage";
    NSRelationshipDescription *relationship = [NSRelationshipDescription new]; relationship.name = @"chat";
    relationship.destinationEntity = chatEntity; relationship.minCount = 0; relationship.maxCount = 1;
    messageEntity.properties = @[Attribute(@"id", NSInteger64AttributeType), Attribute(@"eligible", NSBooleanAttributeType),
        Attribute(@"received", NSBooleanAttributeType), Attribute(@"outgoing", NSBooleanAttributeType), relationship];
    NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[chatEntity, messageEntity];
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSString *account = @"u0123456789abcdef0123456789abcdef";
    NSString *root = [NSString stringWithUTF8String:argv[1]];
    NSString *path = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"PrivateStore/P_%@/Messages/Line.sqlite", account]];
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    assert([coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:path] options:nil error:NULL]);
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    context.persistentStoreCoordinator = coordinator;
    NSManagedObject *chat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context];
    [chat setValue:@YES forKey:@"enable"];
    [chat setValue:@5 forKey:@"unread"]; [chat setValue:@100 forKey:@"lastReceivedMessageID"];
    [chat setValue:@50 forKey:@"readUpToMessageID"];
    for (long long number = 96; number <= 100; number++) Message(context, chat, number, YES);
    assert(!BadgeScope(chat, account)); // No persistent object identity yet.
    assert([context save:NULL] && BadgeSchema(chat));
    NSString *scope = BadgeScope(chat, account); assert(scope.length == 64);
    assert(!BadgeScope(chat, @"udifferentaccount"));
    assert(BadgeCount(chat, nil) == 5 && BadgeCount(chat, @100) == 0 && !context.hasChanges);
    assert(BadgeCount(chat, @101) == 5); // Rolled-back/foreign future boundary stays native.
    assert(!ValidBoundary(@0) && !ValidBoundary(@(-1)) && !ValidBoundary(@1.5) && !ValidBoundary(@"100"));
    NSManagedObject *sent = Message(context, chat, 75, YES);
    [sent setValue:@NO forKey:@"received"]; [sent setValue:@YES forKey:@"outgoing"];
    Message(context, chat, 101, YES); Message(context, chat, 102, NO); Message(context, chat, 103, YES);
    [chat setValue:@103 forKey:@"lastReceivedMessageID"]; [chat setValue:@7 forKey:@"unread"];
    assert([context save:NULL] && BadgeCount(chat, @100) == 2 && !context.hasChanges);
    assert(BadgeCount(chat, @103) == 0);
    NSFetchRequest *old = [NSFetchRequest fetchRequestWithEntityName:@"Message"];
    old.predicate = [NSPredicate predicateWithFormat:@"id < 100"];
    for (NSManagedObject *message in [context executeFetchRequest:old error:NULL]) [context deleteObject:message];
    [chat setValue:@3 forKey:@"unread"]; assert(BadgeCount(chat, @100) == 2); // Deleted older messages don't distort the new count.
    [chat setValue:@4 forKey:@"unread"]; assert(BadgeCount(chat, @100) == 4); // Latest exists but an intermediate message is missing.
    [chat setValue:@3 forKey:@"unread"];
    [chat setValue:@100 forKey:@"readUpToMessageID"]; assert(BadgeCount(chat, @100) == 3); // Native read caught up; stop projecting.
    [chat setValue:@50 forKey:@"readUpToMessageID"]; [chat setValue:@104 forKey:@"lastReceivedMessageID"];
    assert(BadgeCount(chat, @100) == 3); // Missing newest message never hides an unread badge.
    NSManagedObject *other = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context];
    [other setValue:@2 forKey:@"unread"]; [other setValue:@90 forKey:@"lastReceivedMessageID"];
    assert([context save:NULL] && ![BadgeScope(other, account) isEqual:scope]);
    assert(BadgeCount(other, nil) == 2 && !context.hasChanges);
    assert([[chat valueForKey:@"readUpToMessageID"] longLongValue] == 50);
    assert([[chat valueForKey:@"unread"] integerValue] == 3);
    // A/B were locally viewed; only C is new. Eligible sent/unknown/ambiguous
    // rows in the native cursor interval must not break the full-count proof.
    NSManagedObject *rebound = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context];
    [rebound setValue:@YES forKey:@"enable"]; [rebound setValue:@3 forKey:@"unread"];
    [rebound setValue:@190 forKey:@"readUpToMessageID"]; [rebound setValue:@203 forKey:@"lastReceivedMessageID"];
    for (long long number = 201; number <= 203; number++) Message(context, rebound, number, YES);
    for (long long number = 195; number <= 196; number++) {
        NSManagedObject *outgoing = Message(context, rebound, number, YES);
        [outgoing setValue:@NO forKey:@"received"]; [outgoing setValue:@YES forKey:@"outgoing"];
    }
    NSManagedObject *ambiguous = Message(context, rebound, 197, YES);
    [ambiguous setValue:@YES forKey:@"outgoing"];
    NSManagedObject *unknown = Message(context, rebound, 198, YES); [unknown setValue:@NO forKey:@"received"];
    Message(context, rebound, 0, YES); Message(context, rebound, 500, YES); // Outside the committed cursor interval.
    assert([context save:NULL]);
    assert(BadgeCount(rebound, @202) == 1 && !context.hasChanges);
    NSString *reboundScope = BadgeScope(rebound, account);
    NSUInteger correction = BadgeCorrection(context, coordinator.persistentStores.firstObject, account, @{reboundScope:@202});
    assert(correction == 2 && 39 - correction == 37);
    assert([[rebound valueForKey:@"unread"] integerValue] == 3);
    assert([[rebound valueForKey:@"readUpToMessageID"] longLongValue] == 190);
    NSDictionary *markers = @{scope:@104};
    assert(BadgeCorrection(context, coordinator.persistentStores.firstObject, account, markers) == 3);
    [chat setValue:@NO forKey:@"enable"];
    assert(BadgeCorrection(context, coordinator.persistentStores.firstObject, account, markers) == 0);
    [chat setValue:@YES forKey:@"enable"]; [chat setValue:@4 forKey:@"type"];
    assert(BadgeCorrection(context, coordinator.persistentStores.firstObject, account, markers) == 0);
    [chat setValue:@0 forKey:@"type"]; assert([context save:NULL]);
    assert(BadgeCorrection(context, coordinator.persistentStores.firstObject, @"other", markers) == 0);
    assert(BadgeCorrection(context, coordinator.persistentStores.firstObject, account, @{}) == 0);
    suppressRead = NO;
    assert(BadgeCorrection(context, coordinator.persistentStores.firstObject, account, markers) == 0);
    assert(!context.hasChanges); // Aggregate correction, too, is a pure read.
    suppressRead = YES;
    CheckRestoredSnapshots(context, account);
    NSString *secondaryPath = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"PrivateStore/S_%@/Messages/Line.sqlite", account]];
    [NSFileManager.defaultManager createDirectoryAtPath:secondaryPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    NSPersistentStore *secondary = [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:secondaryPath] options:nil error:NULL];
    assert(secondary);
    NSManagedObject *subChat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context];
    [context assignObject:subChat toPersistentStore:secondary];
    [subChat setValue:@YES forKey:@"enable"]; [subChat setValue:@2 forKey:@"unread"];
    [subChat setValue:@104 forKey:@"lastReceivedMessageID"]; assert([context save:NULL]);
    NSString *secondaryScope = BadgeScope(subChat, account);
    assert(secondaryScope.length == 64 && ![secondaryScope isEqual:scope]);
    assert(BadgeCorrection(context, secondary, account, markers) == 0);
    assert(BadgeCorrection(context, secondary, account, @{secondaryScope:@104}) == 2 && !context.hasChanges);
    puts("PASS unread snapshots: restored history delta, legacy persistence, cursor/deletion/missing-tail safety and zero native writes");
} return 0; }
'''


def main():
    source = (ROOT / "src/interface/LocalUnreadBadges.x").read_text()
    common = source.split("#if !defined(RUIN_LOCAL_UNREAD_HOST_CHECK)")[0].replace("%config(generator=internal);", "")
    with tempfile.TemporaryDirectory(prefix="ruin-unread-badges-") as folder:
        temporary = Path(folder)
        fixture = temporary / "check.m"
        fixture.write_text(SHIM + common + CHECK)
        executable = temporary / "check"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
            "-Wno-unused-const-variable", "-I", str(ROOT / "src/interface"), "-I", str(ROOT / "src/core"),
            str(fixture), "-framework", "Foundation", "-framework", "CoreData", "-o", str(executable)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(executable)], check=True, capture_output=True)
        subprocess.run([str(executable), str(temporary)], check=True)


if __name__ == "__main__":
    main()
