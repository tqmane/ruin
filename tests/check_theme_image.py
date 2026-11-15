#!/usr/bin/env python3
"""Exercise the production theme image bridge with real image/anchor verification."""
from pathlib import Path
import json
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

PREAMBLE = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/dyld_images.h>
#import <mach/mach.h>
#import "FeatureImage.h"
#import "VersionMapping.h"
#include <assert.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

@interface _TtC4LINE11AppDelegate : NSObject @end
@implementation _TtC4LINE11AppDelegate @end

typedef struct {
    struct mach_header_64 header;
    struct uuid_command uuid;
    struct { struct dylib_command command; char name[8]; } identifier;
    struct segment_command_64 text;
    uint32_t words[4];
    char shopURL[sizeof("line://shop/theme")];
    char validationLog[sizeof("validateTheme result:")];
} TestImage;
static TestImage lineImage, containerImage;
static const uintptr_t baseAddress = 0x100000000;
static char linePath[PATH_MAX], containerPath[PATH_MAX], aliasPath[PATH_MAX];
static const char *processPath, *ownerPath;
static NSDictionary *bundleInfo;
static RUINVersionMapping fixtureVersion;
static RUINInstructionAnchor anchors[4];
static BOOL nativeProcess, missingOwner, pinAllowed = YES;
static unsigned opens, closes, pins, hooks, featureRefreshes, guestResolves;
static NSMutableArray<void (^)(void)> *pending;

@interface ThemeFixtureBundle : NSObject
+ (instancetype)mainBundle;
@property(readonly) NSDictionary *infoDictionary;
@property(readonly) NSString *executablePath;
@end
@implementation ThemeFixtureBundle
+ (instancetype)mainBundle { static ThemeFixtureBundle *bundle;
    if (!bundle) bundle = [ThemeFixtureBundle new]; return bundle; }
- (NSDictionary *)infoDictionary { return bundleInfo; }
- (NSString *)executablePath { return @(linePath); }
@end

static intptr_t Slide(TestImage *image) { return (intptr_t)((uintptr_t)image - baseAddress); }
static uint32_t FixtureImageCount(void) { return 2; }
static const struct mach_header *FixtureHeader(uint32_t index) {
    return index < 2 ? (const void *)(index ? &containerImage.header : &lineImage.header) : NULL;
}
static intptr_t FixtureSlide(uint32_t index) { return Slide(index ? &containerImage : &lineImage); }
static const char *FixtureName(uint32_t index) { return index < 2 ? (index ? containerPath : linePath) : NULL; }
static const char *FixtureClassImage(Class cls) {
    return !missingOwner && cls == _TtC4LINE11AppDelegate.class ? ownerPath : NULL;
}
static void FixtureObserve(void (*callback)(const struct mach_header *, intptr_t)) { (void)callback; }
static int FixtureExecutablePath(char *buffer, uint32_t *size) {
    uint32_t required = (uint32_t)strlen(processPath) + 1;
    if (!buffer || *size < required) { *size = required; return -1; }
    memcpy(buffer, processPath, required); return 0;
}
static BOOL FixtureMain(RUINMainExecutableImage *image) {
    RUINDyldImageCandidate candidates[] = {
        {&lineImage.header, Slide(&lineImage), linePath},
        {&containerImage.header, Slide(&containerImage), containerPath}
    };
    // The strict resolver can see LC's rewritten MH_EXECUTE as the main image.
    // Kernel lifetime and conversion proof must still distinguish that case.
    return RUINResolveMainExecutableImageFromCandidates(processPath, candidates, 2, image);
}
static kern_return_t FixtureTaskInfo(task_name_t task, task_flavor_t flavor,
    task_info_t output, mach_msg_type_number_t *count) {
    (void)task;
    assert(flavor == TASK_DYLD_INFO && *count >= TASK_DYLD_INFO_COUNT);
    static struct dyld_image_info first;
    static struct { uint32_t version, count; const struct dyld_image_info *images; } list;
    first.imageLoadAddress = (const void *)(nativeProcess ? &lineImage.header : &containerImage.header);
    list.version = 15; list.count = 1; list.images = &first;
    task_dyld_info_data_t result = {.all_image_info_addr=(mach_vm_address_t)&list,
        .all_image_info_size=sizeof(list), .all_image_info_format=TASK_DYLD_ALL_IMAGE_INFO_64};
    memcpy(output, &result, sizeof(result)); *count = TASK_DYLD_INFO_COUNT;
    return KERN_SUCCESS;
}
static void *FixtureOpen(const char *path, int mode) {
    assert(!strcmp(path, linePath) && (mode & RTLD_NOLOAD)); opens++;
    if (!pinAllowed) return NULL;
    void *reference = dlopen(NULL, RTLD_LAZY); assert(reference); pins++; return reference;
}
static int FixtureClose(void *reference) { assert(reference && pins); closes++; pins--; return dlclose(reference); }

