%config(generator=internal);

#import "MessagingPrivateAPI.h"
#import "UnsendOperation.h"
#import "Features.h"
#import "MessageHistory.h"
#import <CoreData/CoreData.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <execinfo.h>
#import <sqlite3.h>
#import <stdatomic.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>

/* build/current-unsend-evidence.json records the manifest-matching binary.
 Current parser 0x10461eeec -> MessageDestroyOperation (Swift metadata):
 param1 ChatID, param2 positive Int64 MessageServerID, param3=="1" silent.
 type 64 -> recipient sender, 65 -> others (explicit CMPs, not enum memory).
 Dispatcher 0x1000bac30/44 -> parser -> destroy wrapper 0x103e29a24 ->
 body 0x103e29b38. Its FIRST message lookup returns nil for an empty fetch;
 nil exits before cleanup 0x103e2b3c4 or cancellation creation. Intercept that
 lookup through the standard Core Data ObjC API, with exact ordered return
 PCs AND a single-message ID predicate/result/context. No native ABI call or
 patch, broad deleteObject: suppression, operation mutation, or time window.
 */

typedef struct { uintptr_t address; uint32_t word; } CodeAnchor;
static const CodeAnchor anchors[] = {
    {0x1000bac24, 0xf277053f}, {0x1000bac30, 0x951590af}, {0x1000bac44, 0x94f5bb78},
    {0x103e29b2c, 0x94000003}, {0x103e29b7c, 0x9407fdd4}, {0x103e29b80, 0xb4000415},
    {0x103e29c04, 0xb4fffc20}, {0x103e29dcc, 0x9400057e}, {0x1040292fc, 0x97fa9bd2},
    {0x103ed03a8, 0x9554620e}, {0x103ed03c4, 0xb4000160}, {0x103ed03f4, 0xd2800017},
    {0x10461ef0c, 0x9538eaa5}, {0x10461f234, 0xf10102bf}, {0x10461f23c, 0xf10106bf}
};
// Nearest first: fetch helper -> lookup wrapper -> destroy body -> incoming
// wrapper -> operation dispatcher. Missing/reordered frames fail open.
static const uintptr_t scopePCs[] = {0x103ed03ac, 0x104029300, 0x103e29b80, 0x103e29b30, 0x1000bac48};
static _Atomic(uintptr_t) imageSlide;
static atomic_bool codeVerified;
static atomic_int fetchStatus, displayStatus, param1Status; // 0 pending, 1 gated, 2 ABI mismatch, 3 installed.
static atomic_uint_fast64_t fetchCalls, scopedLookups, protectedMessages, rejectedLookups, observationErrors;
static atomic_uint_fast64_t markerFailures, historyFreezes, displayReturns;
static atomic_uint_fast64_t capturedOperations, rejectedOperations;
static NSString *const OperationThreadKey = @"RUINUnsendOperation.currentParserIdentity";
static os_unfair_lock installLock = OS_UNFAIR_LOCK_INIT, markerLock = OS_UNFAIR_LOCK_INIT;
static sqlite3 *markerDatabase;
static _Thread_local unsigned int fetchDepth, displayDepth;
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
static BOOL testImageMatches;
static _Thread_local const uintptr_t *testPCs;
static _Thread_local size_t testPCCount;
static _Thread_local uintptr_t testParam1Caller;
#endif

static BOOL TargetMatches(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSDictionary *info = bundle.infoDictionary;
    return ([bundle.bundleIdentifier isEqual:RUINTargetBundleIdentifier] ||
        [info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier]) &&
        [info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] &&
        [info[@"CFBundleVersion"] isEqual:RUINTargetBuild];
}
static BOOL Enabled(void) {
    return atomic_load(&codeVerified) && TargetMatches() &&
        [NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey];
}
static BOOL VerifyCode(void) {
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
    atomic_store(&imageSlide, 0); return testImageMatches;
#else
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
        header->sizeofcmds > 1024 * 1024) return NO;
    const uint8_t *p = (const void *)(header + 1), *end = p + header->sizeofcmds;
    uintptr_t textStart = 0, textEnd = 0, slide = (uintptr_t)_dyld_get_image_vmaddr_slide(0);
    for (uint32_t i = 0; i < header->ncmds && p + sizeof(struct load_command) <= end; i++) {
        const struct load_command *command = (const void *)p;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - p)) return NO;
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const void *)p;
            if (!strcmp(segment->segname, "__TEXT")) { textStart = segment->vmaddr; textEnd = textStart + segment->vmsize; }
        }
        p += command->cmdsize;
    }
    if (!textStart || textEnd <= textStart) return NO;
    for (NSUInteger i = 0; i < sizeof(anchors) / sizeof(anchors[0]); i++) {
        if (anchors[i].address < textStart || anchors[i].address > textEnd - sizeof(uint32_t)) return NO;
        uint32_t actual; memcpy(&actual, (const void *)(anchors[i].address + slide), sizeof(actual));
        if (actual != anchors[i].word) return NO;
    }
    atomic_store(&imageSlide, slide); return YES;
