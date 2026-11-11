#!/usr/bin/env python3
"""Run the production retained-video range and method-ABI guards on the host."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/check-retained-video-cache'
PREAMBLE = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <assert.h>
#import <limits.h>
#import <string.h>
'''
FIXTURE = r'''
#define R(location, length) [NSValue valueWithRange:NSMakeRange(location, length)]
@interface VideoGuardFixture : NSObject
- (id)cacheKey;
- (id)originURL;
- (BOOL)wrongReturn;
@end
@implementation VideoGuardFixture
- (id)cacheKey { return nil; }
- (id)originURL { return nil; }
- (BOOL)wrongReturn { return NO; }
@end

int main(void) { @autoreleasepool {
    NSArray *full = @[R(0, 8)];
    assert(CompleteRanges(full, @8));
    assert(CompleteRanges(@[R(4, 4), R(0, 4)], @8)); // Adjacent, out of order.
    assert(CompleteRanges(@[R(0, 6), R(4, 4)], @8)); // Overlap.
    assert(!CompleteRanges(@[R(0, 3), R(4, 4)], @8)); // Hole.
    assert(!CompleteRanges(@[R(0, 9)], @8));
    assert(!CompleteRanges(@[R(1, NSUIntegerMax)], @8)); // Addition would overflow.
    assert(!CompleteRanges(@[R(NSUIntegerMax, 2)], @8));
    assert(!CompleteRanges(nil, @8) && !CompleteRanges(full, nil));
    for (id ranges in @[NSNull.null, @8, @[], @[@8], @[[NSValue valueWithPointer:NULL]]])
        assert(!CompleteRanges(ranges, @8));
    for (id length in @[@0, @(-8), @YES, @NO, @8.0, @"8", NSNull.null, @(ULLONG_MAX)])
        assert(!CompleteRanges(full, length));
    NSMutableArray *bounded = [NSMutableArray array];
    for (NSUInteger i = 0; i < 128; i++) [bounded addObject:R(0, 8)];
    assert(CompleteRanges(bounded, @8));
    [bounded addObject:R(0, 8)];
    assert(!CompleteRanges(bounded, @8));

    Class cls = VideoGuardFixture.class;
    Method present = class_getInstanceMethod(cls, @selector(cacheKey));
    assert(MethodMatches(present, "@16@0:8"));
    assert(MethodMatches(class_getInstanceMethod(cls, @selector(originURL)), "@16@0:8"));
    assert(!MethodMatches(present, "B16@0:8"));
    assert(!MethodMatches(class_getInstanceMethod(cls, @selector(wrongReturn)), "@16@0:8"));
    assert(!MethodMatches(class_getInstanceMethod(cls, NSSelectorFromString(@"missingCacheKey")), "@16@0:8"));
} return 0; }
'''


def main():
    source = (ROOT / 'src/messaging/RetainedVideo.x').read_text()
    start_marker, end_marker = 'static BOOL MethodMatches(', 'static void Observe('
    assert source.count(start_marker) == source.count(end_marker) == 1
    start = source.index(start_marker)
    production = source[start:source.index(end_marker, start)]
    assert production.count('static BOOL CompleteRanges(') == 1
    OUT.mkdir(parents=True, exist_ok=True)
    fixture = OUT / 'RetainedVideoGuardsUnderTest.m'
    fixture.write_text(PREAMBLE + '\n' + production + '\n' + FIXTURE)
    executable = OUT / 'check_retained_video_cache'
    subprocess.run([
        'xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks', '-std=gnu11',
        '-Wall', '-Wextra', '-Werror', str(fixture),
        '-framework', 'Foundation', '-o', str(executable),
    ], cwd=ROOT, check=True)
    subprocess.run([str(executable)], cwd=ROOT, check=True, timeout=10)
    print('PASS production CompleteRanges and MethodMatches guards', flush=True)


if __name__ == '__main__':
    main()
