#import "NativeReadPositions.h"
#include <assert.h>
#include <stdint.h>
#include <string.h>

static void putLE64(uint8_t *p, uint64_t value) {
    for (NSUInteger i = 0; i < 8; i++) p[i] = (uint8_t)(value >> (i * 8));
}

static NSData *data(const uint8_t *bytes, NSUInteger length) { return [NSData dataWithBytes:bytes length:length]; }

int main(void) {
    @autoreleasepool {
        const uint8_t member[] = {0x1b,0x5a,0x2f,0x18,0xd9,0xad,0x63,0x61,0xf3,0xef,0x4a,0x65,0x37,0x2b,0xfb,0xad};
        const uint8_t read[] = {0x10,0x02,0x0c,0xf8,0xde,0x06,0xde,0x08};
        uint8_t zeroEntry[8] = {0};
        NSDictionary *actual = RUINNativeReadPositions(data(member, sizeof(member)), data(read, sizeof(read)), data(zeroEntry, sizeof(zeroEntry)), 123);
        NSDictionary *range = actual[@"u1b5a2f18d9ad6361f3ef4a65372bfbad"][0];
        assert([range[@"start"] isEqual:@"0"]);
        assert([range[@"end"] isEqual:@"638955751847232016"]);
        assert([range[@"startTime"] isEqual:@0] && [range[@"endTime"] isEqual:@0]);
        assert([range[@"observedAt"] isEqual:@123] && [range[@"timeSource"] isEqual:@"observed"]);

        uint8_t members[32]; memcpy(members, member, 16); memcpy(members + 16, member, 16);
        uint8_t reads[16], joins[16];
        putLE64(reads, 10); putLE64(reads + 8, 20);
        putLE64(joins, 4); putLE64(joins + 8, 12);
        NSDictionary *two = RUINNativeReadPositions(data(members, 32), data(reads, 16), data(joins, 16), -7);
        NSArray *ranges = two[@"u1b5a2f18d9ad6361f3ef4a65372bfbad"];
        assert(ranges.count == 2);
        assert([ranges[0][@"start"] isEqual:@"4"] && [ranges[0][@"end"] isEqual:@"10"]);
        assert([ranges[1][@"start"] isEqual:@"12"] && [ranges[1][@"end"] isEqual:@"20"]);
        assert([ranges[1][@"timeSource"] isEqual:@"unknown"] && [ranges[1][@"observedAt"] isEqual:@0]);

        uint8_t maxBytes[8], maxEntry[8];
        putLE64(maxBytes, INT64_MAX); putLE64(maxEntry, INT64_MAX - 1);
        NSDictionary *boundary = RUINNativeReadPositions(data(member, 16), data(maxBytes, 8), data(maxEntry, 8), 0);
        NSDictionary *maxRange = boundary[@"u1b5a2f18d9ad6361f3ef4a65372bfbad"][0];
        assert([maxRange[@"start"] isEqual:@"9223372036854775806"] && [maxRange[@"end"] isEqual:@"9223372036854775807"]);

        uint8_t negative[8]; putLE64(negative, (uint64_t)INT64_MAX + 1);
        assert([RUINNativeReadPositions(data(member, 16), data(negative, 8), data(zeroEntry, 8), 1) count] == 0);
        assert([RUINNativeReadPositions(data(member, 16), data(zeroEntry, 8), data(zeroEntry, 8), 1) count] == 0);
        assert([RUINNativeReadPositions(data(member, 16), data(read, 8), data(read, 8), 1) count] == 0);
        assert([RUINNativeReadPositions(data(NULL, 0), data(NULL, 0), data(NULL, 0), 0) isEqual:@{}]);

        assert(RUINNativeReadPositions(data(member, 15), data(read, 8), data(zeroEntry, 8), 1) == nil);
        assert(RUINNativeReadPositions(data(member, 16), data(read, 7), data(zeroEntry, 8), 1) == nil);
        assert(RUINNativeReadPositions(data(member, 16), data(read, 8), data(zeroEntry, 7), 1) == nil);
        assert(RUINNativeReadPositions(data(members, 32), data(read, 8), data(joins, 8), 1) == nil);
        assert(RUINNativeReadPositions((id)@[], data(read, 8), data(zeroEntry, 8), 1) == nil);
    }
    return 0;
}
