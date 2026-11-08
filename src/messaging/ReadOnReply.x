%config(generator=internal);

#import "MessagingPrivateAPI.h"
#import "ReadOnReply.h"
#import "Features.h"
#import "../core/TargetMetadata.h"
#import "AutomaticReadGate.h"
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>

static BOOL talkInstalled, squareInstalled;
static BOOL talkSendInstalled, squareSendInstalled;
static BOOL talkFailureInstalled, squareFailureInstalled;
static atomic_ulong modelSendEntries;
static atomic_ulong observedSentNotifications, allowanceAttempts, grantedAllowances, rejectedContexts;
static atomic_ulong observedFailedNotifications;
static char pendingReplyKey;

@interface RUINReplyTalk (RUINReplyFailure)
- (void)addNotificationOfFailedMessage;
@end
@interface RUINReplySquare (RUINReplyFailure)
- (void)addNotificationOfFailedMessage;
@end

@protocol RUINReplyMessageFields <RUINMessagingMessageFields>
- (BOOL)isSendMessage;
@end

static NSManagedObject *ReplyChat(id message) {
    Class cls = object_getClass(message);
    Method sent = class_getInstanceMethod(cls, sel_registerName("isSendMessage"));
    Method chatGetter = class_getInstanceMethod(cls, sel_registerName("chatObject"));
    if (!sent || !chatGetter || strcmp(method_getTypeEncoding(sent), "B16@0:8") ||
        strcmp(method_getTypeEncoding(chatGetter), "@16@0:8") ||
        ![(id<RUINReplyMessageFields>)message isSendMessage]) return nil;
    id chat = [(id<RUINMessagingMessageFields>)message chatObject];
    return [chat isKindOfClass:NSManagedObject.class] ? chat : nil;
}

