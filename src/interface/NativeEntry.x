%config(generator=internal);

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "Features.h"
#import "../core/TargetMetadata.h"
#import "Localization.h"
#import "SecondaryLogin.h"

extern void RUINOpenSettingsInLINE(UIViewController *owner);
extern void RUINRefreshRuntimeReport(void);

static BOOL nativeHookInstalled;
static NSUInteger attachedRows;
static NSString *runtimeEncoding;
static char entryFooterKey;
static char homeItemKey;
static BOOL homeHookInstalled, homeEntryAvailable;
static BOOL friendHomeHookInstalled;
static char settingsTableKey;
static atomic_uint_fast64_t settingsTableSearches, settingsTableReuse;

@interface RUINSettingsTableRecord : NSObject
@property(nonatomic, weak) UIView *root;
@property(nonatomic, weak) UITableView *table;
@property(nonatomic, weak) UIWindow *window;
@end
@implementation RUINSettingsTableRecord @end

@interface RUINSettingsFooterView : UIView
@property (nonatomic, strong) UIButton *entryButton;
@property (nonatomic) CGFloat entryTop;
@end

@implementation RUINSettingsFooterView
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    self.entryButton.frame = CGRectMake(16, self.entryTop, MAX(0, width - 32), 60);
}
@end

static UITableView *RUINFindSettingsTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for (UIView *child in view.subviews) {
        UITableView *table = RUINFindSettingsTable(child);
        if (table) return table;
    }
    return nil;
}

static NSString *RUINSettingsEntryAccessibilityLabel(void) {
    return RUINLocalizedString(@"settings.accessibility_label");
}

