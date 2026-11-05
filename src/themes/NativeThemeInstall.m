#import "NativeThemeInstall.h"

#import "NativeThemeRegistration.h"
#import "NativeThemeLocalPolicy.h"
#import "NativeThemeReceipt.h"
#import "ThemeArchive.h"
#import "ThemeFeatures.h"
#import "ThemeVersion.h"

#import <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const kRUINThemeInstallErrorDomain = @"RUINNativeThemeInstall";
static const NSUInteger kRUINThemeInstallMaxEntries = 4096;
static const uint64_t kRUINThemeInstallMaxBytes = 256ULL * 1024 * 1024;

typedef NS_ENUM(NSInteger, RUINThemeInstallErrorCode) {
    RUINThemeInstallErrorInvalidRecord = 1,
    RUINThemeInstallErrorCatalogMismatch,
    RUINThemeInstallErrorFilesystem,
    RUINThemeInstallErrorManifest,
    RUINThemeInstallErrorBusy,
    RUINThemeInstallErrorRollback
};

static dispatch_queue_t RUINThemeInstallQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("line.ruin.native-theme-install", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSMutableSet<NSString *> *RUINThemeInstallActiveProducts(void)
{
    static NSMutableSet<NSString *> *products;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ products = [NSMutableSet set]; });
    return products;
}

static NSError *RUINThemeInstallError(RUINThemeInstallErrorCode code, NSString *message,
                                      NSError * _Nullable underlying)
{
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey:message} mutableCopy];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:kRUINThemeInstallErrorDomain code:code userInfo:info];
}

static BOOL RUINThemeInstallRawInteger(id value, BOOL allowString, int64_t *result)
{
    if (![value isKindOfClass:NSNumber.class] && !(allowString && [value isKindOfClass:NSString.class])) return NO;
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    NSString *digits = [value isKindOfClass:NSString.class] ? value : [value stringValue];
    if (!digits.length || digits.length > 19) return NO;
    for (NSUInteger i = 0; i < digits.length; i++)
        if ([digits characterAtIndex:i] < '0' || [digits characterAtIndex:i] > '9') return NO;
    errno = 0;
    unsigned long long number = strtoull(digits.UTF8String, NULL, 10);
    if (errno || number == 0 || number > (unsigned long long)LLONG_MAX) return NO;
    if (result) *result = (int64_t)number;
    return YES;
}

static BOOL RUINThemeInstallFlag(id value)
{
    return [value isKindOfClass:NSNumber.class] && [value boolValue];
}

static BOOL RUINThemeInstallRecordMatchesCatalog(NSString *productID,
                                                  NSString *name, int64_t rawVersion,
                                                  NSURL *archiveURL, NSError **error)
{
    NSError *catalogError = nil;
    NSArray<NSDictionary<NSString *, id> *> *catalog = RUINThemeCatalog(&catalogError);
    if (!catalog) {
        if (error) *error = catalogError ?: RUINThemeInstallError(RUINThemeInstallErrorCatalogMismatch,
            @"The current local theme catalog is unavailable.", nil);
        return NO;
    }

    NSUInteger matches = 0;
    for (NSDictionary *item in catalog) {
        id itemID = item[@"productID"];
        id itemName = item[@"name"];
        id itemURLValue = item[@"packageURL"];
        NSURL *itemURL = [itemURLValue isKindOfClass:NSURL.class] ? itemURLValue : nil;
        int64_t itemVersion = 0;
        if (![itemID isKindOfClass:NSString.class] || [itemID caseInsensitiveCompare:productID] != NSOrderedSame ||
            ![itemName isKindOfClass:NSString.class] || ![itemName isEqual:name] ||
            !RUINThemeInstallRawInteger(item[@"version"], YES, &itemVersion) || itemVersion != rawVersion ||
            !RUINThemeInstallFlag(item[@"downloadedLocally"]) ||
            !RUINThemeInstallFlag(item[@"archiveStructureValidated"]) ||
            !itemURL.isFileURL || ![itemURL.pathExtension.lowercaseString isEqual:@"linetheme"] ||
            ![itemURL.standardizedURL isEqual:archiveURL.standardizedURL]) continue;
        matches++;
    }
    if (matches == 1) return YES;
    if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorCatalogMismatch,
        matches ? @"The saved archive matches more than one current catalog record." :
                  @"The saved archive is no longer an exact match in the current local catalog.", nil);
    return NO;
}

