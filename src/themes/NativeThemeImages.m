#import "NativeThemeImages.h"
#if !defined(RUIN_NATIVE_THEME_IMAGES_HOST_CHECK)
#import "NativeReadRangeSync.h"
#endif

#import <objc/runtime.h>
#import <stdatomic.h>
#import <errno.h>
#import <dirent.h>
#import <fcntl.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <os/lock.h>

enum { kRequest, kRequestCompletion, kURL, kURLCompletion,
       kDownloadRequest, kDownloadRequestCompletion, kDownloadURL, kDownloadURLCompletion, kHookCount };
enum { kPending, kInstalled, kTargetMismatch, kClassMismatch, kMissingSelector,
       kABIMismatch, kPeerMismatch, kInstallFailed };
enum { kCacheNotRequested, kCacheTargetMismatch, kCacheScheduled, kCacheRunning,
       kCacheComplete, kCacheUnavailable };
enum { kMaxNamespaces = 64, kMaxDirectoryEntries = 1024, kMaxNamespaceName = 67 };

typedef void (^RUINNativeTaskCompletion)(NSData *, NSURLResponse *, NSError *);
typedef NSURLSessionDataTask *(*RUINRequestTaskIMP)(id, SEL, NSURLRequest *);
typedef NSURLSessionDataTask *(*RUINRequestCompletionTaskIMP)(id, SEL, NSURLRequest *, RUINNativeTaskCompletion);
typedef NSURLSessionDataTask *(*RUINURLTaskIMP)(id, SEL, NSURL *);
typedef NSURLSessionDataTask *(*RUINURLCompletionTaskIMP)(id, SEL, NSURL *, RUINNativeTaskCompletion);

static const char *gSelectorNames[kHookCount] = {
    "dataTaskWithRequest:", "dataTaskWithRequest:completionHandler:",
    "dataTaskWithURL:", "dataTaskWithURL:completionHandler:",
    "downloadTaskWithRequest:", "downloadTaskWithRequest:completionHandler:",
    "downloadTaskWithURL:", "downloadTaskWithURL:completionHandler:"
};

static SEL RUINSelectorAtIndex(NSUInteger index)
{
    switch (index) {
        case kRequest: return @selector(dataTaskWithRequest:);
        case kRequestCompletion: return @selector(dataTaskWithRequest:completionHandler:);
        case kURL: return @selector(dataTaskWithURL:);
        case kURLCompletion: return @selector(dataTaskWithURL:completionHandler:);
        case kDownloadRequest: return @selector(downloadTaskWithRequest:);
        case kDownloadRequestCompletion: return @selector(downloadTaskWithRequest:completionHandler:);
        case kDownloadURL: return @selector(downloadTaskWithURL:);
        case kDownloadURLCompletion: return @selector(downloadTaskWithURL:completionHandler:);
        default: return NULL;
    }
}

static _Atomic(IMP) gOriginals[kHookCount];
static atomic_int gSelectorStatus[kHookCount] = {
    ATOMIC_VAR_INIT(kPending), ATOMIC_VAR_INIT(kPending),
    ATOMIC_VAR_INIT(kPending), ATOMIC_VAR_INIT(kPending)
};
static atomic_int gInstallStatus = ATOMIC_VAR_INIT(kPending);
static atomic_int gCacheStatus = ATOMIC_VAR_INIT(kCacheNotRequested);
static atomic_uint_fast64_t gOriginalCalls[kHookCount];
static atomic_uint_fast64_t gURLFixes;
static atomic_uint_fast64_t gCacheNamespacesScanned;
static atomic_uint_fast64_t gCacheCandidatesChecked;
static atomic_uint_fast64_t gCacheEntriesRemoved;
static dispatch_once_t gInstallOnce;
static dispatch_once_t gCacheRepairOnce;
static os_unfair_lock gCandidateLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray *gImageCandidates;
enum { kDelegateRequest, kDelegateURL, kDelegateRequestCompletion, kDelegateURLCompletion,
       kDelegateDownloadRequestCompletion, kDelegateDownloadURLCompletion, kDelegateCount };
