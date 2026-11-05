#import "NativeTabAvailability.h"
#import "InterfaceFeatures.h"
#import "Features.h"
#include <stdatomic.h>
#include <stdint.h>

#if !defined(RUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK)
#import <mach/mach.h>
#import <mach-o/dyld.h>
#endif

// LINE 26.16.0's default availableMenus implementation invokes these scalar
// witnesses with metadata in x0, conformance in x1 and borrowed self in x20.
// It then generates both its menu array and index map itself.
typedef uint8_t (*NativeGetter)(const void *, const void *,
    void * __attribute__((swift_context))) __attribute__((swiftcall));
static NativeGetter originals[23];
static atomic_uint_fast64_t calls, filtered;
static atomic_uint_fast64_t requiredServiceKept;
static atomic_uint lastTimelineEvaluated = 255;
// ponytail: the iPhone has one root provider; scope by scene if multi-window roots are introduced.
static atomic_uint effectiveTimeline = 255;
static atomic_uint observedChoices;
static atomic_int status;
enum { ChoiceVOOM=1, ChoiceShopping=2, ChoiceNews=4, ChoiceWallet=8, ChoiceSettings=16 };

static BOOL Enabled(NSString *key) { return [NSUserDefaults.standardUserDefaults boolForKey:key]; }
static uint8_t Result(unsigned slot, uint8_t original, uint8_t result) {
    (void)slot; (void)original;
    if (slot == 0x28) atomic_store(&effectiveTimeline,result);
#if !defined(RUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK)
    if ([NSProcessInfo.processInfo.environment[@"RUIN_ENABLE_RUNTIME_INSPECTOR"] isEqual:@"1"] && atomic_load(&calls) <= 64) {
        static NSMutableArray *trace;
        static NSObject *traceLock; static dispatch_once_t once;
        dispatch_once(&once, ^{ traceLock=[NSObject new]; });
        @synchronized (traceLock) {
            if (!trace) trace=[NSMutableArray array];
            if (trace.count >= 64) return result;
            [trace addObject:@{@"slot":@(slot),@"original":@(original),@"result":@(result),
                @"timelineEvaluated":@(atomic_load(&lastTimelineEvaluated)),
                @"requiredKept":@(atomic_load(&requiredServiceKept)),
                @"hideShopping":@(Enabled(RUINHideShoppingTabDefaultsKey)),
                @"hideNews":@(Enabled(RUINHideNewsCallTabsDefaultsKey)),
                @"hideSettings":@(Enabled(RUINHideSettingsTabDefaultsKey))}];
            NSURL *root=[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL *dir=[root URLByAppendingPathComponent:@"RUIN" isDirectory:YES];
            [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:NULL];
            NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"pid":@(NSProcessInfo.processInfo.processIdentifier),@"calls":trace} options:0 error:NULL];
            [data writeToURL:[dir URLByAppendingPathComponent:@"native-tab-gate-trace.json"] options:NSDataWritingAtomic error:NULL];
        }
    }
#endif
    return result;
}
static uint8_t Original(unsigned slot, const void *metadata, const void *witness, void *context) {
    NativeGetter getter = slot / 8 < 23 ? originals[slot / 8] : NULL;
    return getter ? getter(metadata, witness, context) : 0;
}
static BOOL TimelineRemains(void) {
    unsigned timeline = atomic_load(&effectiveTimeline);
    atomic_store(&lastTimelineEvaluated,timeline);
    return timeline < 4;
}
static uint8_t Filter(unsigned slot, const void *metadata, const void *witness, void *context) {
    atomic_fetch_add(&calls,1);
    uint8_t value = Original(slot, metadata, witness, context);
    if (slot == 0x28 ? (value == 0 || value >= 4) : !value) return Result(slot,value,value);
    unsigned choice = 0;
    NSString *key = nil;
    switch (slot) {
        case 0x28:
            if (value == 1) { choice=ChoiceVOOM; key=RUINHideVOOMTabDefaultsKey; }
            else { choice=ChoiceShopping; key=RUINHideShoppingTabDefaultsKey; }
            break;
        case 0x50:
            if (!Original(0x58,metadata,witness,context)) break;
            choice=ChoiceNews; key=RUINHideNewsCallTabsDefaultsKey; break;
        case 0x70: choice=ChoiceNews; key=RUINHideNewsCallTabsDefaultsKey; break;
        case 0x80: case 0x98: {
            // MoreTab: settings=0, apps=1, wallet=2. Keep the consolidated
            // layout's 0x98 predicate unchanged; that predicate is also used
            // by the native early branch before individual menus are built.
            if (slot == 0x98 && Original(0xa0,metadata,witness,context)) return Result(slot,value,value);
            uint8_t more = Original(0x78,metadata,witness,context);
            if (more == 2) { choice=ChoiceWallet; key=RUINHideWalletTabDefaultsKey; }
            else if (more == 0) { choice=ChoiceSettings; key=RUINHideSettingsTabDefaultsKey; }
            break;
        }
    }
    atomic_fetch_or(&observedChoices,choice);
    BOOL hide = key && Enabled(key);
    if (choice == ChoiceSettings) {
#if !defined(RUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK)
        extern NSDictionary *RUINNativeEntryDiagnostics(void);
        NSDictionary *entry = RUINNativeEntryDiagnostics();
        hide = hide && ([entry[@"homeHookInstalled"] boolValue] || [entry[@"friendHomeHookInstalled"] boolValue]);
#endif
    }
    if (hide && ((slot == 0x28 && !Original(0x80,metadata,witness,context) &&
            !Original(0x98,metadata,witness,context)) ||
            ((slot == 0x80 || slot == 0x98) && !TimelineRemains()))) {
        // The root requires a timeline or more service. NewsRow alone does
        // not satisfy it. Preserve an existing service; never invent a tab.
        atomic_fetch_add(&requiredServiceKept,1);
        return Result(slot,value,value);
    }
    if (hide) { atomic_fetch_add(&filtered,1); return Result(slot,value,slot == 0x28 ? 4 : 0); }
    return Result(slot,value,value);
}
#define GATE(name, offset) \
static uint8_t __attribute__((swiftcall)) name(const void *m, const void *w, \
    void *c __attribute__((swift_context))) { return Filter(offset,m,w,c); }
