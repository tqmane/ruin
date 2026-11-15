#import "FeatureImage.h"
#import "VersionMapping.h"
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/dyld_images.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <assert.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <unistd.h>

BOOL RUINFeatureImageIsProcessMainForTesting(const void *header);

@interface FeatureImageOwner : NSObject
@end
@implementation FeatureImageOwner
- (NSString *)description { return @"owner"; }
@end

static void CheckHookIndependentClassOwner(void) {
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header(0);
    if (header->cputype != CPU_TYPE_ARM64 || header->cpusubtype != CPU_SUBTYPE_ARM64_ALL) return;
    const uint8_t *cursor = (const void *)(header + 1);
    NSString *uuid = nil;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const void *)cursor;
        if (command->cmd == LC_UUID)
            uuid = [[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
        cursor += command->cmdsize;
    }
    assert(uuid);
    RUINHostIdentity host = {.uuid=uuid.UTF8String};
    RUINFeatureImage image;
    assert(RUINResolveFeatureImage(&host, FeatureImageOwner.class, &image));
    assert(image.image.header == header && RUINFeatureImageMatches(&image, &host));
    RUINReleaseFeatureImage(&image);
    Method method = class_getInstanceMethod(FeatureImageOwner.class, @selector(description));
    IMP original = method_getImplementation(method);
    IMP replacement = class_getMethodImplementation(NSObject.class, @selector(description));
    Dl_info native = {0}, foreign = {0};
    assert(dladdr((const void *)original, &native) && dladdr((const void *)replacement, &foreign));
    assert(native.dli_fbase != foreign.dli_fbase);
    method_setImplementation(method, replacement); // Host-only stand-in for a Logos inspection hook.
    assert(RUINResolveFeatureImage(&host, FeatureImageOwner.class, &image));
    assert(image.image.header == header);
    RUINReleaseFeatureImage(&image);
    method_setImplementation(method, original);
}

typedef struct {
    struct mach_header_64 header;
    struct uuid_command uuid;
    struct { struct dylib_command command; char name[8]; } identifier;
    struct segment_command_64 text;
} TestImage;

static void MakeFile(const char *path) {
    int fd = open(path, O_CREAT | O_WRONLY, 0600);
    assert(fd >= 0); assert(close(fd) == 0);
}
static void MakeImage(TestImage *image, const RUINHostIdentity *host, uint32_t filetype) {
    memset(image, 0, sizeof(*image));
    image->header = (struct mach_header_64){.magic=MH_MAGIC_64, .cputype=CPU_TYPE_ARM64,
        .cpusubtype=CPU_SUBTYPE_ARM64_ALL, .filetype=filetype, .ncmds=3,
        .sizeofcmds=sizeof(*image)-sizeof(image->header), .flags=MH_NO_REEXPORTED_DYLIBS};
    image->uuid = (struct uuid_command){.cmd=LC_UUID, .cmdsize=sizeof(image->uuid)};
    [[[NSUUID alloc] initWithUUIDString:@(host->uuid)] getUUIDBytes:image->uuid.uuid];
    image->identifier.command = (struct dylib_command){.cmd=LC_ID_DYLIB,
        .cmdsize=sizeof(image->identifier), .dylib.name.offset=sizeof(struct dylib_command)};
    strcpy(image->identifier.name, "LINE");
    image->text = (struct segment_command_64){.cmd=LC_SEGMENT_64, .cmdsize=sizeof(image->text),
        .vmaddr=(uintptr_t)image, .vmsize=sizeof(*image), .initprot=VM_PROT_READ};
    strcpy(image->text.segname, "__TEXT");
}

// Compile a second copy of the production resolver with only its environment
// inputs replaced. In particular, native selection, conversion detection,
// UUID/CPU/slide checks and loader-lifetime decisions are not test substitutes.
static const char *runtimeBundlePath, *runtimeProcessPath, *runtimeOwnerPath;
static RUINDyldImageCandidate runtimeCandidates[2];
static RUINDyldImageCandidate runtimeMainCandidate;
static struct dyld_image_info runtimeKernelImage;
static struct { uint32_t version, count; const struct dyld_image_info *images; } runtimeKernelInfo;
static BOOL runtimeMainAvailable, runtimeKernelAvailable, runtimePinAvailable;
static unsigned runtimeSnapshotCalls, runtimeOpenCalls, runtimeCloseCalls, runtimeKernelCalls;
static int runtimeLoaderToken;

