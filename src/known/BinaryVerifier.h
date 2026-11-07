#pragma once
#import "KnownMappings.h"
#import <mach-o/loader.h>
#include <stdint.h>

typedef struct {
    uintptr_t address;
    uint8_t wordCount;
    uint32_t words[4];
} RUINInstructionAnchor;

FOUNDATION_EXPORT BOOL RUINVerifyHostImage(const RUINHostIdentity *host, const struct mach_header_64 *header);
FOUNDATION_EXPORT BOOL RUINCurrentHostImageMatches(const RUINHostIdentity *host);
FOUNDATION_EXPORT BOOL RUINReadImageBytes(const struct mach_header_64 *header, intptr_t slide,
    uintptr_t address, void *output, size_t length, const char *segmentName);
FOUNDATION_EXPORT BOOL RUINVerifyInstructions(const struct mach_header_64 *header, intptr_t slide,
    const RUINInstructionAnchor *anchors, size_t count);
