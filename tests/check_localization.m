#define RUIN_LOCALIZATION_HOST_CHECK 1
#import "../src/core/Localization.m"
#include <assert.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 2);
        NSBundle *bundle = [NSBundle bundleWithPath:@(argv[1])];
        assert(bundle);
        NSString *key = @"既読を隠す";
        NSString *english = RUINLocalizeInBundle(bundle, key, @[@"en"]);
        assert(english.length && ![english isEqual:key]);
        assert([RUINLocalizeInBundle(bundle, key, @[@"fr-CA"]) isEqual:english]);
        assert([RUINLocalizeInBundle(bundle, key, @[@"ja-JP"]) isEqual:key]);
        for (NSString *language in @[@"ko", @"zh-Hans", @"zh-Hant"])
            assert(![RUINLocalizeInBundle(bundle, key, @[language]) isEqual:english]);
        assert([RUINLanguageForPreferences(@[@"ko-KR"]) isEqual:@"ko"]);
        assert([RUINLanguageForPreferences(@[@"zh-TW"]) isEqual:@"zh-Hant"]);
        assert([RUINLanguageForPreferences(@[@"zh-CN"]) isEqual:@"zh-Hans"]);

        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSFileManager *files = NSFileManager.defaultManager;
        [files createDirectoryAtPath:[temporary stringByAppendingPathComponent:@"en.lproj"]
            withIntermediateDirectories:YES attributes:nil error:NULL];
        [@{@"CFBundleIdentifier":@"test.ruin.localization", @"CFBundleDevelopmentRegion":@"en"}
            writeToFile:[temporary stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
        [@{key:@"English fallback"} writeToFile:[temporary stringByAppendingPathComponent:@"en.lproj/Localizable.strings"] atomically:YES];
        NSBundle *partial = [NSBundle bundleWithPath:temporary];
        assert([RUINLocalizeInBundle(partial, key, @[@"ko"]) isEqual:@"English fallback"]);
        assert([RUINLocalizeInBundle(partial, @"Unknown English text", @[@"fr"]) isEqual:@"Unknown English text"]);
        [files removeItemAtPath:temporary error:NULL];
        puts("PASS locale matching, unsupported-language English fallback, per-key fallback and regional Chinese");
    }
}
