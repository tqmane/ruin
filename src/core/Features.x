%config(generator=internal);

#import "Features.h"
#import "TargetMetadata.h"
#import "LINEPrivateCalls.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreData/CoreData.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <string.h>

NSString * const RUINTargetBundleIdentifier = @"jp.naver.line";
NSString * const RUINReadControlEnabledDefaultsKey = @"RUINReadControlEnabled";
NSString * const RUINLocalNamesDefaultsKey = @"RUINLocalNames";
NSString * const RUINLocalNamesByIdentityDefaultsKey = @"RUINLocalNamesByIdentity";
NSString * const RUINReadExceptionsDefaultsKey = @"RUINReadExceptions";
NSString * const RUINMarkReadOnReplyDefaultsKey = @"RUINMarkReadOnReply";
NSString * const RUINLocalLYPEnabledDefaultsKey = @"RUINLocalLYPEnabled";
NSString * const RUINLegacyMessagingEnabledDefaultsKey = @"RUINLegacyMessagingEnabled";

typedef enum {
    RUINHookPending,
    RUINHookVersionGated,
    RUINHookMissingClass,
    RUINHookMissingSelector,
    RUINHookEncodingMismatch,
    RUINHookInstallFailed,
    RUINHookInstalled
} RUINHookStatus;

typedef struct {
    const char *className;
    const char *selectorName;
    const char *encoding;
    atomic_uint_fast64_t calls;
    atomic_int status;
} RUINHook;

static RUINHook gManagedChatReadHook = {
    "ManagedChat", "canMarkChatAsReadToServer", "B16@0:8",
    ATOMIC_VAR_INIT(0),
    ATOMIC_VAR_INIT(RUINHookPending)
};
static RUINHook gSquareChatReadHook = {
    "ManagedSquareChat", "canMarkChatAsReadToServer", "B16@0:8",
    ATOMIC_VAR_INIT(0),
    ATOMIC_VAR_INIT(RUINHookPending)
};
static RUINHook gUserDisplayNameHook = {
    "ManagedUser", "displayUserName", "@16@0:8",
    ATOMIC_VAR_INIT(0),
    ATOMIC_VAR_INIT(RUINHookPending)
};
static RUINHook gUserDisplayNameNoAddressBookHook = {
    "ManagedUser", "displayUserNameNoAddressBook", "@16@0:8",
    ATOMIC_VAR_INIT(0),
    ATOMIC_VAR_INIT(RUINHookPending)
};
static RUINHook gUnifiedGroupDisplayNameHook = {
    "ManagedUnifiedGroup", "displayNameWithMyProfileInfo:inUserContext:", "@32@0:8@16@24",
    ATOMIC_VAR_INIT(0),
    ATOMIC_VAR_INIT(RUINHookPending)
};
static RUINHook gSquareChatGroupNameHook = {
    "ManagedSquareChat", "groupNameWithContext:", "@24@0:8@16",
    ATOMIC_VAR_INIT(0),
    ATOMIC_VAR_INIT(RUINHookPending)
};
static RUINHook gManagedChatGroupNameHook = {
    "ManagedChat", "groupNameWithContext:", "@24@0:8@16",
    ATOMIC_VAR_INIT(0),
    ATOMIC_VAR_INIT(RUINHookPending)
};

static RUINHook * const gHooks[] = {
    &gManagedChatReadHook,
    &gSquareChatReadHook,
    &gUserDisplayNameHook,
    &gUserDisplayNameNoAddressBookHook,
    &gUnifiedGroupDisplayNameHook,
    &gManagedChatGroupNameHook,
    &gSquareChatGroupNameHook
};

static os_unfair_lock gInstallLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
static NSDictionary<NSString *, NSString *> *gLocalNames;
static NSDictionary<NSString *, NSString *> *gLocalNamesByIdentity;
static NSSet<NSString *> *gReadExceptions;
static NSMutableDictionary<NSString *, NSNumber *> *gReplyBoundaries;
static NSString *gActiveAccountMID;
static BOOL gReadPolicyValid;
static uint64_t gReadPolicyGeneration;
static atomic_bool gTargetSupported = ATOMIC_VAR_INIT(false);
static atomic_bool gReadControlEnabled = ATOMIC_VAR_INIT(false);
static atomic_bool gMarkReadOnReply = ATOMIC_VAR_INIT(false);
static atomic_bool gReplyObserverInstalled = ATOMIC_VAR_INIT(false);
static _Thread_local unsigned int gDisplayNameHookDepth;

static BOOL RUINInfoStringEquals(NSDictionary *info, NSString *key, NSString *expected)
{
    id value = info[key];
    return [value isKindOfClass:[NSString class]] && [value isEqualToString:expected];
}

