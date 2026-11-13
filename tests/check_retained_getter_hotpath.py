#!/usr/bin/env python3
"""Foundation seam for extracted production getter/cache logic, not archive I/O.

ScheduleGetterWarm is a counted request boundary: no real queue, DB, capture,
or filesystem work runs. Generation changes model invalidation; account/defaults
observers and the actual async warmer are outside this test.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PREAMBLE = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); exit(1); } } while (0)
static NSUInteger originals, warms, scopes, queues, databases, notifications;
static BOOL enabled = YES, throwWarm;
static _Thread_local unsigned captureDepth, getterDepth;
static atomic_ulong URLReplacements;
static NSCache *getterURLCache;
static os_unfair_lock getterCacheLock = OS_UNFAIR_LOCK_INIT;
static uint64_t getterCacheGeneration;
static NSUInteger pendingGetterWarms;
static const void *getterStateAssociation = &getterStateAssociation;
@interface TestContext : NSObject
- (void)performBlock:(void (^)(void))block;
- (void)performBlockAndWait:(void (^)(void))block;
@end
@implementation TestContext
- (void)performBlock:(__unused void (^)(void))block { queues++; CHECK(NO); }
- (void)performBlockAndWait:(__unused void (^)(void))block { queues++; CHECK(NO); }
@end
// Keep the extracted type spelling without defining a second Core Data class.
#define NSManagedObject TestManagedObject
@interface NSManagedObject : NSObject
@property(nonatomic, strong) TestContext *managedObjectContext;
@end
@implementation NSManagedObject @end
static BOOL Enabled(void) { return enabled; }
static void InitializeGetterCache(void) { if (!getterURLCache) getterURLCache = [NSCache new]; }
static void NotifyChanged(__unused NSDictionary *key) { notifications++; }
static NSDictionary * __attribute__((unused)) Scope(__unused NSManagedObject *message) { scopes++; CHECK(NO); return nil; }
static id __attribute__((unused)) Store(__unused BOOL create) { databases++; CHECK(NO); return nil; }
static NSManagedObject *scheduledMessage;
static NSString *scheduledRole;
static id scheduledValue;
// Dependency boundary only: count requests, never execute the production warmer.
static void ScheduleGetterWarm(NSManagedObject *message, NSString *role, id value) {
    warms++; scheduledMessage = message; scheduledRole = role; scheduledValue = value;
    if (throwWarm) @throw [NSException exceptionWithName:@"warm" reason:nil userInfo:nil];
}
'''
FIXTURE = r'''
static void NoBlockingWork(void) { CHECK(scopes == 0 && queues == 0 && databases == 0); }
int main(void) { @autoreleasepool {
    NSManagedObject *message = [NSManagedObject new];
    message.managedObjectContext = [TestContext new];
    NSObject *native = [NSObject new];
    id (^original)(void) = ^id { originals++; return native; };
    // Each early exit invokes native exactly once and never consults the cache.
    enabled = NO;
    CHECK(ForwardURL(message, @"photo", original) == native);
    CHECK(originals == 1 && warms == 0 && getterDepth == 0 && getterURLCache == nil);
    enabled = YES; message.managedObjectContext = nil;
    CHECK(ForwardURL(message, @"photo", original) == native);
    CHECK(originals == 2 && warms == 0 && getterDepth == 0 && getterURLCache == nil);
    message.managedObjectContext = [TestContext new]; getterDepth = 1;
    CHECK(ForwardURL(message, @"photo", original) == native);
    CHECK(originals == 3 && warms == 0 && getterDepth == 1 && getterURLCache == nil);
    getterDepth = 0; captureDepth = 1;
    CHECK(ForwardURL(message, @"photo", original) == native);
    CHECK(originals == 4 && warms == 0 && getterDepth == 0 && captureDepth == 1 && getterURLCache == nil);
    captureDepth = 0;
    InitializeGetterCache();
    RUINRetainedMediaGetterState *state = GetterState(message, YES);
    NSArray *key = @[@"object", @"store", @"talk", @"chat", @"message"];
    NSURL *archive = [NSURL fileURLWithPath:@"/synthetic/archive"];
    state.cacheKey = key; [getterURLCache setObject:@{@"photo":archive, @"video":archive} forKey:key];
    CHECK(ForwardURL(message, @"photo", original) == archive);
    CHECK(ForwardURL(message, @"attached", original) == archive);
    CHECK(originals == 6 && warms == 0 && atomic_load(&URLReplacements) == 2);
    // Actual recursion: the inner invocation must preserve native and skip warming.
    CHECK(ForwardURL(message, @"photo", ^id {
        originals++; CHECK(getterDepth == 1);
        CHECK(ForwardURL(message, @"photo", original) == native);
        CHECK(getterDepth == 1 && warms == 0); return native;
    }) == archive);
    CHECK(originals == 8 && getterDepth == 0 && warms == 0);
    [getterURLCache removeAllObjects];
    CHECK(ForwardURL(message, @"audio", original) == native);
    CHECK(originals == 9 && warms == 1 && scheduledMessage == message);
    CHECK([scheduledRole isEqual:@"audio"] && scheduledValue == native && getterDepth == 0);
    CHECK(ForwardURL(message, @"photo", ^id { originals++; return nil; }) == nil);
    CHECK(originals == 10 && warms == 2 && scheduledValue == nil);
    NSException *failure = [NSException exceptionWithName:@"original" reason:nil userInfo:nil];
    BOOL caught = NO;
    @try { ForwardURL(message, @"photo", ^id { originals++; @throw failure; }); }
    @catch (NSException *exception) { caught = exception == failure; }
    CHECK(caught && originals == 11 && warms == 2 && getterDepth == 0);
    throwWarm = YES; caught = NO;
    @try { ForwardURL(message, @"photo", original); }
    @catch (NSException *exception) { caught = [exception.name isEqual:@"warm"]; }
    CHECK(caught && originals == 12 && warms == 3 && getterDepth == 0);
    throwWarm = NO; NoBlockingWork();
    puts("PASS ForwardURL: originals once, OFF/context/reentry/capture guards, cached hit, cold request, exception cleanup");
    NSDictionary *URLs = @{@"photo":archive}, *messageKey = @{@"message":@"1"};
    state.generation = 10; state.pending = YES; pendingGetterWarms = 1;
    FinishGetterWarm(message, 9, getterCacheGeneration, key, URLs, messageKey);
    CHECK(state.pending && state.generation == 10 && pendingGetterWarms == 0);
    CHECK([getterURLCache objectForKey:key] == nil && notifications == 0);
    pendingGetterWarms = 1;
    NSTimeInterval before = NSProcessInfo.processInfo.systemUptime;
    FinishGetterWarm(message, 10, getterCacheGeneration, key, URLs, messageKey);
    CHECK(!state.pending && pendingGetterWarms == 0 && notifications == 1);
    CHECK([getterURLCache objectForKey:key] == URLs && state.retryAfter >= before + 1.0);
    state.pending = YES; pendingGetterWarms = 1;
    FinishGetterWarm(message, 10, getterCacheGeneration, key, URLs, messageKey);
    CHECK(!state.pending && notifications == 1 && pendingGetterWarms == 0);
    uint64_t oldGeneration = getterCacheGeneration;
    InvalidateAllGetterCaches(); // Same generation barrier used for account changes; no observer test.
    CHECK(getterCacheGeneration == oldGeneration + 1 && CachedArchiveURL(message, @"photo") == nil);
    state.pending = YES; pendingGetterWarms = 1;
    FinishGetterWarm(message, 10, oldGeneration, key, URLs, messageKey);
    CHECK(state.pending && pendingGetterWarms == 0 && notifications == 1);
    CHECK([getterURLCache objectForKey:key] == nil);
    CHECK(ForwardURL(message, @"photo", original) == native);
    CHECK(originals == 13 && warms == 4 && getterDepth == 0);
    NoBlockingWork();
    puts("PASS FinishGetterWarm: stale request/global generation rejected, publish, unchanged notification suppression");
} return 0; }
'''


def extract(source, start, end):
    assert source.count(start) == source.count(end) == 1, (start, end)
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


def main():
    source = (ROOT / 'src/messaging/RetainedMedia.x').read_text()
    sections = [
        ('@interface RUINRetainedMediaGetterState :', 'static void InitializeGetterCache('),
        ('static RUINRetainedMediaGetterState *GetterState(', '// UIKit owns'),
        ('static NSURL *CachedArchiveURL(', 'static void InvalidateGetterCache('),
        ('static void InvalidateAllGetterCaches(', 'static void InstallGetterCacheObservers('),
        ('static void FinishGetterWarm(', 'static NSString *GetterSelectorForRole('),
        ('static id ForwardURL(', '%group RUINMediaTalkURLs'),
    ]
    with tempfile.TemporaryDirectory(prefix='ruin-getter-hotpath-') as directory:
        fixture = Path(directory) / 'GetterHotpath.m'
        executable = Path(directory) / 'GetterHotpath'
        fixture.write_text(PREAMBLE + ''.join(extract(source, *s) for s in sections) + FIXTURE)
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks',
                        '-std=gnu11', '-Wall', '-Wextra', '-Werror', str(fixture),
                        '-framework', 'Foundation', '-o', str(executable)], check=True, timeout=30)
        subprocess.run([str(executable)], check=True, timeout=10)


if __name__ == '__main__':
    main()
