#import "PushDiagnostics.h"
#import "BundleIdentity.h"
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <os/lock.h>

static os_unfair_lock statusLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary *notificationStatus;

NSDictionary *RUINPushDiagnostics(void) {
    os_unfair_lock_lock(&statusLock);
    NSDictionary *snapshot = notificationStatus;
    os_unfair_lock_unlock(&statusLock);
    return snapshot ?: @{@"settingsQueried":@NO, @"deliveryVerified":@NO};
}

void RUINRefreshPushDiagnostics(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINRefreshPushDiagnostics(); });
        return;
    }
    NSDictionary *info = RUINActualMainBundleInfo();
    NSString *topic = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : @"";
    NSString *original = [info[@"RUINOriginalBundleIdentifier"] isKindOfClass:NSString.class]
        ? info[@"RUINOriginalBundleIdentifier"] : @"";
    NSString *environment = [info[@"RUINPushEnvironment"] isKindOfClass:NSString.class]
        ? info[@"RUINPushEnvironment"] : @"unknown";
    BOOL registered = UIApplication.sharedApplication.isRegisteredForRemoteNotifications;
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        NSDictionary *snapshot = @{
            @"settingsQueried":@YES,
            @"capturedAt":[[NSISO8601DateFormatter new] stringFromDate:NSDate.date],
            @"authorizationStatus":@(settings.authorizationStatus),
            @"alertSetting":@(settings.alertSetting),
            @"soundSetting":@(settings.soundSetting),
            @"badgeSetting":@(settings.badgeSetting),
            @"notificationCenterSetting":@(settings.notificationCenterSetting),
            @"lockScreenSetting":@(settings.lockScreenSetting),
            @"registeredForRemoteNotifications":@(registered),
            @"apsEnvironment":environment,
            @"signedTopicMatchesOriginal":@(original.length && [topic isEqualToString:original]),
            @"deliveryVerified":@NO,
            @"tokensOrPayloadsRecorded":@NO
        };
        [UNUserNotificationCenter.currentNotificationCenter getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *notifications) {
            NSMutableDictionary *complete = [snapshot mutableCopy];
            complete[@"deliveredNotificationCount"] = @(notifications.count);
            NSDate *latest = nil;
            NSDate *latestPush = nil;
            NSMutableDictionary *triggerCounts = [NSMutableDictionary dictionary];
            for (UNNotification *notification in notifications) {
                if (!latest || [notification.date compare:latest] == NSOrderedDescending) latest = notification.date;
                UNNotificationTrigger *trigger = notification.request.trigger;
                NSString *kind = trigger ? NSStringFromClass(trigger.class) : @"immediateLocal";
                triggerCounts[kind] = @([triggerCounts[kind] unsignedIntegerValue] + 1);
                if ([trigger isKindOfClass:UNPushNotificationTrigger.class] &&
                    (!latestPush || [notification.date compare:latestPush] == NSOrderedDescending)) latestPush = notification.date;
            }
            complete[@"deliveredTriggerCounts"] = [triggerCounts copy];
            if (latestPush) complete[@"latestPushDeliveredAt"] = [[NSISO8601DateFormatter new] stringFromDate:latestPush];
            if (latest) complete[@"latestDeliveredAt"] = [[NSISO8601DateFormatter new] stringFromDate:latest];
            NSDictionary *result = [complete copy];
            os_unfair_lock_lock(&statusLock);
            notificationStatus = result;
            os_unfair_lock_unlock(&statusLock);
            NSURL *directory = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject
                URLByAppendingPathComponent:@"RUIN" isDirectory:YES];
            if (!directory) return;
            if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL]) return;
            NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
            [data writeToURL:[directory URLByAppendingPathComponent:@"push.json"] options:NSDataWritingAtomic error:NULL];
        }];
    }];
}
