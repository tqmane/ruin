#define RUIN_CONFIRMATIONS_INTERNAL 1
#import "Confirmations.h"
#import "SwiftFields.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <string.h>

NSString * const RUINConfirmSendEnabledDefaultsKey = @"RUINConfirmSendEnabled";
NSString * const RUINConfirmSendMinimumGroupMemberCountDefaultsKey = @"RUINConfirmSendMinimumGroupMemberCount";
NSString * const RUINConfirmCallEnabledDefaultsKey = @"RUINConfirmCallEnabled";
NSString * const RUINConfirmCameraOnEnabledDefaultsKey = @"RUINConfirmCameraOnEnabled";
NSString * const RUINConfirmDisconnectEnabledDefaultsKey = @"RUINConfirmDisconnectEnabled";

static NSString * const RUINTargetBundleIdentifier = @"jp.naver.line";
static NSString * const RUINTargetVersion = @"26.16.0";
static NSString * const RUINTargetBuild = @"2026.1006.1718";
static const char * const RUINChatInputBarClass = "_TtC15LineMessagingUI12ChatInputBar";
static const char * const RUINChatViewControllerClass = "_TtC15LineMessagingUI18ChatViewController";
static const char * const RUINManagedChatClass = "ManagedChat";
static const char * const RUINManagedSquareChatClass = "ManagedSquareChat";

typedef NS_ENUM(NSInteger, RUINConfirmationKind) {
    RUINConfirmationSend,
    RUINConfirmationCall,
    RUINConfirmationCameraOn,
    RUINConfirmationDisconnect
};

typedef NS_ENUM(NSInteger, RUINInvocationShape) {
    RUINInvocationOneObject,
    RUINInvocationTwoObjects,
    RUINInvocationControlAction
};

typedef NS_ENUM(NSInteger, RUINHookStatus) {
    RUINHookPending,
    RUINHookVersionGated,
    RUINHookMissingClass,
    RUINHookMissingSelector,
    RUINHookEncodingMismatch,
    RUINHookInstallFailed,
    RUINHookInstalled
};

enum {
    RUINHookNeedsChatThread = 1 << 0,
    RUINHookComposerControlBoundary = 1 << 1,
    RUINHookCameraToggle = 1 << 2,
    RUINHookCallHierarchyContext = 1 << 3
};

typedef struct RUINConfirmationHook RUINConfirmationHook;

struct RUINConfirmationHook {
    const char *className;
    const char *selectorName;
    const char *encoding;
    RUINConfirmationKind kind;
    RUINInvocationShape shape;
    IMP replacement;
    unsigned int flags;
    const char *contextClass;
    const char *contextIvar;
    const char *contextGetter;
    const char *senderIvar;
    const char *senderArrayGetter;
    const char *senderContainerGetter;
    _Atomic(IMP) original;
    atomic_int status;
    atomic_uint_fast64_t calls;
    atomic_uint_fast64_t prompts;
    atomic_uint_fast64_t approved;
    atomic_uint_fast64_t cancelled;
    atomic_uint_fast64_t staleContext;
    atomic_uint_fast64_t missingContext;
    atomic_uint_fast64_t suppressedWhilePending;
    atomic_uint_fast64_t unclassifiedSender;
};

@interface RUINConfirmationPending : NSObject
@property(nonatomic, assign) RUINConfirmationHook *hook;
@property(nonatomic, strong) id target;
@property(nonatomic, strong, nullable) id argument0;
@property(nonatomic, strong, nullable) id argument1;
@property(nonatomic, assign) SEL selector;
@property(nonatomic, assign) SEL dispatchedAction;
@property(nonatomic, assign) IMP original;
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UIViewController *anchorController;
@property(nonatomic, strong) UIViewController *presenter;
@property(nonatomic, weak, nullable) UIAlertController *alert;
@property(nonatomic, strong, nullable) UIViewController *threadController;
@property(nonatomic, copy, nullable) NSString *threadMID;
@property(nonatomic, strong, nullable) id contextOwner;
@property(nonatomic, strong, nullable) id contextIdentity;
@property(nonatomic, copy, nullable) NSString *contextClassName;
@property(nonatomic, copy, nullable) NSString *contextIvarName;
@property(nonatomic, assign) SEL contextGetter;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, copy) NSString *approveTitle;
@property(nonatomic) BOOL cameraToggleMustTurnOn;
@property(nonatomic) BOOL resolved;
@property(nonatomic) BOOL originalInvoked;
@property(nonatomic) NSInteger memberCount;
@end

@interface RUINChatSnapshot : NSObject
@property(nonatomic, strong) UIViewController *controller;
@property(nonatomic, strong) id chat;
@property(nonatomic, copy) NSString *mid;
@property(nonatomic) BOOL oneOnOneKnown;
@property(nonatomic) BOOL oneOnOne;
@property(nonatomic) BOOL memberCountKnown;
@property(nonatomic) NSInteger totalMemberCount;
@end

@implementation RUINConfirmationPending
@end
@implementation RUINChatSnapshot
@end

static void RUINHandleHook(RUINConfirmationHook *hook, id self, SEL selector, id _Nullable argument0, id _Nullable argument1, SEL dispatchedAction);

static void RUINChatInputSendReplacement(id self, SEL selector, id sender);
static void RUINControlSendActionReplacement(id self, SEL selector, SEL action, id target, id event);
static void RUINGroupCallAudioStartReplacement(id self, SEL selector, id sender);
static void RUINGroupCallVideoStartReplacement(id self, SEL selector, id sender);
static void RUINContactAudioStartReplacement(id self, SEL selector, id sender);
static void RUINContactVideoStartReplacement(id self, SEL selector, id sender);
static void RUINFreeVideoCameraReplacement(id self, SEL selector, id sender);
static void RUINGroupVideoCameraReplacement(id self, SEL selector, id sender);
static void RUINEffectsTurnOnCameraReplacement(id self, SEL selector, id sender);
static void RUINFreeVideoDisconnectReplacement(id self, SEL selector, id sender);
static void RUINFreeAudioCloseReplacement(id self, SEL selector, id sender);
static void RUINBizCallDisconnectReplacement(id self, SEL selector, id sender, id event);

