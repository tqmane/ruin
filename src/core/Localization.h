#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSBundle * _Nullable RUINResourceBundle(void);
FOUNDATION_EXPORT NSDictionary *RUINLocalizationDiagnostics(void);

#if defined(RUIN_HOST_CHECK) && !defined(RUIN_LOCALIZATION_HOST_CHECK)
static inline NSString *RUINLocalizedString(NSString *key) NS_FORMAT_ARGUMENT(1);
static inline NSString *RUINLocalizedString(NSString *key) { return key; }
#else
FOUNDATION_EXPORT NSString *RUINLocalizedString(NSString *key) NS_FORMAT_ARGUMENT(1);
#endif

NS_ASSUME_NONNULL_END
