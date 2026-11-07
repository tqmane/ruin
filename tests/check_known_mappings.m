#import "KnownMappings.h"
#import "BinaryVerifier.h"
#import "TargetMetadata.h"
#include <assert.h>
#include <string.h>

int main(void) { @autoreleasepool {
    // Expectations are independent of KnownHosts.def and include cross-version
    // combinations: a recognized version must never admit another build/UUID.
    const RUINHostIdentity *old = RUINKnownHostForVersion(@"26.16.0", @"2026.1006.1718");
    const RUINHostIdentity *current = RUINKnownHostForVersion(@"26.17.0", @"2026.1103.1841");
    assert(old && current && old != current);
    assert(!RUINKnownHostForVersion(@"26.17.0", @"2026.1006.1718"));
    assert(!RUINKnownHostForVersion(@"26.18.0", @"2026.1103.1841"));
    NSDictionary *info = @{@"CFBundleIdentifier":@"jp.naver.line",
        @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"};
    assert(RUINKnownHostForInfo(info) == current);
    NSMutableDictionary *future = [info mutableCopy];
    future[@"CFBundleShortVersionString"]=@"26.18.0";
    future[@"CFBundleVersion"]=@"2026.1110.1200";
    assert(RUINTargetMetadataMatchesInfo(future));
    assert(!RUINVerifiedTargetMatchesInfo(future) && !RUINKnownHostForInfo(future));
    future[@"CFBundleVersion"]=@"2026..1110";
    assert(!RUINTargetMetadataMatchesInfo(future));
    future[@"CFBundleVersion"]=@".";
    assert(!RUINTargetMetadataMatchesInfo(future));
    NSMutableDictionary *renamed = [info mutableCopy];
    renamed[@"CFBundleIdentifier"] = @"example.sideload.line";
    assert(!RUINKnownHostForInfo(renamed));
    renamed[@"RUINOriginalBundleIdentifier"] = @"jp.naver.line";
    assert(RUINKnownHostForInfo(renamed) == current);

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
    assert(RUINVerifyHostImage(current,&image.header));
    assert(!RUINVerifyHostImage(old,&image.header));
    image.uuid.uuid[0]^=1;
    assert(!RUINVerifyHostImage(current,&image.header));
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
    assert(!RUINVerifyHostImage(current,&image.header));
    assert(!RUINReadImageBytes(&image.header,slide,0x100000000,&output,4,"__TEXT"));
    puts("PASS known builds, UUID isolation, bounded image reads and instruction mismatch gates");
} return 0; }
