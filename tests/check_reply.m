#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import "Features.h"
#import "ReadOnReply.h"
#import "AutomaticReadGate.h"
// Extended fixture: compile this file with generated Features.m, ReadOnReply.m,
// AutomaticReadGate.m and RUIN_AUTOMATIC_READ_GATE_HOST_CHECK=1 (Foundation/CoreData).
#if defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
#import "SwiftFields.h"
#endif

@interface ManagedChat : NSManagedObject
@property(nonatomic, copy) NSString *mid;
@property(nonatomic) int64_t lastReceivedMessageID;
- (_Bool)canMarkChatAsReadToServer;
@end
@implementation ManagedChat
@dynamic mid, lastReceivedMessageID;
- (_Bool)canMarkChatAsReadToServer { return YES; }
@end
@interface ManagedSquareChat : ManagedChat @end
@implementation ManagedSquareChat @end

static void Require(BOOL value, NSString *reason) {
    if (!value) @throw [NSException exceptionWithName:@"ReplyCheck" reason:reason userInfo:nil];
}

#if defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
// These model only the Swift field access seam. Gate policy, lifecycle hooks,
// prior KVO and send correlation are the production implementations.
@interface RUINFixtureReadGate : NSObject
@property(nonatomic) BOOL enabled;
@end
@implementation RUINFixtureReadGate @end
@interface _TtC15LineMessagingUI11ChatContext : NSObject
@property(nonatomic, strong) RUINFixtureReadGate *markAsReadController;
@end
@implementation _TtC15LineMessagingUI11ChatContext @end
@interface UIViewController : NSObject
- (void)viewDidLoad;
- (void)viewWillAppear:(_Bool)animated;
- (void)viewDidAppear:(_Bool)animated;
- (void)viewDidLayoutSubviews;
@end
@implementation UIViewController
- (void)viewDidLoad {}
- (void)viewWillAppear:(_Bool)animated { (void)animated; }
- (void)viewDidAppear:(_Bool)animated { (void)animated; }
- (void)viewDidLayoutSubviews {}
@end
@interface _TtC15LineMessagingUI18ChatViewController : UIViewController
@property(nonatomic, strong) ManagedChat *chat;
@property(nonatomic, strong) _TtC15LineMessagingUI11ChatContext *chatContext;
@end
@implementation _TtC15LineMessagingUI18ChatViewController @end
id RUINCopySwiftField(id object, const char *path) {
    if ([object isKindOfClass:_TtC15LineMessagingUI18ChatViewController.class] && !strcmp(path, "chatContext"))
        return [object chatContext];
    if ([object isKindOfClass:_TtC15LineMessagingUI11ChatContext.class] && !strcmp(path, "markAsReadController"))
        return [object markAsReadController];
    return nil;
}
int32_t RUINWriteReadControllerEnabled(id object, int32_t enabled) {
    if (![object isKindOfClass:RUINFixtureReadGate.class] || (enabled != 0 && enabled != 1)) return -1;
    RUINFixtureReadGate *gate = object; int32_t previous = gate.enabled; gate.enabled = enabled; return previous;
}
@interface RUINFixtureNativeReader : NSObject
@property(nonatomic, strong) ManagedChat *chat;
@property(nonatomic, strong) RUINFixtureReadGate *gate;
@property(nonatomic) NSUInteger receipts;
@property(nonatomic) int64_t lastRead;
- (void)attemptRead;
@end
@implementation RUINFixtureNativeReader
- (void)attemptRead {
    int64_t boundary = _chat.lastReceivedMessageID;
    void (^nativeUIRead)(void) = ^{ if (self.gate.enabled) { self.receipts++; self.lastRead = boundary; } };
    if (NSThread.isMainThread) nativeUIRead(); else dispatch_async(dispatch_get_main_queue(), nativeUIRead);
}
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    (void)path; (void)object; (void)change; (void)context;
    [self attemptRead]; // Deliberately bypass the ObjC policy, as native Swift does.
}
@end

