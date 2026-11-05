#import "LegacyMessagingConfiguration.h"
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

static NSString *const kLabs = @"function.lab.silent_message";
static NSString *const kPremium = @"function.premium.common.mute_message";
static NSString *const kUnsend = @"function.chatroom.message.unsend.timelimit";

static BOOL RUINLegacyConfigurationShape(id object) {
    if (![object isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in @[kLabs, kPremium]) {
        id value = object[key];
        if (![value isKindOfClass:NSString.class] ||
            !([value isEqual:@"Y"] || [value isEqual:@"N"])) return NO;
    }
    NSString *limit = object[kUnsend];
    if (![limit isKindOfClass:NSString.class] || !limit.length || limit.length > 12) return NO;
    for (NSUInteger i = 0; i < limit.length; i++)
        if ([limit characterAtIndex:i] < '0' || [limit characterAtIndex:i] > '9') return NO;
    return limit.longLongValue > 0;
}

static id RUINProjectLegacyConfiguration(id original, BOOL enabled, NSPropertyListReadOptions options) {
    if (!enabled || !RUINLegacyConfigurationShape(original)) return original;
    NSMutableDictionary *copy = [original mutableCopy];
    copy[kLabs] = @"Y";
    copy[kPremium] = @"N";
    if ([original[kUnsend] longLongValue] < 86400000) copy[kUnsend] = @"86400000";
    return options == NSPropertyListImmutable ? [copy copy] : copy;
}

#if defined(RUIN_LEGACY_MESSAGING_CONFIGURATION_HOST_CHECK)
#include <assert.h>
#include <stdio.h>
int main(void) {
    @autoreleasepool {
        const char *encoding = method_getTypeEncoding(class_getClassMethod(NSPropertyListSerialization.class,
            @selector(propertyListWithData:options:format:error:)));
        assert(encoding && (!strcmp(encoding, "@48@0:8@16Q24^Q32o^@40") ||
            !strcmp(encoding, "@48@0:8@16Q24^Q32^@40")));
        NSDictionary *input = @{kLabs:@"N", kPremium:@"Y", kUnsend:@"3600000",
            @"function.chatroom.message.unsend.premium.timelimit":@"604800000", @"unrelated":@[@1]};
        NSDictionary *projected = RUINProjectLegacyConfiguration(input, YES, NSPropertyListImmutable);
        assert([projected[kLabs] isEqual:@"Y"] && [projected[kPremium] isEqual:@"N"]);
        assert([projected[kUnsend] isEqual:@"86400000"]);
        assert([input[kLabs] isEqual:@"N"] && [input[kPremium] isEqual:@"Y"]);
        assert([input[kUnsend] isEqual:@"3600000"]);
        assert(projected.count == input.count && projected[@"unrelated"] == input[@"unrelated"]);
        assert([projected[@"function.chatroom.message.unsend.premium.timelimit"] isEqual:@"604800000"]);
        assert(RUINProjectLegacyConfiguration(input, NO, NSPropertyListImmutable) == input);
        NSMutableDictionary *invalid = [input mutableCopy]; invalid[kPremium] = @YES;
        assert(RUINProjectLegacyConfiguration(invalid, YES, NSPropertyListImmutable) == invalid);
        invalid = [input mutableCopy]; invalid[kUnsend] = @"3600ms";
        assert(RUINProjectLegacyConfiguration(invalid, YES, NSPropertyListImmutable) == invalid);
        invalid = [input mutableCopy]; [invalid removeObjectForKey:kLabs];
        assert(RUINProjectLegacyConfiguration(invalid, YES, NSPropertyListImmutable) == invalid);
        invalid = [input mutableCopy]; invalid[kUnsend] = @"172800000";
        assert([RUINProjectLegacyConfiguration(invalid, YES, NSPropertyListImmutable)[kUnsend] isEqual:@"172800000"]);
        assert([RUINProjectLegacyConfiguration(input, YES, NSPropertyListMutableContainers) isKindOfClass:NSMutableDictionary.class]);
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:input format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        NSDictionary *decoded = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
        assert([RUINProjectLegacyConfiguration(decoded, YES, 0)[kUnsend] isEqual:@"86400000"]);
        puts("PASS legacy configuration projection isolates three keys and preserves original/cache data");
    }
    return 0;
}
#else
#import "Features.h"

typedef id (*RUINPropertyListDecoder)(id, SEL, NSData *, NSPropertyListReadOptions,
    NSPropertyListFormat *, NSError *__autoreleasing *);
static RUINPropertyListDecoder gOriginalDecoder;
static atomic_bool gEnabled;
static atomic_uint_fast64_t gDecoded, gMatched, gProjected;
static NSString *gHookStatus = @"pending";

static id RUINDecodeLegacyConfiguration(id owner, SEL selector, NSData *data,
    NSPropertyListReadOptions options, NSPropertyListFormat *format, NSError *__autoreleasing *error) {
    id original = gOriginalDecoder(owner, selector, data, options, format, error);
    atomic_fetch_add(&gDecoded, 1);
    if (!RUINLegacyConfigurationShape(original)) return original;
    atomic_fetch_add(&gMatched, 1);
    id result = RUINProjectLegacyConfiguration(original, atomic_load(&gEnabled), options);
    if (result != original) atomic_fetch_add(&gProjected, 1);
    return result;
}

void RUINInstallLegacyMessagingConfiguration(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    BOOL target = [info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier] &&
        [info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] &&
        [info[@"CFBundleVersion"] isEqual:RUINTargetBuild];
    atomic_store(&gEnabled, target && [NSUserDefaults.standardUserDefaults boolForKey:RUINLocalLYPEnabledDefaultsKey]);
    if (!target) { gHookStatus = @"version_gated"; return; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method method = class_getClassMethod(NSPropertyListSerialization.class,
            @selector(propertyListWithData:options:format:error:));
        const char *encoding = method ? method_getTypeEncoding(method) : NULL;
        if (!encoding || (strcmp(encoding, "@48@0:8@16Q24^Q32o^@40") &&
            strcmp(encoding, "@48@0:8@16Q24^Q32^@40"))) {
            gHookStatus = @"decoder_abi_mismatch"; return;
        }
        gOriginalDecoder = (void *)method_getImplementation(method);
        if (!gOriginalDecoder) { gHookStatus = @"decoder_missing"; return; }
        method_setImplementation(method, (IMP)RUINDecodeLegacyConfiguration);
        gHookStatus = @"installed";
    });
}

NSDictionary *RUINLegacyMessagingConfigurationDiagnostics(void) {
    return @{@"status":gHookStatus, @"enabled":@(atomic_load(&gEnabled)),
        @"decodedPropertyLists":@(atomic_load(&gDecoded)), @"matchingConfigurations":@(atomic_load(&gMatched)),
        @"projectedConfigurations":@(atomic_load(&gProjected)), @"writesConfigurationToDisk":@NO,
        @"subscriptionStatusModified":@NO, @"normalUnsendMinimumMilliseconds":@86400000};
}
#endif
