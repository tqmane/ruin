#import "RUINSettings.h"
#import "Features.h"
#import "LocalUnreadBadges.h"
#import "LegacyHome.h"
#import "InterfaceFeatures.h"
#import "Localization.h"
#import "SecondaryLogin.h"
#import "Confirmations.h"
#import "MessageHistory.h"
#import "MenuExtras.h"
#import "AgeVerification.h"
#import "LocalNotifications.h"
#import "LocalFont.h"
#import "LocalFontUI.h"
#import "ChatPicker.h"
#import "NativeTabAvailability.h"
#import "MIDLookup.h"
#import "ThemeUI.h"
#import "ThemeShop.h"
#import "TargetMetadata.h"
#import "StartupProfiler.h"
#import "RuntimeInspector.h"
#import "ChatCatalog.h"

extern NSDictionary *RUINNativeEntryDiagnostics(void);

static UINavigationController *sSettingsNavigationController;
static BOOL sSettingsPresentationInFlight;
static BOOL sCompatibilityWarningScheduled;
static NSString *const RUINPartialWarningPresentedBuildsKey = @"RUINPartialCompatibilityWarningPresentedBuilds";

@interface RUINPreferenceSwitch : UISwitch
@property(nonatomic, copy) NSString *preferenceKey;
@end
@implementation RUINPreferenceSwitch
@end

static NSString *RUINSettingsInfoString(NSString *key) {
    id value = NSBundle.mainBundle.infoDictionary[key];
    return [value isKindOfClass:NSString.class] ? value : @"unknown";
}

static BOOL RUINSettingsHostIsFullySupported(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    return RUINFullySupportedTargetMatchesInfo(info);
}

static BOOL RUINShouldSuppressPartialCompatibilityWarning(void) {
    return [RUINSettingsInfoString(@"CFBundleShortVersionString") isEqualToString:@"26.17.0"] &&
        [RUINSettingsInfoString(@"CFBundleVersion") isEqualToString:@"2026.1103.1841"];
}

static NSString *RUINPartialCompatibilityMessage(void) {
    NSString *format = RUINLocalizedString(@"compatibility.partial.message");
    return [NSString stringWithFormat:format,
            RUINSettingsInfoString(@"CFBundleShortVersionString"), RUINSettingsInfoString(@"CFBundleVersion")];
}

typedef NS_ENUM(NSInteger, RUINSettingsSection) {
    RUINSettingsSectionVersion = 0,
    RUINSettingsSectionReadControls,
    RUINSettingsSectionConfirmations,
    RUINSettingsSectionAppearance,
    RUINSettingsSectionTabs,
    RUINSettingsSectionMedia,
    RUINSettingsSectionNotifications,
    RUINSettingsSectionShops,
    RUINSettingsSectionLineFeatures,
    RUINSettingsSectionSecondaryLogin,
    RUINSettingsSectionDiagnostics,
    RUINSettingsSectionLinks,
    RUINSettingsSectionCount,
};

@interface RUINSettingsViewController : UITableViewController <UIAdaptivePresentationControllerDelegate>
@property(nonatomic) BOOL compatible;
@property(nonatomic) BOOL fullySupported;
@property(nonatomic) NSInteger category; // -1 = root category list
- (instancetype)initWithCompatibility:(BOOL)compatible;
- (instancetype)initWithCategory:(NSInteger)category compatible:(BOOL)compatible;
- (void)closeSettings;
@end

@interface RUINDiagnosticsViewController : UIViewController
@property(nonatomic, strong) NSDictionary *document;
@property(nonatomic, copy) NSString *navigationTitle;
@end

static NSString *RUINStartupProfileStatusTitle(NSString *status) {
    if ([status isEqualToString:@"complete"]) return RUINLocalizedString(@"profiler.status_complete");
    if ([status isEqualToString:@"incomplete"]) return RUINLocalizedString(@"profiler.status_incomplete");
    if ([status isEqualToString:@"timeout"]) return RUINLocalizedString(@"profiler.status_timeout");
    if ([status isEqualToString:@"failed"]) return RUINLocalizedString(@"profiler.status_failed");
    return RUINLocalizedString(@"profiler.status_none");
}

