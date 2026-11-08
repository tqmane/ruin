#import "NativeTabMappings.h"
#import "VersionMapping.h"

const RUINNativeTabMapping *RUINNativeTabMappingForHost(const RUINHostIdentity *host)
{
    const RUINVersionMapping *mapping = RUINMappingForHostIdentity(host);
    return mapping ? &mapping->nativeTabs : NULL;
}
