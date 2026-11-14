#define RUIN_CONFIRMATIONS_INTERNAL 1
#define RUIN_HOST_CHECK 1
#import "../src/interface/Confirmations.h"
#import "../src/core/Localization.h"

#include <assert.h>
#include <stdint.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>

// Only UIKit and app context are simulated. The router below is extracted from
// Confirmations.x by check_confirmations.py and compiled without rewriting it.
@class UIWindow;
@interface UIView : NSObject
@property(nonatomic, strong) UIView *superview;
@property(nonatomic, strong) UIWindow *window;
@end
@implementation UIView
@end
@interface UIControl : UIView
@end
@implementation UIControl
@end
@interface UIWindow : UIView
@end
@implementation UIWindow
@end
@interface UIViewController : NSObject
@property(nonatomic) BOOL isViewLoaded;
@property(nonatomic, strong) UIView *view;
@end
@implementation UIViewController
@end
@interface UIAlertController : UIViewController
@end
@implementation UIAlertController
@end
@interface _TtC15LineMessagingUI12ChatInputBar : UIView
@property(nonatomic, weak) UIControl *sendButton;
@end
@implementation _TtC15LineMessagingUI12ChatInputBar
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#include "ConfirmationTypes.inc"
#pragma clang diagnostic pop
@implementation RUINConfirmationPending
@end

static const char * const RUINChatInputBarClass = "_TtC15LineMessagingUI12ChatInputBar";
static RUINConfirmationHook gControlSendActionHook = {
    .kind = RUINConfirmationSend, .shape = RUINInvocationControlAction,
    .flags = RUINHookNeedsChatThread | RUINHookComposerControlBoundary
};
static RUINConfirmationHook gChatInputSendHook = {
    .kind = RUINConfirmationSend, .shape = RUINInvocationOneObject,
    .flags = RUINHookNeedsChatThread
};
static RUINConfirmationHook gUnrelatedHook = {.kind = RUINConfirmationCall};
static RUINConfirmationPending *gPendingConfirmation;
static RUINConfirmationOwnerTickets gPendingOwnerTickets;
static os_unfair_lock gPendingLock = OS_UNFAIR_LOCK_INIT;
typedef struct {
    __unsafe_unretained RUINConfirmationPending *pending;
    uint64_t ticket;
    BOOL consumed;
} RUINConfirmationSendPermit;
static _Thread_local RUINConfirmationSendPermit *gApprovedSendPermit;
static atomic_int gSendButtonIvarState;
static atomic_uint_fast64_t gUnknownCameraState;
static BOOL gEnabled = YES, gContextValid = YES;
static UIWindow *gWindow;
static UIViewController *gPresenter;
static NSUInteger gPromptCount, gControlOriginalCount, gSendOriginalCount, gOtherOriginalCount;
static dispatch_block_t gDuringControlOriginal;

static id RUINObjectIvar(id object, const char *className, const char *ivarName)
{
    assert(strcmp(className, RUINChatInputBarClass) == 0);
    assert(strcmp(ivarName, "$__lazy_storage_$_sendButton") == 0);
    return [(_TtC15LineMessagingUI12ChatInputBar *)object sendButton];
}
static BOOL RUINWindowIsActive(UIWindow *window) { return gContextValid && window == gWindow; }
static UIWindow *RUINWindowForTarget(__unused id target) { return gWindow; }
static UIViewController *RUINNearestViewController(__unused id target) { return gPresenter; }
static BOOL RUINThreadStillMatches(__unused RUINConfirmationPending *pending) { return gContextValid; }
static id RUINCurrentContextIdentity(RUINConfirmationPending *pending) { return pending.contextIdentity; }
static BOOL RUINCameraStillTurnsOn(__unused RUINConfirmationPending *pending) { return YES; }
static BOOL RUINSenderMatchesHook(__unused RUINConfirmationHook *hook, __unused id target, __unused id sender)
{ return YES; }
static RUINConfirmationActionClass RUINCameraSenderClassification(__unused id target, __unused id sender)
{ return RUINConfirmationActionProtected; }
static BOOL RUINFeatureEnabled(__unused RUINConfirmationKind kind) { return gEnabled; }
static NSString *RUINApproveTitle(__unused RUINConfirmationKind kind) { return @""; }
static BOOL RUINShouldConfirmSend(__unused RUINConfirmationHook *hook, __unused id target,
    __unused RUINConfirmationPending *pending, BOOL *shouldConfirm)
{ *shouldConfirm = YES; return YES; }
static BOOL RUINPreparePresentation(RUINConfirmationPending *pending, __unused id target)
{
    pending.window = gWindow;
    pending.presenter = gPresenter;
    pending.anchorController = gPresenter;
    return YES;
}
static BOOL RUINCapturePendingContext(__unused RUINConfirmationHook *hook,
    __unused RUINConfirmationPending *pending) { return YES; }
