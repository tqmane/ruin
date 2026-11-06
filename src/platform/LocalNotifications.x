%config(generator=internal);

#import "LocalNotifications.h"
#import <CoreFoundation/CoreFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <math.h>
#import <stdint.h>

NSString *const RUINLocalNotificationsEnabledDefaultsKey = @"RUINLocalNotificationsEnabled";

static const NSUInteger kMaximumIdentityLength = 512;
static const NSUInteger kMaximumRecentIdentities = 256;
static const NSTimeInterval kMaximumMessageAge = 5 * 60;
static const NSTimeInterval kMaximumFutureSkew = 60;
static const double kMaximumExactInteger = 9007199254740991.0;
static NSString *const kRUINLocalDefaultTitle = @"LINE";
static NSString *const kRUINLocalGenericBody = @"新着メッセージを受信しました";
static NSString *const kRUINLocalAttachmentBody = @"添付ファイルを受信しました";

typedef NS_ENUM(NSUInteger, RUINLocalSnapshotDisposition) {
    RUINLocalSnapshotRejected,
    RUINLocalSnapshotDuplicate,
    RUINLocalSnapshotSeenWithoutNotification,
    RUINLocalSnapshotShouldNotify
};

static NSDate *RUINLocalEnableCutoff(BOOL *hasObserved, BOOL *wasEnabled,
    NSDate *cutoff, BOOL enabled, NSDate *now)
{
    if (!*hasObserved) {
        *hasObserved = YES;
        *wasEnabled = enabled;
        return enabled ? now : nil;
    }
    if (*wasEnabled == enabled) return cutoff;
    *wasEnabled = enabled;
    return enabled ? now : nil;
}

static BOOL RUINLocalStrictBoolean(id value, BOOL *result)
{
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return NO;
    if (result) *result = [value boolValue];
    return YES;
}

static BOOL RUINLocalIntegerNumber(id value, long long *result)
{
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    if (!isfinite(number) || trunc(number) != number || fabs(number) > kMaximumExactInteger) return NO;
    if (result) *result = (long long)number;
    return YES;
}

static BOOL RUINLocalIdentityString(id value)
{
    if (![value isKindOfClass:NSString.class] || ![value length] ||
        [value length] > kMaximumIdentityLength) return NO;
    return [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] > 0;
}

