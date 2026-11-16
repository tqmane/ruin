%config(generator=internal);

#import <UIKit/UIKit.h>
#import "Features.h"
#import "TargetMetadata.h"
#import "BinaryVerifier.h"
#import "BundleIdentity.h"
#import "Keychain.h"
#import "Sideload.h"
#import "SiriCompatibility.h"
#import "Localization.h"
#import "RUINSettings.h"
#import "SecondaryLogin.h"
#import "InterfaceFeatures.h"
#import "Confirmations.h"
#import "MessageHistory.h"
#import "MenuExtras.h"
#import "ReadOnReply.h"
#import "ReadBoundary.h"
#import "NativeChatControls.h"
#import "LocalUnreadBadges.h"
#import "LegacyHome.h"
#import "RuntimeInspector.h"
#import "UnsendRetention.h"
#import "UnsendOperation.h"
#import "UnsendMarkerUI.h"
#import "RetainedMedia.h"
#import "AgeVerification.h"
#import "ReadUsersEvents.h"
#import "AutomaticReadGate.h"
#import "ThemeFeatures.h"
#import "ThemeUI.h"
#import "ThemeShop.h"
#import "ThemeStoreDownload.h"
#import "ThemeStoreWeb.h"
#import "ThemeStoreImages.h"
#import "NativeThemeImages.h"
#import "NativeThemeWorkflow.h"
#import "NativeThemeRegistration.h"
#import "MIDLookup.h"
#import "ReadersSheet.h"
#import "NativeReadRangeSync.h"
#import "NativeTabAvailability.h"
#import "ReadRangeFetch.h"
#import "PushDiagnostics.h"
#import "LocalNotifications.h"
#import "LocalAppearance.h"
#import "LocalFont.h"
#import "LocalFontUI.h"
#import "ChatPicker.h"
#import "ChatCatalog.h"
#import "NativeMuteSend.h"
#import "ClientVersionAdvertisement.h"
#import "LegacyMessagingConfiguration.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <string.h>
#include <stdlib.h>

extern void RUINInstallNativeEntry(void);
extern NSDictionary *RUINNativeEntryDiagnostics(void);

NSString *const RUINVersion = RUIN_BUILD_VERSION;

static BOOL sEnvironmentSettingsScheduled;
static BOOL sEnvironmentSettingsPresented;
static id sActiveObserver;
static NSDictionary *sKeychainSelfTest;
static BOOL sLocalNotificationLaunchHookInstalled;

static NSDictionary *RUINMainBundleInfo(void) {
    return NSBundle.mainBundle.infoDictionary ?: @{};
}

BOOL RUINIsCompatible(void) {
    NSDictionary *info = RUINMainBundleInfo();
    return RUINTargetMetadataMatchesInfo(info);
}

%group RUINLaunchBoundary
%hook RUINAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    BOOL result = %orig(application, options);
    // Install after LINE assigns its delegate and before launch returns, so a
    // cold notification tap cannot enter LINE's remote-push parser.
    if (result) RUINInstallLocalNotifications();
    return result;
}
%end
%end

static void RUINInstallLocalNotificationLaunchBoundary(void) {
    if (sLocalNotificationLaunchHookInstalled || !RUINIsCompatible()) return;
    Class cls = NSClassFromString(@"LINE.AppDelegate");
    SEL selector = @selector(application:didFinishLaunchingWithOptions:);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *type = method ? method_getTypeEncoding(method) : NULL;
    if (!type || (strcmp(type, "B32@0:8@16@24") && strcmp(type, "c32@0:8@16@24"))) return;
    %init(RUINLaunchBoundary, RUINAppDelegate = cls);
    sLocalNotificationLaunchHookInstalled = YES;
}

static NSString *RUINRuntimeImageUUID(const struct mach_header *header) {
    if (!header || header->magic != MH_MAGIC_64) return nil;
    const struct mach_header_64 *image = (const void *)header;
    if (image->sizeofcmds > 1024 * 1024 ||
        image->ncmds > image->sizeofcmds / sizeof(struct load_command)) return nil;
    const uint8_t *cursor = (const void *)(image + 1), *end = cursor + image->sizeofcmds;
    NSString *uuid = nil;
    for (uint32_t i = 0; i < image->ncmds; i++) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return nil;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) return nil;
        if (command->cmd == LC_UUID) {
            if (uuid || command->cmdsize != sizeof(struct uuid_command)) return nil;
            uuid = [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
        }
        cursor += command->cmdsize;
    }
    return cursor == end ? uuid : nil;
}