static BOOL RUINShowConfirmation(RUINConfirmationPending *pending)
{
    assert(!gPendingConfirmation);
    pending.ownerTicket = RUINConfirmationIssueOwnerTicket(&gPendingOwnerTickets);
    assert(pending.ownerTicket);
    gPendingConfirmation = pending;
    pending.alert = [UIAlertController new];
    gPromptCount++;
    return YES;
}
static UIView *RUINComposerForSendControl(id control, id actionTarget, SEL action);
#include "ConfirmationProduction.inc"

@interface RUINConfirmationRelayShim : NSObject
@property(nonatomic, strong) id composer;
@property(nonatomic, strong) id sender;
@property(nonatomic, assign) SEL forwardedAction;
@property(nonatomic) BOOL duplicate;
- (void)relay:(id)sender;
@end
@implementation RUINConfirmationRelayShim
- (void)relay:(id)sender
{
    id forwardedSender = self.sender ?: sender;
    RUINHandleHook(&gChatInputSendHook, self.composer, self.forwardedAction, forwardedSender, nil, NULL);
    if (self.duplicate)
        RUINHandleHook(&gChatInputSendHook, self.composer, self.forwardedAction, forwardedSender, nil, NULL);
}
@end

static void ShimSendOriginal(__unused id target, __unused SEL selector, __unused id sender)
{ gSendOriginalCount++; }
static void ShimOtherOriginal(__unused id target, __unused SEL selector, __unused id sender)
{ gOtherOriginalCount++; }
static void ShimControlOriginal(id control, __unused SEL selector, SEL action, id target, __unused id event)
{
    gControlOriginalCount++;
    if (gDuringControlOriginal) gDuringControlOriginal();
    if ([target isKindOfClass:RUINConfirmationRelayShim.class]) {
        assert(action == @selector(relay:));
        [(RUINConfirmationRelayShim *)target relay:control];
    } else {
        RUINHandleHook(&gChatInputSendHook, target, action, control, nil, NULL);
    }
}

@interface RUINConfirmationAlertShim : NSObject
@property(nonatomic, copy) dispatch_block_t action;
@end

@implementation RUINConfirmationAlertShim
@end

@interface RUINConfirmationPendingShim : NSObject
@property(nonatomic, strong) RUINConfirmationAlertShim *alert;
@end

@implementation RUINConfirmationPendingShim
@end

@interface RUINConfirmationUIKitShim : NSObject
@property(nonatomic) BOOL alertStillPresented;
@property(nonatomic) BOOL alertBeingDismissed;
@property(nonatomic) BOOL alertViewAttached;
@property(nonatomic) BOOL anotherModalPresented;
- (RUINConfirmationDismissalState)observeWithTimeout:(BOOL)timedOut;
@end

@implementation RUINConfirmationUIKitShim
- (RUINConfirmationDismissalState)observeWithTimeout:(BOOL)timedOut
{
    return RUINConfirmationObserveDismissal(self.alertStillPresented, self.alertBeingDismissed,
        self.alertViewAttached, self.anotherModalPresented, timedOut);
}
@end