static NSDictionary *Toggle(NSString *title, NSString *key, NSString *icon) { return @{@"title":title, @"key":key, @"icon":icon}; }
static UIImage *RUINSettingsIcon(NSString *name) {
    if (!name) return nil;
    UIImage *image = [UIImage imageNamed:name inBundle:RUINResourceBundleForImage(name) compatibleWithTraitCollection:nil];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
static NSArray<NSDictionary<NSString *, NSString *> *> *RUINCommunityLinks(void) {
    return @[
        @{@"title":@"GitHub", @"detail":@"tqmane", @"url":@"https://github.com/tqmane", @"icon":@"tabler-brand-github"},
        @{@"title":@"X", @"detail":@"@tamany00", @"url":@"https://x.com/tamany00", @"icon":@"tabler-brand-x"},
        @{@"title":@"Discord", @"detail":@"discord.gg/zJBrCaf6dz", @"url":@"https://discord.gg/zJBrCaf6dz", @"icon":@"tabler-brand-discord"}
    ];
}
static NSDictionary<NSString *, NSString *> *RUINTabIcons(void) {
    return @{@"home":@"tabler-home", @"talk":@"tabler-message-circle", @"shopping":@"tabler-shopping-bag",
        @"voom":@"tabler-video", @"wallet":@"tabler-wallet", @"news":@"tabler-news",
        @"call":@"tabler-phone", @"settings":@"tabler-settings", @"apps":@"tabler-apps"};
}
static NSDictionary<NSString *, NSString *> *RUINTabTitles(void) {
    return @{@"home":RUINLocalizedString(@"tabs.home"), @"talk":RUINLocalizedString(@"tabs.talk"), @"shopping":RUINLocalizedString(@"tabs.shopping"),
        @"voom":@"VOOM", @"wallet":RUINLocalizedString(@"tabs.wallet"), @"news":RUINLocalizedString(@"tabs.news"),
        @"call":RUINLocalizedString(@"tabs.call"), @"settings":RUINLocalizedString(@"tabs.settings"), @"apps":RUINLocalizedString(@"tabs.apps")};
}
static NSDictionary<NSString *, NSString *> *RUINTabHideKeys(void) {
    return @{@"shopping":RUINHideShoppingTabDefaultsKey,
        @"voom":RUINHideVOOMTabDefaultsKey, @"wallet":RUINHideWalletTabDefaultsKey,
        @"news":RUINHideNewsCallTabsDefaultsKey, @"call":RUINHideNewsCallTabsDefaultsKey,
        @"settings":RUINHideSettingsTabDefaultsKey, @"apps":RUINHideAppsTabDefaultsKey};
}
static NSArray<NSString *> *RUINNativeServicePair(void) {
    NSArray *tabs = RUINNativeTabIdentifiers();
    NSString *timeline = [tabs containsObject:@"shopping"] ? @"shopping" : [tabs containsObject:@"voom"] ? @"voom" : @"";
    NSString *more = [tabs containsObject:@"settings"] ? @"settings" : [tabs containsObject:@"wallet"] ? @"wallet" : [tabs containsObject:@"apps"] ? @"apps" : @"";
    return @[timeline,more];
}
static BOOL RUINCanHideNativeService(NSString *key) {
    return RUINNativeTabCanHideService(key);
}
static NSArray<NSDictionary *> *RUINNativeTabRows(void) {
    NSDictionary *keys = RUINTabHideKeys();
    NSDictionary *titles = RUINTabTitles();
    NSDictionary *icons = RUINTabIcons();
    NSMutableArray *rows = [NSMutableArray arrayWithObject:Toggle(RUINLocalizedString(@"settings.legacy_home"), RUINLegacyHomeEnabledDefaultsKey, @"tabler-home")];
    for (NSString *identifier in RUINNativeTabIdentifiers()) {
        NSString *key = keys[identifier], *title = titles[identifier];
        if (key && title) [rows addObject:Toggle([NSString stringWithFormat:RUINLocalizedString(@"settings.hide_tab"), title], key, icons[identifier] ?: @"tabler-eye-off")];
    }
    [rows addObject:Toggle(RUINLocalizedString(@"settings.fixed_startup_tab"), RUINStartupTabFixedDefaultsKey, @"tabler-pin")];
    return rows;
}
static NSArray<NSDictionary *> *ToggleRows(NSInteger section) {
    switch (section) {
        case RUINSettingsSectionReadControls: return @[Toggle(RUINLocalizedString(@"settings.hide_read"), RUINReadControlEnabledDefaultsKey, @"tabler-eye-off"), Toggle(RUINLocalizedString(@"settings.mark_read_on_reply"), RUINMarkReadOnReplyDefaultsKey, @"tabler-message-reply"), Toggle(RUINLocalizedString(@"settings.clear_viewed_unread_badges"), RUINClearViewedUnreadBadgesDefaultsKey, @"tabler-bell-off"), Toggle(RUINLocalizedString(@"settings.track_read_ranges"), RUINTrackReadUsersKey, @"tabler-eye")];
        case RUINSettingsSectionConfirmations: return @[Toggle(RUINLocalizedString(@"settings.confirm_group_send"), RUINConfirmSendEnabledDefaultsKey, @"tabler-send"), Toggle(RUINLocalizedString(@"settings.confirm_call"), RUINConfirmCallEnabledDefaultsKey, @"tabler-phone-call"), Toggle(RUINLocalizedString(@"settings.confirm_camera_on"), RUINConfirmCameraOnEnabledDefaultsKey, @"tabler-camera"), Toggle(RUINLocalizedString(@"settings.confirm_disconnect"), RUINConfirmDisconnectEnabledDefaultsKey, @"tabler-phone-off")];
        case RUINSettingsSectionAppearance: return @[Toggle(RUINLocalizedString(@"settings.hide_ads"), RUINHideAdsDefaultsKey, @"tabler-ad-off"), Toggle(RUINLocalizedString(@"settings.hide_recommendations"), RUINHideRecommendationsDefaultsKey, @"tabler-thumb-down"), Toggle(RUINLocalizedString(@"settings.hide_voice_input"), RUINHideVoiceInputDefaultsKey, @"tabler-microphone-off"), Toggle(RUINLocalizedString(@"settings.hide_agent_bar"), RUINHideAgentIBarDefaultsKey, @"tabler-robot-off"), Toggle(RUINLocalizedString(@"settings.fix_panel_height"), RUINFixPanelHeightDefaultsKey, @"tabler-sticker"), Toggle(RUINLocalizedString(@"settings.profile_avatar_left"), RUINProfileHeaderLeftDefaultsKey, @"tabler-users")];
        case RUINSettingsSectionTabs: return RUINNativeTabRows();
        case RUINSettingsSectionMedia: return @[Toggle(RUINLocalizedString(@"settings.keep_unsent_media"), RUINKeepUnsentMessagesKey, @"tabler-history"), Toggle(RUINLocalizedString(@"settings.copy_sticker_gif"), RUINCopyStickerGIFEnabledDefaultsKey, @"tabler-gif")];
        case RUINSettingsSectionNotifications: return @[Toggle(RUINLocalizedString(@"settings.local_notifications"), RUINLocalNotificationsEnabledDefaultsKey, @"tabler-bell")];
        case RUINSettingsSectionLineFeatures: return @[Toggle(RUINLocalizedString(@"settings.local_lyp"), RUINLocalLYPEnabledDefaultsKey, @"tabler-sparkles"), Toggle(RUINLocalizedString(@"settings.legacy_messaging"), RUINLegacyMessagingEnabledDefaultsKey, @"tabler-messages"), Toggle(RUINLocalizedString(@"settings.skip_age_verification"), RUINBypassAgeVerificationDefaultsKey, @"tabler-shield-check")];
        default: return @[];
    }
}
static NSArray<NSNumber *> *RUINSettingsRootCategories(BOOL compatible) {
    if (!compatible) return @[@(RUINSettingsSectionDiagnostics)];
    return @[@(RUINSettingsSectionReadControls), @(RUINSettingsSectionConfirmations), @(RUINSettingsSectionAppearance),
        @(RUINSettingsSectionTabs), @(RUINSettingsSectionMedia), @(RUINSettingsSectionNotifications),
        @(RUINSettingsSectionShops), @(RUINSettingsSectionLineFeatures), @(RUINSettingsSectionSecondaryLogin),
        @(RUINSettingsSectionDiagnostics), @(RUINSettingsSectionLinks)];
}
static NSString *RUINSettingsCategoryTitle(NSInteger category) {
    switch (category) {
        case RUINSettingsSectionVersion: return RUINLocalizedString(@"settings.version");
        case RUINSettingsSectionReadControls: return RUINLocalizedString(@"settings.read_controls");
        case RUINSettingsSectionConfirmations: return RUINLocalizedString(@"settings.confirmations");
        case RUINSettingsSectionAppearance: return RUINLocalizedString(@"settings.appearance");
        case RUINSettingsSectionTabs: return RUINLocalizedString(@"settings.tabs");
        case RUINSettingsSectionMedia: return RUINLocalizedString(@"settings.media");
        case RUINSettingsSectionNotifications: return RUINLocalizedString(@"settings.notifications");
        case RUINSettingsSectionShops: return RUINLocalizedString(@"settings.shops");
        case RUINSettingsSectionLineFeatures: return RUINLocalizedString(@"settings.line_features");
        case RUINSettingsSectionSecondaryLogin: return RUINLocalizedString(@"settings.secondary_login");
        case RUINSettingsSectionDiagnostics: return RUINLocalizedString(@"settings.diagnostics");
        case RUINSettingsSectionLinks: return RUINLocalizedString(@"settings.links");
        default: return RUINLocalizedString(@"settings.title");
    }
}
static NSString *RUINSettingsCategoryIcon(NSInteger category) {
    switch (category) {
        case RUINSettingsSectionReadControls: return @"tabler-eye-off";
        case RUINSettingsSectionConfirmations: return @"tabler-checks";
        case RUINSettingsSectionAppearance: return @"tabler-paint";
        case RUINSettingsSectionTabs: return @"tabler-layout-grid";
        case RUINSettingsSectionMedia: return @"tabler-photo";
        case RUINSettingsSectionNotifications: return @"tabler-bell";
        case RUINSettingsSectionShops: return @"tabler-shopping-bag";
        case RUINSettingsSectionLineFeatures: return @"tabler-sparkles";
        case RUINSettingsSectionSecondaryLogin: return @"tabler-device-tablet";
        case RUINSettingsSectionDiagnostics: return @"tabler-activity";
        case RUINSettingsSectionLinks: return @"tabler-link";
        default: return @"tabler-settings";
    }
}
static void RUINApplySystemNavigationBarAppearance(UIViewController *controller) {
    UITraitCollection *traits = controller.viewIfLoaded ? controller.viewIfLoaded.traitCollection : controller.traitCollection;
    UIColor *labelColor = [UIColor.labelColor resolvedColorWithTraitCollection:traits];
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithDefaultBackground];
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: labelColor};
    appearance.largeTitleTextAttributes = @{NSForegroundColorAttributeName: labelColor};
    controller.navigationItem.standardAppearance = appearance;
    controller.navigationItem.scrollEdgeAppearance = appearance;
    controller.navigationItem.compactAppearance = appearance;
}

