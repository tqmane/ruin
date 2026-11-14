%config(generator=internal);

#import <Foundation/Foundation.h>

static NSString *RUINResolveDeclaredIconName(id candidate, NSDictionary *icons, BOOL *valid)
{
    if (valid) *valid = NO;
    if (![candidate isKindOfClass:NSString.class] || ![candidate length] ||
        ![icons isKindOfClass:NSDictionary.class]) return nil;

    NSDictionary *primary = [icons[@"CFBundlePrimaryIcon"] isKindOfClass:NSDictionary.class]
        ? icons[@"CFBundlePrimaryIcon"] : nil;
    NSString *primaryName = [primary[@"CFBundleIconName"] isKindOfClass:NSString.class]
        ? primary[@"CFBundleIconName"] : nil;
    if (primaryName && [candidate isEqualToString:primaryName]) {
        if (valid) *valid = YES;
        return nil;
    }

    NSDictionary *alternates = [icons[@"CFBundleAlternateIcons"] isKindOfClass:NSDictionary.class]
        ? icons[@"CFBundleAlternateIcons"] : nil;
    if ([alternates[candidate] isKindOfClass:NSDictionary.class]) {
        if (valid) *valid = YES;
        return candidate;
    }

    NSString *match = nil;
    for (id key in alternates) {
        NSDictionary *entry = [alternates[key] isKindOfClass:NSDictionary.class] ? alternates[key] : nil;
        if (![entry[@"CFBundleIconName"] isEqual:candidate]) continue;
        if (match) return nil;
        match = [key isKindOfClass:NSString.class] ? key : nil;
    }
    if (match) {
        if (valid) *valid = YES;
        return match;
    }
    return nil;
}

#if defined(RUIN_LOCAL_APPEARANCE_HOST_CHECK)

#include <assert.h>

int main(void)
{
    NSDictionary *icons = @{
        @"CFBundlePrimaryIcon":@{@"CFBundleIconName":@"primary"},
        @"CFBundleAlternateIcons":@{
            @"first":@{@"CFBundleIconName":@"firstAsset"},
            @"second":@{@"CFBundleIconName":@"secondAsset"},
            @"ambiguousA":@{@"CFBundleIconName":@"sharedAsset"},
            @"ambiguousB":@{@"CFBundleIconName":@"sharedAsset"}
        }
    };
    BOOL valid = NO;
    assert(RUINResolveDeclaredIconName(@"primary", icons, &valid) == nil && valid);
    assert([RUINResolveDeclaredIconName(@"first", icons, &valid) isEqualToString:@"first"] && valid);
    assert([RUINResolveDeclaredIconName(@"secondAsset", icons, &valid) isEqualToString:@"second"] && valid);
    assert(RUINResolveDeclaredIconName(@"sharedAsset", icons, &valid) == nil && !valid);
    assert(RUINResolveDeclaredIconName(@"missing", icons, &valid) == nil && !valid);
    assert(RUINResolveDeclaredIconName(@17, icons, &valid) == nil && !valid);
    return 0;
}

#else

#import "../core/Localization.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "../core/Features.h"
#import "../core/TargetMetadata.h"
#import "../core/SwiftFields.h"
#import "LocalAppearance.h"

static NSString * const kAppIconViewControllerClass = @"_TtC14LineSettingsUI21AppIconViewController";
static NSString * const kAppIconCollectionCellClass = @"_TtC14LineSettingsUI25AppIconCollectionViewCell";
static NSString * const kAppIconApplySheetClass = @"_TtC14LineSettingsUI37AppIconApplyBottomSheetViewController";
static NSString * const kAppIconBottomButtonContainerClass = @"_TtC14LineSettingsUI32AppIconBottomButtonContainerView";

