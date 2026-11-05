#import "NativeFontCustomization.h"
#import "Features.h"
#import <stdatomic.h>
#import <stdint.h>
#import <string.h>

// Font callers pass feature 3 and compare the scalar reason to 3.
// Other features and the OFF state retain the complete original reason.
typedef uintptr_t (*RUINBenefitReasonGetter)(uintptr_t, const void *, const void *,
    void * __attribute__((swift_context))) __attribute__((swiftcall));
static RUINBenefitReasonGetter gOriginalReason;
static const void *gExpectedMetadata, *gExpectedWitness;
static atomic_bool gEnabled;
static atomic_uint_fast64_t gCalls, gFontCalls, gProjected;
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
        if (table[0] != (uintptr_t)(slide + 0x109b464c8) ||
            table[0xe0/8] != (uintptr_t)(slide + 0x103d2e084) ||
            *(const uintptr_t *)(slide + 0x10d25b100) != (uintptr_t)(slide + 0x10a95a6f4) ||
            memcmp((const void *)(slide + 0x103d2e084), expectedGetter, sizeof(expectedGetter)) ||
            memcmp((const void *)(slide + 0x10329061c), expectedFontCaller, sizeof(expectedFontCaller))) {
            atomic_store(&gStatus, FontFingerprintMismatch); return;
        }
        gExpectedMetadata = (const void *)(slide + 0x10d25b0c0);
        gExpectedWitness = table;
        gOriginalReason = (void *)table[0xe0/8];
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
        if (vm_protect(mach_task_self(), page, vm_page_size, FALSE, info.protection) != KERN_SUCCESS) {
            __atomic_store_n(&table[0xe0/8], (uintptr_t)gOriginalReason, __ATOMIC_RELEASE);
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
    puts("PASS font-only scalar reason projection preserves original calls and other benefits");
    return 0;
}
#endif