static const char *gDelegateNames[kDelegateCount] = {
    "_dataTaskWithRequest:delegate:", "_dataTaskWithURL:delegate:",
    "_dataTaskWithRequest:delegate:completionHandler:", "_dataTaskWithURL:delegate:completionHandler:",
    "_downloadTaskWithRequest:delegate:completionHandler:", "_downloadTaskWithURL:delegate:completionHandler:"
};
static _Atomic(IMP) gDelegateOriginals[kDelegateCount];
static atomic_int gDelegateStatus[kDelegateCount];
static atomic_uint_fast64_t gDelegateCalls[kDelegateCount];

static void RUINObserveThemeImageURL(NSURLComponents *parts)
{
    const char *enabled = getenv("RUIN_ENABLE_RUNTIME_INSPECTOR");
    if (!enabled || strcmp(enabled, "1") != 0 ||
        ![parts.host.lowercaseString isEqual:@"shop.line-scdn.net"] ||
        ![parts.path hasPrefix:@"/themeshop/"] || parts.path.length > 2048) return;
    NSDictionary *row = @{@"scheme":parts.scheme ?: @"", @"host":parts.host ?: @"",
        @"path":parts.path ?: @"", @"hasQuery":@(parts.query != nil),
        @"hasFragment":@(parts.fragment != nil), @"port":parts.port ?: @0};
    os_unfair_lock_lock(&gCandidateLock);
    gImageCandidates = gImageCandidates ?: [NSMutableArray array];
    if (gImageCandidates.count < 32 && ![gImageCandidates containsObject:row]) [gImageCandidates addObject:row];
    os_unfair_lock_unlock(&gCandidateLock);
}

static const char *RUINHookStatusName(int status)
{
    switch (status) {
        case kInstalled: return "installed";
        case kTargetMismatch: return "target-mismatch";
        case kClassMismatch: return "class-mismatch";
        case kMissingSelector: return "selector-missing";
        case kABIMismatch: return "abi-mismatch";
        case kPeerMismatch: return "not-installed-peer-mismatch";
        case kInstallFailed: return "install-failed";
        default: return "pending";
    }
}

static const char *RUINCacheStatusName(int status)
{
    switch (status) {
        case kCacheTargetMismatch: return "target-mismatch";
        case kCacheScheduled: return "scheduled";
        case kCacheRunning: return "running";
        case kCacheComplete: return "complete";
        case kCacheUnavailable: return "directory-unavailable";
        default: return "not-requested";
    }
}

