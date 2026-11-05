%config(generator=internal);

#import "MessagingPrivateAPI.h"
#import "MenuExtras.h"

#import "Features.h"
#import "ReadersSheet.h"
#import "MIDLookup.h"
#import "MessageHistory.h"
#import "ReadRangeFetch.h"
#import "SwiftFields.h"
#import "GIFEncoder.h"

#import <CoreData/CoreData.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <math.h>
#import <os/lock.h>
#import <string.h>
#import <stdlib.h>

NSString * const RUINCopyStickerGIFEnabledDefaultsKey = @"RUINCopyStickerGIFEnabled";
NSString * const RUINCopyMIDEnabledDefaultsKey = @"RUINCopyMIDEnabled";
NSString * const RUINSearchMIDEnabledDefaultsKey = @"RUINSearchMIDEnabled";

static NSString * const RUINMenuExtrasErrorDomain = @"RUINMenuExtrasErrorDomain";

typedef NS_ENUM(NSInteger, RUINMenuExtrasErrorCode) {
    RUINMenuExtrasErrorIncompatibleTarget = 1,
    RUINMenuExtrasErrorPreferenceDisabled,
    RUINMenuExtrasErrorInvalidLocalURL,
    RUINMenuExtrasErrorUnsupportedAnimation,
    RUINMenuExtrasErrorImageDecode,
    RUINMenuExtrasErrorGIFEncoding,
    RUINMenuExtrasErrorMIDUnavailable
};

static atomic_bool sInstallAttempted = ATOMIC_VAR_INIT(false);
static atomic_bool sMenuInspectionPending = ATOMIC_VAR_INIT(false);
static atomic_int sMenuHookStatus = ATOMIC_VAR_INIT(0);
static atomic_int sCalloutSurfaceHookStatus = ATOMIC_VAR_INIT(0);
static atomic_int sCalloutGridHookStatus = ATOMIC_VAR_INIT(0);
static atomic_int sCalloutIntrinsicHookStatus;
static atomic_uint_fast64_t sCalloutSizingGrowCount;
static BOOL sCalloutCountInstalled, sCalloutCellInstalled, sCalloutSelectionInstalled;
static BOOL sMenuLongPressInstalled, sCalloutWindowInstalled, sCalloutIntrinsicInstalled;
static atomic_bool sCalloutGridHooksReady = ATOMIC_VAR_INIT(false);
static atomic_bool sReadUsersBindingVerified = ATOMIC_VAR_INIT(false);
static atomic_uint_fast64_t sStickerGIFCopyAttemptCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t sStickerGIFCopySuccessCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t sStickerGIFEncodedFrameCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t sStickerGIFPasteboardVerifiedCount, sStickerGIFLastFrameCount;
static atomic_int sStickerGIFLastEncodingRejectionCode = ATOMIC_VAR_INIT(0);
static os_unfair_lock sMenuHookLock = OS_UNFAIR_LOCK_INIT;
static _Thread_local unsigned int sMessageLongPressDepth;
static char sReadUsersContextAssociationKey;
static char sCalloutActionCellRegistrationAssociationKey;

@interface RUINMenuExtrasReadUsersContext : NSObject
@property(nonatomic, weak) UICollectionViewCell *messageCell;
@property(nonatomic, weak) UICollectionView *messageCollectionView;
@property(nonatomic, strong) NSIndexPath *messageIndexPath;
@property(nonatomic, weak) UIViewController *chatViewController;
@property(nonatomic, copy) NSDictionary *messageKey;
@property(nonatomic, weak) UICollectionView *menuCollectionView;
@property(nonatomic) BOOL includesReadUsers;
@property(nonatomic, strong, nullable) NSURL *stickerGIFURL;
@property(nonatomic) NSInteger originalItemCount;
@property(nonatomic) BOOL hasOriginalItemCount;
@property(nonatomic, strong) UICollectionViewLayout *originalMenuLayout;
@property(nonatomic) BOOL originalScrollEnabled;
@property(nonatomic) CGFloat nativeItemHeight;
@property(nonatomic) NSInteger nativeGridColumns;
@property(nonatomic) NSInteger nativeMaximumRows;
@end

@implementation RUINMenuExtrasReadUsersContext
@end

typedef NS_ENUM(NSInteger, RUINMenuExtrasHookStatus) {
    RUINMenuExtrasHookNotAttempted = 0,
    RUINMenuExtrasHookVersionGated,
    RUINMenuExtrasHookMissingClass,
    RUINMenuExtrasHookMissingSelector,
    RUINMenuExtrasHookNotOwnMethod,
    RUINMenuExtrasHookEncodingMismatch,
    RUINMenuExtrasHookInstallFailed,
    RUINMenuExtrasHookInstalled
};

static BOOL RUINMenuExtrasTargetMatches(void)
{
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *info = bundle.infoDictionary ?: @{};
    id originalBundleID = info[@"RUINOriginalBundleIdentifier"];
    BOOL bundleMatches = [bundle.bundleIdentifier isEqualToString:RUINTargetBundleIdentifier] ||
        ([originalBundleID isKindOfClass:NSString.class] &&
         [originalBundleID isEqualToString:RUINTargetBundleIdentifier]);
    return bundleMatches &&
        [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] &&
        [info[@"CFBundleShortVersionString"] isEqualToString:RUINTargetVersion] &&
        [info[@"CFBundleVersion"] isKindOfClass:NSString.class] &&
        [info[@"CFBundleVersion"] isEqualToString:RUINTargetBuild];
}

static BOOL RUINMenuExtrasPreferenceEnabled(NSString *key)
{
    return [NSUserDefaults.standardUserDefaults boolForKey:key];
}

static void RUINMenuExtrasSetError(NSError **error, RUINMenuExtrasErrorCode code, NSString *description)
{
    if (error) *error = [NSError errorWithDomain:RUINMenuExtrasErrorDomain
                                            code:code
                                        userInfo:@{ NSLocalizedDescriptionKey: description }];
}

static NSString *RUINMenuExtrasEncoding(Class cls, const char *selectorName)
{
    if (!cls) return nil;
    Method method = class_getInstanceMethod(cls, sel_registerName(selectorName));
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding ? [NSString stringWithUTF8String:encoding] : nil;
}

static NSUInteger RUINMenuExtrasOwnMethodCount(Class cls)
{
    if (!cls) return 0;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    free(methods);
    return count;
}

static NSDictionary *RUINMenuExtrasMethodEvidence(NSString *className,
                                                   NSString *selectorName,
                                                   NSString *expectedEncoding)
{
    Class cls = objc_getClass(className.UTF8String);
    NSString *encoding = RUINMenuExtrasEncoding(cls, selectorName.UTF8String);
    return @{
        @"classPresent": @(cls != Nil),
        @"selector": selectorName,
        @"encoding": encoding ?: (id)NSNull.null,
        @"expectedEncoding": expectedEncoding,
        @"encodingMatches": @(encoding && [encoding isEqualToString:expectedEncoding])
    };
}

static NSArray<NSString *> *RUINMenuExtrasIvarNames(Class cls)
{
    unsigned int count = 0;
    Ivar *ivars = cls ? class_copyIvarList(cls, &count) : NULL;
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        const char *name = ivar_getName(ivars[index]);
        if (name) [names addObject:[NSString stringWithUTF8String:name]];
    }
    free(ivars);
    [names sortUsingSelector:@selector(compare:)];
    return names;
}

static NSArray<NSDictionary *> *RUINMenuExtrasIvarSignatures(Class cls)
{
    unsigned int count = 0;
    Ivar *ivars = cls ? class_copyIvarList(cls, &count) : NULL;
    NSMutableArray<NSDictionary *> *fields = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        const char *name = ivar_getName(ivars[index]);
        const char *encoding = ivar_getTypeEncoding(ivars[index]);
        if (!name) continue;
        [fields addObject:@{
            @"fieldName": [NSString stringWithUTF8String:name],
            @"typeEncoding": encoding ? [NSString stringWithUTF8String:encoding] : (id)NSNull.null
        }];
    }
    free(ivars);
    [fields sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"fieldName"] compare:right[@"fieldName"]];
    }];
    return fields;
}

static NSArray<NSString *> *RUINMenuExtrasProtocolNames(Class cls)
{
    unsigned int count = 0;
    Protocol *__unsafe_unretained *protocols = cls ? class_copyProtocolList(cls, &count) : NULL;
    NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        const char *name = protocol_getName(protocols[index]);
        if (name) [names addObject:[NSString stringWithUTF8String:name]];
    }
    free(protocols);
    [names sortUsingSelector:@selector(compare:)];
    return names;
}

static NSArray<NSDictionary *> *RUINMenuExtrasMethodSignatures(Class cls, BOOL classMethods)
{
    Class target = classMethods ? object_getClass(cls) : cls;
    unsigned int count = 0;
    Method *methods = target ? class_copyMethodList(target, &count) : NULL;
    NSMutableArray<NSDictionary *> *signatures = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        SEL selector = method_getName(methods[index]);
        const char *encoding = method_getTypeEncoding(methods[index]);
        if (!selector || !encoding) continue;
        [signatures addObject:@{
            @"selector": NSStringFromSelector(selector),
            @"typeEncoding": [NSString stringWithUTF8String:encoding]
        }];
    }
    free(methods);
    [signatures sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"selector"] compare:right[@"selector"]];
    }];
    return signatures;
}

static NSArray<NSDictionary *> *RUINMenuExtrasProtocolRequirements(Protocol *protocol, BOOL required)
{
    if (!protocol) return @[];
    unsigned int count = 0;
    struct objc_method_description *descriptions = protocol_copyMethodDescriptionList(protocol, required, YES, &count);
    NSMutableArray<NSDictionary *> *result = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int index = 0; index < count; index++) {
        SEL selector = descriptions[index].name;
        const char *encoding = descriptions[index].types;
        if (!selector) continue;
        [result addObject:@{
            @"selector": NSStringFromSelector(selector),
            @"typeEncoding": encoding ? [NSString stringWithUTF8String:encoding] : (id)NSNull.null
        }];
    }
    free(descriptions);
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"selector"] compare:right[@"selector"]];
    }];
    return result;
}

