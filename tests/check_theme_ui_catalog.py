#!/usr/bin/env python3
"""Exercise production saved-file deduplication and section rows on Foundation."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
THEMES = ROOT / "src/themes"


def extract(source, start, end):
    assert source.count(start) == source.count(end) == 1
    return source[source.index(start):source.index(end, source.index(start))]


CHECK = r'''
static NSDictionary *Archive(NSURL *root, NSString *file, NSString *product, NSString *version) {
    NSURL *URL = [root URLByAppendingPathComponent:file];
    assert([@"unchanged archive fixture" writeToURL:URL atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    return @{@"name":@"BT21 DOODLE", @"productID":product, @"version":version,
        @"versionString":@"V1.01", @"packageURL":URL,
        @"downloadedLocally":@YES, @"archiveStructureValidated":@YES};
}
int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2);
    NSURL *root = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
    NSString *ID = @"8d024db7-a7e3-4529-9645-140b2959bede";
    NSDictionary *first = Archive(root, @"a.linetheme", ID.uppercaseString, @"2");
    NSDictionary *copy = Archive(root, @"z.linetheme", ID, @"2");
    NSDictionary *newer = Archive(root, @"newer.linetheme", ID, @"3");
    NSDictionary *other = Archive(root, @"other.linetheme", @"313c6eb8-8584-4f5f-b849-b2b0c7e1c43d", @"2");
    NSDictionary *mixed = Archive(root, @"mixed.linetheme", @"MixedSKU1", @"2");
    NSDictionary *lower = Archive(root, @"lower.linetheme", @"mixedsku1", @"2");
    NSArray *input = @[copy, first, newer, other, mixed, lower];
    NSArray *visible = RUINThemeUIVisibleArchives(input);
    assert(visible.count == 5 && visible[0] == first);
    assert([visible containsObject:newer] && [visible containsObject:other]);
    assert([visible containsObject:mixed] && [visible containsObject:lower]);
    assert(RUINThemeUIVisibleArchives(@[first, copy]).firstObject == first);
    assert(RUINThemeUIVisibleArchives(@[copy, first]).firstObject == first);
    assert([first[@"productID"] isEqual:ID.uppercaseString]); // Never rewrite catalog metadata.

    NSMutableDictionary *displayVersion = [copy mutableCopy];
    [displayVersion removeObjectForKey:@"version"];
    assert(RUINThemeUIVisibleArchives(@[first, displayVersion]).count == 1);
    NSMutableDictionary *unknown = [copy mutableCopy];
    unknown[@"version"] = @"unknown"; unknown[@"versionString"] = @"unknown";
    assert(RUINThemeUIVisibleArchives(@[first, unknown]).count == 2);
    NSMutableDictionary *missingID = [copy mutableCopy]; [missingID removeObjectForKey:@"productID"];
    assert(RUINThemeUIVisibleArchives(@[first, missingID]).count == 2);
    NSMutableDictionary *invalid = [copy mutableCopy]; invalid[@"archiveStructureValidated"] = @NO;
    assert(RUINThemeUIVisibleArchives(@[invalid]).count == 0);
    // Raw CDN versions preserve leading zeros; do not conflate distinct paths.
    NSMutableDictionary *zeroVersion = [copy mutableCopy]; zeroVersion[@"version"] = @"02";
    assert(RUINThemeUIVisibleArchives(@[first, zeroVersion]).count == 2);
    assert([RUINThemeUIName(first) isEqual:@"BT21 DOODLE"]);
    assert([RUINThemeUIVersion(first) isEqual:@"V1.01"]);
    for (NSDictionary *record in input) {
        NSString *bytes = [NSString stringWithContentsOfURL:record[@"packageURL"] encoding:NSUTF8StringEncoding error:NULL];
        assert([bytes isEqual:@"unchanged archive fixture"]);
    }
    assert([NSFileManager.defaultManager contentsOfDirectoryAtPath:root.path error:NULL].count == input.count);

    RUINThemeSettingsViewController *controller = [RUINThemeSettingsViewController new];
    controller.archives = visible; controller.nativeRecords = @[@{}];
    assert([controller numberOfSectionsInTableView:nil] == 4);
    assert(RUINThemeUISectionDownload == 0 && RUINThemeUISectionShop == 1 &&
        RUINThemeUISectionSaved == 2 && RUINThemeUISectionNative == 3);
    assert([controller tableView:nil numberOfRowsInSection:RUINThemeUISectionShop] == 2);
    assert([controller tableView:nil numberOfRowsInSection:RUINThemeUISectionSaved] == 5);
    assert([controller tableView:nil numberOfRowsInSection:RUINThemeUISectionNative] == 1);
    assert([[controller tableView:nil titleForHeaderInSection:RUINThemeUISectionShop] isEqual:@"shops.theme_title"]);
    controller.archives = @[];
    assert([controller tableView:nil numberOfRowsInSection:RUINThemeUISectionSaved] == 1);
    puts("PASS production saved UI ID/version dedup, distinct versions/IDs, unchanged archives and shop section order");
} return 0; }
'''


def main():
    source = (THEMES / "ThemeUI.m").read_text()
    helpers = extract(source, "typedef NS_ENUM(NSInteger, RUINThemeUISection)", "static NSString *RUINThemeUINativeStatus(")
    methods = extract(source, "- (NSInteger)numberOfSectionsInTableView:", "- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:")
    shim = '''#import <Foundation/Foundation.h>
#import "ThemeProductIdentity.h"
#import "ThemeVersion.h"
#include <assert.h>
#include <stdio.h>
static NSString *RUINLocalizedString(NSString *key) { return key; }
@interface UITableView : NSObject @end
@interface RUINThemeSettingsViewController : NSObject
@property(nonatomic, copy) NSArray *archives, *nativeRecords;
@property(nonatomic) BOOL hasDownloadStatus;
@property(nonatomic, strong) NSError *catalogError;
@end
'''
    with tempfile.TemporaryDirectory(prefix="ruin-theme-ui-catalog-") as temporary:
        directory = Path(temporary)
        data = directory / "archives"
        data.mkdir()
        fixture = directory / "check.m"
        fixture.write_text(shim + helpers + "@implementation RUINThemeSettingsViewController\n" + methods + "\n@end\n" + CHECK)
        executable = directory / "check"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks",
            "-Wall", "-Wextra", "-Werror", "-I", str(THEMES), str(fixture),
            str(THEMES / "ThemeVersion.m"), "-framework", "Foundation", "-o", str(executable)],
            cwd=ROOT, check=True, timeout=30)
        subprocess.run([str(executable), str(data)], cwd=ROOT, check=True, timeout=20)


if __name__ == "__main__":
    main()
