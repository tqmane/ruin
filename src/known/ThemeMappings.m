#import "ThemeMappings.h"
#import "VersionMapping.h"

const RUINThemeMappings *RUINThemeMappingsForHost(const RUINHostIdentity *host)
{
    const RUINVersionMapping *mapping = RUINMappingForHostIdentity(host);
    return mapping ? &mapping->themes : NULL;
}

BOOL RUINThemeLocalPolicyCallersMatch(const RUINThemeLocalPolicyMapping *mapping,
    const uintptr_t *PCs, size_t count)
{
    return mapping && mapping->status == RUINMappingStatusVerified && PCs && count >= 2 &&
        PCs[0] == mapping->repositoryReturnPC &&
        (PCs[1] == mapping->serverSyncReturnPCs[0] || PCs[1] == mapping->serverSyncReturnPCs[1]);
}
