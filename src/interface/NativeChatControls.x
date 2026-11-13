%config(generator=internal);

#import "TargetMetadata.h"
#import <Foundation/Foundation.h>

// Preserve only the member-count suffix actually rendered by LINE's group
// title. Identity and original name still come from the validated owner queue.
static NSString *RUINNativeMemberSuffix(NSString *title, BOOL group)
{
    if (!group) return @"";
    static NSRegularExpression *expression;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ expression = [NSRegularExpression regularExpressionWithPattern:@" \\([0-9]+\\)$" options:0 error:NULL]; });
    NSTextCheckingResult *match = [expression firstMatchInString:title ?: @"" options:0 range:NSMakeRange(0, title.length)];
    return match ? [title substringWithRange:match.range] : @"";
}

static NSString *RUINNativeOriginalTitle(NSString *visibleTitle, NSString *originalName, BOOL group)
{
    if (!group || !originalName.length) return visibleTitle ?: @"";
    if ([visibleTitle isEqual:originalName]) return originalName;
    return [originalName stringByAppendingString:RUINNativeMemberSuffix(visibleTitle, YES)];
}

#if defined(RUIN_NATIVE_TITLE_HOST_CHECK)
#import <assert.h>
int main(void) { @autoreleasepool {
    assert([RUINNativeMemberSuffix(@"てすたーず (2)", YES) isEqual:@" (2)"]);
    assert([RUINNativeOriginalTitle(@"R25 (2)", @"てすたーず", YES) isEqual:@"てすたーず (2)"]);
    assert([RUINNativeOriginalTitle(@"Original (2) (3)", @"Original (2)", YES) isEqual:@"Original (2) (3)"]);
    assert([RUINNativeOriginalTitle(@"Original (2)", @"Original (2)", YES) isEqual:@"Original (2)"]);
    assert([RUINNativeMemberSuffix(@"Friend (2)", NO) isEqual:@""]);
    assert([RUINNativeMemberSuffix(@"Name (x)", YES) isEqual:@""]);
    assert([RUINNativeMemberSuffix(@"Name (2) trailing", YES) isEqual:@""]);
    assert([RUINNativeOriginalTitle(@"Friend", @"Other", NO) isEqual:@"Friend"]);
    puts("PASS original group name/member-count preservation, alias restoration, literal name suffix and one-to-one isolation");
} return 0; }
#else
#import "NativeChatControls.h"
#import "../core/Localization.h"

#import "Features.h"
#import "LINEPrivateCalls.h"
#import "SwiftFields.h"
#import "AutomaticReadGate.h"

#import <CoreData/CoreData.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <string.h>

static NSString * const RUINNativeChatControllerName = @"_TtC15LineMessagingUI18ChatViewController";
static const char * const RUINNativeChatControllerClass = "_TtC15LineMessagingUI18ChatViewController";
static const char * const RUINNativeChatViewDidAppearEncoding = "v20@0:8B16";
static const char * const RUINNativeChatViewDidLayoutSubviewsEncoding = "v16@0:8";
static const char * const RUINNativeChatGetterEncoding = "@16@0:8";
static const char * const RUINNativeChatOneOnOneEncoding = "B16@0:8";

typedef NS_ENUM(NSInteger, RUINNativeChatHookState) {
    RUINNativeChatHookPending,
    RUINNativeChatHookVersionGated,
    RUINNativeChatHookMissingClass,
    RUINNativeChatHookMissingSelector,
    RUINNativeChatHookEncodingMismatch,
    RUINNativeChatHookActionInstallFailed,
    RUINNativeChatHookInstalled
};

@interface RUINNativeTitleGestureRecord : NSObject
@property(nonatomic, weak) UIView *view;
@property(nonatomic, weak) UILongPressGestureRecognizer *recognizer;
@property(nonatomic) BOOL originalUserInteractionEnabled;
@end

@implementation RUINNativeTitleGestureRecord
@end

@interface RUINNativeTitleAliasRecord : NSObject
@property(nonatomic, weak) id chatObject;
@property(nonatomic, weak) UIView *contentView;
@property(nonatomic, weak) UILabel *label;
@property(nonatomic, copy, nullable) NSString *identityKey;
@property(nonatomic, copy, nullable) NSString *nativeTitle;
@property(nonatomic, copy, nullable) NSString *originalName;
@property(nonatomic, copy, nullable) NSString *appliedAlias;
@property(nonatomic) BOOL resolving;
@property(nonatomic) BOOL resolved;
@end

@implementation RUINNativeTitleAliasRecord
@end

@interface RUINNativeChatIdentity : NSObject
@property(nonatomic, strong) id chatObject;
@property(nonatomic, copy, nullable) NSString *readExceptionKey;
@property(nonatomic, copy, nullable) NSString *localNameKey;
@property(nonatomic, copy, nullable) NSString *localNameOriginalText;
@property(nonatomic, copy, nullable) NSString *midToCopy;
@end

@implementation RUINNativeChatIdentity
@end

static os_unfair_lock gNativeChatInstallLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gReadExceptionDefaultsLock = OS_UNFAIR_LOCK_INIT;
static _Atomic(IMP) gOriginalChatViewDidAppear = ATOMIC_VAR_INIT(NULL);
static _Atomic(IMP) gOriginalChatViewDidLayoutSubviews = ATOMIC_VAR_INIT(NULL);
static atomic_int gNativeChatHookState = ATOMIC_VAR_INIT(RUINNativeChatHookPending);
static atomic_bool gTitleAliasLayoutHookInstalled = ATOMIC_VAR_INIT(false);
static BOOL gNativeChatActionMethodsInstalled;
static BOOL gNativeChatAppearanceHookInstalled;
static atomic_uint_fast64_t gViewDidAppearCalls = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gTitleGestureAttachCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gMissingTitleViewCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gUnreliableTitleViewCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gMissingChatContextCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gMissingAliasIdentityCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gMissingReadIdentityCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gStaleUIActionCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gLocalNameEditorCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gLocalNameSaveCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gMIDCopyCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gReadExceptionToggleCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gReadExceptionArrayRepairCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gStoredGroupIdentityCount = ATOMIC_VAR_INIT(0);
static NSString * const gIdentityFailureNames[] = {
    @"inactiveController", @"chatUnavailable", @"managedContextUnavailable",
    @"readIdentityUnavailable", @"chatTypeUnsupported", @"oneOnOneMetadataMissing",
    @"swiftChatContextUnavailable", @"swiftChatContextChatMismatch",
    @"swiftGroupUnavailable", @"swiftGroupClassMismatch", @"unifiedGroupContextUnavailable",
    @"unifiedGroupSchemaMismatch", @"unifiedGroupIdentityMissing", @"unifiedGroupIDMissing",
    @"unifiedGroupIDMismatch", @"nativeGroupIdentityLookupException",
    @"nativeIdentityLookupException", @"unclassifiedFailure"
};
static atomic_uint_fast64_t gIdentityFailureCounts[sizeof(gIdentityFailureNames) / sizeof(gIdentityFailureNames[0])];

