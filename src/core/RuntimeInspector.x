%config(generator=internal);

#import "RuntimeInspector.h"

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <execinfo.h>
#import <mach-o/dyld.h>
#import <CoreData/CoreData.h>

#import "Features.h"
#import "TargetMetadata.h"
#import "LINEPrivateCalls.h"
#import "SwiftFields.h"
#import "ThemeApplyEvent.h"
extern void RUINRefreshRuntimeReport(void);

static CFStringRef const kInspectorNotification = CFSTR("com.tqmane.ruin.inspect-ui");
enum { kMaxControllers = 96, kMaxControllerDepth = 20, kMaxFieldsEach = 32,
       kMaxViews = 1200, kMaxViewDepth = 24, kMaxControls = 256,
       kMaxTargetsEach = 16, kMaxActionsTotal = 512,
       kMaxAppTabMetadataNodes = 32, kMaxAppTabMetadataDepth = 3,
       kMaxAppTabMetadataFieldsEach = 32, kMaxAppTabMetadataSelectorsEach = 32 };
enum { kStatusPending, kStatusDisabled, kStatusVersionGated, kStatusRegistered,
       kStatusNoWindow, kStatusWriteFailed, kStatusWriteOK };

static atomic_bool gRegistered = ATOMIC_VAR_INIT(false);
static atomic_bool gSnapshotScheduled = ATOMIC_VAR_INIT(false);
static atomic_int gStatus = ATOMIC_VAR_INIT(kStatusPending);
static atomic_uint_fast64_t gNotifications = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gSnapshots = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gControllerCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gFieldNameCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gViewCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gControlCount = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gActionCount = ATOMIC_VAR_INIT(0);
static atomic_bool gTruncated = ATOMIC_VAR_INIT(false);
static atomic_bool gForegroundWindowFound = ATOMIC_VAR_INIT(false);
static NSMutableArray *gNativePresentations;
static NSString *gPresentationEncoding;
static BOOL gPresentationHookInstalled;

static BOOL RUINInspectorEnabled(void) {
    const char *value = getenv("RUIN_ENABLE_RUNTIME_INSPECTOR");
    return value && strcmp(value, "1") == 0;
}

static BOOL RUINInspectorTargetMatches(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    return RUINTargetMetadataMatchesInfo(info);
}

static NSString *RUINClassName(id object) { return NSStringFromClass(object_getClass(object)) ?: @""; }

static NSArray *RUINThemeStoredFields(id object) {
    NSArray *fields = RUINCopySwiftFieldInfo(object, NULL) ?: @[];
    return [fields subarrayWithRange:NSMakeRange(0, MIN(fields.count, 48))];
}

static NSDictionary *RUINThemePackageMetadata(id package) {
    if (![RUINClassName(package) isEqual:@"LineShopThemeInterface.ThemePackage"]) return @{};
    NSMutableDictionary *result = [@{@"class":RUINClassName(package), @"fields":RUINThemeStoredFields(package)} mutableCopy];
    for (NSString *key in @[@"productId", @"isDefaultTheme", @"isOwned", @"isSubscribed", @"installedTime",
                            @"isActivated", @"isGrantedByDefault", @"version", @"validFor",
                            @"remoteURL", @"unzipURL", @"tempZipStoreURL", @"metaStoreURL"]) {
        id value = RUINCopySwiftField(package, key.UTF8String);
        if ([value isKindOfClass:NSNumber.class]) result[key] = value;
        else if ([value isKindOfClass:NSString.class] && [[NSUUID alloc] initWithUUIDString:value]) result[key] = value;
        else if ([value isKindOfClass:NSURL.class]) {
            NSURL *url = value;
            NSString *path = url.path ?: @"";
            if (url.isFileURL) {
                if ([path hasPrefix:NSHomeDirectory()]) path = [@"$APP" stringByAppendingString:[path substringFromIndex:NSHomeDirectory().length]];
                NSRegularExpression *account = [NSRegularExpression regularExpressionWithPattern:@"S_u[0-9a-fA-F]{32}" options:0 error:nil];
                path = [account stringByReplacingMatchesInString:path options:0 range:NSMakeRange(0, path.length) withTemplate:@"S_<account>"];
                NSRegularExpression *group = [NSRegularExpression regularExpressionWithPattern:@"/private/var/mobile/Containers/Shared/AppGroup/[0-9A-Fa-f-]{36}" options:0 error:nil];
                path = [group stringByReplacingMatchesInString:path options:0 range:NSMakeRange(0, path.length) withTemplate:@"APP_GROUP"];
                result[key] = @{@"kind":@"file", @"path":path};
            } else if ([url.scheme.lowercaseString isEqual:@"https"])
                result[key] = @{@"kind":@"https", @"host":url.host ?: @"", @"path":path};
        }
    }
    return result;
}

