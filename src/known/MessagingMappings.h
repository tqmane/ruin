#pragma once
#import "BinaryVerifier.h"

typedef struct {
    RUINMappingStatus status;
    const RUINInstructionAnchor *anchors;
    size_t anchorCount;
    uintptr_t callerReturnAddress;
} RUINReadBoundaryMapping;

typedef struct {
    RUINMappingStatus parserStatus;
    const RUINInstructionAnchor *parserAnchors;
    size_t parserAnchorCount;
    uintptr_t parserParam1ReturnAddress;
    RUINMappingStatus lookupStatus;
    const uintptr_t *orderedLookupReturnAddresses;
    size_t orderedLookupReturnAddressCount;
} RUINUnsendOperationMapping;

typedef struct {
    RUINReadBoundaryMapping readBoundary;
    RUINUnsendOperationMapping unsendOperation;
} RUINMessagingMapping;
