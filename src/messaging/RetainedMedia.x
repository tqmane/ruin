%config(generator=internal);

#import "RetainedMedia.h"
#import "RetainedMediaStore.h"
#import "MessageHistory.h"
#import "MessagingPrivateAPI.h"
#import "TargetMetadata.h"
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <string.h>
#import <sys/stat.h>

@interface RUINMediaStateRecord : NSObject
@property (nonatomic, assign) BOOL nonMedia;
@property (nonatomic, assign) BOOL initialObserved;
@property (nonatomic, assign) uint8_t capturedRoles;
@property (nonatomic, copy) NSDictionary *key;
@end
@implementation RUINMediaStateRecord
@end

NSNotificationName const RUINRetainedMediaDidChangeNotification = @"com.tqmane.ruin.retained-media-changed";

static RUINRetainedMediaStore *mediaStore;
static BOOL mediaStoreMissing;
static BOOL talkHooksInstalled;
static atomic_ulong videoRequests, videoRejected;
static atomic_ulong captureRequests, scopeRejections, localSources, remoteSources, copySuccesses, copyFailures, URLReplacements;
static _Thread_local unsigned captureDepth, getterDepth;
static NSMutableDictionary<NSArray *, NSUUID *> *pendingCopies;
static UIBackgroundTaskIdentifier backgroundTask;
static os_unfair_lock mediaStateLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSManagedObjectID *, RUINMediaStateRecord *> *mediaStateByID;
static NSMutableArray<NSManagedObjectID *> *mediaStateOrder;
static const NSUInteger RUINMediaStateCacheLimit = 1024;
static os_unfair_lock scopeCacheLock = OS_UNFAIR_LOCK_INIT;
static NSString *cachedVerifiedAccountName;
static NSString *cachedVerifiedMID;
static NSURL *cachedVerifiedStoreURL;
static NSArray<NSURL *> *cachedAccountRoots;

// UIKit owns the finite background grace period. A committed archive is durable;
// force termination before a copy completes cannot be turned into a guarantee.
static void UpdateBackgroundTask(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static dispatch_once_t once;
        dispatch_once(&once, ^{ backgroundTask = UIBackgroundTaskInvalid; });
        BOOL pending;
        @synchronized (RUINRetainedMediaStore.class) { pending = pendingCopies.count != 0; }
        if (pending && backgroundTask == UIBackgroundTaskInvalid) {
            backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"RUIN retained media"
                expirationHandler:^{
                    UIBackgroundTaskIdentifier expired = backgroundTask;
                    backgroundTask = UIBackgroundTaskInvalid;
                    if (expired != UIBackgroundTaskInvalid) [UIApplication.sharedApplication endBackgroundTask:expired];
                }];
        } else if (!pending && backgroundTask != UIBackgroundTaskInvalid) {
            UIBackgroundTaskIdentifier finished = backgroundTask;
            backgroundTask = UIBackgroundTaskInvalid;
            [UIApplication.sharedApplication endBackgroundTask:finished];
        }
    });
}

static BOOL TargetMatches(void) {
    static BOOL matched;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ matched = RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary); });
    return matched;
}

static BOOL Enabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey] && TargetMatches();
}

static NSUserDefaults *SharedGroupDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.linecorp.line"]; });
    return defaults;
}

static NSURL *SharedGroupContainerURL(void) {
    static NSURL *containerURL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        containerURL = [[NSFileManager.defaultManager
            containerURLForSecurityApplicationGroupIdentifier:@"group.com.linecorp.line"] copy];
    });
    return containerURL;
}

static uint8_t RoleBit(NSString *role) {
    if ([role isEqual:@"photo"]) return 1 << 0;
    if ([role isEqual:@"audio"]) return 1 << 1;
    if ([role isEqual:@"attached"] || [role isEqual:@"video"] || [role isEqual:@"file"]) return 1 << 2;
    if ([role isEqual:@"thumbnail"]) return 1 << 3;
    if ([role isEqual:@"livePhoto"]) return 1 << 4;
    return 0;
}

