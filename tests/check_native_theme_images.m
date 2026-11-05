#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "NativeThemeImages.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef void (^FixtureCompletion)(NSData *, NSURLResponse *, NSError *);
enum { kFixtureSelectorCount = 4 };

@interface RUINSessionBase : NSObject
@property(nonatomic) NSUInteger requestCalls;
@property(nonatomic) NSUInteger requestCompletionCalls;
@property(nonatomic) NSUInteger urlCalls;
@property(nonatomic) NSUInteger urlCompletionCalls;
@property(nonatomic) NSUInteger downloadRequestCalls;
@property(nonatomic) NSUInteger downloadRequestCompletionCalls;
@property(nonatomic) NSUInteger downloadURLCalls;
@property(nonatomic) NSUInteger downloadURLCompletionCalls;
@property(nonatomic, strong) NSURLRequest *lastRequest;
@property(nonatomic, strong) NSURL *lastURL;
@property(nonatomic, strong) id task;
@property(nonatomic) BOOL receivedExpectedCompletion;
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request;
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(FixtureCompletion)completion;
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)URL;
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)URL completionHandler:(FixtureCompletion)completion;
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request;
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(FixtureCompletion)completion;
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)URL;
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)URL completionHandler:(FixtureCompletion)completion;
@end

static FixtureCompletion gExpectedCompletion;
static const char *kDelegateSelectors[] = {
    "_dataTaskWithRequest:delegate:", "_dataTaskWithURL:delegate:",
    "_dataTaskWithRequest:delegate:completionHandler:", "_dataTaskWithURL:delegate:completionHandler:",
    "_downloadTaskWithRequest:delegate:completionHandler:", "_downloadTaskWithURL:delegate:completionHandler:"
};
static NSUInteger gDelegateCounts[6];
static id gLastDelegateArgument, gLastDelegate, gLastCompletion;
static id FixtureDelegateCall(id self, SEL selector, id argument, id delegate)
{
    for (NSUInteger i = 0; i < 6; i++)
        if (selector == sel_registerName(kDelegateSelectors[i])) gDelegateCounts[i]++;
    gLastDelegateArgument = argument; gLastDelegate = delegate;
    return [self valueForKey:@"task"];
}
static id FixtureDelegateCompletionCall(id self, SEL selector, id argument, id delegate, id completion)
{
    gLastCompletion = completion;
    return FixtureDelegateCall(self, selector, argument, delegate);
}

@implementation RUINSessionBase
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
{
    self.requestCalls++;
    self.lastRequest = request;
    return (id)self.task;
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(FixtureCompletion)completion
{
    self.requestCompletionCalls++;
    self.lastRequest = request;
    self.receivedExpectedCompletion = completion == gExpectedCompletion;
    return (id)self.task;
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)URL
{
    self.urlCalls++;
    self.lastURL = URL;
    return (id)self.task;
}
- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)URL completionHandler:(FixtureCompletion)completion
{
    self.urlCompletionCalls++;
    self.lastURL = URL;
    self.receivedExpectedCompletion = completion == gExpectedCompletion;
    return (id)self.task;
}
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
{
    self.downloadRequestCalls++;
    self.lastRequest = request;
    return (id)self.task;
}
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(FixtureCompletion)completion
{
    self.downloadRequestCompletionCalls++;
    self.lastRequest = request;
    self.receivedExpectedCompletion = completion == gExpectedCompletion;
    return (id)self.task;
}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)URL
{
    self.downloadURLCalls++;
    self.lastURL = URL;
    return (id)self.task;
}
- (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)URL completionHandler:(FixtureCompletion)completion
{
    self.downloadURLCompletionCalls++;
    self.lastURL = URL;
    self.receivedExpectedCompletion = completion == gExpectedCompletion;
    return (id)self.task;
}
@end

@interface RUINSessionFixture : RUINSessionBase
@end
@implementation RUINSessionFixture
@end

static NSString *const kBrokenImage =
    @"https://shop.line-scdn.net/themeshop/v1/products/9d/dd/1e/"
    "9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/icon_136x202@2x.png";
static NSString *const kWorkingImage =
    @"https://shop.line-scdn.net/themeshop/v1/products/9d/dd/1e/"
    "9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/icon_136x202.png";

static void BadURLMethod(id self, SEL selector, NSURL *URL)
{
    (void)self; (void)selector; (void)URL;
}

