%config(generator=internal)

#import "TargetMetadata.h"
#import "ThemePrivateAPI.h"
#import "ThemeShop.h"
#import "ThemeFeatures.h"
#import "SwiftFields.h"
#import "ThemeVersion.h"
#import "ThemeProductIdentity.h"
#import "../core/Localization.h"
#import "RuntimeInspector.h"
#import "ThemeApplyEvent.h"
#import "NativeThemeValidation.h"
#import "NativeThemeRegistration.h"

#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdlib.h>
#import <stdatomic.h>
#import <UIKit/UIKit.h>

NSString * const RUINThemeRandomEnabledDefaultsKey = @"enableRandomTheme";
NSString * const RUINThemeShopDownloadEnabledDefaultsKey = @"enableThemeDL";
NSString * const RUINThemeAppliedThemeIDDefaultsKey = @"app.ruin.theme.appliedProductID";
NSString * const RUINThemeDynamicThemeNextUpdateDateDefaultsKey = @"dynamicThemeNextUpdateDate";
NSString * const RUINThemeErrorDomain = @"app.ruin.theme";

static const NSUInteger RUINThemeMaximumInputLength = 256;
static atomic_bool gThemeInstallInvoked = ATOMIC_VAR_INIT(false);
static os_unfair_lock gThemeInstallLock = OS_UNFAIR_LOCK_INIT;

typedef enum {
    RUINThemeHookPending,
    RUINThemeHookVersionGated,
    RUINThemeHookMissingClass,
    RUINThemeHookMissingSelector,
    RUINThemeHookEncodingMismatch,
    RUINThemeHookInstallFailed,
    RUINThemeHookInstalled,
    RUINThemeHookNativeSchedulingPreserved
} RUINThemeHookStatus;

static atomic_int gThemePriceTierStatus = ATOMIC_VAR_INIT(RUINThemeHookPending);
static atomic_uint_fast64_t gThemePriceTierCalls = ATOMIC_VAR_INIT(0);
static atomic_int gThemeApplyObserverStatus = ATOMIC_VAR_INIT(RUINThemeHookPending);
static atomic_int gThemeApplyFailureObserverStatus = ATOMIC_VAR_INIT(RUINThemeHookPending);
static atomic_int gThemeApplyMarkerStatus = ATOMIC_VAR_INIT(RUINThemeHookPending);
static atomic_uint_fast64_t gThemeApplyEvents = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gThemeApplyFailures = ATOMIC_VAR_INIT(0);
static atomic_int gThemeDefaultsFreezeStatus = ATOMIC_VAR_INIT(RUINThemeHookPending);
static os_unfair_lock gThemePendingResetLock = OS_UNFAIR_LOCK_INIT;
static RUINThemeApplyCompletion gThemePendingResetCompletion;
static uint64_t gThemePendingResetID;
static atomic_uint_fast64_t gThemeNextResetID = ATOMIC_VAR_INIT(1);

static NSString *RUINThemeHookStatusNameValue(int status);
static void RUINThemeFinishPendingReset(uint64_t requestID, BOOL applied, NSError *error);

static NSString *RUINThemeNativeUnavailableReason(NSString *operation)
{
    if ([operation isEqualToString:@"Shop download hook"]) {
        return @"LINE exposes no Objective-C onButtonTapped: implementation to bind. The verified LineShopProductDetail priceTier display gate is installed separately.";
    }
    if ([operation isEqualToString:@"Theme removal"]) {
        return @"LINE's theme resource remover is Swift-only metadata here, with no verified Objective-C method ABI. No package file is deleted.";
    }
    if ([operation isEqualToString:@"Theme reset"]) {
        return @"LINE's ThemePackageManagementViewController -didTapResetButton method with ABI v16@0:8 is absent at runtime or the target version gate is closed.";
    }
    if ([operation isEqualToString:@"Theme apply"]) {
        return [NSString stringWithFormat:
            @"%@ requires LINE's DynamicThemeApplier, which has no verified callable Objective-C method ABI in this build. No active-theme state is changed.",
            operation];
    }
    if ([operation isEqualToString:@"Random theme on startup"]) {
        return @"Random selection requires LINE's DynamicThemeApplier, whose callable apply ABI is unverified. The preference is reported, but no theme is selected or applied.";
    }
    if ([operation isEqualToString:@"iPad theme management"]) {
        return @"The catalog, public asset download, and display gate are platform-neutral; reset uses LINE's visible native screen action, while direct apply, removal, and startup random selection remain unavailable.";
    }
    return [NSString stringWithFormat:
        @"%@ is unavailable: LINE exposes the theme engine as Swift-only metadata without a verified Objective-C method ABI. No network request, archive extraction, filesystem change, preference change, or theme application was attempted.",
        operation];
}

static NSError *RUINThemeError(RUINThemeErrorCode code, NSString *operation, NSString *reason)
{
    return [NSError errorWithDomain:RUINThemeErrorDomain
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey: reason,
                               @"operation": operation
                           }];
}

static BOOL RUINThemeFail(NSError **error, NSString *operation)
{
    if (error) {
        *error = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
                                operation,
                                RUINThemeNativeUnavailableReason(operation));
    }
    return NO;
}

static BOOL RUINThemeTargetMatches(void)
{
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
}

static Method RUINThemeOwnMethod(Class cls, SEL selector)
{
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = methods[i];
            break;
        }
    }
    free(methods);
    return found;
}

static BOOL RUINThemeMethodHasEncoding(Class cls, SEL selector, const char *expected)
{
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding && strcmp(encoding, expected) == 0;
}

static BOOL RUINThemeValidUntilIsActive(int64_t value)
{
    if (value <= 0) return NO;
    long double seconds = (long double)value;
    if (seconds > 100000000000000000.0L) seconds /= 1000000000.0L;
    else if (seconds > 100000000000000.0L) seconds /= 1000000.0L;
    else if (seconds > 100000000000.0L) seconds /= 1000.0L;
    return seconds > [NSDate date].timeIntervalSince1970;
}

static BOOL RUINThemeProductDetailHasLocalAccess(id self)
{
    LineShopProductDetail *product = self;
    id type = [product type];
    if (![type isKindOfClass:[NSString class]] || [(NSString *)type caseInsensitiveCompare:@"theme"] != NSOrderedSame)
        return NO;
    BOOL owned = [product isOwned];
    BOOL granted = [product isGrantedByDefault];
    int64_t validUntil = [product validUntil];
    return owned || granted || RUINThemeValidUntilIsActive(validUntil);
}

%group RUINThemePriceTier
%hook LineShopProductDetail
- (int)priceTier
{
    atomic_fetch_add_explicit(&gThemePriceTierCalls, 1, memory_order_relaxed);
    int originalTier = %orig;
    if (atomic_load_explicit(&gThemePriceTierStatus, memory_order_acquire) != RUINThemeHookInstalled ||
        ![[NSUserDefaults standardUserDefaults] boolForKey:RUINThemeShopDownloadEnabledDefaultsKey] ||
        !RUINThemeProductDetailHasLocalAccess(self))
        return originalTier;
    return 0;
}
%end
%end

static void RUINInstallThemePriceTierHook(void)
{
    if (atomic_load(&gThemePriceTierStatus) == RUINThemeHookInstalled) return;
    if (!RUINThemeTargetMatches()) {
        atomic_store(&gThemePriceTierStatus, RUINThemeHookVersionGated);
        return;
    }
    Class cls = objc_lookUpClass("LineShopProductDetail");
    if (!cls) {
        atomic_store(&gThemePriceTierStatus, RUINThemeHookMissingClass);
        return;
    }
    SEL selector = sel_registerName("priceTier");
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        atomic_store(&gThemePriceTierStatus, RUINThemeHookMissingSelector);
        return;
    }
    if (strcmp(method_getTypeEncoding(method) ?: "", "i16@0:8") != 0 ||
        !RUINThemeMethodHasEncoding(cls, sel_registerName("type"), "@16@0:8") ||
        !RUINThemeMethodHasEncoding(cls, sel_registerName("isOwned"), "B16@0:8") ||
        !RUINThemeMethodHasEncoding(cls, sel_registerName("isGrantedByDefault"), "B16@0:8") ||
        !RUINThemeMethodHasEncoding(cls, sel_registerName("validUntil"), "q16@0:8")) {
        atomic_store(&gThemePriceTierStatus, RUINThemeHookEncodingMismatch);
        return;
    }

    IMP original = method_getImplementation(method);
    if (!original) {
        atomic_store(&gThemePriceTierStatus, RUINThemeHookInstallFailed);
        return;
    }
    %init(RUINThemePriceTier, LineShopProductDetail=cls);
    atomic_store(&gThemePriceTierStatus, RUINThemeHookInstalled);
}

