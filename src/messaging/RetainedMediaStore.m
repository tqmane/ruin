#import "RetainedMediaStore.h"
#import <CommonCrypto/CommonDigest.h>
#import <CoreFoundation/CoreFoundation.h>
#import <TargetConditionals.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

static NSString *const RUINRetainedMediaErrorDomain = @"RUINRetainedMediaStore";
static const NSUInteger RUINMaxKeyCharacters = 1024;
static const size_t RUINMaxMetadataBytes = 16384;
static const size_t RUINMaxMarkerBytes = 4096;

static NSArray<NSString *> *RUINMediaRoles(void) {
    return @[@"photo", @"video", @"audio", @"file", @"thumbnail", @"livePhoto"];
}

static NSError *RUINRetainedMediaError(void) {
    return [NSError errorWithDomain:RUINRetainedMediaErrorDomain code:1 userInfo:nil];
}

static BOOL RUINValidText(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length > RUINMaxKeyCharacters)
        return NO;
    for (NSUInteger i = 0; i < value.length; i++) if ([value characterAtIndex:i] == 0) return NO;
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    return utf8 != nil && utf8.length <= RUINMaxKeyCharacters * 4;
}

static NSDictionary<NSString *, NSString *> *RUINCopyMessageKey(NSDictionary *key) {
    if (![key isKindOfClass:NSDictionary.class] || (key.count != 4 && key.count != 5)) return nil;
    for (id field in key) {
        if (![field isKindOfClass:NSString.class] ||
            ![@[@"store", @"kind", @"chat", @"message", @"sender"] containsObject:field]) return nil;
    }
    id store = key[@"store"], kind = key[@"kind"], chat = key[@"chat"], message = key[@"message"];
    if (!RUINValidText(store) || !RUINValidText(kind) || !RUINValidText(chat) ||
        ![@[@"talk", @"square"] containsObject:kind] || ![message isKindOfClass:NSString.class] ||
        (key[@"sender"] && !RUINValidText(key[@"sender"]))) return nil;
    NSString *messageString = message;
    if (!messageString.length || messageString.length > 19) return nil;
    unsigned long long number = 0;
    for (NSUInteger i = 0; i < messageString.length; i++) {
        unichar digit = [messageString characterAtIndex:i];
        if (digit < '0' || digit > '9' || number > (LLONG_MAX - (digit - '0')) / 10) return nil;
        number = number * 10 + digit - '0';
    }
    if (!number || (messageString.length > 1 && [messageString characterAtIndex:0] == '0')) return nil;
    return @{@"store":[store copy], @"kind":[kind copy], @"chat":[chat copy], @"message":[messageString copy]};
}

static NSString *RUINScopeName(NSDictionary<NSString *, NSString *> *key) {
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:@[key[@"store"], key[@"kind"], key[@"chat"], key[@"message"]]
                                                   options:0 error:nil];
    if (!bytes) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *name = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [name appendFormat:@"%02x", digest[i]];
    return name;
}

static NSString *RUINSafeExtension(NSString *extension) {
    if (![extension isKindOfClass:NSString.class]) return nil;
    NSString *value = [extension hasPrefix:@"."] ? [extension substringFromIndex:1] : extension;
    if (!value.length || value.length > 16) return nil;
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))) return nil;
    }
    return value.lowercaseString;
}

static BOOL RUINIsDirectoryMode(const struct stat *status, mode_t mode) {
    return S_ISDIR(status->st_mode) && (status->st_mode & 0777) == mode;
}

static BOOL RUINIsRegularMode(const struct stat *status, mode_t mode) {
    return S_ISREG(status->st_mode) && (status->st_mode & 0777) == mode && status->st_size >= 0;
}

static BOOL RUINProtectPath(NSString *path) {
#if TARGET_OS_IPHONE
    return [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}
                                          ofItemAtPath:path error:nil];
#else
    (void)path;
    return YES;
#endif
}

static BOOL RUINPathIsWithinRoot(const char *path, const char *root) {
    size_t length = strlen(root);
    if (length == 1 && root[0] == '/') return path[0] == '/' && path[1] != '\0';
    return strncmp(path, root, length) == 0 && path[length] == '/';
}

