#!/usr/bin/env python3
"""Count production navigation/refresh work with live-object reuse regressions."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from check_interface_review import function_body

ROOT = Path(__file__).resolve().parents[1]
SHIM = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
@class UIWindow, UIViewController, UINavigationController;
static NSUInteger subviewReads, typeReads, caseReads, fieldReads, reports;
@interface UIView : NSObject {
    NSMutableArray *_children;
    __weak UIView *_parent;
    __weak UIWindow *_window;
    BOOL _hidden;
}
@property(nonatomic, readonly) NSArray *subviews;
@property(nonatomic, readonly) UIView *superview;
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic) BOOL hidden;
@property(nonatomic) NSUInteger hiddenWrites, invalidations, layouts;
@property(nonatomic, copy) NSString *kindType, *kindCase;
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
- (BOOL)isDescendantOfView:(UIView *)view;
- (BOOL)isHidden;
- (void)invalidateIntrinsicContentSize;
- (void)setNeedsLayout;
@end
@implementation UIView
- (instancetype)init { if ((self = [super init])) _children = [NSMutableArray array]; return self; }
- (NSArray *)subviews { subviewReads++; return [_children copy]; }
- (UIView *)superview { return _parent; }
- (UIWindow *)window { return _window ?: self.superview.window; }
- (void)setWindow:(UIWindow *)value { _window = value; }
- (BOOL)hidden { return _hidden; }
- (BOOL)isHidden { return _hidden; }
- (void)setHidden:(BOOL)value { _hidden = value; self.hiddenWrites++; }
- (void)addSubview:(UIView *)view { [view removeFromSuperview]; view->_parent = self; [_children addObject:view]; }
- (void)removeFromSuperview { if (_parent) [_parent->_children removeObject:self]; _parent = nil; }
- (BOOL)isDescendantOfView:(UIView *)view {
    for (UIView *cursor = self; cursor; cursor = cursor.superview) if (cursor == view) return YES;
    return NO;
}
- (void)invalidateIntrinsicContentSize { self.invalidations++; }
- (void)setNeedsLayout { self.layouts++; }
@end
@interface UILabel : UIView @end
@implementation UILabel @end
@interface UITableView : UIView @end
@implementation UITableView @end
@interface UIImage : NSObject
+ (instancetype)systemImageNamed:(NSString *)name;
@end
@implementation UIImage
+ (instancetype)systemImageNamed:(NSString *)name { assert(name.length); return [self new]; }
@end
enum { UIBarButtonItemStylePlain, UIUserInterfaceIdiomPhone, UIUserInterfaceIdiomPad };
@interface UIBarButtonItem : NSObject
@property(nonatomic, copy) NSString *accessibilityLabel;
- (instancetype)initWithImage:(UIImage *)image style:(NSInteger)style target:(id)target action:(SEL)action;
@end
@implementation UIBarButtonItem
- (instancetype)initWithImage:(UIImage *)image style:(NSInteger)style target:(id)target action:(SEL)action {
    assert(image && style == UIBarButtonItemStylePlain && target && action); return [super init];
}
@end
@interface UINavigationItem : NSObject
@property(nonatomic, copy) NSArray *rightBarButtonItems;
@end
@implementation UINavigationItem @end
@interface UIViewController : NSObject
@property(nonatomic, strong) UIView *view;
@property(nonatomic, readonly) UIView *viewIfLoaded;
@property(nonatomic, weak) UINavigationController *navigationController;
@property(nonatomic, strong) UINavigationItem *navigationItem;
@property(nonatomic, strong) UIViewController *presentedViewController;
@property(nonatomic, copy) NSArray *childViewControllers;
@end
@implementation UIViewController
- (instancetype)init { if ((self = [super init])) _navigationItem = [UINavigationItem new]; return self; }
- (UIView *)viewIfLoaded { return self.view; }
@end
@interface UINavigationController : UIViewController
@property(nonatomic, strong) UIViewController *topViewController;
@property(nonatomic) BOOL navigationBarHidden;
@end
@implementation UINavigationController @end
@interface UITabBarController : UIViewController
@property(nonatomic) NSUInteger applications;
@end
@implementation UITabBarController @end
@interface UIWindow : UIView
@property(nonatomic, strong) UIViewController *rootViewController;
@end
@implementation UIWindow @end
@interface UIScene : NSObject @end
@implementation UIScene @end
@interface UIWindowScene : UIScene
@property(nonatomic, copy) NSArray *windows;
@end
@implementation UIWindowScene @end
@protocol UIApplicationDelegate <NSObject>
@property(nonatomic, strong) UIWindow *window;
@end
@interface AppDelegate : NSObject <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation AppDelegate @end
@interface UIApplication : NSObject
+ (instancetype)sharedApplication;
@property(nonatomic, copy) NSSet *connectedScenes;
@property(nonatomic, strong) id<UIApplicationDelegate> delegate;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static UIApplication *app; if (!app) app = [self new]; return app; }
@end
@interface UIDevice : NSObject
+ (instancetype)currentDevice;
@property(nonatomic) NSInteger userInterfaceIdiom;
@end
@implementation UIDevice
+ (instancetype)currentDevice { static UIDevice *device; if (!device) device = [self new]; return device; }
@end
static NSMutableDictionary *preferences;
@interface FixtureDefaults : NSObject
+ (instancetype)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)key;
@end
@implementation FixtureDefaults
+ (instancetype)standardUserDefaults { return [self new]; }
- (BOOL)boolForKey:(NSString *)key { return [preferences[key] boolValue]; }
@end
#define NSUserDefaults FixtureDefaults
static NSString *RUINLocalizedString(NSString *key) { return key; }
static void RUINRefreshRuntimeReport(void) { reports++; }
static NSString * const RUINSecondaryLoginEnabledKey = @"secondary";
static char homeItemKey, settingsTableKey;
static BOOL homeEntryAvailable;
static atomic_uint_fast64_t settingsTableSearches, settingsTableReuse;

@interface _TtC17LineMessagingUIV228ChatNavigationBarContentView : UIView
@property(nonatomic, strong) UILabel *titleLabel;
@end
@implementation _TtC17LineMessagingUIV228ChatNavigationBarContentView @end
static id RUINCopySwiftField(id object, const char *path) {
    assert(!strcmp(path, "titleLabel")); fieldReads++;
    return [(_TtC17LineMessagingUIV228ChatNavigationBarContentView *)object titleLabel];
}
static NSString *RUINCopySwiftFieldTypeName(UIView *object, const char *path) {
    assert(!strcmp(path, "kind")); typeReads++; return object.kindType;
}
static NSString *RUINCopySwiftEnumCaseName(UIView *object, const char *path) {
    assert(!strcmp(path, "kind")); caseReads++; return object.kindCase;
}
@interface VoiceView : UIView @end
@implementation VoiceView @end
@interface UnverifiedVoiceView : UIView @end
@implementation UnverifiedVoiceView @end

typedef enum { RUINHideGroupAds, RUINHideGroupRecommendations, RUINHideGroupVoiceInput, RUINHideGroupAgentI } RUINHideGroup;
typedef struct { RUINHideGroup group; } RUINViewTarget;
static RUINViewTarget viewTarget;
static RUINViewTarget *RUINViewTargetForObject(__unused id object) { return &viewTarget; }
static char gOriginalHiddenStateKey;
static unsigned gInternalHiddenUpdateDepth;
static atomic_bool gHideAdsEnabled, gHideRecommendationsEnabled, gHideVoiceInputEnabled, gHideAgentIEnabled, gTargetMatches;
static atomic_uint_fast64_t gVisibleViewScans, gVisibleViewScanSkips, gVoiceTypeReflections, gVoiceKindRestorations;
static NSUInteger gViewHooksGeneration, walkedRoots, installAttempts;
static NSString * const RUINHideAdsDefaultsKey = @"ads";
static NSString * const RUINHideRecommendationsDefaultsKey = @"recommendations";
static NSString * const RUINHideVoiceInputDefaultsKey = @"voice";
static NSString * const RUINHideAgentIBarDefaultsKey = @"agent";
static BOOL targetMatches = YES, installNewHook;
static BOOL RUINTargetMatches(void) { return targetMatches; }
static void RUINMarkHooksVersionGated(void) {}
static void RUINInstallHooks(void) { installAttempts++; if (installNewHook) { gViewHooksGeneration++; installNewHook = NO; } }
static void RUINRefreshViewTree(__unused UIView *view) { walkedRoots++; }
static NSHashTable *gTrackedTabControllers;
static struct { const char *className; } gSetControllersHook = { "UITabBarController" };
static struct { _Atomic(IMP) original; atomic_uint_fast64_t calls; } gVoiceButtonLayoutHook;
static void RUINApplyRequestedControllers(UITabBarController *controller, __unused BOOL startup) { controller.applications++; }
'''
CHECK = r'''
static UIViewController *Controller(UIWindow *window, UIView *root) {
    root.window = window;
    UIViewController *controller = [UIViewController new]; controller.view = root;
    return controller;
}
static _TtC17LineMessagingUIV228ChatNavigationBarContentView *Content(UIView *root) {
    _TtC17LineMessagingUIV228ChatNavigationBarContentView *content = [_TtC17LineMessagingUIV228ChatNavigationBarContentView new];
    content.titleLabel = [UILabel new]; [content addSubview:content.titleLabel]; [root addSubview:content];
    return content;
}
int main(void) { @autoreleasepool {
    preferences = [NSMutableDictionary dictionary];
    UIWindow *window = [UIWindow new], *otherWindow = [UIWindow new];
    UIView *root = [UIView new];
    UIViewController *chat = Controller(window, root);
    UINavigationController *navigation = [UINavigationController new];
    navigation.topViewController = chat; chat.navigationController = navigation;
    UIView *wrapper = [UIView new]; [root addSubview:wrapper];
    _TtC17LineMessagingUIV228ChatNavigationBarContentView *content = Content(wrapper);
    assert(RUINCurrentVerifiedTitleLabel(chat) == content.titleLabel);
    subviewReads = 0;
    for (unsigned i = 0; i < 100; i++) assert(RUINCurrentVerifiedTitleLabel(chat) == content.titleLabel);
    assert(subviewReads == 0 && atomic_load(&gNavigationSearches) == 1 && atomic_load(&gNavigationReuse) == 100);
    assert(fieldReads == 101); // Live values never become a stale field cache.
    UILabel *oldLabel = content.titleLabel;
    content.titleLabel = [UILabel new]; [content addSubview:content.titleLabel];
    assert(oldLabel.window == window && RUINCurrentVerifiedTitleLabel(chat) == content.titleLabel);
    [content.titleLabel removeFromSuperview]; assert(!RUINCurrentVerifiedTitleLabel(chat));
    [content addSubview:content.titleLabel]; assert(RUINCurrentVerifiedTitleLabel(chat) == content.titleLabel);
    wrapper.hidden = YES; assert(!RUINCurrentVerifiedTitleLabel(chat));
    wrapper.hidden = NO; assert(RUINCurrentVerifiedTitleLabel(chat) == content.titleLabel);
    UIView *foreignRoot = [UIView new]; foreignRoot.window = window;
    [foreignRoot addSubview:content];
    _TtC17LineMessagingUIV228ChatNavigationBarContentView *replacement = Content(root);
    assert(content.window == window && RUINCurrentVerifiedTitleLabel(chat) == replacement.titleLabel);
    UIView *newRoot = [UIView new]; newRoot.window = window; chat.view = newRoot;
    replacement = Content(newRoot);
    assert(RUINCurrentVerifiedTitleLabel(chat) == replacement.titleLabel);
    uint_fast64_t searches = atomic_load(&gNavigationSearches);
    newRoot.window = otherWindow;
    assert(RUINCurrentVerifiedTitleLabel(chat) == replacement.titleLabel && atomic_load(&gNavigationSearches) == searches + 1);
    navigation.topViewController = [UIViewController new]; searches = atomic_load(&gNavigationSearches);
    RUINCurrentVerifiedTitleLabel(chat);
    assert(atomic_load(&gNavigationSearches) == searches + 1);
    navigation.topViewController = chat;
    UIViewController *lifetime = Controller(window, [UIView new]);
    __weak UIView *releasedContent;
    @autoreleasepool {
        _TtC17LineMessagingUIV228ChatNavigationBarContentView *temporary = Content(lifetime.view);
        releasedContent = temporary;
        assert(RUINCurrentVerifiedTitleLabel(lifetime) == temporary.titleLabel);
        [temporary removeFromSuperview];
    }
    assert(!releasedContent && !RUINCurrentVerifiedTitleLabel(lifetime));
    replacement = Content(lifetime.view);
    assert(RUINCurrentVerifiedTitleLabel(lifetime) == replacement.titleLabel);

    UITableView *table = [UITableView new]; UIView *settingsRoot = [UIView new]; [settingsRoot addSubview:table];
    UIViewController *settings = Controller(window, settingsRoot);
    assert(RUINCurrentSettingsTable(settings) == table);
    subviewReads = 0;
    for (unsigned i = 0; i < 100; i++) assert(RUINCurrentSettingsTable(settings) == table);
    assert(subviewReads == 0 && settingsTableSearches == 1 && settingsTableReuse == 100);
    [foreignRoot addSubview:table];
    UITableView *newTable = [UITableView new]; [settingsRoot addSubview:newTable];
    assert(RUINCurrentSettingsTable(settings) == newTable && settingsTableSearches == 2);
    settingsRoot.window = otherWindow;
    assert(RUINCurrentSettingsTable(settings) == newTable && settingsTableSearches == 3);
    UIView *newSettingsRoot = [UIView new]; newSettingsRoot.window = otherWindow;
    settings.view = newSettingsRoot;
    assert(!RUINCurrentSettingsTable(settings));
    [newSettingsRoot addSubview:newTable]; assert(RUINCurrentSettingsTable(settings) == newTable);

    UIDevice.currentDevice.userInterfaceIdiom = UIUserInterfaceIdiomPad;
    UIBarButtonItem *native = [UIBarButtonItem new]; chat.navigationItem.rightBarButtonItems = @[native];
    RUINAttachHomeSettingsButton(chat);
    assert(reports == 1 && chat.navigationItem.rightBarButtonItems.count == 2);
    for (unsigned i = 0; i < 100; i++) RUINAttachHomeSettingsButton(chat);
    assert(reports == 1 && chat.navigationItem.rightBarButtonItems.firstObject == native);
    chat.navigationItem.rightBarButtonItems = @[native]; RUINAttachHomeSettingsButton(chat);
    assert(reports == 2 && chat.navigationItem.rightBarButtonItems.count == 2);
    navigation.navigationBarHidden = YES;
    RUINAttachHomeSettingsButton(chat); assert(reports == 2);

    VoiceView *voice = [VoiceView new];
    voice.kindType = @"LineMessagingUIV2.ChatInputBarButtonKind"; voice.kindCase = @"audio";
    viewTarget.group = RUINHideGroupVoiceInput; atomic_store(&gHideVoiceInputEnabled, YES);
    for (unsigned i = 0; i < 100; i++) assert(RUINShouldHideView(&viewTarget, voice));
    assert(typeReads == 100 && caseReads == 100);
    voice.kindCase = @"send";
    assert(!RUINShouldHideView(&viewTarget, voice) && typeReads == 101 && caseReads == 101);
    voice.kindType = @"OtherKind"; voice.kindCase = @"audio";
    assert(!RUINShouldHideView(&viewTarget, voice) && typeReads == 102 && caseReads == 101);
    voice.kindType = @"LineMessagingUIV2.ChatInputBarButtonKind";
    UnverifiedVoiceView *unverified = [UnverifiedVoiceView new];
    unverified.kindType = @"OtherKind"; unverified.kindCase = @"audio";
    assert(!RUINShouldHideView(&viewTarget, unverified));
    assert(!RUINShouldHideView(&viewTarget, unverified) && typeReads == 104 && caseReads == 101);
    voice.kindCase = @"audio"; RUINVoiceButtonLayout(voice, @selector(description));
    assert(voice.hidden);
    voice.kindCase = @"send"; RUINVoiceButtonLayout(voice, @selector(description));
    assert(!voice.hidden && !objc_getAssociatedObject(voice, &gOriginalHiddenStateKey));

    UIView *agent = [UIView new]; viewTarget.group = RUINHideGroupAgentI;
    RUINHideView(agent);
    for (unsigned i = 0; i < 100; i++) RUINHideView(agent);
    assert(agent.hiddenWrites == 1 && agent.invalidations == 1);
    RUINRestoreView(agent);
    assert(!agent.hidden && agent.hiddenWrites == 2 && agent.invalidations == 2);
    agent.hidden = YES; agent.hiddenWrites = 0; agent.invalidations = 0;
    RUINHideView(agent); RUINRestoreView(agent);
    assert(agent.hidden && agent.hiddenWrites == 0 && agent.invalidations == 0);

    UITabBarController *tabs = [UITabBarController new], *detached = [UITabBarController new];
    UIViewController *owner = Controller(window, [UIView new]); owner.childViewControllers = @[tabs];
    window.rootViewController = owner;
    UIWindowScene *scene = [UIWindowScene new]; scene.windows = @[window];
    UIApplication.sharedApplication.connectedScenes = [NSSet setWithObject:scene];
    AppDelegate *delegate = [AppDelegate new]; delegate.window = window; UIApplication.sharedApplication.delegate = delegate;
    RUINRegisterTabController(detached);
    for (unsigned i = 0; i < 100; i++) RUINPerformInstallOrRefresh();
    assert(tabs.applications == 100 && detached.applications == 100);
    assert(atomic_load(&gVisibleViewScans) == 1 && walkedRoots == 1 && atomic_load(&gVisibleViewScanSkips) == 99);
    preferences[@"unrelatedSetting"] = @YES; RUINPerformInstallOrRefresh();
    assert(atomic_load(&gVisibleViewScans) == 1);
    preferences[RUINHideAdsDefaultsKey] = @YES; RUINPerformInstallOrRefresh();
    assert(atomic_load(&gVisibleViewScans) == 2 && atomic_load(&gHideAdsEnabled));
    preferences[RUINHideAdsDefaultsKey] = @NO; RUINPerformInstallOrRefresh();
    assert(atomic_load(&gVisibleViewScans) == 3 && !atomic_load(&gHideAdsEnabled));
    installNewHook = YES; RUINPerformInstallOrRefresh();
    assert(atomic_load(&gVisibleViewScans) == 4);
    NSUInteger attempts = installAttempts; targetMatches = NO; RUINPerformInstallOrRefresh();
    assert(installAttempts == attempts && !atomic_load(&gTargetMatches));
    targetMatches = YES; RUINPerformInstallOrRefresh(); assert(atomic_load(&gVisibleViewScans) == 5);
    puts("PASS production hotpaths: 100 warm UI reads without tree scans; fresh title/voice values; stale UI rejected; reports only on change; one tab application; preference/hook-driven scans");
} return 0; }
'''


def function(source, signature):
    return signature + "\n" + function_body(source, signature) + "\n"


def main():
    chat = (ROOT / "src/interface/NativeChatControls.x").read_text()
    entry = (ROOT / "src/interface/NativeEntry.x").read_text()
    interface = (ROOT / "src/interface/InterfaceFeatures.x").read_text()
    navigation_record = chat[chat.index("@interface RUINNativeNavigationRecord"):
        chat.index("@interface RUINNativeTitleAliasRecord")]
    table_record = entry[entry.index("@interface RUINSettingsTableRecord"):
        entry.index("@interface RUINSettingsFooterView")]
    functions = navigation_record + table_record
    for source, signatures in (
        (chat, ("static UIView *RUINFindCustomNavigationContent(UIView *view, NSUInteger depth)",
                "static UIView *RUINCurrentNavigationContent(UIViewController *controller)",
                "static UILabel *RUINCurrentVerifiedTitleLabel(UIViewController *controller)")),
        (entry, ("static UITableView *RUINFindSettingsTable(UIView *view)",
                 "static UITableView *RUINCurrentSettingsTable(UIViewController *controller)",
                 "static NSString *RUINSettingsEntryAccessibilityLabel(void)",
                 "static void RUINAttachHomeSettingsButton(UIViewController *controller)")),
        (interface, ("static BOOL RUINIsHideGroupEnabled(RUINHideGroup group)",
                     "static BOOL RUINShouldHideView(RUINViewTarget *target, id view)",
                     "static void RUINHideView(UIView *view)", "static void RUINRestoreView(UIView *view)",
                     "static void RUINVoiceButtonLayout(id self, SEL selector)",
                     "static void RUINRefreshVisibleViews(void)",
                     "static void RUINRegisterTabController(UITabBarController *controller)",
                     "static void RUINRefreshTrackedTabControllers(NSHashTable *refreshed)",
                     "static void RUINDiscoverTabControllers(UIViewController *controller, NSHashTable *visited)",
                     "static NSHashTable *RUINDiscoverExistingTabs(void)",
                     "static NSUInteger RUINLoadPreferences(void)", "static void RUINPerformInstallOrRefresh(void)")),
    ):
        for signature in signatures:
            functions += function(source, signature)
    assert "RUINCurrentSettingsTable(controller)" in function_body(entry, "static void RUINAttachSettingsEntry(UIViewController *controller)")
    assert "RUINCurrentNavigationContent(controller)" in function_body(chat, "static void RUINAttachReadExceptionButton(UIViewController *controller)")
    with tempfile.TemporaryDirectory(prefix="ruin-interface-hotpath-") as directory:
        fixture = Path(directory) / "check.m"
        fixture.write_text(SHIM + functions + CHECK)
        executable = Path(directory) / "check"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11",
            "-Wall", "-Wextra", "-Werror", str(fixture), "-framework", "Foundation", "-o", str(executable)],
            check=True, cwd=ROOT, timeout=30)
        subprocess.run([str(executable)], check=True, cwd=ROOT, timeout=10)


if __name__ == "__main__":
    main()