NSDictionary *RUINRuntimeDiagnostics(void) {
    NSDictionary *info = RUINMainBundleInfo();
    NSDictionary *featureDiagnostics = RUINFeatureDiagnostics() ?: @{};
    NSDictionary *compatibilityDiagnostics = RUINCompatibilityDiagnostics() ?: @{};
    RUINMainExecutableImage executable;
    BOOL resolved = RUINResolveMainExecutableImage(&executable);
    const struct mach_header *mainImage = resolved ? (const void *)executable.header : NULL;
    const char *imageName = resolved ? _dyld_get_image_name(executable.imageIndex) : NULL;
    NSString *imageBasename = imageName ? [NSString stringWithUTF8String:imageName].lastPathComponent : nil;
    const struct mach_header *imageZero = _dyld_get_image_header(0);
    const char *imageZeroName = _dyld_get_image_name(0);
    NSString *imageZeroBasename = imageZeroName ? [NSString stringWithUTF8String:imageZeroName].lastPathComponent : nil;
#if defined(__arm64e__)
    NSString *loadedArchitecture = @"arm64e";
#elif defined(__arm64__)
    NSString *loadedArchitecture = @"arm64";
#else
    NSString *loadedArchitecture = @"unknown";
#endif
    return @{
        @"capturedAt": [[NSISO8601DateFormatter new] stringFromDate:NSDate.date],
        @"ruin": @{ @"version": RUINVersion, @"loaded": @YES,
            @"loadedArchitecture": loadedArchitecture },
        @"app": @{
            @"originalBundleIdentifier": info[@"RUINOriginalBundleIdentifier"] ?: NSNull.null,
            @"signedBundleIdentifier": info[@"RUINSignedBundleIdentifier"] ?: NSNull.null,
            @"version": info[@"CFBundleShortVersionString"] ?: @"unknown",
            @"build": info[@"CFBundleVersion"] ?: @"unknown",
            @"mainExecutableResolved": @(resolved),
            @"machOImageIndex": resolved ? @(executable.imageIndex) : NSNull.null,
            @"machOCPUType": mainImage ? @(mainImage->cputype) : NSNull.null,
            @"machOCPUSubtype": mainImage ? @(mainImage->cpusubtype) : NSNull.null,
            @"machOFileType": mainImage ? @(mainImage->filetype) : NSNull.null,
            @"machOImageName": imageBasename ?: NSNull.null,
            @"machOUUID": RUINRuntimeImageUUID(mainImage) ?: NSNull.null,
            @"compatible": @(RUINIsCompatible())
        },
        @"dyldImageZero": @{
            @"name":imageZeroBasename ?: NSNull.null,
            @"fileType":imageZero ? @(imageZero->filetype) : NSNull.null,
            @"uuid":RUINRuntimeImageUUID(imageZero) ?: NSNull.null
        },
        @"compatibility": compatibilityDiagnostics,
        @"bundleIdentity": RUINBundleIdentityDiagnostics(),
        @"chatCatalog": RUINChatCatalogDiagnostics(),
        @"push": RUINPushDiagnostics(),
        @"nativeEntry": RUINNativeEntryDiagnostics() ?: @{},
        @"nativeChat": RUINNativeChatControlsDiagnostics(),
        @"localUnreadBadges": RUINLocalUnreadBadgesDiagnostics(),
        @"legacyHome": RUINLegacyHomeDiagnostics(),
        @"runtimeInspector": RuntimeInspectorDiagnostics(),
        @"secondaryLogin": RUINSecondaryLoginDiagnostics(),
        @"replyObserver": RUINReplyDiagnostics(),
        @"readBoundary": RUINReadBoundaryDiagnostics(),
        @"automaticReadGate": RUINAutomaticReadGateDiagnostics(),
        @"themes": RUINThemeDiagnostics(),
        @"themeShop": RUINThemeShopDiagnostics(),
        @"themeStoreDownload": RUINThemeStoreDownloadDiagnostics(),
        @"themeStoreWeb": RUINThemeStoreWebDiagnostics(),
        @"siriCompatibility": RUINSiriCompatibilityDiagnostics(),
        @"themeStoreImages": RUINThemeStoreImagesDiagnostics(),
        @"nativeThemeImages": RUINNativeThemeImagesDiagnostics(),
        @"nativeThemeWorkflow": RUINNativeThemeWorkflowDiagnostics(),
        @"midLookup": RUINMIDLookupDiagnostics(),
        @"readersSheet": RUINReadersSheetDiagnostics(),
        @"interface": RUINInterfaceDiagnostics(),
        @"localNotifications": RUINLocalNotificationDiagnostics(),
        @"localNotificationLaunchHookInstalled": @(sLocalNotificationLaunchHookInstalled),
        @"localAppearance": RUINLocalAppearanceDiagnostics(),
        @"localization": RUINLocalizationDiagnostics(),
        @"localFont": RUINLocalFontDiagnostics(),
        @"localFontRendering": RUINLocalFontHookDiagnostics(),
        @"nativeMuteSend": RUINNativeMuteSendDiagnostics(),
        @"clientVersionAdvertisement": RUINClientVersionAdvertisementDiagnostics(),
        @"legacyMessagingConfiguration": RUINLegacyMessagingConfigurationDiagnostics(),
        @"confirmations": RUINConfirmationDiagnostics(),
        @"messageHistory": RUINMessageHistoryDiagnostics(),
        @"nativeReadRangeSync": RUINNativeReadRangeSyncDiagnostics(),
        @"readRangeFetch": RUINReadRangeFetchDiagnostics(),
        @"unsendRetention": RUINUnsendRetentionDiagnostics(),
        @"retainedMedia": RUINRetainedMediaDiagnostics(),
        @"unsendOperation": RUINUnsendOperationDiagnostics(),
        @"unsendMarkerUI": RUINUnsendMarkerUIDiagnostics(),
        @"ageVerification": RUINAgeVerificationDiagnostics(),
        @"readUsersEvents": RUINReadUsersEventsDiagnostics(),
        @"menuExtras": RUINMenuExtrasDiagnostics(),
        @"keychain": RUINKeychainDiagnostics() ?: @{},
        @"keychainSelfTest": sKeychainSelfTest ?: @{},
        @"features": featureDiagnostics
    };
}

