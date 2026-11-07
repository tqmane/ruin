#pragma once
#import <Foundation/Foundation.h>

// Only identities verified against pristine executables belong in this table.
// Feature-specific addresses live beside their typed mappings, never in hooks.
typedef struct RUINHostIdentity {
    const char *version;
    const char *build;
    const char *uuid;
    const char *sourceSHA256;
    BOOL fullySupported;
} RUINHostIdentity;

FOUNDATION_EXPORT const RUINHostIdentity RUINKnownHosts[];
FOUNDATION_EXPORT const size_t RUINKnownHostCount;
FOUNDATION_EXPORT const RUINHostIdentity *RUINKnownHostForVersion(NSString *version, NSString *build);
FOUNDATION_EXPORT const RUINHostIdentity *RUINKnownHostForInfo(NSDictionary *info);
