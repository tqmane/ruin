%config(generator=internal);

#import "ClientVersionAdvertisement.h"

#import "../core/Features.h"

#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

static NSString *const kLegacyClientVersion = @"15.16.1";
static NSString *const kLegacyBundleVersion = @"2025.926.1805";
static NSString *const kLegacyAppStoreVersionID = @"878450687";
static NSString *const kCurrentClientVersion = @"26.16.0";
static NSString *const kCurrentBundleVersion = @"2026.1006.1718";
static const char *const kRequestSelectorName = "dataTaskWithRequest:";
static const char *const kRequestCompletionSelectorName = "dataTaskWithRequest:completionHandler:";

typedef NS_ENUM(NSInteger, RUINAdvertisementHookStatus) {
    RUINAdvertisementHookPending,
    RUINAdvertisementHookInstalled,
    RUINAdvertisementHookTargetMismatch,
    RUINAdvertisementHookSessionClassMismatch,
    RUINAdvertisementHookSelectorMissing,
    RUINAdvertisementHookABIMismatch,
    RUINAdvertisementHookInstallFailed
};

typedef NS_ENUM(NSInteger, RUINHeaderLookupResult) {
    RUINHeaderMissing,
    RUINHeaderFound,
    RUINHeaderInvalid
};

typedef NS_ENUM(NSInteger, RUINHeaderRewriteResult) {
    RUINHeaderUnrecognized,
    RUINHeaderUnchanged,
    RUINHeaderChanged,
    RUINHeaderMalformed
};

typedef NS_ENUM(NSInteger, RUINObservedUAStyle) {
    RUINObservedUAStyleUnseen,
    RUINObservedUAStyleMissing,
    RUINObservedUAStyleIPhoneAppLine,
    RUINObservedUAStyleLine,
    RUINObservedUAStyleOther
};

enum { kRequestHook, kRequestCompletionHook, kRequestHookCount };

typedef void (^RUINURLSessionCompletion)(NSData *, NSURLResponse *, NSError *);
typedef RUINHeaderRewriteResult (*RUINHeaderRewriter)(NSString *, NSString **, BOOL *);

static atomic_int gHookStatus = ATOMIC_VAR_INIT(RUINAdvertisementHookPending);
static atomic_bool gRequestSessionClassMatched = ATOMIC_VAR_INIT(false);
static atomic_int gObservedUAStyle = ATOMIC_VAR_INIT(RUINObservedUAStyleUnseen);
static atomic_bool gUAContainsCurrentVersion = ATOMIC_VAR_INIT(false);
static atomic_bool gUAContainsCurrentBuild = ATOMIC_VAR_INIT(false);
static atomic_uint_fast64_t gRequestsObserved;
static atomic_uint_fast64_t gRequestsRewritten;
static atomic_uint_fast64_t gHostScopedRequests;
static atomic_uint_fast64_t gFlagOffRequests;
static atomic_uint_fast64_t gWrongTargetRequests;
static atomic_uint_fast64_t gOutOfScopeRequests;
static atomic_uint_fast64_t gMalformedRequests;
static atomic_uint_fast64_t gNoRecognizedFields;
static atomic_uint_fast64_t gRewriteApplication;
static atomic_uint_fast64_t gRewriteApplicationVersion;
static atomic_uint_fast64_t gRewriteUserAgent;
static atomic_uint_fast64_t gRewriteUserAgentBuildVersion;
static dispatch_once_t gInstallOnce;

#if defined(RUIN_CLIENT_VERSION_ADVERTISEMENT_HOST_CHECK)
NSString *const RUINTargetBundleIdentifier = @"jp.naver.line";
NSString *const RUINTargetVersion = @"26.16.0";
NSString *const RUINTargetBuild = @"2026.1006.1718";
NSString *const RUINLocalLYPEnabledDefaultsKey = @"RUINLocalLYPEnabled";
#endif

static BOOL RUINInfoStringEquals(NSDictionary *info, NSString *key, NSString *expected)
{
    id value = info[key];
    return [value isKindOfClass:NSString.class] && [value isEqualToString:expected];
}

static BOOL RUINClientVersionAdvertisementTargetMatches(void)
{
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *info = bundle.infoDictionary ?: @{};
    BOOL bundleMatches = [bundle.bundleIdentifier isEqualToString:RUINTargetBundleIdentifier] ||
        RUINInfoStringEquals(info, @"RUINOriginalBundleIdentifier", RUINTargetBundleIdentifier);
    return bundleMatches &&
        RUINInfoStringEquals(info, @"CFBundleShortVersionString", RUINTargetVersion) &&
        RUINInfoStringEquals(info, @"CFBundleVersion", RUINTargetBuild);
}