static NSString *RUINLocalIdentityDigest(NSDictionary *snapshot)
{
    NSArray *identity = @[snapshot[@"store"], snapshot[@"kind"], snapshot[@"chat"], snapshot[@"message"]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:identity options:0 error:NULL];
    if (!data || data.length > UINT32_MAX) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (!CC_SHA256(data.bytes, (CC_LONG)data.length, digest)) return nil;
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static BOOL RUINLocalRememberDigest(NSMutableArray<NSString *> *recent,
    NSMutableSet<NSString *> *recentSet, NSString *digest, NSUInteger limit)
{
    if (!digest.length || !limit || [recentSet containsObject:digest]) return NO;
    [recent addObject:digest];
    [recentSet addObject:digest];
    while (recent.count > limit) {
        [recentSet removeObject:recent.firstObject];
        [recent removeObjectAtIndex:0];
    }
    return YES;
}

static BOOL RUINLocalDigestIsValid(id value)
{
    if (![value isKindOfClass:NSString.class] || [value length] != CC_SHA256_DIGEST_LENGTH * 2) return NO;
    for (NSUInteger i = 0; i < [value length]; i++) {
        unichar c = [value characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return NO;
    }
    return YES;
}

static NSString *RUINLocalDisplayText(id value, NSString *fallback, NSUInteger limit)
{
    if (![value isKindOfClass:NSString.class] || [value length] > 4096) return nil;
    NSString *text = value;
    if (![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)
        return fallback;
    if (text.length <= limit) return [text copy];
    NSRange range = [text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, limit)];
    return [[text substringToIndex:NSMaxRange(range)] copy];
}

// Pure policy shared by production and the host check; the caller supplies the
// UIKit-derived state so the host check never touches UIApplication.
static BOOL RUINLocalEvaluateSnapshot(NSDictionary *snapshot, BOOL enabled,
    BOOL hasBeenForegroundActive, NSDate *activationBaseline, NSDate *enableCutoff,
    NSDate *now, NSString **digestOut, NSString **titleOut, NSString **bodyOut,
    BOOL *isOutgoingOut, BOOL *mutedOut)
{
    if (digestOut) *digestOut = nil;
    if (titleOut) *titleOut = nil;
    if (bodyOut) *bodyOut = nil;
    if (isOutgoingOut) *isOutgoingOut = NO;
    if (mutedOut) *mutedOut = NO;
    if (!enabled || !hasBeenForegroundActive || !activationBaseline || !enableCutoff || !now ||
        ![snapshot isKindOfClass:NSDictionary.class]) return NO;

    for (NSString *key in @[@"store", @"kind", @"chat", @"message"])
        if (!RUINLocalIdentityString(snapshot[key])) return NO;

    BOOL isOutgoing = NO, mutedOrSilent = NO;
    if (!RUINLocalStrictBoolean(snapshot[@"isOutgoing"], &isOutgoing) ||
        !RUINLocalStrictBoolean(snapshot[@"muted"], &mutedOrSilent)) return NO;

    long long timestampMs = 0, contentType = 0;
    if (!RUINLocalIntegerNumber(snapshot[@"timestampMs"], &timestampMs) || timestampMs <= 0 ||
        !RUINLocalIntegerNumber(snapshot[@"contentType"], &contentType)) return NO;
    (void)contentType;
    double timestamp = timestampMs / 1000.0;
    double current = now.timeIntervalSince1970;
    double baseline = activationBaseline.timeIntervalSince1970;
    double enable = enableCutoff.timeIntervalSince1970;
    if (!isfinite(timestamp) || !isfinite(current) || !isfinite(baseline) || !isfinite(enable) ||
        timestamp < baseline || timestamp < enable || timestamp > current + kMaximumFutureSkew ||
        current - timestamp > kMaximumMessageAge) return NO;

    NSString *digest = RUINLocalIdentityDigest(snapshot);
    NSString *title = RUINLocalDisplayText(snapshot[@"title"], kRUINLocalDefaultTitle, 120);
    NSString *fallbackBody = contentType ? kRUINLocalAttachmentBody : kRUINLocalGenericBody;
    NSString *body = RUINLocalDisplayText(snapshot[@"body"], fallbackBody, 500);
    if (!digest || !title || !body) return NO;
    if (digestOut) *digestOut = digest;
    if (titleOut) *titleOut = title;
    if (bodyOut) *bodyOut = body;
    if (isOutgoingOut) *isOutgoingOut = isOutgoing;
    if (mutedOut) *mutedOut = mutedOrSilent;
    return YES;
}

static RUINLocalSnapshotDisposition RUINLocalPrepareSnapshot(NSDictionary *snapshot,
    BOOL enabled, BOOL isBackground, BOOL hasBeenForegroundActive, NSDate *activationBaseline,
    NSDate *enableCutoff, NSDate *now, NSMutableArray<NSString *> *recent,
    NSMutableSet<NSString *> *recentSet, NSString **digestOut, NSString **titleOut, NSString **bodyOut)
{
    NSString *digest = nil, *title = nil, *body = nil;
    BOOL isOutgoing = NO, mutedOrSilent = NO;
    if (!RUINLocalEvaluateSnapshot(snapshot, enabled, hasBeenForegroundActive, activationBaseline,
        enableCutoff, now, &digest, &title, &body, &isOutgoing, &mutedOrSilent) || isOutgoing)
        return RUINLocalSnapshotRejected;
    if ([recentSet containsObject:digest]) return RUINLocalSnapshotDuplicate;
    if (!RUINLocalRememberDigest(recent, recentSet, digest, kMaximumRecentIdentities))
        return RUINLocalSnapshotDuplicate;
    if (digestOut) *digestOut = digest;
    if (titleOut) *titleOut = title;
    if (bodyOut) *bodyOut = body;
    return isBackground && !mutedOrSilent
        ? RUINLocalSnapshotShouldNotify : RUINLocalSnapshotSeenWithoutNotification;
}

#if !defined(RUIN_LOCAL_NOTIFICATIONS_HOST_CHECK)

#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import "Features.h"
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdlib.h>
#import <string.h>

static NSString *const kRUINLocalRequestPrefix = @"com.ruin.local.";
static NSString *const kRUINLocalRecentDigestsDefaultsKey = @"RUINLocalNotificationRecentDigests";
static const int64_t kRUINLocalBackgroundTaskMaximumDuration = 20 * NSEC_PER_SEC;

typedef NS_ENUM(int, RUINFetchOperationHookStatus) {
    RUINFetchOperationHookNotAttempted,
    RUINFetchOperationHookWrongBuild,
    RUINFetchOperationHookMissingClass,
    RUINFetchOperationHookMissingMethod,
    RUINFetchOperationHookABIMismatch,
    RUINFetchOperationHookInstallFailed,
    RUINFetchOperationHookInstalled
};

static atomic_bool gInstalled;
static atomic_uint_fast64_t gObservedSnapshots, gSnapshotRejections, gDuplicates;
static atomic_uint_fast64_t gSeenWithoutNotification, gLocalRequestsAccepted, gRequestErrors;
static atomic_uint_fast64_t gBackgroundTaskStarts, gBackgroundTaskBeginFailures;
static atomic_uint_fast64_t gBackgroundTaskEnds, gBackgroundTaskExpirations;
static atomic_bool gBackgroundTaskActive;
static atomic_uint_fast64_t gFetchOperationServiceStartCalls, gFetchOperationServiceShutdownCalls;
static atomic_int gFetchOperationServiceHookStatus;
static NSMutableArray<NSString *> *gRecentDigests;
static NSMutableSet<NSString *> *gRecentDigestSet;
@class RUINLocalNotificationDelegateProxy;
static RUINLocalNotificationDelegateProxy *gDelegateProxy;
static UNUserNotificationCenter *gNotificationCenter;
static BOOL gLifecycleObserverInstalled;
static BOOL gDefaultsObserverInstalled;
static BOOL gHasBeenForegroundActive;
static BOOL gHasObservedEnabledState;
static BOOL gEnabledState;
static BOOL gBackgroundTaskAttemptedThisBackground;
static BOOL gBackgroundTaskIdentifierInitialized;
static UIBackgroundTaskIdentifier gBackgroundTask;
static uint64_t gBackgroundTaskGeneration;
static NSDate *gActivationBaseline;
static NSDate *gEnableCutoff;

static void RUINLocalInstallOnMain(void);
static void RUINLocalMarkActive(void);
static void RUINLocalRefreshEnabledState(void);
static void RUINLocalEndBackgroundTask(uint64_t generation, BOOL expired);
static void RUINLocalApplicationDidEnterBackground(void);
static void RUINLocalApplicationWillEnterForeground(void);
static void RUINLocalInstallFetchOperationServiceHooks(void);

@interface RUINLocalNotificationDelegateProxy : NSObject <UNUserNotificationCenterDelegate>
@property(nonatomic, weak) id<UNUserNotificationCenterDelegate> originalDelegate;
- (void)applicationDidBecomeActive:(NSNotification *)notification;
- (void)applicationDidEnterBackground:(NSNotification *)notification;
- (void)applicationWillEnterForeground:(NSNotification *)notification;
- (void)userDefaultsDidChange:(NSNotification *)notification;
@end

@implementation RUINLocalNotificationDelegateProxy
- (BOOL)respondsToSelector:(SEL)selector
{
    return [super respondsToSelector:selector] || [self.originalDelegate respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector
{
    id<UNUserNotificationCenterDelegate> original = self.originalDelegate;
    return [original respondsToSelector:selector] ? original : [super forwardingTargetForSelector:selector];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    (void)notification;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINLocalMarkActive(); });
        return;
    }
    RUINLocalMarkActive();
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    (void)notification;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINLocalApplicationDidEnterBackground(); });
        return;
    }
    RUINLocalApplicationDidEnterBackground();
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    (void)notification;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINLocalApplicationWillEnterForeground(); });
        return;
    }
    RUINLocalApplicationWillEnterForeground();
}