static NSURL *RUINCreatePrivateStagingRoot(NSError **error)
{
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ruin-theme-install.XXXXXX"];
    char *path = strdup(template.fileSystemRepresentation);
    if (!path || !mkdtemp(path)) {
        int savedError = errno;
        free(path);
        if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
            [NSString stringWithFormat:@"Could not create a private theme staging root (%d).", savedError], nil);
        return nil;
    }
    NSURL *URL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path] isDirectory:YES];
    free(path);
    return URL;
}

static BOOL RUINValidateStagedManifest(NSURL *packageURL, int64_t expectedRevision, NSError **error)
{
    NSURL *manifestURL = [packageURL URLByAppendingPathComponent:@"theme.json"];
    struct stat status;
    if (lstat(manifestURL.path.fileSystemRepresentation, &status) != 0 || !S_ISREG(status.st_mode)) {
        if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorManifest,
            @"The staged theme.json is not a regular file.", nil);
        return NO;
    }
    NSData *data = [NSData dataWithContentsOfURL:manifestURL options:NSDataReadingMappedIfSafe error:nil];
    NSError *parseError = nil;
    id document = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError] : nil;
    id manifest = [document isKindOfClass:NSDictionary.class] ? document[@"manifest"] : nil;
    int64_t revision = 0;
    BOOL valid = [manifest isKindOfClass:NSDictionary.class] &&
        [manifest[@"platform"] isKindOfClass:NSString.class] && [manifest[@"platform"] isEqual:@"iOS"] &&
        RUINThemeInstallRawInteger(manifest[@"revision"], NO, &revision) && revision == expectedRevision;
    if (!valid && error) *error = RUINThemeInstallError(RUINThemeInstallErrorManifest,
        @"The staged manifest must target iOS and its integer revision must match the saved raw version.", parseError);
    return valid;
}

static NSError *RUINPackageTreeError(void)
{
    return RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
        @"The existing theme package contains an unsupported file or exceeds the safe replacement limits.", nil);
}

