#import "NativeReadRangeSync.h"
#import "MessageHistory.h"
#import <objc/runtime.h>
#include <string.h>
#import <os/lock.h>

static NSString *const queueKey = @"lineMessageReadRangeSyncChatIDs";
static NSString *probeStatus = @"not_requested";
static NSUInteger queueBefore, queueAfter;
static NSInteger encodedType = -1;
static NSDictionary *requestMetadata;
static NSDictionary *httpContext;
static os_unfair_lock requestLock = OS_UNFAIR_LOCK_INIT;
static BOOL TrackReadersEnabled(void) {
#if defined(RUIN_NATIVE_READ_RANGE_SYNC_HOST_CHECK)
    return NO;
#else
    return [NSUserDefaults.standardUserDefaults boolForKey:RUINTrackReadUsersKey];
#endif
}

void RUINObserveNativeReadRangeRequest(NSURLSession *session, NSURLRequest *request) {
    BOOL inspect = [NSProcessInfo.processInfo.environment[@"RUIN_ENABLE_RUNTIME_INSPECTOR"] isEqual:@"1"];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    BOOL capture = [info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"] &&
        [info[@"CFBundleShortVersionString"] isEqual:@"26.16.0"] &&
        [info[@"CFBundleVersion"] isEqual:@"2026.1006.1718"] &&
        TrackReadersEnabled();
    if (!inspect && !capture) return;
    if (![session isKindOfClass:NSURLSession.class] || ![request isKindOfClass:NSURLRequest.class]) return;
    NSString *host = request.URL.host.lowercaseString;
    NSSet *paths = [NSSet setWithArray:@[@"/S3",@"/S4",@"/S5",@"/P4",@"/P5",@"/F4",@"/C4",
        @"/SYNC3",@"/SYNC4",@"/api/v3p/rs",@"/api/v4p/rs",@"/api/v3/TalkService.do",@"/api/v4/TalkService.do"]];
    if (![request.URL.scheme.lowercaseString isEqual:@"https"] || request.URL.user.length || request.URL.password.length ||
        !([host hasSuffix:@".line.naver.jp"] || [host hasSuffix:@".line.me"] || [host hasSuffix:@".line-apps.com"]) ||
        ![paths containsObject:request.URL.path]) return;
    NSMutableSet *names = [NSMutableSet set];
    NSMutableDictionary *forward = [NSMutableDictionary dictionary];
    NSSet *allowed = [NSSet setWithArray:@[@"x-line-access",@"x-line-application",@"user-agent",@"x-lal",@"x-lpv",@"x-las"]];
    for (NSDictionary *headers in @[session.configuration.HTTPAdditionalHeaders ?: @{}, request.allHTTPHeaderFields ?: @{}])
        for (id name in headers) if ([name isKindOfClass:NSString.class] && [name length] <= 128 && names.count < 64) {
            NSString *key = [name lowercaseString];
            [names addObject:key];
            id value = headers[name];
            if ([allowed containsObject:key] && [value isKindOfClass:NSString.class] && [value length] <= 65536)
                forward[key] = value;
        }
    NSData *body = request.HTTPBody;
    NSString *protocol = @"none_or_stream";
    BOOL rangeMethod = NO;
    if (body.length) {
        uint8_t first = ((const uint8_t *)body.bytes)[0];
        protocol = first == 0x82 ? @"compact" : (first == 0x80 ? @"binary" : @"encrypted_or_other");
        if (body.length <= 1024 * 1024) rangeMethod = [body rangeOfData:[@"getMessageReadRange" dataUsingEncoding:NSUTF8StringEncoding]
            options:0 range:NSMakeRange(0,body.length)].location != NSNotFound;
    }
    NSDictionary *metadata = @{@"host":host, @"path":request.URL.path,
        @"headerNames":[names.allObjects sortedArrayUsingSelector:@selector(compare:)],
        @"hasAccessHeader":@([names containsObject:@"x-line-access"] || [names containsObject:@"authorization"]),
        @"hasEncryptedAccessHeader":@([names containsObject:@"x-line-encrypted-access"]),
        @"bodyProtocol":protocol, @"isReadRangeMethod":@(rangeMethod), @"valuesRecorded":@NO};
    if (inspect) {
        os_unfair_lock_lock(&requestLock);
        requestMetadata = metadata;
        os_unfair_lock_unlock(&requestLock);
    }
    if (capture && [forward[@"x-line-access"] length] && [forward[@"x-line-application"] length]) {
        NSString *account = [[[NSUserDefaults alloc] initWithSuiteName:@"group.com.linecorp.line"] stringForKey:@"mid"];
        if (![account hasPrefix:@"u"] || account.length != 33) return;
        NSURLComponents *endpoint = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
        endpoint.path = @"/S4"; endpoint.query = nil; endpoint.fragment = nil;
        if (!endpoint.URL) return;
        NSDictionary *context = @{@"account":account, @"URL":endpoint.URL, @"headers":[forward copy]};
        os_unfair_lock_lock(&requestLock);
        httpContext = context;
        os_unfair_lock_unlock(&requestLock);
    }
}

NSDictionary *RUINCopyNativeReadRangeHTTPContext(void) {
    NSString *account = [[[NSUserDefaults alloc] initWithSuiteName:@"group.com.linecorp.line"] stringForKey:@"mid"];
    os_unfair_lock_lock(&requestLock);
    if (![httpContext[@"account"] isEqual:account] ||
        !TrackReadersEnabled()) httpContext = nil;
    NSDictionary *result = [httpContext copy];
    os_unfair_lock_unlock(&requestLock);
    return result;
}

@protocol RUINNativeMIDValue <NSObject>
- (NSInteger)type;
- (NSData *)dataValue;
- (NSString *)stringValue;
@end
@protocol RUINNativeChatIDValue <NSObject>
- (instancetype)initWithMIDString:(NSString *)string;
- (id<RUINNativeMIDValue>)mid;
@end

static BOOL Identifier(id value, unichar prefix) {
    if (![value isKindOfClass:NSString.class] || [value length] != 33 || [value characterAtIndex:0] != prefix) return NO;
    for (NSUInteger i = 1; i < 33; i++) {
        unichar c = [value characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return NO;
    }
    return YES;
}

static BOOL Encoding(Class cls, const char *selector, const char *expected) {
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName(selector)) : NULL;
    return method && !strcmp(method_getTypeEncoding(method), expected);
}

static NSData *SerializedMID(NSData *binary, NSInteger type) {
    if (![binary isKindOfClass:NSData.class] || binary.length != 16 || type < 0 || type > 7) return nil;
    uint8_t tag = (uint8_t)type;
    NSMutableData *result = [NSMutableData dataWithBytes:&tag length:1];
    [result appendData:binary];
    return [result copy];
}

static NSData *NativeChatData(NSString *chat) {
    if (!Identifier(chat, 'c')) return nil;
    Class chatClass = objc_getClass("_TtC19LineSharedMessaging6ChatID");
    Class midClass = objc_getClass("_TtC13LineSharedMID3MID");
    if (!Encoding(chatClass, "initWithMIDString:", "@24@0:8@16") ||
        !Encoding(chatClass, "mid", "@16@0:8") || !Encoding(midClass, "type", "q16@0:8") ||
        !Encoding(midClass, "dataValue", "@16@0:8") || !Encoding(midClass, "stringValue", "@16@0:8")) return nil;
    @try {
        id<RUINNativeChatIDValue> native = [(id<RUINNativeChatIDValue>)[chatClass alloc] initWithMIDString:chat];
        id<RUINNativeMIDValue> mid = [native mid];
        if (object_getClass(mid) != midClass || ![[mid stringValue] isEqual:chat]) return nil;
        NSInteger type = [mid type];
        NSData *result = SerializedMID([mid dataValue], type);
        if (result) encodedType = type;
        return result;
    } @catch (__unused NSException *exception) { return nil; }
}

static BOOL SerializedChat(id value) {
    return [value isKindOfClass:NSData.class] && [value length] == 17 && ((const uint8_t *)[value bytes])[0] <= 7;
}

static NSArray *QueueAddingData(id existing, NSData *chat) {
    if (!SerializedChat(chat) || (existing && ![existing isKindOfClass:NSArray.class]) || [existing count] > 256) return nil;
    for (id item in existing)
        if (!SerializedChat(item)) return nil;
    if ([existing containsObject:chat]) return [existing copy];
    if ([existing count] == 256) return nil;
    NSMutableArray *result = [NSMutableArray arrayWithArray:existing ?: @[]];
    [result addObject:chat];
    return [result copy];
}

void RUINPrepareNativeReadRangeProbe(void) {
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    NSString *chat = environment[@"RUIN_TEST_READ_RANGE_CHAT"];
    if (!chat || ![environment[@"RUIN_ENABLE_RUNTIME_INSPECTOR"] isEqual:@"1"]) return;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    if (![info[@"RUINOriginalBundleIdentifier"] isEqual:@"jp.naver.line"] ||
        ![info[@"CFBundleShortVersionString"] isEqual:@"26.16.0"] ||
        ![info[@"CFBundleVersion"] isEqual:@"2026.1006.1718"]) { probeStatus = @"wrong_build"; return; }
    NSUserDefaults *profile = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.linecorp.line"];
    if (!Identifier([profile objectForKey:@"mid"], 'u')) { probeStatus = @"profile_missing"; return; }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id previous = [defaults objectForKey:queueKey];
    NSData *serialized = NativeChatData(chat);
    if (!serialized) { probeStatus = @"native_encoding_unavailable"; return; }
    NSArray *merged = QueueAddingData(previous, serialized);
    if (!merged) { probeStatus = @"invalid_queue_or_chat"; return; }
    queueBefore = [previous count]; queueAfter = merged.count;
    if ([previous containsObject:serialized]) { probeStatus = @"already_queued"; return; }
    [defaults setObject:merged forKey:queueKey];
    probeStatus = [defaults synchronize] ? @"enqueued" : @"write_failed";
}

NSDictionary *RUINNativeReadRangeSyncDiagnostics(void) {
    NSDictionary *metadata;
    os_unfair_lock_lock(&requestLock);
    metadata = requestMetadata ?: @{};
    os_unfair_lock_unlock(&requestLock);
    return @{@"probeStatus":probeStatus, @"queueBefore":@(queueBefore), @"queueAfter":@(queueAfter),
        @"encodedMIDType":@(encodedType), @"queueProbeRequestsSentByRUIN":@0, @"queueProbeOnly":@YES,
        @"observedNativeRPC":metadata};
}

#if defined(RUIN_NATIVE_READ_RANGE_SYNC_HOST_CHECK)
#import <assert.h>
int main(void) { @autoreleasepool {
    NSData *raw = [NSMutableData dataWithLength:16];
    NSData *a = SerializedMID(raw, 0), *b = SerializedMID(raw, 2);
    assert(a.length == 17 && b.length == 17 && ((const uint8_t *)b.bytes)[0] == 2);
    assert(SerializedMID(raw, 8) == nil && SerializedMID([NSData data], 0) == nil);
    NSArray *original = @[a];
    assert(([QueueAddingData(original, b) isEqual:@[a,b]]));
    assert([QueueAddingData(original, a) isEqual:original] && original.count == 1);
    assert(QueueAddingData(@[@1], b) == nil);
    assert(QueueAddingData(@{}, b) == nil);
    assert(QueueAddingData(original, (id)@"not-data") == nil);
    assert(QueueAddingData(nil, b).count == 1);
    NSMutableArray *full = [NSMutableArray array];
    for (NSUInteger i = 0; i < 256; i++) [full addObject:a];
    assert(QueueAddingData(full, b) == nil && full.count == 256);
    setenv("RUIN_ENABLE_RUNTIME_INSPECTOR", "1", 1);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://legy.line-apps.com/S4"]];
    [request setValue:@"secret-auth-test-marker" forHTTPHeaderField:@"X-Line-Access"];
    request.HTTPBody = [@"getMessageReadRange private-body-test-marker" dataUsingEncoding:NSUTF8StringEncoding];
    RUINObserveNativeReadRangeRequest(session, request);
    NSDictionary *diagnostics = RUINNativeReadRangeSyncDiagnostics();
    assert([diagnostics[@"observedNativeRPC"][@"hasAccessHeader"] boolValue]);
    NSData *json = [NSJSONSerialization dataWithJSONObject:diagnostics options:0 error:NULL];
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    assert([text rangeOfString:@"secret-auth-test-marker"].location == NSNotFound);
    assert([text rangeOfString:@"private-body-test-marker"].location == NSNotFound);
    requestMetadata = nil;
    request.URL = [NSURL URLWithString:@"https://legy.line-apps.com.evil.test/S4"];
    RUINObserveNativeReadRangeRequest(session, request);
    assert(requestMetadata == nil);
    [session invalidateAndCancel];
    puts("PASS native read-range queue preserves pending chats and rejects invalid input");
} return 0; }
#endif
