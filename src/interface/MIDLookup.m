#import "MIDLookup.h"
#import "LINEPrivateCalls.h"

#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

#if !defined(RUIN_MIDLOOKUP_HOST_CHECK)
#import <UIKit/UIKit.h>
#endif

// Verified LINE26.16.0 / 2026.1006.1718 metadata and disassembly:
// -[_TtC4LINE11AppDelegate openURLForObjC:] B24@0:8@16, IMP 0x100043398.
// The wrapper boxes its NSURL argument with NSURL class metadata (0x1000432dc).
// The binary contains both the exact profile URL and ^nv/profilePopup/mid=.+/?$.
// Invoke the app delegate directly; never dispatch this URL through UIApplication.
// See tools/mid-lookup-evidence.json. No Swift parameter enum/layout is synthesized.
static const char * const RUINMIDDelegateClass = "_TtC4LINE11AppDelegate";
static const char * const RUINMIDRouterSelector = "openURLForObjC:";
static atomic_uint_fast64_t gMIDRequests, gMIDAccepted, gMIDRejected;

static BOOL RUINMIDTargetMatches(NSDictionary *info)
{
    return [info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"] &&
        [info[@"CFBundleShortVersionString"] isEqual:@"26.16.0"] &&
        [info[@"CFBundleVersion"] isEqual:@"2026.1006.1718"];
}

static NSURL *RUINMIDURL(id input)
{
    if (![input isKindOfClass:NSString.class] || [input length] > 128) return nil;
    NSString *mid = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (mid.length != 33 || [mid characterAtIndex:0] != 'u') return nil;
    for (NSUInteger index = 1; index < mid.length; index++) {
        unichar c = [mid characterAtIndex:index];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return nil;
    }
    return [NSURL URLWithString:[@"line://nv/profilePopup/mid=" stringByAppendingString:mid]];
}

static BOOL RUINMIDRouterAvailable(id delegate)
{
    Class cls = objc_getClass(RUINMIDDelegateClass);
    if (!cls || !delegate || object_getClass(delegate) != cls) return NO;
    Method method = class_getInstanceMethod(cls, sel_registerName(RUINMIDRouterSelector));
    const char *types = method ? method_getTypeEncoding(method) : NULL;
    return types && strcmp(types, "B24@0:8@16") == 0 && method_getImplementation(method) != NULL;
}

// Fixed status codes only; neither exceptions nor user input enter diagnostics.
static NSString *RUINMIDDispatch(id input, id delegate, NSDictionary *info)
{
    NSURL *url = RUINMIDURL(input);
    if (!url) return @"invalid_mid";
    if (!RUINMIDTargetMatches(info)) return @"version_gated";
    if (!RUINMIDRouterAvailable(delegate)) return @"native_router_unavailable_or_abi_mismatch";
    atomic_fetch_add(&gMIDRequests, 1);
    @try {
        BOOL accepted = [(id<RUINLINEAppDelegateCalls>)delegate openURLForObjC:url];
        atomic_fetch_add(accepted ? &gMIDAccepted : &gMIDRejected, 1);
        return accepted ? @"native_route_accepted" : @"native_route_rejected";
    } @catch (__unused NSException *exception) {
        atomic_fetch_add(&gMIDRejected, 1);
        return @"native_router_exception";
    }
}

NSDictionary<NSString *, id> *RUINMIDLookupDiagnostics(void)
{
    NSMutableDictionary *result = [@{
        @"targetMatches": @(RUINMIDTargetMatches(NSBundle.mainBundle.infoDictionary)),
        @"requests": @(atomic_load(&gMIDRequests)),
        @"nativeRouteAccepted": @(atomic_load(&gMIDAccepted)),
        @"nativeRouteRejected": @(atomic_load(&gMIDRejected)),
        @"profileLookupVerified": @NO
    } mutableCopy];
#if !defined(RUIN_MIDLOOKUP_HOST_CHECK)
    if (NSThread.isMainThread) {
        result[@"nativeRouterAvailable"] = @(RUINMIDRouterAvailable(UIApplication.sharedApplication.delegate));
    } else {
        result[@"nativeRouterStatus"] = @"main_thread_check_required";
    }
#endif
    return result;
}

#if !defined(RUIN_MIDLOOKUP_HOST_CHECK)

@interface RUINMIDLookupController : UIViewController <UITextFieldDelegate>
@property(nonatomic, strong) UITextField *midField;
@property(nonatomic, strong) UIButton *lookupButton;
@property(nonatomic, strong) UILabel *statusLabel;
@end

@implementation RUINMIDLookupController
- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"MID検索";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *explanation = [UILabel new];
    explanation.text = @"確認したいユーザーのMIDを1件入力してください。MIDは「u」で始まる33文字の識別子です。LINE IDとは異なります。";
    explanation.numberOfLines = 0;
    explanation.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    explanation.adjustsFontForContentSizeCategory = YES;
    self.midField = [UITextField new];
    self.midField.placeholder = @"MID（u＋32桁の半角英数字）";
    self.midField.accessibilityLabel = @"検索するMID";
    self.midField.borderStyle = UITextBorderStyleRoundedRect;
    self.midField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.midField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.midField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.midField.smartQuotesType = UITextSmartQuotesTypeNo;
    self.midField.smartDashesType = UITextSmartDashesTypeNo;
    self.midField.keyboardType = UIKeyboardTypeASCIICapable;
    self.midField.returnKeyType = UIReturnKeySearch;
    self.midField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.midField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.midField.adjustsFontForContentSizeCategory = YES;
    self.midField.delegate = self;
    [self.midField addTarget:self action:@selector(inputChanged) forControlEvents:UIControlEventEditingChanged];
    self.lookupButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.lookupButton.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [self.lookupButton setTitle:@"プロフィールを表示" forState:UIControlStateNormal];
    [self.lookupButton addTarget:self action:@selector(lookup) forControlEvents:UIControlEventTouchUpInside];
    self.statusLabel = [UILabel new];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.text = @"検索するとLINE内でプロフィールを開きます。友だち追加やメッセージ送信は行いません。";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        explanation, self.midField, self.lookupButton, self.statusLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
        [self.midField.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [self.lookupButton.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];
    [self inputChanged];
}
- (void)inputChanged
{
    self.lookupButton.enabled = RUINMIDURL(self.midField.text) != nil;
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    (void)textField;
    [self lookup];
    return NO;
}
- (void)lookup
{
    if (!RUINMIDURL(self.midField.text)) {
        self.statusLabel.text = @"「u」に続く32桁の半角数字・a〜f（小文字）を入力してください。";
        return;
    }
    if (self.navigationController.topViewController != self || self.presentedViewController) return;
    [self.view endEditing:YES];
    NSString *input = self.midField.text;
    self.midField.text = @""; // Do not retain the submitted identifier in the search screen.
    [self inputChanged];
    NSString *result = RUINMIDDispatch(input, UIApplication.sharedApplication.delegate, NSBundle.mainBundle.infoDictionary);
    if ([result isEqualToString:@"native_route_accepted"]) {
        self.statusLabel.text = @"LINEにプロフィール表示を要求しました。見つからない場合や表示できない場合は、MIDと通信状態を確認してください。";
    } else {
        self.statusLabel.text = [result isEqualToString:@"version_gated"] || [result isEqualToString:@"native_router_unavailable_or_abi_mismatch"]
            ? @"お使いのLINEのバージョンではMID検索を利用できません。"
            : @"プロフィールを開けませんでした。MIDと通信状態を確認し、もう一度お試しください。";
    }
}
@end

void RUINOpenMIDLookup(UIViewController *source)
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINOpenMIDLookup(source); });
        return;
    }
    UINavigationController *nav = [source isKindOfClass:UINavigationController.class]
        ? (UINavigationController *)source : source.navigationController;
    if (!nav || nav.presentedViewController || nav.transitionCoordinator ||
        [nav.topViewController isKindOfClass:RUINMIDLookupController.class]) return;
    [nav pushViewController:[RUINMIDLookupController new] animated:YES];
}

