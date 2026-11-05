%config(generator=internal);

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdatomic.h>

static NSDictionary<NSString *, NSString *> *groupMap;
static atomic_uint mappedGroupRequests;
static atomic_uint mappedSuiteRequests;
static BOOL installed;
static BOOL suitesInstalled;

%group RUINAppGroupMapping
%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)identifier
{
    NSString *mapped = [identifier isKindOfClass:NSString.class] ? groupMap[identifier] : nil;
    if (mapped) atomic_fetch_add(&mappedGroupRequests, 1);
    return %orig(mapped ?: identifier);
}
%end
%end

%group RUINPreferencesSuiteMapping
%hook NSUserDefaults
- (instancetype)initWithSuiteName:(NSString *)name
{
    NSString *mapped = [name isKindOfClass:NSString.class] ? groupMap[name] : nil;
    if (mapped) atomic_fetch_add(&mappedSuiteRequests, 1);
    return %orig(mapped ?: name);
}
%end
%end

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
        %init(RUINAppGroupMapping);
        installed = YES;
        Method suite = class_getInstanceMethod(NSUserDefaults.class, @selector(initWithSuiteName:));
        if (suite && !strcmp(method_getTypeEncoding(suite), "@24@0:8@16")) {
            %init(RUINPreferencesSuiteMapping);
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
