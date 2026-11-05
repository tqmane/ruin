%config(generator=internal);

#import "ReadUsersEvents.h"
#import "MessageHistory.h"
#import "Features.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>
#import <math.h>

/* Actual manifest-matching LINE 26.16.0 / 2026.1006.1718 metadata, decoded
 with ../RUIN_reimplementation_pack/tools/decode_objc.py:
 LineOperation -read: v24@0:8@16 0x10269fc88 (returns at 0x10269fed4);
 -type q16@0:8 0x1026a0154, property Tq;
 -param1/2/3 @16@0:8 0x1026a0174/17c/184, properties T@"NSString",C,N.
 Type 55 uses param1 for the chat, param2 for the reader MID, and param3
 for the last-read message ID.
 Hook read:, not the setter: field decode order is not an event boundary.
 Addresses document evidence only; no runtime address/offset patching.
 */

typedef NS_ENUM(int, InstallStatus) { Pending, Gated, Missing, Mismatch, Installed };
static os_unfair_lock installLock = OS_UNFAIR_LOCK_INIT;
static atomic_int installStatus;
static atomic_uint_fast64_t readCalls, inactiveCalls, otherTypes, type55Events;
static atomic_uint_fast64_t rejectedEvents, recordedEvents, bridgeFailures;
static atomic_uint_fast64_t knownEventTimes, observationOnlyTimes;

static BOOL TargetMatches(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *info = bundle.infoDictionary;
    return ([bundle.bundleIdentifier isEqual:RUINTargetBundleIdentifier] ||
        [info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier]) &&
        [info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] &&
        [info[@"CFBundleVersion"] isEqual:RUINTargetBuild];
}
static BOOL Enabled(void) {
    return TargetMatches() && [NSUserDefaults.standardUserDefaults boolForKey:RUINTrackReadUsersKey];
}
static BOOL HasEncoding(Class cls, const char *name, const char *expected) {
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName(name)) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    return encoding && !strcmp(encoding, expected);
}
%group RUINReadUsers
%hook RUINReadUsersOperation
- (void)read:(id)protocol {
    atomic_fetch_add(&readCalls, 1);
    // An original exception propagates unchanged;
    // no incomplete/failed decode is observed or retried.
    %orig;
    @try {
        if (!Enabled()) { atomic_fetch_add(&inactiveCalls, 1); return; }
        Class cls = object_getClass(self);
        if (!HasEncoding(cls, "type", "q16@0:8")) {
            atomic_fetch_add(&rejectedEvents, 1); return;
        }
        long long type = ((long long (*)(id, SEL))objc_msgSend)(self, sel_registerName("type"));
        if (type != 55) { atomic_fetch_add(&otherTypes, 1); return; }
        atomic_fetch_add(&type55Events, 1);
        // Recheck the actual receiver, including subclass overrides, before
        // invoking any parameter getter. Never KVC or coerce a numeric field.
        for (const char **name = (const char *[]){"param1", "param2", "param3", NULL}; *name; name++) {
            if (!HasEncoding(cls, *name, "@16@0:8")) { atomic_fetch_add(&rejectedEvents, 1); return; }
        }
        id p1 = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("param1"));
        id p2 = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("param2"));
        id p3 = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("param3"));
        if (![p1 isKindOfClass:NSString.class] || ![p2 isKindOfClass:NSString.class] || ![p3 isKindOfClass:NSString.class]) {
            atomic_fetch_add(&rejectedEvents, 1); return;
        }
        NSString *chat = [p1 copy], *reader = [p2 copy], *message = [p3 copy];
        // Native LineOperation -createdTime q16@0:8 (0x1026a014c).
        long long serverTime = 0;
        if (HasEncoding(cls, "createdTime", "q16@0:8"))
            serverTime = MAX(0, ((long long (*)(id, SEL))objc_msgSend)(self, sel_registerName("createdTime")));
        long long observedTime = (long long)llround(NSDate.date.timeIntervalSince1970 * 1000.0);
        atomic_fetch_add(serverTime > 0 ? &knownEventTimes : &observationOnlyTimes, 1);
        // The bridge validates every code unit and signed-Int64 range and
        // serializes only copied values; the receiver never leaves this queue.
        if (RUINHistoryRecordType55ReadUpToWithTime(chat, reader, message, serverTime, observedTime)) atomic_fetch_add(&recordedEvents, 1);
        else atomic_fetch_add(&bridgeFailures, 1);
    } @catch (__unused NSException *exception) {
        // Observation failure cannot change LINE's successful decode result.
        atomic_fetch_add(&rejectedEvents, 1);
    }

}
%end
%end