static BOOL RUINMeasurePackageDirectory(int directoryFD, NSUInteger *entries, uint64_t *bytes)
{
    int enumerationFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (enumerationFD < 0) return NO;
    DIR *directory = fdopendir(enumerationFD);
    if (!directory) { close(enumerationFD); return NO; }
    BOOL valid = YES;
    struct dirent *item;
    while (valid && (item = readdir(directory)) != NULL) {
        if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..")) continue;
        if (++*entries > kRUINThemeInstallMaxEntries) { valid = NO; break; }
        struct stat status;
        if (fstatat(directoryFD, item->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) { valid = NO; break; }
        if (S_ISDIR(status.st_mode)) {
            int childFD = openat(directoryFD, item->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            valid = childFD >= 0 && RUINMeasurePackageDirectory(childFD, entries, bytes);
            if (childFD >= 0) close(childFD);
        } else if (S_ISREG(status.st_mode) && status.st_size >= 0 &&
                   (uint64_t)status.st_size <= kRUINThemeInstallMaxBytes - *bytes) {
            *bytes += (uint64_t)status.st_size;
        } else {
            valid = NO;
        }
        if (*bytes > kRUINThemeInstallMaxBytes) valid = NO;
    }
    closedir(directory);
    return valid;
}

static BOOL RUINRemovePackageContents(int directoryFD, NSUInteger *entries, uint64_t *bytes)
{
    int enumerationFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (enumerationFD < 0) return NO;
    DIR *directory = fdopendir(enumerationFD);
    if (!directory) { close(enumerationFD); return NO; }
    BOOL removed = YES;
    struct dirent *item;
    while (removed && (item = readdir(directory)) != NULL) {
        if (!strcmp(item->d_name, ".") || !strcmp(item->d_name, "..")) continue;
        if (++*entries > kRUINThemeInstallMaxEntries) { removed = NO; break; }
        struct stat status;
        if (fstatat(directoryFD, item->d_name, &status, AT_SYMLINK_NOFOLLOW) != 0) { removed = NO; break; }
        if (S_ISDIR(status.st_mode)) {
            int childFD = openat(directoryFD, item->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (childFD < 0) { removed = NO; break; }
            removed = RUINRemovePackageContents(childFD, entries, bytes);
            close(childFD);
            if (removed) removed = unlinkat(directoryFD, item->d_name, AT_REMOVEDIR) == 0;
        } else if (S_ISREG(status.st_mode) && status.st_size >= 0 &&
                   (uint64_t)status.st_size <= kRUINThemeInstallMaxBytes - *bytes) {
            *bytes += (uint64_t)status.st_size;
            removed = unlinkat(directoryFD, item->d_name, 0) == 0;
        } else {
            removed = NO;
        }
    }
    closedir(directory);
    return removed;
}

static BOOL RUINRemovePackageAt(int parentFD, NSString *name)
{
    struct stat status;
    if (fstatat(parentFD, name.fileSystemRepresentation, &status, AT_SYMLINK_NOFOLLOW) != 0)
        return errno == ENOENT;
    if (!S_ISDIR(status.st_mode)) return NO;
    int directoryFD = openat(parentFD, name.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directoryFD < 0) return NO;
    NSUInteger entries = 0;
    uint64_t bytes = 0;
    BOOL removed = RUINMeasurePackageDirectory(directoryFD, &entries, &bytes);
    entries = 0;
    bytes = 0;
    if (removed) removed = RUINRemovePackageContents(directoryFD, &entries, &bytes);
    close(directoryFD);
    return removed && unlinkat(parentFD, name.fileSystemRepresentation, AT_REMOVEDIR) == 0;
}

static int RUINOpenPackageParent(NSURL *packageURL, NSError **error)
{
    NSURL *parentURL = packageURL.URLByDeletingLastPathComponent;
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:parentURL
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&directoryError]) {
        if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
            @"Could not create the native theme package parent directory.", directoryError);
        return -1;
    }
    struct stat status;
    char resolved[PATH_MAX];
    if (lstat(parentURL.path.fileSystemRepresentation, &status) != 0 || !S_ISDIR(status.st_mode) ||
        !realpath(parentURL.path.fileSystemRepresentation, resolved)) {
        if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
            @"The native theme package parent is not a safe directory.", nil);
        return -1;
    }
    int directoryFD = open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directoryFD < 0 && error) *error = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
        @"Could not safely open the native theme package parent.", nil);
    return directoryFD;
}

@interface RUINThemeInstallOperation : NSObject
@property(nonatomic, copy) NSDictionary<NSString *, id> *record;
@property(nonatomic, copy) void (^completion)(NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable);
@property(nonatomic, copy) NSString *productID;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) int64_t rawVersion;
@property(nonatomic, strong) NSURL *archiveURL;
@property(nonatomic, strong) NSURL *privateRootURL;
@property(nonatomic, strong) NSURL *stagedURL;
@property(nonatomic, strong) NSURL *packageURL;
@property(nonatomic, copy) NSDictionary<NSString *, id> *metadata;
@property(nonatomic, copy) NSString *packageName;
@property(nonatomic, copy) NSString *backupName;
@property(nonatomic, copy) NSString *siblingName;
@property(nonatomic) int packageParentFD;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL hadBackup;
@property(nonatomic) BOOL siblingOwned;
@property(nonatomic) BOOL promoted;
@property(nonatomic) BOOL finished;
- (void)start;
@end

@implementation RUINThemeInstallOperation

- (instancetype)initWithRecord:(NSDictionary<NSString *, id> *)record
                     completion:(void (^)(NSDictionary<NSString *,id> *, NSError *))completion
{
    self = [super init];
    if (self) {
        _record = [record copy];
        _completion = [completion copy];
        _packageParentFD = -1;
    }
    return self;
}

