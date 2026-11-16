%config(generator=internal);

#import "LocalUnreadTabBadge.h"
#import "LocalUnreadBadges.h"
#import "TargetMetadata.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <string.h>

@interface RUINLocalTabBadgeState : NSObject
@property(nonatomic, weak) UITabBarController *owner;
@property(nonatomic, copy) NSString *nativeValue;
@end
@implementation RUINLocalTabBadgeState @end

static char StateKey, BoundItemKey;
static Class rootClass, chatClass;
static NSHashTable<UITabBarController *> *roots;
static NSUInteger correction, correctionWrites, rawChanges, bindings;
static BOOL installed;
static UITabBarItem *applyingItem;

static BOOL SameValue(NSString *left, NSString *right) {
    return left == right || [left isEqualToString:right];
}

static BOOL ClassBelongs(Class cls) {
    const char *path = cls ? class_getImageName(cls) : NULL;
    NSString *owner = path ? [NSString stringWithUTF8String:path].stringByResolvingSymlinksInPath : nil;
    NSString *host = NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath;
    return host.length && [owner isEqualToString:host];
}

static NSString *ProjectedValue(NSString *native, NSUInteger count) {
    if (!count || !native.length || native.length > 20) return native;
    NSUInteger value = 0;
    for (NSUInteger i = 0; i < native.length; i++) {
        unichar c = [native characterAtIndex:i];
        if (c < '0' || c > '9' || value > (NSUIntegerMax - (c - '0')) / 10) return native;
        value = value * 10 + c - '0';
    }
    return value > count ? [NSString stringWithFormat:@"%lu", (unsigned long)(value - count)] : nil;
}

static UITabBarItem *TalkItem(UITabBarController *root) {
    UITabBarItem *found = nil;
    for (UIViewController *entry in root.viewControllers) {
        UIViewController *content = entry;
        NSUInteger depth = 0;
        while ([content isKindOfClass:UINavigationController.class] && depth++ < 8)
            content = ((UINavigationController *)content).viewControllers.firstObject;
        if (!chatClass || ![content isKindOfClass:chatClass]) continue;
        UITabBarItem *item = entry.tabBarItem;
        if (!item || (found && found != item)) return nil; // Ambiguous native structure: preserve it.
        found = item;
    }
    return found;
}

static void WriteValue(UITabBarItem *item, NSString *value) {
    if (SameValue(item.badgeValue, value)) return;
    UITabBarItem *previous = applyingItem;
    applyingItem = item;
    @try { item.badgeValue = value; correctionWrites++; }
    @finally { applyingItem = previous; }
}

