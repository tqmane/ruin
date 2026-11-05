// Host check:
// xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror -I. src/messaging/GIFEncoder.m tests/check_gif.m -framework Foundation -framework ImageIO -framework CoreGraphics -o /tmp/check_gif && /tmp/check_gif
// Optional owned local asset regression: /tmp/check_gif build/gif-fixture-52002734.png

#import "GIFEncoder.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <fcntl.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

static void Check(BOOL condition, const char *message)
{
    if (condition) return;
    fprintf(stderr, "GIFEncoder check failed: %s\n", message);
    exit(1);
}

static NSURL *TemporaryURL(NSString *name)
{
    NSString *fileName = [NSString stringWithFormat:@"%@-%@.gif", name, NSUUID.UUID.UUIDString];
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
}

static void ReleasePixelData(void *info, const void *data, size_t size)
{
    (void)info;
    (void)size;
    free((void *)data);
}

static CGImageRef SolidImage(size_t width, size_t height, uint8_t red, uint8_t green, uint8_t blue)
{
    size_t byteCount = width * height * 4;
    uint8_t *pixels = calloc(1, byteCount);
    if (!pixels) return NULL;
    for (size_t index = 0; index < byteCount; index += 4) {
        pixels[index] = red;
        pixels[index + 1] = green;
        pixels[index + 2] = blue;
        pixels[index + 3] = 255;
    }

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, byteCount, ReleasePixelData);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = provider ? CGImageCreate(width, height, 8, 32, width * 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, provider, NULL, false,
        kCGRenderingIntentDefault) : NULL;
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    if (provider) CGDataProviderRelease(provider);
    if (!provider) free(pixels);
    return image;
}

static BOOL CreateGIF(NSURL *URL, size_t width, size_t height, NSUInteger frameCount,
                      BOOL includeTiming, BOOL distinctFrames, NSNumber * _Nullable loopCount)
{
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)URL, CFSTR("com.compuserve.gif"), frameCount, NULL);
    if (!destination) return NO;
    if (loopCount) {
        CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)@{
            (__bridge NSString *)kCGImagePropertyGIFDictionary: @{
                (__bridge NSString *)kCGImagePropertyGIFLoopCount: loopCount
            }
        });
    }

    CGImageRef first = SolidImage(width, height, 255, 0, 0);
    CGImageRef second = distinctFrames ? SolidImage(width, height, 0, 0, 255) : first;
    if (!first || !second) {
        if (first) CGImageRelease(first);
        if (distinctFrames && second) CGImageRelease(second);
        CFRelease(destination);
        return NO;
    }

    for (NSUInteger index = 0; index < frameCount; index++) {
        CGImageRef image = distinctFrames && index % 2 ? second : first;
        if (includeTiming) {
            NSNumber *delay = index % 2 ? @0.24 : @0.12;
            CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{
                (__bridge NSString *)kCGImagePropertyGIFDictionary: @{
                    (__bridge NSString *)kCGImagePropertyGIFDelayTime: delay,
                    (__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime: delay
                }
            });
        } else {
            CGImageDestinationAddImage(destination, image, NULL);
        }
    }

    BOOL finalized = CGImageDestinationFinalize(destination);
    CGImageRelease(first);
    if (distinctFrames) CGImageRelease(second);
    CFRelease(destination);
    return finalized;
}

static BOOL CreateAPNG(NSURL *URL, NSArray<NSNumber *> *colors, NSArray<NSNumber *> *delays)
{
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)URL,
        CFSTR("public.png"), colors.count, NULL);
    if (!destination) return NO;
    CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCGImagePropertyPNGDictionary: @{(__bridge NSString *)kCGImagePropertyAPNGLoopCount: @3}});
    for (NSUInteger index = 0; index < colors.count; index++) {
        NSUInteger color = colors[index].unsignedIntegerValue;
        CGImageRef image = SolidImage(3, 2, color == 0 ? 255 : 0, color == 1 ? 255 : 0, color == 2 ? 255 : 0);
        if (!image) { CFRelease(destination); return NO; }
        CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{
            (__bridge NSString *)kCGImagePropertyPNGDictionary: @{
                (__bridge NSString *)kCGImagePropertyAPNGDelayTime: delays[index],
                (__bridge NSString *)kCGImagePropertyAPNGUnclampedDelayTime: delays[index]
            }});
        CGImageRelease(image);
    }
    BOOL done = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return done;
}

