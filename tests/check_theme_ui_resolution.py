#!/usr/bin/env python3
"""Run production URL completion/download guards and shop reason selection on Foundation."""
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
THEMES = ROOT / "src/themes"
SHIM = r'''
#import <Foundation/Foundation.h>
#import "ThemeFeatures.h"
#import "ThemeVersion.h"
#include <assert.h>
#include <stdio.h>
NSString * const RUINThemeErrorDomain = @"fixture.theme";
static NSString *RUINLocalizedString(NSString *key) { return key; }
static unsigned notifications, downloads, alerts;
static BOOL preference = YES;
static void (^resolution)(NSDictionary *, NSError *);
static RUINThemeDownloadCompletion downloadCompletion;
static void RUINResolveThemeStoreURL(NSString *text, void (^completion)(NSDictionary *, NSError *)) {
    assert(text.length && !resolution); resolution = [completion copy];
}
void RUINDownloadThemeByID(NSString *name, NSString *product, NSString *version, RUINThemeDownloadCompletion completion) {
    assert(name.length && product.length && version.length);
    downloads++; downloadCompletion = [completion copy];
}
static void RUINOpenDownloadedThemes(__unused id owner) { assert(NO); }
@interface UIAlertAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)title style:(NSInteger)style handler:(void (^)(UIAlertAction *))handler;
@end
@implementation UIAlertAction
+ (instancetype)actionWithTitle:(__unused NSString *)title style:(__unused NSInteger)style
    handler:(__unused void (^)(UIAlertAction *))handler { return [self new]; }
@end
enum { UIAlertControllerStyleAlert, UIAlertActionStyleDefault, UIAlertActionStyleCancel };
@interface UIAlertController : NSObject
+ (instancetype)alertControllerWithTitle:(NSString *)title message:(NSString *)message preferredStyle:(NSInteger)style;
- (void)addAction:(UIAlertAction *)action;
@end
@implementation UIAlertController
+ (instancetype)alertControllerWithTitle:(__unused NSString *)title message:(__unused NSString *)message
    preferredStyle:(__unused NSInteger)style { return [self new]; }
- (void)addAction:(__unused UIAlertAction *)action {}
@end
@interface RUINThemeSettingsViewController : NSObject
@property(nonatomic) BOOL visible;
- (void)updateAvailability;
- (BOOL)canDownload;
- (BOOL)isVisible;
- (void)showMessage:(NSString *)message title:(NSString *)title;
- (void)showError:(NSError *)error title:(NSString *)title;
- (void)presentViewController:(id)controller animated:(BOOL)animated completion:(void (^)(void))completion;
- (void)startDownloadWithName:(NSString *)name productID:(NSString *)productID version:(NSString *)version;
@end
'''
METHODS = r'''
@implementation RUINThemeSettingsViewController
- (void)updateAvailability {}
- (BOOL)canDownload { return preference && !gThemeUIDownloading; }
- (BOOL)isVisible { return self.visible; }
- (void)presentViewController:(__unused id)controller animated:(__unused BOOL)animated
    completion:(__unused void (^)(void))completion { assert(self.isVisible); alerts++; }
'''
CHECK = r'''
static void Drain(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ CFRunLoopStop(CFRunLoopGetMain()); });
    CFRunLoopRun();
}
static void Finish(NSDictionary *theme, NSError *error) {
    void (^completion)(NSDictionary *, NSError *) = resolution;
    resolution = nil;
    assert(completion); completion(theme, error); Drain();
}
static void Reset(void) {
    assert(!resolution && !downloadCompletion && !gThemeUIDownloading);
    notifications = downloads = alerts = 0; preference = YES;
}
int main(void) { @autoreleasepool {
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:RUINThemeUIDownloadChanged
        object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            assert(NSThread.isMainThread); notifications++;
        }];
    NSDictionary *valid = @{@"name":@"Fixture", @"productID":@"313c6eb8-8584-4f5f-b849-b2b0c7e1c43d", @"version":@"42"};
    RUINThemeSettingsViewController *owner = [RUINThemeSettingsViewController new];
    owner.visible = YES;
    Reset(); BeginResolution(owner);
    assert(gThemeUIDownloading && notifications == 1);
    preference = NO; Finish(valid, nil);
    assert(!gThemeUIDownloading && !gThemeUIDownloadName && notifications == 2 && downloads == 0 && alerts == 1);

    Reset(); BeginResolution(owner);
    NSMutableDictionary *invalid = [valid mutableCopy]; invalid[@"version"] = @"invalid";
    Finish(invalid, nil);
    assert(!gThemeUIDownloading && !gThemeUIDownloadName && notifications == 2 && downloads == 0 && alerts == 1);

    for (NSDictionary *invalidShape in @[@{}, @{@"name":NSNull.null}, @{@"name":@"Fixture",@"productID":@42,@"version":@"42"}]) {
        Reset(); BeginResolution(owner); Finish(invalidShape, nil);
        assert(!gThemeUIDownloading && !gThemeUIDownloadName && gThemeUIDownloadError);
        assert(notifications == 2 && downloads == 0 && alerts == 1);
    }
    Reset(); BeginResolution(owner); Finish(nil, nil);
    assert(!gThemeUIDownloading && notifications == 2 && gThemeUIDownloadError && downloads == 0);
    Reset(); BeginResolution(owner); Finish(valid, [NSError errorWithDomain:@"fixture" code:1 userInfo:nil]);
    assert(!gThemeUIDownloading && notifications == 2 && gThemeUIDownloadError && downloads == 0);

    // Close management and drop its external owner after confirmation. The
    // production resolver must preserve download intent, then release the VC.
    for (unsigned scenario = 0; scenario < 5; scenario++) {
        Reset(); __weak RUINThemeSettingsViewController *weakOwner;
        @autoreleasepool {
            RUINThemeSettingsViewController *temporary = [RUINThemeSettingsViewController new];
            temporary.visible = YES;
            weakOwner = temporary; BeginResolution(temporary);
            temporary.visible = NO;
        }
        assert(weakOwner);
        if (scenario == 2) preference = NO;
        @autoreleasepool {
            Finish(scenario == 3 ? invalid : valid,
                scenario == 1 ? [NSError errorWithDomain:@"fixture" code:1 userInfo:nil] : nil);
        }
        assert(!weakOwner && alerts == 0); // Retention ends at resolution/kickoff.
        if (scenario == 0 || scenario == 4) {
            assert(gThemeUIDownloading && notifications == 3 && downloads == 1);
            downloadCompletion(scenario == 0 ? [NSURL fileURLWithPath:@"/fixture.linetheme"] : nil,
                scenario == 4 ? [NSError errorWithDomain:@"fixture" code:1 userInfo:nil] : nil);
            downloadCompletion = nil; Drain();
            assert(!gThemeUIDownloading && notifications == 4 && alerts == 0);
            assert(gThemeUIDownloadSaved == (scenario == 0));
        } else {
            assert(!gThemeUIDownloading && !gThemeUIDownloadName && notifications == 2 && downloads == 0);
        }
    }

    Reset(); BeginResolution(owner); Finish(valid, nil);
    assert(gThemeUIDownloading && notifications == 3 && downloads == 1 && !gThemeUIDownloadError);
    downloadCompletion([NSURL fileURLWithPath:@"/fixture.linetheme"], nil); downloadCompletion = nil; Drain();
    assert(!gThemeUIDownloading && gThemeUIDownloadSaved && !gThemeUIDownloadError && notifications == 4);

    Reset(); BeginResolution(owner); Finish(valid, nil);
    downloadCompletion(nil, [NSError errorWithDomain:@"fixture" code:1 userInfo:nil]); downloadCompletion = nil; Drain();
    assert(!gThemeUIDownloading && !gThemeUIDownloadSaved && gThemeUIDownloadError && notifications == 4);
    for (unsigned sticker = 0; sticker < 2; sticker++) {
        for (int status = RUINThemeShopVersionGated; status <= RUINThemeShopRouterException; status++) {
            if (status == RUINThemeShopRouteAccepted) continue;
            NSDictionary *alert = ShopAlert(sticker, status);
            NSString *expected = status == RUINThemeShopVersionGated || status == RUINThemeShopRouterUnavailable
                ? @"shops.openUnavailable" : @"shops.openRejected";
            assert([alert[@"message"] isEqual:expected] && ![alert[@"message"] isEqual:alert[@"title"]]);
        }
    }
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    puts("PASS production URL progress, dismissed download intent, bounded screen retention, no detached alerts and shop reasons");
} return 0; }
'''