// Optional<TimelineTab>: 0=square, 1=VOOM, 2=shopping, 3=TW shopping,
// 4=none. The native availableMenus switch explicitly skips case 4.
GATE(GateTimeline,0x28)
GATE(GateCustomizable,0x50)
GATE(GateNewsRow,0x70)
GATE(GateMore,0x80)
GATE(GateFallbackMore,0x98)
#undef GATE

NSArray<NSString *> *RUINObservedNativeTabChoices(void) {
    unsigned choices = atomic_load(&observedChoices);
    NSMutableArray *result = [NSMutableArray array];
    if (choices & ChoiceVOOM) [result addObject:@"voom"];
    if (choices & ChoiceShopping) [result addObject:@"shopping"];
    if (choices & ChoiceNews) [result addObject:@"news"];
    if (choices & ChoiceWallet) [result addObject:@"wallet"];
    if (choices & ChoiceSettings) [result addObject:@"settings"];
    return result;
}

NSDictionary *RUINNativeTabAvailabilityDiagnostics(void) {
    return @{@"status":@(atomic_load(&status)), @"calls":@(atomic_load(&calls)),
        @"filtered":@(atomic_load(&filtered)), @"nativeChoices":RUINObservedNativeTabChoices(),
        @"requiredServiceKept":@(atomic_load(&requiredServiceKept)),
        @"nativeMenuAndIndexGenerationPreserved":@YES, @"customTabViewsAdded":@NO};
}

void RUINInstallNativeTabAvailability(void) {
#if !defined(RUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK)
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        if (![info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier] ||
            ![info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] ||
            ![info[@"CFBundleVersion"] isEqual:RUINTargetBuild]) { atomic_store(&status,1); return; }
        intptr_t slide = _dyld_get_image_vmaddr_slide(0);
        const uint32_t *bridge = (const void *)(slide + 0x100010f38);
        static const uint32_t expectedBridge[] = {0xaa1603e0,0xaa1503e1,0xd61f0100};
        NativeGetter *table = (void *)(slide + 0x10bee1590);
        const uintptr_t expected[] = {0x10072529c,0x100725304,
            0x100725440,0x1007254c8,0x100725520};
        const unsigned slots[] = {0x28,0x50,0x70,0x80,0x98};
        NativeGetter replacements[] = {GateTimeline,GateCustomizable,
            GateNewsRow,GateMore,GateFallbackMore};
        static const int32_t expectedCases[] = {0x24,0x10,0x20,0x18,0x40};
        if (memcmp((const void *)(slide + 0x107d5cf48),expectedCases,sizeof(expectedCases)) ||
            memcmp(bridge,expectedBridge,sizeof(expectedBridge)) ||
            (uintptr_t)table[0] != (uintptr_t)(slide + 0x109670bf0) ||
            (uintptr_t)table[0xb0/8] != (uintptr_t)(slide + 0x100725540)) { atomic_store(&status,2); return; }
        for (unsigned i=0;i<5;i++)
            if ((uintptr_t)table[slots[i]/8] != (uintptr_t)(slide + expected[i])) { atomic_store(&status,2); return; }
        memcpy(originals,table,sizeof(originals));
        vm_address_t page = (vm_address_t)table & ~((vm_address_t)vm_page_size-1);
        vm_address_t region = page; vm_size_t size = 0;
        vm_region_basic_info_data_64_t regionInfo;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t result = vm_region_64(mach_task_self(),&region,&size,VM_REGION_BASIC_INFO_64,
            (vm_region_info_t)&regionInfo,&count,&object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(),object);
        if (result != KERN_SUCCESS || region > page || region+size < page+vm_page_size ||
            vm_protect(mach_task_self(),page,vm_page_size,FALSE,VM_PROT_READ|VM_PROT_WRITE|VM_PROT_COPY) != KERN_SUCCESS) {
            atomic_store(&status,3); return;
        }
        for (unsigned i=0;i<5;i++) __atomic_store_n(&table[slots[i]/8],replacements[i],__ATOMIC_RELEASE);
        if (vm_protect(mach_task_self(),page,vm_page_size,FALSE,regionInfo.protection) != KERN_SUCCESS) {
            for (unsigned i=0;i<5;i++) __atomic_store_n(&table[slots[i]/8],originals[slots[i]/8],__ATOMIC_RELEASE);
            vm_protect(mach_task_self(),page,vm_page_size,FALSE,regionInfo.protection);
            atomic_store(&status,4); return;
        }
        atomic_store(&status,5);
    });