static uint32_t PNGCRC32(const uint8_t *bytes, size_t length)
{
    uint32_t crc = UINT32_MAX;
    for (size_t index = 0; index < length; index++) {
        crc ^= bytes[index];
        for (NSUInteger bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (0xedb88320U & (0U - (crc & 1U)));
    }
    return ~crc;
}

static void PNGWriteBigEndian16(uint8_t *bytes, uint16_t value)
{
    bytes[0] = (uint8_t)(value >> 8);
    bytes[1] = (uint8_t)value;
}

static void PNGWriteBigEndian32(uint8_t *bytes, uint32_t value)
{
    bytes[0] = (uint8_t)(value >> 24);
    bytes[1] = (uint8_t)(value >> 16);
    bytes[2] = (uint8_t)(value >> 8);
    bytes[3] = (uint8_t)value;
}

static BOOL SetAPNGFrameDelays(NSURL *URL, const uint16_t *numerators,
                               const uint16_t *denominators, NSUInteger expectedFrameCount)
{
    static const uint8_t signature[] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    NSData *file = [NSData dataWithContentsOfURL:URL];
    if (file.length < sizeof(signature) || memcmp(file.bytes, signature, sizeof(signature)) != 0) return NO;

    NSMutableData *patched = [file mutableCopy];
    uint8_t *bytes = patched.mutableBytes;
    NSUInteger offset = sizeof(signature), frameCount = 0;
    while (offset <= patched.length && patched.length - offset >= 12) {
        uint32_t chunkLength = ((uint32_t)bytes[offset] << 24) | ((uint32_t)bytes[offset + 1] << 16) |
            ((uint32_t)bytes[offset + 2] << 8) | (uint32_t)bytes[offset + 3];
        if (chunkLength > patched.length - offset - 12) return NO;
        uint8_t *type = bytes + offset + 4;
        uint8_t *data = bytes + offset + 8;
        if (memcmp(type, "fcTL", 4) == 0) {
            if (chunkLength != 26 || frameCount >= expectedFrameCount || denominators[frameCount] == 0) return NO;
            PNGWriteBigEndian16(data + 20, numerators[frameCount]);
            PNGWriteBigEndian16(data + 22, denominators[frameCount]);
            PNGWriteBigEndian32(bytes + offset + 8 + chunkLength, PNGCRC32(type, 4 + chunkLength));
            frameCount++;
        }
        offset += (NSUInteger)chunkLength + 12;
        if (memcmp(type, "IEND", 4) == 0) break;
    }
    return frameCount == expectedFrameCount && [patched writeToURL:URL atomically:YES];
}

static BOOL AppendSubBlocks(NSData *source, NSMutableData *destination, NSUInteger *position)
{
    const uint8_t *bytes = source.bytes;
    while (*position < source.length) {
        uint8_t size = bytes[(*position)++];
        [destination appendBytes:&size length:1];
        if (size == 0) return YES;
        if (size > source.length - *position) return NO;
        [destination appendBytes:bytes + *position length:size];
        *position += size;
    }
    return NO;
}

static NSData *GIFWithoutFrameTimings(NSData *source, NSUInteger *imageCount)
{
    if (imageCount) *imageCount = 0;
    const uint8_t *bytes = source.bytes;
    if (source.length < 13 ||
        (memcmp(bytes, "GIF87a", 6) != 0 && memcmp(bytes, "GIF89a", 6) != 0)) return nil;
    NSMutableData *result = [NSMutableData dataWithBytes:bytes length:13];
    NSUInteger position = 13;
    NSUInteger canvasWidth = bytes[6] | ((NSUInteger)bytes[7] << 8);
    NSUInteger canvasHeight = bytes[8] | ((NSUInteger)bytes[9] << 8);
    uint8_t screenPacked = bytes[10];
    if (screenPacked & 0x80) {
        NSUInteger colorTableLength = 3U * (1U << ((screenPacked & 0x07U) + 1U));
        if (colorTableLength > source.length - position) return nil;
        [result appendBytes:bytes + position length:colorTableLength];
        position += colorTableLength;
    }

    while (position < source.length) {
        uint8_t marker = bytes[position];
        if (marker == 0x3b) {
            [result appendBytes:bytes + position length:1];
            return result;
        }
        if (marker == 0x21) {
            if (source.length - position < 2) return nil;
            uint8_t label = bytes[position + 1];
            position += 2;
            if (label == 0xf9) {
                if (source.length - position < 6 || bytes[position] != 4 || bytes[position + 5] != 0) return nil;
                position += 6;
                continue;
            }

            uint8_t introducer = 0x21;
            [result appendBytes:&introducer length:1];
            [result appendBytes:&label length:1];
            if (label == 0x01) {
                if (position >= source.length) return nil;
                uint8_t headerSize = bytes[position++];
                if (headerSize > source.length - position) return nil;
                [result appendBytes:&headerSize length:1];
                [result appendBytes:bytes + position length:headerSize];
                position += headerSize;
            }
            if (!AppendSubBlocks(source, result, &position)) return nil;
            continue;
        }
        if (marker != 0x2c || source.length - position < 10) return nil;

        NSUInteger left = bytes[position + 1] | ((NSUInteger)bytes[position + 2] << 8);
        NSUInteger top = bytes[position + 3] | ((NSUInteger)bytes[position + 4] << 8);
        NSUInteger width = bytes[position + 5] | ((NSUInteger)bytes[position + 6] << 8);
        NSUInteger height = bytes[position + 7] | ((NSUInteger)bytes[position + 8] << 8);
        if (!width || !height || left + width > canvasWidth || top + height > canvasHeight) return nil;
        uint8_t imagePacked = bytes[position + 9];
        [result appendBytes:bytes + position length:10];
        position += 10;
        if (imagePacked & 0x80) {
            NSUInteger colorTableLength = 3U * (1U << ((imagePacked & 0x07U) + 1U));
            if (colorTableLength > source.length - position) return nil;
            [result appendBytes:bytes + position length:colorTableLength];
            position += colorTableLength;
        }
        if (position >= source.length) return nil;
        uint8_t minimumCodeSize = bytes[position++];
        [result appendBytes:&minimumCodeSize length:1];
        if (position >= source.length || bytes[position] == 0) return nil;
        if (!AppendSubBlocks(source, result, &position)) return nil;
        if (imageCount) (*imageCount)++;
    }
    return nil;
}

static NSNumber *GIFDelay(NSDictionary *properties)
{
    NSDictionary *gif = properties[(__bridge NSString *)kCGImagePropertyGIFDictionary];
    return gif[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime] ?: gif[(__bridge NSString *)kCGImagePropertyGIFDelayTime];
}

static NSNumber *AnimationDelay(NSDictionary *properties)
{
    NSDictionary *png = properties[(__bridge NSString *)kCGImagePropertyPNGDictionary];
    return GIFDelay(properties) ?: png[(__bridge NSString *)kCGImagePropertyAPNGUnclampedDelayTime] ?:
        png[(__bridge NSString *)kCGImagePropertyAPNGDelayTime];
}

static NSData *DecodedPixels(CGImageRef image)
{
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4,
        colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    Check(context != NULL, "create decoded pixel comparison context");
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    return pixels;
}

static NSArray<NSDictionary *> *VisualRuns(CGImageSourceRef source)
{
    NSMutableArray<NSDictionary *> *runs = [NSMutableArray array];
    for (size_t index = 0; index < CGImageSourceGetCount(source); index++) {
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, index, NULL);
        Check(image != NULL, "decode visual timeline frame");
        NSData *pixels = DecodedPixels(image);
        CGImageRelease(image);
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
        NSNumber *delay = AnimationDelay(properties);
        Check(delay != nil, "visual timeline contains explicit timing");
        uint64_t ticks = (uint64_t)llround(delay.doubleValue * 100.0);
        NSDictionary *previous = runs.lastObject;
        if ([previous[@"pixels"] isEqual:pixels]) {
            runs[runs.count - 1] = @{@"pixels": pixels, @"ticks": @([previous[@"ticks"] unsignedLongLongValue] + ticks)};
        } else {
            [runs addObject:@{@"pixels": pixels, @"ticks": @(ticks)}];
        }
    }
    return runs;
}

