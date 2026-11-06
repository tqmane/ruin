%config(generator=internal);

#import "ChatCatalog.h"
#import "../core/Features.h"
#import "../core/LINEPrivateCalls.h"
#import "../core/TargetMetadata.h"
#import "../platform/BundleIdentity.h"

#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <string.h>

static const NSUInteger RUINChatCatalogLimit = 10000;
static NSString *const RUINChatCatalogSuite = @"group.com.linecorp.line";
static const char *const RUINOneOnOneEncoding = "B16@0:8";

typedef NS_ENUM(NSInteger, RUINChatCatalogSchema) {
    RUINChatCatalogSchemaUnknown,
    RUINChatCatalogSchemaTalk,
    RUINChatCatalogSchemaStandaloneUser,
    RUINChatCatalogSchemaUnifiedGroup,
    RUINChatCatalogSchemaSquare
};

typedef NS_ENUM(NSInteger, RUINChatCatalogInstallStatus) {
    RUINChatCatalogInstallNotRequested,
    RUINChatCatalogInstallTargetMismatch,
    RUINChatCatalogInstallIdentityUnavailable,
    RUINChatCatalogInstallABIMismatch,
    RUINChatCatalogInstallReady
};

@interface RUINChatCatalogContextSnapshot : NSObject
@property(nonatomic, strong) NSManagedObjectContext *context;
@property(nonatomic) RUINChatCatalogSchema schema;
@property(nonatomic, copy) NSArray<NSDictionary *> *chats;
@property(nonatomic, copy) NSArray<NSDictionary *> *squares;
@property(nonatomic, copy) NSArray<NSDictionary *> *users;
@property(nonatomic, copy) NSArray<NSDictionary *> *groups;
@end
@implementation RUINChatCatalogContextSnapshot
@end

static os_unfair_lock gChatCatalogLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gChatCatalogInstallLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<NSManagedObjectContext *> *gChatCatalogContexts;
static RUINChatCatalogInstallStatus gChatCatalogInstallStatus = RUINChatCatalogInstallNotRequested;
static BOOL gChatCatalogInstalled;
static atomic_uint_fast64_t gChatCatalogFetches = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gChatCatalogLoads = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gChatCatalogItems = ATOMIC_VAR_INIT(0);