static void CheckRoutingAndUIKitClassification(void)
{
    assert(RUINConfirmationGate(NO, NO, NO) == RUINConfirmationGateInvokeOriginal);
    assert(RUINConfirmationGate(YES, NO, NO) == RUINConfirmationGateSuppress);
    assert(RUINConfirmationGate(YES, YES, YES) == RUINConfirmationGateInvokeOriginal);

    BOOL alertControlIsComposerSend = RUINConfirmationIsComposerControl(YES, NO, NO, NO);
    RUINConfirmationActionClass alertAction = RUINConfirmationClassifyAction(
        YES, alertControlIsComposerSend, NO, YES, NO, NO, NO);
    assert(alertAction == RUINConfirmationActionPassThrough);
    assert(RUINConfirmationClassifiedGate(alertAction, YES) == RUINConfirmationGateInvokeOriginal);

    BOOL sendButtonIsComposerSend = RUINConfirmationIsComposerControl(YES, YES, NO, YES);
    RUINConfirmationActionClass duplicateSend = RUINConfirmationClassifyAction(
        YES, sendButtonIsComposerSend, NO, YES, NO, NO, NO);
    assert(duplicateSend == RUINConfirmationActionProtected);
    assert(RUINConfirmationClassifiedGate(duplicateSend, YES) == RUINConfirmationGateSuppress);
    assert(RUINConfirmationClassifiedGate(duplicateSend, NO) == RUINConfirmationGateContinue);

    assert(RUINConfirmationClassifyCameraButtons(NO, YES) == RUINConfirmationActionPassThrough);
    assert(RUINConfirmationClassifiedGate(RUINConfirmationClassifyCameraButtons(NO, YES), YES) ==
        RUINConfirmationGateInvokeOriginal);
    assert(RUINConfirmationClassifyCameraButtons(YES, NO) == RUINConfirmationActionProtected);
    assert(RUINConfirmationClassifyCameraButtons(NO, NO) == RUINConfirmationActionUnknownProtected);
    assert(RUINConfirmationClassifiedGate(RUINConfirmationClassifyCameraButtons(NO, NO), NO) ==
        RUINConfirmationGateSuppress);

    RUINConfirmationUIKitShim *ui = [RUINConfirmationUIKitShim new];
    ui.alertStillPresented = YES;
    assert([ui observeWithTimeout:NO] == RUINConfirmationDismissalWaiting);
    ui.alertBeingDismissed = YES;
    ui.alertViewAttached = YES;
    assert([ui observeWithTimeout:NO] == RUINConfirmationDismissalWaiting);
    ui.alertStillPresented = NO;
    assert([ui observeWithTimeout:NO] == RUINConfirmationDismissalWaiting);
    ui.alertBeingDismissed = NO;
    ui.alertViewAttached = NO;
    assert([ui observeWithTimeout:NO] == RUINConfirmationDismissalComplete);

    ui.alertStillPresented = YES;
    ui.anotherModalPresented = YES;
    assert([ui observeWithTimeout:NO] == RUINConfirmationDismissalOtherModal);
    ui.anotherModalPresented = NO;
    assert([ui observeWithTimeout:YES] == RUINConfirmationDismissalTimedOut);
}

static void CheckOwnerTickets(void)
{
    RUINConfirmationOwnerTickets tickets = {0};
    uint64_t first = RUINConfirmationIssueOwnerTicket(&tickets);
    assert(first == 1 && RUINConfirmationOwnsTicket(&tickets, first));
    assert(RUINConfirmationIssueOwnerTicket(&tickets) == 0);
    assert(!RUINConfirmationReleaseTicket(&tickets, first + 1));
    assert(RUINConfirmationOwnsTicket(&tickets, first));
    assert(RUINConfirmationReleaseTicket(&tickets, first));

    uint64_t second = RUINConfirmationIssueOwnerTicket(&tickets);
    assert(second > first && !RUINConfirmationOwnsTicket(&tickets, first));
    assert(!RUINConfirmationReleaseTicket(&tickets, first));
    assert(RUINConfirmationReleaseTicket(&tickets, second));
    tickets.lastIssued = UINT64_MAX;
    assert(RUINConfirmationIssueOwnerTicket(&tickets) == 0);
}

