%config(generator=internal);

#import <UIKit/UIKit.h>
#import "Features.h"
#import "Localization.h"
#import "SecondaryLogin.h"
#import "InterfaceFeatures.h"
#import "Confirmations.h"
#import "MessageHistory.h"
#import "MenuExtras.h"
#import "ReadOnReply.h"
#import "ReadBoundary.h"
#import "NativeChatControls.h"
#import "RuntimeInspector.h"
#import "UnsendRetention.h"
#import "UnsendOperation.h"
#import "UnsendMarkerUI.h"
#import "AgeVerification.h"
#import "ReadUsersEvents.h"
#import "AutomaticReadGate.h"
#import "ThemeFeatures.h"
#import "ThemeUI.h"
#import "ThemeShop.h"
#import "ThemeStoreDownload.h"
#import "ThemeStoreWeb.h"
#import "ThemeStoreImages.h"
#import "NativeThemeImages.h"
#import "NativeThemeWorkflow.h"
#import "NativeThemeRegistration.h"
#import "MIDLookup.h"
#import "ReadersSheet.h"
#import "NativeReadRangeSync.h"
#import "NativeTabAvailability.h"
#import "ReadRangeFetch.h"
#import "PushDiagnostics.h"
#import "LocalNotifications.h"
#import "LocalAppearance.h"
#import "LocalFont.h"
#import "LocalFontUI.h"
#import "NativeMuteSend.h"
#import "ClientVersionAdvertisement.h"
#import "LegacyMessagingConfiguration.h"
#import <objc/runtime.h>
#import <string.h>

extern void RUINInstallCompatibility(void);
extern NSDictionary *RUINCompatibilityDiagnostics(void);
extern void RUINInstallKeychainCompatibility(void);
extern NSDictionary *RUINKeychainDiagnostics(void);
extern NSDictionary *RUINKeychainSelfTest(void);
extern void RUINInstallNativeEntry(void);
extern NSDictionary *RUINNativeEntryDiagnostics(void);

static NSString *const RUINVersion = RUIN_BUILD_VERSION;

static UINavigationController *sSettingsNavigationController;
static BOOL sSettingsPresentationInFlight;
static BOOL sEnvironmentSettingsScheduled;
static BOOL sEnvironmentSettingsPresented;
static id sActiveObserver;
static NSDictionary *sKeychainSelfTest;
static BOOL sLocalNotificationLaunchHookInstalled;

static NSDictionary *RUINMainBundleInfo(void) {
    return NSBundle.mainBundle.infoDictionary ?: @{};
}

static NSString *RUINInfoString(NSString *key) {
    id value = RUINMainBundleInfo()[key];
    return [value isKindOfClass:NSString.class] ? value : @"unknown";
}

static BOOL RUINIsCompatible(void) {
    NSDictionary *info = RUINMainBundleInfo();
    return [info[@"RUINOriginalBundleIdentifier"] isEqualToString:RUINTargetBundleIdentifier] &&
           [info[@"CFBundleShortVersionString"] isEqualToString:RUINTargetVersion] &&
           [info[@"CFBundleVersion"] isEqualToString:RUINTargetBuild];
}

%group RUINLaunchBoundary
%hook RUINAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
    BOOL result = %orig(application, options);
    // Install after LINE assigns its delegate and before launch returns, so a
    // cold notification tap cannot enter LINE's remote-push parser.
    if (result) RUINInstallLocalNotifications();
    return result;
}
%end
%end

static void RUINInstallLocalNotificationLaunchBoundary(void) {
    if (sLocalNotificationLaunchHookInstalled || !RUINIsCompatible()) return;
    Class cls = NSClassFromString(@"LINE.AppDelegate");
    SEL selector = @selector(application:didFinishLaunchingWithOptions:);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *type = method ? method_getTypeEncoding(method) : NULL;
    if (!type || (strcmp(type, "B32@0:8@16@24") && strcmp(type, "c32@0:8@16@24"))) return;
    %init(RUINLaunchBoundary, RUINAppDelegate = cls);
    sLocalNotificationLaunchHookInstalled = YES;
}

