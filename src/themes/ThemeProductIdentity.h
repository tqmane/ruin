#pragma once
#import <Foundation/Foundation.h>

// Older downloads may use uppercase UUID directories. Normalize their identity,
// not their existing filesystem path; non-UUID native product IDs keep their case.
static inline NSString * _Nullable RUINCanonicalThemeProductID(id _Nullable value)
{
    if (![value isKindOfClass:NSString.class]) return nil;
    NSUUID *UUID = [[NSUUID alloc] initWithUUIDString:value];
    return UUID && [UUID.UUIDString caseInsensitiveCompare:value] == NSOrderedSame
        ? UUID.UUIDString.lowercaseString : value;
}