static NSString *RUINCurrentChatCatalogAccount(void)
{
    id value = [[[NSUserDefaults alloc] initWithSuiteName:RUINChatCatalogSuite] objectForKey:@"mid"];
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] != 33 ||
        ![(NSString *)value hasPrefix:@"u"]) return nil;
    NSString *mid = value;
    for (NSUInteger index = 1; index < mid.length; index++) {
        unichar character = [mid characterAtIndex:index];
        if (!((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f'))) return nil;
    }
    return [mid copy];
}

NSString *RUINChatCatalogAccount(void)
{
    return RUINCurrentChatCatalogAccount() ?: @"";
}

static BOOL RUINStoreURLMatchesAccount(NSURL *url, NSString *account)
{
    if (!url.isFileURL || account.length != 33) return NO;
    NSArray<NSString *> *parts = url.URLByStandardizingPath.path.pathComponents;
    NSString *expected = [@"S_" stringByAppendingString:account];
    NSUInteger found = NSNotFound;
    for (NSUInteger index = 0; index + 2 < parts.count; index++) {
        if (![parts[index] isEqualToString:@"PrivateStore"]) continue;
        if (found != NSNotFound || ![parts[index + 1] isEqualToString:expected]) return NO;
        found = index;
    }
    return found != NSNotFound;
}

static BOOL RUINContextMatchesAccount(NSManagedObjectContext *context, NSString *account)
{
    if (!context || (context.concurrencyType != NSPrivateQueueConcurrencyType &&
                     context.concurrencyType != NSMainQueueConcurrencyType)) return NO;
    NSPersistentStoreCoordinator *coordinator = context.persistentStoreCoordinator;
    NSArray<NSPersistentStore *> *stores = coordinator.persistentStores;
    if (stores.count == 0) return NO;
    for (NSPersistentStore *store in stores)
        if (!RUINStoreURLMatchesAccount(store.URL, account)) return NO;
    return YES;
}

static BOOL RUINEntityHasAttributes(NSEntityDescription *entity, NSDictionary<NSString *, NSNumber *> *types)
{
    if (!entity) return NO;
    for (NSString *name in types) {
        NSAttributeDescription *attribute = entity.attributesByName[name];
        if (!attribute || attribute.attributeType != (NSAttributeType)types[name].integerValue) return NO;
    }
    return YES;
}

static BOOL RUINEntityHasClass(NSEntityDescription *entity, NSString *className)
{
    if (![entity.managedObjectClassName isEqualToString:className]) return NO;
    Class cls = NSClassFromString(className);
    return cls && [cls isSubclassOfClass:NSManagedObject.class];
}

static NSDictionary<NSString *, NSNumber *> *RUINTalkUserTypes(void)
{
    return @{@"mid": @(NSStringAttributeType), @"name": @(NSStringAttributeType),
        @"customName": @(NSStringAttributeType), @"pictureURL": @(NSStringAttributeType),
        @"pictureStatus": @(NSStringAttributeType), @"profileImage": @(NSStringAttributeType),
        @"statusUpdatedAt": @(NSDateAttributeType)};
}

static BOOL RUINLegacyTalkUserEntity(NSEntityDescription *entity)
{
    if (!RUINEntityHasClass(entity, @"ManagedUser") ||
        !RUINEntityHasAttributes(entity, RUINTalkUserTypes())) return NO;
    NSAttributeDescription *snapshot = entity.attributesByName[@"profileSnapshotTimestamp"];
    return !snapshot;
}

static BOOL RUINStandaloneUserEntity(NSEntityDescription *entity)
{
    if (!RUINEntityHasClass(entity, @"ManagedUser") ||
        !RUINEntityHasAttributes(entity, RUINTalkUserTypes())) return NO;
    NSAttributeDescription *snapshot = entity.attributesByName[@"profileSnapshotTimestamp"];
    return snapshot && snapshot.attributeType == NSInteger64AttributeType;
}

static RUINChatCatalogSchema RUINSchemaForModel(NSManagedObjectModel *model)
{
    NSDictionary<NSString *, NSEntityDescription *> *entities = model.entitiesByName;
    NSEntityDescription *chat = entities[@"Chat"];
    if (RUINEntityHasClass(chat, @"ManagedSquareChat") && RUINEntityHasAttributes(chat, @{
        @"mid": @(NSStringAttributeType), @"name": @(NSStringAttributeType),
        @"chatImageOBSHash": @(NSStringAttributeType), @"enable": @(NSBooleanAttributeType),
        @"lastUpdated": @(NSDateAttributeType)})) return RUINChatCatalogSchemaSquare;

    NSEntityDescription *user = entities[@"User"];
    if (RUINEntityHasClass(chat, @"ManagedChat") && RUINEntityHasAttributes(chat, @{
        @"mid": @(NSStringAttributeType), @"enable": @(NSBooleanAttributeType),
        @"type": @(NSInteger16AttributeType), @"lastUpdated": @(NSDateAttributeType),
        @"sortOrder": @(NSInteger16AttributeType)}) && RUINLegacyTalkUserEntity(user)) {
        NSRelationshipDescription *members = chat.relationshipsByName[@"members"];
        if (members && members.destinationEntity == user)
            return RUINChatCatalogSchemaTalk;
    }

    if (RUINStandaloneUserEntity(user)) return RUINChatCatalogSchemaStandaloneUser;

    NSEntityDescription *group = entities[@"UnifiedGroup"];
    if (RUINEntityHasClass(group, @"ManagedUnifiedGroup") && RUINEntityHasAttributes(group, @{
        @"id": @(NSStringAttributeType), @"name": @(NSStringAttributeType),
        @"pictureStatus": @(NSStringAttributeType), @"enable": @(NSBooleanAttributeType)}))
        return RUINChatCatalogSchemaUnifiedGroup;
    return RUINChatCatalogSchemaUnknown;
}

#if !defined(RUIN_CHAT_CATALOG_HOST_CHECK)
static BOOL RUINRequestMatchesSchema(NSFetchRequest *request, RUINChatCatalogSchema schema,
                                    NSManagedObjectModel *model)
{
    if (![request isKindOfClass:NSFetchRequest.class]) return NO;
    NSString *name = request.entity.name ?: request.entityName;
    NSString *expectedClass = nil;
    switch (schema) {
        case RUINChatCatalogSchemaTalk:
            if ([name isEqualToString:@"Chat"]) expectedClass = @"ManagedChat";
            else if ([name isEqualToString:@"User"]) expectedClass = @"ManagedUser";
            break;
        case RUINChatCatalogSchemaStandaloneUser:
            if ([name isEqualToString:@"User"]) expectedClass = @"ManagedUser";
            break;
        case RUINChatCatalogSchemaUnifiedGroup:
            if ([name isEqualToString:@"UnifiedGroup"]) expectedClass = @"ManagedUnifiedGroup";
            break;
        case RUINChatCatalogSchemaSquare:
            if ([name isEqualToString:@"Chat"]) expectedClass = @"ManagedSquareChat";
            break;
        default: return NO;
    }
    NSEntityDescription *entity = model.entitiesByName[name];
    return expectedClass && entity && (!request.entity || request.entity == entity) &&
        [entity.managedObjectClassName isEqualToString:expectedClass];
}
#endif

#if !defined(RUIN_CHAT_CATALOG_HOST_CHECK)
static void RUINCaptureChatCatalogContext(NSManagedObjectContext *context, NSFetchRequest *request)
{
    NSString *account = RUINCurrentChatCatalogAccount();
    if (!account || !RUINContextMatchesAccount(context, account)) return;
    NSManagedObjectModel *model = context.persistentStoreCoordinator.managedObjectModel;
    RUINChatCatalogSchema schema = RUINSchemaForModel(model);
    if (!RUINRequestMatchesSchema(request, schema, model)) return;
    if (![RUINCurrentChatCatalogAccount() isEqualToString:account]) return;

    os_unfair_lock_lock(&gChatCatalogLock);
    if (!gChatCatalogContexts) gChatCatalogContexts = [NSHashTable weakObjectsHashTable];
    [gChatCatalogContexts addObject:context];
    os_unfair_lock_unlock(&gChatCatalogLock);
    atomic_fetch_add_explicit(&gChatCatalogFetches, 1, memory_order_relaxed);
}
#endif

static NSArray<NSManagedObjectContext *> *RUINCapturedChatContexts(void)
{
    os_unfair_lock_lock(&gChatCatalogLock);
    NSArray *contexts = gChatCatalogContexts.allObjects ?: @[];
    os_unfair_lock_unlock(&gChatCatalogLock);
    return contexts;
}

static id RUINCatalogValue(NSManagedObject *object, NSString *key, NSAttributeType type)
{
    if (!object || object.isDeleted || object.entity.attributesByName[key].attributeType != type) return nil;
    @try {
        id value = [object valueForKey:key];
        return [value conformsToProtocol:@protocol(NSCopying)] ? [value copy] : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL RUINCatalogNameIsSafe(NSString *name, NSString *identifier)
{
    return name.length && identifier.length &&
        [name rangeOfString:identifier options:NSCaseInsensitiveSearch].location == NSNotFound;
}

static BOOL RUINCatalogObjectIsInContext(NSManagedObject *object, NSManagedObjectContext *context,
                                         NSString *account)
{
    return [object isKindOfClass:NSManagedObject.class] && object.managedObjectContext == context &&
        !object.isDeleted && !object.objectID.isTemporaryID &&
        RUINStoreURLMatchesAccount(object.objectID.persistentStore.URL, account);
}

static NSArray<NSManagedObject *> *RUINFetchCatalogObjects(NSManagedObjectContext *context,
    NSString *entityName, NSPredicate *predicate, NSString *sortKey)
{
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entityName];
    request.resultType = NSManagedObjectResultType;
    request.includesPendingChanges = NO;
    request.fetchLimit = RUINChatCatalogLimit;
    request.predicate = predicate;
    if (sortKey.length) request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:sortKey ascending:NO]];
    NSError *error = nil;
    return [context executeFetchRequest:request error:&error] ?: @[];
}

static BOOL RUINManagedChatIsOneOnOne(NSManagedObject *chat, BOOL *value)
{
    SEL selector = @selector(isOneOnOneChat);
    Method method = class_getInstanceMethod(object_getClass(chat), selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, RUINOneOnOneEncoding) != 0) return NO;
    @try {
        *value = [(id<RUINLINEManagedChatCalls>)chat isOneOnOneChat];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static NSArray<NSDictionary *> *RUINReadTalkChats(NSManagedObjectContext *context, NSString *account)
{
    NSArray *objects = RUINFetchCatalogObjects(context, @"Chat",
        [NSPredicate predicateWithFormat:@"enable == YES"], @"lastUpdated");
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:MIN(objects.count, RUINChatCatalogLimit)];
    Class chatClass = NSClassFromString(@"ManagedChat");
    for (id value in objects) {
        if (!chatClass || ![value isKindOfClass:chatClass] || !RUINCatalogObjectIsInContext(value, context, account)) continue;
        NSDictionary *identity = RUINIdentityForObject(value);
        NSString *mid = [identity[@"identifier"] isKindOfClass:NSString.class] ? [identity[@"identifier"] copy] : nil;
        NSDate *updated = RUINCatalogValue(value, @"lastUpdated", NSDateAttributeType);
        BOOL oneOnOne = NO;
        if (![identity[@"kind"] isEqualToString:@"chat"] || mid.length == 0 || !updated ||
            !RUINManagedChatIsOneOnOne(value, &oneOnOne)) continue;
        [rows addObject:@{@"mid":mid, @"oneOnOne":@(oneOnOne), @"updated":updated}];
    }
    return [rows copy];
}

static NSDictionary *RUINSquareItem(NSManagedObject *object, NSManagedObjectContext *context,
                                     NSString *account)
{
    Class squareClass = NSClassFromString(@"ManagedSquareChat");
    if (!squareClass || ![object isKindOfClass:squareClass] ||
        !RUINCatalogObjectIsInContext(object, context, account)) return nil;
    NSDictionary *identity = RUINIdentityForObject(object);
    NSString *mid = [identity[@"identifier"] isKindOfClass:NSString.class] ? [identity[@"identifier"] copy] : nil;
    NSString *name = [identity[@"displayName"] isKindOfClass:NSString.class] ? [identity[@"displayName"] copy] : nil;
    NSDate *updated = RUINCatalogValue(object, @"lastUpdated", NSDateAttributeType);
    if (![identity[@"kind"] isEqualToString:@"squareChat"] || !RUINCatalogNameIsSafe(name, mid) || !updated) return nil;
    NSMutableDictionary *item = [@{@"readKey":[@"squareChat:" stringByAppendingString:mid],
        @"aliasKey":[@"squareChat:" stringByAppendingString:mid], @"name":name,
        @"kind":@"square", @"updated":updated} mutableCopy];
    NSString *imageHash = RUINCatalogValue(object, @"chatImageOBSHash", NSStringAttributeType);
    if (imageHash.length) item[@"pictureStatus"] = imageHash;
    return [item copy];
}

static NSArray<NSDictionary *> *RUINReadSquareChats(NSManagedObjectContext *context, NSString *account)
{
    NSArray *objects = RUINFetchCatalogObjects(context, @"Chat",
        [NSPredicate predicateWithFormat:@"enable == YES"], @"lastUpdated");
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:MIN(objects.count, RUINChatCatalogLimit)];
    for (id value in objects) {
        NSDictionary *item = RUINSquareItem(value, context, account);
        if (item) [rows addObject:item];
    }
    return [rows copy];
}

