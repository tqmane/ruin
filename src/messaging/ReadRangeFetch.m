#import "ReadRangeFetch.h"
#import "ReadRangeCodec.h"
#import "NativeReadRangeSync.h"
#import "MessageHistory.h"
#import "RuntimeInspector.h"
#import <CoreData/CoreData.h>
#import <stdatomic.h>

static NSString *const domain = @"RUINReadRangeFetch";
static atomic_uint_fast32_t sequence;
static atomic_uint_fast64_t requests, successes, failures;
static atomic_int lastHTTPStatus, lastError;
static atomic_int lastCodecError;
static atomic_uint_fast64_t lastResponseBytes;
static const NSUInteger maximumResponse = 8 * 1024 * 1024;

static NSError *Failure(NSInteger code) {
    atomic_store(&lastError, (int)code);
    return [NSError errorWithDomain:domain code:code userInfo:nil];
}

@interface RUINReadRangeConnection : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property(nonatomic, copy) NSDictionary *key;
@property(nonatomic, weak) NSManagedObject *chat;
@property(nonatomic, copy) NSString *account;
@property(nonatomic, strong) NSURL *endpoint;
@property(nonatomic) int32_t sequenceID;
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, copy) void (^completion)(NSError *);
@property(nonatomic) BOOL finished;
- (void)finish:(NSError *)error;
@end

@implementation RUINReadRangeConnection
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session; (void)task; (void)response;
    BOOL sameOrigin = [request.URL.scheme.lowercaseString isEqual:@"https"] &&
        [request.URL.host.lowercaseString isEqual:self.endpoint.host.lowercaseString] &&
        [(request.URL.port ?: @443) isEqual:(self.endpoint.port ?: @443)] && [request.URL.path isEqual:@"/S4"];
    if (!sameOrigin) self.error = Failure(5);
    completionHandler(sameOrigin ? request : nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session; (void)task;
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    atomic_store(&lastHTTPStatus, (int)status);
    if (status != 200 || response.expectedContentLength > (long long)maximumResponse) {
        self.error = Failure(status == 200 ? 6 : 7);
        completionHandler(NSURLSessionResponseCancel);
    } else completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;
    if (data.length > maximumResponse - self.data.length) { self.error = Failure(6); [task cancel]; return; }
    [self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)task;
    [session finishTasksAndInvalidate];
    if (self.error || error) { [self finish:self.error ?: error]; return; }
    NSManagedObject *chat = self.chat;
    NSString *account = [[[NSUserDefaults alloc] initWithSuiteName:@"group.com.linecorp.line"] stringForKey:@"mid"];
    if (![account isEqual:self.account] || !RUINHistoryValidateReadChatKey(self.key, chat)) { [self finish:Failure(2)]; return; }
    NSError *decodeError = nil;
    atomic_store(&lastResponseBytes, self.data.length);
    NSDictionary *readers = RUINReadRangeDecodeResponse(self.data, self.key[@"chat"], self.sequenceID, &decodeError);
    atomic_store(&lastCodecError, (int)decodeError.code);
    if (!readers) { [self finish:decodeError ?: Failure(8)]; return; }
    RUINHistoryRecordServerReadRanges(self.key, readers, ^(BOOL success) {
        [self finish:success ? nil : Failure(9)];
    });
}
- (void)finish:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    if (!error) atomic_store(&lastError, 0);
    atomic_fetch_add(error ? &failures : &successes, 1);
    void (^completion)(NSError *) = self.completion;
    self.completion = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        RUINRequestRuntimeSnapshot();
        if (completion) completion(error);
    });
}
@end

BOOL RUINCanFetchReadRanges(NSDictionary *messageKey, id nativeChat) {
    return [messageKey isKindOfClass:NSDictionary.class] && [messageKey[@"kind"] isEqual:@"talk"] &&
        RUINReadRangeEncodeRequest(messageKey[@"chat"], 0, NULL) != nil &&
        RUINHistoryValidateReadChatKey(messageKey, nativeChat) && RUINCopyNativeReadRangeHTTPContext() != nil;
}

void RUINFetchReadRanges(NSDictionary *messageKey, id nativeChat, void (^completion)(NSError *)) {
    void (^fail)(NSInteger) = ^(NSInteger code) {
        atomic_fetch_add(&failures,1);
        NSError *error = Failure(code);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    };
    if (!RUINHistoryValidateReadChatKey(messageKey, nativeChat)) { fail(2); return; }
    NSDictionary *context = RUINCopyNativeReadRangeHTTPContext();
    if (!context) { fail(3); return; }
    NSError *error = nil;
    int32_t seq = (int32_t)((atomic_fetch_add(&sequence,1) + 1) & INT32_MAX);
    NSData *body = RUINReadRangeEncodeRequest(messageKey[@"chat"], seq, &error);
    if (!body) {
        atomic_fetch_add(&failures,1);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(error ?: Failure(4)); });
        return;
    }
    RUINReadRangeConnection *connection = [RUINReadRangeConnection new];
    connection.key = [messageKey copy]; connection.chat = nativeChat;
    connection.account = context[@"account"]; connection.endpoint = context[@"URL"];
    connection.sequenceID = seq; connection.data = [NSMutableData data]; connection.completion = completion;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPCookieStorage = nil; configuration.HTTPShouldSetCookies = NO;
    configuration.URLCredentialStorage = nil; configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20;
    NSOperationQueue *delegateQueue = [NSOperationQueue new]; delegateQueue.maxConcurrentOperationCount = 1;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:connection delegateQueue:delegateQueue];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:connection.endpoint];
    request.HTTPMethod = @"POST"; request.HTTPBody = body;
    request.allHTTPHeaderFields = context[@"headers"];
    [request setValue:@"application/x-thrift" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/x-thrift" forHTTPHeaderField:@"Accept"];
    [request setValue:@"POST" forHTTPHeaderField:@"X-LHM"];
    atomic_fetch_add(&requests,1);
    [[session dataTaskWithRequest:request] resume];
}

NSDictionary *RUINReadRangeFetchDiagnostics(void) {
    return @{@"requests":@(atomic_load(&requests)), @"successes":@(atomic_load(&successes)),
        @"failures":@(atomic_load(&failures)), @"lastHTTPStatus":@(atomic_load(&lastHTTPStatus)),
        @"lastErrorCode":@(atomic_load(&lastError)), @"lastCodecErrorCode":@(atomic_load(&lastCodecError)),
        @"lastResponseBytes":@(atomic_load(&lastResponseBytes)), @"codec":RUINReadRangeCodecDiagnostics(), @"credentialsPersisted":@NO};
}
