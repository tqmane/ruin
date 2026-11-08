#pragma once
#import "../known/BinaryVerifier.h"
#import "../known/VersionMapping.h"

static inline BOOL RUINVersionMetadataIsValid(id value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    const unsigned char *cursor = (const void *)[value UTF8String];
    if (!cursor || !*cursor) return NO;
    BOOL digit = NO;
    for (; *cursor; cursor++) {
        if (*cursor >= '0' && *cursor <= '9') digit = YES;
        else if (*cursor == '.' && digit) digit = NO;
        else return NO;
    }
    return digit;
}

static inline BOOL RUINTargetMetadataMatchesInfo(NSDictionary *info)
{
    // Structural ObjC hooks validate their own class, selector and ABI. A new
    // version may use those paths without inheriting any private code address.
    // Numeric/Swift mappings must separately verify the exact known image.
    if (![info isKindOfClass:NSDictionary.class] ||
        (![info[@"CFBundleIdentifier"] isEqual:@"jp.naver.line"] &&
         ![info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"])) return NO;
    id version = info[@"CFBundleShortVersionString"], build = info[@"CFBundleVersion"];
    return RUINVersionMetadataIsValid(version) && RUINVersionMetadataIsValid(build);
}

static inline BOOL RUINMappingIdentityMatchesInfo(const RUINVersionMapping *mapping, NSDictionary *info) {
    id version = info[@"CFBundleShortVersionString"], build = info[@"CFBundleVersion"];
    return mapping && [version isKindOfClass:NSString.class] && [build isKindOfClass:NSString.class] &&
        [version isEqualToString:@(mapping->host.version)] && [build isEqualToString:@(mapping->host.build)];
}

static inline const RUINVersionMapping *RUINVerifiedMappingForInfo(NSDictionary *info) {
    if (!RUINTargetMetadataMatchesInfo(info)) return NULL;
#if defined(RUIN_HOST_CHECK)
    return RUINMappingForInfo(info);
#else
    const RUINVersionMapping *mapping = RUINCurrentMapping();
    return RUINMappingIdentityMatchesInfo(mapping, info) ? mapping : NULL;
#endif
}

static inline BOOL RUINVerifiedTargetMatchesInfo(NSDictionary *info) {
    return RUINVerifiedMappingForInfo(info) != NULL;
}

static inline BOOL RUINFullySupportedTargetMatchesInfo(NSDictionary *info) {
    const RUINVersionMapping *mapping = RUINVerifiedMappingForInfo(info);
    return mapping && mapping->host.supportStatus == RUINMappingStatusVerified;
}
