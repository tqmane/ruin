#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import "NativeThemeLocalPolicy.h"
#include <assert.h>
int main(void) { @autoreleasepool {
 NSString *pid=@"9ddd1e78-ff28-4a4e-a5ce-f021b9ca9002";
 NSSet *ids=[NSSet setWithObject:pid];
 NSDictionary *local=@{@"productID":pid,@"owned":@NO,@"name":@"local",@"grantedByDefault":@YES,@"defaultOrder":@(-1)};
 NSPredicate *p=[NSPredicate predicateWithFormat:@"owned == YES AND name == %@",@"local"];
 const uintptr_t syncA[]={0x1057f9058,0x1057fdda0},syncB[]={0x1057f9058,0x1057fd5d4};
 const uintptr_t list[]={0x1057feef0,0x1057ff0c0},other[]={0x1057f9058,0x1057fe000};
 assert(RUINNativeThemeRevocationFetchPCsMatch(syncA,2)&&RUINNativeThemeRevocationFetchPCsMatch(syncB,2));
 assert(!RUINNativeThemeRevocationFetchPCsMatch(list,2)&&!RUINNativeThemeRevocationFetchPCsMatch(other,2));
 assert(!RUINNativeThemeRevocationFetchPCsMatch(syncA,1));
 assert(![RUINNativeThemeRevocationPredicate(p,ids) evaluateWithObject:local]);
 assert(([RUINNativeThemeRevocationPredicate(p,ids) evaluateWithObject:
     @{@"productID":pid,@"owned":@YES,@"name":@"local",@"defaultOrder":@3}]));
 assert(([RUINNativeThemeRevocationPredicate([NSPredicate predicateWithFormat:@"owned == YES"],ids)
     evaluateWithObject:@{@"productID":@"other",@"owned":@YES}]));
 assert((![RUINNativeThemeRevocationPredicate(p,ids)
     evaluateWithObject:@{@"productID":@"other",@"owned":@YES,@"name":@"wrong"}]));
 assert([RUINNativeLocalThemePredicate(p,ids) evaluateWithObject:local]);
 assert(![RUINNativeLocalThemePredicate([NSPredicate predicateWithFormat:@"owned == YES AND name == %@",@"other"],ids) evaluateWithObject:local]);
 assert(![RUINNativeLocalThemePredicate([NSPredicate predicateWithFormat:@"owned == NO"],ids) evaluateWithObject:local]);
 assert(![RUINNativeLocalThemePredicate([NSPredicate predicateWithFormat:@"NOT (owned == YES)"],ids) evaluateWithObject:local]);
 assert([RUINNativeLocalThemePredicate([NSPredicate predicateWithFormat:@"YES == owned"],ids) evaluateWithObject:local]);
 NSURL *root=[[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[@"ruin-parent-policy-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
 NSURL *package=[root URLByAppendingPathComponent:pid isDirectory:YES];
 assert([NSFileManager.defaultManager createDirectoryAtURL:package withIntermediateDirectories:YES attributes:nil error:nil]);
 assert([[@"{\"manifest\":{\"platform\":\"iOS\",\"revision\":1}}" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:[package URLByAppendingPathComponent:@"theme.json"] atomically:YES]);
 assert(![RUINNativeLocalThemeIDs(root) containsObject:pid]);
 NSError *error=nil;
 assert(RUINWriteNativeLocalThemeMarker(package,@{@"productID":pid,@"rawVersion":@1},&error));
 assert([RUINNativeLocalThemeIDs(root) containsObject:pid]);
 NSEntityDescription *e=[NSEntityDescription new]; e.name=@"OwnedThemeProduct"; e.managedObjectClassName=@"NSManagedObject";
 NSMutableArray *attrs=[NSMutableArray array];
 for(NSString *key in @[@"productID",@"name",@"owned",@"grantedByDefault",@"defaultOrder"]) {NSAttributeDescription *a=[NSAttributeDescription new];a.name=key;a.attributeType=([key isEqual:@"owned"]||[key isEqual:@"grantedByDefault"])?NSBooleanAttributeType:([key isEqual:@"defaultOrder"]?NSInteger16AttributeType:NSStringAttributeType);[attrs addObject:a];}
 e.properties=attrs;NSManagedObjectModel *m=[NSManagedObjectModel new];m.entities=@[e];
 NSPersistentStoreCoordinator *psc=[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:m];
 assert([psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[root URLByAppendingPathComponent:@"test.sqlite"] options:nil error:&error]);
 NSManagedObjectContext *c=[[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];c.persistentStoreCoordinator=psc;
 NSManagedObject *o=[[NSManagedObject alloc] initWithEntity:e insertIntoManagedObjectContext:c];[o setValuesForKeysWithDictionary:local];assert([c save:&error]);
 NSFetchRequest *r=[NSFetchRequest fetchRequestWithEntityName:e.name];r.predicate=p;assert([c executeFetchRequest:r error:&error].count==0);
 r.predicate=RUINNativeLocalThemePredicate(p,ids);NSArray *found=[c executeFetchRequest:r error:&error];assert(found.count==1);
 RUINProjectNativeLocalThemeObjects(found,c,ids);assert([[o valueForKey:@"owned"] boolValue]);assert(!c.hasChanges&&!o.hasChanges);assert(![[o valueForKey:@"grantedByDefault"] boolValue]);
 NSManagedObjectContext *fresh=[[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];fresh.persistentStoreCoordinator=psc;
 NSManagedObject *stored=[fresh existingObjectWithID:o.objectID error:&error];assert(![[stored valueForKey:@"owned"] boolValue]);assert([[stored valueForKey:@"grantedByDefault"] boolValue]);
 NSPersistentStoreCoordinator *readPSC=[[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:m];
 assert([readPSC addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[root URLByAppendingPathComponent:@"test.sqlite"] options:@{NSReadOnlyPersistentStoreOption:@YES} error:&error]);
 NSManagedObjectContext *readContext=[[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];readContext.persistentStoreCoordinator=readPSC;
 NSArray *readFound=[readContext executeFetchRequest:r error:&error];assert(readFound.count==1);
 RUINProjectNativeLocalThemeObjects(readFound,readContext,ids);assert([[[readFound firstObject] valueForKey:@"owned"] boolValue]);assert(!readContext.hasChanges);
 // Exercise the native sync predicate against real SQLite rows. It removes
 // the local import from revocation candidates while My Themes keeps it.
 NSManagedObject *foreign=[[NSManagedObject alloc] initWithEntity:e insertIntoManagedObjectContext:c];
 [foreign setValuesForKeysWithDictionary:@{@"productID":NSUUID.UUID.UUIDString.lowercaseString,@"name":@"foreign",@"owned":@YES}];
 [c refreshObject:o mergeChanges:NO];[o setValue:@YES forKey:@"owned"];assert([c save:&error]);
 NSFetchRequest *sync=[NSFetchRequest fetchRequestWithEntityName:e.name];
 sync.predicate=[NSPredicate predicateWithFormat:@"owned == YES"];
 assert([c executeFetchRequest:sync error:&error].count==2);
 sync.predicate=RUINNativeThemeRevocationPredicate(sync.predicate,ids);
 NSArray *candidates=[c executeFetchRequest:sync error:&error];
 assert(candidates.count==1 && [[candidates.firstObject objectID] isEqual:foreign.objectID]);
 sync.predicate=RUINNativeLocalThemePredicate([NSPredicate predicateWithFormat:@"owned == YES"],ids);
 assert([c executeFetchRequest:sync error:&error].count==2);
 assert([NSFileManager.defaultManager removeItemAtURL:root error:nil]);
 puts("PASS SQLite owned-filter projection, compound and negative isolation, no dirty/save, read-only store projection, real marker/manifest eligibility");
} return 0;}