static NSDictionary *RUINMenuExtrasRuntimeSelector(NSString *className, NSString *selectorName, BOOL classMethod)
{
    Class cls = objc_getClass(className.UTF8String);
    SEL selector = sel_registerName(selectorName.UTF8String);
    Method method = cls ? (classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector)) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return @{
        @"className": className,
        @"dispatch": classMethod ? @"class" : @"instance",
        @"selector": selectorName,
        @"typeEncoding": encoding ? [NSString stringWithUTF8String:encoding] : (id)NSNull.null
    };
}

static BOOL RUINMenuExtrasIsRelevantRuntimeClassName(NSString *name)
{
    return [name containsString:@"MessageMenu"] || [name containsString:@"MessageContextMenu"] ||
        [name containsString:@"ChatCollectionView"] || [name containsString:@"ChatViewController"] ||
        [name containsString:@"UIMenuController"] ||
        [name containsString:@"UIMenuItem"] || [name containsString:@"UIContextMenu"] ||
        [name containsString:@"EditMenu"] || [name containsString:@"CalloutMenu"];
}

static BOOL RUINMenuExtrasIsSwiftMessageMenuClassName(NSString *name)
{
    return [name containsString:@"MessageMenu"] || [name containsString:@"MessageContextMenu"] ||
        [name containsString:@"ChatCollectionView"] || [name containsString:@"ChatViewController"] ||
        [name containsString:@"CalloutMenu"];
}

static NSArray<NSString *> *RUINMenuExtrasSwiftFieldNames(id object)
{
    NSArray *names = RUINCopySwiftFieldNames(object);
    if (![names isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (id name in names) if ([name isKindOfClass:NSString.class]) [result addObject:name];
    return result;
}

static void RUINMenuExtrasRecordVisibleObject(id object,
                                               NSMutableSet<NSString *> *visibleNames,
                                               NSMutableDictionary<NSString *, NSArray<NSString *> *> *fieldNames)
{
    NSString *name = NSStringFromClass(object_getClass(object));
    if (!RUINMenuExtrasIsRelevantRuntimeClassName(name)) return;
    [visibleNames addObject:name];
    if (RUINMenuExtrasIsSwiftMessageMenuClassName(name) && !fieldNames[name])
        fieldNames[name] = RUINMenuExtrasSwiftFieldNames(object);
}

static void RUINMenuExtrasCollectLoadedControllerTree(UIViewController *root,
                                                       NSMutableSet<NSString *> *names,
                                                       NSMutableDictionary<NSString *, NSArray<NSString *> *> *fieldNames)
{
    if (!root) return;
    NSMutableArray<UIViewController *> *pending = [NSMutableArray arrayWithObject:root];
    NSHashTable<UIViewController *> *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
    while (pending.count) {
        UIViewController *controller = pending.lastObject;
        [pending removeLastObject];
        if ([visited containsObject:controller]) continue;
        [visited addObject:controller];
        RUINMenuExtrasRecordVisibleObject(controller, names, fieldNames);
        UIView *loadedView = controller.viewIfLoaded;
        if (loadedView) {
            NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:loadedView];
            while (views.count) {
                UIView *view = views.lastObject;
                [views removeLastObject];
                if (view.hidden || view.alpha <= 0.01) continue;
                RUINMenuExtrasRecordVisibleObject(view, names, fieldNames);
                for (id<UIInteraction> interaction in view.interactions)
                    RUINMenuExtrasRecordVisibleObject(interaction, names, fieldNames);
                [views addObjectsFromArray:view.subviews];
            }
        }
        if (controller.presentedViewController) [pending addObject:controller.presentedViewController];
        if ([controller isKindOfClass:UINavigationController.class])
            [pending addObjectsFromArray:((UINavigationController *)controller).viewControllers];
        if ([controller isKindOfClass:UITabBarController.class])
            [pending addObjectsFromArray:((UITabBarController *)controller).viewControllers ?: @[]];
    }
}

static void RUINMenuExtrasCollectVisibleMenuClasses(NSMutableSet<NSString *> *names,
                                                    NSMutableDictionary<NSString *, NSArray<NSString *> *> *fieldNames)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha <= 0.01) continue;
            RUINMenuExtrasCollectLoadedControllerTree(window.rootViewController, names, fieldNames);
            NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:window];
            while (pending.count) {
                UIView *view = pending.lastObject;
                [pending removeLastObject];
                if (view.hidden || view.alpha <= 0.01) continue;
                RUINMenuExtrasRecordVisibleObject(view, names, fieldNames);
                for (id<UIInteraction> interaction in view.interactions)
                    RUINMenuExtrasRecordVisibleObject(interaction, names, fieldNames);
                [pending addObjectsFromArray:view.subviews];
            }
        }
    }
}

static NSDictionary *RUINMenuExtrasLegacyMenuSnapshot(void)
{
    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    Class menuControllerClass = objc_getClass("UIMenuController");
    SEL sharedSelector = sel_registerName("sharedMenuController");
    Method sharedMethod = menuControllerClass ? class_getClassMethod(menuControllerClass, sharedSelector) : NULL;
    const char *sharedEncoding = sharedMethod ? method_getTypeEncoding(sharedMethod) : NULL;
    if (!sharedEncoding || strcmp(sharedEncoding, "@16@0:8") != 0)
        return @{@"menuVisible":@NO, @"itemActions":actions};

    id menuController = [(Class<RUINMessagingLegacyMenuController>)menuControllerClass sharedMenuController];
    SEL visibleSelector = sel_registerName("isMenuVisible");
    Method visibleMethod = class_getInstanceMethod(object_getClass(menuController), visibleSelector);
    const char *visibleEncoding = visibleMethod ? method_getTypeEncoding(visibleMethod) : NULL;
    if (!visibleEncoding || strcmp(visibleEncoding, "B16@0:8") != 0 ||
        ![(id<RUINMessagingLegacyMenuController>)menuController isMenuVisible])
        return @{@"menuVisible":@NO, @"itemActions":actions};

    SEL itemsSelector = sel_registerName("menuItems");
    Method itemsMethod = class_getInstanceMethod(object_getClass(menuController), itemsSelector);
    const char *itemsEncoding = itemsMethod ? method_getTypeEncoding(itemsMethod) : NULL;
    if (!itemsEncoding || strcmp(itemsEncoding, "@16@0:8") != 0)
        return @{@"menuVisible":@YES, @"itemActions":actions};

    id items = [(id<RUINMessagingLegacyMenuController>)menuController menuItems];
    Class menuItemClass = objc_getClass("UIMenuItem");
    if ([items isKindOfClass:NSArray.class] && menuItemClass) {
        SEL actionSelector = sel_registerName("action");
        SEL targetSelector = sel_registerName("target");
        for (id item in (NSArray *)items) {
            if (![item isKindOfClass:menuItemClass]) continue;
            Method actionMethod = class_getInstanceMethod(object_getClass(item), actionSelector);
            Method targetMethod = class_getInstanceMethod(object_getClass(item), targetSelector);
            const char *actionEncoding = actionMethod ? method_getTypeEncoding(actionMethod) : NULL;
            const char *targetEncoding = targetMethod ? method_getTypeEncoding(targetMethod) : NULL;
            if (!actionEncoding || strcmp(actionEncoding, ":16@0:8") != 0) continue;
            SEL action = [(id<RUINMessagingLegacyMenuItem>)item action];
            if (!action) continue;
            id target = targetEncoding && strcmp(targetEncoding, "@16@0:8") == 0
                ? [(id<RUINMessagingLegacyMenuItem>)item target] : nil;
            [actions addObject:@{
                @"itemClassName": NSStringFromClass(object_getClass(item)),
                @"actionSelector": NSStringFromSelector(action),
                @"targetClassName": target ? NSStringFromClass(object_getClass(target)) : (id)NSNull.null
            }];
        }
    }
    return @{@"menuVisible":@YES, @"itemActions":actions};
}

static BOOL RUINMenuExtrasIsMenuSurfaceView(UIView *view)
{
    NSString *name = NSStringFromClass(object_getClass(view));
    return [name containsString:@"_UIContextMenu"] || [name hasPrefix:@"UIContextMenu"] ||
        [name containsString:@"MessageContextMenuView"] || [name containsString:@"MessageMenuView"] ||
        [name containsString:@"CalloutMenu"] || [name containsString:@"EditMenu"] || [name containsString:@"UIMenuController"] ||
        [name containsString:@"UIMenuView"] || [name containsString:@"CalloutBar"];
}

static void RUINMenuExtrasCollectControlActions(UIControl *control,
                                                NSMutableArray<NSDictionary *> *matrix)
{
    NSSet *targets = control.allTargets;
    NSUInteger events = control.allControlEvents;
    for (NSUInteger bit = 1; bit != 0 && matrix.count < 512; bit <<= 1) {
        if (!(events & bit)) continue;
        NSArray<NSString *> *firstResponderActions = [control actionsForTarget:nil forControlEvent:(UIControlEvents)bit];
        for (id action in firstResponderActions) if ([action isKindOfClass:NSString.class]) {
            [matrix addObject:@{
                @"controlClassName": NSStringFromClass(object_getClass(control)),
                @"eventMask": @(bit),
                @"targetClassName": (id)NSNull.null,
                @"actionSelector": action
            }];
            if (matrix.count == 512) return;
        }
        for (id target in targets) {
            NSArray<NSString *> *actions = [control actionsForTarget:target forControlEvent:(UIControlEvents)bit];
            id targetName = target ? NSStringFromClass(object_getClass(target)) : (id)NSNull.null;
            for (id action in actions) if ([action isKindOfClass:NSString.class]) {
                [matrix addObject:@{
                    @"controlClassName": NSStringFromClass(object_getClass(control)),
                    @"eventMask": @(bit),
                    @"targetClassName": targetName,
                    @"actionSelector": action
                }];
                if (matrix.count == 512) return;
            }
        }
    }
}

static NSDictionary *RUINMenuExtrasResponderChainEvidence(UIView *surface)
{
    NSMutableArray<NSString *> *classes = [NSMutableArray array];
    NSString *nearestController = nil;
    NSString *nearestChatMenuResponder = nil;
    UIResponder *responder = surface;
    for (NSUInteger depth = 0; responder && depth < 32; depth++) {
        NSString *name = NSStringFromClass(object_getClass(responder));
        [classes addObject:name];
        if (!nearestController && [responder isKindOfClass:UIViewController.class]) nearestController = name;
        if (!nearestChatMenuResponder &&
            ([name containsString:@"ChatViewController"] || [name containsString:@"MessageMenuController"] ||
             [name containsString:@"ChatMessageMenuHandler"])) nearestChatMenuResponder = name;
        UIResponder *next = responder.nextResponder;
        if (next == responder) break;
        responder = next;
    }
    return @{
        @"surfaceClassName": NSStringFromClass(object_getClass(surface)),
        @"responderClassNames": classes,
        @"nearestViewControllerClassName": nearestController ?: (id)NSNull.null,
        @"nearestChatMenuResponderClassName": nearestChatMenuResponder ?: (id)NSNull.null
    };
}

