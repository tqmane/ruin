#import "ThemeUI.h"
#import "ThemeFeatures.h"
#import "ThemeShop.h"
#import "ThemeVersion.h"
#import "ThemeStoreResolver.h"
#import "NativeThemeWorkflow.h"

// Main-queue state keeps an in-progress UI download visible after reopening.
static NSNotificationName const RUINThemeUIDownloadChanged = @"app.ruin.themeui.downloadChanged";
static BOOL gThemeUIDownloading;
static BOOL gThemeUIDownloadSaved;
static NSString *gThemeUIDownloadName;
static NSError *gThemeUIDownloadError;

static NSString *RUINThemeUIString(id value)
{
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return @"";
}

static BOOL RUINThemeUIFlag(id value)
{
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

static NSString *RUINThemeUIName(NSDictionary *record)
{
    NSString *name = RUINThemeUIString(record[@"name"]);
    if (!name.length) name = RUINThemeUIString(record[@"productID"]);
    if (!name.length) name = @"名前のない着せかえ";
    if (name.length > 256) name = [name substringWithRange:[name rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 256)]];
    return name;
}

static NSString *RUINThemeUIVersion(NSDictionary *record)
{
    NSString *version = RUINThemeUIString(record[@"versionString"]);
    if (!version.length) version = RUINThemeUIString(record[@"version"]);
    return version.length ? version : @"未確認";
}

static NSURL *RUINThemeUIArchiveURL(NSDictionary *record)
{
    id value = record[@"packageURL"];
    NSURL *url = [value isKindOfClass:[NSURL class]] ? value : nil;
    return RUINThemeUIFlag(record[@"downloadedLocally"]) &&
        RUINThemeUIFlag(record[@"archiveStructureValidated"]) && url.isFileURL &&
        [url.pathExtension.lowercaseString isEqualToString:@"linetheme"] ? url : nil;
}

static NSString *RUINThemeUINativeStatus(NSDictionary *record)
{
    if (RUINThemeUIFlag(record[@"owned"])) return @"保有";
    if (RUINThemeUIFlag(record[@"grantedByDefault"])) return @"標準で利用可能";
    NSDate *expiry = [record[@"validUntil"] isKindOfClass:[NSDate class]] ? record[@"validUntil"] : nil;
    if (expiry) return expiry.timeIntervalSinceNow > 0 ? @"利用期限内" : @"利用期限切れの記録";
    return @"利用状況は未確認";
}

static NSError *RUINThemeUIError(NSString *message)
{
    return [NSError errorWithDomain:RUINThemeErrorDomain code:RUINThemeErrorNativeAPIUnavailable
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *RUINThemeUIInputError(NSString *name, NSString *productID, NSString *version)
{
    if (!name.length) return @"名前を入力してください。";
    if (name.length > 256 || [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return @"名前は改行を含めず、256文字以内で入力してください。";
    if (productID.length < 6 || productID.length > 128)
        return @"商品IDは6〜128文字で入力してください。";
    for (NSUInteger i = 0; i < productID.length; i++) {
        unichar c = [productID characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
              (c >= 'A' && c <= 'Z') || c == '-' || c == '_' || c == '.'))
            return @"商品IDには半角英数字・ハイフン・アンダースコア・ピリオドを使えます。";
    }
    if (!RUINThemeDownloadVersion(version)) return @"バージョン（例：V1.30）または配信番号を入力してください。";
    return nil;
}

static NSString *RUINThemeUITrim(NSString *value)
{
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

@interface RUINThemeSettingsViewController : UITableViewController <UIDocumentInteractionControllerDelegate>
@property(nonatomic, copy) NSArray<NSDictionary *> *archives;
@property(nonatomic, copy) NSArray<NSDictionary *> *nativeRecords;
@property(nonatomic) BOOL catalogAvailable;
@property(nonatomic) BOOL nativeCatalogAvailable;
@property(nonatomic) BOOL downloadAvailable;
@property(nonatomic) BOOL catalogLoading;
@property(nonatomic) BOOL catalogReloadRequested;
@property(nonatomic) BOOL hasCatalog;
@property(nonatomic) BOOL checkingArchive;
@property(nonatomic, strong) NSError *catalogError;
@property(nonatomic, weak) UIAlertController *downloadPrompt;
@property(nonatomic, weak) UIAlertAction *downloadSubmitAction;
@property(nonatomic, strong) UIDocumentInteractionController *documentController;
@end

@implementation RUINThemeSettingsViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _archives = @[];
        _nativeRecords = @[];
        self.title = @"着せかえ";
        self.hidesBottomBarWhenPushed = YES;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadCatalog)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"着せかえ一覧を更新";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 76;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadCatalog) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(downloadStateChanged:)
        name:RUINThemeUIDownloadChanged object:nil];
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAvailability];
    [self reloadCatalog];
}