#define RUIN_HOOK_ATOMICS \
    .original = ATOMIC_VAR_INIT(NULL), \
    .status = ATOMIC_VAR_INIT(RUINHookPending), \
    .calls = ATOMIC_VAR_INIT(0), \
    .prompts = ATOMIC_VAR_INIT(0), \
    .approved = ATOMIC_VAR_INIT(0), \
    .cancelled = ATOMIC_VAR_INIT(0), \
    .staleContext = ATOMIC_VAR_INIT(0), \
    .missingContext = ATOMIC_VAR_INIT(0), \
    .suppressedWhilePending = ATOMIC_VAR_INIT(0), \
    .unclassifiedSender = ATOMIC_VAR_INIT(0)

static RUINConfirmationHook gChatInputSendHook = {
    .className = RUINChatInputBarClass, .selectorName = "send:", .encoding = "v24@0:8@16",
    .kind = RUINConfirmationSend, .shape = RUINInvocationOneObject,
    .replacement = (IMP)RUINChatInputSendReplacement, .flags = RUINHookNeedsChatThread,
    RUIN_HOOK_ATOMICS
};
static RUINConfirmationHook gControlSendActionHook = {
    .className = "UIControl", .selectorName = "sendAction:to:forEvent:", .encoding = "v40@0:8:16@24@32",
    .kind = RUINConfirmationSend, .shape = RUINInvocationControlAction,
    .replacement = (IMP)RUINControlSendActionReplacement,
    .flags = RUINHookNeedsChatThread | RUINHookComposerControlBoundary,
    RUIN_HOOK_ATOMICS
};
static RUINConfirmationHook gGroupCallAudioStartHook = {
    .className = "_TtC15LineMessagingUI23GroupCallLayerStartView", .selectorName = "didTapStartFreeCall:", .encoding = "v24@0:8@16",
    .kind = RUINConfirmationCall, .shape = RUINInvocationOneObject,
    .replacement = (IMP)RUINGroupCallAudioStartReplacement, .flags = RUINHookNeedsChatThread,
    RUIN_HOOK_ATOMICS
};
static RUINConfirmationHook gGroupCallVideoStartHook = {
    .className = "_TtC15LineMessagingUI23GroupCallLayerStartView", .selectorName = "didTapStartVideoCall:", .encoding = "v24@0:8@16",
    .kind = RUINConfirmationCall, .shape = RUINInvocationOneObject,
    .replacement = (IMP)RUINGroupCallVideoStartReplacement, .flags = RUINHookNeedsChatThread,
    RUIN_HOOK_ATOMICS
};
static RUINConfirmationHook gContactAudioStartHook = {
    .className = "_TtC11NCXVoIPCore28NCXContactInfoViewController", .selectorName = "startAudioCall:", .encoding = "v24@0:8@16",
    .kind = RUINConfirmationCall, .shape = RUINInvocationOneObject,
    .replacement = (IMP)RUINContactAudioStartReplacement,
    .contextClass = "_TtC11NCXVoIPCore28NCXContactInfoViewController", .contextIvar = "dataSource",
    .senderArrayGetter = "audioCallButtons",
    RUIN_HOOK_ATOMICS
};
static RUINConfirmationHook gContactVideoStartHook = {
    .className = "_TtC11NCXVoIPCore28NCXContactInfoViewController", .selectorName = "startVideoCall:", .encoding = "v24@0:8@16",
    .kind = RUINConfirmationCall, .shape = RUINInvocationOneObject,
    .replacement = (IMP)RUINContactVideoStartReplacement,
    .contextClass = "_TtC11NCXVoIPCore28NCXContactInfoViewController", .contextIvar = "dataSource",
    .senderArrayGetter = "videoCallButtons",
    RUIN_HOOK_ATOMICS
};
static RUINConfirmationHook gFreeVideoCameraHook = {
    .className = "_TtC11NCXFreeCall22NCFVideoViewController", .selectorName = "toggleVideoPaused:", .encoding = "v24@0:8@16",
    .kind = RUINConfirmationCameraOn, .shape = RUINInvocationOneObject,
    .replacement = (IMP)RUINFreeVideoCameraReplacement, .flags = RUINHookCameraToggle,
    .contextClass = "_TtC11NCXFreeCall22NCFVideoViewController", .contextIvar = "session",
    RUIN_HOOK_ATOMICS
};
static RUINConfirmationHook gGroupVideoCameraHook = {
    .className = "_TtC12NCXGroupCall22NCGVideoViewController", .selectorName = "toggleVideoPaused:", .encoding = "v24@0:8@16",
    .kind = RUINConfirmationCameraOn, .shape = RUINInvocationOneObject,
    .replacement = (IMP)RUINGroupVideoCameraReplacement, .flags = RUINHookCameraToggle,
    .contextClass = "_TtC12NCXGroupCall22NCGVideoViewController", .contextIvar = "room",
    RUIN_HOOK_ATOMICS
};
static RUINConfirmationHook gEffectsTurnOnCameraHook = {
    .className = "_TtC13NCXVoIPEffect24NCXEffectsViewController", .selectorName = "turnOnCamera:", .encoding = "v24@0:8@16",
    .kind = RUINConfirmationCameraOn, .shape = RUINInvocationOneObject,
    .replacement = (IMP)RUINEffectsTurnOnCameraReplacement, .flags = RUINHookCallHierarchyContext,
    RUIN_HOOK_ATOMICS
};
static RUINConfirmationHook gFreeVideoDisconnectHook = {
    .className = "_TtC11NCXFreeCall22NCFVideoViewController", .selectorName = "disconnect:", .encoding = "v24@0:8@16",
    .kind = RUINConfirmationDisconnect, .shape = RUINInvocationOneObject,
    .replacement = (IMP)RUINFreeVideoDisconnectReplacement,
    .contextClass = "_TtC11NCXFreeCall22NCFVideoViewController", .contextIvar = "session",
    .senderContainerGetter = "disconnectButtonView",
    RUIN_HOOK_ATOMICS
};
static RUINConfirmationHook gFreeAudioDisconnectHook = {
    .className = "_TtC11NCXFreeCall22NCFAudioViewController", .selectorName = "close:", .encoding = "v24@0:8@16",
    .kind = RUINConfirmationDisconnect, .shape = RUINInvocationOneObject,
    .replacement = (IMP)RUINFreeAudioCloseReplacement,
    .contextClass = "_TtC11NCXFreeCall22NCFAudioViewController", .contextIvar = "session",
    .senderArrayGetter = "disconnectButtons",
    RUIN_HOOK_ATOMICS
};
static RUINConfirmationHook gBizCallDisconnectHook = {
    .className = "_TtC11NCXFreeCall24NCXBizCallViewController", .selectorName = "disconnect:forEvent:", .encoding = "v32@0:8@16@24",
    .kind = RUINConfirmationDisconnect, .shape = RUINInvocationTwoObjects,
    .replacement = (IMP)RUINBizCallDisconnectReplacement,
    .contextClass = "_TtC11NCXFreeCall24NCXBizCallViewController", .contextGetter = "callView",
    .senderIvar = "endButton",
    RUIN_HOOK_ATOMICS
};

