#import "BinaryVerifier.h"
#import <mach-o/dyld.h>
#import <os/lock.h>
#include <string.h>
#include <limits.h>
#include <stdlib.h>

static BOOL ValidExecutableHeader64(const struct mach_header_64 *header) {
    return header && header->magic == MH_MAGIC_64 && header->filetype == MH_EXECUTE &&
        header->sizeofcmds <= 1024 * 1024 &&
        header->ncmds <= header->sizeofcmds / sizeof(struct load_command);
}

static BOOL ValidARM64ExecutableHeader(const struct mach_header_64 *header) {
    return ValidExecutableHeader64(header) && header->cputype == CPU_TYPE_ARM64;
}

static const struct load_command *NextCommand(const uint8_t *cursor, const uint8_t *end) {
    if ((size_t)(end - cursor) < sizeof(struct load_command)) return NULL;
    const struct load_command *command = (const void *)cursor;
    return command->cmdsize >= sizeof(*command) && command->cmdsize <= (size_t)(end - cursor) ? command : NULL;
}

static BOOL ImageUUID(const struct mach_header_64 *header, uint8_t output[16]) {
    if (!ValidExecutableHeader64(header) || !output) return NO;
    const uint8_t *cursor = (const void *)(header + 1), *end = cursor + header->sizeofcmds;
    BOOL found = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = NextCommand(cursor, end);
        if (!command) return NO;
        if (command->cmd == LC_UUID) {
            if (found || command->cmdsize != sizeof(struct uuid_command)) return NO;
            memcpy(output, ((const struct uuid_command *)command)->uuid, 16);
            found = YES;
        }
        cursor += command->cmdsize;
    }
    return found && cursor == end;
}

BOOL RUINVerifyHostImage(const RUINHostIdentity *host, const struct mach_header_64 *header) {
    if (!host || !ValidARM64ExecutableHeader(header)) return NO;
    NSUUID *expected = [[NSUUID alloc] initWithUUIDString:@(host->uuid)];
    if (!expected) return NO;
    uuid_t expectedBytes;
    uint8_t actualBytes[16];
    [expected getUUIDBytes:expectedBytes];
    return ImageUUID(header, actualBytes) && !memcmp(actualBytes, expectedBytes, sizeof(actualBytes));
}

static char *CanonicalImagePath(const char *path) {
    if (!path || !*path) return NULL;
    return realpath(path, NULL);
}

BOOL RUINResolveMainExecutableImageFromCandidates(const char *executablePath,
    const RUINDyldImageCandidate *candidates, size_t count, RUINMainExecutableImage *result)
{
    if (!result) return NO;
    memset(result, 0, sizeof(*result));
    if (!executablePath || !*executablePath || (!candidates && count) || count > UINT32_MAX) return NO;

    char *expectedPath = CanonicalImagePath(executablePath);
    if (!expectedPath) return NO;
    const RUINDyldImageCandidate *match = NULL;
    size_t matchIndex = 0;
    uint8_t matchUUID[16] = {0};
    BOOL ambiguous = NO;
    for (size_t i = 0; i < count; i++) {
        const RUINDyldImageCandidate *candidate = &candidates[i];
        uint8_t candidateUUID[16];
        char *candidatePath = CanonicalImagePath(candidate->imageName);
        if (!candidatePath) continue;
        BOOL sameImage = !strcmp(expectedPath, candidatePath);
        free(candidatePath);
        if (!sameImage) continue;
        if (!ImageUUID(candidate->header, candidateUUID)) { ambiguous = YES; break; }
        if (match) {
            if (match->header != candidate->header || match->slide != candidate->slide ||
                memcmp(matchUUID, candidateUUID, sizeof(matchUUID))) {
                ambiguous = YES; break;
            }
            continue; // Multiple dyld indexes can alias the same loaded guest.
        }
        match = candidate;
        matchIndex = i;
        memcpy(matchUUID, candidateUUID, sizeof(matchUUID));
    }
    free(expectedPath);
    if (!match || ambiguous) return NO;

    *result = (RUINMainExecutableImage){
        .header = match->header,
        .slide = match->slide,
        .imageIndex = (uint32_t)matchIndex,
        .cpuType = match->header->cputype,
        .cpuSubtype = match->header->cpusubtype,
    };
    memcpy(result->uuid, matchUUID, sizeof(result->uuid));
    return YES;
}

static char *CurrentExecutablePath(void) {
    uint32_t size = PATH_MAX;
    char *path = malloc(size);
    if (!path) return NULL;
    if (_NSGetExecutablePath(path, &size) == 0) return path;
    free(path);
    if (!size) return NULL;
    path = malloc(size);
    if (!path) return NULL;
    if (_NSGetExecutablePath(path, &size) == 0) return path;
    free(path);
    return NULL;
}

// The MH_EXECUTE image lives for the process lifetime. Cache only a unique
// positive result; dyld enumeration and path canonicalization happen unlocked.
static os_unfair_lock gMainExecutableImageCacheLock = OS_UNFAIR_LOCK_INIT;
static BOOL gHasMainExecutableImageCache;
static RUINMainExecutableImage gMainExecutableImageCache;

