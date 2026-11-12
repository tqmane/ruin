#import "TargetMetadata.h"
#import "NativeMuteSend.h"

#import "../core/Features.h"
#import "LegacyMessagingConfiguration.h"
#import "VersionMapping.h"
#import "FeatureImage.h"
#import "../core/NativeFunctionPointer.h"

#import <objc/runtime.h>
#import <mach/machine.h>
#import <stdatomic.h>
#import <string.h>
#import <mach/mach.h>

static const char * const kNativeMuteSendClass = "_TtC15LineMessagingUI12ChatInputBar";
static const char * const kNativeMuteSendSelector = "longPressDidActivate:";
static const char * const kNativeMuteSendEncoding = "v24@0:8@16";

// The verified plain ARM64 witness takes metadata in x0, conformance in x1,
// borrowed self in x20 and returns Swift.Bool in w0. Like NativeTabAvailability,
// this rebinds one runtime data pointer; it does not patch executable code.
typedef uint8_t (*RUINMuteSettingGetter)(const void *, const void *,
    void * __attribute__((swift_context))) __attribute__((swiftcall));
typedef void (*RUINMuteConfigurationGetter)(uint8_t * __attribute__((swift_indirect_result)),
    const void *, const void *, const void *, void * __attribute__((swift_context))) __attribute__((swiftcall));
static atomic_uintptr_t originalGetter;
static atomic_uintptr_t originalConfigurationGetter;
static uintptr_t policyReturnPC, witnessTable;
static uintptr_t configurationReturnPC, configurationWitnessTable;
static atomic_bool adapterReady, adapterABIConfirmed;
static atomic_uint_fast64_t settingReads, projectedReads, otherReads;
static atomic_int nativeSetting = ATOMIC_VAR_INIT(-1), effectiveSetting = ATOMIC_VAR_INIT(-1);
static atomic_uint_fast64_t configurationReads, projectedConfigurationReads, otherConfigurationReads;
static atomic_int nativeConfiguration = ATOMIC_VAR_INIT(-1), effectiveConfiguration = ATOMIC_VAR_INIT(-1);
enum { AdapterPending, AdapterUnsupportedHost, AdapterUnsupportedABI, AdapterVerificationFailed,
    AdapterProtectionFailed, AdapterCollision, AdapterProtectionRestoreFailed, AdapterRollbackIncomplete, AdapterInstalled };
static atomic_int adapterStatus;
static atomic_uint installAttempts;
static atomic_bool rollbackSlotsComplete = ATOMIC_VAR_INIT(true);
static atomic_bool rollbackProtectionComplete = ATOMIC_VAR_INIT(true);
#if defined(RUIN_NATIVE_MUTE_SEND_HOST_CHECK)
static BOOL testOptionEnabled;
static uintptr_t testCallerPC;
static uintptr_t testConfigurationCallerPC;
#endif

static BOOL RUINMuteOptionEnabled(void) {
#if defined(RUIN_NATIVE_MUTE_SEND_HOST_CHECK)
    return testOptionEnabled;
#else
    return [NSUserDefaults.standardUserDefaults boolForKey:RUINLegacyMessagingEnabledDefaultsKey];
#endif
}

static BOOL RUINMuteWitnessABISupported(const struct mach_header_64 *header,
    const RUINNativeMuteSendMapping *mapping, BOOL verifiedGuest) {
    return header && header->magic == MH_MAGIC_64 &&
        (header->filetype == MH_EXECUTE || (verifiedGuest && header->filetype == MH_DYLIB)) &&
        header->cputype == CPU_TYPE_ARM64 && header->cpusubtype == CPU_SUBTYPE_ARM64_ALL &&
        mapping && mapping->status == RUINMappingStatusVerified &&
        mapping->witnessTableVA && !(mapping->witnessTableVA % sizeof(uintptr_t)) &&
        mapping->conformanceVA && mapping->getterVA && mapping->policyReturnVA &&
        mapping->anchors && mapping->anchorCount;
}

static BOOL RUINMuteWitnessMatches(const RUINNativeMuteSendMapping *mapping,
    intptr_t slide, const uintptr_t *table) {
    return mapping && table && table[0] == (uintptr_t)(slide + mapping->conformanceVA) &&
        table[1] == (uintptr_t)(slide + mapping->getterVA);
}

