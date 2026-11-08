#import "KnownMappings.h"
#import "VersionMapping.h"
#import "BinaryVerifier.h"
#import "TargetMetadata.h"
#include <assert.h>
#include <string.h>

const RUINVersionMapping *RUINMappingForInfoInRegistryForTesting(
    NSDictionary *, const RUINVersionMapping *const *, size_t);
const RUINVersionMapping *RUINMappingForImageInRegistryForTesting(
    NSDictionary *, const struct mach_header_64 *, const RUINVersionMapping *const *, size_t);

static const RUINVersionMapping kStaticInitProbe = {
    .host = {"26.16.0", "2026.1006.1718", "292883E8-E011-3583-ADF5-F02241E3277B",
        "e1ad61171b021566f4a318c93ba1260747bfb220c81a79d5a80121311787d6ad", RUINMappingStatusVerified},
    .themes = {.shopNavigation = {.status = RUINMappingStatusVerified},
        .shopEligibility = {.status = RUINMappingStatusUnsupported}},
    .messaging = {.readBoundary = {.status = RUINMappingStatusVerified},
        .unsendOperation = {.parserStatus = RUINMappingStatusVerified,
            .lookupStatus = RUINMappingStatusUnsupported}},
    .nativeTabs = {.status = RUINMappingStatusVerified}
};

