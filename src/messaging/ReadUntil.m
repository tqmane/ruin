#import "ReadUntil.h"
#import "MessageHistory.h"
#import <objc/runtime.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#if !defined(RUIN_READ_UNTIL_HOST_CHECK)
#import "../core/TargetMetadata.h"
#import "../known/VersionMapping.h"
#endif

NSString *const RUINReadUntilErrorDomain = @"RUINReadUntil";

@protocol RUINReadUntilChat <NSObject>
- (nullable id)midStructAndReturnError:(NSError * _Nullable __autoreleasing *)error;
@end
@protocol RUINReadUntilMID <NSObject>
- (NSString *)stringValue;
@end
@protocol RUINReadUntilService <NSObject>
+ (nullable id)readUpToMessage:(NSString *)messageID inRoom:(id)room
                   completion:(void (^)(NSError * _Nullable error))completion;
@end

static NSError *ReadUntilError(RUINReadUntilErrorCode code) {
    return [NSError errorWithDomain:RUINReadUntilErrorDomain code:code userInfo:nil];
}
static BOOL SubclassOf(Class cls, Class parent);

// Defer a synchronous native callback until invocation/return validation ends.
// This also prevents a caller exception from unwinding through LINE, whose
// native local cursor update follows its completion invocation.
@interface RUINReadUntilRequest : NSObject {
    RUINReadUntilCompletion _completion;
    id _task;
    NSError *_pendingError;
    BOOL _invoking, _received, _finished;
}
- (instancetype)initWithCompletion:(RUINReadUntilCompletion)completion;
- (void)receive:(nullable NSError *)error;
- (void)returnedTask:(nullable id)task expectedClass:(Class)taskClass;
- (void)finish:(nullable NSError *)error;
@end

@implementation RUINReadUntilRequest
- (instancetype)initWithCompletion:(RUINReadUntilCompletion)completion {
    if ((self = [super init])) { _completion = [completion copy]; _invoking = YES; }
    return self;
}
- (void)receive:(NSError *)error {
    @synchronized (self) {
        if (_finished || _received) return;
        _received = YES;
        _pendingError = error;
        if (_invoking) return;
    }
    [self finish:error];
}
- (void)returnedTask:(id)task expectedClass:(Class)taskClass {
    NSError *result = nil;
    @synchronized (self) {
        if (_finished) return;
        _invoking = NO;
        if (!task || !SubclassOf(object_getClass(task), taskClass))
            result = ReadUntilError(RUINReadUntilInvalidNativeResult);
        else if (_received) result = _pendingError;
        else { _task = task; return; }
    }
    [self finish:result];
}
- (void)finish:(NSError *)error {
    if (error && ![error isKindOfClass:NSError.class])
        error = ReadUntilError(RUINReadUntilInvalidNativeResult);
    RUINReadUntilCompletion completion;
    __attribute__((objc_precise_lifetime)) id heldTask;
    @synchronized (self) {
        if (_finished) return;
        _finished = YES;
        completion = _completion;
        _completion = nil;
        heldTask = _task;
        _task = nil;
        _pendingError = nil;
    }
    @try { if (completion) completion(error); }
    @catch (__unused NSException *exception) { /* Do not unwind into LINE. */ }
    (void)heldTask;
}
@end

static BOOL MatchesMethod(Class cls, BOOL classMethod, const char *name, const char *types) {
    Method method = classMethod ? class_getClassMethod(cls, sel_registerName(name))
                                : class_getInstanceMethod(cls, sel_registerName(name));
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    return actual && !strcmp(actual, types) && method_getImplementation(method);
}

static BOOL SubclassOf(Class cls, Class parent) {
    for (; cls; cls = class_getSuperclass(cls)) if (cls == parent) return YES;
    return NO;
}

static BOOL TargetMatches(void) {
#if defined(RUIN_READ_UNTIL_HOST_CHECK)
    return YES; // The fixture supplies exact fake runtime classes, never LINE.
#else
    const RUINVersionMapping *mapping = RUINCurrentMapping();
    return mapping && mapping->messaging.readUntilABIStatus == RUINMappingStatusVerified;
#endif
}

static BOOL ValidMessageID(NSString *string) {
    if (![string isKindOfClass:NSString.class] || !string.length || string.length > 19) return NO;
    uint64_t value = 0;
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar character = [string characterAtIndex:i];
        if (character < '0' || character > '9') return NO;
        unsigned digit = character - '0';
        if (value > ((uint64_t)LLONG_MAX - digit) / 10) return NO;
        value = value * 10 + digit;
    }
    return value > 0;
}