static void ExpectUnchanged(NSString *value)
{
    NSURL *URL = [NSURL URLWithString:value];
    assert(URL != nil);
    assert(RUINNormalizeNativeThemeImageURL(URL) == URL);
}

static BOOL ClassOwnsSelector(Class cls, SEL selector)
{
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++)
        if (method_getName(methods[i]) == selector) { found = YES; break; }
    free(methods);
    return found;
}

static void CheckURLNormalization(void)
{
    NSURL *broken = [NSURL URLWithString:kBrokenImage];
    assert([RUINNormalizeNativeThemeImageURL(broken).absoluteString isEqual:kWorkingImage]);
    NSURL *escaped = [NSURL URLWithString:[kBrokenImage stringByReplacingOccurrencesOfString:@"@2x" withString:@"%402x"]];
    assert([RUINNormalizeNativeThemeImageURL(escaped).absoluteString isEqual:kWorkingImage]);

    NSURL *uppercase = [NSURL URLWithString:
        @"https://SHOP.LINE-SCDN.NET:443/themeshop/v1/products/9D/DD/1E/"
        "9DDD1E78-FF28-4A4E-A5CE-F021B9CA9002/1/ANDROID/icon@2X.PNG"];
    assert([RUINNormalizeNativeThemeImageURL(uppercase).absoluteString isEqual:
        @"https://shop.line-scdn.net/themeshop/v1/products/9D/DD/1E/"
        "9DDD1E78-FF28-4A4E-A5CE-F021B9CA9002/1/ANDROID/icon.PNG"]);
    NSURL *doubleSuffix = [NSURL URLWithString:
        @"https://shop.line-scdn.net/themeshop/v1/products/9d/dd/1e/"
        "9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/icon@2x@2x.png"];
    assert([[RUINNormalizeNativeThemeImageURL(doubleSuffix).path lastPathComponent]
        isEqualToString:@"icon@2x.png"]);

    ExpectUnchanged(@"https://shop.line-scdn.net/themeshop/v1/products/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/IOS/icon@2x.png");
    ExpectUnchanged(@"https://example.com/themeshop/v1/products/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/icon@2x.png");
    ExpectUnchanged(@"https://shop.line-scdn.net.attacker.example/themeshop/v1/products/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/icon@2x.png");
    ExpectUnchanged(@"https://user@shop.line-scdn.net/themeshop/v1/products/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/icon@2x.png");
    ExpectUnchanged(@"http://shop.line-scdn.net/themeshop/v1/products/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/icon@2x.png");
    ExpectUnchanged(@"https://shop.line-scdn.net:444/themeshop/v1/products/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/icon@2x.png");
    ExpectUnchanged(@"https://shop.line-scdn.net/themeshop/v1/products/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/icon@2x.png?signature=keep");
    ExpectUnchanged(@"https://shop.line-scdn.net/themeshop/v1/products/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/icon@2x.png#keep");
    ExpectUnchanged(@"https://shop.line-scdn.net/themeshop/v1/products/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/theme.zip");
    ExpectUnchanged(@"https://shop.line-scdn.net/themeshop/v1/products/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/1/ANDROID/icon.png");
    ExpectUnchanged(@"https://shop.line-scdn.net/unrelated/icon@2x.png");
}

