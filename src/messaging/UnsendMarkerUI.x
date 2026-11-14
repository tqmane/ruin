%config(generator=internal);

#import "TargetMetadata.h"
#import "MessagingPrivateAPI.h"
#import "UnsendMarkerUI.h"
#import "UnsendOperation.h"
#import "MessageHistory.h"
#if TARGET_OS_IPHONE
#import "RetainedMedia.h"
#import "RetainedMediaViewer.h"
#endif
#import "Features.h"
#import "SwiftFields.h"
#import "../core/Localization.h"
#import <CoreData/CoreData.h>
#import <CoreGraphics/CoreGraphics.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <limits.h>
#import <math.h>
#import <string.h>
#import <stdlib.h>
#import <time.h>

/* Native base message cells expose their view model, bubble and status through
 verified Swift field metadata. Bind by typed MessageIdentifier.server.value
 and the owning controller's actual chat/context/store, never visible text.
 Layout and message content remain native. A reuse generation seals async
 identity binding; cancelled media alone gains a standard-viewer tap target.
 */

static BOOL UITargetMatches(void) {
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
}
#if TARGET_OS_IPHONE
static atomic_bool UIOptionEnabled, UIRefreshQueued, UIScanRequested;
static BOOL UIEnabled(void) { return atomic_load_explicit(&UIOptionEnabled, memory_order_relaxed); }
static BOOL UIReadOption(void) { return UITargetMatches() && [NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey]; }
#else
static BOOL UIEnabled(void) { return UITargetMatches() && [NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey]; }
#endif
static NSString *UIServerNumber(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    const char *type = [value objCType];
    if (!type || !type[0] || type[1]) return nil;
    if (!strchr("csilqCSILQ", type[0]) || (strchr("CSILQ", type[0]) && [value unsignedLongLongValue] > LLONG_MAX)) return nil;
    long long number = [value longLongValue];
    return number > 0 ? [NSString stringWithFormat:@"%lld", number] : nil;
}
static NSDictionary *UIResolveMessageKeyAndVideo(NSManagedObject *chat, NSString *server, NSURL *videoURL) {
#if !TARGET_OS_IPHONE
    (void)videoURL;
#endif
    Class chatClass = objc_getClass("ManagedChat"), messageClass = objc_getClass("ManagedMessage");
    if (!chatClass || !messageClass || ![chat isKindOfClass:chatClass] || ![chat isKindOfClass:NSManagedObject.class] || !server) return @{};
    NSManagedObjectContext *context = chat.managedObjectContext;
    if (!context) return @{};
    __block NSDictionary *key = @{};
    [context performBlockAndWait:^{
        if (chat.isDeleted || chat.objectID.isTemporaryID || !chat.objectID.persistentStore ||
            chat.entity.attributesByName[@"mid"].attributeType != NSStringAttributeType) return;
        NSEntityDescription *entity = [NSEntityDescription entityForName:@"Message" inManagedObjectContext:context];
        NSRelationshipDescription *relationship = entity.relationshipsByName[@"chat"];
        if (entity.attributesByName[@"id"].attributeType != NSStringAttributeType || relationship.isToMany ||
            ![relationship.destinationEntity.name isEqual:chat.entity.name]) return;
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Message"];
        request.predicate = [NSPredicate predicateWithFormat:@"id == %@ AND chat == %@", server, chat];
        request.affectedStores = @[chat.objectID.persistentStore]; request.fetchLimit = 2;
        NSArray *rows = [context executeFetchRequest:request error:NULL];
        if (rows.count != 1 || ![rows.firstObject isKindOfClass:messageClass]) return;
        NSManagedObject *message = rows.firstObject;
        if (message.isDeleted || message.objectID.isTemporaryID || message.managedObjectContext != context ||
            message.objectID.persistentStore != chat.objectID.persistentStore) return;
        NSDictionary *candidate = RUINHistoryMessageKey(message);
        if ([candidate[@"kind"] isEqual:@"talk"] && [candidate[@"message"] isEqual:server] &&
            [candidate[@"chat"] isEqual:[chat valueForKey:@"mid"]]) {
            key = candidate;
#if TARGET_OS_IPHONE
            RUINObserveRetainedMedia(message, candidate);
            if (videoURL) RUINObserveRetainedVideoURL(message, candidate, videoURL);
#endif
        }
    }];
    return key;
}
static NSDictionary *UIResolveMessageKey(NSManagedObject *chat, NSString *server) {
    return UIResolveMessageKeyAndVideo(chat, server, nil);
}
// Reuse seal: an old weak view model cannot immediately repaint a recycled
// cell before native configuration binds another model. No message is kept.
@interface RUINUnsendMarkerRecord : NSObject
@property(nonatomic, weak) id model;
@property(nonatomic, weak) NSManagedObject *chat;
@property(nonatomic, copy) NSString *server;
@property(nonatomic, copy) NSDictionary *key;
@property(nonatomic, weak) id reusedModel;
@property(nonatomic) BOOL awaitingModelChange;
@property(nonatomic) BOOL bindingPending;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) CFTimeInterval lastMediaObservation;
@property(nonatomic) BOOL mediaObservationPending;
@property(nonatomic, copy) NSArray *mediaItems;
@property(nonatomic) BOOL archiveLookupPending;
@property(nonatomic) CFTimeInterval lastArchiveLookup;
@end
@implementation RUINUnsendMarkerRecord @end
static void UIClearBinding(RUINUnsendMarkerRecord *record) {
    record.model = nil; record.chat = nil; record.server = nil; record.key = nil; record.bindingPending = NO; record.mediaObservationPending = NO; record.lastMediaObservation = 0; record.generation++;
    record.mediaItems = nil; record.archiveLookupPending = NO; record.lastArchiveLookup = 0;
}
static void UISealReuse(RUINUnsendMarkerRecord *record, id oldModel) {
    UIClearBinding(record); record.reusedModel = oldModel; record.awaitingModelChange = YES;
}
static BOOL UIMayBind(RUINUnsendMarkerRecord *record, id model) {
    if (!model || (record.awaitingModelChange && record.reusedModel == model)) return NO;
    record.awaitingModelChange = NO; record.reusedModel = nil; return YES;
}
static CGRect UIBadgeCandidate(CGRect bounds, CGRect bubble, CGRect status, CGSize size, NSUInteger position) {
    if (CGRectIsEmpty(bounds) || CGRectIsEmpty(bubble) || CGRectIsEmpty(status) || size.width <= 0 || size.height <= 0 ||
        !isfinite(size.width) || !isfinite(size.height)) return CGRectNull;
    BOOL right = CGRectGetMidX(status) >= CGRectGetMidX(bubble);
    CGFloat edge = position ? (right ? MAX(CGRectGetMaxX(bubble), CGRectGetMaxX(status)) : MIN(CGRectGetMinX(bubble), CGRectGetMinX(status))) :
        (right ? CGRectGetMaxX(bubble) : CGRectGetMinX(bubble));
    CGRect frame = CGRectMake(right ? edge + 4 : edge - size.width - 4, CGRectGetMinY(bubble) + 1, ceil(size.width), ceil(size.height));
    if (!isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !CGRectContainsRect(bounds, frame) ||
        CGRectIntersectsRect(CGRectInset(bubble, -1, -1), frame) || CGRectIntersectsRect(CGRectInset(status, -1, -1), frame)) return CGRectNull;
    return frame;
}

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>