- (void)updateAvailability
{
    NSDictionary *diagnostics = RUINThemeDiagnostics();
    NSDictionary *operations = diagnostics[@"operations"];
    self.catalogAvailable = RUINThemeUIFlag(operations[@"localCatalog"][@"available"]);
    self.downloadAvailable = RUINThemeUIFlag(operations[@"manualDownload"][@"available"]);
    self.nativeCatalogAvailable = RUINThemeUIFlag(diagnostics[@"metadataEvidence"][@"nativeCoreDataCatalog"][@"catalogRuntimeAvailable"]);
}

- (BOOL)canDownload
{
    return self.downloadAvailable && !gThemeUIDownloading && !self.checkingArchive &&
        [NSUserDefaults.standardUserDefaults boolForKey:RUINThemeShopDownloadEnabledDefaultsKey];
}

- (BOOL)hasDownloadStatus
{
    return gThemeUIDownloading || gThemeUIDownloadSaved || gThemeUIDownloadError || self.checkingArchive;
}

- (BOOL)isVisible
{
    return self.viewIfLoaded.window && self.navigationController.topViewController == self &&
        !self.presentedViewController;
}

- (void)reloadRows
{
    self.navigationItem.rightBarButtonItem.enabled = !self.catalogLoading && !self.checkingArchive;
    [self.tableView reloadData];
}

- (void)reloadCatalog
{
    if (self.catalogLoading) {
        self.catalogReloadRequested = YES;
        return;
    }
    [self updateAvailability];
    if (!self.catalogAvailable) {
        self.catalogError = RUINThemeUIError(@"このLINEバージョンでは着せかえ一覧を取得できません。");
        [self.refreshControl endRefreshing];
        [self reloadRows];
        return;
    }
    self.catalogLoading = YES;
    [self reloadRows];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSArray<NSDictionary *> *catalog = RUINThemeCatalog(&error);
            NSMutableArray *archives = [NSMutableArray array];
            NSMutableArray *nativeRecords = [NSMutableArray array];
            for (NSDictionary *record in catalog) {
                if (RUINThemeUIArchiveURL(record)) [archives addObject:record];
                else if ([record[@"sourceEntity"] isEqual:@"OwnedThemeProduct"]) [nativeRecords addObject:record];
            }
            NSError *resultError = catalog ? nil : (error ?: RUINThemeUIError(@"着せかえ一覧を取得できませんでした。"));
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) owner = weakSelf;
                if (!owner) return;
                owner.catalogLoading = NO;
                owner.catalogError = resultError;
                if (catalog) {
                    owner.archives = archives;
                    owner.nativeRecords = nativeRecords;
                    owner.hasCatalog = YES;
                }
                [owner.refreshControl endRefreshing];
                [owner reloadRows];
                if (owner.catalogReloadRequested) {
                    owner.catalogReloadRequested = NO;
                    [owner reloadCatalog];
                }
            });
        }
    });
}

