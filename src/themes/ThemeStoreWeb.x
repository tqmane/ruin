%config(generator=internal);

#import "ThemeStoreWeb.h"
#import "NativeThemeWorkflow.h"

#import "ThemeFeatures.h"
#import "ThemeStoreResolver.h"

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

static NSString * const RUINThemeStoreWebClassName = @"_TtC4LIFF21ChatAppViewController";
static NSString * const RUINThemeStoreWebHandlerName = @"ruinThemeStoreWebDownloadV1";
static NSString * const RUINThemeStoreWebSavedMessage = @"ファイルを保存しました。マイ着せかえを開いて、着せかえを選択して適用できます。";
static NSString * const RUINThemeStoreWebSaveLocationError = @"保存済みファイルの場所を確認できませんでした。";
static NSString * const RUINThemeStoreWebResolverError = @"ストア情報を取得できませんでした。URLと通信状況を確認してください。";
static NSString * const RUINThemeStoreWebGenericError = @"処理を完了できませんでした。";

enum {
    RUINThemeStoreWebHookPending = 0,
    RUINThemeStoreWebHookInstalled = 1,
    RUINThemeStoreWebHookClassUnavailable = 2,
    RUINThemeStoreWebHookMethodUnavailable = 3,
    RUINThemeStoreWebHookABIMismatch = 4,
    RUINThemeStoreWebHookVersionGated = 5
};

static atomic_int gRUINThemeStoreWebHookStatus;
static atomic_uint_fast64_t gRUINThemeStoreWebAppearCalls;
static atomic_uint_fast64_t gRUINThemeStoreWebTrackedViews;
static atomic_uint_fast64_t gRUINThemeStoreWebInjections;
static atomic_uint_fast64_t gRUINThemeStoreWebMessagesAccepted;
static atomic_uint_fast64_t gRUINThemeStoreWebMessagesRejected;
static atomic_uint_fast64_t gRUINThemeStoreWebDownloadsStarted;
static atomic_uint_fast64_t gRUINThemeStoreWebDownloadsSucceeded;
static atomic_uint_fast64_t gRUINThemeStoreWebDownloadsFailed;
static NSHashTable<UIViewController *> *gRUINThemeStoreWebControllers;
static id gRUINThemeStoreWebDefaultsObserver;
static BOOL gRUINThemeStoreWebDownloadInFlight;
static char gRUINThemeStoreWebAssociationKey;