// Only environment inputs are substituted. The production native helper,
// converted-image resolver, memory reader and fingerprint verifier run below.
#define NSBundle ThemeFixtureBundle
#define RUINResolveMainExecutableImage FixtureMain
#define _NSGetExecutablePath FixtureExecutablePath
#define task_info FixtureTaskInfo
#define _dyld_image_count FixtureImageCount
#define _dyld_get_image_header FixtureHeader
#define _dyld_get_image_vmaddr_slide FixtureSlide
#define _dyld_get_image_name FixtureName
#define _dyld_register_func_for_add_image FixtureObserve
#define _dyld_register_func_for_remove_image FixtureObserve
#define class_getImageName FixtureClassImage
#define dlopen FixtureOpen
#define dlclose FixtureClose
'''

BRIDGE_SEAMS = r'''
#undef NSBundle
#undef RUINResolveMainExecutableImage
#undef _NSGetExecutablePath
#undef task_info
#undef _dyld_image_count
#undef _dyld_get_image_header
#undef _dyld_get_image_vmaddr_slide
#undef _dyld_get_image_name
#undef _dyld_register_func_for_add_image
#undef _dyld_register_func_for_remove_image
#undef class_getImageName
#undef dlopen
#undef dlclose

static const RUINVersionMapping *FixtureMapping(NSDictionary *info) {
    const RUINVersionMapping *actual = RUINMappingForInfo(info);
    return actual && !strcmp(actual->host.uuid, fixtureVersion.host.uuid) ? &fixtureVersion : NULL;
}
static const RUINVersionMapping *FixtureCurrentMapping(void) {
    const RUINVersionMapping *mapping = FixtureMapping(bundleInfo);
    RUINMainExecutableImage image;
    return mapping && FixtureMain(&image) && RUINVerifyHostImage(&mapping->host, image.header) ? mapping : NULL;
}
static BOOL FixtureResolveFeature(const RUINHostIdentity *host, Class owner, RUINFeatureImage *image) {
    guestResolves++;
    return RUINResolveFeatureImage(host, owner, image);
}
static void FixtureDispatchAsync(dispatch_queue_t queue, void (^block)(void)) {
    assert(queue == dispatch_get_main_queue());
    if (!pending) pending = [NSMutableArray array];
    [pending addObject:[block copy]];
}
static void Drain(void) {
    for (unsigned budget = 0; pending.count; budget++) {
        assert(budget < 16);
        NSArray<void (^)(void)> *blocks = [pending copy]; [pending removeAllObjects];
        for (void (^block)(void) in blocks) block();
    }
}
static void FixtureInstallDefaults(Class cls) { assert(cls); hooks++; }
void RUINInstallThemeFeatures(void) { featureRefreshes++; }

#define NSBundle ThemeFixtureBundle
#define RUINMappingForInfo FixtureMapping
#define RUINCurrentMapping FixtureCurrentMapping
#define RUINResolveMainExecutableImage FixtureMain
#define RUINResolveFeatureImage FixtureResolveFeature
#define dispatch_async FixtureDispatchAsync
'''

CHECK = r'''
#undef NSBundle
#undef RUINMappingForInfo
#undef RUINCurrentMapping
#undef RUINResolveMainExecutableImage
#undef RUINResolveFeatureImage
#undef dispatch_async

