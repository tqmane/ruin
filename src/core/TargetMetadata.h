#pragma once
#import "../known/BinaryVerifier.h"

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

static inline BOOL RUINVerifiedTargetMatchesInfo(NSDictionary *info) {
    const RUINHostIdentity *host = RUINKnownHostForInfo(info);
#if defined(RUIN_HOST_CHECK)
    return host != NULL;
#else
    return RUINCurrentHostImageMatches(host);
#endif
}

static inline BOOL RUINFullySupportedTargetMatchesInfo(NSDictionary *info) {
    const RUINHostIdentity *host = RUINKnownHostForInfo(info);
    return host && host->fullySupported && RUINVerifiedTargetMatchesInfo(info);
}