static void CheckDecisionLifecycle(void)
{
    RUINConfirmationLifecycle lifecycle = RUINConfirmationLifecycleAwaitingDecision;
    RUINConfirmationDecision decision = RUINConfirmationDecisionNone;
    BOOL permitConsumed = NO;
    assert(RUINConfirmationRecordDecision(&lifecycle, &decision, YES));
    assert(lifecycle == RUINConfirmationLifecycleWaitingForDismissal);
    assert(!RUINConfirmationRecordDecision(&lifecycle, &decision, YES));
    assert(!RUINConfirmationBeginInvocationAfterDismissal(&lifecycle,
        RUINConfirmationDismissalWaiting, YES, &permitConsumed));

    RUINConfirmationUIKitShim *ui = [RUINConfirmationUIKitShim new];
    ui.alertStillPresented = YES;
    RUINConfirmationDismissalState dismissal = [ui observeWithTimeout:NO];
    assert(dismissal == RUINConfirmationDismissalWaiting);
    assert(!RUINConfirmationBeginInvocationAfterDismissal(&lifecycle, dismissal, YES, &permitConsumed));
    ui.alertStillPresented = NO;
    ui.alertBeingDismissed = YES;
    ui.alertViewAttached = YES;
    dismissal = [ui observeWithTimeout:NO];
    assert(dismissal == RUINConfirmationDismissalWaiting);
    assert(!RUINConfirmationBeginInvocationAfterDismissal(&lifecycle, dismissal, YES, &permitConsumed));
    ui.alertBeingDismissed = NO;
    ui.alertViewAttached = NO;
    dismissal = [ui observeWithTimeout:NO];
    assert(dismissal == RUINConfirmationDismissalComplete);
    assert(RUINConfirmationBeginInvocationAfterDismissal(&lifecycle, dismissal, YES, &permitConsumed));
    assert(permitConsumed && lifecycle == RUINConfirmationLifecycleInvoking);
    assert(!RUINConfirmationBeginInvocationAfterDismissal(&lifecycle,
        RUINConfirmationDismissalComplete, YES, &permitConsumed));
    assert(RUINConfirmationFinishInvocation(&lifecycle, YES));
    assert(lifecycle == RUINConfirmationLifecycleCompleted);
    assert(!RUINConfirmationFinishInvocation(&lifecycle, YES));

    lifecycle = RUINConfirmationLifecycleAwaitingDecision;
    decision = RUINConfirmationDecisionNone;
    permitConsumed = NO;
    assert(RUINConfirmationRecordDecision(&lifecycle, &decision, NO));
    assert(lifecycle == RUINConfirmationLifecycleCancelled);
    assert(!RUINConfirmationRecordDecision(&lifecycle, &decision, YES));
    assert(!RUINConfirmationBeginInvocation(&lifecycle, YES, &permitConsumed));

    lifecycle = RUINConfirmationLifecycleAwaitingDecision;
    decision = RUINConfirmationDecisionNone;
    assert(RUINConfirmationRecordDecision(&lifecycle, &decision, YES));
    assert(!RUINConfirmationBeginInvocationAfterDismissal(&lifecycle,
        RUINConfirmationDismissalComplete, NO, &permitConsumed));
    assert(RUINConfirmationAbort(&lifecycle));
    assert(lifecycle == RUINConfirmationLifecycleAborted);

    lifecycle = RUINConfirmationLifecycleAwaitingDecision;
    decision = RUINConfirmationDecisionNone;
    permitConsumed = NO;
    assert(RUINConfirmationRecordDecision(&lifecycle, &decision, YES));
    assert(RUINConfirmationBeginInvocationAfterDismissal(&lifecycle,
        RUINConfirmationDismissalComplete, YES, &permitConsumed));
    assert(RUINConfirmationFinishInvocation(&lifecycle, NO));
    assert(lifecycle == RUINConfirmationLifecycleAborted);

    lifecycle = RUINConfirmationLifecycleAwaitingDecision;
    assert(RUINConfirmationAbort(&lifecycle));
    assert(!RUINConfirmationBeginInvocation(&lifecycle, YES, &permitConsumed));
}

