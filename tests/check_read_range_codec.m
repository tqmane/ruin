#import "../src/messaging/ReadRangeCodec.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static NSString *const chatID = @"c0123456789abcdef0123456789abcdef";
static NSString *const readerID = @"uabcdef0123456789abcdef0123456789";

static void PutByte(NSMutableData *data, uint8_t value) { [data appendBytes:&value length:1]; }
static void Varint(NSMutableData *data, uint64_t value) {
    while (value >= 0x80) { PutByte(data, (uint8_t)((value & 0x7f) | 0x80)); value >>= 7; }
    PutByte(data, (uint8_t)value);
}
static uint32_t Zig32(int32_t n) { return ((uint32_t)n << 1) ^ (uint32_t)-(n < 0); }
static uint64_t Zig64(int64_t n) { return ((uint64_t)n << 1) ^ (uint64_t)-(n < 0); }
static void Binary(NSMutableData *data, const void *bytes, NSUInteger length) {
    Varint(data, length);
    if (length) [data appendBytes:bytes length:length];
}
static void String(NSMutableData *data, NSString *value) {
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding];
    Binary(data, bytes.bytes, bytes.length);
}
static void Field(NSMutableData *data, int16_t *last, int16_t fieldID, uint8_t type) {
    int delta = fieldID - *last;
    if (delta > 0 && delta <= 15) PutByte(data, (uint8_t)((delta << 4) | type));
    else { PutByte(data, type); Varint(data, Zig32(fieldID)); }
    *last = fieldID;
}
static void RangeEntry(NSMutableData *data, int64_t start, int64_t end, int64_t startTime, int64_t endTime) {
    PutByte(data, 0x16); Varint(data, Zig64(start));
    PutByte(data, 0x16); Varint(data, Zig64(end));
    PutByte(data, 0x16); Varint(data, Zig64(startTime));
    PutByte(data, 0x16); Varint(data, Zig64(endTime));
    PutByte(data, 0);
}
static void Group(NSMutableData *data, NSString *chat, NSString *reader, int64_t start, int64_t end,
                  int64_t startTime, int64_t endTime) {
    int16_t last = 0;
    Field(data, &last, 1, 8); String(data, chat);
    Field(data, &last, 2, 11); Varint(data, 1); PutByte(data, 0x89);
    String(data, reader); PutByte(data, 0x1c);
    RangeEntry(data, start, end, startTime, endTime);
    PutByte(data, 0);
}
static NSMutableData *ReplyPrefix(int32_t seq, NSString *method) {
    NSMutableData *data = [NSMutableData data];
    PutByte(data, 0x82); PutByte(data, 0x41); Varint(data, (uint32_t)seq); String(data, method);
    return data;
}
static NSMutableData *Reply(int32_t seq, NSString *chat, int64_t start, int64_t end,
                            int64_t startTime, int64_t endTime) {
    NSMutableData *data = ReplyPrefix(seq, @"getMessageReadRange");
    PutByte(data, 0x09); PutByte(data, 0); // result field 0, LIST
    PutByte(data, 0x1c); // one STRUCT
    Group(data, chat, readerID, start, end, startTime, endTime);
    PutByte(data, 0); // result STOP
    return data;
}
static NSDictionary *Decode(NSData *data, NSError **error) {
    return RUINReadRangeDecodeResponse(data, chatID, 321, error);
}
static void ExpectFailure(NSData *data) {
    NSError *error = nil;
    assert(Decode(data, &error) == nil);
    assert([error.domain isEqualToString:RUINReadRangeCodecErrorDomain]);
    assert([error.userInfo[NSLocalizedDescriptionKey] isKindOfClass:NSString.class]);
}