static void DrainMainQueue(void) {
    __block BOOL finished = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ finished = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!finished && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Require(finished, @"main-queue fixture did not drain");
}
#else
void RUINRefreshAutomaticReadGate(void) {}
void RUINAllowAutomaticReadForReply(NSDictionary *token) { (void)token; }
#endif

static NSUInteger sends, successes, failures, completions;
@interface ReplyFixture : NSObject
@property(nonatomic, strong) ManagedChat *chatObject;
@property(nonatomic) BOOL outgoing;
@property(nonatomic) BOOL raisesOnSend;
#if defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
@property(nonatomic, strong) RUINFixtureNativeReader *reader;
#endif
- (_Bool)isSendMessage;
- (void)sendWithCompletionHandler:(void (^)(void))completion;
- (void)addNotificationOfSentMessage;
- (void)addNotificationOfFailedMessage;
@end
@implementation ReplyFixture
- (_Bool)isSendMessage { return _outgoing; }
- (void)sendWithCompletionHandler:(void (^)(void))completion {
    sends++;
    if (_raisesOnSend) @throw [NSException exceptionWithName:@"NativeSendFailure" reason:@"fixture" userInfo:nil];
    if (completion) completion(); // A completion alone does not prove successful send.
}
- (void)addNotificationOfSentMessage {
    successes++;
#if defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
    [_reader attemptRead];
#endif
}
- (void)addNotificationOfFailedMessage { failures++; }
@end
@interface ManagedMessage : ReplyFixture @end
@implementation ManagedMessage @end
@interface ManagedSquareMessage : ReplyFixture @end
@implementation ManagedSquareMessage @end

static NSDictionary *Info(id self, SEL command) {
    (void)self; (void)command;
    return @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"};
}
static NSEntityDescription *ChatEntity(NSString *name, NSString *className) {
    NSEntityDescription *entity = [NSEntityDescription new]; entity.name = name; entity.managedObjectClassName = className;
    NSAttributeDescription *mid = [NSAttributeDescription new]; mid.name = @"mid"; mid.attributeType = NSStringAttributeType;
    NSAttributeDescription *last = [NSAttributeDescription new]; last.name = @"lastReceivedMessageID"; last.attributeType = NSInteger64AttributeType;
    entity.properties = @[mid, last]; return entity;
}
static void Send(ReplyFixture *message) {
    NSUInteger before = sends, callbacks = completions;
    [message sendWithCompletionHandler:^{ completions++; }];
    Require(sends == before + 1 && completions == callbacks + 1, @"original send/completion was not forwarded exactly once");
}
static void Sent(ReplyFixture *message) {
    NSUInteger before = successes; [message addNotificationOfSentMessage];
    Require(successes == before + 1, @"original sent notification was not forwarded exactly once");
}
static void Reload(void) { RUINInstallFeatures(); RUINRefreshAutomaticReadGate(); }

