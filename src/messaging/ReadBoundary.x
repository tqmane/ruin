%config(generator=internal);

#import "MessagingPrivateAPI.h"
#import "ReadBoundary.h"
#import "Features.h"
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

static NSMutableDictionary *installedBoundaries;
static NSMutableDictionary *installedImplementations;
static atomic_ulong boundaryReads, heldBoundaries, unknownPolicies, policyErrors;
static atomic_ulong pendingFetchQueries, pendingRowsSuppressed;
static BOOL fetchFilterInstalled;
static _Thread_local unsigned boundaryDepth;
static atomic_ulong nativeSiteReads;
static uintptr_t nativeReadCaller;
#if defined(RUIN_BOUNDARY_HOST_CHECK)
static BOOL testNativeCaller = YES;
void RUINBoundaryTestNativeCaller(BOOL value) { testNativeCaller = value; }
#endif

static void VerifyNativeReadSite(void) {
#if defined(RUIN_BOUNDARY_HOST_CHECK)
    nativeReadCaller = 1;
#else
    // The only getter result we replace is the saved comparison in mark_chat.
    // Other readers (including sync acknowledgements) see actual stored state.
    const struct mach_header_64 *header = (const void *)_dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 || header->sizeofcmds > 1024 * 1024) return;
    uintptr_t slide = (uintptr_t)_dyld_get_image_vmaddr_slide(0);
    const uint8_t *p = (const void *)(header + 1), *end = p + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds && p + sizeof(struct load_command) <= end; i++) {
        const struct load_command *command = (const void *)p;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - p)) return;
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const void *)p;
            if (!strcmp(segment->segname, "__TEXT") && segment->vmaddr <= 0x103e15638 &&
                segment->vmaddr + segment->vmsize >= 0x103e15644) {
                uint32_t words[3]; memcpy(words, (const void *)(slide + 0x103e15638), sizeof(words));
                if (words[0] == 0xaa1603e0 && words[1] == 0x95593b59 && words[2] == 0xaa0003f5)
                    nativeReadCaller = slide + 0x103e15640;
                return;
            }
        }
        p += command->cmdsize;
    }
#endif
}

static BOOL LongLongProperty(Class cls, const char *name) {
    objc_property_t property = class_getProperty(cls, name);
    char *type = property ? property_copyAttributeValue(property, "T") : NULL;
    BOOL valid = type && !strcmp(type, "q"); free(type); return valid;
}
static long long PrimitiveBoundary(NSManagedObject *object, NSString *key) {
    [object willAccessValueForKey:key];
    id number;
    @try { number = [object primitiveValueForKey:key]; }
    @finally { [object didAccessValueForKey:key]; }
    return [number isKindOfClass:NSNumber.class] ? [number longLongValue] : 0;
}
static BOOL ShouldHold(NSManagedObject *chat) {
    if (![NSUserDefaults.standardUserDefaults boolForKey:RUINReadControlEnabledDefaultsKey]) return NO;
    if (RUINReadPolicyHasIdentity(chat)) return RUINShouldSuppressReadForChat(chat);
    // A thread inherits the parent's explicit exemption. It never inherits an
    // unrelated parent reply allowance; thread-reply integration remains pending.
    if (chat.entity.relationshipsByName[@"parentChat"]) {
        id parent = [chat valueForKey:@"parentChat"];
        if ([parent isKindOfClass:NSManagedObject.class] && ((NSManagedObject *)parent).entity.attributesByName[@"mid"]) {
            id mid = [parent valueForKey:@"mid"];
            if ([mid isKindOfClass:NSString.class] && [mid length]) {
                NSString *key = [@"squareChat:" stringByAppendingString:mid];
                return ![[NSUserDefaults.standardUserDefaults arrayForKey:RUINReadExceptionsDefaultsKey] containsObject:key];
            }
        }
    }
    atomic_fetch_add(&unknownPolicies, 1);
    return YES;
}