static int RUINOpenRelativeFile(int rootFD, const char *relativePath) {
    char *components = strdup(relativePath);
    if (!components) return -1;
    char *save = NULL;
    char *part = strtok_r(components, "/", &save);
    int currentFD = dup(rootFD);
    if (currentFD < 0) { free(components); return -1; }
    int result = -1;
    while (part) {
        if (!strcmp(part, ".") || !strcmp(part, "..") || !part[0]) break;
        char *next = strtok_r(NULL, "/", &save);
        if (!next) {
            result = openat(currentFD, part, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
            break;
        }
        int nextFD = openat(currentFD, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (nextFD < 0) break;
        close(currentFD);
        currentFD = nextFD;
        part = next;
    }
    close(currentFD);
    free(components);
    return result;
}

static int RUINOpenAllowedSource(NSURL *source, NSArray<NSURL *> *roots) {
    if (![source isKindOfClass:NSURL.class] || !source.isFileURL ||
        ![roots isKindOfClass:NSArray.class]) return -1;
    char canonicalSource[PATH_MAX];
    if (!realpath(source.fileSystemRepresentation, canonicalSource)) return -1;

    for (id root in roots) {
        if (![root isKindOfClass:NSURL.class] || ![root isFileURL]) continue;
        char canonicalRoot[PATH_MAX];
        if (!realpath([root fileSystemRepresentation], canonicalRoot) ||
            !RUINPathIsWithinRoot(canonicalSource, canonicalRoot)) continue;
        int rootFD = open(canonicalRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (rootFD < 0) continue;
        const char *relative = canonicalSource + strlen(canonicalRoot);
        while (*relative == '/') relative++;
        int sourceFD = RUINOpenRelativeFile(rootFD, relative);
        close(rootFD);
        if (sourceFD < 0) continue;
        struct stat status;
        if (fstat(sourceFD, &status) == 0 && S_ISREG(status.st_mode) && status.st_size >= 0) return sourceFD;
        close(sourceFD);
    }
    return -1;
}

// LINE thumbnails use .thumb, and a received PNG may be stored as .jpg.
// Detect image type from the already validated descriptor so Quick Look gets
// the real type without reopening an untrusted path or loading a large asset.
static NSString *RUINImageExtension(int sourceFD) {
    NSMutableData *header = [NSMutableData dataWithLength:65536];
    ssize_t size = pread(sourceFD, header.mutableBytes, header.length, 0);
    if (size <= 0) return nil;
    header.length = (NSUInteger)size;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)header, NULL);
    CFStringRef identifier = source ? CGImageSourceGetType(source) : NULL;
    NSString *extension = identifier ? [UTType typeWithIdentifier:(__bridge NSString *)identifier].preferredFilenameExtension : nil;
    if (source) CFRelease(source);
    return RUINSafeExtension(extension);
}

static BOOL RUINWriteAll(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        cursor += written;
        length -= (size_t)written;
    }
    return YES;
}

static BOOL RUINCopyStableFile(int sourceFD, int destinationFD, unsigned long long *byteCount) {
    struct stat before, after;
    if (fstat(sourceFD, &before) != 0 || !S_ISREG(before.st_mode) || before.st_size < 0) return NO;
    uint8_t buffer[64 * 1024];
    off_t offset = 0;
    while (offset < before.st_size) {
        off_t remaining = before.st_size - offset;
        size_t requested = remaining < (off_t)sizeof(buffer) ? (size_t)remaining : sizeof(buffer);
        ssize_t count = pread(sourceFD, buffer, requested, offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || !RUINWriteAll(destinationFD, buffer, (size_t)count)) return NO;
        offset += count;
    }
    if (fstat(sourceFD, &after) != 0 || !S_ISREG(after.st_mode) ||
        before.st_size != after.st_size ||
        before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
        before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
        offset != before.st_size) return NO;
    *byteCount = (unsigned long long)offset;
    return YES;
}

static BOOL RUINWriteData(NSData *data, int destinationFD, unsigned long long *byteCount) {
    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;
    size_t offset = 0;
    while (remaining) {
        size_t chunk = remaining < 64 * 1024 ? remaining : 64 * 1024;
        if (!RUINWriteAll(destinationFD, bytes + offset, chunk)) return NO;
        offset += chunk;
        remaining -= chunk;
    }
    *byteCount = (unsigned long long)data.length;
    return YES;
}

static int RUINOpenScope(int rootFD, const char *scopeName, BOOL create) {
    if (create && mkdirat(rootFD, scopeName, 0700) != 0 && errno != EEXIST) return -1;
    int fd = openat(rootFD, scopeName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat status;
    if (fstat(fd, &status) != 0 || !S_ISDIR(status.st_mode) ||
        (create && fchmod(fd, 0700) != 0)) {
        close(fd);
        return -1;
    }
    return fd;
}

static BOOL RUINInteger(id value, unsigned long long *result) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    const char *type = [value objCType];
    if (!type || !strchr("csilqCSILQ", type[0])) return NO;
    long long signedValue = [value longLongValue];
    if (signedValue < 0) return NO;
    *result = (unsigned long long)signedValue;
    return YES;
}