static void CheckSessionForwarding(void)
{
    for (NSUInteger i = 0; i < 6; i++) {
        IMP implementation = i < 2 ? (IMP)FixtureDelegateCall : (IMP)FixtureDelegateCompletionCall;
        assert(class_addMethod(RUINSessionBase.class, sel_registerName(kDelegateSelectors[i]), implementation,
            i < 2 ? "@32@0:8@16@24" : "@40@0:8@16@24@?32"));
    }
    assert(RUINNativeThemeImagesClassIsSupported(NSURLSession.class));
    assert(RUINNativeThemeImagesClassIsSupported(object_getClass(NSURLSession.sharedSession)));
    assert(!RUINNativeThemeImagesClassIsSupported(NSObject.class));
    assert(!RUINNativeThemeImagesClassIsSupported(RUINSessionFixture.class));
    const char *names[kFixtureSelectorCount] = {"dataTaskWithRequest:",
        "dataTaskWithRequest:completionHandler:", "dataTaskWithURL:",
        "dataTaskWithURL:completionHandler:"};
    assert(!RUINNativeThemeImagesInstallHooksForTesting(RUINSessionFixture.class, YES));
    for (NSUInteger i = 0; i < kFixtureSelectorCount; i++)
        assert(!ClassOwnsSelector(RUINSessionFixture.class, sel_registerName(names[i])));

    NSDictionary *before = RUINNativeThemeImagesDiagnostics();
    uint64_t fixesBefore = [before[@"urlFixes"] unsignedLongLongValue];
    assert(RUINNativeThemeImagesInstallHooksForTesting(RUINSessionFixture.class, NO));
    for (NSUInteger i = 0; i < kFixtureSelectorCount; i++)
        assert(ClassOwnsSelector(RUINSessionFixture.class, sel_registerName(names[i])));

    RUINSessionFixture *session = [RUINSessionFixture new];
    session.task = [NSObject new];
    NSURL *brokenURL = [NSURL URLWithString:kBrokenImage];
    NSMutableURLRequest *GET = [NSMutableURLRequest requestWithURL:brokenURL];
    GET.HTTPMethod = @"GET";
    [GET setValue:@"preserved" forHTTPHeaderField:@"X-RUIN-Fixture"];
    GET.HTTPBody = [@"body-preserved" dataUsingEncoding:NSUTF8StringEncoding];
    assert((id)[session dataTaskWithRequest:GET] == session.task);
    assert(session.requestCalls == 1 && session.lastRequest != GET);
    assert([session.lastRequest.URL.absoluteString isEqual:kWorkingImage]);
    assert([[session.lastRequest valueForHTTPHeaderField:@"X-RUIN-Fixture"] isEqualToString:@"preserved"]);
    assert([session.lastRequest.HTTPBody isEqual:GET.HTTPBody]);

    NSMutableURLRequest *HEAD = [GET mutableCopy];
    HEAD.HTTPMethod = @"HEAD";
    [session dataTaskWithRequest:HEAD];
    assert(session.requestCalls == 2 && [session.lastRequest.HTTPMethod isEqual:@"HEAD"]);
    assert([session.lastRequest.URL.absoluteString isEqual:kWorkingImage]);

    NSMutableURLRequest *POST = [GET mutableCopy];
    POST.HTTPMethod = @"POST";
    [session dataTaskWithRequest:POST];
    assert(session.requestCalls == 3 && session.lastRequest == POST);
    assert([session.lastRequest.URL.absoluteString isEqual:kBrokenImage]);

    NSMutableURLRequest *query = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[kBrokenImage stringByAppendingString:@"?sig=keep"]]];
    [session dataTaskWithRequest:query];
    assert(session.requestCalls == 4 && session.lastRequest == query);

    gExpectedCompletion = ^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)data; (void)response; (void)error;
    };
    [session dataTaskWithRequest:GET completionHandler:gExpectedCompletion];
    assert(session.requestCompletionCalls == 1 && session.receivedExpectedCompletion);
    assert([session.lastRequest.URL.absoluteString isEqual:kWorkingImage]);
    assert([[session.lastRequest valueForHTTPHeaderField:@"X-RUIN-Fixture"] isEqualToString:@"preserved"]);
    assert([session.lastRequest.HTTPBody isEqual:GET.HTTPBody]);

    [session dataTaskWithURL:brokenURL];
    assert(session.urlCalls == 1 && [session.lastURL.absoluteString isEqual:kWorkingImage]);
    [session dataTaskWithURL:brokenURL completionHandler:gExpectedCompletion];
    assert(session.urlCompletionCalls == 1 && session.receivedExpectedCompletion);
    assert([session.lastURL.absoluteString isEqual:kWorkingImage]);

    NSDictionary *after = RUINNativeThemeImagesDiagnostics();
    assert([after[@"originalCalls"][@"dataTaskWithRequest:"] unsignedLongLongValue] == 4);
    assert([after[@"originalCalls"][@"dataTaskWithRequest:completionHandler:"] unsignedLongLongValue] == 1);
    assert([after[@"originalCalls"][@"dataTaskWithURL:"] unsignedLongLongValue] == 1);
    assert([after[@"originalCalls"][@"dataTaskWithURL:completionHandler:"] unsignedLongLongValue] == 1);
    assert([after[@"urlFixes"] unsignedLongLongValue] - fixesBefore == 5);
    assert((id)[session downloadTaskWithRequest:GET] == session.task);
    assert(session.downloadRequestCalls == 1 && session.lastRequest != GET);
    assert([session.lastRequest.URL.absoluteString isEqual:kWorkingImage]);
    assert([session.lastRequest.HTTPBody isEqual:GET.HTTPBody]);
    [session downloadTaskWithRequest:GET completionHandler:gExpectedCompletion];
    assert(session.downloadRequestCompletionCalls == 1 && session.receivedExpectedCompletion);
    assert([session.lastRequest.URL.absoluteString isEqual:kWorkingImage]);
    [session downloadTaskWithURL:brokenURL];
    assert(session.downloadURLCalls == 1 && [session.lastURL.absoluteString isEqual:kWorkingImage]);
    [session downloadTaskWithURL:brokenURL completionHandler:gExpectedCompletion];
    assert(session.downloadURLCompletionCalls == 1 && session.receivedExpectedCompletion);
    assert([session.lastURL.absoluteString isEqual:kWorkingImage]);
    [session downloadTaskWithRequest:POST];
    assert(session.downloadRequestCalls == 2 && session.lastRequest == POST);
    NSDictionary *downloads = RUINNativeThemeImagesDiagnostics()[@"originalCalls"];
    assert([downloads[@"downloadTaskWithRequest:"] unsignedLongLongValue] == 2);
    assert([downloads[@"downloadTaskWithRequest:completionHandler:"] unsignedLongLongValue] == 1);
    assert([downloads[@"downloadTaskWithURL:"] unsignedLongLongValue] == 1);
    assert([downloads[@"downloadTaskWithURL:completionHandler:"] unsignedLongLongValue] == 1);
    id delegate = NSObject.new;
    for (NSUInteger i = 0; i < 6; i++) {
        BOOL request = i == 0 || i == 2 || i == 4;
        id argument = request ? (id)GET : brokenURL;
        id task = i < 2
            ? ((id (*)(id, SEL, id, id))objc_msgSend)(session, sel_registerName(kDelegateSelectors[i]), argument, delegate)
            : ((id (*)(id, SEL, id, id, id))objc_msgSend)(session, sel_registerName(kDelegateSelectors[i]), argument, delegate, gExpectedCompletion);
        assert(task == session.task && gDelegateCounts[i] == 1 && gLastDelegate == delegate);
        NSURL *result = request ? [gLastDelegateArgument URL] : gLastDelegateArgument;
        assert([result.absoluteString isEqual:kWorkingImage]);
        if (request) assert([[gLastDelegateArgument valueForHTTPHeaderField:@"X-RUIN-Fixture"] isEqual:@"preserved"]);
        if (i >= 2) assert(gLastCompletion == gExpectedCompletion);
    }
    gExpectedCompletion = nil;
}