- (BOOL)validateInput:(NSError **)error
{
    id rawID = self.record[@"productID"];
    id rawName = self.record[@"name"];
    id rawURL = self.record[@"packageURL"];
    NSURL *archiveURL = [rawURL isKindOfClass:NSURL.class] ? rawURL : nil;
    NSUUID *UUID = [rawID isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:rawID] : nil;
    NSString *productID = UUID.UUIDString.lowercaseString;
    int64_t rawVersion = 0;
    BOOL validName = [rawName isKindOfClass:NSString.class] && [rawName length] > 0 && [rawName length] <= 256 &&
        [[rawName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] > 0 &&
        [rawName rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
    if (!UUID || [UUID.UUIDString caseInsensitiveCompare:rawID] != NSOrderedSame || !validName ||
        !RUINThemeInstallRawInteger(self.record[@"version"], YES, &rawVersion) ||
        !RUINThemeInstallFlag(self.record[@"downloadedLocally"]) ||
        !RUINThemeInstallFlag(self.record[@"archiveStructureValidated"]) ||
        !archiveURL.isFileURL || ![archiveURL.pathExtension.lowercaseString isEqual:@"linetheme"]) {
        if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorInvalidRecord,
            @"A saved local archive record needs a UUID, name, positive numeric raw version, and validated .linetheme file.", nil);
        return NO;
    }
    self.productID = productID;
    self.name = rawName;
    self.rawVersion = rawVersion;
    self.archiveURL = archiveURL;
    return YES;
}

- (NSDictionary<NSString *, id> *)makeMetadata
{
    NSString *version = [NSString stringWithFormat:@"%lld", self.rawVersion];
    NSString *versionString = RUINThemeDisplayVersion(version);
    NSString *imagePath = [NSString stringWithFormat:@"/%@/%@/%@/%@/%@/ANDROID/icon_136x202.png",
        [self.productID substringToIndex:2],
        [self.productID substringWithRange:NSMakeRange(2, 2)],
        [self.productID substringWithRange:NSMakeRange(4, 2)], self.productID, version];
    return @{@"productID":self.productID, @"name":self.name, @"rawVersion":@(self.rawVersion),
        @"versionString":versionString ?: version, @"imagePath":imagePath, @"productAvailability":@0};
}

- (void)start
{
    NSError *error = nil;
    if (![self validateInput:&error]) { [self finish:nil error:error]; return; }
    NSMutableSet *activeProducts = RUINThemeInstallActiveProducts();
    if ([activeProducts containsObject:self.productID]) {
        [self finish:nil error:RUINThemeInstallError(RUINThemeInstallErrorBusy,
            @"An import for this theme is already in progress.", nil)];
        return;
    }
    [activeProducts addObject:self.productID];
    self.active = YES;

    if (!RUINThemeInstallRecordMatchesCatalog(self.productID, self.name,
                                               self.rawVersion, self.archiveURL, &error)) {
        [self finish:nil error:error];
        return;
    }
    self.privateRootURL = RUINCreatePrivateStagingRoot(&error);
    if (!self.privateRootURL) { [self finish:nil error:error]; return; }
    self.stagedURL = RUINStageThemeArchiveAtURL(self.archiveURL, self.privateRootURL, &error);
    if (!self.stagedURL) { [self finish:nil error:error]; return; }
    if (!RUINValidateStagedManifest(self.stagedURL, self.rawVersion, &error)) {
        [self finish:nil error:error];
        return;
    }
    self.metadata = [self makeMetadata];

    RUINNativeThemeRegistrationPackageURL(self.productID, ^(NSURL *packageURL, NSError *packageError) {
        dispatch_async(RUINThemeInstallQueue(), ^{
            if (self.finished) return;
            if (!packageURL || packageError) { [self finish:nil error:packageError ?: RUINThemeInstallError(
                RUINThemeInstallErrorFilesystem, @"LINE did not provide a native theme package location.", nil)]; return; }
            [self installAtPackageURL:packageURL];
        });
    });
}

- (BOOL)promoteToPackageURL:(NSURL *)packageURL error:(NSError **)error
{
    if (!packageURL.isFileURL || ![packageURL.lastPathComponent isEqual:self.productID]) {
        if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
            @"The native package location does not match this theme UUID.", nil);
        return NO;
    }
    self.packageURL = packageURL;
    self.packageName = packageURL.lastPathComponent;
    self.packageParentFD = RUINOpenPackageParent(packageURL, error);
    if (self.packageParentFD < 0) return NO;

    struct stat sourceStatus, parentStatus;
    NSUInteger entries = 0;
    uint64_t bytes = 0;
    int sourceFD = -1;
    if (lstat(self.stagedURL.path.fileSystemRepresentation, &sourceStatus) != 0 || !S_ISDIR(sourceStatus.st_mode) ||
        (sourceFD = open(self.stagedURL.path.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) < 0 ||
        !RUINMeasurePackageDirectory(sourceFD, &entries, &bytes) || fstat(self.packageParentFD, &parentStatus) != 0) {
        if (sourceFD >= 0) close(sourceFD);
        if (error) *error = RUINPackageTreeError();
        return NO;
    }
    close(sourceFD);

    BOOL sameVolume = sourceStatus.st_dev == parentStatus.st_dev;
    if (!sameVolume) {
        self.siblingName = [NSString stringWithFormat:@".%@.ruin-stage-%@", self.productID, NSUUID.UUID.UUIDString.lowercaseString];
        NSURL *siblingURL = [packageURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:self.siblingName isDirectory:YES];
        NSError *copyError = nil;
        if (![[NSFileManager defaultManager] copyItemAtURL:self.stagedURL toURL:siblingURL error:&copyError]) {
            if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
                @"Could not copy the validated package to a same-volume staging directory.", copyError);
            return NO;
        }
        self.siblingOwned = YES;
        int siblingFD = openat(self.packageParentFD, self.siblingName.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        entries = 0; bytes = 0;
        BOOL siblingSafe = siblingFD >= 0 && RUINMeasurePackageDirectory(siblingFD, &entries, &bytes);
        if (siblingFD >= 0) close(siblingFD);
        if (!siblingSafe) {
            (void)RUINRemovePackageAt(self.packageParentFD, self.siblingName);
            self.siblingName = nil;
            self.siblingOwned = NO;
            if (error) *error = RUINPackageTreeError();
            return NO;
        }
    }

    self.backupName = [NSString stringWithFormat:@".%@.ruin-backup", self.productID];
    struct stat backupStatus;
    if (fstatat(self.packageParentFD, self.backupName.fileSystemRepresentation,
                &backupStatus, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) {
        if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
            @"A prior package backup needs recovery before this theme can be replaced.", nil);
        return NO;
    }

    struct stat destinationStatus;
    if (fstatat(self.packageParentFD, self.packageName.fileSystemRepresentation,
                &destinationStatus, AT_SYMLINK_NOFOLLOW) == 0) {
        if (!S_ISDIR(destinationStatus.st_mode)) {
            if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
                @"The existing native theme destination is not a directory.", nil);
            return NO;
        }
        int existingFD = openat(self.packageParentFD, self.packageName.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        entries = 0; bytes = 0;
        BOOL safeExisting = existingFD >= 0 && RUINMeasurePackageDirectory(existingFD, &entries, &bytes);
        if (existingFD >= 0) close(existingFD);
        if (!safeExisting) {
            if (error) *error = RUINPackageTreeError();
            return NO;
        }
        if (renameat(self.packageParentFD, self.packageName.fileSystemRepresentation,
                     self.packageParentFD, self.backupName.fileSystemRepresentation) != 0) {
            if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
                @"Could not preserve the existing native theme package before replacement.", nil);
            return NO;
        }
        self.hadBackup = YES;
    } else if (errno != ENOENT) {
        if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
            @"Could not inspect the native theme destination.", nil);
        return NO;
    }

    int moveResult = sameVolume ? renameat(AT_FDCWD, self.stagedURL.path.fileSystemRepresentation,
        self.packageParentFD, self.packageName.fileSystemRepresentation) :
        renameat(self.packageParentFD, self.siblingName.fileSystemRepresentation,
        self.packageParentFD, self.packageName.fileSystemRepresentation);
    if (moveResult != 0) {
        int savedError = errno;
        if (self.hadBackup && renameat(self.packageParentFD, self.backupName.fileSystemRepresentation,
                                      self.packageParentFD, self.packageName.fileSystemRepresentation) == 0)
            self.hadBackup = NO;
        if (error) *error = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
            [NSString stringWithFormat:@"Could not atomically promote the theme package (%d).", savedError], nil);
        return NO;
    }
    if (!sameVolume) self.siblingName = nil;
    self.siblingOwned = NO;
    self.promoted = YES;
    return YES;
}