static void CheckSingleUseSendReentry(void)
{
    int inputBar = 0, control = 0, otherControl = 0, sendSelector = 0, otherSelector = 0;
    BOOL consumed = NO;
    assert(RUINConfirmationConsumeSendReentry(&consumed, 4, 4, YES, YES, YES,
        &inputBar, &control, &inputBar, &control, &sendSelector, &sendSelector));
    assert(consumed);
    assert(!RUINConfirmationConsumeSendReentry(&consumed, 4, 4, YES, YES, YES,
        &inputBar, &control, &inputBar, &control, &sendSelector, &sendSelector));

    consumed = NO;
    assert(!RUINConfirmationConsumeSendReentry(&consumed, 4, 4, YES, YES, YES,
        &inputBar, &control, &inputBar, &otherControl, &sendSelector, &sendSelector));
    assert(!consumed);
    assert(!RUINConfirmationConsumeSendReentry(&consumed, 4, 4, YES, YES, YES,
        &inputBar, &control, &inputBar, &control, &otherSelector, &sendSelector));
    assert(!RUINConfirmationConsumeSendReentry(&consumed, 3, 4, YES, YES, YES,
        &inputBar, &control, &inputBar, &control, &sendSelector, &sendSelector));
    assert(!RUINConfirmationConsumeSendReentry(&consumed, 4, 4, YES, YES, NO,
        &inputBar, &control, &inputBar, &control, &sendSelector, &sendSelector));
    assert(!consumed);
}

static void CheckAlertOwnership(void)
{
    RUINConfirmationPendingShim *pending = [RUINConfirmationPendingShim new];
    RUINConfirmationAlertShim *alert = [RUINConfirmationAlertShim new];
    __weak RUINConfirmationAlertShim *weakAlert = alert;
    pending.alert = alert;
    alert.action = ^{ (void)pending; };
    alert = nil;
    assert(weakAlert != nil); // the pending ticket owns the alert while dismissal is observed

    RUINConfirmationUIKitShim *ui = [RUINConfirmationUIKitShim new];
    ui.alertStillPresented = YES;
    assert([ui observeWithTimeout:NO] == RUINConfirmationDismissalWaiting);
    ui.alertStillPresented = NO;
    ui.alertBeingDismissed = NO;
    ui.alertViewAttached = NO;
    assert([ui observeWithTimeout:NO] == RUINConfirmationDismissalComplete);

    pending.alert = nil; // terminal callback breaks alert -> action -> pending -> alert
    assert(weakAlert == nil);
}

static void ResetProductionShim(void)
{
    assert(!gPendingConfirmation && !gPendingOwnerTickets.active && !gApprovedSendPermit);
    gEnabled = YES;
    gContextValid = YES;
    gPromptCount = gControlOriginalCount = gSendOriginalCount = gOtherOriginalCount = 0;
    gDuringControlOriginal = nil;
    gWindow = [UIWindow new];
    gPresenter = [UIViewController new];
    gPresenter.isViewLoaded = YES;
    gPresenter.view = [UIView new];
    gPresenter.view.window = gWindow;
    atomic_store(&gControlSendActionHook.original, (IMP)ShimControlOriginal);
    atomic_store(&gChatInputSendHook.original, (IMP)ShimSendOriginal);
    atomic_store(&gUnrelatedHook.original, (IMP)ShimOtherOriginal);
}

static RUINConfirmationPending *BeginProductionSend(UIControl *control, id actionTarget, SEL action)
{
    RUINHandleHook(&gControlSendActionHook, control, @selector(sendAction:to:forEvent:),
        actionTarget, nil, action);
    RUINConfirmationPending *pending = gPendingConfirmation;
    assert(pending && pending.sendComposer == control.superview);
    assert(gPromptCount == 1 && !gControlOriginalCount && !gSendOriginalCount);
    assert(RUINPendingIsCurrent(pending, pending.ownerTicket));
    assert(RUINValidatePendingContext(pending));
    return pending;
}

