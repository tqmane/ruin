%config(generator=internal);

#import "RetainedMedia.h"
#import "MessageHistory.h"
#import "MessagingPrivateAPI.h"
#import "SwiftFields.h"
#import "TargetMetadata.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <string.h>
#import <stdatomic.h>

static BOOL installed;
static atomic_int installState;
static atomic_ulong observations, missingMessage, missingURL, missingContext, queued, missingKey;
static atomic_int exportPathShape;
static atomic_ulong nativeAssets, nativeCacheMatches, nativeRangeChecks, nativeCompleteCaches;
static atomic_ulong playerLayers;
static atomic_ulong nativeKeyMatches, nativeOriginMatches, nativeCacheObjects;
static NSString *lastAssetClass, *lastCacheClass, *lastCacheQueueClass, *lastRangeQueueClass;
static char nativeCachePendingKey;
static void ObserveActiveCache(UIViewController *viewer, NSManagedObject *message);

static BOOL Enabled(void) {
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary) &&
        [NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey];
}

static BOOL MethodMatches(Method method, const char *encoding) {
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && !strcmp(actual, encoding);
}

static BOOL CompleteRanges(id ranges, id length) {
    if (![length isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)length) == CFBooleanGetTypeID() ||
        !strchr("csilqCSILQ", [length objCType][0]) || [length longLongValue] <= 0 ||
        ![ranges isKindOfClass:NSArray.class] || ![ranges count] || [ranges count] > 128) return NO;
    NSUInteger size = [length unsignedLongLongValue];
    NSMutableIndexSet *covered = [NSMutableIndexSet indexSet];
    for (id value in ranges) {
        if (![value isKindOfClass:NSValue.class] || strcmp([value objCType], @encode(NSRange))) return NO;
        NSRange range = [value rangeValue];
        if (range.location > size || range.length > size - range.location) return NO;
        [covered addIndexesInRange:range];
    }
    return [covered countOfIndexesInRange:NSMakeRange(0, size)] == size;
}

static void Observe(UIViewController *viewer) {
    if (!Enabled()) return;
    atomic_fetch_add(&observations, 1);
    @try {
        id message = RUINCopySwiftField(viewer, "message");
        if (![message isKindOfClass:NSManagedObject.class]) { atomic_fetch_add(&missingMessage, 1); return; }
        id URL = RUINCopySwiftField(viewer, "videoPlayItem.loadedURLInfo.url");
        // A remote playback URL is resolved through the active native asset below.
        if (![URL isKindOfClass:NSURL.class] || ![URL isFileURL]) {
            id path = RUINCopySwiftField(viewer, "videoDataSource._filePathInTemp");
            atomic_store(&exportPathShape, !path ? 0 : [path isKindOfClass:NSString.class] ? 1 : [path isKindOfClass:NSURL.class] ? 2 : 3);
            URL = [path isKindOfClass:NSString.class] && [path isAbsolutePath] ? [NSURL fileURLWithPath:path] : nil;
        }
        if (![URL isKindOfClass:NSURL.class] || ![URL isFileURL]) {
            atomic_fetch_add(&missingURL, 1);
            ObserveActiveCache(viewer, message);
            return;
        }
        NSURL *source = [URL copy];
        NSManagedObject *object = message;
        // The fullscreen controller owns a managed object directly. Resolve
        // its permanent chat/store/account identity on that object's context.
        NSManagedObjectContext *context = object.managedObjectContext;
        if (!context) { atomic_fetch_add(&missingContext, 1); return; }
        atomic_fetch_add(&queued, 1);
        [context performBlock:^{
            NSDictionary *key = RUINHistoryMessageKey(object);
            if (!key.count) atomic_fetch_add(&missingKey, 1);
            RUINObserveRetainedVideoURL(object, key, source);
        }];
    } @catch (__unused NSException *exception) { }
}