static void RUINCountIdentityFailure(NSString *failure)
{
    if (!failure) return;
    const size_t count = sizeof(gIdentityFailureNames) / sizeof(gIdentityFailureNames[0]);
    for (size_t index = 0; index < count - 1; index++) {
        if ([failure isEqualToString:gIdentityFailureNames[index]]) {
            atomic_fetch_add(&gIdentityFailureCounts[index], 1);
            return;
        }
    }
    atomic_fetch_add(&gIdentityFailureCounts[count - 1], 1);
}

static char gTitleGestureRecordKey;
static char gTitleAliasRecordKey;
static char gReadExceptionButtonKey;
static char gCustomReadExceptionButtonKey;
static void RUINNativeChatViewDidAppear(id self, SEL selector, BOOL animated);
static void RUINNativeChatViewDidLayoutSubviews(id self, SEL selector);
static void RUINToggleReadException(id self, SEL selector, id sender);
static void RUINTitleLongPressed(id self, SEL selector, id sender);
static void RUINRefreshNativeTitleAlias(UIViewController *controller);

typedef void (^RUINNativeChatIdentityCompletion)(RUINNativeChatIdentity * _Nullable identity,
                                                  NSString * _Nullable failure);

static BOOL RUINNativeTargetMatches(void)
{
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
}

static Method RUINNativeOwnMethod(Class cls, SEL selector)
{
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            found = methods[index];
            break;
        }
    }
    free(methods);
    return found;
}

%group RUINNativeChatActions
%hook RUINNativeChatActionTarget
%new(v24@0:8@16)
- (void)ruin_nativeTitleLongPressed:(id)sender
{
    RUINTitleLongPressed(self, _cmd, sender);
}
%new(v24@0:8@16)
- (void)ruin_nativeToggleReadException:(id)sender
{
    RUINToggleReadException(self, _cmd, sender);
}
%end
%end

%group RUINNativeChatAppearance
%hook RUINNativeChatAppearanceTarget
- (void)viewDidAppear:(BOOL)animated
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&gOriginalChatViewDidAppear, original, memory_order_release);
    RUINNativeChatViewDidAppear(self, _cmd, animated);
}
%end
%end

%group RUINNativeChatLayout
%hook RUINNativeChatLayoutTarget
- (void)viewDidLayoutSubviews
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&gOriginalChatViewDidLayoutSubviews, original, memory_order_release);
    RUINNativeChatViewDidLayoutSubviews(self, _cmd);
}
%end
%end

static BOOL RUINInstallTitleAliasLayoutHook(Class cls)
{
    if (atomic_load(&gTitleAliasLayoutHookInstalled)) return YES;
    SEL selector = @selector(viewDidLayoutSubviews);
    Method method = class_getInstanceMethod(cls, selector);
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    if (!actual || strcmp(actual, RUINNativeChatViewDidLayoutSubviewsEncoding) != 0) return NO;
    IMP current = method_getImplementation(method);
    if (!current) return NO;
    atomic_store_explicit(&gOriginalChatViewDidLayoutSubviews, current, memory_order_release);
    %init(RUINNativeChatLayout, RUINNativeChatLayoutTarget = cls);
    return YES;
}

void RUINInstallNativeChatControls(void)
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINInstallNativeChatControls(); });
        return;
    }
    os_unfair_lock_lock(&gNativeChatInstallLock);
    if (!RUINNativeTargetMatches()) {
        atomic_store(&gNativeChatHookState, RUINNativeChatHookVersionGated);
        os_unfair_lock_unlock(&gNativeChatInstallLock);
        return;
    }

    Class cls = objc_getClass(RUINNativeChatControllerClass);
    if (!cls) {
        atomic_store(&gNativeChatHookState, RUINNativeChatHookMissingClass);
        os_unfair_lock_unlock(&gNativeChatInstallLock);
        return;
    }

    SEL didAppear = @selector(viewDidAppear:);
    Method method = RUINNativeOwnMethod(cls, didAppear);
    if (!method) {
        atomic_store(&gNativeChatHookState, RUINNativeChatHookMissingSelector);
        os_unfair_lock_unlock(&gNativeChatInstallLock);
        return;
    }
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || strcmp(encoding, RUINNativeChatViewDidAppearEncoding) != 0) {
        atomic_store(&gNativeChatHookState, RUINNativeChatHookEncodingMismatch);
        os_unfair_lock_unlock(&gNativeChatInstallLock);
        return;
    }

    BOOL actionsReady = gNativeChatActionMethodsInstalled;
    if (!actionsReady &&
        !class_getInstanceMethod(cls, sel_registerName("ruin_nativeTitleLongPressed:")) &&
        !class_getInstanceMethod(cls, sel_registerName("ruin_nativeToggleReadException:"))) {
        %init(RUINNativeChatActions, RUINNativeChatActionTarget = cls);
        actionsReady = gNativeChatActionMethodsInstalled = YES;
    }
    if (!actionsReady) {
        atomic_store(&gNativeChatHookState, RUINNativeChatHookActionInstallFailed);
        os_unfair_lock_unlock(&gNativeChatInstallLock);
        return;
    }

    atomic_store(&gTitleAliasLayoutHookInstalled, RUINInstallTitleAliasLayoutHook(cls));

    if (!gNativeChatAppearanceHookInstalled) {
        IMP current = method_getImplementation(method);
        if (!current) {
            atomic_store(&gNativeChatHookState, RUINNativeChatHookActionInstallFailed);
            os_unfair_lock_unlock(&gNativeChatInstallLock);
            return;
        }
        atomic_store_explicit(&gOriginalChatViewDidAppear, current, memory_order_release);
        %init(RUINNativeChatAppearance, RUINNativeChatAppearanceTarget = cls);
        gNativeChatAppearanceHookInstalled = YES;
    }
    atomic_store(&gNativeChatHookState, RUINNativeChatHookInstalled);
    os_unfair_lock_unlock(&gNativeChatInstallLock);
}

