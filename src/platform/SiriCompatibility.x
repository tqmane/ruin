%config(generator=internal);

#import "SiriCompatibility.h"
#import "../core/TargetMetadata.h"
#import "../known/FeatureImage.h"
#import <Intents/INVocabulary.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct __SecTask *RUINSiriTaskRef;
extern RUINSiriTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator) __attribute__((weak_import));
extern CFTypeRef SecTaskCopyValueForEntitlement(RUINSiriTaskRef task, CFStringRef entitlement,
    CFErrorRef *error) __attribute__((weak_import));

// -1 is unreadable, 0 is confirmed absent/false, 1 is the real Boolean grant.
static int RUINSiriEntitlement(void) {
    if (!SecTaskCreateFromSelf || !SecTaskCopyValueForEntitlement) return -1;
    RUINSiriTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return -1;
    CFErrorRef error = NULL;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.developer.siri"), &error);
    CFRelease(task);
    int result = -1;
    if (!error) {
        if (!value) result = 0;
        else if (CFGetTypeID(value) == CFBooleanGetTypeID())
            result = CFBooleanGetValue(value) ? 1 : 0;
    }
    if (value) CFRelease(value);
    if (error) CFRelease(error);
    return result;
}

static RUINFeatureImage sSiriImage; // Keep the LC loader reference for hook lifetime.
static Class sVocabularyClass;
static atomic_bool sInstalled;
static atomic_int sEntitlement = ATOMIC_VAR_INIT(-1);
static _Atomic(const char *) sStatus = "not_attempted";
static atomic_uint_fast64_t sSkipped, sForwarded;

%group RUINSiriVocabulary
%hook INVocabulary
+ (instancetype)sharedVocabulary {
    Dl_info caller = {0};
    if (self == sVocabularyClass &&
        dladdr(__builtin_return_address(0), &caller) && caller.dli_fbase == sSiriImage.image.header) {
        atomic_fetch_add(&sSkipped, 1);
        return nil;
    }
    atomic_fetch_add(&sForwarded, 1);
    return %orig;
}
%end
%end

void RUINInstallSiriCompatibility(void) {
    @synchronized (NSProcessInfo.processInfo) {
        if (atomic_load(&sInstalled)) return;
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        if (!RUINTargetMetadataMatchesInfo(info)) {
            atomic_store(&sStatus, "wrong_target"); return;
        }
        int entitlement = RUINSiriEntitlement();
        atomic_store(&sEntitlement, entitlement);
        if (entitlement != 0) {
            atomic_store(&sStatus, entitlement == 1 ? "native_entitled" : "entitlement_unreadable"); return;
        }

        // Nil is NOT a general INVocabulary contract. This exact executable has
        // only two factory call sites (+0x1fb9f0 / +0x1fc2dc): the results stay
        // in x24 / x26 and are used only by setVocabularyStrings:ofType: and
        // objc retain/release. No Swift unwrap, object load, or escaping result.
        // check_siri_compatibility.py --binary rechecks that disassembly proof.
        // The ObjC syncContactNames/syncContactGroupNames wrappers are not a
        // shared root: native Swift callers also schedule the same work directly.
        const RUINVersionMapping *mapping = RUINMappingForInfo(info);
        if (!mapping || strcmp(mapping->host.uuid, "614CED59-07E5-372D-94B2-D4901870C7A0")) {
            atomic_store(&sStatus, "nil_safety_unproven"); return;
        }
        Class owner = objc_getClass("_TtC4LINE32NLIntentVocabularyControllerObjC");
        RUINFeatureImage image = {0};
        if (!owner || !RUINResolveFeatureImage(&mapping->host, owner, &image)) {
            atomic_store(&sStatus, "owner_image_unavailable"); return;
        }
        Class vocabulary = objc_getClass("INVocabulary");
        Method factory = NULL;
        unsigned count = 0;
        Method *methods = class_copyMethodList(object_getClass(vocabulary), &count);
        for (unsigned i = 0; i < count; i++) {
            if (method_getName(methods[i]) == @selector(sharedVocabulary)) { factory = methods[i]; break; }
        }
        free(methods);
        if (!factory || strcmp(method_getTypeEncoding(factory), "@16@0:8") ||
            !method_getImplementation(factory)) {
            RUINReleaseFeatureImage(&image);
            atomic_store(&sStatus, "factory_abi_unavailable"); return;
        }
        sSiriImage = image;
        sVocabularyClass = vocabulary;
        %init(RUINSiriVocabulary);
        atomic_store(&sInstalled, true);
        atomic_store(&sStatus, "installed");
    }
}

NSDictionary<NSString *, id> *RUINSiriCompatibilityDiagnostics(void) {
    return @{@"status":@(atomic_load(&sStatus)), @"installed":@(atomic_load(&sInstalled)),
        @"processSiriEntitlement":@(atomic_load(&sEntitlement)),
        @"skippedVocabularyFactories":@(atomic_load(&sSkipped)),
        @"forwardedVocabularyFactories":@(atomic_load(&sForwarded))};
}