static NSDictionary *RUINRuntimeDiagnostics(void) {
    NSDictionary *info = RUINMainBundleInfo();
    NSDictionary *featureDiagnostics = RUINFeatureDiagnostics() ?: @{};
    NSDictionary *compatibilityDiagnostics = RUINCompatibilityDiagnostics() ?: @{};
    return @{
        @"capturedAt": [[NSISO8601DateFormatter new] stringFromDate:NSDate.date],
        @"ruin": @{ @"version": RUINVersion, @"loaded": @YES },
        @"app": @{
            @"originalBundleIdentifier": info[@"RUINOriginalBundleIdentifier"] ?: NSNull.null,
            @"signedBundleIdentifier": info[@"RUINSignedBundleIdentifier"] ?: NSNull.null,
            @"version": info[@"CFBundleShortVersionString"] ?: @"unknown",
            @"build": info[@"CFBundleVersion"] ?: @"unknown",
            @"compatible": @(RUINIsCompatible())
        },
        @"compatibility": compatibilityDiagnostics,
        @"push": RUINPushDiagnostics(),
        @"nativeEntry": RUINNativeEntryDiagnostics() ?: @{},
        @"nativeChat": RUINNativeChatControlsDiagnostics(),
        @"runtimeInspector": RuntimeInspectorDiagnostics(),
        @"secondaryLogin": RUINSecondaryLoginDiagnostics(),
        @"replyObserver": RUINReplyDiagnostics(),
        @"readBoundary": RUINReadBoundaryDiagnostics(),
        @"automaticReadGate": RUINAutomaticReadGateDiagnostics(),
        @"themes": RUINThemeDiagnostics(),
        @"themeShop": RUINThemeShopDiagnostics(),
        @"themeStoreDownload": RUINThemeStoreDownloadDiagnostics(),
        @"themeStoreWeb": RUINThemeStoreWebDiagnostics(),
        @"themeStoreImages": RUINThemeStoreImagesDiagnostics(),
        @"nativeThemeImages": RUINNativeThemeImagesDiagnostics(),
        @"nativeThemeWorkflow": RUINNativeThemeWorkflowDiagnostics(),
        @"midLookup": RUINMIDLookupDiagnostics(),
        @"readersSheet": RUINReadersSheetDiagnostics(),
        @"interface": RUINInterfaceDiagnostics(),
        @"localNotifications": RUINLocalNotificationDiagnostics(),
        @"localNotificationLaunchHookInstalled": @(sLocalNotificationLaunchHookInstalled),
        @"localAppearance": RUINLocalAppearanceDiagnostics(),
        @"localization": RUINLocalizationDiagnostics(),
        @"localFont": RUINLocalFontDiagnostics(),
        @"localFontRendering": RUINLocalFontHookDiagnostics(),
        @"nativeMuteSend": RUINNativeMuteSendDiagnostics(),
        @"clientVersionAdvertisement": RUINClientVersionAdvertisementDiagnostics(),
        @"legacyMessagingConfiguration": RUINLegacyMessagingConfigurationDiagnostics(),
        @"confirmations": RUINConfirmationDiagnostics(),
        @"messageHistory": RUINMessageHistoryDiagnostics(),
        @"nativeReadRangeSync": RUINNativeReadRangeSyncDiagnostics(),
        @"readRangeFetch": RUINReadRangeFetchDiagnostics(),
        @"unsendRetention": RUINUnsendRetentionDiagnostics(),
        @"unsendOperation": RUINUnsendOperationDiagnostics(),
        @"unsendMarkerUI": RUINUnsendMarkerUIDiagnostics(),
        @"ageVerification": RUINAgeVerificationDiagnostics(),
        @"readUsersEvents": RUINReadUsersEventsDiagnostics(),
        @"menuExtras": RUINMenuExtrasDiagnostics(),
        @"keychain": RUINKeychainDiagnostics() ?: @{},
        @"keychainSelfTest": sKeychainSelfTest ?: @{},
        @"features": featureDiagnostics
    };
}

static void RUINWriteRuntimeReport(void) {
    RUINRefreshPushDiagnostics();
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!caches.length) return;
    NSString *directory = [caches stringByAppendingPathComponent:@"RUIN"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES attributes:nil error:NULL]) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:RUINRuntimeDiagnostics()
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:NULL];
    if (data) [data writeToFile:[directory stringByAppendingPathComponent:@"runtime.json"] options:NSDataWritingAtomic error:NULL];
}

@interface RUINSettingsViewController : UITableViewController <UIAdaptivePresentationControllerDelegate>
@property(nonatomic) BOOL compatible;
- (instancetype)initWithCompatibility:(BOOL)compatible;
- (void)closeSettings;
@end

