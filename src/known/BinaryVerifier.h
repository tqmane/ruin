#pragma once
#import "KnownMappings.h"
#import <mach-o/loader.h>
#include <stdint.h>

typedef struct {
    uintptr_t address;
    uint8_t wordCount;
    uint32_t words[4];
} RUINInstructionAnchor;

typedef struct {
    const struct mach_header_64 *header;
    intptr_t slide;
    const char *imageName;
} RUINDyldImageCandidate;

// Generic process main executable identity; numeric host maps impose ARM64/UUID checks separately.
typedef struct {
    const struct mach_header_64 *header;
    intptr_t slide;
    uint32_t imageIndex;
    int32_t cpuType;
    int32_t cpuSubtype;
    uint8_t uuid[16];
} RUINMainExecutableImage;

FOUNDATION_EXPORT BOOL RUINVerifyHostImage(const RUINHostIdentity *host, const struct mach_header_64 *header);
// Requires one canonical-path MH_EXECUTE instance; identical dyld aliases count once.
FOUNDATION_EXPORT BOOL RUINResolveMainExecutableImageFromCandidates(const char *executablePath,
    const RUINDyldImageCandidate *candidates, size_t count, RUINMainExecutableImage *result);
FOUNDATION_EXPORT BOOL RUINResolveMainExecutableImage(RUINMainExecutableImage *result);
FOUNDATION_EXPORT BOOL RUINReadImageBytes(const struct mach_header_64 *header, intptr_t slide,
    uintptr_t address, void *output, size_t length, const char *segmentName);
FOUNDATION_EXPORT BOOL RUINVerifyInstructions(const struct mach_header_64 *header, intptr_t slide,
    const RUINInstructionAnchor *anchors, size_t count);
FOUNDATION_EXPORT BOOL RUINImageExecutableTextRange(const struct mach_header_64 *header,
    uintptr_t *startOut, uintptr_t *sizeOut);
