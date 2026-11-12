#define RUIN_CONFIRMATIONS_INTERNAL 1
#import "../src/interface/Confirmations.h"

#include <assert.h>
#include <stdint.h>

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
    assert(RUINConfirmationConsumeSendReentry(&consumed, 4, 4, YES, YES,
        &inputBar, &control, &sendSelector, &inputBar, &control, &sendSelector, &sendSelector));
    assert(consumed);
    assert(!RUINConfirmationConsumeSendReentry(&consumed, 4, 4, YES, YES,
        &inputBar, &control, &sendSelector, &inputBar, &control, &sendSelector, &sendSelector));

    consumed = NO;
    assert(!RUINConfirmationConsumeSendReentry(&consumed, 4, 4, YES, YES,
        &inputBar, &control, &sendSelector, &inputBar, &otherControl, &sendSelector, &sendSelector));
    assert(!consumed);
    assert(!RUINConfirmationConsumeSendReentry(&consumed, 4, 4, YES, YES,
        &inputBar, &control, &sendSelector, &inputBar, &control, &otherSelector, &sendSelector));
    assert(!RUINConfirmationConsumeSendReentry(&consumed, 3, 4, YES, YES,
        &inputBar, &control, &sendSelector, &inputBar, &control, &sendSelector, &sendSelector));
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

int main(void)
{
    @autoreleasepool {
        CheckRoutingAndUIKitClassification();
        CheckOwnerTickets();
        CheckDecisionLifecycle();
        CheckSingleUseSendReentry();
        CheckAlertOwnership();
    }
    return 0;
}