@interface RUINDiagnosticsViewController : UIViewController
@property(nonatomic, strong) NSDictionary *document;
@end

static BOOL RUINPresentSettings(void);
static void RUINMaybeScheduleEnvironmentSettings(void);

static char preferenceKey;
static NSDictionary *Toggle(NSString *title, NSString *key) { return @{@"title":title, @"key":key}; }
static NSDictionary<NSString *, NSString *> *RUINTabTitles(void) {
    return @{@"home":RUINLocalizedString(@"ホーム"), @"talk":RUINLocalizedString(@"トーク"), @"shopping":RUINLocalizedString(@"ショッピング"),
        @"voom":@"VOOM", @"wallet":RUINLocalizedString(@"ウォレット"), @"news":RUINLocalizedString(@"ニュース"),
        @"call":RUINLocalizedString(@"通話"), @"settings":RUINLocalizedString(@"設定")};
}
static NSDictionary<NSString *, NSString *> *RUINTabHideKeys(void) {
    return @{@"shopping":RUINHideShoppingTabDefaultsKey,
        @"voom":RUINHideVOOMTabDefaultsKey, @"wallet":RUINHideWalletTabDefaultsKey,
        @"news":RUINHideNewsCallTabsDefaultsKey, @"call":RUINHideNewsCallTabsDefaultsKey,
        @"settings":RUINHideSettingsTabDefaultsKey};
}
static NSArray<NSString *> *RUINNativeServicePair(void) {
    NSArray *tabs = RUINNativeTabIdentifiers();
    NSString *timeline = [tabs containsObject:@"shopping"] ? @"shopping" : [tabs containsObject:@"voom"] ? @"voom" : @"";
    NSString *more = [tabs containsObject:@"settings"] ? @"settings" : [tabs containsObject:@"wallet"] ? @"wallet" : @"";
    return @[timeline,more];
}
static BOOL RUINCanHideNativeService(NSString *key) {
    NSArray *pair = RUINNativeServicePair();
    NSDictionary *keys = RUINTabHideKeys();
    for (NSUInteger i=0;i<2;i++) if ([key isEqual:keys[pair[i]]]) {
        NSString *peer = keys[pair[1-i]];
        return peer && ![NSUserDefaults.standardUserDefaults boolForKey:peer];
    }
    return YES;
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
        case 1: return @[Toggle(RUINLocalizedString(@"既読を隠す"), RUINReadControlEnabledDefaultsKey), Toggle(RUINLocalizedString(@"返信時に既読をつける"), RUINMarkReadOnReplyDefaultsKey)];
        case 3: return @[Toggle(RUINLocalizedString(@"グループへの送信確認"), RUINConfirmSendEnabledDefaultsKey), Toggle(RUINLocalizedString(@"通話開始の確認"), RUINConfirmCallEnabledDefaultsKey), Toggle(RUINLocalizedString(@"カメラをオンにする前に確認"), RUINConfirmCameraOnEnabledDefaultsKey), Toggle(RUINLocalizedString(@"通話終了の確認"), RUINConfirmDisconnectEnabledDefaultsKey)];
        case 4: return @[Toggle(RUINLocalizedString(@"広告を非表示"), RUINHideAdsDefaultsKey), Toggle(RUINLocalizedString(@"おすすめ欄を非表示"), RUINHideRecommendationsDefaultsKey), Toggle(RUINLocalizedString(@"音声入力ボタンを非表示"), RUINHideVoiceInputDefaultsKey), Toggle(RUINLocalizedString(@"Agent-iバーを非表示"), RUINHideAgentIBarDefaultsKey)];
        case 5: return RUINNativeTabRows();
        case 6: return @[Toggle(RUINLocalizedString(@"送信取消された本文を保持"), RUINKeepUnsentMessagesKey), Toggle(RUINLocalizedString(@"既読範囲を記録"), RUINTrackReadUsersKey), Toggle(RUINLocalizedString(@"年齢確認をスキップ"), RUINBypassAgeVerificationDefaultsKey), Toggle(RUINLocalizedString(@"スタンプをGIFでコピー"), RUINCopyStickerGIFEnabledDefaultsKey)];
        case 11: return @[Toggle(RUINLocalizedString(@"新着のローカル通知"), RUINLocalNotificationsEnabledDefaultsKey)];
        case 12: return @[Toggle(RUINLocalizedString(@"ローカルLYP機能"), RUINLocalLYPEnabledDefaultsKey), Toggle(RUINLocalizedString(@"送信取消延長・ミュート"), RUINLegacyMessagingEnabledDefaultsKey)];
        default: return @[];
    }
}
static void RefreshFeatures(void) {
    RUINInstallLegacyMessagingConfiguration();
    RUINInstallClientVersionAdvertisement();
    RUINInstallLocalNotifications();
    RUINInstallLocalAppearance();
    RUINInstallLocalFont();
    RUINInstallNativeMuteSend();
    RUINInstallFeatures();
    RUINInstallReadBoundary();
    RUINInstallReadOnReply();
    RUINInstallConfirmations();
    RUINInstallNativeChatControls();
    RUINRefreshInterfaceFeatures();
    RUINInstallAutomaticReadGate();
    RUINInstallMessageHistory();
    RUINInstallUnsendRetention();
    RUINInstallUnsendOperation();
    RUINInstallUnsendMarkerUI();
    RUINInstallAgeVerification();
    RUINInstallReadUsersEvents();
    RUINInstallThemeFeatures();
    RUINInstallThemeStoreDownload();
    RUINInstallThemeStoreImages();
    RUINInstallNativeThemeImages();
    RUINInstallNativeThemeWorkflow();
    RUINInstallThemeStoreWeb();
    RUINInstallMenuExtras();
    RUINWriteRuntimeReport();
}

