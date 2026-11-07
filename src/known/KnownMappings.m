#import "KnownMappings.h"

const RUINHostIdentity RUINKnownHosts[] = {
#define RUIN_KNOWN_HOST(version, build, uuid, hash, complete) {version, build, uuid, hash, complete},
#define RUIN_LATEST_HOST RUIN_KNOWN_HOST
#include "KnownHosts.def"
#undef RUIN_LATEST_HOST
#undef RUIN_KNOWN_HOST
};
const size_t RUINKnownHostCount = sizeof(RUINKnownHosts) / sizeof(RUINKnownHosts[0]);

const RUINHostIdentity *RUINKnownHostForVersion(NSString *version, NSString *build) {
    if (![version isKindOfClass:NSString.class] || ![build isKindOfClass:NSString.class]) return NULL;
    for (size_t i = 0; i < RUINKnownHostCount; i++) {
        const RUINHostIdentity *host = &RUINKnownHosts[i];
        if ([version isEqualToString:@(host->version)] && [build isEqualToString:@(host->build)]) return host;
    }
    return NULL;
}

const RUINHostIdentity *RUINKnownHostForInfo(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class] ||
        (![info[@"CFBundleIdentifier"] isEqual:@"jp.naver.line"] &&
         ![info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"])) return NULL;
    return RUINKnownHostForVersion(info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]);
}
