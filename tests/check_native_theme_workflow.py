#!/usr/bin/env python3
"""Run production My Themes import scheduling across retries and reappearances."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/themes/NativeThemeWorkflow.m"

SHIM = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ThemeProductIdentity.h"
#include <assert.h>
#include <stdio.h>
@interface FixtureView : NSObject
@property(nonatomic, strong) id window;
@end
@implementation FixtureView @end
@interface FixtureNavigation : NSObject
@property(nonatomic, weak) id topViewController;
@end
@implementation FixtureNavigation @end
@interface UIViewController : NSObject
@property(nonatomic, strong) FixtureView *viewIfLoaded;
@property(nonatomic, strong) FixtureNavigation *navigationController;
@end
@implementation UIViewController @end
static BOOL available, rootAvailable;
static id scope;
static NSMutableArray *catalog;
static unsigned imports, refreshes, rootLookups;
static NSMutableArray<void (^)(void)> *pending;
static void Async(__unused dispatch_queue_t queue, void (^block)(void)) {
    [pending addObject:[block copy]];
}
static void After(__unused dispatch_time_t time, dispatch_queue_t queue, void (^block)(void)) {
    Async(queue, block);
}
static void Drain(void) {
    for (unsigned budget = 0; pending.count; budget++) {
        assert(budget < 40);
        NSArray *blocks = [pending copy]; [pending removeAllObjects];
        for (void (^block)(void) in blocks) block();
    }
}
static BOOL RUINNativeThemeRegistrationAvailable(void) { return available; }
static id RUINNativeThemeRegistrationScopeToken(void) { return scope; }
static void RUINNativeThemeRegistrationPackageURL(NSString *product,
    void (^completion)(NSURL *, NSError *)) {
    assert(product.length); rootLookups++;
    Async(nil, ^{ completion(rootAvailable ? [NSURL fileURLWithPath:@"/fixture/packages/product"] : nil,
        rootAvailable ? nil : [NSError errorWithDomain:@"fixture.scope" code:1 userInfo:nil]); });
}
static NSArray *RUINThemeCatalog(NSError **error) { *error = nil; return [catalog copy]; }
static NSDictionary *RUINReadThemeReceipts(NSURL *root) { assert(root); return @{}; }
static NSArray *RUINNativeSelectedThemeIDs(UIViewController *controller) { assert(controller); return @[]; }
static void RUINRefreshNativeMyThemes(UIViewController *controller, void (^completion)(NSError *)) {
    assert(controller); refreshes++; completion(nil);
}
static void RUINImportDownloadedTheme(NSDictionary *record, void (^completion)(NSDictionary *, NSError *)) {
    assert(record[@"packageURL"]); imports++; completion(@{@"committed":@YES}, nil);
}
#define dispatch_async Async
#define dispatch_after After
'''

CHECK = r'''
static NSDictionary *Record(unsigned index) {
    return @{@"packageURL":[NSURL fileURLWithPath:[NSString stringWithFormat:@"/fixture/%u.linetheme", index]],
        @"name":[NSString stringWithFormat:@"Theme %u", index],
        @"productID":[NSString stringWithFormat:@"00000000-0000-0000-0000-%012u", index],
        @"version":@1, @"downloadedLocally":@YES, @"archiveStructureValidated":@YES};
}
int main(void) { @autoreleasepool {
    pending = [NSMutableArray array]; catalog = [NSMutableArray arrayWithObject:Record(1)];
    gImportedArchives = [NSMutableSet set]; scope = NSObject.new; available = YES;
    UIViewController *controller = [UIViewController new];
    controller.viewIfLoaded = [FixtureView new]; controller.viewIfLoaded.window = NSObject.new;
    controller.navigationController = [FixtureNavigation new];
    controller.navigationController.topViewController = controller;
    RUINImportOnNativeAppearance(controller, 0); Drain();
    assert(!gImporting && !imports && [gLastImportError isEqual:@"native_theme_account_scope_unavailable"]);
    rootAvailable = YES;
    RUINImportOnNativeAppearance(controller, 0); Drain();
    assert(!gImporting && imports == 1 && refreshes == 1);
    RUINImportOnNativeAppearance(controller, 0); Drain();
    assert(imports == 1 && refreshes == 1); // The saved identity remains deduplicated.
    [catalog addObject:Record(2)];
    RUINImportOnNativeAppearance(controller, 0); Drain();
    assert(!gImporting && imports == 2 && refreshes == 2); // Same controller, newly saved file.
    scope = NSObject.new;
    RUINImportOnNativeAppearance(controller, 0); Drain();
    assert(imports == 4); // Each account/store scope imports independently.
    controller.viewIfLoaded.window = nil;
    unsigned lookups = rootLookups;
    RUINImportOnNativeAppearance(controller, 0); Drain();
    assert(rootLookups == lookups && imports == 4);
    controller.viewIfLoaded.window = NSObject.new;
    available = NO;
    RUINImportOnNativeAppearance(controller, 0); Drain();
    assert([gLastImportError isEqual:@"native_theme_context_unavailable"] && imports == 4);
    available = YES; [catalog addObject:Record(3)];
    RUINImportOnNativeAppearance(controller, 0); Drain();
    assert(!gImporting && imports == 5);
    puts("PASS production My Themes root/context retry, new archives, deduplication and account scope");
} return 0; }
'''


def main():
    source = SOURCE.read_text()
    globals_ = source[source.index("// Only the original LINE"):source.index("static NSArray *RUINNativeSelectedThemeIDs(")]
    body = source[source.index("static NSString *RUINArchiveIdentity("):source.index("void RUINInstallNativeThemeWorkflow(void)")]
    with tempfile.TemporaryDirectory(prefix="ruin-native-theme-workflow-") as temporary:
        fixture = Path(temporary) / "check.m"
        fixture.write_text(SHIM + globals_ + body + CHECK)
        executable = Path(temporary) / "check"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11",
            "-Wall", "-Wextra", "-Werror", "-Wno-incompatible-pointer-types", "-I", str(ROOT / "src/themes"),
            str(fixture), "-framework", "Foundation", "-o", str(executable)], check=True, timeout=30)
        subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    main()
