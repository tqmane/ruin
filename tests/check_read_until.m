// Compile ReadUntil.m with RUIN_READ_UNTIL_HOST_CHECK=1. No LINE or network.
#import "ReadUntil.h"
#import "MessageHistory.h"
#import "FeatureImage.h"
#import "VersionMapping.h"
#import <objc/runtime.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>

static Class midClass, chatClass, taskClass;
static NSUInteger calls, validations, latestReads, taskCount;
static BOOL accountMatches = YES, midThrows, midReturnsNil;
static NSError *midError;
static NSString *midOverride;
static NSString *receivedID;
static void (^nativeCompletion)(NSError *);
static __weak id returnedTask;
static _Thread_local NSUInteger ownerQueueDepth;
typedef NS_ENUM(NSInteger, Mode) { Deferred, Sync, Failure, Throw, SyncThenThrow, NilTask, WrongTask };
static Mode mode;

// Substitute bundle/dyld inputs, not identity validation. The real feature-image
// candidate verifier checks these synthetic native and converted class owners.
static NSMutableDictionary *targetInfo;
static char fixtureDirectory[] = "/tmp/ruin-read-until.XXXXXX";
static char bundlePath[PATH_MAX], processPath[PATH_MAX], containerPath[PATH_MAX];
static BOOL ownerMatches = YES, imageAvailable = YES;
static NSUInteger resolutions;
static struct {
    struct mach_header_64 header;
    struct uuid_command uuid;
    struct { struct dylib_command command; char name[8]; } identifier;
    struct segment_command_64 text;
} fixtureImage, otherImage;
static BOOL useOtherImage;

NSDictionary *RUINReadUntilInfoForTesting(void) { return targetInfo; }
BOOL RUINReadUntilResolveImageForTesting(const RUINHostIdentity *host,
    Class owner, RUINFeatureImage *image) {
    resolutions++;
    assert(owner == objc_getClass("_TtC13LineMessaging11ChatService"));
    if (!imageAvailable) return NO;
    const struct mach_header_64 *header = useOtherImage ? &otherImage.header : &fixtureImage.header;
    RUINDyldImageCandidate candidate = {header, 0, bundlePath};
    return RUINResolveFeatureImageFromCandidates(host, bundlePath, processPath,
        ownerMatches ? bundlePath : containerPath, header, &candidate, 1, image);
}

static void MakeImageFixture(BOOL native) {
    assert(mkdtemp(fixtureDirectory));
    snprintf(bundlePath, sizeof(bundlePath), "%s/LINE", fixtureDirectory);
    snprintf(containerPath, sizeof(containerPath), "%s/Container", fixtureDirectory);
    strcpy(processPath, native ? bundlePath : containerPath);
    for (NSString *path in @[@(bundlePath), @(containerPath)]) {
        int fd = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY, 0600);
        assert(fd >= 0 && close(fd) == 0);
    }
    targetInfo = [@{@"CFBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.17.0",
        @"CFBundleVersion":@"2026.1103.1841"} mutableCopy];
    const RUINVersionMapping *mapping = RUINMappingForInfo(targetInfo);
    assert(mapping && mapping->messaging.readUntilABIStatus == RUINMappingStatusVerified);
    fixtureImage.header = (struct mach_header_64){.magic=MH_MAGIC_64, .cputype=CPU_TYPE_ARM64,
        .cpusubtype=CPU_SUBTYPE_ARM64_ALL, .filetype=native ? MH_EXECUTE : MH_DYLIB, .ncmds=3,
        .sizeofcmds=sizeof(fixtureImage)-sizeof(fixtureImage.header),
        .flags=native ? MH_PIE : MH_NO_REEXPORTED_DYLIBS};
    fixtureImage.uuid = (struct uuid_command){.cmd=LC_UUID, .cmdsize=sizeof(fixtureImage.uuid)};
    [[[NSUUID alloc] initWithUUIDString:@(mapping->host.uuid)] getUUIDBytes:fixtureImage.uuid.uuid];
    fixtureImage.identifier.command = (struct dylib_command){.cmd=native ? LC_LOAD_DYLIB : LC_ID_DYLIB,
        .cmdsize=sizeof(fixtureImage.identifier), .dylib.name.offset=sizeof(struct dylib_command)};
    strcpy(fixtureImage.identifier.name, "LINE");
    fixtureImage.text = (struct segment_command_64){.cmd=LC_SEGMENT_64, .cmdsize=sizeof(fixtureImage.text),
        .vmaddr=(uintptr_t)&fixtureImage, .vmsize=sizeof(fixtureImage), .initprot=VM_PROT_READ};
    strcpy(fixtureImage.text.segname, "__TEXT");
    otherImage = fixtureImage;
    otherImage.text.vmaddr = (uintptr_t)&otherImage;
}