- (void)userDefaultsDidChange:(NSNotification *)notification
{
    (void)notification;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINLocalRefreshEnabledState(); });
        return;
    }
    RUINLocalRefreshEnabledState();
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    willPresentNotification:(UNNotification *)notification
    withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
    UNNotificationRequest *request = notification.request;
    NSString *digest = [request.identifier hasPrefix:kRUINLocalRequestPrefix]
        ? [request.identifier substringFromIndex:kRUINLocalRequestPrefix.length] : nil;
    if (center == gNotificationCenter && RUINLocalDigestIsValid(digest)) {
        completionHandler(UNNotificationPresentationOptionNone);
        return;
    }
    id<UNUserNotificationCenterDelegate> original = self.originalDelegate;
    if ([original respondsToSelector:_cmd])
        [original userNotificationCenter:center willPresentNotification:notification withCompletionHandler:completionHandler];
    else completionHandler(UNNotificationPresentationOptionNone);
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
    withCompletionHandler:(void (^)(void))completionHandler
{
    UNNotificationRequest *request = response.notification.request;
    NSString *digest = [request.identifier hasPrefix:kRUINLocalRequestPrefix]
        ? [request.identifier substringFromIndex:kRUINLocalRequestPrefix.length] : nil;
    if (center == gNotificationCenter && RUINLocalDigestIsValid(digest)) {
        completionHandler();
        return;
    }
    id<UNUserNotificationCenterDelegate> original = self.originalDelegate;
    if ([original respondsToSelector:_cmd])
        [original userNotificationCenter:center didReceiveNotificationResponse:response withCompletionHandler:completionHandler];
    else completionHandler();
}
@end