// LINE26.16's pending-receipt producer uses this exact field comparison in
// its fetch predicate. Match the AST, never user text or a broad chat query.
static BOOL PendingComparison(NSComparisonPredicate *predicate, BOOL negate) {
    if (predicate.comparisonPredicateModifier != NSDirectPredicateModifier ||
        predicate.leftExpression.expressionType != NSKeyPathExpressionType ||
        predicate.rightExpression.expressionType != NSKeyPathExpressionType) return NO;
    NSString *left = predicate.leftExpression.keyPath, *right = predicate.rightExpression.keyPath;
    NSPredicateOperatorType op = predicate.predicateOperatorType;
    if (negate) {
        if (op == NSLessThanOrEqualToPredicateOperatorType) op = NSGreaterThanPredicateOperatorType;
        else if (op == NSGreaterThanOrEqualToPredicateOperatorType) op = NSLessThanPredicateOperatorType;
        else return NO;
    }
    return ([left isEqual:@"readUpToMessageIDSynced"] && [right isEqual:@"readUpToMessageID"] && op == NSLessThanPredicateOperatorType) ||
           ([left isEqual:@"readUpToMessageID"] && [right isEqual:@"readUpToMessageIDSynced"] && op == NSGreaterThanPredicateOperatorType);
}
static BOOL ImpliesPendingRead(NSPredicate *predicate) {
    if ([predicate isKindOfClass:NSComparisonPredicate.class]) return PendingComparison((id)predicate, NO);
    if (![predicate isKindOfClass:NSCompoundPredicate.class]) return NO;
    NSCompoundPredicate *compound = (id)predicate;
    if (!compound.subpredicates.count) return NO;
    if (compound.compoundPredicateType == NSNotPredicateType)
        return compound.subpredicates.count == 1 && [compound.subpredicates.firstObject isKindOfClass:NSComparisonPredicate.class] && PendingComparison(compound.subpredicates.firstObject, YES);
    BOOL and = compound.compoundPredicateType == NSAndPredicateType;
    for (NSPredicate *child in compound.subpredicates) {
        BOOL matches = ImpliesPendingRead(child);
        if (and && matches) return YES;
        if (!and && !matches) return NO;
    }
    return !and;
}
static BOOL KnownChat(id object) {
    static const char *names[] = {"ManagedChat", "ManagedSquareChat", "ManagedSquareChatThread"};
    for (unsigned int i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        Class cls = objc_getClass(names[i]);
        if (cls && [object isKindOfClass:cls]) return YES;
    }
    return NO;
}
%group RUINBoundaryFetch
%hook NSManagedObjectContext
- (NSArray *)executeFetchRequest:(NSFetchRequest *)request error:(NSError **)error {
    NSArray *result = %orig;
    if (!result || request.resultType != NSManagedObjectResultType || !ImpliesPendingRead(request.predicate)) return result;
    atomic_fetch_add(&pendingFetchQueries, 1);
    if (![NSUserDefaults.standardUserDefaults boolForKey:RUINReadControlEnabledDefaultsKey]) return result;
    NSMutableArray *allowed = [NSMutableArray arrayWithCapacity:result.count];
    for (id object in result) {
        BOOL hold = NO;
        if (KnownChat(object)) {
            hold = YES;
            @try { hold = ShouldHold(object); }
            @catch (__unused NSException *exception) { atomic_fetch_add(&policyErrors, 1); }
        }
        if (hold) atomic_fetch_add(&pendingRowsSuppressed, 1); else [allowed addObject:object];
    }
    return allowed.count == result.count ? result : [allowed copy];
}
%end
%end