static NSArray *RUINThemeControllerMetadata(UIViewController *controller) {
    NSString *name = RUINClassName(controller);
    if (![name isEqual:@"LineShopProductSettingsUI.ThemePackageManagementViewController"] &&
        ![name isEqual:@"LineShopProductSettingsUI.ThemeSettingsViewController"]) return @[];
    id model = RUINCopySwiftField(controller, "viewModel");
    if (!model) return @[];
    NSMutableArray *rows = [NSMutableArray arrayWithObject:@{@"path":@"viewModel", @"class":RUINClassName(model), @"fields":RUINThemeStoredFields(model)}];
    id cellModels = RUINCopySwiftField(model, "cellViewModels");
    if ([cellModels isKindOfClass:NSArray.class]) {
        NSUInteger index = 0;
        for (id cell in cellModels) {
            if (index >= 16) break;
            id package = RUINCopySwiftField(cell, "package");
            NSMutableDictionary *entry = [@{@"path":[NSString stringWithFormat:@"cellViewModels[%lu]", (unsigned long)index++],
                @"class":RUINClassName(cell), @"fields":RUINThemeStoredFields(cell),
                @"package":RUINThemePackageMetadata(package)} mutableCopy];
            for (NSString *field in RUINCopySwiftFieldNames(cell)) {
                if ([field hasPrefix:@"_"] || [field isEqual:@"style"]) {
                    id state = RUINCopySwiftField(cell, field.UTF8String);
                    if ([state isKindOfClass:NSNumber.class]) entry[field] = state;
                }
            }
            [rows addObject:entry];
        }
    }
    for (NSString *field in RUINCopySwiftFieldNames(model)) {
        if (rows.count >= 24) break;
        if ([field rangeOfString:@"package" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [field rangeOfString:@"appl" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [field rangeOfString:@"theme" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [field rangeOfString:@"depend" options:NSCaseInsensitiveSearch].location == NSNotFound &&
            [field rangeOfString:@"storage" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        id child = RUINCopySwiftField(model, field.UTF8String);
        if (!child) continue;
        NSMutableDictionary *row = [@{@"path":[@"viewModel." stringByAppendingString:field],
            @"class":RUINClassName(child), @"fields":RUINThemeStoredFields(child)} mutableCopy];
        NSString *fullPath = [@"viewModel." stringByAppendingString:field];
        row[@"fields"] = RUINCopySwiftFieldInfo(controller, fullPath.UTF8String) ?: @[];
        NSDictionary *package = RUINThemePackageMetadata(child);
        if (package.count) row[@"package"] = package;
        [rows addObject:row];
    }
    return rows;
}

static NSArray *RUINNativeReturnPCs(void) {
    void *frames[32]; int count = backtrace(frames, 32);
    uintptr_t base = (uintptr_t)_dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    NSMutableArray *PCs = [NSMutableArray array];
    for (int i = 0; i < count; i++) {
        uintptr_t pc = (uintptr_t)frames[i];
        if (pc >= base && pc < base + 0x9400000)
            [PCs addObject:[NSString stringWithFormat:@"0x%llx", (unsigned long long)(pc - slide)]];
    }
    return PCs;
}

static void RUINRecordPresentation(id owner, UIViewController *presented) {
    if (NSThread.isMainThread && RUINInspectorEnabled() && RUINInspectorTargetMatches() &&
        gNativePresentations.count < 32) {
        NSArray *PCs = RUINNativeReturnPCs();
        if (PCs.count) {
            if (!gNativePresentations) gNativePresentations = [NSMutableArray array];
            [gNativePresentations addObject:@{@"ownerClass":RUINClassName(owner),
                @"presentedClass":RUINClassName(presented), @"nativeReturnPCs":PCs}];
        }
    }
}

%group RUINPresentationInspection
%hook UIViewController
- (void)presentViewController:(UIViewController *)presented animated:(BOOL)animated completion:(void (^)(void))completion
{
    RUINRecordPresentation(self, presented);
    %orig(presented, animated, completion);
}
%end
%end

static void RUINInstallPresentationInspection(void) {
    if (gPresentationHookInstalled) return;
    Method method = class_getInstanceMethod(UIViewController.class,
        @selector(presentViewController:animated:completion:));
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    gPresentationEncoding = encoding ? [NSString stringWithUTF8String:encoding] : nil;
    if (!encoding || strcmp(encoding, "v36@0:8@16B24@?28")) return;
    %init(RUINPresentationInspection);
    gPresentationHookInstalled = YES;
}

void RUINRecordThemePackageInspection(id event, NSString *phase) {
    if (!RUINInspectorEnabled() || !RUINInspectorTargetMatches()) return;
    NSArray *PCs = RUINNativeReturnPCs();
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSMutableArray *events;
        events = events ?: [NSMutableArray array];
        NSDictionary *metadata = RUINThemePackageMetadata(RUINThemePackageFromEvent(event));
        NSMutableArray *payloadTypes = [NSMutableArray array];
        NSString *objectClass = @"nil";
        if ([event isKindOfClass:NSNotification.class]) {
            NSNotification *notification = event;
            if (notification.object) objectClass = RUINClassName(notification.object);
            for (id key in notification.userInfo) {
                if (payloadTypes.count >= 16) break;
                if ([key isKindOfClass:NSString.class] && [key length] <= 128)
                    [payloadTypes addObject:@{@"key":key, @"class":RUINClassName(notification.userInfo[key])}];
            }
        }
        [events addObject:@{@"phase":phase, @"eventClass":event ? RUINClassName(event) : @"nil",
            @"notificationObjectClass":objectClass, @"payloadTypes":payloadTypes,
            @"package":metadata, @"nativeReturnPCs":PCs,
            @"capturedAt":[NSISO8601DateFormatter.new stringFromDate:NSDate.date]}];
        if (events.count > 8) [events removeObjectAtIndex:0];
        NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *directory = [cache URLByAppendingPathComponent:@"RUIN" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *json = [NSJSONSerialization dataWithJSONObject:events options:NSJSONWritingSortedKeys error:nil];
        [json writeToURL:[directory URLByAppendingPathComponent:@"theme-apply-inspection.json"]
            options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
    });
}

// Debug-only observation on the saving context's queue. Values are limited to
// public theme IDs and scalar metadata; no chat content or account IDs.
static void RUINInspectNativeThemeSave(NSNotification *notification) {
    NSManagedObjectContext *context = notification.object;
    if (![context isKindOfClass:NSManagedObjectContext.class]) return;
    NSMutableArray *changes = [NSMutableArray array];
    NSArray *sets = @[context.insertedObjects, context.updatedObjects, context.deletedObjects];
    NSArray *kinds = @[@"insert", @"update", @"delete"];
    for (NSUInteger i = 0; i < sets.count; i++) {
        for (NSManagedObject *object in sets[i]) {
            if (changes.count >= 24 || ![object.entity.name isEqual:@"OwnedThemeProduct"] ||
                ![object.objectID.persistentStore.URL.lastPathComponent isEqual:@"OwnedThemeProduct.sqlite"]) continue;
            NSString *productID = [object primitiveValueForKey:@"productID"];
            if (![productID isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:productID]) continue;
            NSMutableDictionary *row = [@{@"kind":kinds[i], @"productID":productID} mutableCopy];
            NSDictionary *changed = object.changedValues;
            for (NSString *key in @[@"owned", @"grantedByDefault", @"version", @"installedTime", @"availability", @"defaultOrder"])
                if ([changed[key] isKindOfClass:NSNumber.class]) row[key] = changed[key];
            [changes addObject:row];
        }
    }
    if (!changes.count) return;
    NSArray *PCs = RUINNativeReturnPCs();
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSMutableArray *saves;
        saves = saves ?: [NSMutableArray array];
        [saves addObject:@{@"changes":changes, @"nativeReturnPCs":PCs,
            @"capturedAt":[NSISO8601DateFormatter.new stringFromDate:NSDate.date]}];
        if (saves.count > 24) [saves removeObjectAtIndex:0];
        NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *directory = [cache URLByAppendingPathComponent:@"RUIN" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *json = [NSJSONSerialization dataWithJSONObject:saves options:NSJSONWritingSortedKeys error:nil];
        [json writeToURL:[directory URLByAppendingPathComponent:@"theme-store-inspection.json"]
            options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
    });
}

void RUINRecordNativeThemeFetchInspection(id value, id effective, NSUInteger count) {
    if (!RUINInspectorEnabled() || !RUINInspectorTargetMatches() ||
        ![value isKindOfClass:NSFetchRequest.class] || ![effective isKindOfClass:NSFetchRequest.class]) return;
    NSFetchRequest *request = value, *adapted = effective;
    NSArray *PCs = RUINNativeReturnPCs();
    NSDictionary *entry = @{@"predicate":request.predicate.description ?: @"",
        @"effectivePredicate":adapted.predicate.description ?: @"", @"count":@(count),
        @"resultType":@(request.resultType), @"nativeReturnPCs":PCs,
        @"capturedAt":[NSISO8601DateFormatter.new stringFromDate:NSDate.date]};
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSMutableArray *fetches;
        fetches = fetches ?: [NSMutableArray array];
        [fetches addObject:entry];
        if (fetches.count > 96) [fetches removeObjectAtIndex:0];
        NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *directory = [cache URLByAppendingPathComponent:@"RUIN" isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *json = [NSJSONSerialization dataWithJSONObject:fetches options:NSJSONWritingSortedKeys error:nil];
        [json writeToURL:[directory URLByAppendingPathComponent:@"theme-fetch-inspection.json"]
            options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
    });
}

// Fixed chat-controller paths only. Emit names/types, never field values.
static NSArray *RUINReadControllerMetadata(UIViewController *controller) {
    if (![RUINClassName(controller) isEqual:@"LineMessagingUI.ChatViewController"]) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *roots = @[@"chatContext", @"$__lazy_storage_$_chatControllersContainer", @"$__lazy_storage_$_chatControllerAPIGateway", @"chatViewModel"];
    for (NSString *path in roots) {
        id value = RUINCopySwiftField(controller, path.UTF8String);
        if (!value) continue;
        NSArray *names = RUINCopySwiftFieldNames(value) ?: @[];
        [rows addObject:@{@"path":path, @"class":RUINClassName(value), @"fields":names}];
        for (NSString *name in names) {
            if ([name rangeOfString:@"read" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            NSString *childPath = [NSString stringWithFormat:@"%@.%@", path, name];
            id child = RUINCopySwiftField(controller, childPath.UTF8String);
            if (child) [rows addObject:@{@"path":childPath, @"class":RUINClassName(child), @"fields":RUINCopySwiftFieldNames(child) ?: @[]}];
            if (rows.count >= 32) return rows;
        }
    }
    return rows;
}

// Debug-only fixed UI paths. Values are limited to known Bool fields; never
// serialize model descriptions, IDs, font URLs, messages or service tokens.
static NSArray *RUINLocalFeatureControllerMetadata(UIViewController *controller) {
    NSString *className = RUINClassName(controller);
    NSArray<NSString *> *paths = nil;
    if ([className isEqual:@"LineMessagingUI.ChatViewController"]) {
        paths = @[@"chatViewModel.sendButtonLongPressViewModel",
            @"chatViewModel.sendButtonLongPressViewModel.policy",
            @"chatViewModel.sendButtonLongPressViewModel.policy.generalSettingsService",
            @"chatViewModel.sendButtonLongPressViewModel.policy.configurationService",
            @"chatViewModel.sendButtonLongPressViewModel.policy.muteMessageAvailabilityPolicy",
            @"chatViewModel.sendButtonLongPressViewModel.policy.muteMessageAvailabilityPolicy.configurationService",
            @"chatViewModel.sendButtonLongPressViewModel.isMuteSupported",
            @"sendButtonLongPressMenuUIPresenter"];
    } else if ([className isEqual:@"LineSettingsUI.AppIconViewController"] ||
               [className isEqual:@"LineSettingsUI.AppIconApplyBottomSheetViewController"]) {
        paths = @[@"viewModel", @"viewModel.premiumService",
            @"viewModel.premiumService.benefitAvailabilityRepository", @"icon"];
    } else return @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *path in paths) {
        NSString *type = RUINCopySwiftFieldTypeName(controller, path.UTF8String);
        if (!type) continue;
        NSArray *fields = RUINCopySwiftFieldInfo(controller, path.UTF8String) ?: @[];
        if (fields.count > 48) fields = [fields subarrayWithRange:NSMakeRange(0, 48)];
        NSMutableDictionary *row = [@{@"path":path, @"type":type, @"fields":fields} mutableCopy];
        if ([type isEqual:@"Swift.Bool"] &&
            [path hasSuffix:@".isMuteSupported"]) {
            id value = RUINCopySwiftField(controller, path.UTF8String);
            if ([value isKindOfClass:NSNumber.class]) row[@"value"] = @([value boolValue]);
        }
        [rows addObject:row];
    }
    return rows;
}

static void RUINAppendController(UIViewController *controller, NSUInteger depth,
                                NSHashTable *visited, NSMutableArray *output,
                                NSUInteger *fieldBudget, BOOL *truncated) {
    if (!controller) return;
    if (depth > kMaxControllerDepth || output.count >= kMaxControllers) { *truncated = YES; return; }
    if ([visited containsObject:controller]) return;
    [visited addObject:controller];

    NSArray<NSString *> *allNames = *fieldBudget ? (RUINCopySwiftFieldNames(controller) ?: @[]) : @[];
    if (*fieldBudget == 0) *truncated = YES;
    NSUInteger take = MIN(allNames.count, MIN((NSUInteger)kMaxFieldsEach, *fieldBudget));
    if (take < allNames.count) *truncated = YES;
    NSArray *names = [allNames subarrayWithRange:NSMakeRange(0, take)];
    *fieldBudget -= take;
    [output addObject:@{@"class": RUINClassName(controller), @"swiftFieldNames": names,
        @"viewInteractionEnabled":@(controller.viewIfLoaded.userInteractionEnabled),
        @"readControllerMetadata":RUINReadControllerMetadata(controller),
        @"localFeatureMetadata":RUINLocalFeatureControllerMetadata(controller),
        @"themeControllerMetadata":RUINThemeControllerMetadata(controller)}];

    if (controller.presentedViewController)
        RUINAppendController(controller.presentedViewController, depth + 1, visited, output, fieldBudget, truncated);
    if ([controller isKindOfClass:UINavigationController.class]) {
        UIViewController *visible = ((UINavigationController *)controller).visibleViewController;
        if (visible) RUINAppendController(visible, depth + 1, visited, output, fieldBudget, truncated);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
        if (selected) RUINAppendController(selected, depth + 1, visited, output, fieldBudget, truncated);
    }
    for (UIViewController *child in controller.childViewControllers) {
        if (output.count >= kMaxControllers) { *truncated = YES; break; }
        RUINAppendController(child, depth + 1, visited, output, fieldBudget, truncated);
    }
}

static BOOL RUINAppTabTextContains(NSString *text, NSArray<NSString *> *terms) {
    for (NSString *term in terms)
        if ([text rangeOfString:term options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static BOOL RUINAppTabTextAllowed(NSString *text) {
    return !RUINAppTabTextContains(text, @[@"auth", @"token", @"credential", @"user", @"profile", @"chat", @"message"]);
}

static BOOL RUINAppTabHasComponent(NSString *text, NSString *component) {
    NSCharacterSet *alphanumeric = NSCharacterSet.alphanumericCharacterSet;
    NSCharacterSet *uppercase = NSCharacterSet.uppercaseLetterCharacterSet;
    NSCharacterSet *lowercase = NSCharacterSet.lowercaseLetterCharacterSet;
    NSRange search = NSMakeRange(0, text.length);
    while (search.length) {
        NSRange match = [text rangeOfString:component options:NSCaseInsensitiveSearch range:search];
        if (match.location == NSNotFound) return NO;
        NSUInteger end = NSMaxRange(match);
        BOOL starts = match.location == 0;
        if (!starts) {
            unichar previous = [text characterAtIndex:match.location - 1];
            unichar first = [text characterAtIndex:match.location];
            starts = ![alphanumeric characterIsMember:previous] ||
                ([lowercase characterIsMember:previous] && [uppercase characterIsMember:first]) ||
                ([uppercase characterIsMember:previous] && [uppercase characterIsMember:first]);
        }
        BOOL ends = end == text.length;
        if (!ends) {
            unichar next = [text characterAtIndex:end];
            ends = ![alphanumeric characterIsMember:next] || [uppercase characterIsMember:next];
        }
        if (starts && ends) return YES;
        search = NSMakeRange(NSMaxRange(match), text.length - NSMaxRange(match));
    }
    return NO;
}

static BOOL RUINAppTabHasRelevantComponent(NSString *text) {
    for (NSString *term in @[@"app", @"application", @"root", @"tab", @"manager", @"properties", @"dependency", @"dependencies"])
        if (RUINAppTabHasComponent(text, term)) return YES;
    return NO;
}

static BOOL RUINAppTabFieldAllowed(NSString *name) {
    return RUINAppTabHasRelevantComponent(name);
}

static NSInteger RUINAppTabFieldPriority(NSString *name) {
    if (RUINAppTabHasComponent(name, @"manager")) return 0;
    if (RUINAppTabHasComponent(name, @"tab")) return 1;
    if (RUINAppTabHasComponent(name, @"root")) return 2;
    if (RUINAppTabHasComponent(name, @"properties")) return 3;
    if (RUINAppTabHasComponent(name, @"dependency") || RUINAppTabHasComponent(name, @"dependencies")) return 4;
    if (RUINAppTabHasComponent(name, @"app") || RUINAppTabHasComponent(name, @"application")) return 5;
    return 6;
}

static BOOL RUINAppTabObjectIvarEncoding(const char *encoding) {
    if (!encoding) return NO;
    while (*encoding && strchr("rnNoORV", *encoding)) encoding++;
    return encoding[0] == '@' && (encoding[1] == '\0' || encoding[1] == '"');
}

static BOOL RUINAppTabRelevantObject(NSString *className, NSString *path) {
    NSString *last = [[path componentsSeparatedByString:@"."] lastObject] ?: path;
    return RUINAppTabHasRelevantComponent(className) || RUINAppTabHasRelevantComponent(last);
}

static void RUINAppendAppTabMetadata(id mirrorRoot, NSString * _Nullable mirrorPath,
                                     NSString *path, NSUInteger depth, NSHashTable *visited,
                                     NSMutableArray *nodes, NSUInteger *swiftFieldCount,
                                     NSUInteger *ivarCount, NSUInteger *selectorCount,
                                     BOOL *truncated) {
    if (!mirrorRoot || !RUINAppTabTextAllowed(path)) return;
    const char *fieldPath = mirrorPath.UTF8String;
    NSString *kind = RUINCopySwiftFieldKind(mirrorRoot, fieldPath);
    BOOL isClass = [kind isEqualToString:@"class"];
    BOOL isStruct = [kind isEqualToString:@"struct"];
    if (!isClass && !isStruct) return; // Collections and closures are metadata-only at this stage.
    if (depth > kMaxAppTabMetadataDepth || nodes.count >= kMaxAppTabMetadataNodes) {
        *truncated = YES;
        return;
    }

    id object = isClass ? (mirrorPath ? RUINCopySwiftField(mirrorRoot, fieldPath) : mirrorRoot) : nil;
    if (isClass && (!object || [visited containsObject:object])) return;
    NSString *className = object ? RUINClassName(object) : @"";
    NSString *typeName = object ? className : RUINCopySwiftFieldTypeName(mirrorRoot, fieldPath);
    if (!RUINAppTabTextAllowed(className) || !RUINAppTabTextAllowed(typeName ?: @"")) return;
    if (object) [visited addObject:object];

    BOOL relevantObject = RUINAppTabRelevantObject(className, path);
    NSArray *fieldInfo = (!object || relevantObject) ? (RUINCopySwiftFieldInfo(mirrorRoot, fieldPath) ?: @[]) : @[];
    NSMutableArray *swiftFields = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *swiftFollow = [NSMutableArray array];
    for (NSDictionary *field in fieldInfo) {
        NSString *name = field[@"name"], *type = field[@"type"];
        if (![name isKindOfClass:NSString.class] || ![type isKindOfClass:NSString.class] ||
            !RUINAppTabTextAllowed(name) || !RUINAppTabTextAllowed(type)) continue;
        if (swiftFields.count < kMaxAppTabMetadataFieldsEach) {
            NSString *fullPath = [path stringByAppendingFormat:@".%@", name];
            [swiftFields addObject:@{@"name":name, @"type":type, @"path":fullPath}];
            (*swiftFieldCount)++;
        } else *truncated = YES;
        BOOL followsPath = RUINAppTabFieldAllowed(name) &&
            [type rangeOfString:@"->"].location == NSNotFound &&
            [type rangeOfString:@"Closure" options:NSCaseInsensitiveSearch].location == NSNotFound;
        BOOL followable = depth < kMaxAppTabMetadataDepth && followsPath;
        if (followable && swiftFollow.count < kMaxAppTabMetadataFieldsEach)
            [swiftFollow addObject:@{@"name":name, @"path":[mirrorPath length] ? [mirrorPath stringByAppendingFormat:@".%@", name] : name,
                                     @"fullPath":[path stringByAppendingFormat:@".%@", name]}];
        else if ((followable && swiftFollow.count >= kMaxAppTabMetadataFieldsEach) ||
                 (depth >= kMaxAppTabMetadataDepth && followsPath)) *truncated = YES;
    }
    [swiftFollow sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSInteger a = RUINAppTabFieldPriority(left[@"name"]), b = RUINAppTabFieldPriority(right[@"name"]);
        return a < b ? NSOrderedAscending : a > b ? NSOrderedDescending : [left[@"name"] compare:right[@"name"]];
    }];

    NSMutableDictionary *row = [@{@"path":path, @"kind":kind, @"type":typeName ?: @"unknown",
        @"swiftFields":swiftFields, @"objcIvars":@[], @"selectors":@[]} mutableCopy];
    if (object) row[@"class"] = className;
    [nodes addObject:row];

    for (NSDictionary *field in swiftFollow) {
        NSString *childPath = field[@"path"];
        NSString *childKind = RUINCopySwiftFieldKind(mirrorRoot, childPath.UTF8String);
        if ([childKind isEqualToString:@"class"]) {
            id child = RUINCopySwiftField(mirrorRoot, childPath.UTF8String);
            RUINAppendAppTabMetadata(child, nil, field[@"fullPath"], depth + 1, visited, nodes,
                swiftFieldCount, ivarCount, selectorCount, truncated);
        } else if ([childKind isEqualToString:@"struct"]) {
            RUINAppendAppTabMetadata(mirrorRoot, childPath, field[@"fullPath"], depth + 1, visited, nodes,
                swiftFieldCount, ivarCount, selectorCount, truncated);
        }
    }

    if (!object) return;
    NSMutableArray *ivars = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *ivarFollow = [NSMutableArray array];
    NSMutableSet<NSString *> *seenIvars = [NSMutableSet set];
    for (Class cls = object_getClass(object); cls && cls != NSObject.class; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *list = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            Ivar ivar = list[index];
            const char *rawName = ivar_getName(ivar), *rawType = ivar_getTypeEncoding(ivar);
            if (!rawName || !rawType) continue;
            NSString *name = [NSString stringWithUTF8String:rawName];
            NSString *type = [NSString stringWithUTF8String:rawType];
            NSString *declaringClass = NSStringFromClass(cls) ?: @"";
            if (!name || !type || [seenIvars containsObject:name] ||
                !RUINAppTabTextAllowed(name) || !RUINAppTabTextAllowed(type) ||
                !RUINAppTabTextAllowed(declaringClass)) continue;
            BOOL allowedPath = RUINAppTabFieldAllowed(name) && RUINAppTabObjectIvarEncoding(rawType);
            BOOL follow = depth < kMaxAppTabMetadataDepth && allowedPath;
            if (depth >= kMaxAppTabMetadataDepth && allowedPath) *truncated = YES;
            if (!relevantObject && !follow) continue;
            [seenIvars addObject:name];
            if (ivars.count >= kMaxAppTabMetadataFieldsEach) { *truncated = YES; break; }
            [ivars addObject:@{@"name":name, @"type":type, @"declaringClass":declaringClass}];
            (*ivarCount)++;
            if (follow) {
                // Inspector enumerates fields dynamically and the internal
                // Logos target has no Substrate; object encodings were checked.
                id child = object_getIvar(object, ivar);
                if (child) [ivarFollow addObject:@{@"name":name, @"object":child,
                    @"fullPath":[path stringByAppendingFormat:@".%@", name]}];
            }
        }
        free(list);
        if (ivars.count >= kMaxAppTabMetadataFieldsEach) break;
    }
    row[@"objcIvars"] = ivars;
    [ivarFollow sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSInteger a = RUINAppTabFieldPriority(left[@"name"]), b = RUINAppTabFieldPriority(right[@"name"]);
        return a < b ? NSOrderedAscending : a > b ? NSOrderedDescending : [left[@"name"] compare:right[@"name"]];
    }];
    for (NSDictionary *field in ivarFollow)
        RUINAppendAppTabMetadata(field[@"object"], nil, field[@"fullPath"], depth + 1, visited,
            nodes, swiftFieldCount, ivarCount, selectorCount, truncated);

    if (relevantObject) {
        NSMutableArray *selectors = [NSMutableArray array];
        unsigned int count = 0;
        Method *methods = class_copyMethodList(object_getClass(object), &count);
        for (unsigned int index = 0; index < count; index++) {
            NSString *name = NSStringFromSelector(method_getName(methods[index]));
            const char *rawEncoding = method_getTypeEncoding(methods[index]);
            NSString *encoding = rawEncoding ? [NSString stringWithUTF8String:rawEncoding] : nil;
            if (!name || !encoding || !RUINAppTabTextAllowed(name) || !RUINAppTabTextAllowed(encoding) ||
                !RUINAppTabHasRelevantComponent(name)) continue;
            if (selectors.count >= kMaxAppTabMetadataSelectorsEach) { *truncated = YES; break; }
            [selectors addObject:@{@"selector":name, @"encoding":encoding}];
            (*selectorCount)++;
        }
        free(methods);
        row[@"selectors"] = selectors;
    }
}

static NSDictionary *RUINAppTabMetadata(void) {
    id delegate = UIApplication.sharedApplication.delegate;
    if (!delegate) return @{@"status":@"no_delegate", @"nodes":@[],
        @"counts":@{@"nodes":@0, @"swiftFields":@0, @"objcIvars":@0, @"selectors":@0}, @"truncated":@NO};
    NSString *rootClass = RUINClassName(delegate);
    if (!RUINAppTabTextAllowed(rootClass)) return @{@"status":@"filtered_root", @"nodes":@[],
        @"counts":@{@"nodes":@0, @"swiftFields":@0, @"objcIvars":@0, @"selectors":@0}, @"truncated":@NO};
    NSMutableArray *nodes = [NSMutableArray array];
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
    NSUInteger swiftFieldCount = 0, ivarCount = 0, selectorCount = 0;
    BOOL truncated = NO;
    RUINAppendAppTabMetadata(delegate, nil, @"UIApplication.delegate", 0, visited, nodes,
        &swiftFieldCount, &ivarCount, &selectorCount, &truncated);
    for (NSString *name in @[@"lineTabBarControllerManager", @"tabBarController"]) {
        SEL selector = NSSelectorFromString(name);
        Method getter = class_getInstanceMethod(object_getClass(delegate), selector);
        if (!getter || strcmp(method_getTypeEncoding(getter), "@16@0:8")) continue;
        @try {
            id<RUINLINEAppDelegateCalls> appDelegate = delegate;
            id object = [name isEqualToString:@"lineTabBarControllerManager"]
                ? [appDelegate lineTabBarControllerManager] : [appDelegate tabBarController];
            if (object) RUINAppendAppTabMetadata(object, nil,
                [@"UIApplication.delegate." stringByAppendingString:name], 1, visited, nodes,
                &swiftFieldCount, &ivarCount, &selectorCount, &truncated);
        } @catch (__unused NSException *exception) { truncated = YES; }
    }
    return @{@"status":nodes.count ? @"captured" : @"no_matching_metadata",
        @"rootClass":rootClass, @"nodes":nodes,
        @"counts":@{@"nodes":@(nodes.count), @"swiftFields":@(swiftFieldCount),
                    @"objcIvars":@(ivarCount), @"selectors":@(selectorCount)},
        @"truncated":@(truncated)};
}

static void RUINAppendControl(UIControl *control, NSMutableArray *output,
                              NSUInteger *actionBudget, BOOL *truncated) {
    if (output.count >= kMaxControls) { *truncated = YES; return; }
    NSMutableArray *actions = [NSMutableArray array];
    NSUInteger targetCount = 0;
    for (id target in control.allTargets) {
        if (targetCount++ == kMaxTargetsEach) { *truncated = YES; break; }
        NSString *targetClass = RUINClassName(target);
        for (NSString *selectorName in [control actionsForTarget:target forControlEvent:UIControlEventTouchUpInside]) {
            if (*actionBudget == 0) { *truncated = YES; break; }
            [actions addObject:@{@"targetClass": targetClass, @"selector": selectorName}];
            (*actionBudget)--;
        }
        if (*actionBudget == 0) break;
    }
    NSMutableDictionary *entry = [@{@"class": RUINClassName(control), @"touchUpInside": actions} mutableCopy];
    if ([RUINClassName(control) isEqual:@"LineMessagingUI.ChatInputBarButton"]) {
        entry[@"kindType"] = RUINCopySwiftFieldTypeName(control, "kind") ?: @"missing";
        entry[@"kind"] = RUINCopySwiftEnumCaseName(control, "kind") ?: @"unresolved";
        entry[@"frameInWindow"] = NSStringFromCGRect([control convertRect:control.bounds toView:control.window]);
        entry[@"hidden"] = @(control.hidden);
    }
    [output addObject:entry];
}

static void RUINAppendView(UIView *view, NSUInteger depth, NSMutableArray *views,
                          NSMutableArray *controls, NSUInteger *actionBudget, BOOL *truncated) {
    if (depth > kMaxViewDepth || views.count >= kMaxViews) { *truncated = YES; return; }
    if (view.hidden || view.alpha <= 0.01) return;
    [views addObject:RUINClassName(view)];
    if ([view isKindOfClass:UIControl.class]) RUINAppendControl((UIControl *)view, controls, actionBudget, truncated);
    for (UIView *child in view.subviews) {
        if (views.count >= kMaxViews) { *truncated = YES; break; }
        RUINAppendView(child, depth + 1, views, controls, actionBudget, truncated);
    }
}

static UIWindow *RUINForegroundKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindow *window = ((UIWindowScene *)scene).keyWindow;
        if (window && !window.hidden && window.alpha > 0.01) return window;
    }
    return nil;
}

static void RUINInspectShopImages(UIView *view, NSURL *directory, NSUInteger depth) {
    if (!view || view.hidden || depth > kMaxViewDepth) return;
    if ([view isKindOfClass:WKWebView.class]) {
        WKWebView *web = (WKWebView *)view;
        web.inspectable = YES;
        NSString *host = web.URL.host.lowercaseString ?: @"";
        NSDictionary *origin = @{@"scheme": web.URL.scheme ?: @"", @"host":host,
            @"path": [web.URL.scheme.lowercaseString isEqual:@"https"] ? (web.URL.path ?: @"") : @""};
        NSData *originJSON = [NSJSONSerialization dataWithJSONObject:origin options:NSJSONWritingSortedKeys error:nil];
        [originJSON writeToURL:[directory URLByAppendingPathComponent:@"shop-web-origin.json"]
            options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
        BOOL shopHost = [host hasSuffix:@".line.me"] || [host hasSuffix:@".line-apps.com"] ||
            [host hasSuffix:@".line-scdn.net"];
        if (shopHost) {
            // Public shop assets only: exclude cookies, headers, query tokens,
            // page text and unrelated LIFF pages from the inspection report.
            NSString *script = @"(() => { "
                "const safe = s => {try { const u = new URL(s, location.href); if(u.protocol !== 'https:') return null; "
                "return {host:u.hostname,path:u.pathname}; }catch(e){return null;}}; "
                "if (!/shop|theme|着せかえ/i.test(document.title + location.host + location.pathname)) return {page:safe(location.href)}; "
                "return {page:safe(location.href),imageFixCount:(window.__ruinThemeImagesV1||{}).normalized||0,images:Array.from(document.images).slice(0,80).map(i=>"
                "({url:safe(i.currentSrc||i.src),complete:i.complete,width:i.naturalWidth,height:i.naturalHeight})),"
                "resources:performance.getEntriesByType('resource').filter(e=>e.initiatorType==='img').slice(-80).map(e=>"
                "({url:safe(e.name),status:e.responseStatus||0,duration:e.duration}))}; })()";
            [web evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
                if (error || ![result isKindOfClass:NSDictionary.class]) return;
                NSMutableDictionary *report = [result mutableCopy];
                report[@"capturedAt"] = [NSISO8601DateFormatter.new stringFromDate:NSDate.date];
                NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
                [json writeToURL:[directory URLByAppendingPathComponent:@"shop-web-inspection.json"]
                    options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
            }];
        }
    }
    for (UIView *child in view.subviews) RUINInspectShopImages(child, directory, depth + 1);
}

static void RUINWriteSnapshot(void) {
    UIWindow *window = RUINForegroundKeyWindow();
    NSMutableArray *controllers = [NSMutableArray array], *views = [NSMutableArray array], *controls = [NSMutableArray array];
    NSUInteger fieldBudget = 2048, actionBudget = kMaxActionsTotal;
    BOOL truncated = NO;
    if (window.rootViewController) {
        NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
        RUINAppendController(window.rootViewController, 0, visited, controllers, &fieldBudget, &truncated);
    }
    if (window) RUINAppendView(window, 0, views, controls, &actionBudget, &truncated);
    atomic_store(&gControllerCount, controllers.count);
    atomic_store(&gFieldNameCount, 2048 - fieldBudget);
    atomic_store(&gViewCount, views.count);
    atomic_store(&gControlCount, controls.count);
    atomic_store(&gActionCount, kMaxActionsTotal - actionBudget);
    atomic_store(&gTruncated, truncated);
    atomic_store(&gForegroundWindowFound, window != nil);
    atomic_fetch_add(&gSnapshots, 1);

    NSDictionary *snapshot = @{@"status": window ? @"captured" : @"no_foreground_key_window",
        @"controllers": controllers, @"views": views, @"controls": controls,
        @"appTabMetadata": RUINAppTabMetadata(),
        @"nativePresentations":gNativePresentations ?: @[],
        @"counts": @{@"controllers": @(controllers.count), @"swiftFieldNames": @(2048 - fieldBudget),
            @"views": @(views.count), @"controls": @(controls.count),
            @"touchUpInsideActions": @(kMaxActionsTotal - actionBudget)},
        @"truncated": @(truncated)};
    NSError *error = nil;
    NSURL *cache = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *directory = [cache URLByAppendingPathComponent:@"RUIN" isDirectory:YES];
    NSDictionary *protection = @{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication};
    BOOL made = directory && [NSFileManager.defaultManager createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:protection error:&error];
    NSData *json = made ? [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingSortedKeys error:&error] : nil;
    NSURL *file = [directory URLByAppendingPathComponent:@"ui-inspection.json"];
    NSDataWritingOptions options = NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
    BOOL wrote = json && [json writeToURL:file options:options error:&error];
    if (made) RUINInspectShopImages(window, directory, 0);
    atomic_store(&gStatus, wrote ? (window ? kStatusWriteOK : kStatusNoWindow) : kStatusWriteFailed);
}

static void RUINInspectionNotification(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    atomic_fetch_add(&gNotifications, 1);
    if (!RUINInspectorEnabled() || !RUINInspectorTargetMatches()) return;
    bool expected = false;
    if (!atomic_compare_exchange_strong(&gSnapshotScheduled, &expected, true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { RUINWriteSnapshot(); RUINRefreshRuntimeReport(); }
        @finally { atomic_store(&gSnapshotScheduled, false); }
    });
}

void InstallRuntimeInspector(void) {
    if (!RUINInspectorEnabled()) { atomic_store(&gStatus, kStatusDisabled); return; }
    if (!RUINInspectorTargetMatches()) { atomic_store(&gStatus, kStatusVersionGated); return; }
    RUINInstallPresentationInspection();
    static dispatch_once_t themeSaveOnce;
    dispatch_once(&themeSaveOnce, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:NSManagedObjectContextWillSaveNotification
            object:nil queue:nil usingBlock:^(NSNotification *notification) { RUINInspectNativeThemeSave(notification); }];
    });
    bool expected = false;
    if (atomic_compare_exchange_strong(&gRegistered, &expected, true))
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            RUINInspectionNotification, kInspectorNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    atomic_store(&gStatus, kStatusRegistered);
}

void RUINRequestRuntimeSnapshot(void) {
    RUINInspectionNotification(NULL, NULL, NULL, NULL, NULL);
}

NSDictionary<NSString *, id> *RuntimeInspectorDiagnostics(void) {
    static NSArray *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ names = @[@"pending", @"disabled", @"version_gated", @"registered", @"no_foreground_key_window", @"write_failed", @"write_ok"]; });
    int status = atomic_load(&gStatus);
    return @{@"status": (status >= 0 && (NSUInteger)status < names.count) ? names[(NSUInteger)status] : @"unknown",
        @"registered": @(atomic_load(&gRegistered)), @"notifications": @(atomic_load(&gNotifications)),
        @"presentationTraceInstalled":@(gPresentationHookInstalled),
        @"presentationMethodEncoding":gPresentationEncoding ?: NSNull.null,
        @"snapshots": @(atomic_load(&gSnapshots)), @"controllers": @(atomic_load(&gControllerCount)),
        @"swiftFieldNames": @(atomic_load(&gFieldNameCount)), @"foregroundWindowFound": @(atomic_load(&gForegroundWindowFound)),
        @"views": @(atomic_load(&gViewCount)), @"controls": @(atomic_load(&gControlCount)),
        @"touchUpInsideActions": @(atomic_load(&gActionCount)), @"truncated": @(atomic_load(&gTruncated))};
}
