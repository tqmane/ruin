%config(generator=internal)

#import "TargetMetadata.h"
#import "NativeThemeRegistration.h"
#import "NativeThemeLocalPolicy.h"
#import "BinaryVerifier.h"
#import "ThemeAccountNamespace.h"
#if !defined(RUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK)
#import "RuntimeInspector.h"
#import <execinfo.h>
#import <mach-o/dyld.h>
#endif

#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <errno.h>
#import <limits.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

static NSString *const kRUINRegistrationErrorDomain = @"RUINNativeThemeRegistration";
static NSString *const kRUINWriterThreadKey = @"RUINNativeThemeRegistration.writer";
static os_unfair_lock gCaptureLock = OS_UNFAIR_LOCK_INIT;
static dispatch_once_t gHookOnce;
static dispatch_once_t gQueueOnce;
static NSUInteger gCaptureGeneration;
static id gCaptureToken;
static id gScopeToken;
static __weak NSManagedObjectContext *gNativeContext;
static __weak NSPersistentStoreCoordinator *gNativeCoordinator;
static __weak NSPersistentStore *gNativeStore;
static NSString *gNativeStorePath;
static NSString *gNativeAccount;
static dispatch_queue_t gRegistrationQueue;
static NSURL *RUINNativeApplicationSupportURL(void);
static NSURL *RUINMappedGroupContainerURL(void);
static NSURL *RUINPackageDirectory(NSURL *container, NSString *account, NSString *productID);
#if defined(RUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK)
static NSURL *gTestGroupContainerURL;
static NSURL *gTestApplicationSupportURL;
#endif

enum {
    kRegistrationUnavailable = 1,
    kRegistrationInvalidMetadata,
    kRegistrationWrongModel,
    kRegistrationStaleContext,
    kRegistrationDuplicateProduct
};

@interface RUINNativeCaptureSnapshot : NSObject
@property(nonatomic, strong) id token;
@property(nonatomic, strong) NSManagedObjectContext *context;
@property(nonatomic, strong) NSPersistentStoreCoordinator *coordinator;
@property(nonatomic, strong) NSPersistentStore *store;
@property(nonatomic, copy) NSString *storePath;
@property(nonatomic, copy) NSString *account;
@property(nonatomic) NSUInteger generation;
@end
@implementation RUINNativeCaptureSnapshot
@end

static NSError *RUINRegistrationError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:kRUINRegistrationErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static dispatch_queue_t RUINRegistrationQueue(void)
{
    dispatch_once(&gQueueOnce, ^{
        gRegistrationQueue = dispatch_queue_create("line.ruin.native-theme-registration", DISPATCH_QUEUE_SERIAL);
    });
    return gRegistrationQueue;
}

static BOOL RUINTargetBuildMatches(void)
{
    return RUINTargetMetadataMatchesInfo(NSBundle.mainBundle.infoDictionary);
}

static BOOL RUINAttributeHasType(NSEntityDescription *entity, NSString *name, NSAttributeType type)
{
    NSAttributeDescription *attribute = entity.attributesByName[name];
    return attribute && !attribute.isTransient && attribute.attributeType == type;
}

static BOOL RUINTheme2EntityIsSupported(NSEntityDescription *entity)
{
    return [entity.name isEqual:@"OwnedThemeProduct"] &&
        RUINAttributeHasType(entity, @"productID", NSStringAttributeType) &&
        RUINAttributeHasType(entity, @"installedTime", NSInteger64AttributeType) &&
        RUINAttributeHasType(entity, @"version", NSInteger64AttributeType) &&
        RUINAttributeHasType(entity, @"name", NSStringAttributeType) &&
        RUINAttributeHasType(entity, @"versionString", NSStringAttributeType) &&
        RUINAttributeHasType(entity, @"imagePath", NSStringAttributeType) &&
        RUINAttributeHasType(entity, @"owned", NSBooleanAttributeType) &&
        RUINAttributeHasType(entity, @"defaultOrder", NSInteger16AttributeType) &&
        RUINAttributeHasType(entity, @"grantedByDefault", NSBooleanAttributeType) &&
        RUINAttributeHasType(entity, @"productAvailability", NSInteger16AttributeType);
}

static BOOL RUINStorePathHasNativeNamespace(NSURL *URL, NSString **storePath, NSString **account)
{
    if (!URL.isFileURL) return NO;
    NSString *path = URL.standardizedURL.path;
    NSArray<NSString *> *parts = path.pathComponents;
    if (parts.count < 6) return NO;
    NSUInteger i = parts.count - 4;
    if (![parts[i] isEqual:@"PrivateStore"] || !RUINThemeAccountNamespaceIsValid(parts[i + 1]) ||
        ![parts[i + 2] isEqual:@"Owned Themes"] ||
        ![parts[i + 3] isEqual:@"OwnedThemeProduct.sqlite"] || i < 2 ||
        ![parts[i - 1] isEqual:@"Application Support"] || ![parts[i - 2] isEqual:@"Library"]) return NO;
    if (storePath) *storePath = path;
    if (account) *account = parts[i + 1];
    return YES;
}