static BOOL RUINNativeThemeImagesTargetMatches(void)
{
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    BOOL bundleMatches = [NSBundle.mainBundle.bundleIdentifier isEqual:@"jp.naver.line"] ||
        [info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"];
    return bundleMatches && [info[@"CFBundleShortVersionString"] isEqual:@"26.16.0"] &&
        [info[@"CFBundleVersion"] isEqual:@"2026.1006.1718"];
}

static NSRegularExpression *RUINNativeThemeImagePathRegex(void)
{
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *pattern = @"\\A/themeshop/v1/products/[a-f0-9]{2}/[a-f0-9]{2}/[a-f0-9]{2}/"
            "[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}/[0-9]+/ANDROID/"
            "[a-z0-9_@.-]+@2x\\.png\\z";
        regex = [NSRegularExpression regularExpressionWithPattern:pattern
            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return regex;
}

NSURL *RUINNormalizeNativeThemeImageURL(NSURL *URL)
{
    if (!URL) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    RUINObserveThemeImageURL(components);
    if (!components || !components.scheme || !components.host ||
        [components.scheme caseInsensitiveCompare:@"https"] != NSOrderedSame ||
        [components.host caseInsensitiveCompare:@"shop.line-scdn.net"] != NSOrderedSame ||
        components.user != nil || components.password != nil || components.query != nil ||
        components.fragment != nil || (components.port && ![components.port isEqual:@443])) return URL;

    NSString *path = components.path;
    NSRegularExpression *regex = RUINNativeThemeImagePathRegex();
    if (!path || !regex || [regex numberOfMatchesInString:path options:0
        range:NSMakeRange(0, path.length)] != 1) return URL;

    NSRange suffix = NSMakeRange(path.length - 7, 3);
    NSString *normalizedPath = [path stringByReplacingCharactersInRange:suffix withString:@""];
    NSURLComponents *normalized = [components copy];
    normalized.scheme = @"https";
    normalized.host = @"shop.line-scdn.net";
    if ([normalized.port isEqual:@443]) normalized.port = nil;
    normalized.path = normalizedPath;
    NSURL *result = normalized.URL;
    if (!result) return URL;
    atomic_fetch_add(&gURLFixes, 1);
    return result;
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

static BOOL RUINMethodHasABI(Method method, BOOL hasCompletion)
{
    if (!method) return NO;
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding];
    NSUInteger expectedArguments = hasCompletion ? 4 : 3;
    if (!signature || signature.numberOfArguments != expectedArguments ||
        !RUINTypeIsObject(signature.methodReturnType, NO) ||
        !RUINTypeIsObject([signature getArgumentTypeAtIndex:0], NO) ||
        !RUINTypeIsSelector([signature getArgumentTypeAtIndex:1]) ||
        !RUINTypeIsObject([signature getArgumentTypeAtIndex:2], NO)) return NO;
    return !hasCompletion || RUINTypeIsObject([signature getArgumentTypeAtIndex:3], YES);
}

static BOOL RUINClassIsNSURLSession(Class cls)
{
    if (!cls || class_isMetaClass(cls)) return NO;
    for (Class candidate = cls; candidate; candidate = class_getSuperclass(candidate))
        if (candidate == NSURLSession.class) return YES;
    return NO;
}

static BOOL RUINClassOwnsSelector(Class cls, SEL selector)
{
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) { found = YES; break; }
    }
    free(methods);
    return found;
}

static NSURLRequest *RUINRequestWithNormalizedThemeURL(NSURLRequest *request)
{
    if (!request) return request;
    NSString *method = request.HTTPMethod;
    if (method && ![method isEqualToString:@"GET"] && ![method isEqualToString:@"HEAD"])
        return request;
    NSURL *normalizedURL = RUINNormalizeNativeThemeImageURL(request.URL);
    if (!normalizedURL || normalizedURL == request.URL) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    if (!copy) return request;
    copy.URL = normalizedURL;
    return copy;
}

static NSURLSessionDataTask *RUINDataTaskWithRequest(id self, SEL selector, NSURLRequest *request)
{
#if !defined(RUIN_NATIVE_THEME_IMAGES_HOST_CHECK)
    RUINObserveNativeReadRangeRequest(self, request);
#endif
    atomic_fetch_add(&gOriginalCalls[kRequest], 1);
    IMP original = atomic_load(&gOriginals[kRequest]);
    return ((RUINRequestTaskIMP)original)(self, selector, RUINRequestWithNormalizedThemeURL(request));
}

static NSURLSessionDataTask *RUINDataTaskWithRequestCompletion(id self, SEL selector,
    NSURLRequest *request, RUINNativeTaskCompletion completion)
{
#if !defined(RUIN_NATIVE_THEME_IMAGES_HOST_CHECK)
    RUINObserveNativeReadRangeRequest(self, request);
#endif
    atomic_fetch_add(&gOriginalCalls[kRequestCompletion], 1);
    IMP original = atomic_load(&gOriginals[kRequestCompletion]);
    return ((RUINRequestCompletionTaskIMP)original)(self, selector,
        RUINRequestWithNormalizedThemeURL(request), completion);
}

