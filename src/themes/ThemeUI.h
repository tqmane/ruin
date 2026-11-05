#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Pushes Japanese theme settings into the owner's existing navigation controller.
 The owner must be the visible controller (or its child), or the navigation
 controller itself. Calls from other threads are forwarded to the main queue.
 Displays catalog/download availability from ThemeFeatures; file preview/share
 never reports installation or application. No modal navigation is created.
 */
FOUNDATION_EXPORT void RUINOpenThemeSettings(UIViewController *owner);

NS_ASSUME_NONNULL_END