static void MakeImage(TestImage *image, BOOL converted, BOOL rewritten) {
    memset(image, 0, sizeof(*image));
    image->header = (struct mach_header_64){.magic=MH_MAGIC_64, .cputype=CPU_TYPE_ARM64,
        .cpusubtype=CPU_SUBTYPE_ARM64_ALL, .filetype=converted && !rewritten ? MH_DYLIB : MH_EXECUTE,
        .ncmds=3, .sizeofcmds=offsetof(TestImage, words)-sizeof(image->header),
        .flags=converted ? MH_NO_REEXPORTED_DYLIBS : MH_PIE};
    image->uuid = (struct uuid_command){.cmd=LC_UUID, .cmdsize=sizeof(image->uuid)};
    [[[NSUUID alloc] initWithUUIDString:@(fixtureVersion.host.uuid)] getUUIDBytes:image->uuid.uuid];
    image->identifier.command = (struct dylib_command){.cmd=converted ? LC_ID_DYLIB : LC_LOAD_DYLIB,
        .cmdsize=sizeof(image->identifier), .dylib.name.offset=sizeof(struct dylib_command)};
    strcpy(image->identifier.name, "LINE");
    image->text = (struct segment_command_64){.cmd=LC_SEGMENT_64, .cmdsize=sizeof(image->text),
        .vmaddr=baseAddress, .vmsize=sizeof(*image), .initprot=VM_PROT_READ};
    strcpy(image->text.segname, "__TEXT");
    for (size_t index = 0; index < 4; index++) image->words[index] = 0xd503201f + (uint32_t)index;
    strcpy(image->shopURL, "line://shop/theme");
    strcpy(image->validationLog, "validateTheme result:");
}
static void ConfigureMapping(void) {
    const RUINVersionMapping *registered = RUINMappingForInfo(bundleInfo); assert(registered);
    fixtureVersion = *registered;
    for (size_t index = 0; index < 4; index++) anchors[index] = (RUINInstructionAnchor){
        .address=baseAddress+offsetof(TestImage, words)+index*sizeof(uint32_t),
        .wordCount=1, .words={0xd503201f+(uint32_t)index}};
    fixtureVersion.themes.shopNavigation = (RUINThemeShopNavigationMapping){
        .status=RUINMappingStatusVerified, .themeURLString=baseAddress+offsetof(TestImage, shopURL),
        .anchors=&anchors[0], .anchorCount=1};
    fixtureVersion.themes.shopEligibility = (RUINThemeShopEligibilityMapping){
        .nativeReadAdapterStatus=RUINMappingStatusVerified, .anchors=&anchors[1], .anchorCount=1};
    fixtureVersion.themes.validation = (RUINThemeValidationMapping){
        .status=RUINMappingStatusVerified, .anchors=&anchors[2], .anchorCount=1,
        .resultLogString=baseAddress+offsetof(TestImage, validationLog)};
    fixtureVersion.themes.localPolicy = (RUINThemeLocalPolicyMapping){
        .status=RUINMappingStatusVerified, .anchors=&anchors[3], .anchorCount=1};
}
static void CheckBorrowedImage(BOOL converted) {
    RUINFeatureImage borrowed;
    assert(RUINCopyVerifiedThemeImage(&borrowed) == &fixtureVersion);
    assert(borrowed.image.header == &lineImage.header && borrowed.image.slide == Slide(&lineImage));
    assert(borrowed.convertedExecutable == converted && !borrowed.loaderReference);
    assert(RUINFeatureImageMatches(&borrowed, &fixtureVersion.host));
    assert(RUINVerifyFeatureInstructions(&borrowed, fixtureVersion.themes.validation.anchors, 1));
    assert(RUINVerifyFeatureInstructions(&borrowed, fixtureVersion.themes.localPolicy.anchors, 1));
    char log[sizeof("validateTheme result:")];
    assert(RUINReadFeatureImageBytes(&borrowed, fixtureVersion.themes.validation.resultLogString,
        log, sizeof(log), "__TEXT") && !strcmp(log, "validateTheme result:"));
    lineImage.words[2]++;
    assert(!RUINVerifyFeatureInstructions(&borrowed, fixtureVersion.themes.validation.anchors, 1));
    lineImage.words[2]--;
    unsigned before = closes;
    RUINReleaseFeatureImage(&borrowed); assert(closes == before); // The shared owner retains its pin.
}
static void CheckRejectedAttempt(void) {
    unsigned before = hooks;
    RUINInstallThemePersistenceAdapter(); Drain();
    assert(!atomic_load(&gThemeShopImageReady) && !gThemeShopImageVersion && !pins);
    assert(!atomic_load(&gThemeShopGateReady) && hooks == before);
    RUINFeatureImage borrowed;
    // A native identity can still be copied independently of shop fingerprints.
    if (!nativeProcess) assert(!RUINCopyVerifiedThemeImage(&borrowed) && !borrowed.image.header);
}
int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2); NSString *scenario = @(argv[1]);
    nativeProcess = [scenario hasPrefix:@"native"] || [scenario isEqual:@"renamed-native"];
    BOOL rewritten = [scenario isEqual:@"lc-rewritten"];
    char directory[] = "/tmp/ruin-theme-image.XXXXXX"; assert(mkdtemp(directory));
    snprintf(linePath, sizeof(linePath), "%s/LINE", directory);
    snprintf(containerPath, sizeof(containerPath), "%s/Container", directory);
    snprintf(aliasPath, sizeof(aliasPath), "%s/current", directory);
    int fd = open(linePath, O_CREAT|O_WRONLY, 0600); assert(fd >= 0); close(fd);
    fd = open(containerPath, O_CREAT|O_WRONLY, 0600); assert(fd >= 0); close(fd);
    assert(!symlink(linePath, aliasPath)); ownerPath = aliasPath;
    processPath = nativeProcess || rewritten ? aliasPath : containerPath;
    bundleInfo = @{@"CFBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.17.0",
        @"CFBundleVersion":@"2026.1103.1841"};
    if ([scenario isEqual:@"renamed-native"]) bundleInfo = @{@"CFBundleIdentifier":@"fixture.renamed.line",
        @"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.17.0",
        @"CFBundleVersion":@"2026.1103.1841"};
    ConfigureMapping(); MakeImage(&lineImage, !nativeProcess, rewritten); MakeImage(&containerImage, NO, NO);
    containerImage.uuid.uuid[0]++; // The container's main image is never a LINE identity.
    if (rewritten) assert(FixtureCurrentMapping() == &fixtureVersion);

    // A route before any verified mapping must not permanently consume installation.
    if (![scenario hasSuffix:@"eligibility-retry"]) {
        RUINThemeShopInstallGate(); assert(!atomic_load(&gThemeShopGateReady) && !hooks);
    }
    if ([scenario isEqual:@"lc-owner-retry"]) {
        ownerPath = containerPath; CheckRejectedAttempt(); ownerPath = aliasPath;
    } else if ([scenario isEqual:@"lc-uuid-retry"]) {
        lineImage.uuid.uuid[0]++; CheckRejectedAttempt(); lineImage.uuid.uuid[0]--;
    } else if ([scenario hasSuffix:@"fingerprint-retry"]) {
        lineImage.words[0]++; CheckRejectedAttempt(); lineImage.words[0]--;
    } else if ([scenario hasSuffix:@"url-retry"]) {
        lineImage.shopURL[0]++; CheckRejectedAttempt(); lineImage.shopURL[0]--;
    } else if ([scenario isEqual:@"lc-pin-retry"]) {
        pinAllowed = NO; CheckRejectedAttempt(); pinAllowed = YES;
    } else if ([scenario hasSuffix:@"eligibility-retry"]) {
        lineImage.words[1]++;
        RUINInstallThemePersistenceAdapter(); Drain();
        assert(!atomic_load(&gThemeShopGateReady) && !hooks && atomic_load(&gThemeShopGateStatus) == 1);
        lineImage.words[1]--;
    }

    unsigned beforeOpens = opens, beforeResolves = guestResolves;
    BOOL previouslyPublished = atomic_load(&gThemeShopImageReady);
    RUINInstallThemePersistenceAdapter();
    if (!nativeProcess && !previouslyPublished) {
        assert(!atomic_load(&gThemeShopImageReady) && opens == beforeOpens &&
            guestResolves == beforeResolves && pending.count == 1);
    }
    Drain();
    assert(gThemeShopMappings == &fixtureVersion.themes && atomic_load(&gThemeShopGateReady) && hooks == 1);
    assert(RUINThemeShopVerifyEligibility(&fixtureVersion.themes));
    assert(gThemeShopSlide == Slide(&lineImage));
    if (nativeProcess) {
        assert(!gThemeShopImageVersion && !atomic_load(&gThemeShopImageReady));
        assert(!opens && !pins && !featureRefreshes && !guestResolves);
        // Native anchor/URL failures never fall through into guest resolution.
    } else {
        assert(gThemeShopImageVersion == &fixtureVersion && atomic_load(&gThemeShopImageReady));
        assert(gThemeShopImage.convertedExecutable && gThemeShopImage.loaderReference && pins == 1);
        assert(featureRefreshes == 1);
    }
    CheckBorrowedImage(!nativeProcess);
    unsigned successfulOpens = opens, successfulCloses = closes, successfulResolves = guestResolves;
    void *pin = gThemeShopImage.loaderReference;
    for (unsigned index = 0; index < 5; index++) {
        RUINInstallThemePersistenceAdapter(); Drain(); CheckBorrowedImage(!nativeProcess);
    }
    assert(opens == successfulOpens && closes == successfulCloses && guestResolves == successfulResolves && hooks == 1);
    assert(gThemeShopImage.loaderReference == pin);

    NSDictionary *savedInfo = bundleInfo;
    bundleInfo = @{@"CFBundleIdentifier":@"fixture.unrelated", @"CFBundleShortVersionString":@"26.17.0",
        @"CFBundleVersion":@"2026.1103.1841"};
    RUINFeatureImage borrowed; assert(!RUINCopyVerifiedThemeImage(&borrowed));
    bundleInfo = savedInfo;
    lineImage.uuid.uuid[0]++; assert(!RUINCopyVerifiedThemeImage(&borrowed)); lineImage.uuid.uuid[0]--;
    CheckBorrowedImage(!nativeProcess);
    RUINReleaseFeatureImage(&gThemeShopImage); assert(!pins);
    unlink(aliasPath); unlink(linePath); unlink(containerPath); rmdir(directory);
    printf("PASS production theme image bridge: %s\n", argv[1]);
} return 0; }
'''


def extract(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


def main() -> None:
    source = (ROOT / "src/themes/ThemeShop.x").read_text()
    declarations = "\n".join(
        line for line in source.splitlines()
        if line.startswith((
            "static NSString * const RUINThemeShopURLString =",
            "static const char * const RUINThemeShopDelegateClass =",
            "static const RUINThemeMappings *gThemeShopMappings;",
            "static atomic_bool gThemeShopGateReady;",
            "static atomic_int gThemeShopGateStatus;",
            "static intptr_t gThemeShopSlide;",
            "static RUINFeatureImage gThemeShopImage;",
            "static const RUINVersionMapping *gThemeShopImageVersion;",
            "static atomic_bool gThemeShopImageReady;",
        ))
    ) + "\n"
    mapping = extract(source, "static const RUINThemeMappings *RUINThemeShopMappingForInfo(",
                      "#if !defined(RUIN_THEMESHOP_HOST_CHECK)\nstatic void RUINThemeShopInstallGate(")
    gate = extract(source, "#if !defined(RUIN_THEMESHOP_HOST_CHECK)\nstatic void RUINThemeShopInstallGate(",
                   "#if !defined(RUIN_THEMESHOP_HOST_CHECK)\nstatic NSNumber *gThemeShopUnscopedPrimaryBefore;")
    hook = "%init(RUINThemeDefaults, RUINThemeDefaultsStore=cls);"
    assert gate.count(hook) == 1
    gate = gate.replace(hook, "FixtureInstallDefaults(cls);")
    bridge = extract(source, "#if !defined(RUIN_THEMESHOP_HOST_CHECK)\nstatic void RUINInstallThemePersistenceOnMain(",
                     "NSDictionary *RUINThemePersistenceDiagnostics(")
    scenarios = (
        "native", "renamed-native", "native-fingerprint-retry", "native-url-retry", "native-eligibility-retry",
        "lc-dylib", "lc-rewritten", "lc-owner-retry", "lc-uuid-retry",
        "lc-fingerprint-retry", "lc-url-retry", "lc-pin-retry", "lc-eligibility-retry",
    )
    with tempfile.TemporaryDirectory(prefix="ruin-theme-image-") as temporary:
        directory = Path(temporary)
        fixture = directory / "check.m"
        feature = ROOT / "src/known/FeatureImage.m"
        fixture.write_text(PREAMBLE + f"\n#include {json.dumps(str(feature))}\n" +
                           BRIDGE_SEAMS + declarations + mapping + gate + bridge + CHECK)
        executable = directory / "check"
        sources = [ROOT / "src/known" / name for name in ("BinaryVerifier.m", "KnownMappings.m")]
        sources += sorted((ROOT / "src/known/versions").glob("*.m"))
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11",
                        "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "src/known"),
                        str(fixture), *map(str, sources), "-framework", "Foundation", "-o", str(executable)],
                       check=True)
        for scenario in scenarios:
            subprocess.run([str(executable), scenario], check=True)


if __name__ == "__main__":
    main()