static UITableView *RUINCurrentSettingsTable(UIViewController *controller) {
    UIView *root = controller.view;
    RUINSettingsTableRecord *record = objc_getAssociatedObject(controller, &settingsTableKey);
    UITableView *table = record.table;
    if ([table isKindOfClass:UITableView.class] && record.root == root && root.window &&
        record.window == root.window && table.window == root.window &&
        [table isDescendantOfView:root] &&
        (!controller.navigationController || controller.navigationController.topViewController == controller)) {
        atomic_fetch_add(&settingsTableReuse, 1);
    } else {
        atomic_fetch_add(&settingsTableSearches, 1);
        table = RUINFindSettingsTable(root);
        record = [RUINSettingsTableRecord new];
        record.root = root;
        record.table = table;
        record.window = root.window;
        objc_setAssociatedObject(controller, &settingsTableKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return table;
}

static void RUINAttachSettingsEntry(UIViewController *controller) {
    UITableView *table = RUINCurrentSettingsTable(controller);
    if (!table) return;
    UIView *installedFooter = objc_getAssociatedObject(table, &entryFooterKey);
    if (installedFooter && table.tableFooterView == installedFooter) return;

    // Keep LINE's existing footer and datasource intact; append one native row.
    UIView *oldFooter = table.tableFooterView;
    CGRect oldFooterFrame = oldFooter ? oldFooter.frame : CGRectZero;
    CGFloat oldHeight = CGRectGetHeight(oldFooterFrame);
    CGFloat width = CGRectGetWidth(table.bounds);
    table.tableFooterView = nil;
    RUINSettingsFooterView *footer = [[RUINSettingsFooterView alloc] initWithFrame:CGRectMake(0, 0, width, oldHeight + 80)];
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (oldFooter) {
        oldFooter.frame = oldFooterFrame;
        [footer addSubview:oldFooter];
    }
    footer.entryTop = oldHeight + 8;
    UIButton *entry = [UIButton buttonWithType:UIButtonTypeCustom];
    footer.entryButton = entry;
    entry.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    entry.layer.cornerRadius = 12;
    entry.clipsToBounds = YES;
    entry.accessibilityIdentifier = @"ruin.line.settings.entry";
    entry.accessibilityLabel = RUINSettingsEntryAccessibilityLabel();
    entry.isAccessibilityElement = YES;
    UILabel *title = [UILabel new];
    title.text = @"RUIN";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.adjustsFontForContentSizeCategory = YES;
    title.textColor = UIColor.labelColor;
    title.isAccessibilityElement = NO;
    UILabel *subtitle = [UILabel new];
    subtitle.text = RUINLocalizedString(@"settings.entry_subtitle");
    subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    subtitle.adjustsFontForContentSizeCategory = YES;
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.isAccessibilityElement = NO;
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.alignment = UIStackViewAlignmentLeading;
    labels.spacing = 2;
    labels.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = UIColor.tertiaryLabelColor;
    chevron.isAccessibilityElement = NO;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [entry addSubview:labels];
    [entry addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
        [labels.leadingAnchor constraintEqualToAnchor:entry.leadingAnchor constant:16],
        [labels.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor],
        [labels.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor constant:-12],
        [chevron.trailingAnchor constraintEqualToAnchor:entry.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:entry.centerYAnchor]
    ]];
    [entry addTarget:controller action:sel_registerName("ruin_openSettings:") forControlEvents:UIControlEventTouchUpInside];
    [footer addSubview:entry];
    table.tableFooterView = footer;
    objc_setAssociatedObject(table, &entryFooterKey, footer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    attachedRows++;
    RUINRefreshRuntimeReport();
}

static void RUINAttachHomeSettingsButton(UIViewController *controller) {
    BOOL isNativePad = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad;
    if (!isNativePad && ![NSUserDefaults.standardUserDefaults boolForKey:RUINSecondaryLoginEnabledKey]) return;
    if (!controller.navigationController || controller.navigationController.navigationBarHidden) return;
    UIBarButtonItem *item = objc_getAssociatedObject(controller, &homeItemKey);
    if (!item) {
        item = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
            style:UIBarButtonItemStylePlain target:controller action:sel_registerName("ruin_openSettings:")];
        item.accessibilityLabel = RUINSettingsEntryAccessibilityLabel();
        objc_setAssociatedObject(controller, &homeItemKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray *items = controller.navigationItem.rightBarButtonItems ?: @[];
    BOOL changed = !homeEntryAvailable;
    if (![items containsObject:item]) {
        controller.navigationItem.rightBarButtonItems = [items arrayByAddingObject:item];
        changed = YES;
    }
    homeEntryAvailable = YES;
    if (changed) RUINRefreshRuntimeReport();
}

%group RUINHomeEntry
%hook RUINHomeController
- (void)viewDidAppear:(BOOL)animated
{
    %orig(animated);
    RUINAttachHomeSettingsButton(self);
}
%new(v24@0:8@16)
- (void)ruin_openSettings:(id)sender
{
    (void)sender;
    RUINOpenSettingsInLINE((UIViewController *)self);
}
%end
%end

%group RUINFriendHomeEntry
%hook RUINFriendHomeController
- (void)viewDidAppear:(BOOL)animated
{
    %orig(animated);
    RUINAttachHomeSettingsButton(self);
}
%new(v24@0:8@16)
- (void)ruin_openSettings:(id)sender
{
    (void)sender;
    RUINOpenSettingsInLINE((UIViewController *)self);
}
%end
%end

%group RUINSettingsEntry
%hook RUINSettingsController
- (void)viewDidAppear:(BOOL)animated
{
    %orig(animated);
    RUINAttachSettingsEntry(self);
}
%new(v24@0:8@16)
- (void)ruin_openSettings:(id)sender
{
    (void)sender;
    RUINOpenSettingsInLINE((UIViewController *)self);
}
%end
%end

void RUINInstallNativeEntry(void) {
    if (nativeHookInstalled && homeHookInstalled && friendHomeHookInstalled) return;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    if (!RUINTargetMetadataMatchesInfo(info)) return;
    for (NSString *name in @[@"_TtC8LineHome18HomeViewController", @"_TtC11LineHomeTab23FriendTabViewController"]) {
        BOOL *hookInstalled = [name containsString:@"FriendTab"] ? &friendHomeHookInstalled : &homeHookInstalled;
        if (*hookInstalled) continue;
        Class home = objc_getClass(name.UTF8String);
        Method appearance = home ? class_getInstanceMethod(home, @selector(viewDidAppear:)) : NULL;
        const char *types = appearance ? method_getTypeEncoding(appearance) : NULL;
        if (types && !strcmp(types, "v20@0:8B16") &&
            !class_getInstanceMethod(home, sel_registerName("ruin_openSettings:"))) {
            if (hookInstalled == &friendHomeHookInstalled) {
                %init(RUINFriendHomeEntry, RUINFriendHomeController = home);
            } else {
                %init(RUINHomeEntry, RUINHomeController = home);
            }
            *hookInstalled = YES;
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
    if (class_getInstanceMethod(cls, sel_registerName("ruin_openSettings:"))) return;
    %init(RUINSettingsEntry, RUINSettingsController = cls);
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
             @"settingsTableSearches": @(atomic_load(&settingsTableSearches)),
             @"settingsTableReuse": @(atomic_load(&settingsTableReuse)),
             @"attachedRowCount": @(attachedRows)};
}
