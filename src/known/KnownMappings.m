#import "VersionMapping.h"
#import "BinaryVerifier.h"
#import <mach-o/loader.h>

#define RUIN_VERSION_MAPPING_REGISTRY(X) \
    X(RUINLINE26160) \
    X(RUINLINE26170)
#define RUIN_DECLARE_VERSION_MAPPING(symbol) extern const RUINVersionMapping symbol;
RUIN_VERSION_MAPPING_REGISTRY(RUIN_DECLARE_VERSION_MAPPING)
#undef RUIN_DECLARE_VERSION_MAPPING
#define RUIN_VERSION_MAPPING_POINTER(symbol) &symbol,
static const RUINVersionMapping *const kVersions[] = {
    RUIN_VERSION_MAPPING_REGISTRY(RUIN_VERSION_MAPPING_POINTER)
};
#undef RUIN_VERSION_MAPPING_POINTER
#undef RUIN_VERSION_MAPPING_REGISTRY

static BOOL RUINInfoIsLINE(NSDictionary *info)
{
    return [info isKindOfClass:NSDictionary.class] &&
        ([info[@"CFBundleIdentifier"] isEqual:@"jp.naver.line"] ||
         [info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"]);
}

static BOOL RUINInfoMatchesVersionBuild(NSDictionary *info, const RUINHostIdentity *host)
{
    id version = info[@"CFBundleShortVersionString"];
    id build = info[@"CFBundleVersion"];
    return host && [version isKindOfClass:NSString.class] && [build isKindOfClass:NSString.class] &&
        [version isEqualToString:@(host->version)] && [build isEqualToString:@(host->build)];
}

static const RUINVersionMapping *RUINResolveMapping(
    NSDictionary *info,
    const struct mach_header_64 *header,
    BOOL verifyImage,
    const RUINVersionMapping *const *versions,
    size_t count)
{
    // A verified LINE executable may have a renamed sideload identifier.
    // Metadata-only selection still requires LINE's explicit identity.
    if (![info isKindOfClass:NSDictionary.class] || (!verifyImage && !RUINInfoIsLINE(info)) ||
        (verifyImage && !header) || (!versions && count)) return NULL;
    const RUINVersionMapping *match = NULL;
    for (size_t i = 0; i < count; i++) {
        const RUINVersionMapping *candidate = versions[i];
        if (!RUINInfoMatchesVersionBuild(info, &candidate->host) ||
            (verifyImage && !RUINVerifyHostImage(&candidate->host, header))) continue;
        if (match) return NULL;
        match = candidate;
    }
    return match;
}

const RUINVersionMapping *RUINMappingForInfo(NSDictionary *info)
{
    return RUINResolveMapping(info, NULL, NO, kVersions, sizeof(kVersions) / sizeof(*kVersions));
}

const RUINVersionMapping *RUINCurrentMapping(void)
{
    // Do not permanently cache a miss: BundleIdentity can call during early initialization.
    // Check the resolved main image first so LiveContainer miss-caching avoids querying Info.plist.
    RUINMainExecutableImage image;
    if (!RUINResolveMainExecutableImage(&image)) return NULL;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return RUINResolveMapping(info, image.header, YES, kVersions, sizeof(kVersions) / sizeof(*kVersions));
}

void RUINEnumerateVersionMappings(RUINVersionMappingEnumerator callback, void *context)
{
    if (!callback) return;
    for (size_t i = 0; i < sizeof(kVersions) / sizeof(*kVersions); i++) callback(kVersions[i], context);
}

#if defined(RUIN_HOST_CHECK)
const RUINVersionMapping *RUINMappingForInfoInRegistryForTesting(
    NSDictionary *info, const RUINVersionMapping *const *versions, size_t count)
{
    return RUINResolveMapping(info, NULL, NO, versions, count);
}

const RUINVersionMapping *RUINMappingForImageInRegistryForTesting(
    NSDictionary *info, const struct mach_header_64 *header,
    const RUINVersionMapping *const *versions, size_t count)
{
    return RUINResolveMapping(info, header, YES, versions, count);
}
#endif
