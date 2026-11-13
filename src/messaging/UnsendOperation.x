%config(generator=internal);

#import "MessagingPrivateAPI.h"
#import "UnsendOperation.h"
#import "Features.h"
#import "MessageHistory.h"
#import "RetainedMedia.h"
#import "../core/Localization.h"
#import "../core/TargetMetadata.h"
#import "../known/MessagingMappings.h"
#import <CoreData/CoreData.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <mach-o/dyld.h>
#import <execinfo.h>
#import <sqlite3.h>
#import <stdatomic.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>

static _Atomic(uintptr_t) imageSlide;
static atomic_bool codeVerified;
static const RUINUnsendOperationMapping *selectedUnsendMapping;
static const RUINUnsendOperationMapping *activeUnsendMapping;
typedef NS_ENUM(int, OperationHookStatus) {
    OperationHookPending = 0,
    OperationHookGated = 1,
    OperationHookUnavailable = 2,
    OperationHookInstalled = 3
};
static atomic_int fetchStatus, displayStatus, param1Status;
static atomic_uint_fast64_t fetchCalls, scopedLookups, protectedMessages, rejectedLookups, observationErrors;
static atomic_uint_fast64_t markerFailures, historyFreezes, displayReturns;
static atomic_uint_fast64_t capturedOperations, rejectedOperations;
static NSString *const OperationThreadKey = @"RUINUnsendOperation.currentParserIdentity";
static os_unfair_lock installLock = OS_UNFAIR_LOCK_INIT, markerLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock markerCacheLock = OS_UNFAIR_LOCK_INIT;
static sqlite3 *markerDatabase;
static sqlite3 *markerReadDatabase;
static sqlite3_stmt *markerReadStatement;
static NSCache<NSArray<NSString *> *, NSNumber *> *markerLookupCache;
static NSMutableDictionary<NSArray<NSString *> *, NSNumber *> *markerLookupPending;
static dispatch_queue_t markerReadQueue;
static uint64_t markerCacheGeneration;
static _Thread_local unsigned int fetchDepth, displayDepth;
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
static BOOL testImageMatches;
static _Thread_local const uintptr_t *testPCs;
static _Thread_local size_t testPCCount;
static _Thread_local uintptr_t testParam1Caller;
#endif