static NSDictionary *RUINMenuExtrasVisibleMenuSnapshot(void)
{
    if (!NSThread.isMainThread) return @{@"menuOpenObserved":@NO, @"mainThreadRequired":@YES};
    NSDictionary *legacyMenu = RUINMenuExtrasLegacyMenuSnapshot();
    NSMutableSet<NSString *> *surfaceNames = [NSMutableSet set];
    NSMutableSet<NSString *> *viewNames = [NSMutableSet set];
    NSMutableArray<NSDictionary *> *controlActions = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *responderChains = [NSMutableArray array];

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive)
            continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha <= 0.01) continue;
            NSMutableArray<UIView *> *search = [NSMutableArray arrayWithObject:window];
            NSMutableArray<UIView *> *surfaces = [NSMutableArray array];
            while (search.count) {
                UIView *view = search.lastObject;
                [search removeLastObject];
                if (view.hidden || view.alpha <= 0.01) continue;
                if (RUINMenuExtrasIsMenuSurfaceView(view)) {
                    [surfaces addObject:view];
                    continue;
                }
                [search addObjectsFromArray:view.subviews];
            }
            for (UIView *surface in surfaces) {
                [surfaceNames addObject:NSStringFromClass(object_getClass(surface))];
                [responderChains addObject:RUINMenuExtrasResponderChainEvidence(surface)];
                NSMutableArray<UIView *> *subtree = [NSMutableArray arrayWithObject:surface];
                while (subtree.count) {
                    UIView *view = subtree.lastObject;
                    [subtree removeLastObject];
                    if (view.hidden || view.alpha <= 0.01) continue;
                    [viewNames addObject:NSStringFromClass(object_getClass(view))];
                    if ([view isKindOfClass:UIControl.class])
                        RUINMenuExtrasCollectControlActions((UIControl *)view, controlActions);
                    [subtree addObjectsFromArray:view.subviews];
                }
            }
        }
    }
    NSArray *sortedSurfaces = [[surfaceNames allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSArray *sortedViews = [[viewNames allObjects] sortedArrayUsingSelector:@selector(compare:)];
    BOOL legacyVisible = [legacyMenu[@"menuVisible"] boolValue];
    return @{
        @"menuOpenObserved": @(legacyVisible || sortedSurfaces.count > 0),
        @"legacyUIMenuController": legacyMenu,
        @"surfaceClassNames": sortedSurfaces,
        @"surfaceResponderChains": responderChains,
        @"visibleChildViewClassNames": sortedViews,
        @"controlTargetActionSelectors": controlActions
    };
}

NSDictionary *RUINMenuExtrasRuntimeMenuSignatures(void)
{
    if (!RUINMenuExtrasTargetMatches())
        return @{@"available":@NO, @"reason":@"exact-bundle-version-build-gate-failed"};

    NSArray<NSString *> *knownNames = @[
        @"_TtC17LineMessagingUIV218ChatCollectionView",
        @"_TtC15LineMessagingUI18ChatViewController",
        @"_TtC17LineMessagingUIV229MessageContextMenuInteraction",
        @"_TtC17LineMessagingUIV231MessageContextMenuConfiguration",
        @"_TtC17LineMessagingUIV239MessageContextMenuInteractionParameters",
        @"_TtC15LineMessagingUI21MessageMenuController",
        @"_TtC15LineMessagingUI22ChatMessageMenuHandler",
        @"_TtC15LineMessagingUI36ChatViewControllerMessageMenuHandler",
        @"_TtC22LineSharedUIComponents24CalloutMenuContainerView",
        @"_TtC22LineSharedUIComponents15CalloutMenuView",
        @"_TtC22LineSharedUIComponents19CalloutMenuItemCell",
        @"_TtC22LineSharedUIComponents25CalloutMenuBackgroundView",
        @"_TtC12LineHomeFeed30HomeFeedPostStickerContentView",
        @"_TtC29LinePostCommentFeatureSupport22PostStickerCommentView",
        @"_TtC22LinePostFeatureSupport29PostStickerCollectionViewCell"
    ];
    NSMutableSet<NSString *> *visibleNames = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *visibleFieldNames = [NSMutableDictionary dictionary];
    if (NSThread.isMainThread) RUINMenuExtrasCollectVisibleMenuClasses(visibleNames, visibleFieldNames);

    Protocol *contextMenuDelegate = objc_getProtocol("UIContextMenuInteractionDelegate");
    Protocol *editMenuDelegate = objc_getProtocol("UIEditMenuInteractionDelegate");
    NSMutableSet<NSString *> *candidateNames = [NSMutableSet setWithArray:knownNames];
    [candidateNames unionSet:visibleNames];

    unsigned int classCount = 0;
    Class __unsafe_unretained *loadedClasses = objc_copyClassList(&classCount);
    if (!loadedClasses) classCount = 0;
    for (unsigned int index = 0; index < classCount; index++) {
        Class cls = loadedClasses[index];
        NSString *name = NSStringFromClass(cls);
        if (!RUINMenuExtrasIsRelevantRuntimeClassName(name)) continue;
        if ((contextMenuDelegate && class_conformsToProtocol(cls, contextMenuDelegate)) ||
            (editMenuDelegate && class_conformsToProtocol(cls, editMenuDelegate)))
            [candidateNames addObject:name];
    }
    free(loadedClasses);

    NSArray<NSString *> *sortedNames = [[candidateNames allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray<NSDictionary *> *classes = [NSMutableArray arrayWithCapacity:sortedNames.count];
    for (NSString *name in sortedNames) {
        Class cls = objc_getClass(name.UTF8String);
        if (!cls) continue;
        Class superclass = class_getSuperclass(cls);
        [classes addObject:@{
            @"className": name,
            @"superclass": superclass ? NSStringFromClass(superclass) : (id)NSNull.null,
            @"visibleInForegroundWindowTree": @( [visibleNames containsObject:name] ),
            @"fieldNames": RUINMenuExtrasIvarNames(cls),
            @"fieldSignatures": RUINMenuExtrasIvarSignatures(cls),
            @"directObjectiveCProtocols": RUINMenuExtrasProtocolNames(cls),
            @"instanceMethods": RUINMenuExtrasMethodSignatures(cls, NO),
            @"classMethods": RUINMenuExtrasMethodSignatures(cls, YES),
            @"UIContextMenuInteractionDelegate": @{
                @"protocolPresent": @(contextMenuDelegate != NULL),
                @"conforms": @(contextMenuDelegate && class_conformsToProtocol(cls, contextMenuDelegate))
            },
            @"UIEditMenuInteractionDelegate": @{
                @"protocolPresent": @(editMenuDelegate != NULL),
                @"conforms": @(editMenuDelegate && class_conformsToProtocol(cls, editMenuDelegate))
            }
        }];
    }

    NSMutableArray<NSDictionary *> *uikitProtocols = [NSMutableArray arrayWithCapacity:2];
    for (NSString *name in @[@"UIContextMenuInteractionDelegate", @"UIEditMenuInteractionDelegate"]) {
        Protocol *protocol = objc_getProtocol(name.UTF8String);
        if (!protocol) continue;
        [uikitProtocols addObject:@{
            @"protocolName": name,
            @"requiredInstanceMethods": RUINMenuExtrasProtocolRequirements(protocol, YES),
            @"optionalInstanceMethods": RUINMenuExtrasProtocolRequirements(protocol, NO)
        }];
    }

    NSArray *swiftProtocols = @[
        @{
            @"className": @"_TtC17LineMessagingUIV218ChatCollectionView",
            @"protocolNames": @[@"LineMessagingUIV2.MessageContextMenuInteractionDelegate"]
        },
        @{
            @"className": @"_TtC15LineMessagingUI22ChatMessageMenuHandler",
            @"protocolNames": @[@"LineMessagingUIV2.MessageContextMenuHandler", @"LineMessagingUI.MessageMenuControllerDelegate"]
        }
    ];

    NSArray<NSString *> *visible = [[visibleNames allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSArray<NSDictionary *> *uikitMenuAPIs = @[
        RUINMenuExtrasRuntimeSelector(@"UIContextMenuConfiguration",
            @"configurationWithIdentifier:previewProvider:actionProvider:", YES),
        RUINMenuExtrasRuntimeSelector(@"UIMenuController", @"sharedMenuController", YES),
        RUINMenuExtrasRuntimeSelector(@"UIMenuController", @"isMenuVisible", NO),
        RUINMenuExtrasRuntimeSelector(@"UIMenuController", @"setMenuItems:", NO),
        RUINMenuExtrasRuntimeSelector(@"UIMenuController", @"menuItems", NO),
        RUINMenuExtrasRuntimeSelector(@"UIMenuItem", @"initWithTitle:action:", NO),
        RUINMenuExtrasRuntimeSelector(@"UIMenuItem", @"action", NO),
        RUINMenuExtrasRuntimeSelector(@"UIMenuItem", @"target", NO),
        RUINMenuExtrasRuntimeSelector(@"UIControl", @"allTargets", NO),
        RUINMenuExtrasRuntimeSelector(@"UIControl", @"allControlEvents", NO),
        RUINMenuExtrasRuntimeSelector(@"UIControl", @"actionsForTarget:forControlEvent:", NO),
        RUINMenuExtrasRuntimeSelector(@"UIAction", @"actionWithTitle:image:identifier:handler:", YES)
    ];
    return @{
        @"available": @YES,
        @"foregroundWindowTreeScanned": @(NSThread.isMainThread),
        @"visibleMenuRelatedClassNames": visible,
        @"visibleSwiftFieldNamesOnly": visibleFieldNames,
        @"lineMenuClassSignatures": classes,
        @"uikitMenuDelegateRequirements": uikitProtocols,
        @"uikitMenuAPIs": uikitMenuAPIs,
        @"visibleMenuSnapshot": RUINMenuExtrasVisibleMenuSnapshot(),
        @"verifiedSwiftFieldTypes": @[
            @{
                @"className": @"_TtC15LineMessagingUI21MessageMenuController",
                @"fieldName": @"$__lazy_storage_$_menuItems",
                @"fieldTypeMangledFragment": @"SaySo10UIMenuItemCGSg",
                @"demangledType": @"[__C.UIMenuItem]?"
            }
        ],
        @"verifiedSwiftProtocolConformances": swiftProtocols,
        @"objectFieldValuesRead": @NO,
        @"menuLabelsOrIdentifiersRead": @NO
    };
}

static BOOL RUINMenuExtrasWriteMenuInspection(void)
{
    if (!RUINMenuExtrasTargetMatches()) return NO;
    NSDictionary *inspection = RUINMenuExtrasRuntimeMenuSignatures();
    NSDictionary *snapshot = inspection[@"visibleMenuSnapshot"];
    if (![snapshot[@"menuOpenObserved"] boolValue]) return NO;

    NSMutableDictionary *report = [inspection mutableCopy];
    report[@"captureTrigger"] = @"CalloutMenuContainerView.didMoveToWindow";
    NSString *cacheDirectory = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!cacheDirectory.length) return NO;
    NSString *directory = [cacheDirectory stringByAppendingPathComponent:@"RUIN"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                withIntermediateDirectories:YES attributes:nil error:NULL]) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:NULL];
    return data && [data writeToFile:[directory stringByAppendingPathComponent:@"menu-inspection.json"]
                             options:NSDataWritingAtomic error:NULL];
}

static BOOL RUINMenuExtrasMenuIsOpen(void)
{
    return NSThread.isMainThread &&
        [RUINMenuExtrasVisibleMenuSnapshot()[@"menuOpenObserved"] boolValue];
}

static void RUINMenuExtrasCheckForOpenedMenu(NSUInteger attempt)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (RUINMenuExtrasMenuIsOpen()) {
            RUINMenuExtrasWriteMenuInspection();
            atomic_store_explicit(&sMenuInspectionPending, false, memory_order_release);
        } else if (attempt < 11) {
            RUINMenuExtrasCheckForOpenedMenu(attempt + 1);
        } else {
            atomic_store_explicit(&sMenuInspectionPending, false, memory_order_release);
        }
    });
}

