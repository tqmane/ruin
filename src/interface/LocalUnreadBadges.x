%config(generator=internal);

#import "LocalUnreadBadges.h"
#import "Features.h"
#import <CoreData/CoreData.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>
#import <os/lock.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

NSString *const RUINClearViewedUnreadBadgesDefaultsKey = @"RUINClearViewedUnreadBadges";
static NSString *const ViewedBoundariesKey = @"RUINViewedUnreadBoundaries";

@protocol RUINUnreadMessage <NSObject>
- (BOOL)shouldIncrementChatMessagesUnread;
- (BOOL)isReceivedMessage;
- (BOOL)isSendMessage;
@end

// Called only on the managed object's queue. A store/account mismatch must
// never carry a viewed boundary into another login or a cloned store.
static NSString *BadgeScope(NSManagedObject *chat, NSString *account) {
    if (!account.length || chat.isDeleted || chat.objectID.isTemporaryID ||
        ![chat isKindOfClass:NSClassFromString(@"ManagedChat")]) return nil;
    NSPersistentStore *store = chat.objectID.persistentStore;
    NSArray *parts = store.URL.path.pathComponents;
    NSUInteger index = [parts indexOfObject:@"PrivateStore"];
    if (!store.URL.isFileURL || ![store.URL.lastPathComponent isEqual:@"Line.sqlite"] ||
        index == NSNotFound || index + 2 >= parts.count || ![parts[index + 2] isEqual:@"Messages"] ||
        (!([parts[index + 1] isEqual:[@"P_" stringByAppendingString:account]]) &&
         !([parts[index + 1] isEqual:[@"S_" stringByAppendingString:account]]))) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[account, store.URL.path,
        chat.objectID.URIRepresentation.absoluteString] options:0 error:NULL];
    if (!data || data.length > UINT_MAX) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *key = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [key appendFormat:@"%02x", digest[i]];
    return key;
}

static BOOL BadgeSchema(NSManagedObject *chat) {
    NSDictionary *attributes = chat.entity.attributesByName;
    return [attributes[@"lastReceivedMessageID"] attributeType] == NSInteger64AttributeType &&
        [attributes[@"readUpToMessageID"] attributeType] == NSInteger64AttributeType &&
        [attributes[@"unread"] attributeType] == NSInteger32AttributeType;
}

static BOOL ValidBadgeInteger(id value, unsigned long long minimum, unsigned long long maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    NSString *digits = [value stringValue];
    if (!digits.length || digits.length > 19) return NO;
    for (NSUInteger i = 0; i < digits.length; i++)
        if ([digits characterAtIndex:i] < '0' || [digits characterAtIndex:i] > '9') return NO;
    errno = 0;
    unsigned long long number = strtoull(digits.UTF8String, NULL, 10);
    return !errno && number >= minimum && number <= maximum;
}

static BOOL ValidBoundary(id value) { return ValidBadgeInteger(value, 1, LLONG_MAX); }

static NSNumber *ViewedBoundary(id marker) {
    return [marker isKindOfClass:NSDictionary.class] ? marker[@"boundary"] : marker;
}

static BOOL ValidViewedMarker(id marker) {
    if (![marker isKindOfClass:NSDictionary.class]) return ValidBoundary(marker);
    return ValidBoundary(marker[@"boundary"]) && ValidBadgeInteger(marker[@"nativeUnread"], 0, INT32_MAX) &&
        ValidBadgeInteger(marker[@"readCursor"], 0, LLONG_MAX);
}

static NSDictionary *ViewedSnapshot(NSManagedObject *chat) {
    if (!BadgeSchema(chat)) return nil;
    id boundary = [chat valueForKey:@"lastReceivedMessageID"];
    id unread = [chat valueForKey:@"unread"];
    id cursor = [chat valueForKey:@"readUpToMessageID"];
    if (!ValidBoundary(boundary) || !ValidBadgeInteger(unread, 0, INT32_MAX) ||
        !ValidBadgeInteger(cursor, 0, LLONG_MAX)) return nil;
    return @{@"boundary":boundary, @"nativeUnread":unread, @"readCursor":cursor};
}