static BOOL TargetMatches(void) {
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
}
static BOOL Enabled(void) {
    return atomic_load(&codeVerified) && TargetMatches() &&
        [NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey];
}
static BOOL VerifyCode(void) {
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    const RUINVersionMapping *versionMapping = RUINMappingForInfo(info);
#else
    const RUINVersionMapping *versionMapping = RUINCurrentMapping();
#endif
    const RUINMessagingMapping *mapping = versionMapping ? &versionMapping->messaging : NULL;
    selectedUnsendMapping = mapping ? &mapping->unsendOperation : NULL;
    activeUnsendMapping = NULL;
    atomic_store(&imageSlide, 0);
    if (!TargetMatches() || !versionMapping || !selectedUnsendMapping ||
        selectedUnsendMapping->parserStatus != RUINMappingStatusVerified || !selectedUnsendMapping->parserAnchors ||
        !selectedUnsendMapping->parserAnchorCount || !selectedUnsendMapping->parserParam1ReturnAddress) return NO;
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
    atomic_store(&imageSlide, 0);
    if (!testImageMatches || selectedUnsendMapping->lookupStatus != RUINMappingStatusVerified ||
        !selectedUnsendMapping->orderedLookupReturnAddresses ||
        !selectedUnsendMapping->orderedLookupReturnAddressCount) return NO;
    activeUnsendMapping = selectedUnsendMapping;
    return YES;
#else
    RUINMainExecutableImage image;
    if (!RUINResolveMainExecutableImage(&image)) return NO;
    const struct mach_header_64 *header = image.header;
    intptr_t slide = image.slide;
    if (RUINCurrentMapping() != versionMapping ||
        !RUINVerifyInstructions(header, slide, selectedUnsendMapping->parserAnchors,
            selectedUnsendMapping->parserAnchorCount) ||
        selectedUnsendMapping->lookupStatus != RUINMappingStatusVerified ||
        !selectedUnsendMapping->orderedLookupReturnAddresses ||
        !selectedUnsendMapping->orderedLookupReturnAddressCount) return NO;
    atomic_store(&imageSlide, (uintptr_t)slide);
    activeUnsendMapping = selectedUnsendMapping;
    return YES;
#endif
}
static BOOL OrderedScope(const uintptr_t *pcs, size_t count) {
    if (!activeUnsendMapping) return NO;
    size_t matched = 0;
    for (size_t i = 0; i < count && matched < activeUnsendMapping->orderedLookupReturnAddressCount; i++)
        if (pcs[i] == activeUnsendMapping->orderedLookupReturnAddresses[matched]) matched++;
    return matched == activeUnsendMapping->orderedLookupReturnAddressCount;
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
    if (!activeUnsendMapping || caller != activeUnsendMapping->parserParam1ReturnAddress) return actual;
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
static void InitializeMarkerLookup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        markerLookupCache = [NSCache new];
        markerLookupCache.countLimit = 512;
        markerLookupPending = [NSMutableDictionary dictionary];
        markerReadQueue = dispatch_queue_create("com.ruin.unsend-marker-read", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
}
static NSArray<NSString *> *MarkerQueryKey(NSDictionary *messageKey) {
    if (![messageKey isKindOfClass:NSDictionary.class]) return nil;
    NSMutableArray<NSString *> *values = [NSMutableArray arrayWithCapacity:4];
    for (NSString *field in @[@"store", @"kind", @"chat"]) {
        id value = messageKey[field];
        if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
        NSString *copy = [value copy];
        NSData *bytes = [copy dataUsingEncoding:NSUTF8StringEncoding];
        if (!bytes || bytes.length > INT_MAX) return nil;
        for (NSUInteger i = 0; i < copy.length; i++) if (![copy characterAtIndex:i]) return nil;
        [values addObject:copy];
    }
    NSString *message = MessageID(messageKey[@"message"]);
    if (!message || ![values[1] isEqual:@"talk"]) return nil;
    [values addObject:message];
    return [values copy];
}
static NSArray<NSString *> *MarkerStoredKey(NSDictionary *messageKey) {
    NSArray<NSString *> *queryKey = MarkerQueryKey(messageKey);
    return queryKey && [messageKey[@"message"] isEqualToString:queryKey[3]] ? queryKey : nil;
}
static BOOL CachedMarker(NSArray<NSString *> *key, BOOL *retained) {
    InitializeMarkerLookup();
    os_unfair_lock_lock(&markerCacheLock);
    NSNumber *value = [markerLookupCache objectForKey:key];
    if (value) *retained = value.boolValue;
    os_unfair_lock_unlock(&markerCacheLock);
    return value != nil;
}
static void InvalidateMarkerCache(NSArray<NSString *> *writtenKey) {
    InitializeMarkerLookup();
    os_unfair_lock_lock(&markerCacheLock);
    markerCacheGeneration++;
    [markerLookupCache removeAllObjects];
    [markerLookupPending removeAllObjects];
    if (writtenKey) [markerLookupCache setObject:@YES forKey:writtenKey];
    os_unfair_lock_unlock(&markerCacheLock);
}
static int ReadMarkerOnQueue(NSArray<NSString *> *key, BOOL *retained) {
    int result = SQLITE_ERROR;
    os_unfair_lock_lock(&markerLock);
    @try {
        if (!markerReadStatement) {
            NSURL *url = MarkerURL();
            if (!url) return SQLITE_CANTOPEN;
            if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return SQLITE_DONE;
            if (sqlite3_open_v2(url.fileSystemRepresentation, &markerReadDatabase,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
                if (markerReadDatabase) sqlite3_close_v2(markerReadDatabase);
                markerReadDatabase = NULL;
                return SQLITE_ERROR;
            }
            sqlite3_busy_timeout(markerReadDatabase, 30);
            if (sqlite3_prepare_v2(markerReadDatabase,
                    "SELECT 1 FROM retained WHERE store=? AND kind=? AND chat=? AND message=?",
                    -1, &markerReadStatement, NULL) != SQLITE_OK) {
                BOOL uninitialized = strstr(sqlite3_errmsg(markerReadDatabase), "no such table: retained") != NULL;
                sqlite3_close_v2(markerReadDatabase);
                markerReadDatabase = NULL;
                markerReadStatement = NULL;
                return uninitialized ? SQLITE_DONE : SQLITE_ERROR;
            }
        }
        sqlite3_reset(markerReadStatement);
        sqlite3_clear_bindings(markerReadStatement);
        result = SQLITE_OK;
        for (NSUInteger i = 0; result == SQLITE_OK && i < key.count; i++) {
            NSData *bytes = [key[i] dataUsingEncoding:NSUTF8StringEncoding];
            result = bytes && bytes.length <= INT_MAX
                ? sqlite3_bind_text(markerReadStatement, (int)i + 1, bytes.bytes ?: "", (int)bytes.length, SQLITE_TRANSIENT)
                : SQLITE_MISMATCH;
        }
        if (result == SQLITE_OK) result = sqlite3_step(markerReadStatement);
        if (result == SQLITE_ROW) *retained = YES;
        else if (result == SQLITE_DONE) *retained = NO;
        sqlite3_reset(markerReadStatement);
        sqlite3_clear_bindings(markerReadStatement);
    } @finally { os_unfair_lock_unlock(&markerLock); }
    return result;
}
static void ScheduleMarkerRead(NSArray<NSString *> *key) {
    InitializeMarkerLookup();
    uint64_t generation;
    os_unfair_lock_lock(&markerCacheLock);
    if ([markerLookupCache objectForKey:key]) { os_unfair_lock_unlock(&markerCacheLock); return; }
    generation = markerCacheGeneration;
    NSNumber *pendingGeneration = markerLookupPending[key];
    if ((pendingGeneration && pendingGeneration.unsignedLongLongValue == generation) || markerLookupPending.count >= 128) {
        os_unfair_lock_unlock(&markerCacheLock);
        return;
    }
    markerLookupPending[key] = @(generation);
    os_unfair_lock_unlock(&markerCacheLock);
    dispatch_async(markerReadQueue, ^{
        @autoreleasepool {
            BOOL retained = NO;
            int status = ReadMarkerOnQueue(key, &retained);
            BOOL completed = status == SQLITE_ROW || status == SQLITE_DONE;
            os_unfair_lock_lock(&markerCacheLock);
            if ([markerLookupPending[key] unsignedLongLongValue] == generation) [markerLookupPending removeObjectForKey:key];
            if (completed && markerCacheGeneration == generation) [markerLookupCache setObject:@(retained) forKey:key];
            os_unfair_lock_unlock(&markerCacheLock);
#if TARGET_OS_IPHONE
            if (completed && retained) dispatch_async(dispatch_get_main_queue(), ^{
                    [NSNotificationCenter.defaultCenter postNotificationName:RUINRetainedMediaDidChangeNotification object:key];
                });
#endif
        }
    });
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
        if (write && result) InvalidateMarkerCache(MarkerStoredKey(key));
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
#if TARGET_OS_IPHONE
            RUINCaptureRetainedMedia(object, key);
#endif
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
            if (text) { atomic_fetch_add(&displayReturns, 1); return [text stringByAppendingFormat:@"\n%@", RUINLocalizedString(@"取消済")]; }
        } @catch (__unused NSException *exception) { atomic_fetch_add(&observationErrors, 1); }
        return actual;
    } @finally { displayDepth--; }

}
%end
%end
static void InstallOperationHook(Class cls, const char *name, const char *encoding, atomic_int *status, void (^initialize)(Class)) {
    if (atomic_load(status) == OperationHookInstalled) return;
    Method method = cls ? class_getInstanceMethod(cls, sel_registerName(name)) : NULL;
    if (!method || strcmp(method_getTypeEncoding(method), encoding) || !method_getImplementation(method)) {
        atomic_store(status, OperationHookUnavailable);
        return;
    }
    initialize(cls);
    atomic_store(status, OperationHookInstalled);
}
void RUINInstallUnsendOperation(void) {
    os_unfair_lock_lock(&installLock);
    @try {
        BOOL valid = VerifyCode();
        atomic_store(&codeVerified, valid);
        if (!valid) {
            if (atomic_load(&fetchStatus) != OperationHookInstalled) atomic_store(&fetchStatus, OperationHookGated);
            if (atomic_load(&displayStatus) != OperationHookInstalled) atomic_store(&displayStatus, OperationHookGated);
            if (atomic_load(&param1Status) != OperationHookInstalled) atomic_store(&param1Status, OperationHookGated);
            return;
        }
        InstallOperationHook(NSManagedObjectContext.class, "executeFetchRequest:error:", "@32@0:8@16^@24", &fetchStatus, ^(__unused Class cls) {
            %init(RUINUnsendFetch);
        });
        InstallOperationHook(objc_getClass("ManagedMessage"), "displayedText", "@16@0:8", &displayStatus, ^(Class cls) {
            %init(RUINUnsendDisplay, RUINUnsendDisplayedMessage = cls);
        });
        InstallOperationHook(objc_getClass("LineOperation"), "param1", "@16@0:8", &param1Status, ^(Class cls) {
            %init(RUINUnsendParam1, RUINUnsendParsedOperation = cls);
        });
    } @finally { os_unfair_lock_unlock(&installLock); }
}
__attribute__((constructor)) static void EarlyUnsendOperation(void) { @autoreleasepool { RUINInstallUnsendOperation(); } }
BOOL RUINClearUnsendOperationMarkers(void) {
    os_unfair_lock_lock(&markerLock);
    @try {
        NSURL *url = MarkerURL();
        if (!url) return NO;
        if (!markerDatabase && ![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
            InvalidateMarkerCache(nil);
            return YES;
        }
        if (!OpenMarkers(NO)) return NO;
        BOOL cleared = sqlite3_exec(markerDatabase, "DELETE FROM retained", NULL, NULL, NULL) == SQLITE_OK;
        if (cleared) InvalidateMarkerCache(nil);
        return cleared;
    } @finally { os_unfair_lock_unlock(&markerLock); }
}
BOOL RUINUnsendOperationHasRetainedMarker(NSDictionary *messageKey) {
    if (!Enabled() || ![messageKey isKindOfClass:NSDictionary.class]) return NO;
    @try {
        NSArray<NSString *> *key = MarkerQueryKey(messageKey);
        if (!key) return NO;
        BOOL retained = NO;
        if (CachedMarker(key, &retained)) return retained;
        ScheduleMarkerRead(key);
        return NO;
    } @catch (__unused NSException *exception) { return NO; }
}
NSDictionary *RUINUnsendOperationDiagnostics(void) {
    long long count = 0;
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    const RUINVersionMapping *versionMapping = RUINMappingForInfo(info);
#else
    const RUINVersionMapping *versionMapping = RUINCurrentMapping();
#endif
    const RUINMessagingMapping *mapping = versionMapping ? &versionMapping->messaging : NULL;
    const RUINUnsendOperationMapping *operationMapping = mapping ? &mapping->unsendOperation : NULL;
    os_unfair_lock_lock(&markerLock);
    @try {
        sqlite3_stmt *statement = NULL;
        if (markerDatabase && sqlite3_prepare_v2(markerDatabase, "SELECT count(*) FROM retained", -1, &statement, NULL) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW)
            count = sqlite3_column_int64(statement, 0);
        sqlite3_finalize(statement);
    } @finally { os_unfair_lock_unlock(&markerLock); }
    NSArray *statuses = @[@"pending", @"gated", @"missing_or_encoding_mismatch", @"installed"];
    return @{@"enabled":@(Enabled()), @"targetSupported":@(TargetMatches()), @"nativeCodeVerified":@(atomic_load(&codeVerified)),
        @"retentionMappingSupported":@(operationMapping && operationMapping->orderedLookupReturnAddressCount != 0),
        @"lookupScopeVerified":@(activeUnsendMapping != NULL),
        @"codeAnchorCount":@(operationMapping ? operationMapping->parserAnchorCount : 0),
        @"fetchHook":statuses[atomic_load(&fetchStatus)], @"fetchEncoding":@"@32@0:8@16^@24",
        @"displayHook":statuses[atomic_load(&displayStatus)], @"displayEncoding":@"@16@0:8",
        @"operationParam1Hook":statuses[atomic_load(&param1Status)], @"operationParam1Encoding":@"@16@0:8",
        @"capturedOperations":@(atomic_load(&capturedOperations)), @"rejectedOperations":@(atomic_load(&rejectedOperations)),
        @"fetchCalls":@(atomic_load(&fetchCalls)), @"scopedLookups":@(atomic_load(&scopedLookups)),
        @"protectedMessages":@(atomic_load(&protectedMessages)), @"rejectedLookups":@(atomic_load(&rejectedLookups)),
        @"markerFailures":@(atomic_load(&markerFailures)), @"historyFreezes":@(atomic_load(&historyFreezes)),
        @"displayReplacementReturns":@(atomic_load(&displayReturns)), @"inspectionErrors":@(atomic_load(&observationErrors)), @"markerCount":@(count),
        @"operationMapping":@"current parser: 64 sender / 65 others; param1 chat, param2 positive message ID, param3 exactly 1 silent",
        @"boundary":@"original fetch once; verified ordered server destroy-operation lookup for types 64/65 alone receives empty result before local cleanup/delete/tombstone",
        @"identity":@"native parser param1/param2 copied on its callback thread, consumed once at exact lookup; permanent result must match operation chat+ID and predicate ID; marker binds actual store/kind/chat/message",
        @"nativeABIPatched":@NO, @"deleteObjectGloballySuppressed":@NO, @"deviceRetentionVerified":@NO,
        @"limitations":@"server destroy route only; normal own text was verified separately on device; full-route parity is not inferred. Other routes, OpenChat and media bytes still need validation"};
}