static void ObserveActiveCache(UIViewController *viewer, NSManagedObject *message) {
    if (objc_getAssociatedObject(viewer, &nativeCachePendingKey)) return;
    Class assetClass = NSClassFromString(@"NLCacheableAsset");
    Class cacheClass = NSClassFromString(@"_TtC14CacheableAsset14CacheableCache");
    Class queueClass = NSClassFromString(@"OS_dispatch_queue");
    if (!assetClass || !cacheClass || !queueClass ||
        !MethodMatches(class_getInstanceMethod(assetClass, @selector(cacheKey)), "@16@0:8") ||
        !MethodMatches(class_getInstanceMethod(assetClass, @selector(originURL)), "@16@0:8")) return;
    id key = RUINCopySwiftField(viewer, "videoPlayItem.loadedURLInfo.cacheKey");
    id origin = RUINCopySwiftField(viewer, "videoPlayItem.loadedURLInfo.url");
    if (![key isKindOfClass:NSString.class] || ![key length] || [key length] > 4096 ||
        ![origin isKindOfClass:NSURL.class]) return;
    NSMutableArray<CALayer *> *layers = [NSMutableArray arrayWithObject:viewer.view.layer];
    id cache = nil;
    NSUInteger budget = 256, matches = 0;
    while (layers.count && budget--) {
        CALayer *layer = layers.lastObject; [layers removeLastObject];
        if ([layer isKindOfClass:AVPlayerLayer.class]) {
            id<RUINMessagingCacheableAsset> asset = (id)((AVPlayerLayer *)layer).player.currentItem.asset;
            atomic_fetch_add(&playerLayers, 1);
            lastAssetClass = asset ? NSStringFromClass(object_getClass(asset)) : nil;
            if ([asset isKindOfClass:assetClass]) {
                atomic_fetch_add(&nativeAssets, 1);
                BOOL sameKey = [[asset cacheKey] isEqual:key];
                BOOL sameOrigin = [[asset originURL] isEqual:origin];
                if (sameKey) atomic_fetch_add(&nativeKeyMatches, 1);
                if (sameOrigin) atomic_fetch_add(&nativeOriginMatches, 1);
                // Bind to an exact native identity: original URL or cache key.
                if (sameOrigin || sameKey) {
                    id candidate = RUINCopySwiftField(asset, "loaderDelegate.cache");
                    lastCacheClass = candidate ? NSStringFromClass(object_getClass(candidate)) : nil;
                    if ([candidate isKindOfClass:cacheClass]) {
                        atomic_fetch_add(&nativeCacheObjects, 1); cache = candidate; matches++;
                    }
                }
            }
        }
        [layers addObjectsFromArray:layer.sublayers ?: @[]];
    }
    if (layers.count || matches != 1) return;
    id cacheQueue = RUINCopySwiftField(cache, "queue");
    id rangeQueue = RUINCopySwiftField(cache, "synchronizedRanges.queue");
    lastCacheQueueClass = cacheQueue ? NSStringFromClass(object_getClass(cacheQueue)) : nil;
    lastRangeQueueClass = rangeQueue ? NSStringFromClass(object_getClass(rangeQueue)) : nil;
    NSManagedObjectContext *context = message.managedObjectContext;
    if (!context || ![cacheQueue isKindOfClass:queueClass] || ![rangeQueue isKindOfClass:queueClass]) return;
    atomic_fetch_add(&nativeCacheMatches, 1);
    objc_setAssociatedObject(viewer, &nativeCachePendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIViewController *weakViewer = viewer;
    void (^finished)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakViewer) objc_setAssociatedObject(weakViewer, &nativeCachePendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
    };
    // CacheableAsset owns both queues. Read its mutable range array on the
    // Synchronized queue, never by reflecting it concurrently from UIKit.
    dispatch_async((dispatch_queue_t)cacheQueue, ^{ @try {
        id path = RUINCopySwiftField(cache, "filePath");
        id length = RUINCopySwiftField(cache, "contentLength");
        dispatch_async((dispatch_queue_t)rangeQueue, ^{ @try {
            atomic_fetch_add(&nativeRangeChecks, 1);
            id ranges = RUINCopySwiftField(cache, "synchronizedRanges._value");
            if (!CompleteRanges(ranges, length) || ![path isKindOfClass:NSString.class] || ![path isAbsolutePath]) return;
            atomic_fetch_add(&nativeCompleteCaches, 1);
            NSURL *URL = [NSURL fileURLWithPath:path];
            [context performBlock:^{ RUINObserveRetainedVideoURL(message, RUINHistoryMessageKey(message), URL); }];
        } @catch (__unused NSException *exception) {} @finally { finished(); } });
    } @catch (__unused NSException *exception) { finished(); } });
}

