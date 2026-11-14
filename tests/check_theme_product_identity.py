#!/usr/bin/env python3
"""Production download/catalog/workflow identity with real receipt persistence."""
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
THEMES = ROOT / "src/themes"


def extract(source, start, end):
    assert source.count(start) == source.count(end) == 1
    return source[source.index(start):source.index(end, source.index(start))]


SHIM = r'''
#import <Foundation/Foundation.h>
#import "ThemeFeatures.h"
#import "ThemeProductIdentity.h"
#import "ThemeVersion.h"
#import "NativeThemeReceipt.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

NSString * const RUINThemeErrorDomain = @"fixture.theme";
NSString * const RUINThemeShopDownloadEnabledDefaultsKey = @"fixture.download";
static const NSUInteger RUINThemeMaximumInputLength = 256;
static BOOL targetMatches = YES, preference = YES;
static BOOL RUINThemeTargetMatches(void) { return targetMatches; }
static NSString *RUINLocalizedString(NSString *key) { return key; }
static NSURL *support;
@interface FixtureFileManager : NSFileManager
+ (instancetype)defaultManager;
@end
@implementation FixtureFileManager
+ (instancetype)defaultManager { return [self new]; }
- (NSArray *)URLsForDirectory:(NSSearchPathDirectory)directory inDomains:(NSSearchPathDomainMask)domains {
    assert(directory == NSApplicationSupportDirectory && domains == NSUserDomainMask);
    return @[support];
}
@end
@interface FixtureDefaults : NSObject
+ (instancetype)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)key;
@end
@implementation FixtureDefaults
+ (instancetype)standardUserDefaults { return [self new]; }
- (BOOL)boolForKey:(NSString *)key { assert([key isEqual:RUINThemeShopDownloadEnabledDefaultsKey]); return preference; }
@end
static NSURL *requestedURL;
static NSString *requestedProduct;
static unsigned transfers;
// The network transfer is the seam; arguments come from the actual shared downloader.
@interface RUINThemeAssetTransfer : NSObject
- (void)startURL:(NSURL *)url productID:(NSString *)productID version:(NSString *)version
    displayName:(NSString *)name completion:(RUINThemeDownloadCompletion)completion;
@end
@implementation RUINThemeAssetTransfer
- (void)startURL:(NSURL *)url productID:(NSString *)productID version:(NSString *)version
    displayName:(NSString *)name completion:(RUINThemeDownloadCompletion)completion {
    assert([version isEqual:@"42"] && [name isEqual:@"Fixture"] && completion);
    requestedURL = url; requestedProduct = productID; transfers++;
}
@end
'''
CHECK = r'''
static void Drain(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ CFRunLoopStop(CFRunLoopGetMain()); });
    CFRunLoopRun();
}
int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2);
    support = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
    NSString *lower = @"313c6eb8-8584-4f5f-b849-b2b0c7e1c43d", *upper = lower.uppercaseString;
    assert([RUINCanonicalThemeProductID(upper) isEqual:lower]);
    for (NSString *value in @[@"MixedSKU1", @"mixedsku1", @"default", @"not-a-uuid", @"", @"{313C6EB8-8584-4F5F-B849-B2B0C7E1C43D}"])
        assert([RUINCanonicalThemeProductID(value) isEqual:value]);
    assert(!RUINCanonicalThemeProductID(nil) && !RUINCanonicalThemeProductID(NSNull.null));
    RUINThemeDownloadCompletion completion = ^(NSURL *url, NSError *error) { (void)url; (void)error; };
    RUINDownloadThemeByID(@"Fixture", upper, @"42", completion);
    assert(transfers == 1 && [requestedProduct isEqual:lower]);
    assert(([requestedURL.path isEqual:[NSString stringWithFormat:@"/themeshop/v1/products/31/3c/6e/%@/42/IOS/theme.zip", lower]]));
    preference = NO;
    RUINDownloadRegisteredTheme(@"Fixture", upper, @"42", completion);
    assert(transfers == 2 && [requestedProduct isEqual:lower]);
    preference = YES;
    RUINDownloadThemeByID(@"Fixture", @"MixedSKU1", @"42", completion);
    assert(transfers == 3 && [requestedProduct isEqual:@"MixedSKU1"]);
    assert([requestedURL.path containsString:@"/MixedSKU1/"]);

    NSError *error = nil;
    NSArray *catalog = RUINThemeDownloadedAssetCatalog(&error);
    assert(!error && catalog.count == 3);
    NSArray *preferred = RUINPreferredArchives(catalog);
    assert(preferred.count == 2); // UUID case aliases merge; non-UUID ID stays intact.
    NSDictionary *selected = nil;
    for (NSDictionary *row in preferred) if ([row[@"productID"] isEqual:lower]) selected = row;
    assert(selected && [selected[@"version"] isEqual:@"42"]);
    NSURL *archive = selected[@"packageURL"];
    assert([archive.path containsString:upper]); // Preserve historical storage paths.
    assert([NSFileManager.defaultManager fileExistsAtPath:archive.path]);
    NSMutableDictionary *legacy = [selected mutableCopy]; legacy[@"productID"] = upper;
    NSDictionary *normalized = RUINPreferredArchives(@[legacy]).firstObject;
    assert([normalized[@"productID"] isEqual:lower] && [legacy[@"productID"] isEqual:upper]);
    // These identities must remain distinct even on a case-insensitive host volume.
    NSMutableDictionary *mixed = [selected mutableCopy], *lowerMixed = [selected mutableCopy];
    mixed[@"productID"] = @"MixedSKU1"; lowerMixed[@"productID"] = @"mixedsku1";
    assert((RUINPreferredArchives(@[mixed, lowerMixed]).count == 2));

    NSString *account = [@"P_u" stringByAppendingString:
        [NSUUID.UUID.UUIDString.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""]];
    NSURL *root = [[[support URLByAppendingPathComponent:@"PrivateStore" isDirectory:YES]
        URLByAppendingPathComponent:account isDirectory:YES]
        URLByAppendingPathComponent:@"Theme Packages" isDirectory:YES];
    assert([NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:&error]);
    NSDictionary *metadata = @{@"productID":lower, @"name":@"Fixture", @"rawVersion":@42,
        @"versionString":@"V1.41", @"imagePath":[NSString stringWithFormat:@"/31/3c/6e/%@/42/ANDROID/theme.png",lower]};
    assert(RUINWriteThemeReceipt(root, metadata, archive.lastPathComponent, &error) && !error);
    NSDictionary *receipt = RUINReadThemeReceipts(root)[normalized[@"productID"]];
    assert([receipt[@"rawVersion"] isEqual:@42] && [receipt[@"archiveName"] isEqual:archive.lastPathComponent]);

    targetMatches = NO;
    __block BOOL returned = NO;
    RUINDownloadThemeByID(@"Fixture", upper, @"42", ^(NSURL *url, NSError *failure) {
        assert(!url && failure && ![failure.localizedDescription containsString:@"26.16"]); returned = YES;
    });
    Drain(); assert(returned && transfers == 3);
    puts("PASS production UUID download/catalog/workflow identity, non-UUID case and real receipt matching");
} return 0; }
'''


