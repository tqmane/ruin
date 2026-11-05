#import "ReadRangeCodec.h"
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>

NSErrorDomain const RUINReadRangeCodecErrorDomain = @"RUINReadRangeCodecErrorDomain";
static atomic_uint_fast64_t lastRawReaders, lastEmptyReaders, lastEmptyRanges;

NSDictionary<NSString *, NSNumber *> *RUINReadRangeCodecDiagnostics(void) {
    return @{@"rawReaderCount":@(atomic_load(&lastRawReaders)),
        @"emptyReaderCount":@(atomic_load(&lastEmptyReaders)),
        @"emptyOrReversedRangeCount":@(atomic_load(&lastEmptyRanges))};
}

enum {
    RUINCompactStop = 0,
    RUINCompactTrue = 1,
    RUINCompactFalse = 2,
    RUINCompactByte = 3,
    RUINCompactI16 = 4,
    RUINCompactI32 = 5,
    RUINCompactI64 = 6,
    RUINCompactDouble = 7,
    RUINCompactBinary = 8,
    RUINCompactList = 9,
    RUINCompactSet = 10,
    RUINCompactMap = 11,
    RUINCompactStruct = 12,
};

enum { RUINMaxResponseBytes = 8 * 1024 * 1024, RUINMaxDepth = 24,
       RUINMaxContainerCount = 16384, RUINMaxReaders = 4096,
       RUINMaxEntries = 16384, RUINMaxStringBytes = 64 * 1024 };

static BOOL SetError(NSError **error, RUINReadRangeCodecError code, NSString *description) {
    if (error && !*error) {
        *error = [NSError errorWithDomain:RUINReadRangeCodecErrorDomain code:code
                                 userInfo:@{NSLocalizedDescriptionKey: description}];
    }
    return NO;
}