@implementation RUINSettingsViewController
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    RUINApplySystemNavigationBarAppearance(self);
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tableView reloadData];
    RUINRefreshRuntimeReport();
}
- (instancetype)initWithCompatibility:(BOOL)compatible {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _compatible = compatible;
        _fullySupported = RUINSettingsHostIsFullySupported();
        _category = -1;
    }
    return self;
}
- (instancetype)initWithCategory:(NSInteger)category compatible:(BOOL)compatible {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _compatible = compatible;
        _fullySupported = RUINSettingsHostIsFullySupported();
        _category = category;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = self.category >= 0 ? RUINSettingsCategoryTitle(self.category) : RUINLocalizedString(@"settings.title");
    RUINApplySystemNavigationBarAppearance(self);
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(closeSettings)];
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 60;
}
- (void)closeSettings {
    sSettingsPresentationInFlight = YES;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{ sSettingsNavigationController = nil; sSettingsPresentationInFlight = NO; }];
}
- (void)presentationControllerDidDismiss:(__unused UIPresentationController *)controller {
    sSettingsNavigationController = nil; sSettingsPresentationInFlight = NO;
}
// Version section: banner, RUIN/LINE version, and, for an unverified build
// only, the partial-compatibility notice (suppressed for the verified target).
- (BOOL)showsPartialCompatibilityRow {
    return !self.fullySupported && !RUINShouldSuppressPartialCompatibilityWarning();
}
- (NSDictionary *)aliases {
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:RUINLocalNamesByIdentityDefaultsKey] ?: @{};
    NSMutableDictionary *visible = [NSMutableDictionary dictionary];
    for (id key in saved) if ([key isKindOfClass:NSString.class] && [saved[key] isKindOfClass:NSString.class] && [saved[key] length]) visible[key] = saved[key];
    return visible;
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    if (self.category >= 0) return 1;
    return self.compatible ? 2 : 1;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.category >= 0 || !self.compatible) return nil;
    return section == 0 ? RUINLocalizedString(@"settings.version") : nil;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.compatible) return RUINLocalizedString(@"compatibility.build_unsupported");
    if (self.category < 0) return nil;
    switch (self.category) {
        case RUINSettingsSectionReadControls: return [NSString stringWithFormat:@"%@\n%@\n%@", RUINLocalizedString(@"settings.read_controls_footer"), RUINLocalizedString(@"settings.clear_viewed_unread_badges_footer"), RUINLocalizedString(@"settings.chat_names_footer")];
        case RUINSettingsSectionConfirmations: return RUINLocalizedString(@"settings.confirmations_footer");
        case RUINSettingsSectionAppearance: return RUINLocalizedString(@"settings.appearance_footer");
        case RUINSettingsSectionTabs: {
            NSArray *pair = RUINNativeServicePair();
            NSString *dependency = [pair[0] length] && [pair[1] length] ?
                [NSString stringWithFormat:RUINLocalizedString(@"settings.tabs_hide_conflict"), RUINTabTitles()[pair[0]], RUINTabTitles()[pair[1]]] :
                RUINLocalizedString(@"settings.tabs_required");
            if ([RUINNativeTabAvailabilityDiagnostics()[@"menuOnlyScopeVerified"] boolValue]) dependency = @"";
            NSString *footer = [NSString stringWithFormat:RUINLocalizedString(@"settings.tabs_footer"),
                dependency.length ? [dependency stringByAppendingString:@"\n"] : @""];
            BOOL alternateEntryExpected = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ||
                [NSUserDefaults.standardUserDefaults boolForKey:RUINSecondaryLoginEnabledKey];
            if (alternateEntryExpected && ![RUINNativeEntryDiagnostics()[@"homeEntryAvailable"] boolValue])
                footer = [footer stringByAppendingFormat:@"\n%@", RUINLocalizedString(@"settings.tabs_entry_not_ready")];
            return [footer stringByAppendingFormat:@"\n%@", RUINLocalizedString(@"settings.legacy_home_footer")];
        }
        case RUINSettingsSectionMedia: return RUINLocalizedString(@"media.history_footer");
        case RUINSettingsSectionSecondaryLogin: return RUINLocalizedString(@"settings.secondary_login_footer");
        case RUINSettingsSectionDiagnostics: return [NSString stringWithFormat:@"%@\n%@", RUINLocalizedString(@"settings.diagnostics_footer"), RUINLocalizedString(@"settings.startup_profile_footer")];
        case RUINSettingsSectionNotifications: return RUINLocalizedString(@"settings.notifications_footer");
        case RUINSettingsSectionLineFeatures: return RUINLocalizedString(@"settings.line_features_footer");
        default: return nil;
    }
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.category < 0) {
        if (!self.compatible) return RUINSettingsRootCategories(NO).count;
        if (section == 0) return self.showsPartialCompatibilityRow ? 3 : 2;
        return RUINSettingsRootCategories(YES).count + 1;
    }
    if (!self.compatible) return 1;
    NSInteger category = self.category;
    if (category == RUINSettingsSectionLinks) return RUINCommunityLinks().count;
    if (category == RUINSettingsSectionReadControls) return ToggleRows(category).count + 2;
    if (category == RUINSettingsSectionConfirmations || category == RUINSettingsSectionTabs) return ToggleRows(category).count + 1;
    if (category == RUINSettingsSectionShops) return 2;
    if (category == RUINSettingsSectionDiagnostics) return 9;
    if (category == RUINSettingsSectionLineFeatures) return ToggleRows(RUINSettingsSectionLineFeatures).count + 2;
    return MAX((NSInteger)1, (NSInteger)ToggleRows(category).count);
}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    if (self.category < 0 && self.compatible && path.section == 0 && path.row == 0) {
        CGFloat width = CGRectGetWidth(tableView.bounds);
        // Before the first layout pass the table can report a zero width.
        if (width <= 32) return 140;
        return ceil((width - 32) * 496.0 / 1170.0);
    }
    return UITableViewAutomaticDimension;
}
- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 2;
    NSInteger section = self.category >= 0 ? self.category : (self.compatible && path.section == 0 ? RUINSettingsSectionVersion : -1);
    NSArray *rows = ToggleRows(section);
    NSString *settingsIcon = nil;
    UIColor *settingsIconTint = UIColor.systemBlueColor;
    if (section == -1) {
        NSArray *categories = RUINSettingsRootCategories(self.compatible);
        if (self.compatible && path.row == (NSInteger)categories.count) {
            cell.textLabel.text = RUINLocalizedString(@"setup.open");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.imageView.image = RUINSettingsIcon(@"tabler-sparkles");
            cell.imageView.tintColor = UIColor.systemBlueColor;
            return cell;
        }
        NSInteger category = [categories[path.row] integerValue];
        cell.textLabel.text = RUINSettingsCategoryTitle(category);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.imageView.image = RUINSettingsIcon(RUINSettingsCategoryIcon(category));
        cell.imageView.tintColor = UIColor.systemBlueColor;
        return cell;
    }
    if (self.compatible && section == RUINSettingsSectionLinks) {
        NSDictionary *link = RUINCommunityLinks()[path.row];
        cell.textLabel.text = link[@"title"];
        cell.detailTextLabel.text = link[@"detail"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        settingsIcon = link[@"icon"];
    } else if (!self.compatible || (section == RUINSettingsSectionDiagnostics && path.row < 2)) {
        cell.textLabel.text = path.row == 0 ? RUINLocalizedString(@"diagnostics.runtime_title") : RUINLocalizedString(@"diagnostics.feature_matrix");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        settingsIcon = path.row == 0 ? @"tabler-activity" : @"tabler-list-check";
    } else if (section == RUINSettingsSectionDiagnostics) {
        NSDictionary *summary = RUINStartupProfileSummary();
        BOOL hasLog = [summary[@"hasLog"] boolValue];
        NSInteger profilerRow = path.row - 2;
        if (profilerRow == 0) {
            cell.textLabel.text = RUINLocalizedString(@"profiler.record_next_launch");
            RUINPreferenceSwitch *toggle = [RUINPreferenceSwitch new];
            toggle.preferenceKey = RUINStartupProfileRecordNextLaunchDefaultsKey;
            toggle.on = [summary[@"armed"] boolValue];
            toggle.accessibilityLabel = cell.textLabel.text;
            [toggle addTarget:self action:@selector(profilerPreferenceChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
            settingsIcon = @"tabler-gauge";
        } else if (profilerRow == 1) {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            if ([summary[@"armed"] boolValue]) {
                cell.textLabel.text = RUINLocalizedString(@"profiler.status_none");
                cell.detailTextLabel.text = RUINLocalizedString(@"profiler.armed");
            } else if (hasLog) {
                NSString *statusTitle = RUINStartupProfileStatusTitle(summary[@"status"]);
                cell.textLabel.text = statusTitle;
                cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"profiler.status_summary"),
                    statusTitle, (unsigned long)[summary[@"eventCount"] unsignedIntegerValue],
                    [summary[@"totalMs"] doubleValue]];
            } else {
                cell.textLabel.text = RUINLocalizedString(@"profiler.status_none");
                cell.detailTextLabel.text = RUINLocalizedString(@"profiler.no_log");
            }
            settingsIcon = @"tabler-info-circle";
        } else if (profilerRow == 2) {
            cell.textLabel.text = RUINLocalizedString(@"profiler.view_log");
            cell.textLabel.textColor = hasLog ? UIColor.labelColor : UIColor.secondaryLabelColor;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            settingsIcon = @"tabler-file-text";
        } else if (profilerRow == 3) {
            cell.textLabel.text = RUINLocalizedString(@"profiler.export_json");
            cell.textLabel.textColor = hasLog ? UIColor.labelColor : UIColor.secondaryLabelColor;
            settingsIcon = @"tabler-share";
        } else if (profilerRow == 4) {
            cell.textLabel.text = RUINLocalizedString(@"profiler.delete_log");
            cell.textLabel.textColor = hasLog ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
            settingsIcon = @"tabler-trash";
            settingsIconTint = UIColor.systemRedColor;
        } else if (profilerRow == 5) {
            cell.textLabel.text = RUINLocalizedString(@"diagnostics.show_extract_button");
            RUINPreferenceSwitch *toggle = [RUINPreferenceSwitch new];
            toggle.preferenceKey = RUINUIExtractButtonEnabledDefaultsKey;
            toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:RUINUIExtractButtonEnabledDefaultsKey];
            toggle.accessibilityLabel = cell.textLabel.text;
            [toggle addTarget:self action:@selector(preferenceChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
            settingsIcon = @"tabler-eye";
        } else {
            cell.textLabel.text = RUINLocalizedString(@"diagnostics.ui_extract");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            settingsIcon = @"tabler-file-text";
        }
    } else if (section == RUINSettingsSectionLineFeatures && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionLineFeatures).count) {
        cell.textLabel.text = RUINLocalizedString(@"font.title");
        cell.detailTextLabel.text = RUINLocalFontName() ?: RUINLocalizedString(@"font.default");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        settingsIcon = @"tabler-typography";
    } else if (section == RUINSettingsSectionLineFeatures && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionLineFeatures).count + 1) {
        cell.textLabel.text = RUINLocalizedString(@"profile.open_by_mid");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        settingsIcon = @"tabler-user-search";
    } else if (section == RUINSettingsSectionShops) {
        cell.textLabel.text = path.row == 0 ? RUINLocalizedString(@"themes.downloads_title") : RUINLocalizedString(@"shops.sticker_title");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        settingsIcon = path.row == 0 ? @"tabler-palette" : @"tabler-sticker";
    } else if (section == RUINSettingsSectionVersion && path.row == 0 && self.category < 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = UIColor.clearColor;
        UIImageView *banner = [[UIImageView alloc] initWithImage:
            [UIImage imageNamed:@"version-banner" inBundle:RUINResourceBundleForImage(@"version-banner") compatibleWithTraitCollection:nil]];
        banner.contentMode = UIViewContentModeScaleAspectFill;
        banner.clipsToBounds = YES;
        banner.layer.cornerRadius = 12;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:banner];
        [NSLayoutConstraint activateConstraints:@[
            [banner.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
            [banner.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor],
            [banner.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
            [banner.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
        ]];
    } else if (section == RUINSettingsSectionVersion && path.row == 2 && self.showsPartialCompatibilityRow) {
        cell.textLabel.text = RUINLocalizedString(@"compatibility.partial.title");
        cell.detailTextLabel.text = RUINPartialCompatibilityMessage();
        cell.textLabel.textColor = UIColor.systemOrangeColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        settingsIcon = @"tabler-info-circle";
        settingsIconTint = UIColor.systemOrangeColor;
    } else if (section == RUINSettingsSectionVersion) {
        cell.textLabel.text = [NSString stringWithFormat:@"RUIN v%@", RUINVersion];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"LINE %@ / %@", RUINSettingsInfoString(@"CFBundleShortVersionString"), RUINSettingsInfoString(@"CFBundleVersion")];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        settingsIcon = @"tabler-info-circle";
    } else if (section == RUINSettingsSectionSecondaryLogin) {
        BOOL on = [RUINSecondaryLoginDiagnostics()[@"activeTabletRole"] boolValue];
        cell.textLabel.text = on ? RUINLocalizedString(@"login.secondary_mode") : RUINLocalizedString(@"login.primary_mode");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        settingsIcon = @"tabler-device-tablet";
    } else if ((NSUInteger)path.row < rows.count) {
        NSDictionary *row = rows[path.row]; NSString *key = row[@"key"];
        cell.textLabel.text = row[@"title"];
        settingsIcon = row[@"icon"];
        RUINPreferenceSwitch *toggle = [RUINPreferenceSwitch new];
        toggle.preferenceKey = key;
        toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:key];
        toggle.accessibilityLabel = row[@"title"];
        if (section == RUINSettingsSectionTabs) toggle.enabled = toggle.on ||
            ([key isEqual:RUINLegacyHomeEnabledDefaultsKey] ? RUINLegacyHomeAvailable() : RUINCanHideNativeService(key));
        if ([key isEqual:RUINHideSettingsTabDefaultsKey]) toggle.enabled = toggle.on ||
            (toggle.enabled && [RUINNativeEntryDiagnostics()[@"homeEntryAvailable"] boolValue]);
        cell.textLabel.textColor = toggle.enabled ? UIColor.labelColor : UIColor.secondaryLabelColor;
        [toggle addTarget:self action:@selector(preferenceChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        if (section == RUINSettingsSectionReadControls && (NSUInteger)path.row == rows.count) { cell.textLabel.text = RUINLocalizedString(@"settings.read_exceptions"); cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"common.item_count"), (unsigned long)[NSUserDefaults.standardUserDefaults arrayForKey:RUINReadExceptionsDefaultsKey].count]; settingsIcon = @"tabler-list-check"; }
        if (section == RUINSettingsSectionReadControls && (NSUInteger)path.row == rows.count + 1) { cell.textLabel.text = RUINLocalizedString(@"names.choose_chat"); cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"names.modified_chat_count"), (unsigned long)self.aliases.count]; settingsIcon = @"tabler-edit"; }
        if (section == RUINSettingsSectionConfirmations) { cell.textLabel.text = RUINLocalizedString(@"settings.minimum_group_members"); cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"common.member_count"), (long)[NSUserDefaults.standardUserDefaults integerForKey:RUINConfirmSendMinimumGroupMemberCountDefaultsKey]]; settingsIcon = @"tabler-users"; }
        if (section == RUINSettingsSectionTabs) {
            cell.textLabel.text = RUINLocalizedString(@"settings.startup_tab");
            NSString *identifier = [NSUserDefaults.standardUserDefaults stringForKey:RUINStartupTabDefaultsKey];
            cell.detailTextLabel.text = RUINTabTitles()[identifier ?: @""] ?: RUINLocalizedString(@"common.not_set");
            settingsIcon = @"tabler-list";
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    if (settingsIcon) {
        cell.imageView.image = RUINSettingsIcon(settingsIcon);
        cell.imageView.tintColor = settingsIconTint;
    }
    return cell;
}
- (void)preferenceChanged:(RUINPreferenceSwitch *)toggle {
    NSString *key = toggle.preferenceKey;
    if (!key) return;
    [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:key]; RUINRefreshSettingsFeature(key);
    if ([RUINTabHideKeys().allValues containsObject:key])
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)profilerPreferenceChanged:(RUINPreferenceSwitch *)toggle {
    if (![toggle.preferenceKey isEqual:RUINStartupProfileRecordNextLaunchDefaultsKey]) return;
    [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:RUINStartupProfileRecordNextLaunchDefaultsKey];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)showStartupProfileLog {
    NSDictionary *log = RUINStartupProfileLoadSavedLog();
    if (!log) { [self showMessage:RUINLocalizedString(@"profiler.no_log")]; return; }
    RUINDiagnosticsViewController *viewer = [RUINDiagnosticsViewController new];
    viewer.document = log;
    viewer.navigationTitle = RUINLocalizedString(@"profiler.view_log");
    [self.navigationController pushViewController:viewer animated:YES];
}
- (void)exportStartupProfileLog {
    NSURL *url = RUINStartupProfileSavedLogURL();
    if (!url) { [self showMessage:RUINLocalizedString(@"profiler.no_log")]; return; }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    if (share.popoverPresentationController) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:5 inSection:0]];
        share.popoverPresentationController.sourceView = cell ?: self.view;
        share.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }
    [self presentViewController:share animated:YES completion:nil];
}
- (void)confirmDeleteStartupProfileLog {
    if (!RUINStartupProfileSavedLogURL()) { [self showMessage:RUINLocalizedString(@"profiler.no_log")]; return; }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"profiler.delete_log")
        message:RUINLocalizedString(@"profiler.delete_log_message") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weak = self;
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"profiler.delete_log") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        RUINStartupProfileDeleteSavedLog();
        [weak.tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"RUIN" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.confirm") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)runUIExtractionAndShare {
    RUINRunUIExtraction();
    NSDictionary *result = RUINComposerInspectionResult();
    NSData *json = result ? [NSJSONSerialization dataWithJSONObject:result
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL] : nil;
    NSURL *url = json ? [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:@"RUIN-ui-extraction.json"]] : nil;
    if (!url || ![json writeToURL:url options:NSDataWritingAtomic error:NULL]) {
        RUINDiagnosticsViewController *viewer = [RUINDiagnosticsViewController new];
        viewer.document = result;
        viewer.navigationTitle = RUINLocalizedString(@"diagnostics.ui_extract");
        [self.navigationController pushViewController:viewer animated:YES];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.completionWithItemsHandler = ^(__unused UIActivityType activityType, __unused BOOL completed,
                                         __unused NSArray *returnedItems, __unused NSError *activityError) {
        [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
    };
    if (share.popoverPresentationController) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:8 inSection:0]];
        share.popoverPresentationController.sourceView = cell ?: self.view;
        share.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }
    [self presentViewController:share animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    NSInteger section = self.category >= 0 ? self.category : (self.compatible && path.section == 0 ? RUINSettingsSectionVersion : -1);
    if (section == -1) {
        NSArray *categories = RUINSettingsRootCategories(self.compatible);
        if (self.compatible && path.row == (NSInteger)categories.count) { RUINPresentSetup(self); return; }
        NSInteger category = [categories[path.row] integerValue];
        RUINSettingsViewController *detail = [[RUINSettingsViewController alloc] initWithCategory:category compatible:self.compatible];
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }
    if (self.compatible && section == RUINSettingsSectionLinks) {
        NSURL *URL = [NSURL URLWithString:RUINCommunityLinks()[path.row][@"url"]];
        [UIApplication.sharedApplication openURL:URL options:@{} completionHandler:nil];
    } else if (!self.compatible || (section == RUINSettingsSectionDiagnostics && path.row < 2)) {
        RUINDiagnosticsViewController *viewer = [RUINDiagnosticsViewController new];
        if (path.row == 1) {
            viewer.document = RUINFeatureDiagnostics();
            viewer.navigationTitle = RUINLocalizedString(@"diagnostics.feature_matrix");
        } else {
            viewer.navigationTitle = RUINLocalizedString(@"diagnostics.runtime_title");
        }
        [self.navigationController pushViewController:viewer animated:YES];
    } else if (section == RUINSettingsSectionDiagnostics) {
        if (path.row == 4) [self showStartupProfileLog];
        else if (path.row == 5) [self exportStartupProfileLog];
        else if (path.row == 6) [self confirmDeleteStartupProfileLog];
        else if (path.row == 8) [self runUIExtractionAndShare];
    } else if (section == RUINSettingsSectionLineFeatures && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionLineFeatures).count) {
        RUINOpenLocalFontSettings(self);
    } else if (section == RUINSettingsSectionLineFeatures && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionLineFeatures).count + 1) {
        RUINOpenMIDLookup(self);
    } else if (section == RUINSettingsSectionShops) {
        if (path.row == 0) RUINOpenThemeSettings(self);
        else RUINOpenStickerShop(self);
    } else if (section == RUINSettingsSectionReadControls && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionReadControls).count + 1) {
        __weak typeof(self) weak = self;
        RUINOpenLocalNamePicker(self, ^{ RUINRefreshSettingsFeature(RUINLocalNamesByIdentityDefaultsKey); [weak.tableView reloadData]; });
    } else if (section == RUINSettingsSectionReadControls && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionReadControls).count) [self editReadExceptions];
    else if (section == RUINSettingsSectionConfirmations && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionConfirmations).count) [self editThreshold];
    else if (section == RUINSettingsSectionTabs && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionTabs).count) [self editStartupTab];
}
- (void)editThreshold {
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"settings.minimum_group_members") message:RUINLocalizedString(@"confirm.minimum_members_hint") preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) { field.keyboardType = UIKeyboardTypeNumberPad; field.text = [NSString stringWithFormat:@"%ld", (long)[NSUserDefaults.standardUserDefaults integerForKey:RUINConfirmSendMinimumGroupMemberCountDefaultsKey]]; }];
    __weak typeof(self) owner = self; __weak UIAlertController *weakPrompt = prompt;
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.save") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *text = weakPrompt.textFields.firstObject.text ?: @"";
        if (!text.length || [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound || text.length > 6) { dispatch_async(dispatch_get_main_queue(), ^{ [owner showMessage:RUINLocalizedString(@"confirm.invalid_member_count")]; }); return; }
        [NSUserDefaults.standardUserDefaults setInteger:text.integerValue forKey:RUINConfirmSendMinimumGroupMemberCountDefaultsKey]; RUINRefreshSettingsFeature(RUINConfirmSendMinimumGroupMemberCountDefaultsKey); [owner.tableView reloadData];
    }]];
    [self presentViewController:prompt animated:YES completion:nil];
}
- (void)editReadExceptions {
    __weak typeof(self) weak = self;
    RUINOpenReadExceptionPicker(self, ^{ RUINRefreshSettingsFeature(RUINReadExceptionsDefaultsKey); [weak.tableView reloadData]; });
}
- (void)editStartupTab {
    NSArray *available = RUINAvailableTabs();
    if (!available.count) { [self showMessage:RUINLocalizedString(@"settings.tabs_not_ready")]; return; }
    NSDictionary *titles = RUINTabTitles();
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"settings.startup_tab") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) owner = self;
    for (NSString *identifier in available) [menu addAction:[UIAlertAction actionWithTitle:titles[identifier] ?: identifier style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [NSUserDefaults.standardUserDefaults setObject:identifier forKey:RUINStartupTabDefaultsKey]; RUINRefreshSettingsFeature(RUINStartupTabDefaultsKey); [owner.tableView reloadData]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.cancel") style:UIAlertActionStyleCancel handler:nil]];
    if (menu.popoverPresentationController) { menu.popoverPresentationController.sourceView = self.view; menu.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1); }
    [self presentViewController:menu animated:YES completion:nil];
}
@end