static Class gAppIconViewControllerClass;
static Class gAppIconCollectionCellClass;
static Class gAppIconApplySheetClass;
static Class gAppIconBottomButtonContainerClass;
static _Atomic(IMP) gOriginalShouldSelect;
static _Atomic(IMP) gOriginalApply;
static _Atomic(IMP) gOriginalInlineApply;
static char gSelectedLocalIconNameKey;
static uint64_t gSelectionGeneration;
static BOOL gLastFeatureEnabled;
static BOOL gFeatureStateInitialized;
static atomic_bool gHooksInstalled = ATOMIC_VAR_INIT(false);
static atomic_bool gSupportsAlternateIcons = ATOMIC_VAR_INIT(false);
static atomic_bool gSupportsAlternateIconsChecked = ATOMIC_VAR_INIT(false);
static atomic_bool gCurrentIconIsPrimary = ATOMIC_VAR_INIT(false);
static atomic_bool gCurrentIconChecked = ATOMIC_VAR_INIT(false);
static atomic_bool gLastApplyChecked = ATOMIC_VAR_INIT(false);
static atomic_bool gLastApplyMatchesCurrent = ATOMIC_VAR_INIT(false);
static atomic_int gInstallStatus = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gSelectionChecks = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gSelectionNameReads = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gSelectionNameReadFailures = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gDeclaredSelections = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gApplyAttempts = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gApplySuccesses = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gApplyFailures = ATOMIC_VAR_INIT(0);

static BOOL RUINLocalAppearanceCompatible(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    return RUINTargetMetadataMatchesInfo(info);
}

static BOOL RUINLocalAppearanceEnabled(void)
{
    return RUINLocalAppearanceCompatible() &&
        [NSUserDefaults.standardUserDefaults boolForKey:RUINLocalLYPEnabledDefaultsKey];
}

static void RUINSyncSelectionGeneration(void)
{
    BOOL enabled = RUINLocalAppearanceEnabled();
    if (!gFeatureStateInitialized || enabled != gLastFeatureEnabled) {
        gSelectionGeneration++;
        gLastFeatureEnabled = enabled;
        gFeatureStateInitialized = YES;
    }
}

static NSDictionary *RUINCurrentIconSettings(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    BOOL isPad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    id settings = info[isPad ? @"CFBundleIcons~ipad" : @"CFBundleIcons"];
    if (![settings isKindOfClass:NSDictionary.class] && isPad)
        settings = info[@"CFBundleIcons"];
    return [settings isKindOfClass:NSDictionary.class] ? settings : nil;
}

static NSString *RUINIconNameFromSwiftObject(id object, Class expectedClass,
                                             const char *fieldPath, BOOL *readSucceeded)
{
    if (readSucceeded) *readSucceeded = NO;
    if (!object || object_getClass(object) != expectedClass) return nil;
    id value = RUINCopySwiftField(object, fieldPath);
    if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
    if (readSucceeded) *readSucceeded = YES;
    return value;
}