static NSString *RUINThemeStoreWebJavaScript(BOOL enabled, BOOL announceReady)
{
    static NSString * const source =
        @"(() => {\n"
        "  const handlerName = \"__RUIN_HANDLER__\";\n"
        "  const stateKey = \"__ruinThemeStoreWebV1\";\n"
        "  const requestedEnabled = __RUIN_ENABLED__;\n"
        "  const announceReady = __RUIN_READY__;\n"
        "  const validUUID = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;\n"
        "  const allowedHost = host => String(host || \"\").toLowerCase() === \"themeshop.line.me\";\n"
        "  const allowedURL = u => !!u && u.protocol === \"https:\" && !u.username && !u.password && (!u.port || u.port === \"443\") && allowedHost(u.hostname);\n"
        "  let pageURL; try { pageURL = new URL(location.href); } catch (_) { return; }\n"
        "  if (!allowedURL(pageURL)) return;\n"
        "  const nativeHandler = () => { try { const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handlerName]; return h && typeof h.postMessage === \"function\" ? h : null; } catch (_) { return null; } };\n"
        "  const nativeAvailable = !!nativeHandler();\n"
        "  const previous = window[stateKey];\n"
        "  if (previous) { previous.setEnabled(requestedEnabled); previous.refresh(); if (announceReady && nativeAvailable) nativeHandler().postMessage({type:\"pageReady\"}); return; }\n"
        "  const productRouteID = u => { if (!u || u.protocol !== \"https:\" || ![\"themeshop.line.me\",\"store.line.me\"].includes(u.hostname.toLowerCase()) || u.username || u.password || (u.port && u.port !== \"443\")) return null; if (u.hostname.toLowerCase() === \"themeshop.line.me\") { const hash = u.hash.match(/^#?\\/product\\/theme\\/([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})(?:\\?preview=[0-9]+)?$/); if (hash) return hash[1].toLowerCase(); } const m = u.pathname.match(/^\\/themeshop\\/product\\/([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})(?:\\/[a-z]{2}(?:-[a-z0-9]+)?)?\\/?$/i); return m ? m[1].toLowerCase() : null; };\n"
        "  const pageProductID = raw => { try { const u = new URL(raw, location.href); return allowedURL(u) ? productRouteID(u) : null; } catch (_) { return null; } };\n"
        "  const storeProductID = raw => { try { const u = new URL(raw, location.href); return u.hostname.toLowerCase() === \"store.line.me\" ? productRouteID(u) : null; } catch (_) { return null; } };\n"
        "  const selectedProductID = () => { const ids = []; const direct = pageProductID(location.href); if (direct) ids.push(direct); const u = new URL(location.href); for (const key of [\"id\", \"productId\", \"productID\"]) { const value = u.searchParams.get(key); if (value && validUUID.test(value)) ids.push(value.toLowerCase()); } const canonical = document.querySelector(\"link[rel='canonical']\"); const og = document.querySelector(\"meta[property='og:url']\"); for (const value of [canonical && canonical.href, og && og.content]) { const id = value && storeProductID(value); if (id) ids.push(id); } const unique = Array.from(new Set(ids)); return unique.length === 1 ? unique[0] : null; };\n"
        "  const isPurchaseLabel = value => /^(購入する|purchase|buy)$/i.test(String(value || \"\").replace(/\\s+/g, \" \").trim());\n"
        "  const original = new WeakMap();\n"
        "  const changed = [];\n"
        "  let enabled = requestedEnabled && nativeAvailable;\n"
        "  let activeControl = null;\n"
        "  let activeProductID = null;\n"
        "  let queued = false;\n"
        "  const snapshotFor = el => original.get(el);\n"
        "  const currentLabel = el => el instanceof HTMLInputElement ? el.value : (el.innerText || el.textContent || \"\");\n"
        "  const controlLabel = el => { const saved = snapshotFor(el); const current = currentLabel(el).replace(/\\s+/g, \" \").trim(); return saved && (current === \"ダウンロード\" || !current) ? saved.label : current; };\n"
        "  const visible = el => { if (!el.isConnected || el.disabled || el.getAttribute(\"aria-disabled\") === \"true\") return false; const r = el.getBoundingClientRect(); if (!r.width || !r.height || r.bottom <= 0 || r.top >= innerHeight || r.right <= 0 || r.left >= innerWidth) return false; const s = getComputedStyle(el); return s.display !== \"none\" && s.visibility !== \"hidden\" && s.opacity !== \"0\"; };\n"
        "  const isRecommendation = el => { for (let n = el, i = 0; n && i < 9; n = n.parentElement, i++) { const marker = [n.id, n.className && String(n.className), n.getAttribute(\"aria-label\"), n.getAttribute(\"data-testid\"), n.getAttribute(\"data-section\")].join(\" \").toLowerCase(); if (/(recommend|related|suggest|ranking|carousel|swiper|similar|おすすめ|レコメンド|ランキング)/i.test(marker)) return true; if (n === document.body) break; } return false; };\n"
        "  const isProductCard = el => { for (let n = el, i = 0; n && i < 9; n = n.parentElement, i++) { const marker = [n.id, n.className && String(n.className), n.getAttribute(\"data-testid\")].join(\" \").toLowerCase(); if ((n.matches && n.matches(\"li,[role='listitem']\")) || /(product[-_ ]?(card|item|tile)|item[-_ ]?card)/i.test(marker)) return true; if (n === document.body) break; } return false; };\n"
        "  const explicitProductIDs = el => { const ids = new Set(); for (let n = el, i = 0; n && i < 9; n = n.parentElement, i++) { for (const key of [\"data-product-id\", \"data-productid\", \"data-item-id\"]) { const value = n.getAttribute && n.getAttribute(key); if (value && validUUID.test(value)) ids.add(value.toLowerCase()); } if (n.matches && n.matches(\"a[href]\")) { try { const id = productRouteID(new URL(n.href, location.href)); if (id) ids.add(id); } catch (_) {} } if (n === document.body) break; } return Array.from(ids); };\n"
        "  const controls = () => Array.from(document.querySelectorAll(\"button,a,[role='button'],input[type='button'],input[type='submit']\"));\n"
        "  const chooseControl = pid => { const candidates = []; for (const el of controls()) { if (!visible(el) || !isPurchaseLabel(controlLabel(el)) || isRecommendation(el)) continue; const ids = explicitProductIDs(el); if (ids.some(id => id !== pid)) continue; const strong = ids.includes(pid); if (!strong && isProductCard(el)) continue; candidates.push({el, strong}); } const strong = candidates.filter(item => item.strong); if (strong.length === 1) return strong[0].el; return candidates.length === 1 ? candidates[0].el : null; };\n"
        "  const captureControl = el => { if (original.has(el)) { const saved = original.get(el); if (el instanceof HTMLInputElement || saved.nodes.every(item => el.contains(item.node))) return saved; original.delete(el); const index = changed.indexOf(el); if (index >= 0) changed.splice(index, 1); } if (el instanceof HTMLInputElement) { const saved = {label: el.value, value: el.value, nodes: null}; original.set(el, saved); changed.push(el); return saved; } const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT); const nodes = []; while (walker.nextNode()) { const node = walker.currentNode; if (node.nodeValue.trim()) nodes.push({node, value: node.nodeValue}); } if (!nodes.length) return null; const saved = {label: el.innerText || nodes.map(item => item.value).join(\"\"), nodes}; original.set(el, saved); changed.push(el); return saved; };\n"
        "  const restoreControl = el => { const saved = original.get(el); if (!saved) return; if (el instanceof HTMLInputElement) { if (el.value === \"ダウンロード\") el.value = saved.value; } else if (saved.nodes && el.isConnected && saved.nodes.every(item => el.contains(item.node) && (item.node.nodeValue === \"ダウンロード\" || item.node.nodeValue === \"\"))) { for (const item of saved.nodes) item.node.nodeValue = item.value; } original.delete(el); };\n"
        "  const restoreAll = () => { for (const el of changed.splice(0)) restoreControl(el); activeControl = null; activeProductID = null; };\n"
        "  const setButtonLabel = el => { const saved = captureControl(el); if (!saved) return false; if (el instanceof HTMLInputElement) { if (el.value !== \"ダウンロード\") el.value = \"ダウンロード\"; } else { saved.nodes.forEach((item, index) => { const value = index === 0 ? \"ダウンロード\" : \"\"; if (item.node.nodeValue !== value) item.node.nodeValue = value; }); } return true; };\n"
        "  const refresh = () => { if (!enabled || !nativeHandler()) { restoreAll(); return; } const pid = selectedProductID(); const target = pid && chooseControl(pid); if (!target) { restoreAll(); return; } for (const el of changed.slice()) if (el !== target) { restoreControl(el); const index = changed.indexOf(el); if (index >= 0) changed.splice(index, 1); } if (activeControl !== target || activeProductID !== pid || !original.has(target) || currentLabel(target).replace(/\\s+/g, \" \").trim() !== \"ダウンロード\") { if (!setButtonLabel(target)) { restoreAll(); return; } } activeControl = target; activeProductID = pid; };\n"
        "  const schedule = () => { if (queued) return; queued = true; setTimeout(() => { queued = false; refresh(); }, 0); };\n"
        "  window.addEventListener(\"hashchange\", schedule);\n"
        "  document.addEventListener(\"scroll\", schedule, true);\n"
        "  window.addEventListener(\"resize\", schedule, {passive:true});\n"
        "  const state = {setEnabled(value) { enabled = !!value && !!nativeHandler(); refresh(); }, refresh};\n"
        "  window[stateKey] = state;\n"
        "  document.addEventListener(\"click\", event => { if (!enabled || !activeControl || !activeProductID) return; const target = event.target instanceof Element ? event.target.closest(\"button,a,[role='button'],input[type='button'],input[type='submit']\") : null; if (target !== activeControl || !visible(target) || !isPurchaseLabel(controlLabel(target))) return; event.preventDefault(); event.stopImmediatePropagation(); event.stopPropagation(); const currentID = selectedProductID(); if (!currentID || currentID !== activeProductID) { schedule(); return; } const handler = nativeHandler(); if (!handler) { state.setEnabled(false); return; } try { handler.postMessage({type:\"downloadTheme\", productID:currentID, productURL:`https://store.line.me/themeshop/product/${currentID}/ja`}); } catch (_) { state.setEnabled(false); } }, true);\n"
        "  const observer = new MutationObserver(schedule);\n"
        "  if (document.documentElement) observer.observe(document.documentElement, {subtree:true, childList:true, characterData:true, attributes:true, attributeFilter:[\"href\",\"data-product-id\",\"data-productid\",\"data-item-id\",\"aria-label\",\"aria-disabled\",\"class\",\"id\",\"value\"]});\n"
        "  refresh();\n"
        "  if (announceReady && nativeAvailable) nativeHandler().postMessage({type:\"pageReady\"});\n"
        "})()\n";

    NSString *result = [source stringByReplacingOccurrencesOfString:@"__RUIN_HANDLER__" withString:RUINThemeStoreWebHandlerName];
    result = [result stringByReplacingOccurrencesOfString:@"__RUIN_ENABLED__" withString:enabled ? @"true" : @"false"];
    return [result stringByReplacingOccurrencesOfString:@"__RUIN_READY__" withString:announceReady ? @"true" : @"false"];
}

