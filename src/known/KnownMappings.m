#import "VersionMapping.h"
#import "BinaryVerifier.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <string.h>

static const RUINVersionMapping *const kVersions[] = {
    &RUINLINE26160,
    &RUINLINE26170
};

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
    if (!RUINInfoIsLINE(info) || (verifyImage && !header) || (!versions && count)) return NULL;
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
    // Do not cache a miss: BundleIdentity can call during early initialization.
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header(0);
    return RUINResolveMapping(info, header, YES, kVersions, sizeof(kVersions) / sizeof(*kVersions));
}

const RUINVersionMapping *RUINMappingForHostIdentity(const RUINHostIdentity *host)
{
    if (!host || !host->version || !host->build || !host->uuid) return NULL;
    const RUINVersionMapping *match = NULL;
    for (size_t i = 0; i < sizeof(kVersions) / sizeof(*kVersions); i++) {
        const RUINHostIdentity *candidate = &kVersions[i]->host;
        if (strcmp(candidate->version, host->version) || strcmp(candidate->build, host->build) ||
            strcmp(candidate->uuid, host->uuid)) continue;
        if (match) return NULL;
        match = kVersions[i];
    }
    return match;
}

void RUINEnumerateVersionMappings(RUINVersionMappingEnumerator callback, void *context)
{
    if (!callback) return;
    for (size_t i = 0; i < sizeof(kVersions) / sizeof(*kVersions); i++) callback(kVersions[i], context);
}

const RUINHostIdentity *RUINKnownHostForVersion(NSString *version, NSString *build)
{
    if (![version isKindOfClass:NSString.class] || ![build isKindOfClass:NSString.class]) return NULL;
    NSDictionary *info = @{
        @"CFBundleIdentifier": @"jp.naver.line",
        @"CFBundleShortVersionString": version,
        @"CFBundleVersion": build
    };
    const RUINVersionMapping *mapping = RUINMappingForInfo(info);
    return mapping ? &mapping->host : NULL;
}

const RUINHostIdentity *RUINKnownHostForInfo(NSDictionary *info)
{
    const RUINVersionMapping *mapping = RUINMappingForInfo(info);
    return mapping ? &mapping->host : NULL;
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
