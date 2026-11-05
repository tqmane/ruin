#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

#import "NativeThemeRegistration.h"

#include <assert.h>
#include <stdio.h>

@interface RUINRegistrationFixture : NSObject
@property(nonatomic, strong) NSPersistentStoreCoordinator *coordinator;
@property(nonatomic, strong) NSManagedObjectContext *context;
@property(nonatomic, strong) NSURL *storeURL;
@end
@implementation RUINRegistrationFixture
@end

@interface RUINMergeFailingContext : NSManagedObjectContext
@end
@implementation RUINMergeFailingContext
- (void)mergeChangesFromContextDidSaveNotification:(NSNotification *)notification
{
    (void)notification;
    [NSException raise:@"RUINExpectedMergeFailure" format:@"Fixture merge failure."];
}
@end

static NSManagedObjectModel *Theme2Model(NSURL *URL)
{
    NSManagedObjectModel *source = [[NSManagedObjectModel alloc] initWithContentsOfURL:URL];
    assert(source != nil);
    NSManagedObjectModel *model = [source copy];
    NSEntityDescription *entity = model.entitiesByName[@"OwnedThemeProduct"];
    assert(entity != nil);
    entity.managedObjectClassName = NSStringFromClass(NSManagedObject.class);
    return model;
}

static NSURL *StoreURL(NSURL *root, NSString *account, NSString *folder)
{
    NSURL *directory = [[[root URLByAppendingPathComponent:@"Library" isDirectory:YES]
        URLByAppendingPathComponent:@"Application Support" isDirectory:YES]
        URLByAppendingPathComponent:@"PrivateStore" isDirectory:YES];
    directory = [[directory URLByAppendingPathComponent:account isDirectory:YES]
        URLByAppendingPathComponent:folder isDirectory:YES];
    NSError *error = nil;
    assert([[NSFileManager defaultManager] createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:nil error:&error]);
    assert(error == nil);
    return [directory URLByAppendingPathComponent:@"OwnedThemeProduct.sqlite"];
}

static RUINRegistrationFixture *Fixture(NSManagedObjectModel *model, NSURL *URL, BOOL readOnly)
{
    RUINRegistrationFixture *fixture = [RUINRegistrationFixture new];
    fixture.storeURL = URL;
    fixture.coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSDictionary *options = readOnly ? @{NSReadOnlyPersistentStoreOption: @YES} : @{};
    NSError *error = nil;
    NSPersistentStore *store = [fixture.coordinator addPersistentStoreWithType:NSSQLiteStoreType
        configuration:nil URL:URL options:options error:&error];
    assert(store != nil && error == nil);
    fixture.context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    fixture.context.persistentStoreCoordinator = fixture.coordinator;
    return fixture;
}

static NSDictionary<NSString *, id> *Metadata(NSString *productID, NSString *name,
    int64_t version, NSString *versionString)
{
    NSString *lowerID = productID.lowercaseString;
    NSString *path = [NSString stringWithFormat:@"/%@/%@/%@/%@/%lld/ANDROID/icon.png",
        [lowerID substringToIndex:2], [lowerID substringWithRange:NSMakeRange(2, 2)],
        [lowerID substringWithRange:NSMakeRange(4, 2)], lowerID, version];
    return @{ @"productID": lowerID, @"name": name, @"rawVersion": @(version),
        @"versionString": versionString, @"imagePath": path, @"productAvailability": @0 };
}

static void Register(NSDictionary<NSString *, id> *metadata, BOOL local, NSURL *packageURL,
    NSManagedObjectID **objectIDOut, NSDictionary **persistedOut, NSError **errorOut)
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSManagedObjectID *objectID = nil;
    __block NSDictionary *persisted = nil;
    __block NSError *error = nil;
    RUINRegisterNativeThemeMetadata(metadata, local, packageURL, ^(NSManagedObjectID *returnedID,
        NSDictionary<NSString *,id> *returnedMetadata, NSError *returnedError) {
        objectID = returnedID;
        persisted = returnedMetadata;
        error = returnedError;
        dispatch_semaphore_signal(semaphore);
    });
    long result = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    assert(result == 0);
    if (objectIDOut) *objectIDOut = objectID;
    if (persistedOut) *persistedOut = persisted;
    if (errorOut) *errorOut = error;
}

static NSURL *PackageURL(NSString *productID, NSError **errorOut)
{
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSURL *URL = nil;
    __block NSError *error = nil;
    RUINNativeThemeRegistrationPackageURL(productID, ^(NSURL *packageURL, NSError *returnedError) {
        URL = packageURL;
        error = returnedError;
        dispatch_semaphore_signal(semaphore);
    });
    long result = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    assert(result == 0);
    if (errorOut) *errorOut = error;
    return URL;
}