static BOOL RUINThemeStoreWebIsUUID(NSString *value)
{
    if (value.length != 36) return NO;
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex:i];
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != '-') return NO;
        } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
            return NO;
        }
    }
    return YES;
}

static NSString *RUINThemeStoreWebNormalizedUUID(NSString *value)
{
    return RUINThemeStoreWebIsUUID(value) ? value.lowercaseString : nil;
}

static BOOL RUINThemeStoreWebAllowedHost(NSString *host)
{
    return [host.lowercaseString isEqualToString:@"themeshop.line.me"];
}

static BOOL RUINThemeStoreWebTargetMatches(void)
{
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *info = bundle.infoDictionary ?: @{};
    BOOL bundleMatches = [bundle.bundleIdentifier isEqualToString:@"jp.naver.line"] ||
        [info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"];
    id version = info[@"CFBundleShortVersionString"];
    id build = info[@"CFBundleVersion"];
    return bundleMatches && [version isKindOfClass:NSString.class] && [version isEqual:@"26.16.0"] &&
        [build isKindOfClass:NSString.class] && [build isEqual:@"2026.1006.1718"];
}

static BOOL RUINThemeStoreWebAllowedURL(NSURL *URL)
{
    NSURLComponents *parts = URL ? [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO] : nil;
    return parts && [parts.scheme.lowercaseString isEqualToString:@"https"] &&
        RUINThemeStoreWebAllowedHost(parts.host ?: @"") && !parts.user && !parts.password &&
        (!parts.port || parts.port.integerValue == 443);
}

static BOOL RUINThemeStoreWebSameOrigin(NSURL *left, NSURL *right)
{
    NSURLComponents *a = left ? [NSURLComponents componentsWithURL:left resolvingAgainstBaseURL:NO] : nil;
    NSURLComponents *b = right ? [NSURLComponents componentsWithURL:right resolvingAgainstBaseURL:NO] : nil;
    if (!a || !b || ![a.scheme.lowercaseString isEqualToString:b.scheme.lowercaseString] ||
        ![a.host.lowercaseString isEqualToString:b.host.lowercaseString]) return NO;
    NSInteger portA = a.port ? a.port.integerValue : ([a.scheme.lowercaseString isEqualToString:@"https"] ? 443 : 80);
    NSInteger portB = b.port ? b.port.integerValue : ([b.scheme.lowercaseString isEqualToString:@"https"] ? 443 : 80);
    return portA == portB;
}

static NSString *RUINThemeStoreWebProductIDFromURL(NSURL *URL, BOOL *conflict)
{
    if (conflict) *conflict = NO;
    NSURLComponents *parts = URL ? [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO] : nil;
    if (!parts) return nil;
    NSMutableSet<NSString *> *IDs = [NSMutableSet set];
    NSArray<NSString *> *path = [parts.path componentsSeparatedByString:@"/"];
    BOOL productRoute = path.count == 4 || (path.count == 5 && path[4].length > 0) ||
        (path.count == 6 && path[4].length > 0 && path[5].length == 0);
    if (productRoute && [path[1] isEqualToString:@"themeshop"] && [path[2] isEqualToString:@"product"]) {
        NSString *ID = RUINThemeStoreWebNormalizedUUID(path[3]);
        if (ID) [IDs addObject:ID];
    }
    if ([parts.host.lowercaseString isEqualToString:@"themeshop.line.me"] &&
        parts.fragment.length > 0 && parts.fragment.length <= 256) {
        NSString *pattern = @"^/product/theme/([0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12})(?:\\?preview=[0-9]+)?$";
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:parts.fragment options:0 range:NSMakeRange(0, parts.fragment.length)];
        if (match.numberOfRanges == 2) {
            NSString *ID = RUINThemeStoreWebNormalizedUUID([parts.fragment substringWithRange:[match rangeAtIndex:1]]);
            if (ID) [IDs addObject:ID];
        }
    }
    NSSet<NSString *> *keys = [NSSet setWithArray:@[@"id", @"productid"]];
    for (NSURLQueryItem *item in parts.queryItems) {
        if (![keys containsObject:item.name.lowercaseString]) continue;
        NSString *ID = RUINThemeStoreWebNormalizedUUID(item.value ?: @"");
        if (ID) [IDs addObject:ID];
    }
    if (IDs.count > 1) {
        if (conflict) *conflict = YES;
        return nil;
    }
    return IDs.anyObject;
}