static void RUINClearSelectedLocalIconName(UIViewController *controller)
{
    objc_setAssociatedObject(controller, &gSelectedLocalIconNameKey, nil,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RUINCaptureSelectedLocalIconName(UIViewController *controller, NSString *modelName)
{
    if (!controller || !modelName) return;
    objc_setAssociatedObject(controller, &gSelectedLocalIconNameKey,
        @[modelName, @(gSelectionGeneration)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString *RUINCapturedLocalIconName(UIViewController *controller)
{
    NSArray *selection = objc_getAssociatedObject(controller, &gSelectedLocalIconNameKey);
    if (selection.count != 2 || [selection[1] unsignedLongLongValue] != gSelectionGeneration ||
        ![selection[0] isKindOfClass:NSString.class]) return nil;
    return selection[0];
}

static UIViewController *RUINAppIconControllerInResponderChain(UIResponder *responder)
{
    for (UIResponder *current = responder; current; current = current.nextResponder)
        if (object_getClass(current) == gAppIconViewControllerClass) return (UIViewController *)current;
    return nil;
}

static void RUINShowLocalIconError(UIViewController *owner, NSString *message)
{
    if (!owner || !owner.isViewLoaded || owner.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.ok") style:UIAlertActionStyleDefault handler:nil]];
    [owner presentViewController:alert animated:YES completion:nil];
}

static BOOL RUINLocalShouldSelectIcon(id self, SEL selector,
                                      UICollectionView *collectionView, NSIndexPath *indexPath)
{
    BOOL (*original)(id, SEL, id, id) = (BOOL (*)(id, SEL, id, id))atomic_load(&gOriginalShouldSelect);
    if (object_getClass(self) != gAppIconViewControllerClass)
        return original ? original(self, selector, collectionView, indexPath) : NO;
    RUINSyncSelectionGeneration();
    if (!RUINLocalAppearanceEnabled()) {
        RUINClearSelectedLocalIconName(self);
        return original ? original(self, selector, collectionView, indexPath) : NO;
    }

    UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
    if (!cell || object_getClass(cell) != gAppIconCollectionCellClass) {
        RUINClearSelectedLocalIconName(self);
        return original ? original(self, selector, collectionView, indexPath) : NO;
    }

    atomic_fetch_add_explicit(&gSelectionChecks, 1, memory_order_relaxed);
    if (!UIApplication.sharedApplication.supportsAlternateIcons) {
        RUINClearSelectedLocalIconName(self);
        return original ? original(self, selector, collectionView, indexPath) : NO;
    }
    BOOL readSucceeded = NO;
    NSString *modelName = RUINIconNameFromSwiftObject(cell, gAppIconCollectionCellClass,
                                                       "iconName", &readSucceeded);
    atomic_fetch_add_explicit(readSucceeded ? &gSelectionNameReads : &gSelectionNameReadFailures,
                              1, memory_order_relaxed);
    BOOL valid = NO;
    RUINResolveDeclaredIconName(modelName, RUINCurrentIconSettings(), &valid);
    if (valid) {
        atomic_fetch_add_explicit(&gDeclaredSelections, 1, memory_order_relaxed);
        RUINCaptureSelectedLocalIconName(self, modelName);
        return YES;
    }
    RUINClearSelectedLocalIconName(self);
    return original ? original(self, selector, collectionView, indexPath) : NO;
}

static void RUINCloseNativeApplySheet(UIViewController *controller)
{
    if (controller.presentingViewController) {
        [controller dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    UINavigationController *navigation = controller.navigationController;
    if (navigation && navigation.topViewController == controller) {
        if (navigation.viewControllers.count > 1)
            [navigation popViewControllerAnimated:YES];
        else if (navigation.presentingViewController)
            [navigation dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    for (UIViewController *ancestor = controller.parentViewController; ancestor; ancestor = ancestor.parentViewController) {
        if (ancestor.presentingViewController) {
            [ancestor dismissViewControllerAnimated:YES completion:nil];
            return;
        }
    }
}

static void RUINRecordCurrentIconState(void)
{
    atomic_store_explicit(&gCurrentIconIsPrimary,
        UIApplication.sharedApplication.alternateIconName == nil, memory_order_relaxed);
    atomic_store_explicit(&gCurrentIconChecked, true, memory_order_relaxed);
}

static BOOL RUINCurrentIconMatches(NSString *alternateName)
{
    NSString *currentName = UIApplication.sharedApplication.alternateIconName;
    return alternateName ? [currentName isEqualToString:alternateName] : currentName == nil;
}

static BOOL RUINApplyLocalIconName(NSString *modelName, UIViewController *owner,
                                   BOOL dismissOnSuccess)
{
    if (!UIApplication.sharedApplication.supportsAlternateIcons) {
        atomic_fetch_add_explicit(&gApplyFailures, 1, memory_order_relaxed);
        RUINShowLocalIconError(owner, RUINLocalizedString(@"appearance.icon_change_failed"));
        return YES;
    }

    BOOL valid = NO;
    NSString *alternateName = RUINResolveDeclaredIconName(modelName, RUINCurrentIconSettings(), &valid);
    if (!valid) return NO;

    atomic_fetch_add_explicit(&gApplyAttempts, 1, memory_order_relaxed);
    __weak UIViewController *weakController = owner;
    [UIApplication.sharedApplication setAlternateIconName:alternateName completionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RUINRecordCurrentIconState();
            BOOL matches = RUINCurrentIconMatches(alternateName);
            atomic_store_explicit(&gLastApplyMatchesCurrent, matches, memory_order_relaxed);
            atomic_store_explicit(&gLastApplyChecked, true, memory_order_relaxed);
            BOOL applied = error == nil && matches;
            if (applied) {
                atomic_fetch_add_explicit(&gApplySuccesses, 1, memory_order_relaxed);
                if (dismissOnSuccess && weakController) RUINCloseNativeApplySheet(weakController);
            } else {
                atomic_fetch_add_explicit(&gApplyFailures, 1, memory_order_relaxed);
                if (weakController)
                    RUINShowLocalIconError(weakController, RUINLocalizedString(@"appearance.icon_change_failed"));
            }
        });
    }];
    return YES;
}

static void RUINLocalApplyIcon(id self, SEL selector, id sender)
{
    void (*original)(id, SEL, id) = (void (*)(id, SEL, id))atomic_load(&gOriginalApply);
    if (!NSThread.isMainThread || object_getClass(self) != gAppIconApplySheetClass) {
        if (original) original(self, selector, sender);
        return;
    }
    RUINSyncSelectionGeneration();
    if (!RUINLocalAppearanceEnabled()) {
        if (original) original(self, selector, sender);
        return;
    }

    NSString *modelName = RUINIconNameFromSwiftObject(self, gAppIconApplySheetClass,
        "icon.name", NULL);
    if (!modelName || !RUINApplyLocalIconName(modelName, self, YES)) {
        if (original) original(self, selector, sender);
    }
}

static void RUINLocalInlineApplyIcon(id self, SEL selector)
{
    void (*original)(id, SEL) = (void (*)(id, SEL))atomic_load(&gOriginalInlineApply);
    if (!NSThread.isMainThread || object_getClass(self) != gAppIconBottomButtonContainerClass) {
        if (original) original(self, selector);
        return;
    }
    RUINSyncSelectionGeneration();
    if (!RUINLocalAppearanceEnabled()) {
        if (original) original(self, selector);
        return;
    }

    UIViewController *controller = RUINAppIconControllerInResponderChain((UIResponder *)self);
    NSString *modelName = RUINCapturedLocalIconName(controller);
    if (!controller || !modelName || !RUINApplyLocalIconName(modelName, controller, NO)) {
        if (original) original(self, selector);
    }
}

%group RUINLocalAppIcons
%hook RUINAppIconController
- (BOOL)collectionView:(UICollectionView *)collectionView shouldSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store(&gOriginalShouldSelect, original);
    return RUINLocalShouldSelectIcon(self, _cmd, collectionView, indexPath);
}
%end
%hook RUINAppIconApplySheet
- (void)didPressedApply:(id)sender
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store(&gOriginalApply, original);
    RUINLocalApplyIcon(self, _cmd, sender);
}
%end
%hook RUINAppIconBottomButton
- (void)didPressApply
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store(&gOriginalInlineApply, original);
    RUINLocalInlineApplyIcon(self, _cmd);
}
%end
%end

void RUINInstallLocalAppearance(void)
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINInstallLocalAppearance(); });
        return;
    }

    RUINSyncSelectionGeneration();
    if (!RUINLocalAppearanceCompatible()) {
        atomic_store_explicit(&gInstallStatus, 1, memory_order_relaxed);
        return;
    }
    atomic_store_explicit(&gSupportsAlternateIcons,
        UIApplication.sharedApplication.supportsAlternateIcons, memory_order_relaxed);
    atomic_store_explicit(&gSupportsAlternateIconsChecked, true, memory_order_relaxed);
    RUINRecordCurrentIconState();
    if (atomic_load_explicit(&gHooksInstalled, memory_order_relaxed)) return;

    Class viewControllerClass = objc_lookUpClass(kAppIconViewControllerClass.UTF8String);
    Class collectionCellClass = objc_lookUpClass(kAppIconCollectionCellClass.UTF8String);
    Class applySheetClass = objc_lookUpClass(kAppIconApplySheetClass.UTF8String);
    Class bottomButtonClass = objc_lookUpClass(kAppIconBottomButtonContainerClass.UTF8String);
    Method selectMethod = viewControllerClass
        ? class_getInstanceMethod(viewControllerClass, sel_registerName("collectionView:shouldSelectItemAtIndexPath:")) : NULL;
    Method applyMethod = applySheetClass
        ? class_getInstanceMethod(applySheetClass, sel_registerName("didPressedApply:")) : NULL;
    Method inlineApplyMethod = bottomButtonClass
        ? class_getInstanceMethod(bottomButtonClass, sel_registerName("didPressApply")) : NULL;
    if (!viewControllerClass || !collectionCellClass || !applySheetClass ||
        !bottomButtonClass || !selectMethod || !applyMethod || !inlineApplyMethod) {
        atomic_store_explicit(&gInstallStatus, 2, memory_order_relaxed);
        return;
    }

    const char *selectEncoding = method_getTypeEncoding(selectMethod);
    const char *applyEncoding = method_getTypeEncoding(applyMethod);
    const char *inlineApplyEncoding = method_getTypeEncoding(inlineApplyMethod);
    if (!selectEncoding || strcmp(selectEncoding, "B32@0:8@16@24") ||
        !applyEncoding || strcmp(applyEncoding, "v24@0:8@16") ||
        !inlineApplyEncoding || strcmp(inlineApplyEncoding, "v16@0:8")) {
        atomic_store_explicit(&gInstallStatus, 3, memory_order_relaxed);
        return;
    }

    gAppIconViewControllerClass = viewControllerClass;
    gAppIconCollectionCellClass = collectionCellClass;
    gAppIconApplySheetClass = applySheetClass;
    gAppIconBottomButtonContainerClass = bottomButtonClass;
    IMP selectOriginal = method_getImplementation(selectMethod);
    IMP applyOriginal = method_getImplementation(applyMethod);
    IMP inlineOriginal = method_getImplementation(inlineApplyMethod);
    if (!selectOriginal || !applyOriginal || !inlineOriginal) {
        atomic_store_explicit(&gInstallStatus, 2, memory_order_relaxed);
        return;
    }
    atomic_store(&gOriginalShouldSelect, selectOriginal);
    atomic_store(&gOriginalApply, applyOriginal);
    atomic_store(&gOriginalInlineApply, inlineOriginal);
    %init(RUINLocalAppIcons, RUINAppIconController = viewControllerClass,
        RUINAppIconApplySheet = applySheetClass, RUINAppIconBottomButton = bottomButtonClass);
    atomic_store_explicit(&gHooksInstalled, true, memory_order_relaxed);
    atomic_store_explicit(&gInstallStatus,
        atomic_load_explicit(&gHooksInstalled, memory_order_relaxed) ? 4 : 2, memory_order_relaxed);
}

