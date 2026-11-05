#import "NativeReadPositions.h"
#import <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#import <string.h>

NSDictionary<NSString *, NSArray<NSDictionary *> *> *RUINNativeReadPositions(NSData *members, NSData *lastReads, NSData *entries, int64_t observedAt) {
    if (![members isKindOfClass:NSData.class] || ![lastReads isKindOfClass:NSData.class] || ![entries isKindOfClass:NSData.class]) return nil;

    NSUInteger memberBytes = members.length;
    NSUInteger readBytes = lastReads.length;
    NSUInteger entryBytes = entries.length;
    if (memberBytes % 16 || readBytes % 8 || entryBytes % 8 ||
        memberBytes / 16 != readBytes / 8 || memberBytes / 16 != entryBytes / 8 || memberBytes / 16 > 4096) return nil;

    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *result = [NSMutableDictionary dictionary];
    const uint8_t *memberData = members.bytes;
    const uint8_t *readData = lastReads.bytes;
    const uint8_t *entryData = entries.bytes;
    for (NSUInteger i = 0; i < memberBytes / 16; i++) {
        char hex[34] = "u";
        for (NSUInteger j = 0; j < 16; j++) snprintf(hex + 1 + j * 2, 3, "%02x", memberData[i * 16 + j]);
        NSString *mid = [NSString stringWithUTF8String:hex];
        uint64_t rawRead, rawEntry;
        memcpy(&rawRead, readData + i * 8, sizeof(rawRead));
        memcpy(&rawEntry, entryData + i * 8, sizeof(rawEntry));
        int64_t lastRead = (int64_t)CFSwapInt64LittleToHost(rawRead);
        int64_t entry = (int64_t)CFSwapInt64LittleToHost(rawEntry);
        if (entry < 0) return nil;
        if (mid.length != 33 || [mid isEqualToString:@"u00000000000000000000000000000000"] || lastRead <= 0 || entry >= lastRead) continue;

        NSMutableArray<NSDictionary *> *ranges = result[mid];
        if (!ranges) result[mid] = ranges = [NSMutableArray array];
        [ranges addObject:@{
            @"start": [NSString stringWithFormat:@"%lld", (long long)entry],
            @"end": [NSString stringWithFormat:@"%lld", (long long)lastRead],
            @"startTime": @0,
            @"endTime": @0,
            @"observedAt": @(MAX((int64_t)0, observedAt)),
            @"timeSource": observedAt > 0 ? @"observed" : @"unknown"
        }];
    }
    NSMutableDictionary *immutable = [NSMutableDictionary dictionaryWithCapacity:result.count];
    for (NSString *key in result) immutable[key] = [result[key] copy];
    return [immutable copy];
}