static NSError *RUINThemeStoreWebError(NSString *message)
{
    return [NSError errorWithDomain:@"RUINThemeStoreWeb" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@class RUINThemeStoreWebState;

@interface RUINThemeStoreWebBridge : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) RUINThemeStoreWebState *state;
@end

@interface RUINThemeStoreWebState : NSObject
@property (nonatomic, weak) UIViewController *controller;
@property (nonatomic, weak) WKWebView *webView;
@property (nonatomic, strong) RUINThemeStoreWebBridge *bridge;
@property (nonatomic) BOOL scriptInstalled;
- (void)detach;
@end

static RUINThemeStoreWebState *RUINThemeStoreWebGetState(UIViewController *controller, BOOL create)
{
    RUINThemeStoreWebState *state = objc_getAssociatedObject(controller, &gRUINThemeStoreWebAssociationKey);
    if (!state && create) {
        state = [RUINThemeStoreWebState new];
        state.controller = controller;
        objc_setAssociatedObject(controller, &gRUINThemeStoreWebAssociationKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

@implementation RUINThemeStoreWebState
- (void)detach
{
    WKWebView *webView = self.webView;
    if (webView && self.bridge) {
        dispatch_block_t cleanup = ^{
            [webView evaluateJavaScript:RUINThemeStoreWebJavaScript(NO, NO) completionHandler:nil];
            [webView.configuration.userContentController removeScriptMessageHandlerForName:RUINThemeStoreWebHandlerName
                contentWorld:WKContentWorld.pageWorld];
        };
        if ([NSThread isMainThread]) cleanup();
        else dispatch_async(dispatch_get_main_queue(), cleanup);
    }
    self.webView = nil;
    self.bridge.state = nil;
    self.bridge = nil;
    self.scriptInstalled = NO;
}

- (void)dealloc
{
    [self detach];
}
@end

static BOOL RUINThemeStoreWebValidateFrame(RUINThemeStoreWebBridge *bridge, WKScriptMessage *message)
{
    RUINThemeStoreWebState *state = bridge.state;
    WKWebView *webView = state.webView;
    if (!state || !webView || message.webView != webView || !message.frameInfo.isMainFrame) return NO;
    NSURL *frameURL = message.frameInfo.request.URL;
    NSURL *webURL = webView.URL;
    WKSecurityOrigin *origin = message.frameInfo.securityOrigin;
    if (!RUINThemeStoreWebAllowedURL(frameURL) || !RUINThemeStoreWebAllowedURL(webURL) ||
        !RUINThemeStoreWebSameOrigin(frameURL, webURL) ||
        [origin.protocol.lowercaseString isEqualToString:@"https"] == NO ||
        !RUINThemeStoreWebAllowedHost(origin.host ?: @"") ||
        ![origin.host.lowercaseString isEqualToString:frameURL.host.lowercaseString] ||
        (origin.port != 0 && origin.port != 443)) return NO;
    return YES;
}

static void RUINThemeStoreWebApplyPreference(RUINThemeStoreWebState *state)
{
    WKWebView *webView = state.webView;
    if (!webView || !state.scriptInstalled) return;
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:RUINThemeShopDownloadEnabledDefaultsKey];
    [webView evaluateJavaScript:RUINThemeStoreWebJavaScript(enabled, NO) completionHandler:nil];
}

static NSString *RUINThemeStoreWebFailureMessage(NSError *error)
{
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorNotConnectedToInternet: return @"インターネットに接続されていません。接続を確認して、もう一度お試しください。";
            case NSURLErrorTimedOut: return @"通信がタイムアウトしました。時間をおいて、もう一度お試しください。";
            case NSURLErrorNetworkConnectionLost: return @"通信が途中で切断されました。接続を確認して、もう一度お試しください。";
            case NSURLErrorCancelled: return @"通信が中止されました。";
            default: return RUINThemeStoreWebGenericError;
        }
    }
    if ([error.domain isEqualToString:RUINThemeStoreResolverErrorDomain]) return RUINThemeStoreWebResolverError;
    id description = error.userInfo[NSLocalizedDescriptionKey];
    if (![description isKindOfClass:NSString.class]) return RUINThemeStoreWebGenericError;
    if ([description isEqualToString:RUINThemeStoreWebSaveLocationError] ||
        [description isEqualToString:RUINThemeStoreWebResolverError] ||
        [description isEqualToString:RUINThemeStoreWebGenericError]) return description;
    return RUINThemeStoreWebGenericError;
}

static void RUINThemeStoreWebShowResult(UIViewController *controller, NSError *error)
{
    if (!controller || !controller.viewIfLoaded.window) return;
    NSString *title = error ? @"ダウンロードを完了できませんでした" : @"保存完了";
    NSString *message = error ? RUINThemeStoreWebFailureMessage(error) : RUINThemeStoreWebSavedMessage;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if (!error) [alert addAction:[UIAlertAction actionWithTitle:@"マイ着せかえを開く" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        RUINOpenDownloadedThemes(controller);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *presenter = controller;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) presenter = presenter.presentedViewController;
    if (!presenter.presentedViewController && presenter.viewIfLoaded.window) [presenter presentViewController:alert animated:YES completion:nil];
}

static void RUINThemeStoreWebFinishDownload(UIViewController *controller, NSError *error, NSURL *packageURL)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        gRUINThemeStoreWebDownloadInFlight = NO;
        BOOL isSavedArchive = !error && packageURL.isFileURL &&
            [packageURL.pathExtension.lowercaseString isEqualToString:@"linetheme"] &&
            [NSFileManager.defaultManager fileExistsAtPath:packageURL.path];
        if (!isSavedArchive) {
            atomic_fetch_add(&gRUINThemeStoreWebDownloadsFailed, 1);
            RUINThemeStoreWebShowResult(controller, error ?: RUINThemeStoreWebError(RUINThemeStoreWebSaveLocationError));
            return;
        }
        atomic_fetch_add(&gRUINThemeStoreWebDownloadsSucceeded, 1);
        RUINThemeStoreWebShowResult(controller, nil);
    });
}