static void RefreshRoot(UITabBarController *root) {
    if (!NSThread.isMainThread || ![root isKindOfClass:rootClass]) return;
    [roots addObject:root];
    UITabBarItem *old = objc_getAssociatedObject(root, &BoundItemKey);
    UITabBarItem *item = TalkItem(root);
    if (old != item) {
        RUINLocalTabBadgeState *oldState = objc_getAssociatedObject(old, &StateKey);
        if (oldState.owner == root) {
            WriteValue(old, oldState.nativeValue);
            objc_setAssociatedObject(old, &StateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        objc_setAssociatedObject(root, &BoundItemKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!item) return;
    RUINLocalTabBadgeState *state = objc_getAssociatedObject(item, &StateKey);
    if (state && !state.owner) {
        WriteValue(item, state.nativeValue);
        objc_setAssociatedObject(item, &StateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        state = nil;
    }
    BOOL newlyBound = !state;
    if (!state) {
        state = [RUINLocalTabBadgeState new];
        state.owner = root;
        state.nativeValue = item.badgeValue;
        objc_setAssociatedObject(item, &StateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        bindings++;
    }
    if (state.owner != root) return;
    WriteValue(item, ProjectedValue(state.nativeValue, correction));
    if (newlyBound) RUINRefreshLocalUnreadBadgeTotals();
}

%group RUINLocalUnreadTabBadgeHooks
%hook UITabBarItem
- (void)setBadgeValue:(NSString *)value {
    RUINLocalTabBadgeState *state = objc_getAssociatedObject(self, &StateKey);
    if (applyingItem == self || !NSThread.isMainThread || !state) { %orig(value); return; }
    UITabBarController *owner = state.owner;
    if (!owner || TalkItem(owner) != self) {
        objc_setAssociatedObject(self, &StateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(value);
        return;
    }
    BOOL changed = !SameValue(state.nativeValue, value);
    state.nativeValue = value;
    %orig(ProjectedValue(value, correction));
    if (changed) { rawChanges++; RUINRefreshLocalUnreadBadgeTotals(); }
}
%end

%hook UIViewController
- (void)setTabBarItem:(UITabBarItem *)item {
    %orig(item);
    UITabBarController *root = self.tabBarController;
    if ([root isKindOfClass:rootClass]) RefreshRoot(root);
}
%end

%hook RUINUnreadNativeRoot
- (void)setViewControllers:(NSArray *)controllers { %orig(controllers); RefreshRoot(self); }
- (void)setViewControllers:(NSArray *)controllers animated:(BOOL)animated { %orig(controllers, animated); RefreshRoot(self); }
- (void)setTabs:(NSArray *)tabs { %orig(tabs); RefreshRoot(self); }
- (void)setTabs:(NSArray *)tabs animated:(BOOL)animated { %orig(tabs, animated); RefreshRoot(self); }
- (void)viewDidLoad { %orig; RefreshRoot(self); }
- (void)viewDidAppear:(BOOL)animated { %orig(animated); RefreshRoot(self); }
%end
%end

// Discover already-built roots once at installation. Badge setters never scan
// windows, reflect Swift fields, or access a native unread model.
static void DiscoverRoots(UIViewController *controller, NSHashTable *seen) {
    if (!controller || [seen containsObject:controller]) return;
    [seen addObject:controller];
    if ([controller isKindOfClass:rootClass]) RefreshRoot((id)controller);
    for (UIViewController *child in controller.childViewControllers) DiscoverRoots(child, seen);
    DiscoverRoots(controller.presentedViewController, seen);
}

void RUINInstallLocalUnreadTabBadge(void) {
    if (!NSThread.isMainThread || installed || !RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary)) return;
    Class root = NSClassFromString(@"_TtC22LineSharedUIComponents20RootTabBarController");
    Class chat = NSClassFromString(@"_TtC13LineChatTabUI25ChatTabPageViewController");
    if (![root isSubclassOfClass:UITabBarController.class] || ![chat isSubclassOfClass:UIViewController.class] ||
        !ClassBelongs(root) || !ClassBelongs(chat)) return;
    const SEL selectors[] = {@selector(setViewControllers:), @selector(setViewControllers:animated:),
        @selector(setTabs:), @selector(setTabs:animated:), @selector(viewDidLoad), @selector(viewDidAppear:)};
    const char *types[] = {"v24@0:8@16", "v28@0:8@16B24", "v24@0:8@16", "v28@0:8@16B24", "v16@0:8", "v20@0:8B16"};
    Method badge = class_getInstanceMethod(UITabBarItem.class, @selector(setBadgeValue:));
    if (!badge || strcmp(method_getTypeEncoding(badge), "v24@0:8@16") || !method_getImplementation(badge)) return;
    Method item = class_getInstanceMethod(UIViewController.class, @selector(setTabBarItem:));
    if (!item || strcmp(method_getTypeEncoding(item), "v24@0:8@16") || !method_getImplementation(item)) return;
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        Method method = class_getInstanceMethod(root, selectors[i]);
        if (!method || strcmp(method_getTypeEncoding(method), types[i]) || !method_getImplementation(method)) return;
    }
    rootClass = root; chatClass = chat;
    roots = [NSHashTable weakObjectsHashTable];
    %init(RUINLocalUnreadTabBadgeHooks, RUINUnreadNativeRoot = root);
    installed = YES;
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) DiscoverRoots(window.rootViewController, seen);
    }
}

void RUINSetLocalUnreadTabBadgeCorrection(NSUInteger count) {
    if (!NSThread.isMainThread) return;
    correction = count;
    RUINInstallLocalUnreadTabBadge();
    for (UITabBarController *root in roots.allObjects) RefreshRoot(root);
}

NSDictionary *RUINLocalUnreadTabBadgeDiagnostics(void) {
    return @{@"installed":@(installed), @"correction":@(correction), @"bindings":@(bindings),
        @"rawChanges":@(rawChanges), @"displayWrites":@(correctionWrites)};
}