typedef struct {
    const char *reason;
    NSInteger native, viewed, delta, tail, display;
} RUINTalkBadgeDecision;
static os_unfair_lock BadgeDecisionLock = OS_UNFAIR_LOCK_INIT;
static RUINTalkBadgeDecision LastBadgeDecision = {"not_checked", 0, -1, -1, -1, 0};
static NSInteger BadgeOutcome(NSInteger display, const char *reason, NSInteger native,
                              NSInteger viewed, NSInteger delta, NSInteger tail) {
    os_unfair_lock_lock(&BadgeDecisionLock);
    LastBadgeDecision = (RUINTalkBadgeDecision){reason, native, viewed, delta, tail, display};
    os_unfair_lock_unlock(&BadgeDecisionLock);
    return display;
}
static NSDictionary *BadgeCountDiagnostics(void) {
    os_unfair_lock_lock(&BadgeDecisionLock);
    RUINTalkBadgeDecision value = LastBadgeDecision;
    os_unfair_lock_unlock(&BadgeDecisionLock);
    return @{@"reason":@(value.reason), @"nativeUnread":@(value.native), @"viewedUnread":@(value.viewed),
        @"nativeDelta":@(value.delta), @"eligibleNewTail":@(value.tail), @"displayedUnread":@(value.display)};
}

// Only incoming, natively eligible IDs in a bounded interval are counted. No
// message/chat fields are changed, including pending receipt or read cursors.
static BOOL BadgeMessages(NSManagedObject *chat, long long lower, long long received, long long boundary,
                          NSInteger *total, NSInteger *newer, BOOL *foundLatest) {
    *total = 0; *newer = 0; *foundLatest = NO;
    NSManagedObjectContext *context = chat.managedObjectContext;
    NSEntityDescription *message = context.persistentStoreCoordinator.managedObjectModel.entitiesByName[@"Message"];
    NSRelationshipDescription *relationship = message.relationshipsByName[@"chat"];
    Class messageClass = NSClassFromString(@"ManagedMessage");
    if (message.attributesByName[@"id"].attributeType != NSInteger64AttributeType ||
        relationship.isToMany || relationship.destinationEntity != chat.entity || !messageClass) return NO;
    SEL selectors[] = {@selector(shouldIncrementChatMessagesUnread), @selector(isReceivedMessage), @selector(isSendMessage)};
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(*selectors); i++) {
        Method method = class_getInstanceMethod(messageClass, selectors[i]);
        const char *encoding = method ? method_getTypeEncoding(method) : NULL;
        if (!encoding || encoding[0] != @encode(BOOL)[0] || strcmp(encoding + 1, "16@0:8")) return NO;
    }
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Message"];
    request.predicate = [NSPredicate predicateWithFormat:@"chat == %@ AND id > %lld AND id <= %lld", chat, lower, received];
    request.affectedStores = @[chat.objectID.persistentStore];
    request.fetchLimit = 1001;
    request.returnsObjectsAsFaults = NO;
    NSError *error = nil;
    NSArray *messages = [context executeFetchRequest:request error:&error];
    if (error || !messages || messages.count > 1000) return NO;
    for (NSManagedObject *item in messages) {
        if (![item isKindOfClass:messageClass]) return NO;
        id<RUINUnreadMessage> candidate = (id)item;
        if ([candidate isReceivedMessage] && ![candidate isSendMessage]) {
            long long number = [[item valueForKey:@"id"] longLongValue];
            *foundLatest |= number == received;
            if ([candidate shouldIncrementChatMessagesUnread]) {
                (*total)++;
                if (number > boundary) (*newer)++;
            }
        }
    }
    return YES;
}

