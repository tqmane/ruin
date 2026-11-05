#import <Foundation/Foundation.h>

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

typedef NS_ENUM(NSInteger, RUINConfirmationSendDisposition) {
    RUINConfirmationSendMissingThread,
    RUINConfirmationSendBypass,
    RUINConfirmationSendConfirm
};

static inline RUINConfirmationGateDisposition RUINConfirmationGate(BOOL enabled, BOOL approvedInvocation, BOOL pending)
{
    if (!enabled || approvedInvocation) return RUINConfirmationGateInvokeOriginal;
    return pending ? RUINConfirmationGateSuppress : RUINConfirmationGateContinue;
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
