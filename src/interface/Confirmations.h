#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const RUINConfirmSendEnabledDefaultsKey;
/** Minimum total group members, including the current user. Unset means confirm every verified group send. */
FOUNDATION_EXPORT NSString * const RUINConfirmSendMinimumGroupMemberCountDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINConfirmCallEnabledDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINConfirmCameraOnEnabledDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINConfirmDisconnectEnabledDefaultsKey;

/** Installs exact, build-gated foreground UI action hooks. All feature switches default to off. */
FOUNDATION_EXPORT void RUINInstallConfirmations(void);

/** Hook state and counters only; no chat IDs, message text, or call participant data. */
FOUNDATION_EXPORT NSDictionary *RUINConfirmationDiagnostics(void);

#if defined(RUIN_CONFIRMATIONS_INTERNAL)
typedef NS_ENUM(NSInteger, RUINConfirmationGateDisposition) {
    RUINConfirmationGateInvokeOriginal,
    RUINConfirmationGateContinue,
    RUINConfirmationGateSuppress
};

typedef NS_ENUM(NSInteger, RUINConfirmationActionClass) {
    RUINConfirmationActionProtected,
    RUINConfirmationActionPassThrough,
    RUINConfirmationActionUnknownProtected
};

typedef NS_ENUM(NSInteger, RUINConfirmationDismissalState) {
    RUINConfirmationDismissalWaiting,
    RUINConfirmationDismissalComplete,
    RUINConfirmationDismissalOtherModal,
    RUINConfirmationDismissalTimedOut
};

typedef NS_ENUM(NSInteger, RUINConfirmationLifecycle) {
    RUINConfirmationLifecycleAwaitingDecision,
    RUINConfirmationLifecycleWaitingForDismissal,
    RUINConfirmationLifecycleInvoking,
    RUINConfirmationLifecycleCompleted,
    RUINConfirmationLifecycleAborted,
    RUINConfirmationLifecycleCancelled
};

typedef NS_ENUM(NSInteger, RUINConfirmationDecision) {
    RUINConfirmationDecisionNone,
    RUINConfirmationDecisionApprove,
    RUINConfirmationDecisionCancel
};

typedef struct {
    uint64_t lastIssued;
    uint64_t active;
} RUINConfirmationOwnerTickets;

typedef NS_ENUM(NSInteger, RUINConfirmationSendDisposition) {
    RUINConfirmationSendMissingThread,
    RUINConfirmationSendBypass,
    RUINConfirmationSendConfirm
};

static inline RUINConfirmationGateDisposition RUINConfirmationGate(BOOL enabled, BOOL approvedInvocation, BOOL mainThread)
{
    if (!enabled || approvedInvocation) return RUINConfirmationGateInvokeOriginal;
    return mainThread ? RUINConfirmationGateContinue : RUINConfirmationGateSuppress;
}

static inline RUINConfirmationGateDisposition RUINConfirmationClassifiedGate(
    RUINConfirmationActionClass actionClass, BOOL pending)
{
    if (actionClass == RUINConfirmationActionPassThrough)
        return RUINConfirmationGateInvokeOriginal;
    if (actionClass == RUINConfirmationActionUnknownProtected || pending)
        return RUINConfirmationGateSuppress;
    return RUINConfirmationGateContinue;
}

static inline RUINConfirmationActionClass RUINConfirmationClassifyCameraButtons(
    BOOL senderInVideoOffButtons, BOOL senderInVideoOnButtons)
{
    if (senderInVideoOffButtons && !senderInVideoOnButtons)
        return RUINConfirmationActionProtected;
    if (senderInVideoOnButtons && !senderInVideoOffButtons)
        return RUINConfirmationActionPassThrough;
    return RUINConfirmationActionUnknownProtected;
}

static inline BOOL RUINConfirmationIsComposerControl(BOOL isControl, BOOL hasComposerAncestor,
    BOOL targetsInputBarSend, BOOL isVerifiedSendButton)
{
    return isControl && hasComposerAncestor && (targetsInputBarSend || isVerifiedSendButton);
}

static inline RUINConfirmationActionClass RUINConfirmationClassifyAction(BOOL requiresComposerBoundary,
    BOOL composerBoundaryMatched, BOOL requiresSenderIdentity, BOOL senderIdentityMatched,
    BOOL cameraToggle, BOOL senderInVideoOffButtons, BOOL senderInVideoOnButtons)
{
    if ((requiresComposerBoundary && !composerBoundaryMatched) ||
        (requiresSenderIdentity && !senderIdentityMatched)) return RUINConfirmationActionPassThrough;
    if (cameraToggle)
        return RUINConfirmationClassifyCameraButtons(senderInVideoOffButtons, senderInVideoOnButtons);
    return RUINConfirmationActionProtected;
}

