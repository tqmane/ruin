#import "TargetMetadata.h"
#import "NativeMuteSend.h"

#import "../core/Features.h"
#import "LegacyMessagingConfiguration.h"

#import <objc/runtime.h>
#import <string.h>

static const char * const kNativeMuteSendClass = "_TtC15LineMessagingUI12ChatInputBar";
static const char * const kNativeMuteSendSelector = "longPressDidActivate:";
static const char * const kNativeMuteSendEncoding = "v24@0:8@16";

static BOOL RUINNativeMuteSendTargetMatches(void)
{
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
}

NSDictionary<NSString *, id> *RUINNativeMuteSendDiagnostics(void)
{
    BOOL targetMatches = RUINNativeMuteSendTargetMatches();
    BOOL enabled = targetMatches &&
        [NSUserDefaults.standardUserDefaults boolForKey:RUINLegacyMessagingEnabledDefaultsKey];
    Class inputClass = targetMatches ? objc_getClass(kNativeMuteSendClass) : Nil;
    SEL selector = sel_registerName(kNativeMuteSendSelector);
    Method method = inputClass ? class_getInstanceMethod(inputClass, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    NSString *runtimeEncoding = encoding ? [NSString stringWithUTF8String:encoding] : nil;
    BOOL longPressABIConfirmed = encoding && strcmp(encoding, kNativeMuteSendEncoding) == 0;
    NSDictionary *configuration = RUINLegacyMessagingConfigurationDiagnostics();
    BOOL decoderInstalled = [configuration[@"status"] isEqual:@"installed"];
    BOOL projected = [configuration[@"projectedConfigurations"] unsignedLongLongValue] > 0;

    NSString *status = !targetMatches ? @"versionGated" :
        !enabled ? @"disabled" :
        !inputClass ? @"unsupportedSendButtonClassMissing" :
        !method ? @"unsupportedSendLongPressSelectorMissing" :
        !longPressABIConfirmed ? @"unsupportedSendLongPressEncodingMismatch" :
        !decoderInstalled ? @"configurationDecoderUnavailable" :
        projected ? @"legacyConfigurationProjected" : @"awaitingNativeConfiguration";
    NSString *reason = !targetMatches ? @"The exact LINE bundle, version, or build did not match." :
        !enabled ? @"The independent legacy-messaging option is off." :
        !inputClass ? @"The verified native send-button class is unavailable." :
        !method ? @"The verified native long-press selector is unavailable." :
        !longPressABIConfirmed ? @"The native long-press encoding differs from the verified build." :
        !decoderInstalled ? @"The native configuration decoder did not match its verified ABI." :
        projected ? @"Configuration is projected; effective flags are shown below. The native menu gate remains unverified." :
        @"Waiting for LINE to load its native configuration; restart after changing the independent legacy-messaging option.";

    return @{
        @"status":status,
        @"reason":reason,
        @"targetMatches26_16_0":@(targetMatches),
        @"legacyMessagingEnabled":@(enabled),
        @"nativeLongPressClass":[NSString stringWithUTF8String:kNativeMuteSendClass],
        @"nativeLongPressClassPresent":@(inputClass != Nil),
        @"nativeLongPressSelector":[NSString stringWithUTF8String:kNativeMuteSendSelector],
        @"nativeLongPressExpectedEncoding":[NSString stringWithUTF8String:kNativeMuteSendEncoding],
        @"nativeLongPressRuntimeEncoding":runtimeEncoding ?: (id)NSNull.null,
        @"nativeLongPressABIConfirmed":@(longPressABIConfirmed),
        @"fetchedLabsSilentMessage":configuration[@"fetchedLabsSilentMessage"] ?: NSNull.null,
        @"fetchedPremiumCommonMuteMessage":configuration[@"fetchedPremiumCommonMuteMessage"] ?: NSNull.null,
        @"effectiveLabsSilentMessage":configuration[@"effectiveLabsSilentMessage"] ?: NSNull.null,
        @"effectivePremiumCommonMuteMessage":configuration[@"effectivePremiumCommonMuteMessage"] ?: NSNull.null,
        @"nativeMenuViewModelPath":@"ChatViewController.chatViewModel.sendButtonLongPressViewModel",
        @"nativeMenuPolicyPath":@"SendButtonLongPressMenuViewModel.policy (SendButtonLongPressMenuPolicy)",
        @"nativeMenuPolicyFields":@[@"configurationService", @"generalSettingsService"],
        @"muteFeatureBooleanPath":@"LineConfigurationSubsystem.LineConfigurationManagerProperties.$__lazy_storage_$_premium.isPremiumMuteMessageEnabled",
        @"muteFeatureBooleanType":@"Swift.Bool",
        @"rawFeatureKeySymbol":@"RawPremiumMuteMessageEnabledKey",
        @"rawFeatureKeyProvenAsDefaultsKey":@NO,
        @"muteGateFunctionProven":@NO,
        @"muteGateFunctionABIProven":@NO,
        @"hookInstalled":@(decoderInstalled),
        @"legacyConfigurationProjected":@(projected),
        @"muteGateABIConfirmed":@NO,
        @"nativeMenuModified":@NO,
        @"globalMembershipModified":@NO,
        @"agreementStateModified":@NO,
        @"customPickerAdded":@NO,
        @"legacyMutePayloadField":@"NOTIFICATION_DISABLED",
        @"legacyMutePayloadProvesNativeMenuPath":@NO
    };
}

void RUINInstallNativeMuteSend(void)
{
    RUINInstallLegacyMessagingConfiguration();
}