static RUINMediaStateRecord *MediaStateForID(NSManagedObjectID *objectID) {
    if (!objectID) return nil;
    os_unfair_lock_lock(&mediaStateLock);
    RUINMediaStateRecord *record = mediaStateByID[objectID];
    os_unfair_lock_unlock(&mediaStateLock);
    return record;
}

static RUINMediaStateRecord *SetMediaStateForID(NSManagedObjectID *objectID, NSDictionary *key, BOOL isMedia, uint8_t capturedRoles) {
    if (!objectID) return nil;
    os_unfair_lock_lock(&mediaStateLock);
    if (!mediaStateByID) {
        mediaStateByID = [NSMutableDictionary dictionary];
        mediaStateOrder = [NSMutableArray array];
    }
    RUINMediaStateRecord *record = mediaStateByID[objectID];
    if (!record) {
        if (mediaStateOrder.count >= RUINMediaStateCacheLimit) {
            NSManagedObjectID *evict = mediaStateOrder.firstObject;
            [mediaStateOrder removeObjectAtIndex:0];
            if (evict) [mediaStateByID removeObjectForKey:evict];
        }
        record = [RUINMediaStateRecord new];
        mediaStateByID[objectID] = record;
        [mediaStateOrder addObject:objectID];
    }
    record.nonMedia = !isMedia;
    record.initialObserved = YES;
    record.capturedRoles |= capturedRoles;
    if (key) record.key = key;
    os_unfair_lock_unlock(&mediaStateLock);
    return record;
}

static void MarkCapturedRoleForID(NSManagedObjectID *objectID, NSString *role) {
    uint8_t bit = RoleBit(role);
    if (!objectID || !bit) return;
    os_unfair_lock_lock(&mediaStateLock);
    RUINMediaStateRecord *record = mediaStateByID[objectID];
    if (record) record.capturedRoles |= bit;
    os_unfair_lock_unlock(&mediaStateLock);
}

static NSDictionary *ArchiveKey(NSDictionary *key) {
    if (![key isKindOfClass:NSDictionary.class]) return @{};
    NSMutableDictionary *copy = [NSMutableDictionary dictionary];
    for (NSString *field in @[@"store", @"kind", @"chat", @"message"]) {
        id value = key[field];
        if (![value isKindOfClass:NSString.class] || ![value length]) return @{};
        copy[field] = [value copy];
    }
    return [copy copy];
}

static RUINRetainedMediaStore *Store(BOOL create) {
    @synchronized (RUINRetainedMediaStore.class) {
        if (mediaStore) return mediaStore;
        if (!create && mediaStoreMissing) return nil;
        NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
            inDomains:NSUserDomainMask].firstObject;
        NSURL *directory = [[support URLByAppendingPathComponent:@"RUIN" isDirectory:YES]
            URLByAppendingPathComponent:@"RetainedMedia" isDirectory:YES];
        BOOL isDirectory = NO;
        BOOL exists = directory && [NSFileManager.defaultManager fileExistsAtPath:directory.path
            isDirectory:&isDirectory] && isDirectory;
        if (directory && (create || exists)) {
            mediaStoreMissing = NO;
            mediaStore = [[RUINRetainedMediaStore alloc] initWithDirectoryURL:directory error:NULL];
        } else if (!create && directory) {
            mediaStoreMissing = YES;
        }
        return mediaStore;
    }
}

static BOOL SameFile(NSURL *firstURL, NSURL *secondURL) {
    struct stat first, second;
    return firstURL.isFileURL && secondURL.isFileURL &&
        stat(firstURL.fileSystemRepresentation, &first) == 0 &&
        stat(secondURL.fileSystemRepresentation, &second) == 0 &&
        S_ISREG(first.st_mode) && S_ISREG(second.st_mode) &&
        first.st_dev == second.st_dev && first.st_ino == second.st_ino;
}