%group RUINThemeApplyObserver
%hook RUINThemeApplyClient
- (void)didApplyPackage:(id)event
{
    %orig;
    RUINRecordThemePackageInspection(event, @"didApplyPackage");
    atomic_fetch_add_explicit(&gThemeApplyEvents, 1, memory_order_relaxed);
    id package = RUINThemePackageFromEvent(event);

    if (!package) return;
    @try {
        id isDefault = RUINCopySwiftField(package, "isDefaultTheme");
        if ([isDefault isKindOfClass:[NSNumber class]] && [isDefault boolValue]) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:RUINThemeAppliedThemeIDDefaultsKey];
            atomic_store(&gThemeApplyMarkerStatus, RUINThemeHookInstalled);
            RUINThemeFinishPendingReset(0, YES, nil);
            return;
        }
        id productID = RUINCopySwiftField(package, "productId");
        if (![isDefault isKindOfClass:[NSNumber class]] ||
            ![productID isKindOfClass:[NSString class]] || [(NSString *)productID length] == 0) {
            atomic_store(&gThemeApplyMarkerStatus, RUINThemeHookInstallFailed);
            return;
        }
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if ([isDefault boolValue]) [defaults removeObjectForKey:RUINThemeAppliedThemeIDDefaultsKey];
        else [defaults setObject:productID forKey:RUINThemeAppliedThemeIDDefaultsKey];
        atomic_store(&gThemeApplyMarkerStatus, RUINThemeHookInstalled);
    } @catch (__unused NSException *exception) {
        atomic_store(&gThemeApplyMarkerStatus, RUINThemeHookInstallFailed);
    }
}
%end
%end

%group RUINThemeApplyFailureObserver
%hook RUINThemeApplyClient
- (void)didFailToApplyPackage:(id)event
{
    %orig;
    RUINRecordThemePackageInspection(event, @"didFailToApplyPackage");
    atomic_fetch_add_explicit(&gThemeApplyFailures, 1, memory_order_relaxed);
    id package = RUINThemePackageFromEvent(event);
    if (!package) return;
    id isDefault = RUINCopySwiftField(package, "isDefaultTheme");
    if ([isDefault isKindOfClass:[NSNumber class]] && [isDefault boolValue]) {
        RUINThemeFinishPendingReset(0, NO, RUINThemeError(
            RUINThemeErrorNativeAPIUnavailable, @"Theme reset", @"LINE reported failure while applying the default theme."));
    }
}
%end
%end

static void RUINInstallThemeApplyObserver(void)
{
    if (atomic_load(&gThemeApplyObserverStatus) == RUINThemeHookInstalled) return;
    if (!RUINThemeTargetMatches()) {
        atomic_store(&gThemeApplyObserverStatus, RUINThemeHookVersionGated);
        return;
    }
    Class cls = objc_lookUpClass("_TtC25LineShopProductSettingsUIP33_A54AA8E647C2D20FD64F93390B5A502221ThemeApplyEventClient");
    if (!cls) {
        atomic_store(&gThemeApplyObserverStatus, RUINThemeHookMissingClass);
        return;
    }
    SEL selector = sel_registerName("didApplyPackage:");
    Method method = class_getInstanceMethod(cls, selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding) {
        atomic_store(&gThemeApplyObserverStatus, RUINThemeHookMissingSelector);
        return;
    }
    if (strcmp(encoding, "v24@0:8@16") != 0) {
        atomic_store(&gThemeApplyObserverStatus, RUINThemeHookEncodingMismatch);
        return;
    }
    IMP original = method_getImplementation(method);
    if (!original) {
        atomic_store(&gThemeApplyObserverStatus, RUINThemeHookInstallFailed);
        return;
    }
    if (!RUINThemeOwnMethod(cls, selector)) {
        atomic_store(&gThemeApplyObserverStatus, RUINThemeHookInstallFailed);
        return;
    }
    %init(RUINThemeApplyObserver, RUINThemeApplyClient=cls);
    atomic_store(&gThemeApplyObserverStatus, RUINThemeHookInstalled);
}

static void RUINInstallThemeApplyFailureObserver(void)
{
    if (atomic_load(&gThemeApplyFailureObserverStatus) == RUINThemeHookInstalled) return;
    if (!RUINThemeTargetMatches()) {
        atomic_store(&gThemeApplyFailureObserverStatus, RUINThemeHookVersionGated);
        return;
    }
    Class cls = objc_lookUpClass("_TtC25LineShopProductSettingsUIP33_A54AA8E647C2D20FD64F93390B5A502221ThemeApplyEventClient");
    if (!cls) {
        atomic_store(&gThemeApplyFailureObserverStatus, RUINThemeHookMissingClass);
        return;
    }
    SEL selector = sel_registerName("didFailToApplyPackage:");
    Method method = class_getInstanceMethod(cls, selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding) {
        atomic_store(&gThemeApplyFailureObserverStatus, RUINThemeHookMissingSelector);
        return;
    }
    if (strcmp(encoding, "v24@0:8@16") != 0) {
        atomic_store(&gThemeApplyFailureObserverStatus, RUINThemeHookEncodingMismatch);
        return;
    }
    IMP original = method_getImplementation(method);
    Method own = RUINThemeOwnMethod(cls, selector);
    if (!original || !own) {
        atomic_store(&gThemeApplyFailureObserverStatus, RUINThemeHookInstallFailed);
        return;
    }
    %init(RUINThemeApplyFailureObserver, RUINThemeApplyClient=cls);
    atomic_store(&gThemeApplyFailureObserverStatus, RUINThemeHookInstalled);
}

static NSString *RUINThemeApplyObserverStatusName(void)
{
    return RUINThemeHookStatusNameValue(atomic_load(&gThemeApplyObserverStatus));
}

static NSString *RUINThemeApplyMarkerStatusName(void)
{
    return RUINThemeHookStatusNameValue(atomic_load(&gThemeApplyMarkerStatus));
}

static NSString *RUINThemeDefaultsFreezeStatusName(void)
{
    return RUINThemeHookStatusNameValue(atomic_load(&gThemeDefaultsFreezeStatus));
}

static NSString *RUINThemeHookStatusNameValue(int status)
{
    switch (status) {
        case RUINThemeHookVersionGated: return @"version_gated";
        case RUINThemeHookMissingClass: return @"missing_class";
        case RUINThemeHookMissingSelector: return @"missing_selector";
        case RUINThemeHookEncodingMismatch: return @"encoding_mismatch";
        case RUINThemeHookInstallFailed: return @"install_failed";
        case RUINThemeHookInstalled: return @"installed";
        case RUINThemeHookNativeSchedulingPreserved: return @"native_scheduler_preserved";
        default: return @"not_checked";
    }
}

static NSString *RUINThemePriceTierStatusName(void)
{
    return RUINThemeHookStatusNameValue(atomic_load(&gThemePriceTierStatus));
}

static BOOL RUINThemeHasDocumentType(NSString *contentType)
{
    NSArray *documentTypes = [NSBundle mainBundle].infoDictionary[@"CFBundleDocumentTypes"];
    for (NSDictionary *documentType in documentTypes) {
        if (![documentType isKindOfClass:[NSDictionary class]]) continue;
        NSArray *contentTypes = documentType[@"LSItemContentTypes"];
        if ([contentTypes isKindOfClass:[NSArray class]] && [contentTypes containsObject:contentType])
            return YES;
    }
    return NO;
}

static NSURL *RUINThemeModelURL(void)
{
    NSURL *bundleURL = [[NSBundle mainBundle] URLForResource:@"LineShopThemeRepository-Resources"
                                                withExtension:@"bundle"];
    NSBundle *bundle = bundleURL ? [NSBundle bundleWithURL:bundleURL] : nil;
    return [bundle URLForResource:@"Theme" withExtension:@"momd"];
}

static BOOL RUINThemeCatalogRuntimeAvailable(void)
{
    // Core Data is linked by the dylib and available at the iOS 18 deployment floor.
    return RUINThemeModelURL() != nil;
}