int main(void) { @autoreleasepool {
    NSError *error = nil;
    NSData *request = RUINReadRangeEncodeRequest(chatID, 7, &error);
    assert(request && !error);
    static const uint8_t requestPrefix[] = {
        0x82,0x21,0x07,0x13,'g','e','t','M','e','s','s','a','g','e','R','e','a','d','R','a','n','g','e',
        0x29,0x18,0x21
    };
    NSMutableData *expectedRequest = [NSMutableData dataWithBytes:requestPrefix length:sizeof(requestPrefix)];
    [expectedRequest appendData:[chatID dataUsingEncoding:NSUTF8StringEncoding]];
    PutByte(expectedRequest, 0x15); PutByte(expectedRequest, 0x08);
    PutByte(expectedRequest, 0);
    assert([request isEqualToData:expectedRequest]); // field 2 LIST<string>; field 3 FULL_SYNC

    const int64_t largeStart = INT64_C(9007199254740993);
    const int64_t largeEnd = INT64_MAX;
    NSMutableData *valid = Reply(321, chatID, largeStart, largeEnd, INT64_C(1700000000123), INT64_C(1700000000456));
    assert(((const uint8_t *)valid.bytes)[2] == 0xc1 && ((const uint8_t *)valid.bytes)[3] == 0x02);
    // An unknown field containing a list is safely skipped before success field 0.
    NSMutableData *unknown = ReplyPrefix(321, @"getMessageReadRange");
    PutByte(unknown, 0x99); PutByte(unknown, 0x16); Varint(unknown, Zig64(7));
    PutByte(unknown, 0x09); PutByte(unknown, 0); PutByte(unknown, 0x1c);
    Group(unknown, chatID, readerID, largeStart, largeEnd, INT64_C(1700000000123), INT64_C(1700000000456));
    PutByte(unknown, 0);
    NSDictionary *readers = Decode(unknown, &error);
    assert(readers && !error && readers.count == 1);
    NSDictionary *range = readers[readerID][0];
    assert([range[@"start"] isEqualToString:@"9007199254740993"]);
    assert([range[@"end"] isEqualToString:@"9223372036854775807"]);
    assert([range[@"startTime"] isEqual:@1700000000123LL]);
    assert([range[@"endTime"] isEqual:@1700000000456LL]);
    assert([range[@"timeSource"] isEqualToString:@"range"]);

    // Invalid and empty ranges are ignored after complete schema validation.
    NSMutableData *emptyRange = ReplyPrefix(321, @"getMessageReadRange");
    PutByte(emptyRange, 0x09); PutByte(emptyRange, 0); PutByte(emptyRange, 0x1c);
    int16_t groupLast = 0;
    Field(emptyRange, &groupLast, 1, 8); String(emptyRange, chatID);
    Field(emptyRange, &groupLast, 2, 11); Varint(emptyRange, 1); PutByte(emptyRange, 0x89);
    String(emptyRange, readerID); PutByte(emptyRange, 0x1c);
    RangeEntry(emptyRange, 10, 10, 1, 2); PutByte(emptyRange, 0); PutByte(emptyRange, 0);
    assert([Decode(emptyRange, &error) isEqual:@{}] && !error);

    NSMutableData *wrongMethod = Reply(321, chatID, 1, 2, 3, 4);
    NSMutableData *wrongMethodPrefix = ReplyPrefix(321, @"getMessageReadRangX");
    [wrongMethodPrefix appendData:[wrongMethod subdataWithRange:NSMakeRange(2 + 1 + 19 + 2, wrongMethod.length - (2 + 1 + 19 + 2))]];
    ExpectFailure(wrongMethodPrefix);
    ExpectFailure(Reply(322, chatID, 1, 2, 3, 4));
    ExpectFailure(Reply(321, @"c1123456789abcdef0123456789abcdef", 1, 2, 3, 4));

    NSMutableData *missingChat = ReplyPrefix(321, @"getMessageReadRange");
    PutByte(missingChat, 0x09); PutByte(missingChat, 0); PutByte(missingChat, 0x0c); PutByte(missingChat, 0); // empty success list
    assert([Decode(missingChat, &error) isEqual:@{}] && !error);

    NSMutableData *withoutTimes = ReplyPrefix(321, @"getMessageReadRange");
    PutByte(withoutTimes, 0x09); PutByte(withoutTimes, 0); PutByte(withoutTimes, 0x1c);
    PutByte(withoutTimes, 0x18); String(withoutTimes, chatID);
    PutByte(withoutTimes, 0x1b); Varint(withoutTimes, 1); PutByte(withoutTimes, 0x89);
    String(withoutTimes, readerID); PutByte(withoutTimes, 0x1c);
    PutByte(withoutTimes, 0x16); Varint(withoutTimes, Zig64(1));
    PutByte(withoutTimes, 0x16); Varint(withoutTimes, Zig64(2));
    PutByte(withoutTimes, 0); PutByte(withoutTimes, 0); PutByte(withoutTimes, 0);
    NSDictionary *unknownTime = Decode(withoutTimes, &error)[readerID][0];
    assert(unknownTime && !error && [unknownTime[@"startTime"] isEqual:@0] && [unknownTime[@"endTime"] isEqual:@0]);

    NSMutableData *duplicateChat = ReplyPrefix(321, @"getMessageReadRange");
    PutByte(duplicateChat, 0x09); PutByte(duplicateChat, 0); PutByte(duplicateChat, 0x2c);
    Group(duplicateChat, chatID, readerID, 1, 2, 3, 4);
    Group(duplicateChat, chatID, readerID, 1, 2, 3, 4); PutByte(duplicateChat, 0);
    ExpectFailure(duplicateChat);

    NSMutableData *errorResult = ReplyPrefix(321, @"getMessageReadRange");
    PutByte(errorResult, 0x1c); PutByte(errorResult, 0); PutByte(errorResult, 0);
    ExpectFailure(errorResult);

    NSMutableData *wrongSchema = ReplyPrefix(321, @"getMessageReadRange");
    PutByte(wrongSchema, 0x08); Varint(wrongSchema, 0); Binary(wrongSchema, NULL, 0); PutByte(wrongSchema, 0);
    ExpectFailure(wrongSchema);

    NSMutableData *oversizedCount = ReplyPrefix(321, @"getMessageReadRange");
    PutByte(oversizedCount, 0x09); PutByte(oversizedCount, 0); PutByte(oversizedCount, 0xfc);
    Varint(oversizedCount, 16385); PutByte(oversizedCount, 0);
    ExpectFailure(oversizedCount);

    NSMutableData *overflow = [NSMutableData dataWithBytes:(const uint8_t[]){0x82,0x41} length:2];
    const uint8_t badVarint[] = {0xff,0xff,0xff,0xff,0x10};
    [overflow appendBytes:badVarint length:sizeof(badVarint)];
    ExpectFailure(overflow);

    NSMutableData *truncated = [valid mutableCopy];
    [truncated setLength:truncated.length - 1];
    ExpectFailure(truncated);

    NSMutableData *tooLarge = [NSMutableData dataWithLength:(8 * 1024 * 1024) + 1];
    ExpectFailure(tooLarge);

    assert(RUINReadRangeEncodeRequest(@"not-a-chat", 0, &error) == nil && error);
    puts("PASS bounded read-range compact codec");
} return 0; }
