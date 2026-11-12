#import "FeatureImage.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

static BOOL CopyReadable(uintptr_t address, void *output, size_t length) {
    if (!address || !output || !length || address > UINTPTR_MAX - length) return NO;
    vm_size_t copied = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)address, length,
        (vm_address_t)output, &copied) == KERN_SUCCESS && copied == length;
}

// Copy first: a removed or malformed candidate must never be dereferenced while
// walking dyld's list. Loaded images are pinned before feature bytes are read.
static NSData *CopyCommands(const struct mach_header_64 *address,
    struct mach_header_64 *header, uint8_t uuid[16], BOOL *converted) {
    if (!CopyReadable((uintptr_t)address, header, sizeof(*header)) ||
        header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
        header->cpusubtype != CPU_SUBTYPE_ARM64_ALL ||
        (header->filetype != MH_EXECUTE && header->filetype != MH_DYLIB) ||
        !header->sizeofcmds || header->sizeofcmds > 1024 * 1024 ||
        header->ncmds > header->sizeofcmds / sizeof(struct load_command) ||
        (uintptr_t)address > UINTPTR_MAX - sizeof(*header)) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:header->sizeofcmds];
    if (!CopyReadable((uintptr_t)address + sizeof(*header), data.mutableBytes, data.length)) return nil;
    const uint8_t *cursor = data.bytes, *end = cursor + data.length;
    BOOL found = NO, dylibID = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return nil;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) return nil;
        if (command->cmd == LC_UUID) {
            if (found || command->cmdsize != sizeof(struct uuid_command)) return nil;
            memcpy(uuid, ((const struct uuid_command *)command)->uuid, 16);
            found = YES;
        } else if (command->cmd == LC_ID_DYLIB) {
            if (dylibID || command->cmdsize < sizeof(struct dylib_command)) return nil;
            const struct dylib_command *dylib = (const void *)command;
            uint32_t offset = dylib->dylib.name.offset;
            if (offset < sizeof(*dylib) || offset >= command->cmdsize ||
                !memchr(cursor + offset, 0, command->cmdsize - offset)) return nil;
            dylibID = YES;
        } else if (command->cmd == LC_SEGMENT_64 && command->cmdsize < sizeof(struct segment_command_64)) {
            return nil;
        }
        cursor += command->cmdsize;
    }
    if (!found || cursor != end) return nil;
    // LC can change the in-memory type back to MH_EXECUTE. Its conversion still
    // has an LC_ID_DYLIB, clears PIE and sets NO_REEXPORTED_DYLIBS.
    *converted = dylibID && !(header->flags & MH_PIE) && (header->flags & MH_NO_REEXPORTED_DYLIBS);
    return data;
}

BOOL RUINFeatureImageMatches(const RUINFeatureImage *image, const RUINHostIdentity *host) {
    if (!image || !host || !host->uuid) return NO;
    struct mach_header_64 header;
    uint8_t uuid[16]; BOOL converted = NO;
    if (!CopyCommands(image->image.header, &header, uuid, &converted)) return NO;
    uuid_t expected;
    NSUUID *identity = [[NSUUID alloc] initWithUUIDString:@(host->uuid)];
    if (!identity) return NO;
    [identity getUUIDBytes:expected];
    return header.filetype == image->fileType && converted == image->convertedExecutable &&
        !memcmp(uuid, expected, 16) && !memcmp(uuid, image->image.uuid, 16) &&
        header.cputype == image->image.cpuType && header.cpusubtype == image->image.cpuSubtype;
}

static BOOL SamePath(const char *left, const char *right) {
    char *a = left ? realpath(left, NULL) : NULL, *b = right ? realpath(right, NULL) : NULL;
    BOOL same = a && b && !strcmp(a, b);
    free(a); free(b);
    return same;
}

static BOOL HeaderMatchesSlide(NSData *commands, const struct mach_header_64 *header,
    const RUINDyldImageCandidate *candidate) {
    const uint8_t *cursor = commands.bytes;
    BOOL found = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const void *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const void *)command;
            if (!strncmp(segment->segname, "__TEXT", 16)) {
                if (found || segment->fileoff || segment->vmsize < sizeof(*header) + commands.length)
                    return NO;
                uintptr_t address = (uintptr_t)candidate->header;
                // Subtract the signed slide without overflow.
                if (candidate->slide >= 0) {
                    if (address < (uintptr_t)candidate->slide ||
                        address - (uintptr_t)candidate->slide != segment->vmaddr) return NO;
                } else {
                    uintptr_t magnitude = (uintptr_t)(-(candidate->slide + 1)) + 1;
                    if (address > UINTPTR_MAX - magnitude || address + magnitude != segment->vmaddr) return NO;
                }
                found = YES;
            }
        }
        cursor += command->cmdsize;
    }
    return found;
}