int main(void) { @autoreleasepool {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *keys = @[RUINReadControlEnabledDefaultsKey, RUINMarkReadOnReplyDefaultsKey, RUINReadExceptionsDefaultsKey];
    NSMutableDictionary *old = [NSMutableDictionary dictionary];
    for (NSString *key in keys) old[key] = [defaults objectForKey:key] ?: NSNull.null;
    Method method = class_getInstanceMethod(NSBundle.class, @selector(infoDictionary));
    IMP originalInfo = method_setImplementation(method, (IMP)Info);
    int status = 0;
    @try {
        NSManagedObjectModel *model = [NSManagedObjectModel new];
        model.entities = @[ChatEntity(@"Chat", @"ManagedChat"), ChatEntity(@"SquareChat", @"ManagedSquareChat")];
        NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        Require([coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:NULL] != nil, @"fixture store failed");
        NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        context.persistentStoreCoordinator = coordinator;
        for (Class cls in @[ManagedMessage.class, ManagedSquareMessage.class]) {
            [defaults setBool:YES forKey:RUINReadControlEnabledDefaultsKey];
            [defaults setBool:YES forKey:RUINMarkReadOnReplyDefaultsKey];
            [defaults setObject:@[] forKey:RUINReadExceptionsDefaultsKey];
            RUINInstallFeatures(); RUINInstallReadOnReply();
            BOOL square = cls == ManagedSquareMessage.class;
            ManagedChat *chat = [NSEntityDescription insertNewObjectForEntityForName:square ? @"SquareChat" : @"Chat" inManagedObjectContext:context];
            chat.mid = NSStringFromClass(cls); chat.lastReceivedMessageID = 100;
            ReplyFixture *message = [cls new]; message.chatObject = chat; message.outgoing = YES;
#if defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
            RUINFixtureReadGate *gate = [RUINFixtureReadGate new]; gate.enabled = YES;
            RUINFixtureNativeReader *reader = [RUINFixtureNativeReader new]; reader.chat = chat; reader.gate = gate; message.reader = reader;
            // Native observer is intentionally registered first: an after-change
            // refresh would lose this race even though Features later suppresses.
            [chat addObserver:reader forKeyPath:@"lastReceivedMessageID" options:0 context:NULL];
            __attribute__((objc_precise_lifetime)) _TtC15LineMessagingUI18ChatViewController *controller = [_TtC15LineMessagingUI18ChatViewController new];
            controller.chat = chat; controller.chatContext = [_TtC15LineMessagingUI11ChatContext new];
            controller.chatContext.markAsReadController = gate;
            RUINInstallAutomaticReadGate(); [controller viewDidLoad];
            Require(!gate.enabled, @"automatic gate was not initially held");
            ManagedChat *otherChat = [NSEntityDescription insertNewObjectForEntityForName:square ? @"SquareChat" : @"Chat" inManagedObjectContext:context];
            otherChat.mid = [chat.mid stringByAppendingString:@"-other"]; otherChat.lastReceivedMessageID = 100;
            RUINFixtureReadGate *otherGate = [RUINFixtureReadGate new]; otherGate.enabled = YES;
            __attribute__((objc_precise_lifetime)) _TtC15LineMessagingUI18ChatViewController *otherController = [_TtC15LineMessagingUI18ChatViewController new];
            otherController.chat = otherChat; otherController.chatContext = [_TtC15LineMessagingUI11ChatContext new];
            otherController.chatContext.markAsReadController = otherGate; [otherController viewDidLoad];
#endif
            Require(RUINShouldSuppressReadForChat(chat), @"initial boundary was not hidden");
            Sent(message);
            Require(RUINShouldSuppressReadForChat(chat), @"history-only notification granted an allowance");
            Send(message);
            Require(RUINShouldSuppressReadForChat(chat), @"send entry or unverified completion granted an allowance");
            Sent(message);
            Require(!RUINShouldSuppressReadForChat(chat), @"successful explicit reply did not allow captured boundary");
#if defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
            Require(gate.enabled && !otherGate.enabled && reader.receipts == 1 && reader.lastRead == 100, @"successful reply did not admit only its original native read");
#endif
            chat.lastReceivedMessageID = 101; // Native observer runs before any layout callback.
            Require(RUINShouldSuppressReadForChat(chat), @"new incoming boundary inherited the old allowance");
#if defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
            Require(!gate.enabled && reader.receipts == 1, @"new incoming native observer ran before re-suppression");
            NSManagedObjectContext *staleContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
            staleContext.persistentStoreCoordinator = coordinator;
            ManagedChat *staleChat = [NSEntityDescription insertNewObjectForEntityForName:square ? @"SquareChat" : @"Chat" inManagedObjectContext:staleContext];
            staleChat.mid = chat.mid; staleChat.lastReceivedMessageID = 100;
            ReplyFixture *staleMessage = [cls new]; staleMessage.chatObject = staleChat; staleMessage.outgoing = YES;
            Send(staleMessage); Sent(staleMessage);
            Require(!gate.enabled, @"successful send from a stale context reopened a newer UI boundary");
            Require(RUINShouldSuppressReadForChat(chat), @"stale-context reply allowed the newer received boundary");
#endif
            Sent(message);
            Require(RUINShouldSuppressReadForChat(chat), @"duplicate sent event reopened the gate");
            Send(message);
            NSUInteger failedBefore = failures; [message addNotificationOfFailedMessage];
            Require(failures == failedBefore + 1, @"native failed notification was not forwarded exactly once");
            Sent(message);
            Require(RUINShouldSuppressReadForChat(chat), @"asynchronous send failure left a grantable token");
            Send(message); chat.lastReceivedMessageID = 102; Sent(message);
            Require(RUINShouldSuppressReadForChat(chat), @"late success allowed a boundary received after send entry");
            Send(message); Reload(); Sent(message);
            Require(RUINShouldSuppressReadForChat(chat), @"settings reload revived a pending send token");
            message.outgoing = NO; Send(message); Sent(message); message.outgoing = YES;
            Require(RUINShouldSuppressReadForChat(chat), @"incoming message granted a reply allowance");
            message.raisesOnSend = YES;
            NSUInteger before = sends;
            @try { [message sendWithCompletionHandler:nil]; Require(NO, @"native exception was swallowed"); }
            @catch (NSException *exception) { Require([exception.name isEqual:@"NativeSendFailure"], @"wrong native exception"); }
            Require(sends == before + 1, @"throwing native send was forwarded more than once");
            message.raisesOnSend = NO; Sent(message);
            Require(RUINShouldSuppressReadForChat(chat), @"failed send left a grantable token");
            [defaults setBool:NO forKey:RUINMarkReadOnReplyDefaultsKey]; Reload(); Send(message); Sent(message);
            Require(RUINShouldSuppressReadForChat(chat), @"disabled reply option granted an allowance");
            [defaults setBool:YES forKey:RUINMarkReadOnReplyDefaultsKey]; Reload();
            Send(message); Sent(message);
            chat.lastReceivedMessageID = 102;
            Require(!RUINShouldSuppressReadForChat(chat), @"same-value boundary write expired its allowance");
            chat.lastReceivedMessageID = 103;
#if defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
            Require(!gate.enabled, @"second receive did not rearm suppression");
#endif
            NSString *identity = [NSString stringWithFormat:@"%@:%@", square ? @"squareChat" : @"chat", chat.mid];
            [defaults setObject:@[identity] forKey:RUINReadExceptionsDefaultsKey]; Reload();
            Require(!RUINShouldSuppressReadForChat(chat), @"chat exception was suppressed");
#if defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
            NSUInteger receipts = reader.receipts;
            Require(gate.enabled && !otherGate.enabled, @"exception leaked to another chat or did not restore native gate");
            chat.lastReceivedMessageID = 104;
            Require(reader.receipts == receipts + 1, @"exception incoming read was blocked");
#endif
            [defaults setObject:@[] forKey:RUINReadExceptionsDefaultsKey]; Reload();
            [defaults setBool:NO forKey:RUINReadControlEnabledDefaultsKey]; Reload();
            Require(!RUINShouldSuppressReadForChat(chat), @"read-control off did not restore policy");
#if defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
            Require(gate.enabled && otherGate.enabled, @"read-control off did not restore native gates");
            [chat removeObserver:reader forKeyPath:@"lastReceivedMessageID"];
            // Preserve a native false gate through a complete hold/restore cycle.
            gate.enabled = NO;
            [defaults setBool:YES forKey:RUINReadControlEnabledDefaultsKey]; Reload();
            [defaults setBool:NO forKey:RUINReadControlEnabledDefaultsKey]; Reload();
            Require(!gate.enabled, @"restore forced a native false gate to true");
#endif
        }
#if defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
        // A private owning context queues rearming from the prior callback
        // before the native did-change observer can queue its UI read.
        [defaults setBool:YES forKey:RUINReadControlEnabledDefaultsKey];
        [defaults setBool:YES forKey:RUINMarkReadOnReplyDefaultsKey];
        [defaults setObject:@[] forKey:RUINReadExceptionsDefaultsKey]; RUINInstallFeatures();
        NSManagedObjectContext *privateContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        privateContext.persistentStoreCoordinator = coordinator;
        __block ManagedChat *privateChat;
        __block ManagedMessage *privateMessage;
        RUINFixtureReadGate *privateGate = [RUINFixtureReadGate new]; privateGate.enabled = YES;
        RUINFixtureNativeReader *privateReader = [RUINFixtureNativeReader new]; privateReader.gate = privateGate;
        [privateContext performBlockAndWait:^{
            privateChat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:privateContext];
            privateChat.mid = @"private-context"; privateChat.lastReceivedMessageID = 300;
            privateMessage = [ManagedMessage new]; privateMessage.chatObject = privateChat;
            privateMessage.outgoing = YES; privateMessage.reader = privateReader; privateReader.chat = privateChat;
            [privateChat addObserver:privateReader forKeyPath:@"lastReceivedMessageID" options:0 context:NULL];
        }];
        __attribute__((objc_precise_lifetime)) _TtC15LineMessagingUI18ChatViewController *privateController = [_TtC15LineMessagingUI18ChatViewController new];
        privateController.chat = privateChat; privateController.chatContext = [_TtC15LineMessagingUI11ChatContext new];
        privateController.chatContext.markAsReadController = privateGate; [privateController viewDidLoad];
        Require(!privateGate.enabled, @"private-context automatic gate was not held");
        [privateContext performBlockAndWait:^{ Send(privateMessage); Sent(privateMessage); }]; DrainMainQueue();
        Require(privateGate.enabled && privateReader.receipts == 1 && privateReader.lastRead == 300,
                @"private-context success did not precede native UI delivery");
        [privateContext performBlockAndWait:^{ privateChat.lastReceivedMessageID = 301; }]; DrainMainQueue();
        Require(!privateGate.enabled && privateReader.receipts == 1, @"private-context incoming UI read beat rearming");
        [privateContext performBlockAndWait:^{
            Send(privateMessage); Sent(privateMessage);
            privateChat.lastReceivedMessageID = 302;
        }]; DrainMainQueue();
        Require(!privateGate.enabled && privateReader.lastRead < 302,
                [NSString stringWithFormat:@"queued reply restore admitted a newer receive (gate=%d, lastRead=%lld)",
                 privateGate.enabled, (long long)privateReader.lastRead]);
        [privateContext performBlockAndWait:^{ privateChat.lastReceivedMessageID = 303; }];
        [defaults setBool:NO forKey:RUINReadControlEnabledDefaultsKey]; Reload();
        DrainMainQueue();
        Require(privateGate.enabled, @"private-context settings off did not restore native gate");
        [privateContext performBlockAndWait:^{ [privateChat removeObserver:privateReader forKeyPath:@"lastReceivedMessageID"]; }];
        puts("Automatic read gate checks passed: prior receive ordering, successful reply, settings and exceptions");
#else
        puts("Read-on-reply checks passed: success correlation, stale/failed sends and boundary policy");
#endif
    } @catch (NSException *exception) {
        fprintf(stderr, "Read-on-reply check failed: %s\n", exception.reason.UTF8String); status = 1;
    } @finally {
        method_setImplementation(method, originalInfo);
        for (NSString *key in keys) { id value = old[key]; if (value == NSNull.null) [defaults removeObjectForKey:key]; else [defaults setObject:value forKey:key]; }
    }
    return status;
}}
