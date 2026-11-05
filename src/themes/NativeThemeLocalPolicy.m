#import "NativeThemeLocalPolicy.h"
#import "NativeThemeReceipt.h"
#import <os/lock.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdatomic.h>

static const char *kLocalMarker = ".ruin-local-theme.plist";
static os_unfair_lock gLocalCacheLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary *gLocalCache;
static NSUInteger gLocalGeneration;
static atomic_uint_fast64_t gLocalScans, gLocalMatches, gPredicateRewrites, gProjectedObjects, gReadonlyProjectedObjects;
static atomic_uint_fast64_t gRevocationScansIsolated;

BOOL RUINNativeThemeRevocationFetchPCsMatch(const uintptr_t *PCs, NSUInteger count)
{
    // Actual fetch stacks: native owned-theme repository -> server sync's
    // revocation scan. My Themes' separate read-only fetch does not match.
    return PCs && count >= 2 && PCs[0] == 0x1057f9058 &&
        (PCs[1] == 0x1057fdda0 || PCs[1] == 0x1057fd5d4);
}

NSPredicate *RUINNativeThemeRevocationPredicate(NSPredicate *predicate, NSSet<NSString *> *IDs)
{
    if (!IDs.count) return predicate;
    NSPredicate *excluded = [NSCompoundPredicate notPredicateWithSubpredicate:
        [NSPredicate predicateWithFormat:@"productID IN %@ AND defaultOrder < 0", IDs]];
    atomic_fetch_add(&gRevocationScansIsolated, 1);
    return predicate ? [NSCompoundPredicate andPredicateWithSubpredicates:@[predicate, excluded]] : excluded;
}

static NSData *RUINReadRegularFileAt(int directory, const char *name, off_t maximum)
{
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat status;
    if (fstat(fd, &status) || !S_ISREG(status.st_mode) || status.st_size <= 0 || status.st_size > maximum) {
        close(fd); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)status.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(fd, (uint8_t *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); return nil; }
        offset += (NSUInteger)count;
    }
    close(fd);
    return data;
}

static BOOL RUINLocalManifestMatches(int directory, NSString *productID, NSNumber *revision)
{
    if (![revision isKindOfClass:NSNumber.class] || revision.longLongValue < 1) return NO;
    NSData *markerData = RUINReadRegularFileAt(directory, kLocalMarker, 16384);
    id marker = markerData ? [NSPropertyListSerialization propertyListWithData:markerData options:NSPropertyListImmutable format:NULL error:nil] : nil;
    if (![marker isKindOfClass:NSDictionary.class] || ![marker[@"productID"] isEqual:productID] ||
        ![marker[@"rawVersion"] isEqual:revision]) return NO;
    NSData *json = RUINReadRegularFileAt(directory, "theme.json", 4 * 1024 * 1024);
    id document = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    id manifest = [document isKindOfClass:NSDictionary.class] ? document[@"manifest"] : nil;
    return [manifest isKindOfClass:NSDictionary.class] && [manifest[@"platform"] isEqual:@"iOS"] &&
        [manifest[@"revision"] isEqual:revision];
}

