#import "NativeThemeWorkflow.h"
#import "../core/Localization.h"
#import "NativeThemeNavigation.h"
#import "NativeThemeInstall.h"
#import "NativeThemeRegistration.h"
#import "NativeThemeLocalPolicy.h"
#import "NativeThemeReceipt.h"
#import "RuntimeInspector.h"
#import "ThemeFeatures.h"
#import "ThemeProductIdentity.h"
#import "SwiftFields.h"
#import <objc/runtime.h>

// Only the original LINE management screen renders and applies these packages.
static NSMutableSet<NSString *> *gImportedArchives;
static BOOL gImporting;
static NSUInteger gImportedCount, gFailedCount;
static NSUInteger gRefreshAttempts, gRefreshSkippedForSelection;
static NSUInteger gNativeAppearanceRequests;
static NSString *gLastImportError;
static id gImportedScope;
static __weak UIViewController *gPendingMyThemesController;

static NSArray *RUINNativeSelectedThemeIDs(UIViewController *controller)
{
    id selected = RUINCopySwiftField(controller, "viewModel.selectedCellViewModels");
    if (![selected isKindOfClass:NSArray.class]) return nil;
    NSMutableArray *IDs = [NSMutableArray array];
    for (id model in selected) {
        id productID = RUINCopySwiftField(model, "package.productId");
        if (![productID isKindOfClass:NSString.class]) return nil;
        [IDs addObject:RUINCanonicalThemeProductID(productID)];
    }
    return IDs;
}

static NSString *RUINArchiveIdentity(NSDictionary *record)
{
    NSURL *URL = record[@"packageURL"];
    if (![URL isKindOfClass:NSURL.class] || !URL.isFileURL ||
        ![record[@"downloadedLocally"] boolValue] ||
        ![record[@"archiveStructureValidated"] boolValue]) return nil;
    return URL.path;
}

static NSArray *RUINPreferredArchives(NSArray *catalog)
{
    NSMutableDictionary *best = [NSMutableDictionary dictionary];
    for (NSDictionary *candidate in catalog) {
        NSDictionary *record = candidate;
        if (!RUINArchiveIdentity(record)) continue;
        NSString *productID = RUINCanonicalThemeProductID(record[@"productID"]);
        if (!productID.length) continue;
        if (![productID isEqual:record[@"productID"]]) {
            NSMutableDictionary *normalized = [record mutableCopy];
            normalized[@"productID"] = productID;
            record = normalized;
        }
        NSDictionary *previous = best[productID];
        long long version = [record[@"version"] longLongValue];
        long long oldVersion = [previous[@"version"] longLongValue];
        NSURL *URL = record[@"packageURL"], *oldURL = previous[@"packageURL"];
        NSDate *date = [NSFileManager.defaultManager attributesOfItemAtPath:URL.path error:nil][NSFileModificationDate] ?: NSDate.distantPast;
        NSDate *oldDate = oldURL ? [NSFileManager.defaultManager attributesOfItemAtPath:oldURL.path error:nil][NSFileModificationDate] : nil;
        NSComparisonResult dates = [date compare:oldDate ?: NSDate.distantPast];
        if (!previous || version > oldVersion || (version == oldVersion &&
            (dates == NSOrderedDescending || (dates == NSOrderedSame &&
             [URL.lastPathComponent compare:oldURL.lastPathComponent] == NSOrderedDescending)))) best[productID] = record;
    }
    return [best.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        return [left[@"name"] compare:right[@"name"]];
    }];
}

@interface RUINNativeThemeImportJob : NSObject
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, copy) NSArray<NSDictionary *> *records;
@property(nonatomic) NSUInteger index;
@property(nonatomic) NSUInteger saved;
@property(nonatomic, copy) NSArray *selection;
@property(nonatomic, strong) id scope;
- (void)next;
@end

@implementation RUINNativeThemeImportJob
- (void)next
{
    NSAssert(NSThread.isMainThread, @"Native theme workflow uses the main queue");
    if (self.index == self.records.count || self.scope != RUINNativeThemeRegistrationScopeToken()) {
        gImporting = NO;
        UIViewController *controller = self.controller;
        if (self.saved && controller.viewIfLoaded.window &&
            controller.navigationController.topViewController == controller &&
            self.selection && [self.selection isEqual:RUINNativeSelectedThemeIDs(controller)]) {
            gRefreshAttempts++;
            RUINRefreshNativeMyThemes(controller, ^(NSError *error) {
                if (error) gLastImportError = @"native_list_refresh_failed";
            });
        } else if (self.saved) gRefreshSkippedForSelection++;
        return;
    }
    NSDictionary *record = self.records[self.index++];
    RUINImportDownloadedTheme(record, ^(NSDictionary *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (result) {
                [gImportedArchives addObject:RUINArchiveIdentity(record)];
                self.saved++;
                gImportedCount++;
            }
            if (error) {
                gFailedCount++;
                gLastImportError = [NSString stringWithFormat:@"%@:%ld", error.domain, (long)error.code];
            }
            [self next];
        });
    });
}
@end

