#import <Foundation/Foundation.h>
#import "NativeThemeReceipt.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSURL *PackagesRoot(NSURL *base, NSString *account)
{
    NSURL *privateStore = [base URLByAppendingPathComponent:@"PrivateStore" isDirectory:YES];
    NSURL *accountURL = [privateStore URLByAppendingPathComponent:account isDirectory:YES];
    NSURL *root = [accountURL URLByAppendingPathComponent:@"Theme Packages" isDirectory:YES];
    NSError *error = nil;
    assert([NSFileManager.defaultManager createDirectoryAtURL:root
        withIntermediateDirectories:YES attributes:nil error:&error] && !error);
    return root;
}

static NSDictionary *Metadata(NSString *productID, NSString *name)
{
    NSString *imagePath = [NSString stringWithFormat:@"/%@/%@/%@/%@/42/ANDROID/theme.png",
        [productID substringToIndex:2], [productID substringWithRange:NSMakeRange(2, 2)],
        [productID substringWithRange:NSMakeRange(4, 2)], productID];
    return @{@"productID":productID, @"name":name, @"rawVersion":@42,
        @"versionString":@"4.2", @"imagePath":imagePath};
}

static NSString *ArchiveName(void)
{
    return [NSUUID.UUID.UUIDString stringByAppendingString:@".linetheme"];
}

static BOOL Write(NSURL *root, NSDictionary *metadata, NSString *archive)
{
    NSError *error = nil;
    BOOL result = RUINWriteThemeReceipt(root, metadata, archive, &error);
    assert(result == (error == nil));
    return result;
}

static void CheckRoundTrip(NSURL *base)
{
    NSString *productID = NSUUID.UUID.UUIDString.lowercaseString;
    NSURL *root = PackagesRoot(base, @"S_receipt-alpha");
    NSURL *account = root.URLByDeletingLastPathComponent;
    NSURL *directory = [account URLByAppendingPathComponent:@"RUIN Theme Receipts" isDirectory:YES];
    NSURL *file = [directory URLByAppendingPathComponent:[productID stringByAppendingString:@".plist"]];
    NSString *archive = ArchiveName();

    assert(![NSFileManager.defaultManager fileExistsAtPath:directory.path]);
    NSDictionary *input = Metadata(productID, @"Receipt theme");
    assert(Write(root, input, archive));
    NSDictionary *expected = [@{@"productID":productID, @"name":@"Receipt theme",
        @"rawVersion":@42, @"versionString":@"4.2", @"imagePath":input[@"imagePath"],
        @"archiveName":archive} copy];
    assert([RUINReadThemeReceipt(root, productID.uppercaseString) isEqual:expected]);
    assert([RUINReadThemeReceipts(root) isEqual:@{productID:expected}]);

    struct stat directoryStatus, fileStatus;
    assert(lstat(directory.path.fileSystemRepresentation, &directoryStatus) == 0);
    assert(S_ISDIR(directoryStatus.st_mode) && (directoryStatus.st_mode & 0777) == 0700);
    assert(lstat(file.path.fileSystemRepresentation, &fileStatus) == 0);
    assert(S_ISREG(fileStatus.st_mode) && (fileStatus.st_mode & 0777) == 0600);
    assert(![NSFileManager.defaultManager fileExistsAtPath:[root URLByAppendingPathComponent:@"RUIN Theme Receipts"].path]);

    NSURL *unrelated = [directory URLByAppendingPathComponent:@"keep-me.txt"];
    NSData *marker = [@"unrelated" dataUsingEncoding:NSUTF8StringEncoding];
    assert([marker writeToURL:unrelated options:0 error:nil]);
    assert(Write(root, Metadata(productID, @"Updated theme"), archive));
    assert([[NSData dataWithContentsOfURL:unrelated] isEqual:marker]);
    assert([RUINReadThemeReceipt(root, productID)[@"name"] isEqual:@"Updated theme"]);
}