static NSDictionary *RUINRuntimeStatus(void) {
    // Ordinary navigation needs counters, not signing, database or view-tree inspection.
    return @{@"capturedAt":[[NSISO8601DateFormatter new] stringFromDate:NSDate.date],
        @"scope":@"status", @"ruin":@{@"version":RUINVersion, @"loaded":@YES},
        @"replyObserver":RUINReplyDiagnostics(),
        @"automaticReadGate":RUINAutomaticReadGateDiagnostics()};
}

void RUINRefreshRuntimeReport(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINRefreshRuntimeReport(); });
        return;
    }
    static BOOL scheduled;
    if (scheduled) return;
    scheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        scheduled = NO;
        const char *value = getenv("RUIN_ENABLE_RUNTIME_INSPECTOR");
        BOOL inspect = value && !strcmp(value, "1");
        if (inspect) RUINRefreshPushDiagnostics();
        // Full inspection may contain live mutable diagnostic collections.
        // Encode it on the owning thread only in this explicit debug mode.
        NSData *inspectionData = inspect ? [NSJSONSerialization dataWithJSONObject:RUINRuntimeDiagnostics()
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL] : nil;
        NSDictionary *snapshot = inspect ? nil : RUINRuntimeStatus();
        static dispatch_queue_t queue;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ queue = dispatch_queue_create("com.tqmane.ruin.runtime-report", DISPATCH_QUEUE_SERIAL); });
        dispatch_async(queue, ^{
            NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            if (!caches.length) return;
            NSString *directory = [caches stringByAppendingPathComponent:@"RUIN"];
            if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                withIntermediateDirectories:YES attributes:nil error:NULL]) return;
            NSData *data = inspect ? inspectionData : [NSJSONSerialization dataWithJSONObject:snapshot
                options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
            if (data) [data writeToFile:[directory stringByAppendingPathComponent:@"runtime.json"]
                options:NSDataWritingAtomic error:NULL];
        });
    });
}