@implementation RUINSettingsViewController
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tableView reloadData];
    RUINWriteRuntimeReport();
}
- (instancetype)initWithCompatibility:(BOOL)compatible {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _compatible = compatible;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = RUINLocalizedString(@"RUIN設定");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    if (self.navigationController.viewControllers.firstObject == self)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(closeSettings)];
    if (self.compatible) self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addLocalName)];
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
- (NSArray<NSString *> *)aliasKeys { return [self.aliases.allKeys sortedArrayUsingSelector:@selector(compare:)]; }
- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return self.compatible ? 13 : 1; }
- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.compatible ? @[RUINLocalizedString(@"バージョン"), RUINLocalizedString(@"既読の管理"), RUINLocalizedString(@"ID別のローカル表示名"), RUINLocalizedString(@"操作確認"), RUINLocalizedString(@"表示の管理"), RUINLocalizedString(@"タブの管理"), RUINLocalizedString(@"履歴・追加機能（開発中）"), RUINLocalizedString(@"サブ端末ログイン"), RUINLocalizedString(@"診断"), RUINLocalizedString(@"ショップ"), RUINLocalizedString(@"ユーザー検索"), RUINLocalizedString(@"通知"), RUINLocalizedString(@"LINE機能（開発中）")][section] : RUINLocalizedString(@"診断");
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.compatible) return RUINLocalizedString(@"このLINEビルドでは機能を有効にできません。");
    switch (section) {
        case 1: return RUINLocalizedString(@"1対1のトークで、既読非表示・トーク別の例外・返信時の切替を実機で確認済みです。グループやオープンチャット、手動で既読にする操作は検証中です。");
        case 2: return RUINLocalizedString(@"ユーザー・グループ・オープンチャットの識別IDで照合します。表示名を空にすると解除します。一覧への反映にはアプリの再起動が必要です。");
        case 3: return RUINLocalizedString(@"送信確認を行う最低人数は、自分を含むグループ人数です。0は人数指定なし。通話・送信の一部の入口はまだ検証中です。");
        case 4: return RUINLocalizedString(@"変更後はトーク画面を開き直してください。");
        case 5: {
            NSArray *pair = RUINNativeServicePair();
            NSString *dependency = [pair[0] length] && [pair[1] length] ?
                [NSString stringWithFormat:RUINLocalizedString(@"「%@」と「%@」を同時に非表示にできません。"), RUINTabTitles()[pair[0]], RUINTabTitles()[pair[1]]] :
                RUINLocalizedString(@"アプリの動作に必要なタブは、常に表示されます。");
            return [NSString stringWithFormat:RUINLocalizedString(@"現在利用可能なタブのみ設定できます。「ホーム」と「トーク」は非表示にできません。%@変更はアプリの再起動後に反映されます。"),dependency];
        }
        case 6: return RUINLocalizedString(@"1対1トークでの受信済みテキスト保持と「取消済」表示を確認済みです。添付ファイル・グループ・オープンチャットでの保持は検証中です。既読者一覧には、この端末で記録した名前と日時を表示します。");
        case 7: return RUINLocalizedString(@"変更はログアウト後、ログイン画面の「ログイン」長押しで行います。切り替え後はアプリの再起動が必要です。");
        case 8: return RUINLocalizedString(@"着せかえ・スタンプGIF・MID検索なども全機能対応の対象です。未完成の項目を対応済みとは表示しません。");
        case 11: return RUINLocalizedString(@"1対1・グループトークの新着のみ通知します。アプリ停止中の即時受信には対応していません。");
        case 12: return RUINLocalizedString(@"アプリアイコン等は「ローカルLYP」、24時間までの送信取消とミュート送信は別スイッチで設定します（変更後はLINEを再起動）。ミュート送信は入力確定後、送信ボタンを約2秒長押しします。");
        default: return nil;
    }
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (!self.compatible) return 1;
    if (section == 2) return MAX((NSInteger)1, (NSInteger)self.aliasKeys.count);
    if (section == 1 || section == 3 || section == 5) return ToggleRows(section).count + 1;
    if (section == 8 || section == 9) return 2;
    if (section == 12) return ToggleRows(12).count + 1;
    return MAX((NSInteger)1, (NSInteger)ToggleRows(section).count);
}
- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 2;
    NSArray *rows = ToggleRows(path.section);
    if (!self.compatible || path.section == 8) {
        cell.textLabel.text = path.row == 0 ? RUINLocalizedString(@"ランタイム・機能診断") : RUINLocalizedString(@"全機能の対応表");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == 12 && (NSUInteger)path.row == ToggleRows(12).count) {
        cell.textLabel.text = RUINLocalizedString(@"カスタムフォント");
        cell.detailTextLabel.text = RUINLocalFontName() ?: RUINLocalizedString(@"標準フォント");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == 10) {
        cell.textLabel.text = RUINLocalizedString(@"MIDでプロフィールを開く");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == 9) {
        cell.textLabel.text = path.row == 0 ? RUINLocalizedString(@"着せかえのダウンロード・保存一覧") : RUINLocalizedString(@"スタンプショップ");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (path.section == 0) {
        cell.textLabel.text = [NSString stringWithFormat:@"RUIN v%@", RUINVersion];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"LINE %@ / %@", RUINInfoString(@"CFBundleShortVersionString"), RUINInfoString(@"CFBundleVersion")];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (path.section == 2) {
        NSArray *keys = self.aliasKeys;
        if (keys.count) { NSString *key = keys[path.row]; cell.textLabel.text = self.aliases[key]; cell.detailTextLabel.text = key; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; }
        else { cell.textLabel.text = RUINLocalizedString(@"ルールはありません（＋で追加）"); cell.textLabel.textColor = UIColor.secondaryLabelColor; }
    } else if (path.section == 7) {
        BOOL on = [RUINSecondaryLoginDiagnostics()[@"activeTabletRole"] boolValue];
        cell.textLabel.text = on ? RUINLocalizedString(@"iPad扱いのサブ端末モード") : RUINLocalizedString(@"通常のiPhoneモード");
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ((NSUInteger)path.row < rows.count) {
        NSDictionary *row = rows[path.row]; NSString *key = row[@"key"];
        cell.textLabel.text = row[@"title"];
        UISwitch *toggle = [UISwitch new]; toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:key];
        if (path.section == 5) toggle.enabled = toggle.on || RUINCanHideNativeService(key);
        if ([key isEqual:RUINHideSettingsTabDefaultsKey]) toggle.enabled = toggle.on ||
            (toggle.enabled && [RUINNativeEntryDiagnostics()[@"homeEntryAvailable"] boolValue]);
        cell.textLabel.textColor = toggle.enabled ? UIColor.labelColor : UIColor.secondaryLabelColor;
        objc_setAssociatedObject(toggle, &preferenceKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [toggle addTarget:self action:@selector(preferenceChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        if (path.section == 1) { cell.textLabel.text = RUINLocalizedString(@"通常通り既読をつけるトーク"); cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"%lu件"), (unsigned long)[NSUserDefaults.standardUserDefaults arrayForKey:RUINReadExceptionsDefaultsKey].count]; }
        if (path.section == 3) { cell.textLabel.text = RUINLocalizedString(@"送信確認の最低人数"); cell.detailTextLabel.text = [NSString stringWithFormat:RUINLocalizedString(@"%ld人"), (long)[NSUserDefaults.standardUserDefaults integerForKey:RUINConfirmSendMinimumGroupMemberCountDefaultsKey]]; }
        if (path.section == 5) { cell.textLabel.text = RUINLocalizedString(@"起動時に開くタブ"); cell.detailTextLabel.text = [NSUserDefaults.standardUserDefaults stringForKey:RUINStartupTabDefaultsKey] ?: RUINLocalizedString(@"未設定"); }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)preferenceChanged:(UISwitch *)toggle {
    NSString *key = objc_getAssociatedObject(toggle, &preferenceKey);
    if (!key) return;
    [NSUserDefaults.standardUserDefaults setBool:toggle.isOn forKey:key]; RefreshFeatures();
    if ([RUINTabHideKeys().allValues containsObject:key])
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:5] withRowAnimation:UITableViewRowAnimationNone];
}
- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"RUIN" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"確認") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (!self.compatible || path.section == 8) {
        RUINDiagnosticsViewController *viewer = [RUINDiagnosticsViewController new];
        if (path.row == 1) {
            viewer.document = RUINFeatureDiagnostics();
        }
        [self.navigationController pushViewController:viewer animated:YES];
    } else if (path.section == 12 && (NSUInteger)path.row == ToggleRows(12).count) {
        RUINOpenLocalFontSettings(self);
    } else if (path.section == 10) {
        RUINOpenMIDLookup(self);
    } else if (path.section == 9) {
        if (path.row == 0) RUINOpenThemeSettings(self);
        else RUINOpenStickerShop(self);
    } else if (path.section == 2 && self.aliasKeys.count) {
        NSString *key = self.aliasKeys[path.row]; [self editLocalName:key alias:self.aliases[key]];
    } else if (path.section == 1 && (NSUInteger)path.row == ToggleRows(1).count) [self editReadExceptions];
    else if (path.section == 3 && (NSUInteger)path.row == ToggleRows(3).count) [self editThreshold];
    else if (path.section == 5 && (NSUInteger)path.row == ToggleRows(5).count) [self editStartupTab];
}
- (BOOL)tableView:(__unused UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)path { return self.compatible && path.section == 2 && self.aliasKeys.count > 0; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete || path.section != 2 || (NSUInteger)path.row >= self.aliasKeys.count) return;
    RUINSetLocalName(self.aliasKeys[path.row], @""); RefreshFeatures(); [tableView reloadData];
}
- (void)addLocalName { [self editLocalName:nil alias:nil]; }
- (void)editLocalName:(NSString *)identity alias:(NSString *)alias {
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:identity ? RUINLocalizedString(@"表示名を編集") : RUINLocalizedString(@"ID別の表示名を追加") message:RUINLocalizedString(@"種別は user:、chat:、group:、squareChat: のいずれかです。表示名を空にすると解除します。") preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = RUINLocalizedString(@"種別:MID"); field.text = identity; field.autocorrectionType = UITextAutocorrectionTypeNo; field.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = RUINLocalizedString(@"この端末での表示名"); field.text = alias; }];
    __weak typeof(self) owner = self; __weak UIAlertController *weakPrompt = prompt;
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"キャンセル") style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"保存") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIAlertController *active = weakPrompt; if (!active) return;
        NSString *key = [active.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange colon = [key rangeOfString:@":"]; BOOL valid = colon.location != NSNotFound && NSMaxRange(colon) < key.length;
        if (valid) valid = [@[@"user", @"chat", @"group", @"squareChat"] containsObject:[key substringToIndex:colon.location]];
        if (!valid) { dispatch_async(dispatch_get_main_queue(), ^{ [owner showMessage:RUINLocalizedString(@"種別と識別IDを確認してください。")]; }); return; }
        if (identity && ![identity isEqual:key]) RUINSetLocalName(identity, @"");
        RUINSetLocalName(key, active.textFields[1].text ?: @""); RefreshFeatures(); [owner.tableView reloadData];
    }]];
    [self presentViewController:prompt animated:YES completion:nil];
}
- (void)editThreshold {
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"送信確認の最低人数") message:RUINLocalizedString(@"自分を含むグループ人数。0は人数指定なし。") preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) { field.keyboardType = UIKeyboardTypeNumberPad; field.text = [NSString stringWithFormat:@"%ld", (long)[NSUserDefaults.standardUserDefaults integerForKey:RUINConfirmSendMinimumGroupMemberCountDefaultsKey]]; }];
    __weak typeof(self) owner = self; __weak UIAlertController *weakPrompt = prompt;
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"キャンセル") style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"保存") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *text = weakPrompt.textFields.firstObject.text ?: @"";
        if (!text.length || [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet].location != NSNotFound || text.length > 6) { dispatch_async(dispatch_get_main_queue(), ^{ [owner showMessage:RUINLocalizedString(@"0以上の人数を入力してください。")]; }); return; }
        [NSUserDefaults.standardUserDefaults setInteger:text.integerValue forKey:RUINConfirmSendMinimumGroupMemberCountDefaultsKey]; RefreshFeatures(); [owner.tableView reloadData];
    }]];
    [self presentViewController:prompt animated:YES completion:nil];
}
- (void)editReadExceptions {
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"既読の例外") message:RUINLocalizedString(@"chat:MID または squareChat:MID をカンマ区切りで入力します。空欄で全て解除します。") preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = [[NSUserDefaults.standardUserDefaults arrayForKey:RUINReadExceptionsDefaultsKey] componentsJoinedByString:@","]; field.autocorrectionType = UITextAutocorrectionTypeNo; field.autocapitalizationType = UITextAutocapitalizationTypeNone; }];
    __weak typeof(self) owner = self; __weak UIAlertController *weakPrompt = prompt;
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"キャンセル") style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"保存") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSMutableOrderedSet *keys = [NSMutableOrderedSet orderedSet]; BOOL valid = YES;
        for (NSString *part in [(weakPrompt.textFields.firstObject.text ?: @"") componentsSeparatedByString:@","]) {
            NSString *key = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; if (!key.length) continue;
            NSRange colon = [key rangeOfString:@":"]; if (colon.location == NSNotFound || NSMaxRange(colon) == key.length || ![@[@"chat", @"squareChat"] containsObject:[key substringToIndex:colon.location]]) { valid = NO; break; }
            [keys addObject:key];
        }
        if (!valid) { dispatch_async(dispatch_get_main_queue(), ^{ [owner showMessage:RUINLocalizedString(@"トークの識別IDを確認してください。")]; }); return; }
        [NSUserDefaults.standardUserDefaults setObject:keys.array forKey:RUINReadExceptionsDefaultsKey]; RefreshFeatures(); [owner.tableView reloadData];
    }]];
    [self presentViewController:prompt animated:YES completion:nil];
}
- (void)editStartupTab {
    NSArray *available = RUINAvailableTabs();
    if (!available.count) { [self showMessage:RUINLocalizedString(@"LINEのタブを検出した後に選択できます。")]; return; }
    NSDictionary *titles = RUINTabTitles();
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"起動時に開くタブ") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) owner = self;
    for (NSString *identifier in available) [menu addAction:[UIAlertAction actionWithTitle:titles[identifier] ?: identifier style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [NSUserDefaults.standardUserDefaults setObject:identifier forKey:RUINStartupTabDefaultsKey]; RefreshFeatures(); [owner.tableView reloadData]; }]];
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