static BOOL IsIdentifier(NSString *value, char prefix) {
    if (value.length != 33 || [value characterAtIndex:0] != prefix) return NO;
    for (NSUInteger i = 1; i < 33; i++) {
        unichar c = [value characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return NO;
    }
    return YES;
}

static void AppendByte(NSMutableData *data, uint8_t byte) {
    [data appendBytes:&byte length:1];
}

static void AppendVarint(NSMutableData *data, uint64_t value) {
    while (value >= 0x80) {
        AppendByte(data, (uint8_t)((value & 0x7f) | 0x80));
        value >>= 7;
    }
    AppendByte(data, (uint8_t)value);
}

static void AppendBinary(NSMutableData *data, const void *bytes, NSUInteger length) {
    AppendVarint(data, length);
    if (length) [data appendBytes:bytes length:length];
}

NSData *RUINReadRangeEncodeRequest(NSString *chatID, int32_t seq, NSError **error) {
    if (error) *error = nil;
    if (![chatID isKindOfClass:NSString.class] || !IsIdentifier(chatID, 'c')) {
        SetError(error, RUINReadRangeCodecErrorInvalidArgument, @"Chat identifier is invalid.");
        return nil;
    }
    NSData *chatBytes = [chatID dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (!chatBytes || chatBytes.length > RUINMaxStringBytes) {
        SetError(error, RUINReadRangeCodecErrorInvalidArgument, @"Chat identifier cannot be encoded as UTF-8.");
        return nil;
    }

    static const char method[] = "getMessageReadRange";
    NSMutableData *request = [NSMutableData dataWithCapacity:chatBytes.length + sizeof(method) + 12];
    AppendByte(request, 0x82);
    AppendByte(request, 0x21); // compact version 1, CALL
    AppendVarint(request, (uint32_t)seq);
    AppendBinary(request, method, sizeof(method) - 1);
    AppendByte(request, 0x29); // args field 2: LIST
    AppendByte(request, 0x18); // one BINARY item
    AppendBinary(request, chatBytes.bytes, chatBytes.length);
    AppendByte(request, 0x15); // args field 3: I32 sync reason
    AppendByte(request, 0x08); // FULL_SYNC (4), zigzag encoded
    AppendByte(request, RUINCompactStop);
    return [request copy];
}

typedef struct {
    const uint8_t *bytes;
    NSUInteger length;
    NSUInteger offset;
    NSError * __autoreleasing *error;
} RUINCompactReader;

static BOOL ReaderError(RUINCompactReader *reader, RUINReadRangeCodecError code, NSString *description) {
    return SetError(reader->error, code, description);
}

static BOOL ReadByte(RUINCompactReader *reader, uint8_t *value) {
    if (reader->offset >= reader->length) {
        return ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact response is truncated.");
    }
    *value = reader->bytes[reader->offset++];
    return YES;
}

static BOOL ReadBytes(RUINCompactReader *reader, NSUInteger count, const uint8_t **bytes) {
    if (count > reader->length - reader->offset) {
        return ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact response is truncated.");
    }
    *bytes = reader->bytes + reader->offset;
    reader->offset += count;
    return YES;
}

static BOOL ReadVarint(RUINCompactReader *reader, unsigned bitLimit, uint64_t *value) {
    const unsigned maxBytes = (bitLimit + 6) / 7;
    uint64_t result = 0;
    for (unsigned i = 0; i < maxBytes; i++) {
        uint8_t byte;
        if (!ReadByte(reader, &byte)) return NO;
        uint8_t part = byte & 0x7f;
        unsigned remaining = bitLimit - i * 7;
        if (remaining < 7 && part >= (1u << remaining)) {
            return ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact varint overflows its field.");
        }
        result |= (uint64_t)part << (i * 7);
        if (!(byte & 0x80)) {
            if (i && part == 0) {
                return ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact varint is not canonical.");
            }
            *value = result;
            return YES;
        }
    }
    return ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact varint is too long.");
}

static int64_t UnZigZag64(uint64_t value) {
    return (int64_t)(value >> 1) ^ -(int64_t)(value & 1);
}

static int32_t UnZigZag32(uint32_t value) {
    return (int32_t)(value >> 1) ^ -(int32_t)(value & 1);
}

static BOOL ReadStringBytes(RUINCompactReader *reader, const uint8_t **bytes, NSUInteger *length) {
    uint64_t count;
    if (!ReadVarint(reader, 32, &count)) return NO;
    if (count > RUINMaxStringBytes) {
        return ReaderError(reader, RUINReadRangeCodecErrorBounds, @"Compact string exceeds the size limit.");
    }
    *length = (NSUInteger)count;
    return ReadBytes(reader, *length, bytes);
}

static BOOL IsCanonicalUTF8(const uint8_t *s, NSUInteger n) {
    for (NSUInteger i = 0; i < n;) {
        uint8_t a = s[i++];
        if (a <= 0x7f) continue;
        if (a >= 0xc2 && a <= 0xdf) {
            if (i >= n || (s[i++] & 0xc0) != 0x80) return NO;
            continue;
        }
        if (a >= 0xe0 && a <= 0xef) {
            if (i + 1 >= n) return NO;
            uint8_t b = s[i++], c = s[i++];
            if ((c & 0xc0) != 0x80 ||
                (a == 0xe0 ? (b < 0xa0 || b > 0xbf) :
                 a == 0xed ? (b < 0x80 || b > 0x9f) : ((b & 0xc0) != 0x80))) return NO;
            continue;
        }
        if (a >= 0xf0 && a <= 0xf4) {
            if (i + 2 >= n) return NO;
            uint8_t b = s[i++], c = s[i++], d = s[i++];
            if ((c & 0xc0) != 0x80 || (d & 0xc0) != 0x80 ||
                (a == 0xf0 ? (b < 0x90 || b > 0xbf) :
                 a == 0xf4 ? (b < 0x80 || b > 0x8f) : ((b & 0xc0) != 0x80))) return NO;
            continue;
        }
        return NO;
    }
    return YES;
}

static BOOL ReadString(RUINCompactReader *reader, NSString **value) {
    const uint8_t *bytes;
    NSUInteger length;
    if (!ReadStringBytes(reader, &bytes, &length)) return NO;
    if (!IsCanonicalUTF8(bytes, length)) {
        return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Compact string is not canonical UTF-8.");
    }
    NSString *string = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    if (!string) return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Compact string is invalid UTF-8.");
    *value = string;
    return YES;
}

static BOOL ReadFieldHeader(RUINCompactReader *reader, int16_t *lastID, uint8_t *type, int16_t *fieldID, BOOL *stop) {
    uint8_t header;
    if (!ReadByte(reader, &header)) return NO;
    if (header == RUINCompactStop) { *stop = YES; return YES; }
    *stop = NO;
    *type = header & 0x0f;
    uint8_t delta = header >> 4;
    if (*type == RUINCompactStop || *type > RUINCompactStruct) {
        return ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact field has an invalid type.");
    }
    int32_t id;
    if (delta) id = (int32_t)*lastID + delta;
    else {
        uint64_t encoded;
        if (!ReadVarint(reader, 32, &encoded)) return NO;
        id = UnZigZag32((uint32_t)encoded);
    }
    if (id < INT16_MIN || id > INT16_MAX) {
        return ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact field identifier is out of range.");
    }
    *fieldID = (int16_t)id;
    *lastID = *fieldID;
    return YES;
}

static BOOL ReadCollectionHeader(RUINCompactReader *reader, uint8_t *elementType, uint64_t *count) {
    uint8_t header;
    if (!ReadByte(reader, &header)) return NO;
    uint8_t size = header >> 4;
    *elementType = header & 0x0f;
    if (*elementType == RUINCompactStop || *elementType > RUINCompactStruct) {
        return ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact collection has an invalid element type.");
    }
    if (size == 15) {
        if (!ReadVarint(reader, 32, count)) return NO;
    } else *count = size;
    if (*count > RUINMaxContainerCount) {
        return ReaderError(reader, RUINReadRangeCodecErrorBounds, @"Compact collection exceeds the item limit.");
    }
    return YES;
}

static BOOL CheckDepth(RUINCompactReader *reader, NSUInteger depth) {
    return depth <= RUINMaxDepth || ReaderError(reader, RUINReadRangeCodecErrorBounds, @"Compact response nesting exceeds the depth limit.");
}

static BOOL SkipValue(RUINCompactReader *reader, uint8_t type, NSUInteger depth);

static BOOL SkipStruct(RUINCompactReader *reader, NSUInteger depth) {
    if (!CheckDepth(reader, depth)) return NO;
    int16_t lastID = 0;
    for (;;) {
        uint8_t type;
        int16_t fieldID;
        BOOL stop;
        if (!ReadFieldHeader(reader, &lastID, &type, &fieldID, &stop)) return NO;
        if (stop) return YES;
        if (type == RUINCompactTrue || type == RUINCompactFalse) continue;
        if (!SkipValue(reader, type, depth + 1)) return NO;
    }
}

static BOOL SkipValue(RUINCompactReader *reader, uint8_t type, NSUInteger depth) {
    if (!CheckDepth(reader, depth)) return NO;
    uint8_t byte;
    uint64_t ignored;
    switch (type) {
        case RUINCompactTrue:
        case RUINCompactFalse:
            if (!ReadByte(reader, &byte)) return NO;
            return (byte == RUINCompactTrue || byte == RUINCompactFalse) ||
                ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact boolean is invalid.");
        case RUINCompactByte:
            return ReadByte(reader, &byte);
        case RUINCompactI16:
        case RUINCompactI32:
            if (!ReadVarint(reader, 32, &ignored)) return NO;
            if (type == RUINCompactI16) {
                int32_t number = UnZigZag32((uint32_t)ignored);
                if (number < INT16_MIN || number > INT16_MAX)
                    return ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact i16 is out of range.");
            }
            return YES;
        case RUINCompactI64:
            return ReadVarint(reader, 64, &ignored);
        case RUINCompactDouble: {
            const uint8_t *unused;
            return ReadBytes(reader, 8, &unused);
        }
        case RUINCompactBinary: {
            const uint8_t *unused;
            NSUInteger length;
            return ReadStringBytes(reader, &unused, &length);
        }
        case RUINCompactList:
        case RUINCompactSet: {
            uint8_t elementType;
            uint64_t count;
            if (!ReadCollectionHeader(reader, &elementType, &count)) return NO;
            for (uint64_t i = 0; i < count; i++)
                if (!SkipValue(reader, elementType, depth + 1)) return NO;
            return YES;
        }
        case RUINCompactMap: {
            uint64_t count;
            if (!ReadVarint(reader, 32, &count)) return NO;
            if (count > RUINMaxContainerCount)
                return ReaderError(reader, RUINReadRangeCodecErrorBounds, @"Compact map exceeds the item limit.");
            if (!count) return YES;
            if (!ReadByte(reader, &byte)) return NO;
            uint8_t keyType = byte >> 4, valueType = byte & 0x0f;
            if (!keyType || keyType > RUINCompactStruct || !valueType || valueType > RUINCompactStruct)
                return ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact map has an invalid type.");
            for (uint64_t i = 0; i < count; i++) {
                if (!SkipValue(reader, keyType, depth + 1) || !SkipValue(reader, valueType, depth + 1)) return NO;
            }
            return YES;
        }
        case RUINCompactStruct:
            return SkipStruct(reader, depth);
        default:
            return ReaderError(reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact value has an invalid type.");
    }
}

static BOOL ReadI64(RUINCompactReader *reader, int64_t *value) {
    uint64_t encoded;
    if (!ReadVarint(reader, 64, &encoded)) return NO;
    *value = UnZigZag64(encoded);
    return YES;
}

static BOOL ReadRangeEntry(RUINCompactReader *reader, NSUInteger depth, NSDictionary **range) {
    if (!CheckDepth(reader, depth)) return NO;
    int16_t lastID = 0;
    uint8_t type;
    int16_t fieldID;
    BOOL stop;
    BOOL seen[5] = {NO, NO, NO, NO, NO};
    int64_t values[5] = {0, 0, 0, 0, 0};
    for (;;) {
        if (!ReadFieldHeader(reader, &lastID, &type, &fieldID, &stop)) return NO;
        if (stop) break;
        if (fieldID >= 1 && fieldID <= 4) {
            if (type != RUINCompactI64 || seen[fieldID])
                return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Read range entry has an invalid field.");
            seen[fieldID] = YES;
            if (!ReadI64(reader, &values[fieldID])) return NO;
        } else if (type != RUINCompactTrue && type != RUINCompactFalse && !SkipValue(reader, type, depth + 1)) return NO;
    }
    if (!seen[1] || !seen[2])
        return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Read range entry is incomplete.");
    if (values[1] >= values[2]) { atomic_fetch_add(&lastEmptyRanges,1); *range = nil; return YES; }
    char start[32], end[32];
    snprintf(start, sizeof(start), "%" PRId64, values[1]);
    snprintf(end, sizeof(end), "%" PRId64, values[2]);
    *range = @{@"start": [NSString stringWithUTF8String:start],
               @"end": [NSString stringWithUTF8String:end],
               @"startTime": @(values[3]), @"endTime": @(values[4]), @"timeSource": @"range"};
    return YES;
}

static BOOL ReadRangesMap(RUINCompactReader *reader, NSUInteger depth,
                          NSDictionary<NSString *, NSArray<NSDictionary *> *> **readers,
                          NSUInteger *totalEntries) {
    if (!CheckDepth(reader, depth)) return NO;
    uint64_t count;
    if (!ReadVarint(reader, 32, &count)) return NO;
    if (count > RUINMaxReaders)
        return ReaderError(reader, RUINReadRangeCodecErrorBounds, @"Read range response exceeds the reader limit.");
    atomic_store(&lastRawReaders, count);
    if (!count) { *readers = @{}; return YES; }
    uint8_t types;
    if (!ReadByte(reader, &types)) return NO;
    if ((types >> 4) != RUINCompactBinary || (types & 0x0f) != RUINCompactList)
        return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Read range map has an invalid type.");

    NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *result = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *seenReaders = [NSMutableSet set];
    for (uint64_t i = 0; i < count; i++) {
        NSString *readerID;
        if (!ReadString(reader, &readerID)) return NO;
        if (!IsIdentifier(readerID, 'u') || [seenReaders containsObject:readerID])
            return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Read range map has an invalid reader identifier.");
        [seenReaders addObject:readerID];
        uint8_t elementType;
        uint64_t entryCount;
        if (!ReadCollectionHeader(reader, &elementType, &entryCount)) return NO;
        if (elementType != RUINCompactStruct)
            return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Reader ranges have an invalid type.");
        if (entryCount > RUINMaxEntries - *totalEntries)
            return ReaderError(reader, RUINReadRangeCodecErrorBounds, @"Read range response exceeds the entry limit.");
        *totalEntries += (NSUInteger)entryCount;
        NSMutableArray<NSDictionary *> *validRanges = [NSMutableArray array];
        for (uint64_t j = 0; j < entryCount; j++) {
            NSDictionary *range;
            if (!ReadRangeEntry(reader, depth + 2, &range)) return NO;
            if (range) [validRanges addObject:range];
        }
        if (validRanges.count) result[readerID] = [validRanges copy];
        else atomic_fetch_add(&lastEmptyReaders,1);
    }
    *readers = [result copy];
    return YES;
}

static BOOL ReadMessageReadRange(RUINCompactReader *reader, NSUInteger depth, NSString *expectedChatID,
                                 NSDictionary<NSString *, NSArray<NSDictionary *> *> **readers,
                                 NSUInteger *totalEntries) {
    if (!CheckDepth(reader, depth)) return NO;
    int16_t lastID = 0;
    BOOL hasChatID = NO, hasRanges = NO;
    NSString *chatID = nil;
    NSDictionary<NSString *, NSArray<NSDictionary *> *> *rangeReaders = nil;
    for (;;) {
        uint8_t type;
        int16_t fieldID;
        BOOL stop;
        if (!ReadFieldHeader(reader, &lastID, &type, &fieldID, &stop)) return NO;
        if (stop) break;
        if (fieldID == 1) {
            if (type != RUINCompactBinary || hasChatID)
                return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Read range result has an invalid chat field.");
            hasChatID = YES;
            if (!ReadString(reader, &chatID)) return NO;
        } else if (fieldID == 2) {
            if (type != RUINCompactMap || hasRanges)
                return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Read range result has an invalid ranges field.");
            hasRanges = YES;
            if (!ReadRangesMap(reader, depth + 1, &rangeReaders, totalEntries)) return NO;
        } else if (type != RUINCompactTrue && type != RUINCompactFalse && !SkipValue(reader, type, depth + 1)) return NO;
    }
    if (!hasChatID || !hasRanges || !IsIdentifier(chatID, 'c'))
        return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Read range result is incomplete or has an invalid chat identifier.");
    if (![chatID isEqualToString:expectedChatID])
        return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Read range response contains an unexpected chat.");
    *readers = rangeReaders;
    return YES;
}

static BOOL ReadSuccessList(RUINCompactReader *reader, NSString *expectedChatID,
                            NSDictionary<NSString *, NSArray<NSDictionary *> *> **readers,
                            NSUInteger *totalEntries, BOOL *foundChat) {
    uint8_t elementType;
    uint64_t count;
    if (!ReadCollectionHeader(reader, &elementType, &count)) return NO;
    if (elementType != RUINCompactStruct)
        return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Read range success field has an invalid type.");
    if (!count) { *foundChat = YES; *readers = @{}; return YES; }
    for (uint64_t i = 0; i < count; i++) {
        NSDictionary<NSString *, NSArray<NSDictionary *> *> *groupReaders;
        if (!ReadMessageReadRange(reader, 1, expectedChatID, &groupReaders, totalEntries)) return NO;
        if (*foundChat)
            return ReaderError(reader, RUINReadRangeCodecErrorSchema, @"Read range response contains the expected chat more than once.");
        *foundChat = YES;
        *readers = groupReaders;
    }
    return YES;
}

NSDictionary<NSString *, NSArray<NSDictionary *> *> *RUINReadRangeDecodeResponse(NSData *data, NSString *expectedChatID,
                                                                                  int32_t seq, NSError **error) {
    atomic_store(&lastRawReaders,0); atomic_store(&lastEmptyReaders,0); atomic_store(&lastEmptyRanges,0);
    if (error) *error = nil;
    if (![data isKindOfClass:NSData.class] || ![expectedChatID isKindOfClass:NSString.class] || !IsIdentifier(expectedChatID, 'c')) {
        SetError(error, RUINReadRangeCodecErrorInvalidArgument, @"Expected chat identifier or response data is invalid.");
        return nil;
    }
    if (data.length > RUINMaxResponseBytes) {
        SetError(error, RUINReadRangeCodecErrorBounds, @"Compact response exceeds the size limit.");
        return nil;
    }
    RUINCompactReader reader = { data.bytes, data.length, 0, error };
    uint8_t byte;
    if (!ReadByte(&reader, &byte) || byte != 0x82) {
        ReaderError(&reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact message protocol identifier is invalid.");
        return nil;
    }
    if (!ReadByte(&reader, &byte)) return nil;
    if ((byte & 0x1f) != 1 || (byte >> 5) != 2) {
        ReaderError(&reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact response is not a version 1 reply.");
        return nil;
    }
    uint64_t encodedSequence;
    if (!ReadVarint(&reader, 32, &encodedSequence)) return nil;
    if ((uint32_t)encodedSequence != (uint32_t)seq) {
        ReaderError(&reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact response sequence does not match.");
        return nil;
    }
    const uint8_t *method;
    NSUInteger methodLength;
    if (!ReadStringBytes(&reader, &method, &methodLength)) return nil;
    static const char expectedMethod[] = "getMessageReadRange";
    if (methodLength != sizeof(expectedMethod) - 1 || memcmp(method, expectedMethod, sizeof(expectedMethod) - 1)) {
        ReaderError(&reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact response method does not match.");
        return nil;
    }
    int16_t lastID = 0;
    BOOL seenSuccess = NO, foundChat = NO;
    NSUInteger totalEntries = 0;
    NSDictionary<NSString *, NSArray<NSDictionary *> *> *readers = nil;
    for (;;) {
        uint8_t type;
        int16_t fieldID;
        BOOL stop;
        if (!ReadFieldHeader(&reader, &lastID, &type, &fieldID, &stop)) return nil;
        if (stop) break;
        if (fieldID == 0) {
            if (type != RUINCompactList || seenSuccess) {
                ReaderError(&reader, RUINReadRangeCodecErrorSchema, @"Compact result has an invalid success field.");
                return nil;
            }
            seenSuccess = YES;
            if (!ReadSuccessList(&reader, expectedChatID, &readers, &totalEntries, &foundChat)) return nil;
        } else if (fieldID == 1) {
            if (type != RUINCompactStruct) {
                ReaderError(&reader, RUINReadRangeCodecErrorSchema, @"Compact result has an invalid error field.");
                return nil;
            }
            ReaderError(&reader, RUINReadRangeCodecErrorServer, @"Server returned a Thrift error result.");
            return nil;
        } else if (type != RUINCompactTrue && type != RUINCompactFalse && !SkipValue(&reader, type, 1)) return nil;
    }
    if (!seenSuccess || !foundChat || !readers) {
        ReaderError(&reader, RUINReadRangeCodecErrorSchema, @"Compact result is missing the expected chat.");
        return nil;
    }
    if (reader.offset != reader.length) {
        ReaderError(&reader, RUINReadRangeCodecErrorMalformedMessage, @"Compact response has trailing bytes.");
        return nil;
    }
    return readers;
}
