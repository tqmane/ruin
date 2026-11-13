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
#import <sys/stat.h>

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
static sqlite3 *markerDatabase;
static NSMutableSet<NSArray<NSString *> *> *retainedMarkerSet;
static NSMutableSet<NSString *> *retainedMessageIDs;
static BOOL retainedCacheValid;
static NSString *retainedCachePath;
static dev_t retainedCacheDev;
static ino_t retainedCacheIno;
static struct timespec retainedCacheMtime;
static atomic_bool cachedMarkersReady, cachedHasRetainedMarkers;
static atomic_uint_fast64_t operationMarkerGeneration;
static _Thread_local unsigned int fetchDepth, displayDepth;
#if defined(RUIN_UNSEND_OPERATION_HOST_CHECK) && RUIN_UNSEND_OPERATION_HOST_CHECK
static BOOL testImageMatches;
static _Thread_local const uintptr_t *testPCs;
static _Thread_local size_t testPCCount;
static _Thread_local uintptr_t testParam1Caller;
#endif

static BOOL TargetMatches(void) {
#if defined(RUIN_HOST_CHECK) && RUIN_HOST_CHECK
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
#else
    static BOOL matched;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ matched = RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary); });
    return matched;
#endif
}
static BOOL Enabled(void) {
    if (!atomic_load_explicit(&codeVerified, memory_order_acquire)) return NO;
    if (![NSUserDefaults.standardUserDefaults boolForKey:RUINKeepUnsentMessagesKey]) return NO;
    return TargetMatches();
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
#if defined(RUIN_HOST_CHECK) && RUIN_HOST_CHECK
    NSURL *root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return root ? [root URLByAppendingPathComponent:@"RUIN/unsend-operation.sqlite"] : nil;
#else
    static NSURL *cachedURL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        cachedURL = root ? [[root URLByAppendingPathComponent:@"RUIN/unsend-operation.sqlite"] copy] : nil;
    });
    return cachedURL;