static RUINConfirmationHook * const gHooks[] = {
    &gChatInputSendHook, &gControlSendActionHook,
    &gGroupCallAudioStartHook, &gGroupCallVideoStartHook,
    &gContactAudioStartHook, &gContactVideoStartHook,
    &gFreeVideoCameraHook, &gGroupVideoCameraHook, &gEffectsTurnOnCameraHook,
    &gFreeVideoDisconnectHook, &gFreeAudioDisconnectHook, &gBizCallDisconnectHook
};

static os_unfair_lock gInstallLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gPendingLock = OS_UNFAIR_LOCK_INIT;
static RUINConfirmationPending *gPendingConfirmation;
static _Thread_local unsigned int gApprovedInvocationDepth;
static atomic_int gSendButtonIvarState = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gMissingSendThreshold = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gUnknownSendContext = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gUnknownCameraState = ATOMIC_VAR_INIT(0);

#define RUIN_DEFINE_OBJECT_WRAPPER(name, hook) \
    static void name(id self, SEL selector, id argument) { RUINHandleHook(&hook, self, selector, argument, nil, NULL); }

RUIN_DEFINE_OBJECT_WRAPPER(RUINChatInputSendReplacement, gChatInputSendHook)
RUIN_DEFINE_OBJECT_WRAPPER(RUINGroupCallAudioStartReplacement, gGroupCallAudioStartHook)
RUIN_DEFINE_OBJECT_WRAPPER(RUINGroupCallVideoStartReplacement, gGroupCallVideoStartHook)
RUIN_DEFINE_OBJECT_WRAPPER(RUINContactAudioStartReplacement, gContactAudioStartHook)
RUIN_DEFINE_OBJECT_WRAPPER(RUINContactVideoStartReplacement, gContactVideoStartHook)
RUIN_DEFINE_OBJECT_WRAPPER(RUINFreeVideoCameraReplacement, gFreeVideoCameraHook)
RUIN_DEFINE_OBJECT_WRAPPER(RUINGroupVideoCameraReplacement, gGroupVideoCameraHook)
RUIN_DEFINE_OBJECT_WRAPPER(RUINEffectsTurnOnCameraReplacement, gEffectsTurnOnCameraHook)
RUIN_DEFINE_OBJECT_WRAPPER(RUINFreeVideoDisconnectReplacement, gFreeVideoDisconnectHook)
RUIN_DEFINE_OBJECT_WRAPPER(RUINFreeAudioCloseReplacement, gFreeAudioDisconnectHook)

static void RUINBizCallDisconnectReplacement(id self, SEL selector, id sender, id event)
{
    RUINHandleHook(&gBizCallDisconnectHook, self, selector, sender, event, NULL);
}

static void RUINControlSendActionReplacement(id self, SEL selector, SEL action, id target, id event)
{
    RUINHandleHook(&gControlSendActionHook, self, selector, target, event, action);
}

static BOOL RUINStringEquals(id value, NSString *expected)
{
    return [value isKindOfClass:NSString.class] && [(NSString *)value isEqualToString:expected];
}

static BOOL RUINIsCompatible(void)
{
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *info = bundle.infoDictionary ?: @{};
    BOOL bundleMatches = [bundle.bundleIdentifier isEqualToString:RUINTargetBundleIdentifier] ||
        RUINStringEquals(info[@"RUINOriginalBundleIdentifier"], RUINTargetBundleIdentifier);
    return bundleMatches &&
        RUINStringEquals(info[@"CFBundleShortVersionString"], RUINTargetVersion) &&
        RUINStringEquals(info[@"CFBundleVersion"], RUINTargetBuild);
}

static Method RUINOwnMethod(Class cls, SEL selector)
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

static void RUINInstallHook(RUINConfirmationHook *hook)
{
    if (atomic_load_explicit(&hook->status, memory_order_acquire) == RUINHookInstalled) return;
    Class cls = objc_getClass(hook->className);
    if (!cls) {
        atomic_store(&hook->status, RUINHookMissingClass);
        return;
    }
    SEL selector = sel_registerName(hook->selectorName);
    Method method = RUINOwnMethod(cls, selector);
    if (!method) {
        atomic_store(&hook->status, RUINHookMissingSelector);
        return;
    }
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || strcmp(encoding, hook->encoding) != 0) {
        atomic_store(&hook->status, RUINHookEncodingMismatch);
        return;
    }
    IMP current = method_getImplementation(method);
    if (current == hook->replacement) {
        atomic_store(&hook->status, RUINHookInstallFailed);
        return;
    }
    atomic_store_explicit(&hook->original, current, memory_order_release);
    IMP replaced = method_setImplementation(method, hook->replacement);
    if (!replaced) {
        atomic_store(&hook->original, NULL);
        atomic_store(&hook->status, RUINHookInstallFailed);
        return;
    }
    atomic_store_explicit(&hook->original, replaced, memory_order_release);
    atomic_store(&hook->status, RUINHookInstalled);
}

void RUINInstallConfirmations(void)
{
    os_unfair_lock_lock(&gInstallLock);
    if (!RUINIsCompatible()) {
        for (size_t index = 0; index < sizeof(gHooks) / sizeof(gHooks[0]); index++) {
            if (atomic_load(&gHooks[index]->status) != RUINHookInstalled)
                atomic_store(&gHooks[index]->status, RUINHookVersionGated);
        }
        os_unfair_lock_unlock(&gInstallLock);
        return;
    }

    for (size_t index = 0; index < sizeof(gHooks) / sizeof(gHooks[0]); index++)
        RUINInstallHook(gHooks[index]);

    Class inputClass = objc_getClass(RUINChatInputBarClass);
    Ivar sendButtonIvar = inputClass ? class_getInstanceVariable(inputClass, "$__lazy_storage_$_sendButton") : NULL;
    const char *sendButtonType = sendButtonIvar ? ivar_getTypeEncoding(sendButtonIvar) : NULL;
    atomic_store(&gSendButtonIvarState, sendButtonIvar && (!sendButtonType || !sendButtonType[0] || sendButtonType[0] == '@') ? 0 : -1);
    os_unfair_lock_unlock(&gInstallLock);
}