static void RUINMenuExtrasScheduleInspection(void)
{
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(&sMenuInspectionPending, &expected, true,
                                                 memory_order_acq_rel, memory_order_relaxed)) return;
    dispatch_async(dispatch_get_main_queue(), ^{ RUINMenuExtrasCheckForOpenedMenu(0); });
}

%group RUINMenuLongPress
%hook RUINMenuInteraction
- (void)handleLongPressGesture:(id)gesture {
    sMessageLongPressDepth++;
    @try {
        %orig;
    } @finally {
        sMessageLongPressDepth--;
    }
    RUINMenuExtrasScheduleInspection();

}
%end
%end

static void RUINMenuExtrasCollectChatCollections(UIView *root, Class chatCollectionClass,
                                                 NSMutableArray<UICollectionView *> *result)
{
    if (!root) return;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if (view.hidden || view.alpha <= 0.01) continue;
        if ([view isKindOfClass:chatCollectionClass] && [view isKindOfClass:UICollectionView.class])
            [result addObject:(UICollectionView *)view];
        [pending addObjectsFromArray:view.subviews];
    }
}

static UIViewController *RUINMenuExtrasChatControllerForCell(UICollectionViewCell *cell, UIWindow *window);

static NSDictionary *RUINMenuExtrasMessageKeyForCell(UICollectionViewCell *cell)
{
    if (!cell) return nil;
    Class baseCell = objc_getClass("_TtC17LineMessagingUIV219ChatBaseMessageCell");
    if (!baseCell || ![cell isKindOfClass:baseCell]) return nil;
    // Runtime evidence: FetchedModel<Message>.id.wrappedValue is an actual
    // NSManagedObjectID. The FetchedModel itself is not a managed object.
    id value = RUINCopySwiftField(cell, "messageViewModel.message.id.wrappedValue");
    if (![value isKindOfClass:NSManagedObjectID.class] || [value isTemporaryID]) return nil;
    NSManagedObjectID *messageID = value;
    UIViewController *owner = RUINMenuExtrasChatControllerForCell(cell, cell.window);
    Method getter = owner ? class_getInstanceMethod(object_getClass(owner), sel_registerName("chat")) : NULL;
    if (!getter || strcmp(method_getTypeEncoding(getter), "@16@0:8")) return nil;
    id chat = [(id<RUINMessagingChatOwner>)owner chat];
    if (![chat isKindOfClass:NSManagedObject.class]) return nil;
    NSManagedObjectContext *context = [chat managedObjectContext];
    if (!context) return nil;
    __block NSDictionary *key = nil;
    [context performBlockAndWait:^{
        @try {
            NSManagedObjectID *localID = messageID;
            NSPersistentStoreCoordinator *coordinator = context.persistentStoreCoordinator;
            if (coordinator) localID = [coordinator managedObjectIDForURIRepresentation:messageID.URIRepresentation];
            if ([chat isDeleted] || [[chat objectID] isTemporaryID] ||
                !localID.persistentStore || localID.persistentStore != [[chat objectID] persistentStore]) return;
            NSError *error = nil;
            NSManagedObject *message = [context existingObjectWithID:localID error:&error];
            Class talk = objc_getClass("ManagedMessage"), square = objc_getClass("ManagedSquareMessage");
            if (error || message.isDeleted || message.managedObjectContext != context ||
                !((talk && [message isKindOfClass:talk]) || (square && [message isKindOfClass:square]))) return;
            NSDictionary *candidate = RUINHistoryMessageKey(message);
            NSDictionary *chatIdentity = RUINIdentityForObject(chat);
            NSString *kind = [chatIdentity[@"kind"] isEqual:@"chat"] ? @"talk" :
                ([chatIdentity[@"kind"] isEqual:@"squareChat"] ? @"square" : nil);
            if (kind && [candidate[@"kind"] isEqual:kind] &&
                [candidate[@"chat"] isEqual:chatIdentity[@"identifier"]]) key = [candidate copy];
        } @catch (__unused NSException *exception) { key = nil; }
    }];
    return key;
}

static NSURL *RUINMenuExtrasAnimatedStickerFileURLForCell(UICollectionViewCell *cell)
{
    Class stickerCellClass = objc_getClass("_TtC17LineMessagingUIV231ChatAnimationStickerMessageCell");
    Class viewModelClass = objc_getClass("_TtC15LineMessagingUI36ChatAnimationStickerMessageViewModel");
    if (!cell || !stickerCellClass || object_getClass(cell) != stickerCellClass || !viewModelClass) return nil;

    id viewModel = RUINCopySwiftField(cell, "messageViewModel");
    if (!viewModel || object_getClass(viewModel) != viewModelClass) return nil;
    // LINE 26.16 stores sourceFileURLs as (animation: URL, audio: URL?)?.
    id sourceURL = RUINCopySwiftField(viewModel, "sourceFileURLs.animation");
    if (![sourceURL isKindOfClass:NSURL.class] || ![(NSURL *)sourceURL isFileURL] || ![(NSURL *)sourceURL path].length)
        return nil;

    NSString *path = [[(NSURL *)sourceURL path] stringByStandardizingPath];
    BOOL isDirectory = NO;
    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory)
        return nil;
    return [NSURL fileURLWithPath:path];
}

static UIViewController *RUINMenuExtrasChatControllerForCell(UICollectionViewCell *cell, UIWindow *window)
{
    Class chatControllerClass = objc_getClass("_TtC15LineMessagingUI18ChatViewController");
    if (!chatControllerClass) return nil;
    UIResponder *responder = cell;
    for (NSUInteger depth = 0; responder && depth < 32; depth++) {
        if ([responder isKindOfClass:chatControllerClass] &&
            [responder isKindOfClass:UIViewController.class]) {
            UIViewController *controller = (UIViewController *)responder;
            return controller.viewIfLoaded.window == window ? controller : nil;
        }
        UIResponder *next = responder.nextResponder;
        if (next == responder) break;
        responder = next;
    }
    return nil;
}

