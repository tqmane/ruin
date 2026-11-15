// Compile both the header-only host helper and the production resolver.
#define RUIN_HOST_CHECK 1
#define RUINLocalizedString RUINHostLocalizedString
#import "../src/core/Localization.h"
#undef RUINLocalizedString
#define RUIN_LOCALIZATION_HOST_CHECK 1
#import "../src/core/Localization.m"
#import <objc/runtime.h>
#import <ImageIO/ImageIO.h>
#include <assert.h>
#include <stdlib.h>

static NSURL *runtimeCache;
typedef NSArray<NSURL *> *(*DirectoryURLsIMP)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask);
static DirectoryURLsIMP originalDirectoryURLs;

static NSArray<NSURL *> *RuntimeDirectoryURLs(NSFileManager *files, SEL selector,
    NSSearchPathDirectory directory, NSSearchPathDomainMask domain) {
    // Isolate extraction to this child's fixture without changing production
    // code, other Foundation directories, or the user's real cache directory.
    if (directory == NSCachesDirectory && domain == NSUserDomainMask) return @[runtimeCache];
    return originalDirectoryURLs(files, selector, directory, domain);
}

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

static void CheckEmbeddedResources(NSString *source) {
    NSBundle *embedded = RUINEmbeddedResourceBundle();
    assert([embedded.bundleIdentifier isEqual:@"com.tqmane.ruin.resources"]);
    assert([[embedded.bundlePath stringByResolvingSymlinksInPath]
        hasPrefix:[[runtimeCache.path stringByResolvingSymlinksInPath] stringByAppendingString:@"/"]]);
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableSet *expected = [NSMutableSet set], *actual = [NSMutableSet set];
    for (NSString *relative in [files enumeratorAtPath:source]) {
        NSString *path = [source stringByAppendingPathComponent:relative];
        BOOL directory = NO;
        assert([files fileExistsAtPath:path isDirectory:&directory]);
        if (directory) continue;
        [expected addObject:relative];
        NSData *original = [NSData dataWithContentsOfFile:path];
        NSData *restored = [NSData dataWithContentsOfFile:
            [embedded.bundlePath stringByAppendingPathComponent:relative]];
        assert(original && [original isEqualToData:restored]);
        if ([relative.pathExtension isEqual:@"png"]) {
            CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)restored, NULL);
            assert(imageSource && CGImageSourceGetCount(imageSource) == 1);
            CGImageRef image = CGImageSourceCreateImageAtIndex(imageSource, 0,
                (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCacheImmediately:@YES});
            assert(image);
            CFRelease(image);
            CFRelease(imageSource);
        }
    }
    for (NSString *relative in [files enumeratorAtPath:embedded.bundlePath]) {
        BOOL directory = NO;
        assert([files fileExistsAtPath:[embedded.bundlePath stringByAppendingPathComponent:relative]
            isDirectory:&directory]);
        if (!directory) [actual addObject:relative];
    }
    // Includes Info.plist, every native .strings catalog, and the Tabler images.
    assert(expected.count && [expected isEqualToSet:actual]);
}

