#import <Foundation/Foundation.h>
#import "NativeThemeLocalPolicy.h"

#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

static NSString *NewID(void) { return NSUUID.UUID.UUIDString.lowercaseString; }

static void WriteData(NSURL *URL, NSData *data)
{
    NSError *error = nil;
    assert([data writeToURL:URL options:NSDataWritingAtomic error:&error] && !error);
}

static void WriteManifest(NSURL *directory, NSString *platform, NSNumber *revision)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"manifest":@{
        @"platform":platform, @"revision":revision}} options:0 error:nil];
    assert(data);
    WriteData([directory URLByAppendingPathComponent:@"theme.json"], data);
}

static NSURL *WritePackage(NSURL *root, NSString *directoryID, NSString *markerID,
    NSNumber *markerRevision, NSString *platform, NSNumber *manifestRevision, BOOL hasMarker)
{
    NSURL *directory = [root URLByAppendingPathComponent:directoryID isDirectory:YES];
    NSError *error = nil;
    assert([[NSFileManager defaultManager] createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:nil error:&error] && !error);
    WriteManifest(directory, platform, manifestRevision);
    if (hasMarker) {
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{
            @"productID":markerID, @"rawVersion":markerRevision}
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
        assert(data && !error);
        WriteData([directory URLByAppendingPathComponent:@".ruin-local-theme.plist"], data);
    }
    return directory;
}

static void BumpMtime(NSURL *directory)
{
    struct stat status;
    assert(stat(directory.path.fileSystemRepresentation, &status) == 0);
    struct timespec times[2] = {status.st_atimespec, status.st_mtimespec};
    if (++times[1].tv_nsec == 1000000000) { times[1].tv_nsec = 0; times[1].tv_sec++; }
    assert(utimensat(AT_FDCWD, directory.path.fileSystemRepresentation, times, 0) == 0);
}

static void CheckPackageScan(NSURL *base)
{
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *root = [base URLByAppendingPathComponent:@"packages" isDirectory:YES];
    assert([files createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *valid = NewID();
    WritePackage(root, valid, valid, @7, @"iOS", @7, YES);

    NSString *foreign = NewID();
    WritePackage(root, NewID(), foreign, @7, @"iOS", @7, YES);
    WritePackage(root, NewID(), nil, nil, @"iOS", @7, NO);
    WritePackage(root, @"not-a-uuid", @"not-a-uuid", @7, @"iOS", @7, YES);
    WritePackage(root, NewID(), NewID(), @7, @"iOS", @8, YES);
    WritePackage(root, NewID(), NewID(), @7, @"Android", @7, YES);

    NSString *linked = NewID();
    NSURL *target = WritePackage([base URLByAppendingPathComponent:@"outside" isDirectory:YES],
        linked, linked, @7, @"iOS", @7, YES);
    NSURL *link = [root URLByAppendingPathComponent:linked];
    assert(symlink(target.path.fileSystemRepresentation, link.path.fileSystemRepresentation) == 0);

    NSString *markerLinkID = NewID();
    NSURL *markerLink = WritePackage(root, markerLinkID, nil, nil, @"iOS", @7, NO);
    NSURL *externalMarker = [base URLByAppendingPathComponent:@"external-marker.plist"];
    NSData *marker = [NSPropertyListSerialization dataWithPropertyList:@{
        @"productID":markerLinkID, @"rawVersion":@7}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    assert(marker);
    WriteData(externalMarker, marker);
    NSURL *markerPath = [markerLink URLByAppendingPathComponent:@".ruin-local-theme.plist"];
    assert(symlink(externalMarker.path.fileSystemRepresentation, markerPath.path.fileSystemRepresentation) == 0);

    NSSet *found = RUINNativeLocalThemeIDs(root);
    assert([found isEqualToSet:[NSSet setWithObject:valid]]);

    NSString *added = NewID();
    WritePackage(root, added, added, @9, @"iOS", @9, YES);
    BumpMtime(root);
    found = RUINNativeLocalThemeIDs(root);
    assert(found.count == 2 && [found containsObject:valid] && [found containsObject:added]);
}

int main(void)
{
    @autoreleasepool {
        char path[] = "/tmp/ruin-native-local-policy.XXXXXX";
        char *created = mkdtemp(path);
        assert(created);
        NSURL *base = [NSURL fileURLWithPath:[NSString stringWithUTF8String:created] isDirectory:YES];
        CheckPackageScan(base);
        assert([NSFileManager.defaultManager removeItemAtURL:base error:nil]);
        puts("native theme local marker scan and cache checks passed");
    }
    return 0;
}
