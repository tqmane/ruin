%config(generator=internal);

#import "LocalFont.h"
#import "LocalFontUI.h"
#import "FeatureImage.h"
#import "VersionMapping.h"
#import "../core/Localization.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface RUINLocalFontViewController : UITableViewController <UIDocumentPickerDelegate>
@end

@implementation RUINLocalFontViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = RUINLocalizedString(@"カスタムフォント");
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return 2;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return RUINLocalizedString(@"OTF/TTFファイルを適用します。変更後はトークを開き直すか、アプリを再起動してください。");
}
- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = path.row == 0 ? RUINLocalizedString(@"フォントを選択") : RUINLocalizedString(@"標準に戻す");
    if (path.row == 0) {
        cell.detailTextLabel.text = RUINLocalFontName() ?: RUINLocalizedString(@"標準フォント");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)showResult:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:RUINLocalizedString(@"カスタムフォント")
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:RUINLocalizedString(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    [self.tableView reloadData];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.row == 1) {
        RUINResetLocalFont();
        [self showResult:RUINLocalizedString(@"標準フォントに戻しました。トークを開き直してください。")];
        return;
    }
    UTType *otf = [UTType typeWithFilenameExtension:@"otf"];
    UTType *ttf = [UTType typeWithFilenameExtension:@"ttf"];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[otf ?: UTTypeFont, ttf ?: UTTypeFont] asCopy:YES];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSError *error = nil;
    BOOL imported = urls.count == 1 && RUINImportLocalFont(urls.firstObject, &error);
    if (imported) RUINInstallLocalFontHooks();
    [controller dismissViewControllerAnimated:YES completion:^{
        [self showResult:imported ? RUINLocalizedString(@"フォントを適用しました。トークを開き直してください。") :
            RUINLocalizedString(@"フォントを読み込めませんでした。OTF/TTFファイルを確認してください。")];
    }];
}
@end

void RUINOpenLocalFontSettings(UIViewController *presenter) {
    RUINLocalFontViewController *controller = [RUINLocalFontViewController new];
    [presenter.navigationController pushViewController:controller animated:YES];
}

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <stdatomic.h>
#import <objc/runtime.h>

static atomic_uint_fast64_t sFontReplacements, sFontFactoryCalls, sFontInactiveCalls;
static _Thread_local BOOL sReplacingFont;
static RUINFeatureImage sFontImage;
static _Atomic(const void *) sFontCallerHeader;
static _Atomic(const char *) sFontImageStatus = "notAttempted";

static void RUINRefreshFontCallerImage(void) {
    @synchronized (UIFont.class) {
        if (atomic_load_explicit(&sFontCallerHeader, memory_order_acquire)) return;
        const RUINVersionMapping *version = RUINMappingForInfo(NSBundle.mainBundle.infoDictionary);
        RUINMainExecutableImage native = {0};
        RUINHostIdentity nativeHost = {0};
        NSString *nativeUUID = nil;
        if (!version) {
            // Keep version-independent native UI support. Metadata alone never
            // admits an unknown LC guest: this fallback must remain process-main.
            if (!RUINResolveMainExecutableImage(&native)) {
                atomic_store(&sFontImageStatus, "mappingUnavailable"); return;
            }
            nativeUUID = [[NSUUID alloc] initWithUUIDBytes:native.uuid].UUIDString;
            nativeHost.uuid = nativeUUID.UTF8String;
        }
        RUINFeatureImage image = {0};
        // Prove the original class owner, including LC's MH_EXECUTE rewrite.
        // A successful proof owns its loader reference for the hooks' lifetime.
        if (!RUINResolveFeatureImage(version ? &version->host : &nativeHost,
            objc_getClass("_TtC4LINE11AppDelegate"), &image)) {
            atomic_store(&sFontImageStatus, "ownerImageUnavailable");
            return;
        }
        if (!version && (image.convertedExecutable || image.image.header != native.header)) {
            RUINReleaseFeatureImage(&image);
            atomic_store(&sFontImageStatus, "nativeImageRejected"); return;
        }
        sFontImage = image;
        atomic_store(&sFontImageStatus, "resolved");
        atomic_store_explicit(&sFontCallerHeader, image.image.header, memory_order_release);
    }
}

