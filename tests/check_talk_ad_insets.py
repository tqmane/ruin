#!/usr/bin/env python3
"""Exercise production owned Talk table/collection setters and restoration."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
import check_talk_ads as banner

ROOT = Path(__file__).resolve().parents[1]

SHIM = r'''
#include <math.h>
#include <stdlib.h>
typedef struct UIEdgeInsets { double top, left, bottom, right; } UIEdgeInsets;
#define CGPoint RUINTalkTestPoint
typedef struct RUINTalkTestPoint { double x, y; } RUINTalkTestPoint;
@interface UIView (TalkInsetFixture)
- (BOOL)isDescendantOfView:(UIView *)ancestor;
@end
@implementation UIView (TalkInsetFixture)
- (BOOL)isDescendantOfView:(UIView *)ancestor {
    for (UIView *v = self; v; v = v.superview) if (v == ancestor) return YES;
    return NO;
}
@end
@interface UIViewController : NSObject
@property(nonatomic, strong) UIView *viewIfLoaded;
@property(nonatomic, weak) UIViewController *parentViewController;
@property(nonatomic, strong) NSMutableDictionary *fields;
@property(nonatomic) unsigned nativeWillLayout, nativeDidLayout;
- (void)viewWillLayoutSubviews;
- (void)viewDidLayoutSubviews;
@end
@implementation UIViewController
- (instancetype)init { if ((self = [super init])) _fields = [NSMutableDictionary dictionary]; return self; }
- (void)viewWillLayoutSubviews { self.nativeWillLayout++; }
- (void)viewDidLayoutSubviews { self.nativeDidLayout++; }
@end
@interface UIScrollView : UIView
@property(nonatomic) UIEdgeInsets contentInset, verticalScrollIndicatorInsets;
@property(nonatomic, readonly) UIEdgeInsets adjustedContentInset;
@property(nonatomic) CGPoint contentOffset;
@property(nonatomic) BOOL dragging, decelerating;
@property(nonatomic) unsigned contentWrites, indicatorWrites, offsetWrites;
@property(nonatomic) double systemTop;
@property(nonatomic) BOOL lastAnimated;
@property(nonatomic, copy) void (^onAdjustedRead)(void);
- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated;
@end
@implementation UIScrollView
- (void)setContentInset:(UIEdgeInsets)value { _contentInset = value; self.contentWrites++; }
- (void)setVerticalScrollIndicatorInsets:(UIEdgeInsets)value { _verticalScrollIndicatorInsets = value; self.indicatorWrites++; }
- (UIEdgeInsets)adjustedContentInset {
    if (self.onAdjustedRead) self.onAdjustedRead();
    UIEdgeInsets value = self.contentInset; value.top += self.systemTop; return value;
}
- (void)setContentOffset:(CGPoint)value { _contentOffset = value; self.offsetWrites++; }
- (void)setContentOffset:(CGPoint)value animated:(BOOL)animated { self.lastAnimated = animated; self.contentOffset = value; }
@end
@interface UITableView : UIScrollView @end
@implementation UITableView @end
@interface UICollectionView : UIScrollView @end
@implementation UICollectionView @end
static id RUINCopySwiftField(UIViewController *owner, const char *path) {
    return owner.fields[@(path)];
}
'''

CHECK = r'''
static Class AddFixtureClass(Class parent, const char *name) {
    Class cls = objc_allocateClassPair(parent, name, 0); assert(cls);
    objc_registerClassPair(cls); return cls;
}
static void WrongLayout(__unused id self, __unused SEL selector) {}
int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2);
    Class topClass = AddFixtureClass(UIView.class, "_TtC13LineChatTabUI16TopBannerBoxView");
    Class pageClass = AddFixtureClass(UIViewController.class, "_TtC13LineChatTabUI25ChatTabPageViewController");
    Class listClass = AddFixtureClass(UIViewController.class, "_TtC13LineChatTabUI22ChatListViewController");
    Class friendClass = AddFixtureClass(UIViewController.class, "_TtC19LineGeneralContents17GCSViewController");
    if (!strcmp(argv[1], "bad-abi")) {
        assert(class_addMethod(pageClass, @selector(viewDidLayoutSubviews), (IMP)WrongLayout, "q16@0:8"));
        RUINInstallTalkInsetHooks(); assert(atomic_load(&gTalkInsetStatus) == RUINHookEncodingMismatch);
        UIScrollView *foreign = [UIScrollView new]; foreign.contentInset = (UIEdgeInsets){238,2,3,4};
        assert(foreign.contentInset.top == 238 && !gTalkPageClass);
        puts("PASS Talk page ABI rejection leaves scroll views untouched"); return 0;
    }
    if (!strcmp(argv[1], "bad-inset-abi") || !strcmp(argv[1], "bad-offset-abi")) {
        BOOL edge = !strcmp(argv[1], "bad-inset-abi");
        Class cls = edge ? UITableView.class : UICollectionView.class;
        SEL selector = edge ? @selector(setContentInset:) : @selector(setContentOffset:animated:);
        assert(class_addMethod(cls, selector, (IMP)WrongLayout,
            edge ? "v32@0:8{UIEdgeInsets=dd}16" : "v36@0:8{CGPoint=ff}16B32"));
        RUINInstallTalkInsetHooks(); assert(atomic_load(&gTalkInsetStatus) == RUINHookEncodingMismatch);
        assert(!gTalkPageClass);
        puts("PASS Talk inset/offset HFA ABI rejection without partial installation"); return 0;
    }
    IMP nativeInsetSetter = method_getImplementation(class_getInstanceMethod(UIScrollView.class, @selector(setContentInset:)));
    IMP nativeIndicatorSetter = method_getImplementation(class_getInstanceMethod(UIScrollView.class, @selector(setVerticalScrollIndicatorInsets:)));
    RUINInstallTalkTopBannerHooks(); RUINInstallTalkInsetHooks();
    assert(method_getImplementation(class_getInstanceMethod(UIScrollView.class, @selector(setContentInset:))) == nativeInsetSetter);
    assert(method_getImplementation(class_getInstanceMethod(UIScrollView.class, @selector(setVerticalScrollIndicatorInsets:))) == nativeIndicatorSetter);
    assert(atomic_load(&gTalkInsetStatus) == RUINHookInstalled);
    UIViewController *page = [pageClass new], *list = [listClass new], *friends = [friendClass new];
    page.viewIfLoaded = [UIView new]; list.parentViewController = page; friends.parentViewController = page;
    UIScrollView *header = [UIScrollView new];
    UITableView *table = [UITableView new]; UICollectionView *collection = [UICollectionView new];
    UIStackView *stack = [UIStackView new]; UIView *top = [topClass new];
    [page.viewIfLoaded addSubview:header]; [header addSubview:stack]; [stack addArrangedSubview:top];
    [page.viewIfLoaded addSubview:table]; [page.viewIfLoaded addSubview:collection];
    top.enumType = @"LineChatTabUI.TopBannerBoxBannerType"; top.enumCase = @"smartChannel";
    NSLayoutConstraint *height = [NSLayoutConstraint new];
    height.firstItem = top; height.firstAttribute = NSLayoutAttributeHeight; height.relation = NSLayoutRelationEqual;
    height.constant = 114; height.priority = 1000; height.active = YES; [top.constraints addObject:height];
    page.fields[@"topBannerBoxView"] = top; page.fields[@"topBannerBoxBackgroundView"] = stack;
    page.fields[@"$__lazy_storage_$_topBannerBoxScrollView"] = header;
    page.fields[@"chatSubTabViewController.$__lazy_storage_$_contentViewController"] = list;
    page.fields[@"friendSubTabViewController.gcsViewController"] = friends;
    list.fields[@"tableView"] = table; friends.fields[@"$__lazy_storage_$_collectionView"] = collection;
    table.contentInset = (UIEdgeInsets){238,2,3,4}; table.verticalScrollIndicatorInsets = (UIEdgeInsets){238,5,6,7};
    table.systemTop = 44; table.contentOffset = (CGPoint){3,-282};
    collection.contentInset = (UIEdgeInsets){238,8,9,10}; collection.contentOffset = (CGPoint){0,-238};
    header.contentInset = (UIEdgeInsets){51,1,1,1};
    atomic_store(&gHideAdsEnabled, YES); [top layoutSubviews];
    [page viewWillLayoutSubviews]; [page viewDidLayoutSubviews];
    assert(page.nativeWillLayout == 1 && page.nativeDidLayout == 1);
    assert(top.hidden && table.contentInset.top == 124 && collection.contentInset.top == 124);
    assert(height.constant == 114); // The native height is read, not rewritten or guessed from stale frames.
    assert(table.contentOffset.y == -168 && collection.contentOffset.y == -124);
    assert(table.contentInset.left == 2 && table.contentInset.bottom == 3 && table.contentInset.right == 4);
    assert(table.verticalScrollIndicatorInsets.top == 124 && table.verticalScrollIndicatorInsets.left == 5);
    assert(header.contentInset.top == 51 && !objc_getAssociatedObject(header, &gTalkInsetRecordKey));
    // Native writes may arrive after the page's layout callback. No new page
    // callback is used in this measured 164/50/124/-124 OFF/ON regression.
    table.systemTop = 74;
    table.contentInset = (UIEdgeInsets){164,2,3,4}; table.contentOffset = (CGPoint){7,-238};
    assert(table.contentInset.top == 50 && table.adjustedContentInset.top == 124 && table.contentOffset.y == -124);
    atomic_store(&gHideAdsEnabled, NO); RUINRefreshTalkTopBanner(top);
    assert(table.contentInset.top == 164 && table.adjustedContentInset.top == 238 && table.contentOffset.y == -238);
    unsigned offOffsetWrites = table.offsetWrites;
    table.contentInset = (UIEdgeInsets){180,12,13,14};
    assert(table.contentInset.top == 180 && table.offsetWrites == offOffsetWrites && table.contentOffset.y == -238);
    atomic_store(&gHideAdsEnabled, YES); RUINRefreshTalkTopBanner(top);
    table.contentInset = (UIEdgeInsets){164,2,3,4};
    table.verticalScrollIndicatorInsets = (UIEdgeInsets){164,5,6,7};
    [table setContentOffset:(CGPoint){8,-238} animated:YES];
    assert(table.contentInset.top == 50 && table.verticalScrollIndicatorInsets.top == 50);
    assert(table.contentOffset.x == 8 && table.contentOffset.y == -124 && table.lastAnimated);
    unsigned offsetWrites = table.offsetWrites;
    table.dragging = YES; table.contentOffset = (CGPoint){8,-238};
    assert(table.contentOffset.y == -238 && table.offsetWrites == offsetWrites + 1);
    table.dragging = NO; table.contentOffset = (CGPoint){8,-238}; assert(table.contentOffset.y == -124);
    table.systemTop = 44; table.contentInset = (UIEdgeInsets){238,2,3,4};
    table.verticalScrollIndicatorInsets = (UIEdgeInsets){238,5,6,7}; table.contentOffset = (CGPoint){3,-282};
    assert(table.contentInset.top == 124 && table.contentOffset.y == -168);
    setenv("RUIN_ENABLE_RUNTIME_INSPECTOR", "1", 1);
    NSArray *diagnostics = RUINTalkInsetDiagnostics(); assert(diagnostics.count == 2);
    for (NSDictionary *row in diagnostics)
        assert([row[@"nativeContentTop"] doubleValue] == 238 && [row[@"contentTop"] doubleValue] == 124);
    unsetenv("RUIN_ENABLE_RUNTIME_INSPECTOR"); assert(!RUINTalkInsetDiagnostics().count);
    unsigned writes = table.contentWrites, indicators = table.indicatorWrites;
    for (unsigned i = 0; i < 50; i++) [page viewDidLayoutSubviews];
    assert(table.contentWrites == writes && table.indicatorWrites == indicators);
    __block unsigned reentrantReads = 0;
    __weak UIViewController *weakPage = page;
    table.onAdjustedRead = ^{ assert(++reentrantReads < 16); [weakPage viewDidLayoutSubviews]; };
    [page viewDidLayoutSubviews];
    table.onAdjustedRead = nil; assert(reentrantReads && !gTalkInsetDepth);
    table.contentInset = (UIEdgeInsets){260,20,30,40};
    assert(table.contentInset.top == 146 && table.contentOffset.y == -190);
    UIEdgeInsets readModifyWrite = table.contentInset; readModifyWrite.left = 19; table.contentInset = readModifyWrite;
    assert(table.contentInset.top == 146 && table.contentInset.left == 19);
    height.constant = 80; [page viewDidLayoutSubviews];
    assert(table.contentInset.top == 180 && table.contentOffset.y == -224);
    atomic_store(&gHideAdsEnabled, NO); RUINRefreshTalkTopBanner(top);
    assert(!top.hidden && table.contentInset.top == 260 && table.contentOffset.y == -304);
    assert(table.verticalScrollIndicatorInsets.top == 238 && table.contentInset.left == 19);
    atomic_store(&gHideAdsEnabled, YES); [top layoutSubviews];
    top.enumCase = @"legacy";
    unsigned legacyOffsetWrites = table.offsetWrites; CGPoint legacyOffset = table.contentOffset;
    table.contentInset = (UIEdgeInsets){200,19,30,40};
    table.verticalScrollIndicatorInsets = (UIEdgeInsets){200,5,6,7};
    [top layoutSubviews];
    assert(table.contentInset.top == 200 && table.verticalScrollIndicatorInsets.top == 200);
    assert(table.offsetWrites == legacyOffsetWrites && table.contentOffset.y == legacyOffset.y);
    top.enumCase = @"smartChannel";
    table.contentInset = (UIEdgeInsets){260,19,30,40};
    table.contentOffset = (CGPoint){0,500}; [top layoutSubviews];
    assert(table.contentInset.top == 180 && table.contentOffset.y == 500); // No jump while reading down the list.
    atomic_store(&gHideAdsEnabled, NO); [top layoutSubviews]; assert(table.contentOffset.y == 500);
    UIScrollView *foreign = [UIScrollView new]; foreign.contentInset = (UIEdgeInsets){238,4,5,6};
    assert(foreign.contentInset.top == 238 && !objc_getAssociatedObject(foreign, &gTalkInsetRecordKey));
    UITableView *foreignTable = [UITableView new]; UICollectionView *foreignCollection = [UICollectionView new];
    for (UIScrollView *foreignView in @[foreignTable, foreignCollection]) {
        foreignView.contentInset = (UIEdgeInsets){164,7,8,9};
        foreignView.verticalScrollIndicatorInsets = (UIEdgeInsets){164,10,11,12};
        [foreignView setContentOffset:(CGPoint){17,-238} animated:YES];
        assert(foreignView.contentWrites == 1 && foreignView.contentInset.top == 164 && foreignView.contentInset.right == 9);
        assert(foreignView.indicatorWrites == 1 && foreignView.verticalScrollIndicatorInsets.left == 10);
        assert(foreignView.offsetWrites == 1 && foreignView.contentOffset.x == 17 && foreignView.contentOffset.y == -238);
        assert(foreignView.lastAnimated && !objc_getAssociatedObject(foreignView, &gTalkInsetRecordKey));
    }
    UIView *otherRoot = [UIView new]; [otherRoot addSubview:collection];
    atomic_store(&gHideAdsEnabled, YES); [top layoutSubviews];
    assert(collection.contentInset.top == 238); // Stale/reparented content is restored, not projected.
    UIStackView *foreignStack = [UIStackView new]; [otherRoot addSubview:foreignStack];
    [foreignStack addArrangedSubview:top]; [top layoutSubviews];
    assert(table.contentInset.top == 260); // A banner reparented outside the page loses authority too.
    puts("PASS owned Talk/Friends late inset/offset setters, OFF/ON restoration, reentrancy and foreign-view passthrough");
} return 0; }
'''


def main():
    source = (ROOT / "src/interface/InterfaceFeatures.x").read_text()
    shim = banner.SHIM.replace("static void RUINRefreshTalkInsetsForBanner(__unused UIView *view) {}",
                               "static void RUINRefreshTalkInsetsForBanner(UIView *view);")
    status = source[source.index("typedef enum {"):source.index("typedef struct {")]
    state = source[source.index("static Class gTalkTopBannerClass"):source.index("static atomic_int gStartupStatus")]
    top_hooks = source[source.index("// SmartChannel shares a slot"):source.index("static BOOL RUINPrepareMethodHook(")]
    inset_hooks = source[source.index("// Native page layout computes list insets"):source.index("static void RUINInstallViewTargetHooks(")]
    top_install = source[source.index("static BOOL RUINIsUIViewSubclass("):source.index("static void RUINMarkHooksVersionGated(")]
    with tempfile.TemporaryDirectory(prefix="ruin-talk-insets-") as temporary:
        directory = Path(temporary)
        logos = directory / "check.x"
        logos.write_text("%config(generator=internal);\n" + shim + SHIM + status + state + top_hooks + inset_hooks + top_install + CHECK)
        generated = directory / "check.m"
        with generated.open("w") as output:
            subprocess.run(["/usr/bin/perl", str(ROOT / "vendor/logos/bin/logos.pl"), str(logos)],
                           stdout=output, check=True, timeout=20)
        executable = directory / "check"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", "-std=gnu11",
            "-Wall", "-Wextra", "-Werror", str(generated), "-framework", "Foundation", "-o", str(executable)],
            check=True, timeout=40)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(executable)],
                       check=True, capture_output=True, timeout=15)
        for scenario in ("normal", "bad-abi", "bad-inset-abi", "bad-offset-abi"):
            subprocess.run([str(executable), scenario], check=True, timeout=15)


if __name__ == "__main__":
    main()
