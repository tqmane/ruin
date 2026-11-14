#!/usr/bin/env python3
"""Focused host checks for startup-tab retry and interface review safeguards."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def function_body(source, signature):
    start = source.index(signature)
    while True:
        opening = source.index("{", start)
        semicolon = source.find(";", start)
        if semicolon < 0 or opening < semicolon:
            break
        start = source.index(signature, start + len(signature))
    depth = 0
    for end in range(opening, len(source)):
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
            if depth == 0:
                return source[opening:end + 1]
    raise AssertionError(f"unterminated function: {signature}")


def check_startup_selection(source):
    signature = "static void RUINApplyStartupSelection(UITabBarController *controller, NSArray *controllers)"
    production = function_body(source, signature).replace(
        "NSUserDefaults.standardUserDefaults", "fixtureDefaults")
    harness = r'''#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#include <assert.h>
static char gStartupSelectionAppliedKey;
static atomic_int gStartupStatus = ATOMIC_VAR_INIT(0);
static NSString * const RUINStartupTabFixedDefaultsKey = @"fixed";
static NSString * const RUINStartupTabDefaultsKey = @"tab";
typedef NS_ENUM(NSInteger, RUINTabKind) { RUINTabUnknown, RUINTabHome, RUINTabTalk };
@interface UIViewController : NSObject
@property(nonatomic) RUINTabKind kind;
@end
@implementation UIViewController @end
@interface UITabBarController : NSObject
@property(nonatomic, copy) NSArray *viewControllers;
@property(nonatomic, strong) UIViewController *selectedViewController;
@property(nonatomic, copy) dispatch_block_t selectionCallback;
@property(nonatomic) NSUInteger selectionAttempts;
@property(nonatomic) BOOL rejectSelection;
@end
@implementation UITabBarController
@synthesize selectedViewController = _selectedViewController;
- (void)setSelectedViewController:(UIViewController *)value {
    self.selectionAttempts++;
    if (!self.rejectSelection) _selectedViewController = value;
    if (self.selectionCallback) self.selectionCallback();
}
@end
static NSUserDefaults *fixtureDefaults;
static RUINTabKind RUINKindForIdentifier(NSString *identifier) {
    return [identifier isEqualToString:@"talk"] ? RUINTabTalk : RUINTabUnknown;
}
static RUINTabKind RUINKindForTabController(UIViewController *controller) { return controller.kind; }
'''
    main = r'''
int main(void) { @autoreleasepool {
    NSString *suite = [@"ruin-startup-" stringByAppendingString:NSUUID.UUID.UUIDString];
    fixtureDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [fixtureDefaults setBool:YES forKey:RUINStartupTabFixedDefaultsKey];
    [fixtureDefaults setObject:@"talk" forKey:RUINStartupTabDefaultsKey];
    UIViewController *home = [UIViewController new]; home.kind = RUINTabHome;
    UIViewController *talk = [UIViewController new]; talk.kind = RUINTabTalk;
    UITabBarController *reentrant = [UITabBarController new]; reentrant.viewControllers = @[home, talk];
    __weak UITabBarController *weakReentrant = reentrant;
    reentrant.selectionCallback = ^{ RUINApplyStartupSelection(weakReentrant, @[home, talk]); };
    RUINApplyStartupSelection(reentrant, @[home, talk]);
    assert(reentrant.selectedViewController == talk && reentrant.selectionAttempts == 1);
    reentrant.selectionCallback = nil;
    UITabBarController *refusing = [UITabBarController new]; refusing.viewControllers = @[home, talk];
    refusing.rejectSelection = YES;
    RUINApplyStartupSelection(refusing, @[home, talk]);
    assert(![objc_getAssociatedObject(refusing, &gStartupSelectionAppliedKey) boolValue]);
    refusing.rejectSelection = NO;
    RUINApplyStartupSelection(refusing, @[home, talk]);
    assert(refusing.selectedViewController == talk && refusing.selectionAttempts == 2);
    UITabBarController *tabs = [UITabBarController new];

    // A requested controller outside the native array is never selected.
    tabs.viewControllers = @[home];
    RUINApplyStartupSelection(tabs, @[talk]);
    assert(tabs.selectedViewController == nil && atomic_load(&gStartupStatus) == 4);
    assert(![objc_getAssociatedObject(tabs, &gStartupSelectionAppliedKey) boolValue]);

    // Hidden from the allowed list, the native target remains unselected and retryable.
    tabs.viewControllers = @[home, talk];
    RUINApplyStartupSelection(tabs, @[home]);
    assert(tabs.selectedViewController == nil && atomic_load(&gStartupStatus) == 4);
    assert(![objc_getAssociatedObject(tabs, &gStartupSelectionAppliedKey) boolValue]);

    RUINApplyStartupSelection(tabs, @[home, talk]);
    assert(tabs.selectedViewController == talk && atomic_load(&gStartupStatus) == 2);
    tabs.selectedViewController = home; // User navigated after startup selection.
    RUINApplyStartupSelection(tabs, @[home, talk]);
    assert(tabs.selectedViewController == home);
    [fixtureDefaults removePersistentDomainForName:suite];
    puts("PASS startup selection retries safely, respects hidden/native membership, and stays applied after user navigation");
} return 0; }
'''
    with tempfile.TemporaryDirectory(prefix="ruin-interface-review-") as directory:
        source_path = Path(directory) / "check.m"
        executable = Path(directory) / "check"
        source_path.write_text(harness + signature + production + main)
        subprocess.run([
            "xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks",
            "-Wall", "-Wextra", "-Werror", str(source_path), "-framework", "Foundation",
            "-o", str(executable),
        ], check=True, cwd=ROOT)
        subprocess.run([str(executable)], check=True, cwd=ROOT)


def check_source_guards():
    interface = (ROOT / "src/interface/InterfaceFeatures.x").read_text()
    hidden_settings = function_body(interface, "static BOOL RUINShouldHideTab(RUINTabKind kind)")
    assert 'entry[@"homeEntryAvailable"]' in hidden_settings
    assert "homeHookInstalled" not in hidden_settings
    apply_tabs = function_body(interface, "static void RUINApplyRequestedControllers(UITabBarController *controller, BOOL allowStartup)")
    assert "NSArray *startupSelectable = nativeGeneration ? RUINFilteredControllers(native) : allowed;" in apply_tabs
    assert "RUINApplyStartupSelection(controller, native)" not in apply_tabs
    assert "RUINApplyStartupSelection(controller, allowed)" not in apply_tabs
    assert "RUINApplyStartupSelection(controller, startupSelectable)" in apply_tabs
    for signature in (
        "static void RUINSetViewControllers(id self, SEL selector, NSArray *controllers)",
        "static void RUINSetViewControllersAnimated(id self, SEL selector, NSArray *controllers, BOOL animated)",
    ):
        assert "RUINApplyRequestedControllers(tabs, YES)" in function_body(interface, signature)

    picker = (ROOT / "src/interface/ChatPicker.m").read_text()
    assert "[self.failedImages removeAllObjects]" in function_body(picker, "- (void)loadChats")
    avatar = function_body(picker, "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index")
    assert "PickerAvatarRequestKey(account, url)" in avatar
    assert "[RUINChatCatalogAccount() isEqualToString:account]" in avatar
    assert avatar.index("PickerFinishAvatarRequest(owner.pendingImages") < avatar.index("if (!accountIsCurrent || !image) return;")
    assert avatar.index("if (!accountIsCurrent || !image) return;") < avatar.index("[owner.tableView reloadData]")

    chat = (ROOT / "src/interface/NativeChatControls.x").read_text()
    apply_alias = function_body(chat, "static void RUINApplyNativeTitleAliasRecord(")
    assert "RUINCurrentVerifiedTitleLabel" not in apply_alias
    refresh_alias = function_body(chat, "static void RUINRefreshNativeTitleAlias(UIViewController *controller, BOOL force)")
    assert "if (!force && !record.appliedAlias) return;" in refresh_alias
    assert "record.chatObject == chat" in refresh_alias
    assert "RUINApplyNativeTitleAliasRecord(controller, label, record, savedAliases)" in refresh_alias
    print("PASS settings entry uses availability proof; alias layout reuses verified label and skips inactive work")


if __name__ == "__main__":
    interface = (ROOT / "src/interface/InterfaceFeatures.x").read_text()
    check_startup_selection(interface)
    check_source_guards()