static void CheckAPNGRoundtrip(NSArray<NSNumber *> *colors, NSArray<NSNumber *> *sourceDelays,
                               NSArray<NSNumber *> *expectedDelays)
{
    NSURL *URL = TemporaryURL(@"apng-to-gif");
    Check(CreateAPNG(URL, colors, sourceDelays), "create APNG with ImageIO");
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)URL, NULL);
    Check(source && CGImageSourceGetCount(source) == colors.count, "APNG retains every input frame");
    NSDictionary *global = CFBridgingRelease(CGImageSourceCopyProperties(source, NULL));
    NSDictionary *png = global[(__bridge NSString *)kCGImagePropertyPNGDictionary];
    Check(global[(__bridge NSString *)kCGImagePropertyPixelWidth] == nil &&
        [png[(__bridge NSString *)kCGImagePropertyAPNGCanvasPixelWidth] integerValue] == 3 &&
        [png[(__bridge NSString *)kCGImagePropertyAPNGCanvasPixelHeight] integerValue] == 2 &&
        [png[(__bridge NSString *)kCGImagePropertyAPNGLoopCount] integerValue] == 3,
        "APNG canvas and loop metadata use the PNG dictionary");
    for (size_t index = 0; index < colors.count; index++) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
        double actualDelay = AnimationDelay(properties).doubleValue;
        if (fabs(actualDelay - sourceDelays[index].doubleValue) >= 0.000001)
            fprintf(stderr, "APNG source delay mismatch at %zu: expected %.9f, got %.9f\n",
                index, sourceDelays[index].doubleValue, actualDelay);
        Check(fabs(actualDelay - sourceDelays[index].doubleValue) < 0.000001,
            "APNG source timing fixture is exact");
    }

    NSError *error = nil;
    NSUInteger encodedFrameCount = 0;
    NSData *GIF = RUINGIFEncoderCreateGIFDataFromLocalFileURL(URL, &encodedFrameCount, &error);
    if (!GIF) fprintf(stderr, "APNG rejection: %s\n", RUINGIFEncoderRejectionName(error.code).UTF8String);
    Check(GIF.length && !error, "APNG conversion succeeds");
    NSUInteger rawFrameCount = 0;
    Check(GIFWithoutFrameTimings(GIF, &rawFrameCount) != nil && rawFrameCount == expectedDelays.count,
        "GIF contains complete in-canvas image blocks for every output frame");
    CGImageSourceRef output = CGImageSourceCreateWithData((__bridge CFDataRef)GIF, NULL);
    Check(output && CGImageSourceGetCount(output) == expectedDelays.count &&
        encodedFrameCount == CGImageSourceGetCount(output), "report actual coalesced GIF frame count");
    NSDictionary *outputGlobal = CFBridgingRelease(CGImageSourceCopyProperties(output, NULL));
    Check([outputGlobal[(__bridge NSString *)kCGImagePropertyGIFDictionary][(__bridge NSString *)kCGImagePropertyGIFLoopCount] integerValue] == 3,
        "APNG loop count survives even an all-identical animation");
    for (size_t index = 0; index < expectedDelays.count; index++) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(output, index, NULL));
        Check(fabs(GIFDelay(properties).doubleValue - expectedDelays[index].doubleValue) < 0.000001,
            "duplicate pause durations are summed without dropping time");
    }
    Check([VisualRuns(source) isEqual:VisualRuns(output)], "APNG and GIF have identical pixels and complete pause timelines");
    CFRelease(source);
    CFRelease(output);
    [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
}