static uint8_t RUINReadMuteSetting(const void *metadata, const void *witness, void *context,
    uintptr_t caller) {
    RUINMuteSettingGetter getter = (RUINMuteSettingGetter)RUINNativeFunctionPointerForCall(
        atomic_load_explicit(&originalGetter, memory_order_acquire));
    uint8_t value = getter ? getter(metadata, witness, context) : 0;
    if (!atomic_load_explicit(&adapterReady, memory_order_acquire) ||
        caller != policyReturnPC || (uintptr_t)witness != witnessTable || value > 1) {
        atomic_fetch_add(&otherReads, 1);
        return value;
    }
    atomic_fetch_add(&settingReads, 1);
    atomic_store(&nativeSetting, value);
    uint8_t effective = RUINMuteOptionEnabled() ? 1 : value;
    if (effective != value) atomic_fetch_add(&projectedReads, 1);
    atomic_store(&effectiveSetting, effective);
    return effective;
}

static uint8_t __attribute__((swiftcall,noinline,disable_tail_calls)) RUINMuteSettingGate(
    const void *metadata, const void *witness, void *context __attribute__((swift_context))) {
#if defined(RUIN_NATIVE_MUTE_SEND_HOST_CHECK)
    uintptr_t caller = testCallerPC;
#else
    uintptr_t caller = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
#endif
    return RUINReadMuteSetting(metadata, witness, context, caller);
}

// This specialized key has an indirect one-byte Bool result in x8. Only the
// caller-owned return buffer changes; the configuration dictionary stays native.
static void __attribute__((swiftcall,noinline,disable_tail_calls)) RUINMuteConfigurationGate(
    uint8_t *output __attribute__((swift_indirect_result)), const void *configuration,
    const void *metadata, const void *witness, void *context __attribute__((swift_context))) {
#if defined(RUIN_NATIVE_MUTE_SEND_HOST_CHECK)
    uintptr_t caller = testConfigurationCallerPC;
#else
    uintptr_t caller = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
#endif
    RUINMuteConfigurationGetter getter = (RUINMuteConfigurationGetter)RUINNativeFunctionPointerForCall(
        atomic_load_explicit(&originalConfigurationGetter, memory_order_acquire));
    if (getter) getter(output, configuration, metadata, witness, context);
    else if (output) *output = 0;
    if (!output || !atomic_load_explicit(&adapterReady, memory_order_acquire) ||
        caller != configurationReturnPC || (uintptr_t)witness != configurationWitnessTable || *output > 1) {
        atomic_fetch_add(&otherConfigurationReads, 1);
        return;
    }
    atomic_fetch_add(&configurationReads, 1);
    uint8_t value = *output;
    atomic_store(&nativeConfiguration, value);
    if (RUINMuteOptionEnabled()) *output = 1;
    if (*output != value) atomic_fetch_add(&projectedConfigurationReads, 1);
    atomic_store(&effectiveConfiguration, *output);
}

static BOOL RUINMuteConfigurationWitnessMatches(const RUINNativeMuteSendMapping *mapping,
    intptr_t slide, const uintptr_t *table) {
    return mapping && table && mapping->configurationWitnessTableVA &&
        !(mapping->configurationWitnessTableVA % sizeof(uintptr_t)) &&
        mapping->configurationConformanceVA && mapping->configurationValueTypeVA &&
        mapping->configurationGetterVA && mapping->configurationReturnVA &&
        table[0] == (uintptr_t)(slide + mapping->configurationConformanceVA) &&
        table[1] == (uintptr_t)(slide + mapping->configurationValueTypeVA) &&
        table[2] == (uintptr_t)(slide + mapping->configurationGetterVA);
}

static BOOL RUINStoreMuteConfigurationWitness(const struct mach_header_64 *header,
    const RUINNativeMuteSendMapping *mapping, intptr_t slide, uintptr_t *table, BOOL verifiedGuest) {
    if (!RUINMuteWitnessABISupported(header, mapping, verifiedGuest) ||
        !RUINMuteConfigurationWitnessMatches(mapping, slide, table)) return NO;
    uintptr_t expected = slide + mapping->configurationGetterVA;
    atomic_store_explicit(&originalConfigurationGetter, expected, memory_order_release);
    configurationReturnPC = slide + mapping->configurationReturnVA;
    configurationWitnessTable = (uintptr_t)table;
    uintptr_t replacement = RUINNativeFunctionPointerRaw((const void *)RUINMuteConfigurationGate);
    return __atomic_compare_exchange_n(&table[2], &expected, replacement, NO,
        __ATOMIC_RELEASE, __ATOMIC_RELAXED);
}

static BOOL RUINRestoreMuteConfigurationWitness(uintptr_t *table) {
    atomic_store_explicit(&adapterReady, false, memory_order_release);
    uintptr_t replacement = RUINNativeFunctionPointerRaw((const void *)RUINMuteConfigurationGate);
    return __atomic_compare_exchange_n(&table[2], &replacement, atomic_load(&originalConfigurationGetter), NO,
        __ATOMIC_RELEASE, __ATOMIC_RELAXED) || replacement == atomic_load(&originalConfigurationGetter);
}