static BOOL SameMainExecutableImage(const RUINMainExecutableImage *left,
    const RUINMainExecutableImage *right)
{
    return left->header == right->header && left->slide == right->slide &&
        left->cpuType == right->cpuType &&
        left->cpuSubtype == right->cpuSubtype && !memcmp(left->uuid, right->uuid, sizeof(left->uuid));
}

static BOOL CopyCachedMainExecutableImage(RUINMainExecutableImage *result)
{
    os_unfair_lock_lock(&gMainExecutableImageCacheLock);
    BOOL cached = gHasMainExecutableImageCache;
    if (cached) *result = gMainExecutableImageCache;
    os_unfair_lock_unlock(&gMainExecutableImageCacheLock);
    return cached;
}

static BOOL StoreMainExecutableImage(RUINMainExecutableImage *image,
    RUINMainExecutableImage *result)
{
    os_unfair_lock_lock(&gMainExecutableImageCacheLock);
    if (!gHasMainExecutableImageCache) {
        gMainExecutableImageCache = *image;
        gHasMainExecutableImageCache = YES;
    }
    BOOL sameImage = SameMainExecutableImage(&gMainExecutableImageCache, image);
    if (sameImage) *result = gMainExecutableImageCache;
    os_unfair_lock_unlock(&gMainExecutableImageCacheLock);
    return sameImage;
}

BOOL RUINResolveMainExecutableImage(RUINMainExecutableImage *result) {
    if (!result) return NO;
    memset(result, 0, sizeof(*result));
    if (CopyCachedMainExecutableImage(result)) return YES;

    char *path = CurrentExecutablePath();
    if (!path) return NO;
    uint32_t count = _dyld_image_count();
    RUINDyldImageCandidate *candidates = count ? calloc(count, sizeof(*candidates)) : NULL;
    if (count && !candidates) {
        free(path);
        return NO;
    }
    for (uint32_t i = 0; i < count; i++) {
        candidates[i] = (RUINDyldImageCandidate){
            .header = (const struct mach_header_64 *)_dyld_get_image_header(i),
            .slide = _dyld_get_image_vmaddr_slide(i),
            .imageName = _dyld_get_image_name(i),
        };
    }
    RUINMainExecutableImage image = {0};
    BOOL resolved = RUINResolveMainExecutableImageFromCandidates(path, candidates, count, &image);
    free(candidates);
    free(path);
    return resolved && StoreMainExecutableImage(&image, result);
}

BOOL RUINReadImageBytes(const struct mach_header_64 *header, intptr_t slide,
    uintptr_t address, void *output, size_t length, const char *segmentName) {
    if (!ValidARM64ExecutableHeader(header) || !output || !length || !segmentName || strlen(segmentName) > 16 ||
        address > UINTPTR_MAX - length) return NO;
    const uint8_t *cursor = (const void *)(header + 1), *end = cursor + header->sizeofcmds;
    BOOL contained = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = NextCommand(cursor, end);
        if (!command) return NO;
        if (command->cmd == LC_SEGMENT_64) {
            if (command->cmdsize < sizeof(struct segment_command_64)) return NO;
            const struct segment_command_64 *segment = (const void *)command;
            if (!strncmp(segment->segname, segmentName, sizeof(segment->segname)) &&
                (segment->initprot & VM_PROT_READ) && address >= segment->vmaddr &&
                address - segment->vmaddr <= segment->vmsize &&
                length <= segment->vmsize - (address - segment->vmaddr)) contained = YES;
        }
        cursor += command->cmdsize;
    }
    if (!contained || cursor != end) return NO;
    // Add ASLR without signed overflow or wrapping a malicious fixture address.
    uintptr_t resolved;
    if (slide >= 0) {
        if (address > UINTPTR_MAX - (uintptr_t)slide) return NO;
        resolved = address + (uintptr_t)slide;
    } else {
        uintptr_t magnitude = (uintptr_t)(-(slide + 1)) + 1;
        if (address < magnitude) return NO;
        resolved = address - magnitude;
    }
    if (resolved > UINTPTR_MAX - length) return NO;
    memcpy(output, (const void *)resolved, length);
    return YES;
}

BOOL RUINVerifyInstructions(const struct mach_header_64 *header, intptr_t slide,
    const RUINInstructionAnchor *anchors, size_t count) {
    if (!anchors || !count) return NO;
    for (size_t i = 0; i < count; i++) {
        const RUINInstructionAnchor *anchor = &anchors[i];
        uint32_t actual[4];
        if (!anchor->wordCount || anchor->wordCount > 4 || anchor->address % 4 ||
            !RUINReadImageBytes(header, slide, anchor->address, actual, anchor->wordCount * sizeof(uint32_t), "__TEXT") ||
            memcmp(actual, anchor->words, anchor->wordCount * sizeof(uint32_t))) return NO;
    }
    return YES;
}
