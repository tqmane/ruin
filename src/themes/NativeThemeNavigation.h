#import <Foundation/Foundation.h>

@class UIViewController;

NS_ASSUME_NONNULL_BEGIN

typedef void (^RUINNativeMyThemesCompletion)(NSError * _Nullable error);
typedef void (^RUINNativeMyThemesDidAppearHandler)(UIViewController *controller);

FOUNDATION_EXPORT void RUINOpenNativeMyThemes(UIViewController *owner,
    RUINNativeMyThemesCompletion completion);
FOUNDATION_EXPORT void RUINRefreshNativeMyThemes(UIViewController *controller,
    RUINNativeMyThemesCompletion completion);
FOUNDATION_EXPORT void RUINSetNativeMyThemesDidAppearHandler(
    RUINNativeMyThemesDidAppearHandler _Nullable handler);
FOUNDATION_EXPORT void RUINInstallNativeMyThemesDidAppearHook(void);

NS_ASSUME_NONNULL_END
