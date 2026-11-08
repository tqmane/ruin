#import "NativeThemeReceipt.h"
#import "ThemeAccountNamespace.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *kRUINReceiptDirectory = "RUIN Theme Receipts";
static const size_t kRUINReceiptMaximumBytes = 16 * 1024;
static const NSUInteger kRUINReceiptMaximumEntries = 4096;
static NSString *const kRUINReceiptErrorDomain = @"RUINThemeReceipt";

static BOOL RUINReceiptFail(NSError **error, NSInteger code, NSString *message)
{
    if (error) *error = [NSError errorWithDomain:kRUINReceiptErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

static BOOL RUINReceiptPOSIXFail(NSError **error, int code, NSString *message)
{
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

static NSString *RUINReceiptCanonicalUUID(id value)
{
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *string = value;
    NSUUID *UUID = [[NSUUID alloc] initWithUUIDString:string];
    return UUID && [UUID.UUIDString caseInsensitiveCompare:string] == NSOrderedSame
        ? UUID.UUIDString.lowercaseString : nil;
}

static BOOL RUINReceiptCleanString(id value, NSUInteger maximumLength, BOOL requireVisible)
{
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *string = value;
    if (!string.length || string.length > maximumLength ||
        ![string canBeConvertedToEncoding:NSUTF8StringEncoding] ||
        [string rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return NO;
    return !requireVisible ||
        [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
}

static BOOL RUINReceiptPositiveInt64(id value, int64_t *result)
{
    if (![value isKindOfClass:NSNumber.class]) return NO;
    CFTypeRef number = (__bridge CFTypeRef)value;
    if (CFGetTypeID(number) != CFNumberGetTypeID() || CFNumberIsFloatType((CFNumberRef)number)) return NO;
    NSString *digits = [(NSNumber *)value stringValue];
    if (!digits.length || digits.length > 19) return NO;
    for (NSUInteger i = 0; i < digits.length; i++)
        if ([digits characterAtIndex:i] < '0' || [digits characterAtIndex:i] > '9') return NO;
    errno = 0;
    unsigned long long parsed = strtoull(digits.UTF8String, NULL, 10);
    if (errno || parsed == 0 || parsed > (unsigned long long)LLONG_MAX) return NO;
    if (result) *result = (int64_t)parsed;
    return YES;
}

static BOOL RUINReceiptArchiveName(id value)
{
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *filename = value;
    if (filename.length != 46 || ![[filename substringFromIndex:36] isEqual:@".linetheme"])
        return NO;
    return RUINReceiptCanonicalUUID([filename substringToIndex:36]) != nil;
}

static BOOL RUINReceiptOpenPaths(NSURL *packagesRoot, int *accountFD, int *rootFD)
{
    if (!packagesRoot.isFileURL) return NO;
    NSString *path = packagesRoot.path;
    if (![path isAbsolutePath] || ![packagesRoot.lastPathComponent isEqual:@"Theme Packages"]) return NO;
    // Foundation strips /private from existing /private/var paths on Apple
    // platforms. That native alias is valid; reject traversal lexically and
    // keep the no-follow checks on the account and package directories below.
    for (NSString *component in [path componentsSeparatedByString:@"/"])
        if ([component isEqual:@"."] || [component isEqual:@".."]) return NO;

    NSURL *accountURL = packagesRoot.URLByDeletingLastPathComponent;
    NSURL *privateStoreURL = accountURL.URLByDeletingLastPathComponent;
    NSString *account = accountURL.lastPathComponent;
    if (![privateStoreURL.lastPathComponent isEqual:@"PrivateStore"] ||
        !RUINThemeAccountNamespaceIsValid(account)) return NO;

    int store = open(privateStoreURL.path.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (store < 0) return NO;
    int accountDirectory = openat(store, account.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int savedErrno = errno;
    close(store);
    if (accountDirectory < 0) { errno = savedErrno; return NO; }
    int root = openat(accountDirectory, "Theme Packages",
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0 && errno != ENOENT) { close(accountDirectory); return NO; }

    struct stat accountStatus, rootStatus;
    if (fstat(accountDirectory, &accountStatus) || !S_ISDIR(accountStatus.st_mode) ||
        accountStatus.st_uid != geteuid() ||
        (root >= 0 && (fstat(root, &rootStatus) || !S_ISDIR(rootStatus.st_mode) || rootStatus.st_uid != geteuid()))) {
        if (root >= 0) close(root);
        close(accountDirectory);
        return NO;
    }
    *accountFD = accountDirectory;
    *rootFD = root;
    return YES;
}

static int RUINReceiptOpenDirectory(int accountFD, BOOL create, NSError **error)
{
    if (create && mkdirat(accountFD, kRUINReceiptDirectory, 0700) && errno != EEXIST) {
        int code = errno;
        RUINReceiptPOSIXFail(error, code, @"Could not create the theme receipt directory.");
        return -1;
    }
    int directory = openat(accountFD, kRUINReceiptDirectory,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) {
        if (create) RUINReceiptPOSIXFail(error, errno, @"Could not open the theme receipt directory.");
        return -1;
    }
    struct stat status;
    int statResult = fstat(directory, &status);
    if (statResult || !S_ISDIR(status.st_mode) || status.st_uid != geteuid()) {
        int code = statResult ? errno : EPERM;
        close(directory);
        if (create) RUINReceiptPOSIXFail(error, code, @"The theme receipt directory is unsafe.");
        return -1;
    }
    if (create && fchmod(directory, 0700)) {
        int code = errno;
        close(directory);
        RUINReceiptPOSIXFail(error, code, @"Could not protect the theme receipt directory.");
        return -1;
    }
    if ((status.st_mode & 0777) != 0700 && !create) {
        close(directory);
        return -1;
    }
    return directory;
}

static NSData *RUINReceiptReadData(int directory, const char *filename)
{
    int file = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (file < 0) return nil;
    struct stat status;
    if (fstat(file, &status) || !S_ISREG(status.st_mode) || status.st_uid != geteuid() ||
        (status.st_mode & 0777) != 0600 || status.st_size <= 0 ||
        status.st_size > (off_t)kRUINReceiptMaximumBytes) {
        close(file);
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(file, (uint8_t *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(file); return nil; }
        offset += (NSUInteger)count;
    }
    uint8_t extra;
    ssize_t trailing;
    do { trailing = read(file, &extra, sizeof(extra)); } while (trailing < 0 && errno == EINTR);
    close(file);
    return trailing == 0 ? data : nil;
}

static NSDictionary<NSString *, id> *RUINReceiptMetadata(NSData *data, NSString *expectedID)
{
    id object = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:nil];
    if (![object isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *receipt = object;
    NSSet *allowed = [NSSet setWithArray:@[@"receiptVersion", @"committed", @"productID",
        @"name", @"rawVersion", @"versionString", @"imagePath", @"archiveName"]];
    for (id key in receipt) if (![key isKindOfClass:NSString.class] || ![allowed containsObject:key]) return nil;

    id receiptVersion = receipt[@"receiptVersion"];
    int64_t parsedVersion = 0, rawVersion = 0;
    id committed = receipt[@"committed"];
    if (!RUINReceiptPositiveInt64(receiptVersion, &parsedVersion) || parsedVersion != 1 ||
        ![committed isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)committed) != CFBooleanGetTypeID() || ![committed boolValue] ||
        ![RUINReceiptCanonicalUUID(receipt[@"productID"]) isEqual:expectedID] ||
        !RUINReceiptCleanString(receipt[@"name"], 256, YES) ||
        !RUINReceiptPositiveInt64(receipt[@"rawVersion"], &rawVersion) ||
        !RUINReceiptArchiveName(receipt[@"archiveName"])) return nil;

    id versionString = receipt[@"versionString"], imagePath = receipt[@"imagePath"];
    if ((versionString && !RUINReceiptCleanString(versionString, 256, YES)) ||
        (imagePath && !RUINReceiptCleanString(imagePath, 512, YES))) return nil;

    NSMutableDictionary *metadata = [@{
        @"productID": expectedID,
        @"name": [receipt[@"name"] copy],
        @"rawVersion": @(rawVersion),
        @"archiveName": [receipt[@"archiveName"] copy]
    } mutableCopy];
    if (versionString) metadata[@"versionString"] = [versionString copy];
    if (imagePath) metadata[@"imagePath"] = [imagePath copy];
    return [metadata copy];
}

static BOOL RUINReceiptCanonicalFilename(NSString *filename, NSString **productID)
{
    if (filename.length != 42 || ![[filename substringFromIndex:36] isEqual:@".plist"]) return NO;
    NSString *canonical = RUINReceiptCanonicalUUID([filename substringToIndex:36]);
    if (!canonical || ![canonical isEqual:[filename substringToIndex:36]]) return NO;
    if (productID) *productID = canonical;
    return YES;
}

BOOL RUINWriteThemeReceipt(NSURL *trustedPackagesRoot, NSDictionary<NSString *,id> *metadata,
    NSString *archiveName, NSError **error)
{
    if (error) *error = nil;
    if (![metadata isKindOfClass:NSDictionary.class])
        return RUINReceiptFail(error, 1, @"Theme metadata must be a dictionary.");
    NSString *productID = RUINReceiptCanonicalUUID(metadata[@"productID"]);
    int64_t rawVersion = 0;
    if (!productID || !RUINReceiptCleanString(metadata[@"name"], 256, YES) ||
        !RUINReceiptPositiveInt64(metadata[@"rawVersion"], &rawVersion) ||
        !RUINReceiptArchiveName(archiveName))
        return RUINReceiptFail(error, 2, @"Theme receipt metadata or archive filename is invalid.");

    NSMutableDictionary *receipt = [@{
        @"receiptVersion": @1,
        @"committed": @YES,
        @"productID": productID,
        @"name": [metadata[@"name"] copy],
        @"rawVersion": @(rawVersion),
        @"archiveName": [archiveName copy]
    } mutableCopy];
    id versionString = metadata[@"versionString"], imagePath = metadata[@"imagePath"];
    if (RUINReceiptCleanString(versionString, 256, YES)) receipt[@"versionString"] = [versionString copy];
    if (RUINReceiptCleanString(imagePath, 512, YES)) receipt[@"imagePath"] = [imagePath copy];
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:receipt
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&serializationError];
    if (!data || data.length > kRUINReceiptMaximumBytes)
        return RUINReceiptFail(error, 3, @"The theme receipt could not be serialized within its size limit.");

    int account = -1, root = -1;
    if (!RUINReceiptOpenPaths(trustedPackagesRoot, &account, &root))
        return RUINReceiptFail(error, 4, @"The Theme Packages path is not a validated native account path.");
    if (root >= 0) close(root);
    int directory = RUINReceiptOpenDirectory(account, YES, error);
    close(account);
    if (directory < 0) return NO;

    NSString *filename = [productID stringByAppendingString:@".plist"];
    struct stat existing;
    BOOL targetExists = fstatat(directory, filename.fileSystemRepresentation, &existing,
        AT_SYMLINK_NOFOLLOW) == 0;
    if (targetExists && (!S_ISREG(existing.st_mode) || existing.st_uid != geteuid())) {
        close(directory);
        return RUINReceiptFail(error, 5, @"The existing theme receipt path is unsafe.");
    }
    if (!targetExists && errno != ENOENT) {
        int code = errno;
        close(directory);
        return RUINReceiptPOSIXFail(error, code, @"Could not inspect the existing theme receipt.");
    }

    DIR *entries = fdopendir(dup(directory));
    if (!entries) {
        int code = errno;
        close(directory);
        return RUINReceiptPOSIXFail(error, code, @"Could not inspect the theme receipt directory.");
    }
    NSUInteger count = 0;
    struct dirent *entry = NULL;
    BOOL scanOK = YES;
    for (;;) {
        errno = 0;
        entry = readdir(entries);
        if (!entry) { scanOK = errno == 0; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (++count > kRUINReceiptMaximumEntries) { scanOK = NO; break; }
    }
    closedir(entries);
    if (!scanOK || count >= kRUINReceiptMaximumEntries) {
        close(directory);
        return RUINReceiptFail(error, 6, @"The theme receipt directory exceeds its entry limit.");
    }

    NSString *temporary = [@".ruin-theme-receipt-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    int file = openat(directory, temporary.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (file < 0) {
        int code = errno;
        close(directory);
        return RUINReceiptPOSIXFail(error, code, @"Could not create the temporary theme receipt.");
    }
    BOOL success = fchmod(file, 0600) == 0;
    int writeError = success ? 0 : errno;
    NSUInteger offset = 0;
    while (success && offset < data.length) {
        ssize_t written = write(file, (const uint8_t *)data.bytes + offset, data.length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { success = NO; writeError = written < 0 ? errno : EIO; }
        else offset += (NSUInteger)written;
    }
    if (success && fsync(file)) { success = NO; writeError = errno; }
    if (close(file) && success) { success = NO; writeError = errno; }
    if (success && renameat(directory, temporary.fileSystemRepresentation,
        directory, filename.fileSystemRepresentation)) { success = NO; writeError = errno; }
    if (success && fsync(directory)) { success = NO; writeError = errno; }
    if (!success) unlinkat(directory, temporary.fileSystemRepresentation, 0);
    close(directory);
    if (!success) return RUINReceiptPOSIXFail(error, writeError ?: EIO,
        @"Could not atomically save the theme receipt.");
    return YES;
}

NSDictionary<NSString *,id> *RUINReadThemeReceipt(NSURL *trustedPackagesRoot, NSString *productID)
{
    NSString *canonicalID = RUINReceiptCanonicalUUID(productID);
    if (!canonicalID) return nil;
    int account = -1, root = -1;
    if (!RUINReceiptOpenPaths(trustedPackagesRoot, &account, &root)) return nil;
    if (root >= 0) close(root);
    int directory = RUINReceiptOpenDirectory(account, NO, NULL);
    close(account);
    if (directory < 0) return nil;
    NSString *filename = [canonicalID stringByAppendingString:@".plist"];
    NSData *data = RUINReceiptReadData(directory, filename.fileSystemRepresentation);
    close(directory);
    return data ? RUINReceiptMetadata(data, canonicalID) : nil;
}

NSDictionary<NSString *,NSDictionary<NSString *,id> *> *RUINReadThemeReceipts(NSURL *trustedPackagesRoot)
{
    int account = -1, root = -1;
    if (!RUINReceiptOpenPaths(trustedPackagesRoot, &account, &root)) return @{};
    if (root >= 0) close(root);
    int directory = RUINReceiptOpenDirectory(account, NO, NULL);
    close(account);
    if (directory < 0) return @{};

    DIR *entries = fdopendir(dup(directory));
    if (!entries) { close(directory); return @{}; }
    NSMutableDictionary *receipts = [NSMutableDictionary dictionary];
    NSUInteger count = 0;
    BOOL overflow = NO;
    BOOL readError = NO;
    struct dirent *entry = NULL;
    for (;;) {
        errno = 0;
        entry = readdir(entries);
        if (!entry) { readError = errno != 0; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        if (++count > kRUINReceiptMaximumEntries) { overflow = YES; break; }
        NSString *filename = [NSString stringWithUTF8String:entry->d_name];
        NSString *productID = nil;
        if (!filename || !RUINReceiptCanonicalFilename(filename, &productID)) continue;
        NSData *data = RUINReceiptReadData(directory, filename.fileSystemRepresentation);
        NSDictionary *metadata = data ? RUINReceiptMetadata(data, productID) : nil;
        if (metadata) receipts[productID] = metadata;
    }
    closedir(entries);
    close(directory);
    return overflow || readError ? @{} : [receipts copy];
}
