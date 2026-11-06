%config(generator=internal);

#import "LocalFont.h"
#import "LocalFontUI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface RUINLocalFontViewController : UITableViewController <UIDocumentPickerDelegate>
@end

@implementation RUINLocalFontViewController
- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"カスタムフォント";
}
- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return 2;
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"OTF/TTFファイルを適用します。変更後はトークを開き直すか、アプリを再起動してください。";
}
- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = path.row == 0 ? @"フォントを選択" : @"標準に戻す";
    if (path.row == 0) {
        cell.detailTextLabel.text = RUINLocalFontName() ?: @"標準フォント";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)showResult:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"カスタムフォント"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    [self.tableView reloadData];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.row == 1) {
        RUINResetLocalFont();
        [self showResult:@"標準フォントに戻しました。トークを開き直してください。"];
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
    [controller dismissViewControllerAnimated:YES completion:^{
        [self showResult:imported ? @"フォントを適用しました。トークを開き直してください。" :
            @"フォントを読み込めませんでした。OTF/TTFファイルを確認してください。"];
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

static atomic_uint_fast64_t sFontReplacements;
static _Thread_local BOOL sReplacingFont;

static UIFont *RUINReplaceTextFont(UIFont *original, void *caller) {
    Dl_info image;
    if (!original || sReplacingFont || !dladdr(caller, &image) ||
        image.dli_fbase != _dyld_get_image_header(0)) return original;
    sReplacingFont = YES;
    UIFont *replacement = RUINLocalFontAtSize(original.pointSize);
    sReplacingFont = NO;
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
    if (!RUINIsSystemTextFont(original)) return original;
    return RUINReplaceTextFont(original, __builtin_return_address(0));
}
+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    UIFont *original = %orig;
    // Named icon/symbol fonts retain their own glyphs. LINE's basic text font
    // uses the system descriptor; only direct calls from LINE are replaced.
    if (!RUINIsSystemTextFont(original)) return original;
    return RUINReplaceTextFont(original, __builtin_return_address(0));
}
%end
%end

void RUINInstallLocalFontHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ %init(RUINLocalTextFont); });
}

NSDictionary *RUINLocalFontHookDiagnostics(void) {
    return @{@"factoryReplacements":@(atomic_load(&sFontReplacements)),
        @"scope":@"LINE system text font factories", @"namedIconFontsReplaced":@NO};
}