def extract(source, start, end):
    assert source.count(start) == source.count(end) == 1
    return source[source.index(start):source.index(end, source.index(start))]


def main():
    ui = (THEMES / "ThemeUI.m").read_text()
    shop = (THEMES / "ThemeShop.x").read_text()
    globals_ = extract(ui, "static NSNotificationName const RUINThemeUIDownloadChanged", "static NSString *RUINThemeUIString(")
    validation = extract(ui, "static NSError *RUINThemeUIError(", "static NSString *RUINThemeUITrim(")
    messages = extract(ui, "- (void)showMessage:", "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:")
    download = extract(ui, "- (void)startDownloadWithName:", "- (CGRect)menuRect:")
    resolve = extract(ui, "        RUINThemeSettingsViewController *owner = weakSelf;", "\n    }];\n    download.enabled = NO;")
    begin = '''static void BeginResolution(RUINThemeSettingsViewController *source) {
        __weak typeof(source) weakSelf = source;
        NSString *URLText = @"https://store.line.me/themeshop/product/313c6eb8-8584-4f5f-b849-b2b0c7e1c43d/ja";
    ''' + resolve + "\n}\n"
    status = extract(shop, "typedef NS_ENUM(int, RUINThemeShopStatus)", "static atomic_int gThemeShopStatus;")
    message = extract(shop, "    NSString *message = status == RUINThemeShopVersionGated", "    UIAlertController *alert = [UIAlertController alertControllerWithTitle:")
    title = shop.split("    UIAlertController *alert = [UIAlertController alertControllerWithTitle:", 1)[1].split("\n        message:message", 1)[0]
    shop_alert = "static NSDictionary *ShopAlert(BOOL sticker, RUINThemeShopStatus status) {\n" + message + '\nreturn @{@"title":' + title + ', @"message":message};\n}\n'
    for locale in ("ja", "en", "ko", "zh-Hans", "zh-Hant"):
        catalog = plistlib.loads((ROOT / "resources/RUINResources.bundle" / f"{locale}.lproj/Localizable.strings").read_bytes())
        for key in ("shops.openUnavailable", "shops.openRejected"):
            assert catalog[key] and all(catalog[key] != catalog[title] for title in
                ("スタンプショップを開けませんでした", "着せかえショップを開けませんでした")), (locale, key)
    with tempfile.TemporaryDirectory(prefix="ruin-theme-ui-resolution-") as temporary:
        directory = Path(temporary)
        fixture = directory / "check.m"
        fixture.write_text(SHIM + globals_ + validation + METHODS + messages + download + "\n@end\n" + begin + status + shop_alert + CHECK)
        executable = directory / "check"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11",
            "-Wall", "-Wextra", "-Werror", "-I", str(THEMES), str(fixture),
            str(THEMES / "ThemeVersion.m"), "-framework", "Foundation", "-o", str(executable)],
            cwd=ROOT, check=True, timeout=30)
        subprocess.run([str(executable)], cwd=ROOT, check=True, timeout=10)


if __name__ == "__main__":
    main()