static const char *UICellClass = "_TtC17LineMessagingUIV219ChatBaseMessageCell";
static const char *UIModelClass = "_TtC17LineMessagingUIV220ChatMessageViewModel";
static const char *UIChatControllerClass = "_TtC15LineMessagingUI18ChatViewController";
static char UIRecordKey, UIBadgeKey, UIMediaButtonKey;
static NSHashTable<UICollectionViewCell *> *UICells;
static NSTimer *UITimer;
static dispatch_queue_t UIArchiveQueue;
static NSUInteger UIArchivePending;
static NSArray *UIObservers;
static os_unfair_lock UIProbeLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary *UIProbe;
static BOOL UIHasModelProbe, UIHasVideoModelProbe;
static atomic_uint_fast64_t UILayoutCalls, UIReuseCalls, UIBoundCells, UIUnresolvedCells, UIMarkerMatches, UIBadgesAdded, UIBadgesRemoved, UINoSpace, UIErrors;
static atomic_uint UIVisibleCount;
static atomic_uint_fast64_t UIRefreshNanoseconds, UIRefreshMaxNanoseconds, UIRefreshHistogram[16];
static atomic_uint_fast64_t UICellRefreshes, UITrackedPasses, UITrackedVisits, UIDisabledCallbacks;
static _Thread_local unsigned int UIHookDepth;
static void InitUILayout(Class cls);
static void InitUIMoveToWindow(Class cls);
static void InitUIReuse(Class cls);
typedef struct { const char *name; void (*initialize)(Class); atomic_int status; } UIHook;
static UIHook UIHooks[] = {
    {"layoutSubviews", InitUILayout, ATOMIC_VAR_INIT(0)},
    {"didMoveToWindow", InitUIMoveToWindow, ATOMIC_VAR_INIT(0)},
    {"prepareForReuse", InitUIReuse, ATOMIC_VAR_INIT(0)}
};
static RUINUnsendMarkerRecord *UIRecord(UICollectionViewCell *cell) {
    RUINUnsendMarkerRecord *record = objc_getAssociatedObject(cell, &UIRecordKey);
    if (!record) { record = [RUINUnsendMarkerRecord new]; objc_setAssociatedObject(cell, &UIRecordKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return record;
}
static void UIRemoveBadge(UICollectionViewCell *cell) {
    UILabel *badge = objc_getAssociatedObject(cell, &UIBadgeKey);
    if (badge.superview) { [badge removeFromSuperview]; atomic_fetch_add(&UIBadgesRemoved, 1); }
    UIView *mediaButton = objc_getAssociatedObject(cell, &UIMediaButtonKey);
    [mediaButton removeFromSuperview];
}
static id UIField(id object, const char *path) { return RUINCopySwiftField(object, path); }
static void UIObserveMetadata(UICollectionViewCell *cell) {
    const char *enabled = getenv("RUIN_ENABLE_RUNTIME_INSPECTOR");
    if (!enabled || strcmp(enabled, "1")) return;
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *path in @[@"messageViewModel", @"messageViewModel.messageIdentifier", @"messageViewModel.messageIdentifier.server",
        @"messageViewModel.messageIdentifier.server.value", @"messageViewModel.message", @"messageViewModel.message.id",
        @"messageViewModel.message.id.wrappedValue", @"contentContainerView", @"messageStatusView", @"messageContentView",
        @"messageViewModel.contentLoadStatus", @"messageViewModel.mediaAndDownloadURLs.media",
        @"messageViewModel.videoPlayItem.resolvedURL.videoMessage.url", @"messageViewModel.videoPlayItem.loadedURLInfo.url",
        @"messageViewModel.videoViewModel", @"messageContentView.viewModel",
        @"messageContentView.videoView", @"messageContentView.playerView", @"messageContentView.videoViewModel"]) {
        id value = UIField(cell, path.UTF8String);
        NSArray *names = value ? RUINCopySwiftFieldNames(value) : @[];
        if (names.count > 64) names = [names subarrayWithRange:NSMakeRange(0, 64)];
        [paths addObject:@{@"path":path, @"present":@(value != nil), @"valueClass":value ? NSStringFromClass(object_getClass(value)) : @"",
            @"fieldNames":names ?: @[], @"isManagedObjectID":@([value isKindOfClass:NSManagedObjectID.class]),
            @"isLocalURL":@([value isKindOfClass:NSURL.class] && [value isFileURL])}];
    }
    NSArray *names = RUINCopySwiftFieldNames(cell) ?: @[];
    if (names.count > 64) names = [names subarrayWithRange:NSMakeRange(0, 64)];
    NSDictionary *sample = @{@"cellClass":NSStringFromClass(object_getClass(cell)), @"cellFieldNames":names, @"paths":paths};
    os_unfair_lock_lock(&UIProbeLock); UIProbe = sample; os_unfair_lock_unlock(&UIProbeLock);
}
static UIViewController *UIOwnerController(UICollectionViewCell *cell) {
    Class cls = objc_getClass(UIChatControllerClass);
    UIResponder *next = cell;
    for (NSUInteger i = 0; next && i < 40; i++, next = next.nextResponder)
        if (cls && [next isKindOfClass:cls]) return (id)next;
    return nil;
}
static NSManagedObject *UIOwnerChat(UIViewController *controller) {
    SEL selector = sel_registerName("chat");
    Method getter = controller ? class_getInstanceMethod(object_getClass(controller), selector) : NULL;
    if (!getter || strcmp(method_getTypeEncoding(getter), "@16@0:8")) return nil;
    id chat = [(id<RUINMessagingChatOwner>)controller chat];
    return [chat isKindOfClass:NSManagedObject.class] ? chat : nil;
}
// The native media cell and its layout remain intact. Only a retained,
// cancelled asset gets a tap target over its existing bubble; normal messages
// keep LINE's native gestures/viewer. Reuse and each tap revalidate identity.
@interface RUINRetainedMediaButton : UIButton
@property(nonatomic, weak) UICollectionViewCell *messageCell;
@property(nonatomic, copy) NSDictionary *messageKey;
@property(nonatomic, strong) UIImageView *preview;
@property(nonatomic, strong) NSURL *previewURL;
@end
@implementation RUINRetainedMediaButton
- (void)openMedia {
    UICollectionViewCell *cell = self.messageCell;
    RUINUnsendMarkerRecord *record = cell ? UIRecord(cell) : nil;
    if (!cell.window || !UIEnabled() || ![record.key isEqual:self.messageKey] ||
        UIField(cell, "messageViewModel") != record.model ||
        ![UIServerNumber(UIField(record.model, "messageIdentifier.server.value")) isEqual:record.server] ||
        UIOwnerChat(UIOwnerController(cell)) != record.chat) return;
    RUINPresentRetainedMediaViewer(UIOwnerController(cell), RUINRetainedMediaItems(record.key));
}
@end

static BOOL UIHasNativeImage(UIView *view, UIView *bubble, NSUInteger depth) {
    if (!view || view.hidden || view.alpha <= 0.01 || depth > 16) return NO;
    if ([view isKindOfClass:UIImageView.class] && [(UIImageView *)view image]) {
        CGRect frame = [view convertRect:view.bounds toView:bubble];
        if (frame.size.width * frame.size.height >= bubble.bounds.size.width * bubble.bounds.size.height * 0.5)
            return YES;
    }
    for (UIView *child in view.subviews) if (UIHasNativeImage(child, bubble, depth + 1)) return YES;
    return NO;
}
static BOOL UIUpdateMedia(UICollectionViewCell *cell, UIView *bubble, NSDictionary *key, NSArray *items) {
    if (!items.count) return NO;
    RUINRetainedMediaButton *button = objc_getAssociatedObject(cell, &UIMediaButtonKey);
    if (!button) {
        button = [RUINRetainedMediaButton buttonWithType:UIButtonTypeCustom];
        button.preview = [UIImageView new]; button.preview.contentMode = UIViewContentModeScaleAspectFit;
        button.preview.userInteractionEnabled = NO; button.preview.clipsToBounds = YES;
        button.preview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [button addSubview:button.preview];
        [button addTarget:button action:@selector(openMedia) forControlEvents:UIControlEventTouchUpInside];
        button.accessibilityLabel = RUINLocalizedString(@"menu.retained_media");
        button.accessibilityIdentifier = @"RUINRetainedMedia";
        objc_setAssociatedObject(cell, &UIMediaButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSURL *previewURL = nil;
    for (NSString *role in @[@"photo", @"thumbnail"])
        for (NSDictionary *item in items) if (!previewURL && [item[@"role"] isEqual:role]) previewURL = item[@"URL"];
    BOOL nativeImage = UIHasNativeImage(bubble, bubble, 0);
    if (nativeImage) { button.preview.image = nil; button.previewURL = nil; }
    else if (![button.previewURL isEqual:previewURL]) {
        button.previewURL = previewURL;
        button.preview.image = previewURL ? [UIImage imageWithContentsOfFile:previewURL.path] : nil;
    }
    button.preview.hidden = nativeImage;
    button.messageKey = key; button.messageCell = cell;
    button.frame = [bubble convertRect:bubble.bounds toView:cell.contentView];
    button.preview.frame = button.bounds;
    if (button.superview != cell.contentView) [cell.contentView addSubview:button];
    [cell.contentView bringSubviewToFront:button];
    return YES;
}

static BOOL UIHasContentAt(UIView *view, UIView *host, UILabel *ownBadge, CGRect frame, NSUInteger depth, NSUInteger *budget) {
    if (view == ownBadge || view.hidden || view.alpha <= 0.01) return NO;
    if (!*budget || depth > 20) return YES;
    (*budget)--;
    if (view != host && !view.subviews.count) {
        // A bare, empty UIView paints nothing. Unknown/custom leaves count as
        // occupied; labels and controls are never matched by their text.
        UIColor *background = [view.backgroundColor resolvedColorWithTraitCollection:view.traitCollection];
        BOOL clear = (!background || CGColorGetAlpha(background.CGColor) <= 0.01) &&
            (!view.layer.backgroundColor || CGColorGetAlpha(view.layer.backgroundColor) <= 0.01);
        BOOL empty = object_getClass(view) == UIView.class && !view.layer.contents && clear &&
            view.layer.borderWidth == 0 && view.layer.shadowOpacity == 0;
        if (!empty && CGRectIntersectsRect([view convertRect:view.bounds toView:host], frame)) return YES;
    }
    for (UIView *child in view.subviews) if (UIHasContentAt(child, host, ownBadge, frame, depth + 1, budget)) return YES;
    return NO;
}
static BOOL UIMediaCell(UICollectionViewCell *cell) {
    for (NSString *name in @[@"_TtC17LineMessagingUIV220ChatImageMessageCell", @"_TtC17LineMessagingUIV220ChatVideoMessageCell",
        @"_TtC17LineMessagingUIV222ChatVideoMessageCellV2", @"_TtC17LineMessagingUIV220ChatAudioMessageCell",
        @"_TtC17LineMessagingUIV219ChatFileMessageCell"])
        if ([cell isKindOfClass:NSClassFromString(name)]) return YES;
    return NO;
}
static NSURL *UIResolvedVideoURL(UICollectionViewCell *cell, RUINUnsendMarkerRecord *record) {
    if (UIField(cell, "messageViewModel") != record.model) return nil;
    id model = record.model;
    if ([model isKindOfClass:NSClassFromString(@"_TtC15LineMessagingUI25ChatVideoMessageViewModel")]) {
        id URL = UIField(model, "mediaAndDownloadURLs.media");
        return [URL isKindOfClass:NSURL.class] && [URL isFileURL] ? URL : nil;
    }
    if ([model isKindOfClass:NSClassFromString(@"_TtC17LineMessagingUIV227ChatVideoMessageViewModelV2")] &&
        [UIField(model, "videoPlayItem.resolvedURL.videoMessage.messageID") isEqual:record.server])
        for (NSString *path in @[@"videoPlayItem.loadedURLInfo.url", @"videoPlayItem.resolvedURL.videoMessage.url"]) {
            id URL = UIField(model, path.UTF8String);
            if ([URL isKindOfClass:NSURL.class] && [URL isFileURL]) return URL;
        }
    return nil;
}
static void UIObserveVisibleMedia(UICollectionViewCell *cell, RUINUnsendMarkerRecord *record, BOOL force) {
    if (!UIEnabled() || !UIMediaCell(cell) || record.mediaObservationPending || !record.key.count ||
        (!force && NSProcessInfo.processInfo.systemUptime - record.lastMediaObservation < 1)) return;
    NSManagedObject *chat = record.chat;
    NSManagedObjectContext *context = chat.managedObjectContext;
    NSString *server = record.server;
    if (!context || !server) return;
    record.mediaObservationPending = YES; record.lastMediaObservation = NSProcessInfo.processInfo.systemUptime;
    NSURL *videoURL = [UIResolvedVideoURL(cell, record) copy];
    NSUInteger generation = record.generation;
    __weak RUINUnsendMarkerRecord *weakRecord = record;
    // ponytail: reuse the existing visible-cell heartbeat until LINE exposes a
    // verified common media-download completion callback. Only media cells are
    // re-resolved; UIKit never waits on their managed-object queue.
    [context performBlock:^{
        @try { UIResolveMessageKeyAndVideo(chat, server, videoURL); }
        @catch (__unused NSException *exception) { atomic_fetch_add(&UIErrors, 1); }
        dispatch_async(dispatch_get_main_queue(), ^{
            RUINUnsendMarkerRecord *latest = weakRecord;
            if (latest.generation == generation) latest.mediaObservationPending = NO;
        });
    }];
}
static void UIRefreshCell(UICollectionViewCell *cell);
static void UIRequestArchiveItems(UICollectionViewCell *cell, RUINUnsendMarkerRecord *record) {
    if (!cell.window || record.archiveLookupPending || UIArchivePending >= 128 ||
        NSProcessInfo.processInfo.systemUptime - record.lastArchiveLookup < 1.0) return;
    if (!UIArchiveQueue) UIArchiveQueue = dispatch_queue_create("com.ruin.marker-media-read",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    NSDictionary *key = [record.key copy];
    NSUInteger generation = record.generation;
    record.archiveLookupPending = YES; record.lastArchiveLookup = NSProcessInfo.processInfo.systemUptime; UIArchivePending++;
    __weak UICollectionViewCell *weakCell = cell;
    dispatch_async(UIArchiveQueue, ^{
        @autoreleasepool {
            NSArray *items = @[];
            @try { items = RUINRetainedMediaItems(key) ?: @[]; }
            @catch (__unused NSException *exception) { atomic_fetch_add(&UIErrors, 1); }
            dispatch_async(dispatch_get_main_queue(), ^{
                UIArchivePending--;
                UICollectionViewCell *current = weakCell;
                RUINUnsendMarkerRecord *latest = current ? objc_getAssociatedObject(current, &UIRecordKey) : nil;
                if (!latest || latest.generation != generation || ![latest.key isEqual:key]) return;
                latest.archiveLookupPending = NO; latest.lastArchiveLookup = NSProcessInfo.processInfo.systemUptime;
                BOOL changed = ![latest.mediaItems isEqualToArray:items];
                latest.mediaItems = items;
                if (changed && UIEnabled() && current.window) UIRefreshCell(current);
            });
        }
    });
}
static void UIRefreshCellImpl(UICollectionViewCell *cell) {
    atomic_fetch_add(&UICellRefreshes, 1);
    if (![cell isKindOfClass:objc_getClass(UICellClass)]) return;
    if (!UICells) UICells = [NSHashTable weakObjectsHashTable]; [UICells addObject:cell];
    RUINUnsendMarkerRecord *record = UIRecord(cell);
    if (!UIEnabled() || !cell.window || cell.hidden || cell.alpha <= 0.01 || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        UIRemoveBadge(cell); UIClearBinding(record); return;
    }
    @try {
        id model = UIField(cell, "messageViewModel");
        BOOL videoCell = [cell isKindOfClass:NSClassFromString(@"_TtC17LineMessagingUIV220ChatVideoMessageCell")] ||
            [cell isKindOfClass:NSClassFromString(@"_TtC17LineMessagingUIV222ChatVideoMessageCellV2")];
        if (model && (!UIHasModelProbe || (videoCell && !UIHasVideoModelProbe))) {
            UIObserveMetadata(cell); UIHasModelProbe = YES;
            if (videoCell) UIHasVideoModelProbe = YES;
        }
        Class modelClass = objc_getClass(UIModelClass);
        if (!modelClass || ![model isKindOfClass:modelClass] || !UIMayBind(record, model)) { UIRemoveBadge(cell); return; }
        NSString *server = UIServerNumber(UIField(model, "messageIdentifier.server.value"));
        UIViewController *owner = UIOwnerController(cell); NSManagedObject *chat = UIOwnerChat(owner);
        if (!server || !chat) { atomic_fetch_add(&UIUnresolvedCells, 1); UIRemoveBadge(cell); return; }
        if (record.model != model || record.chat != chat || ![record.server isEqual:server] || !record.key.count) {
            if (record.bindingPending && record.model == model && record.chat == chat && [record.server isEqual:server]) { UIRemoveBadge(cell); return; }
            UIClearBinding(record);
            NSManagedObjectContext *bindingContext = chat.managedObjectContext;
            if (!bindingContext) { atomic_fetch_add(&UIUnresolvedCells, 1); UIRemoveBadge(cell); return; }
            record.model = model; record.chat = chat; record.server = server; record.bindingPending = YES;
            NSUInteger generation = record.generation;
            __weak UICollectionViewCell *weakCell = cell; __weak id weakModel = model; __weak NSManagedObject *weakChat = chat;
            // Never make UIKit wait for a managed-object queue. Only the copied
            // identity key returns to main; a generation seals reuse/off edits.
            [bindingContext performBlock:^{
                NSDictionary *key = @{};
                @try { key = UIResolveMessageKey(chat, server); }
                @catch (__unused NSException *exception) { atomic_fetch_add(&UIErrors, 1); }
                dispatch_async(dispatch_get_main_queue(), ^{
                    UICollectionViewCell *current = weakCell; if (!current) return;
                    @try {
                        RUINUnsendMarkerRecord *latest = UIRecord(current);
                        if (latest.generation != generation) return;
                        latest.bindingPending = NO;
                        if (!UIEnabled() || !current.window || !weakModel || UIField(current, "messageViewModel") != weakModel ||
                            ![UIServerNumber(UIField(weakModel, "messageIdentifier.server.value")) isEqual:server] ||
                            !weakChat || UIOwnerChat(UIOwnerController(current)) != weakChat || !key.count) {
                            atomic_fetch_add(&UIUnresolvedCells, 1); UIRemoveBadge(current); UIClearBinding(latest); return;
                        }
                        latest.key = key; atomic_fetch_add(&UIBoundCells, 1); UIRefreshCell(current);
                    } @catch (__unused NSException *exception) { atomic_fetch_add(&UIErrors, 1); UIRemoveBadge(current); UIClearBinding(UIRecord(current)); }
                });
            }];
            UIRemoveBadge(cell); return;
        }
        UIObserveVisibleMedia(cell, record, NO);
        UIRequestArchiveItems(cell, record);
        NSArray *mediaItems = record.mediaItems;
        if (!mediaItems.count && !RUINUnsendOperationHasRetainedMarker(record.key)) { UIRemoveBadge(cell); return; }
        atomic_fetch_add(&UIMarkerMatches, 1);
        UIView *bubble = UIField(cell, "contentContainerView"), *status = UIField(cell, "messageStatusView");
        if (object_getClass(bubble) != objc_getClass("_TtC17LineMessagingUIV224ChatMessageContainerView") ||
            ![status isKindOfClass:NSClassFromString(@"_TtC17LineMessagingUIV221ChatMessageStatusView")] ||
            ![bubble isDescendantOfView:cell.contentView] || ![status isDescendantOfView:cell.contentView] || status.hidden) { UIRemoveBadge(cell); return; }
        BOOL retainedMedia = mediaItems.count && UIUpdateMedia(cell, bubble, record.key, mediaItems);
        UILabel *badge = objc_getAssociatedObject(cell, &UIBadgeKey);
        if (!badge) {
            NSString *markerLabel = RUINLocalizedString(@"media.unsent_badge");
            badge = [UILabel new]; badge.text = markerLabel; badge.textAlignment = NSTextAlignmentCenter;
            badge.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2]; badge.adjustsFontForContentSizeCategory = YES;
            badge.textColor = UIColor.secondaryLabelColor; badge.backgroundColor = UIColor.tertiarySystemBackgroundColor;
            badge.layer.cornerRadius = 3; badge.clipsToBounds = YES; badge.userInteractionEnabled = NO;
            badge.isAccessibilityElement = YES; badge.accessibilityLabel = markerLabel; badge.accessibilityIdentifier = @"RUINUnsendMarker";
            objc_setAssociatedObject(cell, &UIBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGSize textSize = [badge sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
        CGSize size = CGSizeMake(textSize.width + 8, textSize.height + 2);
        CGRect body = [bubble convertRect:bubble.bounds toView:cell.contentView], marks = [status convertRect:status.bounds toView:cell.contentView];
        CGRect frame = CGRectNull;
        for (NSUInteger i = 0; i < 2; i++) {
            CGRect candidate = UIBadgeCandidate(cell.contentView.bounds, body, marks, size, i); NSUInteger budget = 160;
            if (!CGRectIsNull(candidate) && !UIHasContentAt(cell.contentView, cell.contentView, badge, candidate, 0, &budget)) { frame = candidate; break; }
        }
        if (CGRectIsNull(frame) && retainedMedia && body.size.width >= size.width + 8 && body.size.height >= size.height + 8)
            frame = CGRectMake(CGRectGetMaxX(body) - size.width - 4, CGRectGetMinY(body) + 4, size.width, size.height);
        if (CGRectIsNull(frame)) { atomic_fetch_add(&UINoSpace, 1); UIRemoveBadge(cell); return; }
        badge.frame = frame;
        if (badge.superview != cell.contentView) { [cell.contentView addSubview:badge]; atomic_fetch_add(&UIBadgesAdded, 1); }
        [cell.contentView bringSubviewToFront:badge];
    } @catch (__unused NSException *exception) { atomic_fetch_add(&UIErrors, 1); UIRemoveBadge(cell); UIClearBinding(record); }
}
static void UIRefreshCell(UICollectionViewCell *cell) {
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    UIRefreshCellImpl(cell);
    uint64_t elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
    atomic_fetch_add(&UIRefreshNanoseconds, elapsed);
    uint64_t maximum = atomic_load(&UIRefreshMaxNanoseconds);
    while (elapsed > maximum && !atomic_compare_exchange_weak(&UIRefreshMaxNanoseconds, &maximum, elapsed)) {}
    unsigned bucket = 0; uint64_t limit = 1000;
    while (bucket < 15 && elapsed > limit) { bucket++; limit <<= 1; }
    atomic_fetch_add(&UIRefreshHistogram[bucket], 1);
}
static uint64_t UIRefreshP95UpperBound(void) {
    uint64_t count = atomic_load(&UICellRefreshes), sum = 0;
    if (!count) return 0;
    for (unsigned i = 0; i < 16; i++) {
        sum += atomic_load(&UIRefreshHistogram[i]);
        if (sum >= count - count / 20) return i == 15 ? atomic_load(&UIRefreshMaxNanoseconds) : (1000ULL << i);
    }
    return atomic_load(&UIRefreshMaxNanoseconds);
}
static void UIRefreshTracked(void);
static void UIStopHeartbeat(void) { [UITimer invalidate]; UITimer = nil; }
static void UIEnsureHeartbeat(void) {
    if (UITimer || !UIEnabled() || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UITimer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) { UIRefreshTracked(); }];
    [NSRunLoop.mainRunLoop addTimer:UITimer forMode:NSRunLoopCommonModes];
}
static void UIRefreshTracked(void) {
    if (!UIEnabled() || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        UIStopHeartbeat(); atomic_store(&UIVisibleCount, 0); return;
    }
    atomic_fetch_add(&UITrackedPasses, 1);
    NSUInteger visible = 0;
    for (UICollectionViewCell *cell in UICells.allObjects) {
        if (!cell.window || cell.hidden || cell.alpha <= 0.01) continue;
        atomic_fetch_add(&UITrackedVisits, 1); visible++; UIRefreshCell(cell);
    }
    atomic_store(&UIVisibleCount, (unsigned int)visible);
    if (!visible) UIStopHeartbeat(); else UIEnsureHeartbeat();
}
static void UINativeCallback(id object, NSUInteger index, void (^original)(void)) {
    if (!NSThread.isMainThread) { original(); return; }
    if (!UIEnabled()) {
        atomic_fetch_add(&UIDisabledCallbacks, 1);
        original();
        RUINUnsendMarkerRecord *record = objc_getAssociatedObject(object, &UIRecordKey);
        if (record) { UIRemoveBadge(object); UIClearBinding(record); }
        return;
    }
    BOOL outermost = UIHookDepth++ == 0;
    @try {
        if (index == 2) {
            @try { atomic_fetch_add(&UIReuseCalls, 1); UIRemoveBadge(object); UISealReuse(UIRecord(object), UIField(object, "messageViewModel")); }
            @catch (__unused NSException *exception) { atomic_fetch_add(&UIErrors, 1); }
        }
        original();
        if (index == 2) @try {
            if (!UIField(object, "messageViewModel")) UIRecord(object).reusedModel = nil;
        } @catch (__unused NSException *exception) { atomic_fetch_add(&UIErrors, 1); }
        if (outermost && index != 2 && NSThread.isMainThread) {
            if (index == 0) atomic_fetch_add(&UILayoutCalls, 1);
            @try { UIRefreshCell(object); if ([object window]) UIEnsureHeartbeat(); }
            @catch (__unused NSException *exception) { atomic_fetch_add(&UIErrors, 1); }
        }
    } @finally {
        if (index == 2) @try { UIRemoveBadge(object); } @catch (__unused NSException *exception) { atomic_fetch_add(&UIErrors, 1); }
        UIHookDepth--;
    }
}
%group RUINMarkerLayout
%hook RUINUnsendMarkerCell
- (void)layoutSubviews {
    UINativeCallback(self, 0, ^{ %orig; });
}
%end
%end
static void InitUILayout(Class cls) { %init(RUINMarkerLayout, RUINUnsendMarkerCell = cls); }
%group RUINMarkerWindow
%hook RUINUnsendMarkerCell
- (void)didMoveToWindow {
    UINativeCallback(self, 1, ^{ %orig; });
}
%end
%end
static void InitUIMoveToWindow(Class cls) { %init(RUINMarkerWindow, RUINUnsendMarkerCell = cls); }
%group RUINMarkerReuse
%hook RUINUnsendMarkerCell
- (void)prepareForReuse {
    UINativeCallback(self, 2, ^{ %orig; });
}
%end
%end
static void InitUIReuse(Class cls) { %init(RUINMarkerReuse, RUINUnsendMarkerCell = cls); }
static void UIScan(UIView *view, NSUInteger depth, NSUInteger *budget) {
    if (!view || !*budget || depth > 28) return;
    (*budget)--;
    if ([view isKindOfClass:objc_getClass(UICellClass)]) { [UICells addObject:(id)view]; if (UIEnabled()) UIObserveMetadata((id)view); }
    for (UIView *child in view.subviews) UIScan(child, depth + 1, budget);
}
void RUINRefreshUnsendMarkerUI(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ RUINRefreshUnsendMarkerUI(); }); return; }
    atomic_store(&UIOptionEnabled, UIReadOption());
    if (!UIEnabled()) {
        UIStopHeartbeat();
        for (UICollectionViewCell *cell in UICells.allObjects) {
            UIRemoveBadge(cell);
            RUINUnsendMarkerRecord *record = objc_getAssociatedObject(cell, &UIRecordKey);
            if (record) UIClearBinding(record);
        }
        atomic_store(&UIVisibleCount, 0);
        return;
    }
    if (!UICells) UICells = [NSHashTable weakObjectsHashTable];
    NSUInteger budget = 1600;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive)
            for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow && !window.hidden) UIScan(window, 0, &budget);
    UIRefreshTracked();
}
static void UIQueueRefresh(BOOL scan) {
    if (scan) atomic_store(&UIScanRequested, true);
    if (atomic_exchange(&UIRefreshQueued, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        atomic_store(&UIRefreshQueued, false);
        if (atomic_exchange(&UIScanRequested, false)) RUINRefreshUnsendMarkerUI();
        else UIRefreshTracked();
    });
}
void RUINInstallUnsendMarkerUI(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ RUINInstallUnsendMarkerUI(); }); return; }
    if (!UICells) UICells = [NSHashTable weakObjectsHashTable];
    Class cls = objc_getClass(UICellClass);
    if (UITargetMatches()) for (NSUInteger i = 0; i < 3; i++) {
        UIHook *hook = &UIHooks[i]; if (atomic_load(&hook->status) == 3) continue;
        SEL selector = sel_registerName(hook->name); Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        if (!method || strcmp(method_getTypeEncoding(method), "v16@0:8")) { atomic_store(&hook->status, 2); continue; }
        if (!method_getImplementation(method)) { atomic_store(&hook->status, 2); continue; }
        hook->initialize(cls);
        atomic_store(&hook->status, 3);
    }
    else for (NSUInteger i = 0; i < 3; i++) if (atomic_load(&UIHooks[i].status) != 3) atomic_store(&UIHooks[i].status, 1);
    if (!UIObservers) {
        NSMutableArray *observers = [NSMutableArray array];
        [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
            object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
                if (UIReadOption() != UIEnabled()) UIQueueRefresh(YES);
            }]];
        for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationDidEnterBackgroundNotification])
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                usingBlock:^(__unused NSNotification *note) { UIQueueRefresh(YES); }]];
        [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:RUINRetainedMediaDidChangeNotification
            object:nil queue:nil usingBlock:^(__unused NSNotification *note) { if (UIEnabled()) UIQueueRefresh(NO); }]];
        [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                if (!UIEnabled()) return;
                for (UICollectionViewCell *cell in UICells.allObjects) if (cell.window)
                    UIObserveVisibleMedia(cell, UIRecord(cell), YES);
            }]];
        UIObservers = [observers copy];
    }
    RUINRefreshUnsendMarkerUI();
}
NSDictionary *RUINUnsendMarkerUIDiagnostics(void) {
    os_unfair_lock_lock(&UIProbeLock); NSDictionary *probe = UIProbe ?: @{}; os_unfair_lock_unlock(&UIProbeLock);
    NSMutableArray *hooks = [NSMutableArray array]; NSArray *statuses = @[@"pending", @"version_gated", @"missing_or_encoding_mismatch", @"installed"];
    for (NSUInteger i = 0; i < 3; i++) [hooks addObject:@{@"selector":@(UIHooks[i].name), @"expectedEncoding":@"v16@0:8", @"status":statuses[atomic_load(&UIHooks[i].status)]}];
    return @{@"enabled":@(UIEnabled()), @"cellClass":@(UICellClass), @"hooks":hooks, @"layoutCalls":@(atomic_load(&UILayoutCalls)),
        @"cellRefreshes":@(atomic_load(&UICellRefreshes)), @"trackedRefreshPasses":@(atomic_load(&UITrackedPasses)),
        @"refreshElapsedNanoseconds":@(atomic_load(&UIRefreshNanoseconds)),
        @"refreshAverageNanoseconds":@(atomic_load(&UICellRefreshes) ? atomic_load(&UIRefreshNanoseconds) / atomic_load(&UICellRefreshes) : 0),
        @"refreshP95UpperBoundNanoseconds":@(UIRefreshP95UpperBound()), @"refreshMaxNanoseconds":@(atomic_load(&UIRefreshMaxNanoseconds)),
        @"trackedCellsVisited":@(atomic_load(&UITrackedVisits)), @"disabledCallbacks":@(atomic_load(&UIDisabledCallbacks)),
        @"reuseCalls":@(atomic_load(&UIReuseCalls)), @"visibleTrackedCells":@(atomic_load(&UIVisibleCount)), @"identityBindings":@(atomic_load(&UIBoundCells)),
        @"unresolvedBindings":@(atomic_load(&UIUnresolvedCells)), @"markerMatches":@(atomic_load(&UIMarkerMatches)),
        @"badgesAdded":@(atomic_load(&UIBadgesAdded)), @"badgesRemoved":@(atomic_load(&UIBadgesRemoved)), @"noSafeSpace":@(atomic_load(&UINoSpace)),
        @"inspectionErrors":@(atomic_load(&UIErrors)), @"fieldMetadataProbe":probe,
        @"binding":@"native base message cell/view model; typed MessageIdentifier.server.value; owning controller chat/context; permanent unique Message within actual chat/store; full History key marker query",
        @"label":@"取消済", @"nativeTextModified":@NO, @"nativeLayoutResized":@NO, @"pixelVerified":@NO,
        @"limits":@"normal/group message cells; ambiguous/missing identity or occupied badge space stays native; reused cells wait for a different bound view model; one-second visible-cell polling handles sidecar arrival"};
}
#endif

