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
static atomic_ulong modelSendEntries;
static atomic_ulong observedSentNotifications, allowanceAttempts, rejectedContexts;

static void ObserveSendEntry(id message) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:RUINMarkReadOnReplyDefaultsKey]) return;
    @try {
        Method sent = class_getInstanceMethod([message class], sel_registerName("isSendMessage"));
        Method chatGetter = class_getInstanceMethod([message class], sel_registerName("chatObject"));
        if (!sent || !chatGetter || strcmp(method_getTypeEncoding(sent), "B16@0:8") ||
            strcmp(method_getTypeEncoding(chatGetter), "@16@0:8")) return;
        id chat = [(id<RUINMessagingMessageFields>)message chatObject];
        if (![chat isKindOfClass:NSManagedObject.class]) return;
        NSManagedObjectContext *context = ((NSManagedObject *)chat).managedObjectContext;
        if (!context) return;
        [context performBlockAndWait:^{ RUINAllowReadAfterUserReply(chat); }];
        RUINRefreshAutomaticReadGate();
        atomic_fetch_add(&allowanceAttempts, 1);
    } @catch (__unused NSException *exception) {
        atomic_fetch_add(&rejectedContexts, 1);
    }
}
%group RUINReplyTalkSent
%hook RUINReplyTalk
- (void)addNotificationOfSentMessage {
    // Completion/history notifications do not identify a new user reply.
    atomic_fetch_add(&observedSentNotifications, 1);
    %orig;
}
%end
%end

%group RUINReplySquareSent
%hook RUINReplySquare
- (void)addNotificationOfSentMessage {
    atomic_fetch_add(&observedSentNotifications, 1);
    %orig;
}
%end
%end

%group RUINReplyTalkSend
%hook RUINReplyTalk
- (void)sendWithCompletionHandler:(id)completion {
    atomic_fetch_add(&modelSendEntries, 1);
    ObserveSendEntry(self);
    %orig;
}
%end
%end

%group RUINReplySquareSend
%hook RUINReplySquare
- (void)sendWithCompletionHandler:(id)completion {
    atomic_fetch_add(&modelSendEntries, 1);
    ObserveSendEntry(self);
    %orig;
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
    if (!talkSendInstalled) talkSendInstalled = Install("ManagedMessage", "sendWithCompletionHandler:", "v24@0:8@?16", ^(Class cls) {
        %init(RUINReplyTalkSend, RUINReplyTalk = cls);
    });
    if (!squareSendInstalled) squareSendInstalled = Install("ManagedSquareMessage", "sendWithCompletionHandler:", "v24@0:8@?16", ^(Class cls) {
        %init(RUINReplySquareSend, RUINReplySquare = cls);
    });
    RUINSetReplyObserverInstalled(talkSendInstalled && squareSendInstalled);
}
NSDictionary *RUINReplyDiagnostics(void) {
    return @{@"talkHookInstalled":@(talkInstalled), @"squareHookInstalled":@(squareInstalled),
        @"talkSendEntryInstalled":@(talkSendInstalled), @"squareSendEntryInstalled":@(squareSendInstalled),
        @"modelSendEntries":@(atomic_load(&modelSendEntries)),
        @"sentNotificationsObserved":@(atomic_load(&observedSentNotifications)),
        @"readAllowanceAttempts":@(atomic_load(&allowanceAttempts)), @"rejectedContexts":@(atomic_load(&rejectedContexts)),
        @"receiptDeliveryVerified":@NO};
}