#endif
}
static BOOL OrderedScope(const uintptr_t *pcs, size_t count) {
    size_t matched = 0;
    for (size_t i = 0; i < count && matched < sizeof(scopePCs) / sizeof(scopePCs[0]); i++)
        if (pcs[i] == scopePCs[matched]) matched++;
    return matched == sizeof(scopePCs) / sizeof(scopePCs[0]);
}
static BOOL InUnsendLookup(void) {
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
    return OrderedScope(testPCs, testPCCount);
#else
    void *frames[48]; uintptr_t pcs[48], slide = atomic_load(&imageSlide);
    int count = backtrace(frames, 48);
    for (int i = 0; i < count; i++) pcs[i] = (uintptr_t)frames[i] - slide;
    return OrderedScope(pcs, count > 0 ? (size_t)count : 0);
#endif
}
static NSString *MessageID(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
    long long number = 0;
    for (NSUInteger i = 0; i < [value length]; i++) {
        unichar digit = [value characterAtIndex:i];
        if (digit < '0' || digit > '9' || number > (LLONG_MAX - (digit - '0')) / 10) return nil;
        number = number * 10 + digit - '0';
    }
    return number > 0 ? [NSString stringWithFormat:@"%lld", number] : nil;
}
%group RUINUnsendParam1
%hook RUINUnsendParsedOperation
- (id)param1 {
    id object = self;
    id actual = %orig;
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
    uintptr_t caller = testParam1Caller;
#else
    uintptr_t caller = (uintptr_t)__builtin_return_address(0) - atomic_load(&imageSlide);
#endif
    if (caller != 0x10461ef10) return actual;
    // This is the first field read by the verified parser, after decoding.
    // Replace, then consume this thread-local tuple at its first scoped fetch;
    // never maintain a global/time-window allowlist of message IDs.
    NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
    [thread removeObjectForKey:OperationThreadKey];
    @try {
        if (!Enabled() || ![actual isKindOfClass:NSString.class] || ![actual length]) return actual;
        Class cls = object_getClass(object);
        const char *names[] = {"type", "param2", "param3"}, *types[] = {"q16@0:8", "@16@0:8", "@16@0:8"};
        for (NSUInteger i = 0; i < 3; i++) {
            Method method = class_getInstanceMethod(cls, sel_registerName(names[i]));
            if (!method || strcmp(method_getTypeEncoding(method), types[i])) { atomic_fetch_add(&rejectedOperations, 1); return actual; }
        }
        long long type = [(id<RUINMessagingOperationFields>)object type];
        id rawMessage = [(id<RUINMessagingOperationFields>)object param2];
        NSString *message = MessageID(rawMessage);
        if ((type != 64 && type != 65) || !message) { atomic_fetch_add(&rejectedOperations, 1); return actual; }
        thread[OperationThreadKey] = @{@"chat":[actual copy], @"message":message};
        atomic_fetch_add(&capturedOperations, 1);
    } @catch (__unused NSException *exception) { atomic_fetch_add(&rejectedOperations, 1); }
    return actual;

}
%end
%end
static NSString *RequestedMessage(NSFetchRequest *request) {
    if (request.resultType != NSManagedObjectResultType || ![request.predicate isKindOfClass:NSComparisonPredicate.class]) return nil;
    NSComparisonPredicate *p = (id)request.predicate;
    if (p.comparisonPredicateModifier != NSDirectPredicateModifier || p.predicateOperatorType != NSEqualToPredicateOperatorType || p.options) return nil;
    NSExpression *left = p.leftExpression, *right = p.rightExpression;
    if (left.expressionType == NSConstantValueExpressionType) { NSExpression *swap = left; left = right; right = swap; }
    if (left.expressionType != NSKeyPathExpressionType || ![left.keyPath isEqual:@"id"] || right.expressionType != NSConstantValueExpressionType) return nil;
    return MessageID(right.constantValue);
}
static NSURL *MarkerURL(void) {
    NSURL *root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return root ? [root URLByAppendingPathComponent:@"RUIN/unsend-operation.sqlite"] : nil;
}
static BOOL OpenMarkers(BOOL create) {
    if (markerDatabase) return YES;
    NSURL *url = MarkerURL();
    if (!url) return NO;
    if (!create && ![NSFileManager.defaultManager fileExistsAtPath:url.path]) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL]) return NO;