%group RUINVideoViewer
%hook RUINRetainedVideoController
%property (nonatomic, strong) NSTimer *ruin_retainedVideoTimer;
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    Observe(self);
    if (![self ruin_retainedVideoTimer] && Enabled()) {
        __weak UIViewController *viewer = self;
        NSTimer *timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) {
            UIViewController *current = viewer;
            if (current.viewIfLoaded.window) Observe(current);
        }];
        [self setRuin_retainedVideoTimer:timer];
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    }
}
- (void)viewDidLayoutSubviews { %orig; Observe(self); }
- (void)viewWillDisappear:(BOOL)animated {
    Observe(self);
    [[self ruin_retainedVideoTimer] invalidate]; [self setRuin_retainedVideoTimer:nil];
    %orig;
}
%end
%end

void RUINInstallRetainedVideo(void) {
    if (!RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary)) return;
    @synchronized (UIViewController.class) {
        if (installed) return;
        Class cls = NSClassFromString(@"_TtC15LineMessagingUI23ChatVideoViewController");
        if (!cls || ![cls isSubclassOfClass:UIViewController.class]) { atomic_store(&installState, 1); return; }
        for (NSString *name in @[@"viewDidAppear:", @"viewWillDisappear:", @"viewDidLayoutSubviews"]) {
            Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
            const char *encoding = [name hasSuffix:@":"] ? "v20@0:8B16" : "v16@0:8";
            if (!method || strcmp(method_getTypeEncoding(method), encoding)) {
                atomic_store(&installState, [name isEqual:@"viewDidAppear:"] ? 2 : [name isEqual:@"viewWillDisappear:"] ? 3 : 4); return;
            }
        }
        %init(RUINVideoViewer, RUINRetainedVideoController = cls);
        installed = YES; atomic_store(&installState, 5);
    }
}

NSDictionary *RUINRetainedVideoDiagnostics(void) {
    return @{@"installState":@(atomic_load(&installState)), @"observations":@(atomic_load(&observations)),
        @"missingMessage":@(atomic_load(&missingMessage)), @"missingLocalURL":@(atomic_load(&missingURL)),
        @"missingContext":@(atomic_load(&missingContext)), @"queued":@(atomic_load(&queued)),
        @"missingKey":@(atomic_load(&missingKey)), @"exportPathShape":@(atomic_load(&exportPathShape)),
        @"nativeAssets":@(atomic_load(&nativeAssets)),
        @"nativeCacheMatches":@(atomic_load(&nativeCacheMatches)), @"nativeRangeChecks":@(atomic_load(&nativeRangeChecks)),
        @"nativeCompleteCaches":@(atomic_load(&nativeCompleteCaches)), @"playerLayers":@(atomic_load(&playerLayers)),
        @"lastAssetClass":lastAssetClass ?: @"not_observed", @"nativeKeyMatches":@(atomic_load(&nativeKeyMatches)),
        @"nativeOriginMatches":@(atomic_load(&nativeOriginMatches)), @"nativeCacheObjects":@(atomic_load(&nativeCacheObjects)),
        @"lastCacheClass":lastCacheClass ?: @"not_observed", @"lastCacheQueueClass":lastCacheQueueClass ?: @"not_observed",
        @"lastRangeQueueClass":lastRangeQueueClass ?: @"not_observed"};
}