static BOOL RUINRoleContainsOnly(int roleFD, NSString *assetName) {
    int duplicateFD = dup(roleFD);
    if (duplicateFD < 0) return NO;
    DIR *directory = fdopendir(duplicateFD);
    if (!directory) { close(duplicateFD); return NO; }
    NSUInteger count = 0;
    BOOL valid = YES;
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (strcmp(entry->d_name, "metadata.plist") && strcmp(entry->d_name, assetName.UTF8String)) {
            valid = NO;
            break;
        }
        count++;
    }
    closedir(directory);
    return valid && count == 2;
}

static NSData *RUINReadMetadata(int fd, const struct stat *status, size_t maximumBytes) {
    if (!RUINIsRegularMode(status, 0600) || status->st_size <= 0 ||
        (uint64_t)status->st_size > maximumBytes) return nil;
    NSMutableData *data = [NSMutableData dataWithCapacity:(NSUInteger)status->st_size];
    uint8_t buffer[1024];
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 || (size_t)data.length + (count > 0 ? (size_t)count : 0) > maximumBytes)
            return nil;
        if (!count) break;
        [data appendBytes:buffer length:(NSUInteger)count];
    }
    return data;
}

static BOOL RUINIsUnsentAtScope(int scopeFD) {
    int markerFD = openat(scopeFD, "unsent.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (markerFD < 0) return NO;
    struct stat markerStatus;
    NSData *data = fstat(markerFD, &markerStatus) == 0
        ? RUINReadMetadata(markerFD, &markerStatus, RUINMaxMarkerBytes) : nil;
    close(markerFD);
    NSDictionary *marker = data ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:nil] : nil;
    unsigned long long version = 0;
    return [marker isKindOfClass:NSDictionary.class] && marker.count == 2 &&
        RUINInteger(marker[@"version"], &version) && version == 1 &&
        [marker[@"state"] isKindOfClass:NSString.class] && [marker[@"state"] isEqualToString:@"unsent"];
}

