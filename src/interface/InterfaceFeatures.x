%config(generator=internal);

#import "TargetMetadata.h"
#import "InterfaceFeatures.h"
#import "../platform/SecondaryLogin.h"
#import "ChatCatalog.h"
#import "BinaryVerifier.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <math.h>

#import "Features.h"
#import "NativeTabAvailability.h"
#import "SwiftFields.h"
extern NSDictionary *RUINNativeEntryDiagnostics(void);

NSString * const RUINHideVOOMTabDefaultsKey = @"RUINInterfaceHideVOOMTab";
NSString * const RUINHideWalletTabDefaultsKey = @"RUINInterfaceHideWalletTab";
NSString * const RUINHideShoppingTabDefaultsKey = @"RUINInterfaceHideShoppingTab";
NSString * const RUINHideAppsTabDefaultsKey = @"RUINInterfaceHideAppsTab";
NSString * const RUINHideNewsCallTabsDefaultsKey = @"RUINInterfaceHideNewsCallTabs";
NSString * const RUINHideSettingsTabDefaultsKey = @"RUINInterfaceHideSettingsTab";
NSString * const RUINStartupTabFixedDefaultsKey = @"RUINInterfaceStartupTabFixed";
NSString * const RUINStartupTabDefaultsKey = @"RUINInterfaceStartupTab";
NSString * const RUINHideAdsDefaultsKey = @"RUINInterfaceHideAds";
NSString * const RUINHideRecommendationsDefaultsKey = @"RUINInterfaceHideRecommendations";
NSString * const RUINHideVoiceInputDefaultsKey = @"RUINInterfaceHideVoiceInput";
NSString * const RUINHideAgentIBarDefaultsKey = @"RUINInterfaceHideAgentIBar";
NSString * const RUINFixPanelHeightDefaultsKey = @"RUINInterfaceFixPanelHeight";
NSString * const RUINProfileHeaderLeftDefaultsKey = @"RUINInterfaceProfileHeaderLeft";

NSString * const RUINInterfaceTabHome = @"home";
NSString * const RUINInterfaceTabTalk = @"talk";
NSString * const RUINInterfaceTabVOOM = @"voom";
NSString * const RUINInterfaceTabWallet = @"wallet";
NSString * const RUINInterfaceTabShopping = @"shopping";
NSString * const RUINInterfaceTabNews = @"news";
NSString * const RUINInterfaceTabCall = @"call";
NSString * const RUINInterfaceTabSettings = @"settings";
NSString * const RUINInterfaceTabApps = @"apps";

typedef enum {
    RUINHookPending,
    RUINHookVersionGated,
    RUINHookMissingClass,
    RUINHookMissingSelector,
    RUINHookEncodingMismatch,
    RUINHookClassTypeMismatch,
    RUINHookInstallFailed,
    RUINHookInstalled
} RUINHookStatus;

typedef struct {
    const char *className;
    const char *selectorName;
    const char *encoding;
    _Atomic(IMP) original;
    atomic_uint_fast64_t calls;
    atomic_int status;
} RUINMethodHook;

typedef enum {
    RUINHideGroupAds,
    RUINHideGroupRecommendations,
    RUINHideGroupVoiceInput,
    RUINHideGroupAgentI
} RUINHideGroup;

typedef struct {
    const char *className;
    RUINHideGroup group;
    Class cls;
    RUINMethodHook setHidden;
    RUINMethodHook didMoveToWindow;
} RUINViewTarget;

static void RUINSetViewControllers(id self, SEL selector, NSArray *controllers);
static void RUINSetViewControllersAnimated(id self, SEL selector, NSArray *controllers, BOOL animated);
static void RUINStyledTabsViewDidLoad(id self, SEL selector);
static void RUINStyledTabsViewDidAppear(id self, SEL selector, BOOL animated);
static void RUINForceHidden(RUINViewTarget *target, id self, SEL selector, BOOL hidden);
static void RUINViewDidMoveToWindow(RUINViewTarget *target, id self, SEL selector);
static void RUINVoiceButtonLayout(id self, SEL selector);

#define RUIN_HOOK(class_name, selector, types) \
    { class_name, selector, types, ATOMIC_VAR_INIT(NULL), \
      ATOMIC_VAR_INIT(0), ATOMIC_VAR_INIT(RUINHookPending) }

static RUINMethodHook gSetControllersHook = RUIN_HOOK(
    "_TtC22LineSharedUIComponents22StyledTabBarController", "setViewControllers:",
    "v24@0:8@16");
static RUINMethodHook gSetControllersAnimatedHook = RUIN_HOOK(
    "_TtC22LineSharedUIComponents22StyledTabBarController", "setViewControllers:animated:",
    "v28@0:8@16B24");
static RUINMethodHook gTabsViewDidLoadHook = RUIN_HOOK(
    "_TtC22LineSharedUIComponents22StyledTabBarController", "viewDidLoad",
    "v16@0:8");
static RUINMethodHook gTabsViewDidAppearHook = RUIN_HOOK(
    "_TtC22LineSharedUIComponents22StyledTabBarController", "viewDidAppear:",
    "v20@0:8B16");
static RUINMethodHook gVoiceButtonLayoutHook = RUIN_HOOK(
    "_TtC15LineMessagingUI18ChatInputBarButton", "layoutSubviews",
    "v16@0:8");

#define RUIN_VIEW_TARGET(name, kind) \
    { name, kind, Nil, \
      RUIN_HOOK(name, "setHidden:", "v20@0:8B16"), \
      RUIN_HOOK(name, "didMoveToWindow", "v16@0:8") }

// These names are exact Objective-C runtime names present in LINE 26.16.0.
typedef NS_ENUM(NSUInteger, RUINViewTargetIndex) {
    RUINViewLADHomeBannerContainer,
    RUINViewChatTabGoogleAdContainerView,
    RUINViewAdVoomView,
    RUINViewAdTimelineVideoAdView,
    RUINViewAdTimelineMiniPopupCell,
    RUINViewAdTimelineCarouselContentsCell,
    RUINViewAdTimelineCarouselView,
    RUINViewAdWalletBigBannerCarouselView,
    RUINViewAdWalletBigBannerCarouselViewItemCell,
    RUINViewAdWalletBigBannerView,
    RUINViewAdWalletCarouselView,
    RUINViewAdWalletCarouselViewItemCell,
    RUINViewAdWalletInfeedView,
    RUINViewAdWalletNativeBannerView,
    RUINViewAdWalletView,
    RUINViewVOOMVideoADContentCell,
    RUINViewContentRecommendationView,
    RUINViewFriendRecommendationTableViewCell,
    RUINViewRecommendAddFriendPanelView,
    RUINViewRecentRecommendView,
    RUINViewRecommendFriendView,
    RUINViewMessageRecommendationView,
    RUINViewRecommendedFriendView,
    RUINViewChatInputBarButton,
    RUINViewAITSChipMenuView,
    RUINViewTargetCount
};

static RUINViewTarget gViewTargets[] = {
    [RUINViewLADHomeBannerContainer] = RUIN_VIEW_TARGET("_TtC11LineHomeTab22LADHomeBannerContainer", RUINHideGroupAds),
    [RUINViewChatTabGoogleAdContainerView] = RUIN_VIEW_TARGET("_TtC13LineChatTabUI28ChatTabGoogleAdContainerView", RUINHideGroupAds),
    [RUINViewAdVoomView] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport10AdVoomView", RUINHideGroupAds),
    [RUINViewAdTimelineVideoAdView] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport21AdTimelineVideoAdView", RUINHideGroupAds),
    [RUINViewAdTimelineMiniPopupCell] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport23AdTimelineMiniPopupCell", RUINHideGroupAds),
    [RUINViewAdTimelineCarouselContentsCell] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport30AdTimelineCarouselContentsCell", RUINHideGroupAds),
    [RUINViewAdTimelineCarouselView] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport22AdTimelineCarouselView", RUINHideGroupAds),
    [RUINViewAdWalletBigBannerCarouselView] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport29AdWalletBigBannerCarouselView", RUINHideGroupAds),
    [RUINViewAdWalletBigBannerCarouselViewItemCell] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport37AdWalletBigBannerCarouselViewItemCell", RUINHideGroupAds),
    [RUINViewAdWalletBigBannerView] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport21AdWalletBigBannerView", RUINHideGroupAds),
    [RUINViewAdWalletCarouselView] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport20AdWalletCarouselView", RUINHideGroupAds),
    [RUINViewAdWalletCarouselViewItemCell] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport28AdWalletCarouselViewItemCell", RUINHideGroupAds),
    [RUINViewAdWalletInfeedView] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport18AdWalletInfeedView", RUINHideGroupAds),
    [RUINViewAdWalletNativeBannerView] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport24AdWalletNativeBannerView", RUINHideGroupAds),
    [RUINViewAdWalletView] = RUIN_VIEW_TARGET("_TtC20LineAdFeatureSupport12AdWalletView", RUINHideGroupAds),
    [RUINViewVOOMVideoADContentCell] = RUIN_VIEW_TARGET("_TtC21LineLightsUISubsystem22VOOMVideoADContentCell", RUINHideGroupAds),

    [RUINViewContentRecommendationView] = RUIN_VIEW_TARGET("_TtC11LineHomeTab25ContentRecommendationView", RUINHideGroupRecommendations),
    [RUINViewFriendRecommendationTableViewCell] = RUIN_VIEW_TARGET("_TtC11LineHomeTab33FriendRecommendationTableViewCell", RUINHideGroupRecommendations),
    [RUINViewRecommendAddFriendPanelView] = RUIN_VIEW_TARGET("_TtC11LineHomeTab27RecommendAddFriendPanelView", RUINHideGroupRecommendations),
    [RUINViewRecentRecommendView] = RUIN_VIEW_TARGET("_TtC11LineCallTab19RecentRecommendView", RUINHideGroupRecommendations),
    [RUINViewRecommendFriendView] = RUIN_VIEW_TARGET("_TtC11LineCallTab19RecommendFriendView", RUINHideGroupRecommendations),
    [RUINViewMessageRecommendationView] = RUIN_VIEW_TARGET("_TtC17LineMessagingUIV225MessageRecommendationView", RUINHideGroupRecommendations),
    [RUINViewRecommendedFriendView] = RUIN_VIEW_TARGET("_TtC31LineSocialGraphUIFeatureSupport21RecommendedFriendView", RUINHideGroupRecommendations),

    // Composer controls share this class; only its .audio kind is hidden.
    [RUINViewChatInputBarButton] = RUIN_VIEW_TARGET("_TtC15LineMessagingUI18ChatInputBarButton", RUINHideGroupVoiceInput),
    [RUINViewAITSChipMenuView] = RUIN_VIEW_TARGET("_TtC17LineMessagingUIV216AITSChipMenuView", RUINHideGroupAgentI)
};

#undef RUIN_VIEW_TARGET
#undef RUIN_HOOK

static atomic_bool gTargetMatches = ATOMIC_VAR_INIT(false);
static atomic_bool gHideAdsEnabled = ATOMIC_VAR_INIT(false);
static atomic_bool gHideRecommendationsEnabled = ATOMIC_VAR_INIT(false);
static atomic_bool gHideVoiceInputEnabled = ATOMIC_VAR_INIT(false);
static atomic_bool gHideAgentIEnabled = ATOMIC_VAR_INIT(false);
static BOOL gAgentIntrinsicInstalled;
static atomic_uint_fast64_t gVoiceKindRestorations;
static NSUInteger gViewHooksGeneration;
static atomic_uint_fast64_t gVisibleViewScans, gVisibleViewScanSkips, gVoiceTypeReflections;
static void RUINRefreshTalkInsetsForBanner(UIView *banner);
static void RUINInstallTalkInsetHooks(void);
static Class gTalkTopBannerClass;
static atomic_int gTalkTopBannerStatus = ATOMIC_VAR_INIT(RUINHookPending);
static atomic_uint_fast64_t gTalkTopBannerUpdates, gTalkTopBannerCollapses;

@interface RUINTalkSmartTopBannerView : UIView
@property(nonatomic, strong) NSNumber *ruin_talkAdNativeHidden;
@property(nonatomic, strong) NSMapTable<NSLayoutConstraint *, NSNumber *> *ruin_talkAdHeightPriorities;
@property(nonatomic, strong) NSNumber *ruin_talkAdUpdating;
@end

static void RUINRefreshTalkTopBanner(UIView *view);

static atomic_int gStartupStatus = ATOMIC_VAR_INIT(0);
static atomic_uint_fast64_t gTabReapplications = ATOMIC_VAR_INIT(0);
static atomic_int gTabVisibilityStatus;
static atomic_uint_fast64_t gNativeTabCount, gUIKitTabCount;
static char gOriginalCompactTabsKey;
static NSHashTable<UITabBarController *> *gTrackedTabControllers;
static BOOL gTabConfigurationHookInstalled;
static atomic_uint_fast64_t gKeptNativeMenuRefreshes;
static _Thread_local unsigned int gTabSetterDepth;
static _Thread_local unsigned int gHiddenSetterDepth;
static _Thread_local unsigned int gInternalHiddenUpdateDepth;

static char gRequestedControllersKey;
static char gStartupSelectionAppliedKey;
static char gOriginalHiddenStateKey;

typedef enum {
    RUINTabUnknown,
    RUINTabHomeKind,
    RUINTabTalkKind,
    RUINTabVOOMKind,
    RUINTabWalletKind,
    RUINTabShoppingKind,
    RUINTabNewsKind,
    RUINTabCallKind,
    RUINTabSettingsKind,
    RUINTabAppsKind
} RUINTabKind;

static NSString *RUINTargetStatusName(RUINHookStatus status)
{
    switch (status) {
        case RUINHookVersionGated: return @"version_gated";
        case RUINHookMissingClass: return @"missing_class";
        case RUINHookMissingSelector: return @"missing_selector";
        case RUINHookEncodingMismatch: return @"encoding_mismatch";
        case RUINHookClassTypeMismatch: return @"class_type_mismatch";
        case RUINHookInstallFailed: return @"install_failed";
        case RUINHookInstalled: return @"installed";
        default: return @"pending";
    }
}

static BOOL RUINTargetMatches(void)
{
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
}

static BOOL RUINKeepNativeMenusForLaunch(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL hideMore = [defaults boolForKey:RUINHideAppsTabDefaultsKey] ||
        [defaults boolForKey:RUINHideWalletTabDefaultsKey];
    if (!NSThread.isMainThread || !hideMore) return NO;
    NSDictionary *visibility = RUINNativeTabAvailabilityDiagnostics();
    if ([visibility[@"status"] intValue] != 5 || [visibility[@"tabFilterRecoveryMode"] boolValue]) return NO;
    Class root = objc_getClass("_TtC22LineSharedUIComponents20RootTabBarController");
    if (!root) return NO;
    for (UITabBarController *controller in gTrackedTabControllers.allObjects)
        if ([controller isKindOfClass:root] && controller.viewIfLoaded.window && !controller.isBeingDismissed)
            return YES;
    return NO;
}