static BOOL RUINStoreMuteWitness(const struct mach_header_64 *header,
    const RUINNativeMuteSendMapping *mapping, intptr_t slide, uintptr_t *table, BOOL verifiedGuest) {
    if (!RUINMuteWitnessABISupported(header, mapping, verifiedGuest) || !RUINMuteWitnessMatches(mapping, slide, table))
        return NO;
    uintptr_t expected = (uintptr_t)(slide + mapping->getterVA);
    atomic_store_explicit(&originalGetter, expected, memory_order_release);
    policyReturnPC = slide + mapping->policyReturnVA;
    witnessTable = (uintptr_t)table;
    uintptr_t replacement = RUINNativeFunctionPointerRaw((const void *)RUINMuteSettingGate);
    return __atomic_compare_exchange_n(&table[1], &expected, replacement, NO,
        __ATOMIC_RELEASE, __ATOMIC_RELAXED);
}

static BOOL RUINRestoreMuteWitness(uintptr_t *table) {
    atomic_store_explicit(&adapterReady, false, memory_order_release);
    uintptr_t replacement = RUINNativeFunctionPointerRaw((const void *)RUINMuteSettingGate);
    return __atomic_compare_exchange_n(&table[1], &replacement, atomic_load(&originalGetter), NO,
        __ATOMIC_RELEASE, __ATOMIC_RELAXED) || replacement == atomic_load(&originalGetter);
}

// Page operations are shared by the device adapter and its fault-injection fixture.
#if defined(RUIN_NATIVE_MUTE_SEND_HOST_CHECK)
static unsigned testProtectionCalls, testProtectionFailure;
static uint32_t testProtectionFailureMask;
static BOOL testProtectionQueryFailure;
static uintptr_t *testCollisionTable;
#endif
static BOOL RUINMutePageProtection(vm_address_t page, vm_prot_t *protection) {
#if defined(RUIN_NATIVE_MUTE_SEND_HOST_CHECK)
    (void)page;
    *protection = VM_PROT_READ;
    return !testProtectionQueryFailure;
#else
    vm_address_t region = page; vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t result = vm_region_64(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info, &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || region > page || size < page - region ||
        size - (page - region) < vm_page_size || !(info.protection & VM_PROT_READ)) return NO;
    *protection = info.protection;
    return YES;
#endif
}
static BOOL RUINMuteProtectPage(vm_address_t page, vm_prot_t protection) {
#if defined(RUIN_NATIVE_MUTE_SEND_HOST_CHECK)
    (void)page; (void)protection;
    ++testProtectionCalls;
    if (testProtectionCalls == 3 && testCollisionTable) testCollisionTable[2]++;
    return testProtectionCalls != testProtectionFailure &&
        !(testProtectionCalls < 32 && (testProtectionFailureMask & (1u << testProtectionCalls)));
#else
    return vm_protect(mach_task_self(), page, vm_page_size, FALSE, protection) == KERN_SUCCESS;
#endif
}

static int RUINInstallMuteTable(uintptr_t *table, size_t tableBytes,
    BOOL (^store)(void), BOOL (^restore)(void)) {
    vm_address_t page = (vm_address_t)table & ~((vm_address_t)vm_page_size - 1);
    vm_prot_t protection;
    if (tableBytes > vm_page_size || (uintptr_t)table - page > vm_page_size - tableBytes ||
        !RUINMutePageProtection(page, &protection) ||
        !RUINMuteProtectPage(page, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY))
        return AdapterProtectionFailed;
    BOOL stored = store();
    if (RUINMuteProtectPage(page, protection)) return stored ? AdapterInstalled : AdapterCollision;
    BOOL slotsRestored = !stored || restore();
    BOOL protectionRestored = RUINMuteProtectPage(page, protection);
    atomic_store(&rollbackSlotsComplete, atomic_load(&rollbackSlotsComplete) && slotsRestored);
    atomic_store(&rollbackProtectionComplete, atomic_load(&rollbackProtectionComplete) && protectionRestored);
    return slotsRestored && protectionRestored ? AdapterProtectionRestoreFailed : AdapterRollbackIncomplete;
}