static BOOL ValidMediaChatID(NSString *chatID) {
    if (chatID.length != 33) return NO;
    unichar prefix = [chatID characterAtIndex:0];
    if (prefix != 'u' && prefix != 'c' && prefix != 'r') return NO;
    for (NSUInteger i = 1; i < 33; i++) {
        unichar c = [chatID characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return NO;
    }
    return YES;
}

static NSArray<NSURL *> *AccountRootsForScope(NSString *accountName, NSURL *storeURL, NSString *mid) {
    NSURL *group = SharedGroupContainerURL();
    if (!group) return nil;
    os_unfair_lock_lock(&scopeCacheLock);
    if (cachedAccountRoots &&
        [cachedVerifiedAccountName isEqualToString:accountName] &&
        [cachedVerifiedMID isEqualToString:mid] &&
        [cachedVerifiedStoreURL isEqual:storeURL]) {
        NSArray<NSURL *> *roots = cachedAccountRoots;
        os_unfair_lock_unlock(&scopeCacheLock);
        return roots;
    }
    os_unfair_lock_unlock(&scopeCacheLock);

    NSURL *account = [[group URLByAppendingPathComponent:@"Library/Application Support/PrivateStore" isDirectory:YES]
        URLByAppendingPathComponent:accountName isDirectory:YES];
    NSURL *expectedStore = [account URLByAppendingPathComponent:@"Messages/Line.sqlite" isDirectory:NO];
    if (!SameFile(storeURL, expectedStore)) return nil;

    NSMutableArray<NSURL *> *accounts = [NSMutableArray arrayWithObject:account];
    for (NSString *subpath in @[@"Library/Caches/PrivateStore"])
        [accounts addObject:[[group URLByAppendingPathComponent:subpath isDirectory:YES]
            URLByAppendingPathComponent:accountName isDirectory:YES]];
    for (NSNumber *directory in @[@(NSApplicationSupportDirectory), @(NSCachesDirectory)]) {
        NSURL *local = [NSFileManager.defaultManager URLsForDirectory:directory.unsignedIntegerValue
            inDomains:NSUserDomainMask].firstObject;
        if (local) [accounts addObject:[[local URLByAppendingPathComponent:@"PrivateStore" isDirectory:YES]
            URLByAppendingPathComponent:accountName isDirectory:YES]];
    }
    NSArray<NSURL *> *copied = [accounts copy];
    os_unfair_lock_lock(&scopeCacheLock);
    cachedVerifiedAccountName = [accountName copy];
    cachedVerifiedMID = [mid copy];
    cachedVerifiedStoreURL = [storeURL copy];
    cachedAccountRoots = copied;
    os_unfair_lock_unlock(&scopeCacheLock);
    return copied;
}

static NSArray<NSURL *> *MediaRootsForAccountsAndChat(NSArray<NSURL *> *accounts, NSString *chatID) {
    // Native files use these media subtrees. Never grant the account's database,
    // authentication, backup or unrelated attachment directories as sources.
    NSMutableArray *roots = [NSMutableArray array];
    for (NSURL *base in accounts) for (NSString *folder in @[@"Message Attachments", @"Message Thumbnails", @"Image"]) {
        NSURL *media = [base URLByAppendingPathComponent:folder isDirectory:YES];
        if (![folder isEqual:@"Image"]) media = [media URLByAppendingPathComponent:chatID isDirectory:YES];
        BOOL directory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:media.path isDirectory:&directory] && directory)
            [roots addObject:media];
    }
    return [roots copy];
}