static BOOL RUINStoreIsWritableSQLite(NSPersistentStore *store)
{
    return [store.type isEqual:NSSQLiteStoreType] && !store.isReadOnly &&
        ![store.options[NSReadOnlyPersistentStoreOption] boolValue];
}

static BOOL RUINContextNativeScope(NSManagedObjectContext *context,
    NSManagedObjectModel **modelOut, NSEntityDescription **entityOut,
    NSPersistentStoreCoordinator **coordinatorOut, NSPersistentStore **storeOut,
    NSString **pathOut, NSString **accountOut, BOOL requireWritable)
{
    if (!context || (context.concurrencyType != NSPrivateQueueConcurrencyType &&
                     context.concurrencyType != NSMainQueueConcurrencyType)) return NO;
    NSPersistentStoreCoordinator *coordinator = context.persistentStoreCoordinator;
    NSManagedObjectModel *model = coordinator.managedObjectModel;
    NSEntityDescription *entity = model.entitiesByName[@"OwnedThemeProduct"];
    if (!coordinator || !RUINTheme2EntityIsSupported(entity)) return NO;

    NSPersistentStore *match = nil;
    NSString *path = nil, *account = nil;
    NSUInteger matches = 0;
    for (NSPersistentStore *store in coordinator.persistentStores) {
        NSString *candidatePath = nil, *candidateAccount = nil;
        if (!RUINStorePathHasNativeNamespace(store.URL, &candidatePath, &candidateAccount)) continue;
        matches++;
        match = store;
        path = candidatePath;
        account = candidateAccount;
    }
    if (matches != 1 || !match || (requireWritable && !RUINStoreIsWritableSQLite(match))) return NO;
    // LINE keeps its owned-theme DB in the app container, separate from packages.
    NSURL *applicationSupport = RUINNativeApplicationSupportURL();
    if (!applicationSupport.isFileURL) return NO;
    NSString *relativePath = [NSString pathWithComponents:@[@"PrivateStore", account,
        @"Owned Themes", @"OwnedThemeProduct.sqlite"]];
    NSURL *expected = [applicationSupport.URLByResolvingSymlinksInPath URLByAppendingPathComponent:relativePath];
    if (![match.URL.URLByResolvingSymlinksInPath.standardizedURL.path
        isEqual:expected.standardizedURL.path]) return NO;
    if (modelOut) *modelOut = model;
    if (entityOut) *entityOut = entity;
    if (coordinatorOut) *coordinatorOut = coordinator;
    if (storeOut) *storeOut = match;
    if (pathOut) *pathOut = path;
    if (accountOut) *accountOut = account;
    return YES;
}

static BOOL RUINRequestTargetsTheme(NSFetchRequest *request, NSManagedObjectContext *context)
{
    if (![request isKindOfClass:NSFetchRequest.class]) return NO;
    NSString *name = request.entity.name ?: request.entityName;
    NSEntityDescription *entity = context.persistentStoreCoordinator.managedObjectModel.entitiesByName[@"OwnedThemeProduct"];
    return [name isEqual:@"OwnedThemeProduct"] && RUINTheme2EntityIsSupported(entity) &&
        (!request.entity || [request.entity.name isEqual:entity.name]);
}

static void RUINObserveAccount(NSString *account)
{
    os_unfair_lock_lock(&gCaptureLock);
    if (gNativeAccount && ![gNativeAccount isEqual:account]) {
        gNativeContext = nil;
        gNativeCoordinator = nil;
        gNativeStore = nil;
        gNativeStorePath = nil;
        gNativeAccount = nil;
        gCaptureToken = nil;
        gScopeToken = nil;
        gCaptureGeneration++;
    }
    os_unfair_lock_unlock(&gCaptureLock);
}

static BOOL RUINCaptureNativeContext(NSManagedObjectContext *context)
{
    NSString *path = nil, *account = nil;
    if (!RUINContextNativeScope(context, NULL, NULL, NULL, NULL, &path, &account, NO)) return NO;
    RUINObserveAccount(account);

    NSPersistentStoreCoordinator *coordinator = nil;
    NSPersistentStore *store = nil;
    if (!RUINContextNativeScope(context, NULL, NULL, &coordinator, &store, &path, &account, YES)) return NO;
    os_unfair_lock_lock(&gCaptureLock);
    if (gNativeContext == context && gNativeCoordinator == coordinator && gNativeStore == store &&
        [gNativeStorePath isEqual:path] && [gNativeAccount isEqual:account]) {
        os_unfair_lock_unlock(&gCaptureLock);
        return YES;
    }
    gCaptureGeneration++;
    gCaptureToken = [NSObject new];
    if (!gScopeToken || ![gNativeStorePath isEqual:path]) gScopeToken = [NSObject new];
    gNativeContext = context;
    gNativeCoordinator = coordinator;
    gNativeStore = store;
    gNativeStorePath = [path copy];
    gNativeAccount = [account copy];
    os_unfair_lock_unlock(&gCaptureLock);
    return YES;
}

