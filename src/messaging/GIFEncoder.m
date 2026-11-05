#import "GIFEncoder.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <string.h>

const uint64_t RUINGIFEncoderMaximumInputBytes = 64ULL * 1024ULL * 1024ULL;
const NSUInteger RUINGIFEncoderMaximumFrameCount = 512;
const NSUInteger RUINGIFEncoderMaximumDimension = 2048;
const uint64_t RUINGIFEncoderMaximumTotalPixels = 64ULL * 1024ULL * 1024ULL;

static NSString * const RUINGIFEncoderErrorDomain = @"RUINGIFEncoderErrorDomain";

static void RUINGIFEncoderSetError(NSError **error, RUINGIFEncoderErrorCode code, NSString *description)
{
    if (error) *error = [NSError errorWithDomain:RUINGIFEncoderErrorDomain
                                            code:code
                                        userInfo:@{NSLocalizedDescriptionKey: description}];
}

NSString *RUINGIFEncoderRejectionName(NSInteger errorCode)
{
    switch (errorCode) {
        case 0: return @"none";
        case RUINGIFEncoderErrorInvalidLocalFile: return @"invalid_local_file";
        case RUINGIFEncoderErrorLocalFileRead: return @"local_file_read";
        case RUINGIFEncoderErrorInputTooLarge: return @"input_too_large";
        case RUINGIFEncoderErrorNotAnimated: return @"not_animated";
        case RUINGIFEncoderErrorTooManyFrames: return @"too_many_frames";
        case RUINGIFEncoderErrorInvalidDimensions: return @"invalid_dimensions";
        case RUINGIFEncoderErrorDimensionTooLarge: return @"dimension_too_large";
        case RUINGIFEncoderErrorTooManyPixels: return @"too_many_pixels";
        case RUINGIFEncoderErrorMissingFrameTiming: return @"missing_frame_timing";
        case RUINGIFEncoderErrorInvalidFrameTiming: return @"invalid_frame_timing";
        case RUINGIFEncoderErrorInvalidLoopCount: return @"invalid_loop_count";
        case RUINGIFEncoderErrorImageDecode: return @"image_decode";
        case RUINGIFEncoderErrorGIFEncoding: return @"gif_encoding";
        default: return @"unknown";
    }
}

static BOOL RUINGIFEncoderPositiveInteger(id value, uint64_t *result)
{
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double number = [value doubleValue];
    if (!isfinite(number) || number < 1.0 || number >= 18446744073709551616.0 || floor(number) != number) return NO;
    if (result) *result = (uint64_t)number;
    return YES;
}

static BOOL RUINGIFEncoderGIFCanvasDimensions(NSData *data, uint64_t *width, uint64_t *height)
{
    const uint8_t *bytes = data.bytes;
    BOOL isGIF = data.length >= 10 &&
        ((memcmp(bytes, "GIF87a", 6) == 0) || (memcmp(bytes, "GIF89a", 6) == 0));
    if (!isGIF) return NO;
    uint64_t parsedWidth = (uint64_t)bytes[6] | ((uint64_t)bytes[7] << 8);
    uint64_t parsedHeight = (uint64_t)bytes[8] | ((uint64_t)bytes[9] << 8);
    if (parsedWidth == 0 || parsedHeight == 0) return NO;
    if (width) *width = parsedWidth;
    if (height) *height = parsedHeight;
    return YES;
}