static void RUINThemeStoreWebStartDownload(RUINThemeStoreWebState *state, NSString *productID, NSString *productURL)
{
    if (gRUINThemeStoreWebDownloadInFlight ||
        ![NSUserDefaults.standardUserDefaults boolForKey:RUINThemeShopDownloadEnabledDefaultsKey]) {
        atomic_fetch_add(&gRUINThemeStoreWebMessagesRejected, 1);
        return;
    }
    NSString *normalizedID = RUINThemeStoreWebNormalizedUUID(productID);
    NSURL *sourceURL = RUINValidatedThemeStoreURL(productURL);
    NSArray<NSString *> *path = [sourceURL.path componentsSeparatedByString:@"/"];
    if (!normalizedID || !sourceURL || path.count != 5 || ![path[3].lowercaseString isEqualToString:normalizedID]) {
        atomic_fetch_add(&gRUINThemeStoreWebMessagesRejected, 1);
        return;
    }

    WKWebView *webView = state.webView;
    BOOL webConflict = NO;
    NSString *frameID = RUINThemeStoreWebProductIDFromURL(webView.URL, &webConflict);
    // The script's store URL is the binding when LINE keeps the selected ID only in canonical metadata.
    if (webConflict || (frameID && ![frameID isEqualToString:normalizedID])) {
        atomic_fetch_add(&gRUINThemeStoreWebMessagesRejected, 1);
        return;
    }
    gRUINThemeStoreWebDownloadInFlight = YES;
    atomic_fetch_add(&gRUINThemeStoreWebMessagesAccepted, 1);
    atomic_fetch_add(&gRUINThemeStoreWebDownloadsStarted, 1);
    UIViewController *controller = state.controller;
    __weak UIViewController *weakController = controller;
    NSString *URLText = [NSString stringWithFormat:@"https://store.line.me/themeshop/product/%@/ja", normalizedID];
    if (!RUINValidatedThemeStoreURL(URLText)) {
        RUINThemeStoreWebFinishDownload(controller, RUINThemeStoreWebError(RUINThemeStoreWebResolverError), nil);
        return;
    }
    RUINResolveThemeStoreURL(URLText, ^(NSDictionary<NSString *,NSString *> *theme, NSError *error) {
        NSString *resolvedID = RUINThemeStoreWebNormalizedUUID(theme[@"productID"] ?: @"");
        if (error || !theme || ![resolvedID isEqualToString:normalizedID] ||
            ![theme[@"name"] isKindOfClass:NSString.class] || ![theme[@"version"] isKindOfClass:NSString.class]) {
            RUINThemeStoreWebFinishDownload(weakController, error ?: RUINThemeStoreWebError(RUINThemeStoreWebResolverError), nil);
            return;
        }
        RUINDownloadThemeByID(theme[@"name"], resolvedID, theme[@"version"], ^(NSURL *packageURL, NSError *downloadError) {
            RUINThemeStoreWebFinishDownload(weakController, downloadError, packageURL);
        });
    });
}