static int RUINInstallMutePair(const struct mach_header_64 *header,
    const RUINNativeMuteSendMapping *mapping, intptr_t slide,
    uintptr_t *table, uintptr_t *configurationTable, BOOL verifiedGuest) {
    atomic_store_explicit(&adapterReady, false, memory_order_release);
    atomic_store(&rollbackSlotsComplete, true);
    atomic_store(&rollbackProtectionComplete, true);
    // Capture both original call paths before the first replacement is visible.
    if (!RUINMuteWitnessABISupported(header, mapping, verifiedGuest) ||
        !RUINMuteWitnessMatches(mapping, slide, table) ||
        !RUINMuteConfigurationWitnessMatches(mapping, slide, configurationTable)) return AdapterCollision;
    atomic_store(&originalGetter, slide + mapping->getterVA);
    atomic_store(&originalConfigurationGetter, slide + mapping->configurationGetterVA);
    policyReturnPC = slide + mapping->policyReturnVA; witnessTable = (uintptr_t)table;
    configurationReturnPC = slide + mapping->configurationReturnVA;
    configurationWitnessTable = (uintptr_t)configurationTable;
    int result = RUINInstallMuteTable(table, 2 * sizeof(*table), ^BOOL{
        return RUINStoreMuteWitness(header, mapping, slide, table, verifiedGuest);
    }, ^BOOL{ return RUINRestoreMuteWitness(table); });
    if (result != AdapterInstalled) return result;
    result = RUINInstallMuteTable(configurationTable, 3 * sizeof(*configurationTable), ^BOOL{
        return RUINStoreMuteConfigurationWitness(header, mapping, slide, configurationTable, verifiedGuest);
    }, ^BOOL{ return RUINRestoreMuteConfigurationWitness(configurationTable); });
    if (result != AdapterInstalled) {
        int rollback = RUINInstallMuteTable(table, 2 * sizeof(*table), ^BOOL{
            return RUINRestoreMuteWitness(table);
        }, ^BOOL{ return table[1] == atomic_load(&originalGetter); });
        if (rollback != AdapterInstalled && rollback != AdapterProtectionRestoreFailed) {
            atomic_store(&rollbackSlotsComplete, table[1] == atomic_load(&originalGetter));
            return AdapterRollbackIncomplete;
        }
        return result;
    }
    atomic_store_explicit(&adapterReady, true, memory_order_release);
    return AdapterInstalled;
}

static NSString *RUINMuteAdapterStatus(void) {
    switch (atomic_load(&adapterStatus)) {
        case AdapterUnsupportedHost: return @"unsupportedVerifiedHost";
        case AdapterUnsupportedABI: return @"unsupportedNativePointerABI";
        case AdapterVerificationFailed: return @"nativeWitnessVerificationFailed";
        case AdapterProtectionFailed: return @"nativeWitnessProtectionFailed";
        case AdapterCollision: return @"nativeWitnessChanged";
        case AdapterProtectionRestoreFailed: return @"nativeWitnessProtectionRestoreFailed";
        case AdapterRollbackIncomplete: return @"nativeWitnessRollbackIncomplete";
        case AdapterInstalled: return @"nativeMuteReadAdaptersInstalled";
        default: return @"pending";
    }
}

static BOOL RUINNativeMuteSendTargetMatches(void)
{
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
}

