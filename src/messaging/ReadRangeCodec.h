#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const RUINReadRangeCodecErrorDomain;

typedef NS_ERROR_ENUM(RUINReadRangeCodecErrorDomain, RUINReadRangeCodecError) {
    RUINReadRangeCodecErrorInvalidArgument = 1,
    RUINReadRangeCodecErrorMalformedMessage = 2,
    RUINReadRangeCodecErrorBounds = 3,
    RUINReadRangeCodecErrorSchema = 4,
    RUINReadRangeCodecErrorServer = 5,
};

FOUNDATION_EXPORT NSData * _Nullable RUINReadRangeEncodeRequest(NSString *chatID, int32_t seq, NSError **error);
FOUNDATION_EXPORT NSDictionary<NSString *, NSArray<NSDictionary *> *> * _Nullable
RUINReadRangeDecodeResponse(NSData *data, NSString *expectedChatID, int32_t seq, NSError **error);
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *RUINReadRangeCodecDiagnostics(void);

NS_ASSUME_NONNULL_END