static BOOL RUINLocalTargetBuildMatches(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    BOOL bundleMatches = [NSBundle.mainBundle.bundleIdentifier isEqual:RUINTargetBundleIdentifier] ||
        [info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier];
    return bundleMatches && [info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] &&
        [info[@"CFBundleVersion"] isEqual:RUINTargetBuild];
}

static Method RUINLocalOwnMethod(Class cls, SEL selector)
{
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) { result = methods[i]; break; }
    }
    free(methods);
    return result;
}

%group RUINFetchOperationLifecycle
%hook RUINFetchOperationService
- (void)start
{
    atomic_fetch_add(&gFetchOperationServiceStartCalls, 1);
    %orig;
}
- (void)shutdown
{
    atomic_fetch_add(&gFetchOperationServiceShutdownCalls, 1);
    %orig;
}
%end
%end

static void RUINLocalInstallFetchOperationServiceHooks(void)
{
    if (atomic_load(&gFetchOperationServiceHookStatus) == RUINFetchOperationHookInstalled) return;
    if (!RUINLocalTargetBuildMatches()) {
        atomic_store(&gFetchOperationServiceHookStatus, RUINFetchOperationHookWrongBuild);
        return;
    }
    Class cls = objc_getClass("_TtC4LINE21FetchOperationService");
    if (!cls) {
        atomic_store(&gFetchOperationServiceHookStatus, RUINFetchOperationHookMissingClass);
        return;
    }
    SEL startSelector = sel_registerName("start");
    SEL shutdownSelector = sel_registerName("shutdown");
    Method start = RUINLocalOwnMethod(cls, startSelector);
    Method shutdown = RUINLocalOwnMethod(cls, shutdownSelector);
    if (!start || !shutdown) {
        atomic_store(&gFetchOperationServiceHookStatus, RUINFetchOperationHookMissingMethod);
        return;
    }
    // build/message-objc.json records both methods as v16@0:8 for this exact LINE build.
    if (strcmp(method_getTypeEncoding(start), "v16@0:8") ||
        strcmp(method_getTypeEncoding(shutdown), "v16@0:8")) {
        atomic_store(&gFetchOperationServiceHookStatus, RUINFetchOperationHookABIMismatch);
        return;
    }
    IMP startOriginal = method_getImplementation(start);
    IMP shutdownOriginal = method_getImplementation(shutdown);
    if (!startOriginal || !shutdownOriginal) {
        atomic_store(&gFetchOperationServiceHookStatus, RUINFetchOperationHookInstallFailed);
        return;
    }
    %init(RUINFetchOperationLifecycle, RUINFetchOperationService = cls);
    atomic_store(&gFetchOperationServiceHookStatus, RUINFetchOperationHookInstalled);
}

static NSString *RUINLocalFetchOperationServiceHookStatusName(void)
{
    switch (atomic_load(&gFetchOperationServiceHookStatus)) {
        case RUINFetchOperationHookWrongBuild: return @"wrong_build";
        case RUINFetchOperationHookMissingClass: return @"missing_class";
        case RUINFetchOperationHookMissingMethod: return @"missing_method";
        case RUINFetchOperationHookABIMismatch: return @"abi_mismatch";
        case RUINFetchOperationHookInstallFailed: return @"install_failed";
        case RUINFetchOperationHookInstalled: return @"installed";
        default: return @"not_attempted";
    }
}

static void RUINLocalEndBackgroundTask(uint64_t generation, BOOL expired)
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINLocalEndBackgroundTask(generation, expired); });
        return;
    }
    if (generation != gBackgroundTaskGeneration || gBackgroundTask == UIBackgroundTaskInvalid) return;
    UIBackgroundTaskIdentifier task = gBackgroundTask;
    gBackgroundTask = UIBackgroundTaskInvalid;
    gBackgroundTaskGeneration++;
    atomic_store(&gBackgroundTaskActive, false);
    atomic_fetch_add(&gBackgroundTaskEnds, 1);
    if (expired) atomic_fetch_add(&gBackgroundTaskExpirations, 1);
    [UIApplication.sharedApplication endBackgroundTask:task];
}

