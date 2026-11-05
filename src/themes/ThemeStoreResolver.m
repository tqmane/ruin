#import "ThemeStoreResolver.h"

#import "ThemeVersion.h"

#include <limits.h>

NSString * const RUINThemeStoreResolverErrorDomain = @"RUINThemeStoreResolverErrorDomain";

static const NSUInteger RUINThemeStoreResolverMaximumHTMLBytes = 1024 * 1024;

static NSError *RUINThemeStoreResolverError(RUINThemeStoreResolverErrorCode code, NSString *message)
{
    return [NSError errorWithDomain:RUINThemeStoreResolverErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static BOOL RUINIsASCIIHexDigit(unichar character)
{
    return (character >= '0' && character <= '9') ||
        (character >= 'a' && character <= 'f') ||
        (character >= 'A' && character <= 'F');
}

static BOOL RUINIsUUID(NSString *value)
{
    if (value.length != 36) return NO;
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (character != '-') return NO;
        } else if (!RUINIsASCIIHexDigit(character)) {
            return NO;
        }
    }
    return YES;
}

static BOOL RUINIsSimpleLocale(NSString *locale)
{
    NSArray<NSString *> *parts = [locale componentsSeparatedByString:@"-"];
    if (parts.count == 0 || parts.count > 2) return NO;
    NSString *language = parts[0];
    if (language.length == 0 || language.length > 3) return NO;
    for (NSUInteger index = 0; index < language.length; index++) {
        unichar character = [language characterAtIndex:index];
        if (!((character >= 'a' && character <= 'z') ||
              (character >= 'A' && character <= 'Z'))) return NO;
    }
    if (parts.count == 1) return YES;

    NSString *region = parts[1];
    if (region.length < 2 || region.length > 8) return NO;
    for (NSUInteger index = 0; index < region.length; index++) {
        unichar character = [region characterAtIndex:index];
        if (!((character >= 'a' && character <= 'z') ||
              (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9'))) return NO;
    }
    return YES;
}

static BOOL RUINIsAllowedStoreOrigin(NSURL *URL)
{
    if (!URL) return NO;
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    return components && components.scheme && components.host &&
        [components.scheme caseInsensitiveCompare:@"https"] == NSOrderedSame &&
        [components.host caseInsensitiveCompare:@"store.line.me"] == NSOrderedSame &&
        components.user == nil && components.password == nil &&
        (components.port == nil || components.port.integerValue == 443);
}

NSURL * _Nullable RUINValidatedThemeStoreURL(NSString * _Nullable URLText)
{
    if (!URLText || URLText.length > 2048) return nil;
    NSString *trimmed = [URLText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    if (!components || !components.scheme || !components.host ||
        [components.scheme caseInsensitiveCompare:@"https"] != NSOrderedSame ||
        [components.host caseInsensitiveCompare:@"store.line.me"] != NSOrderedSame ||
        components.user != nil || components.password != nil ||
        (components.port != nil && components.port.integerValue != 443) ||
        components.query != nil || components.fragment != nil) return nil;

    NSArray<NSString *> *path = [components.percentEncodedPath componentsSeparatedByString:@"/"];
    if (path.count != 5 || ![path[1] isEqualToString:@"themeshop"] ||
        ![path[2] isEqualToString:@"product"] ||
        !RUINIsUUID(path[3]) || !RUINIsSimpleLocale(path[4])) return nil;
    return components.URL;
}

static NSArray<NSTextCheckingResult *> *RUINRegexMatches(NSString *pattern, NSString *text)
{
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                            options:NSRegularExpressionCaseInsensitive
                                                                              error:nil];
    return regex ? [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)] : @[];
}

static NSDictionary<NSString *, NSString *> * _Nullable RUINHTMLAttributes(NSString *tag)
{
    NSMutableDictionary<NSString *, NSString *> *attributes = [NSMutableDictionary dictionary];
    for (NSTextCheckingResult *match in RUINRegexMatches(
            @"([A-Za-z_:][A-Za-z0-9_.:-]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", tag)) {
        NSString *name = [[tag substringWithRange:[match rangeAtIndex:1]] lowercaseString];
        if (attributes[name]) return nil;
        NSUInteger valueGroup = NSNotFound;
        for (NSUInteger group = 2; group <= 4; group++) {
            if ([match rangeAtIndex:group].location != NSNotFound) {
                valueGroup = group;
                break;
            }
        }
        if (valueGroup != NSNotFound)
            attributes[name] = [tag substringWithRange:[match rangeAtIndex:valueGroup]];
    }
    return attributes;
}

static NSArray<NSString *> *RUINMetaValues(NSString *HTML, NSString *keyName, NSString *keyValue)
{
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (NSTextCheckingResult *match in RUINRegexMatches(@"<meta\\b[^>]*>", HTML)) {
        NSString *tag = [HTML substringWithRange:match.range];
        NSDictionary<NSString *, NSString *> *attributes = RUINHTMLAttributes(tag);
        NSString *attributeValue = attributes[keyName];
        if (!attributeValue || [attributeValue caseInsensitiveCompare:keyValue] != NSOrderedSame) continue;
        NSString *content = attributes[@"content"];
        if (content) [values addObject:content];
    }
    return values;
}

static BOOL RUINParseEntityNumber(NSString *digits, unsigned int base, unsigned int *result)
{
    if (digits.length == 0) return NO;
    unsigned int value = 0;
    for (NSUInteger index = 0; index < digits.length; index++) {
        unichar character = [digits characterAtIndex:index];
        unsigned int digit;
        if (character >= '0' && character <= '9') digit = character - '0';
        else if (base == 16 && character >= 'a' && character <= 'f') digit = character - 'a' + 10;
        else if (base == 16 && character >= 'A' && character <= 'F') digit = character - 'A' + 10;
        else return NO;
        if (digit >= base || value > (0x10FFFFU - digit) / base) return NO;
        value = value * base + digit;
    }
    if (value == 0 || (value >= 0xD800 && value <= 0xDFFF)) return NO;
    *result = value;
    return YES;
}

static void RUINAppendUnicodeScalar(NSMutableString *output, unsigned int scalar)
{
    if (scalar <= 0xFFFF) {
        unichar character = (unichar)scalar;
        [output appendString:[NSString stringWithCharacters:&character length:1]];
        return;
    }
    scalar -= 0x10000;
    unichar pair[2] = {
        (unichar)(0xD800 + (scalar >> 10)),
        (unichar)(0xDC00 + (scalar & 0x3FF))
    };
    [output appendString:[NSString stringWithCharacters:pair length:2]];
}

// Decode common named and numeric entities once; an escaped ampersand is not rescanned.
static NSString * _Nullable RUINDecodeHTMLEntities(NSString *input)
{
    NSDictionary<NSString *, NSNumber *> *named = @{
        @"amp": @0x26, @"quot": @0x22, @"apos": @0x27, @"lt": @0x3C, @"gt": @0x3E,
        @"nbsp": @0xA0, @"copy": @0xA9, @"reg": @0xAE, @"ndash": @0x2013,
        @"mdash": @0x2014, @"hellip": @0x2026
    };
    NSMutableString *output = [NSMutableString stringWithCapacity:input.length];
    NSUInteger index = 0;
    while (index < input.length) {
        if ([input characterAtIndex:index] != '&') {
            [output appendFormat:@"%C", [input characterAtIndex:index++]];
            continue;
        }
        NSRange semicolon = [input rangeOfString:@";" options:0
            range:NSMakeRange(index + 1, input.length - index - 1)];
        if (semicolon.location == NSNotFound || semicolon.location - index > 16) {
            [output appendString:@"&"];
            index++;
            continue;
        }
        NSString *entity = [input substringWithRange:NSMakeRange(index + 1, semicolon.location - index - 1)];
        NSNumber *namedScalar = named[entity];
        unsigned int scalar = namedScalar ? namedScalar.unsignedIntValue : 0;
        BOOL recognized = namedScalar != nil;
        if (!recognized && [entity hasPrefix:@"#"]) {
            BOOL hexadecimal = entity.length > 2 &&
                ([entity characterAtIndex:1] == 'x' || [entity characterAtIndex:1] == 'X');
            NSString *digits = [entity substringFromIndex:hexadecimal ? 2 : 1];
            recognized = RUINParseEntityNumber(digits, hexadecimal ? 16 : 10, &scalar);
            if (!recognized) return nil;
        }
        if (recognized) RUINAppendUnicodeScalar(output, scalar);
        else [output appendString:[input substringWithRange:NSMakeRange(index, NSMaxRange(semicolon) - index)]];
        index = NSMaxRange(semicolon);
    }
    return output;
}

static NSString * _Nullable RUINParagraphText(NSString *HTML, NSString *attribute, NSString *value,
                                               NSUInteger startAt, NSUInteger *endAt)
{
    for (NSTextCheckingResult *match in RUINRegexMatches(@"<p\\b[^>]*>", HTML)) {
        if (match.range.location < startAt) continue;
        NSString *tag = [HTML substringWithRange:match.range];
        NSDictionary<NSString *, NSString *> *attributes = RUINHTMLAttributes(tag);
        if (![[attributes[attribute] lowercaseString] isEqualToString:[value lowercaseString]]) continue;
        NSUInteger bodyStart = NSMaxRange(match.range);
        NSRange closing = [HTML rangeOfString:@"</p>" options:NSCaseInsensitiveSearch
            range:NSMakeRange(bodyStart, HTML.length - bodyStart)];
        if (closing.location == NSNotFound) return nil;
        if (endAt) *endAt = NSMaxRange(closing);
        NSString *body = [HTML substringWithRange:NSMakeRange(bodyStart, closing.location - bodyStart)];
        if ([body rangeOfString:@"<"].location != NSNotFound) return nil;
        return RUINDecodeHTMLEntities(body);
    }
    return nil;
}

static NSString * _Nullable RUINMainProductTitle(NSString *HTML, NSUInteger *endAt)
{
    return RUINParagraphText(HTML, @"data-test", @"theme-name-title", 0, endAt);
}

static NSString * _Nullable RUINMainDisplayVersion(NSString *HTML, NSUInteger startAt)
{
    for (NSTextCheckingResult *match in RUINRegexMatches(@"<p\\b[^>]*>", HTML)) {
        if (match.range.location < startAt) continue;
        NSString *tag = [HTML substringWithRange:match.range];
        NSDictionary<NSString *, NSString *> *attributes = RUINHTMLAttributes(tag);
        NSString *classNames = attributes[@"class"];
        if (!classNames) continue;
        BOOL isVersion = NO;
        for (NSString *className in [classNames componentsSeparatedByCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
            if ([className isEqualToString:@"mdCMN38Period"]) {
                isVersion = YES;
                break;
            }
        }
        if (!isVersion) continue;

        NSUInteger bodyStart = NSMaxRange(match.range);
        NSRange closing = [HTML rangeOfString:@"</p>" options:NSCaseInsensitiveSearch
            range:NSMakeRange(bodyStart, HTML.length - bodyStart)];
        if (closing.location == NSNotFound) return nil;
        NSString *body = [HTML substringWithRange:NSMakeRange(bodyStart, closing.location - bodyStart)];
        NSString *decoded = RUINDecodeHTMLEntities(body);
        if (!decoded || [body rangeOfString:@"<"].location != NSNotFound) return nil;
        NSRange slash = [decoded rangeOfString:@"/"];
        NSString *version = slash.location == NSNotFound ? decoded :
            [decoded substringToIndex:slash.location];
        return [version stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return nil;
}

static NSString * _Nullable RUINThemeNameFromOGTitle(NSString *title)
{
    NSRange suffix = [title rangeOfString:@" - LINE " options:NSBackwardsSearch];
    if (suffix.location == NSNotFound || NSMaxRange(suffix) >= title.length) return nil;
    NSString *name = [[title substringToIndex:suffix.location]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return name.length > 0 ? name : nil;
}

static NSString * _Nullable RUINRawVersionFromImageURL(NSString *imageURL, NSString *expectedProductID)
{
    NSURLComponents *components = [NSURLComponents componentsWithString:imageURL];
    if (!components || !components.scheme || !components.host ||
        [components.scheme caseInsensitiveCompare:@"https"] != NSOrderedSame ||
        [components.host caseInsensitiveCompare:@"shop.line-scdn.net"] != NSOrderedSame ||
        components.user != nil || components.password != nil ||
        (components.port != nil && components.port.integerValue != 443) ||
        components.query != nil || components.fragment != nil) return nil;

    NSArray<NSString *> *parts = [components.percentEncodedPath componentsSeparatedByString:@"/"];
    if (parts.count != 11 || ![parts[1] isEqualToString:@"themeshop"] ||
        ![parts[2] isEqualToString:@"v1"] || ![parts[3] isEqualToString:@"products"] ||
        !RUINIsUUID(parts[7]) || [parts[7] caseInsensitiveCompare:expectedProductID] != NSOrderedSame ||
        [parts[4] caseInsensitiveCompare:[expectedProductID substringToIndex:2]] != NSOrderedSame ||
        [parts[5] caseInsensitiveCompare:[[expectedProductID substringFromIndex:2] substringToIndex:2]] != NSOrderedSame ||
        [parts[6] caseInsensitiveCompare:[[expectedProductID substringFromIndex:4] substringToIndex:2]] != NSOrderedSame ||
        ![parts[9] isEqualToString:@"WEBSTORE"] ||
        ![parts[10] hasPrefix:@"icon_"] || parts[10].length <= 5) return nil;

    for (NSUInteger index = 5; index < parts[10].length; index++) {
        unichar character = [parts[10] characterAtIndex:index];
        if (!((character >= 'a' && character <= 'z') ||
              (character >= 'A' && character <= 'Z') ||
              (character >= '0' && character <= '9') ||
              character == '_' || character == '.' || character == '-')) return nil;
    }
    NSString *version = parts[8];
    return [RUINThemeDownloadVersion(version) isEqual:version] ? version : nil;
}

NSDictionary<NSString *, NSString *> * _Nullable
RUINParseThemeStoreHTML(NSData * _Nullable HTMLData, NSString * _Nullable expectedProductID)
{
    if (!HTMLData || HTMLData.length == 0 ||
        HTMLData.length > RUINThemeStoreResolverMaximumHTMLBytes ||
        !expectedProductID || !RUINIsUUID(expectedProductID)) return nil;

    NSString *HTML = [[NSString alloc] initWithData:HTMLData encoding:NSUTF8StringEncoding];
    if (!HTML) return nil;
    NSArray<NSString *> *titles = RUINMetaValues(HTML, @"property", @"og:title");
    NSArray<NSString *> *images = RUINMetaValues(HTML, @"property", @"og:image");
    if (titles.count != 1 || images.count != 1) return nil;

    NSString *decodedTitle = RUINDecodeHTMLEntities(titles[0]);
    NSString *name = decodedTitle ? RUINThemeNameFromOGTitle(decodedTitle) : nil;
    NSString *rawVersion = RUINRawVersionFromImageURL(
        RUINDecodeHTMLEntities(images[0]) ?: @"", expectedProductID.lowercaseString);
    if (!name.length || name.length > 256 ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        !rawVersion) return nil;

    NSUInteger titleEnd = 0;
    NSString *mainTitle = RUINMainProductTitle(HTML, &titleEnd);
    if (!mainTitle || ![mainTitle isEqualToString:name]) return nil;

    NSString *displayVersion = RUINMainDisplayVersion(HTML, titleEnd);
    NSString *mappedDisplayVersion = displayVersion ? RUINThemeDownloadVersion(displayVersion) : nil;
    if (mappedDisplayVersion && ![mappedDisplayVersion isEqualToString:rawVersion]) return nil;

    NSMutableDictionary<NSString *, NSString *> *result = [@{
        @"name": name,
        @"productID": expectedProductID.lowercaseString,
        @"version": rawVersion
    } mutableCopy];
    if (mappedDisplayVersion) result[@"displayVersion"] = displayVersion;
    return [result copy];
}

@interface RUINThemeStoreFetch : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, copy) NSString *productID;
@property (nonatomic, copy) RUINThemeStoreResolverCompletion completion;
@property (nonatomic, strong) NSMutableData *body;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSError *failure;
@property (nonatomic) BOOL finished;
- (void)startWithURL:(NSURL *)URL;
@end

@implementation RUINThemeStoreFetch

- (void)startWithURL:(NSURL *)URL
{
    self.body = [NSMutableData data];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.HTTPCookieStorage = nil;
    configuration.URLCredentialStorage = nil;
    configuration.HTTPShouldSetCookies = NO;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 60;

    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    request.HTTPMethod = @"GET";
    request.HTTPShouldHandleCookies = NO;
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
}

- (void)finishWithTheme:(NSDictionary<NSString *, NSString *> *)theme error:(NSError *)error
{
    if (self.finished) return;
    self.finished = YES;
    RUINThemeStoreResolverCompletion completion = self.completion;
    self.completion = nil;
    NSURLSession *session = self.session;
    self.task = nil;
    self.session = nil;
    [session finishTasksAndInvalidate];
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(theme, error);
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler
{
    (void)session;
    (void)task;
    if (!RUINIsAllowedStoreOrigin(request.URL)) {
        self.failure = RUINThemeStoreResolverError(RUINThemeStoreResolverBadResponse,
            @"The theme page redirected to an unsupported address.");
        completionHandler(nil);
        return;
    }
    NSMutableURLRequest *safeRequest = [request mutableCopy];
    [safeRequest setValue:nil forHTTPHeaderField:@"Cookie"];
    [safeRequest setValue:nil forHTTPHeaderField:@"Authorization"];
    [safeRequest setValue:nil forHTTPHeaderField:@"Proxy-Authorization"];
    safeRequest.HTTPShouldHandleCookies = NO;
    completionHandler(safeRequest);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
    completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    (void)session;
    if (![response isKindOfClass:NSHTTPURLResponse.class] ||
        ((NSHTTPURLResponse *)response).statusCode != 200 ||
        !RUINIsAllowedStoreOrigin(response.URL)) {
        self.failure = RUINThemeStoreResolverError(RUINThemeStoreResolverBadResponse,
            @"LINE Store returned an invalid response.");
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    if (response.expectedContentLength > (int64_t)RUINThemeStoreResolverMaximumHTMLBytes) {
        self.failure = RUINThemeStoreResolverError(RUINThemeStoreResolverResponseTooLarge,
            @"The theme page exceeds the 1 MiB size limit.");
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    [self.body setLength:0];
    completionHandler(NSURLSessionResponseAllow);
    (void)dataTask;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    (void)session;
    if (data.length > RUINThemeStoreResolverMaximumHTMLBytes - self.body.length) {
        self.failure = RUINThemeStoreResolverError(RUINThemeStoreResolverResponseTooLarge,
            @"The theme page exceeds the 1 MiB size limit.");
        [dataTask cancel];
        return;
    }
    [self.body appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    (void)session;
    (void)task;
    NSError *failure = self.failure;
    if (!failure && error)
        failure = RUINThemeStoreResolverError(RUINThemeStoreResolverNetworkError,
            @"The theme page could not be downloaded.");
    NSDictionary<NSString *, NSString *> *theme = nil;
    if (!failure) {
        theme = RUINParseThemeStoreHTML(self.body, self.productID);
        if (!theme)
            failure = RUINThemeStoreResolverError(RUINThemeStoreResolverInvalidHTML,
                @"The theme page did not contain valid product details.");
    }
    [self finishWithTheme:theme error:failure];
}

@end

void RUINResolveThemeStoreURL(NSString * _Nullable URLText, RUINThemeStoreResolverCompletion completion)
{
    NSURL *URL = RUINValidatedThemeStoreURL(URLText);
    if (!URL) {
        NSError *error = RUINThemeStoreResolverError(RUINThemeStoreResolverInvalidURL,
            @"Enter a valid LINE Store theme URL.");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, error);
        });
        return;
    }
    NSArray<NSString *> *path = [URL.path componentsSeparatedByString:@"/"];
    RUINThemeStoreFetch *fetch = [RUINThemeStoreFetch new];
    fetch.productID = path[3].lowercaseString;
    fetch.completion = completion;
    [fetch startWithURL:URL];
}
