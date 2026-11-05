#import "ThemeArchive.h"

#import <TargetConditionals.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <zlib.h>

NSString * const RUINThemeArchiveErrorDomain = @"RUINThemeArchiveErrorDomain";

static const uint64_t RUINThemeArchiveMaxInput = 64ULL * 1024 * 1024;
static const uint64_t RUINThemeArchiveMaxEntry = 64ULL * 1024 * 1024;
static const uint64_t RUINThemeArchiveMaxExpanded = 256ULL * 1024 * 1024;
static const NSUInteger RUINThemeArchiveMaxEntries = 4096;
#define RUINThemeArchiveChunk (64 * 1024)

typedef NS_ENUM(NSInteger, RUINThemeArchiveErrorCode) {
    RUINThemeArchiveErrorInvalidArgument = 1,
    RUINThemeArchiveErrorIO = 2,
    RUINThemeArchiveErrorInvalidZIP = 3,
    RUINThemeArchiveErrorInvalidManifest = 4,
};

@interface RUINThemeArchiveEntry : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic) uint16_t flags;
@property(nonatomic) uint16_t method;
@property(nonatomic) uint32_t crc;
@property(nonatomic) uint32_t compressedSize;
@property(nonatomic) uint32_t expandedSize;
@property(nonatomic) uint32_t localOffset;
@property(nonatomic) uint64_t dataOffset;
@property(nonatomic) uint64_t rangeEnd;
@property(nonatomic, getter=isDirectory) BOOL directory;
@end

@implementation RUINThemeArchiveEntry
@end

static BOOL RUINThemeArchiveFail(NSError **error, RUINThemeArchiveErrorCode code, NSString *message)
{
    if (error) *error = [NSError errorWithDomain:RUINThemeArchiveErrorDomain
                                            code:code
                                        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

static uint16_t RUINReadLE16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t RUINReadLE32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static BOOL RUINValidateExtraFields(const uint8_t *bytes, uint64_t start, uint64_t length, NSError **error)
{
    uint64_t end = start + length;
    for (uint64_t cursor = start; cursor < end;) {
        if (end - cursor < 4)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Malformed ZIP extra field.");
        uint16_t identifier = RUINReadLE16(bytes + cursor);
        uint16_t size = RUINReadLE16(bytes + cursor + 2);
        if ((uint64_t)size > end - cursor - 4 || identifier == 0x0001)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Malformed or ZIP64 extra field.");
        cursor += 4 + size;
    }
    return YES;
}

static NSString *RUINCanonicalThemePath(NSString *path)
{
    NSString *normalized = [path precomposedStringWithCanonicalMapping];
    return [normalized stringByFoldingWithOptions:NSCaseInsensitiveSearch
                                            locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
}

static BOOL RUINRegisterThemePath(NSString *path,
                                  BOOL directory,
                                  NSMutableDictionary<NSString *, NSNumber *> *nodeTypes,
                                  NSMutableSet<NSString *> *explicitPaths,
                                  NSError **error)
{
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray<NSString *> *canonicalParts = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSString *part in parts) {
        if (part.length == 0 || [part isEqual:@"."] || [part isEqual:@".."] ||
            [part lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > NAME_MAX)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Unsafe or overlong ZIP path component.");
        [canonicalParts addObject:RUINCanonicalThemePath(part)];
    }

    NSMutableArray<NSString *> *prefix = [NSMutableArray arrayWithCapacity:canonicalParts.count];
    for (NSUInteger i = 0; i + 1 < canonicalParts.count; i++) {
        [prefix addObject:canonicalParts[i]];
        NSString *parent = [prefix componentsJoinedByString:@"/"];
        if ([nodeTypes[parent] integerValue] == 2)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"A file is also used as a ZIP path directory.");
        nodeTypes[parent] = @1;
    }

    NSString *canonicalPath = [canonicalParts componentsJoinedByString:@"/"];
    if ([explicitPaths containsObject:canonicalPath])
        return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Duplicate ZIP path after Unicode and case normalization.");
    [explicitPaths addObject:canonicalPath];

    NSNumber *existing = nodeTypes[canonicalPath];
    if (directory) {
        if (existing && existing.integerValue == 2)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"A ZIP path collides with a file.");
        nodeTypes[canonicalPath] = @1;
    } else {
        if (existing)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"A ZIP file collides with a directory.");
        nodeTypes[canonicalPath] = @2;
    }
    return YES;
}

