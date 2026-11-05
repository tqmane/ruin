%config(generator=internal);

#import "UnsendMarkerUI.h"
#import "UnsendOperation.h"
#import "MessageHistory.h"
#import "Features.h"
#import "SwiftFields.h"
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

/* Exact manifest-matching LINE 26.16.0 / 2026.1006.1718 metadata:
 _TtC17LineMessagingUIV219ChatTextMessageCell -> ChatBaseMessageCell:
 messageViewModel field 0x10ae9f458, ChatMessageViewModelProtocol? weak;
 contentContainerView 0x10ae9f248: ChatMessageContainerView;
 messageStatusView 0x10ae9f290: ChatMessageStatusView?.
 _TtC17LineMessagingUIV224ChatTextMessageViewModel -> ChatMessageViewModel:
 messageIdentifier 0x10ae9e6c4: LineSharedMessaging.MessageIdentifier?;
 server case 0x10aefaf60: MessageServerID; value 0x10aefaf88: Swift.Int64.
 FetchedModel.ID.wrappedValue (0x10af9833c) is AnyHashable, NOT assumed to
 be NSManagedObjectID. Probe reports its class without descriptions/values.
 Cell prepareForReuse v16@0:8 0x10449eef8; inherited base layoutSubviews
 v16@0:8 0x104480f90. Only the exact text-cell class is materialized/swizzled.
 Owning ChatViewController -chat @16@0:8 is the existing verified bridge.
 Resolve a permanent Message by typed server ID AND actual chat relationship,
 in that chat's own persistent store, then use RUINHistoryMessageKey.
 Never read/rewrite native text/attributed strings, mutate models, resize the
 native cell, invoke a Swift ABI function, or bind by visible label text.
 */

