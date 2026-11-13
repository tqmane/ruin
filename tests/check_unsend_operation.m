// Compile this file (it includes the actual adapter with private host seams):
// xcrun --sdk macosx clang -fobjc-arc -fblocks -std=gnu11 -Wall -Wextra -Werror \
//   -I. src/core/Features.m src/messaging/MessageHistory.m tests/check_unsend_operation.m \
//   -framework Foundation -framework CoreData -lsqlite3 -o /tmp/ruin-check-unsend-operation
// /tmp/ruin-check-unsend-operation
#define RUIN_UNSEND_OPERATION_HOST_CHECK 1
#import "UnsendOperation.m"
#import <stdio.h>

static NSDictionary *fixtureInfo;
static NSURL *fixtureSupport;
static IMP originalInfo, originalDirectories, systemFetch;
static atomic_uint_fast64_t fixtureFetchCalls, fixtureDisplayCalls, outerCallbacks, actualDeletes;
static NSException *fixtureFetchException;
static id fixtureFetchOverride;
static const uintptr_t *fixtureScopePCs;
static size_t fixtureScopePCCount;
static void Check(BOOL condition, NSString *reason) {
    if (!condition) @throw [NSException exceptionWithName:@"RUINUnsendOperationCheck" reason:reason userInfo:nil];
}
static NSDictionary *FixtureInfo(id self, SEL selector) { (void)self; (void)selector; return fixtureInfo; }
static NSArray *FixtureDirectories(id self, SEL selector, NSSearchPathDirectory directory, NSSearchPathDomainMask mask) {
    if (directory == NSApplicationSupportDirectory && mask == NSUserDomainMask) return @[fixtureSupport];
    return ((id (*)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask))originalDirectories)(self, selector, directory, mask);
}
static id FixtureFetch(id self, SEL selector, id request, NSError **error) {
    atomic_fetch_add(&fixtureFetchCalls, 1);
    if (fixtureFetchException) @throw fixtureFetchException;
    id actual = ((id (*)(id, SEL, id, NSError **))systemFetch)(self, selector, request, error);
    return fixtureFetchOverride ?: actual;
}
@interface RUINOperationMessageBase : NSManagedObject
- (id)displayedText;
- (id)plaintext;
- (id)chatObject;
@end
@implementation RUINOperationMessageBase
- (id)plaintext { return [self valueForKey:@"text"]; }
- (id)displayedText { atomic_fetch_add(&fixtureDisplayCalls, 1); return [self plaintext]; }
- (id)chatObject { return [self valueForKey:@"chat"]; }
@end
@interface ManagedMessage : RUINOperationMessageBase @end
@implementation ManagedMessage @end
@interface LineOperation : NSObject
@property (nonatomic) long long type;
@property (nonatomic, copy) NSString *param1;
@property (nonatomic, copy) NSString *param2;
@property (nonatomic, copy) NSString *param3;
@end
@implementation LineOperation @end
static void CaptureOperation(NSString *chat, NSString *message, long long type) {
    LineOperation *operation = [LineOperation new]; operation.type = type;
    operation.param1 = chat; operation.param2 = message; operation.param3 = @"0";
    uintptr_t previous = testParam1Caller;
    testParam1Caller = selectedUnsendMapping ? selectedUnsendMapping->parserParam1ReturnAddress : 0;
    @try { Check([[operation param1] isEqual:chat], @"operation getter return was changed"); }
    @finally { testParam1Caller = previous; }
}
static void CheckVersionMappings(void) {
    NSDictionary *info16 = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
    NSDictionary *info17 = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"};
    NSDictionary *unknown = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.99.0", @"CFBundleVersion":@"unknown"};
    const RUINVersionMapping *version16 = RUINMappingForInfo(info16);
    const RUINVersionMapping *version17 = RUINMappingForInfo(info17);
    const RUINMessagingMapping *map16 = version16 ? &version16->messaging : NULL;
    const RUINMessagingMapping *map17 = version17 ? &version17->messaging : NULL;
    Check(map16 && map16->unsendOperation.parserParam1ReturnAddress &&
        map16->unsendOperation.orderedLookupReturnAddressCount == 5, @"26.16 unsend mapping was not preserved");
    Check(map17 && map17->readBoundary.status == RUINMappingStatusUnsupported &&
        map17->unsendOperation.parserParam1ReturnAddress && map17->unsendOperation.parserAnchorCount &&
        map17->unsendOperation.lookupStatus == RUINMappingStatusVerified &&
        map17->unsendOperation.orderedLookupReturnAddressCount == 6, @"26.17 verified lookup chain missing");
    Check(!RUINMappingForInfo(unknown), @"unknown host acquired a numeric messaging mapping");
}
static NSAttributeDescription *Attribute(NSString *name, NSAttributeType type) {
    NSAttributeDescription *a = [NSAttributeDescription new]; a.name = name; a.attributeType = type; a.optional = YES; return a;
}
static NSManagedObjectModel *Model(void) {
    NSEntityDescription *chat = [NSEntityDescription new], *message = [NSEntityDescription new];
    chat.name = @"Chat"; chat.managedObjectClassName = @"NSManagedObject"; chat.properties = @[Attribute(@"mid", NSStringAttributeType)];
    NSRelationshipDescription *relationship = [NSRelationshipDescription new];
    relationship.name = @"chat"; relationship.destinationEntity = chat; relationship.maxCount = 1; relationship.optional = YES;
    message.name = @"Message"; message.managedObjectClassName = @"ManagedMessage";
    message.properties = @[Attribute(@"id", NSStringAttributeType), Attribute(@"text", NSStringAttributeType),
        Attribute(@"timestamp", NSInteger64AttributeType), Attribute(@"contentType", NSInteger16AttributeType), relationship];
    NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[chat, message]; return model;
}
static ManagedMessage *Insert(NSManagedObjectContext *context, NSString *identifier, NSString *chatID, NSString *text) {
    NSManagedObject *chat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat" inManagedObjectContext:context];
    [chat setValue:chatID forKey:@"mid"];
    ManagedMessage *message = [NSEntityDescription insertNewObjectForEntityForName:@"Message" inManagedObjectContext:context];
    [message setValue:identifier forKey:@"id"]; [message setValue:chat forKey:@"chat"];
    [message setValue:text forKey:@"text"]; [message setValue:@0 forKey:@"contentType"]; [message setValue:@1 forKey:@"timestamp"];
    Check([context save:NULL], @"fixture save failed"); return message;
}
static NSFetchRequest *Request(NSString *identifier) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Message"];
    request.predicate = [NSPredicate predicateWithFormat:@"id = %@", identifier]; return request;
}
static void WithScope(const uintptr_t *pcs, size_t count, void (^body)(void)) {
    const uintptr_t *previous = testPCs; size_t previousCount = testPCCount;
    testPCs = pcs; testPCCount = count;
    @try { body(); } @finally { testPCs = previous; testPCCount = previousCount; }
}
// Native control-flow fixture: nil/empty lookup skips local destruction only;
// the enclosing callback still completes. Real Core Data performs every fetch
// and deletion; only the caller PC capture/image check are injected on macOS.
static void Destroy(NSManagedObjectContext *context, NSFetchRequest *request) {
    @try {
        uint_fast64_t before = atomic_load(&fixtureFetchCalls);
        NSArray *objects = [context executeFetchRequest:request error:NULL];
        Check(atomic_load(&fixtureFetchCalls) == before + 1, @"original fetch was omitted or called twice");
        for (NSManagedObject *object in objects) { [context deleteObject:object]; atomic_fetch_add(&actualDeletes, 1); }
    } @finally { atomic_fetch_add(&outerCallbacks, 1); }
}
int main(void) {
    @autoreleasepool {
        int result = 0;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id oldKeep = [defaults objectForKey:RUINKeepUnsentMessagesKey], oldReaders = [defaults objectForKey:RUINTrackReadUsersKey];
        Method infoMethod = class_getInstanceMethod(NSBundle.class, @selector(infoDictionary));
        Method directoriesMethod = class_getInstanceMethod(NSFileManager.class, @selector(URLsForDirectory:inDomains:));
        Method fetchMethod = class_getInstanceMethod(NSManagedObjectContext.class, @selector(executeFetchRequest:error:));
        fixtureSupport = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        __block NSManagedObjectContext *a, *b;
        NSPersistentStoreCoordinator *first, *second;
        @try {
            CheckVersionMappings();
            originalInfo = method_setImplementation(infoMethod, (IMP)FixtureInfo);
            originalDirectories = method_setImplementation(directoriesMethod, (IMP)FixtureDirectories);
            systemFetch = method_setImplementation(fetchMethod, (IMP)FixtureFetch);
            [defaults removeObjectForKey:RUINKeepUnsentMessagesKey]; [defaults setBool:NO forKey:RUINTrackReadUsersKey];
            fixtureInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
            testImageMatches = NO; RUINInstallUnsendOperation();
            Check(![RUINUnsendOperationDiagnostics()[@"nativeCodeVerified"] boolValue] &&
                ![RUINUnsendOperationDiagnostics()[@"fetchHook"] isEqual:@"installed"], @"image mismatch installed protection");
            IMP inherited = class_getMethodImplementation(RUINOperationMessageBase.class, @selector(displayedText));
            testImageMatches = YES; RUINInstallUnsendOperation(); RUINInstallUnsendOperation();
            Check(selectedUnsendMapping && activeUnsendMapping, @"verified 26.16 mapping was not activated");
            fixtureScopePCs = activeUnsendMapping->orderedLookupReturnAddresses;
            fixtureScopePCCount = activeUnsendMapping->orderedLookupReturnAddressCount;
            Check([RUINUnsendOperationDiagnostics()[@"fetchHook"] isEqual:@"installed"] &&
                [RUINUnsendOperationDiagnostics()[@"displayHook"] isEqual:@"installed"] &&
                [RUINUnsendOperationDiagnostics()[@"operationParam1Hook"] isEqual:@"installed"] &&
                class_getMethodImplementation(RUINOperationMessageBase.class, @selector(displayedText)) == inherited,
                @"hook missing/repeated installation corrupted inherited getter");
            NSManagedObjectModel *model = Model();
            Check([NSFileManager.defaultManager createDirectoryAtURL:fixtureSupport withIntermediateDirectories:YES attributes:nil error:NULL], @"fixture directory creation failed");
            first = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
            second = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
            Check([first addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[fixtureSupport URLByAppendingPathComponent:@"first.sqlite"] options:nil error:NULL] != nil &&
                [second addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[fixtureSupport URLByAppendingPathComponent:@"second.sqlite"] options:nil error:NULL] != nil, @"fixture store creation failed");
            a = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType]; a.persistentStoreCoordinator = first;
            b = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType]; b.persistentStoreCoordinator = second;
            __block ManagedMessage *off, *retained, *sameIDOtherChat, *sameIDOtherStore, *manual, *missingScope, *media;
            [a performBlockAndWait:^{
                off = Insert(a, @"11", @"off-chat", @"RUIN TEST default off");
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{ Destroy(a, Request(@"11")); });
                Check(off.isDeleted && ![RUINUnsendOperationDiagnostics()[@"protectedMessages"] unsignedLongLongValue], @"default OFF prevented native deletion");
                Check([a save:NULL], @"disabled deletion save failed");
            }];
            [defaults setBool:YES forKey:RUINKeepUnsentMessagesKey]; RUINInstallMessageHistory();
            [a performBlockAndWait:^{
                retained = Insert(a, @"9007199254740993", @"private-chat-sentinel", @"RUIN TEST private-original-sentinel");
                manual = Insert(a, @"12", @"manual-chat", @"RUIN TEST manual");
                missingScope = Insert(a, @"13", @"other-chat", @"RUIN TEST incomplete scope");
                media = Insert(a, @"14", @"media-chat", @"native media caption"); [media setValue:@1 forKey:@"contentType"];
                Check([a save:NULL], @"media fixture save failed");
            }];
            [b performBlockAndWait:^{
                sameIDOtherStore = Insert(b, @"9007199254740993", @"private-chat-sentinel", @"RUIN TEST other store");
                sameIDOtherChat = Insert(b, @"9007199254740993", @"different-chat", @"RUIN TEST other chat");
            }];
            [a performBlockAndWait:^{
                uint_fast64_t callbacks = atomic_load(&outerCallbacks), deletes = atomic_load(&actualDeletes);
                CaptureOperation(@"private-chat-sentinel", @"9007199254740993", 65);
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{ Destroy(a, Request(@"9007199254740993")); });
                Check(!retained.isDeleted && [[retained plaintext] isEqual:@"RUIN TEST private-original-sentinel"] &&
                    atomic_load(&outerCallbacks) == callbacks + 1 && atomic_load(&actualDeletes) == deletes, @"confirmed local unsend lost body or enclosing callback");
                uint_fast64_t displays = atomic_load(&fixtureDisplayCalls);
                Check([[retained displayedText] isEqual:@"RUIN TEST private-original-sentinel\n取消済"] &&
                    atomic_load(&fixtureDisplayCalls) == displays + 1, @"retained display missing or original getter called twice");
                Check([[retained valueForKey:@"text"] isEqual:@"RUIN TEST private-original-sentinel"] &&
                    [[retained valueForKey:@"contentType"] shortValue] == 0, @"retention mutated native text/type");
                Check([a executeFetchRequest:Request(@"9007199254740993") error:NULL].count == 1, @"ordinary lookup was hidden by a persistent marker");
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{
                    Check([a executeFetchRequest:Request(@"9007199254740993") error:NULL].count == 1, @"consumed parser identity authorized another lookup");
                });
                CaptureOperation(@"wrong-chat", @"9007199254740993", 65);
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{
                    Check([a executeFetchRequest:Request(@"9007199254740993") error:NULL].count == 1, @"unsend identity crossed chat binding");
                });
                CaptureOperation(@"private-chat-sentinel", @"9007199254740993", 55);
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{
                    Check([a executeFetchRequest:Request(@"9007199254740993") error:NULL].count == 1, @"non-unsend operation authorized retention");
                });
                uint64_t generationBeforeDuplicate = RUINUnsendOperationGeneration();
                CaptureOperation(@"private-chat-sentinel", @"9007199254740993", 65);
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{ Destroy(a, Request(@"9007199254740993")); });
                Check([RUINUnsendOperationDiagnostics()[@"markerCount"] unsignedIntegerValue] == 1, @"duplicate operation duplicated marker");
                Check(RUINUnsendOperationGeneration() >= generationBeforeDuplicate, @"marker generation regressed");
                WithScope(fixtureScopePCs, 3, ^{ Destroy(a, Request(@"13")); });
                Check(missingScope.isDeleted, @"partial call chain suppressed unrelated delete");
                [a deleteObject:manual]; Check(manual.isDeleted, @"manual user deletion was suppressed");
                uint64_t generationBeforeMedia = RUINUnsendOperationGeneration();
                CaptureOperation(@"media-chat", @"14", 64);
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{ Destroy(a, Request(@"14")); });
                Check(RUINUnsendOperationGeneration() > generationBeforeMedia, @"new retained marker did not bump generation");
                Check(!media.isDeleted && [[media displayedText] isEqual:@"native media caption"], @"media model was deleted or fabricated as plaintext");
                Check([a save:NULL], @"post-operation save failed");
            }];
            [b performBlockAndWait:^{
                Check([[sameIDOtherStore displayedText] isEqual:@"RUIN TEST other store"] &&
                    [[sameIDOtherChat displayedText] isEqual:@"RUIN TEST other chat"], @"marker crossed store/chat identity");
            }];
            // A valid caller chain is insufficient when the actual returned ID
            // differs from the requested ID. Original fetch still executes once.
            [a performBlockAndWait:^{
                fixtureFetchOverride = @[retained];
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{
                    Check([a executeFetchRequest:Request(@"999") error:NULL].firstObject == retained, @"mismatched identity was hidden");
                    NSFetchRequest *broad = [NSFetchRequest fetchRequestWithEntityName:@"Message"];
                    Check([a executeFetchRequest:broad error:NULL].firstObject == retained, @"broad query was hidden");
                    NSMutableString *badID = [@"9007199254740993" mutableCopy];
                    [badID appendString:[NSString stringWithCharacters:(unichar[]){0, '2'} length:2]];
                    NSFetchRequest *malformed = Request(badID);
                    Check([a executeFetchRequest:malformed error:NULL].firstObject == retained, @"embedded-NUL ID was truncated into a match");
                });
                fixtureFetchOverride = nil;
                CaptureOperation(@"private-chat-sentinel", @"9007199254740993", 65);
                Check(sqlite3_exec(markerDatabase, "PRAGMA query_only=ON", NULL, NULL, NULL) == SQLITE_OK, @"marker failure fixture failed");
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{
                    Check([a executeFetchRequest:Request(@"9007199254740993") error:NULL].count == 1, @"marker storage failure falsely reported retention");
                });
                Check(sqlite3_exec(markerDatabase, "PRAGMA query_only=OFF", NULL, NULL, NULL) == SQLITE_OK, @"marker write restoration failed");
                fixtureFetchException = [NSException exceptionWithName:@"FixtureFetchFailure" reason:@"expected" userInfo:nil];
                NSException *caught;
                @try { WithScope(fixtureScopePCs, fixtureScopePCCount, ^{ (void)[a executeFetchRequest:Request(@"9007199254740993") error:NULL]; }); }
                @catch (NSException *exception) { caught = exception; }
                Check(caught == fixtureFetchException && fetchDepth == 0, @"original fetch exception swallowed or depth leaked"); fixtureFetchException = nil;
            }];
            os_unfair_lock_lock(&markerLock); sqlite3_close_v2(markerDatabase); markerDatabase = NULL; os_unfair_lock_unlock(&markerLock);
            [a performBlockAndWait:^{ Check([[retained displayedText] hasSuffix:@"\n取消済"], @"marker did not persist across reopen"); }];
            [defaults setBool:NO forKey:RUINKeepUnsentMessagesKey];
            [a performBlockAndWait:^{
                Check([[retained displayedText] isEqual:@"RUIN TEST private-original-sentinel"], @"disabling did not restore original display");
                CaptureOperation(@"private-chat-sentinel", @"9007199254740993", 65);
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{
                    Check([a executeFetchRequest:Request(@"9007199254740993") error:NULL].count == 1, @"disabled retention did not restore native lookup");
                });
            }];
            [defaults setBool:YES forKey:RUINKeepUnsentMessagesKey];
            fixtureInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"unsupported"};
            [a performBlockAndWait:^{
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{ Check([a executeFetchRequest:Request(@"9007199254740993") error:NULL].count == 1, @"unsupported build did not fail open"); });
            }];
            fixtureInfo = @{@"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718"};
            testImageMatches = NO; RUINInstallUnsendOperation();
            [a performBlockAndWait:^{ WithScope(fixtureScopePCs, fixtureScopePCCount, ^{
                Check([a executeFetchRequest:Request(@"9007199254740993") error:NULL].count == 1, @"loaded-code mismatch did not fail open");
            }); }];
            testImageMatches = YES; RUINInstallUnsendOperation();
            fixtureInfo = @{ @"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841" };
            RUINInstallUnsendOperation();
            Check([RUINUnsendOperationDiagnostics()[@"nativeCodeVerified"] boolValue] &&
                [RUINUnsendOperationDiagnostics()[@"retentionMappingSupported"] boolValue],
                @"26.17 verified lookup mapping did not activate");
            [a performBlockAndWait:^{
                ManagedMessage *current = Insert(a, @"1717", @"current-chat", @"RUIN TEST current host");
                CaptureOperation(@"current-chat", @"1717", 65);
                WithScope(fixtureScopePCs, fixtureScopePCCount, ^{
                    Check([a executeFetchRequest:Request(@"1717") error:NULL].count == 1,
                        @"26.17 accepted the old host's lookup chain");
                });
                CaptureOperation(@"current-chat", @"1717", 65);
                WithScope(activeUnsendMapping->orderedLookupReturnAddresses,
                    activeUnsendMapping->orderedLookupReturnAddressCount, ^{ Destroy(a, Request(@"1717")); });
                Check(!current.isDeleted && [[current displayedText] hasSuffix:@"\n取消済"],
                    @"26.17 native destroy fixture lost retained text");
            }];
            fixtureInfo = @{ @"RUINOriginalBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.16.0", @"CFBundleVersion":@"2026.1006.1718" };
            RUINInstallUnsendOperation();
            Check([RUINUnsendOperationDiagnostics()[@"nativeCodeVerified"] boolValue], @"26.16 mapping did not recover after a gated host");
            uint64_t generationBeforeClear = RUINUnsendOperationGeneration();
            Check(RUINClearUnsendOperationMarkers() && [RUINUnsendOperationDiagnostics()[@"markerCount"] unsignedIntegerValue] == 0, @"marker clear failed");
            Check(RUINUnsendOperationGeneration() > generationBeforeClear, @"marker clear did not bump generation");
            [a performBlockAndWait:^{ Check([[retained displayedText] isEqual:@"RUIN TEST private-original-sentinel"], @"cleared marker still rendered a label"); }];
            NSString *diagnostics = [RUINUnsendOperationDiagnostics() description];
            for (NSString *private in @[@"private-chat-sentinel", @"private-original-sentinel", @"9007199254740993", fixtureSupport.path])
                Check([diagnostics rangeOfString:private].location == NSNotFound, @"diagnostics exposed content/identity/path");
        } @catch (NSException *exception) {
            fprintf(stderr, "RUIN UnsendOperation check failed: %s\n", exception.reason.UTF8String ?: "unknown"); result = 1;
        } @finally {
            if (a) [a performBlockAndWait:^{ [a reset]; }]; if (b) [b performBlockAndWait:^{ [b reset]; }];
            for (NSPersistentStore *store in first.persistentStores) [first removePersistentStore:store error:NULL];
            for (NSPersistentStore *store in second.persistentStores) [second removePersistentStore:store error:NULL];
            if (oldKeep) [defaults setObject:oldKeep forKey:RUINKeepUnsentMessagesKey]; else [defaults removeObjectForKey:RUINKeepUnsentMessagesKey];
            if (oldReaders) [defaults setObject:oldReaders forKey:RUINTrackReadUsersKey]; else [defaults removeObjectForKey:RUINTrackReadUsersKey];
            if (originalInfo) method_setImplementation(infoMethod, originalInfo);
            if (originalDirectories) method_setImplementation(directoriesMethod, originalDirectories);
            if (systemFetch) method_setImplementation(fetchMethod, systemFetch);
            os_unfair_lock_lock(&markerLock); if (markerDatabase) sqlite3_close_v2(markerDatabase); markerDatabase = NULL; os_unfair_lock_unlock(&markerLock);
            [NSFileManager.defaultManager removeItemAtURL:fixtureSupport error:NULL];
        }
        if (!result) puts("RUIN UnsendOperation native host checks passed"); return result;
    }
}
