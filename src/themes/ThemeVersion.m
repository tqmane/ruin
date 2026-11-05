#import "ThemeVersion.h"

#include <limits.h>

static BOOL RUINThemeVersionIsASCIIDecimal(NSString *text)
{
    if (text.length == 0) return NO;
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        if (character < '0' || character > '9') return NO;
    }
    return YES;
}

static BOOL RUINThemeVersionParseDecimal(NSString *text, unsigned long long *value)
{
    if (!RUINThemeVersionIsASCIIDecimal(text)) return NO;

    unsigned long long parsed = 0;
    for (NSUInteger index = 0; index < text.length; index++) {
        unichar character = [text characterAtIndex:index];
        unsigned long long digit = (unsigned long long)(character - '0');
        if (parsed > (ULLONG_MAX - digit) / 10) return NO;
        parsed = parsed * 10 + digit;
    }
    *value = parsed;
    return YES;
}

NSString * _Nullable RUINThemeDownloadVersion(NSString * _Nullable input)
{
    if (!input || input.length > 128) return nil;

    NSString *version = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (version.length == 0) return nil;

    if (RUINThemeVersionIsASCIIDecimal(version)) return version;

    NSUInteger start = 0;
    unichar first = [version characterAtIndex:0];
    if (first == 'V' || first == 'v') start = 1;

    NSRange dot = [version rangeOfString:@"." options:0 range:NSMakeRange(start, version.length - start)];
    if (dot.location == NSNotFound || dot.location == start ||
        version.length - NSMaxRange(dot) != 2) return nil;

    NSString *majorText = [version substringWithRange:NSMakeRange(start, dot.location - start)];
    NSString *minorText = [version substringFromIndex:NSMaxRange(dot)];
    unsigned long long major;
    unsigned long long minor;
    if (!RUINThemeVersionParseDecimal(majorText, &major) || major < 1 ||
        !RUINThemeVersionParseDecimal(minorText, &minor)) return nil;

    unsigned long long base = major - 1;
    if (base > (ULLONG_MAX - minor - 1) / 100) return nil;
    unsigned long long mapped = base * 100 + minor + 1;
    return [NSString stringWithFormat:@"%llu", mapped];
}

NSString * _Nullable RUINThemeDisplayVersion(NSString * _Nullable version)
{
    if (!version || version.length > 128) return nil;
    unsigned long long raw;
    if (!RUINThemeVersionParseDecimal(version, &raw) || raw == 0) return nil;
    return [NSString stringWithFormat:@"V%llu.%02llu", (raw - 1) / 100 + 1, (raw - 1) % 100];
}