static void CheckCumulativeAPNGTiming(void)
{
    NSMutableArray<NSNumber *> *colors = [NSMutableArray arrayWithCapacity:30];
    NSMutableArray<NSNumber *> *delays = [NSMutableArray arrayWithCapacity:30];
    for (NSUInteger index = 0; index < 30; index++) {
        [colors addObject:@(index % 3)];
        [delays addObject:@(1.0 / 30.0)];
    }

    NSURL *URL = TemporaryURL(@"apng-thirty-fps");
    Check(CreateAPNG(URL, colors, delays), "create thirty-frame 30 fps APNG");
    uint16_t numerators[30], denominators[30];
    for (NSUInteger index = 0; index < 30; index++) {
        numerators[index] = 1;
        denominators[index] = 30;
    }
    Check(SetAPNGFrameDelays(URL, numerators, denominators, 30), "set exact 1/30-second APNG frame delays");
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)URL, NULL);
    Check(source && CGImageSourceGetCount(source) == 30, "30 fps APNG retains every source frame");
    double sourceDuration = 0.0;
    for (NSUInteger index = 0; index < 30; index++) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
        double delay = AnimationDelay(properties).doubleValue;
        Check(fabs(delay - 1.0 / 30.0) < 0.000001, "30 fps APNG stores exact rational frame delays");
        sourceDuration += delay;
    }
    Check(fabs(sourceDuration - 1.0) < 0.000001, "30 fps APNG source timeline totals one second");

    NSError *error = nil;
    NSUInteger encodedFrameCount = 0;
    NSData *GIF = RUINGIFEncoderCreateGIFDataFromLocalFileURL(URL, &encodedFrameCount, &error);
    Check(GIF.length && !error, "convert 30 fps APNG with cumulative timing quantization");
    CGImageSourceRef output = CGImageSourceCreateWithData((__bridge CFDataRef)GIF, NULL);
    NSUInteger rawFrameCount = 0;
    Check(output && CGImageSourceGetCount(output) == 30 && encodedFrameCount == 30 &&
        GIFWithoutFrameTimings(GIF, &rawFrameCount) != nil && rawFrameCount == 30,
        "30 fps GIF contains every complete visual frame");

    uint64_t cumulativeTicks = 0;
    for (NSUInteger index = 0; index < 30; index++) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(output, index, NULL));
        double delayCentiseconds = GIFDelay(properties).doubleValue * 100.0;
        Check(fabs(delayCentiseconds - round(delayCentiseconds)) < 0.000001,
            "30 fps output frame uses an integer GIF centisecond delay");
        cumulativeTicks += (uint64_t)llround(delayCentiseconds);
        uint64_t expectedBoundaryTicks = (uint64_t)llround((index + 1) * 100.0 / 30.0);
        if (cumulativeTicks != expectedBoundaryTicks)
            fprintf(stderr, "30 fps boundary %lu: got %llu ticks, expected %llu\n",
                (unsigned long)(index + 1), (unsigned long long)cumulativeTicks,
                (unsigned long long)expectedBoundaryTicks);
        Check(cumulativeTicks == expectedBoundaryTicks,
            "30 fps output follows nearest cumulative centisecond boundaries");
        Check(fabs(cumulativeTicks / 100.0 - (index + 1) / 30.0) <= 0.0050001,
            "30 fps cumulative timing error stays within 5 ms");
    }
    Check(cumulativeTicks == 100, "30 fps GIF completes one second without cumulative drift");

    CFRelease(source);
    CFRelease(output);
    [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
}