@interface RUINDiagnosticsViewController ()
@property(nonatomic, copy) NSString *reportText;
@end

@implementation RUINDiagnosticsViewController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    RUINApplySystemNavigationBarAppearance(self);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.navigationTitle.length ? self.navigationTitle
        : (self.title.length ? self.title : RUINLocalizedString(@"settings.diagnostics"));
    RUINApplySystemNavigationBarAppearance(self);
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *textView = [UITextView new];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.selectable = YES;
    textView.alwaysBounceVertical = YES;
    textView.backgroundColor = UIColor.clearColor;
    textView.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    textView.accessibilityLabel = RUINLocalizedString(@"diagnostics.export_description");
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:(self.document ?: RUINRuntimeDiagnostics())
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&error];
    self.reportText = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]
                           : [NSString stringWithFormat:RUINLocalizedString(@"diagnostics.json_failed"), error.localizedDescription ?: RUINLocalizedString(@"errors.unknown")];
    textView.text = self.reportText;
    if (json && self.reportText.length) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                 target:self
                                 action:@selector(shareDiagnostics:)];
    }
    [self.view addSubview:textView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [textView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8.0],
        [textView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0]
    ]];
}

- (void)shareDiagnostics:(UIBarButtonItem *)sender {
    if (!self.reportText.length) return;
    UIActivityViewController *activity = [[UIActivityViewController alloc]
        initWithActivityItems:@[self.reportText]
        applicationActivities:nil];
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.barButtonItem = sender;
    }
    [self presentViewController:activity animated:YES completion:nil];
}