static RUINMenuExtrasReadUsersContext *RUINMenuExtrasResolveReadUsersContext(
    UIView *container, UICollectionView *menuCollectionView)
{
    BOOL includesReadUsers = [NSUserDefaults.standardUserDefaults boolForKey:RUINTrackReadUsersKey];
    BOOL canCopyStickerGIF = RUINMenuExtrasPreferenceEnabled(RUINCopyStickerGIFEnabledDefaultsKey);
    if (!NSThread.isMainThread || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        (!includesReadUsers && !canCopyStickerGIF)) return nil;
    UIWindow *menuWindow = container.window;
    UIWindowScene *scene = menuWindow.windowScene;
    if (!menuWindow || !scene || scene.activationState != UISceneActivationStateForegroundActive) return nil;

    id placeholderValue = RUINCopySwiftField(container, "targetPlaceholderView");
    if (![placeholderValue isKindOfClass:UIView.class]) return nil;
    UIView *placeholder = placeholderValue;
    if (!placeholder.window || placeholder.window.windowScene != scene) return nil;
    CGPoint anchor = [placeholder convertPoint:CGPointMake(CGRectGetMidX(placeholder.bounds),
                                                            CGRectGetMidY(placeholder.bounds)) toView:nil];
    if (placeholder.window != menuWindow)
        anchor = [placeholder.window convertPoint:anchor toWindow:menuWindow];

    Class chatCollectionClass = objc_getClass("_TtC17LineMessagingUIV218ChatCollectionView");
    if (!chatCollectionClass) return nil;
    NSMutableArray<UICollectionView *> *chatCollections = [NSMutableArray array];
    for (UIWindow *window in scene.windows) {
        if (window.hidden || window.alpha <= 0.01) continue;
        RUINMenuExtrasCollectChatCollections(window, chatCollectionClass, chatCollections);
    }

    RUINMenuExtrasReadUsersContext *match = nil;
    NSUInteger matches = 0;
    for (UICollectionView *chatCollectionView in chatCollections) {
        // Resolve the anchored cell with UIKit's layout API. The legacy
        // CalloutMenu path need not populate UIContextMenu configuration.
        CGPoint chatAnchor = anchor;
        if (chatCollectionView.window != menuWindow)
            chatAnchor = [menuWindow convertPoint:anchor toWindow:chatCollectionView.window];
        chatAnchor = [chatCollectionView convertPoint:chatAnchor fromView:chatCollectionView.window];
        NSIndexPath *indexPath = [chatCollectionView indexPathForItemAtPoint:chatAnchor];
        if (!indexPath) continue;
        UICollectionViewCell *cell = [chatCollectionView cellForItemAtIndexPath:indexPath];
        if (!cell || cell.window.windowScene != scene) continue;
        NSDictionary *messageKey = RUINMenuExtrasMessageKeyForCell(cell);
        if (!messageKey.count) continue;

        CGRect cellRect = [cell convertRect:cell.bounds toView:cell.window];
        if (cell.window != menuWindow)
            cellRect = [cell.window convertRect:cellRect toWindow:menuWindow];
        if (!CGRectContainsPoint(CGRectInset(cellRect, -16.0, -16.0), anchor)) continue;

        UIViewController *chatController = RUINMenuExtrasChatControllerForCell(cell, cell.window);
        if (!chatController || chatController.presentedViewController) continue;
        RUINMenuExtrasReadUsersContext *context = [RUINMenuExtrasReadUsersContext new];
        context.messageCell = cell;
        context.messageCollectionView = chatCollectionView;
        context.messageIndexPath = indexPath;
        context.chatViewController = chatController;
        context.messageKey = messageKey;
        context.menuCollectionView = menuCollectionView;
        context.includesReadUsers = includesReadUsers;
        if (canCopyStickerGIF) context.stickerGIFURL = RUINMenuExtrasAnimatedStickerFileURLForCell(cell);
        if (!context.messageKey.count) continue;
        match = context;
        matches++;
    }
    if (matches == 1) {
        if (match.includesReadUsers) atomic_store_explicit(&sReadUsersBindingVerified, true, memory_order_release);
        if (match.includesReadUsers || match.stickerGIFURL) return match;
    }
    return nil;
}

static void RUINMenuExtrasAttachReadUsersEntry(UIView *container)
{
    if (!atomic_load_explicit(&sCalloutGridHooksReady, memory_order_acquire) || !container.window) return;
    id menuViewValue = RUINCopySwiftField(container, "menuView");
    if (![menuViewValue isKindOfClass:UIView.class] ||
        ![NSStringFromClass(object_getClass(menuViewValue)) isEqualToString:@"LineSharedUIComponents.CalloutMenuView"]) return;
    UIView *menuView = menuViewValue;
    id collectionValue = RUINCopySwiftField(menuView, "collectionView");
    if (![collectionValue isKindOfClass:UICollectionView.class]) return;
    UICollectionView *collectionView = collectionValue;
    RUINMenuExtrasReadUsersContext *previous = objc_getAssociatedObject(menuView, &sReadUsersContextAssociationKey);
    if (previous.originalMenuLayout) {
        collectionView.collectionViewLayout = previous.originalMenuLayout;
        collectionView.scrollEnabled = previous.originalScrollEnabled;
    }
    objc_setAssociatedObject(menuView, &sReadUsersContextAssociationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    atomic_store_explicit(&sReadUsersBindingVerified, false, memory_order_release);

    RUINMenuExtrasReadUsersContext *context =
        RUINMenuExtrasResolveReadUsersContext(container, collectionView);
    if (!context) return;
    objc_setAssociatedObject(menuView, &sReadUsersContextAssociationKey, context,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // LINE caches the native menu's row count separately from its data source.
    // A full grid otherwise clips the appended entry (e.g. a recent editable
    // message has twelve native items). Preserve its viewport and original item
    // callbacks, but use UIKit's scrolling grid when the extra item needs a row.
    [collectionView reloadData];
    [collectionView layoutIfNeeded];
    UICollectionViewLayout *nativeLayout = collectionView.collectionViewLayout;
    UICollectionViewLayoutAttributes *first = context.originalItemCount > 0
        ? [nativeLayout layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]] : nil;
    CGSize size = first.size;
    CGFloat width = CGRectGetWidth(collectionView.bounds) - collectionView.adjustedContentInset.left
        - collectionView.adjustedContentInset.right;
    NSInteger columns = size.width > 0 ? (NSInteger)floor((width + 0.5) / size.width) : 0;
    context.nativeItemHeight = size.height;
    context.nativeGridColumns = columns;
    id maximumRows = RUINCopySwiftField(menuView, "maximumRows");
    NSInteger nativeRows = [maximumRows isKindOfClass:NSNumber.class] ? [maximumRows integerValue] : 0;
    context.nativeMaximumRows = nativeRows >= 1 && nativeRows <= 8 ? nativeRows : 3;
    NSInteger addedItems = (context.includesReadUsers ? 1 : 0) + (context.stickerGIFURL ? 1 : 0);
    if (context.hasOriginalItemCount && context.originalItemCount > 0 && columns > 0 &&
        addedItems > 0 &&
        (context.originalItemCount + addedItems - 1) / columns > (context.originalItemCount - 1) / columns &&
        size.height > 0 && isfinite(size.width) && isfinite(size.height)) {
        context.originalMenuLayout = nativeLayout;
        context.originalScrollEnabled = collectionView.scrollEnabled;
        UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
        layout.itemSize = size;
        layout.minimumInteritemSpacing = 0;
        layout.minimumLineSpacing = 0;
        collectionView.collectionViewLayout = layout;
        collectionView.scrollEnabled = YES;
        collectionView.showsVerticalScrollIndicator = YES;
    }
    [collectionView reloadData];
    [menuView invalidateIntrinsicContentSize];
    [container setNeedsLayout];
}

static UICollectionViewCell *RUINMenuExtrasActionCell(
    UICollectionView *collectionView, NSIndexPath *indexPath, NSString *title, NSString *symbolName)
{
    static NSString *const reuseIdentifier = @"RUIN.MenuExtras.CalloutAction";
    if (![objc_getAssociatedObject(collectionView, &sCalloutActionCellRegistrationAssociationKey) boolValue]) {
        Class cellClass = objc_getClass("_TtC22LineSharedUIComponents19CalloutMenuItemCell") ?: UICollectionViewCell.class;
        [collectionView registerClass:cellClass forCellWithReuseIdentifier:reuseIdentifier];
        objc_setAssociatedObject(collectionView, &sCalloutActionCellRegistrationAssociationKey, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UICollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:reuseIdentifier
                                                                            forIndexPath:indexPath];
    UILabel *titleLabel = RUINCopySwiftField(cell, "titleLabel");
    UIImageView *imageView = RUINCopySwiftField(cell, "imageView");
    if (!titleLabel) {
        titleLabel = [UILabel new];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        titleLabel.textAlignment = NSTextAlignmentCenter;
        titleLabel.font = [UIFont systemFontOfSize:12.0];
        titleLabel.numberOfLines = 1;
        [cell.contentView addSubview:titleLabel];
        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:2.0],
            [titleLabel.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-2.0],
            [titleLabel.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-5.0]
        ]];
    }
    if (!imageView) {
        imageView = [UIImageView new];
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        [cell.contentView addSubview:imageView];
        [NSLayoutConstraint activateConstraints:@[
            [imageView.centerXAnchor constraintEqualToAnchor:cell.contentView.centerXAnchor],
            [imageView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:7.0],
            [imageView.widthAnchor constraintEqualToConstant:23.0],
            [imageView.heightAnchor constraintEqualToConstant:23.0],
            [titleLabel.topAnchor constraintGreaterThanOrEqualToAnchor:imageView.bottomAnchor constant:2.0]
        ]];
    }
    titleLabel.text = title;
    imageView.image = [UIImage systemImageNamed:symbolName];
    imageView.tintColor = titleLabel.textColor;
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = title;
    return cell;
}

static UICollectionViewCell *RUINMenuExtrasReadUsersCell(
    UICollectionView *collectionView, NSIndexPath *indexPath)
{
    return RUINMenuExtrasActionCell(collectionView, indexPath, NSLocalizedString(@"既読者一覧", nil), @"eye");
}

static UICollectionViewCell *RUINMenuExtrasStickerGIFCell(
    UICollectionView *collectionView, NSIndexPath *indexPath)
{
    return RUINMenuExtrasActionCell(collectionView, indexPath, NSLocalizedString(@"GIFでコピー", nil), @"doc.on.doc");
}

static NSInteger RUINMenuExtrasAdditionalActionCount(RUINMenuExtrasReadUsersContext *context)
{
    return (context.includesReadUsers ? 1 : 0) + (context.stickerGIFURL ? 1 : 0);
}

%group RUINMenuIntrinsic
%hook RUINMenuCallout
- (CGSize)intrinsicContentSize {
    CGSize size = %orig;
    RUINMenuExtrasReadUsersContext *context = objc_getAssociatedObject(self, &sReadUsersContextAssociationKey);
    if (!context.originalMenuLayout || !context.hasOriginalItemCount || context.nativeGridColumns < 1 ||
        !isfinite(context.nativeItemHeight) || context.nativeItemHeight <= 0 || size.height < 0) return size;
    NSInteger count = context.originalItemCount + RUINMenuExtrasAdditionalActionCount(context);
    NSInteger rows = (count + context.nativeGridColumns - 1) / context.nativeGridColumns;
    CGFloat height = MIN(rows, context.nativeMaximumRows) * context.nativeItemHeight;
    if (isfinite(height) && height > size.height) {
        size.height = height;
        atomic_fetch_add(&sCalloutSizingGrowCount, 1);
    }
    return size;

}
%end
%end

%group RUINMenuCount
%hook RUINMenuCallout
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    NSInteger count = %orig;
    if (!atomic_load_explicit(&sCalloutGridHooksReady, memory_order_acquire) || section != 0 ||
        ![self isKindOfClass:UIView.class]) return count;
    RUINMenuExtrasReadUsersContext *context = objc_getAssociatedObject(self, &sReadUsersContextAssociationKey);
    if (!context || context.menuCollectionView != collectionView || !context.messageCell) return count;
    context.originalItemCount = count;
    context.hasOriginalItemCount = YES;
    return count + RUINMenuExtrasAdditionalActionCount(context);

}
%end
%end