static const char *RUINHookStatusName(RUINHookStatus status)
{
    switch (status) {
        case RUINHookVersionGated: return "versionGated";
        case RUINHookMissingClass: return "missingClass";
        case RUINHookMissingSelector: return "missingSelector";
        case RUINHookEncodingMismatch: return "encodingMismatch";
        case RUINHookInstallFailed: return "installFailed";
        case RUINHookInstalled: return "installed";
        default: return "pending";
    }
}

static id RUINObjectIvar(id object, const char *className, const char *ivarName)
{
    Class cls = className ? objc_getClass(className) : Nil;
    if (!object || !cls || !ivarName || ![object isKindOfClass:cls]) return nil;
    Ivar ivar = class_getInstanceVariable(cls, ivarName);
    const char *encoding = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    if (!ivar) return nil;
    if (encoding && encoding[0] == '@') return object_getIvar(object, ivar);
    // Swift stored fields can omit ObjC type encodings. Mirror preserves their
    // ownership and layout; never treat an untyped byte offset as an object.
    if (!encoding || !encoding[0]) return RUINCopySwiftField(object, ivarName);
    return nil;
}

static id RUINObjectGetter(id object, const char *className, const char *selectorName)
{
    Class cls = className ? objc_getClass(className) : Nil;
    if (!object || !cls || !selectorName || ![object isKindOfClass:cls]) return nil;
    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, "@16@0:8") != 0) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static UIViewController *RUINNearestViewController(id target)
{
    if ([target isKindOfClass:UIViewController.class]) return target;
    if (![target isKindOfClass:UIView.class]) return nil;
    UIResponder *responder = target;
    while ((responder = responder.nextResponder)) {
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
    }
    return nil;
}

static UIViewController *RUINFindControllerNamed(UIViewController *start, const char *className)
{
    if (!start || !className) return nil;
    Class cls = objc_getClass(className);
    if (!cls) return nil;
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    UIViewController *current = start;
    for (NSUInteger depth = 0; current && depth < 16; depth++) {
        NSValue *key = [NSValue valueWithNonretainedObject:current];
        if ([visited containsObject:key]) break;
        [visited addObject:key];
        if ([current isKindOfClass:cls]) return current;
        current = current.parentViewController ?: current.presentingViewController;
    }
    return nil;
}

static id RUINChatObject(UIViewController *controller)
{
    Class cls = objc_getClass(RUINChatViewControllerClass);
    if (!controller || !cls || ![controller isKindOfClass:cls]) return nil;
    SEL selector = sel_registerName("chat");
    Method method = class_getInstanceMethod(cls, selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, "@16@0:8") != 0) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(controller, selector);
}

static NSString *RUINChatMID(id chat)
{
    if (!chat) return nil;
    id value = nil;
    @try {
        value = [chat valueForKey:@"mid"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] ? [value copy] : nil;
}

static RUINChatSnapshot *RUINReadChatSnapshot(id target)
{
    UIViewController *nearest = RUINNearestViewController(target);
    UIViewController *chatController = RUINFindControllerNamed(nearest, RUINChatViewControllerClass);
    id chat = RUINChatObject(chatController);
    NSString *mid = RUINChatMID(chat);
    if (!chatController || !chat || !mid) return nil;

    RUINChatSnapshot *snapshot = [RUINChatSnapshot new];
    snapshot.controller = chatController;
    snapshot.chat = chat;
    snapshot.mid = mid;

    Class managedChat = objc_getClass(RUINManagedChatClass);
    Class managedSquareChat = objc_getClass(RUINManagedSquareChatClass);
    BOOL supported = (managedChat && [chat isKindOfClass:managedChat]) ||
        (managedSquareChat && [chat isKindOfClass:managedSquareChat]);
    if (!supported) return snapshot;

    SEL oneOnOneSelector = sel_registerName("isOneOnOneChat");
    Method oneOnOneMethod = class_getInstanceMethod(object_getClass(chat), oneOnOneSelector);
    const char *oneOnOneEncoding = oneOnOneMethod ? method_getTypeEncoding(oneOnOneMethod) : NULL;
    if (oneOnOneEncoding && strcmp(oneOnOneEncoding, "B16@0:8") == 0) {
        snapshot.oneOnOne = ((BOOL (*)(id, SEL))objc_msgSend)(chat, oneOnOneSelector);
        snapshot.oneOnOneKnown = YES;
    }

    SEL countSelector = sel_registerName("memberCountExcludingMyself");
    Method countMethod = class_getInstanceMethod(object_getClass(chat), countSelector);
    const char *countEncoding = countMethod ? method_getTypeEncoding(countMethod) : NULL;
    if (countEncoding && strcmp(countEncoding, "q16@0:8") == 0) {
        NSInteger excludingSelf = ((NSInteger (*)(id, SEL))objc_msgSend)(chat, countSelector);
        if (excludingSelf >= 0 && excludingSelf < NSIntegerMax) {
            snapshot.totalMemberCount = excludingSelf + 1;
            snapshot.memberCountKnown = YES;
        }
    }
    return snapshot;
}

static UIWindow *RUINWindowForTarget(id target)
{
    if ([target isKindOfClass:UIView.class]) return [(UIView *)target window];
    if ([target isKindOfClass:UIViewController.class]) {
        UIViewController *controller = target;
        return controller.isViewLoaded ? controller.view.window : nil;
    }
    return nil;
}

static UIViewController *RUINTopPresenter(UIViewController *controller)
{
    UIViewController *top = controller;
    while (top.parentViewController) top = top.parentViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed)
        top = top.presentedViewController;
    return top;
}