@end

static UIWindow *RUINForegroundKeyWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && !window.hidden) return window;
        }
    }
    id<UIApplicationDelegate> delegate = application.delegate;
    if ([delegate respondsToSelector:@selector(window)]) {
        UIWindow *window = delegate.window;
        if (window.isKeyWindow && !window.hidden) return window;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in application.windows) {
        if (window.isKeyWindow && !window.hidden) return window;
    }
#pragma clang diagnostic pop
    return nil;
}

static UIWindow *RUINVisibleSourceWindow(UIViewController *owner) {
    UIView *ownerView = owner.viewIfLoaded;
    UIWindow *window = ownerView.window;
    UIWindowScene *scene = window.windowScene;
    if (!ownerView || !window || window.hidden || window.alpha <= 0.0 ||
        !scene || scene.activationState != UISceneActivationStateForegroundActive) return nil;

    UIView *view = ownerView;
    for (; view && view != window; view = view.superview)
        if (view.hidden || view.alpha <= 0.0) return nil;
    if (view != window) return nil;

    for (UIViewController *controller = owner; controller; controller = controller.parentViewController) {
        if (controller.isBeingDismissed) return nil;
        UIViewController *presented = controller.presentedViewController;
        if (presented && !presented.isBeingDismissed) return nil;
    }
    return window;
}