void RUINInstallReadUsersEvents(void) {
    os_unfair_lock_lock(&installLock);
    @try {
        if (atomic_load(&installStatus) == Installed) return;
        if (!TargetMatches()) { atomic_store(&installStatus, Gated); return; }
        Class cls = objc_getClass("LineOperation");
        SEL selector = sel_registerName("read:");
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        if (!method || !method_getImplementation(method)) { atomic_store(&installStatus, Missing); return; }
        if (!HasEncoding(cls, "read:", "v24@0:8@16")) { atomic_store(&installStatus, Mismatch); return; }
        // Logos materializes inherited methods on this target class only.
        %init(RUINReadUsers, RUINReadUsersOperation = cls);
        atomic_store(&installStatus, Installed);
    } @finally { os_unfair_lock_unlock(&installLock); }
}
NSDictionary *RUINReadUsersEventsDiagnostics(void) {
    Class cls = objc_getClass("LineOperation");
    NSMutableArray *metadata = [NSMutableArray array];
    const char *names[] = {"read:", "type", "param1", "param2", "param3"};
    const char *expected[] = {"v24@0:8@16", "q16@0:8", "@16@0:8", "@16@0:8", "@16@0:8"};
    for (unsigned int i = 0; i < 5; i++) {
        Method method = cls ? class_getInstanceMethod(cls, sel_registerName(names[i])) : NULL;
        const char *actual = method ? method_getTypeEncoding(method) : NULL;
        [metadata addObject:@{@"selector":@(names[i]), @"expectedEncoding":@(expected[i]),
            @"actualEncoding":actual ? @(actual) : @"", @"matches":@(HasEncoding(cls, names[i], expected[i]))}];
    }
    return @{@"class":@"LineOperation", @"status":@[@"pending", @"version_gated", @"missing", @"encoding_mismatch", @"installed"][atomic_load(&installStatus)],
        @"targetSupported":@(TargetMatches()), @"enabled":@(Enabled()), @"preferenceKey":RUINTrackReadUsersKey,
        @"metadata":metadata, @"readCalls":@(atomic_load(&readCalls)), @"inactiveCalls":@(atomic_load(&inactiveCalls)),
        @"otherTypeCalls":@(atomic_load(&otherTypes)), @"type55Events":@(atomic_load(&type55Events)),
        @"rejectedEvents":@(atomic_load(&rejectedEvents)), @"recordedEvents":@(atomic_load(&recordedEvents)),
        @"bridgeFailures":@(atomic_load(&bridgeFailures)),
        @"knownServerEventTimes":@(atomic_load(&knownEventTimes)), @"observationOnlyTimes":@(atomic_load(&observationOnlyTimes)),
        @"captureBoundary":@"after successful original read:, getters and copies on callback queue; original forwarded once",
        @"coverage":@"type 55 only; param1 chat, param2 reader, param3 read-up-to; talk attribution via History's unique store binding",
        @"limitations":@"Android reference uses start<message<=end; iOS wire boundary/device behavior and OpenChat coverage remain unverified; missing server times use separately stored first observation, legacy missing dates stay unknown"};
}

#if defined(RUIN_READ_USERS_EVENTS_HOST_CHECK) && RUIN_READ_USERS_EVENTS_HOST_CHECK
/* From ruin/; only temporary databases and fake model objects:
 xcrun --sdk macosx clang -DRUIN_READ_USERS_EVENTS_HOST_CHECK=1 -fobjc-arc \
   -fblocks -std=gnu11 -Wall -Wextra -Werror -I. Features.m MessageHistory.m \
   ReadUsersEvents.m -framework Foundation -framework CoreData -lsqlite3 \
   -o /tmp/ruin-check-read-users
 /tmp/ruin-check-read-users && /tmp/ruin-check-read-users owned && /tmp/ruin-check-read-users mismatch
 */
