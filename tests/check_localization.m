// Compile both the header-only host helper and the production resolver.
#define RUIN_HOST_CHECK 1
#define RUINLocalizedString RUINHostLocalizedString
#import "../src/core/Localization.h"
#undef RUINLocalizedString
#define RUIN_LOCALIZATION_HOST_CHECK 1
#import "../src/core/Localization.m"
#include <assert.h>
#include <stdlib.h>

static void CheckHostProcess(NSString *executable, NSString *directory, NSString *resources,
    NSString *key, NSString *expected) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.currentDirectoryURL = [NSURL fileURLWithPath:directory isDirectory:YES];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    if (resources) environment[@"RUIN_TEST_RESOURCE_BUNDLE"] = resources;
    else [environment removeObjectForKey:@"RUIN_TEST_RESOURCE_BUNDLE"];
    task.environment = environment;
    task.arguments = @[@"--host", key, expected];
    assert([task launchAndReturnError:NULL]);
    [task waitUntilExit];
    assert(task.terminationStatus == 0);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *key = @"settings.hide_read";
        NSString *unknown = @"tests.unknown_semantic_key";
        if (argc == 4 && [@(argv[1]) isEqual:@"--host"]) {
            assert([RUINHostLocalizedString(@(argv[2])) isEqual:@(argv[3])]);
            assert([RUINHostLocalizedString(unknown) isEqual:unknown]);
            return 0;
        }
        assert(argc == 2);
        NSString *bundlePath = [@(argv[1]) stringByStandardizingPath];
        NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
        assert(bundle);
        NSDictionary *expected = @{@"en":@"Suppress read receipts", @"ja":@"既読を隠す",
            @"ko":@"읽음 확인 숨기기", @"zh-Hans":@"隐藏已读", @"zh-Hant":@"隱藏已讀"};
        for (NSString *language in RUINSupportedLanguages()) {
            assert([RUINLocalizeInBundle(bundle, key, @[language]) isEqual:expected[language]]);
            assert([RUINLocalizeInBundle(bundle, unknown, @[language]) isEqual:unknown]);
            // Every shipped entry must resolve to its unchanged catalog value.
            NSDictionary *catalog = [NSDictionary dictionaryWithContentsOfFile:
                [bundlePath stringByAppendingPathComponent:
                    [language stringByAppendingString:@".lproj/Localizable.strings"]]];
            assert(catalog.count);
            for (NSString *entry in catalog)
                assert([RUINLocalizeInBundle(bundle, entry, @[language]) isEqual:catalog[entry]]);
        }
        assert([RUINLocalizeInBundle(bundle, key, @[@"fr-CA"]) isEqual:expected[@"en"]]);
        assert([RUINLocalizeInBundle(bundle, key, @[]) isEqual:expected[@"en"]]);
        assert([RUINLocalizeInBundle(nil, key, @[@"ja"]) isEqual:key]);
        NSDictionary *regional = @{@"en-GB":@"en", @"ja-JP":@"ja", @"ko-KR":@"ko",
            @"zh-TW":@"zh-Hant", @"zh-HK":@"zh-Hant", @"zh-CN":@"zh-Hans", @"zh-SG":@"zh-Hans"};
        for (NSString *preference in regional) {
            assert([RUINLanguageForPreferences(@[preference]) isEqual:regional[preference]]);
            assert([RUINLocalizeInBundle(bundle, key, @[preference]) isEqual:expected[regional[preference]]]);
        }
        assert([RUINLanguageForPreferences(@[@"fr", @"ko-KR"]) isEqual:@"ko"]);

        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        @try {
            assert([files createDirectoryAtPath:temporary withIntermediateDirectories:YES attributes:nil error:NULL]);
            assert(([@{@"CFBundleIdentifier":@"test.ruin.localization", @"CFBundleDevelopmentRegion":@"en"}
                writeToFile:[temporary stringByAppendingPathComponent:@"Info.plist"] atomically:YES]));
            // All locale bundles exist. The requested key is missing only from
            // the selected catalog, so this exercises per-key English fallback.
            for (NSString *language in RUINSupportedLanguages()) {
                NSString *directory = [temporary stringByAppendingPathComponent:[language stringByAppendingString:@".lproj"]];
                assert([files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
                NSDictionary *catalog = [language isEqual:@"en"]
                    ? @{key:@"English fallback", @"tests.english_only":@"English only",
                        @"tests.escaped":@"quote\" backslash\\ line\nnext\ttab 日本 😀"}
                    : @{@"tests.selected_only":expected[language]};
                NSString *contents = catalog.descriptionInStringsFileFormat;
                assert([contents writeToFile:[directory stringByAppendingPathComponent:@"Localizable.strings"]
                    atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
            }
            NSBundle *partial = [NSBundle bundleWithPath:temporary];
            assert(partial);
            for (NSString *language in RUINSupportedLanguages()) {
                assert([partial pathForResource:language ofType:@"lproj"]);
                assert([RUINLocalizeInBundle(partial, key, @[language]) isEqual:@"English fallback"]);
                assert([RUINLocalizeInBundle(partial, @"tests.english_only", @[language]) isEqual:@"English only"]);
                assert([RUINLocalizeInBundle(partial, @"tests.escaped", @[language])
                    isEqual:@"quote\" backslash\\ line\nnext\ttab 日本 😀"]);
                NSString *selectedOnly = [language isEqual:@"en"] ? @"tests.selected_only" : expected[language];
                assert([RUINLocalizeInBundle(partial, @"tests.selected_only", @[language]) isEqual:selectedOnly]);
                assert([RUINLocalizeInBundle(partial, unknown, @[language]) isEqual:unknown]);
            }
            assert([RUINLocalizeInBundle(partial, key, @[@"fr"]) isEqual:@"English fallback"]);

            // Host lookup must work outside the repo with an explicit bundle,
            // and from the repo root when the environment override is absent.
            NSString *executable = NSBundle.mainBundle.executablePath;
            CheckHostProcess(executable, temporary, bundlePath, key, @"既読を隠す");
            CheckHostProcess(executable, temporary, temporary, key, @"English fallback");
            NSString *root = [[bundlePath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
            CheckHostProcess(executable, root, nil, key, @"既読を隠す");
        } @finally {
            [files removeItemAtPath:temporary error:NULL];
        }
        setenv("RUIN_TEST_RESOURCE_BUNDLE", bundlePath.fileSystemRepresentation, 1);
        // Semantic IDs are not format literals. The resolved templates still
        // format the same human text, regardless of the host's preferred locale.
        assert(([[NSString stringWithFormat:RUINHostLocalizedString(@"common.label_value"), @"項目", @"値"]
            isEqual:@"項目：値"]));
        assert(([[NSString stringWithFormat:RUINHostLocalizedString(@"common.member_count"), (long)12]
            isEqual:@"12人"]));
        puts("PASS five catalogs, regional locales, per-key English fallback, unknown semantic keys, host bundle paths and formats");
    }
    return 0;
}
