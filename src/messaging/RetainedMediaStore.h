#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RUINRetainedMediaStore : NSObject
- (nullable instancetype)initWithDirectoryURL:(NSURL *)directoryURL
                                        error:(NSError * _Nullable * _Nullable)error;
- (BOOL)captureURL:(NSURL *)source
      allowedRoots:(NSArray<NSURL *> *)roots
            forKey:(NSDictionary *)key
              role:(NSString *)role
        completion:(void (^ _Nullable)(BOOL success))completion;
- (BOOL)captureData:(NSData *)data
          extension:(NSString *)extension
             forKey:(NSDictionary *)key
               role:(NSString *)role
         completion:(void (^ _Nullable)(BOOL success))completion;
- (BOOL)markUnsentForKey:(NSDictionary *)key;
- (BOOL)isUnsentForKey:(NSDictionary *)key;
- (NSArray<NSDictionary<NSString *, id> *> *)itemsForKey:(NSDictionary *)key;
// Monotonic operation counts only; contains no paths or message identifiers.
- (NSDictionary<NSString *, NSNumber *> *)diagnostics;
@end

NS_ASSUME_NONNULL_END