%group RUINMenuCell
%hook RUINMenuCallout
- (id)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    RUINMenuExtrasReadUsersContext *context = objc_getAssociatedObject(self, &sReadUsersContextAssociationKey);
    if (atomic_load_explicit(&sCalloutGridHooksReady, memory_order_acquire) && indexPath.section == 0 &&
        context && context.menuCollectionView == collectionView && context.hasOriginalItemCount) {
        NSInteger actionIndex = context.originalItemCount;
        if (context.includesReadUsers && indexPath.item == actionIndex)
            return RUINMenuExtrasReadUsersCell(collectionView, indexPath);
        actionIndex += context.includesReadUsers ? 1 : 0;
        if (context.stickerGIFURL && indexPath.item == actionIndex)
            return RUINMenuExtrasStickerGIFCell(collectionView, indexPath);
    }
    return %orig;

}
%end
%end

static void RUINMenuExtrasPresentReadUsersMessage(UIViewController *chatController, NSString *message)
{
    if (!chatController || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        chatController.isBeingDismissed || chatController.isBeingPresented ||
        chatController.presentedViewController || !chatController.viewIfLoaded.window ||
        chatController.viewIfLoaded.window.windowScene.activationState != UISceneActivationStateForegroundActive)
        return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"既読者一覧", nil)
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [chatController presentViewController:alert animated:YES completion:nil];
}

static void RUINMenuExtrasPresentStickerGIFFailure(UIViewController *chatController)
{
    if (!chatController || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        chatController.isBeingDismissed || chatController.isBeingPresented || chatController.presentedViewController ||
        !chatController.viewIfLoaded.window ||
        chatController.viewIfLoaded.window.windowScene.activationState != UISceneActivationStateForegroundActive)
        return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:NSLocalizedString(@"GIFをコピーできませんでした", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [chatController presentViewController:alert animated:YES completion:nil];
}

static void RUINMenuExtrasPresentReaders(UIViewController *chatController,
                                          NSArray<NSDictionary *> *readers, RUINReaderLoader loader)
{
    RUINPresentReadersSheetWithLoader(chatController, readers, loader, ^(UIViewController *sheet, NSString *mid) {
        RUINOpenMIDProfile(sheet, mid);
    });
}

%group RUINMenuSelection
%hook RUINMenuCallout
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    RUINMenuExtrasReadUsersContext *context = objc_getAssociatedObject(self, &sReadUsersContextAssociationKey);
    BOOL menuActionSelected = atomic_load_explicit(&sCalloutGridHooksReady, memory_order_acquire) &&
        indexPath.section == 0 && context && context.menuCollectionView == collectionView &&
        context.hasOriginalItemCount;
    NSInteger stickerGIFIndex = context.originalItemCount + (context.includesReadUsers ? 1 : 0);
    BOOL selectedStickerGIF = menuActionSelected && context.stickerGIFURL && indexPath.item == stickerGIFIndex;
    BOOL selectedReadUsers = menuActionSelected && context.includesReadUsers &&
        indexPath.item == context.originalItemCount;
    if (selectedStickerGIF) {
        UICollectionViewCell *cell = context.messageCell;
        NSDictionary *messageKey = RUINMenuExtrasMessageKeyForCell(cell);
        NSIndexPath *currentIndexPath = cell && context.messageCollectionView
            ? [context.messageCollectionView indexPathForCell:cell] : nil;
        NSURL *currentURL = RUINMenuExtrasAnimatedStickerFileURLForCell(cell);
        BOOL bindingMatches = messageKey.count && [messageKey isEqual:context.messageKey] &&
            [currentIndexPath isEqual:context.messageIndexPath] && [currentURL isEqual:context.stickerGIFURL];
        __weak UIViewController *chatController = context.chatViewController;
        [(id)self accessibilityPerformEscape];
        // Encode after the native selection has been validated and copied.
        // Large animations must not block UIKit or its watchdog.
        static dispatch_queue_t encodingQueue;
        static dispatch_once_t encodingQueueOnce;
        dispatch_once(&encodingQueueOnce, ^{
            encodingQueue = dispatch_queue_create("com.tqmane.ruin.sticker-gif", DISPATCH_QUEUE_SERIAL);
        });
        dispatch_async(encodingQueue, ^{ @autoreleasepool {
            BOOL copied = bindingMatches && RUINMenuExtrasCopyAnimatedGIFFromLocalFileURL(currentURL, NULL);
            if (!copied) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                RUINMenuExtrasPresentStickerGIFFailure(chatController);
            });
        }});
        return;
    }
    if (!selectedReadUsers) {
        %orig;
        return;
    }

    UICollectionViewCell *cell = context.messageCell;
    UICollectionView *messageCollectionView = context.messageCollectionView;
    NSDictionary *messageKey = RUINMenuExtrasMessageKeyForCell(cell);
    NSIndexPath *currentIndexPath = cell && messageCollectionView
        ? [messageCollectionView indexPathForCell:cell] : nil;
    if (!messageKey.count || ![messageKey isEqual:context.messageKey] || ![currentIndexPath isEqual:context.messageIndexPath]) {
        UIViewController *chatController = context.chatViewController;
        [(id)self accessibilityPerformEscape];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            RUINMenuExtrasPresentReadUsersMessage(chatController,
                NSLocalizedString(@"取得できませんでした", nil));
        });
        return;
    }

    UIViewController *chatController = context.chatViewController;
    __block id nativeChat = nil;
    @try {
        SEL chatSelector = sel_registerName("chat");
        Method getter = chatController ? class_getInstanceMethod(object_getClass(chatController), chatSelector) : NULL;
        if (getter && !strcmp(method_getTypeEncoding(getter), "@16@0:8")) {
            id chat = [(id<RUINMessagingChatOwner>)chatController chat];
            nativeChat = chat;
            RUINObserveNativeReadPositionsForMessageKey(messageKey, chat);
        }
    } @catch (__unused NSException *exception) { /* Existing recorded ranges remain usable. */ }
    NSArray<NSDictionary *> *readers = RUINReadUsersForMessageKey(messageKey);
    NSDictionary *copiedKey = [messageKey copy];
    id boundChat = nativeChat;
    RUINReaderLoader loader = ^(RUINReaderLoadCompletion completion) {
        RUINFetchReadRanges(copiedKey, boundChat, ^(NSError *error) {
            completion(error ? @[] : RUINReadUsersForMessageKey(copiedKey), error);
        });
    };
    [(id)self accessibilityPerformEscape];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RUINMenuExtrasPresentReaders(chatController, readers, loader);
    });

}
%end
%end

%group RUINMenuWindow
%hook RUINMenuContainer
- (void)didMoveToWindow {
    %orig;
    if (NSThread.isMainThread && ((UIView *)self).window) {
        RUINMenuExtrasScheduleInspection();
        UIView *container = (UIView *)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (container.window) RUINMenuExtrasAttachReadUsersEntry(container);
        });
    }

}
%end
%end

static Method RUINMenuExtrasOwnMethod(Class cls, SEL selector)
{
    unsigned int count = 0;
    Method *methods = cls ? class_copyMethodList(cls, &count) : NULL;
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

static NSString *RUINMenuExtrasHookStatusName(RUINMenuExtrasHookStatus status)
{
    switch (status) {
        case RUINMenuExtrasHookVersionGated: return @"exact-build-gate-failed";
        case RUINMenuExtrasHookMissingClass: return @"native-class-missing";
        case RUINMenuExtrasHookMissingSelector: return @"native-selector-missing";
        case RUINMenuExtrasHookNotOwnMethod: return @"method-not-owned-by-target-class";
        case RUINMenuExtrasHookEncodingMismatch: return @"method-encoding-mismatch";
        case RUINMenuExtrasHookInstallFailed: return @"method-hook-install-failed";
        case RUINMenuExtrasHookInstalled: return @"installed";
        default: return @"not-attempted";
    }
}

static RUINMenuExtrasHookStatus RUINMenuExtrasValidateHook(Class cls, SEL selector, const char *expectedEncoding, BOOL requireOwn) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!cls) return RUINMenuExtrasHookMissingClass;
    if (!method) return RUINMenuExtrasHookMissingSelector;
    if (requireOwn && !RUINMenuExtrasOwnMethod(cls, selector)) return RUINMenuExtrasHookNotOwnMethod;
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || strcmp(encoding, expectedEncoding)) return RUINMenuExtrasHookEncodingMismatch;
    return method_getImplementation(method) ? RUINMenuExtrasHookInstalled : RUINMenuExtrasHookInstallFailed;
}

BOOL RUINMenuExtrasCopyAnimatedGIFFromLocalFileURL(NSURL *URL, NSError **error)
{
    atomic_fetch_add_explicit(&sStickerGIFCopyAttemptCount, 1, memory_order_relaxed);
    atomic_store(&sStickerGIFLastFrameCount, 0);
    if (error) *error = nil;
    if (!RUINMenuExtrasTargetMatches()) {
        RUINMenuExtrasSetError(error, RUINMenuExtrasErrorIncompatibleTarget, @"This LINE build is not supported.");
        return NO;
    }
    if (!RUINMenuExtrasPreferenceEnabled(RUINCopyStickerGIFEnabledDefaultsKey)) {
        RUINMenuExtrasSetError(error, RUINMenuExtrasErrorPreferenceDisabled, @"Animated sticker copy is disabled.");
        return NO;
    }

    NSUInteger frameCount = 0;
    NSError *encodingError = nil;
    NSData *data = RUINGIFEncoderCreateGIFDataFromLocalFileURL(URL, &frameCount, &encodingError);
    if (!data) {
        if (error) *error = encodingError;
        if ([encodingError.domain isEqualToString:@"RUINGIFEncoderErrorDomain"])
            atomic_store_explicit(&sStickerGIFLastEncodingRejectionCode, (int)encodingError.code, memory_order_relaxed);
        return NO;
    }
    atomic_store(&sStickerGIFLastFrameCount, frameCount);
    __block BOOL stored = NO;
    void (^writeClipboard)(void) = ^{
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
            !RUINMenuExtrasPreferenceEnabled(RUINCopyStickerGIFEnabledDefaultsKey)) return;
        @try {
            UIPasteboard *pasteboard = UIPasteboard.generalPasteboard;
            [pasteboard setData:data forPasteboardType:UTTypeGIF.identifier];
            // Read back only the GIF just written by this user action.
            stored = [[pasteboard dataForPasteboardType:UTTypeGIF.identifier] isEqualToData:data];
        } @catch (__unused NSException *exception) { stored = NO; }
    };
    if (NSThread.isMainThread) writeClipboard();
    else dispatch_sync(dispatch_get_main_queue(), writeClipboard);
    if (!stored) {
        RUINMenuExtrasSetError(error, RUINMenuExtrasErrorGIFEncoding, @"The copied GIF could not be verified on the clipboard.");
        return NO;
    }
    atomic_fetch_add(&sStickerGIFPasteboardVerifiedCount, 1);
    atomic_store(&sStickerGIFLastFrameCount, frameCount);
    atomic_fetch_add_explicit(&sStickerGIFCopySuccessCount, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&sStickerGIFEncodedFrameCount, frameCount, memory_order_relaxed);
    atomic_store_explicit(&sStickerGIFLastEncodingRejectionCode, 0, memory_order_relaxed);
    return YES;
}