BOOL RUINResolveFeatureImageFromCandidates(const RUINHostIdentity *host,
    const char *bundleExecutable, const char *processExecutable, const char *ownerExecutable,
    const struct mach_header_64 *ownerHeader, const RUINDyldImageCandidate *candidates,
    size_t count, RUINFeatureImage *result) {
    if (!result) return NO;
    memset(result, 0, sizeof(*result));
    if (!host || !ownerHeader || !SamePath(bundleExecutable, ownerExecutable) ||
        (!candidates && count) || count > UINT32_MAX) return NO;
    BOOL found = NO, sameProcessPath = SamePath(bundleExecutable, processExecutable);
    for (size_t i = 0; i < count; i++) {
        const RUINDyldImageCandidate *candidate = &candidates[i];
        if (!SamePath(bundleExecutable, candidate->imageName)) continue;
        struct mach_header_64 header; uint8_t uuid[16]; BOOL converted = NO;
        NSData *commands = CopyCommands(candidate->header, &header, uuid, &converted);
        if (candidate->header != ownerHeader || !commands ||
            !HeaderMatchesSlide(commands, &header, candidate) ||
            ((!sameProcessPath || header.filetype == MH_DYLIB) && !converted)) goto reject;
        if (found) {
            // dyld index aliases are one image; another instance at the same
            // path is ambiguous, even when one candidate is otherwise invalid.
            if (result->image.header != candidate->header || result->image.slide != candidate->slide ||
                result->fileType != header.filetype || memcmp(result->image.uuid, uuid, 16)) goto reject;
            continue;
        }
        result->image = (RUINMainExecutableImage){.header=candidate->header,
            .slide=candidate->slide, .imageIndex=(uint32_t)i,
            .cpuType=header.cputype, .cpuSubtype=header.cpusubtype};
        memcpy(result->image.uuid, uuid, 16);
        result->fileType = header.filetype;
        result->convertedExecutable = converted;
        if (!RUINFeatureImageMatches(result, host)) goto reject;
        found = YES;
    }
    if (found) return YES;
reject:
    memset(result, 0, sizeof(*result));
    return NO;
}

static atomic_uint_fast64_t imageGeneration;
static void ImageListChanged(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    atomic_fetch_add_explicit(&imageGeneration, 1, memory_order_relaxed);
}

static char *CopyImageName(const char *name) {
    if (!name) return NULL;
    char path[PATH_MAX];
    for (size_t offset = 0; offset < sizeof(path);) {
        uintptr_t address = (uintptr_t)name;
        if (address > UINTPTR_MAX - offset) return NULL;
        address += offset;
        size_t length = MIN((size_t)64, MIN(sizeof(path) - offset,
            (size_t)vm_page_size - address % vm_page_size));
        if (!CopyReadable(address, path + offset, length)) return NULL;
        if (memchr(path + offset, 0, length)) return strdup(path);
        offset += length;
    }
    return NULL;
}