static BOOL RUINOwnerIsVisibleInNavigationController(UIViewController *owner,
                                                       UINavigationController *navigation,
                                                       UIWindow *window) {
    if (!navigation || navigation.isBeingDismissed || navigation.viewIfLoaded.window != window) return NO;
    for (UIViewController *controller = owner; controller; controller = controller.parentViewController)
        if (controller == navigation.topViewController) return YES;
    return NO;
}

static BOOL RUINPresentSettingsFromController(UIViewController *presenter, BOOL compatible) {
    if (sSettingsPresentationInFlight || sSettingsNavigationController.presentingViewController) return YES;
    if (!presenter || presenter.isBeingDismissed) return NO;

    RUINSettingsViewController *root = [[RUINSettingsViewController alloc] initWithCompatibility:compatible];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:root];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.navigationBar.prefersLargeTitles = YES;
    navigation.presentationController.delegate = root;
    sSettingsNavigationController = navigation;
    sSettingsPresentationInFlight = YES;
    [presenter presentViewController:navigation animated:YES completion:^{ sSettingsPresentationInFlight = NO; }];
    return YES;
}

void RUINOpenSettingsInLINE(UIViewController *owner) {
    if (!RUINIsCompatible() || !owner) return;
    UIWindow *window = RUINVisibleSourceWindow(owner);
    if (!window) return;

    UINavigationController *navigation = owner.navigationController;
    if (RUINOwnerIsVisibleInNavigationController(owner, navigation, window)) {
        RUINSettingsViewController *settings = [[RUINSettingsViewController alloc] initWithCompatibility:YES];
        settings.hidesBottomBarWhenPushed = YES;
        [navigation pushViewController:settings animated:YES];
        return;
    }
    RUINPresentSettingsFromController(owner, YES);
}

