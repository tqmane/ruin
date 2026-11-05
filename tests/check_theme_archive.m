#import <Foundation/Foundation.h>
#import "ThemeArchive.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSUInteger RegularFileCount(NSURL *directoryURL)
{
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:directoryURL
        includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey]
        options:0
        errorHandler:^BOOL(NSURL *url, NSError *error) { (void)url; (void)error; return NO; }];
    NSUInteger count = 0;
    for (NSURL *url in enumerator) {
        NSNumber *isLink = nil, *isRegular = nil;
        assert([url getResourceValue:&isLink forKey:NSURLIsSymbolicLinkKey error:NULL]);
        assert(!isLink.boolValue);
        assert([url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:NULL]);
        if (isRegular.boolValue) count++;
    }
    return count;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        assert(argc == 5);
        NSURL *archiveURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        BOOL expectSuccess = strcmp(argv[2], "accept") == 0;
        assert(expectSuccess || strcmp(argv[2], "reject") == 0);
        NSUInteger expectedFiles = (NSUInteger)strtoull(argv[3], NULL, 10);
        uint32_t expectedRevision = (uint32_t)strtoul(argv[4], NULL, 10);

        char tempTemplate[] = "/tmp/ruin-theme-archive-check-XXXXXX";
        char *tempPath = mkdtemp(tempTemplate);
        assert(tempPath);
        NSString *tempRoot = [NSString stringWithUTF8String:tempPath];
        NSString *stageRootPath = [tempRoot stringByAppendingPathComponent:@"stage-root"];
        assert([[NSFileManager defaultManager] createDirectoryAtPath:stageRootPath
                                         withIntermediateDirectories:NO
                                                          attributes:@{NSFilePosixPermissions:@0700}
                                                               error:NULL]);
        NSURL *stageRootURL = [NSURL fileURLWithPath:stageRootPath isDirectory:YES];

        if (expectSuccess) {
            NSString *linkPath = [tempRoot stringByAppendingPathComponent:@"stage-link"];
            assert(symlink(stageRootPath.fileSystemRepresentation, linkPath.fileSystemRepresentation) == 0);
            NSError *linkError = nil;
            assert(RUINStageThemeArchiveAtURL(archiveURL, [NSURL fileURLWithPath:linkPath isDirectory:YES], &linkError) == nil);
            assert(linkError != nil);
            assert([[NSFileManager defaultManager] contentsOfDirectoryAtPath:stageRootPath error:NULL].count == 0);
        }

        NSError *error = nil;
        NSURL *stagedURL = RUINStageThemeArchiveAtURL(archiveURL, stageRootURL, &error);
        if (!expectSuccess) {
            assert(stagedURL == nil && error != nil);
            assert([[NSFileManager defaultManager] contentsOfDirectoryAtPath:stageRootPath error:NULL].count == 0);
            assert(![[NSFileManager defaultManager] fileExistsAtPath:[tempRoot stringByAppendingPathComponent:@"escape"]]);
        } else {
            assert(stagedURL && !error);
            assert([[NSUUID alloc] initWithUUIDString:stagedURL.lastPathComponent] != nil);
            NSArray *stages = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:stageRootPath error:NULL];
            assert(stages.count == 1 && [stages.firstObject isEqualToString:stagedURL.lastPathComponent]);
            assert(RegularFileCount(stagedURL) == expectedFiles);
            NSData *manifestData = [NSData dataWithContentsOfURL:[stagedURL URLByAppendingPathComponent:@"theme.json"]];
            NSDictionary *document = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:NULL];
            NSDictionary *manifest = document[@"manifest"];
            assert([manifest[@"schemaVersion"] unsignedIntValue] > 0);
            assert([manifest[@"revision"] unsignedIntValue] > 0);
            if (expectedRevision) assert([manifest[@"revision"] unsignedIntValue] == expectedRevision);
        }

        assert([[NSFileManager defaultManager] removeItemAtPath:tempRoot error:NULL]);
        printf("check_theme_archive: %s %s\n", argv[2], argv[1]);
    }
    return 0;
}