static NSArray<NSDictionary *> *RUINReadUsers(NSManagedObjectContext *context,
    NSString *account, NSArray<NSString *> *identifiers, BOOL standalone)
{
    if (identifiers.count == 0) return @[];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"mid IN %@", identifiers];
    NSArray *objects = RUINFetchCatalogObjects(context, @"User", predicate, nil);
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:objects.count];
    for (id value in objects) {
        if (![value isKindOfClass:NSManagedObject.class] || !RUINCatalogObjectIsInContext(value, context, account)) continue;
        NSDictionary *identity = RUINIdentityForObject(value);
        NSString *identifier = [identity[@"identifier"] isKindOfClass:NSString.class] ? [identity[@"identifier"] copy] : nil;
        NSString *name = [identity[@"displayName"] isKindOfClass:NSString.class] ? [identity[@"displayName"] copy] : nil;
        if (![identity[@"kind"] isEqualToString:@"user"] || !RUINCatalogNameIsSafe(name, identifier)) continue;
        NSMutableDictionary *row = [@{@"identifier":identifier, @"name":name,
            @"sourcePriority":@(standalone ? 1 : 0)} mutableCopy];
        NSString *pictureURL = RUINCatalogValue(value, @"pictureURL", NSStringAttributeType);
        NSString *pictureStatus = RUINCatalogValue(value, @"pictureStatus", NSStringAttributeType);
        NSDate *profileUpdated = RUINCatalogValue(value, @"statusUpdatedAt", NSDateAttributeType);
        if (pictureURL.length) row[@"pictureURL"] = pictureURL;
        if (pictureStatus.length) row[@"pictureStatus"] = pictureStatus;
        if (profileUpdated) row[@"profileUpdated"] = profileUpdated;
        [rows addObject:[row copy]];
    }
    return [rows copy];
}