static BOOL RUINWindowIsActive(UIWindow *window)
{
    if (!window || !window.isKeyWindow || UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
        return NO;
    return window.windowScene.activationState == UISceneActivationStateForegroundActive;
}

static BOOL RUINPreparePresentation(RUINConfirmationPending *pending, id target)
{
    UIViewController *anchor = RUINNearestViewController(target);
    UIWindow *window = RUINWindowForTarget(target);
    if (!anchor || !window || !RUINWindowIsActive(window) || !anchor.isViewLoaded || anchor.view.window != window)
        return NO;
    UIViewController *presenter = RUINTopPresenter(anchor);
    if (!presenter || !presenter.isViewLoaded || presenter.view.window != window || presenter.presentedViewController)
        return NO;
    pending.anchorController = anchor;
    pending.presenter = presenter;
    pending.window = window;
    return YES;
}

static BOOL RUINReadContextIvar(RUINConfirmationPending *pending, id owner, const char *className, const char *ivarName)
{
    id identity = RUINObjectIvar(owner, className, ivarName);
    if (!identity) return NO;
    pending.contextOwner = owner;
    pending.contextIdentity = identity;
    pending.contextClassName = [NSString stringWithUTF8String:className];
    pending.contextIvarName = [NSString stringWithUTF8String:ivarName];
    pending.contextGetter = NULL;
    return YES;
}

static BOOL RUINReadContextGetter(RUINConfirmationPending *pending, id owner, const char *className, const char *getterName)
{
    id identity = RUINObjectGetter(owner, className, getterName);
    if (!identity) return NO;
    pending.contextOwner = owner;
    pending.contextIdentity = identity;
    pending.contextClassName = [NSString stringWithUTF8String:className];
    pending.contextIvarName = nil;
    pending.contextGetter = sel_registerName(getterName);
    return YES;
}

static BOOL RUINCaptureCallHierarchyContext(RUINConfirmationPending *pending, id target)
{
    UIViewController *current = RUINNearestViewController(target);
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    for (NSUInteger depth = 0; current && depth < 16; depth++) {
        NSValue *key = [NSValue valueWithNonretainedObject:current];
        if ([visited containsObject:key]) break;
        [visited addObject:key];
        const char *className = class_getName(object_getClass(current));
        if (className && (strcmp(className, "_TtC11NCXFreeCall22NCFVideoViewController") == 0 ||
                          strcmp(className, "_TtC11NCXFreeCall22NCFAudioViewController") == 0)) {
            if (RUINReadContextIvar(pending, current, className, "session")) return YES;
        }
        if (className && (strcmp(className, "_TtC12NCXGroupCall22NCGVideoViewController") == 0 ||
                          strcmp(className, "_TtC12NCXGroupCall22NCGAudioViewController") == 0)) {
            if (RUINReadContextIvar(pending, current, className, "room")) return YES;
        }
        if (className && strcmp(className, "_TtC11NCXFreeCall24NCXBizCallViewController") == 0) {
            if (RUINReadContextGetter(pending, current, className, "callView")) return YES;
        }
        current = current.parentViewController ?: current.presentingViewController;
    }
    return NO;
}

static BOOL RUINCapturePendingContext(RUINConfirmationHook *hook, RUINConfirmationPending *pending)
{
    if (hook->flags & RUINHookNeedsChatThread) {
        if (pending.threadMID && pending.threadController) return YES;
        RUINChatSnapshot *snapshot = RUINReadChatSnapshot(pending.target);
        if (!snapshot) return NO;
        pending.threadController = snapshot.controller;
        pending.threadMID = snapshot.mid;
        return YES;
    }
    if (hook->flags & RUINHookCallHierarchyContext)
        return RUINCaptureCallHierarchyContext(pending, pending.target);
    if (hook->contextClass && hook->contextIvar)
        return RUINReadContextIvar(pending, pending.target, hook->contextClass, hook->contextIvar);
    if (hook->contextClass && hook->contextGetter)
        return RUINReadContextGetter(pending, pending.target, hook->contextClass, hook->contextGetter);
    return NO;
}

static id RUINCurrentContextIdentity(RUINConfirmationPending *pending)
{
    if (!pending.contextOwner || !pending.contextClassName) return nil;
    const char *className = pending.contextClassName.UTF8String;
    if (pending.contextGetter)
        return RUINObjectGetter(pending.contextOwner, className, sel_getName(pending.contextGetter));
    return RUINObjectIvar(pending.contextOwner, className, pending.contextIvarName.UTF8String);
}

static BOOL RUINThreadStillMatches(RUINConfirmationPending *pending)
{
    if (!pending.threadMID) return NO;
    UIViewController *current = RUINFindControllerNamed(RUINNearestViewController(pending.target), RUINChatViewControllerClass);
    if (!current || current != pending.threadController) return NO;
    id chat = RUINChatObject(current);
    NSString *mid = RUINChatMID(chat);
    return mid && [mid isEqualToString:pending.threadMID];
}

static BOOL RUINCameraSenderIsOffStateButton(id target, id sender)
{
    RUINConfirmationHook *hook = NULL;
    Class freeVideo = objc_getClass("_TtC11NCXFreeCall22NCFVideoViewController");
    Class groupVideo = objc_getClass("_TtC12NCXGroupCall22NCGVideoViewController");
    if ((freeVideo && [target isKindOfClass:freeVideo])) hook = &gFreeVideoCameraHook;
    else if ((groupVideo && [target isKindOfClass:groupVideo])) hook = &gGroupVideoCameraHook;
    if (!hook || !sender) return NO;

    id offButtons = RUINObjectGetter(target, hook->className, "videoOffButtons");
    id onButtons = RUINObjectGetter(target, hook->className, "videoOnButtons");
    if (![offButtons isKindOfClass:NSArray.class] || ![onButtons isKindOfClass:NSArray.class]) return NO;
    return [(NSArray *)offButtons containsObject:sender] && ![(NSArray *)onButtons containsObject:sender];
}

static BOOL RUINCameraStillTurnsOn(RUINConfirmationPending *pending)
{
    if (!pending.cameraToggleMustTurnOn) return YES;
    return RUINCameraSenderIsOffStateButton(pending.target, pending.argument0);
}

static BOOL RUINValidatePendingContext(RUINConfirmationPending *pending)
{
    if (![NSThread isMainThread] || !RUINWindowIsActive(pending.window)) return NO;
    if (RUINWindowForTarget(pending.target) != pending.window) return NO;
    if (RUINNearestViewController(pending.target) != pending.anchorController) return NO;
    if (!pending.presenter.isViewLoaded || pending.presenter.view.window != pending.window) return NO;
    if (pending.threadMID && !RUINThreadStillMatches(pending)) return NO;
    if (pending.contextIdentity && RUINCurrentContextIdentity(pending) != pending.contextIdentity) return NO;
    return RUINCameraStillTurnsOn(pending);
}

static id RUINGetterValue(id object, const char *className, const char *getterName)
{
    return RUINObjectGetter(object, className, getterName);
}

static BOOL RUINSenderMatchesHook(RUINConfirmationHook *hook, id target, id sender)
{
    if (hook->senderIvar) {
        id expected = RUINObjectIvar(target, hook->className, hook->senderIvar);
        return expected && expected == sender;
    }
    if (hook->senderArrayGetter) {
        id array = RUINGetterValue(target, hook->className, hook->senderArrayGetter);
        return [array isKindOfClass:NSArray.class] && [(NSArray *)array containsObject:sender];
    }
    if (hook->senderContainerGetter) {
        id container = RUINGetterValue(target, hook->className, hook->senderContainerGetter);
        if (![container isKindOfClass:UIView.class] || ![sender isKindOfClass:UIView.class]) return NO;
        for (UIView *view = sender; view; view = view.superview) {
            if (view == container) return YES;
        }
        return NO;
    }
    return YES;
}

static BOOL RUINIsComposerSendControl(id control, id actionTarget, SEL action)
{
    Class inputClass = objc_getClass(RUINChatInputBarClass);
    if (!inputClass || ![control isKindOfClass:UIControl.class]) return NO;
    UIView *composer = nil;
    for (UIView *view = (UIView *)control; view; view = view.superview) {
        if ([view isKindOfClass:inputClass]) {
            composer = view;
            break;
        }
    }
    if (!composer) return NO;

    if ([actionTarget isKindOfClass:inputClass] && action == sel_registerName("send:"))
        return YES;

    id sendButton = RUINObjectIvar(composer, RUINChatInputBarClass, "$__lazy_storage_$_sendButton");
    if (sendButton == control) {
        atomic_store(&gSendButtonIvarState, 1);
        return YES;
    }
    if (!sendButton && atomic_load(&gSendButtonIvarState) == 0)
        atomic_store(&gSendButtonIvarState, -1);
    return NO;
}

static NSString *RUINPreferenceKey(RUINConfirmationKind kind)
{
    switch (kind) {
        case RUINConfirmationSend: return RUINConfirmSendEnabledDefaultsKey;
        case RUINConfirmationCall: return RUINConfirmCallEnabledDefaultsKey;
        case RUINConfirmationCameraOn: return RUINConfirmCameraOnEnabledDefaultsKey;
        case RUINConfirmationDisconnect: return RUINConfirmDisconnectEnabledDefaultsKey;
    }
}

static NSString *RUINPromptTitle(RUINConfirmationKind kind)
{
    switch (kind) {
        case RUINConfirmationSend: return @"送信の確認";
        case RUINConfirmationCall: return @"通話の確認";
        case RUINConfirmationCameraOn: return @"カメラの確認";
        case RUINConfirmationDisconnect: return @"通話終了の確認";
    }
}

static NSString *RUINApproveTitle(RUINConfirmationKind kind)
{
    switch (kind) {
        case RUINConfirmationSend: return @"送信";
        case RUINConfirmationCall: return @"開始";
        case RUINConfirmationCameraOn: return @"オンにする";
        case RUINConfirmationDisconnect: return @"終了";
    }
}

static BOOL RUINFeatureEnabled(RUINConfirmationKind kind)
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:RUINPreferenceKey(kind)];
}