BOOL RUINMenuExtrasCopyMIDFromManagedUser(id managedUser, NSError **error)
{
    if (error) *error = nil;
    if (!RUINMenuExtrasTargetMatches()) {
        RUINMenuExtrasSetError(error, RUINMenuExtrasErrorIncompatibleTarget, @"This LINE build is not supported.");
        return NO;
    }
    if (!RUINMenuExtrasPreferenceEnabled(RUINCopyMIDEnabledDefaultsKey)) {
        RUINMenuExtrasSetError(error, RUINMenuExtrasErrorPreferenceDisabled, @"MID copy is disabled.");
        return NO;
    }

    Class userClass = objc_getClass("ManagedUser");
    SEL midStringSelector = sel_registerName("midString");
    if (!userClass || !managedUser || ![managedUser isKindOfClass:userClass]) {
        RUINMenuExtrasSetError(error, RUINMenuExtrasErrorMIDUnavailable, @"The verified LINE user MID field is unavailable.");
        return NO;
    }
    Method midStringMethod = class_getInstanceMethod(object_getClass(managedUser), midStringSelector);
    const char *encoding = midStringMethod ? method_getTypeEncoding(midStringMethod) : NULL;
    if (!encoding || strcmp(encoding, "@16@0:8") != 0) {
        RUINMenuExtrasSetError(error, RUINMenuExtrasErrorMIDUnavailable, @"The verified LINE user MID field is unavailable.");
        return NO;
    }

    id value = [(id<RUINMessagingUserFields>)managedUser midString];
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] == 0) {
        RUINMenuExtrasSetError(error, RUINMenuExtrasErrorMIDUnavailable, @"This user has no copyable MID.");
        return NO;
    }

    UIPasteboard.generalPasteboard.string = value;
    return YES;
}

void RUINInstallMenuExtras(void)
{
    atomic_store_explicit(&sInstallAttempted, true, memory_order_release);
    os_unfair_lock_lock(&sMenuHookLock);
    if (!RUINMenuExtrasTargetMatches()) {
        atomic_store_explicit(&sMenuHookStatus, RUINMenuExtrasHookVersionGated, memory_order_release);
        atomic_store_explicit(&sCalloutSurfaceHookStatus, RUINMenuExtrasHookVersionGated, memory_order_release);
        atomic_store_explicit(&sCalloutGridHookStatus, RUINMenuExtrasHookVersionGated, memory_order_release);
        atomic_store_explicit(&sCalloutGridHooksReady, false, memory_order_release);
        os_unfair_lock_unlock(&sMenuHookLock);
        return;
    }

    Class interaction = objc_getClass("_TtC17LineMessagingUIV229MessageContextMenuInteraction");
    RUINMenuExtrasHookStatus menuStatus = sMenuLongPressInstalled ? RUINMenuExtrasHookInstalled :
        RUINMenuExtrasValidateHook(interaction, sel_registerName("handleLongPressGesture:"), "v24@0:8@16", YES);
    if (!sMenuLongPressInstalled && menuStatus == RUINMenuExtrasHookInstalled) {
        %init(RUINMenuLongPress, RUINMenuInteraction = interaction);
        sMenuLongPressInstalled = YES;
    }
    atomic_store(&sMenuHookStatus, menuStatus);

    Class container = objc_getClass("_TtC22LineSharedUIComponents24CalloutMenuContainerView");
    RUINMenuExtrasHookStatus windowStatus = sCalloutWindowInstalled ? RUINMenuExtrasHookInstalled :
        RUINMenuExtrasValidateHook(container, sel_registerName("didMoveToWindow"), "v16@0:8", NO);
    if (!sCalloutWindowInstalled && windowStatus == RUINMenuExtrasHookInstalled) {
        %init(RUINMenuWindow, RUINMenuContainer = container);
        sCalloutWindowInstalled = YES;
    }
    atomic_store(&sCalloutSurfaceHookStatus, windowStatus);

    Class callout = objc_getClass("_TtC22LineSharedUIComponents15CalloutMenuView");
    RUINMenuExtrasHookStatus numberStatus = sCalloutCountInstalled ? RUINMenuExtrasHookInstalled :
        RUINMenuExtrasValidateHook(callout, sel_registerName("collectionView:numberOfItemsInSection:"), "q32@0:8@16q24", YES);
    if (!sCalloutCountInstalled && numberStatus == RUINMenuExtrasHookInstalled) {
        %init(RUINMenuCount, RUINMenuCallout = callout);
        sCalloutCountInstalled = YES;
    }
    RUINMenuExtrasHookStatus cellStatus = sCalloutCellInstalled ? RUINMenuExtrasHookInstalled :
        RUINMenuExtrasValidateHook(callout, sel_registerName("collectionView:cellForItemAtIndexPath:"), "@32@0:8@16@24", YES);
    if (!sCalloutCellInstalled && cellStatus == RUINMenuExtrasHookInstalled) {
        %init(RUINMenuCell, RUINMenuCallout = callout);
        sCalloutCellInstalled = YES;
    }
    RUINMenuExtrasHookStatus selectStatus = sCalloutSelectionInstalled ? RUINMenuExtrasHookInstalled :
        RUINMenuExtrasValidateHook(callout, sel_registerName("collectionView:didSelectItemAtIndexPath:"), "v32@0:8@16@24", YES);
    if (!sCalloutSelectionInstalled && selectStatus == RUINMenuExtrasHookInstalled) {
        %init(RUINMenuSelection, RUINMenuCallout = callout);
        sCalloutSelectionInstalled = YES;
    }
    BOOL allInstalled = sCalloutCountInstalled && sCalloutCellInstalled && sCalloutSelectionInstalled;
    atomic_store(&sCalloutGridHooksReady, allInstalled);
    atomic_store(&sCalloutGridHookStatus, allInstalled ? RUINMenuExtrasHookInstalled :
        (numberStatus != RUINMenuExtrasHookInstalled ? numberStatus :
         (cellStatus != RUINMenuExtrasHookInstalled ? cellStatus : selectStatus)));

    RUINMenuExtrasHookStatus intrinsicStatus = sCalloutIntrinsicInstalled ? RUINMenuExtrasHookInstalled :
        RUINMenuExtrasValidateHook(callout, sel_registerName("intrinsicContentSize"), "{CGSize=dd}16@0:8", YES);
    if (!sCalloutIntrinsicInstalled && intrinsicStatus == RUINMenuExtrasHookInstalled) {
        %init(RUINMenuIntrinsic, RUINMenuCallout = callout);
        sCalloutIntrinsicInstalled = YES;
    }
    atomic_store(&sCalloutIntrinsicHookStatus, intrinsicStatus);

    os_unfair_lock_unlock(&sMenuHookLock);
}