BOOL RUINResolveFeatureImage(const RUINHostIdentity *host, const void *implementation,
    RUINFeatureImage *result) {
    if (!result) return NO;
    memset(result, 0, sizeof(*result));
    Dl_info owner = {0};
    const char *bundle = NSBundle.mainBundle.executablePath.fileSystemRepresentation;
    if (!implementation || !bundle || !dladdr(implementation, &owner) || !owner.dli_fbase ||
        !SamePath(bundle, owner.dli_fname)) return NO;
    static dispatch_once_t observers;
    dispatch_once(&observers, ^{
        _dyld_register_func_for_add_image(ImageListChanged);
        _dyld_register_func_for_remove_image(ImageListChanged);
    });
    // NOLOAD never loads a substitute. Holding this reference keeps the image
    // alive during verification, publication, and subsequent pass-through calls.
    uint32_t pathSize = 0;
    _NSGetExecutablePath(NULL, &pathSize);
    char *process = pathSize && pathSize <= 1024 * 1024 ? malloc(pathSize) : NULL;
    BOOL pathValid = process && !_NSGetExecutablePath(process, &pathSize);
    struct mach_header_64 header; uint8_t uuid[16]; BOOL converted = NO;
    if (!pathValid || !CopyCommands(owner.dli_fbase, &header, uuid, &converted)) {
        free(process); return NO;
    }
    // A real process main has process lifetime and cannot be dlopened as a
    // library. Converted guests require a retained, already-loaded handle.
    void *reference = converted ? dlopen(bundle, RTLD_LAZY | RTLD_NOLOAD) : NULL;
    if ((converted && !reference) || (!converted &&
        (header.filetype != MH_EXECUTE || !SamePath(bundle, process)))) {
        free(process); return NO;
    }
    uint64_t generation = atomic_load_explicit(&imageGeneration, memory_order_acquire);
    uint32_t count = _dyld_image_count();
    RUINDyldImageCandidate *candidates = count ? calloc(count, sizeof(*candidates)) : NULL;
    BOOL complete = pathValid && candidates;
    for (uint32_t i = 0; complete && i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        candidates[i] = (RUINDyldImageCandidate){
            .header=(const void *)_dyld_get_image_header(i), .slide=_dyld_get_image_vmaddr_slide(i),
            .imageName=CopyImageName(name)};
        if (!candidates[i].imageName) complete = NO;
    }
    BOOL resolved = complete && count == _dyld_image_count() &&
        generation == atomic_load_explicit(&imageGeneration, memory_order_acquire) &&
        RUINResolveFeatureImageFromCandidates(host, bundle, process, owner.dli_fname,
            owner.dli_fbase, candidates, count, result);
    for (uint32_t i = 0; i < count && candidates; i++) free((void *)candidates[i].imageName);
    free(candidates); free(process);
    if (!resolved) { if (reference) dlclose(reference); return NO; }
    result->loaderReference = reference;
    return YES;
}

void RUINReleaseFeatureImage(RUINFeatureImage *image) {
    if (!image) return;
    if (image->loaderReference) dlclose(image->loaderReference);
    memset(image, 0, sizeof(*image));
}

BOOL RUINReadFeatureImageBytes(const RUINFeatureImage *image, uintptr_t address,
    void *output, size_t length, const char *segmentName) {
    if (!image || !output || !length || !segmentName || strlen(segmentName) > 16 ||
        address > UINTPTR_MAX - length) return NO;
    struct mach_header_64 header; uint8_t uuid[16]; BOOL converted = NO;
    NSData *commands = CopyCommands(image->image.header, &header, uuid, &converted);
    if (!commands || header.filetype != image->fileType || converted != image->convertedExecutable ||
        memcmp(uuid, image->image.uuid, 16)) return NO;
    const uint8_t *cursor = commands.bytes;
    BOOL contained = NO;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        const struct load_command *command = (const void *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const void *)command;
            if (!strncmp(segment->segname, segmentName, 16) && (segment->initprot & VM_PROT_READ) &&
                address >= segment->vmaddr && address - segment->vmaddr <= segment->vmsize &&
                length <= segment->vmsize - (address - segment->vmaddr)) contained = YES;
        }
        cursor += command->cmdsize;
    }
    uintptr_t resolved;
    intptr_t slide = image->image.slide;
    if (!contained) return NO;
    if (slide >= 0) {
        if (address > UINTPTR_MAX - (uintptr_t)slide) return NO;
        resolved = address + (uintptr_t)slide;
    } else {
        uintptr_t magnitude = (uintptr_t)(-(slide + 1)) + 1;
        if (address < magnitude) return NO;
        resolved = address - magnitude;
    }
    return CopyReadable(resolved, output, length);
}

BOOL RUINVerifyFeatureInstructions(const RUINFeatureImage *image,
    const RUINInstructionAnchor *anchors, size_t count) {
    if (!anchors || !count) return NO;
    for (size_t i = 0; i < count; i++) {
        uint32_t actual[4]; const RUINInstructionAnchor *anchor = &anchors[i];
        if (!anchor->wordCount || anchor->wordCount > 4 || anchor->address % 4 ||
            !RUINReadFeatureImageBytes(image, anchor->address, actual, anchor->wordCount * 4, "__TEXT") ||
            memcmp(actual, anchor->words, anchor->wordCount * 4)) return NO;
    }
    return YES;
}
