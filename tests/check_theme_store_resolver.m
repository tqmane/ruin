/* From ruin/:
   xcrun --sdk macosx clang -fobjc-arc -std=gnu11 -Wall -Wextra -Werror -I. \
     src/themes/ThemeVersion.m src/themes/ThemeStoreResolver.m tests/check_theme_store_resolver.m \
     -framework Foundation -o build/check_theme_store_resolver &&
   build/check_theme_store_resolver
 */

#import <Foundation/Foundation.h>

#import "ThemeStoreResolver.h"

#include <assert.h>
#include <stdio.h>

static NSData *Fixture(NSString *path)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    assert(data != nil);
    return data;
}

static void CheckTheme(NSData *HTML, NSString *productID, NSString *name,
                       NSString *version, NSString *displayVersion)
{
    NSDictionary<NSString *, NSString *> *theme = RUINParseThemeStoreHTML(HTML, productID);
    assert(theme != nil);
    assert([theme[@"name"] isEqualToString:name]);
    assert([theme[@"productID"] isEqualToString:productID]);
    assert([theme[@"version"] isEqualToString:version]);
    assert([theme[@"displayVersion"] isEqualToString:displayVersion]);
}

int main(void)
{
    @autoreleasepool {
        NSString *monchichiID = @"313c6eb8-8584-4f5f-b849-b2b0c7e1c43d";
        NSString *studyID = @"dda6a0f7-c7b2-40bb-9f27-8077e0db73ca";
        NSData *monchichi = Fixture(@"tests/fixtures/theme-monchichi.html");
        NSData *study = Fixture(@"tests/fixtures/theme-study.html");

        CheckTheme(monchichi, monchichiID, @"モンチッチ （ギンガムチェック）", @"31", @"V1.30");
        CheckTheme(study, studyID, @"テスト期間中！勉強しろ！！", @"132", @"V2.31");
        assert(RUINParseThemeStoreHTML(monchichi, studyID) == nil);
        assert(RUINParseThemeStoreHTML(study, monchichiID) == nil);
        assert(RUINParseThemeStoreHTML([@"<script>run()</script>" dataUsingEncoding:NSUTF8StringEncoding],
            monchichiID) == nil);
        assert(RUINParseThemeStoreHTML([[NSMutableData alloc] initWithLength:1024 * 1024 + 1],
            monchichiID) == nil);

        NSString *entityHTML = [NSString stringWithFormat:
            @"<meta property='og:title' content='A &amp;#x42; &amp; B - LINE STORE'>"
             "<meta property='og:image' content='https://shop.line-scdn.net/themeshop/v1/products/"
             "31/3c/6e/%@/31/WEBSTORE/icon_198x278.png'>"
             "<p data-test='theme-name-title'>A &amp;#x42; &amp; B</p>"
             "<p class='mdCMN38Period'>V1.30 /</p>", monchichiID];
        NSDictionary *entityTheme = RUINParseThemeStoreHTML(
            [entityHTML dataUsingEncoding:NSUTF8StringEncoding], monchichiID);
        assert([entityTheme[@"name"] isEqualToString:@"A &#x42; & B"]);
        assert([entityTheme[@"version"] isEqualToString:@"31"]);

        NSString *changedHost = [[NSString alloc] initWithData:monchichi encoding:NSUTF8StringEncoding];
        changedHost = [changedHost stringByReplacingOccurrencesOfString:@"shop.line-scdn.net"
            withString:@"attacker.example"];
        assert(RUINParseThemeStoreHTML([changedHost dataUsingEncoding:NSUTF8StringEncoding],
            monchichiID) == nil);
        NSString *missingOrigin = [[NSString alloc] initWithData:monchichi encoding:NSUTF8StringEncoding];
        missingOrigin = [missingOrigin stringByReplacingOccurrencesOfString:@"https://shop.line-scdn.net"
            withString:@""];
        assert(RUINParseThemeStoreHTML([missingOrigin dataUsingEncoding:NSUTF8StringEncoding],
            monchichiID) == nil);

        NSString *base = @"https://store.line.me/themeshop/product/313c6eb8-8584-4f5f-b849-b2b0c7e1c43d/";
        assert(RUINValidatedThemeStoreURL([base stringByAppendingString:@"ja"]) != nil);
        assert(RUINValidatedThemeStoreURL([base stringByAppendingString:@"zh-Hant"]) != nil);
        assert(RUINValidatedThemeStoreURL(@"http://store.line.me/themeshop/product/313c6eb8-8584-4f5f-b849-b2b0c7e1c43d/ja") == nil);
        assert(RUINValidatedThemeStoreURL(@"https://store.line.me.attacker.example/themeshop/product/313c6eb8-8584-4f5f-b849-b2b0c7e1c43d/ja") == nil);
        assert(RUINValidatedThemeStoreURL(@"https://user@store.line.me/themeshop/product/313c6eb8-8584-4f5f-b849-b2b0c7e1c43d/ja") == nil);
        assert(RUINValidatedThemeStoreURL(@"https://store.line.me:8443/themeshop/product/313c6eb8-8584-4f5f-b849-b2b0c7e1c43d/ja") == nil);
        assert(RUINValidatedThemeStoreURL(@"https://store.line.me/themeshop/product/not-a-uuid/ja") == nil);
        assert(RUINValidatedThemeStoreURL([base stringByAppendingString:@"ja/extra"]) == nil);
        assert(RUINValidatedThemeStoreURL([base stringByAppendingString:@"ja?next=https://attacker.example"]) == nil);
        assert(RUINValidatedThemeStoreURL([base stringByAppendingString:@"ja#fragment"]) == nil);

        puts("check_theme_store_resolver: PASS");
    }
    return 0;
}
