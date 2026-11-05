#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import "Features.h"
#import "ReadBoundary.h"
extern void RUINBoundaryTestNativeCaller(BOOL value);

@interface ManagedChat : NSManagedObject
@property(nonatomic, copy) NSString *mid;
@property(nonatomic) int64_t readUpToMessageID;
@property(nonatomic) int64_t readUpToMessageIDSynced;
@property(nonatomic) int64_t lastReceivedMessageID;
- (_Bool)canMarkChatAsReadToServer;
@end
@implementation ManagedChat
@dynamic mid, readUpToMessageID, readUpToMessageIDSynced, lastReceivedMessageID;
- (_Bool)canMarkChatAsReadToServer { return YES; }
@end

static IMP savedInfo;
static NSDictionary *Info(id self, SEL selector) {
    if (self != NSBundle.mainBundle) return ((id (*)(id, SEL))savedInfo)(self, selector);
    return @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
}
static NSAttributeDescription *Attribute(NSString *name, NSAttributeType type) {
    NSAttributeDescription *result = [NSAttributeDescription new];
    result.name = name; result.attributeType = type; result.optional = YES; return result;
}
static void Require(BOOL condition, NSString *reason) {
    if (!condition) @throw [NSException exceptionWithName:@"ReadBoundaryCheck" reason:reason userInfo:nil];
}
int main(int argc, const char **argv) { @autoreleasepool {
    BOOL early = argc > 1 && strcmp(argv[1], "early") == 0;
    Method infoMethod = class_getInstanceMethod(NSBundle.class, @selector(infoDictionary));
    savedInfo = method_setImplementation(infoMethod, (IMP)Info);
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *keys = @[RUINReadControlEnabledDefaultsKey, RUINReadExceptionsDefaultsKey, RUINMarkReadOnReplyDefaultsKey];
    NSMutableDictionary *old = [NSMutableDictionary dictionary];
    for (NSString *key in keys) old[key] = [defaults objectForKey:key] ?: NSNull.null;
    int status = 0;
    NSURL *fixture = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"ruin-boundary-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:fixture withIntermediateDirectories:YES attributes:nil error:NULL];
    @try {
        [defaults setBool:NO forKey:RUINReadControlEnabledDefaultsKey];
        [defaults setBool:NO forKey:RUINMarkReadOnReplyDefaultsKey];
        [defaults setObject:@[] forKey:RUINReadExceptionsDefaultsKey];
        RUINInstallFeatures();
        if (early) RUINInstallReadBoundary();
        NSEntityDescription *entity = [NSEntityDescription new];
        entity.name = @"Chat"; entity.managedObjectClassName = @"ManagedChat";
        entity.properties = @[Attribute(@"mid", NSStringAttributeType), Attribute(@"readUpToMessageID", NSInteger64AttributeType), Attribute(@"readUpToMessageIDSynced", NSInteger64AttributeType), Attribute(@"lastReceivedMessageID", NSInteger64AttributeType)];
        NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[entity];
        NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        NSURL *databaseURL = [fixture URLByAppendingPathComponent:@"fixture.sqlite"];
        NSPersistentStore *persistent = [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:databaseURL options:nil error:NULL];
        Require(persistent != nil, @"fixture store failed");
        NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        context.persistentStoreCoordinator = coordinator;
        ManagedChat *chat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context];
        chat.mid = @"test-peer"; chat.readUpToMessageID = 20; chat.readUpToMessageIDSynced = 10; chat.lastReceivedMessageID = 20;
        Require(chat.readUpToMessageIDSynced == 10, @"disabled getter changed native value");
        Require([context save:NULL], @"initial native save failed");
        if (!early) RUINInstallReadBoundary();
        [defaults setBool:YES forKey:RUINReadControlEnabledDefaultsKey]; RUINInstallFeatures();
        long long held = chat.readUpToMessageIDSynced;
        if (held != 20) NSLog(@"Boundary fixture debug: runtimeClass=%@ declared=%@ currentRead=%lld primitive=%@ encoding=%s diagnostics=%@", NSStringFromClass(object_getClass(chat)), NSStringFromClass(chat.class), chat.readUpToMessageID, [chat primitiveValueForKey:@"readUpToMessageIDSynced"], method_getTypeEncoding(class_getInstanceMethod(object_getClass(chat), @selector(readUpToMessageIDSynced))), RUINReadBoundaryDiagnostics());
        Require(held == 20, @"hidden getter did not hold pending boundary");
        Require([[chat primitiveValueForKey:@"readUpToMessageIDSynced"] longLongValue] == 10, @"primitive sync state was changed");
        RUINBoundaryTestNativeCaller(NO);
        Require(chat.readUpToMessageIDSynced == 10, @"unrelated consumer saw a synthetic boundary");
        chat.readUpToMessageIDSynced = MAX(chat.readUpToMessageIDSynced, 11);
        Require([context save:NULL] && [[chat primitiveValueForKey:@"readUpToMessageIDSynced"] longLongValue] == 11,
                @"native acknowledgement consumer persisted a synthetic boundary");
        chat.readUpToMessageIDSynced = 10;
        RUINBoundaryTestNativeCaller(YES);
        [defaults setObject:@[@"chat:test-peer"] forKey:RUINReadExceptionsDefaultsKey]; RUINInstallFeatures();
        Require(chat.readUpToMessageIDSynced == 10, @"exception did not restore original boundary");
        [defaults setObject:@[] forKey:RUINReadExceptionsDefaultsKey];
        [defaults setBool:YES forKey:RUINMarkReadOnReplyDefaultsKey]; RUINInstallFeatures();
        RUINAllowReadAfterUserReply(chat);
        Require(chat.readUpToMessageIDSynced == 10, @"reply allowance did not restore original boundary");
        chat.lastReceivedMessageID = 21;
        long long savedSynced = chat.readUpToMessageIDSynced;
        Require(savedSynced == 21 && chat.readUpToMessageID == 20,
                @"pre-advance synced read did not cover the newly received boundary");
        chat.readUpToMessageID = 21;
        Require(savedSynced >= chat.readUpToMessageID, @"native pre-read/advance comparison would admit a receipt");
        Require(chat.readUpToMessageIDSynced == 21, @"new incoming boundary was not held");
        Require([[chat primitiveValueForKey:@"readUpToMessageIDSynced"] longLongValue] == 10, @"primitive value changed after reply expiry");
        Require([context save:NULL], @"save while holding the public boundary failed");
        [context reset]; context = nil;
        Require([coordinator removePersistentStore:persistent error:NULL], @"close fixture store failed");
        coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        persistent = [coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:databaseURL options:nil error:NULL];
        Require(persistent != nil, @"reopen fixture store failed");
        context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        context.persistentStoreCoordinator = coordinator;
        chat = [[context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Chat"] error:NULL] firstObject];
        Require(chat.readUpToMessageIDSynced == 21, @"reopened getter lost the held boundary");
        Require([[chat primitiveValueForKey:@"readUpToMessageIDSynced"] longLongValue] == 10, @"saving persisted the synthetic sync value");
        [defaults setBool:NO forKey:RUINReadControlEnabledDefaultsKey]; RUINInstallFeatures();
        Require(chat.readUpToMessageIDSynced == 10, @"disable did not restore native value");
        [defaults setBool:YES forKey:RUINReadControlEnabledDefaultsKey];
        [defaults setBool:NO forKey:RUINMarkReadOnReplyDefaultsKey];
        [defaults setObject:@[] forKey:RUINReadExceptionsDefaultsKey]; RUINInstallFeatures();
        NSManagedObjectContext *fetchContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        fetchContext.persistentStoreCoordinator = coordinator;
        NSFetchRequest *pending = [NSFetchRequest fetchRequestWithEntityName:@"Chat"];
        pending.predicate = [NSPredicate predicateWithFormat:@"readUpToMessageIDSynced < readUpToMessageID"];
        Require([[fetchContext executeFetchRequest:pending error:NULL] count] == 0, @"pending receipt query leaked a suppressed chat");
        Require([RUINReadBoundaryDiagnostics()[@"pendingRowsSuppressed"] unsignedLongValue] > 0, @"pending-query filter did not exercise a native stored row");
        NSFetchRequest *ordinary = [NSFetchRequest fetchRequestWithEntityName:@"Chat"];
        Require([[fetchContext executeFetchRequest:ordinary error:NULL] count] == 1, @"ordinary UI fetch was changed");
        NSFetchRequest *mixed = [NSFetchRequest fetchRequestWithEntityName:@"Chat"];
        mixed.predicate = [NSCompoundPredicate orPredicateWithSubpredicates:@[pending.predicate, [NSPredicate predicateWithFormat:@"mid == %@", @"test-peer"]]];
        Require([[fetchContext executeFetchRequest:mixed error:NULL] count] == 1, @"unrelated OR branch was incorrectly filtered");
        [defaults setObject:@[@"chat:test-peer"] forKey:RUINReadExceptionsDefaultsKey]; RUINInstallFeatures();
        Require([[fetchContext executeFetchRequest:pending error:NULL] count] == 1, @"pending receipt query dropped an exempt chat");
        [defaults setObject:@[] forKey:RUINReadExceptionsDefaultsKey];
        [defaults setBool:NO forKey:RUINReadControlEnabledDefaultsKey]; RUINInstallFeatures();
        Require([[fetchContext executeFetchRequest:pending error:NULL] count] == 1, @"disabled filter changed pending receipt query");
        [fetchContext reset]; fetchContext = nil;
        [context reset]; context = nil;
        Require([coordinator removePersistentStore:persistent error:NULL], @"final fixture close failed");
        NSLog(@"Read-boundary checks passed (%@)", early ? @"before model creation" : @"after dynamic accessor creation");
    } @catch (NSException *exception) {
        fprintf(stderr, "Read-boundary check failed: %s\n", exception.reason.UTF8String); status = 1;
    } @finally {
        for (NSString *key in keys) { id value = old[key]; if (value == NSNull.null) [defaults removeObjectForKey:key]; else [defaults setObject:value forKey:key]; }
        method_setImplementation(infoMethod, savedInfo);
        [NSFileManager.defaultManager removeItemAtURL:fixture error:NULL];
    }
    return status;
}}