static NSArray<NSURL *> *RUINThemeProductStoreURLs(NSError **error)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSURL *> *roots = [fileManager URLsForDirectory:NSApplicationSupportDirectory
                                                   inDomains:NSUserDomainMask];
    NSSet<NSString *> *storeNames = [NSSet setWithObjects:
        @"OwnedThemeProduct.sqlite", @"SubscribedThemeProduct.sqlite", nil];
    NSMutableArray<NSURL *> *stores = [NSMutableArray array];
    NSUInteger visited = 0;
    for (NSURL *root in roots) {
        NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:root
                                               includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey]
                                                                  options:NSDirectoryEnumerationSkipsPackageDescendants
                                                             errorHandler:nil];
        for (NSURL *url in enumerator) {
            if (++visited > 25000) {
                if (error) *error = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
                                                    @"Local theme catalog",
                                                    @"LINE's application-support store search exceeded its 25,000-entry safety limit.");
                return nil;
            }
            if (enumerator.level > 10) {
                [enumerator skipDescendants];
                continue;
            }
            NSNumber *symbolicLink = nil;
            [url getResourceValue:&symbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
            if (symbolicLink.boolValue) {
                [enumerator skipDescendants];
                continue;
            }
            if (![storeNames containsObject:url.lastPathComponent]) continue;

            NSNumber *directory = nil;
            [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
            if (directory.boolValue) continue;
            [stores addObject:url];
        }
    }
    return [stores sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.lastPathComponent compare:right.lastPathComponent];
    }];
}

static NSError *RUINThemeStoreError(NSString *reason, NSError *underlying)
{
    NSMutableDictionary *info = [@{
        NSLocalizedDescriptionKey: reason,
        @"operation": @"Local theme catalog"
    } mutableCopy];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:RUINThemeErrorDomain
                               code:RUINThemeErrorNativeAPIUnavailable
                           userInfo:info];
}

static NSArray<NSDictionary<NSString *, id> *> *RUINThemeReadProductStoreBody(NSURL *storeURL,
                                                                              NSString *storeName,
                                                                              NSError **error)
{
    NSURL *modelURL = RUINThemeModelURL();
    if (!modelURL) {
        if (error) *error = RUINThemeStoreError(@"The bundled Theme.momd model is unavailable.", nil);
        return nil;
    }
    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    if (!model) {
        if (error) *error = RUINThemeStoreError(@"Theme.momd could not be loaded.", nil);
        return nil;
    }
    NSDictionary *entities = model.entitiesByName;
    if (!model || ![entities isKindOfClass:[NSDictionary class]] || !entities[@"OwnedThemeProduct"]) {
        if (error) *error = RUINThemeStoreError(@"Theme.momd did not load the verified OwnedThemeProduct entity.", nil);
        return nil;
    }

    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc]
        initWithManagedObjectModel:model];
    if (!coordinator) {
        if (error) *error = RUINThemeStoreError(@"A Core Data coordinator could not be created.", nil);
        return nil;
    }
    NSError *storeError = nil;
    NSDictionary *options = @{
        NSReadOnlyPersistentStoreOption: @YES,
        NSMigratePersistentStoresAutomaticallyOption: @NO,
        NSInferMappingModelAutomaticallyOption: @NO
    };
    NSPersistentStore *store = [coordinator addPersistentStoreWithType:NSSQLiteStoreType
        configuration:nil URL:storeURL options:options error:&storeError];
    if (!store) {
        if (error) *error = RUINThemeStoreError(@"LINE's theme product store could not be opened read-only.", storeError);
        return nil;
    }

    NSManagedObjectContext *context = [[NSManagedObjectContext alloc]
        initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    if (!context) {
        if (error) *error = RUINThemeStoreError(@"A read-only Core Data context could not be created.", nil);
        return nil;
    }
    context.persistentStoreCoordinator = coordinator;
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"OwnedThemeProduct"];
    if (!request) {
        if (error) *error = RUINThemeStoreError(@"A fetch request for OwnedThemeProduct could not be created.", nil);
        return nil;
    }
    request.fetchLimit = 4097;

    __block NSArray *result = nil;
    __block NSError *fetchError = nil;
    [context performBlockAndWait:^{
        RUINPerformThemeCatalogRead(^{
            NSArray *records = [context executeFetchRequest:request error:&fetchError];
            if (!records && !fetchError) {
                fetchError = RUINThemeStoreError(@"Core Data returned no result for the theme product fetch.", nil);
                return;
            }
            if (records.count > 4096) {
                fetchError = RUINThemeStoreError(@"The local theme record count exceeded the 4,096-entry safety limit.", nil);
                return;
            }
            NSMutableArray *installed = [NSMutableArray array];
            for (id record in records) {
                id productID = [record valueForKey:@"productID"];
                id installedTime = [record valueForKey:@"installedTime"];
                if (![productID isKindOfClass:[NSString class]] || [(NSString *)productID length] == 0)
                    continue;

                NSMutableDictionary *item = [@{
                    @"productID": RUINCanonicalThemeProductID(productID),
                    @"sourceStore": storeName,
                    @"sourceEntity": @"OwnedThemeProduct",
                    @"packageArchiveValidated": @NO,
                    @"installedLocally": @([installedTime isKindOfClass:[NSNumber class]] && [installedTime longLongValue] > 0)
                } mutableCopy];
                if ([installedTime isKindOfClass:[NSNumber class]]) item[@"installedTime"] = installedTime;
                for (NSString *key in @[@"name", @"versionString", @"latestVersionString",
                                        @"version", @"latestVersion", @"owned", @"grantedByDefault", @"validUntil",
                                        @"notice", @"applicationVersionRange", @"productAvailability"]) {
                    id value = [record valueForKey:key];
                    if (value && value != [NSNull null]) item[key] = value;
                }
                [installed addObject:[item copy]];
            }
            result = [installed copy];
        });
        }];

    if (fetchError) {
        if (error) *error = RUINThemeStoreError(@"LINE's theme product records could not be fetched read-only.", fetchError);
        return nil;
    }
    return result ?: @[];
}

static NSArray<NSDictionary<NSString *, id> *> *RUINThemeReadProductStore(NSURL *storeURL,
                                                                          NSString *storeName,
                                                                          NSError **error)
{
    @try {
        return RUINThemeReadProductStoreBody(storeURL, storeName, error);
    } @catch (NSException *exception) {
        if (error) *error = RUINThemeStoreError(
            [NSString stringWithFormat:@"Core Data raised while reading a theme store: %@",
                                       exception.reason ?: @"unknown exception"], nil);
        return nil;
    }
}

static BOOL RUINThemeSafeURLComponent(NSString *value, BOOL digitsOnly)
{
    if (![value isKindOfClass:[NSString class]] || value.length == 0 || value.length > 128) return NO;
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        BOOL digit = c >= '0' && c <= '9';
        BOOL letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        if (!digit && (digitsOnly || !(letter || c == '-' || c == '_' || c == '.'))) return NO;
    }
    return YES;
}

static NSURL *RUINThemePublicAssetURL(NSString *productID, NSString *version)
{
    productID = RUINCanonicalThemeProductID(productID);
    NSString *prefix = [productID substringToIndex:6];
    NSString *path = [NSString stringWithFormat:@"/themeshop/v1/products/%@/%@/%@/%@/%@/IOS/theme.zip",
        [prefix substringWithRange:NSMakeRange(0, 2)],
        [prefix substringWithRange:NSMakeRange(2, 2)],
        [prefix substringWithRange:NSMakeRange(4, 2)],
        productID, version];
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"https";
    components.host = @"shop.line-scdn.net";
    components.path = path;
    return components.URL;
}

static const NSUInteger RUINThemeMaxArchiveBytes = 64 * 1024 * 1024;
static const uint64_t RUINThemeMaxEntryBytes = 64ULL * 1024 * 1024;
static const uint64_t RUINThemeMaxExpandedBytes = 256ULL * 1024 * 1024;
static const NSUInteger RUINThemeMaxArchiveEntries = 4096;