static NSInteger BadgeCount(NSManagedObject *chat, id viewed) {
    NSInteger native = [[chat valueForKey:@"unread"] integerValue];
    if (native <= 0 || !ValidViewedMarker(viewed))
        return BadgeOutcome(MAX(0, native), "native_or_invalid_marker", native, -1, -1, -1);
    id receivedValue = [chat valueForKey:@"lastReceivedMessageID"];
    id readValue = [chat valueForKey:@"readUpToMessageID"];
    long long boundary = ViewedBoundary(viewed).longLongValue;
    if (!ValidBoundary(receivedValue) || !ValidBadgeInteger(readValue, 0, LLONG_MAX))
        return BadgeOutcome(native, "invalid_live_cursor", native, -1, -1, -1);
    long long received = [receivedValue longLongValue], read = [readValue longLongValue];
    BOOL snapshot = [viewed isKindOfClass:NSDictionary.class];
    if (received < boundary || (!snapshot && read >= boundary))
        return BadgeOutcome(native, "cursor_rebased_or_native_read", native, -1, -1, -1);
    if (received == boundary) return BadgeOutcome(0, "viewed_boundary_unchanged", native, -1, -1, 0);

    NSInteger baseline = -1, delta = -1, tail = -1;
    const char *fallback = "legacy_full_window_unverified";
    if (snapshot) {
        baseline = [viewed[@"nativeUnread"] integerValue];
        delta = native - baseline;
        if (read != [viewed[@"readCursor"] longLongValue]) fallback = "snapshot_read_cursor_changed";
        else if (delta < 0) fallback = "snapshot_native_decreased";
        else if (delta > 1000) fallback = "snapshot_delta_unbounded";
        else {
            NSInteger total = 0;
            BOOL latest = NO;
            if (!BadgeMessages(chat, boundary, received, boundary, &total, &tail, &latest)) {
                tail = -1;
                fallback = "snapshot_tail_unavailable";
            }
            else if (!latest) fallback = "snapshot_latest_missing";
            else if (tail != delta) fallback = "snapshot_tail_delta_mismatch";
            else return BadgeOutcome(delta, "snapshot_delta", native, baseline, delta, tail);
        }
    }
    // Legacy markers never acquire an inferred baseline. Cursor/counter changes
    // may use the old exact-window proof; restored/incomplete history stays native.
    NSInteger total = 0, newer = 0;
    BOOL latest = NO;
    if (native <= 1000 && BadgeMessages(chat, read, received, boundary, &total, &newer, &latest) &&
        latest && total == native && newer > 0)
        return BadgeOutcome(newer, "full_window_verified", native, baseline, delta, tail);
    return BadgeOutcome(native, fallback, native, baseline, delta, tail);
}

// The caller owns the context queue. This read-only query also accounts for
// viewed chats whose cells are no longer visible after a restart or scrolling.
static NSUInteger BadgeCorrection(NSManagedObjectContext *context, NSPersistentStore *store,
                                  NSString *account, NSDictionary *boundaries) {
    if (!boundaries.count) return 0;
    NSUInteger correction = 0;
    @try {
        NSDictionary *attributes = context.persistentStoreCoordinator.managedObjectModel.entitiesByName[@"Chat"].attributesByName;
        if ([attributes[@"enable"] attributeType] != NSBooleanAttributeType ||
            [attributes[@"type"] attributeType] != NSInteger16AttributeType) return 0;
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Chat"];
        // Match LINE's ordinary-chat contribution; muted chats are included.
        // Other native contributions (including OpenChat) remain untouched.
        request.predicate = [NSPredicate predicateWithFormat:@"unread > 0 AND enable == YES AND type != 4"];
        request.affectedStores = @[store];
        request.fetchLimit = 1001;
        NSArray *chats = [context executeFetchRequest:request error:NULL];
        if (chats.count > 1000) return 0;
        for (NSManagedObject *chat in chats) {
            NSString *key = BadgeScope(chat, account);
            if (!key || !ValidViewedMarker(boundaries[key]) || !BadgeSchema(chat) || !RUINShouldSuppressReadForChat(chat)) continue;
            NSInteger native = [[chat valueForKey:@"unread"] integerValue];
            correction += (NSUInteger)MAX(0, native - BadgeCount(chat, boundaries[key]));
        }
    } @catch (__unused NSException *exception) { return 0; }
    return correction;
}

#if !defined(RUIN_LOCAL_UNREAD_HOST_CHECK)
#import "ChatCatalog.h"
#import "LocalUnreadTabBadge.h"
#import "SwiftFields.h"
#import "TargetMetadata.h"
#import <UIKit/UIKit.h>

@interface RUINBadgeCell : UITableViewCell
- (BOOL)render;
@end
@interface RUINBadgeChatController : UIViewController
- (id)chat;
@end

@interface RUINBadgeDisplay : NSObject
@property(nonatomic, weak) UIButton *button;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSAttributedString *attributedTitle;
@property(nonatomic) BOOL hidden;
@property(nonatomic) BOOL overridden;
@property(nonatomic) NSUInteger generation;
@end
@implementation RUINBadgeDisplay @end

static char DisplayKey;
static NSMutableDictionary *viewedBoundaries;
static NSHashTable *cells;
static BOOL installed;
static NSUInteger viewedChanges, displayChanges, rejected;
static __weak RUINBadgeChatController *visibleChat;
static __weak NSManagedObjectContext *sourceContext;
static NSManagedObjectContext *totalsContext;
static NSPersistentStore *totalsStore;
static NSString *totalsAccount;
static NSUInteger totalsGeneration;
static BOOL totalsScheduled, rowsScheduled;
static NSUInteger mainContextSnapshots, privateContextSnapshots;
static void RefreshCells(void);