void RUINOpenSettingsInLINE(UIViewController *owner) {
    UINavigationController *navigation = owner.navigationController;
    BOOL visibleOwner = NO;
    for (UIViewController *candidate = owner; candidate; candidate = candidate.parentViewController)
        if (candidate == navigation.topViewController) { visibleOwner = YES; break; }
    if (!RUINIsCompatible() || !navigation || !visibleOwner) return;
    RUINSettingsViewController *settings = [[RUINSettingsViewController alloc] initWithCompatibility:YES];
    settings.hidesBottomBarWhenPushed = YES;
    [navigation pushViewController:settings animated:YES];
}

void RUINRefreshRuntimeReport(void) { RUINWriteRuntimeReport(); }

static BOOL RUINPresentSettings(void) {
    if (sSettingsPresentationInFlight || sSettingsNavigationController.presentingViewController) return YES;
    UIWindow *window = RUINForegroundKeyWindow();
    UIViewController *presenter = window.rootViewController;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed)
        presenter = presenter.presentedViewController;
    if (!presenter || presenter.isBeingDismissed) return NO;

    RUINSettingsViewController *root = [[RUINSettingsViewController alloc] initWithCompatibility:RUINIsCompatible()];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:root];
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    navigation.navigationBar.prefersLargeTitles = YES;
    navigation.presentationController.delegate = root;
    sSettingsNavigationController = navigation;
    sSettingsPresentationInFlight = YES;
    [presenter presentViewController:navigation animated:YES completion:^{ sSettingsPresentationInFlight = NO; }];
    return YES;
}