static BOOL RUINWriteUnsentMarker(int rootFD, NSString *rootPath, NSString *scopeName) {
    int scopeFD = RUINOpenScope(rootFD, scopeName.UTF8String, YES);
    if (scopeFD < 0) return NO;
    NSString *scopePath = [rootPath stringByAppendingPathComponent:scopeName];
    if (!RUINProtectPath(scopePath)) { close(scopeFD); return NO; }
    struct stat existing;
    if (fstatat(scopeFD, "unsent.plist", &existing, AT_SYMLINK_NOFOLLOW) == 0) {
        BOOL alreadyMarked = RUINIsUnsentAtScope(scopeFD);
        close(scopeFD);
        return alreadyMarked;
    }
    if (errno != ENOENT) { close(scopeFD); return NO; }

    NSString *temporaryName = [@".unsent-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    char temporary[64];
    if (!temporaryName.UTF8String || strlen(temporaryName.UTF8String) >= sizeof(temporary)) {
        close(scopeFD);
        return NO;
    }
    strlcpy(temporary, temporaryName.UTF8String, sizeof(temporary));
    int markerFD = openat(scopeFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (markerFD < 0) { close(scopeFD); return NO; }
    struct stat markerIdentity;
    BOOL hasIdentity = fstat(markerFD, &markerIdentity) == 0 && S_ISREG(markerIdentity.st_mode);
    NSString *markerPath = [scopePath stringByAppendingPathComponent:temporaryName];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"version":@1, @"state":@"unsent"}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    BOOL written = data && data.length <= RUINMaxMarkerBytes && fchmod(markerFD, 0600) == 0 &&
        RUINProtectPath(markerPath) && RUINWriteAll(markerFD, data.bytes, data.length) && fsync(markerFD) == 0;
    close(markerFD);
    BOOL marked = NO, published = NO;
    if (written && fsync(scopeFD) == 0) {
        if (renameatx_np(scopeFD, temporary, scopeFD, "unsent.plist", RENAME_EXCL) == 0) {
            published = YES;
            marked = fsync(scopeFD) == 0;
        } else if (errno == EEXIST) {
            marked = RUINIsUnsentAtScope(scopeFD);
        }
    }
    if (!published && hasIdentity) {
        struct stat current;
        if (fstatat(scopeFD, temporary, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
            current.st_dev == markerIdentity.st_dev && current.st_ino == markerIdentity.st_ino && S_ISREG(current.st_mode))
            unlinkat(scopeFD, temporary, 0);
    }
    close(scopeFD);
    return marked;
}

static NSDictionary<NSString *, id> *RUINReadRole(int scopeFD,
                                                   NSString *rootPath,
                                                   NSString *scopeName,
                                                   NSString *role) {
    int roleFD = openat(scopeFD, role.UTF8String, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (roleFD < 0) return nil;
    struct stat roleStatus;
    if (fstat(roleFD, &roleStatus) != 0 || !RUINIsDirectoryMode(&roleStatus, 0700)) {
        close(roleFD);
        return nil;
    }
    int metadataFD = openat(roleFD, "metadata.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat metadataStatus;
    NSData *metadataData = nil;
    if (metadataFD >= 0 && fstat(metadataFD, &metadataStatus) == 0)
        metadataData = RUINReadMetadata(metadataFD, &metadataStatus, RUINMaxMetadataBytes);
    if (metadataFD >= 0) close(metadataFD);
    NSDictionary *metadata = metadataData ? [NSPropertyListSerialization propertyListWithData:metadataData
        options:NSPropertyListImmutable format:nil error:nil] : nil;
    if (![metadata isKindOfClass:NSDictionary.class] || metadata.count != 5 ||
        ![metadata[@"role"] isKindOfClass:NSString.class] || ![metadata[@"role"] isEqualToString:role] ||
        ![metadata[@"filename"] isKindOfClass:NSString.class] ||
        ![metadata[@"type"] isKindOfClass:NSString.class]) {
        close(roleFD);
        return nil;
    }
    unsigned long long version = 0, expectedSize = 0;
    NSString *type = RUINSafeExtension(metadata[@"type"]);
    NSString *filename = metadata[@"filename"];
    if (!RUINInteger(metadata[@"version"], &version) || version != 1 || !type ||
        ![type isEqualToString:metadata[@"type"]] ||
        ![filename isEqualToString:[@"asset." stringByAppendingString:type]] ||
        !RUINInteger(metadata[@"byteCount"], &expectedSize) ||
        !RUINRoleContainsOnly(roleFD, filename)) {
        close(roleFD);
        return nil;
    }
    int assetFD = openat(roleFD, filename.UTF8String, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat assetStatus;
    BOOL validAsset = assetFD >= 0 && fstat(assetFD, &assetStatus) == 0 &&
        RUINIsRegularMode(&assetStatus, 0600) && (unsigned long long)assetStatus.st_size == expectedSize;
    if (assetFD >= 0) close(assetFD);
    close(roleFD);
    if (!validAsset) return nil;
    NSURL *url = [[NSURL fileURLWithPath:rootPath isDirectory:YES]
        URLByAppendingPathComponent:scopeName isDirectory:YES];
    url = [url URLByAppendingPathComponent:role isDirectory:YES];
    url = [url URLByAppendingPathComponent:filename isDirectory:NO];
    return @{@"role":role, @"URL":url, @"byteCount":@(expectedSize)};
}

static void RUINRemoveStage(int scopeFD,
                            const char *stageName,
                            int stageFD,
                            const char *assetName,
                            const struct stat *assetIdentity,
                            const struct stat *metadataIdentity) {
    if (stageFD < 0) return;
    struct stat current;
    if (metadataIdentity && fstatat(stageFD, "metadata.plist", &current, AT_SYMLINK_NOFOLLOW) == 0 &&
        current.st_dev == metadataIdentity->st_dev && current.st_ino == metadataIdentity->st_ino && S_ISREG(current.st_mode))
        unlinkat(stageFD, "metadata.plist", 0);
    if (assetIdentity && fstatat(stageFD, assetName, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
        current.st_dev == assetIdentity->st_dev && current.st_ino == assetIdentity->st_ino && S_ISREG(current.st_mode))
        unlinkat(stageFD, assetName, 0);
    struct stat opened, stagePathStatus;
    if (fstat(stageFD, &opened) == 0 && fstatat(scopeFD, stageName, &stagePathStatus, AT_SYMLINK_NOFOLLOW) == 0 &&
        opened.st_dev == stagePathStatus.st_dev && opened.st_ino == stagePathStatus.st_ino && S_ISDIR(stagePathStatus.st_mode))
        unlinkat(scopeFD, stageName, AT_REMOVEDIR);
}

static BOOL RUINCommit(int rootFD,
                       NSString *rootPath,
                       NSString *scopeName,
                       NSString *role,
                       NSString *extension,
                       BOOL (^writer)(int destinationFD, unsigned long long *byteCount)) {
    int scopeFD = RUINOpenScope(rootFD, scopeName.UTF8String, YES);
    if (scopeFD < 0) return NO;
    NSString *scopePath = [rootPath stringByAppendingPathComponent:scopeName];
    if (!RUINProtectPath(scopePath)) { close(scopeFD); return NO; }
    struct stat existingRole;
    if (fstatat(scopeFD, role.UTF8String, &existingRole, AT_SYMLINK_NOFOLLOW) == 0) {
        BOOL alreadyCommitted = RUINReadRole(scopeFD, rootPath, scopeName, role) != nil;
        close(scopeFD);
        return alreadyCommitted;
    }
    if (errno != ENOENT) { close(scopeFD); return NO; }

    NSString *stageNameString = [@".staging-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    char stageName[64];
    if (!stageNameString.UTF8String || strlen(stageNameString.UTF8String) >= sizeof(stageName)) {
        close(scopeFD);
        return NO;
    }
    strlcpy(stageName, stageNameString.UTF8String, sizeof(stageName));
    if (mkdirat(scopeFD, stageName, 0700) != 0) { close(scopeFD); return NO; }
    struct stat createdStage;
    if (fstatat(scopeFD, stageName, &createdStage, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISDIR(createdStage.st_mode)) {
        close(scopeFD);
        return NO;
    }
    int stageFD = openat(scopeFD, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (stageFD < 0) {
        struct stat current;
        if (fstatat(scopeFD, stageName, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
            createdStage.st_dev == current.st_dev && createdStage.st_ino == current.st_ino && S_ISDIR(current.st_mode))
            unlinkat(scopeFD, stageName, AT_REMOVEDIR);
        close(scopeFD);
        return NO;
    }
    struct stat openedStage;
    if (fstat(stageFD, &openedStage) != 0 || openedStage.st_dev != createdStage.st_dev ||
        openedStage.st_ino != createdStage.st_ino) {
        close(stageFD);
        close(scopeFD);
        return NO;
    }
    BOOL success = NO, published = NO;
    int assetFD = -1, metadataFD = -1;
    struct stat assetIdentity, metadataIdentity;
    BOOL hasAssetIdentity = NO, hasMetadataIdentity = NO;
    unsigned long long byteCount = 0;
    char assetName[32] = {0};
    int nameLength = snprintf(assetName, sizeof(assetName), "asset.%s", extension.UTF8String);
    NSString *stagePath = [scopePath stringByAppendingPathComponent:stageNameString];
    if (nameLength > 0 && (size_t)nameLength < sizeof(assetName) && fchmod(stageFD, 0700) == 0 &&
        RUINProtectPath(stagePath)) {
        assetFD = openat(stageFD, assetName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (assetFD >= 0) {
            hasAssetIdentity = fstat(assetFD, &assetIdentity) == 0 && S_ISREG(assetIdentity.st_mode);
            NSString *assetPath = [stagePath stringByAppendingPathComponent:[NSString stringWithUTF8String:assetName]];
            BOOL wrote = fchmod(assetFD, 0600) == 0 && RUINProtectPath(assetPath) && writer(assetFD, &byteCount);
            if (wrote && fsync(assetFD) == 0) {
                NSDictionary *properties = @{@"version":@1, @"role":role, @"filename":[NSString stringWithUTF8String:assetName],
                    @"type":extension, @"byteCount":@(byteCount)};
                NSData *metadata = [NSPropertyListSerialization dataWithPropertyList:properties
                    format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
                if (metadata && metadata.length <= RUINMaxMetadataBytes) {
                    metadataFD = openat(stageFD, "metadata.plist", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
                    if (metadataFD >= 0) {
                        hasMetadataIdentity = fstat(metadataFD, &metadataIdentity) == 0 && S_ISREG(metadataIdentity.st_mode);
                        NSString *metadataPath = [stagePath stringByAppendingPathComponent:@"metadata.plist"];
                        BOOL wroteMetadata = fchmod(metadataFD, 0600) == 0 && RUINProtectPath(metadataPath) &&
                            RUINWriteAll(metadataFD, metadata.bytes, metadata.length) && fsync(metadataFD) == 0;
                        if (wroteMetadata && fsync(stageFD) == 0) {
                            if (renameatx_np(scopeFD, stageName, scopeFD, role.UTF8String, RENAME_EXCL) == 0) {
                                published = YES;
                                success = YES;
                                fsync(scopeFD);
                            } else if (errno == EEXIST) {
                                success = RUINReadRole(scopeFD, rootPath, scopeName, role) != nil;
                            }
                        }
                    }
                }
            }
        }
    }
    if (metadataFD >= 0) close(metadataFD);
    if (assetFD >= 0) close(assetFD);
    if (!published) RUINRemoveStage(scopeFD, stageName, stageFD, assetName,
                                    hasAssetIdentity ? &assetIdentity : NULL,
                                    hasMetadataIdentity ? &metadataIdentity : NULL);
    close(stageFD);
    close(scopeFD);
    return success;
}

@implementation RUINRetainedMediaStore {
    int _rootFD;
    NSString *_rootPath;
    dispatch_queue_t _queue;
    os_unfair_lock _cacheLock;
    NSMutableSet<NSString *> *_cachedScopeNames;
    BOOL _scopeCacheValid;
    time_t _cachedMtimeSec;
    long _cachedMtimeNsec;
    nlink_t _cachedNlink;
    atomic_uint_fast64_t _capturesAccepted;
    atomic_uint_fast64_t _capturesSucceeded;
    atomic_uint_fast64_t _capturesFailed;
    atomic_uint_fast64_t _itemQueries;
    atomic_uint_fast64_t _itemsReturned;
    atomic_uint_fast64_t _unsentMarkAttempts;
    atomic_uint_fast64_t _unsentMarkSuccesses;
    atomic_uint_fast64_t _unsentQueries;
}

- (nullable instancetype)initWithDirectoryURL:(NSURL *)directoryURL error:(NSError **)error {
    if (error) *error = nil;
    if (!(self = [super init])) return nil;
    _rootFD = -1;
    if (![directoryURL isKindOfClass:NSURL.class] || !directoryURL.isFileURL ||
        [directoryURL.standardizedURL.path isEqualToString:@"/"]) {
        if (error) *error = RUINRetainedMediaError();
        return nil;
    }
    NSURL *standardURL = directoryURL.standardizedURL;
    NSString *path = standardURL.path;
    struct stat status;
    if (lstat(path.fileSystemRepresentation, &status) == 0) {
        if (S_ISLNK(status.st_mode) || !S_ISDIR(status.st_mode)) {
            if (error) *error = RUINRetainedMediaError();
            return nil;
        }
    } else if (errno == ENOENT) {
        if (![NSFileManager.defaultManager createDirectoryAtURL:standardURL
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]) {
            if (error) *error = RUINRetainedMediaError();
            return nil;
        }
    } else {
        if (error) *error = RUINRetainedMediaError();
        return nil;
    }
    if (lstat(path.fileSystemRepresentation, &status) != 0 || S_ISLNK(status.st_mode) || !S_ISDIR(status.st_mode)) {
        if (error) *error = RUINRetainedMediaError();
        return nil;
    }
    char canonical[PATH_MAX];
    if (!realpath(path.fileSystemRepresentation, canonical)) {
        if (error) *error = RUINRetainedMediaError();
        return nil;
    }
    int rootFD = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat opened, requested;
    if (rootFD < 0 || fstat(rootFD, &opened) != 0 || lstat(path.fileSystemRepresentation, &requested) != 0 ||
        S_ISLNK(requested.st_mode) || opened.st_dev != requested.st_dev || opened.st_ino != requested.st_ino ||
        fchmod(rootFD, 0700) != 0 || !RUINProtectPath([NSString stringWithUTF8String:canonical])) {
        if (rootFD >= 0) close(rootFD);
        if (error) *error = RUINRetainedMediaError();
        return nil;
    }
    _rootFD = rootFD;
    _rootPath = [[NSString stringWithUTF8String:canonical] copy];
    _cacheLock = OS_UNFAIR_LOCK_INIT;
    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    _queue = dispatch_queue_create("com.ruin.retained-media", attributes);
    atomic_init(&_capturesAccepted, 0);
    atomic_init(&_capturesSucceeded, 0);
    atomic_init(&_capturesFailed, 0);
    atomic_init(&_itemQueries, 0);
    atomic_init(&_itemsReturned, 0);
    atomic_init(&_unsentMarkAttempts, 0);
    atomic_init(&_unsentMarkSuccesses, 0);
    atomic_init(&_unsentQueries, 0);
    return self;
}

- (void)dealloc {
    if (_rootFD >= 0) close(_rootFD);
}

- (void)rejectWithCompletion:(void (^ _Nullable)(BOOL success))completion {
    atomic_fetch_add_explicit(&_capturesFailed, 1, memory_order_relaxed);
    if (!completion) return;
    void (^callback)(BOOL) = [completion copy];
    dispatch_async(_queue, ^{
        @try { callback(NO); }
        @catch (__unused NSException *exception) { }
    });
}

- (void)invalidateScopeCache {
    os_unfair_lock_lock(&_cacheLock);
    _scopeCacheValid = NO;
    os_unfair_lock_unlock(&_cacheLock);
}

- (BOOL)refreshAndHasScope:(nullable NSString *)scopeName {
    struct stat st;
    if (fstat(_rootFD, &st) != 0) return YES;
    os_unfair_lock_lock(&_cacheLock);
    @try {
        if (!_scopeCacheValid ||
            st.st_mtimespec.tv_sec != _cachedMtimeSec ||
            st.st_mtimespec.tv_nsec != _cachedMtimeNsec ||
            st.st_nlink != _cachedNlink) {
            int scanFD = openat(_rootFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            DIR *dir = scanFD >= 0 ? fdopendir(scanFD) : NULL;
            if (!dir) {
                if (scanFD >= 0) close(scanFD);
                _scopeCacheValid = NO;
                return YES;
            }
            NSMutableSet<NSString *> *names = [NSMutableSet set];
            struct dirent *entry = NULL;
            while ((entry = readdir(dir)) != NULL) {
                if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
                if (entry->d_type != DT_DIR && entry->d_type != DT_UNKNOWN) continue;
                NSString *name = [NSString stringWithUTF8String:entry->d_name];
                if (name) [names addObject:name];
            }
            closedir(dir);
            _cachedScopeNames = names;
            _cachedMtimeSec = st.st_mtimespec.tv_sec;
            _cachedMtimeNsec = st.st_mtimespec.tv_nsec;
            _cachedNlink = st.st_nlink;
            _scopeCacheValid = YES;
        }
        return scopeName ? [_cachedScopeNames containsObject:scopeName] : (_cachedScopeNames.count > 0);
    } @finally {
        os_unfair_lock_unlock(&_cacheLock);
    }
}

- (BOOL)hasAnyScopes {
    return [self refreshAndHasScope:nil];
}

- (void)finishCapture:(BOOL)success completion:(void (^ _Nullable)(BOOL success))completion {
    if (success) [self invalidateScopeCache];
    atomic_fetch_add_explicit(success ? &_capturesSucceeded : &_capturesFailed, 1, memory_order_relaxed);
    if (!completion) return;
    @try { completion(success); }
    @catch (__unused NSException *exception) { }
}

- (BOOL)captureURL:(NSURL *)source
      allowedRoots:(NSArray<NSURL *> *)roots
            forKey:(NSDictionary *)key
              role:(NSString *)role
        completion:(void (^)(BOOL success))completion {
    NSDictionary *copiedKey = RUINCopyMessageKey(key);
    NSString *scopeName = copiedKey ? RUINScopeName(copiedKey) : nil;
    NSString *safeRole = [role isKindOfClass:NSString.class] && [RUINMediaRoles() containsObject:role] ? [role copy] : nil;
    NSString *extension = [source isKindOfClass:NSURL.class] ? RUINSafeExtension(source.pathExtension) : nil;
    if (!extension) extension = @"bin";
    int sourceFD = copiedKey && scopeName && safeRole ? RUINOpenAllowedSource(source, roots) : -1;
    struct stat sourceStatus;
    if (sourceFD < 0 || (fstat(sourceFD, &sourceStatus) == 0 && sourceStatus.st_size == 0 && ![safeRole isEqual:@"file"])) {
        if (sourceFD >= 0) close(sourceFD);
        [self rejectWithCompletion:completion];
        return NO;
    }
    if ([@[@"photo", @"thumbnail"] containsObject:safeRole]) extension = RUINImageExtension(sourceFD) ?: extension;
    void (^callback)(BOOL) = [completion copy];
    atomic_fetch_add_explicit(&_capturesAccepted, 1, memory_order_relaxed);
    dispatch_async(_queue, ^{
        BOOL success = NO;
        @try {
            success = RUINCommit(self->_rootFD, self->_rootPath, scopeName, safeRole, extension,
                ^BOOL(int destinationFD, unsigned long long *byteCount) {
                    return RUINCopyStableFile(sourceFD, destinationFD, byteCount);
                });
        } @catch (__unused NSException *exception) { success = NO; }
        close(sourceFD);
        [self finishCapture:success completion:callback];
    });
    return YES;
}

- (BOOL)captureData:(NSData *)data
          extension:(NSString *)extension
             forKey:(NSDictionary *)key
               role:(NSString *)role
         completion:(void (^)(BOOL success))completion {
    NSDictionary *copiedKey = RUINCopyMessageKey(key);
    NSString *scopeName = copiedKey ? RUINScopeName(copiedKey) : nil;
    NSString *safeExtension = RUINSafeExtension(extension);
    NSString *safeRole = [role isKindOfClass:NSString.class] && [RUINMediaRoles() containsObject:role] ? [role copy] : nil;
    if (!copiedKey || !scopeName || !safeExtension || !safeRole || ![data isKindOfClass:NSData.class]) {
        [self rejectWithCompletion:completion];
        return NO;
    }
    NSData *copiedData = [data copy];
    void (^callback)(BOOL) = [completion copy];
    atomic_fetch_add_explicit(&_capturesAccepted, 1, memory_order_relaxed);
    dispatch_async(_queue, ^{
        BOOL success = NO;
        @try {
            success = RUINCommit(self->_rootFD, self->_rootPath, scopeName, safeRole, safeExtension,
                ^BOOL(int destinationFD, unsigned long long *byteCount) {
                    return RUINWriteData(copiedData, destinationFD, byteCount);
                });
        } @catch (__unused NSException *exception) { success = NO; }
        [self finishCapture:success completion:callback];
    });
    return YES;
}

- (BOOL)markUnsentForKey:(NSDictionary *)key {
    atomic_fetch_add_explicit(&_unsentMarkAttempts, 1, memory_order_relaxed);
    NSDictionary *copiedKey = RUINCopyMessageKey(key);
    NSString *scopeName = copiedKey ? RUINScopeName(copiedKey) : nil;
    BOOL marked = scopeName && RUINWriteUnsentMarker(_rootFD, _rootPath, scopeName);
    if (marked) {
        [self invalidateScopeCache];
        atomic_fetch_add_explicit(&_unsentMarkSuccesses, 1, memory_order_relaxed);
    }
    return marked;
}

- (BOOL)isUnsentForKey:(NSDictionary *)key {
    atomic_fetch_add_explicit(&_unsentQueries, 1, memory_order_relaxed);
    if (![self refreshAndHasScope:nil]) return NO;
    NSDictionary *copiedKey = RUINCopyMessageKey(key);
    NSString *scopeName = copiedKey ? RUINScopeName(copiedKey) : nil;
    if (!scopeName || ![self refreshAndHasScope:scopeName]) return NO;
    int scopeFD = RUINOpenScope(_rootFD, scopeName.UTF8String, NO);
    if (scopeFD < 0) return NO;
    struct stat status;
    BOOL marked = fstat(scopeFD, &status) == 0 && RUINIsDirectoryMode(&status, 0700) &&
        RUINIsUnsentAtScope(scopeFD);
    close(scopeFD);
    return marked;
}

- (NSArray<NSDictionary<NSString *,id> *> *)itemsForKey:(NSDictionary *)key {
    atomic_fetch_add_explicit(&_itemQueries, 1, memory_order_relaxed);
    if (![self refreshAndHasScope:nil]) return @[];
    NSDictionary *copiedKey = RUINCopyMessageKey(key);
    NSString *scopeName = copiedKey ? RUINScopeName(copiedKey) : nil;
    if (!scopeName || ![self refreshAndHasScope:scopeName]) return @[];
    int scopeFD = RUINOpenScope(_rootFD, scopeName.UTF8String, NO);
    if (scopeFD < 0) return @[];
    struct stat scopeStatus;
    if (fstat(scopeFD, &scopeStatus) != 0 || !RUINIsDirectoryMode(&scopeStatus, 0700)) {
        close(scopeFD);
        return @[];
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *items = [NSMutableArray array];
    for (NSString *role in RUINMediaRoles()) {
        NSDictionary *item = RUINReadRole(scopeFD, _rootPath, scopeName, role);
        if (item) [items addObject:item];
    }
    close(scopeFD);
    atomic_fetch_add_explicit(&_itemsReturned, (uint64_t)items.count, memory_order_relaxed);
    return [items copy];
}

- (NSDictionary<NSString *,NSNumber *> *)diagnostics {
    return @{@"capturesAccepted":@(atomic_load_explicit(&_capturesAccepted, memory_order_relaxed)),
             @"capturesSucceeded":@(atomic_load_explicit(&_capturesSucceeded, memory_order_relaxed)),
             @"capturesFailed":@(atomic_load_explicit(&_capturesFailed, memory_order_relaxed)),
             @"itemQueries":@(atomic_load_explicit(&_itemQueries, memory_order_relaxed)),
             @"itemsReturned":@(atomic_load_explicit(&_itemsReturned, memory_order_relaxed)),
             @"unsentMarkAttempts":@(atomic_load_explicit(&_unsentMarkAttempts, memory_order_relaxed)),
             @"unsentMarkSuccesses":@(atomic_load_explicit(&_unsentMarkSuccesses, memory_order_relaxed)),
             @"unsentQueries":@(atomic_load_explicit(&_unsentQueries, memory_order_relaxed))};
}

@end
