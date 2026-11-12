#import "FeatureImage.h"
#import "VersionMapping.h"
#import <mach/mach.h>
#import <mach-o/dyld.h>
#include <assert.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <unistd.h>

BOOL RUINFeatureImageIsProcessMainForTesting(const void *header);

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
int main(void) { @autoreleasepool {
    const RUINVersionMapping *version = RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"});
    assert(version);
    char dir[] = "/tmp/ruin-feature-image.XXXXXX"; assert(mkdtemp(dir));
    char line[PATH_MAX], host[PATH_MAX], alias[PATH_MAX];
    snprintf(line,sizeof(line),"%s/LINE",dir); MakeFile(line);
    snprintf(host,sizeof(host),"%s/Container",dir); MakeFile(host);
    snprintf(alias,sizeof(alias),"%s/current",dir); assert(!symlink(line,alias));
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
    puts("PASS feature image: canonical owner, LC conversion/type rewrite, UUID/CPU, aliases/conflicts, safe reads, strict main unchanged");
} return 0; }