void RUINOpenMIDProfile(UIViewController *source, NSString *mid)
{
    if (!NSThread.isMainThread) {
        NSString *copied = [mid copy];
        dispatch_async(dispatch_get_main_queue(), ^{ RUINOpenMIDProfile(source, copied); });
        return;
    }
    if (!source.viewIfLoaded.window || source.presentedViewController ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSString *result = RUINMIDDispatch(mid, UIApplication.sharedApplication.delegate, NSBundle.mainBundle.infoDictionary);
    if ([result isEqual:@"native_route_accepted"]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"プロフィールを開けませんでした"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    [source presentViewController:alert animated:YES completion:nil];
}

#else
#import <assert.h>
static NSUInteger testCalls;
static BOOL RUINMIDTestRouter(id self, SEL command, NSURL *url)
{
    (void)self; (void)command;
    assert([url isKindOfClass:NSURL.class] && [url.scheme isEqual:@"line"]);
    assert([url.host isEqual:@"nv"] && [url.path hasPrefix:@"/profilePopup/mid=u"]);
    assert(!url.query && !url.fragment && !url.user && !url.password);
    testCalls++;
    return YES;
}
int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSDictionary *info = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
        NSString *valid = @"u00000000000000000000000000000000";
        Class cls = objc_allocateClassPair(NSObject.class, RUINMIDDelegateClass, 0);
        BOOL mismatch = argc == 2 && strcmp(argv[1], "mismatch") == 0;
        assert(cls && class_addMethod(cls, sel_registerName(RUINMIDRouterSelector), (IMP)RUINMIDTestRouter,
            mismatch ? "q24@0:8@16" : "B24@0:8@16"));
        objc_registerClassPair(cls);
        id delegate = [cls new];
        for (id value in @[@"", @"lineid", @"line://nv/profilePopup/mid=u00000000000000000000000000000000", @"u0000000000000000000000000000000/", @"c00000000000000000000000000000000", @"u0000000000000000000000000000000g", @"u0000000000000000000000000000000Ａ", @42]) {
            assert([RUINMIDDispatch(value, delegate, info) isEqual:@"invalid_mid"]);
        }
        assert(!RUINMIDURL(nil));
        assert(!RUINMIDURL([@" " stringByPaddingToLength:129 withString:@" " startingAtIndex:0]));
        assert(RUINMIDURL([NSString stringWithFormat:@" \n%@\n", valid]));
        assert([RUINMIDDispatch(valid, delegate, @{}) isEqual:@"version_gated"]);
        assert([RUINMIDDispatch(valid, NSObject.new, info) isEqual:@"native_router_unavailable_or_abi_mismatch"]);
        assert(testCalls == 0);
        assert([RUINMIDDispatch(valid, delegate, info) isEqual:(mismatch
            ? @"native_router_unavailable_or_abi_mismatch" : @"native_route_accepted")]);
        assert(testCalls == (mismatch ? 0 : 1));
        puts("PASS MID validation, fixed route, version/class/ABI gates, no invalid-input dispatch");
    }
    return 0;
}
#endif