%group RUINNativeTabConfiguration
%hook RUINNativeTabConfigurationDelegate
- (void)didReceiveChangedConfigurationNotification:(NSNotification *)notification
{
    // This callback only rebuilds the native tab controllers. Its More-tab
    // updater reads the Mini App flag directly, bypassing protocol witnesses.
    // ponytail: keep this launch's native menu; new server tab choices apply
    // after restart. Configuration storage and service factories stay native.
    if (RUINKeepNativeMenusForLaunch()) {
        atomic_fetch_add(&gKeptNativeMenuRefreshes,1);
        return;
    }
    %orig(notification);
}
%end
%end

// Separate Logos groups keep original implementations scoped to each
// concrete class; no hook is installed on UIView or UITabBarController itself.
%group RUINInterfaceSetControllers
%hook RUINInterfaceSetControllersTarget
- (void)setViewControllers:(NSArray *)controllers
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&gSetControllersHook.original, original, memory_order_release);
    RUINSetViewControllers(self, _cmd, controllers);
}
%end
%end

%group RUINInterfaceSetControllersAnimated
%hook RUINInterfaceSetControllersAnimatedTarget
- (void)setViewControllers:(NSArray *)controllers animated:(BOOL)animated
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&gSetControllersAnimatedHook.original, original, memory_order_release);
    RUINSetViewControllersAnimated(self, _cmd, controllers, animated);
}
%end
%end

%group RUINInterfaceTabsViewDidLoad
%hook RUINInterfaceTabsViewDidLoadTarget
- (void)viewDidLoad
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&gTabsViewDidLoadHook.original, original, memory_order_release);
    RUINStyledTabsViewDidLoad(self, _cmd);
}
%end
%end

%group RUINInterfaceTabsViewDidAppear
%hook RUINInterfaceTabsViewDidAppearTarget
- (void)viewDidAppear:(BOOL)animated
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&gTabsViewDidAppearHook.original, original, memory_order_release);
    RUINStyledTabsViewDidAppear(self, _cmd, animated);
}
%end
%end

%group RUINInterfaceVoiceButtonLayout
%hook RUINInterfaceVoiceButtonLayoutTarget
- (void)layoutSubviews
{
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&gVoiceButtonLayoutHook.original, original, memory_order_release);
    RUINVoiceButtonLayout(self, _cmd);
}
%end
%end

%group RUINHideLADHomeBannerContainer
%hook RUINLADHomeBannerContainer
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewLADHomeBannerContainer];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewLADHomeBannerContainer];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideChatTabGoogleAdContainerView
%hook RUINChatTabGoogleAdContainerView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewChatTabGoogleAdContainerView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewChatTabGoogleAdContainerView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdVoomView
%hook RUINAdVoomView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdVoomView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdVoomView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdTimelineVideoAdView
%hook RUINAdTimelineVideoAdView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdTimelineVideoAdView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdTimelineVideoAdView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdTimelineMiniPopupCell
%hook RUINAdTimelineMiniPopupCell
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdTimelineMiniPopupCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdTimelineMiniPopupCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdTimelineCarouselContentsCell
%hook RUINAdTimelineCarouselContentsCell
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdTimelineCarouselContentsCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdTimelineCarouselContentsCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdTimelineCarouselView
%hook RUINAdTimelineCarouselView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdTimelineCarouselView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdTimelineCarouselView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdWalletBigBannerCarouselView
%hook RUINAdWalletBigBannerCarouselView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletBigBannerCarouselView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletBigBannerCarouselView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdWalletBigBannerCarouselViewItemCell
%hook RUINAdWalletBigBannerCarouselViewItemCell
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletBigBannerCarouselViewItemCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletBigBannerCarouselViewItemCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdWalletBigBannerView
%hook RUINAdWalletBigBannerView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletBigBannerView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletBigBannerView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdWalletCarouselView
%hook RUINAdWalletCarouselView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletCarouselView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletCarouselView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdWalletCarouselViewItemCell
%hook RUINAdWalletCarouselViewItemCell
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletCarouselViewItemCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletCarouselViewItemCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdWalletInfeedView
%hook RUINAdWalletInfeedView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletInfeedView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletInfeedView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdWalletNativeBannerView
%hook RUINAdWalletNativeBannerView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletNativeBannerView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletNativeBannerView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAdWalletView
%hook RUINAdWalletView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAdWalletView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideVOOMVideoADContentCell
%hook RUINVOOMVideoADContentCell
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewVOOMVideoADContentCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewVOOMVideoADContentCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideContentRecommendationView
%hook RUINContentRecommendationView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewContentRecommendationView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewContentRecommendationView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideFriendRecommendationTableViewCell
%hook RUINFriendRecommendationTableViewCell
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewFriendRecommendationTableViewCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewFriendRecommendationTableViewCell];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideRecommendAddFriendPanelView
%hook RUINRecommendAddFriendPanelView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewRecommendAddFriendPanelView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewRecommendAddFriendPanelView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideRecentRecommendView
%hook RUINRecentRecommendView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewRecentRecommendView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewRecentRecommendView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideRecommendFriendView
%hook RUINRecommendFriendView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewRecommendFriendView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewRecommendFriendView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideMessageRecommendationView
%hook RUINMessageRecommendationView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewMessageRecommendationView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewMessageRecommendationView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideRecommendedFriendView
%hook RUINRecommendedFriendView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewRecommendedFriendView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewRecommendedFriendView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideChatInputBarButton
%hook RUINChatInputBarButton
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewChatInputBarButton];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewChatInputBarButton];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINHideAITSChipMenuView
%hook RUINAITSChipMenuView
- (void)setHidden:(BOOL)hidden
{
    RUINViewTarget *target = &gViewTargets[RUINViewAITSChipMenuView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->setHidden.original, original, memory_order_release);
    RUINForceHidden(target, self, _cmd, hidden);
}
- (void)didMoveToWindow
{
    RUINViewTarget *target = &gViewTargets[RUINViewAITSChipMenuView];
    IMP original = (IMP)&%orig;
    if (original) atomic_store_explicit(&target->didMoveToWindow.original, original, memory_order_release);
    RUINViewDidMoveToWindow(target, self, _cmd);
}
%end
%end

%group RUINAgentIntrinsicLayout
%hook RUINAgentIntrinsicView
- (CGSize)intrinsicContentSize
{
    CGSize size = %orig;
    if (atomic_load(&gHideAgentIEnabled)) size.height = 0;
    return size;
}
%end
%end

// MARK: - Bottom panel height fix
//
// In iPad-idiom sub-device sessions the chat bottom container that hosts
// the sticker board and the plus menu keeps a zero height, so both panels
// stay invisible even though the input bar switches into the open state.
// When a panel is open but the container is collapsed, report and enforce
// the height LINE itself uses for the working voice-recording panel in
// the same environment (332pt, measured on device) for that container
// only. The
// container class, both selectors and their type encodings are verified
// before hooking, mirroring the other interface hooks.
static atomic_bool gFixPanelHeightEnabled = ATOMIC_VAR_INIT(true);
static atomic_bool gPanelHeightHookInstalled;
static atomic_uint_fast64_t gPanelHeightApplications;
static double gPanelLastTargetHeight;  // main thread only
static NSString *gPanelHeightHookStatus = @"pending";
static char gPanelHeightConstraintKey;
static atomic_bool gProfileHeaderLeftEnabled = ATOMIC_VAR_INIT(false);
static atomic_uint gProfileHeaderApplyRuns = ATOMIC_VAR_INIT(0);
static atomic_bool gProfileHeaderFoundContainer = ATOMIC_VAR_INIT(false);
static atomic_bool gProfileHeaderHookInstalled;
static NSString *gProfileHeaderHookStatus = @"pending";
static atomic_bool gPanelTraitHookInstalled;
static atomic_uint_fast64_t gPanelTraitApplications;
static NSString *gPanelTraitHookStatus = @"pending";
static BOOL RUINIsUIViewSubclass(Class cls);

static BOOL RUINPanelHeightShouldFix(UIView *container) {
    if (!atomic_load_explicit(&gFixPanelHeightEnabled, memory_order_relaxed)) return NO;
    if (!atomic_load_explicit(&gTargetMatches, memory_order_relaxed)) return NO;
    if (container.subviews.count) return YES;
    UIView *bar = nil;
    for (UIView *sibling in container.superview.subviews)
        if ([NSStringFromClass(sibling.class) isEqual:@"LineMessagingUI.ChatInputBar"]) { bar = sibling; break; }
    if (!bar) return NO;
    // The bar scan below reflects over Swift fields; cache per bar briefly.
    static __weak UIView *cachedBar;
    static BOOL cachedSignal;
    static NSTimeInterval cachedAt;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (cachedBar == bar && now - cachedAt < 0.5) return cachedSignal;
    BOOL signal = NO;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:bar];
    NSUInteger guard = 0;
    while (stack.count && guard++ < 128 && !signal) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([NSStringFromClass(view.class) isEqual:@"LineMessagingUI.ChatInputBarButton"]) {
            NSString *kind = RUINCopySwiftEnumCaseName(view, "kind");
            if ([kind isEqual:@"keyboard"]) signal = YES;
            else if ([kind isEqual:@"plus"] &&
                ([(UIButton *)view isSelected] || !CGAffineTransformIsIdentity(view.transform))) signal = YES;
        }
        [stack addObjectsFromArray:view.subviews];
    }
    cachedBar = bar;
    cachedSignal = signal;
    cachedAt = now;
    return signal;
}

static double RUINPanelTargetHeight(UIView *container) {
    // Match the height LINE itself gives this container in voice recording
    // mode — the one bottom panel that works in iPad-idiom sub-device
    // sessions (measured on device: 332pt).
    double height = 332;
    UIWindow *window = container.window;
    if (window) height = MIN(height, CGRectGetHeight(window.bounds) * 0.65);
    return height;
}

static void RUINPanelHeightApply(UIView *container) {
    NSLayoutConstraint *constraint = objc_getAssociatedObject(container, &gPanelHeightConstraintKey);
    if (!RUINPanelHeightShouldFix(container)) {
        if (constraint.active) constraint.active = NO;
        return;
    }
    if (CGRectGetHeight(container.bounds) >= 1 && !constraint.active) return;
    double target = RUINPanelTargetHeight(container);
    gPanelLastTargetHeight = target;
    BOOL changed = NO;
    if (!constraint) {
        constraint = [container.heightAnchor constraintEqualToConstant:target];
        constraint.priority = 999;
        objc_setAssociatedObject(container, &gPanelHeightConstraintKey, constraint,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        changed = YES;
    }
    if (constraint.constant != target) { constraint.constant = target; changed = YES; }
    if (!constraint.active) {
        constraint.active = YES;
        atomic_fetch_add_explicit(&gPanelHeightApplications, 1, memory_order_relaxed);
        changed = YES;
    }
    if (changed) [container invalidateIntrinsicContentSize];
}

%group RUINPanelHeightFix
%hook RUINPanelHeightContainer
- (CGSize)intrinsicContentSize
{
    CGSize size = %orig;
    if (size.height < 1 && RUINPanelHeightShouldFix(self))
        size.height = (CGFloat)RUINPanelTargetHeight(self);
    return size;
}
- (void)layoutSubviews
{
    %orig;
    RUINPanelHeightApply(self);
}
%end
%end

static void RUINInstallPanelHeightHooks(void) {
    if (atomic_load(&gPanelHeightHookInstalled)) return;
    Class cls = objc_getClass("_TtGC17LineMessagingUIV226ChatTopBottomContainerViewOS_16ChatBottomViewID_");
    if (!cls) {
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        for (unsigned int i = 0; i < count && !cls; i++) {
            const char *name = classes[i] ? class_getName(classes[i]) : NULL;
            if (name && strstr(name, "ChatTopBottomContainerView") && strstr(name, "ChatBottomViewID") &&
                RUINIsUIViewSubclass(classes[i])) cls = classes[i];
        }
        free(classes);
    }
    if (!cls) { gPanelHeightHookStatus = @"missing_class"; return; }
    Method layout = class_getInstanceMethod(cls, @selector(layoutSubviews));
    Method sizing = class_getInstanceMethod(cls, @selector(intrinsicContentSize));
    const char *layoutTypes = layout ? method_getTypeEncoding(layout) : NULL;
    const char *sizingTypes = sizing ? method_getTypeEncoding(sizing) : NULL;
    if (!layoutTypes || strcmp(layoutTypes, "v16@0:8") ||
        !sizingTypes || strcmp(sizingTypes, "{CGSize=dd}16@0:8")) {
        gPanelHeightHookStatus = @"abi_mismatch"; return;
    }
    %init(RUINPanelHeightFix, RUINPanelHeightContainer = cls);
    atomic_store(&gPanelHeightHookInstalled, true);
    gPanelHeightHookStatus = @"installed";
}

// The chat is SwiftUI: its composer decides whether to build the bottom
// panels from the trait idiom, not from UIDevice. The tablet idiom must
// stay projected for the login device-role determination, so instead of
// touching it, override only the chat view controller's trait collection
// to the phone idiom (its parent keeps the override; the rest of the app
// keeps the tablet traits). Same preference switch as the height fix.
// The parent that received RUIN's override is remembered on the chat
// controller, so turning the switch off clears only RUIN's own override and
// never one LINE installed itself.
static char RUINChatPanelTraitOverrideParentKey;

%group RUINChatPanelTraits
%hook RUINChatPanelTraitsController
- (void)viewDidAppear:(BOOL)animated
{
    %orig(animated);
    if (!atomic_load_explicit(&gTargetMatches, memory_order_relaxed)) return;
    RUINSetChatInterfaceVisible(YES);
}
- (void)viewDidDisappear:(BOOL)animated
{
    %orig(animated);
    if (!atomic_load_explicit(&gTargetMatches, memory_order_relaxed)) return;
    RUINSetChatInterfaceVisible(NO);
}
- (void)viewWillAppear:(BOOL)animated
{
    %orig(animated);
    if (!atomic_load_explicit(&gTargetMatches, memory_order_relaxed)) return;
    UIViewController *controller = (UIViewController *)self;
    UIViewController *parent = controller.parentViewController;
    UIViewController *overridden = objc_getAssociatedObject(controller, &RUINChatPanelTraitOverrideParentKey);
    if (!atomic_load_explicit(&gFixPanelHeightEnabled, memory_order_relaxed)) {
        if (overridden) {
            if (overridden == parent) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [parent setOverrideTraitCollection:nil forChildViewController:controller];
#pragma clang diagnostic pop
            }
            objc_setAssociatedObject(controller, &RUINChatPanelTraitOverrideParentKey, nil, OBJC_ASSOCIATION_ASSIGN);
        }
        return;
    }
    if (!parent) return;
    // Already projected to the phone idiom (by RUIN or natively): nothing to do.
    if (controller.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPhone) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UITraitCollection *phone = [UITraitCollection traitCollectionWithUserInterfaceIdiom:UIUserInterfaceIdiomPhone];
    UITraitCollection *combined = [UITraitCollection traitCollectionWithTraitsFromCollections:@[controller.traitCollection, phone]];
    [parent setOverrideTraitCollection:combined forChildViewController:controller];
#pragma clang diagnostic pop
    objc_setAssociatedObject(controller, &RUINChatPanelTraitOverrideParentKey, parent, OBJC_ASSOCIATION_ASSIGN);
    atomic_fetch_add_explicit(&gPanelTraitApplications, 1, memory_order_relaxed);
}
%end
%end

