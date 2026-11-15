#import "Localization.h"
#import "EmbeddedResources.h"
#import <dlfcn.h>

static NSArray<NSString *> *RUINSupportedLanguages(void) {
    return @[@"en", @"ja", @"ko", @"zh-Hans", @"zh-Hant"];
}

// Some injectors import only the dylib. Keep the native resource files with
// that dylib and materialize them before asking NSBundle to read them. The
// content digest gives updated catalogs a new path, including NSBundle caches.
static NSBundle *RUINEmbeddedResourceBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *cache = [files URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        if (!cache.isFileURL) return;
        NSURL *directory = [[[cache URLByAppendingPathComponent:@"RUIN/Resources" isDirectory:YES]
            URLByAppendingPathComponent:@(RUINEmbeddedResourceDigest) isDirectory:YES]
            URLByAppendingPathComponent:@"RUINResources.bundle" isDirectory:YES];
        for (NSUInteger i = 0; i < sizeof(RUINEmbeddedResourceFiles) / sizeof(RUINEmbeddedResourceFiles[0]); i++) {
            const RUINEmbeddedResourceFile *file = &RUINEmbeddedResourceFiles[i];
            NSURL *destination = [directory URLByAppendingPathComponent:@(file->path)];
            NSData *data = [NSData dataWithBytesNoCopy:(void *)file->bytes length:file->length freeWhenDone:NO];
            if ([[NSData dataWithContentsOfURL:destination] isEqualToData:data]) continue;
            if (![files createDirectoryAtURL:destination.URLByDeletingLastPathComponent
                withIntermediateDirectories:YES attributes:nil error:NULL] ||
                ![data writeToURL:destination options:NSDataWritingAtomic error:NULL]) return;
        }
        bundle = [NSBundle bundleWithURL:directory];
    });
    return bundle;
}

static NSBundle *RUINExternalResourceBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *roots = [NSMutableArray array];
        Dl_info image;
        if (dladdr((const void *)RUINResourceBundle, &image) && image.dli_fname) {
            NSString *path = [[NSString stringWithUTF8String:image.dli_fname] stringByDeletingLastPathComponent];
            if (path) [roots addObject:path];
        }
        // Resources updated alongside this dylib take precedence over an old
        // copy left in a previously injected IPA.
        [roots addObject:NSBundle.mainBundle.bundlePath];
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

NSBundle *RUINResourceBundle(void) {
    return RUINExternalResourceBundle() ?: RUINEmbeddedResourceBundle();
}

NSBundle *RUINResourceBundleForImage(NSString *name) {
    NSBundle *external = RUINExternalResourceBundle();
    for (NSString *suffix in @[@"", @"@2x", @"@3x"])
        if ([external pathForResource:[name stringByAppendingString:suffix] ofType:@"png"])
            return external;
    return RUINEmbeddedResourceBundle();
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
    NSBundle *resources = RUINResourceBundle();
    NSString *value = RUINLocalizeInBundle(resources, key, languages);
    if (![value isEqualToString:key]) return value;
    // An older external bundle may still use Japanese text as its keys. Use
    // the catalogs compiled with this dylib when neither external locale has
    // the requested semantic key, preserving the final unknown-key fallback.
    NSBundle *embedded = RUINEmbeddedResourceBundle();
    return resources == embedded ? value : RUINLocalizeInBundle(embedded, key, languages);
}

NSDictionary *RUINLocalizationDiagnostics(void) {
    NSArray *languages = [NSUserDefaults.standardUserDefaults arrayForKey:@"AppleLanguages"] ?: NSLocale.preferredLanguages;
    NSBundle *resources = RUINResourceBundle();
    return @{@"resourcesFound":@(resources != nil),
        @"resourceSource":RUINExternalResourceBundle() ? @"external" : (resources ? @"embedded" : @"unavailable"),
        @"embeddedResourcesFound":@(RUINEmbeddedResourceBundle() != nil),
        @"language":RUINLanguageForPreferences(languages), @"fallback":@"en",
        @"supported":RUINSupportedLanguages()};
}
