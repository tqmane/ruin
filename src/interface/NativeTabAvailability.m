#import "NativeTabAvailability.h"
#import "NativeTabMappings.h"
#import "BinaryVerifier.h"
#import "InterfaceFeatures.h"
#import "Features.h"
#import "../core/TargetMetadata.h"
#include <stdatomic.h>
#include <stdint.h>

#if !defined(RUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK)
#import <mach/mach.h>
#import <mach-o/dyld.h>
#endif

// LINE 26.16.0's default availableMenus implementation invokes these scalar
// witnesses with metadata in x0, conformance in x1 and borrowed self in x20.
// It then generates both its menu array and index map itself.
// These are Swift protocol witness slots, not Objective-C methods expressible
// with Logos %hook. This typed adapter stays in RUIN.dylib and only rebinds
// runtime data pointers; it never rewrites the IPA or executable instructions.
typedef uint8_t (*NativeGetter)(const void *, const void *,
    void * __attribute__((swift_context))) __attribute__((swiftcall));
static NativeGetter originals[23];
static atomic_uint_fast64_t calls, filtered;
static atomic_uint_fast64_t requiredServiceKept;
static atomic_uint lastTimelineEvaluated = 255;
// ponytail: the iPhone has one root provider; scope by scene if multi-window roots are introduced.
static atomic_uint effectiveTimeline = 255;
static atomic_uint observedChoices;
static atomic_uint nativeTimeline = 255, nativeMoreKind = 255;
static atomic_bool nativeMoreAvailable, nativeFallbackMoreAvailable;
static atomic_int status;
#if !defined(RUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK)
static uintptr_t menuStartVA, menuEndVA;
#endif
static intptr_t imageSlide;
static const RUINNativeTabRefreshRead *refreshReads;
static size_t refreshReadCount;
static BOOL menuScopeVerified, recoveryMode;
#if defined(RUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK)
static BOOL testMenuCaller = YES;
#endif
enum { ChoiceVOOM=1, ChoiceShopping=2, ChoiceNews=4, ChoiceWallet=8, ChoiceSettings=16, ChoiceApps=32 };
enum { TimelineSquare=0, TimelineVOOM=1, TimelineShopping=2, TimelineTWShopping=3, TimelineNone=4 };

static BOOL Enabled(NSString *key) { return [NSUserDefaults.standardUserDefaults boolForKey:key]; }
static unsigned ChoiceForTimeline(uint8_t value) {
    switch (value) {
        case TimelineVOOM: return ChoiceVOOM;
        case TimelineShopping: case TimelineTWShopping: return ChoiceShopping;
        default: return 0;
    }
}
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
    uint8_t value = getter ? getter(metadata, witness, context) : 0;
    if (getter) {
        if (slot == 0x28) {
            atomic_store(&nativeTimeline,value);
            atomic_store(&lastTimelineEvaluated,value);
        }
        else if (slot == 0x78) atomic_store(&nativeMoreKind,value);
        else if (slot == 0x80) atomic_store(&nativeMoreAvailable,value != 0);
        else if (slot == 0x98) atomic_store(&nativeFallbackMoreAvailable,value != 0);
    }
    return value;
}