// Called on the managed object's context. A store must be the current native
// account's Line.sqlite in the OS-authorized/mapped LINE group, not a guessed
// container or another account's database.
static NSDictionary *Scope(NSManagedObject *message, BOOL includeRoots) {
    if (message.isDeleted || message.objectID.isTemporaryID ||
        ![message.entity.name isEqual:@"Message"]) return nil;
    NSDictionary *key = ArchiveKey(RUINHistoryMessageKey(message));
    if (!key.count || ![key[@"kind"] isEqual:@"talk"]) return nil;
    NSString *chatID = key[@"chat"];
    if (!ValidMediaChatID(chatID)) return nil;
    NSURL *storeURL = message.objectID.persistentStore.URL;
    if (!storeURL.isFileURL || ![storeURL.lastPathComponent isEqual:@"Line.sqlite"]) return nil;
    NSString *accountName = storeURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.lastPathComponent;
    id mid = [SharedGroupDefaults() objectForKey:@"mid"];
    if (![mid isKindOfClass:NSString.class] || [mid length] != 33 || ![mid hasPrefix:@"u"] ||
        ![@[[@"P_" stringByAppendingString:mid], [@"S_" stringByAppendingString:mid]] containsObject:accountName]) return nil;
    NSArray<NSURL *> *accounts = AccountRootsForScope(accountName, storeURL, mid);
    if (!accounts) return nil;
    NSAttributeDescription *attribute = message.entity.attributesByName[@"contentType"];
    if (!attribute || ![@[@(NSInteger16AttributeType), @(NSInteger32AttributeType), @(NSInteger64AttributeType)]
        containsObject:@(attribute.attributeType)]) return nil;
    id type = [message valueForKey:@"contentType"];
    if (![type isKindOfClass:NSNumber.class] || !strchr("csilqCSILQ", [type objCType][0])) return nil;
    NSArray *roots = includeRoots ? MediaRootsForAccountsAndChat(accounts, chatID) : @[];
    return @{@"key":key, @"roots":roots, @"accounts":accounts, @"chatID":chatID, @"contentType":type};
}

static id MediaValue(id<RUINMessagingMediaFields> object, NSString *name) {
    Method method = class_getInstanceMethod(object_getClass(object), NSSelectorFromString(name));
    if (!method || strcmp(method_getTypeEncoding(method), "@16@0:8")) return nil;
    if ([name isEqual:@"imageFileURL"]) return [object imageFileURL];
    if ([name isEqual:@"audioFileURL"]) return [object audioFileURL];
    if ([name isEqual:@"attachedFileURL"]) return [object attachedFileURL];
    if ([name isEqual:@"thumbnailFileURL"]) return [object thumbnailFileURL];
    if ([name isEqual:@"livePhotoFileURL"]) return [object livePhotoFileURL];
    if ([name isEqual:@"cacheableImagePathURL"]) return [object cacheableImagePathURL];
    return nil;
}

static NSString *AttachedRole(NSInteger contentType) {
    return contentType == 2 ? @"video" : contentType == 3 ? @"audio" : @"file";
}

static void NotifyChanged(NSDictionary *key) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:RUINRetainedMediaDidChangeNotification object:key];
    });
}

// Deduplicate before opening a source FD; getters may be called for every layout.
static void CaptureSource(RUINRetainedMediaStore *store, NSDictionary *scope, NSString *role,
                          NSURL *source, NSData *data, NSString *extension, NSManagedObjectID *objectID) {
    NSDictionary *key = scope[@"key"];
    for (NSDictionary *item in [store itemsForKey:key]) if ([item[@"role"] isEqual:role]) {
        MarkCapturedRoleForID(objectID, role);
        return;
    }
    NSArray *token = @[key, role];
    NSUUID *request = NSUUID.UUID;
    @synchronized (RUINRetainedMediaStore.class) {
        if (!pendingCopies) pendingCopies = [NSMutableDictionary dictionary];
        if (pendingCopies[token]) return;
        pendingCopies[token] = request;
    }
    UpdateBackgroundTask();
    void (^completed)(BOOL) = ^(BOOL success) {
        @synchronized (RUINRetainedMediaStore.class) {
            if (![pendingCopies[token] isEqual:request]) return;
            [pendingCopies removeObjectForKey:token];
        }
        if (success) MarkCapturedRoleForID(objectID, role);
        atomic_fetch_add(success ? &copySuccesses : &copyFailures, 1);
        UpdateBackgroundTask();
        if (success && [store isUnsentForKey:key]) NotifyChanged(key);
    };
    BOOL accepted = data ? [store captureData:data extension:extension forKey:key role:role completion:completed] :
        [store captureURL:source allowedRoots:scope[@"roots"] forKey:key role:role completion:completed];
    // Rejected URLs must not prevent an embedded thumbnail from being captured.
    // The queued rejection callback cannot release a newer request's ownership.
    if (!accepted) completed(NO);
}