@interface FeatureImageBundleFixture : NSObject
+ (instancetype)mainBundle;
- (NSString *)executablePath;
@end
@implementation FeatureImageBundleFixture
+ (instancetype)mainBundle {
    static FeatureImageBundleFixture *bundle;
    if (!bundle) bundle = [self new];
    return bundle;
}
- (NSString *)executablePath { return runtimeBundlePath ? @(runtimeBundlePath) : nil; }
@end

static BOOL RuntimeMainImage(RUINMainExecutableImage *image) {
    return runtimeMainAvailable && RUINResolveMainExecutableImageFromCandidates(runtimeProcessPath,
        &runtimeMainCandidate, 1, image);
}
static int RuntimeExecutablePath(char *path, uint32_t *size) {
    uint32_t needed = runtimeProcessPath ? (uint32_t)strlen(runtimeProcessPath) + 1 : 0;
    if (!needed || !path || *size < needed) { *size = needed; return -1; }
    memcpy(path, runtimeProcessPath, needed);
    return 0;
}
static const char *RuntimeClassImage(Class cls) { return cls ? runtimeOwnerPath : NULL; }
static uint32_t RuntimeImageCount(void) { runtimeSnapshotCalls++; return 2; }
static const struct mach_header *RuntimeImageHeader(uint32_t index) {
    assert(index < 2); return (const void *)runtimeCandidates[index].header;
}
static intptr_t RuntimeImageSlide(uint32_t index) {
    assert(index < 2); return runtimeCandidates[index].slide;
}
static const char *RuntimeImageName(uint32_t index) {
    assert(index < 2); return runtimeCandidates[index].imageName;
}
static void RuntimeImageObserver(void (*callback)(const struct mach_header *, intptr_t)) {
    (void)callback;
}
static void *RuntimeOpen(const char *path, int mode) {
    runtimeOpenCalls++;
    assert(path && (mode & RTLD_NOLOAD));
    return runtimePinAvailable ? &runtimeLoaderToken : NULL;
}
static int RuntimeClose(void *reference) {
    assert(reference == &runtimeLoaderToken); runtimeCloseCalls++; return 0;
}
static kern_return_t RuntimeTaskInfo(task_name_t task, task_flavor_t flavor,
    task_info_t output, mach_msg_type_number_t *count) {
    (void)task; runtimeKernelCalls++;
    assert(flavor == TASK_DYLD_INFO && *count == TASK_DYLD_INFO_COUNT);
    if (!runtimeKernelAvailable) return KERN_FAILURE;
    task_dyld_info_data_t *info = (void *)output;
    *info = (task_dyld_info_data_t){.all_image_info_addr=(mach_vm_address_t)&runtimeKernelInfo,
        .all_image_info_size=sizeof(runtimeKernelInfo), .all_image_info_format=TASK_DYLD_ALL_IMAGE_INFO_64};
    return KERN_SUCCESS;
}