- (void)downloadStateChanged:(NSNotification *)notification
{
    [self reloadRows];
    if ([notification.userInfo[@"finished"] boolValue] && gThemeUIDownloadSaved) [self reloadCatalog];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) return 3 + (self.hasDownloadStatus ? 1 : 0) + (self.catalogError ? 1 : 0);
    if (section == 3) return 1;
    return MAX((NSInteger)(section == 1 ? self.archives.count : self.nativeRecords.count), 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == 0) return @"ダウンロード";
    if (section == 1) return [NSString stringWithFormat:@"保存済みファイル（%lu）", (unsigned long)self.archives.count];
    if (section == 3) return @"着せかえショップ";
    return [NSString stringWithFormat:@"LINEの着せかえ記録（%lu）", (unsigned long)self.nativeRecords.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == 3) return nil;
    if (section == 0) {
        if (!self.downloadAvailable) return @"このLINEバージョンでは、この画面からのダウンロードを利用できません。";
        return @"ストアURLから着せかえ情報を取得してダウンロードできます。名前・商品ID・バージョンの手入力も可能です。";
    }
    NSString *note = section == 1
        ? @"ダウンロードした着せかえは、マイ着せかえを開くと一覧に表示されます。選択して適用できます。"
        : (self.nativeCatalogAvailable
            ? @"LINEが保存している記録です。現在の適用状態とファイルの存在は確認していません。"
            : @"この環境ではLINEの着せかえ記録を取得できません。");
    if (self.catalogError && self.hasCatalog)
        note = [note stringByAppendingString:@"\n一覧の更新に失敗しました。前回取得した内容を表示しています。"];
    return note;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ThemeRow"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ThemeRow"];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.detailTextLabel.text = nil;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = YES;
    BOOL spinning = NO;

    if (path.section == 0 && path.row == 0) {
        cell.textLabel.text = @"着せかえのダウンロードを有効にする";
        UISwitch *toggle = [UISwitch new];
        toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:RUINThemeShopDownloadEnabledDefaultsKey];
        toggle.enabled = self.downloadAvailable && !gThemeUIDownloading;
        toggle.accessibilityLabel = cell.textLabel.text;
        [toggle addTarget:self action:@selector(downloadEnabledChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else if (path.section == 0 && path.row == 1) {
        cell.textLabel.text = @"ストアURLからダウンロード";
        cell.detailTextLabel.text = @"ストアURLから名前・商品ID・バージョンを取得";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.userInteractionEnabled = self.canDownload;
        cell.textLabel.textColor = self.canDownload ? UIColor.labelColor : UIColor.secondaryLabelColor;
        cell.selectionStyle = self.canDownload ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else if (path.section == 0 && path.row == 2) {
        cell.textLabel.text = @"名前・商品ID・バージョンを指定";
        cell.detailTextLabel.text = @"手動でファイルをダウンロード";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.userInteractionEnabled = self.canDownload;
        cell.textLabel.textColor = self.canDownload ? UIColor.labelColor : UIColor.secondaryLabelColor;
        cell.selectionStyle = self.canDownload ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else if (path.section == 0 && self.catalogError && path.row == 3 + (self.hasDownloadStatus ? 1 : 0)) {
        cell.textLabel.text = @"一覧を更新できませんでした";
        cell.detailTextLabel.text = @"タップして理由を確認";
        cell.textLabel.textColor = UIColor.systemRedColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (path.section == 0) {
        spinning = gThemeUIDownloading || self.checkingArchive;
        if (gThemeUIDownloading) {
            cell.textLabel.text = @"ダウンロード・ファイル確認中…";
            cell.detailTextLabel.text = gThemeUIDownloadName;
        } else if (self.checkingArchive) cell.textLabel.text = @"ファイルを確認中…";
        else if (gThemeUIDownloadError) {
            cell.textLabel.text = @"ダウンロードを完了できませんでした";
            cell.detailTextLabel.text = @"タップして理由を確認";
            cell.textLabel.textColor = UIColor.systemRedColor;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            cell.textLabel.text = @"ファイルを保存しました";
            cell.detailTextLabel.text = gThemeUIDownloadName;
        }
    } else if (path.section == 3) {
        cell.textLabel.text = @"LINEの着せかえショップを開く";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        NSArray<NSDictionary *> *records = path.section == 1 ? self.archives : self.nativeRecords;
        if (records.count) {
            NSDictionary *record = records[path.row];
            cell.textLabel.text = RUINThemeUIName(record);
            cell.detailTextLabel.text = [NSString stringWithFormat:@"商品ID: %@\nバージョン: %@%@",
                RUINThemeUIString(record[@"productID"]), RUINThemeUIVersion(record),
                path.section == 2 ? [@" · " stringByAppendingString:RUINThemeUINativeStatus(record)] : @""];
            cell.accessoryType = path.section == 1 ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryDetailButton;
            cell.userInteractionEnabled = path.section == 2 || (!gThemeUIDownloading && !self.checkingArchive);
            cell.selectionStyle = cell.userInteractionEnabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        } else {
            spinning = self.catalogLoading;
            if (self.catalogLoading) cell.textLabel.text = @"一覧を読み込み中…";
            else if (self.catalogError) {
                cell.textLabel.text = @"一覧を取得できませんでした";
                cell.detailTextLabel.text = @"タップして理由を確認";
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            } else if (path.section == 2 && !self.nativeCatalogAvailable) cell.textLabel.text = @"LINEの着せかえ記録を取得できません";
            else cell.textLabel.text = path.section == 1 ? @"保存済みファイルはありません" : @"着せかえ記録はありません";
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
        }
    }
    if (spinning) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        indicator.accessibilityLabel = @"処理中";
        [indicator startAnimating];
        cell.accessoryView = indicator;
    }
    return cell;
}

- (void)downloadEnabledChanged:(UISwitch *)toggle
{
    [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:RUINThemeShopDownloadEnabledDefaultsKey];
    [self reloadRows];
}

- (void)showMessage:(NSString *)message title:(NSString *)title
{
    if (!self.isVisible) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSError *)error title:(NSString *)title
{
    NSString *message = error.localizedDescription ?: @"処理を完了できませんでした。";
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorNotConnectedToInternet: message = @"インターネットに接続されていません。接続を確認して、もう一度お試しください。"; break;
            case NSURLErrorTimedOut: message = @"通信がタイムアウトしました。時間をおいて、もう一度お試しください。"; break;
            case NSURLErrorNetworkConnectionLost: message = @"通信が途中で切断されました。接続を確認して、もう一度お試しください。"; break;
            case NSURLErrorCancelled: message = @"通信が中止されました。"; break;
            default: break;
        }
    }
    [self showMessage:message title:title];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path
{
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 3) { RUINOpenThemeShop(self); return; }
    if (path.section == 0) {
        if (path.row == 1) [self showStoreURLPrompt];
        else if (path.row == 2) [self showDownloadPrompt];
        else if (self.catalogError && path.row == 3 + (self.hasDownloadStatus ? 1 : 0)) [self showError:self.catalogError title:@"一覧を更新できませんでした"];
        else if (path.row == 3 && gThemeUIDownloadError && !gThemeUIDownloading && !self.checkingArchive)
            [self showError:gThemeUIDownloadError title:@"ダウンロードを完了できませんでした"];
        return;
    }
    NSArray<NSDictionary *> *records = path.section == 1 ? self.archives : self.nativeRecords;
    if (!records.count) {
        if (self.catalogError && !self.catalogLoading) [self showError:self.catalogError title:@"一覧を取得できませんでした"];
        return;
    }
    NSDictionary *record = records[path.row];
    if (path.section == 2) [self showNativeRecord:record];
    else if (!gThemeUIDownloading && !self.checkingArchive) [self showArchiveActions:record atIndexPath:path];
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)path
{
    if (path.section == 2 && (NSUInteger)path.row < self.nativeRecords.count) [self showNativeRecord:self.nativeRecords[path.row]];
}

- (void)showNativeRecord:(NSDictionary *)record
{
    [self showMessage:[NSString stringWithFormat:@"商品ID: %@\nバージョン: %@\n%@\n\nLINEの保存記録です。現在の適用状態は確認していません。",
        RUINThemeUIString(record[@"productID"]), RUINThemeUIVersion(record), RUINThemeUINativeStatus(record)]
        title:RUINThemeUIName(record)];
}

- (void)showStoreURLPrompt
{
    if (!self.canDownload) return;
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"ストアURLからダウンロード"
        message:@"LINE STOREの着せかえURLを入力してください。" preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://store.line.me/themeshop/product/…";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak UIAlertController *weakPrompt = prompt;
    [prompt addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *download = [UIAlertAction actionWithTitle:@"ダウンロード" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *URLText = RUINThemeUITrim(weakPrompt.textFields.firstObject.text);
        if (!RUINValidatedThemeStoreURL(URLText)) {
            [self showMessage:@"正しいLINE STOREの着せかえURLを入力してください。" title:@"ダウンロードを開始できませんでした"];
            return;
        }
        gThemeUIDownloading = YES;
        gThemeUIDownloadSaved = NO;
        gThemeUIDownloadError = nil;
        gThemeUIDownloadName = @"ストア情報を取得中…";
        [NSNotificationCenter.defaultCenter postNotificationName:RUINThemeUIDownloadChanged object:nil];
        RUINResolveThemeStoreURL(URLText, ^(NSDictionary<NSString *, NSString *> *theme, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                gThemeUIDownloading = NO;
                if (error || !theme) {
                    gThemeUIDownloadError = RUINThemeUIError(@"ストア情報を取得できませんでした。URLと通信状況を確認してください。");
                    [NSNotificationCenter.defaultCenter postNotificationName:RUINThemeUIDownloadChanged object:nil];
                    [self showError:gThemeUIDownloadError title:@"ダウンロードを開始できませんでした"];
                } else [self startDownloadWithName:theme[@"name"] productID:theme[@"productID"] version:theme[@"version"]];
            });
        });
    }];
    download.enabled = NO;
    __weak UITextField *weakField = prompt.textFields.firstObject;
    [weakField addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        download.enabled = RUINValidatedThemeStoreURL(RUINThemeUITrim(weakField.text)) != nil;
    }] forControlEvents:UIControlEventEditingChanged];
    [prompt addAction:download];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (void)showDownloadPrompt
{
    if (!self.canDownload) return;
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"着せかえファイルをダウンロード"
        message:@"名前・商品ID・バージョン番号を入力してください。" preferredStyle:UIAlertControllerStyleAlert];
    NSArray<NSString *> *placeholders = @[@"名前", @"商品ID", @"バージョン（例：V1.30）"];
    for (NSUInteger i = 0; i < placeholders.count; i++) {
        [prompt addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = placeholders[i];
            field.accessibilityLabel = placeholders[i];
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.keyboardType = i > 0 ? UIKeyboardTypeASCIICapable : UIKeyboardTypeDefault;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
            [field addTarget:self action:@selector(downloadFieldsChanged:) forControlEvents:UIControlEventEditingChanged];
        }];
    }
    [prompt addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakPrompt = prompt;
    UIAlertAction *download = [UIAlertAction actionWithTitle:@"ダウンロード" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIAlertController *active = weakPrompt;
        if (active.textFields.count != 3) return;
        [weakSelf startDownloadWithName:RUINThemeUITrim(active.textFields[0].text)
            productID:RUINThemeUITrim(active.textFields[1].text) version:RUINThemeUITrim(active.textFields[2].text)];
    }];
    [prompt addAction:download];
    self.downloadPrompt = prompt;
    self.downloadSubmitAction = download;
    [self downloadFieldsChanged:nil];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (void)downloadFieldsChanged:(UITextField *)field
{
    NSArray<UITextField *> *fields = self.downloadPrompt.textFields;
    if (fields.count != 3) return;
    NSString *error = RUINThemeUIInputError(RUINThemeUITrim(fields[0].text), RUINThemeUITrim(fields[1].text), RUINThemeUITrim(fields[2].text));
    self.downloadSubmitAction.enabled = !error && self.canDownload;
    self.downloadPrompt.message = error ?: @"ファイルを取得して保存します。LINEへの追加・適用はこの操作では行いません。";
}