static NSDictionary *CaptureWithResolvedScope(NSManagedObject *message, NSDictionary *scope,
                                              NSDictionary *requested, BOOL unsent, uint8_t *committedMaskOut) {
    NSInteger type = [scope[@"contentType"] integerValue];
    BOOL media = (type == 1 || type == 2 || type == 3 || type == 14);
    RUINRetainedMediaStore *store = Store(media || unsent);
    if (!store) return nil;
    // Tombstones may have lost contentType/metadata already. Mark a prior
    // archive even then, before startup synchronization continues cleanup.
    if (unsent &&
        ![store isUnsentForKey:requested] && [store markUnsentForKey:requested]) NotifyChanged(requested);
    if (!media) {
        SetMediaStateForID(message.objectID, requested, NO, 0);
        return requested;
    }
    NSMutableDictionary *selectors = [NSMutableDictionary dictionary];
    if (type == 1) { selectors[@"imageFileURL"] = @"photo"; selectors[@"cacheableImagePathURL"] = @"photo"; selectors[@"livePhotoFileURL"] = @"livePhoto"; }
    if (type == 2 || type == 14) selectors[@"attachedFileURL"] = AttachedRole(type);
    if (type == 3) selectors[@"audioFileURL"] = @"audio";
    if (type == 1 || type == 2) selectors[@"thumbnailFileURL"] = @"thumbnail";
    NSArray *committed = [store itemsForKey:requested];
    uint8_t committedMask = 0;
    for (NSDictionary *item in committed) committedMask |= RoleBit(item[@"role"]);
    NSDictionary *captureScope = nil;
    NSManagedObjectID *objectID = message.objectID;
    for (NSString *name in selectors) {
        NSString *role = selectors[name];
        if (committedMask & RoleBit(role)) continue;
        id source = MediaValue((id<RUINMessagingMediaFields>)message, name);
        if (![source isKindOfClass:NSURL.class]) continue;
        if (![source isFileURL]) { atomic_fetch_add(&remoteSources, 1); continue; }
        if (![NSFileManager.defaultManager fileExistsAtPath:[source path]]) continue;
        atomic_fetch_add(&localSources, 1);
        if (!captureScope) {
            NSArray *roots = [scope[@"roots"] count] ? scope[@"roots"] :
                MediaRootsForAccountsAndChat(scope[@"accounts"], scope[@"chatID"]);
            NSMutableDictionary *mutableScope = [scope mutableCopy];
            mutableScope[@"roots"] = roots ?: @[];
            captureScope = [mutableScope copy];
        }
        CaptureSource(store, captureScope, role, source, nil, nil, objectID);
    }
    if ((type == 1 || type == 2) && !(committedMask & RoleBit(@"thumbnail"))) {
        NSAttributeDescription *thumbnail = message.entity.attributesByName[@"thumbnail"];
        id data = thumbnail.attributeType == NSBinaryDataAttributeType ? [message valueForKey:@"thumbnail"] : nil;
        if ([data isKindOfClass:NSData.class] && [data length]) {
            CGImageSourceRef image = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
            if (image) {
                CFStringRef identifier = CGImageSourceGetType(image);
                NSString *extension = identifier ? [UTType typeWithIdentifier:(__bridge NSString *)identifier].preferredFilenameExtension : nil;
                if (CGImageSourceGetStatus(image) == kCGImageStatusComplete && extension.length)
                    CaptureSource(store, captureScope ?: scope, @"thumbnail", nil, [data copy], extension, objectID);
                CFRelease(image);
            }
        }
    }
    if (committedMaskOut) *committedMaskOut = committedMask;
    SetMediaStateForID(objectID, requested, YES, committedMask);
    return requested;
}

