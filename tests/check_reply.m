#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import "Features.h"
#import "ReadOnReply.h"

@interface ManagedChat : NSManagedObject
@property(nonatomic, copy) NSString *mid;
@property(nonatomic) int64_t lastReceivedMessageID;
@end
@implementation ManagedChat
@dynamic mid, lastReceivedMessageID;
@end

static NSUInteger sends, successes, completions;
void RUINRefreshAutomaticReadGate(void) {}
@interface ReplyFixture : NSObject
@property(nonatomic, strong) ManagedChat *chatObject;
- (_Bool)isSendMessage;
- (void)sendWithCompletionHandler:(void (^)(void))completion;
- (void)addNotificationOfSentMessage;
@end
@implementation ReplyFixture
- (_Bool)isSendMessage { return YES; }
- (void)sendWithCompletionHandler:(void (^)(void))completion { sends++; if (completion) completion(); }
- (void)addNotificationOfSentMessage { successes++; }
@end
@interface ManagedMessage : ReplyFixture @end
@implementation ManagedMessage @end
@interface ManagedSquareMessage : ReplyFixture @end
@implementation ManagedSquareMessage @end

static NSDictionary *Info(id self, SEL command) {
    (void)self; (void)command;
    return @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
}
static void Require(BOOL value, NSString *reason) {
    if (!value) @throw [NSException exceptionWithName:@"ReplyCheck" reason:reason userInfo:nil];
}
int main(void) { @autoreleasepool {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *keys = @[RUINReadControlEnabledDefaultsKey, RUINMarkReadOnReplyDefaultsKey, RUINReadExceptionsDefaultsKey];
    NSMutableDictionary *old = [NSMutableDictionary dictionary];
    for (NSString *key in keys) old[key] = [defaults objectForKey:key] ?: NSNull.null;
    Method method = class_getInstanceMethod(NSBundle.class, @selector(infoDictionary));
    IMP originalInfo = method_setImplementation(method, (IMP)Info);
    int status = 0;
    @try {
        [defaults setBool:YES forKey:RUINReadControlEnabledDefaultsKey];
        [defaults setBool:YES forKey:RUINMarkReadOnReplyDefaultsKey];
        [defaults setObject:@[] forKey:RUINReadExceptionsDefaultsKey];
        NSEntityDescription *entity = [NSEntityDescription new];
        entity.name = @"Chat"; entity.managedObjectClassName = @"ManagedChat";
        NSAttributeDescription *mid = [NSAttributeDescription new]; mid.name = @"mid"; mid.attributeType = NSStringAttributeType;
        NSAttributeDescription *last = [NSAttributeDescription new]; last.name = @"lastReceivedMessageID"; last.attributeType = NSInteger64AttributeType;
        entity.properties = @[mid, last];
        NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[entity];
        NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        Require([coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:NULL] != nil, @"fixture store failed");
        NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        context.persistentStoreCoordinator = coordinator;
        RUINInstallFeatures(); RUINInstallReadOnReply();
        for (Class cls in @[ManagedMessage.class, ManagedSquareMessage.class]) {
            ManagedChat *chat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context];
            chat.mid = NSStringFromClass(cls); chat.lastReceivedMessageID = 100;
            ReplyFixture *message = [cls new]; message.chatObject = chat;
            Require(RUINShouldSuppressReadForChat(chat), @"initial boundary was not hidden");
            [message addNotificationOfSentMessage];
            Require(RUINShouldSuppressReadForChat(chat), @"history-only success notification granted a read allowance");
            [message sendWithCompletionHandler:^{ completions++; }];
            Require(!RUINShouldSuppressReadForChat(chat), @"actual send entry did not allow its current boundary");
            chat.lastReceivedMessageID = 101;
            Require(RUINShouldSuppressReadForChat(chat), @"new incoming boundary inherited the old allowance");
            [message addNotificationOfSentMessage];
            Require(RUINShouldSuppressReadForChat(chat), @"late send acknowledgement allowed a newer incoming boundary");
            [defaults setBool:NO forKey:RUINMarkReadOnReplyDefaultsKey];
            [message sendWithCompletionHandler:^{ completions++; }];
            Require(RUINShouldSuppressReadForChat(chat), @"disabled reply option granted an allowance");
            [defaults setBool:YES forKey:RUINMarkReadOnReplyDefaultsKey];
        }
        Require(sends == 4 && successes == 4 && completions == 4, @"native calls/completions were not forwarded exactly once");
        puts("Read-on-reply checks passed: send boundary, history/late notifications, disabled option, exact forwarding");
    } @catch (NSException *exception) {
        fprintf(stderr, "Read-on-reply check failed: %s\n", exception.reason.UTF8String); status = 1;
    } @finally {
        method_setImplementation(method, originalInfo);
        for (NSString *key in keys) { id value = old[key]; if (value == NSNull.null) [defaults removeObjectForKey:key]; else [defaults setObject:value forKey:key]; }
    }
    return status;
}}
