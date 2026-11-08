#pragma once

#import "BinaryVerifier.h"

typedef struct {
    RUINMappingStatus status;
    uintptr_t methodIMP;
    uintptr_t themeURLString;
    const RUINInstructionAnchor *anchors;
    size_t anchorCount;
} RUINThemeShopNavigationMapping;

typedef struct {
    RUINMappingStatus status;
    uintptr_t modeReturnPC;
    uintptr_t accountReturnPC;
    uintptr_t modeCopyReturnPC;
    uintptr_t preflightAccountReturnPC;
    uintptr_t accountChain[3];
    uintptr_t stylesheetEligibilityReturnPC;
    uintptr_t stylesheetSaveReturnPC;
    uintptr_t capabilityReturnPC;
    uintptr_t themeActionReturnPC;
    uintptr_t shopSchemeReturnPCs[2];
    uintptr_t shopSchemeHandlerReturnPCs[2];
    uintptr_t plainModeStackOffset;
    const RUINInstructionAnchor *anchors;
    size_t anchorCount;
} RUINThemeShopEligibilityMapping;

typedef struct {
    RUINMappingStatus status;
    uintptr_t resultReturnPC;
    uintptr_t resultMethodIMP;
    uintptr_t resultLogString;
    const RUINInstructionAnchor *anchors;
    size_t anchorCount;
} RUINThemeValidationMapping;

typedef struct {
    RUINMappingStatus status;
    uintptr_t repositoryReturnPC;
    uintptr_t serverSyncReturnPCs[2];
    uintptr_t readOnlyExcludedReturnPC;
    const RUINInstructionAnchor *anchors;
    size_t anchorCount;
} RUINThemeLocalPolicyMapping;

typedef struct {
    RUINMappingStatus status;
    uintptr_t priceTierReplacementVA;
    uintptr_t applyObserverMethodVA;
    uintptr_t defaultsFreezeReplacementVA;
    uintptr_t manualDownloadSourceReplacementVA;
    uintptr_t resetMethodVA;
} RUINThemeFeatureAddressesMapping;

typedef struct {
    RUINThemeShopNavigationMapping shopNavigation;
    RUINThemeShopEligibilityMapping shopEligibility;
    RUINThemeValidationMapping validation;
    RUINThemeLocalPolicyMapping localPolicy;
    RUINThemeFeatureAddressesMapping featureAddresses;
} RUINThemeMappings;

FOUNDATION_EXPORT const RUINThemeMappings *RUINThemeMappingsForHost(const RUINHostIdentity *host);
FOUNDATION_EXPORT BOOL RUINThemeLocalPolicyCallersMatch(const RUINThemeLocalPolicyMapping *mapping,
    const uintptr_t *PCs, size_t count);