static void RUINInstallChatPanelTraitHooks(void) {
    if (atomic_load(&gPanelTraitHookInstalled)) return;
    Class cls = objc_getClass("LineMessagingUI.ChatViewController");
    if (!cls || ![cls isSubclassOfClass:UIViewController.class]) { gPanelTraitHookStatus = @"missing_class"; return; }
    Method appear = class_getInstanceMethod(cls, @selector(viewWillAppear:));
    Method didAppear = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    Method didDisappear = class_getInstanceMethod(cls, @selector(viewDidDisappear:));
    const char *types = appear ? method_getTypeEncoding(appear) : NULL;
    const char *didAppearTypes = didAppear ? method_getTypeEncoding(didAppear) : NULL;
    const char *didDisappearTypes = didDisappear ? method_getTypeEncoding(didDisappear) : NULL;
    if (!types || strcmp(types, "v20@0:8B16") ||
        !didAppearTypes || strcmp(didAppearTypes, "v20@0:8B16") ||
        !didDisappearTypes || strcmp(didDisappearTypes, "v20@0:8B16")) {
        gPanelTraitHookStatus = @"abi_mismatch";
        return;
    }
    %init(RUINChatPanelTraits, RUINChatPanelTraitsController = cls);
    atomic_store(&gPanelTraitHookInstalled, true);
    gPanelTraitHookStatus = @"installed";
}

// Home profile header customization: the avatar container moves to the
// left, the name/status/music views shift right of it, and the account's
// own MID is shown small at the bottom-right of the header.
static char RUINProfileHeaderMIDLabelKey;
static char RUINProfileHeaderShiftedViewsKey;

static void RUINFindProfileHeaderParts(UIView *view, UIView **container, UIView **decoration)
{
    for (UIView *sub in view.subviews) {
        NSString *cls = NSStringFromClass(sub.class);
        if ([cls isEqualToString:@"LineHomeTab.ListProfileContainerView"]) *container = sub;
        else if ([cls containsString:@"EventEffectDarkModeSupportImageView"]) *decoration = sub;
        RUINFindProfileHeaderParts(sub, container, decoration);
    }
}

static void RUINCollectLeftProfileViews(UIView *view, UIView *header, UIView *container, UIView *decoration, UIView *mid, CGRect containerRect, NSMutableArray<UIView *> *outViews)
{
    for (UIView *sub in view.subviews) {
        if (sub == container || sub == decoration || sub == mid) continue;
        if ([container isDescendantOfView:sub]) {
            RUINCollectLeftProfileViews(sub, header, container, decoration, mid, containerRect, outViews);
            continue;
        }
        sub.transform = CGAffineTransformIdentity;
        CGRect rect = [header convertRect:sub.bounds fromView:sub];
        if (!CGRectIsEmpty(rect) && CGRectGetWidth(rect) > 0 && CGRectGetHeight(rect) > 0 &&
            CGRectGetMinX(rect) < CGRectGetMinX(containerRect) &&
            CGRectGetMaxX(rect) <= CGRectGetMinX(containerRect) + 24.0) {
            [outViews addObject:sub];
            continue;
        }
        RUINCollectLeftProfileViews(sub, header, container, decoration, mid, containerRect, outViews);
    }
}

static void RUINResetTrackedProfileViews(UIView *header)
{
    NSHashTable<UIView *> *shifted = objc_getAssociatedObject(header, &RUINProfileHeaderShiftedViewsKey);
    for (UIView *view in shifted) {
        view.transform = CGAffineTransformIdentity;
    }
    [shifted removeAllObjects];
}

static void RUINTranslateViewInHeader(UIView *header, UIView *view, CGFloat targetX)
{
    if (!view.superview) return;
    view.transform = CGAffineTransformIdentity;
    CGRect layout = [header convertRect:view.bounds fromView:view];
    CGFloat dx = targetX - layout.origin.x;
    if (fabs(dx) > 0.5) view.transform = CGAffineTransformMakeTranslation(dx, 0);
}

static void RUINApplyProfileHeaderLayout(UIView *header)
{
    atomic_fetch_add_explicit(&gProfileHeaderApplyRuns, 1, memory_order_relaxed);
    RUINResetTrackedProfileViews(header);
    UIView *container = nil, *decoration = nil;
    RUINFindProfileHeaderParts(header, &container, &decoration);
    if (!container) return;
    atomic_store(&gProfileHeaderFoundContainer, true);
    container.transform = CGAffineTransformIdentity;
    if (decoration) decoration.transform = CGAffineTransformIdentity;
    CGRect containerRect = [header convertRect:container.bounds fromView:container];
    CGFloat width = CGRectGetWidth(header.bounds);
    CGFloat textX = 16.0 + CGRectGetWidth(containerRect) + 12.0;
    UILabel *mid = objc_getAssociatedObject(header, &RUINProfileHeaderMIDLabelKey);
    NSMutableArray<UIView *> *leftViews = [NSMutableArray array];
    RUINCollectLeftProfileViews(header, header, container, decoration, mid, containerRect, leftViews);
    // Frame writes are stomped by LINE's constraint/stack layout, so the
    // repositioning is a translation transform on top of the laid-out
    // frame; every pass restarts from identity, keeping it idempotent.
    RUINTranslateViewInHeader(header, container, 16);
    if (decoration) decoration.transform = container.transform;
    NSHashTable<UIView *> *shifted = objc_getAssociatedObject(header, &RUINProfileHeaderShiftedViewsKey);
    if (!shifted) {
        shifted = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(header, &RUINProfileHeaderShiftedViewsKey, shifted, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [shifted addObject:container];
    if (decoration) [shifted addObject:decoration];
    for (UIView *view in leftViews) {
        RUINTranslateViewInHeader(header, view, textX);
        [shifted addObject:view];
    }
    NSString *account = RUINChatCatalogAccount();
    if (account.length) {
        if (!mid) {
            mid = [UILabel new];
            mid.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
            mid.textColor = UIColor.secondaryLabelColor;
            mid.textAlignment = NSTextAlignmentRight;
            objc_setAssociatedObject(header, &RUINProfileHeaderMIDLabelKey, mid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [header addSubview:mid];
        }
        mid.text = account;
        mid.frame = CGRectMake(textX, CGRectGetHeight(header.bounds) - 20, MAX(0, width - textX - 16), 14);
        mid.hidden = NO;
    } else if (mid) {
        mid.hidden = YES;
    }
}

static void RUINResetProfileHeaderLayout(UIView *header)
{
    RUINResetTrackedProfileViews(header);
    UIView *container = nil, *decoration = nil;
    RUINFindProfileHeaderParts(header, &container, &decoration);
    if (container) container.transform = CGAffineTransformIdentity;
    if (decoration) decoration.transform = CGAffineTransformIdentity;
    UILabel *mid = objc_getAssociatedObject(header, &RUINProfileHeaderMIDLabelKey);
    if (mid) mid.hidden = YES;
}

static void RUINRefreshProfileHeaderViews(void)
{
    Class profileClass = objc_getClass("LineHomeTab.MyProfileView");
    if (!profileClass) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            [stack addObject:window];
    }
    NSUInteger visited = 0;
    while (stack.count && visited < 2048) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        visited++;
        if ([view isKindOfClass:profileClass]) {
            [view setNeedsLayout];
            [view layoutIfNeeded];
        }
        for (UIView *sub in view.subviews)
            if (visited + stack.count < 2048) [stack addObject:sub];
    }
}

%group RUINProfileHeader
%hook RUINProfileHeaderView
- (void)layoutSubviews
{
    %orig;
    if (!atomic_load_explicit(&gTargetMatches, memory_order_relaxed)) return;
    UIView *header = (UIView *)self;
    if (!atomic_load_explicit(&gProfileHeaderLeftEnabled, memory_order_relaxed)) {
        RUINResetProfileHeaderLayout(header);
        return;
    }
    RUINApplyProfileHeaderLayout(header);
    // The constraint engine may lay the header's children out after this
    // pass; re-apply once on the next main-loop turn so the result sticks.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (atomic_load_explicit(&gProfileHeaderLeftEnabled, memory_order_relaxed) && header.window)
            RUINApplyProfileHeaderLayout(header);
    });
}
- (void)didMoveToWindow
{
    %orig;
    UIView *header = (UIView *)self;
    if (!header.window || !atomic_load_explicit(&gTargetMatches, memory_order_relaxed) ||
        !atomic_load_explicit(&gProfileHeaderLeftEnabled, memory_order_relaxed)) return;
    RUINApplyProfileHeaderLayout(header);
}
%end
%end

static void RUINInstallProfileHeaderHooks(void)
{
    if (atomic_load(&gProfileHeaderHookInstalled)) return;
    Class cls = objc_getClass("LineHomeTab.MyProfileView");
    if (!cls || ![cls isSubclassOfClass:UIView.class]) { gProfileHeaderHookStatus = @"missing_class"; return; }
    Method layout = class_getInstanceMethod(cls, @selector(layoutSubviews));
    Method window = class_getInstanceMethod(cls, @selector(didMoveToWindow));
    const char *layoutTypes = layout ? method_getTypeEncoding(layout) : NULL;
    const char *windowTypes = window ? method_getTypeEncoding(window) : NULL;
    if (!layoutTypes || strcmp(layoutTypes, "v16@0:8") || !windowTypes || strcmp(windowTypes, "v16@0:8")) {
        gProfileHeaderHookStatus = @"abi_mismatch";
        return;
    }
    %init(RUINProfileHeader, RUINProfileHeaderView = cls);
    atomic_store(&gProfileHeaderHookInstalled, true);
    gProfileHeaderHookStatus = @"installed";
    if (atomic_load_explicit(&gProfileHeaderLeftEnabled, memory_order_relaxed))
        RUINRefreshProfileHeaderViews();
}

// SmartChannel shares a slot across ads, news and placeholders. The ad switch
// controls this exact Talk-top region, independent of its current payload.
static BOOL RUINTalkTopBannerShouldCollapse(UIView *view)
{
    return atomic_load_explicit(&gHideAdsEnabled, memory_order_relaxed) &&
        gTalkTopBannerClass && object_getClass(view) == gTalkTopBannerClass &&
        [view.superview isKindOfClass:UIStackView.class] &&
        [((UIStackView *)view.superview).arrangedSubviews containsObject:view] &&
        [RUINCopySwiftFieldTypeName(view, "bannerType") isEqual:@"LineChatTabUI.TopBannerBoxBannerType"] &&
        [RUINCopySwiftEnumCaseName(view, "bannerType") isEqual:@"smartChannel"];
}

static void RUINRelaxTalkBannerHeights(RUINTalkSmartTopBannerView *view)
{
    for (NSLayoutConstraint *constraint in view.constraints) {
        if (!constraint.active || constraint.firstItem != view || constraint.secondItem ||
            constraint.firstAttribute != NSLayoutAttributeHeight ||
            constraint.relation != NSLayoutRelationEqual || constraint.constant <= 0 ||
            constraint.priority != UILayoutPriorityRequired) continue;
        if (!view.ruin_talkAdHeightPriorities)
            view.ruin_talkAdHeightPriorities = [NSMapTable weakToStrongObjectsMapTable];
        [view.ruin_talkAdHeightPriorities setObject:@(constraint.priority) forKey:constraint];
        // UIStackView supplies the zero-height constraint for a hidden arranged view.
        constraint.active = NO;
        constraint.priority = UILayoutPriorityRequired - 1;
        constraint.active = YES;
    }
}

static void RUINRestoreTalkBannerHeights(RUINTalkSmartTopBannerView *view)
{
    UIView *parent = view.superview;
    BOOL deferActive = view.hidden && [parent isKindOfClass:UIStackView.class] &&
        [((UIStackView *)parent).arrangedSubviews containsObject:view];
    // A stack may remove its hiding constraint during a later layout pass.
    // Check only this banner and its direct parent, without touching that constraint.
    for (NSArray *constraints in @[view.constraints, parent.constraints ?: @[]]) {
        for (NSLayoutConstraint *constraint in constraints) {
            if (constraint.active && constraint.firstItem == view && !constraint.secondItem &&
                constraint.firstAttribute == NSLayoutAttributeHeight &&
                constraint.relation == NSLayoutRelationEqual && constraint.constant == 0 &&
                constraint.priority == UILayoutPriorityRequired) deferActive = YES;
        }
    }
    NSMutableArray *finished = nil;
    for (NSLayoutConstraint *constraint in view.ruin_talkAdHeightPriorities) {
        if (constraint.priority == UILayoutPriorityRequired - 1) {
            BOOL active = constraint.active;
            if (active && deferActive) continue;
            if (active) constraint.active = NO;
            constraint.priority = [[view.ruin_talkAdHeightPriorities objectForKey:constraint] floatValue];
            if (active) constraint.active = YES;
        }
        if (!finished) finished = [NSMutableArray array];
        [finished addObject:constraint];
    }
    for (NSLayoutConstraint *constraint in finished)
        [view.ruin_talkAdHeightPriorities removeObjectForKey:constraint];
    if (!view.ruin_talkAdHeightPriorities.count) view.ruin_talkAdHeightPriorities = nil;
}

