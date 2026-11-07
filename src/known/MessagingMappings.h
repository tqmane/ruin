#pragma once
#import "BinaryVerifier.h"

typedef struct {
    const RUINInstructionAnchor *anchors;
    size_t anchorCount;
    uintptr_t callerReturnAddress;
} RUINReadBoundaryMapping;

typedef struct {
    const RUINInstructionAnchor *parserAnchors;
    size_t parserAnchorCount;
    uintptr_t parserParam1ReturnAddress;
    const uintptr_t *orderedLookupReturnAddresses;
    size_t orderedLookupReturnAddressCount;
} RUINUnsendOperationMapping;

typedef struct {
    const RUINHostIdentity *host;
    RUINReadBoundaryMapping readBoundary;
    RUINUnsendOperationMapping unsendOperation;
} RUINMessagingMapping;

FOUNDATION_EXPORT const RUINMessagingMapping *RUINMessagingMappingForHost(const RUINHostIdentity *host);
FOUNDATION_EXPORT const RUINMessagingMapping *RUINMessagingMappingForInfo(NSDictionary *info);
