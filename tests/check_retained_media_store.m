#import "../src/messaging/RetainedMediaStore.h"
#import <stdatomic.h>
#import <assert.h>
#import <sys/stat.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static NSURL *MakeDirectory(NSURL *parent, NSString *name) {
    NSURL *url = [parent URLByAppendingPathComponent:name isDirectory:YES];
    assert([NSFileManager.defaultManager createDirectoryAtURL:url
        withIntermediateDirectories:YES attributes:nil error:nil]);
    return url;
}

static NSURL *WriteFile(NSURL *directory, NSString *name, NSData *data) {
    NSURL *url = [directory URLByAppendingPathComponent:name];
    assert([data writeToURL:url options:NSDataWritingAtomic error:nil]);
    return url;
}

static NSDictionary *MessageKey(NSString *store, NSString *kind, NSString *chat, NSString *message) {
    return @{@"store":store, @"kind":kind, @"chat":chat, @"message":message};
}

static BOOL Wait(dispatch_semaphore_t semaphore) {
    return dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0;
}

static void CheckCaptureData(RUINRetainedMediaStore *store,
                             NSData *data,
                             NSString *extension,
                             NSDictionary *key,
                             NSString *role,
                             BOOL expectedAccepted,
                             BOOL expectedSuccess) {
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block BOOL success = !expectedSuccess;
    __block BOOL offMain = NO;
    __block NSUInteger callbacks = 0;
    BOOL accepted = [store captureData:data extension:extension forKey:key role:role completion:^(BOOL result) {
        success = result;
        offMain = !NSThread.isMainThread;
        callbacks++;
        dispatch_semaphore_signal(completed);
    }];
    assert(accepted == expectedAccepted);
    assert(Wait(completed));
    assert(callbacks == 1 && success == expectedSuccess && offMain);
}

static void CheckCaptureURL(RUINRetainedMediaStore *store,
                            NSURL *source,
                            NSArray<NSURL *> *roots,
                            NSDictionary *key,
                            NSString *role,
                            BOOL expectedAccepted,
                            BOOL expectedSuccess) {
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block BOOL success = !expectedSuccess;
    __block BOOL offMain = NO;
    __block NSUInteger callbacks = 0;
    BOOL accepted = [store captureURL:source allowedRoots:roots forKey:key role:role completion:^(BOOL result) {
        success = result;
        offMain = !NSThread.isMainThread;
        callbacks++;
        dispatch_semaphore_signal(completed);
    }];
    assert(accepted == expectedAccepted);
    assert(Wait(completed));
    assert(callbacks == 1 && success == expectedSuccess && offMain);
}

static NSDictionary *OnlyItem(RUINRetainedMediaStore *store, NSDictionary *key) {
    NSArray *items = [store itemsForKey:key];
    assert(items.count == 1);
    return items[0];
}

static void WriteMetadata(NSDictionary *metadata, NSURL *url) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:metadata
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    assert(data && [data writeToURL:url options:NSDataWritingAtomic error:nil]);
    assert([NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600}
        ofItemAtPath:url.path error:nil]);
}

static void TestNoCreateReads(RUINRetainedMediaStore *store, NSURL *archiveRoot) {
    NSDictionary *missing = MessageKey(@"never-created-store", @"talk", @"never-created-chat", @"81");
    assert([NSFileManager.defaultManager contentsOfDirectoryAtURL:archiveRoot
        includingPropertiesForKeys:nil options:0 error:nil].count == 0);
    assert([store itemsForKey:missing].count == 0);
    assert(![store isUnsentForKey:missing]);
    assert([NSFileManager.defaultManager contentsOfDirectoryAtURL:archiveRoot
        includingPropertiesForKeys:nil options:0 error:nil].count == 0);
}