static void CheckProductionRelay(void)
{
    // A different target and action is admitted only through the real lazy ivar
    // resolver. Test direct send: separately, without the lazy identity fallback.
    for (NSUInteger scenario = 0; scenario < 11; scenario++) {
        ResetProductionShim();
        _TtC15LineMessagingUI12ChatInputBar *composer = [_TtC15LineMessagingUI12ChatInputBar new];
        _TtC15LineMessagingUI12ChatInputBar *otherComposer = [_TtC15LineMessagingUI12ChatInputBar new];
        UIControl *control = [UIControl new];
        UIControl *wrongSender = [UIControl new];
        control.superview = composer;
        RUINConfirmationRelayShim *relay = [RUINConfirmationRelayShim new];
        relay.composer = composer;
        relay.forwardedAction = sel_registerName("send:");
        relay.duplicate = YES;
        BOOL direct = scenario == 0;
        if (!direct) composer.sendButton = control;

        RUINConfirmationPending *pending = BeginProductionSend(control, direct ? composer : relay,
            direct ? sel_registerName("send:") : @selector(relay:));
        // Another tap while the alert owns the ticket must not replay the action.
        RUINHandleHook(&gControlSendActionHook, control, pending.selector,
            pending.argument0, nil, pending.dispatchedAction);
        assert(gPromptCount == 1 && !gControlOriginalCount);
        if (scenario == 2) relay.composer = otherComposer;
        if (scenario == 3) relay.sender = wrongSender;
        if (scenario == 4) relay.forwardedAction = sel_registerName("otherAction:");
        if (scenario == 5) gDuringControlOriginal = ^{ gApprovedSendPermit->ticket++; };
        if (scenario == 6) gDuringControlOriginal = ^{ control.superview = otherComposer; };
        if (scenario == 7) gDuringControlOriginal = ^{ composer.sendButton = wrongSender; };
        if (scenario == 8) gDuringControlOriginal = ^{ gContextValid = NO; };
        if (scenario == 9) gDuringControlOriginal = ^{
            RUINHandleHook(&gUnrelatedHook, composer, sel_registerName("send:"), control, nil, NULL);
            assert(!gOtherOriginalCount);
            // Invalid attempts must not consume the valid composer's permit.
            RUINHandleHook(&gChatInputSendHook, otherComposer, sel_registerName("send:"), control, nil, NULL);
            RUINHandleHook(&gChatInputSendHook, composer, sel_registerName("send:"), wrongSender, nil, NULL);
            RUINHandleHook(&gChatInputSendHook, composer, sel_registerName("otherAction:"), control, nil, NULL);
            assert(!gSendOriginalCount && !gApprovedSendPermit->consumed);
        };
        if (scenario == 10) gDuringControlOriginal = ^{ gApprovedSendPermit->pending = nil; };

        assert(RUINConfirmationRecordDecision(&pending->lifecycle, &pending->decision, YES));
        __weak UIAlertController *weakAlert = pending.alert;
        RUINInvokeApprovedOriginal(pending, pending.ownerTicket, RUINConfirmationDismissalComplete);
        BOOL shouldSend = scenario < 2 || scenario == 9;
        assert(gControlOriginalCount == 1 && gSendOriginalCount == (NSUInteger)shouldSend);
        assert(gPromptCount == 1 && !gOtherOriginalCount);
        assert(pending->originalPermitConsumed && pending->lifecycle == RUINConfirmationLifecycleCompleted);
        assert(!gPendingConfirmation && !gPendingOwnerTickets.active && !gApprovedSendPermit);
        assert(!pending.alert && !weakAlert);

        // Completion and later callbacks cannot reuse the permit or original.
        RUINConfirmationSendPermit stale = {.pending = pending, .ticket = pending.ownerTicket};
        gApprovedSendPermit = &stale;
        assert(!RUINIsApprovedSendReentry(&gChatInputSendHook, composer, sel_registerName("send:"), control));
        gApprovedSendPermit = NULL;
        RUINInvokeApprovedOriginal(pending, pending.ownerTicket, RUINConfirmationDismissalComplete);
        assert(gControlOriginalCount == 1 && gSendOriginalCount == (NSUInteger)shouldSend);
        gDuringControlOriginal = nil;
    }
}