static void CheckRuntime(NSString *source, NSString *app, NSString *expectedPath) {
    assert([[NSBundle.mainBundle.bundlePath stringByResolvingSymlinksInPath]
        isEqual:[app stringByResolvingSymlinksInPath]]);
    NSBundle *resources = RUINResourceBundle();
    assert([resources.bundleIdentifier isEqual:@"com.tqmane.ruin.resources"]);
    if (expectedPath.length) {
        assert([[resources.bundlePath stringByResolvingSymlinksInPath]
            isEqual:[expectedPath stringByResolvingSymlinksInPath]]);
    } else {
        assert([resources.bundlePath isEqual:RUINEmbeddedResourceBundle().bundlePath]);
    }
    CheckEmbeddedResources(source);
    NSString *scenario = app.lastPathComponent.stringByDeletingPathExtension;
    for (NSString *name in @[@"tabler-eye", @"tabler-eye-off", @"tabler-checks"]) {
        BOOL externalImage = expectedPath.length && ![scenario isEqual:@"stale-icons"] &&
            (![@[@"partial-icons", @"base-icon", @"three-x-icon"] containsObject:scenario] ||
                [name isEqual:@"tabler-eye"]);
        NSBundle *imageBundle = RUINResourceBundleForImage(name);
        NSBundle *expectedBundle = externalImage ? resources : RUINEmbeddedResourceBundle();
        assert([imageBundle.bundlePath isEqual:expectedBundle.bundlePath]);
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *unknown = @"tests.unknown_semantic_key";
    for (NSString *language in RUINSupportedLanguages()) {
        [defaults setVolatileDomain:@{@"AppleLanguages":@[language]} forName:NSArgumentDomain];
        NSDictionary *catalog = [NSDictionary dictionaryWithContentsOfFile:
            [source stringByAppendingPathComponent:
                [language stringByAppendingString:@".lproj/Localizable.strings"]]];
        assert(catalog.count);
        // Exercise the public production entry, not the explicit-bundle helper.
        for (NSString *entry in catalog)
            assert([RUINLocalizedString(entry) isEqual:catalog[entry]]);
        assert([RUINLocalizedString(unknown) isEqual:unknown]);
    }
    [defaults setVolatileDomain:@{@"AppleLanguages":@[@"fr-CA"]} forName:NSArgumentDomain];
    assert([RUINLocalizedString(@"settings.hide_read") isEqual:@"Suppress read receipts"]);
    [defaults setVolatileDomain:@{@"AppleLanguages":@[@"ja-JP"]} forName:NSArgumentDomain];
    assert(([[NSString stringWithFormat:RUINLocalizedString(@"common.item_count"), (unsigned long)3]
        isEqual:@"3件"]));
    assert(([[NSString stringWithFormat:RUINLocalizedString(@"common.label_value"), @"項目", @"値"]
        isEqual:@"項目：値"]));
}

static void CopyResources(NSString *source, NSString *destination, BOOL stale, BOOL invalid) {
    NSFileManager *files = NSFileManager.defaultManager;
    assert([files createDirectoryAtPath:destination.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:NULL]);
    assert([files copyItemAtPath:source toPath:destination error:NULL]);
    if (stale) {
        // Pre-migration resources have Japanese text keys and the same bundle ID.
        NSString *contents = [@{@"既読を隠す":@"Legacy translation"} descriptionInStringsFileFormat];
        for (NSString *language in RUINSupportedLanguages()) {
            NSString *path = [destination stringByAppendingPathComponent:
                [language stringByAppendingString:@".lproj/Localizable.strings"]];
            assert([contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        }
    }
    if (invalid) {
        NSString *path = [destination stringByAppendingPathComponent:@"Info.plist"];
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        info[@"CFBundleIdentifier"] = @"test.unrelated.resources";
        assert([info writeToFile:path atomically:YES]);
    }
}

static void CheckRuntimeProcess(NSString *executable, NSString *directory, NSString *source, NSString *scenario) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *app = [[directory stringByAppendingPathComponent:scenario] stringByAppendingPathExtension:@"app"];
    NSString *imageDirectory = [app stringByAppendingPathComponent:@"Contents/MacOS"];
    assert([files createDirectoryAtPath:imageDirectory withIntermediateDirectories:YES attributes:nil error:NULL]);
    NSString *program = [imageDirectory stringByAppendingPathComponent:@"check_localization"];
    assert([files copyItemAtPath:executable toPath:program error:NULL]);
    assert(([@{@"CFBundleIdentifier":@"test.ruin.localization.runtime", @"CFBundlePackageType":@"APPL",
        @"CFBundleExecutable":@"check_localization"}
        writeToFile:[app stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES]));

    NSString *appResources = [app stringByAppendingPathComponent:@"RUINResources.bundle"];
    NSString *imageResources = [imageDirectory stringByAppendingPathComponent:@"RUINResources.bundle"];
    NSString *frameworkResources = [app stringByAppendingPathComponent:@"Frameworks/RUINResources.bundle"];
    NSString *expected = @"";
    if ([scenario isEqual:@"app-root"] || [scenario isEqual:@"invalid-sibling"]) {
        CopyResources(source, appResources, NO, NO);
        expected = appResources;
        if ([scenario isEqual:@"invalid-sibling"]) CopyResources(source, imageResources, NO, YES);
    } else if ([scenario isEqual:@"image-sibling"]) {
        CopyResources(source, imageResources, NO, NO);
        expected = imageResources;
    } else if ([scenario isEqual:@"frameworks"]) {
        CopyResources(source, frameworkResources, NO, NO);
        expected = frameworkResources;
    } else if ([scenario isEqual:@"stale-root"] || [scenario isEqual:@"stale-root-current-sibling"]) {
        CopyResources(source, appResources, YES, NO);
        expected = appResources;
        if ([scenario isEqual:@"stale-root-current-sibling"]) {
            CopyResources(source, imageResources, NO, NO);
            expected = imageResources;
        }
    } else if ([@[@"stale-icons", @"partial-icons", @"base-icon", @"three-x-icon"] containsObject:scenario]) {
        CopyResources(source, appResources, [scenario isEqual:@"stale-icons"], NO);
        expected = appResources;
        for (NSString *relative in [files enumeratorAtPath:appResources]) {
            if (![relative.pathExtension isEqual:@"png"]) continue;
            if ([scenario isEqual:@"partial-icons"] && [relative isEqual:@"tabler-eye@2x.png"]) continue;
            if ([scenario isEqual:@"three-x-icon"] && [relative isEqual:@"tabler-eye@3x.png"]) continue;
            assert([files removeItemAtPath:[appResources stringByAppendingPathComponent:relative] error:NULL]);
        }
        if ([scenario isEqual:@"base-icon"])
            assert([files copyItemAtPath:[source stringByAppendingPathComponent:@"tabler-eye@2x.png"]
                toPath:[appResources stringByAppendingPathComponent:@"tabler-eye.png"] error:NULL]);
    } else {
        assert([scenario isEqual:@"missing-resources"]);
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:program];
    task.currentDirectoryURL = [NSURL fileURLWithPath:directory isDirectory:YES];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    [environment removeObjectForKey:@"RUIN_TEST_RESOURCE_BUNDLE"];
    task.environment = environment;
    task.arguments = @[@"--runtime", source, app, expected];
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
        if (argc == 5 && [@(argv[1]) isEqual:@"--runtime"]) {
            runtimeCache = [NSURL fileURLWithPath:[@(argv[3]) stringByAppendingPathExtension:@"cache"] isDirectory:YES];
            Method method = class_getInstanceMethod(NSFileManager.class, @selector(URLsForDirectory:inDomains:));
            assert(method);
            originalDirectoryURLs = (DirectoryURLsIMP)method_setImplementation(method, (IMP)RuntimeDirectoryURLs);
            assert(originalDirectoryURLs);
            @try {
                CheckRuntime(@(argv[2]), @(argv[3]), @(argv[4]));
            } @finally {
                method_setImplementation(method, (IMP)originalDirectoryURLs);
            }
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

            // A real main bundle and image path exercise discovery independently
            // of the source checkout and the header-only host resource override.
            for (NSString *scenario in @[@"missing-resources", @"app-root", @"image-sibling", @"frameworks",
                @"stale-root", @"stale-root-current-sibling", @"invalid-sibling", @"stale-icons",
                @"partial-icons", @"base-icon", @"three-x-icon"])
                CheckRuntimeProcess(executable, temporary, bundlePath, scenario);
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
        puts("PASS five catalogs, embedded PNG decoding, per-image external fallback, bundle discovery, regional locales and formats");
    }
    return 0;
}
