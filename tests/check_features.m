/* From ruin/:
 xcrun --sdk macosx clang -fobjc-arc -std=gnu11 -Wall -Wextra -Werror \
   -I. -framework Foundation src/core/Features.m tests/check_features.m \
   -o /tmp/ruin-check-features && /tmp/ruin-check-features
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

#import "Features.h"
#import "../src/core/TargetMetadata.h"

#define CHECK(condition, message) do { \
    if (!(condition)) @throw [NSException exceptionWithName:@"RUINFeatureCheck" \
        reason:(message) userInfo:nil]; \
} while (0)

static NSDictionary *gFakeInfoDictionary;
static NSUserDefaults *gFixtureDefaults;
static atomic_bool gConcurrentNameFailure = ATOMIC_VAR_INIT(false);

static id RUINFixtureStandardUserDefaults(id self, SEL selector)
{
    (void)self;
    (void)selector;
    return gFixtureDefaults;
}

static NSDictionary *RUINFakeInfoDictionary(id self, SEL selector)
{
    (void)self;
    (void)selector;
    return gFakeInfoDictionary;
}

@interface RUINBaseManagedChat : NSObject
@property (nonatomic) _Bool originalReadAllowed;
- (_Bool)canMarkChatAsReadToServer;
@end

@implementation RUINBaseManagedChat
- (instancetype)init
{
    self = [super init];
    if (self) _originalReadAllowed = 1;
    return self;
}
- (_Bool)canMarkChatAsReadToServer { return self.originalReadAllowed; }
@end

@interface ManagedChat : RUINBaseManagedChat
@property (nonatomic, copy) NSString *mid;
@property (nonatomic) long long lastReceivedMessageID;
- (NSString *)groupNameWithContext:(id)context;
@end

@implementation ManagedChat
- (instancetype)init
{
    self = [super init];
    if (self) { _mid = @"chat-1"; _lastReceivedMessageID = 100; }
    return self;
}
- (NSString *)groupNameWithContext:(id)context { (void)context; return @"A"; }
@end

static id RUINFakeSquareMIDGetter(id self, SEL selector)
{
    (void)selector;
    return object_getIvar(self, class_getInstanceVariable(object_getClass(self), "_mid"));
}

@interface ManagedSquareChat : NSObject {
    NSString *_mid;
}
@property (nonatomic, copy) NSString *mid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) long long lastReceivedMessageID;
@property (nonatomic) _Bool originalReadAllowed;
- (_Bool)canMarkChatAsReadToServer;
- (NSInteger)groupNameWithContext:(id)context;
@end

@implementation ManagedSquareChat
@dynamic mid;
+ (BOOL)resolveInstanceMethod:(SEL)selector
{
    if (selector == sel_registerName("mid"))
        return class_addMethod(self, selector, (IMP)RUINFakeSquareMIDGetter, "@@:");
    return [super resolveInstanceMethod:selector];
}
- (void)setMid:(NSString *)mid { _mid = [mid copy]; }
- (instancetype)init
{
    self = [super init];
    if (self) { _mid = @"square-1"; _name = @"S"; _lastReceivedMessageID = 200; _originalReadAllowed = 1; }
    return self;
}
- (_Bool)canMarkChatAsReadToServer { return self.originalReadAllowed; }
- (NSInteger)groupNameWithContext:(id)context
{
    (void)context;
    return 73;
}
@end

@interface ManagedUser : NSObject
@property (nonatomic, copy) NSString *mid;
- (NSString *)displayUserName;
- (NSString *)displayUserNameNoAddressBook;
@end

@implementation ManagedUser
- (instancetype)init
{
    self = [super init];
    if (self) _mid = @"user-1";
    return self;
}
- (NSString *)displayUserName { return [self displayUserNameNoAddressBook]; }
- (NSString *)displayUserNameNoAddressBook { return @"A"; }
@end

@interface ManagedUnifiedGroup : NSObject
@property (nonatomic, copy) NSString *id;
@property (nonatomic, copy) NSString *name;
- (NSString *)displayNameWithMyProfileInfo:(id)profileInfo inUserContext:(id)userContext;
@end

@implementation ManagedUnifiedGroup
- (instancetype)init
{
    self = [super init];
    if (self) { _id = @"group-1"; _name = @"G"; }
    return self;
}
- (NSString *)displayNameWithMyProfileInfo:(id)profileInfo inUserContext:(id)userContext
{
    (void)profileInfo;
    (void)userContext;
    return self.name;
}
@end

static const char *RUINEncoding(Class cls, const char *selectorName)
{
    Method method = class_getInstanceMethod(cls, sel_registerName(selectorName));
    return method ? method_getTypeEncoding(method) : NULL;
}

static BOOL RUINClassOwnsSelector(Class cls, SEL selector)
{
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static NSDictionary *RUINFakeInfoForBuild(NSString *build)
{
    return @{
        @"CFBundleIdentifier": @"host.ruin.check",
        @"RUINOriginalBundleIdentifier": RUINTargetBundleIdentifier,
        @"RUINSignedBundleIdentifier": @"host.ruin.check",
        @"CFBundleShortVersionString": @"26.17.0",
        @"CFBundleVersion": build
    };
}

static BOOL RUINObjectsEqual(id left, id right)
{
    return left == right || [left isEqual:right];
}

static void RUINRestoreDefault(NSUserDefaults *defaults, NSString *key, id value)
{
    if (value) [defaults setObject:value forKey:key];
    else [defaults removeObjectForKey:key];
}

static void *RUINNameWorker(void *unused)
{
    (void)unused;
    @autoreleasepool {
        ManagedUser *user = [ManagedUser new];
        for (NSUInteger index = 0; index < 1000; index++) {
            if (![[user displayUserName] isEqualToString:@"B"]) {
                atomic_store(&gConcurrentNameFailure, true);
                break;
            }
        }
    }
    return NULL;
}

static void *RUINAliasWriter(void *argument)
{
    @autoreleasepool {
        NSUInteger worker = (NSUInteger)(uintptr_t)argument;
        for (NSUInteger index = 0; index < 12; index++) {
            NSString *key = [NSString stringWithFormat:@"user:writer-%lu-%lu", (unsigned long)worker, (unsigned long)index];
            RUINSetLocalName(key, @"writer alias");
        }
    }
    return NULL;
}

static long long RUINWrongMID(id self, SEL selector)
{
    (void)self;
    (void)selector;
    return 73;
}

static int RUINRunChecks(void)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id savedReadControl = [defaults objectForKey:RUINReadControlEnabledDefaultsKey];
    id savedLocalNames = [defaults objectForKey:RUINLocalNamesDefaultsKey];
    id savedIdentityNames = [defaults objectForKey:RUINLocalNamesByIdentityDefaultsKey];
    id savedReadExceptions = [defaults objectForKey:RUINReadExceptionsDefaultsKey];
    id savedMarkOnReply = [defaults objectForKey:RUINMarkReadOnReplyDefaultsKey];
    Method bundleInfoMethod = NULL;
    IMP originalBundleInfo = NULL;
    BOOL bundleInfoOverridden = NO;
    int result = 0;

    @try {
        CHECK(RUINMappingForInfo(@{@"CFBundleIdentifier":@"jp.naver.line",
              @"CFBundleShortVersionString":@"26.17.0", @"CFBundleVersion":@"2026.1103.1841"}) != NULL,
              @"latest known identity was not discoverable through the mapping selector");
        NSDictionary *stockTarget = @{
            @"CFBundleIdentifier": @"jp.naver.line",
            @"CFBundleShortVersionString": @"26.16.0",
            @"CFBundleVersion": @"2026.1006.1718"
        };
        NSDictionary *sideloadTarget = @{
            @"CFBundleIdentifier": @"host.ruin.check",
            @"RUINOriginalBundleIdentifier": @"jp.naver.line",
            @"CFBundleShortVersionString": @"26.16.0",
            @"CFBundleVersion": @"2026.1006.1718"
        };
        CHECK(RUINTargetMetadataMatchesInfo(stockTarget), @"stock LINE metadata was rejected");
        CHECK(RUINTargetMetadataMatchesInfo(sideloadTarget), @"sideload LINE metadata was rejected");
        NSMutableDictionary *wrongTarget = [stockTarget mutableCopy];
        wrongTarget[@"CFBundleShortVersionString"] = @"26.15.0";
        CHECK(RUINTargetMetadataMatchesInfo(wrongTarget), @"structural hooks rejected a valid LINE version");
        CHECK(!RUINVerifiedTargetMatchesInfo(wrongTarget), @"unverified version inherited a private binary mapping");
        wrongTarget = [stockTarget mutableCopy];
        wrongTarget[@"CFBundleVersion"] = @"unknown-build";
        CHECK(!RUINTargetMetadataMatchesInfo(wrongTarget), @"unknown app build passed target metadata gate");
        wrongTarget = [stockTarget mutableCopy];
        wrongTarget[@"CFBundleIdentifier"] = @"unknown.bundle";
        CHECK(!RUINTargetMetadataMatchesInfo(wrongTarget), @"unknown bundle passed target metadata gate");
        [defaults removeObjectForKey:RUINLocalNamesByIdentityDefaultsKey];
        [defaults removeObjectForKey:RUINReadExceptionsDefaultsKey];
        [defaults removeObjectForKey:RUINMarkReadOnReplyDefaultsKey];
        NSBundle *mainBundle = [NSBundle mainBundle];
        bundleInfoMethod = class_getInstanceMethod(object_getClass(mainBundle), @selector(infoDictionary));
        CHECK(bundleInfoMethod != NULL, @"NSBundle -infoDictionary was not found");
        originalBundleInfo = method_setImplementation(bundleInfoMethod, (IMP)RUINFakeInfoDictionary);
        bundleInfoOverridden = YES;
        CHECK(originalBundleInfo != NULL, @"NSBundle -infoDictionary override failed");

        SEL readSelector = sel_registerName("canMarkChatAsReadToServer");
        SEL squareNameSelector = sel_registerName("groupNameWithContext:");
        IMP superclassReadIMP = method_getImplementation(class_getInstanceMethod([RUINBaseManagedChat class], readSelector));
        IMP mismatchedNameIMP = method_getImplementation(class_getInstanceMethod([ManagedSquareChat class], squareNameSelector));

        CHECK(strcmp(RUINEncoding([ManagedChat class], "canMarkChatAsReadToServer"), "B16@0:8") == 0,
              @"fake ManagedChat _Bool encoding was not B16@0:8");
        CHECK(strcmp(RUINEncoding([ManagedSquareChat class], "canMarkChatAsReadToServer"), "B16@0:8") == 0,
              @"fake ManagedSquareChat _Bool encoding was not B16@0:8");
        CHECK(strcmp(RUINEncoding([ManagedUser class], "displayUserName"), "@16@0:8") == 0,
              @"fake ManagedUser displayUserName encoding mismatch");
        CHECK(strcmp(RUINEncoding([ManagedUser class], "displayUserNameNoAddressBook"), "@16@0:8") == 0,
              @"fake ManagedUser displayUserNameNoAddressBook encoding mismatch");
        CHECK(strcmp(RUINEncoding([ManagedUnifiedGroup class], "displayNameWithMyProfileInfo:inUserContext:"),
                     "@32@0:8@16@24") == 0,
              @"fake ManagedUnifiedGroup encoding mismatch");
        CHECK(strcmp(RUINEncoding([ManagedSquareChat class], "groupNameWithContext:"), "@24@0:8@16") != 0,
              @"deliberately mismatched selector unexpectedly matched");
        CHECK(!RUINClassOwnsSelector([ManagedSquareChat class], sel_registerName("mid")),
              @"dynamic MID getter was unexpectedly present before resolution");

        [defaults setBool:YES forKey:RUINReadControlEnabledDefaultsKey];
        [defaults setObject:@{@"A": @"B", @"B": @"C", @"G": @"Group alias"}
                     forKey:RUINLocalNamesDefaultsKey];
        gFakeInfoDictionary = RUINFakeInfoForBuild(@"wrong-build");
        RUINInstallFeatures();
        NSDictionary *diagnostics = RUINFeatureDiagnostics();
        CHECK(![diagnostics[@"target"][@"supported"] boolValue], @"unsupported build passed the gate");
        CHECK(![diagnostics[@"readControl"][@"enabled"] boolValue], @"unsupported build left read control enabled");
        CHECK([[ManagedChat new] canMarkChatAsReadToServer], @"unsupported build changed ManagedChat behavior");
        CHECK([[ManagedUser new].displayUserName isEqualToString:@"A"], @"unsupported build applied a local alias");

        gFakeInfoDictionary = RUINFakeInfoForBuild(@"2026.1103.1841");
        [defaults removeObjectForKey:RUINReadControlEnabledDefaultsKey];
        RUINInstallFeatures();
        diagnostics = RUINFeatureDiagnostics();
        CHECK([diagnostics[@"target"][@"supported"] boolValue], @"exact fake target did not pass the gate");
        CHECK(![diagnostics[@"readControl"][@"enabled"] boolValue], @"read control was not default-off");

        CHECK(RUINClassOwnsSelector([ManagedChat class], readSelector),
              @"inherited hook was not installed as a subclass method");
        CHECK(method_getImplementation(class_getInstanceMethod([RUINBaseManagedChat class], readSelector)) == superclassReadIMP,
              @"inherited hook changed the superclass implementation");
        CHECK([[ManagedChat new] canMarkChatAsReadToServer], @"default read hook did not pass through");
        CHECK([[ManagedSquareChat new] canMarkChatAsReadToServer], @"default SquareChat hook did not pass through");
        CHECK([[RUINBaseManagedChat new] canMarkChatAsReadToServer], @"superclass behavior changed after hook install");

        [defaults setBool:YES forKey:RUINReadControlEnabledDefaultsKey];
        RUINInstallFeatures();
        CHECK(![[ManagedChat new] canMarkChatAsReadToServer], @"enabled ManagedChat read control did not suppress");
        CHECK(![[ManagedSquareChat new] canMarkChatAsReadToServer], @"enabled SquareChat read control did not suppress");
        CHECK(RUINClassOwnsSelector([ManagedSquareChat class], sel_registerName("mid")),
              @"verified dynamic identity getter was not resolved");
        CHECK([[RUINBaseManagedChat new] canMarkChatAsReadToServer], @"enabled subclass hook corrupted superclass behavior");

        [defaults setBool:NO forKey:RUINReadControlEnabledDefaultsKey];
        RUINInstallFeatures();
        CHECK([[ManagedChat new] canMarkChatAsReadToServer], @"turning read control off did not restore original behavior");
        CHECK([[ManagedSquareChat new] canMarkChatAsReadToServer], @"turning SquareChat read control off did not restore original behavior");

        ManagedUser *user = [ManagedUser new];
        CHECK([[user displayUserName] isEqualToString:@"B"], @"nested name hooks applied aliases transitively");
        CHECK([[user displayUserNameNoAddressBook] isEqualToString:@"B"], @"direct visible-name alias failed");
        ManagedUnifiedGroup *group = [ManagedUnifiedGroup new];
        CHECK([[group displayNameWithMyProfileInfo:nil inUserContext:nil] isEqualToString:@"Group alias"],
              @"group visible-name alias failed");

        ManagedSquareChat *square = [ManagedSquareChat new];
        CHECK([square groupNameWithContext:nil] == 73, @"mismatched selector's original implementation changed");
        CHECK(method_getImplementation(class_getInstanceMethod([ManagedSquareChat class], squareNameSelector)) == mismatchedNameIMP,
              @"mismatched selector's IMP was replaced");
        diagnostics = RUINFeatureDiagnostics();
        NSDictionary *mismatch = diagnostics[@"localNames"][@"hooks"][@"ManagedSquareChat.groupNameWithContext:"];
        CHECK([mismatch[@"installStatus"] isEqualToString:@"encoding_mismatch"],
              @"mismatched selector was not reported as rejected");

        pthread_t threads[4];
        NSUInteger created = 0;
        BOOL threadCreationFailed = NO;
        atomic_store(&gConcurrentNameFailure, false);
        for (; created < 4; created++) {
            if (pthread_create(&threads[created], NULL, RUINNameWorker, NULL) != 0) {
                threadCreationFailed = YES;
                break;
            }
        }
        for (NSUInteger index = 0; index < created; index++) pthread_join(threads[index], NULL);
        CHECK(!threadCreationFailed, @"could not start name-hook worker threads");
        CHECK(!atomic_load(&gConcurrentNameFailure), @"thread-local name-hook guard crossed threads");

        RUINSetLocalName(@"user:user-1", @"User one");
        ManagedUser *secondUser = [ManagedUser new];
        secondUser.mid = @"user-2";
        CHECK([[user displayUserName] isEqualToString:@"User one"], @"identity alias did not override legacy name");
        CHECK([[secondUser displayUserName] isEqualToString:@"B"], @"same visible name leaked an identity alias");
        RUINSetLocalName(@"user:user-2", @"User two");
        CHECK([[secondUser displayUserName] isEqualToString:@"User two"], @"second identity alias failed");
        CHECK([[[ManagedUser new] displayUserName] isEqualToString:@"User one"], @"identity alias was tied to an object pointer");

        group.id = @"user-1";
        group.name = @"A";
        RUINSetLocalName(@"group:user-1", @"Group one");
        CHECK([[group displayNameWithMyProfileInfo:nil inUserContext:nil] isEqualToString:@"Group one"],
              @"group and user ID namespaces collided");
        ManagedChat *namedChat = [ManagedChat new];
        namedChat.mid = @"user-1";
        RUINSetLocalName(@"chat:user-1", @"Chat one");
        CHECK([[namedChat groupNameWithContext:nil] isEqualToString:@"Chat one"], @"ManagedChat identity name hook failed");
        CHECK([[user displayUserName] isEqualToString:@"User one"], @"chat/group alias changed user alias");

        NSDictionary *interactiveIdentity = RUINIdentityForObject(user);
        CHECK([interactiveIdentity[@"kind"] isEqualToString:@"user"] &&
              [interactiveIdentity[@"identifier"] isEqualToString:@"user-1"] &&
              [interactiveIdentity[@"displayName"] isEqualToString:@"A"],
              @"interactive identity returned aliased text or incorrect identity");
        CHECK([RUINIdentityForObject(group)[@"kind"] isEqualToString:@"group"], @"group identity kind failed");
        CHECK([RUINIdentityForObject(namedChat)[@"kind"] isEqualToString:@"chat"], @"chat identity kind failed");
        CHECK([RUINIdentityForObject(namedChat)[@"displayName"] isEqualToString:@""],
              @"context-dependent chat display name was guessed");
        CHECK([RUINIdentityForObject(square)[@"kind"] isEqualToString:@"squareChat"], @"OpenChat namespace failed");
        CHECK(RUINIdentityForObject(@"not a managed entity").count == 0, @"unknown object acquired an identity");

        RUINSetLocalName(@"user:user-1", @"");
        CHECK([[user displayUserName] isEqualToString:@"A"], @"empty identity alias did not mask legacy fallback");
        CHECK([[secondUser displayUserName] isEqualToString:@"User two"], @"clearing one alias affected another identity");
        RUINSetLocalName(@"A", @"invalid");
        CHECK([defaults dictionaryForKey:RUINLocalNamesByIdentityDefaultsKey][@"A"] == nil,
              @"unprefixed identity key was stored");
        CHECK([[defaults dictionaryForKey:RUINLocalNamesDefaultsKey][@"A"] isEqualToString:@"B"],
              @"legacy preferences were destructively migrated");
        NSString *diagnosticText = [RUINFeatureDiagnostics() description];
        CHECK([diagnosticText rangeOfString:@"user-1"].location == NSNotFound &&
              [diagnosticText rangeOfString:@"User two"].location == NSNotFound,
              @"diagnostics exposed a stored identity or alias");

        created = 0;
        threadCreationFailed = NO;
        for (; created < 4; created++) {
            if (pthread_create(&threads[created], NULL, RUINAliasWriter, (void *)(uintptr_t)created) != 0) {
                threadCreationFailed = YES;
                break;
            }
        }
        for (NSUInteger index = 0; index < created; index++) pthread_join(threads[index], NULL);
        CHECK(!threadCreationFailed, @"could not start alias writer threads");
        NSDictionary *storedNames = [defaults dictionaryForKey:RUINLocalNamesByIdentityDefaultsKey];
        for (NSUInteger worker = 0; worker < 4; worker++) {
            for (NSUInteger index = 0; index < 12; index++) {
                NSString *key = [NSString stringWithFormat:@"user:writer-%lu-%lu", (unsigned long)worker, (unsigned long)index];
                CHECK([storedNames[key] isEqualToString:@"writer alias"], @"concurrent identity setters lost an update");
            }
        }

        ManagedChat *firstChat = [ManagedChat new];
        ManagedChat *secondChat = [ManagedChat new];
        secondChat.mid = @"chat-2";
        square.mid = firstChat.mid; // Same raw ID, separate namespace.
        [defaults setBool:YES forKey:RUINReadControlEnabledDefaultsKey];
        [defaults setObject:@[@"chat:chat-1", @"user:user-1", @"A"] forKey:RUINReadExceptionsDefaultsKey];
        RUINInstallFeatures();
        CHECK(!RUINShouldSuppressReadForChat(firstChat) && [firstChat canMarkChatAsReadToServer],
              @"chat identity exception did not pass through");
        CHECK(RUINShouldSuppressReadForChat(secondChat) && ![secondChat canMarkChatAsReadToServer],
              @"same visible-name chat incorrectly inherited another chat's exception");
        CHECK(RUINShouldSuppressReadForChat(square) && ![square canMarkChatAsReadToServer],
              @"regular chat exception leaked into OpenChat namespace");
        firstChat.originalReadAllowed = 0;
        CHECK(![firstChat canMarkChatAsReadToServer], @"exception forced YES instead of preserving original NO");
        firstChat.originalReadAllowed = 1;
        ManagedChat *unidentifiedChat = [ManagedChat new];
        unidentifiedChat.mid = @"";
        CHECK(!RUINShouldSuppressReadForChat(unidentifiedChat) && [unidentifiedChat canMarkChatAsReadToServer],
              @"missing chat ID failed closed or used a displayed-name ID");
        CHECK(RUINIdentityForObject(unidentifiedChat).count == 0, @"missing ID was fabricated");

        Class wrongIdentityClass = objc_allocateClassPair([ManagedChat class], "RUINWrongIdentityChat", 0);
        CHECK(wrongIdentityClass != Nil, @"could not create malformed getter test class");
        CHECK(class_addMethod(wrongIdentityClass, sel_registerName("mid"), (IMP)RUINWrongMID, "q16@0:8"),
              @"could not add malformed identity getter");
        objc_registerClassPair(wrongIdentityClass);
        id wrongIdentityChat = [wrongIdentityClass new];
        CHECK(RUINIdentityForObject(wrongIdentityChat).count == 0 &&
              !RUINShouldSuppressReadForChat(wrongIdentityChat) && [wrongIdentityChat canMarkChatAsReadToServer],
              @"malformed identity getter was invoked or failed closed");

        [defaults setObject:@[@"chat:chat-1", @"squareChat:chat-1"] forKey:RUINReadExceptionsDefaultsKey];
        RUINInstallFeatures();
        CHECK([square canMarkChatAsReadToServer], @"OpenChat identity exception failed");
        CHECK(![secondChat canMarkChatAsReadToServer], @"OpenChat exception changed another chat");

        [defaults setObject:@[] forKey:RUINReadExceptionsDefaultsKey];
        [defaults setBool:NO forKey:RUINMarkReadOnReplyDefaultsKey];
        RUINInstallFeatures();
        RUINAllowReadAfterUserReply(firstChat);
        CHECK(RUINShouldSuppressReadForChat(firstChat), @"default-off reply setting granted an allowance");
        [defaults setBool:YES forKey:RUINMarkReadOnReplyDefaultsKey];
        RUINInstallFeatures();
        CHECK(RUINShouldSuppressReadForChat(firstChat), @"reply setting alone created an allowance");
        RUINAllowReadAfterUserReply(firstChat);
        CHECK(!RUINShouldSuppressReadForChat(firstChat) && [firstChat canMarkChatAsReadToServer] &&
              [firstChat canMarkChatAsReadToServer], @"reply allowance was consumed by a predicate check");
        CHECK(RUINShouldSuppressReadForChat(secondChat) && RUINShouldSuppressReadForChat(square),
              @"reply allowance leaked to another identity or namespace");
        CHECK(!RUINShouldSuppressReadForChat([ManagedChat new]), @"same-identity refetch lost its current-boundary allowance");
        firstChat.originalReadAllowed = 0;
        CHECK(![firstChat canMarkChatAsReadToServer], @"reply allowance forced YES instead of original NO");
        firstChat.originalReadAllowed = 1;
        firstChat.lastReceivedMessageID = 101;
        CHECK(RUINShouldSuppressReadForChat(firstChat) && ![firstChat canMarkChatAsReadToServer],
              @"new received boundary retained a reply allowance");
        firstChat.lastReceivedMessageID = 100;
        CHECK(RUINShouldSuppressReadForChat(firstChat), @"expired allowance revived when boundary changed back");
        firstChat.lastReceivedMessageID = 0;
        RUINAllowReadAfterUserReply(firstChat);
        CHECK(RUINShouldSuppressReadForChat(firstChat), @"invalid boundary created an allowance");
        firstChat.lastReceivedMessageID = 100;
        RUINAllowReadAfterUserReply(firstChat);
        RUINInstallFeatures();
        CHECK(RUINShouldSuppressReadForChat(firstChat), @"preference reload retained a transient allowance");
        CHECK(![RUINFeatureDiagnostics()[@"readControl"][@"readOnReply"][@"automaticEventHookInstalled"] boolValue],
              @"diagnostics falsely claimed an automatic reply event hook");
        [defaults setBool:NO forKey:RUINReadControlEnabledDefaultsKey];
        RUINInstallFeatures();
        CHECK(!RUINShouldSuppressReadForChat(firstChat) && [firstChat canMarkChatAsReadToServer],
              @"disabling read control did not restore original after identity settings");

        [defaults setBool:YES forKey:RUINReadControlEnabledDefaultsKey];
        gFakeInfoDictionary = RUINFakeInfoForBuild(@"unsupported-again");
        RUINInstallFeatures();
        diagnostics = RUINFeatureDiagnostics();
        CHECK(![diagnostics[@"target"][@"supported"] boolValue], @"unsupported build unexpectedly passed the gate");
        CHECK(![diagnostics[@"readControl"][@"enabled"] boolValue], @"unsupported build did not disable read control");
        CHECK([[ManagedChat new] canMarkChatAsReadToServer], @"unsupported build did not fail open for ManagedChat");
        CHECK([[ManagedSquareChat new] canMarkChatAsReadToServer], @"unsupported build did not fail open for SquareChat");
        CHECK([[user displayUserName] isEqualToString:@"A"], @"unsupported build retained local-name aliases");
        CHECK(RUINIdentityForObject(user).count == 0 && !RUINShouldSuppressReadForChat(firstChat),
              @"unsupported build exposed an interactive identity or suppressed reads");
        CHECK([square groupNameWithContext:nil] == 73, @"unsupported build changed the mismatched original method");

        diagnostics = RUINFeatureDiagnostics();
        CHECK([diagnostics[@"readControl"][@"hooks"][@"ManagedChat"][@"callCount"] unsignedLongLongValue] >= 3,
              @"ManagedChat calls were not counted");
        CHECK([diagnostics[@"readControl"][@"hooks"][@"ManagedSquareChat"][@"callCount"] unsignedLongLongValue] >= 3,
              @"SquareChat calls were not counted");
    } @catch (NSException *exception) {
        fprintf(stderr, "RUIN feature check failed: %s\n", exception.reason.UTF8String ?: "unknown error");
        result = 1;
    } @finally {
        RUINRestoreDefault(defaults, RUINReadControlEnabledDefaultsKey, savedReadControl);
        RUINRestoreDefault(defaults, RUINLocalNamesDefaultsKey, savedLocalNames);
        RUINRestoreDefault(defaults, RUINLocalNamesByIdentityDefaultsKey, savedIdentityNames);
        RUINRestoreDefault(defaults, RUINReadExceptionsDefaultsKey, savedReadExceptions);
        RUINRestoreDefault(defaults, RUINMarkReadOnReplyDefaultsKey, savedMarkOnReply);
        if (bundleInfoOverridden) method_setImplementation(bundleInfoMethod, originalBundleInfo);
    }

    if (!RUINObjectsEqual([defaults objectForKey:RUINReadControlEnabledDefaultsKey], savedReadControl) ||
        !RUINObjectsEqual([defaults objectForKey:RUINLocalNamesDefaultsKey], savedLocalNames) ||
        !RUINObjectsEqual([defaults objectForKey:RUINLocalNamesByIdentityDefaultsKey], savedIdentityNames) ||
        !RUINObjectsEqual([defaults objectForKey:RUINReadExceptionsDefaultsKey], savedReadExceptions) ||
        !RUINObjectsEqual([defaults objectForKey:RUINMarkReadOnReplyDefaultsKey], savedMarkOnReply)) {
        fprintf(stderr, "RUIN feature check failed to restore NSUserDefaults keys\n");
        result = 1;
    }
    if (!result) puts("RUIN Features host checks passed");
    return result;
}

int main(void)
{
    @autoreleasepool {
        NSString *suite = [@"com.tqmane.ruin.check.features." stringByAppendingString:NSUUID.UUID.UUIDString];
        Method defaultsMethod = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        IMP originalDefaults = NULL;
        @try {
            gFixtureDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
            CHECK(gFixtureDefaults != nil && defaultsMethod != NULL, @"fixture defaults setup failed");
            originalDefaults = method_setImplementation(defaultsMethod, (IMP)RUINFixtureStandardUserDefaults);
            CHECK(originalDefaults != NULL && NSUserDefaults.standardUserDefaults == gFixtureDefaults,
                  @"fixture defaults routing failed");
            return RUINRunChecks();
        } @finally {
            if (originalDefaults) method_setImplementation(defaultsMethod, originalDefaults);
            [gFixtureDefaults removePersistentDomainForName:suite];
            gFixtureDefaults = nil;
        }
    }
}
