#!/usr/bin/env python3
"""Compile extracted production marker callbacks against small Foundation stand-ins.

UIRefreshCell is a counted dependency boundary, not a UIKit/rendering test.
The negative control restores the old callback-to-full-scan edge in memory.
"""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/check-marker-hotpath'
PREAMBLE = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #condition); exit(1); \
} } while (0)

@interface NSManagedObject : NSObject @end
@interface UICollectionViewCell : NSObject
@property(nonatomic, strong) id window;
@property(nonatomic, strong) id model;
@property(nonatomic) BOOL hidden, badge;
@property(nonatomic) double alpha;
@property(nonatomic) NSUInteger refreshes;
@end
@implementation UICollectionViewCell @end

enum { UIApplicationStateActive, UIApplicationStateBackground };
@interface UIApplication : NSObject
@property(nonatomic) NSInteger applicationState;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication {
    static UIApplication *app;
    if (!app) app = [UIApplication new];
    return app;
}
@end

static NSUInteger originals, refreshes, scans, tracking, newRecords;
static NSUInteger fields, metadata, database, removals;
static BOOL throwRefresh, throwField;
// Count collection access even if a regression bypasses production counters.
@interface MarkerCells : NSObject
@property(nonatomic, strong) NSMutableArray<UICollectionViewCell *> *cells;
- (NSArray<UICollectionViewCell *> *)allObjects;
- (void)addObject:(UICollectionViewCell *)cell;
@end
@implementation MarkerCells
- (instancetype)init {
    if ((self = [super init])) _cells = [NSMutableArray array];
    return self;
}
- (NSArray *)allObjects { scans++; return self.cells.copy; }
- (void)addObject:(UICollectionViewCell *)cell {
    tracking++;
    if (![self.cells containsObject:cell]) [self.cells addObject:cell];
}
@end