static void RemoveImageFixture(void) {
    unlink(bundlePath); unlink(containerPath); rmdir(fixtureDirectory);
}

static void CheckTargetGate(void) {
    assert(!RUINCurrentMapping()); // The host test is never a verified LINE main.
    imageAvailable = NO; assert(!RUINReadUntilAvailable()); imageAvailable = YES;
    ownerMatches = NO; assert(!RUINReadUntilAvailable()); ownerMatches = YES;
    if (fixtureImage.header.filetype == MH_DYLIB) {
        fixtureImage.header.flags |= MH_PIE; assert(!RUINReadUntilAvailable());
        fixtureImage.header.flags &= ~MH_PIE;
    }
    fixtureImage.uuid.uuid[0]++; assert(!RUINReadUntilAvailable()); fixtureImage.uuid.uuid[0]--;
    fixtureImage.header.cpusubtype = CPU_SUBTYPE_ARM64E; assert(!RUINReadUntilAvailable());
    fixtureImage.header.cpusubtype = CPU_SUBTYPE_ARM64_ALL;
    assert(RUINReadUntilAvailable()); // Early misses were not cached.
    NSUInteger before = resolutions;
    id build = targetInfo[@"CFBundleVersion"];
    targetInfo[@"CFBundleVersion"] = @"2026.1103.1842"; assert(!RUINReadUntilAvailable());
    targetInfo[@"CFBundleVersion"] = build;
    id version = targetInfo[@"CFBundleShortVersionString"];
    targetInfo[@"CFBundleShortVersionString"] = @"26.17.1"; assert(!RUINReadUntilAvailable());
    targetInfo[@"CFBundleShortVersionString"] = @"26.16.0";
    targetInfo[@"CFBundleVersion"] = @"2026.1006.1718";
    assert(!RUINReadUntilAvailable()); // Known image metadata with unsupported callback ABI.
    targetInfo[@"CFBundleShortVersionString"] = version;
    targetInfo[@"CFBundleVersion"] = build;
    assert(resolutions == before);
    id identifier = targetInfo[@"CFBundleIdentifier"];
    targetInfo[@"CFBundleIdentifier"] = @"fixture.other"; assert(!RUINReadUntilAvailable());
    targetInfo[@"RUINOriginalBundleIdentifier"] = identifier;
    assert(RUINReadUntilAvailable()); // Renamed bundle with original identity.
    targetInfo[@"CFBundleIdentifier"] = identifier;
    [targetInfo removeObjectForKey:@"RUINOriginalBundleIdentifier"];
    // A positive lifetime pin must not bypass current owner/image validation.
    ownerMatches = NO; assert(!RUINReadUntilAvailable()); ownerMatches = YES;
    imageAvailable = NO; assert(!RUINReadUntilAvailable()); imageAvailable = YES;
    fixtureImage.uuid.uuid[0]++; assert(!RUINReadUntilAvailable()); fixtureImage.uuid.uuid[0]--;
    fixtureImage.header.cpusubtype = CPU_SUBTYPE_ARM64E; assert(!RUINReadUntilAvailable());
    fixtureImage.header.cpusubtype = CPU_SUBTYPE_ARM64_ALL;
    useOtherImage = YES; assert(!RUINReadUntilAvailable()); useOtherImage = NO;
    assert(RUINReadUntilAvailable() && !RUINCurrentMapping());
}

@interface ReadUntilFixtureContext : NSManagedObjectContext @end
@implementation ReadUntilFixtureContext
- (void)performBlockAndWait:(void (NS_NOESCAPE ^)(void))block {
    [super performBlockAndWait:^{ ownerQueueDepth++; @try { block(); } @finally { ownerQueueDepth--; } }];
}
@end

@interface ReadUntilFixtureMID : NSObject
@property(nonatomic, copy) NSString *stringValue;
@end
@implementation ReadUntilFixtureMID @end

@interface ReadUntilFixtureTask : NSObject @end
@implementation ReadUntilFixtureTask
- (instancetype)init { if ((self = [super init])) taskCount++; return self; }
- (void)dealloc { taskCount--; }
@end

