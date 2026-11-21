#import "ThemeMappings.h"

BOOL RUINThemeLocalPolicyCallersMatch(const RUINThemeLocalPolicyMapping *mapping,
    const uintptr_t *PCs, size_t count)
{
    return mapping && mapping->status == RUINMappingStatusVerified && PCs && count >= 2 &&
        PCs[0] == mapping->repositoryReturnPC &&
        (PCs[1] == mapping->serverSyncReturnPCs[0] || PCs[1] == mapping->serverSyncReturnPCs[1]);
}

BOOL RUINThemeChatBackgroundIdiomWipeMatches(
    const RUINThemeChatBackgroundIdiomMapping *mapping,
    intptr_t slide,
    uintptr_t helperReturnPC,
    uintptr_t wipeReturnPC)
{
    if (!mapping || mapping->status != RUINMappingStatusVerified || !mapping->idiomHelperReturnPC) return NO;
    uintptr_t unslidHelper = (uintptr_t)((intptr_t)helperReturnPC - slide);
    if (unslidHelper != mapping->idiomHelperReturnPC) return NO;
    uintptr_t unslidWipe = (uintptr_t)((intptr_t)wipeReturnPC - slide);
    for (size_t i = 0; i < sizeof(mapping->wipeReturnPCs) / sizeof(*mapping->wipeReturnPCs); i++) {
        if (mapping->wipeReturnPCs[i] && unslidWipe == mapping->wipeReturnPCs[i]) return YES;
    }
    return NO;
}