#define NSBundle FeatureImageBundleFixture
#define RUINResolveMainExecutableImage RuntimeMainImage
#define _NSGetExecutablePath RuntimeExecutablePath
#define class_getImageName RuntimeClassImage
#define _dyld_image_count RuntimeImageCount
#define _dyld_get_image_header RuntimeImageHeader
#define _dyld_get_image_vmaddr_slide RuntimeImageSlide
#define _dyld_get_image_name RuntimeImageName
#define _dyld_register_func_for_add_image RuntimeImageObserver
#define _dyld_register_func_for_remove_image RuntimeImageObserver
#define dlopen RuntimeOpen
#define dlclose RuntimeClose
#define task_info RuntimeTaskInfo
#define RUINFeatureImageResolutionStatus RuntimeResolutionStatus
#define RUINFeatureImageMatches RuntimeImageMatches
#define RUINResolveFeatureImageFromCandidates RuntimeResolveCandidates
#define RUINFeatureImageIsProcessMainForTesting RuntimeIsProcessMain
#define RUINResolveNativeFeatureImage RuntimeResolveNative
#define RUINResolveFeatureImage RuntimeResolveFeature
#define RUINReleaseFeatureImage RuntimeReleaseFeature
#define RUINReadFeatureImageBytes RuntimeReadBytes
#define RUINVerifyFeatureInstructions RuntimeVerifyInstructions
#include "../src/known/FeatureImage.m"
#undef NSBundle
#undef RUINResolveMainExecutableImage
#undef _NSGetExecutablePath
#undef class_getImageName
#undef _dyld_image_count
#undef _dyld_get_image_header
#undef _dyld_get_image_vmaddr_slide
#undef _dyld_get_image_name
#undef _dyld_register_func_for_add_image
#undef _dyld_register_func_for_remove_image
#undef dlopen
#undef dlclose
#undef task_info
#undef RUINFeatureImageResolutionStatus
#undef RUINFeatureImageMatches
#undef RUINResolveFeatureImageFromCandidates
#undef RUINFeatureImageIsProcessMainForTesting
#undef RUINResolveNativeFeatureImage
#undef RUINResolveFeatureImage
#undef RUINReleaseFeatureImage
#undef RUINReadFeatureImageBytes
#undef RUINVerifyFeatureInstructions

static void ResetRuntimeProof(TestImage *image, const char *line, const char *process, const char *alias) {
    runtimeBundlePath = line; runtimeProcessPath = process; runtimeOwnerPath = alias;
    runtimeMainCandidate = (RUINDyldImageCandidate){&image->header, 0, line};
    runtimeCandidates[0] = runtimeMainCandidate;
    runtimeCandidates[1] = (RUINDyldImageCandidate){&image->header, 0, alias};
    runtimeKernelImage = (struct dyld_image_info){.imageLoadAddress=(const void *)&image->header};
    runtimeKernelInfo.version = 1; runtimeKernelInfo.count = 1; runtimeKernelInfo.images = &runtimeKernelImage;
    runtimeMainAvailable = runtimeKernelAvailable = YES;
    runtimePinAvailable = NO;
    runtimeSnapshotCalls = runtimeOpenCalls = runtimeCloseCalls = runtimeKernelCalls = 0;
    // Each synthetic scenario represents a fresh process. The production cache
    // is only a positive kernel proof and has no reset API.
    atomic_store(&nativeProcessHeader, NULL);
}