static NSArray<NSDictionary *> *RUINReadGroups(NSManagedObjectContext *context,
    NSString *account, NSArray<NSString *> *identifiers)
{
    if (identifiers.count == 0) return @[];
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"enable == YES AND id IN %@", identifiers];
    NSArray *objects = RUINFetchCatalogObjects(context, @"UnifiedGroup", predicate, nil);
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:objects.count];
    for (id value in objects) {
        if (![value isKindOfClass:NSManagedObject.class] || !RUINCatalogObjectIsInContext(value, context, account)) continue;
        NSDictionary *identity = RUINIdentityForObject(value);
        NSString *identifier = [identity[@"identifier"] isKindOfClass:NSString.class] ? [identity[@"identifier"] copy] : nil;
        NSString *name = [identity[@"displayName"] isKindOfClass:NSString.class] ? [identity[@"displayName"] copy] : nil;
        if (![identity[@"kind"] isEqualToString:@"group"] || !RUINCatalogNameIsSafe(name, identifier)) continue;
        NSMutableDictionary *row = [@{@"identifier":identifier, @"name":name} mutableCopy];
        NSString *pictureStatus = RUINCatalogValue(value, @"pictureStatus", NSStringAttributeType);
        if (pictureStatus.length) row[@"pictureStatus"] = pictureStatus;
        [rows addObject:[row copy]];
    }
    return [rows copy];
}

