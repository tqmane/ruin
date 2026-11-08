%config(generator=internal)

#import "TargetMetadata.h"
#import "ThemePrivateAPI.h"
#import "NativeThemeImages.h"
#import "ThemeAccountNamespace.h"
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
enum { kMaxNamespaces = 64, kMaxDirectoryEntries = 1024 };

static const char *gSelectorNames[kHookCount] = {
    "dataTaskWithRequest:", "dataTaskWithRequest:completionHandler:",
    "dataTaskWithURL:", "dataTaskWithURL:completionHandler:",
    "downloadTaskWithRequest:", "downloadTaskWithRequest:completionHandler:",
    "downloadTaskWithURL:", "downloadTaskWithURL:completionHandler:"
};

static Class gInstalledTaskClass;
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
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
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

// Logos installs on the concrete NSURLSession class after validating all
// required methods. Inherited methods get a local override; superclass IMPs
// stay untouched and %orig preserves Foundation's task/completion behavior.
%group RUINNativeThemeTasks
%hook RUINThemeURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
{
#if !defined(RUIN_NATIVE_THEME_IMAGES_HOST_CHECK)
    RUINObserveNativeReadRangeRequest(self, request);
#endif
    atomic_fetch_add(&gOriginalCalls[kRequest], 1);
    return %orig(RUINRequestWithNormalizedThemeURL(request));
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(RUINNativeTaskCompletion)completion
{
#if !defined(RUIN_NATIVE_THEME_IMAGES_HOST_CHECK)
    RUINObserveNativeReadRangeRequest(self, request);
#endif
    atomic_fetch_add(&gOriginalCalls[kRequestCompletion], 1);
    return %orig(RUINRequestWithNormalizedThemeURL(request), completion);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)URL
{
    atomic_fetch_add(&gOriginalCalls[kURL], 1);
    return %orig(RUINNormalizeNativeThemeImageURL(URL));
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)URL completionHandler:(RUINNativeTaskCompletion)completion
{
    atomic_fetch_add(&gOriginalCalls[kURLCompletion], 1);
    return %orig(RUINNormalizeNativeThemeImageURL(URL), completion);
}

- (id)downloadTaskWithRequest:(NSURLRequest *)request
{
    atomic_fetch_add(&gOriginalCalls[kDownloadRequest], 1);
    return %orig(RUINRequestWithNormalizedThemeURL(request));
}

- (id)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(RUINNativeDownloadTaskCompletion)completion
{
    atomic_fetch_add(&gOriginalCalls[kDownloadRequestCompletion], 1);
    return %orig(RUINRequestWithNormalizedThemeURL(request), completion);
}

- (id)downloadTaskWithURL:(NSURL *)URL
{
    atomic_fetch_add(&gOriginalCalls[kDownloadURL], 1);
    return %orig(RUINNormalizeNativeThemeImageURL(URL));
}

- (id)downloadTaskWithURL:(NSURL *)URL completionHandler:(RUINNativeDownloadTaskCompletion)completion
{
    atomic_fetch_add(&gOriginalCalls[kDownloadURLCompletion], 1);
    return %orig(RUINNormalizeNativeThemeImageURL(URL), completion);
}

%end
%end

%group RUINNativeThemeDelegateRequest
%hook RUINThemeURLSession
- (id)_dataTaskWithRequest:(NSURLRequest *)request delegate:(id)delegate
{
    atomic_fetch_add(&gDelegateCalls[kDelegateRequest], 1);
    return %orig(RUINRequestWithNormalizedThemeURL(request), delegate);
}
%end
%end

%group RUINNativeThemeDelegateURL
%hook RUINThemeURLSession
- (id)_dataTaskWithURL:(NSURL *)URL delegate:(id)delegate
{
    atomic_fetch_add(&gDelegateCalls[kDelegateURL], 1);
    return %orig(RUINNormalizeNativeThemeImageURL(URL), delegate);
}
%end
%end

%group RUINNativeThemeDelegateRequestCompletion
%hook RUINThemeURLSession
- (id)_dataTaskWithRequest:(NSURLRequest *)request delegate:(id)delegate completionHandler:(RUINNativeTaskCompletion)completion
{
    atomic_fetch_add(&gDelegateCalls[kDelegateRequestCompletion], 1);
    return %orig(RUINRequestWithNormalizedThemeURL(request), delegate, completion);
}
%end
%end

%group RUINNativeThemeDelegateURLCompletion
%hook RUINThemeURLSession
- (id)_dataTaskWithURL:(NSURL *)URL delegate:(id)delegate completionHandler:(RUINNativeTaskCompletion)completion
{
    atomic_fetch_add(&gDelegateCalls[kDelegateURLCompletion], 1);
    return %orig(RUINNormalizeNativeThemeImageURL(URL), delegate, completion);
}
%end
%end

%group RUINNativeThemeDelegateDownloadRequestCompletion
%hook RUINThemeURLSession
- (id)_downloadTaskWithRequest:(NSURLRequest *)request delegate:(id)delegate completionHandler:(RUINNativeDownloadTaskCompletion)completion
{
    atomic_fetch_add(&gDelegateCalls[kDelegateDownloadRequestCompletion], 1);
    return %orig(RUINRequestWithNormalizedThemeURL(request), delegate, completion);
}
%end
%end

%group RUINNativeThemeDelegateDownloadURLCompletion
%hook RUINThemeURLSession
- (id)_downloadTaskWithURL:(NSURL *)URL delegate:(id)delegate completionHandler:(RUINNativeDownloadTaskCompletion)completion
{
    atomic_fetch_add(&gDelegateCalls[kDelegateDownloadURLCompletion], 1);
    return %orig(RUINNormalizeNativeThemeImageURL(URL), delegate, completion);
}
%end
%end

static void RUINInstallDelegateTaskHooks(Class cls)
{
    // Foundation's Swift async adapters use these optional selectors. A
    // missing or changed one does not suppress independently verified hooks.
    for (NSUInteger i = 0; i < kDelegateCount; i++) {
        if (atomic_load(&gDelegateStatus[i]) == kInstalled) continue;
        SEL selector = sel_registerName(gDelegateNames[i]);
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) {
            atomic_store(&gDelegateStatus[i], kMissingSelector);
            continue;
        }
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        BOOL hasCompletion = i >= kDelegateRequestCompletion;
        BOOL valid = signature.numberOfArguments == (hasCompletion ? 5 : 4) &&
            RUINTypeIsObject(signature.methodReturnType, NO) &&
            RUINTypeIsObject([signature getArgumentTypeAtIndex:0], NO) &&
            RUINTypeIsSelector([signature getArgumentTypeAtIndex:1]) &&
            RUINTypeIsObject([signature getArgumentTypeAtIndex:2], NO) &&
            RUINTypeIsObject([signature getArgumentTypeAtIndex:3], NO) &&
            (!hasCompletion || RUINTypeIsObject([signature getArgumentTypeAtIndex:4], YES));
        if (!valid) {
            atomic_store(&gDelegateStatus[i], kABIMismatch);
            continue;
        }
        if (!method_getImplementation(method)) {
            atomic_store(&gDelegateStatus[i], kInstallFailed);
            continue;
        }
        switch (i) {
            case kDelegateRequest:
                %init(RUINNativeThemeDelegateRequest, RUINThemeURLSession=cls);
                break;
            case kDelegateURL:
                %init(RUINNativeThemeDelegateURL, RUINThemeURLSession=cls);
                break;
            case kDelegateRequestCompletion:
                %init(RUINNativeThemeDelegateRequestCompletion, RUINThemeURLSession=cls);
                break;
            case kDelegateURLCompletion:
                %init(RUINNativeThemeDelegateURLCompletion, RUINThemeURLSession=cls);
                break;
            case kDelegateDownloadRequestCompletion:
                %init(RUINNativeThemeDelegateDownloadRequestCompletion, RUINThemeURLSession=cls);
                break;
            case kDelegateDownloadURLCompletion:
                %init(RUINNativeThemeDelegateDownloadURLCompletion, RUINThemeURLSession=cls);
                break;
            default: continue;
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
    const BOOL hasCompletion[kHookCount] = {NO, YES, NO, YES, NO, YES, NO, YES};
    BOOL anyInvalid = NO;
    BOOL anyABIMismatch = NO;
    for (NSUInteger i = 0; i < kHookCount; i++) {
        Method method = class_getInstanceMethod(cls, sel_registerName(gSelectorNames[i]));
        if (!method) {
            atomic_store(&gSelectorStatus[i], kMissingSelector);
            anyInvalid = YES;
        } else if (!RUINMethodHasABI(method, hasCompletion[i])) {
            atomic_store(&gSelectorStatus[i], kABIMismatch);
            anyInvalid = YES;
            anyABIMismatch = YES;
        } else if (!method_getImplementation(method)) {
            atomic_store(&gSelectorStatus[i], kInstallFailed);
            anyInvalid = YES;
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
    if (gInstalledTaskClass && gInstalledTaskClass != cls) {
        RUINSetHookStatuses(kClassMismatch);
        atomic_store(&gInstallStatus, kClassMismatch);
        return NO;
    }
    if (!gInstalledTaskClass) {
        %init(RUINNativeThemeTasks, RUINThemeURLSession=cls);
        gInstalledTaskClass = cls;
    }
    RUINSetHookStatuses(kInstalled);
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
        if (!RUINThemeAccountNamespaceIsValidCString(namespaceEntry->d_name)) continue;
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