static uint16_t RUINThemeReadLE16(const uint8_t *bytes)
{
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t RUINThemeReadLE32(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static BOOL RUINThemeArchiveFail(NSError **error, NSString *reason)
{
    if (error) *error = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
                                       @"Public theme archive validation", reason);
    return NO;
}

static BOOL RUINThemeValidateArchiveData(NSData *archive, NSError **error)
{
    if (archive.length < 22 || archive.length > RUINThemeMaxArchiveBytes)
        return RUINThemeArchiveFail(error, @"The theme ZIP is empty or exceeds the 64 MiB download limit.");
    const uint8_t *bytes = archive.bytes;
    NSUInteger lowerBound = archive.length > 65557 ? archive.length - 65557 : 0;
    NSUInteger cursor = archive.length - 22;
    NSUInteger endRecord = NSNotFound;
    for (;;) {
        if (RUINThemeReadLE32(bytes + cursor) == 0x06054b50) {
            uint16_t commentLength = RUINThemeReadLE16(bytes + cursor + 20);
            if ((uint64_t)cursor + 22 + commentLength == archive.length) {
                endRecord = cursor;
                break;
            }
        }
        if (cursor == lowerBound) break;
        cursor--;
    }
    if (endRecord == NSNotFound)
        return RUINThemeArchiveFail(error, @"The theme ZIP has no valid end-of-central-directory record.");

    uint16_t disk = RUINThemeReadLE16(bytes + endRecord + 4);
    uint16_t centralDisk = RUINThemeReadLE16(bytes + endRecord + 6);
    uint16_t diskEntries = RUINThemeReadLE16(bytes + endRecord + 8);
    uint16_t entryCount = RUINThemeReadLE16(bytes + endRecord + 10);
    uint32_t centralSize = RUINThemeReadLE32(bytes + endRecord + 12);
    uint32_t centralOffset = RUINThemeReadLE32(bytes + endRecord + 16);
    if (disk || centralDisk || diskEntries != entryCount || entryCount == 0 ||
        entryCount == UINT16_MAX || centralSize == UINT32_MAX || centralOffset == UINT32_MAX ||
        entryCount > RUINThemeMaxArchiveEntries)
        return RUINThemeArchiveFail(error, @"Multi-disk, ZIP64, empty, or oversized theme archives are not accepted.");

    uint64_t centralEnd64 = (uint64_t)centralOffset + centralSize;
    if (centralEnd64 > endRecord || centralEnd64 < centralOffset)
        return RUINThemeArchiveFail(error, @"The ZIP central directory is out of bounds.");
    NSUInteger centralEnd = (NSUInteger)centralEnd64;
    cursor = centralOffset;
    uint64_t expandedTotal = 0;
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    NSMutableArray<NSArray<NSNumber *> *> *localRanges = [NSMutableArray arrayWithCapacity:entryCount];

    for (NSUInteger index = 0; index < entryCount; index++) {
        if (cursor > centralEnd || centralEnd - cursor < 46 ||
            RUINThemeReadLE32(bytes + cursor) != 0x02014b50)
            return RUINThemeArchiveFail(error, @"The ZIP central directory contains a malformed entry.");

        uint16_t madeBy = RUINThemeReadLE16(bytes + cursor + 4);
        uint16_t flags = RUINThemeReadLE16(bytes + cursor + 8);
        uint16_t method = RUINThemeReadLE16(bytes + cursor + 10);
        uint32_t compressedSize = RUINThemeReadLE32(bytes + cursor + 20);
        uint32_t expandedSize = RUINThemeReadLE32(bytes + cursor + 24);
        uint16_t nameLength = RUINThemeReadLE16(bytes + cursor + 28);
        uint16_t extraLength = RUINThemeReadLE16(bytes + cursor + 30);
        uint16_t commentLength = RUINThemeReadLE16(bytes + cursor + 32);
        uint16_t diskStart = RUINThemeReadLE16(bytes + cursor + 34);
        uint32_t externalAttributes = RUINThemeReadLE32(bytes + cursor + 38);
        uint32_t localOffset = RUINThemeReadLE32(bytes + cursor + 42);
        uint64_t recordEnd = (uint64_t)cursor + 46 + nameLength + extraLength + commentLength;
        if (!nameLength || recordEnd > centralEnd || diskStart || (flags & 0x0041) ||
            (method != 0 && method != 8) || compressedSize == UINT32_MAX ||
            expandedSize == UINT32_MAX || localOffset == UINT32_MAX ||
            expandedSize > RUINThemeMaxEntryBytes || compressedSize > RUINThemeMaxArchiveBytes)
            return RUINThemeArchiveFail(error, @"A ZIP entry uses unsupported encryption, compression, ZIP64, or size metadata.");

        NSUInteger extraStart = cursor + 46 + nameLength;
        NSUInteger extraEnd = extraStart + extraLength;
        for (NSUInteger extra = extraStart; extra < extraEnd;) {
            if (extraEnd - extra < 4)
                return RUINThemeArchiveFail(error, @"A ZIP extra field is malformed.");
            uint16_t extraID = RUINThemeReadLE16(bytes + extra);
            uint16_t extraSize = RUINThemeReadLE16(bytes + extra + 2);
            if ((uint64_t)extra + 4 + extraSize > extraEnd || extraID == 0x0001)
                return RUINThemeArchiveFail(error, @"Malformed or ZIP64 extra fields are not accepted.");
            extra += 4 + extraSize;
        }

        NSData *nameData = [NSData dataWithBytes:bytes + cursor + 46 length:nameLength];
        NSString *path = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        if (!path || [path containsString:@"\0"] || [path containsString:@"\\"] ||
            [path containsString:@":"] || [path hasPrefix:@"/"])
            return RUINThemeArchiveFail(error, @"A ZIP entry has an absolute, non-UTF8, or platform-ambiguous path.");
        BOOL directoryEntry = [path hasSuffix:@"/"];
        if (directoryEntry) path = [path substringToIndex:path.length - 1];
        NSArray<NSString *> *components = [path componentsSeparatedByString:@"/"];
        if (path.length == 0 || [components containsObject:@"."] || [components containsObject:@".."] ||
            [components containsObject:@""])
            return RUINThemeArchiveFail(error, @"A ZIP entry contains a traversal or empty path component.");
        NSString *canonicalPath = [[path precomposedStringWithCanonicalMapping] lowercaseString];
        if ([paths containsObject:canonicalPath])
            return RUINThemeArchiveFail(error, @"The ZIP contains duplicate paths after case normalization.");
        [paths addObject:canonicalPath];

        uint8_t hostOS = (uint8_t)(madeBy >> 8);
        uint32_t unixMode = externalAttributes >> 16;
        uint32_t fileType = unixMode & 0170000;
        if (hostOS == 3 && fileType &&
            fileType != 0100000 && fileType != 0040000)
            return RUINThemeArchiveFail(error, @"ZIP symlinks and non-regular filesystem entries are rejected.");
        if (directoryEntry && expandedSize != 0)
            return RUINThemeArchiveFail(error, @"A ZIP directory entry has a nonzero expanded size.");
        if (method == 0 && compressedSize != expandedSize)
            return RUINThemeArchiveFail(error, @"A stored ZIP entry has inconsistent compressed and expanded sizes.");
        expandedTotal += expandedSize;
        if (expandedTotal > RUINThemeMaxExpandedBytes)
            return RUINThemeArchiveFail(error, @"The ZIP exceeds the 256 MiB expanded-size limit.");

        if ((uint64_t)localOffset + 30 > centralOffset ||
            RUINThemeReadLE32(bytes + localOffset) != 0x04034b50)
            return RUINThemeArchiveFail(error, @"A ZIP local-file header is out of bounds or malformed.");
        uint16_t localFlags = RUINThemeReadLE16(bytes + localOffset + 6);
        uint16_t localMethod = RUINThemeReadLE16(bytes + localOffset + 8);
        uint16_t localNameLength = RUINThemeReadLE16(bytes + localOffset + 26);
        uint16_t localExtraLength = RUINThemeReadLE16(bytes + localOffset + 28);
        uint64_t dataStart = (uint64_t)localOffset + 30 + localNameLength + localExtraLength;
        uint64_t dataEnd = dataStart + compressedSize;
        if (localFlags != flags || localMethod != method || localNameLength != nameLength ||
            dataEnd > centralOffset || dataEnd < dataStart ||
            memcmp(bytes + localOffset + 30, bytes + cursor + 46, nameLength) != 0)
            return RUINThemeArchiveFail(error, @"A ZIP local header disagrees with the central directory.");
        for (NSUInteger extra = (NSUInteger)localOffset + 30 + localNameLength;
             extra < dataStart;) {
            if (dataStart - extra < 4)
                return RUINThemeArchiveFail(error, @"A local ZIP extra field is malformed.");
            uint16_t extraID = RUINThemeReadLE16(bytes + extra);
            uint16_t extraSize = RUINThemeReadLE16(bytes + extra + 2);
            if ((uint64_t)extra + 4 + extraSize > dataStart || extraID == 0x0001)
                return RUINThemeArchiveFail(error, @"Malformed or ZIP64 local extra fields are not accepted.");
            extra += 4 + extraSize;
        }
        [localRanges addObject:@[@(localOffset), @(dataEnd)]];
        cursor = (NSUInteger)recordEnd;
    }
    if (cursor != centralEnd)
        return RUINThemeArchiveFail(error, @"The ZIP central directory size does not match its entries.");

    [localRanges sortUsingComparator:^NSComparisonResult(NSArray<NSNumber *> *left, NSArray<NSNumber *> *right) {
        return [left[0] compare:right[0]];
    }];
    uint64_t lastEnd = 0;
    for (NSArray<NSNumber *> *range in localRanges) {
        uint64_t start = range[0].unsignedLongLongValue;
        uint64_t end = range[1].unsignedLongLongValue;
        if (start < lastEnd || end < start)
            return RUINThemeArchiveFail(error, @"ZIP entries have overlapping local-file ranges.");
        lastEnd = end;
    }
    return YES;
}

@interface RUINThemeAssetTransfer : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, copy) RUINThemeDownloadCompletion completion;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDownloadTask *task;
@property(nonatomic, copy) NSString *productID;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, strong) NSURL *packageURL;
@property(nonatomic, strong) NSError *failure;
@end