static BOOL Enabled(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults boolForKey:RUINClearViewedUnreadBadgesDefaultsKey] &&
        [defaults boolForKey:RUINReadControlEnabledDefaultsKey];
}

static RUINBadgeDisplay *Display(UIView *cell) {
    RUINBadgeDisplay *record = objc_getAssociatedObject(cell, &DisplayKey);
    if (!record) {
        record = [RUINBadgeDisplay new];
        objc_setAssociatedObject(cell, &DisplayKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return record;
}

static void Restore(UIView *cell) {
    RUINBadgeDisplay *record = Display(cell);
    record.generation++;
    if (!record.overridden) return;
    UIButton *button = record.button;
    button.hidden = record.hidden;
    [button setTitle:record.title forState:UIControlStateNormal];
    [button setAttributedTitle:record.attributedTitle forState:UIControlStateNormal];
    record.overridden = NO;
}

static void OnChatQueue(NSManagedObject *chat, dispatch_block_t work) {
    NSManagedObjectContext *context = chat.managedObjectContext;
    if (context.concurrencyType == NSMainQueueConcurrencyType && NSThread.isMainThread) { mainContextSnapshots++; work(); }
    else if (context.concurrencyType == NSPrivateQueueConcurrencyType) { privateContextSnapshots++; [context performBlock:work]; }
}

void RUINRefreshLocalUnreadBadgeTotals(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ RUINRefreshLocalUnreadBadgeTotals(); }); return; }
    totalsGeneration++;
    if (!Enabled() || ![totalsAccount isEqual:RUINChatCatalogAccount()]) {
        RUINSetLocalUnreadTabBadgeCorrection(0);
        return;
    }
    if (totalsScheduled || !totalsContext || !totalsStore) return;
    totalsScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSUInteger generation = totalsGeneration;
        NSManagedObjectContext *context = totalsContext;
        NSPersistentStore *store = totalsStore;
        NSString *account = totalsAccount;
        NSDictionary *boundaries = [viewedBoundaries copy];
        if (!Enabled() || !context || !store || ![account isEqual:RUINChatCatalogAccount()]) { totalsScheduled = NO; return; }
        // A separate queue reads the same verified native store. It is never
        // saved, and no native context is waited on from the main thread.
        [context performBlock:^{
            [context reset];
            NSUInteger correction = BadgeCorrection(context, store, account, boundaries);
            dispatch_async(dispatch_get_main_queue(), ^{
                totalsScheduled = NO;
                if (generation == totalsGeneration && context == totalsContext && store == totalsStore &&
                    Enabled() && [account isEqual:RUINChatCatalogAccount()]) RUINSetLocalUnreadTabBadgeCorrection(correction);
                // At most one query runs, with one coalesced latest rerun.
                if (generation != totalsGeneration) RUINRefreshLocalUnreadBadgeTotals();
            });
        }];
    });
}

static void BindTotalsSource(NSManagedObjectContext *source, NSPersistentStoreCoordinator *coordinator,
                             NSPersistentStore *store, NSString *account) {
    sourceContext = source;
    if (totalsContext.persistentStoreCoordinator == coordinator &&
        totalsStore == store && [totalsAccount isEqual:account]) return;
    sourceContext = source;
    totalsStore = store;
    totalsAccount = [account copy];
    totalsContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    totalsContext.persistentStoreCoordinator = coordinator;
    totalsContext.undoManager = nil;
    totalsContext.name = @"RUINLocalUnreadDisplay";
    RUINSetLocalUnreadTabBadgeCorrection(0);
    RUINRefreshLocalUnreadBadgeTotals();
}