void RUINRefreshSettingsFeatures(void) {
    RUINInstallLegacyMessagingConfiguration();
    RUINInstallClientVersionAdvertisement();
    RUINInstallLocalNotifications();
    RUINInstallLocalAppearance();
    RUINInstallLocalFont();
    RUINInstallNativeMuteSend();
    RUINInstallFeatures();
    RUINInstallReadBoundary();
    RUINInstallReadOnReply();
    RUINInstallConfirmations();
    RUINInstallNativeChatControls();
    RUINInstallLocalUnreadBadges();
    RUINRefreshInterfaceFeatures();
    RUINInstallLegacyHome();
    RUINInstallAutomaticReadGate();
    RUINInstallMessageHistory();
    RUINInstallUnsendRetention();
    RUINInstallRetainedMedia();
    RUINInstallUnsendOperation();
    RUINInstallUnsendMarkerUI();
    RUINInstallAgeVerification();
    RUINInstallReadUsersEvents();
    RUINInstallThemeFeatures();
    RUINInstallThemeStoreDownload();
    RUINInstallThemeStoreImages();
    RUINInstallNativeThemeImages();
    RUINInstallNativeThemeWorkflow();
    RUINInstallThemeStoreWeb();
    RUINInstallMenuExtras();
    RUINRefreshRuntimeReport();
}

void RUINRefreshSettingsFeature(NSString *key) {
    if (!key.length) return;
    if (!NSThread.isMainThread) {
        NSString *copiedKey = [key copy];
        dispatch_async(dispatch_get_main_queue(), ^{ RUINRefreshSettingsFeature(copiedKey); });
        return;
    }
    if ([key isEqual:RUINClearViewedUnreadBadgesDefaultsKey]) {
        RUINInstallLocalUnreadBadges();
    } else if ([key isEqual:RUINLegacyHomeEnabledDefaultsKey]) {
        RUINInstallLegacyHome();
    } else if ([@[RUINReadControlEnabledDefaultsKey, RUINMarkReadOnReplyDefaultsKey, RUINReadExceptionsDefaultsKey,
           RUINLocalNamesDefaultsKey, RUINLocalNamesByIdentityDefaultsKey] containsObject:key]) {
        RUINInstallFeatures();
        RUINInstallReadBoundary();
        RUINInstallReadOnReply();
        RUINRefreshAutomaticReadGate();
        RUINInstallNativeChatControls();
        RUINInstallLocalUnreadBadges();
    } else if ([key isEqual:RUINLegacyMessagingEnabledDefaultsKey]) {
        RUINInstallLegacyMessagingConfiguration();
        RUINInstallClientVersionAdvertisement();
        RUINInstallNativeMuteSend();
    } else if ([key isEqual:RUINLocalLYPEnabledDefaultsKey]) {
        RUINInstallLocalAppearance();
    } else if ([key isEqual:RUINLocalNotificationsEnabledDefaultsKey]) {
        RUINInstallLocalNotifications();
    } else if ([key isEqual:RUINKeepUnsentMessagesKey]) {
        RUINInstallMessageHistory();
        RUINInstallUnsendRetention();
        RUINInstallRetainedMedia();
        RUINRefreshUnsendMarkerUI();
    } else if ([key isEqual:RUINTrackReadUsersKey]) {
        RUINInstallMessageHistory();
        RUINInstallReadUsersEvents();
    } else if ([@[RUINConfirmSendEnabledDefaultsKey, RUINConfirmCallEnabledDefaultsKey,
           RUINConfirmCameraOnEnabledDefaultsKey, RUINConfirmDisconnectEnabledDefaultsKey,
           RUINConfirmSendMinimumGroupMemberCountDefaultsKey] containsObject:key]) {
        RUINInstallConfirmations();
    } else if ([key isEqual:RUINBypassAgeVerificationDefaultsKey]) {
        RUINInstallAgeVerification();
    } else if ([key isEqual:RUINCopyStickerGIFEnabledDefaultsKey]) {
        RUINInstallMenuExtras();
    } else if ([@[RUINHideAdsDefaultsKey, RUINHideRecommendationsDefaultsKey,
           RUINHideVoiceInputDefaultsKey, RUINHideAgentIBarDefaultsKey] containsObject:key]) {
        RUINRefreshInterfaceFeatures();
    } else if (![@[RUINHideVOOMTabDefaultsKey, RUINHideWalletTabDefaultsKey,
           RUINHideShoppingTabDefaultsKey, RUINHideNewsCallTabsDefaultsKey,
           RUINHideSettingsTabDefaultsKey, RUINHideAppsTabDefaultsKey,
           RUINStartupTabFixedDefaultsKey, RUINStartupTabDefaultsKey] containsObject:key]) {
        RUINRefreshSettingsFeatures();
        return;
    }
    // Tab preferences are consumed by native generation on restart, not rebuilt here.
    RUINRefreshRuntimeReport();
}