static BOOL RUINParseThemeZIP(const uint8_t *bytes,
                              size_t length,
                              NSArray<RUINThemeArchiveEntry *> **parsedEntries,
                              RUINThemeArchiveEntry **manifestEntry,
                              NSError **error)
{
    if (length < 22 || length > RUINThemeArchiveMaxInput)
        return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"ZIP input is empty or exceeds 64 MiB.");

    size_t searchStart = length > 65557 ? length - 65557 : 0;
    size_t endRecord = SIZE_MAX;
    for (size_t cursor = length - 22;; cursor--) {
        if (RUINReadLE32(bytes + cursor) == 0x06054b50) {
            uint16_t commentLength = RUINReadLE16(bytes + cursor + 20);
            if ((uint64_t)cursor + 22 + commentLength == length) {
                endRecord = cursor;
                break;
            }
        }
        if (cursor == searchStart) break;
    }
    if (endRecord == SIZE_MAX)
        return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Missing or malformed ZIP end record.");

    uint16_t disk = RUINReadLE16(bytes + endRecord + 4);
    uint16_t centralDisk = RUINReadLE16(bytes + endRecord + 6);
    uint16_t diskCount = RUINReadLE16(bytes + endRecord + 8);
    uint16_t entryCount = RUINReadLE16(bytes + endRecord + 10);
    uint32_t centralSize = RUINReadLE32(bytes + endRecord + 12);
    uint32_t centralOffset = RUINReadLE32(bytes + endRecord + 16);
    uint64_t centralEnd = (uint64_t)centralOffset + centralSize;
    if (disk || centralDisk || diskCount != entryCount || !entryCount || entryCount == UINT16_MAX ||
        centralSize == UINT32_MAX || centralOffset == UINT32_MAX || entryCount > RUINThemeArchiveMaxEntries ||
        centralEnd != endRecord)
        return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Multi-disk, ZIP64, empty, oversized, or inconsistent ZIP directory.");

    NSMutableArray<RUINThemeArchiveEntry *> *entries = [NSMutableArray arrayWithCapacity:entryCount];
    NSMutableDictionary<NSString *, NSNumber *> *nodeTypes = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *explicitPaths = [NSMutableSet set];
    uint64_t expandedTotal = 0;
    size_t cursor = centralOffset;

    for (NSUInteger index = 0; index < entryCount; index++) {
        if (cursor > centralEnd || centralEnd - cursor < 46 || RUINReadLE32(bytes + cursor) != 0x02014b50)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Malformed ZIP central-directory entry.");

        uint16_t madeBy = RUINReadLE16(bytes + cursor + 4);
        uint16_t flags = RUINReadLE16(bytes + cursor + 8);
        uint16_t method = RUINReadLE16(bytes + cursor + 10);
        uint32_t crc = RUINReadLE32(bytes + cursor + 16);
        uint32_t compressedSize = RUINReadLE32(bytes + cursor + 20);
        uint32_t expandedSize = RUINReadLE32(bytes + cursor + 24);
        uint16_t nameLength = RUINReadLE16(bytes + cursor + 28);
        uint16_t extraLength = RUINReadLE16(bytes + cursor + 30);
        uint16_t commentLength = RUINReadLE16(bytes + cursor + 32);
        uint16_t diskStart = RUINReadLE16(bytes + cursor + 34);
        uint32_t externalAttributes = RUINReadLE32(bytes + cursor + 38);
        uint32_t localOffset = RUINReadLE32(bytes + cursor + 42);
        uint64_t recordEnd = (uint64_t)cursor + 46 + nameLength + extraLength + commentLength;
        uint16_t allowedFlags = (uint16_t)(0x0808 | (method == 8 ? 0x0006 : 0));
        if (!nameLength || recordEnd > centralEnd || diskStart || (flags & (uint16_t)~allowedFlags) ||
            (method != 0 && method != 8) || compressedSize == UINT32_MAX || expandedSize == UINT32_MAX ||
            localOffset == UINT32_MAX || expandedSize > RUINThemeArchiveMaxEntry ||
            compressedSize > RUINThemeArchiveMaxInput)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Unsupported ZIP flags, method, or entry sizes.");

        uint64_t nameOffset = (uint64_t)cursor + 46;
        uint64_t extraOffset = nameOffset + nameLength;
        if (!RUINValidateExtraFields(bytes, extraOffset, extraLength, error)) return NO;
        if (memchr(bytes + nameOffset, 0, nameLength))
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"NUL byte in ZIP path.");
        NSString *rawPath = [[NSString alloc] initWithBytes:bytes + nameOffset
                                                      length:nameLength
                                                    encoding:NSUTF8StringEncoding];
        if (!rawPath || [rawPath hasPrefix:@"/"] || [rawPath containsString:@"\\"] || [rawPath containsString:@":"])
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Absolute, non-UTF8, or ambiguous ZIP path.");

        BOOL directory = [rawPath hasSuffix:@"/"];
        NSString *path = directory ? [rawPath substringToIndex:rawPath.length - 1] : rawPath;
        if (!path.length || !RUINRegisterThemePath(path, directory, nodeTypes, explicitPaths, error)) return NO;

        uint8_t hostOS = (uint8_t)(madeBy >> 8);
        uint32_t unixType = (externalAttributes >> 16) & 0170000;
        if ((hostOS == 3 && unixType && unixType != (directory ? 0040000 : 0100000)) ||
            (hostOS == 0 && (((externalAttributes & 0x10) != 0) != directory)))
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"ZIP symlinks, special files, and mismatched directory types are rejected.");
        if (directory && (compressedSize || expandedSize || crc))
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"ZIP directory entries must be empty.");
        if (!directory && method == 0 && compressedSize != expandedSize)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Stored ZIP entry has inconsistent sizes.");

        expandedTotal += expandedSize;
        if (expandedTotal > RUINThemeArchiveMaxExpanded)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"ZIP exceeds 256 MiB expanded size.");

        uint64_t localHeaderEnd = (uint64_t)localOffset + 30;
        if (localHeaderEnd > centralOffset || RUINReadLE32(bytes + localOffset) != 0x04034b50)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"ZIP local header is out of bounds or malformed.");
        uint16_t localFlags = RUINReadLE16(bytes + localOffset + 6);
        uint16_t localMethod = RUINReadLE16(bytes + localOffset + 8);
        uint32_t localCRC = RUINReadLE32(bytes + localOffset + 14);
        uint32_t localCompressed = RUINReadLE32(bytes + localOffset + 18);
        uint32_t localExpanded = RUINReadLE32(bytes + localOffset + 22);
        uint16_t localNameLength = RUINReadLE16(bytes + localOffset + 26);
        uint16_t localExtraLength = RUINReadLE16(bytes + localOffset + 28);
        uint64_t dataOffset = localHeaderEnd + localNameLength + localExtraLength;
        uint64_t dataEnd = dataOffset + compressedSize;
        if (dataOffset < localHeaderEnd || dataEnd < dataOffset || dataEnd > centralOffset ||
            localFlags != flags || localMethod != method || localNameLength != nameLength ||
            memcmp(bytes + localOffset + 30, bytes + nameOffset, nameLength) != 0)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Local ZIP header disagrees with the central directory.");
        if (!RUINValidateExtraFields(bytes, localHeaderEnd + localNameLength, localExtraLength, error)) return NO;

        uint64_t rangeEnd = dataEnd;
        if (flags & 0x0008) {
            if ((localCRC && localCRC != crc) || (localCompressed && localCompressed != compressedSize) ||
                (localExpanded && localExpanded != expandedSize))
                return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Data-descriptor local fields disagree with the central directory.");
            BOOL descriptorMatches = NO;
            if ((uint64_t)centralOffset - dataEnd >= 16 && RUINReadLE32(bytes + dataEnd) == 0x08074b50 &&
                RUINReadLE32(bytes + dataEnd + 4) == crc && RUINReadLE32(bytes + dataEnd + 8) == compressedSize &&
                RUINReadLE32(bytes + dataEnd + 12) == expandedSize) {
                rangeEnd = dataEnd + 16;
                descriptorMatches = YES;
            } else if ((uint64_t)centralOffset - dataEnd >= 12 && RUINReadLE32(bytes + dataEnd) == crc &&
                       RUINReadLE32(bytes + dataEnd + 4) == compressedSize &&
                       RUINReadLE32(bytes + dataEnd + 8) == expandedSize) {
                rangeEnd = dataEnd + 12;
                descriptorMatches = YES;
            }
            if (!descriptorMatches)
                return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Malformed or inconsistent ZIP data descriptor.");
        } else if (localCRC != crc || localCompressed != compressedSize || localExpanded != expandedSize) {
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Local ZIP sizes or CRC disagree with the central directory.");
        }

        RUINThemeArchiveEntry *entry = [RUINThemeArchiveEntry new];
        entry.path = path;
        entry.flags = flags;
        entry.method = method;
        entry.crc = crc;
        entry.compressedSize = compressedSize;
        entry.expandedSize = expandedSize;
        entry.localOffset = localOffset;
        entry.dataOffset = dataOffset;
        entry.rangeEnd = rangeEnd;
        entry.directory = directory;
        [entries addObject:entry];
        cursor = (size_t)recordEnd;
    }
    if (cursor != centralEnd)
        return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"ZIP central-directory size does not match its entries.");

    NSArray<RUINThemeArchiveEntry *> *sorted = [entries sortedArrayUsingComparator:^NSComparisonResult(RUINThemeArchiveEntry *left, RUINThemeArchiveEntry *right) {
        if (left.localOffset < right.localOffset) return NSOrderedAscending;
        if (left.localOffset > right.localOffset) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    uint64_t lastEnd = 0;
    RUINThemeArchiveEntry *foundManifest = nil;
    for (RUINThemeArchiveEntry *entry in sorted) {
        if (entry.localOffset < lastEnd || entry.rangeEnd < entry.localOffset)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"ZIP local-file records overlap.");
        lastEnd = entry.rangeEnd;
        if ([entry.path isEqualToString:@"theme.json"] && !entry.isDirectory) foundManifest = entry;
    }
    if (!foundManifest)
        return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidManifest, @"ZIP has no root theme.json file.");

    *parsedEntries = entries;
    *manifestEntry = foundManifest;
    return YES;
}