typedef struct {
    NSString *version;
    BOOL matched;
} RUINKnownVersionMatch;

static void RUINMatchKnownVersion(const RUINVersionMapping *mapping, void *context)
{
    RUINKnownVersionMatch *match = context;
    match->matched |= [match->version isKindOfClass:NSString.class] &&
        [match->version isEqualToString:@(mapping->host.version)];
}

static BOOL RUINTargetMatches(BOOL *bundleMatches, BOOL *versionMatches, BOOL *buildMatches)
{
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = bundle.infoDictionary ?: @{};
    BOOL matchesBundle = [bundle.bundleIdentifier isEqualToString:RUINTargetBundleIdentifier] ||
        RUINInfoStringEquals(info, @"RUINOriginalBundleIdentifier", RUINTargetBundleIdentifier);
    RUINKnownVersionMatch versionMatch = {info[@"CFBundleShortVersionString"], NO};
    RUINEnumerateVersionMappings(RUINMatchKnownVersion, &versionMatch);
    BOOL matchesVersion = versionMatch.matched;
    BOOL matchesBuild = RUINMappingForInfo(@{
        @"CFBundleIdentifier": RUINTargetBundleIdentifier,
        @"CFBundleShortVersionString": info[@"CFBundleShortVersionString"] ?: @"",
        @"CFBundleVersion": info[@"CFBundleVersion"] ?: @""
    }) != NULL;
    if (bundleMatches) *bundleMatches = matchesBundle;
    if (versionMatches) *versionMatches = matchesVersion;
    if (buildMatches) *buildMatches = matchesBuild;
    return RUINTargetMetadataMatchesInfo(info);
}

/* Verified in the manifest-matching LINE Mach-O, using decode_objc.py:
 ManagedUser.midString @16@0:8 (0x1092ae054), ManagedUnifiedGroup.validatedMIDString
 @16@0:8 (0x1035afbe0), and NSString properties mid/id below. We use the raw,
 nullable property getters, not Swift validated-ID objects or guessed KVC.
 Current schemas: TalkDataModelV2 15.4 Chat.mid/lastReceivedMessageID;
 UserDataModel 6 User.mid; UnifiedGroupDataModel 8 UnifiedGroup.id/name;
 SquareTalkDataModel 36 Chat.mid/name/lastReceivedMessageID. Boundary type is
 Int64 (q), identifiers/names are NSString. ManagedChat.groupNameWithContext:
 is @24@0:8@16 at 0x103eaa270. These addresses are evidence, never hook targets.
 */
typedef struct {
    const char *className;
    const char *kind;
    const char *identifierProperty;
    const char *displayProperty;
} RUINIdentityType;

static const RUINIdentityType gIdentityTypes[] = {
    {"ManagedUser", "user", "mid", NULL},
    {"ManagedSquareChat", "squareChat", "mid", "name"},
    {"ManagedChat", "chat", "mid", NULL},
    {"ManagedUnifiedGroup", "group", "id", "name"}
};

static const RUINIdentityType *RUINTypeForObject(id object)
{
    if (!object) return NULL;
    for (size_t index = 0; index < sizeof(gIdentityTypes) / sizeof(gIdentityTypes[0]); index++) {
        Class cls = objc_getClass(gIdentityTypes[index].className);
        if (cls && [object isKindOfClass:cls]) return &gIdentityTypes[index];
    }
    return NULL;
}

static BOOL RUINValidIdentityKey(id key, BOOL chatOnly)
{
    if (![key isKindOfClass:[NSString class]]) return NO;
    NSRange separator = [key rangeOfString:@":"];
    if (separator.location == NSNotFound || separator.location == 0 ||
        NSMaxRange(separator) == [key length]) return NO;
    NSString *kind = [key substringToIndex:separator.location];
    if ([kind isEqualToString:@"chat"] || [kind isEqualToString:@"squareChat"]) return YES;
    return !chatOnly && ([kind isEqualToString:@"user"] || [kind isEqualToString:@"group"]);
}

static BOOL RUINGetterSignatureMatches(id object, SEL selector, const char *returnType)
{
    if (![object respondsToSelector:selector]) return NO; // Resolves Core Data dynamic accessors.
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) return NO;
    const char *actual = signature.methodReturnType;
    while (*actual && strchr("rnNoORV", *actual)) actual++;
    return returnType[0] == '@' ? actual[0] == '@' && actual[1] != '?' : strcmp(actual, returnType) == 0;
}

