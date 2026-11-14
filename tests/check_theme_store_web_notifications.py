#!/usr/bin/env python3
"""Exercise the extracted ThemeStoreWeb observer with main deliberately blocked."""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
TIMEOUT = 5
SHIM = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); exit(1); } } while (0)
// Only UI state and hook installation are substituted; notification delivery,
// threading, dispatch_once and dispatch_async are the real host implementations.
@interface UIViewController : NSObject @end
@implementation UIViewController @end
@interface RUINThemeStoreWebState : NSObject
@property(nonatomic, strong) id webView;
@property(nonatomic) BOOL scriptInstalled;
@end
@implementation RUINThemeStoreWebState @end

static NSHashTable<UIViewController *> *gRUINThemeStoreWebControllers;
static id gRUINThemeStoreWebDefaultsObserver;
static atomic_int gRUINThemeStoreWebHookStatus;
enum { RUINThemeStoreWebHookVersionGated = 5 };
static UIViewController *controller;
static RUINThemeStoreWebState *state;
static atomic_bool posterReturned;
static unsigned refreshes, installs;

static BOOL RUINThemeStoreWebTargetMatches(void) { return YES; }
static void RUINThemeStoreWebInstallHook(void) { installs++; }
static RUINThemeStoreWebState *RUINThemeStoreWebGetState(UIViewController *value, BOOL create) {
    CHECK(NSThread.isMainThread && value == controller && !create);
    return state;
}
static void RUINThemeStoreWebApplyPreference(RUINThemeStoreWebState *value) {
    CHECK(NSThread.isMainThread && value == state);
    CHECK(atomic_load(&posterReturned));
    refreshes++;
}
'''
FIXTURE = r'''
int main(void) { @autoreleasepool {
    CHECK(NSThread.isMainThread);
    controller = [UIViewController new];
    state = [RUINThemeStoreWebState new];
    state.webView = [NSObject new];
    state.scriptInstalled = YES;
    gRUINThemeStoreWebControllers = [NSHashTable weakObjectsHashTable];
    [gRUINThemeStoreWebControllers addObject:controller];
    RUINInstallThemeStoreWeb();
    CHECK(installs == 1 && gRUINThemeStoreWebDefaultsObserver != nil);

    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    // A separate suite mirrors the native UTS defaults object; no values are written.
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"ruin-theme-store-web-host"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        CHECK(!NSThread.isMainThread);
        puts("POSTING"); fflush(stdout);
        [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:defaults];
        atomic_store(&posterReturned, true);
        puts("POST_RETURNED"); fflush(stdout);
        dispatch_semaphore_signal(finished);
    }});

    // No main-queue/run-loop cooperation until posting has returned. The parent
    // process timeout bounds a regression's intentional deadlock here.
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    CHECK(atomic_load(&posterReturned) && refreshes == 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        CHECK(NSThread.isMainThread && refreshes == 1);
        CFRunLoopStop(CFRunLoopGetMain());
    });
    CFRunLoopRun();
    CHECK(refreshes == 1);
    [NSNotificationCenter.defaultCenter removeObserver:gRUINThemeStoreWebDefaultsObserver];
    puts("PASS poster returned without main; refresh ran asynchronously on main");
} return 0; }
'''


def production_functions():
    source = (ROOT / "src/themes/ThemeStoreWeb.x").read_text()
    start = "static void RUINThemeStoreWebRefreshTrackedControllers(void)\n{"
    end = "NSDictionary<NSString *, id> *RUINThemeStoreWebDiagnostics(void)"
    assert source.count(start) == source.count(end) == 1
    # Keep both production functions, including the actual registration/block.
    return source[source.index(start):source.index(end, source.index(start))]


def main():
    production = production_functions()
    with tempfile.TemporaryDirectory(prefix="ruin-theme-store-web-notifications-") as temporary:
        directory = Path(temporary)

        def compile_case(name, functions):
            fixture = directory / f"{name}.m"
            executable = directory / name
            fixture.write_text(SHIM + functions + FIXTURE)
            subprocess.run([
                "xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11",
                "-Wall", "-Wextra", "-Werror", str(fixture),
                "-framework", "Foundation", "-o", str(executable),
            ], cwd=ROOT, check=True, timeout=30)
            return executable

        executable = compile_case("production", production)
        subprocess.run([str(executable)], cwd=ROOT, check=True, timeout=TIMEOUT)

        # Restore only the historical blocking registration in a temporary copy.
        registration = "object:nil queue:nil"
        assert production.count(registration) == 1
        regression = compile_case("old-main-queue", production.replace(
            registration, "object:nil queue:NSOperationQueue.mainQueue", 1))
        try:
            result = subprocess.run([str(regression)], cwd=ROOT, capture_output=True,
                                    text=True, timeout=TIMEOUT)
        except subprocess.TimeoutExpired as error:
            output = error.stdout or b""
            assert b"POSTING\n" in output and b"POST_RETURNED\n" not in output, output
            print("PASS negative control: old main-queue observer blocks poster until process timeout", flush=True)
        else:
            raise AssertionError(f"old registration did not deadlock: {result}")


if __name__ == "__main__":
    main()
