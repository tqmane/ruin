#pragma once

#import "KnownMappings.h"
#import "ThemeMappings.h"
#import "MessagingMappings.h"
#import "NativeTabMappings.h"

typedef struct {
    RUINMappingStatus status;
    uintptr_t factoryClassVA;
    uintptr_t homeWitnessVA;
    uintptr_t homeConformanceVA;
    uintptr_t homeMetadataVA;
    uintptr_t homeDecoderVA;
    uintptr_t globalWitnessAccessorVA;
    uintptr_t globalConformanceVA;
    uintptr_t globalMetadataVA;
    uintptr_t globalDecoderVA;
    uintptr_t homeFlagStringVA;
    uintptr_t globalHomeFlagStringVA;
    const RUINInstructionAnchor *anchors;
    size_t anchorCount;
} RUINLegacyHomeMapping;

typedef struct RUINVersionMapping {
    RUINHostIdentity host;
    RUINThemeMappings themes;
    RUINMessagingMapping messaging;
    RUINNativeTabMapping nativeTabs;
    RUINLegacyHomeMapping legacyHome;
} RUINVersionMapping;