#if defined(RUIN_UNSEND_MARKER_UI_HOST_CHECK) && RUIN_UNSEND_MARKER_UI_HOST_CHECK
/* From ruin/: actual Core Data binding + actual read-only marker query, no UI:
 xcrun --sdk macosx clang -DRUIN_UNSEND_MARKER_UI_HOST_CHECK=1 -fobjc-arc \
   -fblocks -std=gnu11 -Wall -Wextra -Werror -I. Features.m MessageHistory.m \
   UnsendMarkerUI.m -framework Foundation -framework CoreData \
   -framework CoreGraphics -lsqlite3 -o /tmp/ruin-check-unsend-marker-ui
 /tmp/ruin-check-unsend-marker-ui
 The included backend exposes its existing private host-only image seam. Do
 not compile UnsendOperation.m a second time for this host check.
 */
#define RUIN_UNSEND_OPERATION_HOST_CHECK 1
#import "UnsendOperation.m"
#import <stdio.h>
@interface ManagedChat : NSManagedObject @end
@implementation ManagedChat @end
@interface ManagedMessage : NSManagedObject @end
@implementation ManagedMessage @end
static NSDictionary *UIFixtureInfo;
static NSURL *UIFixtureRoot;
static IMP UIFixtureDirectoriesOriginal;
static void UICheck(BOOL condition, NSString *reason) {
    if (!condition) @throw [NSException exceptionWithName:@"RUINUnsendMarkerUICheck" reason:reason userInfo:nil];
}
static NSDictionary *UIFixtureBundleInfo(id self, SEL selector) { (void)self; (void)selector; return UIFixtureInfo; }
static NSArray *UIFixtureDirectories(id self, SEL selector, NSSearchPathDirectory directory, NSSearchPathDomainMask mask) {
    if (directory == NSApplicationSupportDirectory && mask == NSUserDomainMask) return @[UIFixtureRoot];
    return ((id (*)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask))UIFixtureDirectoriesOriginal)(self, selector, directory, mask);
}
static NSAttributeDescription *UIFixtureAttribute(NSString *name) {
    NSAttributeDescription *attribute = [NSAttributeDescription new]; attribute.name = name;
    attribute.attributeType = NSStringAttributeType; attribute.optional = YES; return attribute;
}
static NSManagedObjectModel *UIFixtureModel(void) {
    NSEntityDescription *chat = [NSEntityDescription new], *message = [NSEntityDescription new];
    chat.name = @"Chat"; chat.managedObjectClassName = @"ManagedChat"; chat.properties = @[UIFixtureAttribute(@"mid")];
    NSRelationshipDescription *relationship = [NSRelationshipDescription new]; relationship.name = @"chat";
    relationship.destinationEntity = chat; relationship.maxCount = 1; relationship.optional = YES;
    message.name = @"Message"; message.managedObjectClassName = @"ManagedMessage";
    message.properties = @[UIFixtureAttribute(@"id"), relationship];
    NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[chat, message]; return model;
}
static NSManagedObject *UIFixtureChat(NSManagedObjectContext *context, NSString *mid, NSString *messageID) {
    __block NSManagedObject *chat;
    [context performBlockAndWait:^{
        chat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context]; [chat setValue:mid forKey:@"mid"];
        NSManagedObject *message = [NSEntityDescription insertNewObjectForEntityForName:@"Message" inManagedObjectContext:context];
        [message setValue:messageID forKey:@"id"]; [message setValue:chat forKey:@"chat"];
        UICheck([context save:NULL], @"fixture save failed");
    }]; return chat;
}
int main(void) {
    @autoreleasepool {
        int result = 0; NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id savedKeep = [defaults objectForKey:RUINKeepUnsentMessagesKey];
        Method infoMethod = class_getInstanceMethod(NSBundle.class, @selector(infoDictionary));
        Method directoriesMethod = class_getInstanceMethod(NSFileManager.class, @selector(URLsForDirectory:inDomains:));
        IMP originalInfo = NULL; NSMutableArray *coordinators = [NSMutableArray array], *contexts = [NSMutableArray array];
        UIFixtureRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        @try {
            originalInfo = method_setImplementation(infoMethod, (IMP)UIFixtureBundleInfo);
            UIFixtureDirectoriesOriginal = method_setImplementation(directoriesMethod, (IMP)UIFixtureDirectories);
            UIFixtureInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
            [defaults setBool:YES forKey:RUINKeepUnsentMessagesKey]; testImageMatches = YES; RUINInstallUnsendOperation();
            UICheck(UIEnabled(), @"exact signed target gate failed");
            NSDictionary *absent = @{@"store":@"absent", @"kind":@"talk", @"chat":@"absent", @"message":@"1"};
            UICheck(!RUINUnsendOperationHasRetainedMarker(absent) && ![NSFileManager.defaultManager fileExistsAtPath:MarkerURL().path], @"read-only lookup created an absent database");
            UICheck([UIServerNumber(@9007199254740993LL) isEqual:@"9007199254740993"] &&
                [UIServerNumber(@LLONG_MAX) isEqual:@"9223372036854775807"] &&
                !UIServerNumber(@YES) && !UIServerNumber(@12.5) && !UIServerNumber(@0) && !UIServerNumber(@(-1)) &&
                !UIServerNumber(@(ULLONG_MAX)) && !UIServerNumber(@"9007199254740993"), @"typed Int64 ID conversion accepted coercion/overflow or lost precision");
            UICheck([NSFileManager.defaultManager createDirectoryAtURL:UIFixtureRoot withIntermediateDirectories:YES attributes:nil error:NULL], @"fixture directory failed");
            for (NSUInteger i = 0; i < 2; i++) {
                NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:UIFixtureModel()];
                NSURL *url = [UIFixtureRoot URLByAppendingPathComponent:[NSString stringWithFormat:@"store-%lu.sqlite", (unsigned long)i]];
                UICheck([coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url options:nil error:NULL] != nil, @"fixture store failed");
                NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType]; context.persistentStoreCoordinator = coordinator;
                [coordinators addObject:coordinator]; [contexts addObject:context];
            }
            NSManagedObjectContext *a = contexts[0], *b = contexts[1];
            NSManagedObject *chatA = UIFixtureChat(a, @"private-chat-sentinel", @"9007199254740993");
            NSManagedObject *chatB = UIFixtureChat(b, @"private-chat-sentinel", @"9007199254740993");
            NSManagedObject *otherChat = UIFixtureChat(a, @"different-chat", @"9007199254740993");
            NSDictionary *keyA = UIResolveMessageKey(chatA, @"9007199254740993"), *keyB = UIResolveMessageKey(chatB, @"9007199254740993");
            NSDictionary *otherKey = UIResolveMessageKey(otherChat, @"9007199254740993");
            UICheck(keyA.count == 4 && keyB.count == 4 && otherKey.count == 4 && ![keyA[@"store"] isEqual:keyB[@"store"]], @"exact chat/store binding failed");
            UICheck(RetainedMarker(keyA, YES), @"fixture retention marker failed");
            int changes = sqlite3_total_changes(markerDatabase);
            UICheck(RUINUnsendOperationHasRetainedMarker(keyA) && !RUINUnsendOperationHasRetainedMarker(keyB) && !RUINUnsendOperationHasRetainedMarker(otherKey), @"marker identity leaked across store/chat");
            NSMutableDictionary *invalid = [keyA mutableCopy]; invalid[@"message"] = @"9223372036854775808";
            UICheck(!RUINUnsendOperationHasRetainedMarker(invalid), @"marker query accepted overflow");
            invalid = [keyA mutableCopy]; invalid[@"chat"] = [NSString stringWithCharacters:(unichar[]){'x',0,'y'} length:3];
            UICheck(!RUINUnsendOperationHasRetainedMarker(invalid) && sqlite3_total_changes(markerDatabase) == changes, @"query wrote data or accepted embedded NUL");
            os_unfair_lock_lock(&markerLock); sqlite3_close_v2(markerDatabase); markerDatabase = NULL; os_unfair_lock_unlock(&markerLock);
            UICheck(RUINUnsendOperationHasRetainedMarker(keyA) && markerDatabase == NULL, @"read-only reopen failed or published a writable connection");
            [a performBlockAndWait:^{
                NSManagedObject *duplicate = [NSEntityDescription insertNewObjectForEntityForName:@"Message" inManagedObjectContext:a];
                [duplicate setValue:@"9007199254740993" forKey:@"id"]; [duplicate setValue:chatA forKey:@"chat"]; UICheck([a save:NULL], @"duplicate fixture save failed");
            }];
            UICheck(UIResolveMessageKey(chatA, @"9007199254740993").count == 0, @"ambiguous live message selected a row");
            RUINUnsendMarkerRecord *record = [RUINUnsendMarkerRecord new]; NSObject *oldModel = [NSObject new], *newModel = [NSObject new];
            record.model = oldModel; record.key = keyA; UISealReuse(record, oldModel);
            UICheck(!record.key && !UIMayBind(record, oldModel) && UIMayBind(record, newModel), @"reuse retained stale identity or refused a new model");
            CGRect bounds = CGRectMake(0, 0, 375, 44), body = CGRectMake(44, 0, 155, 36), status = CGRectMake(203, 24, 28, 12);
            CGRect candidate = UIBadgeCandidate(bounds, body, status, CGSizeMake(36, 15), 0);
            UICheck(!CGRectIsNull(candidate) && CGRectContainsRect(bounds, candidate) && !CGRectIntersectsRect(body, candidate) && !CGRectIntersectsRect(status, candidate), @"incoming badge overlaps native composition");
            body = CGRectMake(220, 0, 140, 36); status = CGRectMake(184, 8, 30, 28);
            UICheck(CGRectIsNull(UIBadgeCandidate(bounds, body, status, CGSizeMake(36, 15), 0)) &&
                !CGRectIsNull(UIBadgeCandidate(bounds, body, status, CGSizeMake(36, 15), 1)) &&
                CGRectIsNull(UIBadgeCandidate(CGRectMake(0, 0, 10, 10), body, status, CGSizeMake(36, 15), 1)), @"occupied/narrow space was not rejected");
            [defaults setBool:NO forKey:RUINKeepUnsentMessagesKey]; UICheck(!UIEnabled() && !RUINUnsendOperationHasRetainedMarker(keyA), @"OFF did not disable marker reads");
            [defaults setBool:YES forKey:RUINKeepUnsentMessagesKey];
            UIFixtureInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"unsupported"};
            UICheck(!UIEnabled() && !RUINUnsendOperationHasRetainedMarker(keyA), @"unsupported build exposed marker");
        } @catch (NSException *exception) {
            fprintf(stderr, "RUIN UnsendMarkerUI check failed: %s\n", exception.reason.UTF8String ?: "unknown"); result = 1;
        } @finally {
            for (NSManagedObjectContext *context in contexts) [context performBlockAndWait:^{ [context reset]; }];
            for (NSPersistentStoreCoordinator *coordinator in coordinators)
                for (NSPersistentStore *store in coordinator.persistentStores) [coordinator removePersistentStore:store error:NULL];
            if (savedKeep) [defaults setObject:savedKeep forKey:RUINKeepUnsentMessagesKey]; else [defaults removeObjectForKey:RUINKeepUnsentMessagesKey];
            if (originalInfo) method_setImplementation(infoMethod, originalInfo);
            if (UIFixtureDirectoriesOriginal) method_setImplementation(directoriesMethod, UIFixtureDirectoriesOriginal);
            os_unfair_lock_lock(&markerLock); if (markerDatabase) sqlite3_close_v2(markerDatabase); markerDatabase = NULL; os_unfair_lock_unlock(&markerLock);
            [NSFileManager.defaultManager removeItemAtURL:UIFixtureRoot error:NULL];
        }
        if (!result) puts("RUIN UnsendMarkerUI native host checks passed"); return result;
    }
}
#endif