static BOOL RUINMinimumMemberCount(NSInteger *minimum)
{
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:RUINConfirmSendMinimumGroupMemberCountDefaultsKey];
    if (![value isKindOfClass:NSNumber.class]) return NO;
    NSInteger configured = [(NSNumber *)value integerValue];
    if (configured < 1) return NO;
    if (minimum) *minimum = configured;
    return YES;
}

static void RUINInvokeOriginal(RUINConfirmationPending *pending)
{
    if (!pending.original || pending.originalInvoked) return;
    pending.originalInvoked = YES;
    gApprovedInvocationDepth++;
    @try {
        if (pending.hook->shape == RUINInvocationControlAction) {
            ((void (*)(id, SEL, SEL, id, id))pending.original)(pending.target, pending.selector,
                pending.dispatchedAction, pending.argument0, pending.argument1);
        } else if (pending.hook->shape == RUINInvocationTwoObjects) {
            ((void (*)(id, SEL, id, id))pending.original)(pending.target, pending.selector,
                pending.argument0, pending.argument1);
        } else {
            ((void (*)(id, SEL, id))pending.original)(pending.target, pending.selector, pending.argument0);
        }
    } @finally {
        gApprovedInvocationDepth--;
    }
}

static void RUINCallOriginalDirect(RUINConfirmationHook *hook, id self, SEL selector, id argument0, id argument1, SEL dispatchedAction)
{
    IMP original = atomic_load_explicit(&hook->original, memory_order_acquire);
    if (!original) return;
    if (hook->shape == RUINInvocationControlAction)
        ((void (*)(id, SEL, SEL, id, id))original)(self, selector, dispatchedAction, argument0, argument1);
    else if (hook->shape == RUINInvocationTwoObjects)
        ((void (*)(id, SEL, id, id))original)(self, selector, argument0, argument1);
    else
        ((void (*)(id, SEL, id))original)(self, selector, argument0);
}

static void RUINClearPending(RUINConfirmationPending *pending)
{
    os_unfair_lock_lock(&gPendingLock);
    if (gPendingConfirmation == pending) gPendingConfirmation = nil;
    os_unfair_lock_unlock(&gPendingLock);
}

static BOOL RUINAlertIsCurrent(RUINConfirmationPending *pending)
{
    UIAlertController *alert = pending.alert;
    return alert && pending.presenter.presentedViewController == alert && alert.presentingViewController == pending.presenter;
}

static void RUINApprovedAfterDismissal(RUINConfirmationPending *pending)
{
    if (!RUINValidatePendingContext(pending)) {
        atomic_fetch_add_explicit(&pending.hook->staleContext, 1, memory_order_relaxed);
        RUINClearPending(pending);
        return;
    }
    if (pending.presenter.presentedViewController) {
        atomic_fetch_add_explicit(&pending.hook->staleContext, 1, memory_order_relaxed);
        RUINClearPending(pending);
        return;
    }
    RUINInvokeOriginal(pending);
    atomic_fetch_add_explicit(&pending.hook->approved, 1, memory_order_relaxed);
    RUINClearPending(pending);
}

