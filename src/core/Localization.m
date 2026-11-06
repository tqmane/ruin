#import "Localization.h"
#import <dlfcn.h>

static NSArray<NSString *> *RUINSupportedLanguages(void) {
    return @[@"en", @"ja", @"ko", @"zh-Hans", @"zh-Hant"];
}

NSBundle *RUINResourceBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *roots = [NSMutableArray arrayWithObject:NSBundle.mainBundle.bundlePath];
        Dl_info image;
        if (dladdr((const void *)RUINResourceBundle, &image) && image.dli_fname) {
            NSString *path = [[NSString stringWithUTF8String:image.dli_fname] stringByDeletingLastPathComponent];
            if (path) [roots addObject:path];
        }
        [roots addObject:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"]];
        for (NSString *root in roots) {
            NSString *path = [root stringByAppendingPathComponent:@"RUINResources.bundle"];
            NSBundle *candidate = [NSBundle bundleWithPath:path];
            if (candidate && [candidate.bundleIdentifier isEqual:@"com.tqmane.ruin.resources"]) {
                bundle = candidate;
                break;
            }
        }
    });
    return bundle;
}

static NSString *RUINLanguageForPreferences(NSArray<NSString *> *preferences) {
    return [NSBundle preferredLocalizationsFromArray:RUINSupportedLanguages()
        forPreferences:preferences].firstObject ?: @"en";
}

static NSString *RUINLocalizeInBundle(NSBundle *resources, NSString *key, NSArray<NSString *> *preferences) {
    if (!resources) return key;
    NSString *englishPath = [resources pathForResource:@"en" ofType:@"lproj"];
    NSBundle *english = englishPath ? [NSBundle bundleWithPath:englishPath] : nil;
    NSString *fallback = [english localizedStringForKey:key value:key table:nil] ?: key;
    NSString *language = RUINLanguageForPreferences(preferences);
    NSString *selectedPath = [resources pathForResource:language ofType:@"lproj"];
    NSBundle *selected = selectedPath ? [NSBundle bundleWithPath:selectedPath] : nil;
    return [selected localizedStringForKey:key value:fallback table:nil] ?: fallback;
}

NSString *RUINLocalizedString(NSString *key) {
    NSArray *languages = [NSUserDefaults.standardUserDefaults arrayForKey:@"AppleLanguages"] ?: NSLocale.preferredLanguages;
    return RUINLocalizeInBundle(RUINResourceBundle(), key, languages);
}

NSDictionary *RUINLocalizationDiagnostics(void) {
    NSArray *languages = [NSUserDefaults.standardUserDefaults arrayForKey:@"AppleLanguages"] ?: NSLocale.preferredLanguages;
    return @{@"resourcesFound":@(RUINResourceBundle() != nil),
        @"language":RUINLanguageForPreferences(languages), @"fallback":@"en",
        @"supported":RUINSupportedLanguages()};
}