static void CheckABIMismatchIsNotPatched(void)
{
    Class bad = objc_allocateClassPair(NSObject.class, "RUINBadThemeImageSession", 0);
    assert(bad != Nil);
    SEL selectors[] = {@selector(dataTaskWithRequest:), @selector(dataTaskWithRequest:completionHandler:),
        @selector(dataTaskWithURL:), @selector(dataTaskWithURL:completionHandler:)};
    for (NSUInteger i = 0; i < 4; i++) {
        Method method = class_getInstanceMethod(RUINSessionBase.class, selectors[i]);
        assert(method != NULL);
        IMP implementation = method_getImplementation(method);
        const char *encoding = method_getTypeEncoding(method);
        if (i == 2) {
            implementation = (IMP)BadURLMethod;
            encoding = "v@:@";
        }
        assert(class_addMethod(bad, selectors[i], implementation, encoding));
    }
    objc_registerClassPair(bad);
    IMP before[kFixtureSelectorCount];
    for (NSUInteger i = 0; i < 4; i++) before[i] = method_getImplementation(class_getInstanceMethod(bad, selectors[i]));
    assert(!RUINNativeThemeImagesInstallHooksForTesting(bad, NO));
    assert([RUINNativeThemeImagesDiagnostics()[@"selectors"][@"dataTaskWithURL:"]
        isEqual:@"abi-mismatch"]);
    for (NSUInteger i = 0; i < 4; i++)
        assert(method_getImplementation(class_getInstanceMethod(bad, selectors[i])) == before[i]);
    for (NSUInteger i = 0; i < kFixtureSelectorCount; i++)
        assert(!ClassOwnsSelector(NSObject.class, selectors[i]));
}