static void RUINResolve(RUINConfirmationPending *pending, BOOL approved)
{
    if (pending.resolved) return;
    pending.resolved = YES;
    if (!approved) {
        atomic_fetch_add_explicit(&pending.hook->cancelled, 1, memory_order_relaxed);
        RUINClearPending(pending);
        return;
    }
    UIAlertController *alert = pending.alert;
    if (!alert || !RUINAlertIsCurrent(pending) || !RUINValidatePendingContext(pending)) {
        atomic_fetch_add_explicit(&pending.hook->staleContext, 1, memory_order_relaxed);
        RUINClearPending(pending);
        return;
    }
    [alert dismissViewControllerAnimated:YES completion:^{
        RUINApprovedAfterDismissal(pending);
    }];
}

static BOOL RUINShowConfirmation(RUINConfirmationPending *pending)
{
    if (![NSThread isMainThread] || !RUINValidatePendingContext(pending) || pending.presenter.presentedViewController)
        return NO;
    os_unfair_lock_lock(&gPendingLock);
    if (gPendingConfirmation) {
        atomic_fetch_add_explicit(&pending.hook->suppressedWhilePending, 1, memory_order_relaxed);
        os_unfair_lock_unlock(&gPendingLock);
        return NO;
    }
    gPendingConfirmation = pending;
    os_unfair_lock_unlock(&gPendingLock);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINPromptTitle(pending.hook->kind)
                                                                   message:pending.message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    pending.alert = alert;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        RUINResolve(pending, NO);
    }]];
    UIAlertActionStyle style = pending.hook->kind == RUINConfirmationDisconnect ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault;
    [alert addAction:[UIAlertAction actionWithTitle:pending.approveTitle style:style handler:^(__unused UIAlertAction *action) {
        pending.alert = weakAlert;
        RUINResolve(pending, YES);
    }]];
    [pending.presenter presentViewController:alert animated:YES completion:^{
        if (pending.presenter.presentedViewController != weakAlert || !RUINValidatePendingContext(pending)) {
            atomic_fetch_add_explicit(&pending.hook->staleContext, 1, memory_order_relaxed);
            RUINClearPending(pending);
        }
    }];
    atomic_fetch_add_explicit(&pending.hook->prompts, 1, memory_order_relaxed);
    return YES;
}

static BOOL RUINShouldConfirmSend(RUINConfirmationHook *hook, id target, RUINConfirmationPending *pending, BOOL *shouldConfirm)
{
    RUINChatSnapshot *snapshot = RUINReadChatSnapshot(target);
    if (!snapshot) {
        RUINConfirmationSendDisposition decision = RUINConfirmationEvaluateSend(NO, NO, NO, NO, 0, NO, 0);
        if (decision == RUINConfirmationSendMissingThread) {
            atomic_fetch_add_explicit(&gUnknownSendContext, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&hook->missingContext, 1, memory_order_relaxed);
        }
        return NO;
    }
    pending.threadController = snapshot.controller;
    pending.threadMID = snapshot.mid;
    NSInteger minimum = 0;
    BOOL minimumConfigured = RUINMinimumMemberCount(&minimum);
    RUINConfirmationSendDisposition decision = RUINConfirmationEvaluateSend(YES,
        snapshot.oneOnOneKnown, snapshot.oneOnOne,
        snapshot.memberCountKnown, snapshot.totalMemberCount,
        minimumConfigured, minimum);
    if (decision == RUINConfirmationSendBypass) {
        *shouldConfirm = NO;
        return YES;
    }

    if (!snapshot.oneOnOneKnown || !snapshot.memberCountKnown) {
        atomic_fetch_add_explicit(&hook->missingContext, 1, memory_order_relaxed);
    }
    if (!minimumConfigured) atomic_fetch_add_explicit(&gMissingSendThreshold, 1, memory_order_relaxed);
    pending.memberCount = snapshot.memberCountKnown ? snapshot.totalMemberCount : 0;
    if (snapshot.oneOnOneKnown && !snapshot.oneOnOne && snapshot.memberCountKnown) {
        pending.message = [NSString stringWithFormat:@"%ld人のグループに送信しますか？", (long)snapshot.totalMemberCount];
    } else if (!snapshot.oneOnOneKnown) {
        pending.message = @"送信先の種類を確認できません。送信しますか？";
    } else {
        pending.message = @"グループ人数を確認できません。送信しますか？";
    }
    *shouldConfirm = YES;
    return YES;
}

static void RUINHandleHook(RUINConfirmationHook *hook, id self, SEL selector, id argument0, id argument1, SEL dispatchedAction)
{
    atomic_fetch_add_explicit(&hook->calls, 1, memory_order_relaxed);
    BOOL enabled = RUINFeatureEnabled(hook->kind);
    os_unfair_lock_lock(&gPendingLock);
    BOOL alreadyPending = gPendingConfirmation != nil;
    os_unfair_lock_unlock(&gPendingLock);
    RUINConfirmationGateDisposition gate = RUINConfirmationGate(enabled, gApprovedInvocationDepth > 0, alreadyPending);
    if (gate == RUINConfirmationGateInvokeOriginal) {
        RUINCallOriginalDirect(hook, self, selector, argument0, argument1, dispatchedAction);
        return;
    }
    if (gate == RUINConfirmationGateSuppress) {
        atomic_fetch_add_explicit(&hook->suppressedWhilePending, 1, memory_order_relaxed);
        return;
    }
    if (![NSThread isMainThread]) {
        atomic_fetch_add_explicit(&hook->missingContext, 1, memory_order_relaxed);
        return;
    }

    if (hook->flags & RUINHookComposerControlBoundary) {
        if (!RUINIsComposerSendControl(self, argument0, dispatchedAction)) {
            atomic_fetch_add_explicit(&hook->unclassifiedSender, 1, memory_order_relaxed);
            RUINCallOriginalDirect(hook, self, selector, argument0, argument1, dispatchedAction);
            return;
        }
    } else if (hook->senderIvar || hook->senderArrayGetter || hook->senderContainerGetter) {
        if (!RUINSenderMatchesHook(hook, self, argument0)) {
            if (hook->senderArrayGetter || hook->senderContainerGetter)
                atomic_fetch_add_explicit(&hook->unclassifiedSender, 1, memory_order_relaxed);
            RUINCallOriginalDirect(hook, self, selector, argument0, argument1, dispatchedAction);
            return;
        }
    }

    if (hook->flags & RUINHookCameraToggle) {
        if (RUINCameraSenderIsOffStateButton(self, argument0)) {
            // The verified off-state control is the only toggle that turns the camera on.
        } else {
            id onButtons = RUINObjectGetter(self, hook->className, "videoOnButtons");
            if ([onButtons isKindOfClass:NSArray.class] && [(NSArray *)onButtons containsObject:argument0]) {
                RUINCallOriginalDirect(hook, self, selector, argument0, argument1, dispatchedAction);
                return;
            }
            atomic_fetch_add_explicit(&gUnknownCameraState, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&hook->missingContext, 1, memory_order_relaxed);
            return;
        }
    }

    RUINConfirmationPending *pending = [RUINConfirmationPending new];
    pending.hook = hook;
    pending.target = self;
    pending.argument0 = argument0;
    pending.argument1 = argument1;
    pending.selector = selector;
    pending.dispatchedAction = dispatchedAction;
    pending.original = atomic_load_explicit(&hook->original, memory_order_acquire);
    pending.approveTitle = RUINApproveTitle(hook->kind);
    pending.cameraToggleMustTurnOn = (hook->flags & RUINHookCameraToggle) != 0;

    BOOL shouldConfirm = YES;
    if (hook->kind == RUINConfirmationSend) {
        if (!RUINShouldConfirmSend(hook, self, pending, &shouldConfirm)) return;
        if (!shouldConfirm) {
            RUINCallOriginalDirect(hook, self, selector, argument0, argument1, dispatchedAction);
            return;
        }
    }

    if (!RUINPreparePresentation(pending, self) || !RUINCapturePendingContext(hook, pending)) {
        atomic_fetch_add_explicit(&hook->missingContext, 1, memory_order_relaxed);
        return;
    }

    switch (hook->kind) {
        case RUINConfirmationSend:
            break;
        case RUINConfirmationCall:
            pending.message = @"通話を開始しますか？";
            break;
        case RUINConfirmationCameraOn:
            pending.message = @"カメラをオンにしますか？";
            break;
        case RUINConfirmationDisconnect:
            pending.message = @"通話を終了しますか？";
            break;
    }
    if (!RUINShowConfirmation(pending))
        atomic_fetch_add_explicit(&hook->missingContext, 1, memory_order_relaxed);
}