static void CheckAPNGMaximumGIFDelay(void)
{
    NSURL *URL = TemporaryURL(@"apng-gif-delay-limit");
    Check(CreateAPNG(URL, @[@0, @0], @[@0.12, @0.24]), "create maximum-delay APNG input");
    const uint16_t numerators[] = {400, 5107};
    const uint16_t denominators[] = {1, 20};
    Check(SetAPNGFrameDelays(URL, numerators, denominators, 2), "set exact 65,535-tick coalesced delay");

    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)URL, NULL);
    Check(source && CGImageSourceGetCount(source) == 2, "maximum-delay APNG has two source frames");
    NSError *error = nil;
    NSUInteger encodedFrameCount = 0;
    NSData *GIF = RUINGIFEncoderCreateGIFDataFromLocalFileURL(URL, &encodedFrameCount, &error);
    Check(GIF.length && !error && encodedFrameCount == 1, "coalesce a pause at GIF's 16-bit maximum");
    CGImageSourceRef output = CGImageSourceCreateWithData((__bridge CFDataRef)GIF, NULL);
    NSUInteger rawFrameCount = 0;
    Check(output && CGImageSourceGetCount(output) == 1 &&
        GIFWithoutFrameTimings(GIF, &rawFrameCount) != nil && rawFrameCount == 1,
        "maximum-delay GIF has one complete image block");
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(output, 0, NULL));
    Check(fabs(GIFDelay(properties).doubleValue - 655.35) < 0.000001,
        "maximum coalesced pause is not truncated");

    CFRelease(source);
    CFRelease(output);
    [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
}

