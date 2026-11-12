#import "../src/known/BinaryVerifier.h"
#import "../src/known/VersionMapping.h"
#include <assert.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

const RUINVersionMapping *RUINMappingForInfoInRegistryForTesting(
    NSDictionary *, const RUINVersionMapping *const *, size_t);
const RUINVersionMapping *RUINMappingForImageInRegistryForTesting(
    NSDictionary *, const struct mach_header_64 *, const RUINVersionMapping *const *, size_t);

typedef struct {
    struct mach_header_64 header;
    struct uuid_command uuid;
} TestImage;

static void MakeFile(const char *path)
{
    int fd = open(path, O_CREAT | O_WRONLY, 0600);
    assert(fd >= 0);
    assert(write(fd, "x", 1) == 1);
    assert(close(fd) == 0);
}

static void MakeImage(TestImage *image, uint32_t filetype, int32_t subtype, NSString *uuidString)
{
    memset(image, 0, sizeof(*image));
    image->header = (struct mach_header_64){
        .magic = MH_MAGIC_64,
        .cputype = CPU_TYPE_ARM64,
        .cpusubtype = subtype,
        .filetype = filetype,
        .ncmds = 1,
        .sizeofcmds = sizeof(image->uuid)
    };
    image->uuid.cmd = LC_UUID;
    image->uuid.cmdsize = sizeof(image->uuid);
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:uuidString];
    assert(uuid);
    [uuid getUUIDBytes:image->uuid.uuid];
}

