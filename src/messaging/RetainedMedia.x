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
#import <stdatomic.h>
#import <string.h>
#import <sys/stat.h>

NSNotificationName const RUINRetainedMediaDidChangeNotification = @"com.tqmane.ruin.retained-media-changed";

static RUINRetainedMediaStore *mediaStore;
static BOOL talkHooksInstalled;
static atomic_ulong videoRequests, videoRejected;
static atomic_ulong captureRequests, scopeRejections, localSources, remoteSources, copySuccesses, copyFailures, URLReplacements;
static _Thread_local unsigned captureDepth, getterDepth;
static NSMutableDictionary<NSArray *, NSUUID *> *pendingCopies;
static UIBackgroundTaskIdentifier backgroundTask;

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

static BOOL Enabled(void) {
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary) &&
        [NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey];
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
        if (!mediaStore) {
            NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                inDomains:NSUserDomainMask].firstObject;
            NSURL *directory = [[support URLByAppendingPathComponent:@"RUIN" isDirectory:YES]
                URLByAppendingPathComponent:@"RetainedMedia" isDirectory:YES];
            BOOL isDirectory = NO;
            if (directory && (create || ([NSFileManager.defaultManager fileExistsAtPath:directory.path
                isDirectory:&isDirectory] && isDirectory)))
                mediaStore = [[RUINRetainedMediaStore alloc] initWithDirectoryURL:directory error:NULL];
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