static void Capture(id value, NSDictionary *messageKey, BOOL unsent) {
    if (!Enabled() || captureDepth || ![value isKindOfClass:NSManagedObject.class]) return;
    NSManagedObject *message = value;
    NSManagedObjectContext *context = message.managedObjectContext;
    NSDictionary *requested = ArchiveKey(messageKey);
    if (!context || !requested.count) return;
    atomic_fetch_add(&captureRequests, 1);
    [context performBlockAndWait:^{ @try {
        captureDepth++;
        NSDictionary *scope = Scope(message, NO);
        if (!scope || ![scope[@"key"] isEqual:requested]) { atomic_fetch_add(&scopeRejections, 1); return; }
        CaptureWithResolvedScope(message, scope, requested, unsent, NULL);
    } @catch (__unused NSException *exception) { atomic_fetch_add(&copyFailures, 1); }
    @finally { captureDepth--; } }];
}

void RUINObserveRetainedMedia(id message, NSDictionary *messageKey) { Capture(message, messageKey, NO); }
void RUINCaptureRetainedMedia(id message, NSDictionary *messageKey) { Capture(message, messageKey, YES); }

void RUINObserveRetainedVideoURL(id value, NSDictionary *messageKey, NSURL *URL) {
    if (!Enabled() || ![URL isKindOfClass:NSURL.class] || ![value isKindOfClass:NSManagedObject.class]) return;
    NSManagedObject *message = value;
    NSManagedObjectContext *context = message.managedObjectContext;
    NSDictionary *key = ArchiveKey(messageKey);
    if (!context || !key.count) return;
    atomic_fetch_add(&videoRequests, 1);
    [context performBlockAndWait:^{ @try {
        NSDictionary *scope = Scope(message, YES);
        if (![scope[@"key"] isEqual:key] || [scope[@"contentType"] integerValue] != 2) { atomic_fetch_add(&videoRejected, 1); return; }
        if (!URL.isFileURL) { atomic_fetch_add(&remoteSources, 1); return; }
        NSMutableArray *roots = [scope[@"roots"] mutableCopy];
        NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        if (caches) [roots addObject:[caches URLByAppendingPathComponent:@"CacheableVideo" isDirectory:YES]];
        [roots addObject:[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]];
        NSMutableDictionary *videoScope = [scope mutableCopy]; videoScope[@"roots"] = [roots copy];
        RUINRetainedMediaStore *store = Store(YES);
        if (store) CaptureSource(store, videoScope, @"video", [URL copy], nil, nil, message.objectID);
    } @catch (__unused NSException *exception) { atomic_fetch_add(&copyFailures, 1); } }];
}

NSArray<NSDictionary *> *RUINRetainedMediaItems(NSDictionary *messageKey) {
    if (!Enabled()) return @[];
    RUINRetainedMediaStore *store = Store(NO);
    if (!store || ![store hasAnyScopes]) return @[];
    NSDictionary *key = ArchiveKey(messageKey);
    return key.count && [store isUnsentForKey:key] ? [store itemsForKey:key] : @[];
}

static id MatchingRetainedURL(NSArray<NSDictionary *> *items, NSString *role) {
    for (NSDictionary *item in items)
        if (([item[@"role"] isEqual:role] || ([role isEqual:@"attached"] &&
            [@[@"video", @"file"] containsObject:item[@"role"]])) && [item[@"URL"] isKindOfClass:NSURL.class]) {
            atomic_fetch_add(&URLReplacements, 1);
            return item[@"URL"];
        }
    return nil;
}

