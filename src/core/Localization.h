#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSBundle * _Nullable RUINResourceBundle(void);
FOUNDATION_EXPORT NSDictionary *RUINLocalizationDiagnostics(void);

#if defined(RUIN_HOST_CHECK) && !defined(RUIN_LOCALIZATION_HOST_CHECK)
// Host fixtures use the shipped Japanese templates, independent of the host's
// preferred language. Cache each catalog once per translation unit.
static inline NSString *RUINLocalizedString(NSString *key) {
    static NSDictionary *japanese, *english;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = NSProcessInfo.processInfo.environment[@"RUIN_TEST_RESOURCE_BUNDLE"];
        if (!path.length) path = [NSFileManager.defaultManager.currentDirectoryPath
            stringByAppendingPathComponent:@"resources/RUINResources.bundle"];
        japanese = [NSDictionary dictionaryWithContentsOfFile:
            [path stringByAppendingPathComponent:@"ja.lproj/Localizable.strings"]];
        english = [NSDictionary dictionaryWithContentsOfFile:
            [path stringByAppendingPathComponent:@"en.lproj/Localizable.strings"]];
    });
    return japanese[key] ?: english[key] ?: key;
}
#else
FOUNDATION_EXPORT NSString *RUINLocalizedString(NSString *key);
#endif

NS_ASSUME_NONNULL_END