// Called on the managed object's context. A store must be the current native
// account's Line.sqlite in the OS-authorized/mapped LINE group, not a guessed
// container or another account's database.
static NSDictionary *Scope(NSManagedObject *message) {
    if (message.isDeleted || message.objectID.isTemporaryID ||
        ![message.entity.name isEqual:@"Message"]) return nil;
    NSDictionary *key = ArchiveKey(RUINHistoryMessageKey(message));
    if (!key.count || ![key[@"kind"] isEqual:@"talk"]) return nil;
    NSString *chatID = key[@"chat"];
    if (chatID.length != 33 || ![@"ucr" containsString:[chatID substringToIndex:1]] ||
        [chatID rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet
            options:0 range:NSMakeRange(1, 32)].location != NSNotFound) return nil;
    NSURL *storeURL = message.objectID.persistentStore.URL;
    if (!storeURL.isFileURL || ![storeURL.lastPathComponent isEqual:@"Line.sqlite"]) return nil;
    NSString *accountName = storeURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.lastPathComponent;
    NSUserDefaults *profile = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.linecorp.line"];
    id mid = [profile objectForKey:@"mid"];
    if (![mid isKindOfClass:NSString.class] || [mid length] != 33 || ![mid hasPrefix:@"u"] ||
        ![@[[@"P_" stringByAppendingString:mid], [@"S_" stringByAppendingString:mid]] containsObject:accountName]) return nil;
    NSURL *group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.com.linecorp.line"];
    NSURL *account = [[group URLByAppendingPathComponent:@"Library/Application Support/PrivateStore" isDirectory:YES]
        URLByAppendingPathComponent:accountName isDirectory:YES];
    NSURL *expectedStore = [account URLByAppendingPathComponent:@"Messages/Line.sqlite" isDirectory:NO];
    if (!SameFile(storeURL, expectedStore)) return nil;
    NSAttributeDescription *attribute = message.entity.attributesByName[@"contentType"];
    if (!attribute || ![@[@(NSInteger16AttributeType), @(NSInteger32AttributeType), @(NSInteger64AttributeType)]
        containsObject:@(attribute.attributeType)]) return nil;
    id type = [message valueForKey:@"contentType"];
    if (![type isKindOfClass:NSNumber.class] || !strchr("csilqCSILQ", [type objCType][0])) return nil;
    NSMutableArray *accounts = [NSMutableArray arrayWithObject:account];
    for (NSString *subpath in @[@"Library/Caches/PrivateStore"])
        [accounts addObject:[[group URLByAppendingPathComponent:subpath isDirectory:YES]
            URLByAppendingPathComponent:accountName isDirectory:YES]];
    for (NSNumber *directory in @[@(NSApplicationSupportDirectory), @(NSCachesDirectory)]) {
        NSURL *local = [NSFileManager.defaultManager URLsForDirectory:directory.unsignedIntegerValue
            inDomains:NSUserDomainMask].firstObject;
        if (local) [accounts addObject:[[local URLByAppendingPathComponent:@"PrivateStore" isDirectory:YES]
            URLByAppendingPathComponent:accountName isDirectory:YES]];
    }
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
    return @{@"key":key, @"roots":[roots copy], @"contentType":type};
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
                          NSURL *source, NSData *data, NSString *extension) {
    NSDictionary *key = scope[@"key"];
    for (NSDictionary *item in [store itemsForKey:key]) if ([item[@"role"] isEqual:role]) return;
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

static void Capture(id value, NSDictionary *messageKey, BOOL unsent) {
    if (!Enabled() || captureDepth || ![value isKindOfClass:NSManagedObject.class]) return;
    NSManagedObject *message = value;
    NSManagedObjectContext *context = message.managedObjectContext;
    NSDictionary *requested = ArchiveKey(messageKey);
    if (!context || !requested.count) return;
    atomic_fetch_add(&captureRequests, 1);
    [context performBlockAndWait:^{ @try {
        captureDepth++;
        NSDictionary *scope = Scope(message);
        if (!scope || ![scope[@"key"] isEqual:requested]) { atomic_fetch_add(&scopeRejections, 1); return; }
        NSInteger type = [scope[@"contentType"] integerValue];
        BOOL media = [@[@1, @2, @3, @14] containsObject:@(type)];
        RUINRetainedMediaStore *store = Store(media || unsent);
        if (!store) return;
        // Tombstones may have lost contentType/metadata already. Mark a prior
        // archive even then, before startup synchronization continues cleanup.
        if (unsent &&
            ![store isUnsentForKey:requested] && [store markUnsentForKey:requested]) NotifyChanged(requested);
        if (!media) return;
        NSMutableDictionary *selectors = [NSMutableDictionary dictionary];
        if (type == 1) { selectors[@"imageFileURL"] = @"photo"; selectors[@"cacheableImagePathURL"] = @"photo"; selectors[@"livePhotoFileURL"] = @"livePhoto"; }
        if (type == 2 || type == 14) selectors[@"attachedFileURL"] = AttachedRole(type);
        if (type == 3) selectors[@"audioFileURL"] = @"audio";
        if (type == 1 || type == 2) selectors[@"thumbnailFileURL"] = @"thumbnail";
        NSArray *committed = [store itemsForKey:requested];
        for (NSString *name in selectors) {
            BOOL saved = NO;
            for (NSDictionary *item in committed) if ([item[@"role"] isEqual:selectors[name]]) { saved = YES; break; }
            if (saved) continue;
            id source = MediaValue((id<RUINMessagingMediaFields>)message, name);
            if (![source isKindOfClass:NSURL.class]) continue;
            if (![source isFileURL]) { atomic_fetch_add(&remoteSources, 1); continue; }
            if (![NSFileManager.defaultManager fileExistsAtPath:[source path]]) continue;
            atomic_fetch_add(&localSources, 1);
            CaptureSource(store, scope, selectors[name], source, nil, nil);
        }
        NSAttributeDescription *thumbnail = message.entity.attributesByName[@"thumbnail"];
        id data = thumbnail.attributeType == NSBinaryDataAttributeType ? [message valueForKey:@"thumbnail"] : nil;
        if ((type == 1 || type == 2) && [data isKindOfClass:NSData.class] && [data length]) {
            CGImageSourceRef image = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
            if (image) {
                CFStringRef identifier = CGImageSourceGetType(image);
                NSString *extension = identifier ? [UTType typeWithIdentifier:(__bridge NSString *)identifier].preferredFilenameExtension : nil;
                if (CGImageSourceGetStatus(image) == kCGImageStatusComplete && extension.length)
                    CaptureSource(store, scope, @"thumbnail", nil, [data copy], extension);
                CFRelease(image);
            }
        }
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
        NSDictionary *scope = Scope(message);
        if (![scope[@"key"] isEqual:key] || [scope[@"contentType"] integerValue] != 2) { atomic_fetch_add(&videoRejected, 1); return; }
        if (!URL.isFileURL) { atomic_fetch_add(&remoteSources, 1); return; }
        NSMutableArray *roots = [scope[@"roots"] mutableCopy];
        NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        if (caches) [roots addObject:[caches URLByAppendingPathComponent:@"CacheableVideo" isDirectory:YES]];
        [roots addObject:[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]];
        NSMutableDictionary *videoScope = [scope mutableCopy]; videoScope[@"roots"] = [roots copy];
        RUINRetainedMediaStore *store = Store(YES);
        if (store) CaptureSource(store, videoScope, @"video", [URL copy], nil, nil);
    } @catch (__unused NSException *exception) { atomic_fetch_add(&copyFailures, 1); } }];
}

NSArray<NSDictionary *> *RUINRetainedMediaItems(NSDictionary *messageKey) {
    if (!Enabled()) return @[];
    NSDictionary *key = ArchiveKey(messageKey);
    RUINRetainedMediaStore *store = key.count ? Store(NO) : nil;
    return [store isUnsentForKey:key] ? [store itemsForKey:key] : @[];
}

static id ForwardURL(NSManagedObject *message, NSString *role, id (^original)(void)) {
    BOOL outer = getterDepth++ == 0;
    @try {
        id value = original();
        if (!outer || captureDepth || !Enabled() || !message.managedObjectContext) return value;
        __block NSDictionary *scope = nil;
        [message.managedObjectContext performBlockAndWait:^{ @try { scope = Scope(message); }
            @catch (__unused NSException *exception) {} }];
        if (!scope) return value;
        RUINObserveRetainedMedia(message, scope[@"key"]);
        for (NSDictionary *item in RUINRetainedMediaItems(scope[@"key"]))
            if (([item[@"role"] isEqual:role] || ([role isEqual:@"attached"] &&
                [@[@"video", @"file"] containsObject:item[@"role"]])) && [item[@"URL"] isKindOfClass:NSURL.class]) {
                atomic_fetch_add(&URLReplacements,1); return item[@"URL"];
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
