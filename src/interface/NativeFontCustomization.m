#import "NativeFontCustomization.h"
#import "Features.h"
#import <stdatomic.h>
#import <stdint.h>
#import <string.h>

// Font callers pass feature 3 and compare the scalar reason to 3.
// Other features and the OFF state retain the complete original reason.
// Logos %hook cannot express this Swift protocol witness / swiftcall ABI.
// Keep the typed runtime data-pointer adapter inside RUIN.dylib; no IPA bytes
// or executable instructions are modified by it.
typedef uintptr_t (*RUINBenefitReasonGetter)(uintptr_t, const void *, const void *,
    void * __attribute__((swift_context))) __attribute__((swiftcall));
static RUINBenefitReasonGetter gOriginalReason;
typedef struct { uintptr_t first, second, third; uint8_t eligible; } RUINBenefitInfo;
typedef RUINBenefitInfo (*RUINBenefitInfoGetter)(uintptr_t, const void *, const void *,
    void * __attribute__((swift_context))) __attribute__((swiftcall));
_Static_assert(sizeof(RUINBenefitInfo) == 32, "native four-register result");
_Static_assert(offsetof(RUINBenefitInfo, eligible) == 24, "native eligibility byte");
static RUINBenefitInfoGetter gOriginalInfo;
static const void *gExpectedMetadata, *gExpectedWitness;
static atomic_bool gEnabled;
static atomic_uint_fast64_t gCalls, gFontCalls, gProjected;
static atomic_uint_fast64_t gInfoCalls, gFontInfoCalls, gInfoProjected;
static atomic_int gStatus;
enum { FontPending, FontVersionGated, FontFingerprintMismatch, FontProtectionFailed,
    FontRestoreFailed, FontInstalled };

static uintptr_t __attribute__((swiftcall)) RUINFontBenefitReason(uintptr_t feature,
    const void *metadata, const void *witness,
    void *context __attribute__((swift_context))) {
    atomic_fetch_add(&gCalls, 1);
    uintptr_t original = gOriginalReason(feature, metadata, witness, context);
    if (feature != 3 || metadata != gExpectedMetadata || witness != gExpectedWitness) return original;
    atomic_fetch_add(&gFontCalls, 1);
    if (!atomic_load(&gEnabled)) return original;
    atomic_fetch_add(&gProjected, 1);
    return 3;
}

static RUINBenefitInfo __attribute__((swiftcall)) RUINFontBenefitInfo(uintptr_t feature,
    const void *metadata, const void *witness,
    void *context __attribute__((swift_context))) {
    atomic_fetch_add(&gInfoCalls, 1);
    RUINBenefitInfo original = gOriginalInfo(feature, metadata, witness, context);
    if (feature != 3 || metadata != gExpectedMetadata || witness != gExpectedWitness) return original;
    atomic_fetch_add(&gFontInfoCalls, 1);
    if (atomic_load(&gEnabled)) {
        // Keep all owned suggestion payloads unchanged; LINE releases them.
        original.eligible = 1;
        atomic_fetch_add(&gInfoProjected, 1);
    }
    return original;
}

static BOOL RUINFontTargetMatches(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier] &&
        [info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] &&
        [info[@"CFBundleVersion"] isEqual:RUINTargetBuild];
}