BOOL RUINNativeTabCanHideService(NSString *key) {
    if (menuScopeVerified) return YES;
    if ([key isEqual:RUINHideShoppingTabDefaultsKey] || [key isEqual:RUINHideVOOMTabDefaultsKey]) {
        if (!atomic_load(&nativeMoreAvailable) && !atomic_load(&nativeFallbackMoreAvailable)) return NO;
        unsigned more = atomic_load(&nativeMoreKind);
        NSString *peer = more == 0 ? RUINHideSettingsTabDefaultsKey : more == 1 ? RUINHideAppsTabDefaultsKey : more == 2 ? RUINHideWalletTabDefaultsKey : nil;
        // Native apps/consolidated More layouts still supply the required
        // service, even when they have no Settings/Wallet hide switch.
        return !peer || !Enabled(peer);
    }
    if ([key isEqual:RUINHideSettingsTabDefaultsKey] || [key isEqual:RUINHideWalletTabDefaultsKey] || [key isEqual:RUINHideAppsTabDefaultsKey]) {
        unsigned timeline = atomic_load(&nativeTimeline);
        if (timeline >= TimelineNone) return NO;
        unsigned choice = ChoiceForTimeline((uint8_t)timeline);
        NSString *peer = choice == ChoiceShopping ? RUINHideShoppingTabDefaultsKey :
            choice == ChoiceVOOM ? RUINHideVOOMTabDefaultsKey : nil;
        return !peer || !Enabled(peer);
    }
    return YES;
}
static BOOL IsMenuCaller(uintptr_t caller) {
#if defined(RUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK)
    (void)caller;
    return testMenuCaller;
#else
    uintptr_t unslid = caller - (uintptr_t)imageSlide;
    return menuScopeVerified && unslid >= menuStartVA && unslid < menuEndVA;
#endif
}
static BOOL IsVisibilityCaller(unsigned slot, uintptr_t caller) {
    if (IsMenuCaller(caller)) return YES;
    uintptr_t unslid = caller - (uintptr_t)imageSlide;
    for (size_t i = 0; i < refreshReadCount; i++)
        if (refreshReads[i].slot == slot && refreshReads[i].returnVA == unslid) return YES;
    return NO;
}
static uint8_t Filter(unsigned slot, const void *metadata, const void *witness, void *context, uintptr_t caller) {
    atomic_fetch_add(&calls,1);
    uint8_t value = Original(slot, metadata, witness, context);
    // The same getters construct required internal services. Change only the
    // native menu generation/refresh reads; factories and all other consumers retain
    // LINE's actual availability even when every optional tab is hidden.
    if (recoveryMode || !IsVisibilityCaller(slot,caller)) return value;
    if (slot == 0x28 ? (value == TimelineSquare || value >= TimelineNone) : !value)
        return Result(slot,value,value);
    unsigned choice = 0;
    NSString *key = nil;
    switch (slot) {
        case 0x28:
            choice = ChoiceForTimeline(value);
            if (choice == ChoiceVOOM) key = RUINHideVOOMTabDefaultsKey;
            else if (choice == ChoiceShopping) key = RUINHideShoppingTabDefaultsKey;
            break;
        case 0x30: choice=ChoiceVOOM; key=RUINHideVOOMTabDefaultsKey; break;
        case 0x40: case 0x48: choice=ChoiceShopping; key=RUINHideShoppingTabDefaultsKey; break;
        case 0x50:
            if (!Original(0x58,metadata,witness,context)) break;
            choice=ChoiceNews; key=RUINHideNewsCallTabsDefaultsKey; break;
        case 0x70: choice=ChoiceNews; key=RUINHideNewsCallTabsDefaultsKey; break;
        case 0x80: case 0x98: {
            // MoreTab: settings=0, apps=1, wallet=2.
            uint8_t more = Original(0x78,metadata,witness,context);
            if (more == 2) { choice=ChoiceWallet; key=RUINHideWalletTabDefaultsKey; }
            else if (more == 1) { choice=ChoiceApps; key=RUINHideAppsTabDefaultsKey; }
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
        hide = hide && [entry[@"homeEntryAvailable"] boolValue];
#endif
    }
    if (hide) { atomic_fetch_add(&filtered,1); return Result(slot,value,slot == 0x28 ? 4 : 0); }
    return Result(slot,value,value);
}
#define GATE(name, offset) \
static uint8_t __attribute__((swiftcall,noinline,disable_tail_calls)) name(const void *m, const void *w, \
    void *c __attribute__((swift_context))) { return Filter(offset,m,w,c,(uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0))); }
// LINE's TimelineTab cases are squareTab, voom, shopping, twShopping; case 4
// is the native none sentinel and is skipped by availableMenus.
GATE(GateTimeline,0x28)
GATE(GateCustomizable,0x50)
GATE(GateNewsRow,0x70)
GATE(GateMore,0x80)
GATE(GateFallbackMore,0x98)
GATE(GateRefreshVOOM,0x30)
GATE(GateRefreshTWShopping,0x40)
GATE(GateRefreshShopping,0x48)
#undef GATE

