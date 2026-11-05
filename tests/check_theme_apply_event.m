#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "ThemeApplyEvent.h"
#include <assert.h>

int main(void) { @autoreleasepool {
    Class cls = objc_allocateClassPair(NSObject.class,
        "_TtC22LineShopThemeInterface12ThemePackage", 0);
    assert(cls); objc_registerClassPair(cls);
    id first = [cls new], second = [cls new];
    assert(RUINThemePackageFromEvent(first) == first);
    assert(RUINThemePackageFromEvent(nil) == nil);
    assert(RUINThemePackageFromEvent(NSObject.new) == nil);
    NSNotification *(^event)(id, NSDictionary *) = ^NSNotification *(id object, NSDictionary *info) {
        return [NSNotification notificationWithName:@"fixture" object:object userInfo:info];
    };
    assert(RUINThemePackageFromEvent(event(first, nil)) == first);
    assert(RUINThemePackageFromEvent(event(NSObject.new, @{@"package":first})) == first);
    assert(RUINThemePackageFromEvent(event(nil, @{@"same":first, @"again":first})) == first);
    assert(RUINThemePackageFromEvent(event(nil, @{@"before":first, @"after":second})) == nil);
    assert(RUINThemePackageFromEvent(event(nil, @{@"array":@[first]})) == nil);
    assert(RUINThemePackageFromEvent(event(nil, nil)) == nil);
    puts("PASS direct/native-notification package extraction and ambiguous-payload rejection");
} return 0; }