static void RUINRefreshTalkTopBanner(UIView *view)
{
    if (!NSThread.isMainThread || !gTalkTopBannerClass || object_getClass(view) != gTalkTopBannerClass) return;
    RUINTalkSmartTopBannerView *banner = (id)view;
    if (banner.ruin_talkAdUpdating.boolValue) return;
    BOOL nativeHidden = banner.ruin_talkAdNativeHidden ? banner.ruin_talkAdNativeHidden.boolValue : banner.hidden;
    BOOL collapse = RUINTalkTopBannerShouldCollapse(view);
    if (banner.hidden == (nativeHidden || collapse)) {
        banner.ruin_talkAdUpdating = @YES;
        @try {
            if (collapse) RUINRelaxTalkBannerHeights(banner);
            else if (banner.ruin_talkAdHeightPriorities) {
                if (!banner.hidden) [banner.superview layoutIfNeeded];
                RUINRestoreTalkBannerHeights(banner);
            }
        } @finally { banner.ruin_talkAdUpdating = nil; }
        RUINRefreshTalkInsetsForBanner(view);
        return;
    }
    banner.hidden = nativeHidden;
    RUINRefreshTalkInsetsForBanner(view);
}

%group RUINTalkSmartTopBanner
%hook RUINTalkSmartTopBannerView
%property(nonatomic, strong) NSNumber *ruin_talkAdNativeHidden;
%property(nonatomic, strong) NSMapTable *ruin_talkAdHeightPriorities;
%property(nonatomic, strong) NSNumber *ruin_talkAdUpdating;
- (void)setHidden:(BOOL)hidden
{
    RUINTalkSmartTopBannerView *view = (id)self;
    if (view.ruin_talkAdUpdating.boolValue) { %orig(hidden); return; }
    view.ruin_talkAdUpdating = @YES;
    @try {
        atomic_fetch_add(&gTalkTopBannerUpdates, 1);
        view.ruin_talkAdNativeHidden = @(hidden);
        BOOL collapse = RUINTalkTopBannerShouldCollapse(view);
        if (collapse) {
            atomic_fetch_add(&gTalkTopBannerCollapses, 1);
            RUINRelaxTalkBannerHeights(view);
        }
        %orig(hidden || collapse);
        if (!collapse && view.ruin_talkAdHeightPriorities) {
            if (!view.hidden) [view.superview layoutIfNeeded];
            RUINRestoreTalkBannerHeights(view);
        }
    } @finally { view.ruin_talkAdUpdating = nil; }
    RUINRefreshTalkInsetsForBanner(view);
}
- (void)layoutSubviews { %orig; RUINRefreshTalkTopBanner(self); }
- (void)didMoveToWindow { %orig; RUINRefreshTalkTopBanner(self); }
%end
%end

static BOOL RUINPrepareMethodHook(Class cls, RUINMethodHook *hook)
{
    if (atomic_load(&hook->status) == RUINHookInstalled) return NO;
    if (!cls) {
        atomic_store(&hook->status, RUINHookMissingClass);
        return NO;
    }
    Method method = class_getInstanceMethod(cls, sel_registerName(hook->selectorName));
    if (!method) {
        atomic_store(&hook->status, RUINHookMissingSelector);
        return NO;
    }
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || strcmp(encoding, hook->encoding)) {
        atomic_store(&hook->status, RUINHookEncodingMismatch);
        return NO;
    }
    IMP original = method_getImplementation(method);
    if (!original) {
        atomic_store(&hook->status, RUINHookInstallFailed);
        return NO;
    }
    atomic_store_explicit(&hook->original, original, memory_order_release);
    return YES;
}

static void RUINInstallMethodHook(Class cls, RUINMethodHook *hook)
{
    if (!RUINPrepareMethodHook(cls, hook)) return;
    if (hook == &gSetControllersHook) {
        %init(RUINInterfaceSetControllers, RUINInterfaceSetControllersTarget = cls);
    }
    else if (hook == &gSetControllersAnimatedHook) {
        %init(RUINInterfaceSetControllersAnimated, RUINInterfaceSetControllersAnimatedTarget = cls);
    }
    else if (hook == &gTabsViewDidLoadHook) {
        %init(RUINInterfaceTabsViewDidLoad, RUINInterfaceTabsViewDidLoadTarget = cls);
    }
    else if (hook == &gTabsViewDidAppearHook) {
        %init(RUINInterfaceTabsViewDidAppear, RUINInterfaceTabsViewDidAppearTarget = cls);
    }
    else if (hook == &gVoiceButtonLayoutHook) {
        %init(RUINInterfaceVoiceButtonLayout, RUINInterfaceVoiceButtonLayoutTarget = cls);
    }
    else {
        atomic_store(&hook->status, RUINHookInstallFailed);
        return;
    }
    atomic_store(&hook->status, RUINHookInstalled);
    if (hook == &gVoiceButtonLayoutHook) gViewHooksGeneration++;
}

// Native page layout computes list insets from the SmartChannel model's height,
// independently of the arranged view's visibility. Reconcile only its stored
// content scroll views after native layout; no UIKit scroll class is hooked.
@interface RUINTalkInsetRecord : NSObject
@property(nonatomic, weak) UIViewController *page;
@property(nonatomic, weak) UIView *banner;
@property(nonatomic, weak) UIScrollView *scroll;
@property(nonatomic) BOOL hasContent, hasIndicator;
@property(nonatomic) CGFloat nativeContentTop, appliedContentTop, nativeIndicatorTop, appliedIndicatorTop;
@end
@implementation RUINTalkInsetRecord @end
static char gTalkInsetRecordKey;
static Class gTalkPageClass;
static NSHashTable<RUINTalkInsetRecord *> *gTalkInsetRecords;
static atomic_int gTalkInsetStatus = ATOMIC_VAR_INIT(RUINHookPending);
static atomic_uint_fast64_t gTalkInsetProjections;
static _Thread_local unsigned gTalkInsetDepth;

static CGFloat RUINTalkReservedHeight(RUINTalkInsetRecord *record)
{
    UIView *banner = record.banner;
    UIViewController *page = record.page;
    if (!page || object_getClass(page) != gTalkPageClass ||
        ![record.scroll isDescendantOfView:page.viewIfLoaded] ||
        ![banner isDescendantOfView:page.viewIfLoaded] ||
        !RUINTalkTopBannerShouldCollapse(banner)) return 0;
    CGFloat height = 0;
    for (NSLayoutConstraint *constraint in banner.constraints) {
        if (!constraint.active || constraint.firstItem != banner || constraint.secondItem ||
            constraint.firstAttribute != NSLayoutAttributeHeight || constraint.relation != NSLayoutRelationEqual ||
            constraint.priority < UILayoutPriorityRequired - 1 || !isfinite(constraint.constant) ||
            constraint.constant <= 0) continue;
        if (height && height != constraint.constant) return 0;
        height = constraint.constant;
    }
    return height;
}

static BOOL RUINTalkHasSmartBanner(RUINTalkInsetRecord *record)
{
    return gTalkTopBannerClass && object_getClass(record.banner) == gTalkTopBannerClass &&
        [RUINCopySwiftFieldTypeName(record.banner, "bannerType") isEqual:@"LineChatTabUI.TopBannerBoxBannerType"] &&
        [RUINCopySwiftEnumCaseName(record.banner, "bannerType") isEqual:@"smartChannel"];
}

static UIEdgeInsets RUINProjectTalkInsets(RUINTalkInsetRecord *record, UIEdgeInsets requested, BOOL indicator)
{
    // Another native banner kind owns its own inset values. Never restore a
    // cached SmartChannel baseline over that kind's native layout.
    if (!RUINTalkHasSmartBanner(record)) return requested;
    BOOL known = indicator ? record.hasIndicator : record.hasContent;
    CGFloat native = indicator ? record.nativeIndicatorTop : record.nativeContentTop;
    CGFloat applied = indicator ? record.appliedIndicatorTop : record.appliedContentTop;
    // Native read/modify/write of another edge must not subtract the slot twice.
    if (!known || requested.top != applied) native = requested.top;
    CGFloat height = RUINTalkReservedHeight(record);
    requested.top = isfinite(native) && height > 0 && native >= height ? native - height : native;
    if (indicator) {
        record.hasIndicator = YES; record.nativeIndicatorTop = native; record.appliedIndicatorTop = requested.top;
    } else {
        record.hasContent = YES; record.nativeContentTop = native; record.appliedContentTop = requested.top;
    }
    if (requested.top != native) atomic_fetch_add(&gTalkInsetProjections, 1);
    return requested;
}

static RUINTalkInsetRecord *RUINCurrentTalkInsetRecord(UIScrollView *scroll)
{
    if (!NSThread.isMainThread || gTalkInsetDepth) return nil;
    RUINTalkInsetRecord *record = objc_getAssociatedObject(scroll, &gTalkInsetRecordKey);
    UIViewController *page = record.page;
    if (!record || record.scroll != scroll || !page || object_getClass(page) != gTalkPageClass ||
        ![scroll isDescendantOfView:page.viewIfLoaded] ||
        ![record.banner isDescendantOfView:page.viewIfLoaded] ||
        !RUINTalkTopBannerShouldCollapse(record.banner)) return nil;
    return record;
}

static CGPoint RUINProjectTalkOffset(RUINTalkInsetRecord *record, CGPoint requested)
{
    UIScrollView *scroll = record.scroll;
    if (!record.hasContent || scroll.dragging || scroll.decelerating || !RUINTalkReservedHeight(record)) return requested;
    CGFloat removed = record.nativeContentTop - record.appliedContentTop;
    CGFloat nativeTop = record.nativeContentTop + scroll.adjustedContentInset.top - scroll.contentInset.top;
    if (removed > 0 && isfinite(nativeTop) && requested.y <= -nativeTop + 0.5) requested.y += removed;
    return requested;
}

typedef struct { CGPoint offset; CGFloat adjustedTop; BOOL atTop; } RUINTalkInsetAnchor;
static RUINTalkInsetAnchor RUINCaptureTalkInsetAnchor(RUINTalkInsetRecord *record)
{
    UIScrollView *scroll = record.scroll;
    UIEdgeInsets content = scroll.contentInset;
    CGFloat previousTop = scroll.adjustedContentInset.top;
    CGPoint offset = scroll.contentOffset;
    CGFloat previousAppliedTop = record.appliedContentTop + previousTop - content.top;
    if (record.hasContent && content.top != record.appliedContentTop &&
        fabs(offset.y + previousAppliedTop) <= 0.5) previousTop = previousAppliedTop;
    return (RUINTalkInsetAnchor){offset, previousTop,
        !scroll.dragging && !scroll.decelerating && offset.y <= -previousTop + 0.5};
}

static void RUINRestoreTalkInsetAnchor(RUINTalkInsetRecord *record, RUINTalkInsetAnchor anchor, BOOL nativeWrite)
{
    UIScrollView *scroll = record.scroll;
    CGFloat change = anchor.adjustedTop - scroll.adjustedContentInset.top;
    if (anchor.atTop && change && scroll.contentOffset.y == anchor.offset.y) {
        anchor.offset.y += change;
        [scroll setContentOffset:anchor.offset animated:NO];
    }
    if (nativeWrite) {
        CGPoint actual = scroll.contentOffset;
        CGPoint projected = RUINProjectTalkOffset(record, actual);
        if (actual.y != projected.y) [scroll setContentOffset:projected animated:NO];
    }
}

static void RUINApplyTalkInsetRecord(RUINTalkInsetRecord *record)
{
    UIScrollView *scroll = record.scroll;
    if (!scroll || gTalkInsetDepth || !RUINTalkHasSmartBanner(record)) return;
    gTalkInsetDepth++;
    @try {
        RUINTalkInsetAnchor anchor = RUINCaptureTalkInsetAnchor(record);
        UIEdgeInsets content = scroll.contentInset;
        UIEdgeInsets projected = RUINProjectTalkInsets(record, content, NO);
        if (content.top != projected.top) scroll.contentInset = projected;
        RUINRestoreTalkInsetAnchor(record, anchor, NO);
        UIEdgeInsets indicator = scroll.verticalScrollIndicatorInsets;
        projected = RUINProjectTalkInsets(record, indicator, YES);
        if (indicator.top != projected.top) scroll.verticalScrollIndicatorInsets = projected;
    } @finally { gTalkInsetDepth--; }
}

static void RUINRefreshTalkInsetsForBanner(UIView *banner)
{
    if (gTalkInsetDepth) return;
    for (RUINTalkInsetRecord *record in gTalkInsetRecords)
        if (record.banner == banner) RUINApplyTalkInsetRecord(record);
}