static void RUINLocalApplicationDidEnterBackground(void)
{
    RUINLocalRefreshEnabledState();
    if (gBackgroundTaskAttemptedThisBackground) return;
    gBackgroundTaskAttemptedThisBackground = YES;
    if (!gHasBeenForegroundActive || !gEnabledState || gBackgroundTask != UIBackgroundTaskInvalid ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) return;

    uint64_t generation = ++gBackgroundTaskGeneration;
    UIApplication *application = UIApplication.sharedApplication;
    UIBackgroundTaskIdentifier task = [application beginBackgroundTaskWithName:@"RUIN local notification observation"
        expirationHandler:^{ RUINLocalEndBackgroundTask(generation, YES); }];
    if (task == UIBackgroundTaskInvalid) {
        atomic_fetch_add(&gBackgroundTaskBeginFailures, 1);
        return;
    }
    gBackgroundTask = task;
    atomic_store(&gBackgroundTaskActive, true);
    atomic_fetch_add(&gBackgroundTaskStarts, 1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kRUINLocalBackgroundTaskMaximumDuration),
        dispatch_get_main_queue(), ^{ RUINLocalEndBackgroundTask(generation, NO); });
}

static void RUINLocalApplicationWillEnterForeground(void)
{
    gBackgroundTaskAttemptedThisBackground = NO;
    RUINLocalEndBackgroundTask(gBackgroundTaskGeneration, NO);
}

static void RUINLocalInstallOnMain(void)
{
    if (!gBackgroundTaskIdentifierInitialized) {
        gBackgroundTask = UIBackgroundTaskInvalid;
        gBackgroundTaskIdentifierInitialized = YES;
    }
    [NSUserDefaults.standardUserDefaults registerDefaults:@{RUINLocalNotificationsEnabledDefaultsKey:@NO}];
    RUINLocalRefreshEnabledState();
    RUINLocalInstallFetchOperationServiceHooks();
    if (!gDelegateProxy) gDelegateProxy = [RUINLocalNotificationDelegateProxy new];
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    gNotificationCenter = center;
    if (center.delegate != gDelegateProxy) {
        gDelegateProxy.originalDelegate = center.delegate;
        center.delegate = gDelegateProxy;
    }
    if (!gLifecycleObserverInstalled) {
        [[NSNotificationCenter defaultCenter] addObserver:gDelegateProxy
            selector:@selector(applicationDidBecomeActive:)
            name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:gDelegateProxy
            selector:@selector(applicationDidEnterBackground:)
            name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:gDelegateProxy
            selector:@selector(applicationWillEnterForeground:)
            name:UIApplicationWillEnterForegroundNotification object:nil];
        gLifecycleObserverInstalled = YES;
    }
    if (!gDefaultsObserverInstalled) {
        [[NSNotificationCenter defaultCenter] addObserver:gDelegateProxy
            selector:@selector(userDefaultsDidChange:)
            name:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults];
        gDefaultsObserverInstalled = YES;
    }
    if (!gHasBeenForegroundActive && UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
        RUINLocalMarkActive();
    atomic_store(&gInstalled, true);
}

static void RUINLocalMarkActive(void)
{
    RUINLocalApplicationWillEnterForeground();
    gHasBeenForegroundActive = YES;
    gActivationBaseline = NSDate.date;
    RUINLocalInstallOnMain();
}

static void RUINLocalRefreshEnabledState(void)
{
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:RUINLocalNotificationsEnabledDefaultsKey];
    gEnableCutoff = RUINLocalEnableCutoff(&gHasObservedEnabledState, &gEnabledState,
        gEnableCutoff, enabled, NSDate.date);
}

void RUINInstallLocalNotifications(void)
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINInstallLocalNotifications(); });
        return;
    }
    RUINLocalInstallOnMain();
}