@implementation RUINThemeStoreWebBridge
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
    (void)userContentController;
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf userContentController:userContentController didReceiveScriptMessage:message]; });
        return;
    }
    if (![message.name isEqualToString:RUINThemeStoreWebHandlerName] || !RUINThemeStoreWebValidateFrame(self, message) ||
        ![message.body isKindOfClass:NSDictionary.class]) {
        atomic_fetch_add(&gRUINThemeStoreWebMessagesRejected, 1);
        return;
    }
    NSDictionary *body = message.body;
    id type = body[@"type"];
    if (![type isKindOfClass:NSString.class]) {
        atomic_fetch_add(&gRUINThemeStoreWebMessagesRejected, 1);
        return;
    }
    if ([type isEqualToString:@"pageReady"]) {
        RUINThemeStoreWebApplyPreference(self.state);
        return;
    }
    if (![type isEqualToString:@"downloadTheme"] ||
        ![body[@"productID"] isKindOfClass:NSString.class] ||
        ![body[@"productURL"] isKindOfClass:NSString.class] ||
        ![NSUserDefaults.standardUserDefaults boolForKey:RUINThemeShopDownloadEnabledDefaultsKey]) {
        atomic_fetch_add(&gRUINThemeStoreWebMessagesRejected, 1);
        return;
    }
    BOOL frameConflict = NO, pageConflict = NO;
    NSString *productID = RUINThemeStoreWebNormalizedUUID(body[@"productID"]);
    NSString *frameID = RUINThemeStoreWebProductIDFromURL(message.frameInfo.request.URL, &frameConflict);
    NSString *pageID = RUINThemeStoreWebProductIDFromURL(message.webView.URL, &pageConflict);
    NSString *bindingID = nil;
    NSURL *bindingURL = RUINValidatedThemeStoreURL(body[@"productURL"]);
    NSArray<NSString *> *bindingPath = [bindingURL.path componentsSeparatedByString:@"/"];
    if (bindingURL && bindingPath.count == 5) bindingID = bindingPath[3].lowercaseString;
    if (!productID || frameConflict || pageConflict || !bindingID || ![bindingID isEqualToString:productID] ||
        (frameID && ![frameID isEqualToString:productID]) || (pageID && ![pageID isEqualToString:productID])) {
        atomic_fetch_add(&gRUINThemeStoreWebMessagesRejected, 1);
        return;
    }
    RUINThemeStoreWebStartDownload(self.state, productID, body[@"productURL"]);
}
@end

