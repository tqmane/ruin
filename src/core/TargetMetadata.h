#import <Foundation/Foundation.h>

static inline BOOL RUINTargetMetadataMatchesInfo(NSDictionary *info)
{
    return ([info[@"CFBundleIdentifier"] isEqual:@"jp.naver.line"] ||
        [info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"]) &&
        [info[@"CFBundleShortVersionString"] isEqual:@"26.16.0"] &&
        [info[@"CFBundleVersion"] isEqual:@"2026.1006.1718"];
}