#if !defined(RUIN_NATIVE_FONT_HOST_CHECK)
#import <mach/mach.h>
#import <mach-o/dyld.h>
void RUINInstallNativeFontCustomization(void) {
    BOOL target = RUINFontTargetMatches();
    atomic_store(&gEnabled, target && [NSUserDefaults.standardUserDefaults boolForKey:RUINLocalLYPEnabledDefaultsKey]);
    if (!target) { atomic_store(&gStatus, FontVersionGated); return; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        intptr_t slide = _dyld_get_image_vmaddr_slide(0);
        uintptr_t *table = (void *)(slide + 0x10c1fdbd0);
        static const uint32_t expectedGetter[] = {0xa9be4ff4,0xa9017bfd,0x910043fd,0xf9400294,
            0x97fffc06,0xa9417bfd,0xa8c24ff4,0xd65f03c0};
        static const uint32_t expectedFontCaller[] = {0xf94072a8,0x52800060,0xaa1303e1,0xaa1503e2,0xd63f0100};
        static const uint32_t expectedInfo[] = {0xa9be4ff4,0xa9017bfd,0x910043fd,0xf9400294,
            0x97fffe4b,0x12000063,0xa9417bfd,0xa8c24ff4,0xd65f03c0};
        if (table[0] != (uintptr_t)(slide + 0x109b464c8) ||
            table[0xe0/8] != (uintptr_t)(slide + 0x103d2e084) ||
            table[0xe8/8] != (uintptr_t)(slide + 0x103d2e0a4) ||
            *(const uintptr_t *)(slide + 0x10d25b100) != (uintptr_t)(slide + 0x10a95a6f4) ||
            memcmp((const void *)(slide + 0x103d2e084), expectedGetter, sizeof(expectedGetter)) ||
            memcmp((const void *)(slide + 0x103d2e0a4), expectedInfo, sizeof(expectedInfo)) ||
            memcmp((const void *)(slide + 0x10329061c), expectedFontCaller, sizeof(expectedFontCaller))) {
            atomic_store(&gStatus, FontFingerprintMismatch); return;
        }
        gExpectedMetadata = (const void *)(slide + 0x10d25b0c0);
        gExpectedWitness = table;
        gOriginalReason = (void *)table[0xe0/8];
        gOriginalInfo = (void *)table[0xe8/8];
        vm_address_t page = (vm_address_t)(table + 0xe0/8) & ~((vm_address_t)vm_page_size - 1);
        vm_address_t region = page; vm_size_t size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t result = vm_region_64(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64,
            (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (result != KERN_SUCCESS || region > page || region + size < page + vm_page_size ||
            vm_protect(mach_task_self(), page, vm_page_size, FALSE,
                VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
            atomic_store(&gStatus, FontProtectionFailed); return;
        }
        __atomic_store_n(&table[0xe0/8], (uintptr_t)RUINFontBenefitReason, __ATOMIC_RELEASE);
        __atomic_store_n(&table[0xe8/8], (uintptr_t)RUINFontBenefitInfo, __ATOMIC_RELEASE);
        if (vm_protect(mach_task_self(), page, vm_page_size, FALSE, info.protection) != KERN_SUCCESS) {
            __atomic_store_n(&table[0xe0/8], (uintptr_t)gOriginalReason, __ATOMIC_RELEASE);
            __atomic_store_n(&table[0xe8/8], (uintptr_t)gOriginalInfo, __ATOMIC_RELEASE);
            vm_protect(mach_task_self(), page, vm_page_size, FALSE, info.protection);
            atomic_store(&gStatus, FontRestoreFailed); return;
        }
        atomic_store(&gStatus, FontInstalled);
    });
}
#endif

NSDictionary *RUINNativeFontCustomizationDiagnostics(void) {
    NSArray *names = @[@"pending", @"version_gated", @"fingerprint_mismatch", @"protection_failed",
        @"protection_restore_failed", @"installed"];
    unsigned status = atomic_load(&gStatus);
    return @{@"status":status < names.count ? names[status] : @"unknown",
        @"targetMatches":@(RUINFontTargetMatches()), @"enabled":@(atomic_load(&gEnabled)),
        @"benefitReasonCalls":@(atomic_load(&gCalls)), @"fontReasonCalls":@(atomic_load(&gFontCalls)),
        @"projectedFontReasons":@(atomic_load(&gProjected)), @"fontFeatureValue":@3,
        @"benefitInfoCalls":@(atomic_load(&gInfoCalls)), @"fontInfoCalls":@(atomic_load(&gFontInfoCalls)),
        @"projectedFontInfo":@(atomic_load(&gInfoProjected)),
        @"nativeEligibleReason":@3, @"subscriptionStatusModified":@NO,
        @"customPickerAdded":@NO, @"nativeApplyFlowReplaced":@NO};
}

#if defined(RUIN_NATIVE_FONT_HOST_CHECK)
#include <assert.h>
#include <stdio.h>
NSString *const RUINTargetBundleIdentifier=@"jp.naver.line";
NSString *const RUINTargetVersion=@"26.16.0";
NSString *const RUINTargetBuild=@"2026.1006.1718";
static unsigned gOriginalCalls;
static unsigned gOriginalInfoCalls;
static RUINBenefitInfo __attribute__((swiftcall)) RUINTestInfo(uintptr_t feature, const void *metadata,
    const void *witness, void *context __attribute__((swift_context))) {
    (void)feature; assert(metadata && witness && context == (void *)3);
    gOriginalInfoCalls++; return (RUINBenefitInfo){0x12,0x34,0x56,0};
}
static uintptr_t __attribute__((swiftcall)) RUINTestReason(uintptr_t feature, const void *metadata,
    const void *witness, void *context __attribute__((swift_context))) {
    (void)feature; assert(metadata && witness && context == (void *)3);
    gOriginalCalls++; return 0x201;
}
int main(void) {
    gOriginalReason=RUINTestReason; gExpectedMetadata=(void *)1; gExpectedWitness=(void *)2;
    atomic_store(&gEnabled, false);
    assert(RUINFontBenefitReason(3,(void *)1,(void *)2,(void *)3)==0x201);
    atomic_store(&gEnabled, true);
    assert(RUINFontBenefitReason(3,(void *)1,(void *)2,(void *)3)==3);
    for (uintptr_t i=0;i<17;i++) if (i!=3)
        assert(RUINFontBenefitReason(i,(void *)1,(void *)2,(void *)3)==0x201);
    assert(RUINFontBenefitReason(3,(void *)4,(void *)2,(void *)3)==0x201);
    assert(RUINFontBenefitReason(3,(void *)1,(void *)4,(void *)3)==0x201);
    assert(gOriginalCalls==20 && atomic_load(&gProjected)==1);
    gOriginalInfo=RUINTestInfo;
    RUINBenefitInfo info=RUINFontBenefitInfo(3,(void *)1,(void *)2,(void *)3);
    assert(info.first==0x12 && info.second==0x34 && info.third==0x56 && info.eligible==1);
    info=RUINFontBenefitInfo(2,(void *)1,(void *)2,(void *)3); assert(!info.eligible);
    atomic_store(&gEnabled,false);
    info=RUINFontBenefitInfo(3,(void *)1,(void *)2,(void *)3); assert(!info.eligible);
    assert(gOriginalInfoCalls==3 && atomic_load(&gInfoProjected)==1);
    puts("PASS font-only scalar reason projection preserves original calls and other benefits");
    return 0;
}
#endif