static NSURLSessionDataTask *RUINDataTaskWithURL(id self, SEL selector, NSURL *URL)
{
    atomic_fetch_add(&gOriginalCalls[kURL], 1);
    IMP original = atomic_load(&gOriginals[kURL]);
    NSURL *normalized = RUINNormalizeNativeThemeImageURL(URL);
    return ((RUINURLTaskIMP)original)(self, selector, normalized);
}

static NSURLSessionDataTask *RUINDataTaskWithURLCompletion(id self, SEL selector,
    NSURL *URL, RUINNativeTaskCompletion completion)
{
    atomic_fetch_add(&gOriginalCalls[kURLCompletion], 1);
    IMP original = atomic_load(&gOriginals[kURLCompletion]);
    NSURL *normalized = RUINNormalizeNativeThemeImageURL(URL);
    return ((RUINURLCompletionTaskIMP)original)(self, selector, normalized, completion);
}

// Completion blocks are forwarded without invocation or replacement. Both
// task families return an Objective-C task object with the same method ABI.
static id RUINDownloadTaskWithRequest(id self, SEL selector, NSURLRequest *request)
{
    atomic_fetch_add(&gOriginalCalls[kDownloadRequest], 1);
    IMP original = atomic_load(&gOriginals[kDownloadRequest]);
    return ((id (*)(id, SEL, id))original)(self, selector, RUINRequestWithNormalizedThemeURL(request));
}

static id RUINDownloadTaskWithRequestCompletion(id self, SEL selector, NSURLRequest *request, id completion)
{
    atomic_fetch_add(&gOriginalCalls[kDownloadRequestCompletion], 1);
    IMP original = atomic_load(&gOriginals[kDownloadRequestCompletion]);
    return ((id (*)(id, SEL, id, id))original)(self, selector, RUINRequestWithNormalizedThemeURL(request), completion);
}

static id RUINDownloadTaskWithURL(id self, SEL selector, NSURL *URL)
{
    atomic_fetch_add(&gOriginalCalls[kDownloadURL], 1);
    IMP original = atomic_load(&gOriginals[kDownloadURL]);
    return ((id (*)(id, SEL, id))original)(self, selector, RUINNormalizeNativeThemeImageURL(URL));
}

static id RUINDownloadTaskWithURLCompletion(id self, SEL selector, NSURL *URL, id completion)
{
    atomic_fetch_add(&gOriginalCalls[kDownloadURLCompletion], 1);
    IMP original = atomic_load(&gOriginals[kDownloadURLCompletion]);
    return ((id (*)(id, SEL, id, id))original)(self, selector, RUINNormalizeNativeThemeImageURL(URL), completion);
}

static IMP RUINHookForIndex(NSUInteger index)
{
    switch (index) {
        case kRequest: return (IMP)RUINDataTaskWithRequest;
        case kRequestCompletion: return (IMP)RUINDataTaskWithRequestCompletion;
        case kURL: return (IMP)RUINDataTaskWithURL;
        case kURLCompletion: return (IMP)RUINDataTaskWithURLCompletion;
        case kDownloadRequest: return (IMP)RUINDownloadTaskWithRequest;
        case kDownloadRequestCompletion: return (IMP)RUINDownloadTaskWithRequestCompletion;
        case kDownloadURL: return (IMP)RUINDownloadTaskWithURL;
        case kDownloadURLCompletion: return (IMP)RUINDownloadTaskWithURLCompletion;
        default: return NULL;
    }
}

static NSUInteger RUINDelegateIndex(SEL selector)
{
    for (NSUInteger i = 0; i < kDelegateCount; i++)
        if (selector == sel_registerName(gDelegateNames[i])) return i;
    return kDelegateCount;
}

static id RUINDelegateTask(id self, SEL selector, id argument, id delegate)
{
    NSUInteger index = RUINDelegateIndex(selector);
    if (index >= kDelegateCount) return nil;
    atomic_fetch_add(&gDelegateCalls[index], 1);
    IMP original = atomic_load(&gDelegateOriginals[index]);
    id normalized = index == kDelegateRequest ? RUINRequestWithNormalizedThemeURL(argument)
        : RUINNormalizeNativeThemeImageURL(argument);
    return ((id (*)(id, SEL, id, id))original)(self, selector, normalized, delegate);
}