static BOOL RUINVerifiedProperty(id object, const char *name, const char *type, NSAttributeType attributeType)
{
    objc_property_t property = class_getProperty(object_getClass(object), name);
    if (!property) return NO;
    char *declaredType = property_copyAttributeValue(property, "T");
    char *getter = property_copyAttributeValue(property, "G");
    BOOL matches = declaredType && strcmp(declaredType, type) == 0 && (!getter || strcmp(getter, name) == 0);
    free(declaredType);
    free(getter);
    if (!matches) return NO;

    // No queue hops or KVC: caller must already be on this object's owning queue.
    Class managedObjectClass = NSClassFromString(@"NSManagedObject");
    if (managedObjectClass && [object isKindOfClass:managedObjectClass]) {
        NSManagedObject *managed = object;
        if (managed.isDeleted) return NO;
        NSString *key = [NSString stringWithUTF8String:name];
        NSAttributeDescription *attribute = managed.entity.attributesByName[key];
        if (!attribute || attribute.attributeType != attributeType) return NO;
    }
    return YES;
}

static NSString *RUINStringProperty(id object, const char *name)
{
    @try {
        if (!RUINVerifiedProperty(object, name, "@\"NSString\"", NSStringAttributeType)) return nil;
        SEL selector = sel_registerName(name);
        if (!RUINGetterSignatureMatches(object, selector, "@")) return nil;
        // Metadata selects mid/id/name at runtime; this generic getter cannot
        // be a single bracket message. Its object-return ABI is checked above.
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        return [value isKindOfClass:[NSString class]] ? [value copy] : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL RUINReceivedBoundary(id chat, long long *boundary)
{
    @try {
        const char *name = "lastReceivedMessageID";
        if (!RUINVerifiedProperty(chat, name, "q", NSInteger64AttributeType)) return NO;
        SEL selector = sel_registerName(name);
        if (!RUINGetterSignatureMatches(chat, selector, "q")) return NO;
        *boundary = [(id<RUINLINEManagedChatCalls>)chat lastReceivedMessageID];
        return *boundary > 0;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static NSString *RUINIdentityKeyForObject(id object, BOOL chatOnly)
{
    if (!atomic_load(&gTargetSupported)) return nil;
    const RUINIdentityType *type = RUINTypeForObject(object);
    if (!type) return nil;
    if (chatOnly && strcmp(type->kind, "chat") != 0 && strcmp(type->kind, "squareChat") != 0) return nil;
    NSString *identifier = RUINStringProperty(object, type->identifierProperty);
    if (identifier.length == 0) return nil;
    return [NSString stringWithFormat:@"%s:%@", type->kind, identifier];
}

NSDictionary *RUINIdentityForObject(id object)
{
    if (!atomic_load(&gTargetSupported)) return @{};
    const RUINIdentityType *type = RUINTypeForObject(object);
    if (!type) return @{};
    NSString *identifier = RUINStringProperty(object, type->identifierProperty);
    if (identifier.length == 0) return @{};
    NSString *displayName = @"";
    gDisplayNameHookDepth++;
    @try {
        if (type->displayProperty) displayName = RUINStringProperty(object, type->displayProperty) ?: @"";
        else if (strcmp(type->kind, "user") == 0) {
            SEL selector = sel_registerName("displayUserName");
            Method method = class_getInstanceMethod(object_getClass(object), selector);
            const char *encoding = method ? method_getTypeEncoding(method) : NULL;
            if (encoding && strcmp(encoding, "@16@0:8") == 0) {
                id name = [(id<RUINLINEManagedUserCalls>)object displayUserName];
                if ([name isKindOfClass:[NSString class]]) displayName = name;
            }
        }
    } @catch (__unused NSException *exception) {
        displayName = @"";
    } @finally {
        gDisplayNameHookDepth--;
    }
    return @{@"kind": [NSString stringWithUTF8String:type->kind],
             @"identifier": identifier, @"displayName": displayName};
}

static NSDictionary<NSString *, NSString *> *RUINSanitizedLocalNames(id value, BOOL byIdentity)
{
    if (![value isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    NSDictionary *saved = (NSDictionary *)value;
    for (id key in saved) {
        id alias = saved[key];
        if ([key isKindOfClass:[NSString class]] && [(NSString *)key length] > 0 &&
            (!byIdentity || RUINValidIdentityKey(key, NO)) &&
            [alias isKindOfClass:[NSString class]] && (byIdentity || [(NSString *)alias length] > 0)) {
            result[key] = [alias copy];
        }
    }
    return [result copy];
}

static NSString *RUINValidAccountMID(id value)
{
    if (![value isKindOfClass:NSString.class] || [value length] != 33 || ![value hasPrefix:@"u"]) return nil;
    NSString *mid = value;
    for (NSUInteger i = 1; i < mid.length; i++) {
        unichar c = [mid characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return nil;
    }
    return [mid copy];
}

static void RUINReloadSettings(BOOL supported, NSString *activeAccountMID, BOOL activation)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *names = supported ? RUINSanitizedLocalNames([defaults objectForKey:RUINLocalNamesDefaultsKey], NO) : @{};
    NSDictionary *identities = supported ? RUINSanitizedLocalNames([defaults objectForKey:RUINLocalNamesByIdentityDefaultsKey], YES) : @{};
    NSMutableSet *exceptions = [NSMutableSet set];
    id storedExceptions = [defaults objectForKey:RUINReadExceptionsDefaultsKey];
    BOOL exceptionsValid = storedExceptions == nil || [storedExceptions isKindOfClass:NSArray.class];
    if (supported && [storedExceptions isKindOfClass:[NSArray class]]) {
        for (id key in storedExceptions) {
            if (RUINValidIdentityKey(key, YES)) [exceptions addObject:[key copy]];
            else exceptionsValid = NO;
        }
    }
    BOOL enabled = supported && [defaults boolForKey:RUINReadControlEnabledDefaultsKey];
    BOOL markOnReply = supported && [defaults boolForKey:RUINMarkReadOnReplyDefaultsKey];
    NSMutableDictionary *boundaries = [NSMutableDictionary dictionary];
    NSSet *exceptionSnapshot = [exceptions copy];
    NSString *account = activation ? RUINValidAccountMID(activeAccountMID) : nil;
    os_unfair_lock_lock(&gStateLock);
    BOOL keepReplyState = activation && exceptionsValid && gReadPolicyValid &&
        account && [account isEqualToString:gActiveAccountMID] &&
        supported == atomic_load(&gTargetSupported) && enabled == atomic_load(&gReadControlEnabled) &&
        markOnReply == atomic_load(&gMarkReadOnReply) && [exceptionSnapshot isEqualToSet:gReadExceptions];
    gLocalNames = names;
    gLocalNamesByIdentity = identities;
    gReadExceptions = exceptionSnapshot;
    if (!keepReplyState) {
        gReplyBoundaries = boundaries;
        gReadPolicyGeneration++;
    }
    if (activation) gActiveAccountMID = account;
    gReadPolicyValid = exceptionsValid;
    atomic_store(&gTargetSupported, supported);
    atomic_store(&gReadControlEnabled, enabled);
    atomic_store(&gMarkReadOnReply, markOnReply);
    os_unfair_lock_unlock(&gStateLock);
}

void RUINSetLocalName(NSString *identityKey, NSString *alias)
{
    if (!RUINValidIdentityKey(identityKey, NO) || ![alias isKindOfClass:[NSString class]]) return;
    os_unfair_lock_lock(&gInstallLock);
    @try {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSMutableDictionary *names = [RUINSanitizedLocalNames([defaults objectForKey:RUINLocalNamesByIdentityDefaultsKey], YES) mutableCopy];
        // Empty string masks the legacy fallback for this explicitly edited identity.
        names[identityKey] = [alias copy];
        [defaults setObject:names forKey:RUINLocalNamesByIdentityDefaultsKey];
        RUINReloadSettings(RUINTargetMatches(NULL, NULL, NULL), nil, NO);
    } @finally {
        os_unfair_lock_unlock(&gInstallLock);
    }
}

static id RUINApplyLocalAlias(id object, id visibleName)
{
    if (![visibleName isKindOfClass:[NSString class]] || [(NSString *)visibleName length] == 0)
        return visibleName;
    NSString *identityKey = RUINIdentityKeyForObject(object, NO);
    os_unfair_lock_lock(&gStateLock);
    NSDictionary<NSString *, NSString *> *names = gLocalNames;
    NSDictionary<NSString *, NSString *> *identities = gLocalNamesByIdentity;
    os_unfair_lock_unlock(&gStateLock);
    NSString *identityAlias = identityKey ? identities[identityKey] : nil;
    if (identityAlias) return identityAlias.length ? identityAlias : visibleName;
    NSString *alias = names[visibleName];
    return alias ?: visibleName;
}

BOOL RUINShouldSuppressReadForChat(id chat)
{
    if (!atomic_load(&gReadControlEnabled)) return NO;
    NSString *identityKey = RUINIdentityKeyForObject(chat, YES);
    if (!identityKey) return NO; // Never substitute a display name for a missing ID.
    long long boundary = 0;
    BOOL hasBoundary = atomic_load(&gMarkReadOnReply) && RUINReceivedBoundary(chat, &boundary);
    os_unfair_lock_lock(&gStateLock);
    BOOL suppress = atomic_load(&gTargetSupported) && atomic_load(&gReadControlEnabled);
    if ([gReadExceptions containsObject:identityKey]) suppress = NO;
    NSNumber *allowedBoundary = gReplyBoundaries[identityKey];
    if (allowedBoundary && atomic_load(&gMarkReadOnReply)) {
        if (hasBoundary && allowedBoundary.longLongValue == boundary) suppress = NO;
        else [gReplyBoundaries removeObjectForKey:identityKey];
    }
    os_unfair_lock_unlock(&gStateLock);
    return suppress;
}

BOOL RUINReadPolicyHasIdentity(id chat) { return RUINIdentityKeyForObject(chat, YES).length > 0; }

NSDictionary *RUINCaptureReadOnReplyToken(id chat)
{
    if (!atomic_load(&gReadControlEnabled) || !atomic_load(&gMarkReadOnReply)) return @{};
    NSString *identityKey = RUINIdentityKeyForObject(chat, YES);
    long long boundary = 0;
    if (!identityKey || !RUINReceivedBoundary(chat, &boundary)) return @{};
    NSDictionary *token = @{};
    os_unfair_lock_lock(&gStateLock);
    if (atomic_load(&gTargetSupported) && atomic_load(&gReadControlEnabled) && atomic_load(&gMarkReadOnReply) &&
        ![gReadExceptions containsObject:identityKey])
        token = @{@"identity":identityKey, @"boundary":@(boundary), @"generation":@(gReadPolicyGeneration)};
    os_unfair_lock_unlock(&gStateLock);
    return token;
}

BOOL RUINAllowReadAfterUserReplyWithToken(id chat, NSDictionary *token)
{
    if (![token isKindOfClass:NSDictionary.class] || ![token[@"identity"] isKindOfClass:NSString.class] ||
        ![token[@"boundary"] isKindOfClass:NSNumber.class] || ![token[@"generation"] isKindOfClass:NSNumber.class]) return NO;
    NSString *identityKey = RUINIdentityKeyForObject(chat, YES);
    long long boundary = 0;
    if (!identityKey || ![identityKey isEqual:token[@"identity"]] || !RUINReceivedBoundary(chat, &boundary) ||
        boundary != [token[@"boundary"] longLongValue]) return NO;
    BOOL allowed = NO;
    os_unfair_lock_lock(&gStateLock);
    if (atomic_load(&gTargetSupported) && atomic_load(&gReadControlEnabled) && atomic_load(&gMarkReadOnReply) &&
        ![gReadExceptions containsObject:identityKey] &&
        [token[@"generation"] unsignedLongLongValue] == gReadPolicyGeneration) {
        gReplyBoundaries[identityKey] = @(boundary);
        allowed = YES;
    }
    os_unfair_lock_unlock(&gStateLock);
    return allowed;
}

NSDictionary *RUINRevokeReadAfterUserReply(id chat)
{
    NSString *identityKey = RUINIdentityKeyForObject(chat, YES);
    long long boundary = 0;
    BOOL validBoundary = RUINReceivedBoundary(chat, &boundary);
    if (!identityKey) return @{};
    NSDictionary *token = @{};
    os_unfair_lock_lock(&gStateLock);
    NSNumber *allowed = gReplyBoundaries[identityKey];
    if (allowed && validBoundary && allowed.longLongValue == boundary)
        token = @{@"identity":identityKey, @"boundary":allowed, @"generation":@(gReadPolicyGeneration)};
    [gReplyBoundaries removeObjectForKey:identityKey];
    os_unfair_lock_unlock(&gStateLock);
    return token;
}

BOOL RUINReadOnReplyTokenNeedsRearm(NSDictionary *token)
{
    if (![token isKindOfClass:NSDictionary.class] || ![token[@"identity"] isKindOfClass:NSString.class] || ![token[@"boundary"] isKindOfClass:NSNumber.class] ||
        ![token[@"generation"] isKindOfClass:NSNumber.class]) return NO;
    os_unfair_lock_lock(&gStateLock);
    NSNumber *allowed = gReplyBoundaries[token[@"identity"]];
    BOOL rearm = atomic_load(&gTargetSupported) && atomic_load(&gReadControlEnabled) &&
        [token[@"generation"] unsignedLongLongValue] == gReadPolicyGeneration &&
        ![gReadExceptions containsObject:token[@"identity"]] &&
        (!allowed || allowed.longLongValue == [token[@"boundary"] longLongValue]);
    os_unfair_lock_unlock(&gStateLock);
    return rearm;
}

BOOL RUINReadOnReplyTokenIsAllowed(NSDictionary *token)
{
    if (![token isKindOfClass:NSDictionary.class] || ![token[@"identity"] isKindOfClass:NSString.class] ||
        ![token[@"boundary"] isKindOfClass:NSNumber.class] || ![token[@"generation"] isKindOfClass:NSNumber.class]) return NO;
    os_unfair_lock_lock(&gStateLock);
    NSNumber *allowed = gReplyBoundaries[token[@"identity"]];
    BOOL current = atomic_load(&gTargetSupported) && atomic_load(&gReadControlEnabled) && atomic_load(&gMarkReadOnReply) &&
        [token[@"generation"] unsignedLongLongValue] == gReadPolicyGeneration &&
        ![gReadExceptions containsObject:token[@"identity"]] && allowed &&
        allowed.longLongValue == [token[@"boundary"] longLongValue];
    os_unfair_lock_unlock(&gStateLock);
    return current;
}

void RUINAllowReadAfterUserReply(id chat)
{
    (void)RUINAllowReadAfterUserReplyWithToken(chat, RUINCaptureReadOnReplyToken(chat));
}

// Each group owns one original IMP, including inherited Core Data methods.
%group RUINManagedChatRead
%hook RUINManagedChatReadTarget
- (BOOL)canMarkChatAsReadToServer
{
    atomic_fetch_add_explicit(&gManagedChatReadHook.calls, 1, memory_order_relaxed);
    if (RUINShouldSuppressReadForChat(self)) return NO;
    return %orig;
}
%end
%end

%group RUINSquareChatRead
%hook RUINSquareChatReadTarget
- (BOOL)canMarkChatAsReadToServer
{
    atomic_fetch_add_explicit(&gSquareChatReadHook.calls, 1, memory_order_relaxed);
    if (RUINShouldSuppressReadForChat(self)) return NO;
    return %orig;
}
%end
%end

%group RUINUserDisplayName
%hook RUINUserDisplayNameTarget
- (id)displayUserName
{
    atomic_fetch_add_explicit(&gUserDisplayNameHook.calls, 1, memory_order_relaxed);
    BOOL outermost = gDisplayNameHookDepth++ == 0;
    id name = nil;
    @try {
        name = %orig;
        if (outermost) name = RUINApplyLocalAlias(self, name);
    } @finally {
        gDisplayNameHookDepth--;
    }
    return name;
}
%end
%end

%group RUINUserDisplayNameNoAddressBook
%hook RUINUserDisplayNameNoAddressBookTarget
- (id)displayUserNameNoAddressBook
{
    atomic_fetch_add_explicit(&gUserDisplayNameNoAddressBookHook.calls, 1, memory_order_relaxed);
    BOOL outermost = gDisplayNameHookDepth++ == 0;
    id name = nil;
    @try {
        name = %orig;
        if (outermost) name = RUINApplyLocalAlias(self, name);
    } @finally {
        gDisplayNameHookDepth--;
    }
    return name;
}
%end
%end

%group RUINUnifiedGroupDisplayName
%hook RUINUnifiedGroupDisplayNameTarget
- (id)displayNameWithMyProfileInfo:(id)profileInfo inUserContext:(id)userContext
{
    atomic_fetch_add_explicit(&gUnifiedGroupDisplayNameHook.calls, 1, memory_order_relaxed);
    BOOL outermost = gDisplayNameHookDepth++ == 0;
    id name = nil;
    @try {
        name = %orig(profileInfo, userContext);
        if (outermost) name = RUINApplyLocalAlias(self, name);
    } @finally {
        gDisplayNameHookDepth--;
    }
    return name;
}
%end
%end

%group RUINManagedChatGroupName
%hook RUINManagedChatGroupNameTarget
- (id)groupNameWithContext:(id)context
{
    atomic_fetch_add_explicit(&gManagedChatGroupNameHook.calls, 1, memory_order_relaxed);
    BOOL outermost = gDisplayNameHookDepth++ == 0;
    id name = nil;
    @try {
        name = %orig(context);
        if (outermost) name = RUINApplyLocalAlias(self, name);
    } @finally {
        gDisplayNameHookDepth--;
    }
    return name;
}
%end
%end

%group RUINSquareChatGroupName
%hook RUINSquareChatGroupNameTarget
- (id)groupNameWithContext:(id)context
{
    atomic_fetch_add_explicit(&gSquareChatGroupNameHook.calls, 1, memory_order_relaxed);
    BOOL outermost = gDisplayNameHookDepth++ == 0;
    id name = nil;
    @try {
        name = %orig(context);
        if (outermost) name = RUINApplyLocalAlias(self, name);
    } @finally {
        gDisplayNameHookDepth--;
    }
    return name;
}
%end
%end

static void RUINInstallHook(RUINHook *hook)
{
    Class cls = objc_getClass(hook->className);
    if (!cls) {
        atomic_store(&hook->status, RUINHookMissingClass);
        return;
    }
    SEL selector = sel_registerName(hook->selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        atomic_store(&hook->status, RUINHookMissingSelector);
        return;
    }
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || strcmp(encoding, hook->encoding) != 0) {
        atomic_store(&hook->status, RUINHookEncodingMismatch);
        return;
    }

    IMP original = method_getImplementation(method);
    if (!original) {
        atomic_store(&hook->status, RUINHookInstallFailed);
        return;
    }
    if (hook == &gManagedChatReadHook) {
        %init(RUINManagedChatRead, RUINManagedChatReadTarget = cls);
    } else if (hook == &gSquareChatReadHook) {
        %init(RUINSquareChatRead, RUINSquareChatReadTarget = cls);
    } else if (hook == &gUserDisplayNameHook) {
        %init(RUINUserDisplayName, RUINUserDisplayNameTarget = cls);
    } else if (hook == &gUserDisplayNameNoAddressBookHook) {
        %init(RUINUserDisplayNameNoAddressBook, RUINUserDisplayNameNoAddressBookTarget = cls);
    } else if (hook == &gUnifiedGroupDisplayNameHook) {
        %init(RUINUnifiedGroupDisplayName, RUINUnifiedGroupDisplayNameTarget = cls);
    } else if (hook == &gManagedChatGroupNameHook) {
        %init(RUINManagedChatGroupName, RUINManagedChatGroupNameTarget = cls);
    } else if (hook == &gSquareChatGroupNameHook) {
        %init(RUINSquareChatGroupName, RUINSquareChatGroupNameTarget = cls);
    } else {
        atomic_store(&hook->status, RUINHookInstallFailed);
        return;
    }
    atomic_store(&hook->status, RUINHookInstalled);
}

static void RUINRefreshFeatures(NSString *activeAccountMID, BOOL activation)
{
    os_unfair_lock_lock(&gInstallLock);
    @try {
        BOOL supported = RUINTargetMatches(NULL, NULL, NULL);
        RUINReloadSettings(supported, activeAccountMID, activation);
        if (!supported) {
            for (size_t index = 0; index < sizeof(gHooks) / sizeof(gHooks[0]); index++) {
                if (atomic_load(&gHooks[index]->status) != RUINHookInstalled)
                    atomic_store(&gHooks[index]->status, RUINHookVersionGated);
            }
            return;
        }
        for (size_t index = 0; index < sizeof(gHooks) / sizeof(gHooks[0]); index++) {
            if (atomic_load(&gHooks[index]->status) != RUINHookInstalled)
                RUINInstallHook(gHooks[index]);
        }
    } @finally {
        os_unfair_lock_unlock(&gInstallLock);
    }
}

void RUINInstallFeatures(void) { RUINRefreshFeatures(nil, NO); }

void RUINRefreshFeaturesOnActivation(NSString *accountMID) { RUINRefreshFeatures(accountMID, YES); }

static NSString *RUINStatusName(RUINHookStatus status)
{
    switch (status) {
        case RUINHookVersionGated: return @"version_gated";
        case RUINHookMissingClass: return @"missing_class";
        case RUINHookMissingSelector: return @"missing_selector";
        case RUINHookEncodingMismatch: return @"encoding_mismatch";
        case RUINHookInstallFailed: return @"install_failed";
        case RUINHookInstalled: return @"installed";
        default: return @"not_checked";
    }
}

static NSDictionary *RUINHookDiagnostics(RUINHook *hook)
{
    Class cls = objc_getClass(hook->className);
    SEL selector = sel_registerName(hook->selectorName);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    NSString *runtimeEncoding = encoding ? [NSString stringWithUTF8String:encoding] : @"";
    RUINHookStatus status = (RUINHookStatus)atomic_load(&hook->status);
    return @{
        @"class": [NSString stringWithUTF8String:hook->className],
        @"selector": [NSString stringWithUTF8String:hook->selectorName],
        @"expectedEncoding": [NSString stringWithUTF8String:hook->encoding],
        @"runtimeEncoding": runtimeEncoding,
        @"installStatus": RUINStatusName(status),
        @"installed": @(status == RUINHookInstalled),
        @"callCount": @(atomic_load_explicit(&hook->calls, memory_order_relaxed))
    };
}

NSDictionary *RUINFeatureDiagnostics(void)
{
    BOOL bundleMatches = NO, versionMatches = NO, buildMatches = NO;
    BOOL supported = RUINTargetMatches(&bundleMatches, &versionMatches, &buildMatches);
    NSDictionary *info = [NSBundle mainBundle].infoDictionary ?: @{};
    NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:[NSString class]]
        ? info[@"CFBundleShortVersionString"] : @"";
    NSString *build = [info[@"CFBundleVersion"] isKindOfClass:[NSString class]]
        ? info[@"CFBundleVersion"] : @"";
    NSMutableDictionary *hooks = [NSMutableDictionary dictionary];
    for (size_t index = 0; index < sizeof(gHooks) / sizeof(gHooks[0]); index++) {
        RUINHook *hook = gHooks[index];
        NSString *key = [NSString stringWithFormat:@"%s -%s", hook->className, hook->selectorName];
        hooks[key] = RUINHookDiagnostics(hook);
    }

    os_unfair_lock_lock(&gStateLock);
    NSUInteger localNameCount = gLocalNames.count;
    NSUInteger identityNameCount = gLocalNamesByIdentity.count;
    NSUInteger exceptionCount = gReadExceptions.count;
    NSUInteger replyBoundaryCount = gReplyBoundaries.count;
    uint64_t policyGeneration = gReadPolicyGeneration;
    BOOL activationAccountBound = gActiveAccountMID != nil;
    BOOL policyValidated = gReadPolicyValid;
    os_unfair_lock_unlock(&gStateLock);

    NSMutableArray *identityMetadata = [NSMutableArray array];
    for (size_t index = 0; index < sizeof(gIdentityTypes) / sizeof(gIdentityTypes[0]); index++) {
        const RUINIdentityType *type = &gIdentityTypes[index];
        [identityMetadata addObject:@{
            @"class": [NSString stringWithUTF8String:type->className],
            @"kind": [NSString stringWithUTF8String:type->kind],
            @"identifierProperty": [NSString stringWithUTF8String:type->identifierProperty],
            @"declaredType": @"NSString",
            @"guard": @"property type + no-argument object getter + live Core Data schema"
        }];
    }

    return @{
        @"target": @{
            @"bundleAccepted": @(bundleMatches),
            @"version": version,
            @"versionMatches": @(versionMatches),
            @"build": build,
            @"buildMatches": @(buildMatches),
            @"supported": @(supported),
            @"fullyVerified": @(RUINFullySupportedTargetMatchesInfo(info))
        },
        @"readControl": @{
            @"enabled": @(atomic_load(&gReadControlEnabled)),
            @"defaultOffKey": RUINReadControlEnabledDefaultsKey,
            @"exceptionsKey": RUINReadExceptionsDefaultsKey,
            @"exceptionCount": @(exceptionCount),
            @"unresolvedIdentityPolicy": @"original predicate (fail open)",
            @"readOnReply": @{
                @"enabled": @(atomic_load(&gMarkReadOnReply)),
                @"defaultsKey": RUINMarkReadOnReplyDefaultsKey,
                @"allowanceCount": @(replyBoundaryCount),
                @"policyGeneration": @(policyGeneration),
                @"activationAccountBound": @(activationAccountBound),
                @"policyValidated": @(policyValidated),
                @"boundaryProperty": @"lastReceivedMessageID (Int64)",
                @"automaticEventHookInstalled": @(atomic_load(&gReplyObserverInstalled)),
                @"reason": atomic_load(&gReplyObserverInstalled)
                    ? @"Explicit send entry captures a boundary; its sent notification can allow only that unchanged boundary. Prior received-boundary observation rearms the UI gate before native change observers."
                    : @"No send-entry observer attached. Allows original predicate only when the parent supplies a committed reply on the chat owning queue."
            },
            @"hooks": @{
                @"ManagedChat": RUINHookDiagnostics(&gManagedChatReadHook),
                @"ManagedSquareChat": RUINHookDiagnostics(&gSquareChatReadHook)
            }
        },
        @"localNames": @{
            @"defaultsKey": RUINLocalNamesDefaultsKey,
            @"ruleCount": @(localNameCount),
            @"identityDefaultsKey": RUINLocalNamesByIdentityDefaultsKey,
            @"identityRuleCount": @(identityNameCount),
            @"identityMetadata": identityMetadata,
            @"migration": @"identity rules take precedence; empty identity alias masks legacy fallback; legacy visible-name rules are not auto-migrated",
            @"hooks": @{
                @"ManagedUser.displayUserName": RUINHookDiagnostics(&gUserDisplayNameHook),
                @"ManagedUser.displayUserNameNoAddressBook": RUINHookDiagnostics(&gUserDisplayNameNoAddressBookHook),
                @"ManagedUnifiedGroup.displayNameWithMyProfileInfo:inUserContext:": RUINHookDiagnostics(&gUnifiedGroupDisplayNameHook),
                @"ManagedChat.groupNameWithContext:": RUINHookDiagnostics(&gManagedChatGroupNameHook),
                @"ManagedSquareChat.groupNameWithContext:": RUINHookDiagnostics(&gSquareChatGroupNameHook)
            }
        },
        @"sendConfirmation": @{
            @"implemented": @NO,
            @"scope": @"Features module",
            @"handledExternally": @YES,
            @"reason": @"Foreground send approval belongs to the confirmation module; Features installs no model send hook."
        },
        @"hooks": hooks
    };
}

void RUINSetReplyObserverInstalled(BOOL installed) { atomic_store(&gReplyObserverInstalled, installed); }