static void RUINBindTalkPageInsets(UIViewController *page)
{
    if (!NSThread.isMainThread || gTalkInsetDepth || object_getClass(page) != gTalkPageClass || !page.viewIfLoaded) return;
    id banner = RUINCopySwiftField(page, "topBannerBoxView");
    id stack = RUINCopySwiftField(page, "topBannerBoxBackgroundView");
    id headerScroll = RUINCopySwiftField(page, "$__lazy_storage_$_topBannerBoxScrollView");
    if (!gTalkTopBannerClass || object_getClass(banner) != gTalkTopBannerClass ||
        ![stack isKindOfClass:UIStackView.class] || ![headerScroll isKindOfClass:UIScrollView.class] ||
        [(UIView *)banner superview] != stack || [(UIView *)stack superview] != headerScroll) return;
    const char *paths[] = {"chatSubTabViewController.$__lazy_storage_$_contentViewController",
        "friendSubTabViewController.gcsViewController"};
    const char *classes[] = {"_TtC13LineChatTabUI22ChatListViewController", "_TtC19LineGeneralContents17GCSViewController"};
    const char *scrollFields[] = {"tableView", "$__lazy_storage_$_collectionView"};
    for (NSUInteger i = 0; i < 2; i++) {
        id content = RUINCopySwiftField(page, paths[i]);
        Class cls = objc_getClass(classes[i]);
        if (!cls || object_getClass(content) != cls) continue;
        id scroll = RUINCopySwiftField(content, scrollFields[i]);
        if (![scroll isKindOfClass:i == 0 ? UITableView.class : UICollectionView.class] || scroll == headerScroll ||
            ![(UIView *)scroll isDescendantOfView:page.viewIfLoaded]) continue;
        BOOL owned = NO;
        NSUInteger depth = 0;
        for (UIViewController *parent = content; parent && depth++ < 8; parent = parent.parentViewController)
            if (parent == page) { owned = YES; break; }
        if (!owned) continue;
        RUINTalkInsetRecord *record = objc_getAssociatedObject(scroll, &gTalkInsetRecordKey);
        if (!record) {
            record = [RUINTalkInsetRecord new]; record.scroll = scroll;
            objc_setAssociatedObject(scroll, &gTalkInsetRecordKey, record, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [gTalkInsetRecords addObject:record];
        }
        record.page = page; record.banner = banner;
        RUINApplyTalkInsetRecord(record);
    }
}

%group RUINTalkPageInsets
%hook RUINTalkPageInsetsController
- (void)viewDidLayoutSubviews { %orig; RUINBindTalkPageInsets(self); }
%end
%end

%group RUINTalkTableInsets
%hook RUINTalkInsetTableView
- (void)setContentInset:(UIEdgeInsets)insets
{
    RUINTalkInsetRecord *record = RUINCurrentTalkInsetRecord((id)self);
    if (!record) { %orig(insets); return; }
    gTalkInsetDepth++;
    @try {
        RUINTalkInsetAnchor anchor = RUINCaptureTalkInsetAnchor(record);
        %orig(RUINProjectTalkInsets(record, insets, NO));
        RUINRestoreTalkInsetAnchor(record, anchor, YES);
    } @finally { gTalkInsetDepth--; }
}
- (void)setVerticalScrollIndicatorInsets:(UIEdgeInsets)insets
{
    RUINTalkInsetRecord *record = RUINCurrentTalkInsetRecord((id)self);
    if (!record) { %orig(insets); return; }
    gTalkInsetDepth++;
    @try { %orig(RUINProjectTalkInsets(record, insets, YES)); } @finally { gTalkInsetDepth--; }
}
- (void)setContentOffset:(CGPoint)offset
{
    RUINTalkInsetRecord *record = RUINCurrentTalkInsetRecord((id)self);
    if (!record) { %orig(offset); return; }
    gTalkInsetDepth++;
    @try { %orig(RUINProjectTalkOffset(record, offset)); } @finally { gTalkInsetDepth--; }
}
- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated
{
    RUINTalkInsetRecord *record = RUINCurrentTalkInsetRecord((id)self);
    if (!record) { %orig(offset, animated); return; }
    gTalkInsetDepth++;
    @try { %orig(RUINProjectTalkOffset(record, offset), animated); } @finally { gTalkInsetDepth--; }
}
%end
%end

%group RUINTalkCollectionInsets
%hook RUINTalkInsetCollectionView
- (void)setContentInset:(UIEdgeInsets)insets
{
    RUINTalkInsetRecord *record = RUINCurrentTalkInsetRecord((id)self);
    if (!record) { %orig(insets); return; }
    gTalkInsetDepth++;
    @try {
        RUINTalkInsetAnchor anchor = RUINCaptureTalkInsetAnchor(record);
        %orig(RUINProjectTalkInsets(record, insets, NO));
        RUINRestoreTalkInsetAnchor(record, anchor, YES);
    } @finally { gTalkInsetDepth--; }
}
- (void)setVerticalScrollIndicatorInsets:(UIEdgeInsets)insets
{
    RUINTalkInsetRecord *record = RUINCurrentTalkInsetRecord((id)self);
    if (!record) { %orig(insets); return; }
    gTalkInsetDepth++;
    @try { %orig(RUINProjectTalkInsets(record, insets, YES)); } @finally { gTalkInsetDepth--; }
}
- (void)setContentOffset:(CGPoint)offset
{
    RUINTalkInsetRecord *record = RUINCurrentTalkInsetRecord((id)self);
    if (!record) { %orig(offset); return; }
    gTalkInsetDepth++;
    @try { %orig(RUINProjectTalkOffset(record, offset)); } @finally { gTalkInsetDepth--; }
}
- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated
{
    RUINTalkInsetRecord *record = RUINCurrentTalkInsetRecord((id)self);
    if (!record) { %orig(offset, animated); return; }
    gTalkInsetDepth++;
    @try { %orig(RUINProjectTalkOffset(record, offset), animated); } @finally { gTalkInsetDepth--; }
}
%end
%end

static void RUINInstallTalkInsetHooks(void)
{
    if (atomic_load(&gTalkInsetStatus) == RUINHookInstalled) return;
    Class page = objc_getClass("_TtC13LineChatTabUI25ChatTabPageViewController");
    if (!page) { atomic_store(&gTalkInsetStatus, RUINHookMissingClass); return; }
    if (![page isSubclassOfClass:UIViewController.class]) {
        atomic_store(&gTalkInsetStatus, RUINHookClassTypeMismatch); return;
    }
    Method method = class_getInstanceMethod(page, @selector(viewDidLayoutSubviews));
    if (!method || strcmp(method_getTypeEncoding(method) ?: "", "v16@0:8") || !method_getImplementation(method)) {
        atomic_store(&gTalkInsetStatus, RUINHookEncodingMismatch); return;
    }
    char pointEncoding[128], animatedPointEncoding[128];
    snprintf(pointEncoding, sizeof(pointEncoding), "v32@0:8%s16", @encode(CGPoint));
    snprintf(animatedPointEncoding, sizeof(animatedPointEncoding), "v36@0:8%s16B32", @encode(CGPoint));
    SEL setters[] = {@selector(setContentInset:), @selector(setVerticalScrollIndicatorInsets:),
        @selector(setContentOffset:), @selector(setContentOffset:animated:)};
    const char *encodings[] = {"v48@0:8{UIEdgeInsets=dddd}16", "v48@0:8{UIEdgeInsets=dddd}16",
        pointEncoding, animatedPointEncoding};
    Class families[] = {UITableView.class, UICollectionView.class};
    for (NSUInteger i = 0; i < 2; i++) {
        for (NSUInteger j = 0; j < 4; j++) {
            Method setter = class_getInstanceMethod(families[i], setters[j]);
            if (!setter || strcmp(method_getTypeEncoding(setter) ?: "", encodings[j]) || !method_getImplementation(setter)) {
                atomic_store(&gTalkInsetStatus, RUINHookEncodingMismatch); return;
            }
        }
    }
    gTalkPageClass = page;
    gTalkInsetRecords = [NSHashTable weakObjectsHashTable];
    %init(RUINTalkPageInsets, RUINTalkPageInsetsController = page);
    %init(RUINTalkTableInsets, RUINTalkInsetTableView = UITableView.class);
    %init(RUINTalkCollectionInsets, RUINTalkInsetCollectionView = UICollectionView.class);
    atomic_store(&gTalkInsetStatus, RUINHookInstalled);
    gViewHooksGeneration++;
}

static NSArray *RUINTalkInsetDiagnostics(void)
{
    const char *enabled = getenv("RUIN_ENABLE_RUNTIME_INSPECTOR");
    if (!NSThread.isMainThread || !enabled || strcmp(enabled, "1")) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (RUINTalkInsetRecord *record in gTalkInsetRecords) {
        UIScrollView *scroll = record.scroll;
        if (!scroll || rows.count >= 8) continue;
        [rows addObject:@{@"class":NSStringFromClass(scroll.class),
            @"nativeContentTop":@(record.nativeContentTop), @"contentTop":@(scroll.contentInset.top),
            @"adjustedContentTop":@(scroll.adjustedContentInset.top),
            @"indicatorTop":@(scroll.verticalScrollIndicatorInsets.top),
            @"offsetY":@(scroll.contentOffset.y), @"removedHeight":@(RUINTalkReservedHeight(record))}];
    }
    return rows;
}

static void RUINInstallViewTargetHooks(RUINViewTargetIndex index, RUINViewTarget *target)
{
    // Validate both methods before initializing their shared group. UIKit view
    // subclasses must expose both signatures; mismatches remain retryable.
    BOOL hiddenReady = RUINPrepareMethodHook(target->cls, &target->setHidden);
    BOOL movedReady = RUINPrepareMethodHook(target->cls, &target->didMoveToWindow);
    if (!hiddenReady || !movedReady) return;
    switch (index) {
        case RUINViewLADHomeBannerContainer: {
            %init(RUINHideLADHomeBannerContainer, RUINLADHomeBannerContainer = target->cls);
            break;
        }
        case RUINViewChatTabGoogleAdContainerView: {
            %init(RUINHideChatTabGoogleAdContainerView, RUINChatTabGoogleAdContainerView = target->cls);
            break;
        }
        case RUINViewAdVoomView: {
            %init(RUINHideAdVoomView, RUINAdVoomView = target->cls);
            break;
        }
        case RUINViewAdTimelineVideoAdView: {
            %init(RUINHideAdTimelineVideoAdView, RUINAdTimelineVideoAdView = target->cls);
            break;
        }
        case RUINViewAdTimelineMiniPopupCell: {
            %init(RUINHideAdTimelineMiniPopupCell, RUINAdTimelineMiniPopupCell = target->cls);
            break;
        }
        case RUINViewAdTimelineCarouselContentsCell: {
            %init(RUINHideAdTimelineCarouselContentsCell, RUINAdTimelineCarouselContentsCell = target->cls);
            break;
        }
        case RUINViewAdTimelineCarouselView: {
            %init(RUINHideAdTimelineCarouselView, RUINAdTimelineCarouselView = target->cls);
            break;
        }
        case RUINViewAdWalletBigBannerCarouselView: {
            %init(RUINHideAdWalletBigBannerCarouselView, RUINAdWalletBigBannerCarouselView = target->cls);
            break;
        }
        case RUINViewAdWalletBigBannerCarouselViewItemCell: {
            %init(RUINHideAdWalletBigBannerCarouselViewItemCell, RUINAdWalletBigBannerCarouselViewItemCell = target->cls);
            break;
        }
        case RUINViewAdWalletBigBannerView: {
            %init(RUINHideAdWalletBigBannerView, RUINAdWalletBigBannerView = target->cls);
            break;
        }
        case RUINViewAdWalletCarouselView: {
            %init(RUINHideAdWalletCarouselView, RUINAdWalletCarouselView = target->cls);
            break;
        }
        case RUINViewAdWalletCarouselViewItemCell: {
            %init(RUINHideAdWalletCarouselViewItemCell, RUINAdWalletCarouselViewItemCell = target->cls);
            break;
        }
        case RUINViewAdWalletInfeedView: {
            %init(RUINHideAdWalletInfeedView, RUINAdWalletInfeedView = target->cls);
            break;
        }
        case RUINViewAdWalletNativeBannerView: {
            %init(RUINHideAdWalletNativeBannerView, RUINAdWalletNativeBannerView = target->cls);
            break;
        }
        case RUINViewAdWalletView: {
            %init(RUINHideAdWalletView, RUINAdWalletView = target->cls);
            break;
        }
        case RUINViewVOOMVideoADContentCell: {
            %init(RUINHideVOOMVideoADContentCell, RUINVOOMVideoADContentCell = target->cls);
            break;
        }
        case RUINViewContentRecommendationView: {
            %init(RUINHideContentRecommendationView, RUINContentRecommendationView = target->cls);
            break;
        }
        case RUINViewFriendRecommendationTableViewCell: {
            %init(RUINHideFriendRecommendationTableViewCell, RUINFriendRecommendationTableViewCell = target->cls);
            break;
        }
        case RUINViewRecommendAddFriendPanelView: {
            %init(RUINHideRecommendAddFriendPanelView, RUINRecommendAddFriendPanelView = target->cls);
            break;
        }
        case RUINViewRecentRecommendView: {
            %init(RUINHideRecentRecommendView, RUINRecentRecommendView = target->cls);
            break;
        }
        case RUINViewRecommendFriendView: {
            %init(RUINHideRecommendFriendView, RUINRecommendFriendView = target->cls);
            break;
        }
        case RUINViewMessageRecommendationView: {
            %init(RUINHideMessageRecommendationView, RUINMessageRecommendationView = target->cls);
            break;
        }
        case RUINViewRecommendedFriendView: {
            %init(RUINHideRecommendedFriendView, RUINRecommendedFriendView = target->cls);
            break;
        }
        case RUINViewChatInputBarButton: {
            %init(RUINHideChatInputBarButton, RUINChatInputBarButton = target->cls);
            break;
        }
        case RUINViewAITSChipMenuView: {
            %init(RUINHideAITSChipMenuView, RUINAITSChipMenuView = target->cls);
            break;
        }
        default: return;
    }
    atomic_store(&target->setHidden.status, RUINHookInstalled);
    atomic_store(&target->didMoveToWindow.status, RUINHookInstalled);
    gViewHooksGeneration++;
}

static BOOL RUINIsUIViewSubclass(Class cls)
{
    for (Class cursor = cls; cursor; cursor = class_getSuperclass(cursor))
        if (cursor == UIView.class) return YES;
    return NO;
}

static void RUINInstallTalkTopBannerHooks(void)
{
    if (atomic_load(&gTalkTopBannerStatus) == RUINHookInstalled) return;
    Class cls = objc_getClass("_TtC13LineChatTabUI16TopBannerBoxView");
    if (!cls) { atomic_store(&gTalkTopBannerStatus, RUINHookMissingClass); return; }
    if (!RUINIsUIViewSubclass(cls)) {
        atomic_store(&gTalkTopBannerStatus, RUINHookClassTypeMismatch); return;
    }
    const char *selectors[] = {"setHidden:", "didMoveToWindow", "layoutSubviews"};
    for (NSUInteger j = 0; j < 3; j++) {
        Method method = class_getInstanceMethod(cls, sel_registerName(selectors[j]));
        if (!method) { atomic_store(&gTalkTopBannerStatus, RUINHookMissingSelector); return; }
        const char *expected = j ? "v16@0:8" : "v20@0:8B16";
        if (strcmp(method_getTypeEncoding(method) ?: "", expected) || !method_getImplementation(method)) {
            atomic_store(&gTalkTopBannerStatus, RUINHookEncodingMismatch); return;
        }
    }
    gTalkTopBannerClass = cls;
    %init(RUINTalkSmartTopBanner, RUINTalkSmartTopBannerView = cls);
    atomic_store(&gTalkTopBannerStatus, RUINHookInstalled);
    gViewHooksGeneration++;
}

static void RUINMarkHooksVersionGated(void)
{
    RUINMethodHook *tabHooks[] = {
        &gSetControllersHook, &gSetControllersAnimatedHook,
        &gTabsViewDidLoadHook, &gTabsViewDidAppearHook
    };
    for (NSUInteger i = 0; i < sizeof(tabHooks) / sizeof(tabHooks[0]); i++)
        if (atomic_load(&tabHooks[i]->status) != RUINHookInstalled)
            atomic_store(&tabHooks[i]->status, RUINHookVersionGated);
    if (atomic_load(&gVoiceButtonLayoutHook.status) != RUINHookInstalled)
        atomic_store(&gVoiceButtonLayoutHook.status, RUINHookVersionGated);
    for (NSUInteger i = 0; i < sizeof(gViewTargets) / sizeof(gViewTargets[0]); i++) {
        RUINMethodHook *hooks[] = { &gViewTargets[i].setHidden, &gViewTargets[i].didMoveToWindow };
        for (NSUInteger j = 0; j < 2; j++)
            if (atomic_load(&hooks[j]->status) != RUINHookInstalled)
                atomic_store(&hooks[j]->status, RUINHookVersionGated);
    }
}

static void RUINInstallHooks(void)
{
    RUINInstallTalkTopBannerHooks();
    RUINInstallTalkInsetHooks();
    RUINInstallPanelHeightHooks();
    RUINInstallChatPanelTraitHooks();
    RUINInstallProfileHeaderHooks();
    if (!gTabConfigurationHookInstalled) {
        Class delegate = objc_getClass("_TtC4LINE11AppDelegate");
        Method method = delegate ? class_getInstanceMethod(delegate,
            @selector(didReceiveChangedConfigurationNotification:)) : NULL;
        if (method && !strcmp(method_getTypeEncoding(method), "v24@0:8@16")) {
            %init(RUINNativeTabConfiguration, RUINNativeTabConfigurationDelegate=delegate);
            gTabConfigurationHookInstalled = YES;
        }
    }
    Class tabClass = objc_getClass(gSetControllersHook.className);
    RUINMethodHook *tabHooks[] = {
        &gSetControllersHook, &gSetControllersAnimatedHook,
        &gTabsViewDidLoadHook, &gTabsViewDidAppearHook
    };
    for (NSUInteger i = 0; i < sizeof(tabHooks) / sizeof(tabHooks[0]); i++)
        RUINInstallMethodHook(tabClass, tabHooks[i]);

    if (!gTrackedTabControllers) gTrackedTabControllers = [NSHashTable weakObjectsHashTable];
    for (NSUInteger i = 0; i < sizeof(gViewTargets) / sizeof(gViewTargets[0]); i++) {
        RUINViewTarget *target = &gViewTargets[i];
        target->cls = objc_getClass(target->className);
        if (!target->cls) {
            atomic_store(&target->setHidden.status, RUINHookMissingClass);
            atomic_store(&target->didMoveToWindow.status, RUINHookMissingClass);
            continue;
        }
        if (!RUINIsUIViewSubclass(target->cls)) {
            atomic_store(&target->setHidden.status, RUINHookClassTypeMismatch);
            atomic_store(&target->didMoveToWindow.status, RUINHookClassTypeMismatch);
            continue;
        }
        RUINInstallViewTargetHooks((RUINViewTargetIndex)i, target);
        if (target->group == RUINHideGroupVoiceInput)
            RUINInstallMethodHook(target->cls, &gVoiceButtonLayoutHook);
        if (target->group == RUINHideGroupAgentI && !gAgentIntrinsicInstalled) {
            Method size = class_getInstanceMethod(target->cls, @selector(intrinsicContentSize));
            if (size && !strcmp(method_getTypeEncoding(size), "{CGSize=dd}16@0:8")) {
                %init(RUINAgentIntrinsicLayout, RUINAgentIntrinsicView = target->cls);
                gAgentIntrinsicInstalled = YES;
                gViewHooksGeneration++;
            }
        }
    }
}

static RUINViewTarget *RUINViewTargetForObject(id object)
{
    for (Class actualClass = object_getClass(object); actualClass; actualClass = class_getSuperclass(actualClass))
        for (NSUInteger i = 0; i < sizeof(gViewTargets) / sizeof(gViewTargets[0]); i++)
            if (gViewTargets[i].cls && actualClass == gViewTargets[i].cls) return &gViewTargets[i];
    return NULL;
}

static BOOL RUINIsHideGroupEnabled(RUINHideGroup group)
{
    switch (group) {
        case RUINHideGroupAds: return atomic_load_explicit(&gHideAdsEnabled, memory_order_relaxed);
        case RUINHideGroupRecommendations: return atomic_load_explicit(&gHideRecommendationsEnabled, memory_order_relaxed);
        case RUINHideGroupVoiceInput: return atomic_load_explicit(&gHideVoiceInputEnabled, memory_order_relaxed);
        case RUINHideGroupAgentI: return atomic_load_explicit(&gHideAgentIEnabled, memory_order_relaxed);
    }
    return NO;
}

static BOOL RUINShouldHideView(RUINViewTarget *target, id view)
{
    if (!RUINIsHideGroupEnabled(target->group)) return NO;
    if (target->group != RUINHideGroupVoiceInput) return YES;
    // The class, stored field and payloadless enum are pinned to LINE26.16.
    // No image/title matching: the other composer buttons use this class too.
    // This helper reports the live value's type, not immutable field metadata.
    // Preserve both checks when native composer objects are reused.
    atomic_fetch_add(&gVoiceTypeReflections, 1);
    if (![RUINCopySwiftFieldTypeName(view, "kind") isEqualToString:@"LineMessagingUIV2.ChatInputBarButtonKind"])
        return NO;
    return [RUINCopySwiftEnumCaseName(view, "kind") isEqualToString:@"audio"];
}

static void RUINHideView(UIView *view)
{
    if (!objc_getAssociatedObject(view, &gOriginalHiddenStateKey))
        objc_setAssociatedObject(view, &gOriginalHiddenStateKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (view.hidden) return;
    gInternalHiddenUpdateDepth++;
    view.hidden = YES;
    gInternalHiddenUpdateDepth--;
    RUINViewTarget *target = RUINViewTargetForObject(view);
    if (target && target->group == RUINHideGroupAgentI) {
        [view invalidateIntrinsicContentSize]; [view.superview setNeedsLayout];
    }
}

static void RUINRestoreView(UIView *view)
{
    NSNumber *original = objc_getAssociatedObject(view, &gOriginalHiddenStateKey);
    if (!original) return;
    if (view.hidden == original.boolValue) {
        objc_setAssociatedObject(view, &gOriginalHiddenStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    gInternalHiddenUpdateDepth++;
    view.hidden = original.boolValue;
    gInternalHiddenUpdateDepth--;
    objc_setAssociatedObject(view, &gOriginalHiddenStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RUINViewTarget *target = RUINViewTargetForObject(view);
    if (target && target->group == RUINHideGroupAgentI) {
        [view invalidateIntrinsicContentSize]; [view.superview setNeedsLayout];
    }
}

static void RUINForceHidden(RUINViewTarget *target, id self, SEL selector, BOOL hidden)
{
    atomic_fetch_add_explicit(&target->setHidden.calls, 1, memory_order_relaxed);
    IMP original = atomic_load_explicit(&target->setHidden.original, memory_order_acquire);
    if (!original) return;

    if (gHiddenSetterDepth++ || gInternalHiddenUpdateDepth) {
        ((void (*)(id, SEL, BOOL))original)(self, selector, hidden);
        gHiddenSetterDepth--;
        return;
    }
    if (!RUINShouldHideView(target, self)) {
        objc_setAssociatedObject(self, &gOriginalHiddenStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, BOOL))original)(self, selector, hidden);
        gHiddenSetterDepth--;
        return;
    }

    objc_setAssociatedObject(self, &gOriginalHiddenStateKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, BOOL))original)(self, selector, YES);
    gHiddenSetterDepth--;
}

static void RUINViewDidMoveToWindow(RUINViewTarget *target, id self, SEL selector)
{
    atomic_fetch_add_explicit(&target->didMoveToWindow.calls, 1, memory_order_relaxed);
    IMP original = atomic_load_explicit(&target->didMoveToWindow.original, memory_order_acquire);
    if (original) ((void (*)(id, SEL))original)(self, selector);
    if (RUINShouldHideView(target, self)) RUINHideView((UIView *)self);
    else RUINRestoreView((UIView *)self);
}

static void RUINVoiceButtonLayout(id self, SEL selector)
{
    atomic_fetch_add(&gVoiceButtonLayoutHook.calls, 1);
    IMP original = atomic_load(&gVoiceButtonLayoutHook.original);
    if (original) ((void (*)(id, SEL))original)(self, selector);
    RUINViewTarget *target = RUINViewTargetForObject(self);
    if (!target || target->group != RUINHideGroupVoiceInput) return;
    // Native composer updates can change .audio into .send after setHidden:.
    // Recheck the settled role and restore LINE's requested visibility.
    if (RUINShouldHideView(target, self)) {
        if (![(UIView *)self isHidden]) RUINHideView(self);
    } else {
        if (objc_getAssociatedObject(self, &gOriginalHiddenStateKey))
            atomic_fetch_add(&gVoiceKindRestorations, 1);
        RUINRestoreView(self);
    }
}

static void RUINRefreshViewTree(UIView *view)
{
    RUINRefreshTalkTopBanner(view);
    RUINViewTarget *target = RUINViewTargetForObject(view);
    if (target) {
        if (RUINShouldHideView(target, view)) RUINHideView(view);
        else RUINRestoreView(view);
    }
    for (UIView *child in view.subviews) RUINRefreshViewTree(child);
}

static void RUINRefreshVisibleViews(void)
{
    atomic_fetch_add(&gVisibleViewScans, 1);
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) RUINRefreshViewTree(window);
    }
}