static long long ReadSyncedBoundary(NSManagedObject *chat, IMP original, uintptr_t caller) {
    atomic_fetch_add(&boundaryReads, 1);
    BOOL outermost = boundaryDepth++ == 0;
    @try {
        long long actual = original ? ((long long (*)(id, SEL))original)(chat, sel_registerName("readUpToMessageIDSynced"))
                                    : PrimitiveBoundary(chat, @"readUpToMessageIDSynced");
        if (!outermost) return actual;
#if defined(RUIN_BOUNDARY_HOST_CHECK)
        BOOL nativeSite = testNativeCaller;
#else
        BOOL nativeSite = nativeReadCaller && caller == nativeReadCaller;
#endif
        (void)caller;
        if (!nativeSite) return actual;
        atomic_fetch_add(&nativeSiteReads, 1);
        @try {
            NSAttributeDescription *read = chat.entity.attributesByName[@"readUpToMessageID"];
            if (read.attributeType != NSInteger64AttributeType || !ShouldHold(chat)) return actual;
            long long local = PrimitiveBoundary(chat, @"readUpToMessageID");
            // The immediate sender reads synced BEFORE advancing localRead.
            // Cover the newly received boundary as well as already-local reads.
            NSAttributeDescription *received = chat.entity.attributesByName[@"lastReceivedMessageID"];
            if (received.attributeType == NSInteger64AttributeType)
                local = MAX(local, PrimitiveBoundary(chat, @"lastReceivedMessageID"));
            if (local > actual) { atomic_fetch_add(&heldBoundaries, 1); return local; }
        } @catch (__unused NSException *exception) { atomic_fetch_add(&policyErrors, 1); }
        return actual;
    } @finally { boundaryDepth--; }
}
// Core Data creates accessor subclasses after model loading. A Logos %orig slot
// belongs to one compile-time hook and cannot hold a different original for
// every runtime class. These two groups deliberately never consume %orig:
// installation is generated by Logos; original accessors are held per class.
// The thread-local receiver/class cursor preserves a subclass getter calling
// its hooked superclass, without recursively selecting the subclass original.
@interface RUINBoundaryAccessorState : NSObject
@property(nonatomic, assign) Class owner;
@property(nonatomic, assign) IMP original;
@end
@implementation RUINBoundaryAccessorState @end
static char boundaryAccessorStateKey;
static IMP boundaryExistingEntry, boundaryMissingEntry;
static _Thread_local __unsafe_unretained id boundaryActiveReceiver;
static _Thread_local Class boundaryActiveClass;

static long long ReadRuntimeBoundary(NSManagedObject *object, uintptr_t caller) {
    Class previousClass = boundaryActiveClass;
    __unsafe_unretained id previousReceiver = boundaryActiveReceiver;
    Class search = previousReceiver == object && previousClass ?
        class_getSuperclass(previousClass) : object_getClass(object);
    RUINBoundaryAccessorState *state = nil;
    for (Class cls = search; cls; cls = class_getSuperclass(cls)) {
        state = objc_getAssociatedObject(cls, &boundaryAccessorStateKey);
        if (state) break;
    }
    if (!state) return PrimitiveBoundary(object, @"readUpToMessageIDSynced");
    boundaryActiveClass = state.owner;
    boundaryActiveReceiver = object;
    @try { return ReadSyncedBoundary(object, state.original, caller); }
    @finally { boundaryActiveClass = previousClass; boundaryActiveReceiver = previousReceiver; }
}

%group RUINBoundaryExisting
%hook RUINBoundaryExistingAccessor
- (long long)readUpToMessageIDSynced {
    uintptr_t caller = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
    return ReadRuntimeBoundary((id)self, caller);
}
%end
%end

%group RUINBoundaryMissing
%hook RUINBoundaryMissingAccessor
%new(q16@0:8)
- (long long)readUpToMessageIDSynced {
    uintptr_t caller = (uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0));
    return ReadRuntimeBoundary((id)self, caller);
}
%end
%end

static void InstallBoundaryAccessor(Class cls) {
    NSString *name = NSStringFromClass(cls);
    if (!LongLongProperty(cls, "readUpToMessageIDSynced") || !LongLongProperty(cls, "readUpToMessageID")) {
        installedBoundaries[name] = @"missing_verified_properties";
        return;
    }
    SEL selector = sel_registerName("readUpToMessageIDSynced");
    Method method = class_getInstanceMethod(cls, selector);
    IMP current = method ? method_getImplementation(method) : NULL;
    NSValue *installed = installedImplementations[name];
    if (installed) {
        // A later swizzler may retain our entry in its original chain.
        // Rebinding that same entry to a new original would also change
        // the old chain and lose this class's getter. Successful class
        // bindings stay immutable; a native replacement is left in place.
        if (current != installed.pointerValue) installedBoundaries[name] = @"accessor_changed_after_install";
        else {
            RUINBoundaryAccessorState *state = objc_getAssociatedObject(cls, &boundaryAccessorStateKey);
            installedBoundaries[name] = state.original ? @"installed_original_accessor" : @"installed_coredata_accessor";
        }
        return;
    }
    if (method && strcmp(method_getTypeEncoding(method), "q16@0:8") && strcmp(method_getTypeEncoding(method), "q@:")) {
        installedBoundaries[name] = @"encoding_mismatch";
        return;
    }
    // An inherited RUIN entry already resolves the closest registered
    // ancestor. Only native overrides need an additional class binding.
    if (current && (current == boundaryExistingEntry || current == boundaryMissingEntry)) {
        installedBoundaries[name] = @"inherited_boundary_accessor";
        return;
    }
    RUINBoundaryAccessorState *state = [RUINBoundaryAccessorState new];
    state.owner = cls;
    state.original = current;
    objc_setAssociatedObject(cls, &boundaryAccessorStateKey, state, OBJC_ASSOCIATION_RETAIN);
    if (current) {
        %init(RUINBoundaryExisting, RUINBoundaryExistingAccessor = cls);
    } else {
        %init(RUINBoundaryMissing, RUINBoundaryMissingAccessor = cls);
    }
    IMP replacement = class_getMethodImplementation(cls, selector);
    if (!replacement || replacement == current) {
        objc_setAssociatedObject(cls, &boundaryAccessorStateKey, nil, OBJC_ASSOCIATION_RETAIN);
        installedBoundaries[name] = @"installation_failed";
        return;
    }
    if (current) boundaryExistingEntry = replacement;
    else boundaryMissingEntry = replacement;
    installedImplementations[name] = [NSValue valueWithPointer:replacement];
    installedBoundaries[name] = current ? @"installed_original_accessor" : @"installed_coredata_accessor";
}

