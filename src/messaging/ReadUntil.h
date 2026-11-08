#pragma once
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const RUINReadUntilErrorDomain;
typedef NS_ENUM(NSInteger, RUINReadUntilErrorCode) {
    RUINReadUntilInvalidSelection = 1,
    RUINReadUntilUnavailable,
    RUINReadUntilChatMismatch,
    RUINReadUntilInvalidNativeResult,
    RUINReadUntilNativeException
};

typedef void (^RUINReadUntilCompletion)(NSError * _Nullable error);

/** Checks the host's verified callback ABI and native service selectors. */
FOUNDATION_EXPORT BOOL RUINReadUntilAvailable(void);

// LINE 26.17 only. The caller supplies a selected RUINHistoryMessageKey and
// rechecks its live menu binding. Account/store/chat validation is repeated
// here on the chat's owning context. The selected decimal string is preserved.
//
// Completion is delivered once, possibly synchronously/on a native callback
// queue. nil means native request success, not local-save completion. LINE's
// native success path owns the ensuing selected-ID cursor update and save.
// The native cursor update must keep its original synchronized value.
// This adapter never changes read-hide
// preferences, reply allowances, automatic gates, or Core Data primitives.
FOUNDATION_EXPORT void RUINReadUntilMessage(NSDictionary *messageKey,
                                          NSManagedObject *nativeChat,
                                          RUINReadUntilCompletion completion);

NS_ASSUME_NONNULL_END