- (void)startDownloadWithName:(NSString *)name productID:(NSString *)productID version:(NSString *)version
{
    [self updateAvailability];
    NSString *inputError = RUINThemeUIInputError(name, productID, version);
    if (!self.canDownload || inputError) {
        [self showMessage:inputError ?: @"ダウンロード設定と現在の処理状況を確認してください。" title:@"ダウンロードを開始できませんでした"];
        return;
    }
    gThemeUIDownloading = YES;
    gThemeUIDownloadSaved = NO;
    gThemeUIDownloadName = [name copy];
    gThemeUIDownloadError = nil;
    [NSNotificationCenter.defaultCenter postNotificationName:RUINThemeUIDownloadChanged object:nil];
    __weak typeof(self) weakSelf = self;
    RUINDownloadThemeByID(name, productID, version, ^(NSURL *packageURL, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            gThemeUIDownloading = NO;
            BOOL localArchive = packageURL.isFileURL && [packageURL.pathExtension.lowercaseString isEqualToString:@"linetheme"];
            gThemeUIDownloadError = error ?: (localArchive ? nil : RUINThemeUIError(@"保存済みファイルの場所を確認できませんでした。"));
            gThemeUIDownloadSaved = !gThemeUIDownloadError;
            [NSNotificationCenter.defaultCenter postNotificationName:RUINThemeUIDownloadChanged object:nil userInfo:@{@"finished": @YES}];
            if (gThemeUIDownloadError) [weakSelf showError:gThemeUIDownloadError title:@"ダウンロードを完了できませんでした"];
            else if (weakSelf.isVisible) {
                UIAlertController *saved = [UIAlertController alertControllerWithTitle:@"保存完了"
                    message:@"ファイルを保存しました。マイ着せかえを開いて、着せかえを選択して適用できます。"
                    preferredStyle:UIAlertControllerStyleAlert];
                [saved addAction:[UIAlertAction actionWithTitle:@"マイ着せかえを開く" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    RUINOpenDownloadedThemes(weakSelf);
                }]];
                [saved addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
                [weakSelf presentViewController:saved animated:YES completion:nil];
            }
        });
    });
}