static NSURL *MakeDirectory(NSURL *parent, NSString *name)
{
    NSURL *URL = [parent URLByAppendingPathComponent:name isDirectory:YES];
    NSError *error = nil;
    assert([NSFileManager.defaultManager createDirectoryAtURL:URL
        withIntermediateDirectories:YES attributes:nil error:&error]);
    return URL;
}

static void Write(NSURL *URL, NSData *data)
{
    NSError *error = nil;
    assert([data writeToURL:URL options:NSDataWritingAtomic error:&error]);
}

static void CheckCacheRepair(void)
{
    NSString *rootName = [NSString stringWithFormat:@"ruin-native-image-check-%@", NSUUID.UUID.UUIDString];
    NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:rootName]
        isDirectory:YES];
    NSURL *privateStore = MakeDirectory(root, @"PrivateStore");
    NSURL *image = MakeDirectory(MakeDirectory(MakeDirectory(privateStore, @"S_fixture"),
        @"Theme Shop Data"), @"image");
    NSData *notFound = [@"404 Not Found" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *png = [NSData dataWithBytes:(const unsigned char[]){0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}
        length:8];
    NSURL *bad = [image URLByAppendingPathComponent:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa@2x.png"];
    NSURL *valid = [image URLByAppendingPathComponent:@"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb@2x.png"];
    NSURL *otherBody = [image URLByAppendingPathComponent:@"cccccccccccccccccccccccccccccccccccccccc@2x.png"];
    NSURL *unrelated = [image URLByAppendingPathComponent:@"unrelated@2x.png"];
    NSURL *shortBody = [image URLByAppendingPathComponent:@"dddddddddddddddddddddddddddddddddddddddd@2x.png"];
    NSURL *target = [root URLByAppendingPathComponent:@"symlink-target"];
    NSURL *link = [image URLByAppendingPathComponent:@"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee@2x.png"];
    Write(bad, notFound);
    Write(valid, png);
    Write(otherBody, [@"not a 404 body" dataUsingEncoding:NSUTF8StringEncoding]);
    Write(unrelated, notFound);
    Write(shortBody, [@"404 NotFound" dataUsingEncoding:NSUTF8StringEncoding]);
    Write(target, notFound);
    assert(symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) == 0);

    NSURL *wrongNamespace = MakeDirectory(privateStore, @"Other");
    NSURL *wrongPath = MakeDirectory(MakeDirectory(wrongNamespace, @"Theme Shop Data"), @"image");
    NSURL *wrongNamespaceFile = [wrongPath URLByAppendingPathComponent:
        @"ffffffffffffffffffffffffffffffffffffffff@2x.png"];
    Write(wrongNamespaceFile, notFound);

    NSDictionary *before = RUINNativeThemeImagesDiagnostics();
    NSUInteger removed = RUINNativeThemeImageRepairCacheAtURL(root);
    assert(removed == 1);
    assert(![NSFileManager.defaultManager fileExistsAtPath:bad.path]);
    assert([NSFileManager.defaultManager fileExistsAtPath:valid.path]);
    assert([NSFileManager.defaultManager fileExistsAtPath:otherBody.path]);
    assert([NSFileManager.defaultManager fileExistsAtPath:unrelated.path]);
    assert([NSFileManager.defaultManager fileExistsAtPath:shortBody.path]);
    assert([NSFileManager.defaultManager fileExistsAtPath:wrongNamespaceFile.path]);
    struct stat linkInfo;
    assert(lstat(link.fileSystemRepresentation, &linkInfo) == 0 && S_ISLNK(linkInfo.st_mode));
    assert([NSFileManager.defaultManager fileExistsAtPath:target.path]);
    assert([RUINNativeThemeImagesDiagnostics()[@"cacheEntriesRemoved"] unsignedLongLongValue] ==
        [before[@"cacheEntriesRemoved"] unsignedLongLongValue] + 1);
    NSError *error = nil;
    assert([NSFileManager.defaultManager removeItemAtURL:root error:&error]);
}

int main(void)
{
    @autoreleasepool {
        CheckURLNormalization();
        CheckSessionForwarding();
        CheckABIMismatchIsNotPatched();
        CheckCacheRepair();
        puts("check_native_theme_images: PASS");
    }
    return 0;
}