static void RUINThemeStoreWebVisitViews(UIView *view, NSUInteger depth, NSUInteger *visited,
                                        NSMutableArray<WKWebView *> *webViews)
{
    if (!view || depth > 12 || *visited >= 512) return;
    (*visited)++;
    if ([view isKindOfClass:WKWebView.class]) {
        [webViews addObject:(WKWebView *)view];
        return;
    }
    for (UIView *child in view.subviews) RUINThemeStoreWebVisitViews(child, depth + 1, visited, webViews);
}

static void RUINThemeStoreWebInstallOnView(WKWebView *webView, UIViewController *controller)
{
    if (!webView || !controller) return;
    RUINThemeStoreWebState *state = RUINThemeStoreWebGetState(controller, YES);
    if (state.webView != webView) {
        [state detach];
        state.webView = webView;
        RUINThemeStoreWebBridge *bridge = [RUINThemeStoreWebBridge new];
        bridge.state = state;
        state.bridge = bridge;
        WKUserContentController *contentController = webView.configuration.userContentController;
        [contentController addScriptMessageHandler:bridge contentWorld:WKContentWorld.pageWorld name:RUINThemeStoreWebHandlerName];
        BOOL scriptAlreadyAdded = NO;
        for (WKUserScript *script in contentController.userScripts) {
            if ([script.source containsString:@"__ruinThemeStoreWebV1"]) { scriptAlreadyAdded = YES; break; }
        }
        if (!scriptAlreadyAdded) {
            WKUserScript *script = [[WKUserScript alloc] initWithSource:RUINThemeStoreWebJavaScript(NO, YES)
                injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
            [contentController addUserScript:script];
        }
        state.scriptInstalled = YES;
        atomic_fetch_add(&gRUINThemeStoreWebTrackedViews, 1);
        atomic_fetch_add(&gRUINThemeStoreWebInjections, 1);
    }
    gRUINThemeStoreWebControllers = gRUINThemeStoreWebControllers ?: [NSHashTable weakObjectsHashTable];
    [gRUINThemeStoreWebControllers addObject:controller];
    RUINThemeStoreWebApplyPreference(state);
}

static void RUINThemeStoreWebAttachController(id controller)
{
    if (![controller isKindOfClass:UIViewController.class]) return;
    UIViewController *viewController = controller;
    NSMutableArray<WKWebView *> *webViews = [NSMutableArray array];
    NSUInteger visited = 0;
    RUINThemeStoreWebVisitViews(viewController.view, 0, &visited, webViews);
    RUINThemeStoreWebState *state = RUINThemeStoreWebGetState(viewController, NO);
    WKWebView *tracked = state.webView;
    WKWebView *chosen = nil;
    if (webViews.count == 1) chosen = webViews.firstObject;
    else if (tracked && [webViews containsObject:tracked]) chosen = tracked;
    if (chosen) RUINThemeStoreWebInstallOnView(chosen, viewController);
    else if (tracked && ![webViews containsObject:tracked]) [state detach];
}

@interface RUINThemeStoreWebController : UIViewController @end

%group RUINThemeStoreWeb
%hook RUINThemeStoreWebController
- (void)viewDidAppear:(BOOL)animated
{
    %orig;
    id controller = self;
    atomic_fetch_add(&gRUINThemeStoreWebAppearCalls, 1);
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINThemeStoreWebAttachController(controller); });
        return;
    }
    RUINThemeStoreWebAttachController(controller);
}
%end
%end