static void Apply(RUINBadgeCell *cell) {
    if (!NSThread.isMainThread) return;
    Restore(cell);
    [cells addObject:cell];
    if (!Enabled() || !cell.window) return;
    NSManagedObject *chat = RUINCopySwiftField(cell, "chatObject");
    UIButton *button = RUINCopySwiftField(cell, "unreadCountButton");
    if (![chat isKindOfClass:NSManagedObject.class] || ![button isKindOfClass:UIButton.class] ||
        ![button isDescendantOfView:cell]) return;
    NSString *account = RUINChatCatalogAccount();
    NSDictionary *boundaries = [viewedBoundaries copy];
    RUINBadgeDisplay *record = Display(cell);
    NSUInteger generation = record.generation;
    __weak RUINBadgeCell *weakCell = cell;
    OnChatQueue(chat, ^{
        __block NSInteger count = -1;
        __block BOOL validSource = NO;
        NSManagedObjectContext *owner = chat.managedObjectContext;
        NSPersistentStoreCoordinator *coordinator = owner.persistentStoreCoordinator;
        NSPersistentStore *store = chat.objectID.persistentStore;
        @try {
            NSString *key = BadgeScope(chat, account);
            validSource = key && BadgeSchema(chat);
            if (validSource && RUINShouldSuppressReadForChat(chat) && ValidViewedMarker(boundaries[key]))
                count = BadgeCount(chat, boundaries[key]);
        } @catch (__unused NSException *exception) { count = -1; }
        dispatch_async(dispatch_get_main_queue(), ^{
            RUINBadgeCell *current = weakCell;
            if (!current || !current.window || record.generation != generation || !Enabled() ||
                ![account isEqual:RUINChatCatalogAccount()] || RUINCopySwiftField(current, "chatObject") != chat ||
                RUINCopySwiftField(current, "unreadCountButton") != button) return;
            if (validSource) BindTotalsSource(owner, coordinator, store, account);
            if (count < 0) return;
            record.button = button;
            record.hidden = button.hidden;
            record.title = [button titleForState:UIControlStateNormal];
            record.attributedTitle = [button attributedTitleForState:UIControlStateNormal];
            record.overridden = YES;
            if (count == 0) button.hidden = YES;
            else if (!button.hidden) {
                NSString *title = [NSString localizedStringWithFormat:@"%ld", (long)count];
                [button setTitle:title forState:UIControlStateNormal];
                if (record.attributedTitle) {
                    NSMutableAttributedString *text = [record.attributedTitle mutableCopy];
                    [text replaceCharactersInRange:NSMakeRange(0, text.length) withString:title];
                    [button setAttributedTitle:text forState:UIControlStateNormal];
                }
            }
            displayChanges++;
        });
    });
}

static void RefreshCells(void) {
    for (RUINBadgeCell *cell in cells.allObjects) Apply(cell);
}

static void DiscoverCells(UIView *view, Class cellClass, NSUInteger *budget) {
    if (!view || !*budget) return;
    (*budget)--;
    if ([view isKindOfClass:cellClass]) [cells addObject:view];
    for (UIView *child in view.subviews) DiscoverCells(child, cellClass, budget);
}

static void Remember(RUINBadgeChatController *controller) {
    if (!Enabled() || !controller.isViewLoaded || !controller.view.window) return;
    NSManagedObject *chat = [controller chat];
    if (![chat isKindOfClass:NSManagedObject.class]) return;
    NSString *account = RUINChatCatalogAccount();
    __weak RUINBadgeChatController *weakController = controller;
    OnChatQueue(chat, ^{
        __block NSString *key;
        __block NSDictionary *snapshot;
        NSManagedObjectContext *owner = chat.managedObjectContext;
        NSPersistentStoreCoordinator *coordinator = owner.persistentStoreCoordinator;
        NSPersistentStore *store = chat.objectID.persistentStore;
        @try {
            if (BadgeSchema(chat) && RUINShouldSuppressReadForChat(chat)) {
                key = BadgeScope(chat, account);
                snapshot = ViewedSnapshot(chat);
            }
        } @catch (__unused NSException *exception) { key = nil; }
        void (^commit)(void) = ^{
            RUINBadgeChatController *current = weakController;
            if (!current.viewIfLoaded.window || [current chat] != chat || !Enabled() ||
                ![account isEqual:RUINChatCatalogAccount()] || !key || !ValidViewedMarker(snapshot)) return;
            if ([viewedBoundaries[key] isEqual:snapshot]) return;
            // Only RUIN's display snapshot persists. No native DB setter,
            // mark-read command, notification, or network request is used.
            if (viewedBoundaries.count >= 2048 && !viewedBoundaries[key])
                [viewedBoundaries removeObjectForKey:viewedBoundaries.allKeys.firstObject];
            viewedBoundaries[key] = snapshot;
            [NSUserDefaults.standardUserDefaults setObject:viewedBoundaries forKey:ViewedBoundariesKey];
            viewedChanges++;
            BindTotalsSource(owner, coordinator, store, account);
            RefreshCells();
            RUINRefreshLocalUnreadBadgeTotals();
        };
        if (NSThread.isMainThread) commit(); else dispatch_async(dispatch_get_main_queue(), commit);
    });
}

