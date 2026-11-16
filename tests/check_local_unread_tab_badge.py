#!/usr/bin/env python3
"""Exercise the production native tab badge hooks with Foundation UIKit doubles."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

SHIM = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "LocalUnreadTabBadge.h"
#include <assert.h>
#include <stdio.h>
#define BOOL _Bool
@interface UITabBarItem : NSObject
@property(nonatomic, copy) NSString *badgeValue;
@end
@implementation UITabBarItem @end
@class UITabBarController;
@interface UIViewController : NSObject
@property(nonatomic, strong) UITabBarItem *tabBarItem;
@property(nonatomic, weak) UITabBarController *tabBarController;
@property(nonatomic, copy) NSArray *childViewControllers;
@property(nonatomic, strong) UIViewController *presentedViewController;
- (void)viewDidLoad;
- (void)viewDidAppear:(BOOL)animated;
@end
@implementation UIViewController
- (instancetype)init {
    if ((self = [super init])) { _tabBarItem = [UITabBarItem new]; _childViewControllers = @[]; }
    return self;
}
- (void)viewDidLoad {}
- (void)viewDidAppear:(__unused BOOL)animated {}
@end
@interface UINavigationController : UIViewController
@property(nonatomic, copy) NSArray<UIViewController *> *viewControllers;
@end
@implementation UINavigationController @end
@interface UITabBarController : UIViewController
@property(nonatomic, copy) NSArray<UIViewController *> *viewControllers;
@property(nonatomic, copy) NSArray *tabs;
- (void)setViewControllers:(NSArray *)controllers animated:(BOOL)animated;
- (void)setTabs:(NSArray *)tabs animated:(BOOL)animated;
@end
@implementation UITabBarController
- (void)setViewControllers:(NSArray *)controllers {
    for (UIViewController *old in _viewControllers) old.tabBarController = nil;
    _viewControllers = [controllers copy];
    for (UIViewController *entry in controllers) entry.tabBarController = self;
    self.childViewControllers = controllers;
}
- (void)setViewControllers:(NSArray *)controllers animated:(__unused BOOL)animated { self.viewControllers = controllers; }
- (void)setTabs:(NSArray *)tabs animated:(__unused BOOL)animated { self.tabs = tabs; }
@end
@interface UIScene : NSObject @end
@implementation UIScene @end
@interface UIWindow : NSObject
@property(nonatomic, strong) UIViewController *rootViewController;
@end
@implementation UIWindow @end
@interface UIWindowScene : UIScene
@property(nonatomic, copy) NSArray<UIWindow *> *windows;
@end
@implementation UIWindowScene @end
@interface UIApplication : NSObject
@property(nonatomic, copy) NSSet *connectedScenes;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static UIApplication *app; if (!app) app = [self new]; return app; }
@end
static BOOL targetMatches = YES;
static BOOL RUINTargetMetadataMatchesInfo(__unused NSDictionary *info) { return targetMatches; }
static Class foreignClass;
static const char *FixtureClassImageName(Class cls) {
    return cls == foreignClass ? "/foreign/fixture.dylib" : NSBundle.mainBundle.executablePath.fileSystemRepresentation;
}
#define class_getImageName FixtureClassImageName
static NSUInteger totalsRefreshes, feedbackCorrection;
void RUINRefreshLocalUnreadBadgeTotals(void) {
    totalsRefreshes++;
    // Simulate the parent's correction callback, including a synchronous reset.
    RUINSetLocalUnreadTabBadgeCorrection(feedbackCorrection);
}
'''

CHECK = r'''
static Class AddClass(const char *name, Class parent) {
    Class cls = objc_allocateClassPair(parent, name, 0); assert(cls); objc_registerClassPair(cls); return cls;
}
static UINavigationController *Navigation(Class contentClass, NSString *badge) {
    UINavigationController *nav = [UINavigationController new];
    nav.viewControllers = @[[contentClass new]]; nav.tabBarItem.badgeValue = badge; return nav;
}
int main(void) { @autoreleasepool {
    RUINInstallLocalUnreadTabBadge(); assert(!installed); // Missing native classes remain retryable.
    Class rootType = AddClass("_TtC22LineSharedUIComponents20RootTabBarController", UITabBarController.class);
    Class chatType = AddClass("_TtC13LineChatTabUI25ChatTabPageViewController", UIViewController.class);
    for (Class cls in @[rootType, chatType]) {
        foreignClass = cls; RUINInstallLocalUnreadTabBadge(); assert(!installed);
    }
    foreignClass = Nil;
    UITabBarController *root = [rootType new];
    UINavigationController *home = Navigation(UIViewController.class, @"12");
    UINavigationController *chat = Navigation(chatType, @"12");
    UINavigationController *other = Navigation(UIViewController.class, @"12");
    root.viewControllers = @[other, home, chat]; // Talk is identified without a tab index or title.
    UIWindow *window = [UIWindow new]; window.rootViewController = root;
    UIWindowScene *scene = [UIWindowScene new]; scene.windows = @[window];
    UIApplication.sharedApplication.connectedScenes = [NSSet setWithObject:scene];
    targetMatches = NO; RUINInstallLocalUnreadTabBadge(); assert(!installed);
    targetMatches = YES; feedbackCorrection = 5;
    RUINSetLocalUnreadTabBadgeCorrection(5);
    assert(installed && totalsRefreshes == 1 && [chat.tabBarItem.badgeValue isEqual:@"7"]);
    assert([home.tabBarItem.badgeValue isEqual:@"12"] && [other.tabBarItem.badgeValue isEqual:@"12"]);
    RUINInstallLocalUnreadTabBadge(); assert(totalsRefreshes == 1);
    chat.tabBarItem.badgeValue = @"15";
    assert(totalsRefreshes == 2 && [chat.tabBarItem.badgeValue isEqual:@"10"]);
    chat.tabBarItem.badgeValue = @"15"; assert(totalsRefreshes == 2);
    RUINSetLocalUnreadTabBadgeCorrection(2);
    assert(totalsRefreshes == 2 && [chat.tabBarItem.badgeValue isEqual:@"13"]);
    RUINSetLocalUnreadTabBadgeCorrection(0);
    assert([chat.tabBarItem.badgeValue isEqual:@"15"] && totalsRefreshes == 2);

    feedbackCorrection = 2;
    for (NSString *value in @[@"99+", @"", @"•", @" 9", @"-1", @"١٢", @"18446744073709551616"]) {
        chat.tabBarItem.badgeValue = value; assert([chat.tabBarItem.badgeValue isEqual:value]);
    }
    chat.tabBarItem.badgeValue = @"0009"; assert([chat.tabBarItem.badgeValue isEqual:@"7"]);
    RUINSetLocalUnreadTabBadgeCorrection(0); assert([chat.tabBarItem.badgeValue isEqual:@"0009"]);
    chat.tabBarItem.badgeValue = @"1"; assert(!chat.tabBarItem.badgeValue);
    chat.tabBarItem.badgeValue = nil; RUINSetLocalUnreadTabBadgeCorrection(0); assert(!chat.tabBarItem.badgeValue);
    chat.tabBarItem.badgeValue = @"18446744073709551615";
    RUINSetLocalUnreadTabBadgeCorrection(1); assert([chat.tabBarItem.badgeValue isEqual:@"18446744073709551614"]);
    RUINSetLocalUnreadTabBadgeCorrection(NSUIntegerMax); assert(!chat.tabBarItem.badgeValue);
    RUINSetLocalUnreadTabBadgeCorrection(0); assert([chat.tabBarItem.badgeValue isEqual:@"18446744073709551615"]);

    // Rebuild/reorder restores the old item and binds the new native Talk item once.
    UITabBarItem *oldItem = chat.tabBarItem;
    NSUInteger before = totalsRefreshes;
    UINavigationController *replacement = Navigation(chatType, @"20");
    [root setViewControllers:@[replacement, home, other] animated:NO];
    assert(totalsRefreshes == before + 1 && [replacement.tabBarItem.badgeValue isEqual:@"18"]);
    assert([oldItem.badgeValue isEqual:@"18446744073709551615"]);
    oldItem.badgeValue = @"8"; assert([oldItem.badgeValue isEqual:@"8"] && totalsRefreshes == before + 1);
    UITabBarItem *replacedItem = replacement.tabBarItem;
    UITabBarItem *newItem = [UITabBarItem new]; newItem.badgeValue = @"30";
    replacement.tabBarItem = newItem;
    assert(totalsRefreshes == before + 2 && [newItem.badgeValue isEqual:@"28"]);
    assert([replacedItem.badgeValue isEqual:@"20"]);
    [root setTabs:@[] animated:NO]; [root viewDidAppear:NO];
    assert(totalsRefreshes == before + 2 && [newItem.badgeValue isEqual:@"28"]);
    [root setViewControllers:@[home, other] animated:NO]; assert([newItem.badgeValue isEqual:@"30"]);
    // Ambiguous structures and look-alike badges on other tabs never get projected.
    before = totalsRefreshes;
    root.viewControllers = @[chat, replacement];
    assert(totalsRefreshes == before && [newItem.badgeValue isEqual:@"30"]);
    assert([home.tabBarItem.badgeValue isEqual:@"12"] && [other.tabBarItem.badgeValue isEqual:@"12"]);
    root.viewControllers = @[replacement, home];
    assert(totalsRefreshes == before + 1 && [newItem.badgeValue isEqual:@"28"]);
    before = totalsRefreshes;
    for (unsigned i = 0; i < 20; i++) RUINSetLocalUnreadTabBadgeCorrection(2);
    assert(totalsRefreshes == before && [newItem.badgeValue isEqual:@"28"]);
    RUINSetLocalUnreadTabBadgeCorrection(0); assert([newItem.badgeValue isEqual:@"30"]);
    puts("PASS production Talk tab identity, raw/native restoration, numeric bounds, rebuilds and no totals feedback loops");
} return 0; }
'''


def main():
    source = (ROOT / "src/interface/LocalUnreadTabBadge.x").read_text()
    source = "\n".join(line for line in source.splitlines()
                       if not line.startswith("#import ") and not line.startswith("%config("))
    with tempfile.TemporaryDirectory(prefix="ruin-local-unread-tab-") as temporary:
        directory = Path(temporary)
        logos = directory / "check.x"
        logos.write_text("%config(generator=internal);\n" + SHIM + source + CHECK)
        generated = directory / "check.m"
        with generated.open("w") as output:
            subprocess.run(["/usr/bin/perl", str(ROOT / "vendor/logos/bin/logos.pl"), str(logos)],
                           stdout=output, check=True, timeout=20)
        executable = directory / "check"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11",
                        "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "src/interface"), str(generated),
                        "-framework", "Foundation", "-o", str(executable)], check=True, timeout=40)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(executable)],
                       check=True, capture_output=True, timeout=15)
        subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    main()
