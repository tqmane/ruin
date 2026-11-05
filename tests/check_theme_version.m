/* From ruin/:
   xcrun --sdk macosx clang -fobjc-arc -std=gnu11 -Wall -Wextra -Werror -I. \
     src/themes/ThemeVersion.m tests/check_theme_version.m -framework Foundation \
     -o build/check_theme_version && build/check_theme_version
 */

#import <Foundation/Foundation.h>

#import "ThemeVersion.h"

#include <assert.h>
#include <stdio.h>

static void Expect(NSString *input, NSString *expected)
{
    NSString *actual = RUINThemeDownloadVersion(input);
    assert((actual == nil && expected == nil) || [actual isEqualToString:expected]);
}

int main(void)
{
    @autoreleasepool {
        // Public store examples: build/theme-monchichi-store.html and
        // build/theme-study-store.html.
        Expect(@"V1.30", @"31");
        Expect(@"V2.31", @"132");
        Expect(@" v1.30 \t", @"31");
        Expect(@"1.30", @"31");

        // Native DB/displayed-version mapping fixtures.
        Expect(@"V4.27", @"328");
        Expect(@"V4.14", @"315");
        Expect(@"V4.12", @"313");
        Expect(@"V1.04", @"5");
        assert([RUINThemeDisplayVersion(@"31") isEqual:@"V1.30"]);
        assert([RUINThemeDisplayVersion(@"132") isEqual:@"V2.31"]);
        assert([RUINThemeDisplayVersion(@"328") isEqual:@"V4.27"]);
        assert([RUINThemeDownloadVersion(RUINThemeDisplayVersion(@"18446744073709551615"))
            isEqual:@"18446744073709551615"]);
        assert(RUINThemeDisplayVersion(@"0") == nil);
        assert(RUINThemeDisplayVersion(@"V1.30") == nil);

        // Raw CDN versions remain unchanged, including leading zeros.
        Expect(@"328", @"328");
        Expect(@" 00328 ", @"00328");
        Expect(@"0", @"0");

        Expect(nil, nil);
        Expect(@"", nil);
        Expect(@"   ", nil);
        Expect(@"V0.00", nil);
        Expect(@"0.30", nil);
        Expect(@"V1.0", nil);
        Expect(@"V1.000", nil);
        Expect(@"V1.", nil);
        Expect(@".30", nil);
        Expect(@"V1.30.1", nil);
        Expect(@"v 1.30", nil);
        Expect(@"+1.30", nil);
        Expect(@"V１.30", nil);       // Full-width digit.
        Expect(@"V١.30", nil);        // Arabic-Indic digit.
        Expect(@"Ｖ1.30", nil);        // Full-width prefix.
        Expect(@"V1.\n30", nil);     // Embedded control.
        unichar nul = 0;
        NSString *embeddedNUL = [NSString stringWithFormat:@"32%@8",
            [NSString stringWithCharacters:&nul length:1]];
        Expect(embeddedNUL, nil);
        Expect(@"V184467440737095517.14", @"18446744073709551615");
        Expect(@"V184467440737095517.15", nil);
        Expect(@"V184467440737095518.00", nil);

        NSString *maxLength = [@"" stringByPaddingToLength:128 withString:@"0" startingAtIndex:0];
        Expect(maxLength, maxLength);
        Expect([@" " stringByAppendingString:maxLength], nil);

        puts("check_theme_version: PASS");
    }
    return 0;
}