static UIViewController *RUINNativeChatController(id object)
{
    Class cls = objc_getClass(RUINNativeChatControllerClass);
    if (!object || !cls || ![object isKindOfClass:cls]) return nil;
    SEL selector = @selector(chat);
    Method method = class_getInstanceMethod(cls, selector);
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    if (!actual || strcmp(actual, RUINNativeChatGetterEncoding) != 0) return nil;
    return object;
}

static id RUINNativeChatObject(UIViewController *controller)
{
    if (!controller || !RUINNativeChatController(controller)) return nil;
    return [(id<RUINLINEChatControllerCalls>)controller chat];
}

static BOOL RUINNativeControllerIsCurrent(UIViewController *controller, id chat)
{
    if (![NSThread isMainThread] || !controller.isViewLoaded || !controller.view.window ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
        return NO;
    return RUINNativeChatObject(controller) == chat;
}

static NSString *RUINIdentityKey(NSDictionary *identity, BOOL chatOnly)
{
    id kind = identity[@"kind"];
    id identifier = identity[@"identifier"];
    if (![kind isKindOfClass:NSString.class] || ![identifier isKindOfClass:NSString.class] ||
        ![(NSString *)identifier length]) return nil;
    BOOL validChatKind = [kind isEqualToString:@"chat"] || [kind isEqualToString:@"squareChat"];
    BOOL validAliasKind = validChatKind || [kind isEqualToString:@"user"] || [kind isEqualToString:@"group"];
    if (chatOnly ? !validChatKind : !validAliasKind) return nil;
    return [NSString stringWithFormat:@"%@:%@", kind, identifier];
}

// LINE26 ChatContext descriptor 0x10a9681bc, group field record 0x10ae8d41c:
// Optional<NSManagedObject & native group protocol>, not a concrete group class.
// The live class/entity/property guards below establish ManagedUnifiedGroup.
// groupWithContext: (0x104029074) forwards its context into a different store's
// group fetch (0x104029060 -> 0x105958798); never pass the chat's Talk context.
static NSManagedObject *RUINLiveGroupForChat(id controller, id chat, NSString **failure)
{
    id chatContext = RUINCopySwiftField(controller, "chatContext");
    Class contextClass = objc_getClass("_TtC15LineMessagingUI11ChatContext");
    if (!contextClass || object_getClass(chatContext) != contextClass) {
        if (failure) *failure = @"swiftChatContextUnavailable";
        return nil;
    }
    if (RUINCopySwiftField(chatContext, "chat") != chat) {
        if (failure) *failure = @"swiftChatContextChatMismatch";
        return nil;
    }
    id group = RUINCopySwiftField(chatContext, "group");
    if (!group) {
        if (failure) *failure = @"swiftGroupUnavailable";
        return nil;
    }
    Class groupClass = objc_getClass("ManagedUnifiedGroup");
    if (!groupClass || ![group isKindOfClass:groupClass] || ![group isKindOfClass:NSManagedObject.class]) {
        if (failure) *failure = @"swiftGroupClassMismatch";
        return nil;
    }
    return group;
}

static NSDictionary *RUINGroupIdentityOnOwnerQueue(NSManagedObject *group, NSString **failure)
{
    // UnifiedGroupDataModel 8.mom: UnifiedGroup.id is an NSString attribute.
    // RUINIdentityForObject also verifies the native NSString property/getter ABI.
    if (group.isDeleted || ![group.entity.name isEqualToString:@"UnifiedGroup"] ||
        group.entity.attributesByName[@"id"].attributeType != NSStringAttributeType) {
        if (failure) *failure = @"unifiedGroupSchemaMismatch";
        return nil;
    }
    NSDictionary *identity = RUINIdentityForObject(group);
    if (![identity[@"kind"] isEqualToString:@"group"] || !RUINIdentityKey(identity, NO)) {
        if (failure) *failure = @"unifiedGroupIdentityMissing";
        return nil;
    }
    return identity;
}

static RUINNativeChatIdentity *RUINNativeChatIdentityOnOwnerQueue(id chat,
                                                                   NSManagedObjectContext *context,
                                                                   NSDictionary *groupIdentity,
                                                                   NSString *groupFailure,
                                                                   NSString **failure)
{
    if (!chat || !context) {
        if (failure) *failure = @"managedContextUnavailable";
        return nil;
    }
    NSDictionary *chatIdentity = RUINIdentityForObject(chat);
    RUINNativeChatIdentity *result = [RUINNativeChatIdentity new];
    result.chatObject = chat;
    NSString *kind = chatIdentity[@"kind"];
    NSString *identifier = chatIdentity[@"identifier"];

    if ([kind isEqualToString:@"group"]) {
        result.localNameKey = RUINIdentityKey(chatIdentity, NO);
        id originalName = groupIdentity[@"displayName"];
        if ([originalName isKindOfClass:NSString.class]) result.localNameOriginalText = originalName;
        result.midToCopy = identifier;
        if (!result.localNameKey && failure) *failure = @"unifiedGroupIDMissing";
        return result;
    }
    if ([kind isEqualToString:@"chat"] || [kind isEqualToString:@"squareChat"])
        result.midToCopy = identifier;
    result.readExceptionKey = RUINIdentityKey(chatIdentity, YES);
    if (!result.readExceptionKey) {
        if (failure) *failure = @"readIdentityUnavailable";
        return nil;
    }

    if ([kind isEqualToString:@"squareChat"]) {
        result.localNameKey = result.readExceptionKey;
        id originalName = chatIdentity[@"displayName"];
        if ([originalName isKindOfClass:NSString.class]) result.localNameOriginalText = originalName;
        return result;
    }

    Class managedChatClass = objc_getClass("ManagedChat");
    if (![kind isEqualToString:@"chat"] || !managedChatClass || ![chat isKindOfClass:managedChatClass]) {
        if (failure) *failure = @"chatTypeUnsupported";
        return result;
    }
    SEL oneOnOne = sel_registerName("isOneOnOneChat");
    Method method = class_getInstanceMethod(object_getClass(chat), oneOnOne);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, RUINNativeChatOneOnOneEncoding) != 0) {
        if (failure) *failure = @"oneOnOneMetadataMissing";
        return result;
    }
    BOOL isOneOnOne = [(id<RUINLINEManagedChatCalls>)chat isOneOnOneChat];
    if (isOneOnOne) {
        if (identifier.length) result.localNameKey = [@"user:" stringByAppendingString:identifier];
        return result;
    }

    if (![groupIdentity[@"kind"] isEqualToString:@"group"]) {
        if (failure) *failure = groupFailure ?: @"unifiedGroupIdentityMissing";
        return result;
    }
    // Bind the stored group to this chat at use time; never infer an alias ID.
    if (![groupIdentity[@"identifier"] isEqualToString:identifier]) {
        if (failure) *failure = @"unifiedGroupIDMismatch";
        return result;
    }
    result.localNameKey = RUINIdentityKey(groupIdentity, NO);
    id originalGroupName = groupIdentity[@"displayName"];
    if ([originalGroupName isKindOfClass:NSString.class]) result.localNameOriginalText = originalGroupName;
    if (!result.localNameKey && failure) *failure = @"unifiedGroupIDMissing";
    if (result.localNameKey) atomic_fetch_add(&gStoredGroupIdentityCount, 1);
    return result;
}