static NSManagedObject *Fetch(NSManagedObjectContext *context, NSString *productID)
{
    __block NSManagedObject *record = nil;
    [context performBlockAndWait:^{
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"OwnedThemeProduct"];
        request.predicate = [NSPredicate predicateWithFormat:@"productID == %@", productID];
        request.fetchLimit = 1;
        NSError *error = nil;
        NSArray *rows = [context executeFetchRequest:request error:&error];
        assert(rows != nil && error == nil);
        record = rows.firstObject;
    }];
    return record;
}

static void SeedServerOwnedRecord(RUINRegistrationFixture *fixture, NSString *productID)
{
    [fixture.context performBlockAndWait:^{
        NSManagedObject *record = [NSEntityDescription insertNewObjectForEntityForName:@"OwnedThemeProduct"
            inManagedObjectContext:fixture.context];
        [record setValue:productID forKey:@"productID"];
        [record setValue:@12 forKey:@"installedTime"];
        [record setValue:@7 forKey:@"version"];
        [record setValue:@20 forKey:@"latestVersion"];
        [record setValue:@"Server Theme" forKey:@"name"];
        [record setValue:@"V7" forKey:@"versionString"];
        [record setValue:@"V20" forKey:@"latestVersionString"];
        [record setValue:@"/9d/dd/1e/9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002/7/ANDROID/icon.png" forKey:@"imagePath"];
        [record setValue:@NO forKey:@"owned"];
        [record setValue:@NO forKey:@"grantedByDefault"];
        [record setValue:@42 forKey:@"validFor"];
        [record setValue:[NSDate dateWithTimeIntervalSince1970:6000] forKey:@"validUntil"];
        NSError *error = nil;
        assert([fixture.context save:&error] && error == nil);
    }];
}

static void CheckWrongEntityAndNamespace(NSManagedObjectModel *model, NSURL *root)
{
    NSManagedObjectModel *wrong = [NSManagedObjectModel new];
    NSEntityDescription *other = [NSEntityDescription new];
    other.name = @"OtherEntity";
    other.managedObjectClassName = NSStringFromClass(NSManagedObject.class);
    wrong.entities = @[other];
    RUINRegistrationFixture *wrongEntity = Fixture(wrong,
        StoreURL(root, @"S_wrongentity", @"Owned Themes"), NO);
    assert(!RUINNativeThemeRegistrationCaptureContextForTesting(wrongEntity.context));

    RUINRegistrationFixture *wrongNamespace = Fixture(model,
        StoreURL(root, @"S_wrongnamespace", @"Other Themes"), NO);
    assert(!RUINNativeThemeRegistrationCaptureContextForTesting(wrongNamespace.context));
}

static void CheckReadOnly(NSManagedObjectModel *model, NSURL *root)
{
    NSURL *URL = StoreURL(root, @"S_readonly", @"Owned Themes");
    @autoreleasepool { (void)Fixture(model, URL, NO); }
    RUINRegistrationFixture *fixture = Fixture(model, URL, YES);
    assert(!RUINNativeThemeRegistrationCaptureContextForTesting(fixture.context));
}

static void CheckPendingChanges(NSManagedObjectContext *context)
{
    __block NSManagedObject *pending = nil;
    [context performBlockAndWait:^{
        pending = [NSEntityDescription insertNewObjectForEntityForName:@"OwnedThemeProduct" inManagedObjectContext:context];
        [pending setValue:@"b0768339-c2d3-4189-9653-2909e9bb6f58" forKey:@"productID"];
        [pending setValue:@17 forKey:@"installedTime"];
        [pending setValue:@1 forKey:@"version"];
        [pending setValue:@"Pending" forKey:@"name"];
        [pending setValue:@"V1" forKey:@"versionString"];
        [pending setValue:@"/b0/76/83/b0768339-c2d3-4189-9653-2909e9bb6f58/1/ANDROID/icon.png" forKey:@"imagePath"];
    }];
    NSManagedObjectID *localID = nil;
    NSError *error = nil;
    NSURL *packageURL = PackageURL(@"a0768339-c2d3-4189-9653-2909e9bb6f58", &error);
    assert(packageURL != nil && error == nil);
    Register(Metadata(@"a0768339-c2d3-4189-9653-2909e9bb6f58", @"Local Theme", 315, @"V1"), YES,
        packageURL, &localID, NULL, &error);
    assert(localID != nil && error == nil);
    [context performBlockAndWait:^{
        assert(context.hasChanges && pending.hasChanges);
        assert([[pending valueForKey:@"name"] isEqual:@"Pending"]);
    }];
    NSManagedObject *local = Fetch(context, @"a0768339-c2d3-4189-9653-2909e9bb6f58");
    assert(local != nil);
    [context performBlockAndWait:^{
        assert([[local valueForKey:@"owned"] boolValue]);
        assert(![[local valueForKey:@"grantedByDefault"] boolValue]);
        assert([[local valueForKey:@"productAvailability"] integerValue] == 0);
        assert([[local valueForKey:@"installedTime"] longLongValue] > 1000000000000LL);
        assert([[local valueForKey:@"version"] longLongValue] == 315);
        assert([[local valueForKey:@"latestVersion"] longLongValue] == 315);
        assert([[local valueForKey:@"latestVersionString"] isEqual:@"315"]);
        assert([[local valueForKey:@"applicationVersionRange"] isEqual:@"0,1000.0.0,1,26.16.0"]);
        assert([[local valueForKey:@"defaultOrder"] integerValue] == -1);
        assert([[local valueForKey:@"validFor"] integerValue] == -1);
        assert(fabs([[local valueForKey:@"validUntil"] timeIntervalSinceReferenceDate] - (-978307200.001)) < 0.01);
        assert([[local valueForKey:@"imagePath"] isEqual:Metadata(@"a0768339-c2d3-4189-9653-2909e9bb6f58", @"Local Theme", 315, @"V1")[@"imagePath"]]);
    }];
}