static void CheckAccountIsolation(NSURL *base)
{
    NSString *productID = NSUUID.UUID.UUIDString.lowercaseString;
    NSURL *first = PackagesRoot(base, @"S_receipt-first");
    NSURL *second = PackagesRoot(base, @"S_receipt-second");
    assert(Write(first, Metadata(productID, @"First account"), ArchiveName()));
    assert(!RUINReadThemeReceipt(second, productID));
    assert(RUINReadThemeReceipts(second).count == 0);
    assert(Write(second, Metadata(productID, @"Second account"), ArchiveName()));
    assert([RUINReadThemeReceipt(first, productID)[@"name"] isEqual:@"First account"]);
    assert([RUINReadThemeReceipt(second, productID)[@"name"] isEqual:@"Second account"]);
}

static void CheckBadMetadata(NSURL *base)
{
    NSURL *root = PackagesRoot(base, @"S_receipt-invalid");
    NSString *productID = NSUUID.UUID.UUIDString.lowercaseString;
    NSDictionary *valid = Metadata(productID, @"Valid");
    NSMutableArray *invalid = [NSMutableArray array];
    NSMutableDictionary *item = [valid mutableCopy]; item[@"name"] = @"bad\nname"; [invalid addObject:item];
    item = [valid mutableCopy]; item[@"name"] = [@"x" stringByPaddingToLength:257 withString:@"x" startingAtIndex:0]; [invalid addObject:item];
    item = [valid mutableCopy]; item[@"rawVersion"] = @0; [invalid addObject:item];
    item = [valid mutableCopy]; item[@"rawVersion"] = @YES; [invalid addObject:item];
    item = [valid mutableCopy]; item[@"rawVersion"] = @1.5; [invalid addObject:item];
    item = [valid mutableCopy]; item[@"productID"] = @"../../outside"; [invalid addObject:item];
    for (NSDictionary *bad in invalid) assert(!Write(root, bad, ArchiveName()));
    assert(!Write(root, valid, @"../outside.linetheme"));
    assert(!Write(root, valid, @"/tmp/archive.linetheme"));
    assert(![NSFileManager.defaultManager fileExistsAtPath:
        [root.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"RUIN Theme Receipts"].path]);

    NSURL *wrongRoot = [root.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Other" isDirectory:YES];
    assert(!Write(wrongRoot, valid, ArchiveName()));
    NSURL *wrongAccount = PackagesRoot(base, @"other-account");
    assert(!Write(wrongAccount, valid, ArchiveName()));
}

static void CheckReadDoesNotCreate(NSURL *base)
{
    NSURL *root = PackagesRoot(base, @"S_receipt-empty");
    NSURL *directory = [root.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:@"RUIN Theme Receipts" isDirectory:YES];
    assert(RUINReadThemeReceipts(root).count == 0);
    assert(!RUINReadThemeReceipt(root, NSUUID.UUID.UUIDString));
    struct stat status;
    assert(lstat(directory.path.fileSystemRepresentation, &status) < 0 && errno == ENOENT);
}

static void CheckMissingPackageRoot(NSURL *base)
{
    NSString *productID = NSUUID.UUID.UUIDString.lowercaseString;
    NSURL *root = PackagesRoot(base, @"S_receipt-assets-removed");
    assert(Write(root, Metadata(productID, @"Preserved"), ArchiveName()));
    assert(rmdir(root.path.fileSystemRepresentation) == 0);
    assert(RUINReadThemeReceipts(root).count == 1);
    assert(RUINReadThemeReceipt(root, productID));
    struct stat status;
    assert(lstat(root.path.fileSystemRepresentation, &status) < 0 && errno == ENOENT);
}

static void CheckSymlinks(NSURL *base)
{
    NSString *productID = NSUUID.UUID.UUIDString.lowercaseString;
    NSDictionary *metadata = Metadata(productID, @"Symlink");
    NSURL *folderRoot = PackagesRoot(base, @"S_receipt-folder-link");
    NSURL *folderAccount = folderRoot.URLByDeletingLastPathComponent;
    NSURL *folderLink = [folderAccount URLByAppendingPathComponent:@"RUIN Theme Receipts"];
    NSURL *outsideDirectory = [base URLByAppendingPathComponent:@"outside-receipts" isDirectory:YES];
    assert([NSFileManager.defaultManager createDirectoryAtURL:outsideDirectory
        withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]);
    assert(symlink(outsideDirectory.path.fileSystemRepresentation, folderLink.path.fileSystemRepresentation) == 0);
    assert(!Write(folderRoot, metadata, ArchiveName()));
    assert(RUINReadThemeReceipts(folderRoot).count == 0);

    NSURL *fileRoot = PackagesRoot(base, @"S_receipt-file-link");
    NSURL *fileAccount = fileRoot.URLByDeletingLastPathComponent;
    NSURL *receiptDirectory = [fileAccount URLByAppendingPathComponent:@"RUIN Theme Receipts" isDirectory:YES];
    assert(mkdir(receiptDirectory.path.fileSystemRepresentation, 0700) == 0);
    NSURL *outsideFile = [base URLByAppendingPathComponent:@"outside.plist"];
    assert([@"external" writeToURL:outsideFile atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert(chmod(outsideFile.path.fileSystemRepresentation, 0600) == 0);
    NSURL *fileLink = [receiptDirectory URLByAppendingPathComponent:[productID stringByAppendingString:@".plist"]];
    assert(symlink(outsideFile.path.fileSystemRepresentation, fileLink.path.fileSystemRepresentation) == 0);
    assert(!RUINReadThemeReceipt(fileRoot, productID));
    assert(RUINReadThemeReceipts(fileRoot).count == 0);
    assert(!Write(fileRoot, metadata, ArchiveName()));
}

static void CheckBounds(NSURL *base)
{
    NSString *productID = NSUUID.UUID.UUIDString.lowercaseString;
    NSURL *root = PackagesRoot(base, @"S_receipt-bounds");
    NSURL *directory = [root.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:@"RUIN Theme Receipts" isDirectory:YES];
    assert(mkdir(directory.path.fileSystemRepresentation, 0700) == 0);
    NSURL *largeFile = [directory URLByAppendingPathComponent:[productID stringByAppendingString:@".plist"]];
    int fd = open(largeFile.path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(fd >= 0 && ftruncate(fd, 16 * 1024 + 1) == 0 && close(fd) == 0);
    assert(!RUINReadThemeReceipt(root, productID));

    int directoryFD = open(directory.path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY);
    assert(directoryFD >= 0);
    for (NSUInteger i = 0; i < 4097; i++) {
        NSString *name = [NSString stringWithFormat:@"unrelated-%04lu", (unsigned long)i];
        fd = openat(directoryFD, name.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
        assert(fd >= 0 && close(fd) == 0);
    }
    close(directoryFD);
    assert(RUINReadThemeReceipts(root).count == 0);
    assert(!Write(root, Metadata(NSUUID.UUID.UUIDString.lowercaseString, @"Bounded"), ArchiveName()));
}

int main(void)
{
    @autoreleasepool {
        char path[] = "/tmp/ruin-native-theme-receipt.XXXXXX";
        char *created = mkdtemp(path);
        assert(created);
        NSURL *base = [NSURL fileURLWithPath:[NSString stringWithUTF8String:created] isDirectory:YES];
        CheckRoundTrip(base);
        // The actual iOS group URL uses /private/var, whose standardized
        // NSString spelling removes /private. Both aliases address one store.
        NSURL *aliasBase = [[NSURL fileURLWithPath:[@"/private" stringByAppendingString:base.path] isDirectory:YES]
            URLByAppendingPathComponent:@"alias-case" isDirectory:YES];
        CheckRoundTrip(aliasBase);
        CheckAccountIsolation(base);
        CheckBadMetadata(base);
        CheckReadDoesNotCreate(base);
        CheckMissingPackageRoot(base);
        CheckSymlinks(base);
        CheckBounds(base);
        assert([NSFileManager.defaultManager removeItemAtURL:base error:nil]);
        puts("PASS native theme receipt round trip, account isolation, input and path guards, no-create reads, symlink rejection, atomic permissions, and bounds");
    }
    return 0;
}