static void RUINMaybeScheduleEnvironmentSettings(void) {
    if (sEnvironmentSettingsPresented || sEnvironmentSettingsScheduled ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        ![NSProcessInfo.processInfo.environment[@"RUIN_SHOW_SETTINGS"] isEqualToString:@"1"]) return;
    sEnvironmentSettingsScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        sEnvironmentSettingsScheduled = NO;
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive && RUINPresentSettings())
            sEnvironmentSettingsPresented = YES;
    });
}

static void RUINApplicationDidBecomeActive(void) {
    if (RUINIsCompatible()) {
        RUINInstallLegacyMessagingConfiguration();
        RUINInstallLocalNotifications();
        RUINInstallLocalAppearance();
        RUINInstallLocalFont();
        RUINInstallLocalFontHooks();
        RUINInstallNativeMuteSend();
    }
    static BOOL selfTestAttempted;
    if (!selfTestAttempted && [NSProcessInfo.processInfo.environment[@"RUIN_SELF_TEST"] isEqualToString:@"1"]) {
        selfTestAttempted = YES;
        sKeychainSelfTest = RUINKeychainSelfTest();
    }
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        RUINReadControlEnabledDefaultsKey: @NO,
        RUINLocalNamesDefaultsKey: @{}
    }];
    if (RUINIsCompatible()) {
        RUINInstallSiriCompatibility();
        RUINRefreshFeaturesOnActivation(RUINChatCatalogAccount());
        RUINInstallReadBoundary();
        RUINInstallNativeEntry();
        RUINInstallSecondaryLogin();
        RUINInstallLegacyHome();
        RUINInstallReadOnReply();
        RUINInstallAutomaticReadGate();
        RUINInstallThemeFeatures();
        RUINInstallThemeStoreDownload();
        RUINInstallThemeStoreImages();
        RUINInstallNativeThemeImages();
        RUINInstallNativeThemeWorkflow();
        RUINInstallThemeStoreWeb();
        RUINInstallInterfaceFeatures();
        RUINInstallConfirmations();
        RUINInstallMessageHistory();
        RUINInstallUnsendRetention();
        RUINInstallRetainedMedia();
        RUINInstallUnsendOperation();
        RUINInstallUnsendMarkerUI();
        RUINInstallAgeVerification();
        RUINInstallMenuExtras();
        RUINInstallNativeChatControls();
        RUINInstallLocalUnreadBadges();
        InstallRuntimeInspector();
    }
    RUINMaybeScheduleEnvironmentSettings();
    RUINRefreshRuntimeReport();
    RUINMaybeShowCompatibilityWarning();
}

__attribute__((constructor)) static void RUINConstructor(void) {
    @autoreleasepool {
        RUINInstallBundleIdentity();
        if (RUINIsCompatible()) {
            RUINInstallSiriCompatibility();
            // Establish storage and the native visibility boundary before any
            // LINE singleton can cache the root menu during feature setup.
            RUINInstallCompatibility();
            RUINInstallKeychainCompatibility();
            RUINInstallNativeTabAvailability();
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            if (![defaults objectForKey:RUINLegacyMessagingEnabledDefaultsKey])
                [defaults setBool:[defaults boolForKey:RUINLocalLYPEnabledDefaultsKey]
                    forKey:RUINLegacyMessagingEnabledDefaultsKey];
            RUINInstallSecondaryLogin();
            RUINInstallLegacyHome();
            RUINInstallClientVersionAdvertisement();
            RUINInstallChatCatalog();
            RUINInstallLegacyMessagingConfiguration();
            RUINInstallLocalFont();
            RUINInstallLocalFontHooks();
            RUINInstallLocalNotificationLaunchBoundary();
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"RUINMessageMarkdownEnabled"];
            RUINPrepareNativeReadRangeProbe();
            RUINInstallFeatures();
            RUINInstallReadBoundary();
            RUINInstallReadOnReply();
            // Native theme validation and range decoding can run before the
            // application becomes active. Install their data hooks now; the
            // visible management screens still initialize on the normal path.
            RUINInstallThemeFeatures();
            RUINInstallNativeThemeRegistrationCapture();
            RUINInstallMessageHistory();
            RUINInstallReadUsersEvents();
            InstallRuntimeInspector();
            RUINInstallAutomaticReadGate();
            RUINInstallNativeEntry();
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSLog(@"RUIN loaded");
            sActiveObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                                object:nil queue:NSOperationQueue.mainQueue
                                                                           usingBlock:^(NSNotification *notification) {
                (void)notification;
                RUINApplicationDidBecomeActive();
            }];

        });
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) RUINApplicationDidBecomeActive();
    });
}