- (void)installAtPackageURL:(NSURL *)packageURL
{
    NSError *error = nil;
    if (![self promoteToPackageURL:packageURL error:&error]) { [self finish:nil error:error]; return; }
    if (!RUINWriteNativeLocalThemeMarker(packageURL, self.metadata, &error)) {
        [self rollbackWithError:error ?: RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
            @"The local theme registration marker could not be saved.", nil)];
        return;
    }
    RUINRegisterNativeThemeMetadata(self.metadata, YES, self.packageURL,
        ^(NSManagedObjectID *objectID, NSDictionary<NSString *, id> *persistedMetadata, NSError *registrationError) {
            dispatch_async(RUINThemeInstallQueue(), ^{
                if (self.finished) return;
                if (!objectID) {
                    [self rollbackWithError:registrationError ?: RUINThemeInstallError(
                        RUINThemeInstallErrorFilesystem, @"LINE did not persist the native theme record.", nil)];
                    return;
                }
                NSMutableDictionary *result = [@{
                    @"committed": @YES,
                    @"objectID": objectID,
                    @"packageURL": self.packageURL,
                    @"metadata": persistedMetadata ?: self.metadata
                } mutableCopy];
                NSError *completionError = registrationError;
                NSError *receiptError = nil;
                BOOL receiptSaved = RUINWriteThemeReceipt(self.packageURL.URLByDeletingLastPathComponent,
                    persistedMetadata ?: self.metadata, self.archiveURL.lastPathComponent, &receiptError);
                result[@"receiptSaved"] = @(receiptSaved);
                if (!receiptSaved && !completionError) completionError = receiptError;
                if (self.hadBackup && !RUINRemovePackageAt(self.packageParentFD, self.backupName) && !completionError)
                    completionError = RUINThemeInstallError(RUINThemeInstallErrorFilesystem,
                        @"The theme was committed, but its bounded backup cleanup did not finish.", nil);
                self.hadBackup = NO;
                [self finish:[result copy] error:completionError];
            });
        });
}