static void RUINResolveCurrentChat(UIViewController *controller,
                                   RUINNativeChatIdentityCompletion completion)
{
    if (![NSThread isMainThread] || !controller.isViewLoaded || !controller.view.window) {
        RUINCountIdentityFailure(@"inactiveController");
        if (completion) completion(nil, @"inactiveController");
        return;
    }
    id chat = RUINNativeChatObject(controller);
    if (![chat isKindOfClass:NSManagedObject.class]) {
        RUINCountIdentityFailure(@"chatUnavailable");
        atomic_fetch_add(&gMissingChatContextCount, 1);
        if (completion) completion(nil, @"chatUnavailable");
        return;
    }
    NSManagedObjectContext *context = [(NSManagedObject *)chat managedObjectContext];
    if (!context) {
        RUINCountIdentityFailure(@"managedContextUnavailable");
        atomic_fetch_add(&gMissingChatContextCount, 1);
        if (completion) completion(nil, @"managedContextUnavailable");
        return;
    }

    // Mirror only on the live controller's main queue. Read each Core Data
    // object on its own queue, with asynchronous handoff and no nested waits.
    void (^resolveChat)(NSDictionary *, NSString *) = ^(NSDictionary *groupIdentity, NSString *groupFailure) {
        [context performBlock:^{
            NSString *failure = nil;
            RUINNativeChatIdentity *identity = nil;
            @try { identity = RUINNativeChatIdentityOnOwnerQueue(chat, context, groupIdentity, groupFailure, &failure); }
            @catch (__unused NSException *exception) { failure = @"nativeIdentityLookupException"; }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!RUINNativeControllerIsCurrent(controller, chat)) {
                    atomic_fetch_add(&gStaleUIActionCount, 1);
                    return;
                }
                RUINCountIdentityFailure(failure);
                if (!identity) {
                    atomic_fetch_add(&gMissingChatContextCount, 1);
                } else if (!identity.localNameKey) {
                    atomic_fetch_add(&gMissingAliasIdentityCount, 1);
                }
                if (completion) completion(identity, failure);
            });
        }];
    };
    NSString *groupFailure = nil;
    NSManagedObject *group = nil;
    NSManagedObjectContext *groupContext = nil;
    @try {
        group = RUINLiveGroupForChat(controller, chat, &groupFailure);
        groupContext = group.managedObjectContext;
        if (group && !groupContext) groupFailure = @"unifiedGroupContextUnavailable";
    } @catch (__unused NSException *exception) { groupFailure = @"nativeGroupIdentityLookupException"; }
    if (!groupContext) {
        resolveChat(nil, groupFailure);
        return;
    }
    [groupContext performBlock:^{
        NSString *failure = nil;
        NSDictionary *groupIdentity = nil;
        @try { groupIdentity = RUINGroupIdentityOnOwnerQueue(group, &failure); }
        @catch (__unused NSException *exception) { failure = @"nativeGroupIdentityLookupException"; }
        resolveChat(groupIdentity, failure);
    }];
}

static NSString *RUINNonemptyString(NSString *text)
{
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length ? trimmed : nil;
}

static void RUINCollectTitleLabels(UIView *view, NSMutableArray<NSString *> *labels)
{
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = RUINNonemptyString(((UILabel *)view).text ?: @"");
        if (text) [labels addObject:text];
    }
    for (UIView *child in view.subviews) RUINCollectTitleLabels(child, labels);
}

static NSString *RUINNativeTitleText(UIView *titleView, NSString *navigationTitle)
{
    if ([titleView isKindOfClass:UILabel.class]) return RUINNonemptyString(((UILabel *)titleView).text ?: @"");
    if ([titleView isKindOfClass:UIButton.class]) {
        NSString *buttonTitle = RUINNonemptyString(((UIButton *)titleView).currentTitle ?: @"");
        if (buttonTitle) return buttonTitle;
    }
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    RUINCollectTitleLabels(titleView, labels);
    NSSet *unique = [NSSet setWithArray:labels];
    if (unique.count == 1) return unique.anyObject;
    if (unique.count > 1) return nil;
    return RUINNonemptyString(navigationTitle ?: @"");
}

// Exact LINE26.16 stored fields, verified in its Objective-C ivar metadata.
static UIView *RUINFindCustomNavigationContent(UIView *view, NSUInteger depth) {
    if (!view || depth > 24 || view.hidden) return nil;
    static Class contentClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ contentClass = objc_getClass("_TtC17LineMessagingUIV228ChatNavigationBarContentView"); });
    if (contentClass && [view isKindOfClass:contentClass]) return view;
    if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) return nil;
    for (UIView *child in view.subviews) {
        UIView *content = RUINFindCustomNavigationContent(child, depth + 1);
        if (content) return content;
    }
    return nil;
}
static UILabel *RUINCurrentVerifiedTitleLabelInContent(UIView *content)
{
    id label = content ? RUINCopySwiftField(content, "titleLabel") : nil;
    if ([label isKindOfClass:UILabel.class] && ((UILabel *)label).window) return label;
    return nil;
}
static UILabel *RUINCurrentVerifiedTitleLabel(UIViewController *controller)
{
    return RUINCurrentVerifiedTitleLabelInContent(RUINFindCustomNavigationContent(controller.view, 0));
}

static UIView *RUINCurrentTitleView(UIViewController *controller)
{
    return RUINCurrentVerifiedTitleLabel(controller) ?: controller.navigationItem.titleView;
}