def main():
    features = (THEMES / "ThemeFeatures.x").read_text()
    workflow = (THEMES / "NativeThemeWorkflow.m").read_text()
    assert "26.16" not in features, "stale target description"
    error = extract(features, "static NSError *RUINThemeError(", "static BOOL RUINThemeFail(")
    paths = extract(features, "static BOOL RUINThemeSafeURLComponent(", "static const NSUInteger RUINThemeMaxArchiveBytes")
    validation = extract(features, "static const NSUInteger RUINThemeMaxArchiveBytes", "@interface RUINThemeAssetTransfer")
    catalog = extract(features, "static NSArray<NSDictionary<NSString *, id> *> *RUINThemeDownloadedAssetCatalog(", "static BOOL RUINThemeShopDetailRouteAvailable(")
    preferred = extract(workflow, "static NSString *RUINArchiveIdentity(", "@interface RUINNativeThemeImportJob")
    download = features[features.index("static void RUINDownloadThemeAsset("):]
    with tempfile.TemporaryDirectory(prefix="ruin-theme-identity-") as temporary:
        directory = Path(temporary)
        lower = "313c6eb8-8584-4f5f-b849-b2b0c7e1c43d"
        for product, version in ((lower.upper(), "42"), (lower, "41"), ("MixedSKU1", "1")):
            archive = directory / "RUINThemeDownloads" / product / version / "00000000-0000-0000-0000-000000000001.linetheme"
            archive.parent.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr("theme.json", "{}")
        fixture = directory / "check.m"
        fixture.write_text(SHIM + error + paths + validation +
            "\n#define NSFileManager FixtureFileManager\n" + catalog + "\n#undef NSFileManager\n" +
            preferred + "\n#define NSUserDefaults FixtureDefaults\n" + download + "\n#undef NSUserDefaults\n" + CHECK)
        executable = directory / "check"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11",
            "-Wall", "-Wextra", "-Werror", "-I", str(THEMES), str(fixture),
            str(THEMES / "ThemeVersion.m"), str(THEMES / "NativeThemeReceipt.m"),
            "-framework", "Foundation", "-o", str(executable)], cwd=ROOT, check=True, timeout=30)
        subprocess.run([str(executable), str(directory)], cwd=ROOT, check=True, timeout=10)


if __name__ == "__main__":
    main()