static id ForwardURL(NSManagedObject *message, NSString *role, id (^original)(void)) {
    BOOL outer = getterDepth++ == 0;
    @try {
        id value = original();
        if (!outer || captureDepth || !Enabled() || !message.managedObjectContext) return value;
        NSManagedObjectID *objectID = message.objectID;
        RUINMediaStateRecord *record = !objectID.isTemporaryID ? MediaStateForID(objectID) : nil;
        RUINRetainedMediaStore *store = Store(NO);
        BOOL storeHasScopes = store && [store hasAnyScopes];
        uint8_t roleBit = RoleBit(role);
        BOOL valueIsLocalFile = [value isKindOfClass:NSURL.class] && [(NSURL *)value isFileURL];
        if (record) {
            if (record.nonMedia) {
                if (!storeHasScopes || !record.key.count) return value;
                return MatchingRetainedURL(RUINRetainedMediaItems(record.key), role) ?: value;
            }
            if (record.initialObserved && (!valueIsLocalFile || (record.capturedRoles & roleBit))) {
                if (storeHasScopes && record.key.count) {
                    id replaced = MatchingRetainedURL(RUINRetainedMediaItems(record.key), role);
                    if (replaced) return replaced;
                }
                return value;
            }
        }
        __block NSDictionary *resolvedKey = nil;
        [message.managedObjectContext performBlockAndWait:^{ @try {
            captureDepth++;
            NSDictionary *scope = Scope(message, NO);
            if (!scope) return;
            atomic_fetch_add(&captureRequests, 1);
            resolvedKey = CaptureWithResolvedScope(message, scope, scope[@"key"], NO, NULL);
        } @catch (__unused NSException *exception) {}
        @finally { captureDepth--; } }];
        if (!resolvedKey.count) return value;
        if (!storeHasScopes) storeHasScopes = Store(NO) && [Store(NO) hasAnyScopes];
        if (storeHasScopes) {
            id replaced = MatchingRetainedURL(RUINRetainedMediaItems(resolvedKey), role);
            if (replaced) return replaced;
        }
        return value;
    } @finally { getterDepth--; }
}

%group RUINMediaTalkURLs
%hook RUINMediaTalk
- (id)imageFileURL { return ForwardURL(self, @"photo", ^id { return %orig; }); }
- (id)audioFileURL { return ForwardURL(self, @"audio", ^id { return %orig; }); }
- (id)attachedFileURL { return ForwardURL(self, @"attached", ^id { return %orig; }); }
- (id)thumbnailFileURL { return ForwardURL(self, @"thumbnail", ^id { return %orig; }); }
- (id)livePhotoFileURL { return ForwardURL(self, @"livePhoto", ^id { return %orig; }); }
%end
%end

static BOOL GettersAvailable(Class cls) {
    if (!cls || ![cls isSubclassOfClass:NSManagedObject.class]) return NO;
    for (NSString *name in @[@"imageFileURL",@"audioFileURL",@"attachedFileURL",@"thumbnailFileURL",@"livePhotoFileURL"]) {
        Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
        if (!method || strcmp(method_getTypeEncoding(method), "@16@0:8")) return NO;
    }
    return YES;
}

static void InitTalk(Class cls) { %init(RUINMediaTalkURLs, RUINMediaTalk = cls); }

void RUINInstallRetainedMedia(void) {
    RUINInstallRetainedVideo();
    if (!RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary)) return;
    @synchronized (RUINRetainedMediaStore.class) {
        Class talk = NSClassFromString(@"ManagedMessage");
        if (!talkHooksInstalled && GettersAvailable(talk)) { InitTalk(talk); talkHooksInstalled = YES; }
    }
}

NSDictionary *RUINRetainedMediaDiagnostics(void) {
    return @{@"enabled":@(Enabled()), @"talkURLHooksInstalled":@(talkHooksInstalled),
        @"supportedKinds":@[@"talk"], @"captureRequests":@(atomic_load(&captureRequests)),
        @"scopeRejections":@(atomic_load(&scopeRejections)), @"localSources":@(atomic_load(&localSources)),
        @"remoteSourcesSkipped":@(atomic_load(&remoteSources)), @"copySuccesses":@(atomic_load(&copySuccesses)),
        @"copyFailures":@(atomic_load(&copyFailures)), @"URLReplacements":@(atomic_load(&URLReplacements)),
        @"videoViewer":RUINRetainedVideoDiagnostics(), @"videoRequests":@(atomic_load(&videoRequests)),
        @"videoRejected":@(atomic_load(&videoRejected)), @"archive":[Store(NO) diagnostics] ?: @{}, @"prearchiveDownloadedMedia":@YES, @"persistentUnsentMarkers":@YES, @"automaticNetworkFetch":@NO};
}