static void RUINApplyNativeTitleAliasRecord(UIViewController *controller,
                                            RUINNativeTitleAliasRecord *record,
                                            UILabel *knownLabel)
{
    UILabel *label = knownLabel ?: RUINCurrentVerifiedTitleLabel(controller);
    id chat = RUINNativeChatObject(controller);
    if (!label || label != record.label || chat != record.chatObject ||
        !RUINNativeControllerIsCurrent(controller, chat) || !record.identityKey.length) return;

    NSString *currentTitle = label.text ?: @"";
    if (record.appliedAlias) {
        if (![currentTitle isEqualToString:record.appliedAlias])
            record.nativeTitle = RUINNativeOriginalTitle(currentTitle, record.originalName, [record.identityKey hasPrefix:@"group:"]);
    }

    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:RUINLocalNamesByIdentityDefaultsKey] ?: @{};
    id stored = saved[record.identityKey];
    NSString *alias = [stored isKindOfClass:NSString.class] && [(NSString *)stored length] ? stored : nil;
    if (alias) {
        NSString *rendered = [alias stringByAppendingString:RUINNativeMemberSuffix(record.nativeTitle, [record.identityKey hasPrefix:@"group:"])];
        if (![currentTitle isEqualToString:rendered]) label.text = rendered;
        record.appliedAlias = rendered;
    } else {
        if (record.appliedAlias && [currentTitle isEqualToString:record.appliedAlias])
            label.text = RUINNativeOriginalTitle(record.nativeTitle, record.originalName, [record.identityKey hasPrefix:@"group:"]);
        record.appliedAlias = nil;
    }
}

static void RUINResolveTitleAlias(UIViewController *controller,
                                 UILabel *label,
                                 id chat,
                                 RUINNativeTitleAliasRecord *record)
{
    NSString *titleAtStart = [label.text copy] ?: @"";
    record.resolving = YES;
    RUINResolveCurrentChat(controller, ^(RUINNativeChatIdentity *identity, __unused NSString *failure) {
        BOOL sameRecord = objc_getAssociatedObject(controller, &gTitleAliasRecordKey) == record &&
            record.chatObject == chat && record.label == label && record.resolving;
        BOOL current = sameRecord && RUINNativeControllerIsCurrent(controller, chat) &&
            RUINCurrentVerifiedTitleLabel(controller) == label;
        if (!current) {
            if (sameRecord) record.resolving = NO;
            atomic_fetch_add(&gStaleUIActionCount, 1);
            return;
        }
        record.resolving = NO;
        record.resolved = YES;
        if (!identity.localNameKey) return;

        record.identityKey = [identity.localNameKey copy];
        NSString *currentTitle = [label.text copy] ?: @"";
        record.originalName = [identity.localNameOriginalText copy];
        record.nativeTitle = RUINNativeOriginalTitle(currentTitle.length ? currentTitle : titleAtStart,
            record.originalName, [record.identityKey hasPrefix:@"group:"]);
        RUINApplyNativeTitleAliasRecord(controller, record, label);
    });
}

static void RUINRefreshNativeTitleAlias(UIViewController *controller)
{
    if (![NSThread isMainThread] || !controller.isViewLoaded || !controller.view.window) return;
    RUINNativeTitleAliasRecord *existing = objc_getAssociatedObject(controller, &gTitleAliasRecordKey);
    id chat = RUINNativeChatObject(controller);
    if (!chat || !RUINNativeControllerIsCurrent(controller, chat)) return;

    if (existing && existing.chatObject == chat && existing.resolved && !existing.appliedAlias) {
        NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:RUINLocalNamesByIdentityDefaultsKey];
        if (!saved.count) return;
    }

    UIView *cachedContent = existing.contentView;
    UILabel *label = nil;
    if (existing && existing.chatObject == chat && cachedContent && cachedContent.window &&
        cachedContent.superview && existing.label && existing.label.window &&
        [existing.label isDescendantOfView:cachedContent]) {
        label = existing.label;
    } else {
        UIView *content = RUINFindCustomNavigationContent(controller.view, 0);
        label = RUINCurrentVerifiedTitleLabelInContent(content);
        if (!label) return;
        cachedContent = content;
    }

    RUINNativeTitleAliasRecord *record = existing;
    if (!record || record.chatObject != chat || (record.resolving && record.label != label)) {
        record = [RUINNativeTitleAliasRecord new];
        record.chatObject = chat;
        record.contentView = cachedContent;
        record.label = label;
        record.nativeTitle = [label.text copy] ?: @"";
        objc_setAssociatedObject(controller, &gTitleAliasRecordKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        record.contentView = cachedContent;
        if (record.label != label) {
            record.label = label;
            record.nativeTitle = [label.text copy] ?: @"";
            record.appliedAlias = nil;
        }
    }

    if (record.resolving) return;
    if (record.resolved) {
        RUINApplyNativeTitleAliasRecord(controller, record, label);
        return;
    }
    RUINResolveTitleAlias(controller, label, chat, record);
}

