#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const uint64_t RUINGIFEncoderMaximumInputBytes;
FOUNDATION_EXPORT const NSUInteger RUINGIFEncoderMaximumFrameCount;
FOUNDATION_EXPORT const NSUInteger RUINGIFEncoderMaximumDimension;
FOUNDATION_EXPORT const uint64_t RUINGIFEncoderMaximumTotalPixels;

typedef NS_ENUM(NSInteger, RUINGIFEncoderErrorCode) {
    RUINGIFEncoderErrorInvalidLocalFile = 1,
    RUINGIFEncoderErrorLocalFileRead,
    RUINGIFEncoderErrorInputTooLarge,
    RUINGIFEncoderErrorNotAnimated,
    RUINGIFEncoderErrorTooManyFrames,
    RUINGIFEncoderErrorInvalidDimensions,
    RUINGIFEncoderErrorDimensionTooLarge,
    RUINGIFEncoderErrorTooManyPixels,
    RUINGIFEncoderErrorMissingFrameTiming,
    RUINGIFEncoderErrorInvalidFrameTiming,
    RUINGIFEncoderErrorInvalidLoopCount,
    RUINGIFEncoderErrorImageDecode,
    RUINGIFEncoderErrorGIFEncoding
};

/** Returns local GIF data only after all source bounds and frame metadata pass.
    Consecutive pixel-identical canvas frames share one output frame with their delays summed.
    encodedFrameCount reports the verified output count, which may be one for an unchanging image.
    Delays are rounded at cumulative frame boundaries to the nearest GIF centisecond, limiting
    timeline-boundary error to 5.001 ms. A coalesced pause above GIF's 16-bit delay limit is rejected. */
FOUNDATION_EXPORT NSData * _Nullable RUINGIFEncoderCreateGIFDataFromLocalFileURL(
    NSURL *URL, NSUInteger * _Nullable encodedFrameCount, NSError * _Nullable * _Nullable error);

/** Stable content-free rejection label for diagnostics. */
FOUNDATION_EXPORT NSString *RUINGIFEncoderRejectionName(NSInteger errorCode);

NS_ASSUME_NONNULL_END
