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
    RUINMappingStatus status;
    uintptr_t witnessTableVA;
    uintptr_t conformanceVA;
    uintptr_t getterVA;
    uintptr_t policyReturnVA;
    const RUINInstructionAnchor *anchors;
    size_t anchorCount;
    uintptr_t configurationWitnessTableVA;
    uintptr_t configurationConformanceVA;
    uintptr_t configurationValueTypeVA;
    uintptr_t configurationGetterVA;
    uintptr_t configurationReturnVA;
} RUINNativeMuteSendMapping;

typedef struct {
    RUINReadBoundaryMapping readBoundary;
    RUINUnsendOperationMapping unsendOperation;
    RUINMappingStatus readUntilABIStatus;
    RUINNativeMuteSendMapping nativeMuteSend;
} RUINMessagingMapping;