static char UIRecordKey;
static MarkerCells *UICells;
static NSTimer *UITimer;
static atomic_bool UIOptionEnabled;
static atomic_uint_fast64_t UILayoutCalls, UIReuseCalls, UIErrors;
static atomic_uint_fast64_t UICellRefreshes, UITrackedPasses, UITrackedVisits, UIDisabledCallbacks;
static atomic_uint UIVisibleCount;
static _Thread_local unsigned int UIHookDepth;
static void CountSetAssociation(id object, const void *key, id value, objc_AssociationPolicy policy) {
    newRecords++;
    objc_setAssociatedObject(object, key, value, policy);
}
'''

DEPENDENCIES = r'''
static id UIField(UICollectionViewCell *cell, const char *path) {
    fields++;
    CHECK(strcmp(path, "messageViewModel") == 0);
    if (throwField) @throw [NSException exceptionWithName:@"field" reason:nil userInfo:nil];
    return cell.model;
}
static void UIRemoveBadge(UICollectionViewCell *cell) { removals++; cell.badge = NO; }
static void UIRefreshCell(UICollectionViewCell *cell) {
    refreshes++; cell.refreshes++; atomic_fetch_add(&UICellRefreshes, 1);
    if (throwRefresh) @throw [NSException exceptionWithName:@"refresh" reason:nil userInfo:nil];
    [UICells addObject:cell];
    UIRecord(cell);
    UIField(cell, "messageViewModel");
    // Sentinels for downstream metadata/reflection and DB dependency work.
    metadata++; database++;
}
'''

FIXTURE = r'''
static void Reset(void) {
    UIStopHeartbeat();
    CHECK(UIHookDepth == 0);
    UICells = [MarkerCells new];
    UIApplication.sharedApplication.applicationState = UIApplicationStateActive;
    atomic_store(&UIOptionEnabled, YES);
    atomic_store(&UILayoutCalls, 0); atomic_store(&UIReuseCalls, 0);
    atomic_store(&UIErrors, 0); atomic_store(&UICellRefreshes, 0);
    atomic_store(&UITrackedPasses, 0); atomic_store(&UITrackedVisits, 0);
    atomic_store(&UIDisabledCallbacks, 0); atomic_store(&UIVisibleCount, 0);
    originals = refreshes = scans = tracking = newRecords = 0;
    fields = metadata = database = removals = 0;
    throwRefresh = throwField = NO;
}
static UICollectionViewCell *Cell(void) {
    UICollectionViewCell *cell = [UICollectionViewCell new];
    cell.window = [NSObject new]; cell.model = [NSObject new]; cell.alpha = 1;
    return cell;
}
static void LayoutHotpath(void) {
    Reset();
    NSMutableArray<UICollectionViewCell *> *cells = [NSMutableArray array];
    for (NSUInteger i = 0; i < 20; i++) { [cells addObject:Cell()]; [UICells addObject:cells.lastObject]; }
    tracking = 0;
    for (NSUInteger i = 0; i < 100; i++) {
        UICollectionViewCell *current = cells[i % cells.count];
        NSUInteger before = current.refreshes;
        UINativeCallback(current, 0, ^{ originals++; });
        CHECK(scans == 0 && atomic_load(&UITrackedPasses) == 0);
        CHECK(current.refreshes == before + 1);
    }
    CHECK(originals == 100 && refreshes == 100 && tracking == 100);
    CHECK(atomic_load(&UILayoutCalls) == 100 && atomic_load(&UICellRefreshes) == 100);
    CHECK(atomic_load(&UITrackedVisits) == 0 && newRecords == 20);
    for (UICollectionViewCell *cell in cells) CHECK(cell.refreshes == 5);
    CHECK(UITimer != nil && UIHookDepth == 0);
    UIStopHeartbeat();
    puts("PASS 100 layouts / 20 tracked: originals=100 current-cell refreshes=100 full scans=0");
}
static void DisabledHotpath(void) {
    Reset(); atomic_store(&UIOptionEnabled, NO);
    for (NSUInteger index = 0; index < 3; index++) {
        UICollectionViewCell *cell = Cell();
        UINativeCallback(cell, index, ^{ originals++; });
        CHECK(objc_getAssociatedObject(cell, &UIRecordKey) == nil);
    }
    CHECK(originals == 3 && atomic_load(&UIDisabledCallbacks) == 3);
    CHECK(refreshes == 0 && scans == 0 && tracking == 0 && newRecords == 0);
    CHECK(fields == 0 && metadata == 0 && database == 0 && UITimer == nil);
    // OFF may clean an existing binding, but cannot discover/create another.
    UICollectionViewCell *cell = Cell();
    RUINUnsendMarkerRecord *record = UIRecord(cell);
    record.key = @{@"message":@"1"}; record.bindingPending = YES; cell.badge = YES;
    NSUInteger generation = record.generation, allocations = newRecords;
    UINativeCallback(cell, 0, ^{ originals++; });
    CHECK(originals == 4 && !cell.badge && !record.key && !record.bindingPending);
    CHECK(record.generation == generation + 1 && newRecords == allocations);
    CHECK(fields == 0 && metadata == 0 && database == 0 && tracking == 0 && scans == 0);
    puts("PASS OFF originals once; no field/metadata/DB/tracking/new-record dependency calls");
}
static void ReuseAndExceptions(void) {
    Reset();
    UICollectionViewCell *cell = Cell();
    RUINUnsendMarkerRecord *record = UIRecord(cell);
    id oldModel = cell.model;
    record.model = oldModel; record.key = @{@"message":@"old"};
    record.bindingPending = record.mediaObservationPending = YES;
    cell.badge = YES;
    NSUInteger generation = record.generation;
    UINativeCallback(cell, 2, ^{
        originals++;
        CHECK(record.generation == generation + 1 && !record.key && !record.model);
        CHECK(!record.bindingPending && !record.mediaObservationPending && !cell.badge);
        CHECK(record.awaitingModelChange && record.reusedModel == oldModel);
        UINativeCallback(cell, 0, ^{ originals++; });
        cell.badge = YES; // Native/reentrant work cannot leave a badge on reuse.
    });
    CHECK(originals == 2 && refreshes == 0 && scans == 0 && !cell.badge && UIHookDepth == 0);
    CHECK(!UIMayBind(record, oldModel));
    CHECK(UIMayBind(record, [NSObject new]) && !record.awaitingModelChange);

    generation = record.generation;
    NSException *failure = [NSException exceptionWithName:@"original" reason:nil userInfo:nil];
    __block BOOL caught = NO;
    @try {
        UINativeCallback(cell, 2, ^{
            originals++;
            CHECK(record.generation == generation + 1);
            cell.badge = YES;
            @throw failure;
        });
    } @catch (NSException *exception) { caught = exception == failure; }
    CHECK(caught && originals == 3 && !cell.badge && UIHookDepth == 0);
    CHECK(record.generation == generation + 1 && !UIMayBind(record, oldModel));

    UINativeCallback(cell, 2, ^{ originals++; cell.model = nil; });
    CHECK(record.reusedModel == nil && record.awaitingModelChange && UIHookDepth == 0);
    CHECK(originals == 4 && refreshes == 0);
    // Failed dependency calls must not suppress the original or poison depth.
    throwField = YES;
    UINativeCallback(cell, 2, ^{ originals++; });
    throwField = NO;
    CHECK(originals == 5 && atomic_load(&UIErrors) == 2 && UIHookDepth == 0);
    throwRefresh = YES;
    UINativeCallback(cell, 0, ^{ originals++; });
    throwRefresh = NO;
    CHECK(originals == 6 && atomic_load(&UIErrors) == 3 && UIHookDepth == 0);
    UINativeCallback(cell, 0, ^{
        originals++;
        UINativeCallback(cell, 1, ^{ originals++; });
    });
    CHECK(originals == 8 && refreshes == 2 && scans == 0 && UIHookDepth == 0);
    UIStopHeartbeat();
    puts("PASS reuse generation/seal, reentry, original throw and dependency cleanup");
}
static void TrackedVisibility(void) {
    Reset();
    NSMutableArray<UICollectionViewCell *> *cells = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4; i++) { [cells addObject:Cell()]; [UICells addObject:cells.lastObject]; }
    cells[1].window = nil; cells[2].hidden = YES; cells[3].alpha = 0.01;
    UIRefreshTracked();
    CHECK(scans == 1 && refreshes == 1 && cells[0].refreshes == 1);
    CHECK(atomic_load(&UITrackedVisits) == 1 && atomic_load(&UIVisibleCount) == 1 && UITimer != nil);
    UIApplication.sharedApplication.applicationState = UIApplicationStateBackground;
    UIRefreshTracked();
    CHECK(scans == 1 && refreshes == 1 && atomic_load(&UIVisibleCount) == 0 && UITimer == nil);
    UIApplication.sharedApplication.applicationState = UIApplicationStateActive;
    UIEnsureHeartbeat(); CHECK(UITimer != nil);
    atomic_store(&UIOptionEnabled, NO); UIRefreshTracked();
    CHECK(scans == 1 && refreshes == 1 && UITimer == nil);
    atomic_store(&UIOptionEnabled, YES); cells[0].hidden = YES;
    UIEnsureHeartbeat(); UIRefreshTracked();
    CHECK(scans == 2 && refreshes == 1 && atomic_load(&UIVisibleCount) == 0 && UITimer == nil);
    puts("PASS production tracked refresh: visible only; background/OFF/no-visible stop heartbeat");
}
int main(void) { @autoreleasepool {
    LayoutHotpath(); DisabledHotpath(); ReuseAndExceptions(); TrackedVisibility();
} return 0; }
'''


def extract(source, start, end):
    assert source.count(start) == source.count(end) == 1, (start, end)
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


def main():
    source = (ROOT / 'src/messaging/UnsendMarkerUI.x').read_text()
    enabled = extract(source, 'static BOOL UIEnabled(void) { return atomic_load_explicit(',
                      'static BOOL UIReadOption(')
    record = extract(source, '@interface RUINUnsendMarkerRecord :', 'static CGRect UIBadgeCandidate(')
    lookup = extract(source, 'static RUINUnsendMarkerRecord *UIRecord(', 'static void UIRemoveBadge(')
    heartbeat = extract(source, 'static void UIRefreshTracked(void);', 'static void UINativeCallback(')
    callback = extract(source, 'static void UINativeCallback(', '%group RUINMarkerLayout')
    prefix = (PREAMBLE + enabled + record + '\n#define objc_setAssociatedObject CountSetAssociation\n'
              + lookup + '\n#undef objc_setAssociatedObject\n' + DEPENDENCIES + heartbeat)
    OUT.mkdir(parents=True, exist_ok=True)

    def compile_fixture(name, body):
        fixture = OUT / (name + '.m')
        executable = OUT / name
        fixture.write_text(prefix + body + FIXTURE)
        subprocess.run([
            'xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks', '-std=gnu11',
            '-Wall', '-Wextra', '-Werror', str(fixture),
            '-framework', 'Foundation', '-o', str(executable),
        ], cwd=ROOT, check=True)
        return executable

    executable = compile_fixture('MarkerHotpathUnderTest', callback)
    subprocess.run([str(executable)], cwd=ROOT, check=True, timeout=10)
    # Restore the historical O(layouts * tracked-cells) edge without editing app source.
    edge = 'UIRefreshCell(object);'
    assert callback.count(edge) == 1
    regression = compile_fixture('MarkerHotpathFullScanRegression', callback.replace(
        edge, edge + ' UIRefreshTracked();', 1))
    result = subprocess.run([str(regression)], cwd=ROOT, capture_output=True, text=True, timeout=10)
    assert result.returncode != 0 and 'scans == 0' in result.stderr, result
    print('PASS negative control: restoring callback full scan fails hotpath assertion', flush=True)


if __name__ == '__main__':
    main()