NSDictionary *RUINMenuExtrasDiagnostics(void)
{
    Class chatMenuHandler = objc_getClass("_TtC15LineMessagingUI22ChatMessageMenuHandler");
    Class friendSearchRoute = objc_getClass("_TtC4LINE36LineFriendSearchByIDNavigationScheme");
    Class userIDValidator = objc_getClass("_TtC4LINE21SearchUserIDValidator");
    Class animatedStickerCell = objc_getClass("_TtC17LineMessagingUIV231ChatAnimationStickerMessageCell");
    Class animatedStickerViewModel = objc_getClass("_TtC15LineMessagingUI36ChatAnimationStickerMessageViewModel");
    BOOL targetMatches = RUINMenuExtrasTargetMatches();
    NSString *chatMenuProviderEncoding = RUINMenuExtrasEncoding(chatMenuHandler,
        "editMenuInteraction:menuForConfiguration:suggestedActions:");
    BOOL chatMenuProvider = [chatMenuProviderEncoding isEqualToString:@"@40@0:8@16@24@32"];
    RUINMenuExtrasHookStatus hookStatus = (RUINMenuExtrasHookStatus)atomic_load_explicit(&sMenuHookStatus, memory_order_acquire);
    RUINMenuExtrasHookStatus calloutHookStatus = (RUINMenuExtrasHookStatus)atomic_load_explicit(&sCalloutSurfaceHookStatus, memory_order_acquire);
    RUINMenuExtrasHookStatus calloutGridHookStatus = (RUINMenuExtrasHookStatus)atomic_load_explicit(&sCalloutGridHookStatus, memory_order_acquire);
    BOOL readUsersHooksInstalled = calloutHookStatus == RUINMenuExtrasHookInstalled &&
        calloutGridHookStatus == RUINMenuExtrasHookInstalled;
    BOOL stickerMenuReady = targetMatches && readUsersHooksInstalled && animatedStickerCell && animatedStickerViewModel;
    NSString *installReason = @"exact-bundle-version-build-gate-failed";
    if (targetMatches) {
        installReason = readUsersHooksInstalled ?
            @"CalloutMenuView read-users action hooks installed; row requires a live selected ManagedMessage binding" :
            calloutHookStatus == RUINMenuExtrasHookInstalled ?
            @"read-only CalloutMenuContainerView.didMoveToWindow probe installed; grid action hooks unavailable" :
            chatMenuProvider ?
            @"menu-provider-signature-present-but-not-validated-for-message-context" :
            (chatMenuProviderEncoding ? @"chat-menu-provider-encoding-mismatch" : RUINMenuExtrasHookStatusName(hookStatus));
    }

    return @{
        @"targetMatches26_16_0_2026_1006_1718": @(targetMatches),
        @"installAttempted": @(atomic_load_explicit(&sInstallAttempted, memory_order_acquire)),
        @"menuActionInstalled": @(readUsersHooksInstalled),
        @"stickerGIFMenuActionReady": @(stickerMenuReady),
        @"inspectionHookInstalled": @(hookStatus == RUINMenuExtrasHookInstalled),
        @"inspectionHookStatus": RUINMenuExtrasHookStatusName(hookStatus),
        @"calloutSurfaceHookInstalled": @(calloutHookStatus == RUINMenuExtrasHookInstalled),
        @"calloutSurfaceHookStatus": RUINMenuExtrasHookStatusName(calloutHookStatus),
        @"calloutGridHookInstalled": @(calloutGridHookStatus == RUINMenuExtrasHookInstalled),
        @"calloutGridHookStatus": RUINMenuExtrasHookStatusName(calloutGridHookStatus),
        @"installReason": installReason,
        @"preferences": @{
            @"copyStickerGIF": @{
                @"key": RUINCopyStickerGIFEnabledDefaultsKey,
                @"enabled": @(RUINMenuExtrasPreferenceEnabled(RUINCopyStickerGIFEnabledDefaultsKey)),
                @"default": @NO
            },
            @"copyMID": @{
                @"key": RUINCopyMIDEnabledDefaultsKey,
                @"enabled": @(RUINMenuExtrasPreferenceEnabled(RUINCopyMIDEnabledDefaultsKey)),
                @"default": @NO
            },
            @"searchMID": @{
                @"key": RUINSearchMIDEnabledDefaultsKey,
                @"enabled": @(RUINMenuExtrasPreferenceEnabled(RUINSearchMIDEnabledDefaultsKey)),
                @"default": @NO
            },

        },
        @"menuExtraRows": @{
            @"intrinsicHookStatus": RUINMenuExtrasHookStatusName(atomic_load(&sCalloutIntrinsicHookStatus)),
            @"sizingGrowCount": @(atomic_load(&sCalloutSizingGrowCount))},
        @"stickerGIFCopy": @{
            @"pasteboardVerifiedCount": @(atomic_load(&sStickerGIFPasteboardVerifiedCount)),
            @"lastEncodedFrameCount": @(atomic_load(&sStickerGIFLastFrameCount)),
            @"copyAttemptCount": @(atomic_load_explicit(&sStickerGIFCopyAttemptCount, memory_order_relaxed)),
            @"copySuccessCount": @(atomic_load_explicit(&sStickerGIFCopySuccessCount, memory_order_relaxed)),
            @"encodedFrameCount": @(atomic_load_explicit(&sStickerGIFEncodedFrameCount, memory_order_relaxed)),
            @"lastEncodingRejection": RUINGIFEncoderRejectionName(
                atomic_load_explicit(&sStickerGIFLastEncodingRejectionCode, memory_order_relaxed))
        },
        @"nativeEvidence": @{
            @"chatMessageMenuHandler": @{
                @"ownObjectiveCMethodCount": @(RUINMenuExtrasOwnMethodCount(chatMenuHandler)),
                @"menuProvider": RUINMenuExtrasMethodEvidence(@"_TtC15LineMessagingUI22ChatMessageMenuHandler",
                    @"editMenuInteraction:menuForConfiguration:suggestedActions:", @"@40@0:8@16@24@32")
            },
            @"messageContextMenuLongPress": RUINMenuExtrasMethodEvidence(@"_TtC17LineMessagingUIV229MessageContextMenuInteraction",
                @"handleLongPressGesture:", @"v24@0:8@16"),
            @"messageMenuTapHandler": RUINMenuExtrasMethodEvidence(@"_TtC15LineMessagingUI21MessageMenuController",
                @"didTapItem:", @"v24@0:8@16"),
            @"messageMenuStorage": @{
                @"fieldName": @"$__lazy_storage_$_menuItems",
                @"staticType": @"[__C.UIMenuItem]?",
                @"source": @"LINE 26.16 Swift field descriptor"
            },
            @"capturedCalloutMenuGrid": @{
                @"viewClass": @"_TtC22LineSharedUIComponents15CalloutMenuView",
                @"fieldNames": RUINMenuExtrasIvarNames(objc_getClass("_TtC22LineSharedUIComponents15CalloutMenuView")),
                @"itemCellClass": @"_TtC22LineSharedUIComponents19CalloutMenuItemCell",
                @"itemCellFieldNames": RUINMenuExtrasIvarNames(objc_getClass("_TtC22LineSharedUIComponents19CalloutMenuItemCell")),
                @"containerClass": @"_TtC22LineSharedUIComponents24CalloutMenuContainerView",
                @"containerFieldNames": RUINMenuExtrasIvarNames(objc_getClass("_TtC22LineSharedUIComponents24CalloutMenuContainerView")),
                @"numberOfItems": RUINMenuExtrasMethodEvidence(@"_TtC22LineSharedUIComponents15CalloutMenuView",
                    @"collectionView:numberOfItemsInSection:", @"q32@0:8@16q24"),
                @"cellForItem": RUINMenuExtrasMethodEvidence(@"_TtC22LineSharedUIComponents15CalloutMenuView",
                    @"collectionView:cellForItemAtIndexPath:", @"@32@0:8@16@24"),
                @"didSelectItem": RUINMenuExtrasMethodEvidence(@"_TtC22LineSharedUIComponents15CalloutMenuView",
                    @"collectionView:didSelectItemAtIndexPath:", @"v32@0:8@16@24"),
                @"containerDidMoveToWindow": RUINMenuExtrasMethodEvidence(@"_TtC22LineSharedUIComponents24CalloutMenuContainerView",
                    @"didMoveToWindow", @"v16@0:8")
            },
            @"swiftMenuConformances": @[
                @{
                    @"className": @"_TtC17LineMessagingUIV218ChatCollectionView",
                    @"protocolName": @"LineMessagingUIV2.MessageContextMenuInteractionDelegate"
                },
                @{
                    @"className": @"_TtC15LineMessagingUI22ChatMessageMenuHandler",
                    @"protocolNames": @[@"LineMessagingUIV2.MessageContextMenuHandler", @"LineMessagingUI.MessageMenuControllerDelegate"]
                }
            ],
            @"nonChatPostStickerMenuProvider": RUINMenuExtrasMethodEvidence(@"_TtC22LinePostFeatureSupport29PostStickerCollectionViewCell",
                @"editMenuInteraction:menuForConfiguration:suggestedActions:", @"@40@0:8@16@24@32"),
            @"managedUserMID": RUINMenuExtrasMethodEvidence(@"ManagedUser", @"midString", @"@16@0:8"),
            @"nativeMIDSearch": @{
                @"routeClassPresent": @(friendSearchRoute != Nil),
                @"routeClassObjectiveCMethodCount": @(RUINMenuExtrasOwnMethodCount(friendSearchRoute)),
                @"validatorClassPresent": @(userIDValidator != Nil),
                @"routePathEvidence": @"nv/friendSearchById",
                @"reason": @"the native route and validator are Swift-only in Objective-C metadata; this public-ID route's MID parameter contract is unverified"
            },
            @"readUsersMenu": @{
                @"snapshotCallbackDeclared": @YES,
                @"callback": @"RUINReadUsersForMessage(id)",
                @"menuBoundaryAvailable": @(calloutGridHookStatus == RUINMenuExtrasHookInstalled),
                @"nativeGridBoundaryAvailable": @YES,
                @"readUsersActionInstalled": @(readUsersHooksInstalled),
                @"capturedGridClass": @"LineSharedUIComponents.CalloutMenuView",
                @"selectedMessagePath": @"ChatCollectionView.messageContextMenuInteractionParameters.configuration.indexPath -> cell.messageViewModel.message",
                @"selectedManagedMessageBindingVerified": @(atomic_load_explicit(&sReadUsersBindingVerified, memory_order_acquire)),
                @"rowGuard": @"targetPlaceholderView anchor must overlap the selected message cell; message must resolve as ManagedMessage or ManagedSquareMessage",
                @"readerDataAccess": @"RUINReadUsersForMessage runs only after the user selects 既読者一覧",
                @"trackingPreferenceEnabled": @(RUINMenuExtrasPreferenceEnabled(RUINTrackReadUsersKey)),
                @"reason": @"The three LINE CalloutMenuView grid callbacks are hooked by exact selector and encoding. The row is inserted only for a unique live message-cell binding; every original item retains LINE's original callback."
            },
            @"animatedStickerGIFMenu": @{
                @"cellClass": @"_TtC17LineMessagingUIV231ChatAnimationStickerMessageCell",
                @"cellClassPresent": @(animatedStickerCell != Nil),
                @"viewModelClass": @"_TtC15LineMessagingUI36ChatAnimationStickerMessageViewModel",
                @"viewModelClassPresent": @(animatedStickerViewModel != Nil),
                @"messageViewModelField": @"ChatBaseMessageCell.messageViewModel",
                @"assetFileURLField": @"ChatAnimationStickerMessageViewModel.sourceFileURLs.animation",
                @"assetFileURLStaticType": @"(animation: Foundation.URL, audio: Foundation.URL?)?",
                @"fieldSource": @"LINE 26.16 __swift5_types/__swift5_fieldmd and symbolic __swift5_typeref",
                @"runtimeGuards": @[
                    @"exact animated sticker cell and view-model classes",
                    @"animation URL must bridge to NSURL and be an existing local file, not a directory",
                    @"GIF frame and timing validation only after the user selects the action"
                ],
                @"menuActionReady": @(stickerMenuReady)
            },

        },
        @"capabilities": @{
            @"animatedGIFCopyHelper": @YES,
            @"managedUserMIDCopyHelper": @YES,
            @"stickerMenuAugmentation": @(stickerMenuReady),
            @"readUsersMenuIntegration": @(readUsersHooksInstalled),
            @"readUsersBindingVerified": @(atomic_load_explicit(&sReadUsersBindingVerified, memory_order_acquire)),
            @"MIDSearch": @NO,
            @"runtimeMenuSignatureInspector": @YES,
            @"menuInspectionReportPath": @"Library/Caches/RUIN/menu-inspection.json",
            @"reason": @"The reader row requires a unique live selected-message binding. The sticker GIF row also requires the exact animated-sticker cell and view-model plus one existing local source file; native menu selections continue through LINE's callback."
        }
    };
}
