#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL RUINWriteNativeLocalThemeMarker(NSURL *packageURL, NSDictionary *metadata, NSError **error);
FOUNDATION_EXPORT NSSet<NSString *> *RUINNativeLocalThemeIDs(NSURL *packagesRoot);
FOUNDATION_EXPORT NSPredicate * _Nullable RUINNativeLocalThemePredicate(NSPredicate * _Nullable predicate, NSSet<NSString *> *IDs);
FOUNDATION_EXPORT BOOL RUINNativeThemeRevocationFetchPCsMatch(const uintptr_t *PCs, NSUInteger count);
FOUNDATION_EXPORT NSPredicate * _Nullable RUINNativeThemeRevocationPredicate(NSPredicate * _Nullable predicate, NSSet<NSString *> *IDs);
FOUNDATION_EXPORT void RUINProjectNativeLocalThemeObjects(NSArray *objects, NSManagedObjectContext *context, NSSet<NSString *> *IDs);
FOUNDATION_EXPORT NSDictionary *RUINNativeThemeLocalPolicyDiagnostics(void);
NS_ASSUME_NONNULL_END