static NSArray<NSString *> *RUINSortedIdentifiers(NSArray<RUINChatCatalogContextSnapshot *> *snapshots,
                                                    BOOL users)
{
    NSMutableDictionary<NSString *, NSDate *> *values = [NSMutableDictionary dictionary];
    for (RUINChatCatalogContextSnapshot *snapshot in snapshots) {
        for (NSDictionary *row in snapshot.chats) {
            NSString *mid = row[@"mid"];
            NSDate *updated = row[@"updated"];
            if (([row[@"oneOnOne"] boolValue] == users) && mid.length && [updated isKindOfClass:NSDate.class] &&
                (!values[mid] || [updated compare:values[mid]] == NSOrderedDescending)) values[mid] = updated;
        }
    }
    NSArray *sorted = [values.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *left, NSString *right) {
        NSComparisonResult date = [values[right] compare:values[left]];
        return date == NSOrderedSame ? [left compare:right] : date;
    }];
    return sorted.count > RUINChatCatalogLimit ? [sorted subarrayWithRange:NSMakeRange(0, RUINChatCatalogLimit)] : sorted;
}

static BOOL RUINUserCandidateIsBetter(NSDictionary *candidate, NSDictionary *current)
{
    if (!current || [candidate[@"sourcePriority"] integerValue] > [current[@"sourcePriority"] integerValue]) return YES;
    if ([candidate[@"sourcePriority"] integerValue] < [current[@"sourcePriority"] integerValue]) return NO;
    NSDate *updated = candidate[@"profileUpdated"] ?: NSDate.distantPast;
    NSDate *currentUpdated = current[@"profileUpdated"] ?: NSDate.distantPast;
    return [updated compare:currentUpdated] == NSOrderedDescending;
}

static NSArray<NSDictionary *> *RUINJoinCatalogRows(NSArray<NSDictionary *> *chatRows,
    NSArray<NSDictionary *> *squareRows, NSArray<NSDictionary *> *users, NSArray<NSDictionary *> *groups)
{
    NSMutableDictionary<NSString *, NSDictionary *> *byReadKey = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *usersByID = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSDictionary *> *groupsByID = [NSMutableDictionary dictionary];
    for (NSDictionary *candidate in users) {
        NSString *identifier = candidate[@"identifier"];
        if (identifier.length && RUINUserCandidateIsBetter(candidate, usersByID[identifier]))
            usersByID[identifier] = candidate;
    }
    for (NSDictionary *candidate in groups) {
        NSString *identifier = candidate[@"identifier"];
        if (identifier.length && !groupsByID[identifier]) groupsByID[identifier] = candidate;
    }
    for (NSDictionary *row in squareRows) {
        NSString *readKey = row[@"readKey"];
        NSDate *updated = row[@"updated"];
        NSDictionary *previous = byReadKey[readKey];
        if (readKey.length && [updated isKindOfClass:NSDate.class] &&
            (!previous || [updated compare:previous[@"updated"]] == NSOrderedDescending))
            byReadKey[readKey] = row;
    }
    for (NSDictionary *chat in chatRows) {
        NSString *mid = chat[@"mid"];
        NSDate *updated = chat[@"updated"];
        BOOL oneOnOne = [chat[@"oneOnOne"] boolValue];
        if (!mid.length || ![updated isKindOfClass:NSDate.class]) continue;
        NSDictionary *match = oneOnOne ? usersByID[mid] : groupsByID[mid];
        NSString *name = match[@"name"];
        if (!match || !name.length) continue;
        NSString *readKey = [@"chat:" stringByAppendingString:mid];
        NSString *aliasPrefix = oneOnOne ? @"user:" : @"group:";
        NSString *identifier = match[@"identifier"];
        NSMutableDictionary *item = [@{@"readKey":readKey,
            @"aliasKey":[aliasPrefix stringByAppendingString:identifier], @"name":[name copy],
            @"kind":oneOnOne ? @"oneOnOne" : @"group", @"updated":[updated copy]} mutableCopy];
        NSString *pictureURL = match[@"pictureURL"];
        NSString *pictureStatus = match[@"pictureStatus"];
        if (pictureURL.length) item[@"pictureURL"] = [pictureURL copy];
        if (pictureStatus.length) item[@"pictureStatus"] = [pictureStatus copy];
        NSDictionary *previous = byReadKey[readKey];
        if (!previous || [item[@"updated"] compare:previous[@"updated"]] == NSOrderedDescending)
            byReadKey[readKey] = [item copy];
    }

    NSArray *items = [byReadKey.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult date = [right[@"updated"] compare:left[@"updated"]];
        return date == NSOrderedSame ? [left[@"readKey"] compare:right[@"readKey"]] : date;
    }];
    return items.count > RUINChatCatalogLimit ? [items subarrayWithRange:NSMakeRange(0, RUINChatCatalogLimit)] : items;
}