static void RUINThemeStoreWebInstallHook(void)
{
    @synchronized (RUINThemeStoreWebClassName) {
        if (atomic_load(&gRUINThemeStoreWebHookStatus) == RUINThemeStoreWebHookInstalled) return;
        Class cls = objc_getClass(RUINThemeStoreWebClassName.UTF8String);
        if (!cls) {
            atomic_store(&gRUINThemeStoreWebHookStatus, RUINThemeStoreWebHookClassUnavailable);
            return;
        }
        // Verified in build/liff-view-metadata.json: viewDidAppear: v20@0:8B16.
        SEL selector = sel_registerName("viewDidAppear:");
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        Method ownMethod = NULL;
        for (unsigned int i = 0; i < count; i++) if (method_getName(methods[i]) == selector) { ownMethod = methods[i]; break; }
        free(methods);
        if (!ownMethod) {
            atomic_store(&gRUINThemeStoreWebHookStatus, RUINThemeStoreWebHookMethodUnavailable);
            return;
        }
        const char *encoding = method_getTypeEncoding(ownMethod);
        if (!encoding || strcmp(encoding, "v20@0:8B16") != 0) {
            atomic_store(&gRUINThemeStoreWebHookStatus, RUINThemeStoreWebHookABIMismatch);
            return;
        }
        if (!method_getImplementation(ownMethod)) {
            atomic_store(&gRUINThemeStoreWebHookStatus, RUINThemeStoreWebHookMethodUnavailable);
            return;
        }
        %init(RUINThemeStoreWeb, RUINThemeStoreWebController=cls);
        atomic_store(&gRUINThemeStoreWebHookStatus, RUINThemeStoreWebHookInstalled);
    }
}

static void RUINThemeStoreWebRefreshTrackedControllers(void)
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINThemeStoreWebRefreshTrackedControllers(); });
        return;
    }
    for (UIViewController *controller in gRUINThemeStoreWebControllers.allObjects) {
        RUINThemeStoreWebState *state = RUINThemeStoreWebGetState(controller, NO);
        if (state.webView && state.scriptInstalled) RUINThemeStoreWebApplyPreference(state);
    }
}

void RUINInstallThemeStoreWeb(void)
{
    if (!RUINThemeStoreWebTargetMatches()) {
        atomic_store(&gRUINThemeStoreWebHookStatus, RUINThemeStoreWebHookVersionGated);
        return;
    }
    static dispatch_once_t observerOnce;
    dispatch_once(&observerOnce, ^{
        gRUINThemeStoreWebDefaultsObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *notification) { RUINThemeStoreWebRefreshTrackedControllers(); }];
    });
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINInstallThemeStoreWeb(); });
        return;
    }
    (void)gRUINThemeStoreWebDefaultsObserver;
    RUINThemeStoreWebInstallHook();
}

NSDictionary<NSString *, id> *RUINThemeStoreWebDiagnostics(void)
{
    static NSArray<NSString *> * const hookNames = @[@"pending", @"installed", @"class_unavailable", @"method_unavailable", @"abi_mismatch", @"version_gated"];
    int status = atomic_load(&gRUINThemeStoreWebHookStatus);
    NSString *hook = status >= 0 && status < (int)hookNames.count ? hookNames[(NSUInteger)status] : @"unknown";
    return @{
        @"hook": hook,
        @"viewDidAppearCalls": @(atomic_load(&gRUINThemeStoreWebAppearCalls)),
        @"trackedWebViews": @(atomic_load(&gRUINThemeStoreWebTrackedViews)),
        @"bridgeInjections": @(atomic_load(&gRUINThemeStoreWebInjections)),
        @"messagesAccepted": @(atomic_load(&gRUINThemeStoreWebMessagesAccepted)),
        @"messagesRejected": @(atomic_load(&gRUINThemeStoreWebMessagesRejected)),
        @"downloadsStarted": @(atomic_load(&gRUINThemeStoreWebDownloadsStarted)),
        @"downloadsSucceeded": @(atomic_load(&gRUINThemeStoreWebDownloadsSucceeded)),
        @"downloadsFailed": @(atomic_load(&gRUINThemeStoreWebDownloadsFailed)),
        @"enabled": @([NSUserDefaults.standardUserDefaults boolForKey:RUINThemeShopDownloadEnabledDefaultsKey])
    };
}