void RUINInstallReadBoundary(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    if (![info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier] ||
        ![info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] ||
        ![info[@"CFBundleVersion"] isEqual:RUINTargetBuild]) return;
    @synchronized (NSManagedObjectContext.class) {
        if (!installedBoundaries) installedBoundaries = [NSMutableDictionary dictionary];
        if (!installedImplementations) installedImplementations = [NSMutableDictionary dictionary];
        if (!nativeReadCaller) VerifyNativeReadSite();
        if (!fetchFilterInstalled) {
            Method fetch = class_getInstanceMethod(NSManagedObjectContext.class, @selector(executeFetchRequest:error:));
            NSMethodSignature *signature = fetch ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(fetch)] : nil;
            if (signature.numberOfArguments == 4 && signature.methodReturnType[0] == '@' &&
                [signature getArgumentTypeAtIndex:2][0] == '@' && !strcmp([signature getArgumentTypeAtIndex:3], "^@") &&
                method_getImplementation(fetch)) {
                %init(RUINBoundaryFetch);
                fetchFilterInstalled = YES;
            }
        }
        NSArray *baseNames = @[@"ManagedChat", @"ManagedSquareChat", @"ManagedSquareChatThread"];
        NSMutableArray *targets = [NSMutableArray array];
        for (NSString *baseName in baseNames) {
            Class base = objc_getClass(baseName.UTF8String);
            if (base) [targets addObject:base];
            else installedBoundaries[baseName] = @"class_not_loaded";
        }
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        for (unsigned int i = 0; i < count; i++) {
            for (Class parent = class_getSuperclass(classes[i]); parent; parent = class_getSuperclass(parent)) {
                if ([targets containsObject:parent]) {
                    if (![targets containsObject:classes[i]]) [targets addObject:classes[i]];
                    break;
                }
            }
        }
        free(classes);
        for (Class cls in targets) InstallBoundaryAccessor(cls);
    }
}
NSDictionary *RUINReadBoundaryDiagnostics(void) {
    return @{@"accessors":installedBoundaries ?: @{}, @"reads":@(atomic_load(&boundaryReads)),
        @"nativeReadSiteVerified":@(nativeReadCaller != 0), @"nativeReadSiteReads":@(atomic_load(&nativeSiteReads)),
        @"getterScope":@"verified native pre-advance comparison only; other consumers see actual synced value",
        @"pendingFetchFilterInstalled":@(fetchFilterInstalled), @"pendingFetchQueries":@(atomic_load(&pendingFetchQueries)),
        @"pendingRowsSuppressed":@(atomic_load(&pendingRowsSuppressed)),
        @"heldBoundaryReads":@(atomic_load(&heldBoundaries)), @"unknownPoliciesHeld":@(atomic_load(&unknownPolicies)),
        @"policyErrors":@(atomic_load(&policyErrors)), @"writesPrimitiveValues":@NO,
        @"heldBoundary":@"max(actualSynced, localRead, lastReceived); before native local-read advance",
        @"threadReplyAllowanceVerified":@NO, @"receiptSuppressionVerified":@NO};
}
