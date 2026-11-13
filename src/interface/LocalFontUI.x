%config(generator=internal);

#import "LocalFont.h"
#import "LocalFontUI.h"
#import "BinaryVerifier.h"
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
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static atomic_uint_fast64_t sFontReplacements;
static _Thread_local BOOL sReplacingFont;
static _Atomic uintptr_t sFontHostTextStart;
static _Atomic uintptr_t sFontHostTextSize;
static os_unfair_lock sFontHostResolveLock = OS_UNFAIR_LOCK_INIT;
static uint32_t sFontHostMissImageCount;

static BOOL RUINResolveFontHostRange(uintptr_t *startOut, uintptr_t *sizeOut) {
    uintptr_t start = atomic_load_explicit(&sFontHostTextStart, memory_order_acquire);
    uintptr_t size = atomic_load_explicit(&sFontHostTextSize, memory_order_relaxed);
    if (start && size) {
        *startOut = start;
        *sizeOut = size;
        return YES;
    }

    RUINMainExecutableImage mainImage;
    if (RUINResolveMainExecutableImage(&mainImage) &&
        RUINImageExecutableTextRange(mainImage.header, &start, &size) && start && size) {
        os_unfair_lock_lock(&sFontHostResolveLock);
        if (!atomic_load_explicit(&sFontHostTextStart, memory_order_relaxed)) {
            atomic_store_explicit(&sFontHostTextSize, size, memory_order_relaxed);
            atomic_store_explicit(&sFontHostTextStart, start, memory_order_release);
        }
        os_unfair_lock_unlock(&sFontHostResolveLock);
        *startOut = start;
        *sizeOut = size;
        return YES;
    }

    uint32_t currentCount = _dyld_image_count();
    os_unfair_lock_lock(&sFontHostResolveLock);
    start = atomic_load_explicit(&sFontHostTextStart, memory_order_relaxed);
    size = atomic_load_explicit(&sFontHostTextSize, memory_order_relaxed);
    if (start && size) {
        os_unfair_lock_unlock(&sFontHostResolveLock);
        *startOut = start;
        *sizeOut = size;
        return YES;
    }
    if (sFontHostMissImageCount == currentCount) {
        os_unfair_lock_unlock(&sFontHostResolveLock);
        return NO;
    }
    os_unfair_lock_unlock(&sFontHostResolveLock);

    // LiveContainer loads LINE as an MH_DYLIB at NSBundle.mainBundle.executablePath.
    // Verify both the canonical bundle executable path and ownership of a core LINE class.
    NSString *execPath = NSBundle.mainBundle.executablePath;
    Class marker = objc_lookUpClass("_TtC4LINE11AppDelegate") ?: objc_lookUpClass("LineShopProductDetail");
    Dl_info markerInfo = {0};
    BOOL matched = NO;
    if (execPath.length && marker && dladdr((__bridge const void *)marker, &markerInfo) &&
        markerInfo.dli_fbase && markerInfo.dli_fname) {
        char *expected = realpath(execPath.fileSystemRepresentation, NULL);
        char *actual = realpath(markerInfo.dli_fname, NULL);
        BOOL samePath = expected && actual && strcmp(expected, actual) == 0;
        free(expected);
        free(actual);
        if (samePath) {
            const struct mach_header_64 *header = markerInfo.dli_fbase;
            if (header->magic == MH_MAGIC_64 &&
                (header->filetype == MH_EXECUTE || header->filetype == MH_DYLIB) &&
                RUINImageExecutableTextRange(header, &start, &size) && start && size) {
                matched = YES;
            }
        }
    }

    os_unfair_lock_lock(&sFontHostResolveLock);
    if (matched) {
        atomic_store_explicit(&sFontHostTextSize, size, memory_order_relaxed);
        atomic_store_explicit(&sFontHostTextStart, start, memory_order_release);
        *startOut = start;
        *sizeOut = size;
    } else if (_dyld_image_count() == currentCount) {
        sFontHostMissImageCount = currentCount;
    }
    os_unfair_lock_unlock(&sFontHostResolveLock);
    return matched;
}

static BOOL RUINFontCallerIsLINE(void *caller) {
    uintptr_t start = 0, size = 0;
    if (!caller || !RUINResolveFontHostRange(&start, &size)) return NO;
    return ((uintptr_t)caller - start) < size;
}

static UIFont *RUINReplaceTextFont(UIFont *original, void *caller) {
    if (!original || sReplacingFont || !RUINLocalFontIsRegistered()) return original;
    if (!RUINFontCallerIsLINE(caller)) return original;
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
    return RUINReplaceTextFont(%orig, __builtin_extract_return_addr(__builtin_return_address(0)));
}
+ (UIFont *)systemFontOfSize:(CGFloat)size weight:(UIFontWeight)weight {
    return RUINReplaceTextFont(%orig, __builtin_extract_return_addr(__builtin_return_address(0)));
}
+ (UIFont *)boldSystemFontOfSize:(CGFloat)size {
    return RUINReplaceTextFont(%orig, __builtin_extract_return_addr(__builtin_return_address(0)));
}
+ (UIFont *)italicSystemFontOfSize:(CGFloat)size {
    return RUINReplaceTextFont(%orig, __builtin_extract_return_addr(__builtin_return_address(0)));
}
+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style {
    return RUINReplaceTextFont(%orig, __builtin_extract_return_addr(__builtin_return_address(0)));
}
+ (UIFont *)preferredFontForTextStyle:(UIFontTextStyle)style compatibleWithTraitCollection:(UITraitCollection *)traits {
    return RUINReplaceTextFont(%orig, __builtin_extract_return_addr(__builtin_return_address(0)));
}
+ (UIFont *)fontWithName:(NSString *)name size:(CGFloat)size {
    UIFont *original = %orig;
    if (!original || sReplacingFont || !RUINLocalFontIsRegistered()) return original;
    if (!RUINIsSystemTextFont(original)) return original;
    return RUINReplaceTextFont(original, __builtin_extract_return_addr(__builtin_return_address(0)));
}
+ (UIFont *)fontWithDescriptor:(UIFontDescriptor *)descriptor size:(CGFloat)size {
    UIFont *original = %orig;
    // Named icon/symbol fonts retain their own glyphs. LINE's basic text font
    // uses the system descriptor; only direct calls from LINE are replaced.
    if (!original || sReplacingFont || !RUINLocalFontIsRegistered()) return original;
    if (!RUINIsSystemTextFont(original)) return original;
    return RUINReplaceTextFont(original, __builtin_extract_return_addr(__builtin_return_address(0)));
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
