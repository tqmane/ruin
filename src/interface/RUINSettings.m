#import "RUINSettings.h"
#import "Features.h"
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
    RUINSettingsSectionLocalNames,
    RUINSettingsSectionConfirmations,
    RUINSettingsSectionAppearance,
    RUINSettingsSectionTabs,
    RUINSettingsSectionHistory,
    RUINSettingsSectionSecondaryLogin,
    RUINSettingsSectionDiagnostics,
    RUINSettingsSectionShops,
    RUINSettingsSectionMIDLookup,
    RUINSettingsSectionNotifications,
    RUINSettingsSectionLineFeatures,
    RUINSettingsSectionCount,
};

@interface RUINSettingsViewController : UITableViewController <UIAdaptivePresentationControllerDelegate>
@property(nonatomic) BOOL compatible;
@property(nonatomic) BOOL fullySupported;
- (instancetype)initWithCompatibility:(BOOL)compatible;
- (void)closeSettings;
@end

@interface RUINDiagnosticsViewController : UIViewController
@property(nonatomic, strong) NSDictionary *document;
@end

static NSDictionary *Toggle(NSString *title, NSString *key) { return @{@"title":title, @"key":key}; }
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
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *identifier in RUINNativeTabIdentifiers()) {
        NSString *key = keys[identifier], *title = titles[identifier];
        if (key && title) [rows addObject:Toggle([NSString stringWithFormat:RUINLocalizedString(@"settings.hide_tab"), title], key)];
    }
    [rows addObject:Toggle(RUINLocalizedString(@"settings.fixed_startup_tab"), RUINStartupTabFixedDefaultsKey)];
    return rows;
}
static NSArray<NSDictionary *> *ToggleRows(NSInteger section) {
    switch (section) {
        case RUINSettingsSectionReadControls: return @[Toggle(RUINLocalizedString(@"settings.hide_read"), RUINReadControlEnabledDefaultsKey), Toggle(RUINLocalizedString(@"settings.mark_read_on_reply"), RUINMarkReadOnReplyDefaultsKey)];
        case RUINSettingsSectionConfirmations: return @[Toggle(RUINLocalizedString(@"settings.confirm_group_send"), RUINConfirmSendEnabledDefaultsKey), Toggle(RUINLocalizedString(@"settings.confirm_call"), RUINConfirmCallEnabledDefaultsKey), Toggle(RUINLocalizedString(@"settings.confirm_camera_on"), RUINConfirmCameraOnEnabledDefaultsKey), Toggle(RUINLocalizedString(@"settings.confirm_disconnect"), RUINConfirmDisconnectEnabledDefaultsKey)];
        case RUINSettingsSectionAppearance: return @[Toggle(RUINLocalizedString(@"settings.hide_ads"), RUINHideAdsDefaultsKey), Toggle(RUINLocalizedString(@"settings.hide_recommendations"), RUINHideRecommendationsDefaultsKey), Toggle(RUINLocalizedString(@"settings.hide_voice_input"), RUINHideVoiceInputDefaultsKey), Toggle(RUINLocalizedString(@"settings.hide_agent_bar"), RUINHideAgentIBarDefaultsKey)];
        case RUINSettingsSectionTabs: return RUINNativeTabRows();
        case RUINSettingsSectionHistory: return @[Toggle(RUINLocalizedString(@"settings.keep_unsent_media"), RUINKeepUnsentMessagesKey), Toggle(RUINLocalizedString(@"settings.track_read_ranges"), RUINTrackReadUsersKey), Toggle(RUINLocalizedString(@"settings.skip_age_verification"), RUINBypassAgeVerificationDefaultsKey), Toggle(RUINLocalizedString(@"settings.copy_sticker_gif"), RUINCopyStickerGIFEnabledDefaultsKey)];
        case RUINSettingsSectionNotifications: return @[Toggle(RUINLocalizedString(@"settings.local_notifications"), RUINLocalNotificationsEnabledDefaultsKey)];
        case RUINSettingsSectionLineFeatures: return @[Toggle(RUINLocalizedString(@"settings.local_lyp"), RUINLocalLYPEnabledDefaultsKey), Toggle(RUINLocalizedString(@"settings.legacy_messaging"), RUINLegacyMessagingEnabledDefaultsKey)];
        default: return @[];
    }
}
@implementation RUINSettingsViewController
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tableView reloadData];
    RUINRefreshRuntimeReport();
}
- (instancetype)initWithCompatibility:(BOOL)compatible {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _compatible = compatible;
        _fullySupported = RUINSettingsHostIsFullySupported();
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = RUINLocalizedString(@"settings.title");
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
- (NSDictionary *)aliases {
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:RUINLocalNamesByIdentityDefaultsKey] ?: @{};
    NSMutableDictionary *visible = [NSMutableDictionary dictionary];
    for (id key in saved) if ([key isKindOfClass:NSString.class] && [saved[key] isKindOfClass:NSString.class] && [saved[key] length]) visible[key] = saved[key];
    return visible;
}
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return self.compatible ? RUINSettingsSectionCount : 1; }
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.compatible ? @[RUINLocalizedString(@"settings.version"), RUINLocalizedString(@"settings.read_controls"), RUINLocalizedString(@"settings.chat_names"), RUINLocalizedString(@"settings.confirmations"), RUINLocalizedString(@"settings.appearance"), RUINLocalizedString(@"settings.tabs"), RUINLocalizedString(@"settings.history"), RUINLocalizedString(@"settings.secondary_login"), RUINLocalizedString(@"settings.diagnostics"), RUINLocalizedString(@"settings.shops"), RUINLocalizedString(@"settings.user_search"), RUINLocalizedString(@"settings.notifications"), RUINLocalizedString(@"settings.line_features")][section] : RUINLocalizedString(@"settings.diagnostics");
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.compatible) return RUINLocalizedString(@"compatibility.build_unsupported");
    switch (section) {
        case RUINSettingsSectionReadControls: return RUINLocalizedString(@"settings.read_controls_footer");
        case RUINSettingsSectionLocalNames: return RUINLocalizedString(@"settings.chat_names_footer");
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
            return footer;
        }
        case RUINSettingsSectionHistory: return RUINLocalizedString(@"media.history_footer");
        case RUINSettingsSectionSecondaryLogin: return RUINLocalizedString(@"settings.secondary_login_footer");
        case RUINSettingsSectionDiagnostics: return RUINLocalizedString(@"settings.diagnostics_footer");
        case RUINSettingsSectionNotifications: return RUINLocalizedString(@"settings.notifications_footer");
        case RUINSettingsSectionLineFeatures: return RUINLocalizedString(@"settings.line_features_footer");
        default: return nil;
    }
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.compatible) return 1;
    if (section == RUINSettingsSectionVersion && !self.fullySupported &&
        !RUINShouldSuppressPartialCompatibilityWarning()) return 2;
    if (section == RUINSettingsSectionLocalNames) return 1;
    if (section == RUINSettingsSectionReadControls || section == RUINSettingsSectionConfirmations || section == RUINSettingsSectionTabs) return ToggleRows(section).count + 1;
    if (section == RUINSettingsSectionDiagnostics || section == RUINSettingsSectionShops) return 2;
    if (section == RUINSettingsSectionLineFeatures) return ToggleRows(RUINSettingsSectionLineFeatures).count + 1;
    return MAX((NSInteger)1, (NSInteger)ToggleRows(section).count);
}
- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 2;
    NSArray *rows = ToggleRows(path.section);
    if (!self.compatible || path.section == RUINSettingsSectionDiagnostics) {
        cell.textLabel.text = path.row == 0 ? RUINLocalizedString(@"diagnostics.runtime_title") : RUINLocalizedString(@"diagnostics.feature_matrix");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == RUINSettingsSectionLineFeatures && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionLineFeatures).count) {
        cell.textLabel.text = RUINLocalizedString(@"font.title");
        cell.detailTextLabel.text = RUINLocalFontName() ?: RUINLocalizedString(@"font.default");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == RUINSettingsSectionMIDLookup) {
        cell.textLabel.text = RUINLocalizedString(@"profile.open_by_mid");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == RUINSettingsSectionShops) {
        cell.textLabel.text = path.row == 0 ? RUINLocalizedString(@"themes.downloads_title") : RUINLocalizedString(@"shops.sticker_title");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == RUINSettingsSectionVersion && path.row == 1 && !self.fullySupported) {
        cell.textLabel.text = RUINLocalizedString(@"compatibility.partial.title");
        cell.detailTextLabel.text = RUINPartialCompatibilityMessage();
        cell.textLabel.textColor = UIColor.systemOrangeColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == RUINSettingsSectionVersion) {
        cell.textLabel.text = [NSString stringWithFormat:@"RUIN v%@", RUINVersion];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"LINE %@ / %@", RUINSettingsInfoString(@"CFBundleShortVersionString"), RUINSettingsInfoString(@"CFBundleVersion")];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == RUINSettingsSectionLocalNames) {
        cell.textLabel.text = RUINLocalizedString(@"names.choose_chat");
        cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"names.modified_chat_count"), (unsigned long)self.aliases.count];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == RUINSettingsSectionSecondaryLogin) {
        BOOL on = [RUINSecondaryLoginDiagnostics()[@"activeTabletRole"] boolValue];
        cell.textLabel.text = on ? RUINLocalizedString(@"login.secondary_mode") : RUINLocalizedString(@"login.primary_mode");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ((NSUInteger)path.row < rows.count) {
        NSDictionary *row = rows[path.row]; NSString *key = row[@"key"];
        cell.textLabel.text = row[@"title"];
        RUINPreferenceSwitch *toggle = [RUINPreferenceSwitch new];
        toggle.preferenceKey = key;
        toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:key];
        toggle.accessibilityLabel = row[@"title"];
        if (path.section == RUINSettingsSectionTabs) toggle.enabled = toggle.on || RUINCanHideNativeService(key);
        if ([key isEqual:RUINHideSettingsTabDefaultsKey]) toggle.enabled = toggle.on ||
            (toggle.enabled && [RUINNativeEntryDiagnostics()[@"homeEntryAvailable"] boolValue]);
        cell.textLabel.textColor = toggle.enabled ? UIColor.labelColor : UIColor.secondaryLabelColor;
        [toggle addTarget:self action:@selector(preferenceChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        if (path.section == RUINSettingsSectionReadControls) { cell.textLabel.text = RUINLocalizedString(@"settings.read_exceptions"); cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"common.item_count"), (unsigned long)[NSUserDefaults.standardUserDefaults arrayForKey:RUINReadExceptionsDefaultsKey].count]; }
        if (path.section == RUINSettingsSectionConfirmations) { cell.textLabel.text = RUINLocalizedString(@"settings.minimum_group_members"); cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"common.member_count"), (long)[NSUserDefaults.standardUserDefaults integerForKey:RUINConfirmSendMinimumGroupMemberCountDefaultsKey]]; }
        if (path.section == RUINSettingsSectionTabs) {
            cell.textLabel.text = RUINLocalizedString(@"settings.startup_tab");
            NSString *identifier = [NSUserDefaults.standardUserDefaults stringForKey:RUINStartupTabDefaultsKey];
            cell.detailTextLabel.text = RUINTabTitles()[identifier ?: @""] ?: RUINLocalizedString(@"common.not_set");
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)preferenceChanged:(RUINPreferenceSwitch *)toggle {
    NSString *key = toggle.preferenceKey;
    if (!key) return;
    [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:key]; RUINRefreshSettingsFeature(key);
    if ([RUINTabHideKeys().allValues containsObject:key])
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:RUINSettingsSectionTabs] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"RUIN" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"common.confirm") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (!self.compatible || path.section == RUINSettingsSectionDiagnostics) {
        RUINDiagnosticsViewController *viewer = [RUINDiagnosticsViewController new];
        if (path.row == 1) {
            viewer.document = RUINFeatureDiagnostics();
        }
        [self.navigationController pushViewController:viewer animated:YES];
    } else if (path.section == RUINSettingsSectionLineFeatures && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionLineFeatures).count) {
        RUINOpenLocalFontSettings(self);
    } else if (path.section == RUINSettingsSectionMIDLookup) {
        RUINOpenMIDLookup(self);
    } else if (path.section == RUINSettingsSectionShops) {
        if (path.row == 0) RUINOpenThemeSettings(self);
        else RUINOpenStickerShop(self);
    } else if (path.section == RUINSettingsSectionLocalNames) {
        __weak typeof(self) weak = self;
        RUINOpenLocalNamePicker(self, ^{ RUINRefreshSettingsFeature(RUINLocalNamesByIdentityDefaultsKey); [weak.tableView reloadData]; });
    } else if (path.section == RUINSettingsSectionReadControls && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionReadControls).count) [self editReadExceptions];
    else if (path.section == RUINSettingsSectionConfirmations && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionConfirmations).count) [self editThreshold];
    else if (path.section == RUINSettingsSectionTabs && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionTabs).count) [self editStartupTab];
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

@implementation RUINDiagnosticsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RUINLocalizedString(@"settings.diagnostics");
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
    textView.text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]
                        : [NSString stringWithFormat:RUINLocalizedString(@"diagnostics.json_failed"), error.localizedDescription ?: RUINLocalizedString(@"errors.unknown")];
    [self.view addSubview:textView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [textView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8.0],
        [textView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0]
    ]];
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