static void CheckLocalLINEFixture(NSURL *URL)
{
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)URL, NULL);
    Check(source && CGImageSourceGetCount(source) == 20, "local LINE APNG has twenty source frames");
    NSDictionary *sourceGlobal = CFBridgingRelease(CGImageSourceCopyProperties(source, NULL));
    NSDictionary *png = sourceGlobal[(__bridge NSString *)kCGImagePropertyPNGDictionary];
    Check([png[(__bridge NSString *)kCGImagePropertyAPNGCanvasPixelWidth] integerValue] == 278 &&
        [png[(__bridge NSString *)kCGImagePropertyAPNGCanvasPixelHeight] integerValue] == 225 &&
        [png[(__bridge NSString *)kCGImagePropertyAPNGLoopCount] integerValue] == 3, "local LINE APNG canvas and loop fixture");
    for (size_t index = 0; index < 20; index++) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
        Check(fabs(AnimationDelay(properties).doubleValue - 0.05) < 0.000001, "local LINE APNG source frame timing");
    }
    // The twenty stored frames contain eleven distinct consecutive premultiplied RGBA canvases.
    // These explicit pauses total one second; dropping a duplicate without adding its time fails.
    NSArray<NSNumber *> *expectedTicks = @[@5, @10, @10, @10, @5, @10, @10, @10, @10, @10, @10];
    NSArray<NSDictionary *> *sourceRuns = VisualRuns(source);
    Check(sourceRuns.count == 11 && [[sourceRuns valueForKey:@"ticks"] isEqual:expectedTicks],
        "local LINE source has the known eleven visual runs and complete one-second timing");

    NSError *error = nil;
    NSUInteger encodedFrameCount = 0;
    NSData *GIF = RUINGIFEncoderCreateGIFDataFromLocalFileURL(URL, &encodedFrameCount, &error);
    Check(GIF.length && !error, "encode local LINE APNG");
    NSUInteger rawFrameCount = 0;
    Check(GIFWithoutFrameTimings(GIF, &rawFrameCount) != nil && rawFrameCount == expectedTicks.count,
        "local LINE GIF contains complete image blocks for every distinct source run");
    CGImageSourceRef output = CGImageSourceCreateWithData((__bridge CFDataRef)GIF, NULL);
    Check(output && CGImageSourceGetCount(output) == expectedTicks.count && encodedFrameCount == expectedTicks.count,
        "local LINE GIF reports eleven actual output frames after lossless pause coalescing");
    NSDictionary *outputGlobal = CFBridgingRelease(CGImageSourceCopyProperties(output, NULL));
    Check([outputGlobal[(__bridge NSString *)kCGImagePropertyGIFDictionary][(__bridge NSString *)kCGImagePropertyGIFLoopCount] integerValue] == 3,
        "local LINE GIF retains loop count three");
    for (size_t index = 0; index < expectedTicks.count; index++) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(output, index, NULL));
        CGImageRef image = CGImageSourceCreateImageAtIndex(output, index, NULL);
        Check(image && CGImageGetWidth(image) == 278 && CGImageGetHeight(image) == 225 &&
            fabs(GIFDelay(properties).doubleValue - expectedTicks[index].doubleValue / 100.0) < 0.000001,
            "local LINE GIF decodes every visual state at the original canvas size and accumulated pause");
        CGImageRelease(image);
    }
    // GIF palette/partial-alpha conversion changes bytes; the saturated synthetic fixtures above
    // separately assert exact pixels. Here every distinct state and its complete timing must remain.
    NSArray<NSDictionary *> *outputRuns = VisualRuns(output);
    Check(outputRuns.count == expectedTicks.count && [[outputRuns valueForKey:@"ticks"] isEqual:expectedTicks],
        "local LINE GIF retains all visual states, pause durations, and total cycle time");
    CFRelease(source);
    CFRelease(output);
}