static BOOL RUINClientVersionAdvertisementEnabled(void)
{
    return RUINClientVersionAdvertisementTargetMatches() &&
        [NSUserDefaults.standardUserDefaults boolForKey:RUINLocalLYPEnabledDefaultsKey];
}

static BOOL RUINIsDottedVersion(NSString *value, NSUInteger minimumParts, NSUInteger maximumParts)
{
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"."];
    if (parts.count < minimumParts || parts.count > maximumParts) return NO;
    for (NSString *part in parts) {
        if (part.length == 0) return NO;
        for (NSUInteger i = 0; i < part.length; i++) {
            unichar c = [part characterAtIndex:i];
            if (c < '0' || c > '9') return NO;
        }
    }
    return YES;
}

static RUINHeaderLookupResult RUINLookupHeader(NSDictionary *headers, NSString *field,
                                                NSString **actualField, NSString **value)
{
    if (![headers isKindOfClass:NSDictionary.class]) return RUINHeaderMissing;
    NSString *foundField = nil;
    id foundValue = nil;
    NSUInteger matches = 0;
    for (id key in headers) {
        if (![key isKindOfClass:NSString.class] || [key caseInsensitiveCompare:field] != NSOrderedSame) continue;
        matches++;
        if (matches > 1) return RUINHeaderInvalid;
        foundField = key;
        foundValue = headers[key];
    }
    if (matches == 0) return RUINHeaderMissing;
    if (![foundValue isKindOfClass:NSString.class] || [foundValue length] > 4096 ||
        [foundValue rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound)
        return RUINHeaderInvalid;
    if (actualField) *actualField = foundField;
    if (value) *value = foundValue;
    return RUINHeaderFound;
}

static RUINHeaderRewriteResult RUINRewriteXLineApplication(NSString *value, NSString **rewritten,
                                                            BOOL *secondaryChange)
{
    (void)secondaryChange;
    NSArray<NSString *> *parts = [value componentsSeparatedByString:@"\t"];
    if (parts.count != 4 || !([parts[0] isEqualToString:@"IOS"] ||
        [parts[0] isEqualToString:@"IPAD"] || [parts[0] isEqualToString:@"IOSIPAD"]) ||
        parts[2].length == 0 || !RUINIsDottedVersion(parts[1], 3, 3) ||
        !RUINIsDottedVersion(parts[3], 2, 3)) return RUINHeaderMalformed;
    if (![parts[1] isEqualToString:kCurrentClientVersion]) return RUINHeaderUnchanged;
    NSMutableArray<NSString *> *updated = [parts mutableCopy];
    updated[1] = kLegacyClientVersion;
    if (rewritten) *rewritten = [updated componentsJoinedByString:@"\t"];
    return RUINHeaderChanged;
}

static RUINHeaderRewriteResult RUINRewriteApplicationVersion(NSString *value, NSString **rewritten,
                                                             BOOL *secondaryChange)
{
    (void)secondaryChange;
    if (!RUINIsDottedVersion(value, 3, 3)) return RUINHeaderMalformed;
    if (![value isEqualToString:kCurrentClientVersion]) return RUINHeaderUnchanged;
    if (rewritten) *rewritten = kLegacyClientVersion;
    return RUINHeaderChanged;
}

static RUINObservedUAStyle RUINParseUserAgent(NSString *value, NSRange *versionRange)
{
    NSString *lowercase = value.lowercaseString;
    NSUInteger versionStart = 0;
    RUINObservedUAStyle style = RUINObservedUAStyleOther;
    if ([lowercase hasPrefix:@"iphoneapp.line/"]) {
        versionStart = [@"iphoneapp.line/" length];
        style = RUINObservedUAStyleIPhoneAppLine;
    } else if ([lowercase hasPrefix:@"line/"]) {
        versionStart = [@"line/" length];
        style = RUINObservedUAStyleLine;
    } else return RUINObservedUAStyleOther;

    NSUInteger versionEnd = versionStart;
    while (versionEnd < value.length) {
        unichar c = [value characterAtIndex:versionEnd];
        if (!((c >= '0' && c <= '9') || c == '.')) break;
        versionEnd++;
    }
    NSString *version = [value substringWithRange:NSMakeRange(versionStart, versionEnd - versionStart)];
    if (!RUINIsDottedVersion(version, 3, 3)) return RUINObservedUAStyleOther;
    if (versionEnd < value.length) {
        unichar next = [value characterAtIndex:versionEnd];
        if ((next >= '0' && next <= '9') || (next >= 'A' && next <= 'Z') ||
            (next >= 'a' && next <= 'z') || next == '.') return RUINObservedUAStyleOther;
    }
    if (versionRange) *versionRange = NSMakeRange(versionStart, versionEnd - versionStart);
    return style;
}

static BOOL RUINUserAgentBuildVersionRange(NSString *value, NSRange *buildRange)
{
    NSString *token = @"BuildVersion:";
    NSRange tokenRange = [value rangeOfString:token options:NSCaseInsensitiveSearch];
    if (tokenRange.location == NSNotFound ||
        [value rangeOfString:token options:NSCaseInsensitiveSearch
            range:NSMakeRange(NSMaxRange(tokenRange), value.length - NSMaxRange(tokenRange))].location != NSNotFound)
        return NO;
    NSUInteger start = NSMaxRange(tokenRange);
    while (start < value.length && [value characterAtIndex:start] == ' ') start++;
    NSUInteger end = start;
    while (end < value.length) {
        unichar c = [value characterAtIndex:end];
        if (!((c >= '0' && c <= '9') || c == '.')) break;
        end++;
    }
    NSString *version = [value substringWithRange:NSMakeRange(start, end - start)];
    if (!RUINIsDottedVersion(version, 3, 3)) return NO;
    if (end < value.length) {
        unichar next = [value characterAtIndex:end];
        if ((next >= '0' && next <= '9') || (next >= 'A' && next <= 'Z') ||
            (next >= 'a' && next <= 'z') || next == '.') return NO;
    }
    if (buildRange) *buildRange = NSMakeRange(start, end - start);
    return YES;
}

static RUINHeaderRewriteResult RUINRewriteUserAgent(NSString *value, NSString **rewritten,
                                                   BOOL *buildTokenChanged)
{
    if (buildTokenChanged) *buildTokenChanged = NO;
    NSRange versionRange = NSMakeRange(0, 0);
    RUINObservedUAStyle style = RUINParseUserAgent(value, &versionRange);
    if (style == RUINObservedUAStyleOther) return RUINHeaderUnrecognized;
    NSString *version = [value substringWithRange:versionRange];
    NSString *updated = value;
    BOOL versionEligible = [version isEqualToString:kCurrentClientVersion] || [version isEqualToString:kLegacyClientVersion];
    if (!versionEligible) return RUINHeaderUnchanged;
    if ([version isEqualToString:kCurrentClientVersion])
        updated = [updated stringByReplacingCharactersInRange:versionRange withString:kLegacyClientVersion];
    NSRange buildRange = NSMakeRange(0, 0);
    NSString *build = RUINUserAgentBuildVersionRange(updated, &buildRange) ?
        [updated substringWithRange:buildRange] : nil;
    BOOL buildChanged = [build isEqualToString:kCurrentBundleVersion];
    if (buildChanged)
        updated = [updated stringByReplacingCharactersInRange:buildRange withString:kLegacyBundleVersion];
    if (buildTokenChanged) *buildTokenChanged = buildChanged;
    if (rewritten) *rewritten = updated;
    if (![updated isEqualToString:value]) return RUINHeaderChanged;
    return RUINHeaderUnchanged;
}

static void RUINRecordObservedUAStyle(RUINObservedUAStyle style)
{
    int previous = atomic_load(&gObservedUAStyle);
    for (;;) {
        int next = previous;
        if (previous == RUINObservedUAStyleUnseen || previous == RUINObservedUAStyleMissing)
            next = style;
        else if (style != RUINObservedUAStyleMissing && style != previous)
            next = RUINObservedUAStyleOther;
        if (next == previous || atomic_compare_exchange_weak(&gObservedUAStyle, &previous, next)) return;
    }
}

static void RUINObserveUserAgent(NSDictionary *requestHeaders, NSDictionary *sessionHeaders)
{
    NSString *value = nil;
    RUINHeaderLookupResult lookup = RUINLookupHeader(requestHeaders, @"User-Agent", NULL, &value);
    if (lookup == RUINHeaderMissing)
        lookup = RUINLookupHeader(sessionHeaders, @"User-Agent", NULL, &value);
    if (lookup == RUINHeaderMissing) {
        RUINRecordObservedUAStyle(RUINObservedUAStyleMissing);
        return;
    }
    if (lookup == RUINHeaderInvalid) {
        RUINRecordObservedUAStyle(RUINObservedUAStyleOther);
        return;
    }
    NSRange versionRange = NSMakeRange(0, 0);
    RUINObservedUAStyle style = RUINParseUserAgent(value, &versionRange);
    RUINRecordObservedUAStyle(style);
    if (style == RUINObservedUAStyleOther) return;
    NSString *version = [value substringWithRange:versionRange];
    if ([version isEqualToString:kCurrentClientVersion]) atomic_store(&gUAContainsCurrentVersion, true);
    NSRange buildRange = NSMakeRange(0, 0);
    if (RUINUserAgentBuildVersionRange(value, &buildRange) &&
        [[value substringWithRange:buildRange] isEqualToString:kCurrentBundleVersion])
        atomic_store(&gUAContainsCurrentBuild, true);
}

static BOOL RUINCollectHeaderOverride(NSDictionary *requestHeaders, NSDictionary *sessionHeaders,
                                      NSString *field, RUINHeaderRewriter rewriter,
                                      NSMutableDictionary<NSString *, NSString *> *overrides,
                                      BOOL *userAgentBuildVersionChanged)
{
    NSString *actualField = nil;
    NSString *value = nil;
    RUINHeaderLookupResult lookup = RUINLookupHeader(requestHeaders, field, &actualField, &value);
    if (lookup == RUINHeaderInvalid) return NO;
    if (lookup == RUINHeaderMissing) {
        lookup = RUINLookupHeader(sessionHeaders, field, &actualField, &value);
        if (lookup == RUINHeaderInvalid) return NO;
    }
    if (lookup == RUINHeaderMissing) return YES;

    NSString *rewritten = nil;
    BOOL secondaryChange = NO;
    RUINHeaderRewriteResult result = rewriter(value, &rewritten, &secondaryChange);
    if (result == RUINHeaderMalformed) return NO;
    if (userAgentBuildVersionChanged && secondaryChange) *userAgentBuildVersionChanged = YES;
    if (result == RUINHeaderChanged && rewritten && ![rewritten isEqualToString:value])
        overrides[actualField] = rewritten;
    return YES;
}

static BOOL RUINURLIsSupportedLINEAPI(NSURL *URL)
{
    if (![URL.scheme.lowercaseString isEqualToString:@"https"] || URL.user.length || URL.password.length ||
        (URL.port && URL.port.integerValue != 443)) return NO;
    NSString *host = URL.host.lowercaseString;
    return [host hasSuffix:@".line.naver.jp"] || [host hasSuffix:@".line.me"] ||
        [host hasSuffix:@".line-apps.com"];
}

// Returns only per-request overrides. Session configuration and opaque bodies are never changed.
static NSDictionary<NSString *, NSString *> *RUINClientVersionHeaderOverrides(
    NSDictionary *requestHeaders, NSDictionary *sessionHeaders, NSURL *URL,
    BOOL targetMatches, BOOL enabled, BOOL *malformed, BOOL *userAgentBuildVersionChanged)
{
    if (malformed) *malformed = NO;
    if (userAgentBuildVersionChanged) *userAgentBuildVersionChanged = NO;
    if (!targetMatches || !enabled || !RUINURLIsSupportedLINEAPI(URL)) return @{};
    NSMutableDictionary<NSString *, NSString *> *overrides = [NSMutableDictionary dictionary];
    if (!RUINCollectHeaderOverride(requestHeaders, sessionHeaders, @"X-Line-Application",
            RUINRewriteXLineApplication, overrides, userAgentBuildVersionChanged) ||
        !RUINCollectHeaderOverride(requestHeaders, sessionHeaders, @"X-Line-Application-Version",
            RUINRewriteApplicationVersion, overrides, userAgentBuildVersionChanged) ||
        !RUINCollectHeaderOverride(requestHeaders, sessionHeaders, @"User-Agent",
            RUINRewriteUserAgent, overrides, userAgentBuildVersionChanged)) {
        if (malformed) *malformed = YES;
        return @{};
    }
    return [overrides copy];
}

static BOOL RUINTypeIsObject(const char *type, BOOL block)
{
    if (!type) return NO;
    while (*type && strchr("rnNoORV", *type)) type++;
    if (*type++ != '@') return NO;
    if (block) return type[0] == '?' && type[1] == '\0';
    if (*type == '\0') return YES;
    if (*type++ != '"') return NO;
    while (*type && *type != '"') type++;
    return *type == '"' && type[1] == '\0';
}

static BOOL RUINTypeIsSelector(const char *type)
{
    if (!type) return NO;
    while (*type && strchr("rnNoORV", *type)) type++;
    return type[0] == ':' && type[1] == '\0';
}

static BOOL RUINMethodHasRequestABI(Method method, BOOL hasCompletion)
{
    if (!method) return NO;
    const char *encoding = method_getTypeEncoding(method);
    NSMethodSignature *signature = encoding ? [NSMethodSignature signatureWithObjCTypes:encoding] : nil;
    NSUInteger arguments = hasCompletion ? 4 : 3;
    return signature && signature.numberOfArguments == arguments &&
        RUINTypeIsObject(signature.methodReturnType, NO) &&
        RUINTypeIsObject([signature getArgumentTypeAtIndex:0], NO) &&
        RUINTypeIsSelector([signature getArgumentTypeAtIndex:1]) &&
        RUINTypeIsObject([signature getArgumentTypeAtIndex:2], NO) &&
        (!hasCompletion || RUINTypeIsObject([signature getArgumentTypeAtIndex:3], YES));
}

static BOOL RUINClassIsNSURLSession(Class cls)
{
    if (!cls || class_isMetaClass(cls)) return NO;
    for (Class candidate = cls; candidate; candidate = class_getSuperclass(candidate))
        if (candidate == NSURLSession.class) return YES;
    return NO;
}

static NSURLRequest *RUINRequestWithAdvertisedHeaders(id self, NSURLRequest *request)
{
    if (!request) return request;
    atomic_fetch_add(&gRequestsObserved, 1);
    BOOL targetMatches = RUINClientVersionAdvertisementTargetMatches();
    if (!targetMatches) atomic_fetch_add(&gWrongTargetRequests, 1);
    else if (!request.URL || !RUINURLIsSupportedLINEAPI(request.URL))
        atomic_fetch_add(&gOutOfScopeRequests, 1);
    else {
        atomic_fetch_add(&gHostScopedRequests, 1);
        NSDictionary *sessionHeaders = ((NSURLSession *)self).configuration.HTTPAdditionalHeaders ?: @{};
        NSDictionary *requestHeaders = request.allHTTPHeaderFields ?: @{};
        RUINObserveUserAgent(requestHeaders, sessionHeaders);
        if (![NSUserDefaults.standardUserDefaults boolForKey:RUINLocalLYPEnabledDefaultsKey])
            atomic_fetch_add(&gFlagOffRequests, 1);
        else {
            BOOL malformed = NO;
            BOOL buildVersionRewritten = NO;
            NSDictionary *overrides = RUINClientVersionHeaderOverrides(requestHeaders,
                sessionHeaders, request.URL, YES, YES, &malformed, &buildVersionRewritten);
            if (malformed) atomic_fetch_add(&gMalformedRequests, 1);
            else if (overrides.count == 0) atomic_fetch_add(&gNoRecognizedFields, 1);
            else {
                NSMutableURLRequest *copy = [request mutableCopy];
                if (copy) {
                    [overrides enumerateKeysAndObjectsUsingBlock:^(NSString *field, NSString *value, BOOL *stop) {
                        (void)stop;
                        [copy setValue:value forHTTPHeaderField:field];
                    }];
                    atomic_fetch_add(&gRequestsRewritten, 1);
                    for (NSString *field in overrides) {
                        if ([field caseInsensitiveCompare:@"X-Line-Application"] == NSOrderedSame)
                            atomic_fetch_add(&gRewriteApplication, 1);
                        else if ([field caseInsensitiveCompare:@"X-Line-Application-Version"] == NSOrderedSame)
                            atomic_fetch_add(&gRewriteApplicationVersion, 1);
                        else if ([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame)
                            atomic_fetch_add(&gRewriteUserAgent, 1);
                    }
                    if (buildVersionRewritten) atomic_fetch_add(&gRewriteUserAgentBuildVersion, 1);
                    request = copy;
                }
            }
        }
    }
    return request;
}

%group RUINAdvertisedClientVersion
%hook RUINRequestSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
{
    if (atomic_load(&gHookStatus) == RUINAdvertisementHookInstalled)
        request = RUINRequestWithAdvertisedHeaders(self, request);
    return %orig(request);
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(RUINURLSessionCompletion)completion
{
    if (atomic_load(&gHookStatus) == RUINAdvertisementHookInstalled)
        request = RUINRequestWithAdvertisedHeaders(self, request);
    return %orig(request, completion);
}
%end
%end

static const char *RUINHookStatusName(int status)
{
    switch (status) {
        case RUINAdvertisementHookInstalled: return "installed";
        case RUINAdvertisementHookTargetMismatch: return "target_mismatch";
        case RUINAdvertisementHookSessionClassMismatch: return "session_class_mismatch";
        case RUINAdvertisementHookSelectorMissing: return "selector_missing";
        case RUINAdvertisementHookABIMismatch: return "abi_mismatch";
        case RUINAdvertisementHookInstallFailed: return "install_failed";
        default: return "pending";
    }
}

static const char *RUINObservedUAStyleName(int style)
{
    switch (style) {
        case RUINObservedUAStyleIPhoneAppLine: return "iphoneapp_line";
        case RUINObservedUAStyleLine: return "line";
        case RUINObservedUAStyleOther: return "other";
        case RUINObservedUAStyleMissing:
        case RUINObservedUAStyleUnseen:
        default: return "missing";
    }
}

static Class RUINDirectRequestSessionClass(void)
{
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSOperationQueue *delegateQueue = [NSOperationQueue new];
    delegateQueue.maxConcurrentOperationCount = 1;
    NSObject<NSURLSessionDelegate> *delegate = (id<NSURLSessionDelegate>)[NSObject new];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
        delegate:delegate delegateQueue:delegateQueue];
    Class cls = session ? object_getClass(session) : Nil;
    [session invalidateAndCancel];
    return cls;
}

void RUINInstallClientVersionAdvertisement(void)
{
    dispatch_once(&gInstallOnce, ^{
        if (!RUINClientVersionAdvertisementTargetMatches()) {
            atomic_store(&gHookStatus, RUINAdvertisementHookTargetMismatch);
            return;
        }

        NSURLSession *sharedSession = NSURLSession.sharedSession;
        Class sharedClass = sharedSession ? object_getClass(sharedSession) : Nil;
        Class directRequestClass = RUINDirectRequestSessionClass();
        if (!RUINClassIsNSURLSession(sharedClass) || directRequestClass != sharedClass) {
            atomic_store(&gHookStatus, RUINAdvertisementHookSessionClassMismatch);
            return;
        }
        atomic_store(&gRequestSessionClassMatched, true);

        SEL selectors[kRequestHookCount] = {
            sel_registerName(kRequestSelectorName), sel_registerName(kRequestCompletionSelectorName)
        };
        Method methods[kRequestHookCount] = {NULL, NULL};
        for (NSUInteger i = 0; i < kRequestHookCount; i++) {
            methods[i] = class_getInstanceMethod(sharedClass, selectors[i]);
            if (!methods[i]) {
                atomic_store(&gHookStatus, RUINAdvertisementHookSelectorMissing);
                return;
            }
            if (!RUINMethodHasRequestABI(methods[i], i == kRequestCompletionHook)) {
                atomic_store(&gHookStatus, RUINAdvertisementHookABIMismatch);
                return;
            }
        }

        IMP previous[kRequestHookCount] = {NULL, NULL};
        for (NSUInteger i = 0; i < kRequestHookCount; i++) {
            previous[i] = method_getImplementation(methods[i]);
            if (!previous[i]) {
                atomic_store(&gHookStatus, RUINAdvertisementHookInstallFailed);
                return;
            }
        }
        // Preflight the whole group. Its bodies remain pass-through unless both
        // selectors install, so a partial failure cannot rewrite requests.
        %init(RUINAdvertisedClientVersion, RUINRequestSession = sharedClass);
        BOOL installed = YES;
        for (NSUInteger i = 0; i < kRequestHookCount; i++) {
            Method installedMethod = class_getInstanceMethod(sharedClass, selectors[i]);
            installed = installed && installedMethod &&
                method_getImplementation(installedMethod) != previous[i];
        }
        atomic_store(&gHookStatus, installed ? RUINAdvertisementHookInstalled :
            RUINAdvertisementHookInstallFailed);
    });
}

NSDictionary<NSString *, id> *RUINClientVersionAdvertisementDiagnostics(void)
{
    BOOL targetMatches = RUINClientVersionAdvertisementTargetMatches();
    BOOL enabled = RUINClientVersionAdvertisementEnabled();
    return @{
        @"status":[NSString stringWithUTF8String:RUINHookStatusName(atomic_load(&gHookStatus))] ?: @"pending",
        @"targetMatches26_16_0":@(targetMatches),
        @"localLYPEnabled":@(enabled),
        @"requestSessionClassMatched":@(atomic_load(&gRequestSessionClassMatched)),
        @"observedUAStyle":[NSString stringWithUTF8String:RUINObservedUAStyleName(atomic_load(&gObservedUAStyle))],
        @"containsCurrentVersion":@(atomic_load(&gUAContainsCurrentVersion)),
        @"containsCurrentBuild":@(atomic_load(&gUAContainsCurrentBuild)),
        @"advertisedClientVersion":kLegacyClientVersion,
        @"staticCFBundleVersion":kLegacyBundleVersion,
        @"staticAppStoreVersionID":kLegacyAppStoreVersionID,
        @"appStoreVersionIDNetworkFieldStatus":@"not_observed",
        @"appStoreVersionIDQueryOrBodyStatus":@"not_observed_in_available_capture",
        @"recognizedFields":@[@"X-Line-Application[1]", @"X-Line-Application-Version",
            @"User-Agent:iphoneapp.line/<version> or Line/<version>", @"User-Agent:BuildVersion:<version> (if present)"],
        @"sessionConfigurationModified":@NO,
        @"bundleMetadataModified":@NO,
        @"requestBodyInspected":@NO,
        @"requestsObserved":@(atomic_load(&gRequestsObserved)),
        @"requestsRewritten":@(atomic_load(&gRequestsRewritten)),
        @"hostScopedRequests":@(atomic_load(&gHostScopedRequests)),
        @"flagOffRequests":@(atomic_load(&gFlagOffRequests)),
        @"wrongTargetRequests":@(atomic_load(&gWrongTargetRequests)),
        @"outOfScopeRequests":@(atomic_load(&gOutOfScopeRequests)),
        @"malformedRequests":@(atomic_load(&gMalformedRequests)),
        @"noRecognizedVersionFields":@(atomic_load(&gNoRecognizedFields)),
        @"rewrittenXLineApplication":@(atomic_load(&gRewriteApplication)),
        @"rewrittenXLineApplicationVersion":@(atomic_load(&gRewriteApplicationVersion)),
        @"rewrittenUserAgent":@(atomic_load(&gRewriteUserAgent)),
        @"rewrittenUserAgentBuildVersionToken":@(atomic_load(&gRewriteUserAgentBuildVersion)),
        @"cfBundleVersionDirectHeaderRewriteCount":@0,
        @"appStoreVersionIDHeaderRewriteCount":@0,
        @"appStoreVersionIDQueryOrBodyRewriteCount":@0
    };
}

#if defined(RUIN_CLIENT_VERSION_ADVERTISEMENT_HOST_CHECK)
#import <assert.h>
#import <stdio.h>

int main(void)
{
    @autoreleasepool {
        NSURL *lineURL = [NSURL URLWithString:@"https://legy-jp.line-apps.com/S4"];
        NSDictionary *requestHeaders = @{
            @"X-Line-Application":@"IOS\t26.16.0\tiPhone OS\t18.2.1",
            @"X-Line-Application-Version":@"26.16.0",
            @"User-Agent":@"iphoneapp.line/26.16.0 (iPhone; U; CPU iPhone OS 18.2.1 like Mac OS X; BuildVersion: 2026.1006.1718; CFNetwork/3860.500.111.2.2 Darwin/24.2.0)",
            @"CFBundleVersion":@"2026.1006.1718",
            @"AppStoreVersionID":kLegacyAppStoreVersionID,
            @"Content-Type":@"application/x-thrift"
        };
        BOOL malformed = NO;
        BOOL buildVersionRewritten = NO;
        NSDictionary *overrides = RUINClientVersionHeaderOverrides(requestHeaders, @{}, lineURL, YES, YES,
            &malformed, &buildVersionRewritten);
        assert(!malformed);
        assert([overrides[@"X-Line-Application"] isEqual:@"IOS\t15.16.1\tiPhone OS\t18.2.1"]);
        assert([overrides[@"X-Line-Application-Version"] isEqual:kLegacyClientVersion]);
        assert([overrides[@"User-Agent"] isEqual:@"iphoneapp.line/15.16.1 (iPhone; U; CPU iPhone OS 18.2.1 like Mac OS X; BuildVersion: 2025.926.1805; CFNetwork/3860.500.111.2.2 Darwin/24.2.0)"]);
        assert(buildVersionRewritten);
        assert(overrides[@"CFBundleVersion"] == nil && overrides[@"AppStoreVersionID"] == nil);
        assert(overrides[@"Content-Type"] == nil);
        assert([requestHeaders[@"X-Line-Application"] isEqual:@"IOS\t26.16.0\tiPhone OS\t18.2.1"]);

        NSDictionary *lineUAHeaders = @{@"User-Agent":@"Line/26.16.0;BuildVersion: 2026.1006.1718; CFNetwork/3860"};
        overrides = RUINClientVersionHeaderOverrides(lineUAHeaders, @{}, lineURL, YES, YES,
            &malformed, &buildVersionRewritten);
        assert([overrides[@"User-Agent"] isEqual:@"Line/15.16.1;BuildVersion: 2025.926.1805; CFNetwork/3860"]);
        assert(buildVersionRewritten);

        NSDictionary *iPadHeaders = @{@"X-Line-Application":@"IOSIPAD\t26.16.0\tiPhone OS\t18.2.1"};
        overrides = RUINClientVersionHeaderOverrides(iPadHeaders, @{}, lineURL, YES, YES,
            &malformed, &buildVersionRewritten);
        assert([overrides[@"X-Line-Application"] isEqual:@"IOSIPAD\t15.16.1\tiPhone OS\t18.2.1"]);

        NSDictionary *sessionDefaults = @{@"x-line-application":@"IOS\t26.16.0\tiPhone OS\t18.2.1"};
        NSDictionary *perRequest = @{@"Content-Type":@"application/x-thrift"};
        overrides = RUINClientVersionHeaderOverrides(perRequest, sessionDefaults, lineURL, YES, YES,
            &malformed, &buildVersionRewritten);
        assert([overrides[@"x-line-application"] isEqual:@"IOS\t15.16.1\tiPhone OS\t18.2.1"]);
        assert(perRequest[@"X-Line-Application"] == nil);
        assert([sessionDefaults[@"x-line-application"] isEqual:@"IOS\t26.16.0\tiPhone OS\t18.2.1"]);

        NSURL *outsideURL = [NSURL URLWithString:@"https://legy-jp.line-apps.com.evil.test/S4"];
        assert(RUINClientVersionHeaderOverrides(requestHeaders, @{}, outsideURL, YES, YES,
            &malformed, &buildVersionRewritten).count == 0);
        assert(RUINClientVersionHeaderOverrides(requestHeaders, @{}, lineURL, YES, NO,
            &malformed, &buildVersionRewritten).count == 0);
        assert(RUINClientVersionHeaderOverrides(requestHeaders, @{}, lineURL, NO, YES,
            &malformed, &buildVersionRewritten).count == 0);

        NSDictionary *unknownUAHeaders = @{
            @"X-Line-Application":@"IOSIPAD\t26.16.0\tiPhone OS\t18.2.1",
            @"User-Agent":@"unknown-client/26.16.0 CFNetwork/3860.500.111.2.2"
        };
        overrides = RUINClientVersionHeaderOverrides(unknownUAHeaders, @{}, lineURL, YES, YES,
            &malformed, &buildVersionRewritten);
        assert(!malformed && [overrides[@"X-Line-Application"] isEqual:@"IOSIPAD\t15.16.1\tiPhone OS\t18.2.1"]);
        assert(overrides[@"User-Agent"] == nil);

        NSDictionary *unparseableUAHeaders = @{
            @"X-Line-Application":@"IOSIPAD\t26.16.0\tiPhone OS\t18.2.1",
            @"User-Agent":@"iphoneapp.line/26.16 (iPad; CPU iPhone OS 18.2.1; CFNetwork/3860)"
        };
        overrides = RUINClientVersionHeaderOverrides(unparseableUAHeaders, @{}, lineURL, YES, YES,
            &malformed, &buildVersionRewritten);
        assert(!malformed && [overrides[@"X-Line-Application"] isEqual:@"IOSIPAD\t15.16.1\tiPhone OS\t18.2.1"]);
        assert(overrides[@"User-Agent"] == nil);

        NSDictionary *malformedUAHeaders = @{
            @"X-Line-Application":@"IOSIPAD\t26.16.0\tiPhone OS\t18.2.1",
            @"User-Agent":@"iphoneapp.line/26.16.0\r\nX-Evil: 1"
        };
        overrides = RUINClientVersionHeaderOverrides(malformedUAHeaders, @{}, lineURL, YES, YES,
            &malformed, &buildVersionRewritten);
        assert(malformed && overrides.count == 0);

        NSDictionary *badHeaders = @{
            @"X-Line-Application":@"IOS\tbad\tiPhone OS\t18.2.1",
            @"X-Line-Application-Version":@"26.16.0"
        };
        overrides = RUINClientVersionHeaderOverrides(badHeaders, @{}, lineURL, YES, YES,
            &malformed, &buildVersionRewritten);
        assert(malformed && overrides.count == 0);

        atomic_store(&gObservedUAStyle, RUINObservedUAStyleUnseen);
        atomic_store(&gUAContainsCurrentVersion, false);
        atomic_store(&gUAContainsCurrentBuild, false);
        RUINObserveUserAgent(@{@"User-Agent":@"Line/26.16.0;BuildVersion: 2026.1006.1718"}, @{});
        NSDictionary *diagnostics = RUINClientVersionAdvertisementDiagnostics();
        assert([diagnostics[@"observedUAStyle"] isEqual:@"line"]);
        assert([diagnostics[@"containsCurrentVersion"] boolValue]);
        assert([diagnostics[@"containsCurrentBuild"] boolValue]);

        atomic_store(&gObservedUAStyle, RUINObservedUAStyleUnseen);
        atomic_store(&gUAContainsCurrentVersion, false);
        atomic_store(&gUAContainsCurrentBuild, false);
        RUINObserveUserAgent(@{}, @{});
        diagnostics = RUINClientVersionAdvertisementDiagnostics();
        assert([diagnostics[@"observedUAStyle"] isEqual:@"missing"]);
        RUINObserveUserAgent(@{@"User-Agent":@"unknown-client/26.16.0"}, @{});
        diagnostics = RUINClientVersionAdvertisementDiagnostics();
        assert([diagnostics[@"observedUAStyle"] isEqual:@"other"]);
        assert(![diagnostics[@"containsCurrentVersion"] boolValue]);
        assert(![diagnostics[@"containsCurrentBuild"] boolValue]);

        puts("PASS client-version rewriting preserves platform and OS fields; scopes hosts and fails closed");
    }
    return 0;
}
#endif
