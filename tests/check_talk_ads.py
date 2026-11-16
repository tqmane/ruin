#!/usr/bin/env python3
"""Run the production Talk-top banner Logos hooks against bounded UIKit doubles."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

SHIM = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define BOOL _Bool
#define NSLayoutConstraint RUINTalkConstraintFixture
enum { NSLayoutAttributeHeight = 8, NSLayoutAttributeWidth = 7, NSLayoutRelationEqual = 0 };
static const float UILayoutPriorityRequired = 1000;
@interface NSLayoutConstraint : NSObject
@property(nonatomic, weak) id firstItem, secondItem;
@property(nonatomic) NSInteger firstAttribute, relation;
@property(nonatomic) float priority;
@property(nonatomic) BOOL active;
@property(nonatomic) double constant;
@end
@implementation NSLayoutConstraint @end
@interface UIView : NSObject
@property(nonatomic, weak) UIView *superview;
@property(nonatomic, strong) NSMutableArray *subviews, *constraints;
@property(nonatomic) BOOL hidden;
@property(nonatomic) double alpha;
@property(nonatomic, copy) NSString *enumType, *enumCase;
@property(nonatomic) unsigned nativeHiddenCalls, nativeLayoutCalls, nativeMoveCalls, parentLayouts;
- (void)addSubview:(UIView *)view;
- (void)didMoveToWindow;
- (void)layoutSubviews;
- (void)layoutIfNeeded;
@end
@implementation UIView
- (instancetype)init {
    if ((self = [super init])) { _subviews = [NSMutableArray array]; _constraints = [NSMutableArray array]; _alpha = 1; }
    return self;
}
- (void)setHidden:(BOOL)value { _hidden = value; self.nativeHiddenCalls++; }
- (void)addSubview:(UIView *)view { view.superview = self; [self.subviews addObject:view]; }
- (void)didMoveToWindow { self.nativeMoveCalls++; }
- (void)layoutSubviews { self.nativeLayoutCalls++; }
- (void)layoutIfNeeded { self.parentLayouts++; }
@end
@interface UIStackView : UIView
@property(nonatomic, strong) NSMutableArray *arrangedSubviews;
- (void)addArrangedSubview:(UIView *)view;
@end
@implementation UIStackView
- (instancetype)init { if ((self = [super init])) _arrangedSubviews = [NSMutableArray array]; return self; }
- (void)addArrangedSubview:(UIView *)view { [self addSubview:view]; [self.arrangedSubviews addObject:view]; }
@end
static void RUINRefreshTalkInsetsForBanner(__unused UIView *view) {}
static NSString *RUINCopySwiftFieldTypeName(UIView *view, const char *path) {
    assert(!strcmp(path, "bannerType")); return view.enumType;
}
static NSString *RUINCopySwiftEnumCaseName(UIView *view, const char *path) {
    assert(!strcmp(path, "bannerType")); return view.enumCase;
}
static atomic_bool gHideAdsEnabled;
static NSUInteger gViewHooksGeneration;
'''

CHECK = r'''
static NSLayoutConstraint *Height(UIView *view, double value, float priority) {
    NSLayoutConstraint *constraint = [NSLayoutConstraint new];
    constraint.firstItem = view; constraint.firstAttribute = NSLayoutAttributeHeight;
    constraint.constant = value; constraint.priority = priority; constraint.active = YES;
    [view.constraints addObject:constraint]; return constraint;
}
static void WrongHidden(__unused id self, __unused SEL selector, __unused NSInteger hidden) {}
static Class AddClass(const char *name) {
    Class cls = objc_allocateClassPair(UIView.class, name, 0); assert(cls);
    objc_registerClassPair(cls); return cls;
}
int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2);
    RUINInstallTalkTopBannerHooks(); assert(atomic_load(&gTalkTopBannerStatus) == RUINHookMissingClass);
    Class topClass = AddClass("_TtC13LineChatTabUI16TopBannerBoxView");
    Class smartClass = AddClass("_TtC11LineSmartCh11SmartChView");
    Class adClass = AddClass("_TtC11LineSmartCh13SmartChAdView");
    Class errorClass = AddClass("_TtC11LineSmartCh16SmartChErrorView");
    if (!strcmp(argv[1], "bad-abi")) {
        assert(class_addMethod(topClass, @selector(setHidden:), (IMP)WrongHidden, "v20@0:8q16"));
        RUINInstallTalkTopBannerHooks();
        assert(atomic_load(&gTalkTopBannerStatus) == RUINHookEncodingMismatch && !gTalkTopBannerClass);
        puts("PASS Talk-top hook rejects a mismatched owner ABI without partial installation"); return 0;
    }
    RUINInstallTalkTopBannerHooks(); assert(atomic_load(&gTalkTopBannerStatus) == RUINHookInstalled);
    RUINInstallTalkTopBannerHooks(); assert(gViewHooksGeneration == 1);
    UIStackView *stack = [UIStackView new];
    UIView *search = [UIView new], *segments = [UIView new];
    [stack addArrangedSubview:search]; [stack addArrangedSubview:segments];
    UIView *top = [topClass new], *smart = [smartClass new], *ad = [adClass new], *error = [errorClass new];
    UIView *content = [UIView new]; content.hidden = YES;
    ad.hidden = YES; error.hidden = YES;
    [stack addArrangedSubview:top]; [top addSubview:smart];
    [smart addSubview:ad]; [smart addSubview:error]; [smart addSubview:content];
    top.enumType = @"LineChatTabUI.TopBannerBoxBannerType"; top.enumCase = @"smartChannel";
    NSLayoutConstraint *height = Height(top, 114, 1000), *optional = Height(top, 28, 750);
    NSLayoutConstraint *width = Height(top, 375, 1000); width.firstAttribute = NSLayoutAttributeWidth;
    error.hidden = NO;
    assert(!top.hidden && height.priority == 1000); // Ads OFF preserves native empty slot.
    atomic_store(&gHideAdsEnabled, YES);
    unsigned layouts = top.nativeLayoutCalls; [top layoutSubviews];
    assert(top.nativeLayoutCalls == layouts + 1 && top.hidden && height.priority == 999);
    assert(height.constant == 114 && height.active && optional.priority == 750 && width.priority == 1000);
    assert(!error.hidden && ad.hidden); // Payload visibility is never rewritten.
    unsigned settledWrites = top.nativeHiddenCalls;
    for (unsigned i = 0; i < 50; i++) [top layoutSubviews];
    assert(top.nativeHiddenCalls == settledWrites); // No setHidden/layout feedback loop.
    unsigned moves = top.nativeMoveCalls; [top didMoveToWindow];
    assert(top.nativeMoveCalls == moves + 1 && top.hidden);
    unsigned calls = top.nativeHiddenCalls; top.hidden = NO;
    assert(top.nativeHiddenCalls == calls + 1 && top.hidden);
    atomic_store(&gHideAdsEnabled, NO); RUINRefreshTalkTopBanner(top);
    assert(!top.hidden && height.priority == 1000 && stack.parentLayouts);

    // Native can deactivate a suppressed constraint. Restore its priority now
    // without reactivating it, so a later native activation does not retain 999.
    atomic_store(&gHideAdsEnabled, YES); RUINRefreshTalkTopBanner(top);
    assert(top.hidden && height.priority == 999);
    height.active = NO;
    atomic_store(&gHideAdsEnabled, NO); RUINRefreshTalkTopBanner(top);
    assert(!top.hidden && height.priority == 1000 && !height.active);
    assert(![(RUINTalkSmartTopBannerView *)top ruin_talkAdHeightPriorities]);
    height.active = YES; assert(height.priority == 1000);

    // The ad switch controls the entire smartChannel region, including news,
    // mixed content, and skeletons. It never changes payload visibility itself.
    atomic_store(&gHideAdsEnabled, YES);
    error.hidden = YES; ad.hidden = NO; [top layoutSubviews];
    assert(top.hidden && height.priority == 999);
    ad.hidden = YES; [top layoutSubviews];
    assert(top.hidden && height.priority == 999); // Empty/loading slot also collapses.
    content.hidden = NO; error.hidden = NO;
    [top layoutSubviews]; assert(top.hidden && !content.hidden && !error.hidden);
    error.hidden = YES; [top layoutSubviews]; assert(top.hidden && !content.hidden); // News only.
    for (NSString *other in @[@"none", @"legacy", @"lan", @"googleAd"]) {
        top.enumCase = other; [top layoutSubviews];
        assert(!top.hidden && height.priority == 1000 && !content.hidden);
    }
    content.hidden = YES;
    UIView *skeleton = [UIView new]; [smart addSubview:skeleton];
    top.enumCase = @"smartChannel"; [top layoutSubviews]; assert(top.hidden && !skeleton.hidden);
    atomic_store(&gHideAdsEnabled, NO); RUINRefreshTalkTopBanner(top);
    assert(!top.hidden && height.priority == 1000 && !skeleton.hidden);
    atomic_store(&gHideAdsEnabled, YES);
    top.enumCase = @"smartChannel"; top.enumType = @"Unknown.BannerType";
    [top layoutSubviews]; assert(!top.hidden);
    top.enumType = @"LineChatTabUI.TopBannerBoxBannerType";
    [top layoutSubviews]; assert(top.hidden);
    height.priority = 800; atomic_store(&gHideAdsEnabled, NO); RUINRefreshTalkTopBanner(top);
    assert(!top.hidden && height.priority == 800); // Preserve native changes made while suppressed.
    height.priority = 1000;
    top.hidden = YES; atomic_store(&gHideAdsEnabled, YES); RUINRefreshTalkTopBanner(top);
    NSLayoutConstraint *stackHiding = Height(top, 0, 1000);
    RUINRefreshTalkTopBanner(top); assert(stackHiding.priority == 1000);
    [top.constraints removeObjectIdenticalTo:stackHiding]; [stack.constraints addObject:stackHiding];
    RUINRefreshTalkTopBanner(top);
    assert(height.priority == 999 && stackHiding.priority == 1000);
    atomic_store(&gHideAdsEnabled, NO); RUINRefreshTalkTopBanner(top);
    assert(top.hidden && height.priority == 999 && stackHiding.active);
    assert([(RUINTalkSmartTopBannerView *)top ruin_talkAdHeightPriorities].count == 1);
    [top layoutSubviews]; assert(height.priority == 999);
    top.hidden = NO;
    assert(!top.hidden && height.priority == 999); // Delayed stack cleanup still defers restoration.
    stackHiding.active = NO; [top layoutSubviews];
    assert(height.priority == 1000 && !stackHiding.active && stackHiding.priority == 1000);
    assert(![(RUINTalkSmartTopBannerView *)top ruin_talkAdHeightPriorities]);
    atomic_store(&gHideAdsEnabled, YES);
    [stack.arrangedSubviews removeObjectIdenticalTo:top]; [top layoutSubviews];
    assert(!top.hidden && height.priority == 1000);
    [stack.arrangedSubviews addObject:top];
    UIView *foreignRoot = [UIView new]; [foreignRoot addSubview:top]; [top layoutSubviews];
    assert(!top.hidden && !search.hidden && !segments.hidden);
    assert(search.nativeHiddenCalls == 0 && segments.nativeHiddenCalls == 0);
    puts("PASS production full SmartChannel collapse, other-banner isolation, native visibility and deferred constraint restoration");
} return 0; }
'''


def main():
    source = (ROOT / "src/interface/InterfaceFeatures.x").read_text()
    status = source[source.index("typedef enum {"):source.index("typedef struct {")]
    state = source[source.index("static Class gTalkTopBannerClass"):source.index("static atomic_int gStartupStatus")]
    hooks = source[source.index("// SmartChannel shares a slot"):source.index("static BOOL RUINPrepareMethodHook(")]
    install = source[source.index("static BOOL RUINIsUIViewSubclass("):source.index("static void RUINMarkHooksVersionGated(")]
    with tempfile.TemporaryDirectory(prefix="ruin-talk-ads-") as temporary:
        directory = Path(temporary)
        logos = directory / "check.x"
        logos.write_text("%config(generator=internal);\n" + SHIM + status + state + hooks + install + CHECK)
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
        for scenario in ("normal", "bad-abi"):
            subprocess.run([str(executable), scenario], check=True, timeout=15)


if __name__ == "__main__":
    main()