static RUINNativeCaptureSnapshot *RUINCurrentCaptureSnapshot(void)
{
    os_unfair_lock_lock(&gCaptureLock);
    NSManagedObjectContext *context = gNativeContext;
    NSPersistentStoreCoordinator *coordinator = gNativeCoordinator;
    NSPersistentStore *store = gNativeStore;
    if (!context || !coordinator || !store || !gCaptureToken) {
        os_unfair_lock_unlock(&gCaptureLock);
        return nil;
    }
    RUINNativeCaptureSnapshot *snapshot = [RUINNativeCaptureSnapshot new];
    snapshot.token = gCaptureToken;
    snapshot.context = context;
    snapshot.coordinator = coordinator;
    snapshot.store = store;
    snapshot.storePath = gNativeStorePath;
    snapshot.account = gNativeAccount;
    snapshot.generation = gCaptureGeneration;
    os_unfair_lock_unlock(&gCaptureLock);
    return snapshot;
}

static BOOL RUINCaptureIsCurrent(RUINNativeCaptureSnapshot *snapshot)
{
    os_unfair_lock_lock(&gCaptureLock);
    BOOL current = snapshot && gCaptureToken == snapshot.token &&
        gCaptureGeneration == snapshot.generation && gNativeContext == snapshot.context &&
        gNativeCoordinator == snapshot.coordinator && gNativeStore == snapshot.store &&
        [gNativeStorePath isEqual:snapshot.storePath] && [gNativeAccount isEqual:snapshot.account];
    os_unfair_lock_unlock(&gCaptureLock);
    return current;
}

static BOOL RUINContextStillMatchesSnapshot(RUINNativeCaptureSnapshot *snapshot)
{
    if (!RUINCaptureIsCurrent(snapshot)) return NO;
    NSPersistentStoreCoordinator *coordinator = nil;
    NSPersistentStore *store = nil;
    NSString *path = nil, *account = nil;
    if (!RUINContextNativeScope(snapshot.context, NULL, NULL, &coordinator, &store, &path, &account, YES)) return NO;
    return coordinator == snapshot.coordinator && store == snapshot.store &&
        [path isEqual:snapshot.storePath] && [account isEqual:snapshot.account];
}