BOOL RUINReadUntilAvailable(void) {
    Class chat = objc_getClass("ManagedChat");
    Class mid = objc_getClass("_TtC13LineSharedMID3MID");
    Class task = objc_getClass("_TtC13LEGYInterface17AnyCancelableTask");
    Class service = objc_getClass("_TtC13LineMessaging11ChatService");
    return TargetMatches() && SubclassOf(chat, NSManagedObject.class) &&
        SubclassOf(mid, NSObject.class) && task && !class_isMetaClass(task) &&
        SubclassOf(service, NSObject.class) &&
        MatchesMethod(chat, NO, "midStructAndReturnError:", "@24@0:8^@16") &&
        MatchesMethod(mid, NO, "stringValue", "@16@0:8") &&
        MatchesMethod(service, YES, "readUpToMessage:inRoom:completion:", "@40@0:8@16@24@?32");
}

void RUINReadUntilMessage(NSDictionary *messageKey, NSManagedObject *nativeChat,
                          RUINReadUntilCompletion completion) {
    if (!completion) return;
    RUINReadUntilRequest *request = [[RUINReadUntilRequest alloc] initWithCompletion:completion];
    @try {
        NSMutableDictionary *selection = [NSMutableDictionary dictionary];
        if ([messageKey isKindOfClass:NSDictionary.class]) {
            for (NSString *field in @[@"kind", @"store", @"chat", @"message"]) {
                id value = messageKey[field];
                if ([value isKindOfClass:NSString.class]) selection[field] = [value copy];
            }
        }
        NSDictionary *key = [selection copy];
        if (key.count != 4 || ![key[@"kind"] isEqual:@"talk"] || !ValidMessageID(key[@"message"])) {
            [request finish:ReadUntilError(RUINReadUntilInvalidSelection)]; return;
        }
        Class chatClass = objc_getClass("ManagedChat");
        Class midClass = objc_getClass("_TtC13LineSharedMID3MID");
        Class taskClass = objc_getClass("_TtC13LEGYInterface17AnyCancelableTask");
        Class serviceClass = objc_getClass("_TtC13LineMessaging11ChatService");
        if (!TargetMatches() || !SubclassOf(chatClass, NSManagedObject.class) ||
            !SubclassOf(midClass, NSObject.class) || !taskClass || class_isMetaClass(taskClass) ||
            !SubclassOf(serviceClass, NSObject.class) ||
            ![nativeChat isKindOfClass:chatClass] ||
            !MatchesMethod(object_getClass(nativeChat), NO, "midStructAndReturnError:", "@24@0:8^@16") ||
            !MatchesMethod(midClass, NO, "stringValue", "@16@0:8") ||
            !MatchesMethod(serviceClass, YES, "readUpToMessage:inRoom:completion:", "@40@0:8@16@24@?32")) {
            [request finish:ReadUntilError(RUINReadUntilUnavailable)]; return;
        }
        NSManagedObjectContext *context = nativeChat.managedObjectContext;
        if (!context) { [request finish:ReadUntilError(RUINReadUntilChatMismatch)]; return; }
        __block id mid = nil;
        __block NSError *error = nil;
        [context performBlockAndWait:^{
            @try {
                if (!RUINHistoryValidateReadChatKey(key, nativeChat)) {
                    error = ReadUntilError(RUINReadUntilChatMismatch); return;
                }
                mid = [(id<RUINReadUntilChat>)nativeChat midStructAndReturnError:&error];
                if (error) return;
                if (![mid isKindOfClass:midClass] ||
                    !MatchesMethod(object_getClass(mid), NO, "stringValue", "@16@0:8")) {
                    error = ReadUntilError(RUINReadUntilInvalidNativeResult); return;
                }
                id identifier = [(id<RUINReadUntilMID>)mid stringValue];
                if (![identifier isKindOfClass:NSString.class] || ![identifier isEqual:key[@"chat"]])
                    error = ReadUntilError(RUINReadUntilChatMismatch);
            } @catch (__unused NSException *exception) {
                error = ReadUntilError(RUINReadUntilNativeException);
            }
        }];
        if (error) { [request finish:error]; return; }
        // Pristine 26.17 bridge invokes this block as v16@?0@8: NSError or nil.
        // Native owns the ensuing selected-ID cursor update and context save.
        void (^nativeCompletion)(NSError *) = ^(NSError *nativeError) { [request receive:nativeError]; };
        id task = [(Class<RUINReadUntilService>)serviceClass readUpToMessage:key[@"message"]
            inRoom:mid completion:nativeCompletion];
        [request returnedTask:task expectedClass:taskClass];
    } @catch (__unused NSException *exception) {
        [request finish:ReadUntilError(RUINReadUntilNativeException)];
    }
}