@implementation RUINThemeAssetTransfer

- (void)startURL:(NSURL *)url productID:(NSString *)productID version:(NSString *)version
     displayName:(NSString *)displayName
      completion:(RUINThemeDownloadCompletion)completion
{
    self.productID = RUINCanonicalThemeProductID(productID);
    self.version = version;
    self.displayName = displayName;
    self.completion = completion;
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.HTTPCookieStorage = nil;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCache = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 60.0;
    configuration.timeoutIntervalForResource = 120.0;
    NSOperationQueue *delegateQueue = [NSOperationQueue new];
    delegateQueue.maxConcurrentOperationCount = 1;
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60.0];
    request.HTTPMethod = @"GET";
    self.task = [self.session downloadTaskWithRequest:request];
    [self.task resume];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten
 totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if ((totalBytesExpectedToWrite > 0 && (uint64_t)totalBytesExpectedToWrite > RUINThemeMaxArchiveBytes) ||
        totalBytesWritten > (int64_t)RUINThemeMaxArchiveBytes) {
        self.failure = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
            @"Manual name/ID/version download", @"The theme ZIP exceeded the 64 MiB download limit.");
        [downloadTask cancel];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler
{
    NSURL *redirectURL = request.URL;
    if ([redirectURL.scheme.lowercaseString isEqualToString:@"https"] &&
        [redirectURL.host.lowercaseString isEqualToString:@"shop.line-scdn.net"]) {
        completionHandler(request);
        return;
    }
    self.failure = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
        @"Manual name/ID/version download", @"The CDN redirected outside the discovered HTTPS host; the request was stopped.");
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didFinishDownloadingToURL:(NSURL *)location
{
    NSHTTPURLResponse *response = [downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)downloadTask.response : nil;
    if (self.failure) return;
    if (response.statusCode != 200) {
        self.failure = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
            @"Manual name/ID/version download", @"The public theme asset endpoint did not return HTTP 200.");
        return;
    }
    NSError *fileError = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:&fileError];
    unsigned long long fileSize = [attributes[NSFileSize] unsignedLongLongValue];
    if (fileError || fileSize == 0 || fileSize > RUINThemeMaxArchiveBytes) {
        self.failure = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
            @"Manual name/ID/version download", @"The downloaded theme asset is empty, unreadable, or exceeds 64 MiB.");
        return;
    }
    NSData *archive = [NSData dataWithContentsOfURL:location options:NSDataReadingMappedIfSafe error:&fileError];
    NSError *validationError = nil;
    if (!archive || !RUINThemeValidateArchiveData(archive, &validationError)) {
        self.failure = validationError ?: RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
            @"Manual name/ID/version download", @"The downloaded theme asset could not be read.");
        return;
    }

    NSURL *support = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                            inDomains:NSUserDomainMask] firstObject];
    NSURL *directory = [[support URLByAppendingPathComponent:@"RUINThemeDownloads" isDirectory:YES]
        URLByAppendingPathComponent:self.productID isDirectory:YES];
    directory = [directory URLByAppendingPathComponent:self.version isDirectory:YES];
    if (!directory || ![[NSFileManager defaultManager] createDirectoryAtURL:directory
                                                withIntermediateDirectories:YES attributes:nil error:&fileError]) {
        self.failure = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
            @"Manual name/ID/version download", @"A validated theme archive could not be stored in Application Support.");
        return;
    }
    NSString *filename = [NSString stringWithFormat:@"%@.linetheme", [NSUUID UUID].UUIDString];
    NSURL *destination = [directory URLByAppendingPathComponent:filename];
    if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:destination error:&fileError]) {
        self.failure = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
            @"Manual name/ID/version download", @"The validated theme archive could not be moved into its local package folder.");
        return;
    }
    self.packageURL = destination;
    NSURL *labelURL = [[destination URLByDeletingPathExtension] URLByAppendingPathExtension:@"name"];
    [self.displayName writeToURL:labelURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    NSError *finalError = self.failure ?: error;
    NSURL *packageURL = self.packageURL;
    if (!finalError && !packageURL) {
        finalError = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
            @"Manual name/ID/version download", @"The network task ended without a validated package archive.");
    }
    RUINThemeDownloadCompletion completion = self.completion;
    self.completion = nil;
    [session finishTasksAndInvalidate];
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(packageURL, finalError); });
}

@end

static NSArray<NSDictionary<NSString *, id> *> *RUINThemeDownloadedAssetCatalog(NSError **error)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *support = [[fileManager URLsForDirectory:NSApplicationSupportDirectory
                                           inDomains:NSUserDomainMask] firstObject];
    NSURL *root = [support URLByAppendingPathComponent:@"RUINThemeDownloads" isDirectory:YES];
    BOOL isDirectory = NO;
    if (!root || ![fileManager fileExistsAtPath:root.path isDirectory:&isDirectory]) return @[];
    NSNumber *isSymlink = nil;
    [root getResourceValue:&isSymlink forKey:NSURLIsSymbolicLinkKey error:nil];
    if (isSymlink.boolValue || !isDirectory) return @[];
    // The enumerator uses /private/var while Foundation's URL symlink resolver
    // preserves the /var alias. Use the filesystem's canonical existing root.
    char *canonical = realpath(root.fileSystemRepresentation, NULL);
    if (!canonical) return @[];
    root = [NSURL fileURLWithFileSystemRepresentation:canonical isDirectory:YES relativeToURL:nil];
    free(canonical);

    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtURL:root
        includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsRegularFileKey, NSURLFileSizeKey]
        options:NSDirectoryEnumerationSkipsPackageDescendants errorHandler:nil];
    NSMutableArray<NSDictionary<NSString *, id> *> *packages = [NSMutableArray array];
    NSUInteger visited = 0;
    for (NSURL *url in enumerator) {
        if (++visited > 10000) {
            if (error) *error = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
                @"Local theme catalog", @"The downloaded theme archive scan exceeded its 10,000-entry safety limit.");
            return nil;
        }
        if (enumerator.level > 3) {
            [enumerator skipDescendants];
            continue;
        }
        NSNumber *symbolicLink = nil;
        [url getResourceValue:&symbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
        if (symbolicLink.boolValue) {
            [enumerator skipDescendants];
            continue;
        }
        if (![url.pathExtension.lowercaseString isEqualToString:@"linetheme"]) continue;

        NSURL *versionDirectory = url.URLByDeletingLastPathComponent;
        NSURL *productDirectory = versionDirectory.URLByDeletingLastPathComponent;
        if (![productDirectory.URLByDeletingLastPathComponent.path isEqualToString:root.path] ||
            !RUINThemeSafeURLComponent(productDirectory.lastPathComponent, NO) ||
            productDirectory.lastPathComponent.length < 6 ||
            !RUINThemeSafeURLComponent(versionDirectory.lastPathComponent, YES) ||
            ![[[NSUUID alloc] initWithUUIDString:url.lastPathComponent.stringByDeletingPathExtension] isKindOfClass:[NSUUID class]])
            continue;

        NSNumber *regularFile = nil;
        NSNumber *fileSize = nil;
        [url getResourceValue:&regularFile forKey:NSURLIsRegularFileKey error:nil];
        [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        if (!regularFile.boolValue || fileSize.unsignedLongLongValue == 0 ||
            fileSize.unsignedLongLongValue > RUINThemeMaxArchiveBytes) continue;
        NSData *archive = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        if (!archive || !RUINThemeValidateArchiveData(archive, nil)) continue;

        NSURL *labelURL = [[url URLByDeletingPathExtension] URLByAppendingPathExtension:@"name"];
        NSString *displayName = [NSString stringWithContentsOfURL:labelURL
            encoding:NSUTF8StringEncoding error:nil];
        if (![displayName isKindOfClass:[NSString class]] ||
            ![[displayName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length])
            displayName = productDirectory.lastPathComponent;
        [packages addObject:@{
            @"productID": RUINCanonicalThemeProductID(productDirectory.lastPathComponent),
            @"name": displayName,
            @"version": versionDirectory.lastPathComponent,
            @"versionString": RUINThemeDisplayVersion(versionDirectory.lastPathComponent) ?: versionDirectory.lastPathComponent,
            @"sourceStore": @"RUINThemeDownloads",
            @"sourceEntity": @"ValidatedLocalThemeArchive",
            @"packageArchiveValidated": @NO,
            @"archiveStructureValidated": @YES,
            @"archiveValidationLevel": @"zip_structure_paths_types_and_size",
            @"downloadedLocally": @YES,
            @"installedLocally": @NO,
            @"packageURL": url
        }];
    }
    return [packages copy];
}

static BOOL RUINThemeShopDetailRouteAvailable(void)
{
    if (!RUINThemeTargetMatches()) return NO;
    Class appDelegateClass = objc_lookUpClass("_TtC4LINE11AppDelegate");
    Method method = appDelegateClass
        ? class_getInstanceMethod(appDelegateClass, sel_registerName("openURLForObjC:")) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding && strcmp(encoding, "B24@0:8@16") == 0;
}

static void RUINThemeFinishPendingReset(uint64_t requestID, BOOL applied, NSError *error)
{
    os_unfair_lock_lock(&gThemePendingResetLock);
    if (!gThemePendingResetCompletion || (requestID && requestID != gThemePendingResetID)) {
        os_unfair_lock_unlock(&gThemePendingResetLock);
        return;
    }
    RUINThemeApplyCompletion completion = gThemePendingResetCompletion;
    gThemePendingResetCompletion = nil;
    gThemePendingResetID = 0;
    os_unfair_lock_unlock(&gThemePendingResetLock);
    dispatch_async(dispatch_get_main_queue(), ^{ completion(applied, error); });
}

static BOOL RUINThemeResetActionAvailable(void)
{
    if (!RUINThemeTargetMatches()) return NO;
    Class cls = objc_lookUpClass("_TtC25LineShopProductSettingsUI36ThemePackageManagementViewController");
    SEL selector = sel_registerName("didTapResetButton");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding && strcmp(encoding, "v16@0:8") == 0;
}

static UIViewController *RUINThemeVisibleManagementController(void)
{
    if (![NSThread isMainThread]) return nil;
    Class targetClass = objc_lookUpClass("_TtC25LineShopProductSettingsUI36ThemePackageManagementViewController");
    if (!targetClass) return nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow) continue;
            UIViewController *controller = window.rootViewController;
            while (controller) {
                if ([controller isKindOfClass:targetClass] && controller.viewIfLoaded.window == window)
                    return controller;
                UIViewController *next = controller.presentedViewController;
                if (!next && [controller isKindOfClass:[UINavigationController class]])
                    next = ((UINavigationController *)controller).visibleViewController;
                if (!next && [controller isKindOfClass:[UITabBarController class]])
                    next = ((UITabBarController *)controller).selectedViewController;
                if (!next || next == controller) break;
                controller = next;
            }
        }
    }
    return nil;
}