BOOL RUINWriteNativeLocalThemeMarker(NSURL *packageURL, NSDictionary *metadata, NSError **error)
{
    NSString *productID = metadata[@"productID"];
    NSNumber *version = metadata[@"rawVersion"];
    if (!packageURL.isFileURL || ![productID isKindOfClass:NSString.class] ||
        ![[[NSUUID alloc] initWithUUIDString:productID].UUIDString.lowercaseString isEqual:packageURL.lastPathComponent] ||
        ![version isKindOfClass:NSNumber.class] || version.longLongValue < 1) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{@"productID":productID, @"rawVersion":version}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    int directory = open(packageURL.path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (!data || directory < 0) return NO;
    NSString *temporary = [@".ruin-marker-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(directory, temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    BOOL success = fd >= 0;
    NSUInteger offset = 0;
    while (success && offset < data.length) {
        ssize_t count = write(fd, (const uint8_t *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) success = NO;
        else offset += (NSUInteger)count;
    }
    if (fd >= 0) close(fd);
    if (success) success = renameat(directory, temporary.fileSystemRepresentation, directory, kLocalMarker) == 0;
    if (!success) unlinkat(directory, temporary.fileSystemRepresentation, 0);
    close(directory);
    if (success) {
        os_unfair_lock_lock(&gLocalCacheLock);
        gLocalGeneration++;
        [gLocalCache removeAllObjects];
        os_unfair_lock_unlock(&gLocalCacheLock);
    } else if (error && !*error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
    return success;
}

NSSet<NSString *> *RUINNativeLocalThemeIDs(NSURL *packagesRoot)
{
    if (!packagesRoot.isFileURL) return [NSSet set];
    NSSet *registered = [NSSet setWithArray:RUINReadThemeReceipts(packagesRoot).allKeys];
    int root = open(packagesRoot.path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat status;
    if (root < 0) { atomic_store(&gLocalMatches, registered.count); return registered; }
    if (fstat(root, &status)) { close(root); return registered; }
    os_unfair_lock_lock(&gLocalCacheLock);
    NSUInteger generation = gLocalGeneration;
    NSArray *stamp = @[@(generation), @(status.st_ino), @(status.st_mtimespec.tv_sec), @(status.st_mtimespec.tv_nsec)];
    NSDictionary *cached = gLocalCache[packagesRoot.path];
    NSSet *found = [cached[@"stamp"] isEqual:stamp] &&
        [NSDate.date timeIntervalSinceDate:cached[@"checkedAt"] ?: NSDate.distantPast] < 1.0 ? cached[@"IDs"] : nil;
    os_unfair_lock_unlock(&gLocalCacheLock);
    if (found) {
        close(root);
        NSSet *result = [found setByAddingObjectsFromSet:registered];
        atomic_store(&gLocalMatches, result.count);
        return result;
    }
    NSMutableSet *IDs = [NSMutableSet set];
    atomic_fetch_add(&gLocalScans, 1);
    DIR *entries = fdopendir(root);
    if (!entries) { close(root); return IDs; }
    struct dirent *entry;
    NSUInteger visited = 0;
    while ((entry = readdir(entries)) && visited++ < 4096) {
        NSString *productID = [NSString stringWithUTF8String:entry->d_name];
        NSUUID *UUID = productID ? [[NSUUID alloc] initWithUUIDString:productID] : nil;
        if (!UUID || ![UUID.UUIDString.lowercaseString isEqual:productID]) continue;
        int directory = openat(root, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (directory < 0) continue;
        NSData *markerData = RUINReadRegularFileAt(directory, kLocalMarker, 16384);
        id marker = markerData ? [NSPropertyListSerialization propertyListWithData:markerData options:NSPropertyListImmutable format:NULL error:nil] : nil;
        NSNumber *version = [marker isKindOfClass:NSDictionary.class] ? marker[@"rawVersion"] : nil;
        if (RUINLocalManifestMatches(directory, productID, version)) [IDs addObject:productID];
        close(directory);
    }
    closedir(entries);
    found = [IDs copy];
    os_unfair_lock_lock(&gLocalCacheLock);
    if (!gLocalCache) gLocalCache = [NSMutableDictionary dictionary];
    if (gLocalCache.count > 4) [gLocalCache removeAllObjects];
    if (generation == gLocalGeneration) gLocalCache[packagesRoot.path] = @{@"stamp":stamp, @"IDs":found, @"checkedAt":NSDate.date};
    os_unfair_lock_unlock(&gLocalCacheLock);
    NSSet *result = [found setByAddingObjectsFromSet:registered];
    atomic_store(&gLocalMatches, result.count);
    return result;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
NSPredicate *RUINNativeLocalThemePredicate(NSPredicate *predicate, NSSet<NSString *> *IDs)
{
    if (!predicate || !IDs.count) return predicate;
    if ([predicate isKindOfClass:NSCompoundPredicate.class]) {
        NSCompoundPredicate *compound = (NSCompoundPredicate *)predicate;
        NSMutableArray *children = [NSMutableArray array];
        for (NSPredicate *child in compound.subpredicates) [children addObject:RUINNativeLocalThemePredicate(child, IDs)];
        return [[NSCompoundPredicate alloc] initWithType:compound.compoundPredicateType subpredicates:children];
    }
    if (![predicate isKindOfClass:NSComparisonPredicate.class]) return predicate;
    NSComparisonPredicate *comparison = (NSComparisonPredicate *)predicate;
    NSExpression *key = comparison.leftExpression, *value = comparison.rightExpression;
    if (key.expressionType == NSConstantValueExpressionType) { key = comparison.rightExpression; value = comparison.leftExpression; }
    if (comparison.comparisonPredicateModifier != NSDirectPredicateModifier || comparison.options ||
        key.expressionType != NSKeyPathExpressionType || ![key.keyPath isEqual:@"owned"] ||
        value.expressionType != NSConstantValueExpressionType || ![value.constantValue isKindOfClass:NSNumber.class]) return predicate;
    NSNumber *number = value.constantValue;
    if (![number isEqual:@0] && ![number isEqual:@1]) return predicate;
    BOOL positive = number.boolValue;
    if (comparison.predicateOperatorType == NSNotEqualToPredicateOperatorType) positive = !positive;
    else if (comparison.predicateOperatorType != NSEqualToPredicateOperatorType) return predicate;
    NSPredicate *local = [NSPredicate predicateWithFormat:@"productID IN %@", IDs];
    atomic_fetch_add(&gPredicateRewrites, 1);
    return positive ? [NSCompoundPredicate orPredicateWithSubpredicates:@[predicate, local]] :
        [NSCompoundPredicate andPredicateWithSubpredicates:@[predicate, [NSCompoundPredicate notPredicateWithSubpredicate:local]]];
}
#pragma clang diagnostic pop

void RUINProjectNativeLocalThemeObjects(NSArray *objects, NSManagedObjectContext *context, NSSet<NSString *> *IDs)
{
    if (!IDs.count) return;
    for (id value in objects) {
        if (![value isKindOfClass:NSManagedObject.class]) continue;
        NSManagedObject *object = value;
        if (object.managedObjectContext != context || object.hasChanges || object.isDeleted ||
            ![object.entity.name isEqual:@"OwnedThemeProduct"] ||
            object.entity.attributesByName[@"owned"].attributeType != NSBooleanAttributeType) continue;
        if (![IDs containsObject:[object valueForKey:@"productID"]]) continue;
        // Primitive projection changes the value used to compose ThemePackage,
        // without dirtying the native context or changing its stored receipt.
        (void)[object valueForKey:@"owned"];
        [object setPrimitiveValue:@YES forKey:@"owned"];
        if (object.entity.attributesByName[@"defaultOrder"].attributeType == NSInteger16AttributeType &&
            object.entity.attributesByName[@"grantedByDefault"].attributeType == NSBooleanAttributeType &&
            [[object valueForKey:@"defaultOrder"] integerValue] < 0)
            [object setPrimitiveValue:@NO forKey:@"grantedByDefault"];
        if (object.entity.attributesByName[@"applicationVersionRange"].attributeType == NSStringAttributeType &&
            ![[object valueForKey:@"applicationVersionRange"] length])
            [object setPrimitiveValue:@"0,1000.0.0,1,26.16.0" forKey:@"applicationVersionRange"];
        atomic_fetch_add(&gProjectedObjects, 1);
        if (object.objectID.persistentStore.isReadOnly) atomic_fetch_add(&gReadonlyProjectedObjects, 1);
    }
}

NSDictionary *RUINNativeThemeLocalPolicyDiagnostics(void)
{
    return @{@"scans":@(atomic_load(&gLocalScans)), @"localPackages":@(atomic_load(&gLocalMatches)),
        @"predicateLeavesAdapted":@(atomic_load(&gPredicateRewrites)),
        @"objectsProjected":@(atomic_load(&gProjectedObjects)),
        @"readonlyObjectsProjected":@(atomic_load(&gReadonlyProjectedObjects)),
        @"serverRevocationScansIsolated":@(atomic_load(&gRevocationScansIsolated)), @"contextSavePerformed":@NO};
}