static id RUINDelegateTaskCompletion(id self, SEL selector, id argument, id delegate, id completion)
{
    NSUInteger index = RUINDelegateIndex(selector);
    if (index >= kDelegateCount) return nil;
    atomic_fetch_add(&gDelegateCalls[index], 1);
    IMP original = atomic_load(&gDelegateOriginals[index]);
    BOOL request = index == kDelegateRequestCompletion || index == kDelegateDownloadRequestCompletion;
    id normalized = request ? RUINRequestWithNormalizedThemeURL(argument) : RUINNormalizeNativeThemeImageURL(argument);
    return ((id (*)(id, SEL, id, id, id))original)(self, selector, normalized, delegate, completion);
}

static void RUINInstallDelegateTaskHooks(Class cls)
{
    // Foundation's Swift async adapters use these delegate-aware methods.
    // Each optional selector is independently checked against its actual ABI.
    for (NSUInteger i = 0; i < kDelegateCount; i++) {
        SEL selector = sel_registerName(gDelegateNames[i]);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) { atomic_store(&gDelegateStatus[i], kMissingSelector); continue; }
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        BOOL completion = i >= kDelegateRequestCompletion;
        BOOL valid = signature.numberOfArguments == (completion ? 5 : 4) &&
            RUINTypeIsObject(signature.methodReturnType, NO) &&
            RUINTypeIsObject([signature getArgumentTypeAtIndex:0], NO) &&
            RUINTypeIsSelector([signature getArgumentTypeAtIndex:1]) &&
            RUINTypeIsObject([signature getArgumentTypeAtIndex:2], NO) &&
            RUINTypeIsObject([signature getArgumentTypeAtIndex:3], NO) &&
            (!completion || RUINTypeIsObject([signature getArgumentTypeAtIndex:4], YES));
        if (!valid) { atomic_store(&gDelegateStatus[i], kABIMismatch); continue; }
        IMP original = method_getImplementation(method);
        if (!original) { atomic_store(&gDelegateStatus[i], kInstallFailed); continue; }
        atomic_store(&gDelegateOriginals[i], original);
        IMP replacement = completion ? (IMP)RUINDelegateTaskCompletion : (IMP)RUINDelegateTask;
        if (RUINClassOwnsSelector(cls, selector)) {
            IMP replaced = class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
            if (replaced != original) {
                if (replaced) class_replaceMethod(cls, selector, replaced, method_getTypeEncoding(method));
                atomic_store(&gDelegateStatus[i], kInstallFailed); continue;
            }
        } else if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
            atomic_store(&gDelegateStatus[i], kInstallFailed); continue;
        }
        atomic_store(&gDelegateStatus[i], kInstalled);
    }
}

static void RUINSetHookStatuses(int status)
{
    for (NSUInteger i = 0; i < kHookCount; i++) atomic_store(&gSelectorStatus[i], status);
}

