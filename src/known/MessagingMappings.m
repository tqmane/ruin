#import "MessagingMappings.h"
#import "VersionMapping.h"

const RUINMessagingMapping *RUINMessagingMappingForHost(const RUINHostIdentity *host)
{
    const RUINVersionMapping *mapping = RUINMappingForHostIdentity(host);
    return mapping ? &mapping->messaging : NULL;
}

const RUINMessagingMapping *RUINMessagingMappingForInfo(NSDictionary *info)
{
    const RUINVersionMapping *mapping = RUINMappingForInfo(info);
    return mapping ? &mapping->messaging : NULL;
}