BOOL RUINHistoryValidateReadChatKey(NSDictionary *key, id chat) {
    assert(ownerQueueDepth);
    validations++;
    return accountMatches && [key[@"kind"] isEqual:@"talk"] &&
        [key[@"store"] isEqual:@"fixture-store"] &&
        [key[@"chat"] isEqual:[chat valueForKey:@"mid"]];
}

static id NativeMID(id self, SEL selector, NSError **error) {
    (void)selector;
    assert(ownerQueueDepth);
    if (midThrows) @throw [NSException exceptionWithName:@"fixture" reason:nil userInfo:nil];
    if (midError) { *error = midError; return nil; }
    if (midReturnsNil) return nil;
    ReadUntilFixtureMID *mid = [midClass new];
    mid.stringValue = midOverride ?: [self valueForKey:@"mid"];
    return mid;
}
static long long LatestID(id self, SEL selector) {
    (void)self; (void)selector; latestReads++;
    return LLONG_MAX;
}
static id InvalidMIDGetter(id self, SEL selector) { (void)self; (void)selector; return nil; }

// Check the block actually carries a void/object invoke ABI, not a no-arg block.
static void CheckBlockABI(id block) {
    struct Literal { void *isa; int flags, reserved; void *invoke, *descriptor; };
    struct Literal *literal = (__bridge void *)block;
    assert(literal->flags & (1 << 30));
    const uint8_t *p = literal->descriptor;
    p += 2 * sizeof(uintptr_t);
    if (literal->flags & (1 << 25)) p += 2 * sizeof(void *);
    const char *signature = *(const char *const *)p;
    NSMethodSignature *types = [NSMethodSignature signatureWithObjCTypes:signature];
    assert(!strcmp(types.methodReturnType, "v") && types.numberOfArguments == 2);
    assert(!strcmp([types getArgumentTypeAtIndex:0], "@?"));
    assert([types getArgumentTypeAtIndex:1][0] == '@');
}

static id NativeRead(id self, SEL selector, NSString *message, id mid, void (^completion)(NSError *)) {
    (void)self; (void)selector;
    assert([mid isKindOfClass:midClass] && completion);
    CheckBlockABI(completion);
    calls++;
    receivedID = message; // Deliberately no copy: adapter must freeze selection.
    nativeCompletion = [completion copy];
    if (mode == Throw) @throw [NSException exceptionWithName:@"fixture" reason:nil userInfo:nil];
    if (mode == Sync || mode == SyncThenThrow) completion(nil);
    if (mode == SyncThenThrow) @throw [NSException exceptionWithName:@"fixture" reason:nil userInfo:nil];
    if (mode == Failure) completion([NSError errorWithDomain:@"native-fixture" code:7 userInfo:nil]);
    if (mode == NilTask) return nil;
    if (mode == WrongTask) return NSObject.new;
    id task = [taskClass new];
    returnedTask = task;
    return task;
}