NSDictionary<NSString *, id> *RUINNativeMuteSendDiagnostics(void)
{
    BOOL targetMatches = RUINNativeMuteSendTargetMatches();
    BOOL enabled = targetMatches && RUINMuteOptionEnabled();
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
        !decoderInstalled ? @"configurationDecoderUnavailable" : RUINMuteAdapterStatus();
    NSString *reason = !targetMatches ? @"The exact LINE bundle, version, or build did not match." :
        !enabled ? @"The independent legacy-messaging option is off." :
        !inputClass ? @"The verified native send-button class is unavailable." :
        !method ? @"The verified native long-press selector is unavailable." :
        !longPressABIConfirmed ? @"The native long-press encoding differs from the verified build." :
        !decoderInstalled ? @"The native configuration decoder did not match its verified ABI." :
        atomic_load(&adapterReady) ? @"The LabsSilentMessageEnabledKey and chat.silentmessage reads follow the independent option; read counters show whether native menu policy reached them." :
        @"The exact native general-settings witness could not be installed; inspect nativeGeneralSettingAdapterStatus.";

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
        @"muteFeatureBooleanPath":@"SendButtonLongPressMenuPolicy.generalSettingsService[chat.silentmessage]",
        @"muteFeatureBooleanType":@"Swift.Bool",
        @"rawFeatureKeySymbol":@"RawPremiumMuteMessageEnabledKey",
        @"rawFeatureKeyProvenAsDefaultsKey":@NO,
        @"muteGateFunctionProven":@(atomic_load(&adapterABIConfirmed)),
        @"muteGateFunctionABIProven":@(atomic_load(&adapterABIConfirmed)),
        @"installationAttempts":@(atomic_load(&installAttempts)),
        @"rollbackSlotsComplete":@(atomic_load(&rollbackSlotsComplete)),
        @"rollbackProtectionComplete":@(atomic_load(&rollbackProtectionComplete)),
        @"hookInstalled":@(atomic_load(&adapterReady)),
        @"configurationDecoderInstalled":@(decoderInstalled),
        @"nativeGeneralSettingAdapterStatus":RUINMuteAdapterStatus(),
        @"nativeConfigurationAdapterStatus":RUINMuteAdapterStatus(),
        @"nativeConfigurationKey":@"LabsSilentMessageEnabledKey",
        @"nativeConfigurationProtocol":@"LineConfigurationInterface.CompositeConfigurationKey",
        @"nativeConfigurationRawKey":@"function.lab.silent_message",
        @"nativeConfigurationValue":atomic_load(&nativeConfiguration) < 0 ? (id)NSNull.null : @(atomic_load(&nativeConfiguration)),
        @"effectiveConfigurationValue":atomic_load(&effectiveConfiguration) < 0 ? (id)NSNull.null : @(atomic_load(&effectiveConfiguration)),
        @"nativeConfigurationReads":@(atomic_load(&configurationReads)),
        @"projectedConfigurationReads":@(atomic_load(&projectedConfigurationReads)),
        @"otherConfigurationReads":@(atomic_load(&otherConfigurationReads)),
        @"nativeGeneralSettingKey":@"chat.silentmessage",
        @"nativeGeneralSetting":atomic_load(&nativeSetting) < 0 ? (id)NSNull.null : @(atomic_load(&nativeSetting)),
        @"effectiveGeneralSetting":atomic_load(&effectiveSetting) < 0 ? (id)NSNull.null : @(atomic_load(&effectiveSetting)),
        @"nativeGeneralSettingReads":@(atomic_load(&settingReads)),
        @"projectedGeneralSettingReads":@(atomic_load(&projectedReads)),
        @"otherGeneralSettingReads":@(atomic_load(&otherReads)),
        @"nativeGeneralSettingPersisted":@NO,
        @"legacyConfigurationProjected":@(projected),
        @"muteGateABIConfirmed":@(atomic_load(&adapterABIConfirmed)),
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
    RUINInstallNativeMuteSettingAdapter();
}

#if !defined(RUIN_NATIVE_MUTE_SEND_HOST_CHECK)
static BOOL installQueued, installFinished;
static RUINFeatureImage installedImage;

static void RUINAttemptNativeMuteInstall(void) {
    installQueued = NO;
    if (installFinished) return;
    unsigned attempt = atomic_fetch_add(&installAttempts, 1) + 1;
    const RUINVersionMapping *version = RUINMappingForInfo(NSBundle.mainBundle.infoDictionary);
    if (!version || version->messaging.nativeMuteSend.status != RUINMappingStatusVerified) {
        atomic_store(&adapterStatus, AdapterUnsupportedHost);
        installFinished = YES;
        return;
    }
    Class cls = objc_getClass(kNativeMuteSendClass);
    SEL selector = sel_registerName(kNativeMuteSendSelector);
    // Require an owned method, rather than an inherited or guessed implementation.
    unsigned count = 0; Method method = NULL;
    Method *methods = cls ? class_copyMethodList(cls, &count) : NULL;
    for (unsigned i = 0; i < count; i++) if (method_getName(methods[i]) == selector) method = methods[i];
    free(methods);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (encoding && strcmp(encoding, kNativeMuteSendEncoding)) {
        atomic_store(&adapterStatus, AdapterUnsupportedABI);
        installFinished = YES;
        return;
    }
    RUINFeatureImage image = {0};
    const void *implementation = method ? (const void *)RUINNativeFunctionPointerRaw(
        (const void *)method_getImplementation(method)) : NULL;
    if (!encoding ||
        !RUINResolveFeatureImage(&version->host, implementation, &image)) {
        atomic_store(&adapterStatus, AdapterPending);
        if (attempt < 8) {
            installQueued = YES;
            double delay = MIN(4.0, 0.25 * (1u << (attempt - 1)));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ RUINAttemptNativeMuteInstall(); });
        } else {
            atomic_store(&adapterStatus, AdapterUnsupportedHost);
            installFinished = YES;
        }
        return;
    }
    const RUINNativeMuteSendMapping *mapping = &version->messaging.nativeMuteSend;
    BOOL guest = image.convertedExecutable;
    if (!RUINMuteWitnessABISupported(image.image.header, mapping, guest)) {
        atomic_store(&adapterStatus, AdapterUnsupportedABI);
    } else {
        uintptr_t snapshot[2], configurationSnapshot[3];
        if (!RUINVerifyFeatureInstructions(&image, mapping->anchors, mapping->anchorCount) ||
            !RUINReadFeatureImageBytes(&image, mapping->witnessTableVA, snapshot, sizeof(snapshot), "__DATA_CONST") ||
            !RUINMuteWitnessMatches(mapping, image.image.slide, snapshot) ||
            !RUINReadFeatureImageBytes(&image, mapping->configurationWitnessTableVA,
                configurationSnapshot, sizeof(configurationSnapshot), "__DATA") ||
            !RUINMuteConfigurationWitnessMatches(mapping, image.image.slide, configurationSnapshot) ||
            !RUINFeatureImageMatches(&image, &version->host)) {
            atomic_store(&adapterStatus, AdapterVerificationFailed);
        } else {
            atomic_store(&adapterABIConfirmed, true);
            // Keep originals alive even if a failed rollback leaves a pass-through gate reachable.
            installedImage = image;
            memset(&image, 0, sizeof(image));
            int result = RUINInstallMutePair(installedImage.image.header, mapping, installedImage.image.slide,
                (void *)(installedImage.image.slide + mapping->witnessTableVA),
                (void *)(installedImage.image.slide + mapping->configurationWitnessTableVA), guest);
            atomic_store(&adapterStatus, result);
        }
    }
    RUINReleaseFeatureImage(&image);
    installFinished = YES; // A fingerprint, collision or protection failure is permanent for this image.
}
#endif

