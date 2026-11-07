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

static NSString *RUINPartialCompatibilityMessage(void) {
    NSString *format = RUINLocalizedString(@"LINE %@（ビルド %@）は完全には検証されていないため、一部の機能を利用できない可能性があります。");
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
    return @{@"home":RUINLocalizedString(@"ホーム"), @"talk":RUINLocalizedString(@"トーク"), @"shopping":RUINLocalizedString(@"ショッピング"),
        @"voom":@"VOOM", @"wallet":RUINLocalizedString(@"ウォレット"), @"news":RUINLocalizedString(@"ニュース"),
        @"call":RUINLocalizedString(@"通話"), @"settings":RUINLocalizedString(@"設定"), @"apps":RUINLocalizedString(@"アプリ")};
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
        if (key && title) [rows addObject:Toggle([NSString stringWithFormat:RUINLocalizedString(@"%@を非表示"), title], key)];
    }
    [rows addObject:Toggle(RUINLocalizedString(@"起動時のタブを固定"), RUINStartupTabFixedDefaultsKey)];
    return rows;
}
static NSArray<NSDictionary *> *ToggleRows(NSInteger section) {
    switch (section) {
        case RUINSettingsSectionReadControls: return @[Toggle(RUINLocalizedString(@"既読を隠す"), RUINReadControlEnabledDefaultsKey), Toggle(RUINLocalizedString(@"返信時に既読をつける"), RUINMarkReadOnReplyDefaultsKey)];
        case RUINSettingsSectionConfirmations: return @[Toggle(RUINLocalizedString(@"グループへの送信確認"), RUINConfirmSendEnabledDefaultsKey), Toggle(RUINLocalizedString(@"通話開始の確認"), RUINConfirmCallEnabledDefaultsKey), Toggle(RUINLocalizedString(@"カメラをオンにする前に確認"), RUINConfirmCameraOnEnabledDefaultsKey), Toggle(RUINLocalizedString(@"通話終了の確認"), RUINConfirmDisconnectEnabledDefaultsKey)];
        case RUINSettingsSectionAppearance: return @[Toggle(RUINLocalizedString(@"広告を非表示"), RUINHideAdsDefaultsKey), Toggle(RUINLocalizedString(@"おすすめ欄を非表示"), RUINHideRecommendationsDefaultsKey), Toggle(RUINLocalizedString(@"音声入力ボタンを非表示"), RUINHideVoiceInputDefaultsKey), Toggle(RUINLocalizedString(@"Agent-iバーを非表示"), RUINHideAgentIBarDefaultsKey)];
        case RUINSettingsSectionTabs: return RUINNativeTabRows();
        case RUINSettingsSectionHistory: return @[Toggle(RUINLocalizedString(@"送信取消された本文を保持"), RUINKeepUnsentMessagesKey), Toggle(RUINLocalizedString(@"既読範囲を記録"), RUINTrackReadUsersKey), Toggle(RUINLocalizedString(@"年齢確認をスキップ"), RUINBypassAgeVerificationDefaultsKey), Toggle(RUINLocalizedString(@"スタンプをGIFでコピー"), RUINCopyStickerGIFEnabledDefaultsKey)];
        case RUINSettingsSectionNotifications: return @[Toggle(RUINLocalizedString(@"新着のローカル通知"), RUINLocalNotificationsEnabledDefaultsKey)];
        case RUINSettingsSectionLineFeatures: return @[Toggle(RUINLocalizedString(@"ローカルLYP機能"), RUINLocalLYPEnabledDefaultsKey), Toggle(RUINLocalizedString(@"24h送信取消・ミュートメッセージ"), RUINLegacyMessagingEnabledDefaultsKey)];
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
    [super viewDidLoad]; self.title = RUINLocalizedString(@"RUIN設定");
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
    return self.compatible ? @[RUINLocalizedString(@"バージョン"), RUINLocalizedString(@"既読の管理"), RUINLocalizedString(@"トークの表示名"), RUINLocalizedString(@"操作確認"), RUINLocalizedString(@"表示の管理"), RUINLocalizedString(@"タブの管理"), RUINLocalizedString(@"履歴・追加機能（開発中）"), RUINLocalizedString(@"サブ端末ログイン"), RUINLocalizedString(@"診断"), RUINLocalizedString(@"ショップ"), RUINLocalizedString(@"ユーザー検索"), RUINLocalizedString(@"通知"), RUINLocalizedString(@"LINE機能（開発中）")][section] : RUINLocalizedString(@"診断");
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.compatible) return RUINLocalizedString(@"このLINEビルドでは機能を有効にできません。");
    switch (section) {
        case RUINSettingsSectionReadControls: return RUINLocalizedString(@"1対1のトークで、既読非表示・トーク別の例外・返信時の切替を実機で確認済みです。グループやオープンチャット、手動で既読にする操作は検証中です。");
        case RUINSettingsSectionLocalNames: return RUINLocalizedString(@"この端末での表示名だけを変更します。相手には反映されません。一覧に反映されない場合はLINEを再起動してください。");
        case RUINSettingsSectionConfirmations: return RUINLocalizedString(@"送信確認を行う最低人数は、自分を含むグループ人数です。0は人数指定なし。通話・送信の一部の入口はまだ検証中です。");
        case RUINSettingsSectionAppearance: return RUINLocalizedString(@"変更後はトーク画面を開き直してください。");
        case RUINSettingsSectionTabs: {
            NSArray *pair = RUINNativeServicePair();
            NSString *dependency = [pair[0] length] && [pair[1] length] ?
                [NSString stringWithFormat:RUINLocalizedString(@"「%@」と「%@」を同時に非表示にできません。"), RUINTabTitles()[pair[0]], RUINTabTitles()[pair[1]]] :
                RUINLocalizedString(@"アプリの動作に必要なタブは、常に表示されます。");
            if ([RUINNativeTabAvailabilityDiagnostics()[@"menuOnlyScopeVerified"] boolValue]) dependency = @"";
            return [NSString stringWithFormat:RUINLocalizedString(@"現在利用可能なタブのみ設定できます。「ホーム」と「トーク」は非表示にできません。%@変更はアプリの再起動後に反映されます。"),dependency];
        }
        case RUINSettingsSectionHistory: return RUINLocalizedString(@"1対1トークでの受信済みテキスト保持と「取消済」表示を確認済みです。添付ファイル・グループ・オープンチャットでの保持は検証中です。既読者一覧には、この端末で記録した名前と日時を表示します。");
        case RUINSettingsSectionSecondaryLogin: return RUINLocalizedString(@"変更はログアウト後、ログイン画面の「ログイン」長押しで行います。切り替え後はアプリの再起動が必要です。");
        case RUINSettingsSectionDiagnostics: return RUINLocalizedString(@"着せかえ・スタンプGIF・MID検索なども全機能対応の対象です。未完成の項目を対応済みとは表示しません。");
        case RUINSettingsSectionNotifications: return RUINLocalizedString(@"1対1・グループトークの新着のみ通知します。アプリ停止中の即時受信には対応していません。");
        case RUINSettingsSectionLineFeatures: return RUINLocalizedString(@"アプリアイコン等は「ローカルLYP」、24時間までの送信取消とミュート送信は別スイッチで設定します（変更後はLINEを再起動）。ミュート送信は入力確定後、送信ボタンを約2秒長押しします。");
        default: return nil;
    }
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.compatible) return 1;
    if (section == RUINSettingsSectionVersion && !self.fullySupported) return 2;
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
        cell.textLabel.text = path.row == 0 ? RUINLocalizedString(@"ランタイム・機能診断") : RUINLocalizedString(@"全機能の対応表");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == RUINSettingsSectionLineFeatures && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionLineFeatures).count) {
        cell.textLabel.text = RUINLocalizedString(@"カスタムフォント");
        cell.detailTextLabel.text = RUINLocalFontName() ?: RUINLocalizedString(@"標準フォント");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == RUINSettingsSectionMIDLookup) {
        cell.textLabel.text = RUINLocalizedString(@"MIDでプロフィールを開く");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == RUINSettingsSectionShops) {
        cell.textLabel.text = path.row == 0 ? RUINLocalizedString(@"着せかえのダウンロード・保存一覧") : RUINLocalizedString(@"スタンプショップ");
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
        cell.textLabel.text = RUINLocalizedString(@"表示名を変更するトークを選ぶ");
        cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"%lu件のトークを変更中"), (unsigned long)self.aliases.count];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == RUINSettingsSectionSecondaryLogin) {
        BOOL on = [RUINSecondaryLoginDiagnostics()[@"activeTabletRole"] boolValue];
        cell.textLabel.text = on ? RUINLocalizedString(@"iPad扱いのサブ端末モード") : RUINLocalizedString(@"通常のiPhoneモード");
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
        if (path.section == RUINSettingsSectionReadControls) { cell.textLabel.text = RUINLocalizedString(@"通常通り既読をつけるトーク"); cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"%lu件"), (unsigned long)[NSUserDefaults.standardUserDefaults arrayForKey:RUINReadExceptionsDefaultsKey].count]; }
        if (path.section == RUINSettingsSectionConfirmations) { cell.textLabel.text = RUINLocalizedString(@"送信確認の最低人数"); cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"%ld人"), (long)[NSUserDefaults.standardUserDefaults integerForKey:RUINConfirmSendMinimumGroupMemberCountDefaultsKey]]; }
        if (path.section == RUINSettingsSectionTabs) { cell.textLabel.text = RUINLocalizedString(@"起動時に開くタブ"); cell.detailTextLabel.text = [NSUserDefaults.standardUserDefaults stringForKey:RUINStartupTabDefaultsKey] ?: RUINLocalizedString(@"未設定"); }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)preferenceChanged:(RUINPreferenceSwitch *)toggle {
    NSString *key = toggle.preferenceKey;
    if (!key) return;
    [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:key]; RUINRefreshSettingsFeatures();
    if ([RUINTabHideKeys().allValues containsObject:key])
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:RUINSettingsSectionTabs] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"RUIN" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"確認") style:UIAlertActionStyleDefault handler:nil]];
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
        RUINOpenLocalNamePicker(self, ^{ RUINRefreshSettingsFeatures(); [weak.tableView reloadData]; });
    } else if (path.section == RUINSettingsSectionReadControls && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionReadControls).count) [self editReadExceptions];
    else if (path.section == RUINSettingsSectionConfirmations && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionConfirmations).count) [self editThreshold];
    else if (path.section == RUINSettingsSectionTabs && (NSUInteger)path.row == ToggleRows(RUINSettingsSectionTabs).count) [self editStartupTab];
}
- (void)editThreshold {
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"送信確認の最低人数") message:RUINLocalizedString(@"自分を含むグループ人数。0は人数指定なし。") preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) { field.keyboardType = UIKeyboardTypeNumberPad; field.text = [NSString stringWithFormat:@"%ld", (long)[NSUserDefaults.standardUserDefaults integerForKey:RUINConfirmSendMinimumGroupMemberCountDefaultsKey]]; }];
    __weak typeof(self) owner = self; __weak UIAlertController *weakPrompt = prompt;
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"キャンセル") style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"保存") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *text = weakPrompt.textFields.firstObject.text ?: @"";
        if (!text.length || [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound || text.length > 6) { dispatch_async(dispatch_get_main_queue(), ^{ [owner showMessage:RUINLocalizedString(@"0以上の人数を入力してください。")]; }); return; }
        [NSUserDefaults.standardUserDefaults setInteger:text.integerValue forKey:RUINConfirmSendMinimumGroupMemberCountDefaultsKey]; RUINRefreshSettingsFeatures(); [owner.tableView reloadData];
    }]];
    [self presentViewController:prompt animated:YES completion:nil];
}
- (void)editReadExceptions {
    __weak typeof(self) weak = self;
    RUINOpenReadExceptionPicker(self, ^{ RUINRefreshSettingsFeatures(); [weak.tableView reloadData]; });
}
- (void)editStartupTab {
    NSArray *available = RUINAvailableTabs();
    if (!available.count) { [self showMessage:RUINLocalizedString(@"LINEのタブを検出した後に選択できます。")]; return; }
    NSDictionary *titles = RUINTabTitles();
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"起動時に開くタブ") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) owner = self;
    for (NSString *identifier in available) [menu addAction:[UIAlertAction actionWithTitle:titles[identifier] ?: identifier style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [NSUserDefaults.standardUserDefaults setObject:identifier forKey:RUINStartupTabDefaultsKey]; RUINRefreshSettingsFeatures(); [owner.tableView reloadData]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"キャンセル") style:UIAlertActionStyleCancel handler:nil]];
    if (menu.popoverPresentationController) { menu.popoverPresentationController.sourceView = self.view; menu.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1); }
    [self presentViewController:menu animated:YES completion:nil];
}
@end

@implementation RUINDiagnosticsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RUINLocalizedString(@"診断");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UITextView *textView = [UITextView new];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.selectable = YES;
    textView.alwaysBounceVertical = YES;
    textView.backgroundColor = UIColor.clearColor;
    textView.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    textView.accessibilityLabel = RUINLocalizedString(@"RUINのランタイム、互換性、機能診断のJSON");
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:(self.document ?: RUINRuntimeDiagnostics())
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:&error];
    textView.text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]
                        : [NSString stringWithFormat:RUINLocalizedString(@"診断をJSONに変換できませんでした: %@"), error.localizedDescription ?: RUINLocalizedString(@"不明なエラー")];
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
    if (!RUINIsCompatible() || RUINSettingsHostIsFullySupported() ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;

    NSString *buildIdentifier = RUINPartialWarningBuildIdentifier();
    if (RUINPartialWarningWasPresented(buildIdentifier)) return NO;
    if (sCompatibilityWarningScheduled) return YES;

    sCompatibilityWarningScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        sCompatibilityWarningScheduled = NO;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
            !RUINIsCompatible() || RUINSettingsHostIsFullySupported()) return;

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