#endif
}

#if defined(RUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK)
#include <assert.h>
#include <stdio.h>
NSString *const RUINHideVOOMTabDefaultsKey=@"RUINInterfaceHideVOOMTab";
NSString *const RUINHideShoppingTabDefaultsKey=@"RUINInterfaceHideShoppingTab";
NSString *const RUINHideNewsCallTabsDefaultsKey=@"RUINInterfaceHideNewsCallTabs";
NSString *const RUINHideWalletTabDefaultsKey=@"RUINInterfaceHideWalletTab";
NSString *const RUINHideSettingsTabDefaultsKey=@"RUINInterfaceHideSettingsTab";
static unsigned originalCalls;
static uint8_t __attribute__((swiftcall)) TestGetter(const void *m,const void *w,
    void *c __attribute__((swift_context))) {
    assert(m==(void *)1 && w==(void *)2); originalCalls++; return *(uint8_t *)c;
}
static uint8_t __attribute__((swiftcall)) TestMore(const void *m,const void *w,
    void *c __attribute__((swift_context))) { (void)m;(void)w;(void)c;return 0; }
static uint8_t __attribute__((swiftcall)) TestShopping(const void *m,const void *w,
    void *c __attribute__((swift_context))) { (void)m;(void)w;(void)c;return 2; }
static uint8_t __attribute__((swiftcall)) TestAvailable(const void *m,const void *w,
    void *c __attribute__((swift_context))) { (void)m;(void)w;(void)c;return 1; }
int main(void) { @autoreleasepool {
    for (unsigned i=0;i<23;i++) originals[i]=TestGetter;
    originals[0x78/8]=TestMore;
    originals[0x80/8]=TestAvailable; originals[0x98/8]=TestAvailable; originals[0xa0/8]=TestAvailable;
    uint8_t yes=1,shopping=2,none=4;
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{} forName:NSArgumentDomain];
    assert(GateTimeline((void *)1,(void *)2,&shopping)==2 && originalCalls==1);
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{RUINHideShoppingTabDefaultsKey:@YES,
        RUINHideNewsCallTabsDefaultsKey:@YES,RUINHideSettingsTabDefaultsKey:@YES} forName:NSArgumentDomain];
    assert(GateTimeline((void *)1,(void *)2,&shopping)==4 && originalCalls==2);
    assert(GateTimeline((void *)1,(void *)2,&none)==4 && originalCalls==3);
    assert(GateNewsRow((void *)1,(void *)2,&yes)==0);
    assert(GateCustomizable((void *)1,(void *)2,&yes)==0);
    assert(GateMore((void *)1,(void *)2,&yes)==1); // Native timeline already returned none.
    assert(GateTimeline((void *)1,(void *)2,&yes)==1);
    assert(GateMore((void *)1,(void *)2,&yes)==0); // An actual native timeline remains.
    assert(GateFallbackMore((void *)1,(void *)2,&yes)==1);
    originals[0x28/8]=TestShopping;
    assert(GateTimeline((void *)1,(void *)2,&shopping)==4);
    assert(GateMore((void *)1,(void *)2,&yes)==1); // Both services requested hidden: retain native more.
    originals[0x80/8]=TestMore; originals[0x98/8]=TestMore;
    assert(GateTimeline((void *)1,(void *)2,&shopping)==2); // No native more: retain native timeline.
    assert(atomic_load(&requiredServiceKept)==3);
    assert([RUINObservedNativeTabChoices() containsObject:@"shopping"]);
    puts("PASS native scalar tab gates preserve original availability and Swift self forwarding");
} return 0; }
#endif