static void RUINMaybeScheduleEnvironmentSettings(void) {
    if (sEnvironmentSettingsPresented || sEnvironmentSettingsScheduled ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        ![NSProcessInfo.processInfo.environment[@"RUIN_SHOW_SETTINGS"] isEqualToString:@"1"]) return;
    sEnvironmentSettingsScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        sEnvironmentSettingsScheduled = NO;
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive && RUINPresentSettings())
            sEnvironmentSettingsPresented = YES;
    });
}

static void RUINApplicationDidBecomeActive(void) {
    if (RUINIsCompatible()) {
        RUINInstallLegacyMessagingConfiguration();
        RUINInstallLocalNotifications();
        RUINInstallLocalAppearance();
        RUINInstallLocalFont();
        RUINInstallNativeMuteSend();
    }
    static BOOL selfTestAttempted;
    if (!selfTestAttempted && [NSProcessInfo.processInfo.environment[@"RUIN_SELF_TEST"] isEqualToString:@"1"]) {
        selfTestAttempted = YES;
        sKeychainSelfTest = RUINKeychainSelfTest();
    }
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        RUINReadControlEnabledDefaultsKey: @NO,
        RUINLocalNamesDefaultsKey: @{}
    }];
    if (RUINIsCompatible()) {
        RUINInstallFeatures();
        RUINInstallReadBoundary();
        RUINInstallNativeEntry();
        RUINInstallSecondaryLogin();
        RUINInstallReadOnReply();
        RUINInstallAutomaticReadGate();
        RUINInstallThemeFeatures();
        RUINInstallThemeStoreDownload();
        RUINInstallThemeStoreImages();
        RUINInstallNativeThemeImages();
        RUINInstallNativeThemeWorkflow();
        RUINInstallThemeStoreWeb();
        RUINInstallInterfaceFeatures();
        RUINInstallConfirmations();
        RUINInstallMessageHistory();
        RUINInstallUnsendRetention();
        RUINInstallUnsendOperation();
        RUINInstallUnsendMarkerUI();
        RUINInstallAgeVerification();
        RUINInstallMenuExtras();
        RUINInstallNativeChatControls();
        InstallRuntimeInspector();
    }
    RUINMaybeScheduleEnvironmentSettings();
    RUINWriteRuntimeReport();
}

