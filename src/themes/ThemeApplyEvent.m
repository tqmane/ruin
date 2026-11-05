#import "ThemeApplyEvent.h"
#import <objc/runtime.h>

static BOOL RUINIsThemePackage(id object)
{
    Class cls = NSClassFromString(@"LineShopThemeInterface.ThemePackage") ?:
        NSClassFromString(@"_TtC22LineShopThemeInterface12ThemePackage");
    return object && cls && object_getClass(object) == cls;
}

id RUINThemePackageFromEvent(id event)
{
    if (RUINIsThemePackage(event)) return event;
    if (![event isKindOfClass:NSNotification.class]) return nil;
    NSNotification *notification = event;
    if (RUINIsThemePackage(notification.object)) return notification.object;
    id result = nil;
    if (notification.userInfo.count > 32) return nil;
    for (id value in notification.userInfo.allValues) {
        if (!RUINIsThemePackage(value)) continue;
        if (result && result != value) return nil;
        result = value;
    }
    return result;
}