void RUINInstallNativeMuteSettingAdapter(void) {
#if !defined(RUIN_NATIVE_MUTE_SEND_HOST_CHECK)
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!installQueued && !installFinished) {
            installQueued = YES;
            RUINAttemptNativeMuteInstall();
        }
    });
#endif
}

#if defined(RUIN_NATIVE_MUTE_SEND_HOST_CHECK)
#include <assert.h>
#include <stdio.h>
void RUINInstallLegacyMessagingConfiguration(void) {}
NSDictionary *RUINLegacyMessagingConfigurationDiagnostics(void) { return @{}; }

static uint8_t testNativeValue;
static uint8_t testNativeConfigurationValue;
static unsigned testOriginalCalls;
static unsigned testOriginalConfigurationCalls;
static const void *testMetadata, *testWitness;
static const void *testConfigurationSnapshot;
static void *testContext;
static uint8_t __attribute__((swiftcall)) TestMuteGetter(const void *metadata, const void *witness,
    void *context __attribute__((swift_context))) {
    testOriginalCalls++;
    testMetadata = metadata; testWitness = witness; testContext = context;
    return testNativeValue;
}
static void __attribute__((swiftcall)) TestMuteConfigurationGetter(
    uint8_t *output __attribute__((swift_indirect_result)), const void *configuration,
    const void *metadata, const void *witness, void *context __attribute__((swift_context))) {
    testOriginalConfigurationCalls++;
    testConfigurationSnapshot = configuration;
    testMetadata = metadata; testWitness = witness; testContext = context;
    *output = testNativeConfigurationValue;
}