static BOOL RUINProtectStagedPath(NSString *path, NSError **error)
{
#if TARGET_OS_IPHONE
    NSError *protectionError = nil;
    NSDictionary *attributes = @{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication};
    if (![[NSFileManager defaultManager] setAttributes:attributes ofItemAtPath:path error:&protectionError]) {
        if (error) *error = protectionError;
        return NO;
    }
#else
    (void)path;
    (void)error;
#endif
    return YES;
}

static void RUINRemoveDirectoryContents(int directoryFD)
{
    int enumerationFD = dup(directoryFD);
    if (enumerationFD < 0) return;
    DIR *directory = fdopendir(enumerationFD);
    if (!directory) { close(enumerationFD); return; }
    struct dirent *item;
    while ((item = readdir(directory)) != NULL) {
        if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..")) continue;
        struct stat status;
        if (fstatat(directoryFD, item->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) continue;
        if (S_ISDIR(status.st_mode)) {
            int childFD = openat(directoryFD, item->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (childFD >= 0) {
                RUINRemoveDirectoryContents(childFD);
                close(childFD);
                (void)unlinkat(directoryFD, item->d_name, AT_REMOVEDIR);
            }
        } else {
            (void)unlinkat(directoryFD, item->d_name, 0);
        }
    }
    closedir(directory);
}

static BOOL RUINWriteAll(int fileFD, const uint8_t *bytes, size_t length, NSError **error)
{
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(fileFD, bytes + written, length - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0)
            return RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Failed to write staged theme file.");
        written += (size_t)count;
    }
    return YES;
}

static int RUINOpenThemeDirectory(int parentFD, NSString *name, NSString *path, NSError **error)
{
    const char *component = name.fileSystemRepresentation;
    if (!component) {
        RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Invalid staged theme directory name.");
        return -1;
    }
    if (mkdirat(parentFD, component, 0700) != 0 && errno != EEXIST) {
        RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Failed to create staged theme directory.");
        return -1;
    }
    struct stat status;
    if (fstatat(parentFD, component, &status, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISDIR(status.st_mode)) {
        RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Staged theme path is not a new directory.");
        return -1;
    }
    int directoryFD = openat(parentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directoryFD < 0) {
        RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Failed to open staged theme directory safely.");
        return -1;
    }
    if (!RUINProtectStagedPath(path, error)) {
        close(directoryFD);
        return -1;
    }
    return directoryFD;
}

static int RUINOpenThemeParent(int stageFD,
                               NSString *stagePath,
                               NSArray<NSString *> *parts,
                               NSError **error)
{
    int currentFD = dup(stageFD);
    if (currentFD < 0) {
        RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Failed to open staged theme directory.");
        return -1;
    }
    NSMutableString *currentPath = [stagePath mutableCopy];
    for (NSUInteger index = 0; index + 1 < parts.count; index++) {
        NSString *component = parts[index];
        [currentPath appendFormat:@"/%@", component];
        int nextFD = RUINOpenThemeDirectory(currentFD, component, currentPath, error);
        close(currentFD);
        if (nextFD < 0) return -1;
        currentFD = nextFD;
    }
    return currentFD;
}

static BOOL RUINExtractThemeEntry(const RUINThemeArchiveEntry *entry,
                                  const uint8_t *archiveBytes,
                                  int stageFD,
                                  NSString *stagePath,
                                  NSError **error)
{
    NSArray<NSString *> *parts = [entry.path componentsSeparatedByString:@"/"];
    if (entry.isDirectory) {
        int currentFD = dup(stageFD);
        if (currentFD < 0) return RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Failed to open staging directory.");
        NSMutableString *currentPath = [stagePath mutableCopy];
        for (NSString *component in parts) {
            [currentPath appendFormat:@"/%@", component];
            int nextFD = RUINOpenThemeDirectory(currentFD, component, currentPath, error);
            close(currentFD);
            if (nextFD < 0) return NO;
            currentFD = nextFD;
        }
        close(currentFD);
        return YES;
    }

    int parentFD = RUINOpenThemeParent(stageFD, stagePath, parts, error);
    if (parentFD < 0) return NO;
    NSString *leaf = parts.lastObject;
    const char *leafName = leaf.fileSystemRepresentation;
    int fileFD = leafName ? openat(parentFD, leafName,
                                   O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                                   0600) : -1;
    close(parentFD);
    if (fileFD < 0)
        return RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Failed to create a new staged theme file.");

    BOOL ok = fchmod(fileFD, 0600) == 0;
    if (!ok) RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Failed to protect staged theme file permissions.");
    uint64_t total = 0;
    uLong actualCRC = crc32(0L, Z_NULL, 0);
    uint8_t output[RUINThemeArchiveChunk];

    if (ok && entry.method == 0) {
        uint64_t offset = 0;
        while (offset < entry.compressedSize) {
            size_t chunk = (size_t)MIN((uint64_t)sizeof(output), (uint64_t)entry.compressedSize - offset);
            const uint8_t *source = archiveBytes + entry.dataOffset + offset;
            if (!RUINWriteAll(fileFD, source, chunk, error)) { ok = NO; break; }
            actualCRC = crc32(actualCRC, source, (uInt)chunk);
            total += chunk;
            offset += chunk;
        }
    } else if (ok) {
        z_stream stream = {0};
        int status = inflateInit2(&stream, -MAX_WBITS);
        if (status != Z_OK) {
            ok = RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Could not initialize raw ZIP deflate stream.");
        } else {
            stream.next_in = (Bytef *)(archiveBytes + entry.dataOffset);
            stream.avail_in = (uInt)entry.compressedSize;
            do {
                stream.next_out = output;
                stream.avail_out = (uInt)sizeof(output);
                status = inflate(&stream, Z_NO_FLUSH);
                size_t produced = sizeof(output) - stream.avail_out;
                if (produced > (uint64_t)entry.expandedSize - total) {
                    ok = RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Deflate output exceeds its declared size.");
                    break;
                }
                if (produced) {
                    if (!RUINWriteAll(fileFD, output, produced, error)) { ok = NO; break; }
                    actualCRC = crc32(actualCRC, output, (uInt)produced);
                    total += produced;
                }
                if (status != Z_OK && status != Z_STREAM_END) {
                    ok = RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Invalid raw ZIP deflate stream.");
                    break;
                }
            } while (status != Z_STREAM_END);
            if (ok && (stream.total_in != entry.compressedSize || total != entry.expandedSize))
                ok = RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Deflate stream length does not match ZIP metadata.");
            inflateEnd(&stream);
        }
    }

    if (ok && (total != entry.expandedSize || (uint32_t)actualCRC != entry.crc))
        ok = RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Expanded ZIP entry size or CRC does not match.");
    NSString *destinationPath = [stagePath stringByAppendingPathComponent:entry.path];
    if (ok && !RUINProtectStagedPath(destinationPath, error)) ok = NO;
    if (close(fileFD) != 0 && ok)
        ok = RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Failed to close staged theme file.");
    return ok;
}

static BOOL RUINIsPositiveJSONInteger(id value)
{
    if (![value isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double numeric = [value doubleValue];
    return isfinite(numeric) && numeric > 0 && floor(numeric) == numeric && numeric < 9223372036854775808.0;
}

static BOOL RUINValidateThemeManifest(NSString *stagePath, NSError **error)
{
    NSString *manifestPath = [stagePath stringByAppendingPathComponent:@"theme.json"];
    NSInputStream *stream = [NSInputStream inputStreamWithFileAtPath:manifestPath];
    [stream open];
    NSError *parseError = nil;
    id document = [NSJSONSerialization JSONObjectWithStream:stream options:0 error:&parseError];
    [stream close];
    if (![document isKindOfClass:[NSDictionary class]])
        return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidManifest,
                                   parseError.localizedDescription ?: @"Root theme.json is not a JSON object.");
    id manifest = document[@"manifest"];
    if (![manifest isKindOfClass:[NSDictionary class]] ||
        !RUINIsPositiveJSONInteger(manifest[@"schemaVersion"]) ||
        !RUINIsPositiveJSONInteger(manifest[@"revision"]))
        return RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidManifest,
                                   @"theme.json needs a manifest with positive integer schemaVersion and revision.");
    return YES;
}

static void RUINCleanupStage(int rootFD, int stageFD, NSString *stageName)
{
    RUINRemoveDirectoryContents(stageFD);
    close(stageFD);
    (void)unlinkat(rootFD, stageName.fileSystemRepresentation, AT_REMOVEDIR);
}

NSURL *RUINStageThemeArchiveAtURL(NSURL *archiveURL, NSURL *trustedStagingRoot, NSError **error)
{
    if (error) *error = nil;
    if (!archiveURL.isFileURL || !trustedStagingRoot.isFileURL ||
        !archiveURL.path.length || !trustedStagingRoot.path.length) {
        RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidArgument, @"Archive and staging root must be file URLs.");
        return nil;
    }

    int archiveFD = open(archiveURL.path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (archiveFD < 0) {
        RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Could not safely open theme archive.");
        return nil;
    }
    struct stat archiveStatus;
    if (fstat(archiveFD, &archiveStatus) != 0 || !S_ISREG(archiveStatus.st_mode) ||
        archiveStatus.st_size < 22 || (uint64_t)archiveStatus.st_size > RUINThemeArchiveMaxInput) {
        close(archiveFD);
        RUINThemeArchiveFail(error, RUINThemeArchiveErrorInvalidZIP, @"Archive must be a regular file between 22 bytes and 64 MiB.");
        return nil;
    }
    size_t archiveLength = (size_t)archiveStatus.st_size;
    const uint8_t *archiveBytes = mmap(NULL, archiveLength, PROT_READ, MAP_PRIVATE, archiveFD, 0);
    if (archiveBytes == MAP_FAILED) {
        close(archiveFD);
        RUINThemeArchiveFail(error, RUINThemeArchiveErrorIO, @"Could not map bounded theme archive.");
        return nil;
    }

    NSArray<RUINThemeArchiveEntry *> *entries = nil;
    RUINThemeArchiveEntry *manifestEntry = nil;
    NSError *operationError = nil;
    BOOL ok = RUINParseThemeZIP(archiveBytes, archiveLength, &entries, &manifestEntry, &operationError);

    NSString *rootPath = trustedStagingRoot.URLByStandardizingPath.path;
    while (rootPath.length > 1 && [rootPath hasSuffix:@"/"])
        rootPath = [rootPath substringToIndex:rootPath.length - 1];
    struct stat originalRootStatus;
    char resolvedRoot[PATH_MAX];
    int rootFD = -1;
    if (ok && (lstat(rootPath.fileSystemRepresentation, &originalRootStatus) != 0 || !S_ISDIR(originalRootStatus.st_mode) ||
               !realpath(rootPath.fileSystemRepresentation, resolvedRoot))) {
        operationError = [NSError errorWithDomain:RUINThemeArchiveErrorDomain code:RUINThemeArchiveErrorIO
                                           userInfo:@{NSLocalizedDescriptionKey:@"Trusted staging root must be an existing non-symlink directory."}];
        ok = NO;
    }
    if (ok) {
        rootFD = open(resolvedRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        struct stat openedRootStatus;
        if (rootFD < 0 || fstat(rootFD, &openedRootStatus) != 0 ||
            openedRootStatus.st_dev != originalRootStatus.st_dev || openedRootStatus.st_ino != originalRootStatus.st_ino) {
            if (rootFD >= 0) close(rootFD);
            rootFD = -1;
            operationError = [NSError errorWithDomain:RUINThemeArchiveErrorDomain code:RUINThemeArchiveErrorIO
                                               userInfo:@{NSLocalizedDescriptionKey:@"Staging root changed while it was opened."}];
            ok = NO;
        }
    }

    NSString *stageName = NSUUID.UUID.UUIDString.lowercaseString;
    int stageFD = -1;
    NSString *stagePath = nil;
    if (ok && mkdirat(rootFD, stageName.fileSystemRepresentation, 0700) != 0) {
        operationError = [NSError errorWithDomain:RUINThemeArchiveErrorDomain code:RUINThemeArchiveErrorIO
                                           userInfo:@{NSLocalizedDescriptionKey:@"Could not create a new UUID staging directory."}];
        ok = NO;
    }
    if (ok) {
        stageFD = openat(rootFD, stageName.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (stageFD < 0) {
            (void)unlinkat(rootFD, stageName.fileSystemRepresentation, AT_REMOVEDIR);
            operationError = [NSError errorWithDomain:RUINThemeArchiveErrorDomain code:RUINThemeArchiveErrorIO
                                               userInfo:@{NSLocalizedDescriptionKey:@"Could not safely open the UUID staging directory."}];
            ok = NO;
        }
    }
    if (ok) {
        stagePath = [NSString stringWithFormat:@"%s/%@", resolvedRoot, stageName];
        if (!RUINProtectStagedPath(stagePath, &operationError)) ok = NO;
    }

    if (ok && !RUINExtractThemeEntry(manifestEntry, archiveBytes, stageFD, stagePath, &operationError)) ok = NO;
    if (ok && !RUINValidateThemeManifest(stagePath, &operationError)) ok = NO;
    for (RUINThemeArchiveEntry *entry in entries) {
        if (!ok) break;
        if (entry == manifestEntry) continue;
        if (!RUINExtractThemeEntry(entry, archiveBytes, stageFD, stagePath, &operationError)) ok = NO;
    }

    NSURL *result = nil;
    if (ok) {
        result = [NSURL fileURLWithPath:stagePath isDirectory:YES];
        close(stageFD);
    } else if (stageFD >= 0) {
        RUINCleanupStage(rootFD, stageFD, stageName);
    }
    if (rootFD >= 0) close(rootFD);
    munmap((void *)archiveBytes, archiveLength);
    close(archiveFD);
    if (!ok && error) *error = operationError ?: [NSError errorWithDomain:RUINThemeArchiveErrorDomain
                                                                       code:RUINThemeArchiveErrorIO
                                                                   userInfo:@{NSLocalizedDescriptionKey:@"Theme archive staging failed."}];
    return result;
}