int main(void) { @autoreleasepool {
    assert(kStaticInitProbe.themes.shopNavigation.status == RUINMappingStatusVerified &&
        kStaticInitProbe.messaging.unsendOperation.lookupStatus == RUINMappingStatusUnsupported &&
        kStaticInitProbe.nativeTabs.status == RUINMappingStatusVerified);
    // Expectations are independent of the compiled mapping manifest and include cross-version
    // combinations: a recognized version must never admit another build/UUID.
    NSDictionary *info16 = @{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
    NSDictionary *info = @{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"};
    const RUINVersionMapping *old = RUINMappingForInfo(info16);
    const RUINVersionMapping *current = RUINMappingForInfo(info);
    assert(old && current && old != current);
    assert(old->host.supportStatus == RUINMappingStatusVerified &&
        current->host.supportStatus == RUINMappingStatusUnverified);
    assert(old->themes.shopEligibility.status == RUINMappingStatusVerified &&
        current->themes.shopEligibility.status == RUINMappingStatusUnsupported);
    assert(current->messaging.unsendOperation.parserStatus == RUINMappingStatusVerified &&
        current->messaging.unsendOperation.lookupStatus == RUINMappingStatusVerified &&
        current->messaging.unsendOperation.orderedLookupReturnAddressCount == 6);
    assert(current->messaging.readBoundary.status == RUINMappingStatusUnsupported &&
        !current->messaging.readBoundary.callerReturnAddress);
    assert(current->messaging.readUntilABIStatus == RUINMappingStatusVerified);
    assert(!RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1006.1718"}));
    assert(!RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.18.0", @"CFBundleVersion":@"2026.1103.1841"}));
    assert(!RUINCurrentMapping()); // Host test process is not a LINE executable.
    RUINVersionMapping variantA = *current;
    RUINVersionMapping variantB = *current;
    variantB.host.uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA";
    const RUINVersionMapping *variants[] = {&variantA, &variantB};
    assert(!RUINMappingForInfoInRegistryForTesting(info, variants, 2));
    NSMutableDictionary *future = [info mutableCopy];
    future[@"CFBundleShortVersionString"]=@"26.18.0";
    future[@"CFBundleVersion"]=@"2026.1110.1200";
    assert(RUINTargetMetadataMatchesInfo(future));
    assert(!RUINVerifiedTargetMatchesInfo(future) && !RUINMappingForInfo(future));
    future[@"CFBundleVersion"]=@"2026..1110";
    assert(!RUINTargetMetadataMatchesInfo(future));
    future[@"CFBundleVersion"]=@".";
    assert(!RUINTargetMetadataMatchesInfo(future));
    NSMutableDictionary *renamed = [info mutableCopy];
    renamed[@"CFBundleIdentifier"] = @"example.sideload.line";
    assert(!RUINMappingForInfo(renamed));
    renamed[@"RUINOriginalBundleIdentifier"] = @"jp.naver.line";
    assert(RUINMappingForInfo(renamed) == current);

    struct {
        struct mach_header_64 header;
        struct uuid_command uuid;
        struct segment_command_64 segment;
        uint32_t code[4];
    } image = {0};
    image.header = (struct mach_header_64){.magic=MH_MAGIC_64,.cputype=CPU_TYPE_ARM64,
        .filetype=MH_EXECUTE,.ncmds=2,.sizeofcmds=sizeof(image.uuid)+sizeof(image.segment)};
    image.uuid.cmd=LC_UUID; image.uuid.cmdsize=sizeof(image.uuid);
    [[[NSUUID alloc] initWithUUIDString:@"614CED59-07E5-372D-94B2-D4901870C7A0"] getUUIDBytes:image.uuid.uuid];
    image.segment.cmd=LC_SEGMENT_64; image.segment.cmdsize=sizeof(image.segment);
    memcpy(image.segment.segname,"__TEXT",7);
    image.segment.vmaddr=0x100000000; image.segment.vmsize=sizeof(image.code);
    image.segment.initprot=VM_PROT_READ|VM_PROT_EXECUTE;
    image.code[0]=0xaa1603e0; image.code[1]=0xd65f03c0;
    intptr_t slide=(intptr_t)(uintptr_t)image.code-(intptr_t)image.segment.vmaddr;
    assert(RUINVerifyHostImage(&current->host,&image.header));
    assert(RUINMappingForImageInRegistryForTesting(info, &image.header, variants, 2) == &variantA);
    NSMutableDictionary *genericSigned = [info mutableCopy];
    genericSigned[@"CFBundleIdentifier"] = @"example.sideload.line";
    assert(!RUINMappingForInfo(genericSigned));
    assert(RUINMappingForImageInRegistryForTesting(genericSigned, &image.header, variants, 2) == &variantA);
    RUINHostIdentity sameImageOtherBuild = current->host;
    sameImageOtherBuild.build = "2026.1103.1842";
    assert(RUINVerifyHostImage(&sameImageOtherBuild, &image.header));
    assert(!RUINVerifyHostImage(&old->host,&image.header));
    image.uuid.uuid[0]^=1;
    assert(!RUINVerifyHostImage(&current->host,&image.header));
    assert(!RUINMappingForImageInRegistryForTesting(info, &image.header, variants, 2));
    assert(!RUINMappingForImageInRegistryForTesting(genericSigned, &image.header, variants, 2));
    image.uuid.uuid[0]^=1;
    RUINInstructionAnchor anchor={0x100000000,2,{0xaa1603e0,0xd65f03c0}};
    assert(RUINVerifyInstructions(&image.header,slide,&anchor,1));
    image.code[1]^=1;
    assert(!RUINVerifyInstructions(&image.header,slide,&anchor,1));
    image.code[1]^=1;
    uint32_t output=0;
    assert(RUINReadImageBytes(&image.header,slide,0x10000000c,&output,4,"__TEXT"));
    assert(!RUINReadImageBytes(&image.header,slide,0x10000000d,&output,4,"__TEXT"));
    assert(!RUINReadImageBytes(&image.header,slide,0x100000000,&output,4,"__DATA_CONST"));
    assert(!RUINReadImageBytes(&image.header,slide,UINTPTR_MAX,&output,4,"__TEXT"));
    anchor.wordCount=5;
    assert(!RUINVerifyInstructions(&image.header,slide,&anchor,1));
    image.segment.initprot=0;
    assert(!RUINReadImageBytes(&image.header,slide,0x100000000,&output,4,"__TEXT"));
    image.segment.initprot=VM_PROT_READ;
    image.uuid.cmdsize=4;
    assert(!RUINVerifyHostImage(&current->host,&image.header));
    assert(!RUINReadImageBytes(&image.header,slide,0x100000000,&output,4,"__TEXT"));
    puts("PASS unique metadata selection, ambiguous identity rejection, exact UUID selection, bounded reads and instruction mismatch gates");
} return 0; }