__attribute__((constructor)) static void RUINConstructor(void) {
    @autoreleasepool {
        if (RUINIsCompatible()) {
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            if (![defaults objectForKey:RUINLegacyMessagingEnabledDefaultsKey])
                [defaults setBool:[defaults boolForKey:RUINLocalLYPEnabledDefaultsKey]
                    forKey:RUINLegacyMessagingEnabledDefaultsKey];
            RUINInstallSecondaryLogin();
            RUINInstallClientVersionAdvertisement();
            RUINInstallCompatibility();
            RUINInstallKeychainCompatibility();
            RUINInstallLegacyMessagingConfiguration();
            RUINInstallLocalFont();
            RUINInstallLocalFontHooks();
            RUINInstallLocalNotificationLaunchBoundary();
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"RUINMessageMarkdownEnabled"];
            RUINPrepareNativeReadRangeProbe();
            RUINInstallFeatures();
            RUINInstallReadBoundary();
            RUINInstallReadOnReply();
            // Native theme validation and range decoding can run before the
            // application becomes active. Install their data hooks now; the
            // visible management screens still initialize on the normal path.
            RUINInstallThemeFeatures();
            RUINInstallNativeThemeRegistrationCapture();
            RUINInstallMessageHistory();
            RUINInstallReadUsersEvents();
            InstallRuntimeInspector();
            RUINInstallAutomaticReadGate();
            RUINInstallNativeEntry();
            RUINInstallNativeTabAvailability();
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSLog(@"RUIN loaded");
            sActiveObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                                object:nil queue:NSOperationQueue.mainQueue
                                                                           usingBlock:^(NSNotification *notification) {
                (void)notification;
                RUINApplicationDidBecomeActive();
            }];

        });
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) RUINApplicationDidBecomeActive();
    });
}
