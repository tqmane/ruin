#import <CoreData/CoreData.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

#import "NativeThemeInstall.h"
#import "NativeThemeRegistration.h"
#import "NativeThemeReceipt.h"
#import "ThemeFeatures.h"

#include <assert.h>
#include <stdio.h>

static NSDictionary<NSString *, id> *gCatalogRecord;

NSArray<NSDictionary<NSString *, id> *> *RUINThemeCatalog(NSError **error)
{
    if (error) *error = nil;
    return gCatalogRecord ? @[gCatalogRecord] : @[];
}

static NSAttributeDescription *Attribute(NSString *name, NSAttributeType type)
{
    NSAttributeDescription *attribute = [NSAttributeDescription new];
    attribute.name = name;
    attribute.attributeType = type;
    attribute.optional = YES;
    return attribute;
}

static NSManagedObjectModel *Theme2Model(void)
{
    NSEntityDescription *entity = [NSEntityDescription new];
    entity.name = @"OwnedThemeProduct";
    entity.managedObjectClassName = NSStringFromClass(NSManagedObject.class);
    entity.properties = @[
        Attribute(@"productID", NSStringAttributeType), Attribute(@"installedTime", NSInteger64AttributeType),
        Attribute(@"version", NSInteger64AttributeType), Attribute(@"name", NSStringAttributeType),
        Attribute(@"versionString", NSStringAttributeType), Attribute(@"imagePath", NSStringAttributeType),
        Attribute(@"owned", NSBooleanAttributeType), Attribute(@"grantedByDefault", NSBooleanAttributeType),
        Attribute(@"productAvailability", NSInteger16AttributeType), Attribute(@"latestVersion", NSInteger64AttributeType),
        Attribute(@"latestVersionString", NSStringAttributeType), Attribute(@"validFor", NSInteger32AttributeType),
        Attribute(@"validUntil", NSDateAttributeType), Attribute(@"defaultOrder", NSInteger16AttributeType)
    ];
    NSManagedObjectModel *model = [NSManagedObjectModel new];
    model.entities = @[entity];
    return model;
}