static NSDictionary *RUINGIFEncoderPropertyDictionary(NSDictionary *properties, CFStringRef key)
{
    id value = properties[(__bridge NSString *)key];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

static BOOL RUINGIFEncoderCanvasFromMetadata(NSDictionary *properties, uint64_t *width, uint64_t *height)
{
    CFStringRef dictionaries[] = {kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary};
    CFStringRef widths[] = {kCGImagePropertyGIFCanvasPixelWidth, kCGImagePropertyAPNGCanvasPixelWidth, kCGImagePropertyWebPCanvasPixelWidth};
    CFStringRef heights[] = {kCGImagePropertyGIFCanvasPixelHeight, kCGImagePropertyAPNGCanvasPixelHeight, kCGImagePropertyWebPCanvasPixelHeight};
    for (NSUInteger index = 0; index < 3; index++) {
        NSDictionary *values = RUINGIFEncoderPropertyDictionary(properties, dictionaries[index]);
        if (RUINGIFEncoderPositiveInteger(values[(__bridge NSString *)widths[index]], width) &&
            RUINGIFEncoderPositiveInteger(values[(__bridge NSString *)heights[index]], height)) return YES;
    }
    return NO;
}

static NSNumber *RUINGIFEncoderFrameDelay(NSDictionary *properties, RUINGIFEncoderErrorCode *failure)
{
    NSDictionary *containers[] = {
        RUINGIFEncoderPropertyDictionary(properties, kCGImagePropertyGIFDictionary),
        RUINGIFEncoderPropertyDictionary(properties, kCGImagePropertyPNGDictionary),
        RUINGIFEncoderPropertyDictionary(properties, kCGImagePropertyWebPDictionary)
    };
    CFStringRef unclampedKeys[] = {
        kCGImagePropertyGIFUnclampedDelayTime,
        kCGImagePropertyAPNGUnclampedDelayTime,
        kCGImagePropertyWebPUnclampedDelayTime
    };
    CFStringRef delayKeys[] = {
        kCGImagePropertyGIFDelayTime,
        kCGImagePropertyAPNGDelayTime,
        kCGImagePropertyWebPDelayTime
    };

    BOOL sawTiming = NO;
    for (NSUInteger index = 0; index < sizeof(containers) / sizeof(containers[0]); index++) {
        id value = containers[index][(__bridge NSString *)unclampedKeys[index]];
        if (value) {
            sawTiming = YES;
            if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) && [value doubleValue] >= 0.0)
                return value;
            continue;
        }

        value = containers[index][(__bridge NSString *)delayKeys[index]];
        if (!value) continue;
        sawTiming = YES;
        if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) && [value doubleValue] >= 0.0)
            return value;
    }

    if (failure) *failure = sawTiming ? RUINGIFEncoderErrorInvalidFrameTiming : RUINGIFEncoderErrorMissingFrameTiming;
    return nil;
}

static NSNumber *RUINGIFEncoderLoopCount(NSDictionary *properties, RUINGIFEncoderErrorCode *failure)
{
    NSDictionary *containers[] = {
        RUINGIFEncoderPropertyDictionary(properties, kCGImagePropertyGIFDictionary),
        RUINGIFEncoderPropertyDictionary(properties, kCGImagePropertyPNGDictionary),
        RUINGIFEncoderPropertyDictionary(properties, kCGImagePropertyWebPDictionary)
    };
    CFStringRef keys[] = {
        kCGImagePropertyGIFLoopCount,
        kCGImagePropertyAPNGLoopCount,
        kCGImagePropertyWebPLoopCount
    };

    BOOL sawLoopCount = NO;
    for (NSUInteger index = 0; index < sizeof(containers) / sizeof(containers[0]); index++) {
        id value = containers[index][(__bridge NSString *)keys[index]];
        if (!value) continue;
        sawLoopCount = YES;
        if (![value isKindOfClass:NSNumber.class]) continue;
        double count = [value doubleValue];
        if (isfinite(count) && count >= 0.0 && count <= UINT16_MAX && floor(count) == count) return value;
    }

    if (sawLoopCount && failure) *failure = RUINGIFEncoderErrorInvalidLoopCount;
    return nil;
}

static BOOL RUINGIFEncoderDelayTicks(NSNumber *delay, uint64_t *ticks)
{
    if (![delay isKindOfClass:NSNumber.class]) return NO;
    double value = delay.doubleValue * 100.0;
    if (!isfinite(value) || value < 0.0 || value > UINT16_MAX || fabs(value - round(value)) > 0.000001)
        return NO;
    if (ticks) *ticks = (uint64_t)llround(value);
    return YES;
}

static BOOL RUINGIFEncoderQuantizedDelayTicks(NSNumber *delay, double *cumulativeCentiseconds,
                                              uint64_t *previousBoundaryTicks,
                                              uint64_t maximumTotalTicks, uint64_t *ticks)
{
    if (![delay isKindOfClass:NSNumber.class]) return NO;
    double frameCentiseconds = delay.doubleValue * 100.0;
    if (!isfinite(frameCentiseconds) || frameCentiseconds < 0.0) return NO;

    double cumulative = *cumulativeCentiseconds + frameCentiseconds;
    if (!isfinite(cumulative) || cumulative > (double)maximumTotalTicks + 0.5) return NO;
    // ImageIO may report rational APNG delays a few ulps below an exact half-tick.
    double roundedBoundary = floor(cumulative + 0.500001);
    if (roundedBoundary > (double)maximumTotalTicks) return NO;

    uint64_t boundaryTicks = (uint64_t)roundedBoundary;
    if (boundaryTicks < *previousBoundaryTicks) return NO;
    uint64_t frameTicks = boundaryTicks - *previousBoundaryTicks;
    if (frameTicks > UINT16_MAX) return NO;

    *cumulativeCentiseconds = cumulative;
    *previousBoundaryTicks = boundaryTicks;
    if (ticks) *ticks = frameTicks;
    return YES;
}

