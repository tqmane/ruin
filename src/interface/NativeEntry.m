#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Features.h"
#import "SecondaryLogin.h"

extern void RUINOpenSettingsInLINE(UIViewController *owner);
extern void RUINRefreshRuntimeReport(void);

static void (*originalSettingsDidAppear)(id, SEL, BOOL);
static BOOL nativeHookInstalled;
static NSUInteger attachedRows;
static NSString *runtimeEncoding;
static char entryFooterKey;
static char homeItemKey;
static BOOL homeHookInstalled, homeEntryAvailable;
static BOOL friendHomeHookInstalled;

static UITableView *RUINFindSettingsTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for (UIView *child in view.subviews) {
        UITableView *table = RUINFindSettingsTable(child);
        if (table) return table;
    }
    return nil;
}

static void RUINSettingsEntryTapped(id self, SEL selector, id sender) {
    (void)selector; (void)sender;
    RUINOpenSettingsInLINE((UIViewController *)self);
}

static void RUINAttachSettingsEntry(UIViewController *controller) {
    UITableView *table = RUINFindSettingsTable(controller.view);
    if (!table) return;
    UIView *installedFooter = objc_getAssociatedObject(table, &entryFooterKey);
    if (installedFooter && table.tableFooterView == installedFooter) return;

    // Keep LINE's existing footer and datasource intact; append one native row.
    UIView *oldFooter = table.tableFooterView;
    CGFloat oldHeight = oldFooter ? CGRectGetHeight(oldFooter.frame) : 0;
    CGFloat width = CGRectGetWidth(table.bounds);
    table.tableFooterView = nil;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, oldHeight + 80)];
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (oldFooter) {
        oldFooter.frame = CGRectMake(0, 0, width, oldHeight);
        oldFooter.autoresizingMask |= UIViewAutoresizingFlexibleWidth;
        [footer addSubview:oldFooter];
    }
    UIButtonConfiguration *configuration = UIButtonConfiguration.plainButtonConfiguration;
    configuration.title = @"RUIN";
    configuration.subtitle = @"ローカル設定・診断";
    configuration.image = [UIImage systemImageNamed:@"chevron.right"];
    configuration.imagePlacement = NSDirectionalRectEdgeTrailing;
    configuration.imagePadding = 12;
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.background.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    configuration.background.cornerRadius = 12;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(10, 16, 10, 16);
    UIButton *entry = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
    entry.frame = CGRectMake(16, oldHeight + 8, MAX(0, width - 32), 60);
    entry.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    entry.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    entry.accessibilityIdentifier = @"ruin.line.settings.entry";
    entry.accessibilityLabel = @"RUINの設定と診断";
    [entry addTarget:controller action:sel_registerName("ruin_openSettings:") forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:entry];
    table.tableFooterView = footer;
    objc_setAssociatedObject(table, &entryFooterKey, footer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    attachedRows++;
    RUINRefreshRuntimeReport();
}

static void RUINSettingsDidAppear(id self, SEL selector, BOOL animated) {
    originalSettingsDidAppear(self, selector, animated);
    RUINAttachSettingsEntry((UIViewController *)self);
}

static void RUINAttachHomeSettingsButton(UIViewController *controller) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:RUINSecondaryLoginEnabledKey]) return;
    if (!controller.navigationController || controller.navigationController.navigationBarHidden) return;
    UIBarButtonItem *item = objc_getAssociatedObject(controller, &homeItemKey);
    if (!item) {
        item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
            style:UIBarButtonItemStylePlain target:controller action:sel_registerName("ruin_openSettings:")];
        item.accessibilityLabel = @"RUIN設定";
        objc_setAssociatedObject(controller, &homeItemKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray *items = controller.navigationItem.rightBarButtonItems ?: @[];
    if (![items containsObject:item]) controller.navigationItem.rightBarButtonItems = [items arrayByAddingObject:item];
    homeEntryAvailable = YES;
    RUINRefreshRuntimeReport();
}

void RUINInstallNativeEntry(void) {
    if (nativeHookInstalled && homeHookInstalled && friendHomeHookInstalled) return;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    if (![info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier] ||
        ![info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] ||
        ![info[@"CFBundleVersion"] isEqual:RUINTargetBuild]) return;
    for (NSString *name in @[@"_TtC8LineHome18HomeViewController", @"_TtC11LineHomeTab23FriendTabViewController"]) {
        BOOL *flag = [name containsString:@"FriendTab"] ? &friendHomeHookInstalled : &homeHookInstalled;
        if (*flag) continue;
        Class home = objc_getClass(name.UTF8String);
        Method appearance = home ? class_getInstanceMethod(home, @selector(viewDidAppear:)) : NULL;
        if (appearance && !strcmp(method_getTypeEncoding(appearance), "v20@0:8B16")) {
            class_addMethod(home, sel_registerName("ruin_openSettings:"), (IMP)RUINSettingsEntryTapped, "v24@0:8@16");
            IMP original = method_getImplementation(appearance);
            IMP replacement = imp_implementationWithBlock(^(id object, BOOL animated) {
                ((void (*)(id, SEL, BOOL))original)(object, @selector(viewDidAppear:), animated);
                RUINAttachHomeSettingsButton(object);
            });
            if (!class_addMethod(home, @selector(viewDidAppear:), replacement, "v20@0:8B16"))
                method_setImplementation(appearance, replacement);
            *flag = YES;
        }
    }
    if (nativeHookInstalled) return;
    Class cls = objc_getClass("_TtC4LINE22SettingsViewController");
    if (!cls) return;
    SEL selector = @selector(viewDidAppear:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    const char *encoding = method_getTypeEncoding(method);
    runtimeEncoding = encoding ? @(encoding) : @"";
    if (!encoding || strcmp(encoding, "v20@0:8B16")) return;
    originalSettingsDidAppear = (void *)method_getImplementation(method);
    if (!class_addMethod(cls, sel_registerName("ruin_openSettings:"), (IMP)RUINSettingsEntryTapped, "v24@0:8@16")) return;
    if (!class_addMethod(cls, selector, (IMP)RUINSettingsDidAppear, encoding))
        method_setImplementation(method, (IMP)RUINSettingsDidAppear);
    nativeHookInstalled = YES;
}

NSDictionary *RUINNativeEntryDiagnostics(void) {
    return @{@"placement": @"LINE settings list footer",
             @"class": @"_TtC4LINE22SettingsViewController",
             @"hookInstalled": @(nativeHookInstalled),
             @"runtimeEncoding": runtimeEncoding ?: @"",
             @"homeHookInstalled": @(homeHookInstalled),
             @"friendHomeHookInstalled": @(friendHomeHookInstalled),
             @"homeEntryAvailable": @(homeEntryAvailable),
             @"attachedRowCount": @(attachedRows)};
}
