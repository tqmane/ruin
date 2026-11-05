#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdatomic.h>

static NSURL *(*originalGroupURL)(id, SEL, NSString *);
static NSDictionary<NSString *, NSString *> *groupMap;
static atomic_uint mappedGroupRequests;
static atomic_uint mappedSuiteRequests;
static BOOL installed;
static BOOL suitesInstalled;

@interface NSUserDefaults (RUINSuiteMapping)
- (instancetype)ruin_initWithSuiteName:(NSString *)name __attribute__((objc_method_family(init)));
@end

@implementation NSUserDefaults (RUINSuiteMapping)
- (instancetype)ruin_initWithSuiteName:(NSString *)name {
    NSString *mapped = [name isKindOfClass:NSString.class] ? groupMap[name] : nil;
    if (mapped) atomic_fetch_add(&mappedSuiteRequests, 1);
    return [self ruin_initWithSuiteName:mapped ?: name];
}
@end

static NSURL *RUINGroupURL(id self, SEL selector, NSString *identifier) {
    NSString *mapped = [identifier isKindOfClass:NSString.class] ? groupMap[identifier] : nil;
    if (mapped) atomic_fetch_add(&mappedGroupRequests, 1);
    return originalGroupURL(self, selector, mapped ?: identifier);
}

void RUINInstallCompatibility(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id mapping = NSBundle.mainBundle.infoDictionary[@"RUINAppGroupMap"];
        if (![mapping isKindOfClass:NSDictionary.class] || ![mapping count]) return;
        NSMutableDictionary *validated = [NSMutableDictionary dictionary];
        for (id key in mapping) {
            if ([key isKindOfClass:NSString.class] && [mapping[key] isKindOfClass:NSString.class])
                validated[key] = mapping[key];
        }
        groupMap = [validated copy];
        Method method = class_getInstanceMethod(NSFileManager.class,
            @selector(containerURLForSecurityApplicationGroupIdentifier:));
        if (!method || strcmp(method_getTypeEncoding(method), "@24@0:8@16")) return;
        originalGroupURL = (void *)method_setImplementation(method, (IMP)RUINGroupURL);
        installed = originalGroupURL != NULL;
        Method suite = class_getInstanceMethod(NSUserDefaults.class, @selector(initWithSuiteName:));
        Method replacement = class_getInstanceMethod(NSUserDefaults.class, @selector(ruin_initWithSuiteName:));
        if (suite && replacement && !strcmp(method_getTypeEncoding(suite), "@24@0:8@16")) {
            method_exchangeImplementations(suite, replacement);
            suitesInstalled = YES;
        }
    });
}

NSDictionary *RUINCompatibilityDiagnostics(void) {
    return @{@"appGroupMappingInstalled": @(installed),
             @"appGroupMappingCount": @(groupMap.count),
             @"mappedAppGroupRequests": @(atomic_load(&mappedGroupRequests)),
             @"appGroupPreferencesMappingInstalled": @(suitesInstalled),
             @"mappedPreferencesRequests": @(atomic_load(&mappedSuiteRequests))};
}

__attribute__((constructor)) static void RUINPrepareSideload(void) {
    @autoreleasepool { RUINInstallCompatibility(); }
}