#if !defined(RUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK)
static NativeGetter RefreshGate(unsigned slot) {
    switch (slot) {
        case 0x30: return GateRefreshVOOM;
        case 0x40: return GateRefreshTWShopping;
        case 0x48: return GateRefreshShopping;
        case 0x70: return GateNewsRow;
        case 0x50: return GateCustomizable;
        default: return NULL;
    }
}
#endif

NSArray<NSString *> *RUINObservedNativeTabChoices(void) {
    unsigned choices = atomic_load(&observedChoices);
    NSMutableArray *result = [NSMutableArray array];
    if (choices & ChoiceVOOM) [result addObject:@"voom"];
    if (choices & ChoiceShopping) [result addObject:@"shopping"];
    if (choices & ChoiceNews) [result addObject:@"news"];
    if (choices & ChoiceWallet) [result addObject:@"wallet"];
    if (choices & ChoiceSettings) [result addObject:@"settings"];
    if (choices & ChoiceApps) [result addObject:@"apps"];
    return result;
}

NSDictionary *RUINNativeTabAvailabilityDiagnostics(void) {
    return @{@"status":@(atomic_load(&status)), @"calls":@(atomic_load(&calls)),
        @"filtered":@(atomic_load(&filtered)), @"nativeChoices":RUINObservedNativeTabChoices(),
        @"requiredServiceKept":@(atomic_load(&requiredServiceKept)),
        @"nativeTimeline":@(atomic_load(&nativeTimeline)), @"nativeMoreKind":@(atomic_load(&nativeMoreKind)),
        @"nativeMoreAvailable":@(atomic_load(&nativeMoreAvailable) || atomic_load(&nativeFallbackMoreAvailable)),
        @"menuOnlyScopeVerified":@(menuScopeVerified), @"tabFilterRecoveryMode":@(recoveryMode),
        @"nativeRefreshScopeVerified":@(refreshReadCount != 0),
        @"nativeServiceAvailabilityChanged":@NO,
        @"nativeMenuAndIndexGenerationPreserved":@YES, @"customTabViewsAdded":@NO};
}

