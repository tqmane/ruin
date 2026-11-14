#import "RetainedMediaViewer.h"

#import "../core/Localization.h"

#import <QuickLook/QuickLook.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface RUINRetainedPreviewItem : NSObject <QLPreviewItem>
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *role;
@end

@implementation RUINRetainedPreviewItem
- (NSURL *)previewItemURL { return self.URL; }
- (NSString *)previewItemTitle { return self.title; }
@end

@interface RUINRetainedPreviewDataSource : NSObject <QLPreviewControllerDataSource>
@property(nonatomic, copy) NSArray<RUINRetainedPreviewItem *> *items;
@end

@implementation RUINRetainedPreviewDataSource
- (NSInteger)numberOfPreviewItemsInPreviewController:(__unused QLPreviewController *)controller {
    return self.items.count;
}
- (id<QLPreviewItem>)previewController:(__unused QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return index >= 0 && (NSUInteger)index < self.items.count ? self.items[(NSUInteger)index] : nil;
}
@end

static char sRetainedPreviewDataSourceKey;

static NSArray<RUINRetainedPreviewItem *> *RUINValidatedPreviewItems(NSArray<NSDictionary *> *items) {
    NSSet<NSString *> *roles = [NSSet setWithArray:@[@"photo", @"video", @"audio", @"file", @"thumbnail", @"livePhoto"]];
    NSMutableArray<RUINRetainedPreviewItem *> *result = [NSMutableArray array];
    BOOL hasOriginal = NO;
    for (NSDictionary *item in items) if ([item isKindOfClass:NSDictionary.class] &&
        [@[@"photo", @"video"] containsObject:item[@"role"]]) hasOriginal = YES;
    for (NSDictionary *item in items) {
        NSString *role = [item isKindOfClass:NSDictionary.class] ? item[@"role"] : nil;
        if (![role isKindOfClass:NSString.class] || ![roles containsObject:role] ||
            (hasOriginal && [role isEqual:@"thumbnail"])) continue;
        NSURL *URL = item[@"URL"];
        NSNumber *byteCount = item[@"byteCount"];
        if (![URL isKindOfClass:NSURL.class] || !URL.isFileURL || !URL.path.length ||
            ![byteCount isKindOfClass:NSNumber.class] || byteCount.unsignedLongLongValue == 0) continue;
        BOOL isDirectory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:URL.path isDirectory:&isDirectory] || isDirectory) continue;

        RUINRetainedPreviewItem *previewItem = [RUINRetainedPreviewItem new];
        previewItem.URL = URL;
        previewItem.role = role;
        previewItem.title = [role isEqual:@"thumbnail"]
            ? RUINLocalizedString(@"media.preview_only") : RUINLocalizedString(@"menu.retained_media");
        if (![QLPreviewController canPreviewItem:previewItem]) continue;
        [result addObject:previewItem];
    }
    return result;
}

BOOL RUINPresentRetainedMediaViewer(UIViewController *source, NSArray<NSDictionary *> *items) {
    if (!NSThread.isMainThread || !source || !source.viewIfLoaded.window || source.isBeingDismissed ||
        source.isBeingPresented || source.presentedViewController ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        source.viewIfLoaded.window.windowScene.activationState != UISceneActivationStateForegroundActive) return NO;

    NSArray<RUINRetainedPreviewItem *> *previewItems = RUINValidatedPreviewItems(items);
    if (!previewItems.count) return NO;

    RUINRetainedPreviewDataSource *dataSource = [RUINRetainedPreviewDataSource new];
    dataSource.items = previewItems;
    QLPreviewController *preview = [QLPreviewController new];
    preview.dataSource = dataSource;
    objc_setAssociatedObject(preview, &sRetainedPreviewDataSourceKey, dataSource, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL previewOnly = previewItems.count == 1 && [previewItems.firstObject.role isEqual:@"thumbnail"];
    preview.title = RUINLocalizedString(previewOnly ? @"media.preview_only" : @"menu.retained_media");
    [source presentViewController:preview animated:YES completion:nil];
    return YES;
}