static void CheckExpectedRejection(NSURL *URL, RUINGIFEncoderErrorCode code, const char *message)
{
    NSError *error = nil;
    NSUInteger frameCount = 99;
    NSData *data = RUINGIFEncoderCreateGIFDataFromLocalFileURL(URL, &frameCount, &error);
    Check(data == nil && error.code == code && frameCount == 0, message);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        Check(argc <= 2, "accept at most one local LINE APNG fixture path");
        if (argc == 2) {
            CheckLocalLINEFixture([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]]);
            puts("GIFEncoder local APNG fixture checks passed: 20 stored frames, 11 visual runs, 1 second, loop 3");
            return 0;
        }
        NSURL *inputURL = TemporaryURL(@"gif-roundtrip-input");
        NSURL *outputURL = TemporaryURL(@"gif-roundtrip-output");
        Check(CreateGIF(inputURL, 2, 2, 2, YES, YES, @3), "create two-frame input with ImageIO");

        NSError *error = nil;
        NSUInteger encodedFrameCount = 0;
        NSData *encoded = RUINGIFEncoderCreateGIFDataFromLocalFileURL(inputURL, &encodedFrameCount, &error);
        if (!encoded) fprintf(stderr, "two-frame rejection: %s\n",
            RUINGIFEncoderRejectionName(error.code).UTF8String);
        Check(encoded.length > 0 && encodedFrameCount == 2 && error == nil, "encode two-frame input");
        Check([encoded writeToURL:outputURL atomically:YES], "write encoded GIF");

        CGImageSourceRef result = CGImageSourceCreateWithURL((__bridge CFURLRef)outputURL, NULL);
        Check(result && CGImageSourceGetCount(result) == 2, "roundtrip frame count");
        NSDictionary *firstProperties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(result, 0, NULL));
        NSDictionary *secondProperties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(result, 1, NULL));
        double firstDelay = GIFDelay(firstProperties).doubleValue;
        double secondDelay = GIFDelay(secondProperties).doubleValue;
        NSDictionary *resultProperties = CFBridgingRelease(CGImageSourceCopyProperties(result, NULL));
        NSDictionary *gifProperties = resultProperties[(__bridge NSString *)kCGImagePropertyGIFDictionary];
        Check(fabs(firstDelay - 0.12) < 0.001 && fabs(secondDelay - 0.24) < 0.001, "preserve frame timings");
        Check([gifProperties[(__bridge NSString *)kCGImagePropertyGIFLoopCount] integerValue] == 3,
              "preserve loop count");
        CGImageRef firstFrame = CGImageSourceCreateImageAtIndex(result, 0, NULL);
        CGImageRef secondFrame = CGImageSourceCreateImageAtIndex(result, 1, NULL);
        Check(firstFrame && secondFrame && CGImageGetWidth(firstFrame) == 2 && CGImageGetHeight(secondFrame) == 2,
              "decode both roundtrip frames with ImageIO");
        CGImageRelease(firstFrame);
        CGImageRelease(secondFrame);
        CFRelease(result);

        CheckAPNGRoundtrip(@[@1, @1], @[@0.12, @0.24], @[@0.36]);
        CheckAPNGRoundtrip(@[@0, @2], @[@0.12, @0.24], @[@0.12, @0.24]);
        CheckAPNGRoundtrip(@[@0, @0, @2, @2, @0], @[@0.12, @0.24, @0.08, @0.16, @0.20],
            @[@0.36, @0.24, @0.20]);
        CheckCumulativeAPNGTiming();
        CheckAPNGMaximumGIFDelay();

        NSURL *overflowingDuplicateURL = TemporaryURL(@"apng-delay-overflow");
        Check(CreateAPNG(overflowingDuplicateURL, @[@0, @0], @[@400.0, @255.36]),
            "create identical APNG frames exceeding GIF's 16-bit delay");
        const uint16_t overflowNumerators[] = {400, 6384};
        const uint16_t overflowDenominators[] = {1, 25};
        Check(SetAPNGFrameDelays(overflowingDuplicateURL, overflowNumerators, overflowDenominators, 2),
            "set exact 65,536-tick coalesced delay");
        CheckExpectedRejection(overflowingDuplicateURL, RUINGIFEncoderErrorInvalidFrameTiming,
            "reject a coalesced pause above GIF's 16-bit delay without truncation");

        NSURL *oneFrameURL = TemporaryURL(@"gif-one-frame");
        Check(CreateGIF(oneFrameURL, 2, 2, 1, YES, NO, nil), "create one-frame input");
        CheckExpectedRejection(oneFrameURL, RUINGIFEncoderErrorNotAnimated, "reject one-frame image");

        NSData *timedSource = [NSData dataWithContentsOfURL:inputURL];
        NSData *untimedSource = GIFWithoutFrameTimings(timedSource, NULL);
        NSURL *untimedURL = TemporaryURL(@"gif-no-timing");
        Check(untimedSource && [untimedSource writeToURL:untimedURL atomically:YES], "remove frame timing blocks");
        CheckExpectedRejection(untimedURL, RUINGIFEncoderErrorMissingFrameTiming, "reject missing frame timing");

        NSURL *largeInputURL = TemporaryURL(@"gif-oversized");
        int descriptor = open(largeInputURL.fileSystemRepresentation, O_CREAT | O_RDWR, 0600);
        Check(descriptor >= 0, "create sparse oversized input");
        Check(ftruncate(descriptor, (off_t)(RUINGIFEncoderMaximumInputBytes + 1)) == 0,
              "size sparse oversized input");
        close(descriptor);
        CheckExpectedRejection(largeInputURL, RUINGIFEncoderErrorInputTooLarge, "reject oversized input before ImageIO");

        NSURL *wideInputURL = TemporaryURL(@"gif-wide-frame");
        Check(CreateGIF(wideInputURL, RUINGIFEncoderMaximumDimension + 1, 1, 2, YES, NO, @0),
              "create over-dimension input");
        CheckExpectedRejection(wideInputURL, RUINGIFEncoderErrorDimensionTooLarge, "reject oversized frame dimension");

        NSURL *pixelInputURL = TemporaryURL(@"gif-too-many-pixels");
        Check(CreateGIF(pixelInputURL, 2048, 2048, 17, YES, NO, @0), "create over-pixel-budget input");
        CheckExpectedRejection(pixelInputURL, RUINGIFEncoderErrorTooManyPixels, "reject aggregate pixel limit");

        NSURL *frameInputURL = TemporaryURL(@"gif-too-many-frames");
        Check(CreateGIF(frameInputURL, 1, 1, RUINGIFEncoderMaximumFrameCount + 1, YES, NO, @0),
              "create over-frame-budget input");
        CheckExpectedRejection(frameInputURL, RUINGIFEncoderErrorTooManyFrames, "reject frame limit");

        for (NSURL *URL in @[inputURL, outputURL, overflowingDuplicateURL, oneFrameURL, untimedURL, largeInputURL,
                             wideInputURL, pixelInputURL, frameInputURL])
            [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
        puts("GIFEncoder ImageIO checks passed");
    }
    return 0;
}
