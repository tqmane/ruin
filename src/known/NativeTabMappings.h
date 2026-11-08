#pragma once
#import "BinaryVerifier.h"
#include <stdint.h>

typedef struct {
    unsigned slot;
    uintptr_t getterVA;
    uintptr_t returnVA;
    uint32_t callWords[5];
} RUINNativeTabRefreshRead;

typedef struct {
    const char *version;
    const char *build;
    RUINMappingStatus status;
    uintptr_t bridgeVA;
    uintptr_t witnessTableVA;
    uintptr_t caseTableVA;
    uintptr_t firstWitnessVA;
    uintptr_t lastWitnessVA;
    uint32_t bridgeWords[3];
    int32_t caseWords[5];
    unsigned slots[5];
    RUINInstructionAnchor menuGenerator;
    uintptr_t menuGeneratorEndVA;
    uintptr_t getters[5];
    RUINNativeTabRefreshRead refreshReads[5];
} RUINNativeTabMapping;

FOUNDATION_EXPORT const RUINNativeTabMapping *RUINNativeTabMappingForHost(const RUINHostIdentity *host);