int main(void)
{
    @autoreleasepool {
        char directory[] = "/tmp/ruin-main-image.XXXXXX";
        assert(mkdtemp(directory));
        char executable[PATH_MAX], symlinkPath[PATH_MAX], fakeLINE[PATH_MAX], hook[PATH_MAX];
        snprintf(executable, sizeof(executable), "%s/LINE", directory);
        snprintf(symlinkPath, sizeof(symlinkPath), "%s/LINE-current", directory);
        snprintf(fakeLINE, sizeof(fakeLINE), "%s/renamed-LINE", directory);
        snprintf(hook, sizeof(hook), "%s/systemhook.dylib", directory);
        MakeFile(executable); MakeFile(fakeLINE); MakeFile(hook);
        assert(symlink(executable, symlinkPath) == 0);

        TestImage hookImage, arm64Image, arm64eImage, duplicateImage, x86Image;
        MakeImage(&hookImage, MH_DYLIB, CPU_SUBTYPE_ARM64_ALL,
            @"CF0D18A8-8EDA-371C-A814-6641CE3FE51F");
        MakeImage(&arm64Image, MH_EXECUTE, CPU_SUBTYPE_ARM64_ALL,
            @"614CED59-07E5-372D-94B2-D4901870C7A0");
        MakeImage(&arm64eImage, MH_EXECUTE, -2147483646,
            @"E1234567-89AB-CDEF-8123-456789ABCDEF");
        MakeImage(&duplicateImage, MH_EXECUTE, -2147483646,
            @"E7654321-89AB-CDEF-8123-456789ABCDEF");
        MakeImage(&x86Image, MH_EXECUTE, 3, @"614CED59-07E5-372D-94B2-D4901870C7A0");
        x86Image.header.cputype = CPU_TYPE_X86_64;

        // Image zero is a dylib; a same-version/build LINE-looking executable
        // at another path must not win over the actual executable identity.
        const RUINDyldImageCandidate candidates[] = {
            {&hookImage.header, 0x111000, hook},
            {&arm64Image.header, 0x222000, fakeLINE},
            {&arm64eImage.header, 0x333000, executable}
        };
        RUINMainExecutableImage mainImage = {0};
        assert(RUINResolveMainExecutableImageFromCandidates(symlinkPath, candidates,
            sizeof(candidates) / sizeof(*candidates), &mainImage));
        assert(mainImage.header == &arm64eImage.header && mainImage.slide == 0x333000 &&
            mainImage.imageIndex == 2 && mainImage.cpuType == CPU_TYPE_ARM64 &&
            mainImage.cpuSubtype == -2147483646);
        assert(!memcmp(mainImage.uuid, arm64eImage.uuid.uuid, sizeof(mainImage.uuid)));

        RUINVersionMapping arm64Mapping = {
            .host = {"26.17.0", "2026.1103.1841", "614CED59-07E5-372D-94B2-D4901870C7A0",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", RUINMappingStatusUnverified}
        };
        RUINVersionMapping arm64eMapping = {
            .host = {"26.17.0", "2026.1103.1841", "E1234567-89AB-CDEF-8123-456789ABCDEF",
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", RUINMappingStatusUnverified}
        };
        const RUINVersionMapping *variants[] = {&arm64Mapping, &arm64eMapping};
        NSDictionary *info = @{@"CFBundleIdentifier":@"jp.naver.line",
            @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"};
        assert(!RUINMappingForInfoInRegistryForTesting(info, variants, 2));
        assert(RUINMappingForImageInRegistryForTesting(info, mainImage.header, variants, 2) == &arm64eMapping);
        assert(!RUINVerifyHostImage(&arm64Mapping.host, mainImage.header));

        const RUINDyldImageCandidate arm64Only[] = {{&arm64Image.header, 0x222000, executable}};
        RUINMainExecutableImage arm64Main = {0};
        assert(RUINResolveMainExecutableImageFromCandidates(symlinkPath, arm64Only, 1, &arm64Main));
        assert(arm64Main.header == &arm64Image.header && arm64Main.slide == 0x222000 &&
            arm64Main.imageIndex == 0 && arm64Main.cpuSubtype == CPU_SUBTYPE_ARM64_ALL);
        assert(RUINMappingForImageInRegistryForTesting(info, arm64Main.header, variants, 2) == &arm64Mapping);

        const RUINDyldImageCandidate aliases[] = {
            {&arm64Image.header, 0x222000, executable},
            {&arm64Image.header, 0x222000, symlinkPath}
        };
        assert(RUINResolveMainExecutableImageFromCandidates(symlinkPath, aliases, 2, &mainImage));
        assert(mainImage.header == arm64Main.header && mainImage.slide == arm64Main.slide);
        TestImage malformed = arm64Image;
        malformed.uuid.cmdsize--;
        const RUINDyldImageCandidate invalidAlias[] = {
            aliases[0], {&malformed.header, 0x222000, executable}
        };
        assert(!RUINResolveMainExecutableImageFromCandidates(symlinkPath, invalidAlias, 2, &mainImage));

        const RUINDyldImageCandidate ambiguous[] = {
            {&arm64eImage.header, 0x333000, executable},
            {&duplicateImage.header, 0x444000, symlinkPath}
        };
        memset(&mainImage, 0xA5, sizeof(mainImage));
        assert(!RUINResolveMainExecutableImageFromCandidates(symlinkPath, ambiguous, 2, &mainImage));
        assert(!mainImage.header && !mainImage.slide && !mainImage.imageIndex);

        const RUINDyldImageCandidate wrongPath[] = {{&arm64Image.header, 0x222000, fakeLINE}};
        assert(!RUINResolveMainExecutableImageFromCandidates(symlinkPath, wrongPath, 1, &mainImage));
        const RUINDyldImageCandidate wrongFiletype[] = {{&hookImage.header, 0x111000, executable}};
        assert(!RUINResolveMainExecutableImageFromCandidates(symlinkPath, wrongFiletype, 1, &mainImage));
        const RUINDyldImageCandidate wrongCPU[] = {{&x86Image.header, 0x555000, executable}};
        assert(RUINResolveMainExecutableImageFromCandidates(symlinkPath, wrongCPU, 1, &mainImage));
        assert(mainImage.header == &x86Image.header && mainImage.cpuType == CPU_TYPE_X86_64 &&
            mainImage.cpuSubtype == 3 && !memcmp(mainImage.uuid, x86Image.uuid.uuid, sizeof(mainImage.uuid)));
        assert(!RUINVerifyHostImage(&arm64Mapping.host, mainImage.header));
        assert(!RUINMappingForImageInRegistryForTesting(info, mainImage.header, variants, 2));

        unlink(symlinkPath); unlink(executable); unlink(fakeLINE); unlink(hook); rmdir(directory);
        puts("PASS generic main-image selection, ARM64-only host verification, canonical paths, ambiguity, UUID variant selection and header/slide/index pairing");
    }
    return 0;
}