static void TestNamespacesAndDuplicates(RUINRetainedMediaStore *store,
                                        NSURL *allowedRoot,
                                        NSDictionary *baseKey) {
    NSData *first = [@"first committed bytes" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *second = [@"replacement bytes" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *source = WriteFile(allowedRoot, @"photo.data", first);
    CheckCaptureURL(store, source, @[allowedRoot], baseKey, @"photo", YES, YES);
    NSDictionary *item = OnlyItem(store, baseKey);
    assert([item[@"role"] isEqual:@"photo"] && [item[@"byteCount"] unsignedLongLongValue] == first.length);
    NSURL *itemURL = item[@"URL"];
    assert([[NSData dataWithContentsOfURL:itemURL] isEqualToData:first]);
    assert(![itemURL.path containsString:baseKey[@"store"]]);
    assert(![itemURL.path containsString:baseKey[@"chat"]]);

    CheckCaptureData(store, second, @"png", baseKey, @"photo", YES, YES);
    item = OnlyItem(store, baseKey);
    itemURL = item[@"URL"];
    assert([[NSData dataWithContentsOfURL:itemURL] isEqualToData:first]);

    NSArray *fields = @[@"store", @"kind", @"chat", @"message"];
    NSMutableSet<NSString *> *scopePaths = [NSMutableSet setWithObject:
        [[item[@"URL"] URLByDeletingLastPathComponent].URLByDeletingLastPathComponent path]];
    for (NSString *field in fields) {
        NSMutableDictionary *variant = [baseKey mutableCopy];
        if ([field isEqual:@"kind"]) variant[field] = @"square";
        else if ([field isEqual:@"message"]) variant[field] = @"90210";
        else variant[field] = [@"other-" stringByAppendingString:field];
        CheckCaptureData(store, first, @"jpg", variant, @"photo", YES, YES);
        NSDictionary *variantItem = OnlyItem(store, variant);
        NSString *scope = [[variantItem[@"URL"] URLByDeletingLastPathComponent].URLByDeletingLastPathComponent path];
        assert(![scopePaths containsObject:scope]);
        [scopePaths addObject:scope];
    }
    assert(scopePaths.count == 5);

    NSMutableDictionary *nativeKey = [baseKey mutableCopy];
    nativeKey[@"sender"] = @"optional-native-sender";
    CheckCaptureData(store, first, @"mov", nativeKey, @"video", YES, YES);
    NSArray *nativeItems = [store itemsForKey:nativeKey];
    assert(nativeItems.count == 2);
    for (NSDictionary *nativeItem in nativeItems) {
        NSString *scope = [[nativeItem[@"URL"] URLByDeletingLastPathComponent].URLByDeletingLastPathComponent path];
        assert([scope isEqualToString:[[itemURL URLByDeletingLastPathComponent].URLByDeletingLastPathComponent path]]);
    }
}

static void TestNativeThumbnailExtension(RUINRetainedMediaStore *store, NSURL *allowedRoot) {
    NSData *png = [[NSData alloc] initWithBase64EncodedString:@"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jQmcAAAAASUVORK5CYII=" options:0];
    NSURL *source = WriteFile(allowedRoot, @"native.thumb", png);
    NSDictionary *key = MessageKey(@"image-type-store", @"talk", @"image-type-chat", @"19");
    CheckCaptureURL(store, source, @[allowedRoot], key, @"thumbnail", YES, YES);
    NSDictionary *item = OnlyItem(store, key);
    assert([[item[@"URL"] pathExtension] isEqual:@"png"]);
    assert([[NSData dataWithContentsOfURL:item[@"URL"]] isEqual:png]);
}

static void TestMalformedMetadata(RUINRetainedMediaStore *store, NSDictionary *key) {
    CheckCaptureData(store, [@"safe" dataUsingEncoding:NSUTF8StringEncoding], @"jpg", key, @"audio", YES, YES);
    NSDictionary *item = OnlyItem(store, key);
    NSURL *roleURL = [item[@"URL"] URLByDeletingLastPathComponent];
    NSURL *metadataURL = [roleURL URLByAppendingPathComponent:@"metadata.plist"];
    NSDictionary *original = [NSDictionary dictionaryWithContentsOfURL:metadataURL];
    assert(original.count == 5);

    NSMutableDictionary *bad = [original mutableCopy];
    bad[@"filename"] = @"../../outside";
    WriteMetadata(bad, metadataURL);
    assert([store itemsForKey:key].count == 0);

    bad = [original mutableCopy];
    bad[@"role"] = @"video";
    WriteMetadata(bad, metadataURL);
    assert([store itemsForKey:key].count == 0);

    bad = [original mutableCopy];
    bad[@"type"] = @"../outside";
    WriteMetadata(bad, metadataURL);
    assert([store itemsForKey:key].count == 0);

    bad = [original mutableCopy];
    bad[@"byteCount"] = @([original[@"byteCount"] unsignedLongLongValue] + 1);
    WriteMetadata(bad, metadataURL);
    assert([store itemsForKey:key].count == 0);
    WriteMetadata(original, metadataURL);
    assert([store itemsForKey:key].count == 1);
}

static void TestSourceAndArchiveSymlinks(RUINRetainedMediaStore *store,
                                         NSURL *archiveRoot,
                                         NSURL *allowedRoot,
                                         NSURL *outsideRoot) {
    NSDictionary *key = MessageKey(@"symlink-store", @"talk", @"symlink-chat", @"91");
    NSURL *outside = WriteFile(outsideRoot, @"outside.bin", [@"outside" dataUsingEncoding:NSUTF8StringEncoding]);
    NSURL *outsideLink = [allowedRoot URLByAppendingPathComponent:@"outside-link.bin"];
    assert([NSFileManager.defaultManager createSymbolicLinkAtURL:outsideLink withDestinationURL:outside error:nil]);
    CheckCaptureURL(store, outside, @[allowedRoot], key, @"file", NO, NO);
    CheckCaptureURL(store, outsideLink, @[allowedRoot], key, @"file", NO, NO);

    NSDictionary *assetKey = MessageKey(@"file-symlink-store", @"talk", @"file-symlink-chat", @"92");
    CheckCaptureData(store, [@"asset" dataUsingEncoding:NSUTF8StringEncoding], @"bin", assetKey, @"audio", YES, YES);
    NSURL *assetURL = OnlyItem(store, assetKey)[@"URL"];
    assert([NSFileManager.defaultManager removeItemAtURL:assetURL error:nil]);
    assert([NSFileManager.defaultManager createSymbolicLinkAtURL:assetURL withDestinationURL:outside error:nil]);
    assert([store itemsForKey:assetKey].count == 0);

    NSDictionary *roleKey = MessageKey(@"role-symlink-store", @"talk", @"role-symlink-chat", @"93");
    CheckCaptureData(store, [@"role" dataUsingEncoding:NSUTF8StringEncoding], @"bin", roleKey, @"photo", YES, YES);
    NSURL *roleURL = [OnlyItem(store, roleKey)[@"URL"] URLByDeletingLastPathComponent];
    NSURL *scopeURL = [roleURL URLByDeletingLastPathComponent];
    NSURL *movedRole = [scopeURL URLByAppendingPathComponent:@"moved-role" isDirectory:YES];
    assert([NSFileManager.defaultManager moveItemAtURL:roleURL toURL:movedRole error:nil]);
    assert([NSFileManager.defaultManager createSymbolicLinkAtURL:roleURL withDestinationURL:movedRole error:nil]);
    assert([store itemsForKey:roleKey].count == 0);

    NSDictionary *scopeKey = MessageKey(@"scope-symlink-store", @"talk", @"scope-symlink-chat", @"94");
    CheckCaptureData(store, [@"scope" dataUsingEncoding:NSUTF8StringEncoding], @"bin", scopeKey, @"photo", YES, YES);
    scopeURL = [[OnlyItem(store, scopeKey)[@"URL"] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
    NSURL *movedScope = [archiveRoot URLByAppendingPathComponent:@"moved-scope" isDirectory:YES];
    assert([NSFileManager.defaultManager moveItemAtURL:scopeURL toURL:movedScope error:nil]);
    assert([NSFileManager.defaultManager createSymbolicLinkAtURL:scopeURL withDestinationURL:movedScope error:nil]);
    assert([store itemsForKey:scopeKey].count == 0);
}

static void TestEmptyFile(RUINRetainedMediaStore *store, NSURL *allowedRoot) {
    NSDictionary *key = MessageKey(@"empty-store", @"square", @"empty-chat", @"101");
    NSURL *empty = WriteFile(allowedRoot, @"empty.bin", [NSData data]);
    CheckCaptureURL(store, empty, @[allowedRoot], key, @"file", YES, YES);
    CheckCaptureURL(store, empty, @[allowedRoot], MessageKey(@"empty-media-store", @"talk", @"empty-media-chat", @"92"), @"video", NO, NO);
    NSDictionary *item = OnlyItem(store, key);
    assert([item[@"byteCount"] unsignedLongLongValue] == 0);
    assert([NSData dataWithContentsOfURL:item[@"URL"]].length == 0);
}

static NSURL *ScopeURLForItem(NSDictionary *item) {
    return [[item[@"URL"] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
}

static NSDictionary *FIFOKey(NSString *kind) {
    return MessageKey(@"fifo-store", @"talk", kind, @"301");
}

static int CheckFIFORead(NSString *kind, NSURL *archiveRoot) {
    RUINRetainedMediaStore *store = [[RUINRetainedMediaStore alloc] initWithDirectoryURL:archiveRoot error:nil];
    assert(store);
    NSDictionary *key = FIFOKey(kind);
    if ([kind isEqualToString:@"marker"]) {
        assert(![store isUnsentForKey:key]);
        assert(![store markUnsentForKey:key]);
    } else {
        assert([kind isEqualToString:@"metadata"] || [kind isEqualToString:@"asset"]);
        assert([store itemsForKey:key].count == 0);
    }
    return 0;
}

static double MonotonicSeconds(void) {
    struct timespec now;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

static BOOL CheckFIFOChild(NSString *kind, NSURL *archiveRoot) {
    char executable[PATH_MAX];
    uint32_t capacity = sizeof(executable);
    assert(_NSGetExecutablePath(executable, &capacity) == 0);
    char *arguments[] = {executable, "--fifo-read", (char *)kind.UTF8String,
        (char *)archiveRoot.fileSystemRepresentation, NULL};
    pid_t child;
    assert(posix_spawn(&child, executable, NULL, NULL, arguments, environ) == 0);
    double deadline = MonotonicSeconds() + 3.0;
    int status = 0;
    for (;;) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) {
            BOOL passed = WIFEXITED(status) && WEXITSTATUS(status) == 0;
            if (!passed) fprintf(stderr, "FIFO %s check failed\n", kind.UTF8String);
            return passed;
        }
        if (result < 0 && errno == EINTR) continue;
        assert(result == 0);
        if (MonotonicSeconds() >= deadline) {
            assert(kill(child, SIGKILL) == 0 || errno == ESRCH);
            while (waitpid(child, &status, 0) < 0) assert(errno == EINTR);
            fprintf(stderr, "FIFO %s check exceeded process deadline\n", kind.UTF8String);
            return NO;
        }
        usleep(10000);
    }
}

static BOOL TestFIFOReadRejection(RUINRetainedMediaStore *store, NSURL *archiveRoot) {
    BOOL passed = YES;
    for (NSString *kind in @[@"marker", @"metadata", @"asset"]) {
        NSDictionary *key = FIFOKey(kind);
        CheckCaptureData(store, [@"regular asset" dataUsingEncoding:NSUTF8StringEncoding], @"bin", key, @"file", YES, YES);
        NSDictionary *item = OnlyItem(store, key);
        NSURL *target = item[@"URL"];
        if ([kind isEqualToString:@"marker"]) {
            assert([store markUnsentForKey:key]);
            target = [ScopeURLForItem(item) URLByAppendingPathComponent:@"unsent.plist"];
        } else if ([kind isEqualToString:@"metadata"]) {
            target = [target.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"metadata.plist"];
        }
        assert([NSFileManager.defaultManager removeItemAtURL:target error:nil]);
        assert(mkfifo(target.fileSystemRepresentation, 0600) == 0);
        assert(chmod(target.fileSystemRepresentation, 0600) == 0);
        // No writer ever opens the FIFO. Re-exec avoids forking Objective-C
        // after dispatch workers start; the parent kills/reaps a blocked read.
        if (!CheckFIFOChild(kind, archiveRoot)) passed = NO;
        struct stat status;
        assert(lstat(target.fileSystemRepresentation, &status) == 0 && S_ISFIFO(status.st_mode));
    }
    return passed;
}

static void TestUnsentMarkers(RUINRetainedMediaStore *store,
                              NSURL *archiveRoot,
                              NSURL *outsideRoot) {
    NSDictionary *key = MessageKey(@"marker-store", @"talk", @"marker-chat", @"201");
    NSDictionary *otherKey = MessageKey(@"marker-store", @"talk", @"marker-chat", @"202");
    CheckCaptureData(store, [@"committed" dataUsingEncoding:NSUTF8StringEncoding], @"bin", key, @"photo", YES, YES);
    assert([store itemsForKey:key].count == 1);
    assert(![store isUnsentForKey:otherKey]);
    assert([store markUnsentForKey:key]);
    assert([store isUnsentForKey:key]);
    assert([store itemsForKey:key].count == 1);

    NSURL *scopeURL = ScopeURLForItem(OnlyItem(store, key));
    NSURL *markerURL = [scopeURL URLByAppendingPathComponent:@"unsent.plist"];
    struct stat markerStatus;
    assert(stat(markerURL.fileSystemRepresentation, &markerStatus) == 0 && (markerStatus.st_mode & 0777) == 0600);

    NSError *error = nil;
    RUINRetainedMediaStore *reopened = [[RUINRetainedMediaStore alloc] initWithDirectoryURL:archiveRoot error:&error];
    assert(reopened && !error && [reopened isUnsentForKey:key]);
    assert(![reopened isUnsentForKey:otherKey] && [reopened itemsForKey:key].count == 1);
    assert([reopened markUnsentForKey:key]);

    NSDictionary *malformedKey = MessageKey(@"malformed-marker-store", @"square", @"marker-chat", @"203");
    CheckCaptureData(store, [@"malformed" dataUsingEncoding:NSUTF8StringEncoding], @"bin",
        malformedKey, @"audio", YES, YES);
    NSURL *malformedURL = [[ScopeURLForItem(OnlyItem(store, malformedKey))
        URLByAppendingPathComponent:@"unsent.plist"] copy];
    assert([store markUnsentForKey:malformedKey]);
    WriteMetadata(@{@"version":@2, @"state":@"unsent"}, malformedURL);
    assert(![store isUnsentForKey:malformedKey]);
    assert(![store markUnsentForKey:malformedKey]);

    NSDictionary *symlinkKey = MessageKey(@"symlink-marker-store", @"talk", @"marker-chat", @"204");
    CheckCaptureData(store, [@"symlink marker" dataUsingEncoding:NSUTF8StringEncoding], @"bin",
        symlinkKey, @"file", YES, YES);
    NSURL *symlinkMarker = [[ScopeURLForItem(OnlyItem(store, symlinkKey))
        URLByAppendingPathComponent:@"unsent.plist"] copy];
    assert([store markUnsentForKey:symlinkKey]);
    assert([NSFileManager.defaultManager removeItemAtURL:symlinkMarker error:nil]);
    NSURL *outside = WriteFile(outsideRoot, @"marker-target.plist", [NSData data]);
    assert([NSFileManager.defaultManager createSymbolicLinkAtURL:symlinkMarker withDestinationURL:outside error:nil]);
    assert(![store isUnsentForKey:symlinkKey] && ![store markUnsentForKey:symlinkKey]);

    NSDictionary *directoryKey = MessageKey(@"symlink-marker-directory", @"talk", @"marker-chat", @"205");
    CheckCaptureData(store, [@"symlink scope" dataUsingEncoding:NSUTF8StringEncoding], @"bin",
        directoryKey, @"video", YES, YES);
    assert([store markUnsentForKey:directoryKey]);
    scopeURL = ScopeURLForItem(OnlyItem(store, directoryKey));
    NSURL *movedScope = [archiveRoot URLByAppendingPathComponent:@"moved-marker-scope" isDirectory:YES];
    assert([NSFileManager.defaultManager moveItemAtURL:scopeURL toURL:movedScope error:nil]);
    assert([NSFileManager.defaultManager createSymbolicLinkAtURL:scopeURL withDestinationURL:movedScope error:nil]);
    assert(![store isUnsentForKey:directoryKey] && ![store markUnsentForKey:directoryKey]);
}

static void TestNilAndReentrantCompletion(RUINRetainedMediaStore *store, NSURL *allowedRoot) {
    NSDictionary *nilCompletionKey = MessageKey(@"nil-completion", @"talk", @"completion-chat", @"105");
    assert([store captureData:[@"nil completion" dataUsingEncoding:NSUTF8StringEncoding] extension:@"bin"
        forKey:nilCompletionKey role:@"thumbnail" completion:nil]);
    CheckCaptureData(store, [@"queue barrier" dataUsingEncoding:NSUTF8StringEncoding], @"bin",
        MessageKey(@"completion-barrier", @"talk", @"completion-chat", @"106"), @"thumbnail", YES, YES);
    assert(OnlyItem(store, nilCompletionKey));

    NSDictionary *outerKey = MessageKey(@"outer-completion", @"talk", @"completion-chat", @"107");
    NSDictionary *nestedKey = MessageKey(@"nested-completion", @"talk", @"completion-chat", @"108");
    NSURL *nestedSource = WriteFile(allowedRoot, @"nested-capture.bin", [@"nested capture" dataUsingEncoding:NSUTF8StringEncoding]);
    dispatch_semaphore_t nestedDone = dispatch_semaphore_create(0);
    __block BOOL outerSuccess = NO, nestedAccepted = NO, nestedSuccess = NO, nestedOffMain = NO;
    assert([store captureData:[@"outer capture" dataUsingEncoding:NSUTF8StringEncoding] extension:@"bin"
        forKey:outerKey role:@"thumbnail" completion:^(BOOL success) {
            outerSuccess = success;
            nestedAccepted = [store captureURL:nestedSource allowedRoots:@[allowedRoot] forKey:nestedKey role:@"file"
                completion:^(BOOL result) {
                    nestedSuccess = result;
                    nestedOffMain = !NSThread.isMainThread;
                    dispatch_semaphore_signal(nestedDone);
                }];
        }]);
    assert(Wait(nestedDone));
    assert(outerSuccess && nestedAccepted && nestedSuccess && nestedOffMain);
    NSDictionary *nestedItem = OnlyItem(store, nestedKey);
    assert([[NSData dataWithContentsOfURL:nestedItem[@"URL"]]
        isEqualToData:[@"nested capture" dataUsingEncoding:NSUTF8StringEncoding]]);
}

static void TestDescriptorBeforeUnlink(RUINRetainedMediaStore *store,
                                       NSURL *allowedRoot) {
    NSDictionary *blockerKey = MessageKey(@"queue-blocker", @"talk", @"queue-chat", @"111");
    NSDictionary *pendingKey = MessageKey(@"pending-source", @"talk", @"queue-chat", @"112");
    NSURL *pendingSource = WriteFile(allowedRoot, @"pending-source.bin", [@"survives unlink" dataUsingEncoding:NSUTF8StringEncoding]);
    dispatch_semaphore_t entered = dispatch_semaphore_create(0);
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    dispatch_semaphore_t pendingDone = dispatch_semaphore_create(0);
    dispatch_semaphore_t blockerDone = dispatch_semaphore_create(0);
    __block BOOL blockerSuccess = NO, pendingSuccess = NO, pendingOffMain = NO;
    __block NSUInteger pendingCallbacks = 0;

    assert([store captureData:[@"block" dataUsingEncoding:NSUTF8StringEncoding] extension:@"bin"
        forKey:blockerKey role:@"thumbnail" completion:^(BOOL success) {
            blockerSuccess = success;
            dispatch_semaphore_signal(entered);
            dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
            dispatch_semaphore_signal(blockerDone);
        }]);
    assert(Wait(entered) && blockerSuccess);
    assert([store captureURL:pendingSource allowedRoots:@[allowedRoot] forKey:pendingKey role:@"file"
        completion:^(BOOL success) {
            pendingSuccess = success;
            pendingOffMain = !NSThread.isMainThread;
            pendingCallbacks++;
            dispatch_semaphore_signal(pendingDone);
        }]);
    assert([NSFileManager.defaultManager removeItemAtURL:pendingSource error:nil]);
    assert([store markUnsentForKey:pendingKey] && [store isUnsentForKey:pendingKey]);
    dispatch_semaphore_signal(release);
    assert(Wait(blockerDone) && Wait(pendingDone));
    assert(pendingSuccess && pendingOffMain && pendingCallbacks == 1);
    NSDictionary *item = OnlyItem(store, pendingKey);
    assert([[NSData dataWithContentsOfURL:item[@"URL"]] isEqualToData:[@"survives unlink" dataUsingEncoding:NSUTF8StringEncoding]]);
}

static void TestSymlinkRootRejected(NSURL *parent, NSURL *realRoot) {
    NSURL *link = [parent URLByAppendingPathComponent:@"archive-link" isDirectory:YES];
    assert([NSFileManager.defaultManager createSymbolicLinkAtURL:link withDestinationURL:realRoot error:nil]);
    NSError *error = nil;
    assert(![[RUINRetainedMediaStore alloc] initWithDirectoryURL:link error:&error]);
    assert(error && ![error.localizedDescription containsString:realRoot.path]);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 4 && !strcmp(argv[1], "--fifo-read"))
            return CheckFIFORead([NSString stringWithUTF8String:argv[2]],
                [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]] isDirectory:YES]);
        assert(argc == 1);
        NSURL *temporary = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
        NSURL *fixtureRoot = MakeDirectory(temporary, [@"ruin-retained-media-" stringByAppendingString:NSUUID.UUID.UUIDString]);
        NSURL *allowedRoot = MakeDirectory(fixtureRoot, @"allowed");
        NSURL *outsideRoot = MakeDirectory(fixtureRoot, @"outside");
        NSURL *archiveRoot = [fixtureRoot URLByAppendingPathComponent:@"archive" isDirectory:YES];
        NSError *error = nil;
        RUINRetainedMediaStore *store = [[RUINRetainedMediaStore alloc] initWithDirectoryURL:archiveRoot error:&error];
        assert(store && !error);
        struct stat rootStatus;
        assert(stat(archiveRoot.fileSystemRepresentation, &rootStatus) == 0 && (rootStatus.st_mode & 0777) == 0700);

        assert(![store hasAnyScopes]);
        TestNoCreateReads(store, archiveRoot);
        assert(![store hasAnyScopes]);
        TestNativeThumbnailExtension(store, allowedRoot);
        assert([store hasAnyScopes]);
        RUINRetainedMediaStore *reopened = [[RUINRetainedMediaStore alloc] initWithDirectoryURL:archiveRoot error:&error];
        assert(reopened && !error && [reopened hasAnyScopes]);
        NSDictionary *baseKey = MessageKey(@"raw-store-sentinel", @"talk", @"raw-chat-sentinel", @"123456789");
        TestNamespacesAndDuplicates(store, allowedRoot, baseKey);
        TestMalformedMetadata(store, MessageKey(@"metadata-store", @"square", @"metadata-chat", @"81"));
        TestSourceAndArchiveSymlinks(store, archiveRoot, allowedRoot, outsideRoot);
        TestEmptyFile(store, allowedRoot);
        TestUnsentMarkers(store, archiveRoot, outsideRoot);
        TestNilAndReentrantCompletion(store, allowedRoot);
        TestDescriptorBeforeUnlink(store, allowedRoot);
        TestSymlinkRootRejected(fixtureRoot, archiveRoot);
        BOOL fifoReadsPassed = TestFIFOReadRejection(store, archiveRoot);

        NSDictionary *diagnostics = store.diagnostics;
        assert(diagnostics.count == 8);
        for (id value in diagnostics.allValues) assert([value isKindOfClass:NSNumber.class]);
        assert([diagnostics[@"capturesSucceeded"] unsignedLongLongValue] > 0);
        assert([diagnostics[@"capturesFailed"] unsignedLongLongValue] > 0);

        assert([NSFileManager.defaultManager removeItemAtURL:fixtureRoot error:nil]);
        if (!fifoReadsPassed) return 1;
        puts("retained media store checks passed");
    }
    return 0;
}
