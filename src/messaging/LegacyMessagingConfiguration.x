%config(generator=internal);

#import "MessagingPrivateAPI.h"
#import "LegacyMessagingConfiguration.h"
#import "NativeMuteSend.h"
#import "../core/Features.h"
#import "../core/TargetMetadata.h"
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

static NSString *const kLabs = @"function.lab.silent_message";
static NSString *const kPremium = @"function.premium.common.mute_message";
static NSString *const kUnsend = @"function.chatroom.message.unsend.timelimit";
static const long long kNormalUnsendLimitMilliseconds = 24LL * 60 * 60 * 1000;

static BOOL RUINLegacyMessagingTargetMatchesInfo(NSDictionary *info) {
    return RUINTargetMetadataMatchesInfo(info);
}

static BOOL RUINLegacyMessagingEnabledForInfo(NSDictionary *info, BOOL optionEnabled) {
    return RUINLegacyMessagingTargetMatchesInfo(info) && optionEnabled;
}

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
    if ([original[kUnsend] longLongValue] < kNormalUnsendLimitMilliseconds)
        copy[kUnsend] = @"86400000";
    return options == NSPropertyListImmutable ? [copy copy] : copy;
}

#if defined(RUIN_LEGACY_MESSAGING_CONFIGURATION_HOST_CHECK)
#include <assert.h>
#include <stdio.h>
NSString *const RUINTargetBundleIdentifier = @"jp.naver.line";
NSString *const RUINTargetVersion = @"26.16.0";
NSString *const RUINTargetBuild = @"2026.1006.1718";
NSString *const RUINLocalLYPEnabledDefaultsKey = @"RUINLocalLYPEnabled";
NSString *const RUINLegacyMessagingEnabledDefaultsKey = @"RUINLegacyMessagingEnabled";

int main(void) {
    @autoreleasepool {
        const char *encoding = method_getTypeEncoding(class_getClassMethod(NSPropertyListSerialization.class,
            @selector(propertyListWithData:options:format:error:)));
        assert(encoding && (!strcmp(encoding, "@48@0:8@16Q24^Q32o^@40") ||
            !strcmp(encoding, "@48@0:8@16Q24^Q32^@40")));
        NSDictionary *targetInfo = @{@"RUINOriginalBundleIdentifier":RUINTargetBundleIdentifier,
            @"CFBundleShortVersionString":RUINTargetVersion, @"CFBundleVersion":RUINTargetBuild};
        NSDictionary *options = @{RUINLegacyMessagingEnabledDefaultsKey:@YES,
            RUINLocalLYPEnabledDefaultsKey:@NO};
        BOOL enabled = RUINLegacyMessagingEnabledForInfo(targetInfo,
            [options[RUINLegacyMessagingEnabledDefaultsKey] boolValue]);
        assert(enabled && ![options[RUINLocalLYPEnabledDefaultsKey] boolValue]);
        NSDictionary *input = @{kLabs:@"N", kPremium:@"Y", kUnsend:@"3600000",
            @"function.chatroom.message.unsend.premium.timelimit":@"604800000", @"unrelated":@[@1]};
        NSDictionary *projected = RUINProjectLegacyConfiguration(input, enabled, NSPropertyListImmutable);
        assert([projected[kLabs] isEqual:@"Y"] && [projected[kPremium] isEqual:@"N"]);
        assert([projected[kUnsend] isEqual:@"86400000"]);
        assert([input[kLabs] isEqual:@"N"] && [input[kPremium] isEqual:@"Y"]);
        assert([input[kUnsend] isEqual:@"3600000"]);
        assert(projected.count == input.count && projected[@"unrelated"] == input[@"unrelated"]);
        assert([projected[@"function.chatroom.message.unsend.premium.timelimit"] isEqual:@"604800000"]);
        options = @{RUINLegacyMessagingEnabledDefaultsKey:@NO, RUINLocalLYPEnabledDefaultsKey:@YES};
        enabled = RUINLegacyMessagingEnabledForInfo(targetInfo,
            [options[RUINLegacyMessagingEnabledDefaultsKey] boolValue]);
        assert(!enabled && RUINProjectLegacyConfiguration(input, enabled, NSPropertyListImmutable) == input);
        options = @{RUINLegacyMessagingEnabledDefaultsKey:@YES, RUINLocalLYPEnabledDefaultsKey:@NO};
        NSMutableDictionary *wrongTarget = [targetInfo mutableCopy];
        wrongTarget[@"CFBundleVersion"] = @"wrong-build";
        enabled = RUINLegacyMessagingEnabledForInfo(wrongTarget,
            [options[RUINLegacyMessagingEnabledDefaultsKey] boolValue]);
        assert(!enabled && RUINProjectLegacyConfiguration(input, enabled, NSPropertyListImmutable) == input);
        NSMutableDictionary *invalid = [input mutableCopy]; invalid[kPremium] = @YES;
        assert(RUINProjectLegacyConfiguration(invalid, YES, NSPropertyListImmutable) == invalid);
        invalid = [input mutableCopy]; invalid[kUnsend] = @"3600ms";
        assert(RUINProjectLegacyConfiguration(invalid, YES, NSPropertyListImmutable) == invalid);
        invalid = [input mutableCopy]; [invalid removeObjectForKey:kLabs];
        assert(RUINProjectLegacyConfiguration(invalid, YES, NSPropertyListImmutable) == invalid);
        invalid = [input mutableCopy]; invalid[kUnsend] = @"172800000";
        assert([RUINProjectLegacyConfiguration(invalid, YES, NSPropertyListImmutable)[kUnsend] isEqual:@"172800000"]);
        invalid = [input mutableCopy]; invalid[kUnsend] = @"345600000";
        assert([RUINProjectLegacyConfiguration(invalid, YES, NSPropertyListImmutable)[kUnsend] isEqual:@"345600000"]);
        invalid = [input mutableCopy]; invalid[kUnsend] = @"604800001";
        assert([RUINProjectLegacyConfiguration(invalid, YES, NSPropertyListImmutable)[kUnsend] isEqual:@"604800001"]);
        assert([RUINProjectLegacyConfiguration(input, YES, NSPropertyListMutableContainers) isKindOfClass:NSMutableDictionary.class]);
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:input format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
        NSDictionary *decoded = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
        assert([RUINProjectLegacyConfiguration(decoded, YES, 0)[kUnsend] isEqual:@"86400000"]);
        puts("PASS legacy configuration option is target-scoped, independent of local LYP, and preserves unrelated data");
    }
    return 0;
}
#else
#import "Features.h"