static void RUINApplySavedNativeTitleAlias(UIViewController *controller,
                                           UIView *titleView,
                                           RUINNativeChatIdentity *identity,
                                           NSString *nativeTitle)
{
    UILabel *label = RUINCurrentVerifiedTitleLabel(controller);
    if (!identity.localNameKey || ![titleView isKindOfClass:UILabel.class] ||
        label != (UILabel *)titleView || !RUINNativeControllerIsCurrent(controller, identity.chatObject)) return;

    RUINNativeTitleAliasRecord *record = objc_getAssociatedObject(controller, &gTitleAliasRecordKey);
    if (!record || record.chatObject != identity.chatObject || record.label != label) {
        record = [RUINNativeTitleAliasRecord new];
        record.chatObject = identity.chatObject;
        record.label = label;
        record.nativeTitle = [nativeTitle copy] ?: [label.text copy] ?:
            [identity.localNameOriginalText copy] ?: @"";
        objc_setAssociatedObject(controller, &gTitleAliasRecordKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    record.identityKey = [identity.localNameKey copy];
    record.originalName = [identity.localNameOriginalText copy];
    record.resolving = NO;
    record.resolved = YES;
    if (!record.appliedAlias) record.nativeTitle = [label.text copy] ?: [nativeTitle copy] ?:
        [identity.localNameOriginalText copy] ?: @"";
    RUINApplyNativeTitleAliasRecord(controller, record, label);
}

static void RUINDetachTitleGesture(UIViewController *controller)
{
    RUINNativeTitleGestureRecord *record = objc_getAssociatedObject(controller, &gTitleGestureRecordKey);
    UIView *oldView = record.view;
    if (oldView && record.recognizer.view == oldView) [oldView removeGestureRecognizer:record.recognizer];
    if (oldView && !record.originalUserInteractionEnabled) oldView.userInteractionEnabled = NO;
    objc_setAssociatedObject(controller, &gTitleGestureRecordKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RUINAttachTitleGesture(UIViewController *controller)
{
    UIView *titleView = RUINCurrentTitleView(controller);
    UINavigationBar *bar = controller.navigationController.navigationBar;
    if (!titleView || titleView == bar || titleView.hidden || titleView.alpha <= 0 ||
        CGRectGetWidth(titleView.bounds) <= 0 || CGRectGetHeight(titleView.bounds) <= 0) {
        RUINDetachTitleGesture(controller);
        atomic_fetch_add(&gMissingTitleViewCount, 1);
        return;
    }
    if (!RUINNativeTitleText(titleView, controller.navigationItem.title)) {
        RUINDetachTitleGesture(controller);
        atomic_fetch_add(&gUnreliableTitleViewCount, 1);
        return;
    }

    RUINNativeTitleGestureRecord *existing = objc_getAssociatedObject(controller, &gTitleGestureRecordKey);
    if (existing.view == titleView && existing.recognizer.view == titleView) return;
    RUINDetachTitleGesture(controller);

    RUINNativeTitleGestureRecord *record = [RUINNativeTitleGestureRecord new];
    record.view = titleView;
    record.originalUserInteractionEnabled = titleView.userInteractionEnabled;
    if (!titleView.userInteractionEnabled) titleView.userInteractionEnabled = YES;
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:controller action:sel_registerName("ruin_nativeTitleLongPressed:")];
    gesture.minimumPressDuration = 0.65;
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;
    record.recognizer = gesture;
    objc_setAssociatedObject(controller, &gTitleGestureRecordKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [titleView addGestureRecognizer:gesture];
    atomic_fetch_add(&gTitleGestureAttachCount, 1);
}

static BOOL RUINValidReadExceptionKey(NSString *key)
{
    if (![key isKindOfClass:NSString.class]) return NO;
    for (NSString *prefix in @[@"chat:", @"squareChat:"]) {
        if ([key hasPrefix:prefix] && key.length > prefix.length) return YES;
    }
    return NO;
}

static BOOL RUINReadExceptionEnabled(NSString *key)
{
    NSArray *exceptions = [[NSUserDefaults standardUserDefaults] arrayForKey:RUINReadExceptionsDefaultsKey] ?: @[];
    return [exceptions containsObject:key];
}

static UIImage *RUINReadExceptionSymbol(BOOL exempt) {
    NSBundle *bundle = RUINResourceBundle();
    return [[UIImage imageNamed:exempt ? @"tabler-eye" : @"tabler-eye-off"
        inBundle:bundle compatibleWithTraitCollection:nil] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIColor *RUINDisplayedIconColor(UIImageView *view) {
    if (!view.image || CGRectIsEmpty(view.bounds)) return nil;
    // Native buttons may paint a black image while exposing UIKit's default
    // blue tint. Read the rendered image layer, not that unrelated tint value.
    uint8_t pixels[24 * 24 * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, 24, 24, 8, 24 * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGContextScaleCTM(context, 24 / view.bounds.size.width, 24 / view.bounds.size.height);
    CGContextTranslateCTM(context, -view.bounds.origin.x, -view.bounds.origin.y);
    [view.layer renderInContext:context];
    CGContextRelease(context);
    NSUInteger red = 0, green = 0, blue = 0, alpha = 0;
    for (NSUInteger i = 0; i < sizeof(pixels); i += 4) {
        red += pixels[i]; green += pixels[i + 1]; blue += pixels[i + 2]; alpha += pixels[i + 3];
    }
    if (!alpha) return nil;
    return [UIColor colorWithRed:MIN(1, (CGFloat)red / alpha)
        green:MIN(1, (CGFloat)green / alpha) blue:MIN(1, (CGFloat)blue / alpha) alpha:1];
}

static UIColor *RUINPeerImageTint(UIView *view, NSUInteger depth) {
    if (depth > 4 || view.hidden) return nil;
    if ([view isKindOfClass:UIImageView.class]) {
        UIColor *color = RUINDisplayedIconColor((UIImageView *)view);
        if (color) return color;
    }
    for (UIView *child in view.subviews) {
        UIColor *color = RUINPeerImageTint(child, depth + 1);
        if (color) return color;
    }
    return nil;
}

static UIColor *RUINReadExceptionTint(UIViewController *controller, UIButton *custom) {
    if ([custom.superview isKindOfClass:UIStackView.class]) {
        for (UIView *peer in ((UIStackView *)custom.superview).arrangedSubviews.reverseObjectEnumerator) {
            if (peer == custom) continue;
            UIColor *color = RUINPeerImageTint(peer, 0);
            if (color) return color;
        }
    }
    for (UIBarButtonItem *peer in controller.navigationItem.rightBarButtonItems) {
        if (peer == objc_getAssociatedObject(controller, &gReadExceptionButtonKey)) continue;
        UIColor *color = peer.customView ? RUINPeerImageTint(peer.customView, 0) : nil;
        if (color) return color;
    }
    return UIColor.labelColor;
}

static void RUINUpdateReadExceptionButton(UIViewController *controller, NSString *key)
{
    UIBarButtonItem *item = objc_getAssociatedObject(controller, &gReadExceptionButtonKey);
    UIButton *custom = objc_getAssociatedObject(controller, &gCustomReadExceptionButtonKey);
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:RUINReadControlEnabledDefaultsKey];
    BOOL exempt = key && RUINReadExceptionEnabled(key);
    UIImage *image = RUINReadExceptionSymbol(exempt);
    NSString *label = exempt ? RUINLocalizedString(@"このトークの既読抑制を有効にする") : RUINLocalizedString(@"このトークを既読抑制の例外にする");
    NSString *hint = enabled ? RUINLocalizedString(@"このトークだけ既読制御を切り替えます") : RUINLocalizedString(@"全体の既読抑制はオフです。例外設定は保存されます");
    UIColor *tint = RUINReadExceptionTint(controller, custom);
    item.enabled = RUINValidReadExceptionKey(key); item.image = image;
    item.tintColor = tint;
    item.accessibilityLabel = label; item.accessibilityHint = hint;
    custom.enabled = RUINValidReadExceptionKey(key);
    UIButtonConfiguration *configuration = custom.configuration;
    if (configuration) {
        configuration.image = image;
        configuration.baseForegroundColor = tint;
        custom.configuration = configuration;
    } else [custom setImage:image forState:UIControlStateNormal];
    custom.tintColor = tint;
    custom.accessibilityLabel = label; custom.accessibilityHint = hint;
}

static void RUINAttachReadExceptionButton(UIViewController *controller)
{
    UIView *content = RUINFindCustomNavigationContent(controller.view, 0);
    id stackValue = content ? RUINCopySwiftField(content, "rightStackView") : nil;
    if ([stackValue isKindOfClass:UIStackView.class]) {
        UIStackView *stack = stackValue;
        UIButton *button = objc_getAssociatedObject(controller, &gCustomReadExceptionButtonKey);
        if (!button) {
            UIButtonConfiguration *config = UIButtonConfiguration.plainButtonConfiguration;
            config.image = RUINReadExceptionSymbol(NO);
            config.contentInsets = NSDirectionalEdgeInsetsMake(4, 4, 4, 4);
            config.baseForegroundColor = UIColor.labelColor;
            button = [UIButton buttonWithConfiguration:config primaryAction:nil];
            button.accessibilityIdentifier = @"ruin.chat.read-exception";
            [button addTarget:controller action:sel_registerName("ruin_nativeToggleReadException:") forControlEvents:UIControlEventTouchUpInside];
            [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            objc_setAssociatedObject(controller, &gCustomReadExceptionButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (![stack.arrangedSubviews containsObject:button]) [stack addArrangedSubview:button];
    } else {
        UINavigationItem *navigationItem = controller.navigationItem;
        UIBarButtonItem *item = objc_getAssociatedObject(controller, &gReadExceptionButtonKey);
        if (!item) {
            item = [[UIBarButtonItem alloc] initWithImage:RUINReadExceptionSymbol(NO) style:UIBarButtonItemStylePlain target:controller action:sel_registerName("ruin_nativeToggleReadException:")];
            objc_setAssociatedObject(controller, &gReadExceptionButtonKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSArray *items = navigationItem.rightBarButtonItems ?: @[];
        if (![items containsObject:item]) navigationItem.rightBarButtonItems = [items arrayByAddingObject:item];
    }
    RUINResolveCurrentChat(controller, ^(RUINNativeChatIdentity *identity, __unused NSString *failure) {
        RUINUpdateReadExceptionButton(controller, identity.readExceptionKey);
        if (!identity.readExceptionKey) atomic_fetch_add(&gMissingReadIdentityCount, 1);
    });
}

static void RUINUpdateNativeChatControls(UIViewController *controller)
{
    if (![NSThread isMainThread] || !controller.isViewLoaded || !controller.view.window) return;
    RUINAttachTitleGesture(controller);
    RUINAttachReadExceptionButton(controller);
    RUINRefreshNativeTitleAlias(controller);
}

static void RUINNativeChatViewDidAppear(id self, SEL selector, BOOL animated)
{
    IMP original = atomic_load_explicit(&gOriginalChatViewDidAppear, memory_order_acquire);
    if (original) ((void (*)(id, SEL, BOOL))original)(self, selector, animated);
    atomic_fetch_add(&gViewDidAppearCalls, 1);
    RUINUpdateNativeChatControls((UIViewController *)self);
}

static void RUINNativeChatViewDidLayoutSubviews(id self, SEL selector)
{
    IMP original = atomic_load_explicit(&gOriginalChatViewDidLayoutSubviews, memory_order_acquire);
    if (original) ((void (*)(id, SEL))original)(self, selector);
    RUINRefreshNativeTitleAlias((UIViewController *)self);
}

static void RUINPresentLocalNameEditor(UIViewController *controller, UIView *titleView,
                                       NSString *nativeTitle, RUINNativeChatIdentity *identity)
{
    if (!identity.localNameKey || !RUINNativeControllerIsCurrent(controller, identity.chatObject) ||
        RUINCurrentTitleView(controller) != titleView) {
        atomic_fetch_add(&gStaleUIActionCount, 1);
        return;
    }
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:RUINLocalNamesByIdentityDefaultsKey] ?: @{};
    id stored = saved[identity.localNameKey];
    NSString *existingAlias = [stored isKindOfClass:NSString.class] ? stored : @"";
    NSString *title = nativeTitle.length ? nativeTitle : RUINLocalizedString(@"このトーク");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"ローカル表示名")
                                                                   message:[NSString stringWithFormat:(RUINLocalizedString(@"「%@」の表示名をこの端末だけ変更します。空欄で解除し、旧表示名ルールもこのIDには適用しません。") ?: @"「%@」の表示名をこの端末だけ変更します。空欄で解除し、旧表示名ルールもこのIDには適用しません。"), title]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = RUINLocalizedString(@"この端末で表示する名前");
        field.text = existingAlias;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"キャンセル") style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"保存") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (!RUINNativeControllerIsCurrent(controller, identity.chatObject) || RUINCurrentTitleView(controller) != titleView) {
            atomic_fetch_add(&gStaleUIActionCount, 1);
            return;
        }
        NSString *alias = weakAlert.textFields.firstObject.text ?: @"";
        RUINSetLocalName(identity.localNameKey, alias);
        RUINApplySavedNativeTitleAlias(controller, titleView, identity, nativeTitle);
        atomic_fetch_add(&gLocalNameSaveCount, 1);
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
    atomic_fetch_add(&gLocalNameEditorCount, 1);
}

static void RUINPresentTitleActions(UIViewController *controller, UIView *titleView,
                                    NSString *nativeTitle, RUINNativeChatIdentity *identity)
{
    if (!RUINNativeControllerIsCurrent(controller, identity.chatObject) || RUINCurrentTitleView(controller) != titleView) {
        atomic_fetch_add(&gStaleUIActionCount, 1);
        return;
    }
    UIAlertController *actions = [UIAlertController alertControllerWithTitle:nativeTitle
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIAlertController *weakActions = actions;
    if (identity.localNameKey) {
        [actions addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"ローカル表示名を設定") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakActions dismissViewControllerAnimated:YES completion:^{
                RUINPresentLocalNameEditor(controller, titleView, nativeTitle, identity);
            }];
        }]];
    }
    if (identity.midToCopy.length) {
        [actions addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"MIDをコピー") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            if (!RUINNativeControllerIsCurrent(controller, identity.chatObject) || RUINCurrentTitleView(controller) != titleView) {
                atomic_fetch_add(&gStaleUIActionCount, 1);
                return;
            }
            UIPasteboard.generalPasteboard.string = identity.midToCopy;
            atomic_fetch_add(&gMIDCopyCount, 1);
        }]];
    }
    [actions addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"キャンセル") style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = actions.popoverPresentationController;
    if (popover) {
        popover.sourceView = titleView;
        popover.sourceRect = titleView.bounds;
    }
    [controller presentViewController:actions animated:YES completion:nil];
}

static void RUINTitleLongPressed(id self, SEL selector, id sender)
{
    (void)selector;
    UIViewController *controller = self;
    if (![NSThread isMainThread] || ![sender isKindOfClass:UILongPressGestureRecognizer.class] ||
        ((UILongPressGestureRecognizer *)sender).state != UIGestureRecognizerStateBegan) return;
    UIView *titleView = RUINCurrentTitleView(controller);
    UILongPressGestureRecognizer *gesture = sender;
    if (!titleView || gesture.view != titleView || !RUINNativeControllerIsCurrent(controller, RUINNativeChatObject(controller))) {
        atomic_fetch_add(&gStaleUIActionCount, 1);
        return;
    }
    NSString *nativeTitle = RUINNativeTitleText(titleView, controller.navigationItem.title);
    if (!nativeTitle) {
        atomic_fetch_add(&gUnreliableTitleViewCount, 1);
        return;
    }
    RUINResolveCurrentChat(controller, ^(RUINNativeChatIdentity *identity, __unused NSString *failure) {
        if (!identity || (!identity.localNameKey && !identity.midToCopy)) {
            return;
        }
        RUINPresentTitleActions(controller, titleView, nativeTitle, identity);
    });
}

static void RUINToggleReadException(id self, SEL selector, id sender)
{
    (void)selector;
    (void)sender;
    UIViewController *controller = self;
    if (![NSThread isMainThread] || !RUINNativeControllerIsCurrent(controller, RUINNativeChatObject(controller))) {
        atomic_fetch_add(&gStaleUIActionCount, 1);
        return;
    }
    RUINResolveCurrentChat(controller, ^(RUINNativeChatIdentity *identity, __unused NSString *failure) {
        NSString *currentKey = identity.readExceptionKey;
        if (!currentKey || !RUINValidReadExceptionKey(currentKey)) {
            atomic_fetch_add(&gMissingReadIdentityCount, 1);
            return;
        }

        os_unfair_lock_lock(&gReadExceptionDefaultsLock);
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id saved = [defaults objectForKey:RUINReadExceptionsDefaultsKey];
        NSMutableOrderedSet<NSString *> *merged = [NSMutableOrderedSet orderedSet];
        if ([saved isKindOfClass:NSArray.class]) {
            for (id key in (NSArray *)saved) {
                if ([key isKindOfClass:NSString.class] && RUINValidReadExceptionKey(key)) [merged addObject:key];
            }
        } else if (saved) {
            atomic_fetch_add(&gReadExceptionArrayRepairCount, 1);
        }
        BOOL wasEnabled = [merged containsObject:currentKey];
        if (wasEnabled) [merged removeObject:currentKey];
        else [merged addObject:currentKey];
        [defaults setObject:merged.array forKey:RUINReadExceptionsDefaultsKey];
        os_unfair_lock_unlock(&gReadExceptionDefaultsLock);

        RUINInstallFeatures();
        RUINRefreshAutomaticReadGate();
        RUINUpdateReadExceptionButton(controller, currentKey);
        atomic_fetch_add(&gReadExceptionToggleCount, 1);
    });
}

static const char *RUINNativeChatHookStateName(RUINNativeChatHookState state)
{
    switch (state) {
        case RUINNativeChatHookVersionGated: return "versionGated";
        case RUINNativeChatHookMissingClass: return "missingClass";
        case RUINNativeChatHookMissingSelector: return "missingSelector";
        case RUINNativeChatHookEncodingMismatch: return "encodingMismatch";
        case RUINNativeChatHookActionInstallFailed: return "actionInstallFailed";
        case RUINNativeChatHookInstalled: return "installed";
        default: return "pending";
    }
}

NSDictionary *RUINNativeChatControlsDiagnostics(void)
{
    NSMutableDictionary *identityFailures = [NSMutableDictionary dictionary];
    for (size_t index = 0; index < sizeof(gIdentityFailureNames) / sizeof(gIdentityFailureNames[0]); index++) {
        uint_fast64_t count = atomic_load(&gIdentityFailureCounts[index]);
        if (count) identityFailures[gIdentityFailureNames[index]] = @(count);
    }
    return @{
        @"compatible": @(RUINNativeTargetMatches()),
        @"class": RUINNativeChatControllerName,
        @"viewDidAppearEncoding": [NSString stringWithUTF8String:RUINNativeChatViewDidAppearEncoding],
        @"hookState": [NSString stringWithUTF8String:RUINNativeChatHookStateName((RUINNativeChatHookState)atomic_load(&gNativeChatHookState))],
        @"viewDidAppearCalls": @(atomic_load(&gViewDidAppearCalls)),
        @"titleAliasLayoutHookInstalled": @(atomic_load(&gTitleAliasLayoutHookInstalled)),
        @"titleGestureAttachCount": @(atomic_load(&gTitleGestureAttachCount)),
        @"missingTitleViewCount": @(atomic_load(&gMissingTitleViewCount)),
        @"unreliableTitleViewCount": @(atomic_load(&gUnreliableTitleViewCount)),
        @"missingChatContextCount": @(atomic_load(&gMissingChatContextCount)),
        @"missingAliasIdentityCount": @(atomic_load(&gMissingAliasIdentityCount)),
        @"missingReadIdentityCount": @(atomic_load(&gMissingReadIdentityCount)),
        @"staleUIActionCount": @(atomic_load(&gStaleUIActionCount)),
        @"localNameEditorCount": @(atomic_load(&gLocalNameEditorCount)),
        @"localNameSaveCount": @(atomic_load(&gLocalNameSaveCount)),
        @"midCopyCount": @(atomic_load(&gMIDCopyCount)),
        @"readExceptionToggleCount": @(atomic_load(&gReadExceptionToggleCount)),
        @"readExceptionArrayRepairCount": @(atomic_load(&gReadExceptionArrayRepairCount)),
        @"storedGroupIdentityCount": @(atomic_load(&gStoredGroupIdentityCount)),
        @"identityLookupFailureCounts": identityFailures,
        @"globalReadControlEnabled": @([NSUserDefaults.standardUserDefaults boolForKey:RUINReadControlEnabledDefaultsKey]),
        @"identityRules": @{
            @"oneOnOne": @"user:<chat.mid>",
            @"group": @"group:<ManagedUnifiedGroup.id>",
            @"squareChat": @"squareChat:<mid>",
            @"readExceptions": @[@"chat:<mid>", @"squareChat:<mid>"]
        }
    };
}


#endif // RUIN_NATIVE_TITLE_HOST_CHECK