#import <stdio.h>
static NSDictionary *testInfo;
static NSURL *testSupport;
static IMP testOriginalDirectories;
static char testQueueKey;
static _Thread_local BOOL testDecoding;
static atomic_uint_fast64_t testOriginalCalls, testGetterCalls, testBoundaryFailures, testUnsafeGetterCalls;
static void Check(BOOL condition, NSString *reason) {
    if (!condition) @throw [NSException exceptionWithName:@"RUINReadUsersCheck" reason:reason userInfo:nil];
}
static NSDictionary *TestInfo(id self, SEL selector) { (void)self; (void)selector; return testInfo; }
static NSArray *TestDirectories(id self, SEL selector, NSSearchPathDirectory directory, NSSearchPathDomainMask mask) {
    if (directory == NSApplicationSupportDirectory && mask == NSUserDomainMask) return @[testSupport];
    return ((id (*)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask))testOriginalDirectories)(self, selector, directory, mask);
}
static void TestGetterBoundary(void) {
    atomic_fetch_add(&testGetterCalls, 1);
    if (testDecoding || !dispatch_get_specific(&testQueueKey)) atomic_fetch_add(&testBoundaryFailures, 1);
}
@interface RUINOperationFixtureBase : NSObject {
    long long _type;
    long long _createdTime;
    id _param1, _param2, _param3;
}
- (void)read:(id)protocol;
- (long long)type;
- (long long)createdTime;
- (id)param1;
- (id)param2;
- (id)param3;
@end
@implementation RUINOperationFixtureBase
- (long long)type { TestGetterBoundary(); return _type; }
- (long long)createdTime { TestGetterBoundary(); return _createdTime; }
- (id)param1 { TestGetterBoundary(); return _param1; }
- (id)param2 { TestGetterBoundary(); return _param2; }
- (id)param3 { TestGetterBoundary(); return _param3; }
- (void)read:(id)protocol {
    atomic_fetch_add(&testOriginalCalls, 1);
    testDecoding = YES;
    _createdTime = 0;
    @try {
        // Model an actual decoder that can set param3 before type and other
        // fields. Reused objects start with stale values from a prior decode.
        for (NSArray *field in protocol) {
            NSString *name = field[0]; id value = field[1];
            if ([name isEqual:@"type"]) _type = [value longLongValue];
            else if ([name isEqual:@"createdTime"]) _createdTime = [value longLongValue];
            else if ([name isEqual:@"param1"]) _param1 = value;
            else if ([name isEqual:@"param2"]) _param2 = value;
            else if ([name isEqual:@"param3"]) _param3 = value;
            else if ([name isEqual:@"throw"]) @throw value;
        }
    } @finally { testDecoding = NO; }
}
@end
@interface LineOperation : RUINOperationFixtureBase @end
@implementation LineOperation @end
@interface RUINWrongTypeOperation : LineOperation @end
@implementation RUINWrongTypeOperation @end
@interface RUINWrongParamOperation : LineOperation @end
@implementation RUINWrongParamOperation @end
static int TestWrongType(id self, SEL selector) {
    (void)self; (void)selector; atomic_fetch_add(&testUnsafeGetterCalls, 1); return 55;
}
static long long TestWrongParam(id self, SEL selector) {
    (void)self; (void)selector; atomic_fetch_add(&testUnsafeGetterCalls, 1); return 42;
}
static long long TestWrongRead(id self, SEL selector, id protocol) {
    ((void (*)(id, SEL, id))class_getMethodImplementation(RUINOperationFixtureBase.class, selector))(self, selector, protocol);
    return 7;
}
static NSArray *Payload(NSString *chat, id reader, id message, long long type) {
    return @[@[@"param3", message], @[@"param2", reader], @[@"param1", chat], @[@"type", @(type)]];
}
static void ReadOnQueue(dispatch_queue_t queue, LineOperation *operation, NSArray *payload) {
    uint_fast64_t before = atomic_load(&testOriginalCalls);
    dispatch_sync(queue, ^{ [operation read:payload]; });
    Check(atomic_load(&testOriginalCalls) == before + 1, @"original read was omitted or forwarded more than once");
}
static uint64_t Recorded(void) { return [RUINReadUsersEventsDiagnostics()[@"recordedEvents"] unsignedLongLongValue]; }
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        int result = 0;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id savedReaders = [defaults objectForKey:RUINTrackReadUsersKey], savedKeep = [defaults objectForKey:RUINKeepUnsentMessagesKey];
        Method infoMethod = class_getInstanceMethod(NSBundle.class, @selector(infoDictionary));
        Method directoriesMethod = class_getInstanceMethod(NSFileManager.class, @selector(URLsForDirectory:inDomains:));
        IMP oldInfo = NULL;
        RUINHistoryStore *archive = nil;
        testSupport = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        dispatch_queue_t queue = dispatch_queue_create("ruin.check-read-users", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, &testQueueKey, &testQueueKey, NULL);
        @try {
            oldInfo = method_setImplementation(infoMethod, (IMP)TestInfo);
            testOriginalDirectories = method_setImplementation(directoriesMethod, (IMP)TestDirectories);
            [defaults removeObjectForKey:RUINTrackReadUsersKey]; [defaults setBool:NO forKey:RUINKeepUnsentMessagesKey];
            testInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"unsupported"};
            RUINInstallReadUsersEvents();
            Check([RUINReadUsersEventsDiagnostics()[@"status"] isEqual:@"version_gated"], @"unsupported build installed hook");
            testInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"RUINSignedBundleIdentifier":@"app.amethyst8609.ximenia5089",
                @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
            IMP baseRead = class_getMethodImplementation(RUINOperationFixtureBase.class, @selector(read:));
            LineOperation *operation = [LineOperation new];
            NSArray *payload = Payload(@"private-chat-sentinel", @"private-reader-sentinel", @"9007199254740993", 55);
            BOOL mismatch = argc > 1 && !strcmp(argv[1], "mismatch");
            if (mismatch) Check(class_addMethod(LineOperation.class, @selector(read:), (IMP)TestWrongRead, "q24@0:8@16"), @"fixture mismatched read setup failed");
            if (argc > 1 && !strcmp(argv[1], "owned"))
                Check(class_addMethod(LineOperation.class, @selector(read:), baseRead, "v24@0:8@16"), @"fixture owned read setup failed");
            RUINInstallReadUsersEvents(); RUINInstallReadUsersEvents();
            Check(class_getMethodImplementation(RUINOperationFixtureBase.class, @selector(read:)) == baseRead, @"inherited hook rewrote superclass");
            if (mismatch) {
                [defaults setBool:YES forKey:RUINTrackReadUsersKey];
                __block long long returned = 0;
                dispatch_sync(queue, ^{ returned = ((long long (*)(id, SEL, id))objc_msgSend)(operation, @selector(read:), payload); });
                Check(returned == 7 && atomic_load(&testOriginalCalls) == 1 && Recorded() == 0 &&
                    [RUINReadUsersEventsDiagnostics()[@"status"] isEqual:@"encoding_mismatch"], @"mismatched original was replaced or changed");
            } else {
                Check([RUINReadUsersEventsDiagnostics()[@"status"] isEqual:@"installed"], @"signed marker did not enable exact target");
                ReadOnQueue(queue, operation, payload);
                Check(Recorded() == 0 && atomic_load(&testGetterCalls) == 0 &&
                    ![NSFileManager.defaultManager fileExistsAtPath:[testSupport URLByAppendingPathComponent:@"RUIN/history.sqlite"].path],
                    @"default-off observation accessed fields or opened history");
                [defaults setBool:YES forKey:RUINTrackReadUsersKey]; // Live; no reinstall.
                ReadOnQueue(queue, operation, Payload(@"ignored-chat", @"ignored-reader", @"2", 54));
                Check(Recorded() == 0 && atomic_load(&testGetterCalls) == 1, @"non-55 event read parameter fields");
                ReadOnQueue(queue, operation, payload); // param3 first; type last.
                archive = [[RUINHistoryStore alloc] initWithURL:[testSupport URLByAppendingPathComponent:@"RUIN/history.sqlite"] error:NULL];
                Check(archive && Recorded() == 1, @"complete type-55 did not reach actual History bridge");
                Check([archive bindStore:@"fixture-store" kind:@"talk" chat:@"private-chat-sentinel"], @"fixture binding failed");
                NSArray *readers = [archive readersInStore:@"fixture-store" kind:@"talk" chat:@"private-chat-sentinel" message:@"9007199254740993"];
                Check(readers.count == 1 && [readers[0][@"readerID"] isEqual:@"private-reader-sentinel"] &&
                    [readers[0][@"readAtMilliseconds"] longLongValue] == 0 &&
                    [archive readersInStore:@"fixture-store" kind:@"talk" chat:@"private-chat-sentinel" message:@"9007199254740994"].count == 0,
                    @"field order/mapping or exact 64-bit boundary changed");
                ReadOnQueue(queue, operation, @[@[@"type", @55], @[@"param1", @"second-chat"], @[@"param3", @"12"], @[@"param2", @"second-reader"]]);
                Check([archive bindStore:@"fixture-store" kind:@"talk" chat:@"second-chat"], @"second binding failed");
                readers = [archive readersInStore:@"fixture-store" kind:@"talk" chat:@"second-chat" message:@"12"];
                Check(readers.count == 1 && [readers[0][@"readerID"] isEqual:@"second-reader"] && Recorded() == 2,
                    @"reused decode captured stale or incomplete fields");
                ReadOnQueue(queue, operation, payload); // Duplicate reaches bridge but remains one stored range.
                Check([archive.counts[@"observed_ranges"] unsignedIntegerValue] == 2, @"duplicate decode duplicated persisted ranges");
                long long firstObserved = [[archive readersInStore:@"fixture-store" kind:@"talk" chat:@"private-chat-sentinel" message:@"9007199254740993"][0][@"observedAtMilliseconds"] longLongValue];
                NSMutableArray *timedPayload = [payload mutableCopy];
                [timedPayload addObject:@[@"createdTime", @1700000000123]];
                ReadOnQueue(queue, operation, timedPayload);
                NSMutableArray *laterPayload = [payload mutableCopy];
                [laterPayload addObject:@[@"createdTime", @1700000009123]];
                ReadOnQueue(queue, operation, laterPayload);
                ReadOnQueue(queue, operation, payload); // Missing time must not reuse/erase the previous decode's time.
                NSDictionary *timedReader = [archive readersInStore:@"fixture-store" kind:@"talk" chat:@"private-chat-sentinel" message:@"9007199254740993"].firstObject;
                Check([timedReader[@"readAtMilliseconds"] longLongValue] == 1700000000123 &&
                    [timedReader[@"observedAtMilliseconds"] longLongValue] == firstObserved &&
                    [timedReader[@"timeSource"] isEqual:@"server_event"], @"later/missing event time overwrote first known time or observation provenance");
                ReadOnQueue(queue, operation, Payload(@"private-chat-sentinel", @"private-reader-sentinel", @"9007199254740992", 55));
                readers = [archive readersInStore:@"fixture-store" kind:@"talk" chat:@"private-chat-sentinel" message:@"9007199254740993"];
                Check(readers.count == 1 && [readers[0][@"readerID"] isEqual:@"private-reader-sentinel"],
                    @"a lower read-up cursor erased previously captured message coverage");

                NSArray *twoMemberRanges = @[@{@"start":@"0", @"end":@"12", @"startTime":@0, @"endTime":@0,
                    @"observedAt":@0, @"timeSource":@"unknown"}];
                Check([archive recordObservedRangesByReader:@{@"remote-author":twoMemberRanges, @"device-owner":twoMemberRanges}
                    kind:@"talk" chat:@"reader-filter-chat"] &&
                    [archive bindStore:@"fixture-store" kind:@"talk" chat:@"reader-filter-chat"],
                    @"two-member author-exclusion fixture failed");
                NSDictionary *selectedMessage = @{@"store":@"fixture-store", @"kind":@"talk", @"chat":@"reader-filter-chat",
                    @"message":@"12", @"sender":@"remote-author"};
                readers = RUINReadUsersForMessageKey(selectedMessage);
                Check(readers.count == 1 && [readers[0][@"readerID"] isEqual:@"device-owner"],
                    @"author was not excluded or another member's read was filtered");
                NSMutableDictionary *unrelatedAuthor = [selectedMessage mutableCopy]; unrelatedAuthor[@"sender"] = @"unrelated-author";
                Check(RUINReadUsersForMessageKey(unrelatedAuthor).count == 2,
                    @"a message not sent by the device owner lost its other readers");
                Check([archive bindStore:@"second-account-store" kind:@"talk" chat:@"reader-filter-chat"],
                    @"second account binding fixture failed");
                NSMutableDictionary *secondAccountKey = [selectedMessage mutableCopy];
                secondAccountKey[@"store"] = @"second-account-store";
                Check(RUINReadUsersForMessageKey(selectedMessage).count == 0 && RUINReadUsersForMessageKey(secondAccountKey).count == 0,
                    @"store-less readers crossed an ambiguous account binding");
                Check(class_addMethod(RUINWrongTypeOperation.class, @selector(type), (IMP)TestWrongType, "i16@0:8") &&
                    class_addMethod(RUINWrongParamOperation.class, @selector(param2), (IMP)TestWrongParam, "q16@0:8"), @"bad getter fixture failed");
                uint64_t before = Recorded();
                ReadOnQueue(queue, [RUINWrongTypeOperation new], payload);
                ReadOnQueue(queue, [RUINWrongParamOperation new], payload);
                ReadOnQueue(queue, operation, Payload(@"private-chat-sentinel", @42, @"12", 55));
                ReadOnQueue(queue, operation, Payload(@"private-chat-sentinel", @"private-reader-sentinel", @12, 55));
                unichar nul[] = {'1', 0, '2'};
                ReadOnQueue(queue, operation, Payload(@"private-chat-sentinel", @"private-reader-sentinel", [NSString stringWithCharacters:nul length:3], 55));
                ReadOnQueue(queue, operation, Payload(@"private-chat-sentinel", @"private-reader-sentinel", @"9223372036854775808", 55));
                Check(Recorded() == before && atomic_load(&testUnsafeGetterCalls) == 0, @"ABI/value guard invoked unsafe getter or persisted invalid event");
                NSException *decodeFailure = [NSException exceptionWithName:@"FixtureDecodeFailure" reason:@"expected" userInfo:nil];
                uint_fast64_t calls = atomic_load(&testOriginalCalls);
                __block NSException *caught;
                dispatch_sync(queue, ^{
                    @try { [operation read:@[@[@"throw", decodeFailure]]]; }
                    @catch (NSException *exception) { caught = exception; }
                });
                Check(caught == decodeFailure && atomic_load(&testOriginalCalls) == calls + 1 && Recorded() == before,
                    @"original exception was swallowed/retried or failed decode was recorded");
                [defaults setBool:NO forKey:RUINTrackReadUsersKey];
                uint_fast64_t getters = atomic_load(&testGetterCalls);
                ReadOnQueue(queue, operation, payload);
                Check(Recorded() == before && atomic_load(&testGetterCalls) == getters, @"disabling did not immediately restore pass-through");
                [defaults setBool:YES forKey:RUINTrackReadUsersKey];
                testInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"unsupported"};
                ReadOnQueue(queue, operation, payload);
                Check(Recorded() == before && atomic_load(&testGetterCalls) == getters, @"installed hook did not fail open for unsupported build");
                testInfo = @{@"RUINOriginalBundleIdentifier":@"wrong.origin", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
                ReadOnQueue(queue, operation, payload);
                Check(Recorded() == before && atomic_load(&testGetterCalls) == getters, @"wrong original bundle passed gate");
                testInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.15.0", @"CFBundleVersion":@"2026.1006.1718"};
                ReadOnQueue(queue, operation, payload);
                Check(Recorded() == before && atomic_load(&testGetterCalls) == getters, @"wrong version passed gate");
                testInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
                dispatch_queue_t concurrent = dispatch_queue_create("ruin.check-read-users-concurrent", DISPATCH_QUEUE_CONCURRENT);
                dispatch_queue_set_specific(concurrent, &testQueueKey, &testQueueKey, NULL);
                calls = atomic_load(&testOriginalCalls);
                dispatch_apply(24, concurrent, ^(size_t index) {
                    @autoreleasepool {
                        LineOperation *item = [LineOperation new];
                        [item read:Payload(@"parallel-chat", [NSString stringWithFormat:@"parallel-reader-%zu", index], @"12", 55)];
                    }
                });
                Check(Recorded() == before + 24 && atomic_load(&testOriginalCalls) == calls + 24 &&
                    atomic_load(&testBoundaryFailures) == 0, @"parallel callbacks lost events, forwarded twice or crossed queue/boundary");
                NSString *diagnostics = [RUINReadUsersEventsDiagnostics() description];
                for (NSString *private in @[@"private-chat-sentinel", @"private-reader-sentinel", @"9007199254740993", testSupport.path])
                    Check([diagnostics rangeOfString:private].location == NSNotFound, @"diagnostics disclosed event data/path");
            }
        } @catch (NSException *exception) {
            fprintf(stderr, "RUIN ReadUsersEvents check failed: %s\n", exception.reason.UTF8String ?: "unknown"); result = 1;
        } @finally {
            archive = nil;
            if (savedReaders) [defaults setObject:savedReaders forKey:RUINTrackReadUsersKey]; else [defaults removeObjectForKey:RUINTrackReadUsersKey];
            if (savedKeep) [defaults setObject:savedKeep forKey:RUINKeepUnsentMessagesKey]; else [defaults removeObjectForKey:RUINKeepUnsentMessagesKey];
            if (oldInfo) method_setImplementation(infoMethod, oldInfo);
            if (testOriginalDirectories) method_setImplementation(directoriesMethod, testOriginalDirectories);
            [NSFileManager.defaultManager removeItemAtURL:testSupport error:NULL];
        }
        if (!result) puts("RUIN ReadUsersEvents native host checks passed");
        return result;
    }
}
#endif