static BOOL UITargetMatches(void) {
    NSBundle *bundle = NSBundle.mainBundle; NSDictionary *info = bundle.infoDictionary;
    return ([bundle.bundleIdentifier isEqual:RUINTargetBundleIdentifier] ||
        [info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier]) &&
        [info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] && [info[@"CFBundleVersion"] isEqual:RUINTargetBuild];
}
static BOOL UIEnabled(void) { return UITargetMatches() && [NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey]; }
static NSString *UIServerNumber(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
    const char *type = [value objCType];
    if (!type || !type[0] || type[1]) return nil;
    if (!strchr("csilqCSILQ", type[0]) || (strchr("CSILQ", type[0]) && [value unsignedLongLongValue] > LLONG_MAX)) return nil;
    long long number = [value longLongValue];
    return number > 0 ? [NSString stringWithFormat:@"%lld", number] : nil;
}
static NSDictionary *UIResolveMessageKey(NSManagedObject *chat, NSString *server) {
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
            [candidate[@"chat"] isEqual:[chat valueForKey:@"mid"]]) key = candidate;
    }];
    return key;
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
@end
@implementation RUINUnsendMarkerRecord @end
static void UIClearBinding(RUINUnsendMarkerRecord *record) {
    record.model = nil; record.chat = nil; record.server = nil; record.key = nil; record.bindingPending = NO; record.generation++;
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

static const char *UICellClass = "_TtC17LineMessagingUIV219ChatTextMessageCell";
static const char *UIModelClass = "_TtC17LineMessagingUIV224ChatTextMessageViewModel";
static const char *UIChatControllerClass = "_TtC15LineMessagingUI18ChatViewController";
static char UIRecordKey, UIBadgeKey;
static NSHashTable<UICollectionViewCell *> *UICells;
static NSTimer *UITimer;
static NSArray *UIObservers;
static os_unfair_lock UIProbeLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary *UIProbe;
static BOOL UIHasModelProbe;
static atomic_uint_fast64_t UILayoutCalls, UIReuseCalls, UIBoundCells, UIUnresolvedCells, UIMarkerMatches, UIBadgesAdded, UIBadgesRemoved, UINoSpace, UIErrors;
static atomic_uint UIVisibleCount;
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
}
static id UIField(id object, const char *path) { return RUINCopySwiftField(object, path); }
static void UIObserveMetadata(UICollectionViewCell *cell) {
    NSMutableArray *paths = [NSMutableArray array];
    for (NSString *path in @[@"messageViewModel", @"messageViewModel.messageIdentifier", @"messageViewModel.messageIdentifier.server",
        @"messageViewModel.messageIdentifier.server.value", @"messageViewModel.message", @"messageViewModel.message.id",
        @"messageViewModel.message.id.wrappedValue", @"contentContainerView", @"messageStatusView", @"messageContentView"]) {
        id value = UIField(cell, path.UTF8String);
        NSArray *names = value ? RUINCopySwiftFieldNames(value) : @[];
        if (names.count > 64) names = [names subarrayWithRange:NSMakeRange(0, 64)];
        [paths addObject:@{@"path":path, @"present":@(value != nil), @"valueClass":value ? NSStringFromClass(object_getClass(value)) : @"",
            @"fieldNames":names ?: @[], @"isManagedObjectID":@([value isKindOfClass:NSManagedObjectID.class])}];
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
    id chat = ((id (*)(id, SEL))objc_msgSend)(controller, selector);
    return [chat isKindOfClass:NSManagedObject.class] ? chat : nil;
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
static void UIRefreshCell(UICollectionViewCell *cell) {
    if (object_getClass(cell) != objc_getClass(UICellClass)) return;
    if (!UICells) UICells = [NSHashTable weakObjectsHashTable]; [UICells addObject:cell];
    RUINUnsendMarkerRecord *record = UIRecord(cell);
    if (!UIEnabled() || !cell.window || cell.hidden || cell.alpha <= 0.01 || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        UIRemoveBadge(cell); UIClearBinding(record); return;
    }
    @try {
        id model = UIField(cell, "messageViewModel");
        if (model && !UIHasModelProbe) { UIObserveMetadata(cell); UIHasModelProbe = YES; }
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
        if (!RUINUnsendOperationHasRetainedMarker(record.key)) { UIRemoveBadge(cell); return; }
        atomic_fetch_add(&UIMarkerMatches, 1);
        UIView *bubble = UIField(cell, "contentContainerView"), *status = UIField(cell, "messageStatusView");
        if (object_getClass(bubble) != objc_getClass("_TtC17LineMessagingUIV224ChatMessageContainerView") ||
            ![status isKindOfClass:NSClassFromString(@"_TtC17LineMessagingUIV221ChatMessageStatusView")] ||
            ![bubble isDescendantOfView:cell.contentView] || ![status isDescendantOfView:cell.contentView] || status.hidden) { UIRemoveBadge(cell); return; }
        UILabel *badge = objc_getAssociatedObject(cell, &UIBadgeKey);
        if (!badge) {
            badge = [UILabel new]; badge.text = @"取消済"; badge.textAlignment = NSTextAlignmentCenter;
            badge.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2]; badge.adjustsFontForContentSizeCategory = YES;
            badge.textColor = UIColor.secondaryLabelColor; badge.backgroundColor = UIColor.tertiarySystemBackgroundColor;
            badge.layer.cornerRadius = 3; badge.clipsToBounds = YES; badge.userInteractionEnabled = NO;
            badge.isAccessibilityElement = YES; badge.accessibilityLabel = @"取消済"; badge.accessibilityIdentifier = @"RUINUnsendMarker";
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
        if (CGRectIsNull(frame)) { atomic_fetch_add(&UINoSpace, 1); UIRemoveBadge(cell); return; }
        badge.frame = frame;
        if (badge.superview != cell.contentView) { [cell.contentView addSubview:badge]; atomic_fetch_add(&UIBadgesAdded, 1); }
        [cell.contentView bringSubviewToFront:badge];
    } @catch (__unused NSException *exception) { atomic_fetch_add(&UIErrors, 1); UIRemoveBadge(cell); UIClearBinding(record); }
}
static void UIRefreshTracked(void) {
    NSUInteger visible = 0;
    for (UICollectionViewCell *cell in UICells.allObjects) { UIRefreshCell(cell); if (cell.window && !cell.hidden) visible++; }
    atomic_store(&UIVisibleCount, (unsigned int)visible);
    BOOL run = visible && UIEnabled() && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if (!run) { [UITimer invalidate]; UITimer = nil; }
    else if (!UITimer) {
        // The retained object is unchanged, so native layout may not rerun when
        // its sidecar marker arrives. Poll only weakly tracked visible cells.
        UITimer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) { UIRefreshTracked(); }];
        [NSRunLoop.mainRunLoop addTimer:UITimer forMode:NSRunLoopCommonModes];
    }
}
static void UINativeCallback(id object, NSUInteger index, void (^original)(void)) {
    if (!NSThread.isMainThread) { original(); return; }
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
            @try { UIRefreshCell(object); UIRefreshTracked(); }
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
    if (object_getClass(view) == objc_getClass(UICellClass)) { [UICells addObject:(id)view]; if (UIEnabled()) UIObserveMetadata((id)view); }
    for (UIView *child in view.subviews) UIScan(child, depth + 1, budget);
}
void RUINRefreshUnsendMarkerUI(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ RUINRefreshUnsendMarkerUI(); }); return; }
    if (!UICells) UICells = [NSHashTable weakObjectsHashTable];
    if (UITargetMatches()) {
        NSUInteger budget = 1600;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
            if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive)
                for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow && !window.hidden) UIScan(window, 0, &budget);
    }
    UIRefreshTracked();
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
        for (NSNotificationName name in @[NSUserDefaultsDidChangeNotification, UIApplicationDidBecomeActiveNotification, UIApplicationDidEnterBackgroundNotification])
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                usingBlock:^(__unused NSNotification *note) { dispatch_async(dispatch_get_main_queue(), ^{ RUINRefreshUnsendMarkerUI(); }); }]];
        UIObservers = [observers copy];
    }
    RUINRefreshUnsendMarkerUI();
}
NSDictionary *RUINUnsendMarkerUIDiagnostics(void) {
    os_unfair_lock_lock(&UIProbeLock); NSDictionary *probe = UIProbe ?: @{}; os_unfair_lock_unlock(&UIProbeLock);
    NSMutableArray *hooks = [NSMutableArray array]; NSArray *statuses = @[@"pending", @"version_gated", @"missing_or_encoding_mismatch", @"installed"];
    for (NSUInteger i = 0; i < 3; i++) [hooks addObject:@{@"selector":@(UIHooks[i].name), @"expectedEncoding":@"v16@0:8", @"status":statuses[atomic_load(&UIHooks[i].status)]}];
    return @{@"enabled":@(UIEnabled()), @"cellClass":@(UICellClass), @"hooks":hooks, @"layoutCalls":@(atomic_load(&UILayoutCalls)),
        @"reuseCalls":@(atomic_load(&UIReuseCalls)), @"visibleTrackedCells":@(atomic_load(&UIVisibleCount)), @"identityBindings":@(atomic_load(&UIBoundCells)),
        @"unresolvedBindings":@(atomic_load(&UIUnresolvedCells)), @"markerMatches":@(atomic_load(&UIMarkerMatches)),
        @"badgesAdded":@(atomic_load(&UIBadgesAdded)), @"badgesRemoved":@(atomic_load(&UIBadgesRemoved)), @"noSafeSpace":@(atomic_load(&UINoSpace)),
        @"inspectionErrors":@(atomic_load(&UIErrors)), @"fieldMetadataProbe":probe,
        @"binding":@"exact text cell/view model; typed MessageIdentifier.server.value; owning controller chat/context; permanent unique Message within actual chat/store; full History key marker query",
        @"label":@"取消済", @"nativeTextModified":@NO, @"nativeLayoutResized":@NO, @"pixelVerified":@NO,
        @"limits":@"text cells only; ambiguous/missing identity or occupied badge space stays native; reused cells wait for a different bound view model; one-second visible-cell polling handles sidecar arrival"};
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
