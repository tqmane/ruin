/* From ruin/:
 xcrun --sdk macosx clang -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror \
   -DRUIN_THEME_STORE_DOWNLOAD_HOST_CHECK -I. src/themes/ThemeStoreDownload.m \
   tests/check_theme_store_download.m -framework Foundation \
   -o /tmp/check_theme_store_download && /tmp/check_theme_store_download
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ThemeFeatures.h"
#import "ThemeStoreDownload.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

NSString * const RUINThemeShopDownloadEnabledDefaultsKey = @"enableThemeDL";
void RUINThemeStoreDownloadSetTestEnabled(BOOL enabled);

@interface LineShopProductDetail : NSObject {
@public
    NSString *storedType;
    _Bool storedOwned;
    _Bool storedAvailable;
    NSString *storedPrice;
    NSString *storedButtonLabel;
    NSUInteger typeCalls;
    NSUInteger ownedCalls;
    NSUInteger availableCalls;
    NSUInteger priceCalls;
    NSUInteger buttonLabelCalls;
    NSUInteger readCalls;
}
- (NSString *)type;
- (_Bool)isOwned;
- (_Bool)isAvailableForMyself;
- (NSString *)priceInLineCoin;
- (NSString *)customDownloadButtonLabel;
- (void)read:(id)reader;
@end

@implementation LineShopProductDetail
- (NSString *)type { typeCalls++; return storedType; }
- (_Bool)isOwned { ownedCalls++; return storedOwned; }
- (_Bool)isAvailableForMyself { availableCalls++; return storedAvailable; }
- (NSString *)priceInLineCoin { priceCalls++; return storedPrice; }
- (NSString *)customDownloadButtonLabel { buttonLabelCalls++; return storedButtonLabel; }
- (void)read:(id)reader { (void)reader; readCalls++; }
@end

static LineShopProductDetail *Fixture(NSString *type)
{
    LineShopProductDetail *object = [LineShopProductDetail new];
    object->storedType = [type copy];
    object->storedOwned = NO;
    object->storedAvailable = NO;
    object->storedPrice = @"80";
    object->storedButtonLabel = @"native label";
    return object;
}

static void CheckUnchanged(LineShopProductDetail *object, NSString *expectedType)
{
    assert([object->storedType isEqualToString:expectedType]);
    assert(object->storedOwned == NO);
    assert(object->storedAvailable == NO);
    assert([object->storedPrice isEqualToString:@"80"]);
    assert([object->storedButtonLabel isEqualToString:@"native label"]);
}

static void CheckEncoding(Class cls, const char *selectorName, const char *expected)
{
    Method method = class_getInstanceMethod(cls, sel_registerName(selectorName));
    assert(method != NULL);
    assert(strcmp(method_getTypeEncoding(method), expected) == 0);
}

int main(void)
{
    @autoreleasepool {
        Class cls = objc_lookUpClass("LineShopProductDetail");
        assert(cls != Nil);
        CheckEncoding(cls, "type", "@16@0:8");
        CheckEncoding(cls, "isOwned", "B16@0:8");
        CheckEncoding(cls, "isAvailableForMyself", "B16@0:8");
        CheckEncoding(cls, "priceInLineCoin", "@16@0:8");
        CheckEncoding(cls, "customDownloadButtonLabel", "@16@0:8");
        CheckEncoding(cls, "read:", "v24@0:8@16");
        LineShopProductDetail *theme = Fixture(@"Theme");
        LineShopProductDetail *sticker = Fixture(@"sticker");
        RUINInstallThemeStoreDownload();
        NSDictionary *initial = RUINThemeStoreDownloadDiagnostics();
        assert([initial[@"hookStatus"] isEqual:@"installed"]);
        assert([initial[@"targetVersionMatches"] boolValue]);

        RUINThemeStoreDownloadSetTestEnabled(NO);
        assert(![theme isOwned]);
        assert(![theme isAvailableForMyself]);
        assert([[theme priceInLineCoin] isEqualToString:@"80"]);
        assert([[theme customDownloadButtonLabel] isEqualToString:@"native label"]);
        assert(theme->ownedCalls == 1 && theme->availableCalls == 1 &&
            theme->priceCalls == 1 && theme->buttonLabelCalls == 1 && theme->typeCalls == 0);
        CheckUnchanged(theme, @"Theme");

        RUINThemeStoreDownloadSetTestEnabled(YES);
        assert([theme isOwned]);
        assert([theme isAvailableForMyself]);
        assert([[theme priceInLineCoin] isEqualToString:@"0"]);
        assert([theme customDownloadButtonLabel] == nil);
        assert(theme->ownedCalls == 2 && theme->availableCalls == 2 &&
            theme->priceCalls == 2 && theme->buttonLabelCalls == 2 && theme->typeCalls == 4);
        CheckUnchanged(theme, @"Theme");

        assert(![sticker isOwned]);
        assert(![sticker isAvailableForMyself]);
        assert([[sticker priceInLineCoin] isEqualToString:@"80"]);
        assert([[sticker customDownloadButtonLabel] isEqualToString:@"native label"]);
        assert(sticker->ownedCalls == 1 && sticker->availableCalls == 1 &&
            sticker->priceCalls == 1 && sticker->buttonLabelCalls == 1 && sticker->typeCalls == 4);
        CheckUnchanged(sticker, @"sticker");

        id reader = @"fixture reader";
        [theme read:reader];
        [sticker read:reader];
        assert(theme->readCalls == 1 && sticker->readCalls == 1);
        assert(theme->typeCalls == 5 && sticker->typeCalls == 5);

        NSDictionary *diagnostics = RUINThemeStoreDownloadDiagnostics();
        assert([diagnostics[@"calls"][@"isOwned"] unsignedLongLongValue] == 3);
        assert([diagnostics[@"calls"][@"isAvailableForMyself"] unsignedLongLongValue] == 3);
        assert([diagnostics[@"calls"][@"priceInLineCoin"] unsignedLongLongValue] == 3);
        assert([diagnostics[@"calls"][@"customDownloadButtonLabel"] unsignedLongLongValue] == 3);
        assert([diagnostics[@"calls"][@"read"] unsignedLongLongValue] == 2);
        assert([diagnostics[@"projections"][@"isOwned"] unsignedLongLongValue] == 1);
        assert([diagnostics[@"projections"][@"isAvailableForMyself"] unsignedLongLongValue] == 1);
        assert([diagnostics[@"projections"][@"priceInLineCoin"] unsignedLongLongValue] == 1);
        assert([diagnostics[@"projections"][@"customDownloadButtonLabel"] unsignedLongLongValue] == 1);
        assert([diagnostics[@"postReadThemeObservations"] unsignedLongLongValue] == 1);
        assert([diagnostics[@"purchaseOrOrderCalls"] unsignedLongLongValue] == 0);
        assert(![diagnostics[@"downloadSuccessClaimed"] boolValue]);
        CheckUnchanged(theme, @"Theme");
        CheckUnchanged(sticker, @"sticker");
        puts("check_theme_store_download: PASS");
    }
    return 0;
}