static void CheckRuntimeBoundaries(const RUINHostIdentity *host,
    const char *line, const char *process, const char *alias) {
    TestImage native, guest, other;
    MakeImage(&native, host, MH_EXECUTE);
    native.header.flags = MH_PIE;
    native.identifier.command.cmd = LC_LOAD_DYLIB;
    MakeImage(&guest, host, MH_DYLIB);
    MakeImage(&other, host, MH_EXECUTE);
    RUINFeatureImage image;

    ResetRuntimeProof(&native, line, line, alias);
    // A genuine native process must not be gated by an unrelated unload race or
    // by dlopen refusing to provide a handle for the main executable.
    runtimeCandidates[1].imageName = (const void *)1;
    assert(RuntimeResolveFeature(host, FeatureImageOwner.class, &image));
    assert(image.image.header == &native.header && !image.loaderReference && !image.convertedExecutable);
    assert(!runtimeSnapshotCalls && !runtimeOpenCalls && runtimeKernelCalls == 1);
    RuntimeReleaseFeature(&image);
    runtimeKernelAvailable = NO;
    assert(RuntimeResolveNative(host, &image));
    assert(runtimeKernelCalls == 1); // A positive process-lifetime proof is reused.
    assert(!runtimeSnapshotCalls && !runtimeOpenCalls);
    native.uuid.uuid[0]++;
    assert(!RuntimeResolveNative(host, &image) && !image.image.header);
    native.uuid.uuid[0]--;
    native.header.cpusubtype = CPU_SUBTYPE_ARM64E;
    assert(!RuntimeResolveNative(host, &image));
    native.header.cpusubtype = CPU_SUBTYPE_ARM64_ALL;
    runtimeMainCandidate.slide++;
    assert(!RuntimeResolveNative(host, &image));
    runtimeMainCandidate.slide--;
    runtimeOwnerPath = process;
    assert(!RuntimeResolveFeature(host, FeatureImageOwner.class, &image));
    assert(!runtimeSnapshotCalls && !runtimeOpenCalls);

    ResetRuntimeProof(&native, line, line, alias);
    runtimeKernelAvailable = NO;
    assert(!RuntimeResolveNative(host, &image));
    runtimeKernelAvailable = YES;
    assert(RuntimeResolveNative(host, &image)); // Failed proofs are never cached.
    assert(runtimeKernelCalls == 2);

    ResetRuntimeProof(&native, line, line, alias);
    runtimeKernelImage.imageLoadAddress = (const void *)&other.header;
    assert(!RuntimeResolveNative(host, &image));
    assert(!RuntimeResolveFeature(host, FeatureImageOwner.class, &image));
    assert(runtimeSnapshotCalls && runtimeOpenCalls == 1 && !image.image.header);

    ResetRuntimeProof(&guest, line, process, alias);
    assert(!RuntimeResolveNative(host, &image));
    assert(!RuntimeResolveFeature(host, FeatureImageOwner.class, &image));
    assert(runtimeOpenCalls == 1 && !image.image.header);
    runtimePinAvailable = YES;
    assert(RuntimeResolveFeature(host, FeatureImageOwner.class, &image));
    assert(image.convertedExecutable && image.loaderReference == &runtimeLoaderToken);
    RuntimeReleaseFeature(&image);
    assert(runtimeCloseCalls == 1);

    // A virtualized process path and MH_EXECUTE rewrite still cannot turn a
    // converted guest into the no-pin native case, even if kernel input lies.
    guest.header.filetype = MH_EXECUTE;
    ResetRuntimeProof(&guest, line, line, alias);
    assert(!RuntimeResolveNative(host, &image));
    assert(!RuntimeResolveFeature(host, FeatureImageOwner.class, &image));
    assert(!runtimeKernelCalls && runtimeOpenCalls == 1);
    runtimePinAvailable = YES;
    assert(RuntimeResolveFeature(host, FeatureImageOwner.class, &image));
    assert(image.convertedExecutable && image.loaderReference == &runtimeLoaderToken);
    RuntimeReleaseFeature(&image);
    assert(runtimeCloseCalls == 1);

    ResetRuntimeProof(&guest, line, line, alias);
    runtimePinAvailable = YES;
    runtimeCandidates[1].imageName = (const void *)1;
    assert(!RuntimeResolveFeature(host, FeatureImageOwner.class, &image));
    assert(runtimeOpenCalls == 1 && runtimeCloseCalls == 1 && !image.image.header);
}