BOOL RUINPresentSettings(void) {
    UIWindow *window = RUINForegroundKeyWindow();
    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed)
        presenter = presenter.presentedViewController;
    return RUINPresentSettingsFromController(presenter, RUINIsCompatible());
}

static UIViewController *RUINVisibleContainedController(UIViewController *controller, UIWindow *window) {
    while (controller) {
        if ([controller isKindOfClass:UINavigationController.class]) {
            controller = ((UINavigationController *)controller).visibleViewController;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            controller = ((UITabBarController *)controller).selectedViewController;
        } else if ([controller isKindOfClass:UISplitViewController.class]) {
            UISplitViewController *split = (UISplitViewController *)controller;
            controller = nil;
            for (UIViewController *candidate in split.viewControllers.reverseObjectEnumerator)
                if (candidate.viewIfLoaded.window == window) { controller = candidate; break; }
        } else {
            return controller;
        }
    }
    return nil;
}

static UIViewController *RUINCompatibilityWarningPresenter(void) {
    UIWindow *window = RUINForegroundKeyWindow();
    if (!window || window.hidden || !window.windowScene ||
        window.windowScene.activationState != UISceneActivationStateForegroundActive) return nil;

    UIViewController *root = window.rootViewController;
    UIViewController *visible = RUINVisibleContainedController(root, window);
    if (!visible || visible.viewIfLoaded.window != window) return nil;
    for (UIViewController *controller = visible; controller; controller = controller.parentViewController) {
        if (controller.isBeingPresented || controller.isBeingDismissed || controller.transitionCoordinator ||
            controller.presentedViewController) return nil;
        if ([controller isKindOfClass:RUINSettingsViewController.class]) return nil;
        if ([NSStringFromClass(controller.class) rangeOfString:@"login" options:NSCaseInsensitiveSearch].location != NSNotFound)
            return nil;
    }
    return visible;
}

static NSString *RUINPartialWarningBuildIdentifier(void) {
    return [NSString stringWithFormat:@"%@/%@", RUINSettingsInfoString(@"CFBundleShortVersionString"),
            RUINSettingsInfoString(@"CFBundleVersion")];
}

static BOOL RUINPartialWarningWasPresented(NSString *buildIdentifier) {
    return [[NSUserDefaults.standardUserDefaults arrayForKey:RUINPartialWarningPresentedBuildsKey]
        containsObject:buildIdentifier];
}

static void RUINRecordPartialWarningPresented(NSString *buildIdentifier) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *presented = [[defaults arrayForKey:RUINPartialWarningPresentedBuildsKey] mutableCopy];
    if (!presented) presented = [NSMutableArray array];
    if (![presented containsObject:buildIdentifier]) [presented addObject:buildIdentifier];
    [defaults setObject:presented forKey:RUINPartialWarningPresentedBuildsKey];
}

BOOL RUINMaybeShowCompatibilityWarning(void) {
    if (RUINShouldSuppressPartialCompatibilityWarning() || !RUINIsCompatible() || RUINSettingsHostIsFullySupported() ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;

    NSString *buildIdentifier = RUINPartialWarningBuildIdentifier();
    if (RUINPartialWarningWasPresented(buildIdentifier)) return NO;
    if (sCompatibilityWarningScheduled) return YES;

    sCompatibilityWarningScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        sCompatibilityWarningScheduled = NO;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
            RUINShouldSuppressPartialCompatibilityWarning() || !RUINIsCompatible() || RUINSettingsHostIsFullySupported()) return;

        NSString *currentBuildIdentifier = RUINPartialWarningBuildIdentifier();
        if (RUINPartialWarningWasPresented(currentBuildIdentifier)) return;
        UIViewController *presenter = RUINCompatibilityWarningPresenter();
        if (!presenter) return;

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"compatibility.partial.title")
                                                                       message:RUINPartialCompatibilityMessage()
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"compatibility.partial.continue")
                                                  style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:^{
            if (alert.presentingViewController && alert.viewIfLoaded.window)
                RUINRecordPartialWarningPresented(currentBuildIdentifier);
        }];
    });
    return YES;
}

// MARK: - First-run setup