%group RUINLocalBadgeCells
%hook RUINBadgeCell
- (BOOL)render {
    Restore((id)self);
    BOOL result = %orig;
    Apply((id)self);
    return result;
}
- (void)didMoveToWindow { Restore((id)self); %orig; Apply((id)self); }
- (void)prepareForReuse { Restore((id)self); %orig; }
%end
%end

%group RUINLocalBadgeVisits
%hook RUINBadgeChatController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    visibleChat = (id)self;
    Remember((id)self);
}
- (void)viewWillDisappear:(BOOL)animated {
    Remember((id)self);
    if (visibleChat == (id)self) visibleChat = nil;
    %orig;
}
%end
%end

static BOOL MethodMatches(Class cls, SEL selector, const char *encoding) {
    const char *path = cls ? class_getImageName(cls) : NULL;
    NSString *owner = path ? [NSString stringWithUTF8String:path].stringByResolvingSymlinksInPath : nil;
    NSString *host = NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath;
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    return host.length && [owner isEqual:host] && method && !strcmp(method_getTypeEncoding(method), encoding);
}

void RUINInstallLocalUnreadBadges(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ RUINInstallLocalUnreadBadges(); }); return; }
    if (!RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary)) return;
    if (!viewedBoundaries) {
        viewedBoundaries = [NSMutableDictionary dictionary];
        NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:ViewedBoundariesKey];
        for (id key in saved) {
            if ([key isKindOfClass:NSString.class] && [key length] == CC_SHA256_DIGEST_LENGTH * 2 &&
                ValidViewedMarker(saved[key]) && viewedBoundaries.count < 2048) viewedBoundaries[key] = [saved[key] copy];
        }
        cells = [NSHashTable weakObjectsHashTable];
        for (NSNotificationName name in @[NSManagedObjectContextObjectsDidChangeNotification, NSManagedObjectContextDidSaveNotification,
            @"kNLNotificationKeyUnreadCount", @"unreadMessageCountDidUpdate"])
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *notification) {
                id changed = notification.object;
                BOOL nativeCounter = [notification.name isEqual:@"kNLNotificationKeyUnreadCount"] ||
                    [notification.name isEqual:@"unreadMessageCountDidUpdate"];
                // Never make a native Core Data posting queue wait for UIKit.
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ((!nativeCounter && changed != sourceContext) || !Enabled() || rowsScheduled) return;
                    rowsScheduled = YES;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                        rowsScheduled = NO;
                        RefreshCells();
                        RUINRefreshLocalUnreadBadgeTotals();
                    });
                });
            }];
    }
    if (!installed) {
        Class cell = NSClassFromString(@"LineChatTabUI.ChatListCell");
        Class chat = NSClassFromString(@"LineMessagingUI.ChatViewController");
        if (!MethodMatches(cell, @selector(render), "B16@0:8") ||
            !MethodMatches(cell, @selector(didMoveToWindow), "v16@0:8") ||
            !MethodMatches(cell, @selector(prepareForReuse), "v16@0:8") ||
            !MethodMatches(chat, @selector(chat), "@16@0:8") ||
            !MethodMatches(chat, @selector(viewDidAppear:), "v20@0:8B16") ||
            !MethodMatches(chat, @selector(viewWillDisappear:), "v20@0:8B16")) { rejected++; return; }
        %init(RUINLocalBadgeCells, RUINBadgeCell=cell);
        %init(RUINLocalBadgeVisits, RUINBadgeChatController=chat);
        installed = YES;
        // UIKit can restore the Talk tab before didBecomeActive installs the
        // hooks. Capture those existing cells once; never scan on layout.
        NSUInteger budget = 1200;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows)
                if (!window.hidden) DiscoverCells(window, cell, &budget);
        }
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) { Remember(visibleChat); }];
    }
    RUINInstallLocalUnreadTabBadge();
    RefreshCells();
    RUINRefreshLocalUnreadBadgeTotals();
}

NSDictionary *RUINLocalUnreadBadgesDiagnostics(void) {
    return @{@"installed":@(installed), @"enabled":@(Enabled()), @"viewedChanges":@(viewedChanges),
        @"displayChanges":@(displayChanges), @"rejected":@(rejected),
        @"mainContextSnapshots":@(mainContextSnapshots), @"privateContextSnapshots":@(privateContextSnapshots),
        @"trackedCells":@(cells.count),
        @"countPolicy":BadgeCountDiagnostics(),
        @"tab":RUINLocalUnreadTabBadgeDiagnostics(),
        @"scope":@"chat_list_and_talk_tab_display_only", @"nativeDataWritten":@NO, @"readReceiptsSent":@NO};
}
#endif