static NSDictionary *RUINLocalCopiedSnapshot(NSDictionary *snapshot)
{
    if (![snapshot isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *copy = [NSMutableDictionary dictionaryWithCapacity:10];
    for (NSString *key in @[@"store", @"kind", @"chat", @"message", @"title", @"body", @"timestampMs", @"contentType", @"isOutgoing", @"muted"]) {
        id value = snapshot[key];
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) copy[key] = [value copy];
    }
    return [copy copy];
}

static void RUINLocalLoadRecentDigests(void)
{
    if (gRecentDigests) return;
    gRecentDigests = [NSMutableArray array];
    gRecentDigestSet = [NSMutableSet set];
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:kRUINLocalRecentDigestsDefaultsKey];
    if (![stored isKindOfClass:NSArray.class]) return;
    for (id value in stored) {
        if (RUINLocalDigestIsValid(value)) RUINLocalRememberDigest(gRecentDigests, gRecentDigestSet, value, kMaximumRecentIdentities);
    }
}

static void RUINLocalProcessSnapshot(NSDictionary *snapshot)
{
    atomic_fetch_add(&gObservedSnapshots, 1);
    RUINLocalInstallOnMain();
    RUINLocalRefreshEnabledState();
    RUINLocalLoadRecentDigests();
    NSString *digest = nil, *title = nil, *body = nil;
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:RUINLocalNotificationsEnabledDefaultsKey];
    BOOL background = UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
    RUINLocalSnapshotDisposition disposition = RUINLocalPrepareSnapshot(snapshot, enabled, background,
        gHasBeenForegroundActive, gActivationBaseline, gEnableCutoff, NSDate.date,
        gRecentDigests, gRecentDigestSet, &digest, &title, &body);
    if (disposition == RUINLocalSnapshotRejected) {
        atomic_fetch_add(&gSnapshotRejections, 1);
        return;
    }
    if (disposition == RUINLocalSnapshotDuplicate) {
        atomic_fetch_add(&gDuplicates, 1);
        return;
    }
    [NSUserDefaults.standardUserDefaults setObject:[gRecentDigests copy] forKey:kRUINLocalRecentDigestsDefaultsKey];
    if (disposition == RUINLocalSnapshotSeenWithoutNotification) {
        atomic_fetch_add(&gSeenWithoutNotification, 1);
        return;
    }

    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = title;
    content.body = body;
    content.sound = UNNotificationSound.defaultSound;
    NSString *identifier = [kRUINLocalRequestPrefix stringByAppendingString:digest];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                atomic_fetch_add(&gRequestErrors, 1);
                return;
            }
            atomic_fetch_add(&gLocalRequestsAccepted, 1);
        });
    }];
}

void RUINObserveLocalIncomingSnapshot(NSDictionary *copiedFoundationData)
{
    NSDictionary *snapshot = RUINLocalCopiedSnapshot(copiedFoundationData);
    if (!snapshot) {
        atomic_fetch_add(&gSnapshotRejections, 1);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ RUINLocalProcessSnapshot(snapshot); });
}

NSDictionary<NSString *, id> *RUINLocalNotificationDiagnostics(void)
{
    return @{
        @"installed":@(atomic_load(&gInstalled)),
        @"enabled":@([NSUserDefaults.standardUserDefaults boolForKey:RUINLocalNotificationsEnabledDefaultsKey]),
        @"observedSnapshots":@(atomic_load(&gObservedSnapshots)),
        @"snapshotRejections":@(atomic_load(&gSnapshotRejections)),
        @"duplicates":@(atomic_load(&gDuplicates)),
        @"seenWithoutNotification":@(atomic_load(&gSeenWithoutNotification)),
        @"localRequestsAccepted":@(atomic_load(&gLocalRequestsAccepted)),
        @"requestErrors":@(atomic_load(&gRequestErrors)),
        @"backgroundTaskActive":@(atomic_load(&gBackgroundTaskActive)),
        @"backgroundTaskStarts":@(atomic_load(&gBackgroundTaskStarts)),
        @"backgroundTaskBeginFailures":@(atomic_load(&gBackgroundTaskBeginFailures)),
        @"backgroundTaskEnds":@(atomic_load(&gBackgroundTaskEnds)),
        @"backgroundTaskExpirations":@(atomic_load(&gBackgroundTaskExpirations)),
        @"fetchOperationServiceHookStatus":RUINLocalFetchOperationServiceHookStatusName(),
        @"fetchOperationServiceStartCalls":@(atomic_load(&gFetchOperationServiceStartCalls)),
        @"fetchOperationServiceShutdownCalls":@(atomic_load(&gFetchOperationServiceShutdownCalls)),
        @"remoteDeliveryVerified":@NO,
        @"diagnosticsContainMessageContent":@NO
    };
}

#endif
