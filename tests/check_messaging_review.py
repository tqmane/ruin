#!/usr/bin/env python3
"""Focused production scheduling, remote-loader policy, and reader-date regressions."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MENU = (ROOT / "src/messaging/MenuExtras.x").read_text()
SHEET = (ROOT / "src/messaging/ReadersSheet.m").read_text()

INSPECTION = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
static atomic_bool sMenuInspectionAttempted;
static NSMutableArray<dispatch_block_t> *pending;
static NSString *root;
static BOOL menuOpen;
static NSUInteger polls, scans;
static BOOL RUINMenuExtrasTargetMatches(void) { return YES; }
static NSDictionary *RUINMenuExtrasVisibleMenuSnapshot(void) {
    polls++; return @{@"menuOpenObserved":@(menuOpen)};
}
static NSDictionary *RUINMenuExtrasRuntimeMenuSignatures(void) {
    scans++; return @{@"visibleMenuSnapshot":@{@"menuOpenObserved":@(menuOpen)}};
}
static NSArray *FixtureDirectories(NSSearchPathDirectory directory, NSSearchPathDomainMask domain, BOOL expand) {
    assert(directory == NSCachesDirectory && domain == NSUserDomainMask && expand); return @[root];
}
static void FixtureEnqueue(dispatch_queue_t queue, dispatch_block_t block) { (void)queue; [pending addObject:[block copy]]; }
static void FixtureEnqueueAfter(dispatch_time_t time, dispatch_queue_t queue, dispatch_block_t block) {
    (void)time; FixtureEnqueue(queue,block);
}
#define NSSearchPathForDirectoriesInDomains FixtureDirectories
#define dispatch_async FixtureEnqueue
#define dispatch_after FixtureEnqueueAfter
'''

INSPECTION_CHECK = r'''
int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 3); NSString *mode = @(argv[1]); root = @(argv[2]); pending = [NSMutableArray array];
    unsetenv("RUIN_ENABLE_RUNTIME_INSPECTOR");
    if (![mode isEqual:@"unset"]) setenv("RUIN_ENABLE_RUNTIME_INSPECTOR",
        [mode isEqual:@"zero"] ? "0" : ([mode isEqual:@"word"] ? "YES" : "1"),1);
    menuOpen = ![mode isEqual:@"closed"];
    for (unsigned i=0;i<100;i++) RUINMenuExtrasScheduleInspection();
    if ([mode isEqual:@"revoke"]) unsetenv("RUIN_ENABLE_RUNTIME_INSPECTOR");
    unsigned drained = 0;
    while (pending.count) {
        assert(++drained < 20);
        dispatch_block_t next = pending.firstObject; [pending removeObjectAtIndex:0]; next();
    }
    BOOL enabled = [mode isEqual:@"open"] || [mode isEqual:@"closed"];
    assert(polls == (enabled ? (menuOpen ? 1u : 12u) : 0u));
    assert(scans == (enabled && menuOpen ? 1u : 0u));
    NSString *path = [root stringByAppendingPathComponent:@"RUIN/menu-inspection.json"];
    assert([NSFileManager.defaultManager fileExistsAtPath:path] == (scans == 1));
    for (unsigned i=0;i<100;i++) RUINMenuExtrasScheduleInspection();
    assert(!pending.count); // Closed menus and failed/disabled captures do not reopen the session budget.
    unsetenv("RUIN_ENABLE_RUNTIME_INSPECTOR");
    assert(!RUINMenuExtrasWriteMenuInspection());
    printf("PASS menu inspection %s\n",argv[1]);
} return 0; }
'''

LOADERS = r'''
#import <Foundation/Foundation.h>
#import "ReadRangeFetch.h"
#import "ReadersSheet.h"
#import "MessageHistory.h"
#import "NativeReadRangeSync.h"
#include <assert.h>
static NSDictionary *approvedKey, *httpContext;
static id approvedChat;
static BOOL identityValid = YES;
static unsigned validations, contextReads, remoteCalls, historyWrites;
static NSError *remoteError;
static NSArray *localReaders;
BOOL RUINHistoryValidateReadChatKey(NSDictionary *key, id chat) {
    validations++; return identityValid && chat == approvedChat && [key isEqual:approvedKey];
}
NSDictionary *RUINCopyNativeReadRangeHTTPContext(void) { contextReads++; return httpContext; }
void RUINHistoryRecordServerReadRanges(NSDictionary *key, NSDictionary *readers, void (^completion)(BOOL)) {
    (void)key; (void)readers; historyWrites++; completion(NO);
}
void RUINRequestRuntimeSnapshot(void) {}
NSArray *RUINReadUsersForMessageKey(NSDictionary *key) { assert([key isEqual:approvedKey]); return localReaders; }
static void FixtureFetch(NSDictionary *key, id chat, void (^completion)(NSError *)) {
    assert([key isEqual:approvedKey] && chat == approvedChat); remoteCalls++; completion(remoteError);
}
#define RUINFetchReadRanges FixtureFetch
'''

LOADERS_CHECK = r'''
#undef RUINFetchReadRanges
static void DrainUntil(BOOL *done) {
    for (unsigned i=0; !*done && i<100; i++)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(*done);
}
int main(void) { @autoreleasepool {
    approvedKey = @{@"store":@"PrimaryP_fixture",@"kind":@"talk",
        @"chat":@"c0123456789abcdef0123456789abcdef",@"message":@"123"};
    approvedChat = [NSObject new];
    localReaders = @[@{@"readerID":@"fixture",@"readAtMilliseconds":@1700000000000LL,
        @"observedAtMilliseconds":@1700000010000LL,@"timeSource":@"server_event"}];
    SheetLifecycleChecks();
    NSArray *originalRows = [localReaders copy];
    httpContext = @{@"captured":@YES}; // The real provider enforces headers/active-account capture.
    for (NSString *chat in @[@"u0123456789abcdef0123456789abcdef",@"r0123456789abcdef0123456789abcdef",
                             @"c0123456789abcdef0123456789abcdeF",@"cshort"]) {
        NSMutableDictionary *key = [approvedKey mutableCopy]; key[@"chat"] = chat;
        assert(!RUINMenuExtrasReadRangeLoader(key,approvedChat));
    }
    NSMutableDictionary *square = [approvedKey mutableCopy]; square[@"kind"] = @"square";
    assert(!RUINMenuExtrasReadRangeLoader(square,approvedChat));
    assert(!validations && !contextReads && !remoteCalls);
    httpContext = nil;
    assert(!RUINMenuExtrasReadRangeLoader(approvedKey,approvedChat));
    httpContext = @{@"captured":@YES};
    identityValid = NO; unsigned oldReads = contextReads;
    assert(!RUINMenuExtrasReadRangeLoader(approvedKey,approvedChat) && contextReads == oldReads);
    identityValid = YES;
    assert(!RUINMenuExtrasReadRangeLoader(approvedKey,nil));
    NSDictionary *diagnostics = RUINReadRangeFetchDiagnostics();
    assert(![diagnostics[@"requests"] unsignedIntegerValue] && ![diagnostics[@"failures"] unsignedIntegerValue]);
    NSMutableDictionary *selectedKey = [approvedKey mutableCopy];
    RUINReaderLoader loader = RUINMenuExtrasReadRangeLoader(selectedKey,approvedChat);
    assert(loader); selectedKey[@"message"] = @"999"; // The loader binds a copied selection.
    __block BOOL completed = NO;
    loader(^(NSArray *readers, NSError *error) { assert(readers == localReaders && !error); completed = YES; });
    assert(completed && remoteCalls == 1);
    httpContext = nil; completed = NO;
    loader(^(NSArray *readers, NSError *error) { assert(readers == localReaders && !error); completed = YES; });
    assert(completed && remoteCalls == 1); // Context lost during native menu dismissal: local-only, no false error.
    httpContext = @{@"captured":@YES}; identityValid = NO; completed = NO;
    loader(^(NSArray *readers, NSError *error) { assert(readers == localReaders && !error); completed = YES; });
    assert(completed && remoteCalls == 1);
    identityValid = YES;
    remoteError = [NSError errorWithDomain:@"fixture-HTTP" code:401 userInfo:nil];
    loader(^(NSArray *readers, NSError *error) { assert(!readers.count && error == remoteError); });
    assert(remoteCalls == 2 && [localReaders isEqual:originalRows]);
    // The actual fetch entry retains its fail-closed identity/context checks.
    identityValid = NO; completed = NO;
    RUINFetchReadRanges(approvedKey,approvedChat,^(NSError *error) { assert(error.code == 2); completed = YES; });
    DrainUntil(&completed);
    identityValid = YES; httpContext = nil; completed = NO;
    RUINFetchReadRanges(approvedKey,approvedChat,^(NSError *error) { assert(error.code == 3); completed = YES; });
    DrainUntil(&completed);
    assert(!historyWrites && [localReaders isEqual:originalRows]);
    assert(![RUINReadRangeFetchDiagnostics()[@"requests"] unsignedIntegerValue]);
    puts("PASS supported-group/captured-context loader policy, copied scope, identity rejection, local provenance, real error propagation");
} return 0; }
'''

SHEET_UI = r'''
@class UITableView;
#define RUINLocalizedString(key) (key)
@interface FixtureSheetSurface : NSObject
@property(nonatomic) BOOL enabled, isBeingDismissed;
@property(nonatomic, strong) id window;
@property(nonatomic, strong) FixtureSheetSurface *leftBarButtonItem;
- (void)reloadData;
@end
@implementation FixtureSheetSurface
- (void)reloadData {}
@end
@interface FixtureSheetParent : NSObject
- (void)viewDidAppear:(BOOL)animated;
@end
@implementation FixtureSheetParent
- (void)viewDidAppear:(BOOL)animated { (void)animated; }
@end
@interface RUINReadersSheetController : FixtureSheetParent
@property(nonatomic, copy) RUINReaderLoader loader;
@property(nonatomic) BOOL loading, loadFailed, started, isBeingDismissed;
@property(nonatomic, strong) NSArray *readers;
@property(nonatomic, strong) FixtureSheetSurface *viewIfLoaded, *navigationController, *navigationItem, *tableView;
- (void)refreshReaders;
- (void)applyReaders:(NSArray *)readers;
@end
@implementation RUINReadersSheetController
- (void)applyReaders:(NSArray *)readers { self.readers = readers; }
'''

SHEET_UI_CHECK = r'''
@end
static void SheetLifecycleChecks(void) {
    RUINReadersSheetController *sheet = [RUINReadersSheetController new];
    sheet.readers = localReaders;
    sheet.viewIfLoaded = [FixtureSheetSurface new]; sheet.viewIfLoaded.window = [NSObject new];
    sheet.navigationItem = [FixtureSheetSurface new]; sheet.navigationItem.leftBarButtonItem = [FixtureSheetSurface new];
    sheet.tableView = [FixtureSheetSurface new];
    [sheet viewDidAppear:NO];
    assert(sheet.started && !sheet.loading && !sheet.loadFailed && sheet.readers == localReaders);
    assert(![sheet tableView:nil titleForHeaderInSection:0]);
    // Real attempted fetch errors retain local rows and continue to show an error.
    sheet.loader = ^(RUINReaderLoadCompletion completion) {
        completion(@[],[NSError errorWithDomain:@"fixture-HTTP" code:401 userInfo:nil]);
    };
    [sheet refreshReaders];
    for (unsigned i=0;sheet.loading && i<100;i++)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(!sheet.loading && sheet.loadFailed && sheet.readers == localReaders);
    assert([sheet tableView:nil titleForHeaderInSection:0].length);
    sheet.loader = ^(RUINReaderLoadCompletion completion) { completion(localReaders,nil); };
    [sheet refreshReaders];
    for (unsigned i=0;sheet.loading && i<100;i++)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    assert(!sheet.loading && !sheet.loadFailed && sheet.readers == localReaders);
    assert(![sheet tableView:nil titleForHeaderInSection:0]);
    puts("PASS production reader-sheet lifecycle: local-only has no error header; real errors retain rows; refresh recovers");
}
'''


def compile_check(directory, name, source, extra=(), flags=()):
    path = directory / f"{name}.m"
    path.write_text(source)
    output = directory / name
    includes = [part for folder in sorted((ROOT / "src").iterdir()) if folder.is_dir()
                for part in ("-I",str(folder))]
    subprocess.run(["xcrun","--sdk","macosx","clang","-fobjc-arc","-fblocks","-std=gnu11",
        "-Wall","-Wextra","-Werror",*includes,*flags,str(path),*map(str,extra),
        "-framework","Foundation","-framework","CoreData","-o",str(output)],check=True)
    return output


def main():
    with tempfile.TemporaryDirectory(prefix="ruin-messaging-review-") as temporary:
        directory = Path(temporary)
        optin = MENU[MENU.index("static BOOL RUINMenuExtrasInspectionEnabled(void)"):
                     MENU.index("NSDictionary *RUINMenuExtrasRuntimeMenuSignatures(void)")]
        scheduling = MENU[MENU.index("static BOOL RUINMenuExtrasWriteMenuInspection(void)"):
                          MENU.index("%group RUINMenuLongPress")]
        executable = compile_check(directory,"inspection",INSPECTION+optin+scheduling+INSPECTION_CHECK)
        for mode in ("unset","zero","word","open","closed","revoke"):
            subprocess.run([str(executable),mode,str(directory / mode)],check=True,timeout=10)
        loader = MENU[MENU.index("static RUINReaderLoader RUINMenuExtrasReadRangeLoader("):
                      MENU.index("static void RUINMenuExtrasPresentReaders(")]
        lifecycle = SHEET[SHEET.index("- (void)viewDidAppear:(BOOL)animated"):
                          SHEET.index("- (void)applyReaders:(NSArray<NSDictionary *> *)readers {")]
        executable = compile_check(directory,"loaders",LOADERS+loader+SHEET_UI+lifecycle+SHEET_UI_CHECK+LOADERS_CHECK,
            [ROOT / "src/messaging/ReadRangeFetch.m",ROOT / "src/messaging/ReadRangeCodec.m"])
        subprocess.run([str(executable)],check=True,timeout=10)
        executable = compile_check(directory,"dates",SHEET,
            flags=["-DRUIN_READERS_SHEET_HOST_CHECK=1","-DRUIN_HOST_CHECK=1"])
        subprocess.run([str(executable)],check=True,timeout=10)
        # Syntax-check only the owned translation units against real UIKit/SDK,
        # including complete Logos hook bodies, without a full build or link.
        generated = directory / "MenuExtras.m"
        result = subprocess.run(["perl",str(ROOT / "vendor/logos/bin/logos.pl"),"-c","warnings=error",
            str(ROOT / "src/messaging/MenuExtras.x")],check=True,capture_output=True,text=True)
        generated.write_text(result.stdout)
        sdk = subprocess.check_output(["xcrun","--sdk","iphoneos","--show-sdk-path"],text=True).strip()
        includes = [part for folder in sorted((ROOT / "src").iterdir()) if folder.is_dir()
                    for part in ("-I",str(folder))]
        for path in (generated,ROOT / "src/messaging/ReadersSheet.m",ROOT / "src/messaging/ReadRangeFetch.m"):
            subprocess.run(["xcrun","--sdk","iphoneos","clang","-arch","arm64","-isysroot",sdk,
                "-miphoneos-version-min=18.0","-fobjc-arc","-fblocks","-std=gnu11","-Wall","-Wextra",
                "-Werror","-fsyntax-only",*includes,str(path)],check=True)
        print("PASS owned messaging iOS SDK syntax checks")


if __name__ == "__main__":
    main()
