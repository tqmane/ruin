%config(generator=internal)

#import "ThemeStoreImages.h"

NSString *RUINThemeStoreImagesScript(void)
{
    return @"(() => {\n"
        "if (!['themeshop.line.me','themeshop-liff-v2-release.landpress.line.me'].includes(location.hostname)) return;\n"
        "if (window.__ruinThemeImagesV1) return;\n"
        "const state = window.__ruinThemeImagesV1 = {normalized:0};\n"
        "const fix = value => { try { const u = new URL(value, document.baseURI);\n"
        "if (u.protocol !== 'https:' || u.hostname !== 'shop.line-scdn.net' || u.username || u.password || u.search || u.hash || (u.port && u.port !== '443')) return value;\n"
        "if (!/^\\/themeshop\\/v1\\/products\\/[a-f0-9]{2}\\/[a-f0-9]{2}\\/[a-f0-9]{2}\\/[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}\\/[0-9]+\\/ANDROID\\/[a-z0-9_@.-]+@2x\\.png$/i.test(u.pathname)) return value;\n"
        "u.pathname = u.pathname.replace(/@2x\\.png$/i, '.png'); state.normalized++; return u.href;\n"
        "} catch (_) {return value;} };\n"
        "const fixSet = value => typeof value === 'string' ? value.replace(/(?:https:)?\\/\\/shop\\.line-scdn\\.net\\/[^\\s,]+/g, fix) : value;\n"
        "const wrap = (proto, key, transform) => { const d = Object.getOwnPropertyDescriptor(proto, key);\n"
        "if (!d || !d.set || !d.configurable) return;\n"
        "Object.defineProperty(proto, key, {...d, set(value) {d.set.call(this, transform(value));}}); };\n"
        "wrap(HTMLImageElement.prototype, 'src', fix);\n"
        "wrap(HTMLImageElement.prototype, 'srcset', fixSet);\n"
        "if (typeof HTMLSourceElement !== 'undefined') wrap(HTMLSourceElement.prototype, 'srcset', fixSet);\n"
        "const originalAttribute = Element.prototype.setAttribute;\n"
        "Element.prototype.setAttribute = function(name, value) {\n"
        "const key = String(name).toLowerCase();\n"
        "if (this instanceof HTMLImageElement) { if (key === 'src') value = fix(value); else if (key === 'srcset') value = fixSet(value); }\n"
        "else if (typeof HTMLSourceElement !== 'undefined' && this instanceof HTMLSourceElement && key === 'srcset') value = fixSet(value);\n"
        "return originalAttribute.call(this, name, value); };\n"
        "})()";
}

#if !defined(RUIN_THEME_IMAGES_HOST_CHECK)
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

static atomic_int gStatus;
static atomic_uint_fast64_t gScopedLoads, gScriptsAdded;

static BOOL RUINThemeImagesTarget(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return ([NSBundle.mainBundle.bundleIdentifier isEqual:@"jp.naver.line"] ||
        [info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"]) &&
        [info[@"CFBundleShortVersionString"] isEqual:@"26.16.0"] &&
        [info[@"CFBundleVersion"] isEqual:@"2026.1006.1718"];
}

%group RUINThemeStoreImages
%hook WKWebView
- (WKNavigation *)loadRequest:(NSURLRequest *)request
{
    NSString *host = request.URL.host.lowercaseString;
    if ([request.URL.scheme.lowercaseString isEqual:@"https"] &&
        ([host isEqual:@"themeshop.line.me"] ||
         [host isEqual:@"themeshop-liff-v2-release.landpress.line.me"])) {
        atomic_fetch_add(&gScopedLoads, 1);
        WKUserContentController *content = self.configuration.userContentController;
        BOOL installed = NO;
        for (WKUserScript *script in content.userScripts)
            if ([script.source containsString:@"__ruinThemeImagesV1"]) { installed = YES; break; }
        if (!installed) {
            [content addUserScript:[[WKUserScript alloc] initWithSource:RUINThemeStoreImagesScript()
                injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
            atomic_fetch_add(&gScriptsAdded, 1);
        }
    }
    return %orig;
}
%end
%end

void RUINInstallThemeStoreImages(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!RUINThemeImagesTarget()) { atomic_store(&gStatus, 1); return; }
        Method method = class_getInstanceMethod(WKWebView.class, @selector(loadRequest:));
        if (!method || strcmp(method_getTypeEncoding(method), "@24@0:8@16") != 0) {
            atomic_store(&gStatus, 2); return;
        }
        IMP original = method_getImplementation(method);
        if (!original) { atomic_store(&gStatus, 2); return; }
        %init(RUINThemeStoreImages);
        atomic_store(&gStatus, 3);
    });
}

NSDictionary *RUINThemeStoreImagesDiagnostics(void)
{
    return @{@"hookStatus": @(atomic_load(&gStatus)), @"scopedLoads": @(atomic_load(&gScopedLoads)),
        @"scriptsAdded": @(atomic_load(&gScriptsAdded))};
}
#endif