static NSData *RUINGIFEncoderFramePixels(CGImageRef frame, size_t width, size_t height)
{
    if (!frame || CGImageGetWidth(frame) != width || CGImageGetHeight(frame) != height) return nil;
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!colorSpace) return nil;
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4,
        colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) return nil;
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), frame);
    CGContextRelease(context);
    return pixels;
}

static NSData *RUINGIFEncoderReadBoundedLocalFile(NSURL *URL, NSError **error)
{
    NSError *readError = nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:URL error:&readError];
    if (!handle) {
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorLocalFileRead, @"The local image file could not be read.");
        return nil;
    }

    NSMutableData *data = [NSMutableData data];
    BOOL failed = NO;
    BOOL tooLarge = NO;
    for (;;) {
        uint64_t remaining = RUINGIFEncoderMaximumInputBytes + 1ULL - data.length;
        NSUInteger requestLength = (NSUInteger)MIN(64ULL * 1024ULL, remaining);
        NSData *chunk = [handle readDataUpToLength:requestLength error:&readError];
        if (!chunk) {
            failed = YES;
            break;
        }
        if (chunk.length == 0) break;
        if (chunk.length > RUINGIFEncoderMaximumInputBytes - data.length) {
            tooLarge = YES;
            break;
        }
        [data appendData:chunk];
    }
    [handle closeAndReturnError:nil];

    if (tooLarge) {
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorInputTooLarge, @"The local image exceeds the size limit.");
        return nil;
    }
    if (failed || data.length == 0) {
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorLocalFileRead, @"The local image file could not be read.");
        return nil;
    }
    return [data copy];
}