static void ObserveSendEntry(id message) {
    objc_setAssociatedObject(message, &pendingReplyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![NSUserDefaults.standardUserDefaults boolForKey:RUINMarkReadOnReplyDefaultsKey]) return;
    @try {
        NSManagedObject *chat = ReplyChat(message);
        NSManagedObjectContext *context = chat.managedObjectContext;
        if (!context) return;
        __block NSDictionary *token;
        [context performBlockAndWait:^{ token = RUINCaptureReadOnReplyToken(chat); }];
        if (token.count) objc_setAssociatedObject(message, &pendingReplyKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (__unused NSException *exception) {
        atomic_fetch_add(&rejectedContexts, 1);
    }
}

static void ObserveSent(id message) {
    NSDictionary *token = objc_getAssociatedObject(message, &pendingReplyKey);
    objc_setAssociatedObject(message, &pendingReplyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!token.count) return; // History/duplicate notifications cannot create a reply.
    @try {
        NSManagedObject *chat = ReplyChat(message);
        NSManagedObjectContext *context = chat.managedObjectContext;
        if (!context) return;
        __block BOOL allowed = NO;
        [context performBlockAndWait:^{ allowed = RUINAllowReadAfterUserReplyWithToken(chat, token); }];
        atomic_fetch_add(&allowanceAttempts, 1);
        if (allowed) {
            atomic_fetch_add(&grantedAllowances, 1);
            RUINAllowAutomaticReadForReply(token);
        }
    } @catch (__unused NSException *exception) {
        atomic_fetch_add(&rejectedContexts, 1);
    }
}
%group RUINReplyTalkSent
%hook RUINReplyTalk
- (void)addNotificationOfSentMessage {
    atomic_fetch_add(&observedSentNotifications, 1);
    ObserveSent(self);
    %orig;
}
%end
%end

%group RUINReplySquareSent
%hook RUINReplySquare
- (void)addNotificationOfSentMessage {
    atomic_fetch_add(&observedSentNotifications, 1);
    ObserveSent(self);
    %orig;
}
%end
%end

%group RUINReplyTalkFailed
%hook RUINReplyTalk
- (void)addNotificationOfFailedMessage {
    atomic_fetch_add(&observedFailedNotifications, 1);
    objc_setAssociatedObject(self, &pendingReplyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}
%end
%end

%group RUINReplySquareFailed
%hook RUINReplySquare
- (void)addNotificationOfFailedMessage {
    atomic_fetch_add(&observedFailedNotifications, 1);
    objc_setAssociatedObject(self, &pendingReplyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}
%end
%end

%group RUINReplyTalkSend
%hook RUINReplyTalk
- (void)sendWithCompletionHandler:(id)completion {
    atomic_fetch_add(&modelSendEntries, 1);
    ObserveSendEntry(self);
    @try { %orig; }
    @catch (NSException *exception) {
        objc_setAssociatedObject(self, &pendingReplyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @throw exception;
    }
}
%end
%end

%group RUINReplySquareSend
%hook RUINReplySquare
- (void)sendWithCompletionHandler:(id)completion {
    atomic_fetch_add(&modelSendEntries, 1);
    ObserveSendEntry(self);
    @try { %orig; }
    @catch (NSException *exception) {
        objc_setAssociatedObject(self, &pendingReplyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @throw exception;
    }
}
%end
%end

static BOOL Install(const char *name, const char *selectorName, const char *encoding, void (^initialize)(Class)) {
    Class cls = objc_getClass(name);
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName(selectorName)) : NULL;
    if (!method || strcmp(method_getTypeEncoding(method), encoding) || !method_getImplementation(method)) return NO;
    initialize(cls);
    return YES;
}
void RUINInstallReadOnReply(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    if (!RUINTargetMetadataMatchesInfo(info)) { RUINSetReplyObserverInstalled(NO); return; }
    if (!talkInstalled) talkInstalled = Install("ManagedMessage", "addNotificationOfSentMessage", "v16@0:8", ^(Class cls) {
        %init(RUINReplyTalkSent, RUINReplyTalk = cls);
    });
    if (!squareInstalled) squareInstalled = Install("ManagedSquareMessage", "addNotificationOfSentMessage", "v16@0:8", ^(Class cls) {
        %init(RUINReplySquareSent, RUINReplySquare = cls);
    });
    if (!talkFailureInstalled) talkFailureInstalled = Install("ManagedMessage", "addNotificationOfFailedMessage", "v16@0:8", ^(Class cls) {
        %init(RUINReplyTalkFailed, RUINReplyTalk = cls);
    });
    if (!squareFailureInstalled) squareFailureInstalled = Install("ManagedSquareMessage", "addNotificationOfFailedMessage", "v16@0:8", ^(Class cls) {
        %init(RUINReplySquareFailed, RUINReplySquare = cls);
    });
    if (talkInstalled && talkFailureInstalled && !talkSendInstalled) talkSendInstalled = Install("ManagedMessage", "sendWithCompletionHandler:", "v24@0:8@?16", ^(Class cls) {
        %init(RUINReplyTalkSend, RUINReplyTalk = cls);
    });
    if (squareInstalled && squareFailureInstalled && !squareSendInstalled) squareSendInstalled = Install("ManagedSquareMessage", "sendWithCompletionHandler:", "v24@0:8@?16", ^(Class cls) {
        %init(RUINReplySquareSend, RUINReplySquare = cls);
    });
    RUINSetReplyObserverInstalled(talkInstalled && squareInstalled && talkSendInstalled && squareSendInstalled);
}
NSDictionary *RUINReplyDiagnostics(void) {
    return @{@"talkHookInstalled":@(talkInstalled), @"squareHookInstalled":@(squareInstalled),
        @"talkSendEntryInstalled":@(talkSendInstalled), @"squareSendEntryInstalled":@(squareSendInstalled),
        @"talkFailureHookInstalled":@(talkFailureInstalled), @"squareFailureHookInstalled":@(squareFailureInstalled),
        @"modelSendEntries":@(atomic_load(&modelSendEntries)),
        @"sentNotificationsObserved":@(atomic_load(&observedSentNotifications)),
        @"failedNotificationsObserved":@(atomic_load(&observedFailedNotifications)),
        @"readAllowanceAttempts":@(atomic_load(&allowanceAttempts)), @"grantedAllowances":@(atomic_load(&grantedAllowances)),
        @"rejectedContexts":@(atomic_load(&rejectedContexts)),
        @"receiptDeliveryVerified":@NO};
}