static NSDictionary *RUINThemeOperation(NSString *name, NSString *reason)
{
    return @{
        @"available": @NO,
        @"status": @"unsupported_native_api",
        @"reason": reason ?: RUINThemeNativeUnavailableReason(name)
    };
}

static id RUINThemeFeatureAddress(RUINMappingStatus status, uintptr_t address)
{
    if (status != RUINMappingStatusVerified || !address) return NSNull.null;
    return [NSString stringWithFormat:@"0x%llx", (unsigned long long)address];
}

void RUINInstallThemeFeatures(void)
{
    os_unfair_lock_lock(&gThemeInstallLock);
    RUINInstallThemePriceTierHook();
    RUINInstallThemeApplyObserver();
    RUINInstallThemeApplyFailureObserver();
    RUINInstallNativeThemeValidation();
    atomic_store(&gThemeDefaultsFreezeStatus, RUINThemeHookNativeSchedulingPreserved);
    atomic_store_explicit(&gThemeInstallInvoked, true, memory_order_release);
    os_unfair_lock_unlock(&gThemeInstallLock);
}

NSDictionary<NSString *, id> *RUINThemeDiagnostics(void)
{
    NSString *downloaderName = @"_TtC15LineShopProduct26LineThemePackageDownloader";
    NSString *applierName = @"_TtC13LineShopTheme19DynamicThemeApplier";
    NSString *packageName = @"_TtC22LineShopThemeInterface12ThemePackage";
    NSString *removerName = @"_TtC23LineShopThemeRepository27ThemePackageResourceRemover";
    BOOL targetAvailable = RUINThemeTargetMatches();
    BOOL nativeStoreAvailable = targetAvailable && RUINThemeCatalogRuntimeAvailable();
    BOOL catalogAvailable = targetAvailable;
    BOOL manualDownloadAvailable = targetAvailable;
    BOOL nativeShopRouteAvailable = RUINThemeShopDetailRouteAvailable();
    BOOL priceTierGateInstalled = atomic_load(&gThemePriceTierStatus) == RUINThemeHookInstalled;
    BOOL applyObserverInstalled = atomic_load(&gThemeApplyObserverStatus) == RUINThemeHookInstalled;
    BOOL applyFailureObserverInstalled = atomic_load(&gThemeApplyFailureObserverStatus) == RUINThemeHookInstalled;
    BOOL defaultsFreezeInstalled = atomic_load(&gThemeDefaultsFreezeStatus) == RUINThemeHookInstalled;
    BOOL resetActionAvailable = RUINThemeResetActionAvailable();
    BOOL resetControllerVisible = RUINThemeVisibleManagementController() != nil;
    NSDictionary *info = [NSBundle mainBundle].infoDictionary ?: @{};
    NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier ?: @"";
#if defined(RUIN_HOST_CHECK)
    const RUINVersionMapping *versionMapping = RUINMappingForInfo(info);
#else
    RUINFeatureImage themeImage;
    const RUINVersionMapping *versionMapping = RUINCopyVerifiedThemeImage(&themeImage);
#endif
    const RUINThemeFeatureAddressesMapping *featureAddresses = versionMapping
        ? &versionMapping->themes.featureAddresses : NULL;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL shopDownloadEnabled = [defaults boolForKey:RUINThemeShopDownloadEnabledDefaultsKey];
    BOOL randomEnabled = [defaults boolForKey:RUINThemeRandomEnabledDefaultsKey];
    BOOL appliedThemeMarkerPresent = [defaults objectForKey:RUINThemeAppliedThemeIDDefaultsKey] != nil;
    NSString *randomReason = randomEnabled
        ? RUINThemeNativeUnavailableReason(@"Random theme on startup") : @"Disabled by preference.";

    NSDictionary *metadataEvidence = @{
        @"documentContentType": @"jp.naver.talk.theme-package",
        @"documentTypeRegistered": @(RUINThemeHasDocumentType(@"jp.naver.talk.theme-package")),
        @"archiveHandling": @{
            @"customArchiveValidator": @YES,
            @"customExtractor": @NO,
            @"reason": @"ZIP central-directory structure, paths, entry types, and size limits are checked before saving as .linetheme. CRC/decompression and package schema are not checked. No archive is extracted or programmatically imported; LINE's registered document handler is the only evidenced handoff."
        },
        @"nativeCoreDataCatalog": @{
            @"modelVersion": @"Theme 2",
            @"entity": @"OwnedThemeProduct",
            @"managedObjectClass": @"LineShopThemeRepository.ManagedOwnedThemeProduct",
            @"managedObjectObjCClassPresent": @(objc_getClass("_TtC23LineShopThemeRepository24ManagedOwnedThemeProduct") != Nil),
            @"stores": @[@"OwnedThemeProduct.sqlite", @"SubscribedThemeProduct.sqlite"],
            @"catalogRuntimeAvailable": @(nativeStoreAvailable),
            @"localInstallField": @"installedTime",
            @"catalogFields": @[@"productID", @"name", @"versionString", @"latestVersionString",
                                 @"version", @"latestVersion", @"installedTime", @"owned",
                                 @"validUntil", @"notice", @"applicationVersionRange"],
            @"storeAccess": @"read_only"
        },
        @"nativeShopDetailRoute": @{
            @"URLTemplate": @"line://shop/theme/detail?id=<productID>",
            @"selector": @"AppDelegate -openURLForObjC:",
            @"typeEncoding": @"B24@0:8@16",
            @"available": @(nativeShopRouteAvailable),
            @"downloadCompletionExposed": @NO
        },
        @"nativeDownloadURLMetadata": @{
            @"CDNBase": @"https://shop.line-scdn.net:443/",
            @"URLTemplate": @"https://shop.line-scdn.net/themeshop/v1/products/{id[0:2]}/{id[2:2]}/{id[4:2]}/{id}/{latestVersion}/IOS/theme.zip",
            @"generatorFields": @[@"shopAPIVersion", @"uriPathProducts", @"uriPathDeviceType",
                                   @"uriResourceZipName", @"shopID", @"shopURL"],
            @"httpMethod": @"GET",
            @"redirectPolicy": @"HTTPS on the discovered shop.line-scdn.net host only",
            @"cookiesOrAuthHeadersSent": @NO,
            @"purchaseOrOrderRequestObserved": @NO
        },
        @"nativeThemePackageFields": @[@"productId", @"remoteURL", @"unzipURL", @"tempZipStoreURL",
                                        @"metaStoreURL", @"installedTime", @"isOwned", @"isSubscribed"],
        @"nativeThemeUpdatePersistence": @{
            @"appliedThemeIDMarker": RUINThemeAppliedThemeIDDefaultsKey,
            @"nativeUpdateDateKey": RUINThemeDynamicThemeNextUpdateDateDefaultsKey,
            @"randomThemeKey": RUINThemeRandomEnabledDefaultsKey,
            @"markerWrittenOnlyAfterNativeApplyEvent": @YES,
            @"randomPreferenceAlsoFreezesUpdate": @YES
        },
        @"swiftEngineTypes": @[
            @"LineShopProduct.LineThemePackageDownloader",
            @"LineShopTheme.DynamicThemeApplier",
            @"LineShopThemeInterface.ThemePackage",
            @"LineShopThemeRepository.ThemePackageResourceRemover"
        ],
        @"swiftVTableEvidence": @{
            @"LineShopTheme.DynamicThemeApplier": @{
                @"hasVTable": @YES,
                @"vtableOffsetWords": @15,
                @"vtableSlotCount": @1,
                @"slotKind": @"init",
                @"applyActionInVTable": @NO
            },
            @"LineShopProduct.LineThemePackageDownloader": @{
                @"hasVTable": @YES,
                @"vtableOffsetWords": @59,
                @"vtableSlotCount": @1,
                @"slotKind": @"init",
                @"downloadActionSelectorInObjCMetadata": @NO
            }
        },
        @"objectiveCMethodEncodings": @{
            @"LineShopProductDetail": @{
                @"priceTier": @"i16@0:8",
                @"type": @"@16@0:8",
                @"isOwned": @"B16@0:8",
                @"isGrantedByDefault": @"B16@0:8",
                @"validUntil": @"q16@0:8"
            },
            @"_TtC23LineShopThemeRepository24ManagedOwnedThemeProduct": @{
                @"initWithEntity:insertIntoManagedObjectContext:": @"@32@0:8@16@24",
                @"didSave": @"v16@0:8"
            },
            @"LineShopThemeSummary": @{
                @"initWithCoder:": @"@24@0:8@16",
                @"imagePath": @"@16@0:8",
                @"version": @"q16@0:8",
                @"versionString": @"@16@0:8"
            },
            @"_TtC25LineShopProductSettingsUI36ThemePackageManagementViewController": @{
                @"didTapResetButton": @"v16@0:8"
            },
            @"_TtC25LineShopProductSettingsUIP33_A54AA8E647C2D20FD64F93390B5A502221ThemeApplyEventClient": @{
                @"didApplyPackage:": @"v24@0:8@16",
                @"didFailToApplyPackage:": @"v24@0:8@16"
            },
            @"_TtC15LineShopProduct34SingleThemePackagerDownloadHandler": @{
                @"init": @"@16@0:8"
            }
        },
        @"swiftEngineClassesVisibleToObjCRuntime": @{
            @"downloader": @(objc_getClass(downloaderName.UTF8String) != Nil),
            @"applier": @(objc_getClass(applierName.UTF8String) != Nil),
            @"package": @(objc_getClass(packageName.UTF8String) != Nil),
            @"resourceRemover": @(objc_getClass(removerName.UTF8String) != Nil)
        }
    };

    return @{
        @"target": @{
            @"bundleIdentifier": bundleIdentifier,
            @"version": info[@"CFBundleShortVersionString"] ?: @"",
            @"build": info[@"CFBundleVersion"] ?: @"",
            @"expectedVersion": versionMapping
                ? [NSString stringWithUTF8String:versionMapping->host.version] : NSNull.null,
            @"expectedBuild": versionMapping
                ? [NSString stringWithUTF8String:versionMapping->host.build] : NSNull.null,
            @"matches": @(RUINThemeTargetMatches())
        },
        @"installInvoked": @(atomic_load_explicit(&gThemeInstallInvoked, memory_order_acquire)),
        @"preferences": @{
            RUINThemeShopDownloadEnabledDefaultsKey: @(shopDownloadEnabled),
            RUINThemeRandomEnabledDefaultsKey: @(randomEnabled)
        },
        @"metadataEvidence": metadataEvidence,
        @"operations": @{
            @"localThemeValidation": RUINNativeThemeValidationDiagnostics(),
            @"shopDownloadHook": RUINThemeOperation(@"Shop download hook", nil),
            @"priceTierDisplayGate": @{
                @"available": @(priceTierGateInstalled),
                @"status": RUINThemePriceTierStatusName(),
                @"replacementVA": featureAddresses
                    ? RUINThemeFeatureAddress(featureAddresses->status, featureAddresses->priceTierReplacementVA)
                    : NSNull.null,
                @"preferenceKey": RUINThemeShopDownloadEnabledDefaultsKey,
                @"eligibleProductGate": @[@"type == theme", @"owned", @"grantedByDefault", @"unexpired validUntil"],
                @"purchaseOrOrderAction": @NO
            },
            @"nativeApplyObserver": @{
                @"available": @(applyObserverInstalled),
                @"status": RUINThemeApplyObserverStatusName(),
                @"nativeMethodVA": featureAddresses
                    ? RUINThemeFeatureAddress(featureAddresses->status, featureAddresses->applyObserverMethodVA)
                    : NSNull.null,
                @"successEventsObserved": @(atomic_load(&gThemeApplyEvents)),
                @"failureObserverStatus": RUINThemeHookStatusNameValue(atomic_load(&gThemeApplyFailureObserverStatus)),
                @"failureEventsObserved": @(atomic_load(&gThemeApplyFailures)),
                @"markerCaptureStatus": RUINThemeApplyMarkerStatusName(),
                @"appliedThemeMarkerPresent": @(appliedThemeMarkerPresent),
                @"reason": @"Observes LINE's didApplyPackage: callback after native success; it does not initiate an apply or set the marker from a download/preference toggle."
            },
            @"dynamicThemeAutoUpdateFreeze": @{
                @"available": @(defaultsFreezeInstalled),
                @"status": RUINThemeDefaultsFreezeStatusName(),
                @"replacementVA": featureAddresses
                    ? RUINThemeFeatureAddress(featureAddresses->status, featureAddresses->defaultsFreezeReplacementVA)
                    : NSNull.null,
                @"active": @(defaultsFreezeInstalled && (appliedThemeMarkerPresent || randomEnabled)),
                @"markerKey": RUINThemeAppliedThemeIDDefaultsKey,
                @"interceptedKey": RUINThemeDynamicThemeNextUpdateDateDefaultsKey,
                @"randomPreferenceFallback": @(randomEnabled && !appliedThemeMarkerPresent),
                @"reason": @"LINE owns the update date for themes applied by its native management screen; RUIN does not override the native scheduler."
            },
            @"manualDownload": @{
                @"available": @(manualDownloadAvailable),
                @"status": manualDownloadAvailable ? @"public_asset_get_and_validated_local_archive" : @"unavailable",
                @"sourceReplacementVA": featureAddresses
                    ? RUINThemeFeatureAddress(featureAddresses->status, featureAddresses->manualDownloadSourceReplacementVA)
                    : NSNull.null,
                @"completion": @"Returns a local .linetheme URL only after HTTP 200, transfer-size checks, and ZIP structure/path/type/expanded-size validation; CRC and package schema remain unchecked; does not extract or apply.",
                @"requiresEnableThemeDL": @YES,
                @"requiresNativeOwnedGrantOrActiveValidity": @NO,
                @"installationConfirmed": @NO,
                @"reason": manualDownloadAvailable
                    ? @"Uses only the statically recovered anonymous CDN GET when enableThemeDL is on. It does not request an order, write ownership/grant records, or claim installation."
                    : RUINLocalizedString(@"themes.download_unavailable")
            },
            @"localCatalog": @{
                @"available": @(catalogAvailable),
                @"status": catalogAvailable ? @"validated_downloads_plus_read_only_coredata" : @"unavailable",
                @"reason": catalogAvailable
                    ? @"Includes validated local .linetheme archives and, when the Theme 2 model is present, read-only native records with a positive installedTime. Downloaded archives are not marked installed."
                    : RUINLocalizedString(@"themes.catalog_unavailable")
            },
            @"apply": RUINThemeOperation(@"Theme apply", nil),
            @"remove": RUINThemeOperation(@"Theme removal", nil),
            @"reset": @{
                @"available": @(resetActionAvailable && applyObserverInstalled && applyFailureObserverInstalled),
                @"nativeMethodVA": featureAddresses
                    ? RUINThemeFeatureAddress(featureAddresses->status, featureAddresses->resetMethodVA)
                    : NSNull.null,
                @"status": resetActionAvailable ? (resetControllerVisible ? @"native_reset_action_ready" : @"native_screen_required") : @"unsupported_native_api",
                @"nativeManagementScreenVisible": @(resetControllerVisible),
                @"completionRequiresDefaultApplyEvent": @YES,
                @"reason": resetActionAvailable
                    ? (resetControllerVisible
                        ? @"Dispatches LINE's native reset button and reports success only after didApplyPackage: supplies the default package."
                        : @"Open LINE's ThemePackageManagementViewController; the native reset action is callable only while that screen is visible.")
                    : RUINThemeNativeUnavailableReason(@"Theme reset")
            },
            @"randomStartup": @{
                @"available": @NO,
                @"enabled": @(randomEnabled),
                @"applied": @NO,
                @"status": randomEnabled ? @"unsupported_native_api" : @"disabled",
                @"reason": randomReason
            },
            @"iPad": @{
                @"available": @(targetAvailable),
                @"catalog": @(catalogAvailable),
                @"manualDownload": @(manualDownloadAvailable),
                @"nativeResetAction": @(resetActionAvailable),
                @"nativeApplyRemove": @NO,
                @"status": targetAvailable ? @"catalog_and_download_supported" : @"version_gated",
                @"reason": RUINThemeNativeUnavailableReason(@"iPad theme management")
            }
        }
    };
}