static void CheckProductionBoundaryAndCancellation(void)
{
    ResetProductionShim();
    _TtC15LineMessagingUI12ChatInputBar *composer = [_TtC15LineMessagingUI12ChatInputBar new];
    _TtC15LineMessagingUI12ChatInputBar *otherComposer = [_TtC15LineMessagingUI12ChatInputBar new];
    UIControl *control = [UIControl new];
    control.superview = composer;
    assert(RUINComposerForSendControl(control, composer, sel_registerName("send:")) == composer);
    assert(!RUINComposerForSendControl(control, otherComposer, sel_registerName("send:")));
    assert(!RUINComposerForSendControl(control, composer, sel_registerName("otherAction:")));
    assert(!RUINComposerForSendControl([NSObject new], composer, sel_registerName("send:")));

    RUINConfirmationPending *pending = BeginProductionSend(control, composer, sel_registerName("send:"));
    assert(RUINConfirmationRecordDecision(&pending->lifecycle, &pending->decision, NO));
    assert(RUINReleasePending(pending, pending.ownerTicket));
    assert(!pending.alert && !gControlOriginalCount && !gSendOriginalCount);

    gPromptCount = 0;
    pending = BeginProductionSend(control, composer, sel_registerName("send:"));
    control.superview = otherComposer;
    assert(!RUINValidatePendingContext(pending));
    RUINAbortPending(pending, pending.ownerTicket, YES);
    assert(pending->lifecycle == RUINConfirmationLifecycleAborted);
    assert(!pending.alert && !gPendingConfirmation && !gPendingOwnerTickets.active);
    assert(!gControlOriginalCount && !gSendOriginalCount);

    // Disabled confirmations continue to invoke the native action directly.
    control.superview = composer;
    gEnabled = NO;
    RUINHandleHook(&gControlSendActionHook, control, @selector(sendAction:to:forEvent:),
        composer, nil, sel_registerName("send:"));
    assert(gControlOriginalCount == 1 && gSendOriginalCount == 1);
}

static void CheckProductionFailureCleanup(void)
{
    for (NSUInteger failure = 0; failure < 2; failure++) {
        BOOL throws = failure == 1;
        ResetProductionShim();
        _TtC15LineMessagingUI12ChatInputBar *composer = [_TtC15LineMessagingUI12ChatInputBar new];
        UIControl *control = [UIControl new];
        control.superview = composer;
        RUINConfirmationPending *pending = BeginProductionSend(control, composer, sel_registerName("send:"));
        assert(RUINConfirmationRecordDecision(&pending->lifecycle, &pending->decision, YES));
        if (throws) {
            gDuringControlOriginal = ^{ @throw [NSException exceptionWithName:@"shim" reason:nil userInfo:nil]; };
        } else {
            pending.original = NULL;
        }
        BOOL caught = NO;
        @try {
            RUINInvokeApprovedOriginal(pending, pending.ownerTicket, RUINConfirmationDismissalComplete);
        } @catch (NSException *exception) {
            assert([exception.name isEqualToString:@"shim"]);
            caught = YES;
        }
        assert(caught == throws && gControlOriginalCount == (NSUInteger)throws && !gSendOriginalCount);
        assert(pending->lifecycle == RUINConfirmationLifecycleAborted && !pending.alert);
        assert(!gPendingConfirmation && !gPendingOwnerTickets.active && !gApprovedSendPermit);
        gDuringControlOriginal = nil;
    }
}

int main(void)
{
    @autoreleasepool {
        CheckRoutingAndUIKitClassification();
        CheckOwnerTickets();
        CheckDecisionLifecycle();
        CheckSingleUseSendReentry();
        CheckAlertOwnership();
        CheckProductionRelay();
        CheckProductionBoundaryAndCancellation();
        CheckProductionFailureCleanup();
    }
    return 0;
}