#if TARGET_OS_IPHONE
    [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}
                                 ofItemAtPath:url.URLByDeletingLastPathComponent.path error:NULL];
#endif
    if (sqlite3_open_v2(url.fileSystemRepresentation, &markerDatabase, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) == SQLITE_OK) {
        sqlite3_busy_timeout(markerDatabase, 250);
        if (sqlite3_exec(markerDatabase, "CREATE TABLE IF NOT EXISTS retained(store TEXT,kind TEXT,chat TEXT,message TEXT,PRIMARY KEY(store,kind,chat,message))", NULL, NULL, NULL) == SQLITE_OK) return YES;
    }
    if (markerDatabase) sqlite3_close_v2(markerDatabase);
    markerDatabase = NULL; return NO;
}
static BOOL RetainedMarker(NSDictionary *key, BOOL write) {
    BOOL result = NO;
    os_unfair_lock_lock(&markerLock);
    @try {
        if (!OpenMarkers(write)) return NO;
        sqlite3_stmt *statement = NULL;
        int status = sqlite3_prepare_v2(markerDatabase, write ? "INSERT OR IGNORE INTO retained VALUES(?,?,?,?)" :
            "SELECT 1 FROM retained WHERE store=? AND kind=? AND chat=? AND message=?", -1, &statement, NULL);
        for (NSUInteger i = 0; status == SQLITE_OK && i < 4; i++) {
            NSData *data = [key[@[@"store", @"kind", @"chat", @"message"][i]] dataUsingEncoding:NSUTF8StringEncoding];
            status = data && data.length <= INT_MAX ? sqlite3_bind_text(statement, (int)i + 1, data.bytes ?: "", (int)data.length, SQLITE_TRANSIENT) : SQLITE_MISMATCH;
        }
        if (status == SQLITE_OK) status = sqlite3_step(statement);
        result = status == (write ? SQLITE_DONE : SQLITE_ROW);
        sqlite3_finalize(statement);
    } @finally { os_unfair_lock_unlock(&markerLock); }
    return result;
}
%group RUINUnsendFetch
%hook NSManagedObjectContext
- (NSArray *)executeFetchRequest:(NSFetchRequest *)request error:(NSError **)error {
    NSManagedObjectContext *context = self;
    fetchDepth++;
    @try {
        atomic_fetch_add(&fetchCalls, 1);
        NSArray *actual = %orig;
        if (fetchDepth != 1 || !Enabled() || actual.count != 1) return actual;
        @try {
            NSString *requested = RequestedMessage(request);
            if (!requested || !InUnsendLookup()) return actual;
            atomic_fetch_add(&scopedLookups, 1);
            NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
            NSDictionary *operation = thread[OperationThreadKey];
            [thread removeObjectForKey:OperationThreadKey];
            id object = actual.firstObject;
            Class messageClass = objc_getClass("ManagedMessage");
            if (!messageClass || ![object isKindOfClass:messageClass] || ![object isKindOfClass:NSManagedObject.class] ||
                ((NSManagedObject *)object).managedObjectContext != context || ((NSManagedObject *)object).isDeleted) {
                atomic_fetch_add(&rejectedLookups, 1); return actual;
            }
            NSDictionary *key = RUINHistoryMessageKey(object);
            if (![key[@"kind"] isEqual:@"talk"] || ![key[@"message"] isEqual:requested] ||
                ![operation[@"message"] isEqual:requested] || ![operation[@"chat"] isEqual:key[@"chat"]]) {
                atomic_fetch_add(&rejectedLookups, 1); return actual;
            }
            if (!RetainedMarker(key, YES)) { atomic_fetch_add(&markerFailures, 1); return actual; }
            // Freeze any earlier archive. A missing archive is never fabricated;
            // native original text is preserved by bypassing this local destroy.
            @try {
                RUINInstallMessageHistory();
                NSDictionary *snapshot = RUINHistoryRetainUnsentSnapshotForKey(key);
                if (snapshot.count && ![snapshot[@"originalUnavailable"] boolValue]) atomic_fetch_add(&historyFreezes, 1);
            } @catch (__unused NSException *exception) { atomic_fetch_add(&observationErrors, 1); }
            atomic_fetch_add(&protectedMessages, 1);
            return @[];
        } @catch (__unused NSException *exception) { atomic_fetch_add(&observationErrors, 1); }
        return actual;
    } @finally { fetchDepth--; }

}
%end
%end
%group RUINUnsendDisplay
%hook RUINUnsendDisplayedMessage
- (id)displayedText {
    id object = self;
    BOOL outermost = displayDepth++ == 0;
    @try {
        id actual = %orig;
        if (!outermost || !Enabled() || ![object isKindOfClass:NSManagedObject.class]) return actual;
        @try {
            NSManagedObject *message = object;
            NSManagedObjectContext *context = message.managedObjectContext;
            if (!context) return actual;
            __block NSString *text;
            [context performBlockAndWait:^{
                NSDictionary *key = RUINHistoryMessageKey(message);
                if (!key.count || !RetainedMarker(key, NO) || message.entity.attributesByName[@"contentType"].attributeType != NSInteger16AttributeType ||
                    [[message valueForKey:@"contentType"] shortValue] != 0) return;
                Method getter = class_getInstanceMethod(object_getClass(message), sel_registerName("plaintext"));
                if (!getter || strcmp(method_getTypeEncoding(getter), "@16@0:8")) return;
                id value = [(id<RUINMessagingMessageFields>)message plaintext];
                if ([value isKindOfClass:NSString.class] && [value length]) text = [value copy];
            }];
            if (text) { atomic_fetch_add(&displayReturns, 1); return [text stringByAppendingString:@"\n取消済"]; }
        } @catch (__unused NSException *exception) { atomic_fetch_add(&observationErrors, 1); }
        return actual;
    } @finally { displayDepth--; }

}
%end
%end
static void Install(Class cls, const char *name, const char *encoding, atomic_int *status, void (^initialize)(Class)) {
    if (atomic_load(status) == 3) return;
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName(name)) : NULL;
    if (!method || strcmp(method_getTypeEncoding(method), encoding) || !method_getImplementation(method)) {
        atomic_store(status, 2); return;
    }
    initialize(cls);
    atomic_store(status, 3);
}
void RUINInstallUnsendOperation(void) {
    os_unfair_lock_lock(&installLock);
    @try {
        BOOL valid = TargetMatches() && VerifyCode(); atomic_store(&codeVerified, valid);
        if (!valid) {
            if (atomic_load(&fetchStatus) != 3) atomic_store(&fetchStatus, 1);
            if (atomic_load(&displayStatus) != 3) atomic_store(&displayStatus, 1);
            if (atomic_load(&param1Status) != 3) atomic_store(&param1Status, 1);
            return;
        }
        Install(NSManagedObjectContext.class, "executeFetchRequest:error:", "@32@0:8@16^@24", &fetchStatus, ^(__unused Class cls) { %init(RUINUnsendFetch); });
        Install(objc_getClass("ManagedMessage"), "displayedText", "@16@0:8", &displayStatus, ^(Class cls) { %init(RUINUnsendDisplay, RUINUnsendDisplayedMessage = cls); });
        Install(objc_getClass("LineOperation"), "param1", "@16@0:8", &param1Status, ^(Class cls) { %init(RUINUnsendParam1, RUINUnsendParsedOperation = cls); });
    } @finally { os_unfair_lock_unlock(&installLock); }
}
__attribute__((constructor)) static void EarlyUnsendOperation(void) { @autoreleasepool { RUINInstallUnsendOperation(); } }
BOOL RUINClearUnsendOperationMarkers(void) {
    os_unfair_lock_lock(&markerLock);
    @try {
        NSURL *url = MarkerURL();
        if (!url) return NO;
        if (!markerDatabase && ![NSFileManager.defaultManager fileExistsAtPath:url.path]) return YES;
        if (!OpenMarkers(NO)) return NO;
        return sqlite3_exec(markerDatabase, "DELETE FROM retained", NULL, NULL, NULL) == SQLITE_OK;
    } @finally { os_unfair_lock_unlock(&markerLock); }
}
BOOL RUINUnsendOperationHasRetainedMarker(NSDictionary *messageKey) {
    if (!Enabled() || ![messageKey isKindOfClass:NSDictionary.class]) return NO;
    @try {
        NSMutableArray<NSString *> *values = [NSMutableArray array];
        for (NSString *field in @[@"store", @"kind", @"chat"]) {
            id value = messageKey[field];
            if (![value isKindOfClass:NSString.class] || ![value length]) return NO;
            NSString *copy = [value copy];
            NSData *bytes = [copy dataUsingEncoding:NSUTF8StringEncoding];
            if (!bytes || bytes.length > INT_MAX) return NO;
            for (NSUInteger i = 0; i < copy.length; i++) if (![copy characterAtIndex:i]) return NO;
            [values addObject:copy];
        }
        NSString *message = MessageID(messageKey[@"message"]);
        if (!message || ![values[1] isEqual:@"talk"]) return NO;
        [values addObject:message];
        os_unfair_lock_lock(&markerLock);
        @try {
            sqlite3 *database = markerDatabase, *readOnly = NULL;
            if (!database) {
                NSURL *url = MarkerURL();
                if (!url || sqlite3_open_v2(url.fileSystemRepresentation, &readOnly, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
                    if (readOnly) sqlite3_close_v2(readOnly);
                    return NO;
                }
                sqlite3_busy_timeout(readOnly, 30); database = readOnly;
            }
            sqlite3_stmt *statement = NULL;
            int status = sqlite3_prepare_v2(database, "SELECT 1 FROM retained WHERE store=? AND kind=? AND chat=? AND message=?", -1, &statement, NULL);
            for (NSUInteger i = 0; status == SQLITE_OK && i < values.count; i++) {
                NSData *bytes = [values[i] dataUsingEncoding:NSUTF8StringEncoding];
                status = sqlite3_bind_text(statement, (int)i + 1, bytes.bytes ?: "", (int)bytes.length, SQLITE_TRANSIENT);
            }
            if (status == SQLITE_OK) status = sqlite3_step(statement);
            sqlite3_finalize(statement);
            if (readOnly) sqlite3_close_v2(readOnly);
            return status == SQLITE_ROW;
        } @finally { os_unfair_lock_unlock(&markerLock); }
    } @catch (__unused NSException *exception) { return NO; }
}
NSDictionary *RUINUnsendOperationDiagnostics(void) {
    long long count = 0;
    os_unfair_lock_lock(&markerLock);
    @try {
        sqlite3_stmt *statement = NULL;
        if (markerDatabase && sqlite3_prepare_v2(markerDatabase, "SELECT count(*) FROM retained", -1, &statement, NULL) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW)
            count = sqlite3_column_int64(statement, 0);
        sqlite3_finalize(statement);
    } @finally { os_unfair_lock_unlock(&markerLock); }
    NSArray *statuses = @[@"pending", @"gated", @"missing_or_encoding_mismatch", @"installed"];
    return @{@"enabled":@(Enabled()), @"targetSupported":@(TargetMatches()), @"nativeCodeVerified":@(atomic_load(&codeVerified)),
        @"codeAnchorCount":@(sizeof(anchors) / sizeof(anchors[0])),
        @"fetchHook":statuses[atomic_load(&fetchStatus)], @"fetchEncoding":@"@32@0:8@16^@24",
        @"displayHook":statuses[atomic_load(&displayStatus)], @"displayEncoding":@"@16@0:8",
        @"operationParam1Hook":statuses[atomic_load(&param1Status)], @"operationParam1Encoding":@"@16@0:8",
        @"capturedOperations":@(atomic_load(&capturedOperations)), @"rejectedOperations":@(atomic_load(&rejectedOperations)),
        @"fetchCalls":@(atomic_load(&fetchCalls)), @"scopedLookups":@(atomic_load(&scopedLookups)),
        @"protectedMessages":@(atomic_load(&protectedMessages)), @"rejectedLookups":@(atomic_load(&rejectedLookups)),
        @"markerFailures":@(atomic_load(&markerFailures)), @"historyFreezes":@(atomic_load(&historyFreezes)),
        @"displayReplacementReturns":@(atomic_load(&displayReturns)), @"inspectionErrors":@(atomic_load(&observationErrors)), @"markerCount":@(count),
        @"operationMapping":@"current parser: 64 sender / 65 others; param1 chat, param2 positive message ID, param3 exactly 1 silent",
        @"boundary":@"original fetch once; exact five-frame server destroy-operation lookup for types 64/65 alone receives empty result before local cleanup/delete/tombstone",
        @"identity":@"native parser param1/param2 copied on its callback thread, consumed once at exact lookup; permanent result must match operation chat+ID and predicate ID; marker binds actual store/kind/chat/message",
        @"nativeABIPatched":@NO, @"deleteObjectGloballySuppressed":@NO, @"deviceRetentionVerified":@NO,
        @"limitations":@"server destroy route only; normal own text was verified separately on device; full-route parity is not inferred. Other routes, OpenChat and media bytes still need validation"};
}