NSArray<NSDictionary<NSString *, id> *> *RUINThemeCatalog(NSError **error)
{
    if (!RUINThemeTargetMatches()) {
        if (error) *error = RUINThemeStoreError(RUINLocalizedString(@"themes.catalog_unavailable"), nil);
        return nil;
    }
    NSMutableArray<NSDictionary<NSString *, id> *> *packages = [NSMutableArray array];
    if (RUINThemeCatalogRuntimeAvailable()) {
        NSArray<NSURL *> *storeURLs = RUINThemeProductStoreURLs(error);
        if (!storeURLs) return nil;
        for (NSURL *storeURL in storeURLs) {
            NSArray<NSDictionary<NSString *, id> *> *records = RUINThemeReadProductStore(
                storeURL, storeURL.lastPathComponent, error);
            if (!records) return nil;
            for (NSDictionary *record in records) {
                if ([record[@"installedLocally"] boolValue]) [packages addObject:record];
            }
        }
    }
    NSArray<NSDictionary<NSString *, id> *> *downloaded = RUINThemeDownloadedAssetCatalog(error);
    if (!downloaded) return nil;
    [packages addObjectsFromArray:downloaded];
    if (error) *error = nil;
    return [packages sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSComparisonResult result = [((NSString *)left[@"name"] ?: @"")
            compare:((NSString *)right[@"name"] ?: @"")];
        return result == NSOrderedSame
            ? [left[@"productID"] compare:right[@"productID"]]
            : result;
    }];
}