static dispatch_queue_t RUINChatCatalogQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("line.ruin.chat-catalog", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static void RUINCompleteChatCatalog(void (^completion)(NSArray<NSDictionary *> *, NSString *),
                                     NSArray<NSDictionary *> *items, NSString *account)
{
    NSArray *copiedItems = [items copy] ?: @[];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *current = RUINCurrentChatCatalogAccount();
        if (![current isEqualToString:account]) completion(@[], current ?: @"");
        else completion(copiedItems, account ?: @"");
    });
}

void RUINLoadChatCatalog(void (^completion)(NSArray<NSDictionary *> *items, NSString *account))
{
    if (!completion) return;
    atomic_fetch_add_explicit(&gChatCatalogLoads, 1, memory_order_relaxed);
    NSString *account = RUINCurrentChatCatalogAccount();
    if (!account) { RUINCompleteChatCatalog(completion, @[], @""); return; }

    NSArray<NSManagedObjectContext *> *contexts = RUINCapturedChatContexts();
    dispatch_queue_t queue = RUINChatCatalogQueue();
    dispatch_async(queue, ^{
        NSMutableArray<RUINChatCatalogContextSnapshot *> *snapshots = [NSMutableArray array];
        dispatch_group_t firstPass = dispatch_group_create();
        for (NSManagedObjectContext *context in contexts) {
            dispatch_group_enter(firstPass);
            [context performBlock:^{
                RUINChatCatalogSchema schema = RUINChatCatalogSchemaUnknown;
                NSArray *chats = @[], *squares = @[];
                @try {
                    if ([RUINCurrentChatCatalogAccount() isEqualToString:account] &&
                        RUINContextMatchesAccount(context, account)) {
                        schema = RUINSchemaForModel(context.persistentStoreCoordinator.managedObjectModel);
                        if (schema == RUINChatCatalogSchemaTalk) chats = RUINReadTalkChats(context, account);
                        else if (schema == RUINChatCatalogSchemaSquare) squares = RUINReadSquareChats(context, account);
                    }
                } @catch (__unused NSException *exception) {
                    schema = RUINChatCatalogSchemaUnknown;
                    chats = @[]; squares = @[];
                }
                NSArray *copiedChats = [chats copy], *copiedSquares = [squares copy];
                dispatch_async(queue, ^{
                    if (schema != RUINChatCatalogSchemaUnknown) {
                        RUINChatCatalogContextSnapshot *snapshot = [RUINChatCatalogContextSnapshot new];
                        snapshot.context = context;
                        snapshot.schema = schema;
                        snapshot.chats = copiedChats;
                        snapshot.squares = copiedSquares;
                        snapshot.users = @[];
                        snapshot.groups = @[];
                        [snapshots addObject:snapshot];
                    }
                    dispatch_group_leave(firstPass);
                });
            }];
        }

        dispatch_group_notify(firstPass, queue, ^{
            if (![RUINCurrentChatCatalogAccount() isEqualToString:account]) {
                RUINCompleteChatCatalog(completion, @[], RUINCurrentChatCatalogAccount() ?: @"");
                return;
            }
            NSArray<NSString *> *userIDs = RUINSortedIdentifiers(snapshots, YES);
            NSArray<NSString *> *groupIDs = RUINSortedIdentifiers(snapshots, NO);
            dispatch_group_t secondPass = dispatch_group_create();
            for (RUINChatCatalogContextSnapshot *snapshot in snapshots) {
                BOOL readUsers = snapshot.schema == RUINChatCatalogSchemaTalk ||
                    snapshot.schema == RUINChatCatalogSchemaStandaloneUser;
                BOOL readGroups = snapshot.schema == RUINChatCatalogSchemaUnifiedGroup;
                if ((!readUsers || userIDs.count == 0) && (!readGroups || groupIDs.count == 0)) continue;
                dispatch_group_enter(secondPass);
                [snapshot.context performBlock:^{
                    NSArray *users = @[], *groups = @[];
                    @try {
                        if ([RUINCurrentChatCatalogAccount() isEqualToString:account] &&
                            RUINContextMatchesAccount(snapshot.context, account)) {
                            NSManagedObjectModel *model = snapshot.context.persistentStoreCoordinator.managedObjectModel;
                            if (readUsers && RUINSchemaForModel(model) == snapshot.schema) {
                                users = RUINReadUsers(snapshot.context, account, userIDs,
                                    snapshot.schema == RUINChatCatalogSchemaStandaloneUser);
                            } else if (readGroups && RUINSchemaForModel(model) == snapshot.schema) {
                                groups = RUINReadGroups(snapshot.context, account, groupIDs);
                            }
                        }
                    } @catch (__unused NSException *exception) {
                        users = @[]; groups = @[];
                    }
                    NSArray *copiedUsers = [users copy], *copiedGroups = [groups copy];
                    dispatch_async(queue, ^{
                        snapshot.users = copiedUsers;
                        snapshot.groups = copiedGroups;
                        dispatch_group_leave(secondPass);
                    });
                }];
            }

            dispatch_group_notify(secondPass, queue, ^{
                NSString *current = RUINCurrentChatCatalogAccount();
                if (![current isEqualToString:account]) {
                    RUINCompleteChatCatalog(completion, @[], current ?: @"");
                    return;
                }
                NSMutableArray *chats = [NSMutableArray array], *squares = [NSMutableArray array];
                NSMutableArray *users = [NSMutableArray array], *groups = [NSMutableArray array];
                for (RUINChatCatalogContextSnapshot *snapshot in snapshots) {
                    [chats addObjectsFromArray:snapshot.chats];
                    [squares addObjectsFromArray:snapshot.squares];
                    [users addObjectsFromArray:snapshot.users];
                    [groups addObjectsFromArray:snapshot.groups];
                }
                NSArray *items = RUINJoinCatalogRows(chats, squares, users, groups);
                atomic_store_explicit(&gChatCatalogItems, items.count, memory_order_relaxed);
                RUINCompleteChatCatalog(completion, items, account);
            });
        });
    });
}

