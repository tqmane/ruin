#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const RUINTargetBundleIdentifier;
FOUNDATION_EXPORT NSString * const RUINReadControlEnabledDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINLocalNamesDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINLocalNamesByIdentityDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINReadExceptionsDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINMarkReadOnReplyDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINLocalLYPEnabledDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINLegacyMessagingEnabledDefaultsKey;

/**
 RUINLocalNamesByIdentity maps user:<mid>, chat:<mid>, group:<id>, or
 squareChat:<mid> to aliases. RUINLocalNames remains a legacy visible-name
 fallback; legacy names can collide and are never inferred to be identities.
 RUINReadExceptions is an array of chat:/squareChat: identity keys.
 Call RUINInstallFeatures again after changing feature preferences or accounts.
 Reloading preferences clears transient reply allowances. Preferences are
 scoped to this signed app, with globally stable entity IDs rather than an
 unverified account identifier.
 */
FOUNDATION_EXPORT void RUINInstallFeatures(void);
/**
 Retry hooks and reload settings on foreground activation. Transient reply
 state survives only if the validated current account and read policy match.
 Missing/changed accounts, policy changes and explicit installs invalidate it.
 The account is kept in memory only and is never included in diagnostics.
 */
FOUNDATION_EXPORT void RUINRefreshFeaturesOnActivation(NSString * _Nullable accountMID);

/** Runtime metadata and in-memory call counts only; no chat content or IDs. */
FOUNDATION_EXPORT NSDictionary *RUINFeatureDiagnostics(void);

/**
 Interactive use only, on the managed object's owning queue. Returns
 {kind, identifier, displayName}, or {} if unsupported/unresolved. displayName
 is original text, and can be empty for a context-dependent ManagedChat name.
 Never call this API to populate logs or diagnostics.
 */
FOUNDATION_EXPORT NSDictionary *RUINIdentityForObject(id object);

/** Empty alias opts this identity out of both its alias and legacy fallback. */
FOUNDATION_EXPORT void RUINSetLocalName(NSString *identityKey, NSString *alias);

/** Call on the chat object's owning queue. Unresolved identities fail open. */
FOUNDATION_EXPORT BOOL RUINShouldSuppressReadForChat(id chat);
FOUNDATION_EXPORT BOOL RUINReadPolicyHasIdentity(id chat);

/**
 Parent calls only after a verified, user-approved reply is committed, on the
 chat's owning queue. With RUINMarkReadOnReply enabled, permits LINE's original
 predicate while lastReceivedMessageID is unchanged; it sends no receipt and
 makes no claim that a receipt was sent. ReadOnReply correlates a native sent
 notification with its explicit send entry before calling the token API below.
 */
FOUNDATION_EXPORT void RUINAllowReadAfterUserReply(id chat);
/** Copy at send entry; commit only on that message's successful sent notification. */
FOUNDATION_EXPORT NSDictionary *RUINCaptureReadOnReplyToken(id chat);
FOUNDATION_EXPORT BOOL RUINAllowReadAfterUserReplyWithToken(id chat, NSDictionary *token);
/** Called before lastReceivedMessageID changes; returns the revoked allowance for an unchanged-value notification. */
FOUNDATION_EXPORT NSDictionary *RUINRevokeReadAfterUserReply(id chat);
/** Copied-token check for the main-queue gate write; does not access a managed object. */
FOUNDATION_EXPORT BOOL RUINReadOnReplyTokenNeedsRearm(NSDictionary *token);
FOUNDATION_EXPORT BOOL RUINReadOnReplyTokenIsAllowed(NSDictionary *token);
FOUNDATION_EXPORT void RUINSetReplyObserverInstalled(BOOL installed);

NS_ASSUME_NONNULL_END