static NSDictionary<NSString *, id> *Import(NSDictionary<NSString *, id> *record, NSError **errorOut)
{
    __block NSDictionary *result = nil;
    __block NSError *error = nil;
    __block BOOL finished = NO;
    RUINImportDownloadedTheme(record, ^(NSDictionary<NSString *, id> *returnedResult, NSError *returnedError) {
        result = returnedResult;
        error = returnedError;
        finished = YES;
        CFRunLoopStop(CFRunLoopGetMain());
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
    while (!finished && deadline.timeIntervalSinceNow > 0)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, true);
    assert(finished);
    if (errorOut) *errorOut = error;
    return result;
}

static void AddDuplicateRow(NSManagedObjectContext *context, NSString *productID)
{
    [context performBlockAndWait:^{
        NSManagedObject *duplicate = [NSEntityDescription insertNewObjectForEntityForName:@"OwnedThemeProduct"
            inManagedObjectContext:context];
        [duplicate setValue:productID forKey:@"productID"];
        NSError *error = nil;
        assert([context save:&error] && error == nil);
    }];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        assert(argc == 2);
        NSString *archivePath = [NSString stringWithUTF8String:argv[1]];
        if (![archivePath hasPrefix:@"/"])
            archivePath = [[NSFileManager defaultManager].currentDirectoryPath stringByAppendingPathComponent:archivePath];
        NSURL *archiveURL = [NSURL fileURLWithPath:archivePath];
        NSURL *versionURL = archiveURL.URLByDeletingLastPathComponent;
        NSURL *productURL = versionURL.URLByDeletingLastPathComponent;
        NSString *productID = productURL.lastPathComponent.lowercaseString;
        NSString *nameURLPath = [[archiveURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"name"].path;
        NSString *name = [NSString stringWithContentsOfFile:nameURLPath encoding:NSUTF8StringEncoding error:nil];
        NSString *rawVersion = versionURL.lastPathComponent;
        assert(productID.length == 36 && name.length && rawVersion.length);

        gCatalogRecord = @{
            @"productID":productID, @"name":name, @"version":rawVersion,
            @"packageURL":archiveURL, @"downloadedLocally":@YES, @"archiveStructureValidated":@YES
        };

        char temporary[] = "/tmp/ruin-native-theme-install.XXXXXX";
        char *rootPath = mkdtemp(temporary);
        assert(rootPath != NULL);
        NSURL *rootURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:rootPath] isDirectory:YES];
        NSURL *applicationSupportURL = [rootURL URLByAppendingPathComponent:@"Library/Application Support" isDirectory:YES];
        NSURL *groupURL = [applicationSupportURL URLByAppendingPathComponent:
            @"RUIN/AppGroups/group.com.linecorp.line" isDirectory:YES];
        assert([[NSFileManager defaultManager] createDirectoryAtURL:groupURL
            withIntermediateDirectories:YES attributes:nil error:nil]);
        RUINNativeThemeRegistrationSetGroupContainerForTesting(groupURL);
        RUINNativeThemeRegistrationSetApplicationSupportForTesting(applicationSupportURL);

        NSString *mid = @"u00000000000000000000000000000000";
        NSArray *accounts = @[[@"P_" stringByAppendingString:mid], [@"S_" stringByAppendingString:mid]];
        NSMutableArray<NSURL *> *packageURLs = [NSMutableArray array];
        for (NSString *account in accounts) {
            NSURL *storeDirectory = [[[applicationSupportURL URLByAppendingPathComponent:@"PrivateStore" isDirectory:YES]
                URLByAppendingPathComponent:account isDirectory:YES]
                URLByAppendingPathComponent:@"Owned Themes" isDirectory:YES];
            NSURL *storeURL = [storeDirectory URLByAppendingPathComponent:@"OwnedThemeProduct.sqlite"];
            assert([[NSFileManager defaultManager] createDirectoryAtURL:storeDirectory
                withIntermediateDirectories:YES attributes:nil error:nil]);

            NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:Theme2Model()];
            NSError *error = nil;
            NSPersistentStore *store = [coordinator addPersistentStoreWithType:NSSQLiteStoreType
                configuration:nil URL:storeURL options:nil error:&error];
            assert(store && !error);
            NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
            context.persistentStoreCoordinator = coordinator;
            assert(RUINNativeThemeRegistrationCaptureContextForTesting(context));

            NSDictionary *result = Import(gCatalogRecord, &error);
            if (!result || error)
                NSLog(@"Native theme import fixture %@ failed: %@", account, error);
            assert(result && [result[@"committed"] boolValue] && !error);
            assert([result[@"receiptSaved"] boolValue]);
            assert([(NSManagedObjectID *)result[@"objectID"] persistentStore] == store);
            NSURL *packageURL = result[@"packageURL"];
            NSDictionary *receipt = RUINReadThemeReceipt(packageURL.URLByDeletingLastPathComponent, productID);
            assert([receipt[@"productID"] isEqual:productID] && [receipt[@"name"] isEqual:name]);
            NSString *packagePath = [NSString pathWithComponents:@[@"Library", @"Application Support",
                @"PrivateStore", account, @"Theme Packages", productID]];
            assert([packageURL.URLByResolvingSymlinksInPath.standardizedURL isEqual:
                [groupURL.URLByResolvingSymlinksInPath URLByAppendingPathComponent:packagePath isDirectory:YES].standardizedURL]);
            for (NSURL *previous in packageURLs)
                assert(![previous.URLByResolvingSymlinksInPath isEqual:packageURL.URLByResolvingSymlinksInPath]);
            [packageURLs addObject:packageURL];
            assert(RUINIsRegisteredNativeThemeID(packageURL.lastPathComponent));
            assert([[NSFileManager defaultManager] fileExistsAtPath:
                [packageURL URLByAppendingPathComponent:@"theme.json"].path]);
            NSDictionary *metadata = result[@"metadata"];
            assert([metadata[@"rawVersion"] longLongValue] == strtoll(rawVersion.UTF8String, NULL, 10));
            assert([metadata[@"versionString"] isKindOfClass:NSString.class]);
            assert([metadata[@"imagePath"] hasSuffix:@"/ANDROID/icon_136x202.png"]);

            NSString *markerPath = [packageURL URLByAppendingPathComponent:@"rollback-marker"].path;
            NSString *priorPackage = [@"prior package " stringByAppendingString:account];
            assert([priorPackage writeToFile:markerPath atomically:YES encoding:NSUTF8StringEncoding error:nil]);
            AddDuplicateRow(context, productID);
            result = Import(gCatalogRecord, &error);
            assert(result == nil && error != nil);
            assert([[NSString stringWithContentsOfFile:markerPath encoding:NSUTF8StringEncoding error:nil]
                isEqual:priorPackage]);
            assert([RUINReadThemeReceipt(packageURL.URLByDeletingLastPathComponent, productID) isEqual:receipt]);

            [context performBlockAndWait:^{
                [context reset];
                context.persistentStoreCoordinator = nil;
            }];
            context = nil;
            error = nil;
            assert([coordinator removePersistentStore:store error:&error] && !error);
        }
        for (NSUInteger i = 0; i < accounts.count; i++) {
            NSString *marker = [NSString stringWithContentsOfURL:
                [packageURLs[i] URLByAppendingPathComponent:@"rollback-marker"] encoding:NSUTF8StringEncoding error:nil];
            assert([marker isEqual:[@"prior package " stringByAppendingString:accounts[i]]]);
        }
        [[NSFileManager defaultManager] removeItemAtURL:rootURL error:nil];
        puts("native theme install P_/S_ namespace commit and rollback checks passed");
    }
    return 0;
}