void RUINInstallNativeTabAvailability(void) {
#if !defined(RUIN_NATIVE_TAB_AVAILABILITY_HOST_CHECK)
    const RUINVersionMapping *versionMapping = RUINCurrentMapping();
    if (!versionMapping) { atomic_store(&status,1); return; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const RUINNativeTabMapping *mapping = &versionMapping->nativeTabs;
        if (mapping->status != RUINMappingStatusVerified) { atomic_store(&status,1); return; }
        intptr_t slide = _dyld_get_image_vmaddr_slide(0);
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(0);
        RUINInstructionAnchor bridge = {mapping->bridgeVA,3,{0}};
        memcpy(bridge.words,mapping->bridgeWords,sizeof(mapping->bridgeWords));
        int32_t cases[5];
        NativeGetter snapshot[23];
        if (!RUINVerifyInstructions(header,slide,&bridge,1) ||
            !RUINVerifyInstructions(header,slide,&mapping->menuGenerator,1) ||
            mapping->menuGeneratorEndVA <= mapping->menuGenerator.address ||
            !RUINReadImageBytes(header,slide,mapping->caseTableVA,cases,sizeof(cases),"__TEXT") ||
            memcmp(cases,mapping->caseWords,sizeof(cases)) ||
            !RUINReadImageBytes(header,slide,mapping->witnessTableVA,snapshot,sizeof(snapshot),"__DATA_CONST") ||
            (uintptr_t)snapshot[0] != (uintptr_t)(slide + mapping->firstWitnessVA) ||
            (uintptr_t)snapshot[0xb0/8] != (uintptr_t)(slide + mapping->lastWitnessVA)) { atomic_store(&status,2); return; }
        NativeGetter replacements[] = {GateTimeline,GateCustomizable,GateNewsRow,GateMore,GateFallbackMore};
        for (unsigned i=0;i<5;i++)
            if (mapping->slots[i]/8 >= 23 ||
                (uintptr_t)snapshot[mapping->slots[i]/8] != (uintptr_t)(slide + mapping->getters[i])) { atomic_store(&status,2); return; }
        const size_t refreshCount = sizeof(mapping->refreshReads)/sizeof(mapping->refreshReads[0]);
        for (size_t i=0;i<refreshCount;i++) {
            const RUINNativeTabRefreshRead *read = &mapping->refreshReads[i];
            uint32_t actual[5];
            if (!RefreshGate(read->slot) || read->slot/8 >= 23 || read->returnVA < sizeof(actual) ||
                (uintptr_t)snapshot[read->slot/8] != (uintptr_t)(slide + read->getterVA) ||
                !RUINReadImageBytes(header,slide,read->returnVA-sizeof(actual),actual,sizeof(actual),"__TEXT") ||
                memcmp(actual,read->callWords,sizeof(actual))) { atomic_store(&status,2); return; }
            if (read->slot == 0x50) {
                // This reader tail-calls a Swift ABI bridge rather than BLR.
                // Derive the bridge from the verified BL, then validate its
                // argument forwarding before binding the witness.
                int64_t delta = actual[4] & 0x03ffffff;
                if (delta & 0x02000000) delta -= 0x04000000;
                RUINInstructionAnchor thunk = {(uintptr_t)((int64_t)read->returnVA-4+delta*4),4,
                    {0xaa0003f4,0xaa1503e0,0xaa1603e1,0xd61f0100}};
                if ((actual[4] & 0xfc000000) != 0x94000000 ||
                    !RUINVerifyInstructions(header,slide,&thunk,1)) { atomic_store(&status,2); return; }
            }
        }
        memcpy(originals,snapshot,sizeof(originals));
        NativeGetter *table = (void *)(slide + mapping->witnessTableVA);
        vm_address_t page = (vm_address_t)table & ~((vm_address_t)vm_page_size-1);
        if ((uintptr_t)table - page > vm_page_size - sizeof(originals)) { atomic_store(&status,3); return; }
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
        for (unsigned i=0;i<5;i++) __atomic_store_n(&table[mapping->slots[i]/8],replacements[i],__ATOMIC_RELEASE);
        for (size_t i=0;i<refreshCount;i++) __atomic_store_n(&table[mapping->refreshReads[i].slot/8],
            RefreshGate(mapping->refreshReads[i].slot),__ATOMIC_RELEASE);
        if (vm_protect(mach_task_self(),page,vm_page_size,FALSE,regionInfo.protection) != KERN_SUCCESS) {
            for (unsigned i=0;i<5;i++) __atomic_store_n(&table[mapping->slots[i]/8],originals[mapping->slots[i]/8],__ATOMIC_RELEASE);
            for (size_t i=0;i<refreshCount;i++) __atomic_store_n(&table[mapping->refreshReads[i].slot/8],
                originals[mapping->refreshReads[i].slot/8],__ATOMIC_RELEASE);
            vm_protect(mach_task_self(),page,vm_page_size,FALSE,regionInfo.protection);
            atomic_store(&status,4); return;
        }
        imageSlide = slide;
        menuStartVA = mapping->menuGenerator.address;
        menuEndVA = mapping->menuGeneratorEndVA;
        refreshReads = mapping->refreshReads;
        refreshReadCount = refreshCount;
        recoveryMode = [NSProcessInfo.processInfo.environment[@"RUIN_DISABLE_TAB_HIDING"] isEqual:@"1"];
        menuScopeVerified = YES;
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
NSString *const RUINHideAppsTabDefaultsKey=@"RUINInterfaceHideAppsTab";
static unsigned originalCalls;
static uint8_t __attribute__((swiftcall)) TestGetter(const void *m,const void *w,
    void *c __attribute__((swift_context))) {
    assert(m==(void *)1 && w==(void *)2); originalCalls++; return *(uint8_t *)c;
}
static uint8_t __attribute__((swiftcall)) TestMore(const void *m,const void *w,
    void *c __attribute__((swift_context))) { (void)m;(void)w;(void)c;return 0; }
static uint8_t __attribute__((swiftcall)) TestAvailable(const void *m,const void *w,
    void *c __attribute__((swift_context))) { (void)m;(void)w;(void)c;return 1; }
int main(void) { @autoreleasepool {
    for (unsigned i=0;i<23;i++) originals[i]=TestGetter;
    originals[0x78/8]=TestMore;
    originals[0x80/8]=TestAvailable; originals[0x98/8]=TestAvailable; originals[0xa0/8]=TestAvailable;
    uint8_t yes=1,square=TimelineSquare,shopping=TimelineShopping,
        twShopping=TimelineTWShopping,none=TimelineNone;
    menuScopeVerified = YES;
    [NSUserDefaults.standardUserDefaults setVolatileDomain:@{
        RUINHideShoppingTabDefaultsKey:@YES, RUINHideAppsTabDefaultsKey:@YES, RUINHideVOOMTabDefaultsKey:@YES,
        RUINHideNewsCallTabsDefaultsKey:@YES, RUINHideSettingsTabDefaultsKey:@YES} forName:NSArgumentDomain];
    // Factories retain actual services while the menu hides both optional slots.
    originals[0x78/8]=TestAvailable;
    testMenuCaller = NO;
    assert(GateTimeline((void *)1,(void *)2,&shopping)==TimelineShopping);
    assert(GateMore((void *)1,(void *)2,&yes)==1);
    assert(GateNewsRow((void *)1,(void *)2,&yes)==1);
    const RUINNativeTabRefreshRead refresh[] = {
        {.slot=0x30,.returnVA=0x1234}, {.slot=0x40,.returnVA=0x1238},
        {.slot=0x48,.returnVA=0x123c}, {.slot=0x70,.returnVA=0x1240}, {.slot=0x50,.returnVA=0x1244}};
    refreshReads = refresh; refreshReadCount = sizeof(refresh)/sizeof(refresh[0]);
    for (size_t i=0;i<refreshReadCount;i++) {
        assert(Filter(refresh[i].slot,(void *)1,(void *)2,&yes,refresh[i].returnVA)==0);
        assert(Filter(refresh[i].slot,(void *)1,(void *)2,&yes,refresh[i].returnVA+0x100)==1);
    }
    assert(Filter(0x30,(void *)1,(void *)2,&yes,0x123c)==1);
    assert(Filter(0x28,(void *)1,(void *)2,&shopping,0x123c)==TimelineShopping);
    assert(GateRefreshShopping((void *)1,(void *)2,&yes)==1);
    assert(GateRefreshTWShopping((void *)1,(void *)2,&yes)==1);
    assert(GateRefreshVOOM((void *)1,(void *)2,&yes)==1);
    testMenuCaller = YES;
    assert(GateTimeline((void *)1,(void *)2,&shopping)==TimelineNone);
    assert(GateTimeline((void *)1,(void *)2,&twShopping)==TimelineNone);
    assert(GateTimeline((void *)1,(void *)2,&square)==TimelineSquare);
    assert(GateTimeline((void *)1,(void *)2,&none)==TimelineNone);
    assert(GateMore((void *)1,(void *)2,&yes)==0);
    assert(GateFallbackMore((void *)1,(void *)2,&yes)==0);
    assert(GateNewsRow((void *)1,(void *)2,&yes)==0);
    assert(GateCustomizable((void *)1,(void *)2,&yes)==0);
    assert(RUINNativeTabCanHideService(RUINHideShoppingTabDefaultsKey));
    assert(RUINNativeTabCanHideService(RUINHideAppsTabDefaultsKey));
    recoveryMode = YES;
    assert(GateTimeline((void *)1,(void *)2,&shopping)==TimelineShopping);
    assert(GateMore((void *)1,(void *)2,&yes)==1);
    recoveryMode = NO;
    assert([RUINObservedNativeTabChoices() containsObject:@"shopping"]);
    assert([RUINObservedNativeTabChoices() containsObject:@"apps"]);
    puts("PASS native scalar tab gates preserve original availability and Swift self forwarding");
} return 0; }
#endif