#if !defined(RUIN_CHAT_CATALOG_HOST_CHECK)
%group RUINChatCatalogCapture
%hook NSManagedObjectContext
- (NSArray *)executeFetchRequest:(NSFetchRequest *)request error:(NSError **)error
{
    NSArray *result = %orig(request, error);
    if (result && (!error || !*error)) {
        NSString *entityName = request.entityName ?: request.entity.name;
        if ([entityName isEqualToString:@"Chat"] || [entityName isEqualToString:@"User"] ||
            [entityName isEqualToString:@"UnifiedGroup"]) {
            @try { RUINCaptureChatCatalogContext(self, request); }
            @catch (__unused NSException *exception) {}
        }
    }
    return result;
}
%end
%end
#endif

void RUINInstallChatCatalog(void)
{
#if defined(RUIN_CHAT_CATALOG_HOST_CHECK)
    return;
#else
    os_unfair_lock_lock(&gChatCatalogInstallLock);
    if (gChatCatalogInstalled) { os_unfair_lock_unlock(&gChatCatalogInstallLock); return; }
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    if (!RUINTargetMetadataMatchesInfo(info)) {
        gChatCatalogInstallStatus = RUINChatCatalogInstallTargetMismatch;
        os_unfair_lock_unlock(&gChatCatalogInstallLock);
        return;
    }
    NSString *identityStatus = RUINBundleIdentityDiagnostics()[@"status"];
    if (![identityStatus isEqualToString:@"installed"] && ![identityStatus isEqualToString:@"already_original"]) {
        gChatCatalogInstallStatus = RUINChatCatalogInstallIdentityUnavailable;
        os_unfair_lock_unlock(&gChatCatalogInstallLock);
        return;
    }
    Method method = class_getInstanceMethod(NSManagedObjectContext.class, @selector(executeFetchRequest:error:));
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || strcmp(encoding, "@32@0:8@16^@24") != 0 || !method_getImplementation(method)) {
        gChatCatalogInstallStatus = RUINChatCatalogInstallABIMismatch;
        os_unfair_lock_unlock(&gChatCatalogInstallLock);
        return;
    }
    %init(RUINChatCatalogCapture);
    gChatCatalogInstalled = YES;
    gChatCatalogInstallStatus = RUINChatCatalogInstallReady;
    os_unfair_lock_unlock(&gChatCatalogInstallLock);
#endif
}

NSDictionary *RUINChatCatalogDiagnostics(void)
{
    static NSString *const statuses[] = {@"not_requested", @"target_mismatch", @"identity_unavailable",
        @"abi_mismatch", @"installed"};
    os_unfair_lock_lock(&gChatCatalogInstallLock);
    RUINChatCatalogInstallStatus status = gChatCatalogInstallStatus;
    BOOL installed = gChatCatalogInstalled;
    os_unfair_lock_unlock(&gChatCatalogInstallLock);
    os_unfair_lock_lock(&gChatCatalogLock);
    NSUInteger contexts = gChatCatalogContexts.allObjects.count;
    os_unfair_lock_unlock(&gChatCatalogLock);
    return @{@"status":statuses[status], @"installed":@(installed), @"capturedContexts":@(contexts),
        @"verifiedFetches":@(atomic_load_explicit(&gChatCatalogFetches, memory_order_relaxed)),
        @"loads":@(atomic_load_explicit(&gChatCatalogLoads, memory_order_relaxed)),
        @"lastItemCount":@(atomic_load_explicit(&gChatCatalogItems, memory_order_relaxed))};
}