NSData *RUINGIFEncoderCreateGIFDataFromLocalFileURL(NSURL *URL,
                                                     NSUInteger *encodedFrameCount,
                                                     NSError **error)
{
    if (error) *error = nil;
    if (encodedFrameCount) *encodedFrameCount = 0;
    if (![URL isKindOfClass:NSURL.class] || !URL.isFileURL || !URL.path.length) {
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorInvalidLocalFile, @"A local image file is required.");
        return nil;
    }

    NSError *attributesError = nil;
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [NSFileManager.defaultManager attributesOfItemAtPath:URL.path error:&attributesError];
    NSNumber *sizeValue = attributes[NSFileSize];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || ![sizeValue isKindOfClass:NSNumber.class] ||
        sizeValue.unsignedLongLongValue == 0) {
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorInvalidLocalFile, @"The local image file is unavailable.");
        return nil;
    }
    if (sizeValue.unsignedLongLongValue > RUINGIFEncoderMaximumInputBytes) {
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorInputTooLarge, @"The local image exceeds the size limit.");
        return nil;
    }

    NSData *inputData = RUINGIFEncoderReadBoundedLocalFile(URL, error);
    if (!inputData) return nil;

    NSDictionary *sourceOptions = @{(__bridge NSString *)kCGImageSourceShouldCache: @NO};
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)inputData,
                                                          (__bridge CFDictionaryRef)sourceOptions);
    if (!source) {
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorImageDecode, @"The local image could not be opened.");
        return nil;
    }

    size_t frameCount = CGImageSourceGetCount(source);
    if (frameCount < 2) {
        CFRelease(source);
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorNotAnimated, @"The local image is not animated.");
        return nil;
    }
    if (frameCount > RUINGIFEncoderMaximumFrameCount) {
        CFRelease(source);
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorTooManyFrames, @"The local image has too many frames.");
        return nil;
    }

    NSDictionary *sourceProperties = CFBridgingRelease(CGImageSourceCopyProperties(source,
        (__bridge CFDictionaryRef)sourceOptions)) ?: @{};
    uint64_t canvasWidth = 0, canvasHeight = 0;
    BOOL hasCanvas = RUINGIFEncoderCanvasFromMetadata(sourceProperties, &canvasWidth, &canvasHeight) ||
        RUINGIFEncoderGIFCanvasDimensions(inputData, &canvasWidth, &canvasHeight);
    if (!hasCanvas) {
        hasCanvas = RUINGIFEncoderPositiveInteger(
                sourceProperties[(__bridge NSString *)kCGImagePropertyPixelWidth], &canvasWidth) &&
            RUINGIFEncoderPositiveInteger(
                sourceProperties[(__bridge NSString *)kCGImagePropertyPixelHeight], &canvasHeight);
    }
    if (!hasCanvas) {
        CFRelease(source);
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorInvalidDimensions, @"The animation has no valid canvas dimensions.");
        return nil;
    }
    if (canvasWidth > RUINGIFEncoderMaximumDimension || canvasHeight > RUINGIFEncoderMaximumDimension) {
        CFRelease(source);
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorDimensionTooLarge, @"The animation canvas exceeds the dimension limit.");
        return nil;
    }

    uint64_t totalPixels = 0;
    RUINGIFEncoderErrorCode metadataFailure = RUINGIFEncoderErrorGIFEncoding;
    NSMutableArray<NSNumber *> *delayTicks = [NSMutableArray arrayWithCapacity:frameCount];
    double cumulativeCentiseconds = 0.0;
    uint64_t previousBoundaryTicks = 0;
    uint64_t maximumTotalTicks = (uint64_t)frameCount * UINT16_MAX;
    for (size_t index = 0; index < frameCount; index++) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(
            source, index, (__bridge CFDictionaryRef)sourceOptions));
        if (![properties isKindOfClass:NSDictionary.class]) {
            CFRelease(source);
            RUINGIFEncoderSetError(error, RUINGIFEncoderErrorInvalidDimensions, @"An image frame has no valid dimensions.");
            return nil;
        }

        uint64_t width = 0, height = 0;
        if (!RUINGIFEncoderPositiveInteger(properties[(__bridge NSString *)kCGImagePropertyPixelWidth], &width) ||
            !RUINGIFEncoderPositiveInteger(properties[(__bridge NSString *)kCGImagePropertyPixelHeight], &height)) {
            CFRelease(source);
            RUINGIFEncoderSetError(error, RUINGIFEncoderErrorInvalidDimensions, @"An image frame has no valid dimensions.");
            return nil;
        }
        if (width > RUINGIFEncoderMaximumDimension || height > RUINGIFEncoderMaximumDimension) {
            CFRelease(source);
            RUINGIFEncoderSetError(error, RUINGIFEncoderErrorDimensionTooLarge, @"An image frame exceeds the dimension limit.");
            return nil;
        }
        uint64_t decodedWidth = width > canvasWidth ? width : canvasWidth;
        uint64_t decodedHeight = height > canvasHeight ? height : canvasHeight;
        uint64_t pixels = decodedWidth * decodedHeight;
        if (pixels > RUINGIFEncoderMaximumTotalPixels - totalPixels) {
            CFRelease(source);
            RUINGIFEncoderSetError(error, RUINGIFEncoderErrorTooManyPixels, @"The animation exceeds the total pixel limit.");
            return nil;
        }
        totalPixels += pixels;
        NSNumber *delay = RUINGIFEncoderFrameDelay(properties, &metadataFailure);
        if (!delay) {
            CFRelease(source);
            RUINGIFEncoderSetError(error, metadataFailure,
                metadataFailure == RUINGIFEncoderErrorMissingFrameTiming ?
                    @"An image frame has no timing information." : @"An image frame has invalid timing information.");
            return nil;
        }
        uint64_t ticks = 0;
        if (!RUINGIFEncoderQuantizedDelayTicks(delay, &cumulativeCentiseconds,
                &previousBoundaryTicks, maximumTotalTicks, &ticks)) {
            CFRelease(source);
            RUINGIFEncoderSetError(error, RUINGIFEncoderErrorInvalidFrameTiming,
                @"An image frame timing exceeds GIF's delay limits.");
            return nil;
        }
        [delayTicks addObject:@(ticks)];
    }

    NSNumber *loopCount = RUINGIFEncoderLoopCount(sourceProperties, &metadataFailure);
    if (!loopCount && metadataFailure == RUINGIFEncoderErrorInvalidLoopCount) {
        CFRelease(source);
        RUINGIFEncoderSetError(error, metadataFailure, @"The animation loop count is invalid.");
        return nil;
    }

    // ImageIO's GIF writer can emit an incomplete image block for a zero-difference frame.
    // Coalescing equal rendered canvases preserves the pause and avoids that writer path.
    NSMutableArray<NSNumber *> *frameIndices = [NSMutableArray arrayWithCapacity:frameCount];
    NSMutableArray<NSNumber *> *outputDelayTicks = [NSMutableArray arrayWithCapacity:frameCount];
    NSData *previousPixels = nil;
    for (size_t index = 0; index < frameCount; index++) {
        RUINGIFEncoderErrorCode frameFailure = 0;
        @autoreleasepool {
            CGImageRef frame = CGImageSourceCreateImageAtIndex(source, index, (__bridge CFDictionaryRef)sourceOptions);
            NSData *pixels = RUINGIFEncoderFramePixels(frame, (size_t)canvasWidth, (size_t)canvasHeight);
            if (frame) CGImageRelease(frame);
            if (!pixels) {
                frameFailure = RUINGIFEncoderErrorImageDecode;
            } else if ([previousPixels isEqualToData:pixels]) {
                uint64_t ticks = delayTicks[index].unsignedLongLongValue;
                uint64_t previousTicks = outputDelayTicks.lastObject.unsignedLongLongValue;
                if (ticks > UINT16_MAX - previousTicks) {
                    frameFailure = RUINGIFEncoderErrorInvalidFrameTiming;
                } else outputDelayTicks[outputDelayTicks.count - 1] = @(previousTicks + ticks);
            } else {
                [frameIndices addObject:@(index)];
                [outputDelayTicks addObject:delayTicks[index]];
                previousPixels = pixels;
            }
        }
        // The caller retains an autoreleasing NSError only after we return.
        // Create it after the per-frame pool drains, so it remains alive.
        if (frameFailure) {
            CFRelease(source);
            RUINGIFEncoderSetError(error, frameFailure,
                frameFailure == RUINGIFEncoderErrorImageDecode
                    ? @"An animation canvas could not be decoded."
                    : @"An unchanged image pause exceeds GIF's 16-bit timing limit.");
            return nil;
        }
    }
    previousPixels = nil;

    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)data, CFSTR("com.compuserve.gif"), frameIndices.count, NULL);
    if (!destination) {
        CFRelease(source);
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorGIFEncoding, @"An animated GIF destination is unavailable.");
        return nil;
    }

    if (loopCount) {
        CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)@{
            (__bridge NSString *)kCGImagePropertyGIFDictionary: @{
                (__bridge NSString *)kCGImagePropertyGIFLoopCount: loopCount
            }
        });
    }
    for (NSUInteger index = 0; index < frameIndices.count; index++) {
        NSNumber *delay = @(outputDelayTicks[index].unsignedLongLongValue / 100.0);
        CGImageRef frame = CGImageSourceCreateImageAtIndex(source, frameIndices[index].unsignedIntegerValue,
            (__bridge CFDictionaryRef)sourceOptions);
        if (!frame) {
            CFRelease(destination); CFRelease(source);
            RUINGIFEncoderSetError(error, RUINGIFEncoderErrorImageDecode, @"An animation frame could not be decoded.");
            return nil;
        }
        CGImageDestinationAddImage(destination, frame, (__bridge CFDictionaryRef)@{
            (__bridge NSString *)kCGImagePropertyGIFDictionary: @{
                (__bridge NSString *)kCGImagePropertyGIFDelayTime: delay,
                (__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime: delay
            }
        });
        CGImageRelease(frame);
    }

    BOOL finalized = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CFRelease(source);
    if (!finalized) {
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorGIFEncoding, @"The animated GIF could not be encoded.");
        return nil;
    }
    CGImageSourceRef encoded = CGImageSourceCreateWithData((__bridge CFDataRef)data,
        (__bridge CFDictionaryRef)sourceOptions);
    size_t actualFrameCount = encoded ? CGImageSourceGetCount(encoded) : 0;
    BOOL outputMatches = encoded && actualFrameCount == frameIndices.count &&
        CGImageSourceGetStatus(encoded) == kCGImageStatusComplete;
    NSDictionary *encodedProperties = encoded ?
        CFBridgingRelease(CGImageSourceCopyProperties(encoded, NULL)) : @{};
    RUINGIFEncoderErrorCode outputMetadataFailure = RUINGIFEncoderErrorGIFEncoding;
    NSNumber *encodedLoopCount = RUINGIFEncoderLoopCount(encodedProperties ?: @{}, &outputMetadataFailure);
    outputMatches = outputMatches && outputMetadataFailure != RUINGIFEncoderErrorInvalidLoopCount &&
        (loopCount ? (encodedLoopCount && [loopCount isEqualToNumber:encodedLoopCount]) : encodedLoopCount == nil);
    for (size_t index = 0; outputMatches && index < actualFrameCount; index++) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(encoded, index, NULL));
        NSNumber *delay = RUINGIFEncoderFrameDelay(properties ?: @{}, &metadataFailure);
        uint64_t ticks = 0;
        outputMatches = RUINGIFEncoderDelayTicks(delay, &ticks) && ticks == outputDelayTicks[index].unsignedLongLongValue;
    }
    if (encoded) CFRelease(encoded);
    if (!outputMatches) {
        RUINGIFEncoderSetError(error, RUINGIFEncoderErrorGIFEncoding,
            @"The encoded GIF did not preserve its frames, timing, or loop count.");
        return nil;
    }
    if (encodedFrameCount) *encodedFrameCount = actualFrameCount;
    return [data copy];
}
