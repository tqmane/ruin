#!/usr/bin/env python3
"""Host-only archive scheduling regression; compile production code, no UIKit/DB QA."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PREAMBLE = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", \
    __func__, __LINE__, #c); exit(1); } } while (0)
@class NSManagedObject;
@interface UICollectionViewCell : NSObject
@property(nonatomic, strong) id window;
@end
@implementation UICollectionViewCell @end
static char UIRecordKey;
static dispatch_queue_t UIArchiveQueue;
static NSUInteger UIArchivePending, assignments, refreshes;
static atomic_uint_fast64_t UIErrors, queries, queued;
static dispatch_semaphore_t entered, releaseQuery;
static BOOL enabled = YES, throwQuery;
static NSTimeInterval now = 100;
@interface MarkerClock : NSObject
+ (instancetype)processInfo;
- (NSTimeInterval)systemUptime;
@end
@implementation MarkerClock
+ (instancetype)processInfo { static MarkerClock *clock; if (!clock) clock = [self new]; return clock; }
- (NSTimeInterval)systemUptime { return now; }
@end
static BOOL UIEnabled(void) { return enabled; }
static void UIRefreshCell(UICollectionViewCell *cell) {
    CHECK(NSThread.isMainThread && cell.window); refreshes++;
}
static void CountDispatch(dispatch_queue_t queue, dispatch_block_t block) {
    if (queue != dispatch_get_main_queue()) atomic_fetch_add(&queued, 1);
    dispatch_async(queue, block);
}
static void Wait(dispatch_semaphore_t semaphore) {
    CHECK(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
}
static NSArray *RUINRetainedMediaItems(NSDictionary *key) {
    CHECK(!NSThread.isMainThread && [key isEqual:@{@"message": @"old"}]);
    atomic_fetch_add(&queries, 1); dispatch_semaphore_signal(entered);
    Wait(releaseQuery);
    if (throwQuery) @throw [NSException exceptionWithName:@"archive" reason:nil userInfo:nil];
    return @[@"retained"];
}
'''

INSTRUMENT = r'''
// Observe actual cache writes, including an accidental background assignment.
@interface ArchiveRecord : RUINUnsendMarkerRecord @end
@implementation ArchiveRecord
- (void)setMediaItems:(NSArray *)items {
    CHECK(NSThread.isMainThread); assignments++; [super setMediaItems:items];
}
@end
#define NSProcessInfo MarkerClock
#define dispatch_async CountDispatch
'''

FIXTURE = r'''
#undef dispatch_async
#undef NSProcessInfo
static ArchiveRecord *Record(UICollectionViewCell *cell) {
    ArchiveRecord *record = [ArchiveRecord new]; record.key = @{@"message": @"old"};
    objc_setAssociatedObject(cell, &UIRecordKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return record;
}
static UICollectionViewCell *Cell(void) {
    UICollectionViewCell *cell = [UICollectionViewCell new]; cell.window = @YES; return cell;
}
static void Start(UICollectionViewCell *cell, ArchiveRecord *record) {
    CHECK(UIArchivePending == 0);
    entered = dispatch_semaphore_create(0); releaseQuery = dispatch_semaphore_create(0);
    uint64_t before = atomic_load(&queries);
    UIRequestArchiveItems(cell, record);
    CHECK(UIArchivePending == 1 && record.archiveLookupPending);
    Wait(entered); CHECK(atomic_load(&queries) == before + 1);
}
static void Finish(void) {
    dispatch_semaphore_signal(releaseQuery);
    // Queue fence proves the completion has been submitted before main is drained.
    dispatch_semaphore_t fence = dispatch_semaphore_create(0);
    dispatch_async(UIArchiveQueue, ^{ dispatch_semaphore_signal(fence); }); Wait(fence);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    do {
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    } while (UIArchivePending && deadline.timeIntervalSinceNow > 0);
    CHECK(UIArchivePending == 0);
}
static void NoIO(void) {
    UICollectionViewCell *cell = Cell(); ArchiveRecord *record = Record(cell);
    uint64_t before = atomic_load(&queued), calls = atomic_load(&queries);
    cell.window = nil; UIRequestArchiveItems(cell, record);
    CHECK(UIArchivePending == 0 && !record.archiveLookupPending && record.lastArchiveLookup == 0);
    cell.window = @YES;
    for (NSUInteger budget = 128; budget <= 129; budget++) {
        UIArchivePending = budget; UIRequestArchiveItems(cell, record);
        CHECK(UIArchivePending == budget && !record.archiveLookupPending && record.lastArchiveLookup == 0);
    }
    UIArchivePending = 0;
    CHECK(atomic_load(&queued) == before && atomic_load(&queries) == calls);
}
static void Success(void) {
    UICollectionViewCell *cell = Cell(); ArchiveRecord *record = Record(cell);
    NSUInteger writes = assignments, paints = refreshes;
    Start(cell, record); uint64_t before = atomic_load(&queued);
    for (int i = 0; i < 20; i++) UIRequestArchiveItems(cell, record);
    CHECK(atomic_load(&queued) == before && UIArchivePending == 1);
    CHECK(record.mediaItems == nil && assignments == writes && refreshes == paints);
    now = 101; Finish();
    CHECK([record.mediaItems isEqualToArray:@[@"retained"]] && assignments == writes + 1);
    CHECK(!record.archiveLookupPending && record.lastArchiveLookup == now && refreshes == paints + 1);
    UIRequestArchiveItems(cell, record); CHECK(atomic_load(&queued) == before);
    now += 2; Start(cell, record); Finish();
    CHECK(assignments == writes + 2 && refreshes == paints + 1); // Unchanged cache skips repaint.
    puts("PASS off-main query, main cache write, coalescing, cooldown, unchanged cache");
}
static void Stale(void) {
    for (int kind = 0; kind < 4; kind++) { @autoreleasepool {
        UICollectionViewCell *cell = Cell(); ArchiveRecord *record = Record(cell);
        record.mediaItems = @[@"keep"]; Start(cell, record);
        if (kind == 0) record.generation++;
        if (kind == 1) record.key = @{@"message": @"different"};
        if (kind == 2) {
            UISealReuse(record, nil); record.key = @{@"message": @"old"};
            record.mediaItems = @[@"new binding"];
        }
        if (kind == 3) objc_setAssociatedObject(cell, &UIRecordKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSArray *cache = record.mediaItems; BOOL pending = record.archiveLookupPending;
        NSTimeInterval timestamp = record.lastArchiveLookup;
        NSUInteger writes = assignments, paints = refreshes;
        now += 2; Finish();
        CHECK(assignments == writes && refreshes == paints && record.mediaItems == cache);
        CHECK(record.archiveLookupPending == pending && record.lastArchiveLookup == timestamp);
    } }
    puts("PASS stale generation/key, production reuse seal, missing record; pending released");
}
static void Deallocated(void) {
    __weak UICollectionViewCell *weakCell; ArchiveRecord *record;
    @autoreleasepool {
        UICollectionViewCell *cell = Cell(); weakCell = cell; record = Record(cell);
        Start(cell, record); cell = nil;
    }
    CHECK(weakCell == nil);
    NSUInteger writes = assignments, paints = refreshes; Finish();
    CHECK(assignments == writes && refreshes == paints && record.mediaItems == nil);
    puts("PASS deallocated cell not retained; pending released");
}
static void CompletionGuardsAndError(void) {
    for (int kind = 0; kind < 3; kind++) {
        UICollectionViewCell *cell = Cell(); ArchiveRecord *record = Record(cell);
        NSUInteger writes = assignments, paints = refreshes;
        uint64_t errors = atomic_load(&UIErrors);
        throwQuery = kind == 2; Start(cell, record);
        if (kind == 0) enabled = NO;
        if (kind == 1) cell.window = nil;
        Finish();
        CHECK(assignments == writes + 1 && !record.archiveLookupPending && record.lastArchiveLookup == now);
        CHECK(record.mediaItems.count == (kind == 2 ? 0 : 1));
        CHECK(refreshes == paints + (kind == 2 ? 1 : 0));
        CHECK(atomic_load(&UIErrors) == errors + (kind == 2 ? 1 : 0));
        enabled = YES; throwQuery = NO;
        if (kind == 2) { now += 2; Start(cell, record); Finish(); CHECK(record.mediaItems.count == 1); }
    }
    puts("PASS OFF/detached completion skips refresh; throwing query cleans up and retries");
}
int main(void) { @autoreleasepool {
    CHECK(NSThread.isMainThread); NoIO(); CHECK(UIArchiveQueue == nil);
    Success(); NoIO(); puts("PASS no-window / budget >=128 queues no I/O");
    Stale(); Deallocated(); CompletionGuardsAndError();
} return 0; }
'''


def extract(source, start, end):
    assert source.count(start) == source.count(end) == 1, (start, end)
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


def main():
    source = (ROOT / 'src/messaging/UnsendMarkerUI.x').read_text()
    record = extract(source, '@interface RUINUnsendMarkerRecord :', 'static BOOL UIMayBind(')
    request = extract(source, 'static void UIRequestArchiveItems(', 'static void UIRefreshCellImpl(')
    with tempfile.TemporaryDirectory(prefix='ruin-marker-archive-') as directory:
        fixture = Path(directory) / 'MarkerArchive.m'
        executable = Path(directory) / 'MarkerArchive'
        fixture.write_text(PREAMBLE + record + INSTRUMENT + request + FIXTURE)
        subprocess.run([
            'xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks', '-std=gnu11',
            '-Wall', '-Wextra', '-Werror', str(fixture), '-framework', 'Foundation',
            '-o', str(executable),
        ], cwd=ROOT, check=True, timeout=30)
        subprocess.run([str(executable)], cwd=ROOT, check=True, timeout=20)


if __name__ == '__main__':
    main()