static NSDictionary *Key(NSString *message) {
    return @{@"kind":@"talk", @"store":@"fixture-store", @"chat":@"fixture-chat", @"message":message};
}
static void Reset(void) {
    nativeCompletion = nil; receivedID = nil; returnedTask = nil;
    calls = validations = latestReads = 0;
    accountMatches = YES; midError = nil; midOverride = nil; midThrows = midReturnsNil = NO; mode = Deferred;
    assert(taskCount == 0);
}
static void CheckPolicy(NSArray *exceptions) {
    assert([NSUserDefaults.standardUserDefaults boolForKey:@"RUINReadControlEnabled"]);
    assert([[NSUserDefaults.standardUserDefaults arrayForKey:@"RUINReadExceptions"] isEqual:exceptions]);
    assert(latestReads == 0);
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    const char *variant = argc > 1 ? argv[1] : "normal";
    BOOL nativeVariant = !strcmp(variant, "native-owner");
    MakeImageFixture(nativeVariant);
    BOOL swiftRootVariant = !strcmp(variant, "swift-root");
    midClass = objc_allocateClassPair(ReadUntilFixtureMID.class, "_TtC13LineSharedMID3MID", 0);
    chatClass = objc_allocateClassPair(NSManagedObject.class, "ManagedChat", 0);
    Class taskParent = ReadUntilFixtureTask.class;
    if (swiftRootVariant) {
        taskParent = objc_allocateClassPair(Nil, "ReadUntilFixtureSwiftRoot", 0);
        assert(taskParent);
        objc_registerClassPair(taskParent);
    }
    taskClass = objc_allocateClassPair(taskParent, "_TtC13LEGYInterface17AnyCancelableTask", 0);
    Class service = objc_allocateClassPair(NSObject.class, "_TtC13LineMessaging11ChatService", 0);
    assert(midClass && chatClass && taskClass && service);
    assert(class_addMethod(chatClass, sel_registerName("midStructAndReturnError:"), (IMP)NativeMID,
        !strcmp(variant,"chat-abi") ? "q24@0:8^@16" : "@24@0:8^@16"));
    assert(class_addMethod(chatClass, sel_registerName("lastReceivedMessageID"), (IMP)LatestID, "q16@0:8"));
    assert(class_addMethod(object_getClass(service), sel_registerName("readUpToMessage:inRoom:completion:"),
        (IMP)NativeRead, !strcmp(variant,"service-abi") ? "v40@0:8@16@24@?32" : "@40@0:8@16@24@?32"));
    if (!strcmp(variant,"mid-abi"))
        assert(class_addMethod(midClass, sel_registerName("stringValue"), (IMP)InvalidMIDGetter, "q16@0:8"));
    objc_registerClassPair(midClass); objc_registerClassPair(chatClass);
    objc_registerClassPair(taskClass); objc_registerClassPair(service);
    if (!strcmp(variant, "normal") || nativeVariant) CheckTargetGate();
    if (swiftRootVariant) {
        // The real native task inherits SwiftObject, not NSObject.
        assert(RUINReadUntilAvailable());
        puts("PASS native task availability without NSObject inheritance");
        RemoveImageFixture();
        return 0;
    }
    NSEntityDescription *entity = [NSEntityDescription new];
    entity.name = @"Chat"; entity.managedObjectClassName = @"ManagedChat";
    NSAttributeDescription *mid = [NSAttributeDescription new]; mid.name = @"mid"; mid.attributeType = NSStringAttributeType;
    entity.properties = @[mid];
    NSManagedObjectModel *model = [NSManagedObjectModel new]; model.entities = @[entity];
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    assert([coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:NULL]);
    ReadUntilFixtureContext *context = [[ReadUntilFixtureContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = coordinator;
    __block NSManagedObject *chat;
    [context performBlockAndWait:^{
        chat = [[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:context];
        [chat setValue:@"fixture-chat" forKey:@"mid"];
        assert([context obtainPermanentIDsForObjects:@[chat] error:NULL]);
    }];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id oldHide = [defaults objectForKey:@"RUINReadControlEnabled"], oldExceptions = [defaults objectForKey:@"RUINReadExceptions"];
    NSArray *exceptions = @[@"chat:fixture-other"];
    [defaults setBool:YES forKey:@"RUINReadControlEnabled"]; [defaults setObject:exceptions forKey:@"RUINReadExceptions"];
    @try {
        if (strcmp(variant,"normal") && !nativeVariant) {
            __block NSUInteger count = 0;
            RUINReadUntilMessage(Key(@"42"), chat, ^(NSError *error) {
                count++; assert([error.domain isEqual:RUINReadUntilErrorDomain] && error.code == RUINReadUntilUnavailable);
            });
            assert(count == 1 && calls == 0); CheckPolicy(exceptions);
        } else {
            __block NSUInteger count = 0;
            __block NSError *result = nil;
            RUINReadUntilCompletion done = ^(NSError *error) { count++; result = error; };
            ownerMatches = NO;
            RUINReadUntilMessage(Key(@"42"), chat, done);
            assert(count == 1 && result.code == RUINReadUntilUnavailable && calls == 0);
            ownerMatches = YES; count = 0; result = nil;
            NSMutableString *selected = [NSMutableString stringWithString:@"9007199254740993"];
            @autoreleasepool { RUINReadUntilMessage(Key(selected), chat, done); }
            [selected setString:@"9223372036854775807"];
            assert(calls == 1 && validations == 1 && count == 0 && returnedTask && taskCount == 1);
            assert([receivedID isEqual:@"9007199254740993"]);
            ownerMatches = NO;
            assert(!RUINReadUntilAvailable() && returnedTask && taskCount == 1);
            nativeCompletion(nil); nativeCompletion([NSError errorWithDomain:@"duplicate" code:1 userInfo:nil]);
            assert(count == 1 && !result && !returnedTask && taskCount == 0); CheckPolicy(exceptions);
            ownerMatches = YES;
            Reset(); count = 0; mode = Sync;
            @autoreleasepool { RUINReadUntilMessage(Key(@"00042"), chat, done); }
            assert(count == 1 && !result && [receivedID isEqual:@"00042"] && taskCount == 0); CheckPolicy(exceptions);
            for (NSNumber *testMode in @[@(Failure), @(Throw), @(SyncThenThrow), @(NilTask), @(WrongTask)]) {
                Reset(); count = 0; result = nil; mode = testMode.integerValue;
                @autoreleasepool { RUINReadUntilMessage(Key(@"42"), chat, done); }
                assert(count == 1 && result && taskCount == 0);
                nativeCompletion(nil); assert(count == 1); CheckPolicy(exceptions);
            }
            Reset(); count = 0;
            @autoreleasepool { RUINReadUntilMessage(Key(@"42"), chat, done); }
            void (^callback)(NSError *) = nativeCompletion;
            dispatch_apply(2, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t i) {
                callback(i ? [NSError errorWithDomain:@"fixture" code:1 userInfo:nil] : nil);
            });
            assert(count == 1 && taskCount == 0); CheckPolicy(exceptions);
            callback = nil;
            Reset(); count = 0;
            @autoreleasepool { RUINReadUntilMessage(Key(@"42"), chat, done); }
            nativeCompletion((NSError *)(id)@"invalid-native-payload");
            assert(count == 1 && result.code == RUINReadUntilInvalidNativeResult && taskCount == 0); CheckPolicy(exceptions);
            for (NSString *invalid in @[@"0", @"-1", @"+1", @"1.5", @"１２", @"9223372036854775808", @""]) {
                Reset(); count = 0;
                RUINReadUntilMessage(Key(invalid), chat, done);
                assert(count == 1 && result.code == RUINReadUntilInvalidSelection && calls == 0); CheckPolicy(exceptions);
            }
            for (NSString *field in @[@"store", @"chat", @"account"]) {
                Reset(); count = 0;
                NSMutableDictionary *bad = [Key(@"42") mutableCopy];
                if ([field isEqual:@"account"]) accountMatches = NO; else bad[field] = @"mismatched";
                RUINReadUntilMessage(bad, chat, done);
                assert(count == 1 && result.code == RUINReadUntilChatMismatch && calls == 0); CheckPolicy(exceptions);
            }
            Reset(); count = 0; midThrows = YES;
            RUINReadUntilMessage(Key(@"42"), chat, done);
            assert(count == 1 && result.code == RUINReadUntilNativeException && calls == 0); CheckPolicy(exceptions);
            Reset(); count = 0; midError = [NSError errorWithDomain:@"mid-fixture" code:4 userInfo:nil];
            RUINReadUntilMessage(Key(@"42"), chat, done);
            assert(count == 1 && result == midError && calls == 0); CheckPolicy(exceptions);
            Reset(); count = 0; midReturnsNil = YES;
            RUINReadUntilMessage(Key(@"42"), chat, done);
            assert(count == 1 && result.code == RUINReadUntilInvalidNativeResult && calls == 0); CheckPolicy(exceptions);
            Reset(); count = 0; midOverride = @"fixture-other";
            RUINReadUntilMessage(Key(@"42"), chat, done);
            assert(count == 1 && result.code == RUINReadUntilChatMismatch && calls == 0); CheckPolicy(exceptions);
            Reset();
            @autoreleasepool {
                RUINReadUntilMessage(Key(@"42"), chat, ^(__unused NSError *error) {
                    @throw [NSException exceptionWithName:@"caller-fixture" reason:nil userInfo:nil];
                });
            }
            nativeCompletion(nil); assert(taskCount == 0); CheckPolicy(exceptions);
        }
    } @finally {
        nativeCompletion = nil;
        if (oldHide) [defaults setObject:oldHide forKey:@"RUINReadControlEnabled"]; else [defaults removeObjectForKey:@"RUINReadControlEnabled"];
        if (oldExceptions) [defaults setObject:oldExceptions forKey:@"RUINReadExceptions"]; else [defaults removeObjectForKey:@"RUINReadExceptions"];
        RemoveImageFixture();
    }
    puts("PASS verified owner/metadata gate, selected-ID adapter, typed completion, retention, races and unchanged read policy");
} return 0; }
