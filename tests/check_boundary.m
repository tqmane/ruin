#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import "Features.h"
#import "ReadBoundary.h"
#import "MessagingMappings.h"
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

// Multiple native overrides must retain separate originals when a Logos entry
// is bound to runtime-created Core Data subclasses. Also exercise an original
// that calls a different receiver before returning through its own superclass.
static NSUInteger chainBaseCalls, chainACalls, chainBCalls;
static NSUInteger chainWrapperCalls;
static IMP chainWrapperOriginal;
static __weak ManagedChat *chainNestedReceiver;
static long long chainNestedResult;
static long long ChainExternalWrapper(id object, SEL selector) {
    chainWrapperCalls++;
    return ((long long (*)(id, SEL))chainWrapperOriginal)(object, selector) + 3;
}
@interface RUINBoundaryChainBase : ManagedChat @end
@implementation RUINBoundaryChainBase
- (int64_t)readUpToMessageIDSynced {
    chainBaseCalls++;
    [self willAccessValueForKey:@"readUpToMessageIDSynced"];
    @try { return [[self primitiveValueForKey:@"readUpToMessageIDSynced"] longLongValue]; }
    @finally { [self didAccessValueForKey:@"readUpToMessageIDSynced"]; }
}
@end
@interface RUINBoundaryChainA : RUINBoundaryChainBase @end
@implementation RUINBoundaryChainA
- (int64_t)readUpToMessageIDSynced {
    chainACalls++;
    if (chainNestedReceiver) {
        ManagedChat *nested = chainNestedReceiver;
        chainNestedReceiver = nil;
        chainNestedResult = nested.readUpToMessageIDSynced;
    }
    return [super readUpToMessageIDSynced] + 1;
}
@end
@interface RUINBoundaryChainB : RUINBoundaryChainBase @end
@implementation RUINBoundaryChainB
- (int64_t)readUpToMessageIDSynced {
    chainBCalls++;
    return [super readUpToMessageIDSynced] + 2;
}
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
static void CheckVersionMappings(void) {
    NSDictionary *info16 = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
    NSDictionary *info17 = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"};
    NSDictionary *unknown = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.99.0", @"CFBundleVersion":@"unknown"};
    const RUINMessagingMapping *map16 = RUINMessagingMappingForInfo(info16);
    const RUINMessagingMapping *map17 = RUINMessagingMappingForInfo(info17);
    Require(map16 && map16->readBoundary.anchorCount == 1 && map16->readBoundary.callerReturnAddress,
        @"26.16 read boundary mapping was not preserved");
    Require(map17 && map17->readBoundary.anchorCount == 1 && map17->readBoundary.callerReturnAddress &&
        map17->readBoundary.callerReturnAddress != map16->readBoundary.callerReturnAddress,
        @"26.17 read boundary mapping was not resolved independently");
    Require(!RUINMessagingMappingForInfo(unknown), @"unknown host acquired a numeric read mapping");
}
static NSEntityDescription *ChatEntity(NSString *name, NSString *className) {
    NSEntityDescription *entity = [NSEntityDescription new];
    entity.name = name; entity.managedObjectClassName = className;
    entity.properties = @[Attribute(@"mid", NSStringAttributeType), Attribute(@"readUpToMessageID", NSInteger64AttributeType),
        Attribute(@"readUpToMessageIDSynced", NSInteger64AttributeType), Attribute(@"lastReceivedMessageID", NSInteger64AttributeType)];
    return entity;
}
static void CheckAccessorChains(NSManagedObjectContext *context, NSUserDefaults *defaults) {
    ManagedChat *a = [NSEntityDescription insertNewObjectForEntityForName:@"ChainA" inManagedObjectContext:context];
    ManagedChat *b = [NSEntityDescription insertNewObjectForEntityForName:@"ChainB" inManagedObjectContext:context];
    a.mid = @"chain-a"; a.readUpToMessageID = 50; a.lastReceivedMessageID = 50; a.readUpToMessageIDSynced = 10;
    b.mid = @"chain-b"; b.readUpToMessageID = 60; b.lastReceivedMessageID = 60; b.readUpToMessageIDSynced = 30;
    Require([context save:NULL], @"chain fixture save failed");
    RUINInstallReadBoundary();
    SEL getter = @selector(readUpToMessageIDSynced);
    IMP aEntry = class_getMethodImplementation(object_getClass(a), getter);
    IMP bEntry = class_getMethodImplementation(object_getClass(b), getter);
    RUINInstallReadBoundary();
    Require(aEntry == class_getMethodImplementation(object_getClass(a), getter) &&
        bEntry == class_getMethodImplementation(object_getClass(b), getter), @"repeated install wrapped a dynamic getter twice");
    chainACalls = chainBCalls = chainBaseCalls = 0;
    chainNestedReceiver = b;
    Require(a.readUpToMessageIDSynced == 11 && chainNestedResult == 32,
        @"dynamic subclasses shared an original or lost their superclass implementation");
    Require(chainACalls == 1 && chainBCalls == 1 && chainBaseCalls == 2,
        @"nested receiver or superclass original was skipped/reentered");
    [defaults setBool:YES forKey:RUINReadControlEnabledDefaultsKey]; RUINInstallFeatures();
    Require(a.readUpToMessageIDSynced == 50 && b.readUpToMessageIDSynced == 60,
        @"dynamic getter projection did not remain scoped to each receiver");
    RUINBoundaryTestNativeCaller(NO);
    Require(a.readUpToMessageIDSynced == 11 && b.readUpToMessageIDSynced == 32,
        @"unrelated consumers lost per-class native getter behavior");
    RUINBoundaryTestNativeCaller(YES);
    Require([[a primitiveValueForKey:@"readUpToMessageIDSynced"] longLongValue] == 10 &&
        [[b primitiveValueForKey:@"readUpToMessageIDSynced"] longLongValue] == 30,
        @"dynamic accessor projection changed persisted fields");
    [defaults setBool:NO forKey:RUINReadControlEnabledDefaultsKey]; RUINInstallFeatures();
    // Another swizzler keeps the old RUIN entry as its original. Retrying our
    // installer must neither overwrite that wrapper nor mutate the original
    // retained by the already-published RUIN entry.
    Method bMethod = class_getInstanceMethod(RUINBoundaryChainB.class, getter);
    chainWrapperOriginal = method_setImplementation(bMethod, (IMP)ChainExternalWrapper);
    @try {
        RUINInstallReadBoundary();
        Require(method_getImplementation(bMethod) == (IMP)ChainExternalWrapper &&
            [RUINReadBoundaryDiagnostics()[@"accessors"][@"RUINBoundaryChainB"] isEqual:@"accessor_changed_after_install"],
            @"retry replaced a later swizzler's accessor chain");
        chainBCalls = chainBaseCalls = chainWrapperCalls = 0;
        Require(b.readUpToMessageIDSynced == 35 && chainBCalls == 1 && chainBaseCalls == 1 && chainWrapperCalls == 1,
            @"retry changed the original retained by an existing RUIN entry");
    } @finally {
        method_setImplementation(bMethod, chainWrapperOriginal);
        RUINInstallReadBoundary();
    }
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
        CheckVersionMappings();
        [defaults setBool:NO forKey:RUINReadControlEnabledDefaultsKey];
        [defaults setBool:NO forKey:RUINMarkReadOnReplyDefaultsKey];
        [defaults setObject:@[] forKey:RUINReadExceptionsDefaultsKey];
        RUINInstallFeatures();
        if (early) RUINInstallReadBoundary();
        NSManagedObjectModel *model = [NSManagedObjectModel new];
        model.entities = @[ChatEntity(@"Chat", @"ManagedChat"), ChatEntity(@"ChainA", @"RUINBoundaryChainA"),
            ChatEntity(@"ChainB", @"RUINBoundaryChainB")];
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
        CheckAccessorChains(context, defaults);
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
