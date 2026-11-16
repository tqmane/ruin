#!/usr/bin/env python3
"""Run the production unread aggregate scheduler against deterministic queues."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

SHIM = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdio.h>
static BOOL onMain = YES, onPrivate, enabled = YES;
static NSMutableArray *mainJobs, *privateJobs, *published, *snapshots;
static NSUInteger privateSubmissions;
@interface FixtureThread : NSObject
+ (BOOL)isMainThread;
@end
@implementation FixtureThread
+ (BOOL)isMainThread { return onMain; }
@end
@interface FixtureStore : NSObject @end
@implementation FixtureStore @end
@interface FixtureContext : NSObject
@property(nonatomic) NSUInteger resets;
- (void)performBlock:(dispatch_block_t)work;
- (void)performBlockAndWait:(dispatch_block_t)work;
- (void)reset;
@end
@implementation FixtureContext
- (void)performBlock:(dispatch_block_t)work {
    assert(onMain && !onPrivate);
    privateSubmissions++;
    [privateJobs addObject:[work copy]];
    assert(privateJobs.count == 1); // Never accumulate another aggregate job.
}
- (void)performBlockAndWait:(__unused dispatch_block_t)work { assert(!"synchronous context wait"); }
- (void)reset { assert(onPrivate && !onMain); self.resets++; }
@end
static id MainQueue(void) { return mainJobs; }
static dispatch_time_t Time(dispatch_time_t when, int64_t delta) {
    assert(when == DISPATCH_TIME_NOW && delta == 50 * NSEC_PER_MSEC); return 1;
}
static void Async(id queue, dispatch_block_t work) {
    assert(queue == mainJobs); [mainJobs addObject:[work copy]];
}
static void After(dispatch_time_t when, id queue, dispatch_block_t work) {
    assert(onMain && when == 1); Async(queue, work);
}
static void __attribute__((unused)) Sync(__unused id queue, __unused dispatch_block_t work) {
    assert(!"synchronous dispatch wait");
}
static void Run(NSMutableArray *queue, BOOL main) {
    assert(queue.count);
    dispatch_block_t work = queue.firstObject;
    [queue removeObjectAtIndex:0];
    onMain = main; onPrivate = !main;
    work();
    onMain = YES; onPrivate = NO;
}
#define NSThread FixtureThread
#define NSManagedObjectContext FixtureContext
#define NSPersistentStore FixtureStore
#define dispatch_get_main_queue MainQueue
#define dispatch_time Time
#define dispatch_async Async
#define dispatch_after After
#define dispatch_sync Sync
static NSManagedObjectContext *totalsContext;
static NSPersistentStore *totalsStore;
static NSString *totalsAccount, *activeAccount;
static NSMutableDictionary *viewedBoundaries;
static NSUInteger totalsGeneration;
static BOOL totalsScheduled;
static BOOL Enabled(void) { assert(onMain); return enabled; }
static NSString *RUINChatCatalogAccount(void) { assert(onMain); return activeAccount; }
static void RUINSetLocalUnreadTabBadgeCorrection(NSUInteger value) {
    assert(onMain && !onPrivate); [published addObject:@(value)];
}
static NSUInteger BadgeCorrection(NSManagedObjectContext *context, NSPersistentStore *store,
                                  NSString *account, NSDictionary *boundaries) {
    assert(onPrivate && !onMain && context.resets && store && account);
    [snapshots addObject:@{@"context":context, @"store":store, @"account":account, @"boundaries":boundaries}];
    return [boundaries[@"count"] unsignedIntegerValue];
}
'''

CHECK = r'''
static void Reset(void) {
    assert(!mainJobs.count && !privateJobs.count && onMain && !onPrivate);
    mainJobs = [NSMutableArray array]; privateJobs = [NSMutableArray array];
    published = [NSMutableArray array]; snapshots = [NSMutableArray array];
    totalsContext = [NSManagedObjectContext new]; totalsStore = [NSPersistentStore new];
    totalsAccount = activeAccount = @"account-A";
    viewedBoundaries = [@{@"count":@1} mutableCopy];
    totalsGeneration = privateSubmissions = 0; totalsScheduled = NO; enabled = YES;
}
static void Begin(void) {
    RUINRefreshLocalUnreadBadgeTotals();
    assert(totalsScheduled && mainJobs.count == 1 && !privateJobs.count);
    Run(mainJobs, YES);
    assert(totalsScheduled && privateJobs.count == 1 && !mainJobs.count && !published.count);
}
static void Complete(void) {
    Run(privateJobs, NO);
    assert(totalsScheduled && mainJobs.count == 1);
    Run(mainJobs, YES);
}
int main(void) { @autoreleasepool {
    Reset(); Begin();
    // Fifty notifications while the private job is pending, fifty while its
    // completion waits on main. None may create an additional private job.
    for (unsigned i = 0; i < 50; i++) {
        viewedBoundaries[@"count"] = @(i + 2);
        RUINRefreshLocalUnreadBadgeTotals();
        assert(totalsScheduled && privateSubmissions == 1 && privateJobs.count == 1 && !mainJobs.count);
    }
    Run(privateJobs, NO);
    assert([snapshots[0][@"boundaries"][@"count"] isEqual:@1]); // Immutable in-flight snapshot.
    for (unsigned i = 0; i < 50; i++) {
        viewedBoundaries[@"count"] = @(i + 52);
        RUINRefreshLocalUnreadBadgeTotals();
        assert(totalsScheduled && privateSubmissions == 1 && !privateJobs.count && mainJobs.count == 1);
    }
    Run(mainJobs, YES); // Reject old generation; enqueue just one latest timer.
    assert(totalsScheduled && !published.count && mainJobs.count == 1 && !privateJobs.count);
    Run(mainJobs, YES);
    assert(privateSubmissions == 2 && privateJobs.count == 1 && totalsScheduled);
    Complete();
    assert(!totalsScheduled && !mainJobs.count && !privateJobs.count);
    assert(snapshots.count == 2 && published.count == 1 && [published[0] isEqual:@101]);

    // A burst before the timer executes also uses only the latest snapshot.
    Reset(); RUINRefreshLocalUnreadBadgeTotals();
    for (unsigned i = 0; i < 100; i++) {
        viewedBoundaries[@"count"] = @(i + 10); RUINRefreshLocalUnreadBadgeTotals();
        assert(mainJobs.count == 1 && !privateJobs.count);
    }
    Run(mainJobs, YES); Complete();
    assert(privateSubmissions == 1 && published.count == 1 && [published[0] isEqual:@109]);

    // Independently test each completion guard, even without a generation bump.
    for (unsigned change = 0; change < 4; change++) {
        Reset(); Begin();
        if (change == 0) enabled = NO;
        if (change == 1) activeAccount = @"account-B";
        if (change == 2) totalsStore = [NSPersistentStore new];
        if (change == 3) totalsContext = [NSManagedObjectContext new];
        Complete();
        assert(!published.count && !totalsScheduled && !mainJobs.count && !privateJobs.count);
        enabled = YES; totalsAccount = activeAccount;
        viewedBoundaries[@"count"] = @42;
        Begin(); Complete(); assert(published.count == 1 && [published[0] isEqual:@42]);
    }

    // Real source rebinding invalidates old work and coalesces onto the new source.
    Reset(); Begin();
    NSManagedObjectContext *oldContext = totalsContext;
    NSPersistentStore *oldStore = totalsStore;
    totalsContext = [NSManagedObjectContext new]; totalsStore = [NSPersistentStore new];
    totalsAccount = activeAccount = @"account-B"; viewedBoundaries[@"count"] = @77;
    RUINRefreshLocalUnreadBadgeTotals();
    assert(privateSubmissions == 1 && privateJobs.count == 1);
    Complete(); assert(!published.count && mainJobs.count == 1 && totalsScheduled);
    assert(snapshots[0][@"context"] == oldContext && snapshots[0][@"store"] == oldStore);
    assert([snapshots[0][@"account"] isEqual:@"account-A"]);
    Run(mainJobs, YES); Complete();
    assert(privateSubmissions == 2 && [published.lastObject isEqual:@77]);
    assert(snapshots[1][@"context"] == totalsContext && snapshots[1][@"store"] == totalsStore);
    assert([snapshots[1][@"account"] isEqual:@"account-B"]);

    // OFF or an account mismatch during a job immediately restores native state
    // and must not let completion publish the obsolete nonzero correction.
    for (unsigned change = 0; change < 2; change++) {
        Reset(); Begin();
        if (change == 0) enabled = NO; else activeAccount = @"account-B";
        RUINRefreshLocalUnreadBadgeTotals(); assert([published.lastObject isEqual:@0]);
        Complete();
        for (NSNumber *value in published) assert(value.unsignedIntegerValue == 0);
        assert(!totalsScheduled && !mainJobs.count && !privateJobs.count && privateSubmissions == 1);
    }

    // Delayed early aborts release the scheduling latch and permit later work.
    for (unsigned change = 0; change < 4; change++) {
        Reset(); RUINRefreshLocalUnreadBadgeTotals();
        if (change == 0) enabled = NO;
        if (change == 1) activeAccount = @"account-B";
        if (change == 2) totalsContext = nil;
        if (change == 3) totalsStore = nil;
        Run(mainJobs, YES);
        assert(!totalsScheduled && !privateJobs.count && !privateSubmissions && !published.count);
        enabled = YES; totalsAccount = activeAccount;
        if (!totalsContext) totalsContext = [NSManagedObjectContext new];
        if (!totalsStore) totalsStore = [NSPersistentStore new];
        Begin(); Complete(); assert([published.lastObject isEqual:@1]);
    }

    // Off-main callers only enqueue main work; neither queue is synchronously waited on.
    Reset(); onMain = NO;
    RUINRefreshLocalUnreadBadgeTotals();
    assert(!totalsScheduled && !totalsGeneration && !privateSubmissions && mainJobs.count == 1);
    onMain = YES; Run(mainJobs, YES); assert(totalsScheduled && mainJobs.count == 1);
    Run(mainJobs, YES); Complete();
    assert([published.lastObject isEqual:@1] && !mainJobs.count && !privateJobs.count);
    puts("PASS production unread scheduler: 100-event coalescing, latest rerun, stale OFF/account/store/context rejection and async-only queues");
} return 0; }
'''


def main():
    source = (ROOT / "src/interface/LocalUnreadBadges.x").read_text()
    start = "void RUINRefreshLocalUnreadBadgeTotals(void) {"
    end = "\nstatic void BindTotalsSource("
    assert source.count(start) == source.count(end) == 1
    scheduler = source[source.index(start):source.index(end, source.index(start))]
    for forbidden in ("performBlockAndWait", "dispatch_sync", "dispatch_semaphore_wait", "dispatch_group_wait"):
        assert forbidden not in scheduler, f"Scheduler must not synchronously wait: {forbidden}"
    with tempfile.TemporaryDirectory(prefix="ruin-unread-scheduler-") as folder:
        directory = Path(folder)
        fixture = directory / "check.m"
        fixture.write_text(SHIM + scheduler + CHECK)
        executable = directory / "check"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11",
                        "-Wall", "-Wextra", "-Werror", str(fixture), "-framework", "Foundation", "-o", str(executable)],
                       check=True, timeout=40)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(executable)],
                       check=True, capture_output=True, timeout=15)
        subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    main()