- (CGRect)menuRect:(CGRect)rect
{
    CGRect visible = CGRectIntersection(rect, self.tableView.bounds);
    return CGRectIsNull(visible) || CGRectIsEmpty(visible)
        ? CGRectMake(CGRectGetMidX(self.tableView.bounds), CGRectGetMidY(self.tableView.bounds), 1, 1) : visible;
}

- (void)showArchiveActions:(NSDictionary *)record atIndexPath:(NSIndexPath *)path
{
    if (!RUINThemeUIArchiveURL(record)) return;
    CGRect rect = [self.tableView rectForRowAtIndexPath:path];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:RUINThemeUIName(record)
        message:@"LINEのマイ着せかえに追加すると、選択して適用できます。"
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [menu addAction:[UIAlertAction actionWithTitle:@"マイ着せかえに追加" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        RUINOpenDownloadedThemes(weakSelf);
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"プレビュー" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf openArchive:record preview:YES anchorRect:rect];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"共有・ほかのアプリで開く" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf openArchive:record preview:NO anchorRect:rect];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = self.tableView;
    menu.popoverPresentationController.sourceRect = [self menuRect:rect];
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)openArchive:(NSDictionary *)record preview:(BOOL)preview anchorRect:(CGRect)rect
{
    NSURL *requestedURL = RUINThemeUIArchiveURL(record);
    if (!requestedURL || self.checkingArchive || gThemeUIDownloading) return;
    self.checkingArchive = YES;
    [self reloadRows];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSArray<NSDictionary *> *catalog = RUINThemeCatalog(&error);
            NSURL *verifiedURL = nil;
            for (NSDictionary *candidate in catalog) {
                NSURL *url = RUINThemeUIArchiveURL(candidate);
                if (url && [url.path isEqualToString:requestedURL.path]) { verifiedURL = url; break; }
            }
            NSError *resultError = verifiedURL ? nil : (error ?: RUINThemeUIError(@"ファイルが見つからないか、ファイルの構造確認に失敗しました。一覧を更新してください。"));
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) owner = weakSelf;
                if (!owner) return;
                owner.checkingArchive = NO;
                [owner reloadRows];
                if (!owner.isVisible) return;
                if (resultError) { [owner showError:resultError title:@"ファイルを開けませんでした"]; return; }
                UIDocumentInteractionController *document = [UIDocumentInteractionController interactionControllerWithURL:verifiedURL];
                document.delegate = owner;
                document.UTI = @"jp.naver.talk.theme-package";
                owner.documentController = document;
                BOOL presented = preview ? [document presentPreviewAnimated:YES]
                    : [document presentOptionsMenuFromRect:[owner menuRect:rect] inView:owner.tableView animated:YES];
                if (!presented) [owner showMessage:preview
                    ? @"このファイルのプレビューには対応していません。共有メニューからファイルを操作できます。"
                    : @"このファイルで利用できる共有先が見つかりませんでした。"
                    title:preview ? @"プレビューを表示できませんでした" : @"共有メニューを表示できませんでした"];
            });
        }
    });
}

- (UIViewController *)documentInteractionControllerViewControllerForPreview:(UIDocumentInteractionController *)controller
{
    return self.navigationController ?: self;
}

@end

void RUINOpenThemeSettings(UIViewController *owner)
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINOpenThemeSettings(owner); });
        return;
    }
    UINavigationController *navigation = [owner isKindOfClass:[UINavigationController class]]
        ? (UINavigationController *)owner : owner.navigationController;
    BOOL visibleOwner = owner == navigation;
    for (UIViewController *candidate = owner; candidate; candidate = candidate.parentViewController) {
        if (candidate == navigation.topViewController) { visibleOwner = YES; break; }
    }
    if (!navigation || !visibleOwner || navigation.presentedViewController ||
        [navigation.topViewController isKindOfClass:[RUINThemeSettingsViewController class]]) return;
    [navigation pushViewController:[RUINThemeSettingsViewController new] animated:YES];
}