static UIFont *RUINReplaceTextFont(UIFont *original, void *caller) {
    atomic_fetch_add(&sFontFactoryCalls, 1);
    if (!original || sReplacingFont) return original;
    if (!RUINLocalFontIsRegistered()) { atomic_fetch_add(&sFontInactiveCalls, 1); return original; }
    Dl_info image;
    const void *header = atomic_load_explicit(&sFontCallerHeader, memory_order_acquire);
    if (!header || !dladdr(caller, &image) || image.dli_fbase != header) return original;
    sReplacingFont = YES;
    UIFont *replacement = nil;
    @try { replacement = RUINLocalFontAtSize(original.pointSize); }
    @finally { sReplacingFont = NO; }
    if (replacement) atomic_fetch_add(&sFontReplacements, 1);
    return replacement ?: original;
}

static BOOL RUINIsSystemTextFont(UIFont *font) {
    NSString *name = font.fontName;
    return [name hasPrefix:@".SFUI"] || [name hasPrefix:@".AppleSystem"] ||
        [name hasPrefix:@".Hiragino"] || [font.familyName isEqual:@".AppleSystemUIFont"];
}

%group RUINLocalTextFont
%hook UIFont
+ (UIFont *)systemFontOfSize:(CGFloat)size {
    return RUINReplaceTextFont(%orig, __builtin_return_address(0));
}
+ (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)weight {
    return RUINReplaceTextFont(%orig, __builtin_return_address(0));
}
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size {
    return RUINReplaceTextFont(%orig, __builtin_return_address(0));
}
+ (UIFont *)italicSystemFontOfSize:(CGFloat)size {
    return RUINReplaceTextFont(%orig, __builtin_return_address(0));
}
+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style {
    return RUINReplaceTextFont(%orig, __builtin_return_address(0));
}
+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style compatibleWithTraitCollection:(UITraitCollection *)traits {
    return RUINReplaceTextFont(%orig, __builtin_return_address(0));
}
+ (UIFont *)fontWithName:(NSString *)name size:(CGFloat)size {
    UIFont *original = %orig;
    if (!RUINLocalFontIsRegistered() || !RUINIsSystemTextFont(original)) return original;
    return RUINReplaceTextFont(original, __builtin_return_address(0));
}
+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    UIFont *original = %orig;
    // Named icon/symbol fonts retain their own glyphs. LINE's basic text font
    // uses the system descriptor; only direct calls from LINE are replaced.
    if (!RUINLocalFontIsRegistered() || !RUINIsSystemTextFont(original)) return original;
    return RUINReplaceTextFont(original, __builtin_return_address(0));
}
%end
%end

void RUINInstallLocalFontHooks(void) {
    // One proof attempt per explicit install/activation, never per font call.
    RUINRefreshFontCallerImage();
    static dispatch_once_t once;
    dispatch_once(&once, ^{ %init(RUINLocalTextFont); });
}

NSDictionary *RUINLocalFontHookDiagnostics(void) {
    BOOL ready = atomic_load_explicit(&sFontCallerHeader, memory_order_acquire) != NULL;
    return @{@"factoryCalls":@(atomic_load(&sFontFactoryCalls)), @"inactiveCalls":@(atomic_load(&sFontInactiveCalls)),
        @"factoryReplacements":@(atomic_load(&sFontReplacements)),
        @"callerImageResolution":@(atomic_load(&sFontImageStatus)), @"callerImageProven":@(ready),
        @"callerImageConvertedExecutable":@(ready && sFontImage.convertedExecutable),
        @"callerImageLoaderPinned":@(ready && sFontImage.loaderReference != NULL),
        @"scope":@"LINE system text font factories", @"namedIconFontsReplaced":@NO};
}