static NSString *RUINTabIdentifier(RUINTabKind kind)
{
    switch (kind) {
        case RUINTabHomeKind: return RUINInterfaceTabHome;
        case RUINTabTalkKind: return RUINInterfaceTabTalk;
        case RUINTabVOOMKind: return RUINInterfaceTabVOOM;
        case RUINTabWalletKind: return RUINInterfaceTabWallet;
        case RUINTabShoppingKind: return RUINInterfaceTabShopping;
        case RUINTabNewsKind: return RUINInterfaceTabNews;
        case RUINTabCallKind: return RUINInterfaceTabCall;
        case RUINTabSettingsKind: return RUINInterfaceTabSettings;
        case RUINTabAppsKind: return RUINInterfaceTabApps;
        default: return nil;
    }
}

static RUINTabKind RUINKindForIdentifier(NSString *identifier)
{
    if ([identifier isEqualToString:RUINInterfaceTabHome]) return RUINTabHomeKind;
    if ([identifier isEqualToString:RUINInterfaceTabTalk]) return RUINTabTalkKind;
    if ([identifier isEqualToString:RUINInterfaceTabVOOM]) return RUINTabVOOMKind;
    if ([identifier isEqualToString:RUINInterfaceTabWallet]) return RUINTabWalletKind;
    if ([identifier isEqualToString:RUINInterfaceTabShopping]) return RUINTabShoppingKind;
    if ([identifier isEqualToString:RUINInterfaceTabNews]) return RUINTabNewsKind;
    if ([identifier isEqualToString:RUINInterfaceTabCall]) return RUINTabCallKind;
    if ([identifier isEqualToString:RUINInterfaceTabSettings]) return RUINTabSettingsKind;
    if ([identifier isEqualToString:RUINInterfaceTabApps]) return RUINTabAppsKind;
    return RUINTabUnknown;
}

static BOOL RUINControllerHasClass(UIViewController *controller, const char * const *names, size_t count)
{
    for (size_t i = 0; i < count; i++) {
        Class cls = objc_getClass(names[i]);
        if (cls && [controller isKindOfClass:cls]) return YES;
    }
    return NO;
}

static RUINTabKind RUINKindForControllerClass(UIViewController *controller)
{
    static const char * const home[] = {
        "_TtC11LineHomeTab23FriendTabViewController",
        "_TtC8LineHome18HomeViewController", "HomeViewController"
    };
    static const char * const talk[] = {
        "_TtC13LineChatTabUI25ChatTabPageViewController",
        "_TtC13LineChatTabUI24ChatSubTabViewController",
        "_TtC11LineChatTab20ChatFolderController",
        "_TtC13LineChatTabUI23ChatFolderTabController",
        "LineChatTabController", "ChatFolderController"
    };
    static const char * const voom[] = {
        "_TtC12LineTimeline25TimelineTabViewController",
        "_TtC4LINE31VoomSecondDepthTabBarController", "TimelineTabViewController"
    };
    static const char * const wallet[] = {
        "_TtC10LineWallet20WalletViewController", "WalletViewController"
    };
    static const char * const shopping[] = {
        "_TtC17LineTWCommerceTab27TWCommerceTabViewController",
        "_TtC15LineCommerceTab25CommerceTabViewController"
    };
    static const char * const apps[] = {"_TtC10LineWallet21MiniTabViewController"};
    static const char * const news[] = {
        "_TtC14LineNewsRowTab24NewsRowTabViewController", "NewsRowTabViewController",
        "LINE.NewsMainViewController"
    };
    static const char * const call[] = {
        "_TtC11LineCallTab28CallTabRecentsViewController", "CallTabRecentsViewController"
    };
    static const char * const settings[] = {
        "_TtC4LINE22SettingsViewController", "SettingsViewController"
    };
    if (RUINControllerHasClass(controller, home, sizeof(home) / sizeof(home[0]))) return RUINTabHomeKind;
    if (RUINControllerHasClass(controller, talk, sizeof(talk) / sizeof(talk[0]))) return RUINTabTalkKind;
    if (RUINControllerHasClass(controller, voom, sizeof(voom) / sizeof(voom[0]))) return RUINTabVOOMKind;
    if (RUINControllerHasClass(controller, wallet, sizeof(wallet) / sizeof(wallet[0]))) return RUINTabWalletKind;
    if (RUINControllerHasClass(controller, shopping, sizeof(shopping) / sizeof(shopping[0]))) return RUINTabShoppingKind;
    if (RUINControllerHasClass(controller, apps, sizeof(apps) / sizeof(apps[0]))) return RUINTabAppsKind;
    if (RUINControllerHasClass(controller, news, sizeof(news) / sizeof(news[0]))) return RUINTabNewsKind;
    if (RUINControllerHasClass(controller, call, sizeof(call) / sizeof(call[0]))) return RUINTabCallKind;
    if (RUINControllerHasClass(controller, settings, sizeof(settings) / sizeof(settings[0]))) return RUINTabSettingsKind;
    return RUINTabUnknown;
}

static BOOL RUINTabTitleMatchesNativeKey(NSString *title, NSString *key, NSString *japaneseFallback)
{
    NSString *localizedTitle = [NSBundle.mainBundle localizedStringForKey:key value:japaneseFallback table:nil];
    return [title isEqualToString:japaneseFallback] ||
        (title.length && [title caseInsensitiveCompare:localizedTitle] == NSOrderedSame);
}

static RUINTabKind RUINKindForTitle(NSString *title)
{
    if (RUINTabTitleMatchesNativeKey(title, @"access.home", @"ホーム")) return RUINTabHomeKind;
    if (RUINTabTitleMatchesNativeKey(title, @"common.action.chat", @"トーク")) return RUINTabTalkKind;
    if ([title isEqualToString:@"VOOM"]) return RUINTabVOOMKind;
    if (RUINTabTitleMatchesNativeKey(title, @"walletTab.title", @"ウォレット")) return RUINTabWalletKind;
    if (RUINTabTitleMatchesNativeKey(title, @"walletTab.title.shopping", @"ショッピング")) return RUINTabShoppingKind;
    if (RUINTabTitleMatchesNativeKey(title, @"gnb.mini", @"アプリ")) return RUINTabAppsKind;
    if (RUINTabTitleMatchesNativeKey(title, @"news.title", @"ニュース")) return RUINTabNewsKind;
    if (RUINTabTitleMatchesNativeKey(title, @"settings.call.selecttab.call", @"通話")) return RUINTabCallKind;
    if (RUINTabTitleMatchesNativeKey(title, @"access.settings", @"設定")) return RUINTabSettingsKind;
    return RUINTabUnknown;
}