static inline RUINConfirmationDismissalState RUINConfirmationObserveDismissal(
    BOOL alertStillPresented, BOOL alertBeingDismissed, BOOL alertViewAttached,
    BOOL anotherModalPresented, BOOL timedOut)
{
    if (anotherModalPresented) return RUINConfirmationDismissalOtherModal;
    if (!alertStillPresented && !alertBeingDismissed && !alertViewAttached)
        return RUINConfirmationDismissalComplete;
    return timedOut ? RUINConfirmationDismissalTimedOut : RUINConfirmationDismissalWaiting;
}

static inline uint64_t RUINConfirmationIssueOwnerTicket(RUINConfirmationOwnerTickets *tickets)
{
    if (!tickets || tickets->active || tickets->lastIssued == UINT64_MAX) return 0;
    tickets->active = ++tickets->lastIssued;
    return tickets->active;
}

static inline BOOL RUINConfirmationOwnsTicket(const RUINConfirmationOwnerTickets *tickets, uint64_t ticket)
{
    return tickets && ticket && tickets->active == ticket;
}

static inline BOOL RUINConfirmationReleaseTicket(RUINConfirmationOwnerTickets *tickets, uint64_t ticket)
{
    if (!RUINConfirmationOwnsTicket(tickets, ticket)) return NO;
    tickets->active = 0;
    return YES;
}

static inline BOOL RUINConfirmationRecordDecision(RUINConfirmationLifecycle *lifecycle,
    RUINConfirmationDecision *decision, BOOL approved)
{
    if (!lifecycle || !decision || *lifecycle != RUINConfirmationLifecycleAwaitingDecision ||
        *decision != RUINConfirmationDecisionNone) return NO;
    *decision = approved ? RUINConfirmationDecisionApprove : RUINConfirmationDecisionCancel;
    *lifecycle = approved ? RUINConfirmationLifecycleWaitingForDismissal : RUINConfirmationLifecycleCancelled;
    return YES;
}

static inline BOOL RUINConfirmationBeginInvocation(RUINConfirmationLifecycle *lifecycle,
    BOOL originalAvailable, BOOL *permitConsumed)
{
    if (!lifecycle || !permitConsumed || *lifecycle != RUINConfirmationLifecycleWaitingForDismissal ||
        !originalAvailable || *permitConsumed) return NO;
    *permitConsumed = YES;
    *lifecycle = RUINConfirmationLifecycleInvoking;
    return YES;
}

static inline BOOL RUINConfirmationBeginInvocationAfterDismissal(RUINConfirmationLifecycle *lifecycle,
    RUINConfirmationDismissalState dismissal, BOOL originalAvailable, BOOL *permitConsumed)
{
    return dismissal == RUINConfirmationDismissalComplete &&
        RUINConfirmationBeginInvocation(lifecycle, originalAvailable, permitConsumed);
}

static inline BOOL RUINConfirmationFinishInvocation(RUINConfirmationLifecycle *lifecycle, BOOL returned)
{
    if (!lifecycle || *lifecycle != RUINConfirmationLifecycleInvoking) return NO;
    *lifecycle = returned ? RUINConfirmationLifecycleCompleted : RUINConfirmationLifecycleAborted;
    return YES;
}

static inline BOOL RUINConfirmationAbort(RUINConfirmationLifecycle *lifecycle)
{
    if (!lifecycle || (*lifecycle != RUINConfirmationLifecycleAwaitingDecision &&
        *lifecycle != RUINConfirmationLifecycleWaitingForDismissal &&
        *lifecycle != RUINConfirmationLifecycleInvoking)) return NO;
    *lifecycle = RUINConfirmationLifecycleAborted;
    return YES;
}

static inline BOOL RUINConfirmationConsumeSendReentry(BOOL *permitConsumed,
    uint64_t permitTicket, uint64_t ownerTicket, BOOL controlActionOrigin, BOOL inputBarSendHook,
    const void *expectedInputBar, const void *expectedControl, const void *expectedAction,
    const void *receiver, const void *sender, const void *selector, const void *sendSelector)
{
    if (!permitConsumed || *permitConsumed || !permitTicket || permitTicket != ownerTicket ||
        !controlActionOrigin || !inputBarSendHook || !expectedInputBar || expectedInputBar != receiver ||
        !expectedControl || expectedControl != sender || expectedAction != sendSelector ||
        selector != sendSelector) return NO;
    *permitConsumed = YES;
    return YES;
}

static inline RUINConfirmationSendDisposition RUINConfirmationEvaluateSend(BOOL threadKnown,
    BOOL oneOnOneKnown, BOOL oneOnOne, BOOL memberCountKnown, NSInteger totalMembers,
    BOOL thresholdConfigured, NSInteger minimumMembers)
{
    if (!threadKnown) return RUINConfirmationSendMissingThread;
    if (oneOnOneKnown && oneOnOne) return RUINConfirmationSendBypass;
    if (oneOnOneKnown && !oneOnOne && memberCountKnown && thresholdConfigured &&
        totalMembers < minimumMembers) return RUINConfirmationSendBypass;
    return RUINConfirmationSendConfirm;
}
#endif

NS_ASSUME_NONNULL_END
