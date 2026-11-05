#import "ReadOnReply.h"
#import "Features.h"
#import "AutomaticReadGate.h"
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>

static void (*originalTalkSent)(id, SEL), (*originalSquareSent)(id, SEL);
static void (*originalTalkSend)(id, SEL, id), (*originalSquareSend)(id, SEL, id);
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
        id chat = ((id (*)(id, SEL))objc_msgSend)(message, sel_registerName("chatObject"));
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
static void TalkSent(id self, SEL selector) {
    // Completion/history notifications do not identify a new user reply.
    atomic_fetch_add(&observedSentNotifications, 1);
    originalTalkSent(self, selector);
}
static void SquareSent(id self, SEL selector) {
    atomic_fetch_add(&observedSentNotifications, 1);
    originalSquareSent(self, selector);
}
static void TalkSend(id self, SEL selector, id completion) {
    atomic_fetch_add(&modelSendEntries, 1); ObserveSendEntry(self);
    originalTalkSend(self, selector, completion);
}
static void SquareSend(id self, SEL selector, id completion) {
    atomic_fetch_add(&modelSendEntries, 1); ObserveSendEntry(self);
    originalSquareSend(self, selector, completion);
}
static BOOL Install(const char *name, IMP replacement, IMP *original) {
    Class cls = objc_getClass(name);
    SEL selector = sel_registerName("addNotificationOfSentMessage");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || strcmp(method_getTypeEncoding(method), "v16@0:8")) return NO;
    *original = method_getImplementation(method);
    if (!class_addMethod(cls, selector, replacement, "v16@0:8")) method_setImplementation(method, replacement);
    return YES;
}
void RUINInstallReadOnReply(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    if (![info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier] ||
        ![info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] ||
        ![info[@"CFBundleVersion"] isEqual:RUINTargetBuild]) { RUINSetReplyObserverInstalled(NO); return; }
    if (!talkInstalled) talkInstalled = Install("ManagedMessage", (IMP)TalkSent, (IMP *)&originalTalkSent);
    if (!squareInstalled) squareInstalled = Install("ManagedSquareMessage", (IMP)SquareSent, (IMP *)&originalSquareSent);
    for (NSString *name in @[@"ManagedMessage", @"ManagedSquareMessage"]) {
        BOOL *flag = [name isEqual:@"ManagedMessage"] ? &talkSendInstalled : &squareSendInstalled;
        if (*flag) continue;
        Class cls = objc_getClass(name.UTF8String); SEL send = sel_registerName("sendWithCompletionHandler:");
        Method method = cls ? class_getInstanceMethod(cls, send) : NULL;
        if (!method || strcmp(method_getTypeEncoding(method), "v24@0:8@?16")) continue;
        IMP replacement = [name isEqual:@"ManagedMessage"] ? (IMP)TalkSend : (IMP)SquareSend;
        IMP original = method_getImplementation(method);
        if ([name isEqual:@"ManagedMessage"]) originalTalkSend = (void *)original; else originalSquareSend = (void *)original;
        if (!class_addMethod(cls, send, replacement, "v24@0:8@?16")) method_setImplementation(method, replacement);
        *flag = YES;
    }
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
