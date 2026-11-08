#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

typedef enum : uint8_t {
    RUINMappingStatusUnsupported = 0,
    RUINMappingStatusUnverified = 1,
    RUINMappingStatusVerified = 2
} RUINMappingStatus;

typedef struct RUINVersionMapping RUINVersionMapping;

// Only identities verified against pristine executables belong in this table.
// Feature-specific addresses live beside their typed mappings, never in hooks.
typedef struct RUINHostIdentity {
    const char *version;
    const char *build;
    const char *uuid;
    const char *sourceSHA256;
    RUINMappingStatus supportStatus;
} RUINHostIdentity;

typedef void (*RUINVersionMappingEnumerator)(const RUINVersionMapping *mapping, void *context);

FOUNDATION_EXPORT const RUINVersionMapping *RUINMappingForInfo(NSDictionary *info);
FOUNDATION_EXPORT const RUINVersionMapping *RUINCurrentMapping(void);
FOUNDATION_EXPORT const RUINVersionMapping *RUINMappingForHostIdentity(const RUINHostIdentity *host);
FOUNDATION_EXPORT void RUINEnumerateVersionMappings(RUINVersionMappingEnumerator callback, void *context);

// Temporary compatibility accessors; new mapping consumers use the composite API.
FOUNDATION_EXPORT const RUINHostIdentity *RUINKnownHostForVersion(NSString *version, NSString *build);
FOUNDATION_EXPORT const RUINHostIdentity *RUINKnownHostForInfo(NSDictionary *info);