#if defined(RUIN_CHAT_CATALOG_HOST_CHECK)
#import <assert.h>

@interface ManagedChat : NSManagedObject @end
@implementation ManagedChat @end
@interface ManagedUser : NSManagedObject @end
@implementation ManagedUser @end
@interface ManagedUnifiedGroup : NSManagedObject @end
@implementation ManagedUnifiedGroup @end
@interface ManagedSquareChat : NSManagedObject @end
@implementation ManagedSquareChat @end

NSDictionary *RUINIdentityForObject(id object) { (void)object; return @{}; }
NSDictionary *RUINBundleIdentityDiagnostics(void) { return @{@"status":@"already_original"}; }

static NSAttributeDescription *RUINFixtureAttribute(NSString *name, NSAttributeType type)
{
    NSAttributeDescription *attribute = [NSAttributeDescription new];
    attribute.name = name;
    attribute.attributeType = type;
    return attribute;
}

static NSEntityDescription *RUINFixtureEntity(NSString *name, NSString *className,
                                                NSDictionary<NSString *, NSNumber *> *types)
{
    NSEntityDescription *entity = [NSEntityDescription new];
    entity.name = name;
    entity.managedObjectClassName = className;
    NSMutableArray *attributes = [NSMutableArray array];
    [types enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *type, __unused BOOL *stop) {
        [attributes addObject:RUINFixtureAttribute(key, type.integerValue)];
    }];
    entity.properties = attributes;
    return entity;
}

int main(void)
{
    @autoreleasepool {
        NSString *mid = @"u0123456789abcdef0123456789abcdef";
        NSURL *native = [NSURL fileURLWithPath:[NSString stringWithFormat:@"/container/PrivateStore/S_%@/Line.sqlite", mid]];
        NSURL *other = [NSURL fileURLWithPath:@"/container/PrivateStore/S_u11111111111111111111111111111111/Line.sqlite"];
        assert(RUINStoreURLMatchesAccount(native, mid));
        assert(!RUINStoreURLMatchesAccount(other, mid));
        assert(!RUINStoreURLMatchesAccount([NSURL fileURLWithPath:@"/container/PrivateStore/Line.sqlite"], mid));

        NSEntityDescription *user = RUINFixtureEntity(@"User", @"ManagedUser", RUINTalkUserTypes());
        NSEntityDescription *chat = RUINFixtureEntity(@"Chat", @"ManagedChat", @{
            @"mid": @(NSStringAttributeType), @"enable": @(NSBooleanAttributeType),
            @"type": @(NSInteger16AttributeType), @"lastUpdated": @(NSDateAttributeType),
            @"sortOrder": @(NSInteger16AttributeType)});
        NSRelationshipDescription *members = [NSRelationshipDescription new];
        members.name = @"members"; members.destinationEntity = user;
        NSMutableArray *chatProperties = [chat.properties mutableCopy];
        [chatProperties addObject:members]; chat.properties = chatProperties;
        NSManagedObjectModel *talkModel = [NSManagedObjectModel new];
        talkModel.entities = @[chat, user];
        assert(RUINSchemaForModel(talkModel) == RUINChatCatalogSchemaTalk);

        NSArray *joined = RUINJoinCatalogRows(@[
            @{@"mid":mid, @"oneOnOne":@YES, @"updated":[NSDate dateWithTimeIntervalSince1970:20]},
            @{@"mid":@"group-id", @"oneOnOne":@NO, @"updated":[NSDate dateWithTimeIntervalSince1970:10]}], @[], @[
            @{@"identifier":mid, @"name":@"Native user", @"sourcePriority":@1}], @[
            @{@"identifier":@"group-id", @"name":@"Native group"}]);
        assert(joined.count == 2);
        assert([joined[0][@"readKey"] isEqual:@"chat:u0123456789abcdef0123456789abcdef"]);
        assert([joined[0][@"aliasKey"] isEqual:@"user:u0123456789abcdef0123456789abcdef"]);
        assert([joined[0][@"name"] isEqual:@"Native user"]);
        assert([joined[1][@"aliasKey"] isEqual:@"group:group-id"]);
        assert([joined[1][@"kind"] isEqual:@"group"]);
    }
    return 0;
}
#endif