static NSString *const RUINSetupCompletedDefaultsKey = @"RUINSetupCompleted";
static BOOL sSetupPresentationInFlight;

@interface RUINSetupViewController : UIViewController
@property(nonatomic, copy) NSArray<NSDictionary *> *setupRows;
@property(nonatomic) BOOL allowsSecondaryLoginToggle;
- (instancetype)initWithSecondaryLoginAllowed:(BOOL)allowed;
@end

@implementation RUINSetupViewController
- (instancetype)init {
    return [self initWithSecondaryLoginAllowed:YES];
}
- (instancetype)initWithSecondaryLoginAllowed:(BOOL)allowed {
    self = [super init];
    if (self) {
        _allowsSecondaryLoginToggle = allowed;
        NSString *secondaryDesc = allowed
            ? RUINLocalizedString(@"setup.desc_secondary")
            : [NSString stringWithFormat:@"%@\n%@", RUINLocalizedString(@"setup.desc_secondary"), RUINLocalizedString(@"setup.secondary_locked")];
        _setupRows = @[
            @{@"title": RUINLocalizedString(@"login.secondary_action"), @"key": RUINSecondaryLoginEnabledKey, @"icon": @"tabler-device-tablet", @"desc": secondaryDesc, @"enabled": @(allowed)},
            @{@"title": RUINLocalizedString(@"settings.hide_read"), @"key": RUINReadControlEnabledDefaultsKey, @"icon": @"tabler-eye-off", @"desc": RUINLocalizedString(@"setup.desc_read"), @"enabled": @YES},
            @{@"title": RUINLocalizedString(@"settings.confirm_group_send"), @"key": RUINConfirmSendEnabledDefaultsKey, @"icon": @"tabler-send", @"desc": RUINLocalizedString(@"setup.desc_confirm"), @"enabled": @YES},
            @{@"title": RUINLocalizedString(@"settings.hide_ads"), @"key": RUINHideAdsDefaultsKey, @"icon": @"tabler-ad-off", @"desc": RUINLocalizedString(@"setup.desc_ads"), @"enabled": @YES},
            @{@"title": RUINLocalizedString(@"settings.fix_panel_height"), @"key": RUINFixPanelHeightDefaultsKey, @"icon": @"tabler-sticker", @"desc": RUINLocalizedString(@"setup.desc_panel"), @"enabled": @YES},
        ];
    }
    return self;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    RUINApplySystemNavigationBarAppearance(self);
}
- (void)viewDidLoad {
    [super viewDidLoad];
    RUINApplySystemNavigationBarAppearance(self);
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:28],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32],
    ]];


    UILabel *title = [UILabel new];
    title.text = RUINLocalizedString(@"setup.title");
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    [stack addArrangedSubview:title];
    UILabel *message = [UILabel new];
    message.text = RUINLocalizedString(@"setup.message");
    message.font = [UIFont systemFontOfSize:15];
    message.textColor = UIColor.secondaryLabelColor;
    message.numberOfLines = 0;
    [stack addArrangedSubview:message];
    [stack setCustomSpacing:24 afterView:message];

    for (NSDictionary *row in self.setupRows) [stack addArrangedSubview:[self setupCardForRow:row]];
    [stack setCustomSpacing:24 afterView:stack.arrangedSubviews.lastObject];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:RUINLocalizedString(@"setup.done") forState:UIControlStateNormal];
    [done setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    done.backgroundColor = UIColor.systemBlueColor;
    done.layer.cornerRadius = 12;
    [done addTarget:self action:@selector(setupDone) forControlEvents:UIControlEventTouchUpInside];
    [done.heightAnchor constraintEqualToConstant:54].active = YES;
    [stack addArrangedSubview:done];
}
- (UIView *)setupCardForRow:(NSDictionary *)row {
    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 16;

    UIImageView *tile = [[UIImageView alloc] initWithImage:RUINSettingsIcon(row[@"icon"])];
    tile.tintColor = UIColor.systemBlueColor;
    tile.contentMode = UIViewContentModeScaleAspectFit;
    tile.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *title = [UILabel new];
    title.text = row[@"title"];
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    title.numberOfLines = 0;
    UILabel *desc = [UILabel new];
    desc.text = row[@"desc"];
    desc.font = [UIFont systemFontOfSize:13];
    desc.textColor = UIColor.secondaryLabelColor;
    desc.numberOfLines = 0;
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[title, desc]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    texts.translatesAutoresizingMaskIntoConstraints = NO;

    RUINPreferenceSwitch *toggle = [RUINPreferenceSwitch new];
    toggle.preferenceKey = row[@"key"];
    toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:row[@"key"]];
    toggle.accessibilityLabel = row[@"title"];
    BOOL enabled = row[@"enabled"] ? [row[@"enabled"] boolValue] : YES;
    toggle.enabled = enabled;
    if (!enabled) {
        title.textColor = UIColor.secondaryLabelColor;
        tile.tintColor = UIColor.tertiaryLabelColor;
        card.alpha = 0.72;
    }
    [toggle addTarget:self action:@selector(setupPreferenceChanged:) forControlEvents:UIControlEventValueChanged];
    toggle.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:tile];
    [card addSubview:texts];
    [card addSubview:toggle];
    [NSLayoutConstraint activateConstraints:@[
        [tile.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [tile.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [tile.widthAnchor constraintEqualToConstant:26],
        [tile.heightAnchor constraintEqualToConstant:26],
        [texts.leadingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:12],
        [texts.trailingAnchor constraintEqualToAnchor:toggle.leadingAnchor constant:-12],
        [texts.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [texts.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [toggle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [toggle.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
    ]];
    return card;
}
- (void)setupDone {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:RUINSetupCompletedDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)setupPreferenceChanged:(RUINPreferenceSwitch *)toggle {
    if (!toggle.preferenceKey) return;
    if ([toggle.preferenceKey isEqual:RUINSecondaryLoginEnabledKey] && !self.allowsSecondaryLoginToggle) {
        toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:RUINSecondaryLoginEnabledKey];
        return;
    }
    [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:toggle.preferenceKey];
    RUINRefreshSettingsFeature(toggle.preferenceKey);
}
@end

void RUINPresentSetup(UIViewController *presenter) {
    if (!presenter || sSetupPresentationInFlight) return;
    if (presenter.presentedViewController) return;
    sSetupPresentationInFlight = YES;
    BOOL allowSecondary = ![presenter isKindOfClass:RUINSettingsViewController.class] && RUINChatCatalogAccount().length == 0;
    RUINSetupViewController *setup = [[RUINSetupViewController alloc] initWithSecondaryLoginAllowed:allowSecondary];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:setup];
    nav.modalInPresentation = YES;
    [presenter presentViewController:nav animated:YES completion:^{ sSetupPresentationInFlight = NO; }];
}

void RUINPresentFirstRunSetupIfNeeded(UIViewController *presenter) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:RUINSetupCompletedDefaultsKey]) return;
    RUINPresentSetup(presenter);
}