static const char *RUINSkipObjCQualifiers(const char *type)
{
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL RUINTypeIsObject(const char *type)
{
    type = RUINSkipObjCQualifiers(type);
    return type && type[0] == '@' && (type[1] == '\0' || type[1] == '"' || type[1] == '?');
}

static BOOL RUINTypeIsObjectPointer(const char *type)
{
    type = RUINSkipObjCQualifiers(type);
    if (!type || *type++ != '^') return NO;
    return RUINTypeIsObject(type);
}

static BOOL RUINFetchMethodHasExpectedABI(Method method)
{
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    const char *selectorType = signature.numberOfArguments > 1 ?
        RUINSkipObjCQualifiers([signature getArgumentTypeAtIndex:1]) : NULL;
    return signature.numberOfArguments == 4 && RUINTypeIsObject(signature.methodReturnType) &&
        RUINTypeIsObject([signature getArgumentTypeAtIndex:0]) &&
        selectorType && selectorType[0] == ':' && selectorType[1] == '\0' &&
        RUINTypeIsObject([signature getArgumentTypeAtIndex:2]) &&
        RUINTypeIsObjectPointer([signature getArgumentTypeAtIndex:3]);
}

static BOOL RUINNativeServerRevocationFetch(void)
{
#if defined(RUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK)
    return NO;
#else
    RUINMainExecutableImage image;
    if (!RUINResolveMainExecutableImage(&image)) return NO;
    void *frames[24];
    int count = backtrace(frames, 24);
    uintptr_t base = (uintptr_t)image.header;
    intptr_t slide = image.slide;
    uintptr_t PCs[2]; NSUInteger found = 0;
    for (int i = 0; i < count && found < 2; i++) {
        uintptr_t pc = (uintptr_t)frames[i];
        if (pc >= base && pc < base + 0x9400000) PCs[found++] = pc - slide;
    }
    return RUINNativeThemeRevocationFetchPCsMatch(PCs, found);
#endif
}

%group RUINNativeThemeRegistration
%hook NSManagedObjectContext
- (NSArray *)executeFetchRequest:(NSFetchRequest *)request error:(NSError **)error
{
    NSManagedObjectContext *context = self;
    NSFetchRequest *effectiveRequest = request;
    NSSet *localIDs = nil;
    @try {
        NSString *account = nil;
        if (![NSThread.currentThread.threadDictionary[kRUINWriterThreadKey] boolValue] &&
            RUINRequestTargetsTheme(request, context) &&
            RUINContextNativeScope(context, NULL, NULL, NULL, NULL, NULL, &account, NO)) {
            RUINCaptureNativeContext(context);
            NSURL *root = [RUINPackageDirectory(RUINMappedGroupContainerURL(), account,
                @"00000000-0000-0000-0000-000000000000") URLByDeletingLastPathComponent];
            localIDs = RUINNativeLocalThemeIDs(root);
            if (localIDs.count && request.predicate) {
                effectiveRequest = [request copy];
                effectiveRequest.predicate = RUINNativeServerRevocationFetch()
                    ? RUINNativeThemeRevocationPredicate(request.predicate, localIDs)
                    : RUINNativeLocalThemePredicate(request.predicate, localIDs);
            }
        }
    } @catch (__unused NSException *exception) {
        effectiveRequest = request;
        localIDs = nil;
    }
    NSArray *result = %orig(effectiveRequest, error);
    if ([NSThread.currentThread.threadDictionary[kRUINWriterThreadKey] boolValue] || !result || (error && *error))
        return result;
    @try {
        if (!RUINRequestTargetsTheme(request, context)) return result;
#if !defined(RUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK)
        RUINRecordNativeThemeFetchInspection(request, effectiveRequest, result.count);
#endif
        if (request.resultType == NSManagedObjectResultType)
            RUINProjectNativeLocalThemeObjects(result, context, localIDs);
        NSString *ignoredPath = nil, *account = nil;
        if (RUINContextNativeScope(context, NULL, NULL, NULL, NULL, &ignoredPath, &account, NO)) {
            RUINObserveAccount(account);
            RUINCaptureNativeContext(context);
        }
    } @catch (__unused NSException *exception) {
        // A failed local adapter leaves LINE's original result/error intact.
    }
    return result;
}
%end
%end

void RUINInstallNativeThemeRegistrationCapture(void)
{
    dispatch_once(&gHookOnce, ^{
        if (!RUINTargetBuildMatches()) return;
        Method method = class_getInstanceMethod(NSManagedObjectContext.class,
            @selector(executeFetchRequest:error:));
        if (!RUINFetchMethodHasExpectedABI(method)) return;
        if (!method_getImplementation(method)) return;
        %init(RUINNativeThemeRegistration);
    });
}

@interface RUINNativeThemeRegistrationInstaller : NSObject
@end
@implementation RUINNativeThemeRegistrationInstaller
+ (void)load
{
#if !defined(RUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK)
    RUINInstallNativeThemeRegistrationCapture();
#endif
}
@end

BOOL RUINNativeThemeRegistrationAvailable(void)
{
    os_unfair_lock_lock(&gCaptureLock);
    BOOL available = gNativeContext != nil && gNativeCoordinator != nil &&
        gNativeStore != nil && gCaptureToken != nil;
    os_unfair_lock_unlock(&gCaptureLock);
    return available;
}

id RUINNativeThemeRegistrationScopeToken(void)
{
    os_unfair_lock_lock(&gCaptureLock);
    id token = gScopeToken;
    os_unfair_lock_unlock(&gCaptureLock);
    return token;
}

static NSURL *RUINNativeApplicationSupportURL(void)
{
#if defined(RUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK)
    os_unfair_lock_lock(&gCaptureLock);
    NSURL *URL = gTestApplicationSupportURL;
    os_unfair_lock_unlock(&gCaptureLock);
    return URL;
#else
    return [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
#endif
}

static NSURL *RUINMappedGroupContainerURL(void)
{
#if defined(RUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK)
    os_unfair_lock_lock(&gCaptureLock);
    NSURL *fixtureURL = gTestGroupContainerURL;
    os_unfair_lock_unlock(&gCaptureLock);
    return fixtureURL;
#else
    // RUINSideload maps this original identifier to the active profile container.
    return [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.com.linecorp.line"];
#endif
}

static NSURL *RUINPackageDirectory(NSURL *container, NSString *account, NSString *productID)
{
    if (!container.isFileURL || !RUINThemeAccountNamespaceIsValid(account)) return nil;
    NSURL *URL = [[[[[container URLByAppendingPathComponent:@"Library" isDirectory:YES]
        URLByAppendingPathComponent:@"Application Support" isDirectory:YES]
        URLByAppendingPathComponent:@"PrivateStore" isDirectory:YES]
        URLByAppendingPathComponent:account isDirectory:YES]
        URLByAppendingPathComponent:@"Theme Packages" isDirectory:YES];
    return [[URL URLByAppendingPathComponent:productID isDirectory:YES] standardizedURL];
}

BOOL RUINIsRegisteredNativeThemeID(NSString *productID)
{
    if (![productID isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:productID]) return NO;
    os_unfair_lock_lock(&gCaptureLock);
    NSString *account = gNativeAccount;
    id scope = gScopeToken;
    os_unfair_lock_unlock(&gCaptureLock);
    if (!account || !scope) return NO;
    NSURL *root = [RUINPackageDirectory(RUINMappedGroupContainerURL(), account,
        @"00000000-0000-0000-0000-000000000000") URLByDeletingLastPathComponent];
    BOOL found = [RUINNativeLocalThemeIDs(root) containsObject:productID.lowercaseString];
    return found && scope == RUINNativeThemeRegistrationScopeToken();
}

static BOOL RUINPackageURLMatchesSnapshot(NSURL *URL, RUINNativeCaptureSnapshot *snapshot, NSString *productID)
{
    NSURL *container = RUINMappedGroupContainerURL();
    NSURL *expected = RUINPackageDirectory(container, snapshot.account, productID);
    return URL.isFileURL && expected && [URL.standardizedURL isEqual:expected];
}

void RUINNativeThemeRegistrationPackageURL(NSString *productID,
    void (^completion)(NSURL * _Nullable, NSError * _Nullable))
{
    NSUUID *UUID = [productID isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:productID] : nil;
    if (!UUID || [UUID.UUIDString caseInsensitiveCompare:productID] != NSOrderedSame) {
        if (completion) dispatch_async(RUINRegistrationQueue(), ^{
            completion(nil, RUINRegistrationError(kRegistrationInvalidMetadata, @"productID must be a canonical UUID."));
        });
        return;
    }
    RUINNativeCaptureSnapshot *snapshot = RUINCurrentCaptureSnapshot();
    if (!snapshot) {
        if (completion) dispatch_async(RUINRegistrationQueue(), ^{
            completion(nil, RUINRegistrationError(kRegistrationUnavailable,
                @"No validated native account scope is available for package staging."));
        });
        return;
    }
    dispatch_async(RUINRegistrationQueue(), ^{
        __block BOOL scopeMatches = NO;
        [snapshot.context performBlockAndWait:^{ scopeMatches = RUINContextStillMatchesSnapshot(snapshot); }];
        NSURL *container = scopeMatches ? RUINMappedGroupContainerURL() : nil;
        if (!scopeMatches || !container.isFileURL || !RUINCaptureIsCurrent(snapshot)) {
            if (completion) completion(nil, RUINRegistrationError(kRegistrationStaleContext,
                @"The native account context changed or its mapped app-group container is unavailable."));
            return;
        }
        NSURL *URL = RUINPackageDirectory(container, snapshot.account, UUID.UUIDString.lowercaseString);
        if (!URL) {
            if (completion) completion(nil, RUINRegistrationError(kRegistrationUnavailable,
                @"The native account package path could not be constructed."));
            return;
        }
        if (completion) completion(URL, nil);
    });
}

#if defined(RUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK)
BOOL RUINNativeThemeRegistrationCaptureContextForTesting(NSManagedObjectContext *context)
{
    __block BOOL captured = NO;
    [context performBlockAndWait:^{ captured = RUINCaptureNativeContext(context); }];
    return captured;
}

void RUINNativeThemeRegistrationSetGroupContainerForTesting(NSURL *containerURL)
{
    os_unfair_lock_lock(&gCaptureLock);
    gTestGroupContainerURL = containerURL;
    os_unfair_lock_unlock(&gCaptureLock);
}

void RUINNativeThemeRegistrationSetApplicationSupportForTesting(NSURL *applicationSupportURL)
{
    os_unfair_lock_lock(&gCaptureLock);
    gTestApplicationSupportURL = applicationSupportURL;
    os_unfair_lock_unlock(&gCaptureLock);
}
#endif

static BOOL RUINCleanString(id value, NSUInteger maxLength)
{
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *string = value;
    if (!string.length || string.length > maxLength ||
        [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0 ||
        [string rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    return YES;
}

static BOOL RUINPositiveInt64(id value, int64_t *result)
{
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    NSString *digits = [(NSNumber *)value stringValue];
    if (!digits.length || digits.length > 19) return NO;
    for (NSUInteger i = 0; i < digits.length; i++)
        if ([digits characterAtIndex:i] < '0' || [digits characterAtIndex:i] > '9') return NO;
    errno = 0;
    unsigned long long number = strtoull(digits.UTF8String, NULL, 10);
    if (errno || number == 0 || number > (unsigned long long)LLONG_MAX) return NO;
    if (result) *result = (int64_t)number;
    return YES;
}

static BOOL RUINValidImagePath(NSString *path, NSString *productID, int64_t version)
{
    if (![path isKindOfClass:NSString.class] || path.length > 512 ||
        ![path hasPrefix:@"/"] || [path containsString:@"//"] ||
        [path containsString:@"\\"] || [path containsString:@"?"] ||
        [path containsString:@"#"] || [path containsString:@"%"] || [path containsString:@":"])
        return NO;
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    if (parts.count != 8 || parts[0].length || ![parts[1] isEqual:[productID substringToIndex:2]] ||
        ![parts[2] isEqual:[productID substringWithRange:NSMakeRange(2, 2)]] ||
        ![parts[3] isEqual:[productID substringWithRange:NSMakeRange(4, 2)]] ||
        ![parts[4] isEqual:productID] || ![parts[5] isEqual:[NSString stringWithFormat:@"%lld", version]] ||
        ![parts[6] isEqual:@"ANDROID"]) return NO;
    NSString *filename = parts[7];
    NSCharacterSet *filenameCharacters = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@-"];
    if (filename.length < 5 || filename.length > 128 ||
        ![[filename.lowercaseString pathExtension] isEqual:@"png"] || [filename hasPrefix:@"."] ||
        [filename containsString:@".."] || [filename rangeOfCharacterFromSet:filenameCharacters.invertedSet].location != NSNotFound)
        return NO;
    return YES;
}

static NSDictionary<NSString *, id> *RUINValidatedMetadata(NSDictionary<NSString *, id> *metadata,
    NSError **error)
{
    id rawID = metadata[@"productID"];
    id rawName = metadata[@"name"];
    id rawVersion = metadata[@"rawVersion"];
    id rawVersionString = metadata[@"versionString"];
    id rawImagePath = metadata[@"imagePath"];
    NSUUID *UUID = [rawID isKindOfClass:NSString.class] ? [[NSUUID alloc] initWithUUIDString:rawID] : nil;
    NSString *productID = UUID.UUIDString.lowercaseString;
    int64_t version = 0;
    if (!UUID || [UUID.UUIDString caseInsensitiveCompare:rawID] != NSOrderedSame ||
        !RUINCleanString(rawName, 256) || !RUINPositiveInt64(rawVersion, &version) ||
        !RUINCleanString(rawVersionString, 256) ||
        !RUINValidImagePath(rawImagePath, productID, version)) {
        if (error) *error = RUINRegistrationError(kRegistrationInvalidMetadata,
            @"Theme metadata must contain a UUID, a name and version string up to 256 characters, a positive integer version, and a matching public Android PNG path.");
        return nil;
    }
    NSMutableDictionary *validated = [@{
        @"productID": productID,
        @"name": [rawName copy],
        @"rawVersion": @(version),
        @"versionString": [rawVersionString copy],
        @"imagePath": [rawImagePath copy]
    } mutableCopy];
    if (metadata[@"productAvailability"] && metadata[@"productAvailability"] != [NSNull null])
        validated[@"productAvailability"] = metadata[@"productAvailability"];
    else if (metadata[@"productAvailability"] == [NSNull null]) {
        if (error) *error = RUINRegistrationError(kRegistrationInvalidMetadata,
            @"productAvailability must be an integer when supplied.");
        return nil;
    }
    return [validated copy];
}

static BOOL RUINAvailabilityValue(NSDictionary *metadata, NSEntityDescription *entity,
    NSNumber **value, NSError **error)
{
    id raw = metadata[@"productAvailability"];
    NSAttributeDescription *attribute = entity.attributesByName[@"productAvailability"];
    if (!attribute || attribute.attributeType != NSInteger16AttributeType) {
        if (error) *error = RUINRegistrationError(kRegistrationWrongModel,
            @"Theme 2's productAvailability field is unavailable or has an unexpected type.");
        return NO;
    }
    if (!raw) return YES;
    if (![raw isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)raw) == CFBooleanGetTypeID()) {
        if (error) *error = RUINRegistrationError(kRegistrationInvalidMetadata,
            @"productAvailability must be an integer in Theme 2's integer16 range.");
        return NO;
    }
    NSString *digits = [(NSNumber *)raw stringValue];
    if (!digits.length || digits.length > 6) goto invalid;
    for (NSUInteger i = 0; i < digits.length; i++)
        if ([digits characterAtIndex:i] < '0' || [digits characterAtIndex:i] > '9') goto invalid;
    errno = 0;
    unsigned long long n = strtoull(digits.UTF8String, NULL, 10);
    if (errno || n > INT16_MAX) goto invalid;
    if (value) *value = @((int16_t)n);
    return YES;
invalid:
    if (error) *error = RUINRegistrationError(kRegistrationInvalidMetadata,
        @"productAvailability must be an integer in Theme 2's integer16 range.");
    return NO;
}

static BOOL RUINDefaultMatchesAttribute(id value, NSAttributeDescription *attribute)
{
    if (!value || value == [NSNull null]) return NO;
    switch (attribute.attributeType) {
        case NSStringAttributeType: return [value isKindOfClass:NSString.class];
        case NSDateAttributeType: return [value isKindOfClass:NSDate.class];
        case NSBinaryDataAttributeType: return [value isKindOfClass:NSData.class];
        case NSBooleanAttributeType:
        case NSInteger16AttributeType:
        case NSInteger32AttributeType:
        case NSInteger64AttributeType:
        case NSDecimalAttributeType:
        case NSDoubleAttributeType:
        case NSFloatAttributeType: return [value isKindOfClass:NSNumber.class];
        default: return NO;
    }
}

static void RUINApplyNewRowDefaults(NSManagedObject *object, NSEntityDescription *entity)
{
    [entity.attributesByName enumerateKeysAndObjectsUsingBlock:^(NSString *name,
        NSAttributeDescription *attribute, BOOL *stop) {
        (void)stop;
        id value = attribute.defaultValue;
        if (attribute.isOptional && RUINDefaultMatchesAttribute(value, attribute))
            [object setValue:value forKey:name];
    }];
}

static NSManagedObject * _Nullable RUINRegisteredObjectWithID(NSManagedObjectContext *context,
    NSManagedObjectID *objectID)
{
    for (NSManagedObject *object in context.registeredObjects)
        if ([object.objectID isEqual:objectID]) return object;
    return nil;
}

static NSNotification *RUINNotificationPreservingPendingChanges(NSNotification *notification,
    NSManagedObjectContext *context)
{
    NSMutableDictionary *userInfo = [notification.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *key in @[NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]) {
        NSSet *objects = userInfo[key];
        if (![objects isKindOfClass:NSSet.class]) continue;
        NSMutableSet *safe = [NSMutableSet setWithCapacity:objects.count];
        for (NSManagedObject *saved in objects) {
            NSManagedObject *registered = RUINRegisteredObjectWithID(context, saved.objectID);
            if (!registered.hasChanges) [safe addObject:saved];
        }
        userInfo[key] = [safe copy];
    }
    return [NSNotification notificationWithName:notification.name object:notification.object userInfo:userInfo];
}

static void RUINCompleteOnRegistrationQueue(
    void (^completion)(NSManagedObjectID *, NSDictionary<NSString *, id> *, NSError *),
    NSManagedObjectID *objectID, NSDictionary<NSString *, id> *metadata, NSError *error)
{
    if (completion) dispatch_async(RUINRegistrationQueue(), ^{ completion(objectID, metadata, error); });
}

void RUINRegisterNativeThemeMetadata(NSDictionary<NSString *, id> *metadata,
    BOOL isNewRUINLocalTheme, NSURL *stagedPackageURL,
    void (^completion)(NSManagedObjectID * _Nullable, NSDictionary<NSString *, id> * _Nullable, NSError * _Nullable))
{
    NSError *validationError = nil;
    NSDictionary<NSString *, id> *validated = RUINValidatedMetadata(metadata, &validationError);
    RUINNativeCaptureSnapshot *snapshot = RUINCurrentCaptureSnapshot();
    if (!validated || !snapshot) {
        RUINCompleteOnRegistrationQueue(completion, nil, nil, validationError ?:
            RUINRegistrationError(kRegistrationUnavailable,
                @"No writable native OwnedThemeProduct context is available for the current account."));
        return;
    }

    dispatch_async(RUINRegistrationQueue(), ^{
        __block BOOL scopeMatches = NO;
        [snapshot.context performBlockAndWait:^{ scopeMatches = RUINContextStillMatchesSnapshot(snapshot); }];
        if (!scopeMatches || !RUINPackageURLMatchesSnapshot(stagedPackageURL, snapshot, validated[@"productID"])) {
            if (completion) completion(nil, nil, RUINRegistrationError(kRegistrationStaleContext,
                @"The staged package URL does not match the captured native account scope."));
            return;
        }
        if (!RUINCaptureIsCurrent(snapshot)) {
            if (completion) completion(nil, nil, RUINRegistrationError(kRegistrationStaleContext,
                @"The native theme context or account changed before registration."));
            return;
        }
        NSManagedObjectModel *model = snapshot.coordinator.managedObjectModel;
        NSEntityDescription *entity = model.entitiesByName[@"OwnedThemeProduct"];
        NSError *error = nil;
        NSNumber *availability = nil;
        if (!RUINTheme2EntityIsSupported(entity) ||
            !RUINAvailabilityValue(validated, entity, &availability, &error)) {
            if (completion) completion(nil, nil, error ?: RUINRegistrationError(kRegistrationWrongModel,
                @"The captured store does not use the supported Theme 2 OwnedThemeProduct schema."));
            return;
        }

        __block NSManagedObjectID *objectID = nil;
        __block NSNumber *installedTime = nil;
        __block NSNotification *saveNotification = nil;
        __block NSError *writerError = nil;
        NSManagedObjectContext *writer = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        writer.persistentStoreCoordinator = snapshot.coordinator;
        writer.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy;

        [writer performBlockAndWait:^{
            NSThread.currentThread.threadDictionary[kRUINWriterThreadKey] = @YES;
            @try {
                NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"OwnedThemeProduct"];
                request.predicate = [NSPredicate predicateWithFormat:@"productID == %@", validated[@"productID"]];
                request.fetchLimit = 2;
                request.affectedStores = @[snapshot.store];
                NSArray<NSManagedObject *> *matches = [writer executeFetchRequest:request error:&writerError];
                if (!matches) return;
                if (matches.count > 1) {
                    writerError = RUINRegistrationError(kRegistrationDuplicateProduct,
                        @"More than one native theme record has this productID; registration was skipped.");
                    return;
                }
                BOOL inserting = matches.count == 0;
                if (inserting && !isNewRUINLocalTheme) {
                    writerError = RUINRegistrationError(kRegistrationUnavailable,
                        @"A new native record can only be created for a caller-declared local theme.");
                    return;
                }
                if (!RUINCaptureIsCurrent(snapshot)) {
                    writerError = RUINRegistrationError(kRegistrationStaleContext,
                        @"The native theme context or account changed before the store write.");
                    return;
                }
                NSManagedObject *object = inserting ?
                    [NSEntityDescription insertNewObjectForEntityForName:@"OwnedThemeProduct" inManagedObjectContext:writer] : matches.firstObject;
                if (inserting) {
                    [writer assignObject:object toPersistentStore:snapshot.store];
                    RUINApplyNewRowDefaults(object, entity);
                    [object setValue:@YES forKey:@"owned"];
                    [object setValue:@NO forKey:@"grantedByDefault"];
                    NSAttributeDescription *latest = entity.attributesByName[@"latestVersion"];
                    NSAttributeDescription *latestString = entity.attributesByName[@"latestVersionString"];
                    if (latest.attributeType == NSInteger64AttributeType && !latest.isTransient)
                        [object setValue:validated[@"rawVersion"] forKey:@"latestVersion"];
                    if (latestString.attributeType == NSStringAttributeType && !latestString.isTransient)
                        [object setValue:[validated[@"rawVersion"] stringValue] forKey:@"latestVersionString"];
                    NSAttributeDescription *validFor = entity.attributesByName[@"validFor"];
                    NSAttributeDescription *validUntil = entity.attributesByName[@"validUntil"];
                    if (validFor.attributeType == NSInteger32AttributeType && !validFor.isTransient)
                        [object setValue:@(-1) forKey:@"validFor"];
                    if (validUntil.attributeType == NSDateAttributeType && !validUntil.isTransient)
                        [object setValue:[NSDate dateWithTimeIntervalSinceReferenceDate:-978307200.001]
                            forKey:@"validUntil"];
                }
                [object setValue:validated[@"productID"] forKey:@"productID"];
                installedTime = @((int64_t)floor(NSDate.date.timeIntervalSince1970 * 1000.0));
                [object setValue:installedTime forKey:@"installedTime"];
                [object setValue:validated[@"rawVersion"] forKey:@"version"];
                [object setValue:validated[@"name"] forKey:@"name"];
                [object setValue:validated[@"versionString"] forKey:@"versionString"];
                NSAttributeDescription *defaultOrder = entity.attributesByName[@"defaultOrder"];
                if (isNewRUINLocalTheme && defaultOrder.attributeType == NSInteger16AttributeType &&
                    [[object valueForKey:@"defaultOrder"] integerValue] < 0) {
                    [object setValue:@YES forKey:@"owned"];
                    [object setValue:@NO forKey:@"grantedByDefault"];
                }
                NSAttributeDescription *versionRange = entity.attributesByName[@"applicationVersionRange"];
                if (isNewRUINLocalTheme && versionRange.attributeType == NSStringAttributeType &&
                    !versionRange.isTransient && ![[object valueForKey:@"applicationVersionRange"] length]) {
                    // LINE's range format stores an upper/lower comparison pair.
                    // Native range policy: accept the supported 26.16+ clients.
                    // This lower bound is not a host identity or code mapping.
                    [object setValue:@"0,1000.0.0,1,26.16.0" forKey:@"applicationVersionRange"];
                }
                [object setValue:validated[@"imagePath"] forKey:@"imagePath"];
                if (availability) [object setValue:availability forKey:@"productAvailability"];
                NSAttributeDescription *latest = entity.attributesByName[@"latestVersion"];
                NSAttributeDescription *latestString = entity.attributesByName[@"latestVersionString"];
                if (!inserting && latest.attributeType == NSInteger64AttributeType && !latest.isTransient) {
                    NSNumber *currentLatest = [object valueForKey:@"latestVersion"];
                    if (currentLatest.longLongValue <= [validated[@"rawVersion"] longLongValue]) {
                        [object setValue:validated[@"rawVersion"] forKey:@"latestVersion"];
                        if (latestString.attributeType == NSStringAttributeType && !latestString.isTransient)
                            [object setValue:[validated[@"rawVersion"] stringValue] forKey:@"latestVersionString"];
                    }
                }

                id token = [[NSNotificationCenter defaultCenter] addObserverForName:NSManagedObjectContextDidSaveNotification
                    object:writer queue:nil usingBlock:^(NSNotification *note) { saveNotification = note; }];
                BOOL saved = [writer save:&writerError];
                [[NSNotificationCenter defaultCenter] removeObserver:token];
                if (!saved) return;
                objectID = object.objectID;
            } @finally {
                [NSThread.currentThread.threadDictionary removeObjectForKey:kRUINWriterThreadKey];
            }
        }];

        if (writerError || !objectID || !saveNotification) {
            if (completion) completion(nil, nil, writerError ?: RUINRegistrationError(kRegistrationUnavailable,
                @"The native theme writer saved no mergeable change."));
            return;
        }

        NSMutableDictionary *result = [validated mutableCopy];
        result[@"installedTime"] = installedTime;
        NSDictionary<NSString *, id> *persistedMetadata = [result copy];

        __block BOOL merged = NO;
        __block NSError *mergeError = nil;
        [snapshot.context performBlockAndWait:^{
            if (!RUINContextStillMatchesSnapshot(snapshot)) {
                mergeError = RUINRegistrationError(kRegistrationStaleContext,
                    @"The native theme context or account changed before the saved row could be merged.");
                return;
            }
            @try {
                NSNotification *filtered = RUINNotificationPreservingPendingChanges(saveNotification, snapshot.context);
                [snapshot.context mergeChangesFromContextDidSaveNotification:filtered];
                merged = YES;
            } @catch (NSException *exception) {
                mergeError = RUINRegistrationError(kRegistrationUnavailable,
                    exception.reason ?: @"The saved theme row could not be merged into the native context.");
            }
        }];
        if (completion) {
            if (!merged) completion(objectID, persistedMetadata, mergeError ?: RUINRegistrationError(kRegistrationUnavailable,
                @"The native context merge did not complete."));
            else completion(objectID, persistedMetadata, nil);
        }
    });
}