static void CheckUpdatePreservesServerFlags(RUINRegistrationFixture *fixture)
{
    NSString *productID = @"9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002";
    SeedServerOwnedRecord(fixture, productID);
    NSManagedObjectID *objectID = nil;
    NSError *error = nil;
    NSURL *packageURL = PackageURL(productID, &error);
    assert(packageURL != nil && error == nil);
    Register(Metadata(productID, @"Updated Theme", 8, @"V8"), NO, packageURL, &objectID, NULL, &error);
    assert(objectID != nil && error == nil);
    NSManagedObject *record = Fetch(fixture.context, productID);
    assert(record != nil);
    [fixture.context performBlockAndWait:^{
        assert(![[record valueForKey:@"owned"] boolValue]);
        assert(![[record valueForKey:@"grantedByDefault"] boolValue]);
        assert([[record valueForKey:@"validFor"] integerValue] == 42);
        assert(fabs([[record valueForKey:@"validUntil"] timeIntervalSince1970] - 6000.0) < 0.01);
        assert([[record valueForKey:@"name"] isEqual:@"Updated Theme"]);
        assert([[record valueForKey:@"version"] longLongValue] == 8);
        assert([[record valueForKey:@"latestVersion"] longLongValue] == 20);
        assert([[record valueForKey:@"latestVersionString"] isEqual:@"V20"]);
    }];
}