static atomic_bool gEnabled;
static atomic_uint_fast64_t gDecoded, gMatched, gProjected;
static atomic_int gFetchedLabsSilent = ATOMIC_VAR_INIT(-1);
static atomic_int gFetchedPremiumMute = ATOMIC_VAR_INIT(-1);
static atomic_int gEffectiveLabsSilent = ATOMIC_VAR_INIT(-1);
static atomic_int gEffectivePremiumMute = ATOMIC_VAR_INIT(-1);
static NSString *gHookStatus = @"pending";

static id RUINLegacyConfigurationFlagValue(int state) {
    return state < 0 ? (id)NSNull.null : (state ? @"Y" : @"N");
}

%group RUINLegacyMessaging
%hook NSPropertyListSerialization
+ (id)propertyListWithData:(NSData *)data options:(NSPropertyListReadOptions)options format:(NSPropertyListFormat *)format error:(NSError *__autoreleasing *)error {
    id original = %orig;
    atomic_fetch_add(&gDecoded, 1);
    if (!RUINLegacyConfigurationShape(original)) return original;
    atomic_fetch_add(&gMatched, 1);
    atomic_store(&gFetchedLabsSilent, [original[kLabs] isEqual:@"Y"]);
    atomic_store(&gFetchedPremiumMute, [original[kPremium] isEqual:@"Y"]);
    id result = RUINProjectLegacyConfiguration(original, atomic_load(&gEnabled), options);
    if (result != original) atomic_fetch_add(&gProjected, 1);
    atomic_store(&gEffectiveLabsSilent, [result[kLabs] isEqual:@"Y"]);
    atomic_store(&gEffectivePremiumMute, [result[kPremium] isEqual:@"Y"]);
    return result;

}
%end
%end

void RUINInstallLegacyMessagingConfiguration(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    BOOL target = RUINLegacyMessagingTargetMatchesInfo(info);
    BOOL enabled = RUINLegacyMessagingEnabledForInfo(info,
        [NSUserDefaults.standardUserDefaults boolForKey:RUINLegacyMessagingEnabledDefaultsKey]);
    atomic_store(&gEnabled, enabled);
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
        if (!method_getImplementation(method)) { gHookStatus = @"decoder_missing"; return; }
        %init(RUINLegacyMessaging);
        gHookStatus = @"installed";
    });
    RUINInstallNativeMuteSettingAdapter();
}

NSDictionary *RUINLegacyMessagingConfigurationDiagnostics(void) {
    return @{@"status":gHookStatus, @"enabled":@(atomic_load(&gEnabled)),
        @"legacyMessagingEnabled":@(atomic_load(&gEnabled)),
        @"decodedPropertyLists":@(atomic_load(&gDecoded)), @"matchingConfigurations":@(atomic_load(&gMatched)),
        @"projectedConfigurations":@(atomic_load(&gProjected)), @"writesConfigurationToDisk":@NO,
        @"fetchedLabsSilentMessage":RUINLegacyConfigurationFlagValue(atomic_load(&gFetchedLabsSilent)),
        @"fetchedPremiumCommonMuteMessage":RUINLegacyConfigurationFlagValue(atomic_load(&gFetchedPremiumMute)),
        @"effectiveLabsSilentMessage":RUINLegacyConfigurationFlagValue(atomic_load(&gEffectiveLabsSilent)),
        @"effectivePremiumCommonMuteMessage":RUINLegacyConfigurationFlagValue(atomic_load(&gEffectivePremiumMute)),
        @"subscriptionStatusModified":@NO,
        @"normalUnsendLimitMilliseconds":@(kNormalUnsendLimitMilliseconds)};
}
#endif