static BOOL RUINInstallHooksOnClass(Class cls, BOOL requireNSURLSessionSubclass)
{
    if (!cls || class_isMetaClass(cls) || (requireNSURLSessionSubclass && !RUINClassIsNSURLSession(cls))) {
        RUINSetHookStatuses(kClassMismatch);
        atomic_store(&gInstallStatus, kClassMismatch);
        return NO;
    }

    Method methods[kHookCount] = {0};
    const BOOL hasCompletion[kHookCount] = {NO, YES, NO, YES, NO, YES, NO, YES};
    BOOL anyInvalid = NO;
    BOOL anyABIMismatch = NO;
    for (NSUInteger i = 0; i < kHookCount; i++) {
        SEL selector = RUINSelectorAtIndex(i);
        methods[i] = class_getInstanceMethod(cls, selector);
        if (!methods[i]) {
            atomic_store(&gSelectorStatus[i], kMissingSelector);
            anyInvalid = YES;
        } else if (!RUINMethodHasABI(methods[i], hasCompletion[i])) {
            atomic_store(&gSelectorStatus[i], kABIMismatch);
            anyInvalid = YES;
            anyABIMismatch = YES;
        } else {
            atomic_store(&gSelectorStatus[i], kPending);
        }
    }
    if (anyInvalid) {
        for (NSUInteger i = 0; i < kHookCount; i++)
            if (atomic_load(&gSelectorStatus[i]) == kPending)
                atomic_store(&gSelectorStatus[i], kPeerMismatch);
        atomic_store(&gInstallStatus, anyABIMismatch ? kABIMismatch : kMissingSelector);
        return NO;
    }

    IMP previous[kHookCount] = {0};
    const char *encodings[kHookCount] = {0};
    BOOL installed[kHookCount] = {NO, NO, NO, NO};
    for (NSUInteger i = 0; i < kHookCount; i++) {
        previous[i] = method_getImplementation(methods[i]);
        encodings[i] = method_getTypeEncoding(methods[i]);
        if (!previous[i] || !encodings[i]) break;
        atomic_store(&gOriginals[i], previous[i]);
        BOOL changed = NO;
        SEL selector = RUINSelectorAtIndex(i);
        if (RUINClassOwnsSelector(cls, selector)) {
            IMP replaced = class_replaceMethod(cls, selector, RUINHookForIndex(i), encodings[i]);
            changed = replaced == previous[i];
            if (!changed && replaced)
                class_replaceMethod(cls, selector, replaced, encodings[i]);
        } else {
            changed = class_addMethod(cls, selector, RUINHookForIndex(i), encodings[i]);
        }
        // A call may already have entered our replacement during a failed
        // peer swap. Keep its captured original valid after rollback.
        if (!changed) break;
        installed[i] = YES;
        atomic_store(&gSelectorStatus[i], kInstalled);
    }
    BOOL allInstalled = YES;
    for (NSUInteger i = 0; i < kHookCount; i++) if (!installed[i]) allInstalled = NO;
    if (!allInstalled) {
        for (NSUInteger i = kHookCount; i > 0; i--) {
            NSUInteger index = i - 1;
            if (installed[index]) class_replaceMethod(cls, RUINSelectorAtIndex(index), previous[index], encodings[index]);
            atomic_store(&gSelectorStatus[index], kInstallFailed);
        }
        atomic_store(&gInstallStatus, kInstallFailed);
        return NO;
    }
    atomic_store(&gInstallStatus, kInstalled);
    return YES;
}

static BOOL RUINImageCacheFilename(const char *name)
{
    if (!name || strlen(name) != 47 || strcmp(name + 40, "@2x.png") != 0) return NO;
    for (NSUInteger i = 0; i < 40; i++) {
        char c = name[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
            return NO;
    }
    return YES;
}

static BOOL RUINCacheNamespaceName(const char *name)
{
    if (!name || strncmp(name, "S_", 2) != 0) return NO;
    size_t length = strlen(name);
    if (length < 3 || length > kMaxNamespaceName) return NO;
    for (size_t i = 2; i < length; i++) {
        char c = name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-')) return NO;
    }
    return YES;
}

static int RUINOpenDirectoryAt(int parentFD, const char *name)
{
    int fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISDIR(info.st_mode)) { close(fd); return -1; }
    return fd;
}

