#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSURL * _Nullable RUINNormalizeNativeThemeImageURL(NSURL * _Nullable URL);
FOUNDATION_EXPORT void RUINInstallNativeThemeImages(void);
FOUNDATION_EXPORT void RUINRepairNativeThemeImageCache(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RUINNativeThemeImagesDiagnostics(void);

#if defined(RUIN_NATIVE_THEME_IMAGES_HOST_CHECK)
FOUNDATION_EXPORT BOOL RUINNativeThemeImagesClassIsSupported(Class cls);
FOUNDATION_EXPORT BOOL RUINNativeThemeImagesInstallHooksForTesting(Class cls, BOOL requireNSURLSessionSubclass);
FOUNDATION_EXPORT NSUInteger RUINNativeThemeImageRepairCacheAtURL(NSURL *cachesURL);
#endif

NS_ASSUME_NONNULL_END
