#import "BinaryVerifier.h"
#include <string.h>
#include <limits.h>
#import <mach-o/dyld.h>

static BOOL ValidHeader(const struct mach_header_64 *header) {
    return header && header->magic == MH_MAGIC_64 && header->cputype == CPU_TYPE_ARM64 &&
        header->filetype == MH_EXECUTE && header->sizeofcmds <= 1024 * 1024 &&
        header->ncmds <= header->sizeofcmds / sizeof(struct load_command);
}

static const struct load_command *NextCommand(const uint8_t *cursor, const uint8_t *end) {
    if ((size_t)(end - cursor) < sizeof(struct load_command)) return NULL;
    const struct load_command *command = (const void *)cursor;
    return command->cmdsize >= sizeof(*command) && command->cmdsize <= (size_t)(end - cursor) ? command : NULL;
}

BOOL RUINVerifyHostImage(const RUINHostIdentity *host, const struct mach_header_64 *header) {
    if (!host || !ValidHeader(header)) return NO;
    NSUUID *expected = [[NSUUID alloc] initWithUUIDString:@(host->uuid)];
    if (!expected) return NO;
    uuid_t bytes;
    [expected getUUIDBytes:bytes];
    const uint8_t *cursor = (const void *)(header + 1), *end = cursor + header->sizeofcmds;
    BOOL found = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = NextCommand(cursor, end);
        if (!command) return NO;
        if (command->cmd == LC_UUID) {
            if (found || command->cmdsize != sizeof(struct uuid_command) ||
                memcmp(((const struct uuid_command *)command)->uuid, bytes, sizeof(bytes))) return NO;
            found = YES;
        }
        cursor += command->cmdsize;
    }
    return found && cursor == end;
}

BOOL RUINCurrentHostImageMatches(const RUINHostIdentity *host) {
    if (!host) return NO;
    static const RUINHostIdentity *verified;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(0);
        for (size_t i = 0; i < RUINKnownHostCount; i++)
            if (RUINVerifyHostImage(&RUINKnownHosts[i], header)) { verified = &RUINKnownHosts[i]; break; }
    });
    return verified == host;
}

BOOL RUINReadImageBytes(const struct mach_header_64 *header, intptr_t slide,
    uintptr_t address, void *output, size_t length, const char *segmentName) {
    if (!ValidHeader(header) || !output || !length || !segmentName || strlen(segmentName) > 16 ||
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