static void CheckCommittedWriteSurvivesMergeFailure(NSManagedObjectModel *model, NSURL *root)
{
    RUINRegistrationFixture *fixture = Fixture(model,
        StoreURL(root, @"S_mergefailure", @"Owned Themes"), NO);
    RUINMergeFailingContext *context = [[RUINMergeFailingContext alloc]
        initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = fixture.coordinator;
    fixture.context = context;
    assert(RUINNativeThemeRegistrationCaptureContextForTesting(context));

    NSString *productID = @"d0768339-c2d3-4189-9653-2909e9bb6f58";
    NSError *error = nil;
    NSURL *packageURL = PackageURL(productID, &error);
    assert(packageURL != nil && error == nil);
    NSManagedObjectID *objectID = nil;
    NSDictionary *persisted = nil;
    Register(Metadata(productID, @"Committed Before Merge", 4, @"V4"), YES,
        packageURL, &objectID, &persisted, &error);
    assert(objectID != nil && !objectID.isTemporaryID);
    assert(persisted != nil && [persisted[@"productID"] isEqual:productID]);
    assert([persisted[@"name"] isEqual:@"Committed Before Merge"]);
    assert([persisted[@"installedTime"] longLongValue] > 1000000000000LL);
    assert(error != nil);

    NSManagedObjectContext *verifier = [[NSManagedObjectContext alloc]
        initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    verifier.persistentStoreCoordinator = fixture.coordinator;
    NSManagedObject *saved = Fetch(verifier, productID);
    assert(saved != nil && [saved.objectID isEqual:objectID]);
    [verifier performBlockAndWait:^{
        assert([[saved valueForKey:@"name"] isEqual:@"Committed Before Merge"]);
        assert([[saved valueForKey:@"installedTime"] isEqual:persisted[@"installedTime"]]);
    }];
}

static NSURL *CheckPackageURL(NSURL *containerURL)
{
    RUINNativeThemeRegistrationSetGroupContainerForTesting(containerURL);
    NSError *error = nil;
    NSString *productID = @"a0768339-c2d3-4189-9653-2909e9bb6f58";
    NSURL *URL = PackageURL(productID, &error);
    assert(URL != nil && error == nil);
    NSURL *expected = [[[[[containerURL URLByAppendingPathComponent:@"Library" isDirectory:YES]
        URLByAppendingPathComponent:@"Application Support" isDirectory:YES]
        URLByAppendingPathComponent:@"PrivateStore" isDirectory:YES]
        URLByAppendingPathComponent:@"S_fixture" isDirectory:YES]
        URLByAppendingPathComponent:@"Theme Packages" isDirectory:YES];
    expected = [expected URLByAppendingPathComponent:productID isDirectory:YES].standardizedURL;
    assert([URL isEqual:expected]);
    assert(![[NSFileManager defaultManager] fileExistsAtPath:URL.path]);
    assert(PackageURL(@"../../bad", &error) == nil && error != nil);
    return URL;
}

static void CheckInvalidMetadata(void)
{
    NSString *productID = @"a0768339-c2d3-4189-9653-2909e9bb6f58";
    NSMutableDictionary *bad = [Metadata(productID, @"Bad", 2, @"V2") mutableCopy];
    bad[@"imagePath"] = @"/../../outside.png";
    NSManagedObjectID *objectID = nil;
    NSError *error = nil;
    NSURL *packageURL = PackageURL(productID, &error);
    assert(packageURL != nil && error == nil);
    Register(bad, YES, packageURL, &objectID, NULL, &error);
    assert(objectID == nil && error != nil);

    bad = [Metadata(productID, @"Bad", 2, @"V2") mutableCopy];
    bad[@"productAvailability"] = @YES;
    Register(bad, YES, packageURL, &objectID, NULL, &error);
    assert(objectID == nil && error != nil);
}

static void CheckObservedAccountChange(NSManagedObjectModel *model, NSURL *root,
    RUINRegistrationFixture *previous, NSURL *oldAccountURL)
{
    RUINRegistrationFixture *next = Fixture(model,
        StoreURL(root, @"S_nextaccount", @"Owned Themes"), NO);
    assert(RUINNativeThemeRegistrationCaptureContextForTesting(next.context));
    NSManagedObjectID *objectID = nil;
    NSError *error = nil;
    NSString *productID = @"c0768339-c2d3-4189-9653-2909e9bb6f58";
    Register(Metadata(productID, @"Next Account", 3, @"V3"), YES, oldAccountURL,
        &objectID, NULL, &error);
    assert(objectID == nil && error != nil);
    NSURL *packageURL = PackageURL(productID, &error);
    assert(packageURL != nil && error == nil);
    Register(Metadata(@"c0768339-c2d3-4189-9653-2909e9bb6f58", @"Next Account", 3, @"V3"), YES,
        packageURL, &objectID, NULL, &error);
    assert(objectID != nil && error == nil);
    assert(Fetch(next.context, @"c0768339-c2d3-4189-9653-2909e9bb6f58") != nil);
    assert(Fetch(previous.context, @"c0768339-c2d3-4189-9653-2909e9bb6f58") == nil);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        assert(argc == 2);
        NSURL *modelURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSManagedObjectModel *model = Theme2Model(modelURL);
        NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"RUINThemeRegistration-%@", NSUUID.UUID.UUIDString]
            isDirectory:YES];
        NSError *error = nil;
        assert([[NSFileManager defaultManager] createDirectoryAtURL:root
            withIntermediateDirectories:YES attributes:nil error:&error] && error == nil);

        CheckWrongEntityAndNamespace(model, root);
        CheckReadOnly(model, root);
        RUINRegistrationFixture *fixture = Fixture(model,
            StoreURL(root, @"S_fixture", @"Owned Themes"), NO);
        assert(RUINNativeThemeRegistrationCaptureContextForTesting(fixture.context));
        assert(RUINNativeThemeRegistrationAvailable());
        CheckPackageURL([root URLByAppendingPathComponent:@"MappedGroup"]);
        NSError *scopeError = nil;
        NSURL *oldAccountURL = PackageURL(@"c0768339-c2d3-4189-9653-2909e9bb6f58", &scopeError);
        assert(oldAccountURL != nil && scopeError == nil);
        CheckPendingChanges(fixture.context);
        CheckUpdatePreservesServerFlags(fixture);
        CheckCommittedWriteSurvivesMergeFailure(model, root);
        CheckInvalidMetadata();
        CheckObservedAccountChange(model, root, fixture, oldAccountURL);

        [[NSFileManager defaultManager] removeItemAtURL:root error:nil];
        puts("native theme registration checks passed");
    }
    return 0;
}