static void RUINImportOnNativeAppearance(UIViewController *controller, NSUInteger retry)
{
    if (!retry) gNativeAppearanceRequests++;
    if (!controller.viewIfLoaded.window || controller.navigationController.topViewController != controller) {
        gLastImportError = @"native_theme_screen_not_visible"; return;
    }
    gPendingMyThemesController = controller;
    // A controller can reappear after another archive is saved or an early
    // account-scope lookup fails. Receipts/import identities deduplicate work;
    // the lifetime of the view controller is not a completed import boundary.
    if (gImporting) return;
    if (!RUINNativeThemeRegistrationAvailable()) {
        if (retry < 12) {
            __weak UIViewController *weakController = controller;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                if (weakController) RUINImportOnNativeAppearance(weakController, retry + 1);
            });
        } else gLastImportError = @"native_theme_context_unavailable";
        return;
    }
    id scope = RUINNativeThemeRegistrationScopeToken();
    if (gImportedScope != scope) {
        [gImportedArchives removeAllObjects];
        gImportedScope = scope;
    }
    gImporting = YES;
    __weak UIViewController *weakController = controller;
    RUINNativeThemeRegistrationPackageURL(@"00000000-0000-0000-0000-000000000000", ^(NSURL *packageURL, NSError *rootError) {
        if (!packageURL || rootError) {
            dispatch_async(dispatch_get_main_queue(), ^{ gImporting = NO; gLastImportError = @"native_theme_account_scope_unavailable"; });
            return;
        }
        NSURL *root = packageURL.URLByDeletingLastPathComponent;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = nil;
        NSArray *catalog = RUINPreferredArchives(RUINThemeCatalog(&error));
        NSDictionary *receipts = RUINReadThemeReceipts(root);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *pending = [NSMutableArray array];
            for (NSDictionary *record in catalog) {
                NSString *identity = RUINArchiveIdentity(record);
                NSDictionary *receipt = receipts[RUINCanonicalThemeProductID(record[@"productID"])];
                long long registeredVersion = [receipt[@"rawVersion"] longLongValue];
                long long version = [record[@"version"] longLongValue];
                NSURL *URL = record[@"packageURL"];
                BOOL registered = receipt && (registeredVersion > version || (registeredVersion == version &&
                    [receipt[@"archiveName"] isEqual:URL.lastPathComponent]));
                if (registered && identity) [gImportedArchives addObject:identity];
                if (identity && ![gImportedArchives containsObject:identity]) [pending addObject:record];
            }
            UIViewController *visible = weakController;
            if (error || !visible.viewIfLoaded.window || visible.navigationController.topViewController != visible || !pending.count) {
                gImporting = NO;
                if (error) gLastImportError = @"saved_theme_catalog_unavailable";
                return;
            }
            RUINNativeThemeImportJob *job = [RUINNativeThemeImportJob new];
            job.controller = visible;
            job.records = pending;
            job.scope = scope;
            job.selection = RUINNativeSelectedThemeIDs(visible);
            [job next];
        });
        });
    });
}

void RUINInstallNativeThemeWorkflow(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gImportedArchives = [NSMutableSet set];
        [NSNotificationCenter.defaultCenter addObserverForName:RUINNativeThemeRegistrationAvailableNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                UIViewController *controller = gPendingMyThemesController;
                if (controller) RUINImportOnNativeAppearance(controller, 0);
            }];
        RUINInstallNativeThemeRegistrationCapture();
        RUINSetNativeMyThemesDidAppearHandler(^(UIViewController *controller) {
            RUINImportOnNativeAppearance(controller, 0);
            RUINRequestRuntimeSnapshot();
        });
    });
    RUINInstallNativeMyThemesDidAppearHook();
}

void RUINOpenDownloadedThemes(UIViewController *owner)
{
    RUINInstallNativeThemeWorkflow();
    RUINOpenNativeMyThemes(owner, ^(NSError *error) {
        if (!error) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"themes.my_themes_open_failed")
            message:RUINLocalizedString(@"themes.apply_retry_message")
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.close") style:UIAlertActionStyleCancel handler:nil]];
        if (owner.viewIfLoaded.window && !owner.presentedViewController) [owner presentViewController:alert animated:YES completion:nil];
    });
}

NSDictionary *RUINNativeThemeWorkflowDiagnostics(void)
{
    return @{@"nativeContextAvailable": @(RUINNativeThemeRegistrationAvailable()),
        @"registration":RUINNativeThemeRegistrationDiagnostics(),
        @"appearanceHook":RUINNativeMyThemesObservationDiagnostics(),
        @"appearanceImportRequests":@(gNativeAppearanceRequests),
        @"importInProgress": @(gImporting), @"imported": @(gImportedCount),
        @"failed": @(gFailedCount), @"lastError": gLastImportError ?: @"",
        @"listRefreshes":@(gRefreshAttempts), @"refreshSkippedForSelection":@(gRefreshSkippedForSelection),
        @"localOwnership":RUINNativeThemeLocalPolicyDiagnostics(),
        @"downloadControls":@"original_LINE",
        @"renderer": @"original_LINE_MyThemes", @"customTabViewsAdded": @NO};
}