int main(int argc, const char **argv) { @autoreleasepool {
    const RUINVersionMapping *version = RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"});
    assert(version && version->messaging.nativeMuteSend.status == RUINMappingStatusVerified);
    const RUINNativeMuteSendMapping *mapped = &version->messaging.nativeMuteSend;
    if (argc == 2 && !strcmp(argv[1], "--mapping")) {
        NSMutableArray *anchors = [NSMutableArray array];
        for (size_t i = 0; i < mapped->anchorCount; i++) {
            const RUINInstructionAnchor *anchor = &mapped->anchors[i];
            NSMutableArray *words = [NSMutableArray array];
            for (unsigned j = 0; j < anchor->wordCount; j++) [words addObject:@(anchor->words[j])];
            [anchors addObject:@{@"address":@(anchor->address), @"words":words}];
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"uuid":@(version->host.uuid),
            @"sha256":@(version->host.sourceSHA256), @"witnessTableVA":@(mapped->witnessTableVA),
            @"conformanceVA":@(mapped->conformanceVA), @"getterVA":@(mapped->getterVA),
            @"policyReturnVA":@(mapped->policyReturnVA), @"anchors":anchors,
            @"configurationWitnessTableVA":@(mapped->configurationWitnessTableVA),
            @"configurationConformanceVA":@(mapped->configurationConformanceVA),
            @"configurationValueTypeVA":@(mapped->configurationValueTypeVA),
            @"configurationGetterVA":@(mapped->configurationGetterVA),
            @"configurationReturnVA":@(mapped->configurationReturnVA)} options:0 error:NULL];
        puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
        return 0;
    }
    const RUINVersionMapping *old = RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"});
    assert(old && old->messaging.nativeMuteSend.status != RUINMappingStatusVerified);
    struct mach_header_64 header = {.magic=MH_MAGIC_64, .filetype=MH_EXECUTE,
        .cputype=CPU_TYPE_ARM64, .cpusubtype=CPU_SUBTYPE_ARM64_ALL};
    RUINNativeMuteSendMapping mapping = *mapped;
    uintptr_t table[2] = {mapping.conformanceVA, RUINNativeFunctionPointerRaw((const void *)TestMuteGetter)};
    mapping.getterVA = table[1];
    assert(RUINMuteWitnessABISupported(&header, &mapping, NO));
    header.cpusubtype = CPU_SUBTYPE_ARM64E;
    assert(!RUINStoreMuteWitness(&header, &mapping, 0, table, NO));
    header.cpusubtype = CPU_SUBTYPE_ARM64_ALL;
    header.filetype = MH_DYLIB;
    assert(!RUINStoreMuteWitness(&header, &mapping, 0, table, NO));
    header.filetype = MH_EXECUTE;
    table[0]++;
    assert(!RUINStoreMuteWitness(&header, &mapping, 0, table, NO));
    table[0]--;
    assert(RUINStoreMuteWitness(&header, &mapping, 0, table, NO));
    assert(!RUINStoreMuteWitness(&header, &mapping, 0, table, NO)); // Never capture our own gate as original.
    RUINMuteSettingGetter getter = (RUINMuteSettingGetter)RUINNativeFunctionPointerForCall(table[1]);
    int metadata = 42, context = 17;
    testCallerPC = mapping.policyReturnVA;
    testOptionEnabled = YES;
    assert(getter(&metadata, table, &context) == 0); // Installation is pass-through until fully ready.
    atomic_store(&adapterReady, true);
    testOptionEnabled = NO;
    unsigned before = testOriginalCalls;
    assert(getter(&metadata, table, &context) == 0 && testOriginalCalls == before + 1);
    assert(testMetadata == &metadata && testWitness == table && testContext == &context);
    testOptionEnabled = YES;
    assert(getter(&metadata, table, &context) == 1 && testNativeValue == 0);
    assert(atomic_load(&nativeSetting) == 0 && atomic_load(&effectiveSetting) == 1);
    assert(atomic_load(&projectedReads) == 1);
    testCallerPC++;
    assert(getter(&metadata, table, &context) == 0); // Other consumers retain the real setting.
    testCallerPC--;
    assert(getter(&metadata, &metadata, &context) == 0); // Reject a different conformance.
    testOptionEnabled = NO;
    assert(getter(&metadata, table, &context) == 0); // OFF immediately restores native behavior.
    testNativeValue = 1;
    assert(getter(&metadata, table, &context) == 1);
    testOptionEnabled = YES;
    assert(getter(&metadata, table, &context) == 1);
    testNativeValue = 2;
    assert(getter(&metadata, table, &context) == 2); // Unknown scalar values fail closed.
    uintptr_t configurationTable[3] = {mapping.configurationConformanceVA, mapping.configurationValueTypeVA,
        RUINNativeFunctionPointerRaw((const void *)TestMuteConfigurationGetter)};
    mapping.configurationGetterVA = configurationTable[2];
    configurationTable[1]++;
    assert(!RUINStoreMuteConfigurationWitness(&header, &mapping, 0, configurationTable, NO));
    configurationTable[1]--;
    assert(RUINStoreMuteConfigurationWitness(&header, &mapping, 0, configurationTable, NO));
    assert(!RUINStoreMuteConfigurationWitness(&header, &mapping, 0, configurationTable, NO));
    RUINMuteConfigurationGetter configurationGetter = (RUINMuteConfigurationGetter)
        RUINNativeFunctionPointerForCall(configurationTable[2]);
    int configuration = 58;
    struct { uint8_t before, value, after; } result = {0xa5, 0, 0x5a};
    testConfigurationCallerPC = mapping.configurationReturnVA;
    testOptionEnabled = YES;
    configurationGetter(&result.value, &configuration, &metadata, configurationTable, &context);
    assert(result.value == 1 && result.before == 0xa5 && result.after == 0x5a);
    assert(testConfigurationSnapshot == &configuration && testMetadata == &metadata &&
        testWitness == configurationTable && testContext == &context);
    assert(testOriginalConfigurationCalls == 1 && testNativeConfigurationValue == 0);
    assert(atomic_load(&nativeConfiguration) == 0 && atomic_load(&effectiveConfiguration) == 1);
    assert(atomic_load(&projectedConfigurationReads) == 1);
    testOptionEnabled = NO;
    configurationGetter(&result.value, &configuration, &metadata, configurationTable, &context);
    assert(result.value == 0);
    testNativeConfigurationValue = 1;
    configurationGetter(&result.value, &configuration, &metadata, configurationTable, &context);
    assert(result.value == 1);
    testOptionEnabled = YES; testNativeConfigurationValue = 0;
    testConfigurationCallerPC++;
    configurationGetter(&result.value, &configuration, &metadata, configurationTable, &context);
    assert(result.value == 0);
    testConfigurationCallerPC--;
    configurationGetter(&result.value, &configuration, &metadata, &metadata, &context);
    assert(result.value == 0);
    testNativeConfigurationValue = 2;
    configurationGetter(&result.value, &configuration, &metadata, configurationTable, &context);
    assert(result.value == 2);
    RUINRestoreMuteConfigurationWitness(configurationTable);
    assert(configurationTable[2] == mapping.configurationGetterVA);
    RUINRestoreMuteWitness(table);
    assert(table[1] == mapping.getterVA && !atomic_load(&adapterReady));
    // Exercise the production two-table publisher, including failures after the
    // first gate is reachable. A half-installed pair must always pass through.
    for (unsigned failure = 0; failure <= 4; failure++) {
        table[1] = mapping.getterVA; configurationTable[2] = mapping.configurationGetterVA;
        testProtectionCalls = 0; testProtectionFailure = failure;
        int status = RUINInstallMutePair(&header, &mapping, 0, table, configurationTable, NO);
        assert(status == (failure ? (failure == 1 || failure == 3 ? AdapterProtectionFailed :
            AdapterProtectionRestoreFailed) : AdapterInstalled));
        assert(atomic_load(&adapterReady) == !failure);
        if (failure) {
            assert(table[1] == mapping.getterVA && configurationTable[2] == mapping.configurationGetterVA);
            assert(atomic_load(&rollbackSlotsComplete) && atomic_load(&rollbackProtectionComplete));
        } else {
            assert(RUINRestoreMuteWitness(table)); assert(RUINRestoreMuteConfigurationWitness(configurationTable));
        }
    }
    testProtectionCalls = 0; testProtectionFailure = 0;
    testCollisionTable = configurationTable;
    assert(RUINInstallMutePair(&header,&mapping,0,table,configurationTable,NO) == AdapterCollision);
    assert(table[1] == mapping.getterVA && configurationTable[2] == mapping.configurationGetterVA + 1);
    assert(!atomic_load(&adapterReady)); // A foreign replacement is never overwritten during rollback.
    configurationTable[2]--; testCollisionTable = NULL;
    testProtectionCalls = 0; testProtectionFailure = 3;
    testProtectionFailureMask = 1u << 4; // Second install fails, then first rollback cannot make its page writable.
    assert(RUINInstallMutePair(&header,&mapping,0,table,configurationTable,NO) == AdapterRollbackIncomplete);
    assert(!atomic_load(&adapterReady) && !atomic_load(&rollbackSlotsComplete));
    assert(atomic_load(&rollbackProtectionComplete));
    testNativeValue = 0; testOptionEnabled = YES;
    assert(getter(&metadata,table,&context) == 0); // Leftover gate retains its original.
    assert(RUINRestoreMuteWitness(table));
    testProtectionCalls = 0; testProtectionFailure = 0; testProtectionFailureMask = 0;
    testProtectionCalls = 0; testProtectionFailureMask = (1u << 4) | (1u << 5);
    assert(RUINInstallMutePair(&header,&mapping,0,table,configurationTable,NO) == AdapterRollbackIncomplete);
    assert(!atomic_load(&adapterReady) && !atomic_load(&rollbackProtectionComplete));
    assert(table[1] == mapping.getterVA && configurationTable[2] == mapping.configurationGetterVA);
    testProtectionCalls = 0; testProtectionFailureMask = 0;
    header.filetype = MH_DYLIB;
    assert(RUINInstallMutePair(&header,&mapping,0,table,configurationTable,NO) == AdapterCollision);
    assert(RUINInstallMutePair(&header,&mapping,0,table,configurationTable,YES) == AdapterInstalled);
    assert(RUINRestoreMuteWitness(table)); assert(RUINRestoreMuteConfigurationWitness(configurationTable));
    header.filetype = MH_EXECUTE;
    configurationTable[2]++;
    assert(RUINInstallMutePair(&header,&mapping,0,table,configurationTable,NO) == AdapterCollision);
    assert(table[1] == mapping.getterVA && !atomic_load(&adapterReady));
    configurationTable[2]--;
    table[1]++; assert(!RUINRestoreMuteWitness(table)); table[1]--;
    puts("PASS native mute settings/config: scalar and indirect Bool ABI/context, original-once, exact caller/conformance, ON/OFF, return-buffer bounds, native state preserved, unsupported ABI/collision rejected");
} return 0; }
#endif