#endif
}
static off_t retainedCacheSize;
static void UpdateRetainedStatLocked(NSURL *url) {
    struct stat st;
    if (url && stat(url.fileSystemRepresentation, &st) == 0) {
        retainedCacheDev = st.st_dev;
        retainedCacheIno = st.st_ino;
        retainedCacheMtime = st.st_mtimespec;
        retainedCacheSize = st.st_size;
    } else {
        retainedCacheDev = 0;
        retainedCacheIno = 0;
        retainedCacheMtime = (struct timespec){0, 0};
        retainedCacheSize = 0;
    }
}
static void PublishRetainedCacheStateLocked(void) {
    atomic_store_explicit(&cachedHasRetainedMarkers, retainedMarkerSet.count > 0, memory_order_release);
    atomic_store_explicit(&cachedMarkersReady, YES, memory_order_release);
}
static void RefreshRetainedIndexLocked(void) {
    NSURL *url = MarkerURL();
    NSString *path = url.path ?: @"";
    if (markerDatabase != NULL && retainedCacheValid && [retainedCachePath isEqualToString:path]) return;
    struct stat st;
    BOOL exists = url && stat(url.fileSystemRepresentation, &st) == 0;
    if (!exists && !markerDatabase) {
        if (!retainedCacheValid || ![retainedCachePath isEqualToString:path] || retainedMarkerSet.count != 0) {
            retainedMarkerSet = [NSMutableSet set];
            retainedMessageIDs = [NSMutableSet set];
            retainedCachePath = [path copy];
            retainedCacheDev = 0; retainedCacheIno = 0;
            retainedCacheMtime = (struct timespec){0, 0};
            retainedCacheSize = 0;
            retainedCacheValid = YES;
        }
        PublishRetainedCacheStateLocked();
        return;
    }
    if (!markerDatabase && retainedCacheValid && [retainedCachePath isEqualToString:path] &&
        retainedCacheDev == st.st_dev && retainedCacheIno == st.st_ino &&
        retainedCacheMtime.tv_sec == st.st_mtimespec.tv_sec &&
        retainedCacheMtime.tv_nsec == st.st_mtimespec.tv_nsec &&
        retainedCacheSize == st.st_size) {
        PublishRetainedCacheStateLocked();
        return;
    }
    sqlite3 *database = markerDatabase, *readOnly = NULL;
    if (!database && url) {
        if (sqlite3_open_v2(url.fileSystemRepresentation, &readOnly, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
            if (readOnly) sqlite3_close_v2(readOnly);
            return;
        }
        sqlite3_busy_timeout(readOnly, 30);
        database = readOnly;
    }
    NSMutableSet<NSArray<NSString *> *> *loadedKeys = [NSMutableSet set];
    NSMutableSet<NSString *> *loadedIDs = [NSMutableSet set];
    BOOL queryOK = NO;
    sqlite3_stmt *statement = NULL;
    if (database && sqlite3_prepare_v2(database, "SELECT store,kind,chat,message FROM retained", -1, &statement, NULL) == SQLITE_OK) {
        int stepStatus = SQLITE_OK;
        while ((stepStatus = sqlite3_step(statement)) == SQLITE_ROW) {
            const char *s = (const char *)sqlite3_column_text(statement, 0);
            const char *k = (const char *)sqlite3_column_text(statement, 1);
            const char *c = (const char *)sqlite3_column_text(statement, 2);
            const char *m = (const char *)sqlite3_column_text(statement, 3);
            if (!s || !k || !c || !m) continue;
            NSString *store = [NSString stringWithUTF8String:s];
            NSString *kind = [NSString stringWithUTF8String:k];
            NSString *chat = [NSString stringWithUTF8String:c];
            NSString *msg = [NSString stringWithUTF8String:m];
            if (store && kind && chat && msg) {
                [loadedKeys addObject:@[store, kind, chat, msg]];
                [loadedIDs addObject:msg];
            }
        }
        queryOK = (stepStatus == SQLITE_DONE);
    }
    sqlite3_finalize(statement);
    if (readOnly) sqlite3_close_v2(readOnly);
    retainedMarkerSet = loadedKeys;
    retainedMessageIDs = loadedIDs;
    retainedCachePath = [path copy];
    if (exists) {
        retainedCacheDev = st.st_dev; retainedCacheIno = st.st_ino;
        retainedCacheMtime = st.st_mtimespec; retainedCacheSize = st.st_size;
    } else {
        UpdateRetainedStatLocked(url);
    }
    retainedCacheValid = queryOK || !exists;
    PublishRetainedCacheStateLocked();
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
        if (!write) {
            RefreshRetainedIndexLocked();
            if (!retainedMarkerSet.count) return NO;
            NSString *store = key[@"store"], *kind = key[@"kind"], *chat = key[@"chat"], *msg = key[@"message"];
            if (!store || !kind || !chat || !msg) return NO;
            return [retainedMarkerSet containsObject:@[store, kind, chat, msg]];
        }
        if (!OpenMarkers(YES)) return NO;
        RefreshRetainedIndexLocked();
        sqlite3_stmt *statement = NULL;
        int status = sqlite3_prepare_v2(markerDatabase, "INSERT OR IGNORE INTO retained VALUES(?,?,?,?)", -1, &statement, NULL);
        for (NSUInteger i = 0; status == SQLITE_OK && i < 4; i++) {
            NSData *data = [key[@[@"store", @"kind", @"chat", @"message"][i]] dataUsingEncoding:NSUTF8StringEncoding];
            status = data && data.length <= INT_MAX ? sqlite3_bind_text(statement, (int)i + 1, data.bytes ?: "", (int)data.length, SQLITE_TRANSIENT) : SQLITE_MISMATCH;
        }
        if (status == SQLITE_OK) status = sqlite3_step(statement);
        result = status == SQLITE_DONE;
        if (result) {
            int changes = sqlite3_changes(markerDatabase);
            NSString *store = [key[@"store"] copy], *kind = [key[@"kind"] copy], *chat = [key[@"chat"] copy], *msg = [key[@"message"] copy];
            if (store && kind && chat && msg) {
                if (!retainedMarkerSet) retainedMarkerSet = [NSMutableSet set];
                if (!retainedMessageIDs) retainedMessageIDs = [NSMutableSet set];
                [retainedMarkerSet addObject:@[store, kind, chat, msg]];
                [retainedMessageIDs addObject:msg];
            }
            retainedCacheValid = YES;
            UpdateRetainedStatLocked(MarkerURL());
            PublishRetainedCacheStateLocked();
            if (changes > 0) atomic_fetch_add_explicit(&operationMarkerGeneration, 1, memory_order_release);
        }
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
        if (fetchDepth != 1 || actual.count != 1 || !Enabled()) return actual;
        @try {
            NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
            NSDictionary *operation = thread[OperationThreadKey];
            if (!operation) return actual;
            NSString *requested = RequestedMessage(request);
            if (!requested || !InUnsendLookup()) return actual;
            atomic_fetch_add(&scopedLookups, 1);
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
            if (!atomic_load_explicit(&cachedMarkersReady, memory_order_acquire)) {
                os_unfair_lock_lock(&markerLock);
                @try { RefreshRetainedIndexLocked(); }
                @finally { os_unfair_lock_unlock(&markerLock); }
            }
            if (!atomic_load_explicit(&cachedHasRetainedMarkers, memory_order_acquire)) return actual;
            NSManagedObject *message = object;
            NSManagedObjectContext *context = message.managedObjectContext;
            if (!context) return actual;
            __block NSString *text;
            [context performBlockAndWait:^{
                if (message.entity.attributesByName[@"contentType"].attributeType != NSInteger16AttributeType ||
                    [[message valueForKey:@"contentType"] shortValue] != 0) return;
                NSString *rawID = message.entity.attributesByName[@"id"] ? MessageID([message valueForKey:@"id"]) : nil;
                if (!rawID) return;
                BOOL maybeRetained = NO;
                os_unfair_lock_lock(&markerLock);
                @try {
                    RefreshRetainedIndexLocked();
                    maybeRetained = [retainedMessageIDs containsObject:rawID];
                } @finally { os_unfair_lock_unlock(&markerLock); }
                if (!maybeRetained) return;
                NSDictionary *key = RUINHistoryMessageKey(message);
                if (!key.count || !RetainedMarker(key, NO)) return;
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
        BOOL cleared = NO;
        if (!markerDatabase && ![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
            cleared = YES;
        } else if (OpenMarkers(NO)) {
            cleared = sqlite3_exec(markerDatabase, "DELETE FROM retained", NULL, NULL, NULL) == SQLITE_OK;
        }
        if (cleared) {
            retainedMarkerSet = [NSMutableSet set];
            retainedMessageIDs = [NSMutableSet set];
            retainedCachePath = [url.path copy] ?: @"";
            UpdateRetainedStatLocked(url);
            retainedCacheValid = YES;
            PublishRetainedCacheStateLocked();
            atomic_fetch_add_explicit(&operationMarkerGeneration, 1, memory_order_release);
        }
        return cleared;
    } @finally { os_unfair_lock_unlock(&markerLock); }
}
uint64_t RUINUnsendOperationGeneration(void) {
    return (uint64_t)atomic_load_explicit(&operationMarkerGeneration, memory_order_acquire);
}
BOOL RUINUnsendOperationHasRetainedMarker(NSDictionary *messageKey) {
    if (!Enabled() || ![messageKey isKindOfClass:NSDictionary.class]) return NO;
    @try {
        if (!atomic_load_explicit(&cachedMarkersReady, memory_order_acquire)) {
            os_unfair_lock_lock(&markerLock);
            @try { RefreshRetainedIndexLocked(); }
            @finally { os_unfair_lock_unlock(&markerLock); }
        }
#if !defined(RUIN_HOST_CHECK) || !RUIN_HOST_CHECK
        if (!atomic_load_explicit(&cachedHasRetainedMarkers, memory_order_acquire)) return NO;
#endif
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
            RefreshRetainedIndexLocked();
            return [retainedMarkerSet containsObject:values];
        } @finally { os_unfair_lock_unlock(&markerLock); }
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