int main(void) { @autoreleasepool {
    CheckHookIndependentClassOwner();
    const RUINVersionMapping *version = RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"});
    assert(version);
    char dir[] = "/tmp/ruin-feature-image.XXXXXX"; assert(mkdtemp(dir));
    char line[PATH_MAX], host[PATH_MAX], alias[PATH_MAX];
    snprintf(line,sizeof(line),"%s/LINE",dir); MakeFile(line);
    snprintf(host,sizeof(host),"%s/Container",dir); MakeFile(host);
    snprintf(alias,sizeof(alias),"%s/current",dir); assert(!symlink(line,alias));
    CheckRuntimeBoundaries(&version->host, line, host, alias);
    TestImage guest, other; MakeImage(&guest,&version->host,MH_DYLIB);
    MakeImage(&other,&version->host,MH_DYLIB);
    assert(RUINFeatureImageIsProcessMainForTesting(_dyld_get_image_header(0)));
    assert(!RUINFeatureImageIsProcessMainForTesting(&guest.header));
    RUINDyldImageCandidate candidates[2] = {{&guest.header,0,line},{&guest.header,0,alias}};
    RUINFeatureImage image;
#define RESOLVE(n) RUINResolveFeatureImageFromCandidates(&version->host,line,host,line, &guest.header,candidates,n,&image)
    assert(RESOLVE(2)); assert(image.image.header == &guest.header && image.convertedExecutable);
    assert(!RUINVerifyHostImage(&version->host,&guest.header)); // Strict consumers stay strict.
    uint32_t magic = 0;
    assert(RUINReadFeatureImageBytes(&image,(uintptr_t)&guest.header.magic,&magic,4,"__TEXT"));
    assert(magic == MH_MAGIC_64);
    assert(!RUINReadFeatureImageBytes(&image,(uintptr_t)&guest,&magic,4,"__DATA"));
    assert(!RUINReadFeatureImageBytes(&image,UINTPTR_MAX-1,&magic,4,"__TEXT"));
    assert(!RUINReadFeatureImageBytes(&image,(uintptr_t)&guest+sizeof(guest)-1,&magic,4,"__TEXT"));
    RUINInstructionAnchor anchor = {.address=(uintptr_t)&guest.header.magic, .wordCount=1, .words={MH_MAGIC_64}};
    assert(RUINVerifyFeatureInstructions(&image,&anchor,1));
    anchor.words[0]++; assert(!RUINVerifyFeatureInstructions(&image,&anchor,1));
    candidates[1].slide++; assert(!RESOLVE(2)); candidates[1].slide--;
    candidates[1].header=&other.header; assert(!RESOLVE(2));
    other.header.magic=0; assert(!RESOLVE(2)); // Invalid same-path candidates cannot be skipped.
    candidates[1].header=(const void *)1; assert(!RESOLVE(2));
    candidates[1].header=&guest.header;
    guest.header.flags |= MH_PIE; assert(!RESOLVE(2)); guest.header.flags &= ~MH_PIE;
    guest.uuid.uuid[0]++; assert(!RESOLVE(2)); guest.uuid.uuid[0]--;
    guest.header.cpusubtype=CPU_SUBTYPE_ARM64E; assert(!RESOLVE(2)); guest.header.cpusubtype=CPU_SUBTYPE_ARM64_ALL;
    guest.uuid.cmdsize--; assert(!RESOLVE(2)); guest.uuid.cmdsize++;
    guest.header.filetype=MH_EXECUTE; assert(RESOLVE(2)); // LC's in-memory type rewrite.
    guest.header.flags=MH_PIE; assert(!RESOLVE(2)); // Another process path needs conversion proof.
    assert(RUINResolveFeatureImageFromCandidates(&version->host,line,line,alias,
        &guest.header,candidates,2,&image)); // Native process main, canonical symlink.
    assert(!RUINResolveFeatureImageFromCandidates(&version->host,line,line,host,
        &guest.header,candidates,2,&image));
    assert(!RUINResolveFeatureImageFromCandidates(&version->host,line,line,line,
        &other.header,candidates,2,&image));
    assert(RUINResolveFeatureImageFromCandidates(&version->host,line,line,line,
        &guest.header,candidates,2,&image));
    guest.uuid.uuid[0]++; assert(!RUINFeatureImageMatches(&image,&version->host)); guest.uuid.uuid[0]--;
    vm_address_t page = 0;
    assert(vm_allocate(mach_task_self(),&page,vm_page_size,VM_FLAGS_ANYWHERE) == KERN_SUCCESS);
    guest.text.vmaddr = page; guest.text.vmsize = vm_page_size;
    assert(vm_protect(mach_task_self(),page,vm_page_size,FALSE,VM_PROT_NONE) == KERN_SUCCESS);
    assert(!RUINReadFeatureImageBytes(&image,page,&magic,4,"__TEXT"));
    assert(vm_deallocate(mach_task_self(),page,vm_page_size) == KERN_SUCCESS);
    assert(!RUINReadFeatureImageBytes(&image,page,&magic,4,"__TEXT"));
    assert(!RUINReadFeatureImageBytes(&(RUINFeatureImage){.image.header=(const void *)1},1,&magic,4,"__TEXT"));
    RUINReleaseFeatureImage(&image); assert(!image.image.header);
    unlink(alias); unlink(line); unlink(host); rmdir(dir);
    puts("PASS feature image: native process fast path/cache/retry, LC pin lifetime and type rewrite, canonical owner, UUID/CPU/slide, safe reads and strict main unchanged");
} return 0; }