NSDictionary<NSString *, id> *RUINLocalAppearanceDiagnostics(void)
{
    if (NSThread.isMainThread) {
        atomic_store_explicit(&gSupportsAlternateIcons,
            UIApplication.sharedApplication.supportsAlternateIcons, memory_order_relaxed);
        atomic_store_explicit(&gSupportsAlternateIconsChecked, true, memory_order_relaxed);
        RUINRecordCurrentIconState();
    }
    NSDictionary *icons = RUINCurrentIconSettings();
    NSDictionary *alternates = [icons[@"CFBundleAlternateIcons"] isKindOfClass:NSDictionary.class]
        ? icons[@"CFBundleAlternateIcons"] : nil;
    return @{
        @"compatible":@(RUINLocalAppearanceCompatible()),
        @"enabled":@(RUINLocalAppearanceEnabled()),
        @"hooksInstalled":@(atomic_load_explicit(&gHooksInstalled, memory_order_relaxed)),
        @"inlineApplyHookInstalled":@(atomic_load(&gOriginalInlineApply) != NULL),
        @"installStatus":@(atomic_load_explicit(&gInstallStatus, memory_order_relaxed)),
        @"supportsAlternateIconsChecked":@(atomic_load_explicit(&gSupportsAlternateIconsChecked, memory_order_relaxed)),
        @"supportsAlternateIcons":@(atomic_load_explicit(&gSupportsAlternateIcons, memory_order_relaxed)),
        @"currentIconChecked":@(atomic_load_explicit(&gCurrentIconChecked, memory_order_relaxed)),
        @"currentIconIsPrimary":@(atomic_load_explicit(&gCurrentIconIsPrimary, memory_order_relaxed)),
        @"lastApplyChecked":@(atomic_load_explicit(&gLastApplyChecked, memory_order_relaxed)),
        @"lastApplyMatchesCurrentIcon":@(atomic_load_explicit(&gLastApplyMatchesCurrent, memory_order_relaxed)),
        @"declaredAlternateCount":@(alternates.count),
        @"selectionChecks":@(atomic_load_explicit(&gSelectionChecks, memory_order_relaxed)),
        @"selectionNameReads":@(atomic_load_explicit(&gSelectionNameReads, memory_order_relaxed)),
        @"selectionNameReadFailures":@(atomic_load_explicit(&gSelectionNameReadFailures, memory_order_relaxed)),
        @"declaredSelections":@(atomic_load_explicit(&gDeclaredSelections, memory_order_relaxed)),
        @"applyAttempts":@(atomic_load_explicit(&gApplyAttempts, memory_order_relaxed)),
        @"applySuccesses":@(atomic_load_explicit(&gApplySuccesses, memory_order_relaxed)),
        @"applyFailures":@(atomic_load_explicit(&gApplyFailures, memory_order_relaxed))
    };
}

#endif