static RUINTabKind RUINKindForTabController(UIViewController *controller)
{
    RUINTabKind kind = RUINKindForTitle(controller.tabBarItem.title ?: controller.title ?: @"");
    if (kind != RUINTabUnknown) return kind;

    UIViewController *content = controller;
    while ([content isKindOfClass:UINavigationController.class] &&
           ((UINavigationController *)content).viewControllers.count > 0) {
        content = ((UINavigationController *)content).viewControllers.firstObject;
    }
    kind = RUINKindForControllerClass(content);
    if (kind != RUINTabUnknown) return kind;
    return RUINKindForTitle(content.tabBarItem.title ?: content.title ?: @"");
}

static BOOL RUINShouldHideTab(RUINTabKind kind)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    switch (kind) {
        case RUINTabVOOMKind: return [defaults boolForKey:RUINHideVOOMTabDefaultsKey];
        case RUINTabWalletKind: return [defaults boolForKey:RUINHideWalletTabDefaultsKey];
        case RUINTabShoppingKind: return [defaults boolForKey:RUINHideShoppingTabDefaultsKey];
        case RUINTabAppsKind: return [defaults boolForKey:RUINHideAppsTabDefaultsKey];
        case RUINTabNewsKind:
        case RUINTabCallKind: return [defaults boolForKey:RUINHideNewsCallTabsDefaultsKey];
        case RUINTabSettingsKind: {
            NSDictionary *entry = RUINNativeEntryDiagnostics();
            return [entry[@"homeEntryAvailable"] boolValue] &&
                [defaults boolForKey:RUINHideSettingsTabDefaultsKey];
        }
        default: return NO;
    }
}

static NSArray *RUINFilteredControllers(NSArray *requested)
{
    if (![requested isKindOfClass:NSArray.class]) return requested;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:requested.count];
    for (id object in requested) {
        if (![object isKindOfClass:UIViewController.class]) {
            [filtered addObject:object];
            continue;
        }
        RUINTabKind kind = RUINKindForTabController((UIViewController *)object);
        // Home and Talk are mandatory whenever LINE supplied them.
        if (!RUINShouldHideTab(kind)) [filtered addObject:object];
    }
    return [filtered copy];
}

static void RUINRegisterTabController(UITabBarController *controller)
{
    if (!gTrackedTabControllers) gTrackedTabControllers = [NSHashTable weakObjectsHashTable];
    [gTrackedTabControllers addObject:controller];
}

static NSMutableArray *gTabSetterTrace;
static void RUINTraceTabSetter(UITabBarController *controller, NSArray *requested) {
    if (![NSProcessInfo.processInfo.environment[@"RUIN_ENABLE_RUNTIME_INSPECTOR"] isEqual:@"1"] ||
        gTabSetterTrace.count >= 24) return;
    RUINMainExecutableImage image;
    if (!RUINResolveMainExecutableImage(&image)) return;
    NSMutableArray *PCs = [NSMutableArray array];
    for (NSNumber *frame in NSThread.callStackReturnAddresses) {
        Dl_info info;
        if (dladdr((void *)frame.unsignedLongLongValue, &info) &&
            info.dli_fbase == (const void *)image.header)
            [PCs addObject:[NSString stringWithFormat:@"0x%llx", frame.unsignedLongLongValue - image.slide]];
    }
    if (!gTabSetterTrace) gTabSetterTrace = [NSMutableArray array];
    [gTabSetterTrace addObject:@{@"controllerClass":NSStringFromClass(controller.class),
        @"controller": [NSString stringWithFormat:@"%p",controller], @"count":@(requested.count), @"nativeReturnPCs":PCs}];
}

