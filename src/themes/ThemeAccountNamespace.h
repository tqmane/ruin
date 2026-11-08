#ifndef RUIN_THEME_ACCOUNT_NAMESPACE_H
#define RUIN_THEME_ACCOUNT_NAMESPACE_H

#import <Foundation/Foundation.h>
#include <string.h>

enum { RUINThemeAccountNamespaceLength = 35 };

// Native account components are P_/S_ followed by u + 32 lowercase hex digits.
// Validate only; callers retain the complete role-prefixed namespace.
static inline BOOL RUINThemeAccountNamespaceIsValidCString(const char *account)
{
    if (!account || strnlen(account, RUINThemeAccountNamespaceLength + 1) != RUINThemeAccountNamespaceLength ||
        (account[0] != 'P' && account[0] != 'S') || account[1] != '_' || account[2] != 'u') return NO;
    for (size_t i = 3; i < RUINThemeAccountNamespaceLength; i++) {
        char c = account[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return NO;
    }
    return YES;
}

static inline BOOL RUINThemeAccountNamespaceIsValid(id account)
{
    return [account isKindOfClass:NSString.class] &&
        [(NSString *)account length] == RUINThemeAccountNamespaceLength &&
        RUINThemeAccountNamespaceIsValidCString([(NSString *)account UTF8String]);
}

#endif