BOOL RUINApplyDownloadedTheme(NSString *productID, NSError **error)
{
    if (![productID isKindOfClass:[NSString class]] || productID.length == 0 ||
        productID.length > RUINThemeMaximumInputLength) {
        if (error) *error = RUINThemeError(RUINThemeErrorInvalidArgument, @"Theme apply",
                                           @"A nonempty theme product ID of at most 256 characters is required.");
        return NO;
    }
    return RUINThemeFail(error, @"Theme apply");
}

BOOL RUINRemoveThemePackage(NSString *productID, NSError **error)
{
    if (![productID isKindOfClass:[NSString class]] || productID.length == 0 ||
        productID.length > RUINThemeMaximumInputLength) {
        if (error) *error = RUINThemeError(RUINThemeErrorInvalidArgument, @"Theme removal",
                                           @"A nonempty theme product ID of at most 256 characters is required.");
        return NO;
    }
    return RUINThemeFail(error, @"Theme removal");
}

void RUINResetTheme(RUINThemeApplyCompletion completion)
{
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        RUINInstallThemeFeatures();
        if (!RUINThemeResetActionAvailable() ||
            atomic_load(&gThemeApplyObserverStatus) != RUINThemeHookInstalled ||
            atomic_load(&gThemeApplyFailureObserverStatus) != RUINThemeHookInstalled) {
            completion(NO, RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
                @"Theme reset", @"LINE's verified reset action or apply-event observers are unavailable in this process."));
            return;
        }
        UIViewController *controller = RUINThemeVisibleManagementController();
        if (!controller) {
            completion(NO, RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
                @"Theme reset", @"Open LINE's native theme-management screen before requesting a reset."));
            return;
        }

        os_unfair_lock_lock(&gThemePendingResetLock);
        if (gThemePendingResetCompletion) {
            os_unfair_lock_unlock(&gThemePendingResetLock);
            completion(NO, RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
                @"Theme reset", @"Another native theme reset is already awaiting LINE's apply result."));
            return;
        }
        uint64_t requestID = atomic_fetch_add_explicit(&gThemeNextResetID, 1, memory_order_relaxed);
        if (!requestID) requestID = atomic_fetch_add_explicit(&gThemeNextResetID, 1, memory_order_relaxed);
        gThemePendingResetCompletion = [completion copy];
        gThemePendingResetID = requestID;
        os_unfair_lock_unlock(&gThemePendingResetLock);

        [(id<RUINThemeResetAction>)controller didTapResetButton];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RUINThemeFinishPendingReset(requestID, NO, RUINThemeError(
                RUINThemeErrorNativeAPIUnavailable, @"Theme reset",
                @"No default-theme apply event arrived within 120 seconds; the native action's outcome is unknown."));
        });
    });
}

static void RUINDownloadThemeAsset(NSString *name,
                           NSString *productID,
                           NSString *version,
                           BOOL requiresPreference,
                           RUINThemeDownloadCompletion completion)
{
    if (!completion) return;
    version = RUINThemeDownloadVersion(version);
    BOOL nameValid = [name isKindOfClass:[NSString class]] && name.length > 0 &&
        name.length <= RUINThemeMaximumInputLength &&
        [[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0 &&
        [name rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
    BOOL productIDValid = RUINThemeSafeURLComponent(productID, NO) && productID.length >= 6;
    BOOL versionValid = RUINThemeSafeURLComponent(version, YES);
    if (!nameValid || !productIDValid || !versionValid) {
        NSError *error = RUINThemeError(RUINThemeErrorInvalidArgument,
            @"Manual name/ID/version download",
            @"Name must be nonempty; product ID must be 6 to 128 URL-safe characters; version must be 1 to 128 decimal digits.");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }
    if (!RUINThemeTargetMatches()) {
        NSError *error = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
            @"Manual name/ID/version download", RUINLocalizedString(@"themes.download_unavailable"));
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }
    if (requiresPreference && ![[NSUserDefaults standardUserDefaults] boolForKey:RUINThemeShopDownloadEnabledDefaultsKey]) {
        NSError *error = RUINThemeError(RUINThemeErrorNativeAPIUnavailable,
            @"Manual name/ID/version download", @"Enable the local theme download preference first.");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }
    productID = RUINCanonicalThemeProductID(productID);
    NSURL *assetURL = RUINThemePublicAssetURL(productID, version);
    if (!assetURL) {
        NSError *error = RUINThemeError(RUINThemeErrorInvalidArgument,
            @"Manual name/ID/version download", @"The supplied product ID and version did not form a valid asset URL.");
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
        return;
    }

    RUINThemeAssetTransfer *transfer = [RUINThemeAssetTransfer new];
    [transfer startURL:assetURL productID:productID version:version
        displayName:[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        completion:completion];
}


void RUINDownloadThemeByID(NSString *name, NSString *productID, NSString *version,
    RUINThemeDownloadCompletion completion)
{
    RUINDownloadThemeAsset(name, productID, version, YES, completion);
}

void RUINDownloadRegisteredTheme(NSString *name, NSString *productID, NSString *version,
    RUINThemeDownloadCompletion completion)
{
    RUINDownloadThemeAsset(name, productID, version, NO, completion);
}