static void RUINRecordRequestedControllers(UITabBarController *controller, NSArray *requested)
{
    RUINRegisterTabController(controller);
    if (!requested) return;
    RUINTraceTabSetter(controller, requested);

    // LINE can resubmit the already-filtered list while rebuilding its tab UI.
    // Keep the prior full request in that case so a later refresh can restore it.
    NSArray *saved = objc_getAssociatedObject(controller, &gRequestedControllersKey);
    if (saved && [controller.viewControllers isEqualToArray:requested] &&
        [RUINFilteredControllers(saved) isEqualToArray:requested]) return;
    objc_setAssociatedObject(controller, &gRequestedControllersKey, [requested copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIViewController *RUINFallbackController(NSArray *controllers)
{
    for (NSNumber *kindValue in @[@(RUINTabHomeKind), @(RUINTabTalkKind)]) {
        RUINTabKind wanted = (RUINTabKind)kindValue.integerValue;
        for (UIViewController *controller in controllers)
            if (RUINKindForTabController(controller) == wanted) return controller;
    }
    return [controllers.firstObject isKindOfClass:UIViewController.class] ? controllers.firstObject : nil;
}

static void RUINKeepSelectionValid(UITabBarController *controller, NSArray *filtered, UIViewController *previous)
{
    UIViewController *selected = [filtered containsObject:previous] ? previous : nil;
    if (!selected && ![filtered containsObject:controller.selectedViewController])
        selected = RUINFallbackController(filtered);
    if (selected && controller.selectedViewController != selected)
        controller.selectedViewController = selected;
}

static void RUINApplyStartupSelection(UITabBarController *controller, NSArray *controllers)
{
    if ([objc_getAssociatedObject(controller, &gStartupSelectionAppliedKey) boolValue]) return;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:RUINStartupTabFixedDefaultsKey]) {
        objc_setAssociatedObject(controller, &gStartupSelectionAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        atomic_store(&gStartupStatus, 1); // disabled
        return;
    }
    RUINTabKind wanted = RUINKindForIdentifier([defaults stringForKey:RUINStartupTabDefaultsKey] ?: @"");
    if (wanted == RUINTabUnknown) {
        objc_setAssociatedObject(controller, &gStartupSelectionAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        atomic_store(&gStartupStatus, 3); // invalid selection
        return;
    }
    for (UIViewController *candidate in controllers) {
        if ([controller.viewControllers containsObject:candidate] &&
            RUINKindForTabController(candidate) == wanted) {
            // Native selection can synchronously reenter tab setup.
            objc_setAssociatedObject(controller, &gStartupSelectionAppliedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            BOOL applied = NO;
            @try {
                controller.selectedViewController = candidate;
                applied = controller.selectedViewController == candidate;
            } @finally {
                if (!applied) objc_setAssociatedObject(controller, &gStartupSelectionAppliedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            atomic_store(&gStartupStatus, applied ? 2 : 4);
            return;
        }
    }
    atomic_store(&gStartupStatus, 4); // unavailable or hidden
}

static void RUINApplyRequestedControllers(UITabBarController *controller, BOOL allowStartup)
{
    // LINE's own navigation/notification code indexes the original controller
    // array. Never remove or reorder it: filter only UIKit's compact tab UI.
    NSArray *native = [controller.viewControllers copy] ?: @[];
    BOOL nativeGeneration = [RUINNativeTabAvailabilityDiagnostics()[@"status"] intValue] == 5;
    NSArray *allowed = nativeGeneration ? native : RUINFilteredControllers(native);
    NSArray *startupSelectable = nativeGeneration ? RUINFilteredControllers(native) : allowed;
    NSArray<UITab *> *tabs = controller.tabs;
    atomic_store(&gNativeTabCount, native.count);
    atomic_store(&gUIKitTabCount, tabs.count);
    RUINRegisterTabController(controller);
    objc_setAssociatedObject(controller, &gRequestedControllersKey, native, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id saved = objc_getAssociatedObject(controller, &gOriginalCompactTabsKey);
    if (allowed.count == native.count) {
        if (saved) {
            controller.compactTabIdentifiers = saved == NSNull.null ? nil : saved;
            objc_setAssociatedObject(controller, &gOriginalCompactTabsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            atomic_fetch_add(&gTabReapplications, 1);
        }
        atomic_store(&gTabVisibilityStatus, 1);
        if (allowStartup) RUINApplyStartupSelection(controller, startupSelectable);
        return;
    }
    if (!tabs.count || tabs.count != native.count) {
        // Keep LINE's existing tab view and renderer. This legacy layout needs
        // a verified native visibility boundary; never replace its UI.
        atomic_store(&gTabVisibilityStatus, 3);
        if (allowStartup) RUINApplyStartupSelection(controller, startupSelectable);
        return;
    }
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSArray *original = saved ? (saved == NSNull.null ? nil : saved) : controller.compactTabIdentifiers;
    for (UITab *tab in tabs) {
        UIViewController *view = tab.viewController;
        if (![native containsObject:view] || !tab.identifier.length || [seen containsObject:tab.identifier]) {
            atomic_store(&gTabVisibilityStatus, 4);
            if (allowStartup) RUINApplyStartupSelection(controller, startupSelectable);
            return;
        }
        [seen addObject:tab.identifier];
        if ([allowed containsObject:view] && (!original || [original containsObject:tab.identifier]))
            [identifiers addObject:tab.identifier];
    }
    if (!identifiers.count) {
        atomic_store(&gTabVisibilityStatus, 4);
        if (allowStartup) RUINApplyStartupSelection(controller, startupSelectable);
        return;
    }
    if (!saved) objc_setAssociatedObject(controller, &gOriginalCompactTabsKey,
        original ?: NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSArray *previousIdentifiers = controller.compactTabIdentifiers;
    if (![previousIdentifiers isEqualToArray:identifiers]) {
        controller.compactTabIdentifiers = identifiers;
        // The public compact filter must preserve LINE's entire native array.
        if (![controller.viewControllers isEqualToArray:native]) {
            controller.compactTabIdentifiers = previousIdentifiers;
            atomic_store(&gTabVisibilityStatus, 5);
            if (allowStartup) RUINApplyStartupSelection(controller, startupSelectable);
            return;
        }
        atomic_fetch_add(&gTabReapplications, 1);
    }
    atomic_store(&gTabVisibilityStatus, 2);
    RUINKeepSelectionValid(controller, allowed, controller.selectedViewController);
    if (allowStartup) RUINApplyStartupSelection(controller, startupSelectable);
}

static void RUINSetViewControllers(id self, SEL selector, NSArray *controllers)
{
    atomic_fetch_add_explicit(&gSetControllersHook.calls, 1, memory_order_relaxed);
    IMP original = atomic_load_explicit(&gSetControllersHook.original, memory_order_acquire);
    if (!original) return;
    if (gTabSetterDepth++) {
        ((void (*)(id, SEL, NSArray *))original)(self, selector, controllers);
        gTabSetterDepth--;
        return;
    }

    UITabBarController *tabs = (UITabBarController *)self;
    RUINRecordRequestedControllers(tabs, controllers);
    ((void (*)(id, SEL, NSArray *))original)(self, selector, controllers);
    RUINApplyRequestedControllers(tabs, YES);
    gTabSetterDepth--;
}

static void RUINSetViewControllersAnimated(id self, SEL selector, NSArray *controllers, BOOL animated)
{
    atomic_fetch_add_explicit(&gSetControllersAnimatedHook.calls, 1, memory_order_relaxed);
    IMP original = atomic_load_explicit(&gSetControllersAnimatedHook.original, memory_order_acquire);
    if (!original) return;
    if (gTabSetterDepth++) {
        ((void (*)(id, SEL, NSArray *, BOOL))original)(self, selector, controllers, animated);
        gTabSetterDepth--;
        return;
    }

    UITabBarController *tabs = (UITabBarController *)self;
    RUINRecordRequestedControllers(tabs, controllers);
    ((void (*)(id, SEL, NSArray *, BOOL))original)(self, selector, controllers, animated);
    RUINApplyRequestedControllers(tabs, YES);
    gTabSetterDepth--;
}

static void RUINStyledTabsViewDidLoad(id self, SEL selector)
{
    IMP original = atomic_load_explicit(&gTabsViewDidLoadHook.original, memory_order_acquire);
    if (original) ((void (*)(id, SEL))original)(self, selector);
    atomic_fetch_add_explicit(&gTabsViewDidLoadHook.calls, 1, memory_order_relaxed);
    RUINRegisterTabController((UITabBarController *)self);
    RUINApplyRequestedControllers((UITabBarController *)self, NO);
}

static void RUINStyledTabsViewDidAppear(id self, SEL selector, BOOL animated)
{
    IMP original = atomic_load_explicit(&gTabsViewDidAppearHook.original, memory_order_acquire);
    if (original) ((void (*)(id, SEL, BOOL))original)(self, selector, animated);
    atomic_fetch_add_explicit(&gTabsViewDidAppearHook.calls, 1, memory_order_relaxed);
    RUINRegisterTabController((UITabBarController *)self);
    RUINApplyRequestedControllers((UITabBarController *)self, YES);
}

static void RUINRefreshTrackedTabControllers(NSHashTable *refreshed)
{
    for (UITabBarController *controller in gTrackedTabControllers.allObjects)
        if (![refreshed containsObject:controller]) RUINApplyRequestedControllers(controller, NO);
}

static void RUINDiscoverTabControllers(UIViewController *controller, NSHashTable *visited)
{
    if (!controller || [visited containsObject:controller]) return;
    [visited addObject:controller];
    Class styled = objc_getClass(gSetControllersHook.className);
    if (styled && [controller isKindOfClass:styled] && [controller isKindOfClass:UITabBarController.class]) {
        RUINRegisterTabController((UITabBarController *)controller);
        RUINApplyRequestedControllers((UITabBarController *)controller, YES);
    }
    if (controller.presentedViewController) RUINDiscoverTabControllers(controller.presentedViewController, visited);
    for (UIViewController *child in controller.childViewControllers) RUINDiscoverTabControllers(child, visited);
}

static NSHashTable *RUINDiscoverExistingTabs(void)
{
    NSHashTable *visited = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            RUINDiscoverTabControllers(window.rootViewController, visited);
    }
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    if ([delegate respondsToSelector:@selector(window)]) RUINDiscoverTabControllers(delegate.window.rootViewController, visited);
    return visited;
}

static NSUInteger RUINLoadPreferences(void)
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL ads = [defaults boolForKey:RUINHideAdsDefaultsKey];
    BOOL recommendations = [defaults boolForKey:RUINHideRecommendationsDefaultsKey];
    BOOL voice = [defaults boolForKey:RUINHideVoiceInputDefaultsKey];
    BOOL agent = [defaults boolForKey:RUINHideAgentIBarDefaultsKey];
    [defaults registerDefaults:@{RUINFixPanelHeightDefaultsKey: @YES}];
    BOOL panel = [defaults boolForKey:RUINFixPanelHeightDefaultsKey];
    BOOL profileHeader = [defaults boolForKey:RUINProfileHeaderLeftDefaultsKey];
    atomic_store(&gHideAdsEnabled, ads);
    atomic_store(&gHideRecommendationsEnabled, recommendations);
    atomic_store(&gHideVoiceInputEnabled, voice);
    atomic_store(&gHideAgentIEnabled, agent);
    atomic_store(&gFixPanelHeightEnabled, panel);
    atomic_store(&gProfileHeaderLeftEnabled, profileHeader);
    return ads | (recommendations << 1) | (voice << 2) | (agent << 3) | (panel << 4) | (profileHeader << 5);
}

static void RUINPerformInstallOrRefresh(void)
{
    static BOOL viewsRefreshed;
    static NSUInteger appliedViewPreferences;
    if (!RUINTargetMatches()) {
        viewsRefreshed = NO;
        atomic_store(&gTargetMatches, false);
        RUINMarkHooksVersionGated();
        return;
    }
    atomic_store(&gTargetMatches, true);
    NSUInteger previousHooksGeneration = gViewHooksGeneration;
    RUINInstallHooks();
    NSUInteger preferences = RUINLoadPreferences();
    NSHashTable *refreshed = RUINDiscoverExistingTabs();
    RUINRefreshTrackedTabControllers(refreshed);
    // New view instances use their validated setHidden:/didMoveToWindow hooks.
    // Existing trees need a scan only after relevant preferences or hooks change.
    if (!viewsRefreshed || preferences != appliedViewPreferences ||
        previousHooksGeneration != gViewHooksGeneration) {
        RUINRefreshVisibleViews();
        appliedViewPreferences = preferences;
        viewsRefreshed = YES;
    } else atomic_fetch_add(&gVisibleViewScanSkips, 1);
}

static void RUINOnMain(dispatch_block_t block)
{
    if (NSThread.isMainThread) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

void RUINInstallInterfaceFeatures(void)
{
    RUINOnMain(^{ RUINPerformInstallOrRefresh(); });
}

void RUINRefreshInterfaceFeatures(void)
{
    RUINOnMain(^{
        RUINPerformInstallOrRefresh();
        if (atomic_load(&gProfileHeaderHookInstalled))
            RUINRefreshProfileHeaderViews();
    });
}

static NSArray<NSString *> *RUINNativeTabIdentifiersOnMain(BOOL includeHiddenChoices)
{
    if (!atomic_load(&gTargetMatches)) return @[];
    NSMutableSet<NSString *> *available = [NSMutableSet set];
    for (UITabBarController *controller in gTrackedTabControllers.allObjects) {
        NSArray *requested = objc_getAssociatedObject(controller, &gRequestedControllersKey) ?: controller.viewControllers;
        NSMutableSet<NSString *> *controllerTabs = [NSMutableSet set];
        for (UIViewController *item in requested) {
            RUINTabKind kind = RUINKindForTabController(item);
            NSString *identifier = RUINTabIdentifier(kind);
            if (identifier) [controllerTabs addObject:identifier];
        }
        if (![controllerTabs containsObject:RUINInterfaceTabHome])
            [controllerTabs removeObject:RUINInterfaceTabSettings];
        [available unionSet:controllerTabs];
    }
    NSArray *canonical = @[RUINInterfaceTabHome, RUINInterfaceTabTalk, RUINInterfaceTabShopping,
                           RUINInterfaceTabVOOM, RUINInterfaceTabWallet, RUINInterfaceTabNews,
                           RUINInterfaceTabCall, RUINInterfaceTabSettings, RUINInterfaceTabApps];
    if (includeHiddenChoices && [available containsObject:RUINInterfaceTabHome] && [available containsObject:RUINInterfaceTabTalk])
        [available addObjectsFromArray:RUINObservedNativeTabChoices()];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *identifier in canonical) if ([available containsObject:identifier]) [result addObject:identifier];
    return [result copy];
}

NSArray<NSString *> *RUINNativeTabIdentifiers(void)
{
    if (NSThread.isMainThread) return RUINNativeTabIdentifiersOnMain(YES);
    __block NSArray<NSString *> *result;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = RUINNativeTabIdentifiersOnMain(YES); });
    return result ?: @[];
}

static NSArray<NSString *> *RUINAvailableTabsOnMain(void)
{
    BOOL nativeGeneration = [RUINNativeTabAvailabilityDiagnostics()[@"status"] intValue] == 5;
    NSSet<NSString *> *native = [NSSet setWithArray:RUINNativeTabIdentifiersOnMain(!nativeGeneration)];
    NSArray *startupChoices = @[RUINInterfaceTabHome, RUINInterfaceTabTalk, RUINInterfaceTabShopping, RUINInterfaceTabVOOM,
                                RUINInterfaceTabWallet, RUINInterfaceTabNews, RUINInterfaceTabCall, RUINInterfaceTabSettings];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *identifier in startupChoices)
        if ([native containsObject:identifier] && (nativeGeneration || !RUINShouldHideTab(RUINKindForIdentifier(identifier))))
            [result addObject:identifier];
    return [result copy];
}

NSArray<NSString *> *RUINAvailableTabs(void)
{
    if (NSThread.isMainThread) return RUINAvailableTabsOnMain();
    __block NSArray<NSString *> *result;
    dispatch_sync(dispatch_get_main_queue(), ^{ result = RUINAvailableTabsOnMain(); });
    return result ?: @[];
}

static NSUInteger RUINInstalledViewTargetCount(RUINHideGroup group)
{
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < sizeof(gViewTargets) / sizeof(gViewTargets[0]); i++) {
        RUINViewTarget *target = &gViewTargets[i];
        if (target->group == group &&
            atomic_load(&target->setHidden.status) == RUINHookInstalled &&
            atomic_load(&target->didMoveToWindow.status) == RUINHookInstalled) count++;
    }
    return count;
}

static uint64_t RUINViewHookCalls(RUINHideGroup group)
{
    uint64_t calls = 0;
    for (NSUInteger i = 0; i < sizeof(gViewTargets) / sizeof(gViewTargets[0]); i++) {
        RUINViewTarget *target = &gViewTargets[i];
        if (target->group != group) continue;
        calls += atomic_load(&target->setHidden.calls) + atomic_load(&target->didMoveToWindow.calls);
    }
    return calls;
}

static NSDictionary<NSString *, NSNumber *> *RUINViewHookFailures(RUINHideGroup group)
{
    NSUInteger missingClasses = 0, missingSelectors = 0, encodingMismatches = 0;
    NSUInteger classTypeMismatches = 0, installFailures = 0;
    for (NSUInteger i = 0; i < sizeof(gViewTargets) / sizeof(gViewTargets[0]); i++) {
        RUINViewTarget *target = &gViewTargets[i];
        if (target->group != group) continue;
        RUINMethodHook *hooks[] = { &target->setHidden, &target->didMoveToWindow };
        for (NSUInteger j = 0; j < 2; j++) {
            switch (atomic_load(&hooks[j]->status)) {
                case RUINHookMissingClass: missingClasses++; break;
                case RUINHookMissingSelector: missingSelectors++; break;
                case RUINHookEncodingMismatch: encodingMismatches++; break;
                case RUINHookClassTypeMismatch: classTypeMismatches++; break;
                case RUINHookInstallFailed: installFailures++; break;
                default: break;
            }
        }
    }
    return @{@"missingClasses": @(missingClasses), @"missingSelectors": @(missingSelectors),
             @"encodingMismatches": @(encodingMismatches), @"classTypeMismatches": @(classTypeMismatches),
             @"installFailures": @(installFailures)};
}

static NSString *RUINGroupStatus(RUINHideGroup group, BOOL enabled)
{
    if (!RUINTargetMatches()) return @"version_gated";
    if (!atomic_load(&gTargetMatches)) return @"pending";
    if (!enabled) return @"disabled";
    NSUInteger installed = RUINInstalledViewTargetCount(group);
    NSUInteger total = 0;
    for (NSUInteger i = 0; i < sizeof(gViewTargets) / sizeof(gViewTargets[0]); i++)
        if (gViewTargets[i].group == group) total++;
    if (installed == total) return @"enabled_bounded_targets";
    if (installed) return @"enabled_partial_targets";
    return @"missing_verified_targets";
}

NSDictionary *RUINInterfaceDiagnostics(void)
{
    BOOL installedForTarget = atomic_load(&gTargetMatches);
    BOOL targetMatches = installedForTarget || RUINTargetMatches();
    BOOL gated = !targetMatches;
    BOOL ads = atomic_load(&gHideAdsEnabled);
    BOOL recommendations = atomic_load(&gHideRecommendationsEnabled);
    BOOL voice = atomic_load(&gHideVoiceInputEnabled);
    NSString *voiceStatus = gated ? @"version_gated" : !installedForTarget ? @"pending" :
        (voice ? (RUINInstalledViewTargetCount(RUINHideGroupVoiceInput) ? @"enabled_exact_composer_audio_kind" : @"missing_composer_button") : @"disabled");
    int startup = atomic_load(&gStartupStatus);
    NSString *startupStatus = startup == 1 ? @"disabled" : startup == 2 ? @"applied" :
        startup == 3 ? @"invalid_selection" : startup == 4 ? @"unavailable_or_hidden" : @"pending";
    return @{
        @"gate": gated ? @"version_gated" : installedForTarget ? @"matched" : @"pending",
        @"profileHeader": @{
            @"enabled": @(atomic_load(&gProfileHeaderLeftEnabled)),
            @"hook": gProfileHeaderHookStatus ?: @"pending",
            @"accountAvailable": @(RUINChatCatalogAccount().length > 0),
            @"applyRuns": @(atomic_load(&gProfileHeaderApplyRuns)),
            @"containerFound": @(atomic_load(&gProfileHeaderFoundContainer)),
        },
        @"visibleViewScans": @(atomic_load(&gVisibleViewScans)),
        @"visibleViewScanSkips": @(atomic_load(&gVisibleViewScanSkips)),
        @"tabs": @{
            @"configurationRefreshHookInstalled":@(gTabConfigurationHookInstalled),
            @"keptNativeMenuRefreshes":@(atomic_load(&gKeptNativeMenuRefreshes)),
            @"setterTrace":gTabSetterTrace ?: @[],
            @"nativeAvailability":RUINNativeTabAvailabilityDiagnostics(),
            @"setViewControllers": RUINTargetStatusName(atomic_load(&gSetControllersHook.status)),
            @"setViewControllersAnimated": RUINTargetStatusName(atomic_load(&gSetControllersAnimatedHook.status)),
            @"viewDidLoad": RUINTargetStatusName(atomic_load(&gTabsViewDidLoadHook.status)),
            @"viewDidAppear": RUINTargetStatusName(atomic_load(&gTabsViewDidAppearHook.status)),
            @"reloadPath": @"existing_native_tab_view_only",
            @"customTabViewsAdded": @NO,
            @"visibilityStatus": @(atomic_load(&gTabVisibilityStatus)),
            @"nativeControllerCount": @(atomic_load(&gNativeTabCount)),
            @"publicUITabCount": @(atomic_load(&gUIKitTabCount)),
            @"reloadSelector": @"missing_verified_reload_selector",
            @"setterCalls": @(atomic_load(&gSetControllersHook.calls) + atomic_load(&gSetControllersAnimatedHook.calls)),
            @"reapplications": @(atomic_load(&gTabReapplications)),
            @"startupStatus": startupStatus
        },
        @"ads": @{
            @"status": RUINGroupStatus(RUINHideGroupAds, ads),
            @"installedViewClasses": @(RUINInstalledViewTargetCount(RUINHideGroupAds)),
            @"hookCalls": @(RUINViewHookCalls(RUINHideGroupAds)),
            @"hookFailures": RUINViewHookFailures(RUINHideGroupAds),
            @"talkTopBannerHook": RUINTargetStatusName(atomic_load(&gTalkTopBannerStatus)),
            @"talkTopBannerUpdates": @(atomic_load(&gTalkTopBannerUpdates)),
            @"talkTopBannerCollapses": @(atomic_load(&gTalkTopBannerCollapses)),
            @"talkInsetHook": RUINTargetStatusName(atomic_load(&gTalkInsetStatus)),
            @"talkInsetProjections": @(atomic_load(&gTalkInsetProjections)),
            @"talkInsetViews": RUINTalkInsetDiagnostics()
        },
        @"recommendations": @{
            @"status": RUINGroupStatus(RUINHideGroupRecommendations, recommendations),
            @"installedViewClasses": @(RUINInstalledViewTargetCount(RUINHideGroupRecommendations)),
            @"hookCalls": @(RUINViewHookCalls(RUINHideGroupRecommendations)),
            @"hookFailures": RUINViewHookFailures(RUINHideGroupRecommendations)
        },
        @"voiceInput": @{
            @"status": voiceStatus,
            @"layoutHook": RUINTargetStatusName(atomic_load(&gVoiceButtonLayoutHook.status)),
            @"layoutCalls": @(atomic_load(&gVoiceButtonLayoutHook.calls)),
            @"kindRestorations": @(atomic_load(&gVoiceKindRestorations)),
            @"typeReflections": @(atomic_load(&gVoiceTypeReflections)),
            @"installedViewClasses": @(RUINInstalledViewTargetCount(RUINHideGroupVoiceInput)),
            @"hookCalls": @(RUINViewHookCalls(RUINHideGroupVoiceInput)),
            @"hookFailures": RUINViewHookFailures(RUINHideGroupVoiceInput)
        },
        @"agentIBar": @{
            @"enabled": @(atomic_load(&gHideAgentIEnabled)),
            @"installedViewClasses": @(RUINInstalledViewTargetCount(RUINHideGroupAgentI)),
            @"heightHookInstalled": @(gAgentIntrinsicInstalled),
            @"hookCalls": @(RUINViewHookCalls(RUINHideGroupAgentI)),
            @"hookFailures": RUINViewHookFailures(RUINHideGroupAgentI)
        },
        @"panelHeight": @{
            @"status": gated ? @"version_gated" : gPanelHeightHookStatus,
            @"enabled": @(atomic_load(&gFixPanelHeightEnabled)),
            @"applications": @(atomic_load(&gPanelHeightApplications)),
            @"lastTargetHeight": @(gPanelLastTargetHeight),
            @"traitStatus": gated ? @"version_gated" : gPanelTraitHookStatus,
            @"traitApplications": @(atomic_load(&gPanelTraitApplications))
        }
    };
}