static NSDictionary *RUINHookDiagnostics(RUINConfirmationHook *hook)
{
    return @{
        @"class": [NSString stringWithUTF8String:hook->className],
        @"selector": [NSString stringWithUTF8String:hook->selectorName],
        @"encoding": [NSString stringWithUTF8String:hook->encoding],
        @"status": [NSString stringWithUTF8String:RUINHookStatusName((RUINHookStatus)atomic_load(&hook->status))],
        @"calls": @(atomic_load(&hook->calls)),
        @"prompts": @(atomic_load(&hook->prompts)),
        @"approved": @(atomic_load(&hook->approved)),
        @"cancelled": @(atomic_load(&hook->cancelled)),
        @"staleContext": @(atomic_load(&hook->staleContext)),
        @"missingContext": @(atomic_load(&hook->missingContext)),
        @"suppressedWhilePending": @(atomic_load(&hook->suppressedWhilePending)),
        @"unclassifiedSender": @(atomic_load(&hook->unclassifiedSender))
    };
}

NSDictionary *RUINConfirmationDiagnostics(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger minimum = 0;
    BOOL thresholdConfigured = RUINMinimumMemberCount(&minimum);
    NSMutableArray *hooks = [NSMutableArray arrayWithCapacity:sizeof(gHooks) / sizeof(gHooks[0])];
    for (size_t index = 0; index < sizeof(gHooks) / sizeof(gHooks[0]); index++)
        [hooks addObject:RUINHookDiagnostics(gHooks[index])];

    NSMutableArray<NSString *> *missingEvidence = [NSMutableArray array];
    if ([defaults boolForKey:RUINConfirmSendEnabledDefaultsKey] && !thresholdConfigured)
        [missingEvidence addObject:@"sendThresholdUnset: every verified group send requires confirmation until a positive total-member threshold is configured"];
    if ([defaults boolForKey:RUINConfirmSendEnabledDefaultsKey] && atomic_load(&gSendButtonIvarState) != 1)
        [missingEvidence addObject:@"composerSendButtonIdentity: UIControl.sendAction has not yet observed the control stored in ChatInputBar's sendButton ivar; the exact send: action path remains covered"];
    if (atomic_load(&gUnknownSendContext) || atomic_load(&gUnknownCameraState))
        [missingEvidence addObject:@"runtimeContext: at least one action lacked verified thread or camera-state context and was suppressed"];

    return @{
        @"compatible": @(RUINIsCompatible()),
        @"version": RUINTargetVersion,
        @"build": RUINTargetBuild,
        @"preferences": @{
            @"confirmSend": @([defaults boolForKey:RUINConfirmSendEnabledDefaultsKey]),
            @"minimumGroupMemberCount": thresholdConfigured ? @(minimum) : NSNull.null,
            @"confirmCall": @([defaults boolForKey:RUINConfirmCallEnabledDefaultsKey]),
            @"confirmCameraOn": @([defaults boolForKey:RUINConfirmCameraOnEnabledDefaultsKey]),
            @"confirmDisconnect": @([defaults boolForKey:RUINConfirmDisconnectEnabledDefaultsKey])
        },
        @"sendThresholdEvidence": @{
            @"countSelector": @"ManagedChat/ManagedSquareChat memberCountExcludingMyself q16@0:8",
            @"totalMembers": @"memberCountExcludingMyself + 1",
            @"groupChatID": @"Chat.mid from the active ChatViewController.chat"
        },
        @"runtime": @{
            @"sendThresholdUnsetCount": @(atomic_load(&gMissingSendThreshold)),
            @"unknownSendContextCount": @(atomic_load(&gUnknownSendContext)),
            @"unknownCameraStateCount": @(atomic_load(&gUnknownCameraState)),
            @"sendButtonIvarState": atomic_load(&gSendButtonIvarState) == 1 ? @"verified" : (atomic_load(&gSendButtonIvarState) < 0 ? @"missingEvidence" : @"notObserved")
        },
        @"hooks": hooks,
        @"missingEvidence": missingEvidence,
        @"coverageLimits": @[
            @"CallTabRecentsTableViewCell startCall is not hooked because the verified cell metadata does not expose a stable recipient identity.",
            @"NCXGroupCall close: is not hooked because its call-ending sender semantics were not verified in this build.",
            @"No direct chat-header one-to-one call action was verified; profile call buttons and the in-chat group-call start controls are covered."
        ]
    };
}