- (void)rollbackWithError:(NSError *)registrationError
{
    NSError *error = registrationError;
    BOOL removed = !self.promoted || RUINRemovePackageAt(self.packageParentFD, self.packageName);
    if (removed) self.promoted = NO;
    BOOL restored = !self.hadBackup || (removed &&
        renameat(self.packageParentFD, self.backupName.fileSystemRepresentation,
                 self.packageParentFD, self.packageName.fileSystemRepresentation) == 0);
    if (restored) self.hadBackup = NO;
    if (!removed || !restored) error = RUINThemeInstallError(RUINThemeInstallErrorRollback,
        @"Native registration was not committed and package rollback could not fully restore the prior files.", registrationError);
    [self finish:nil error:error];
}

- (void)finish:(NSDictionary<NSString *, id> *)result error:(NSError *)error
{
    if (self.finished) return;
    self.finished = YES;
    if (self.siblingOwned && self.siblingName && self.packageParentFD >= 0)
        (void)RUINRemovePackageAt(self.packageParentFD, self.siblingName);
    if (self.privateRootURL) [[NSFileManager defaultManager] removeItemAtURL:self.privateRootURL error:nil];
    if (self.packageParentFD >= 0) close(self.packageParentFD);
    if (self.active) [RUINThemeInstallActiveProducts() removeObject:self.productID];
    void (^completion)(NSDictionary *, NSError *) = self.completion;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
}

@end

void RUINImportDownloadedTheme(NSDictionary<NSString *, id> *record,
    void (^completion)(NSDictionary<NSString *, id> * _Nullable result, NSError * _Nullable error))
{
    RUINThemeInstallOperation *operation = [[RUINThemeInstallOperation alloc]
        initWithRecord:[record isKindOfClass:NSDictionary.class] ? record : @{}
        completion:completion];
    dispatch_async(RUINThemeInstallQueue(), ^{ [operation start]; });
}