static BOOL RUINIsKnown404File(int imageFD, const char *name)
{
    int fd = openat(imageFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return NO;
    struct stat opened;
    BOOL known404 = NO;
    const unsigned char body[] = "404 Not Found";
    unsigned char bytes[sizeof(body)];
    if (fstat(fd, &opened) == 0 && S_ISREG(opened.st_mode) && opened.st_size == 13 &&
        opened.st_size <= 64 && pread(fd, bytes, sizeof(bytes), 0) == 13 &&
        memcmp(bytes, body, 13) == 0) {
        struct stat current;
        if (fstat(fd, &current) == 0 && S_ISREG(current.st_mode) && current.st_size == 13 &&
            current.st_dev == opened.st_dev && current.st_ino == opened.st_ino &&
            fstatat(imageFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0 &&
            S_ISREG(current.st_mode) && current.st_size == 13 &&
            current.st_dev == opened.st_dev && current.st_ino == opened.st_ino)
            known404 = YES;
    }
    close(fd);
    return known404;
}

static NSUInteger RUINRepairCacheAtURL(NSURL *cachesURL)
{
    atomic_store(&gCacheStatus, kCacheRunning);
    if (!cachesURL.isFileURL || !cachesURL.fileSystemRepresentation) {
        atomic_store(&gCacheStatus, kCacheUnavailable);
        return 0;
    }
    int cachesFD = open(cachesURL.fileSystemRepresentation,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (cachesFD < 0) {
        atomic_store(&gCacheStatus, kCacheUnavailable);
        return 0;
    }
    int privateStoreFD = RUINOpenDirectoryAt(cachesFD, "PrivateStore");
    close(cachesFD);
    if (privateStoreFD < 0) {
        atomic_store(&gCacheStatus, kCacheComplete);
        return 0;
    }

    int namespaceScanFD = dup(privateStoreFD);
    DIR *namespaceDirectory = namespaceScanFD >= 0 ? fdopendir(namespaceScanFD) : NULL;
    if (!namespaceDirectory) {
        if (namespaceScanFD >= 0) close(namespaceScanFD);
        close(privateStoreFD);
        atomic_store(&gCacheStatus, kCacheUnavailable);
        return 0;
    }

    NSUInteger removed = 0;
    NSUInteger namespaces = 0;
    NSUInteger namespaceEntries = 0;
    struct dirent *namespaceEntry;
    while (namespaceEntries++ < kMaxDirectoryEntries &&
           (namespaceEntry = readdir(namespaceDirectory)) != NULL) {
        if (!RUINCacheNamespaceName(namespaceEntry->d_name)) continue;
        if (namespaces >= kMaxNamespaces) break;
        int namespaceFD = RUINOpenDirectoryAt(privateStoreFD, namespaceEntry->d_name);
        if (namespaceFD < 0) continue;
        int themeDataFD = RUINOpenDirectoryAt(namespaceFD, "Theme Shop Data");
        close(namespaceFD);
        if (themeDataFD < 0) continue;
        int imageFD = RUINOpenDirectoryAt(themeDataFD, "image");
        close(themeDataFD);
        if (imageFD < 0) continue;
        namespaces++;
        atomic_fetch_add(&gCacheNamespacesScanned, 1);

        int imageScanFD = dup(imageFD);
        DIR *imageDirectory = imageScanFD >= 0 ? fdopendir(imageScanFD) : NULL;
        if (!imageDirectory) {
            if (imageScanFD >= 0) close(imageScanFD);
            close(imageFD);
            continue;
        }
        NSUInteger entries = 0;
        struct dirent *imageEntry;
        while (entries++ < kMaxDirectoryEntries &&
               (imageEntry = readdir(imageDirectory)) != NULL) {
            if (!RUINImageCacheFilename(imageEntry->d_name)) continue;
            atomic_fetch_add(&gCacheCandidatesChecked, 1);
            if (!RUINIsKnown404File(imageFD, imageEntry->d_name)) continue;
            if (unlinkat(imageFD, imageEntry->d_name, 0) == 0) {
                removed++;
                atomic_fetch_add(&gCacheEntriesRemoved, 1);
            }
        }
        closedir(imageDirectory);
        close(imageFD);
    }
    closedir(namespaceDirectory);
    close(privateStoreFD);
    atomic_store(&gCacheStatus, kCacheComplete);
    return removed;
}

void RUINRepairNativeThemeImageCache(void)
{
    if (!RUINNativeThemeImagesTargetMatches()) {
        atomic_store(&gCacheStatus, kCacheTargetMismatch);
        return;
    }
    dispatch_once(&gCacheRepairOnce, ^{
        NSURL *cachesURL = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
            inDomains:NSUserDomainMask].firstObject;
        atomic_store(&gCacheStatus, kCacheScheduled);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            RUINRepairCacheAtURL(cachesURL);
        });
    });
}

