#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSDictionary<NSString *, NSArray<NSDictionary *> *> * _Nullable
RUINNativeReadPositions(NSData *members, NSData *lastReads, NSData *entries, int64_t observedAt);

NS_ASSUME_NONNULL_END