void RUINInstallNativeThemeImages(void)
{
    dispatch_once(&gInstallOnce, ^{
        if (!RUINNativeThemeImagesTargetMatches()) {
            RUINSetHookStatuses(kTargetMismatch);
            atomic_store(&gInstallStatus, kTargetMismatch);
            return;
        }
        NSURLSession *session = NSURLSession.sharedSession;
        Class actualClass = session ? object_getClass(session) : Nil;
        if (!actualClass || !RUINClassIsNSURLSession(actualClass)) {
            RUINSetHookStatuses(kClassMismatch);
            atomic_store(&gInstallStatus, kClassMismatch);
            return;
        }
        if (RUINInstallHooksOnClass(actualClass, YES)) RUINInstallDelegateTaskHooks(actualClass);
    });
    RUINRepairNativeThemeImageCache();
}

NSDictionary<NSString *, id> *RUINNativeThemeImagesDiagnostics(void)
{
    os_unfair_lock_lock(&gCandidateLock);
    NSArray *candidates = [gImageCandidates copy] ?: @[];
    os_unfair_lock_unlock(&gCandidateLock);
    NSMutableDictionary *selectors = [NSMutableDictionary dictionaryWithCapacity:kHookCount];
    NSMutableDictionary *originalCalls = [NSMutableDictionary dictionaryWithCapacity:kHookCount];
    NSMutableDictionary *delegateSelectors = [NSMutableDictionary dictionary], *delegateCalls = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < kDelegateCount; i++) {
        delegateSelectors[@(gDelegateNames[i])] = @(RUINHookStatusName(atomic_load(&gDelegateStatus[i])));
        delegateCalls[@(gDelegateNames[i])] = @(atomic_load(&gDelegateCalls[i]));
    }
    for (NSUInteger i = 0; i < kHookCount; i++) {
        NSString *name = @(gSelectorNames[i]);
        selectors[name] = @(RUINHookStatusName(atomic_load(&gSelectorStatus[i])));
        originalCalls[name] = @(atomic_load(&gOriginalCalls[i]));
    }
    return @{@"hookStatus": @(RUINHookStatusName(atomic_load(&gInstallStatus))),
        @"selectors": selectors, @"originalCalls": originalCalls,
        @"delegateSelectors":delegateSelectors, @"delegateCalls":delegateCalls,
        @"urlFixes": @(atomic_load(&gURLFixes)),
        @"cacheRepairStatus": @(RUINCacheStatusName(atomic_load(&gCacheStatus))),
        @"cacheNamespacesScanned": @(atomic_load(&gCacheNamespacesScanned)),
        @"cacheCandidatesChecked": @(atomic_load(&gCacheCandidatesChecked)),
        @"cacheEntriesRemoved": @(atomic_load(&gCacheEntriesRemoved)),
        @"publicImageCandidates": candidates};
}

#if defined(RUIN_NATIVE_THEME_IMAGES_HOST_CHECK)
BOOL RUINNativeThemeImagesClassIsSupported(Class cls)
{
    return RUINClassIsNSURLSession(cls);
}

BOOL RUINNativeThemeImagesInstallHooksForTesting(Class cls, BOOL requireNSURLSessionSubclass)
{
    BOOL installed = RUINInstallHooksOnClass(cls, requireNSURLSessionSubclass);
    if (installed) RUINInstallDelegateTaskHooks(cls);
    return installed;
}

NSUInteger RUINNativeThemeImageRepairCacheAtURL(NSURL *cachesURL)
{
    return RUINRepairCacheAtURL(cachesURL);
}
#endif
