#import "LocalFont.h"
#import <CoreText/CoreText.h>
#import <math.h>

static NSString * const RUINLocalFontDefaultsKey = @"RUINLocalFontSelection";
static NSString * const RUINLocalFontErrorDomain = @"RUINLocalFontErrorDomain";
static const unsigned long long RUINLocalFontMaximumBytes = 32ULL * 1024ULL * 1024ULL;

enum {
    RUINLocalFontErrorInvalidURL = 1,
    RUINLocalFontErrorUnsupportedType,
    RUINLocalFontErrorInvalidFile,
    RUINLocalFontErrorTooLarge,
    RUINLocalFontErrorInvalidFont,
    RUINLocalFontErrorStorage,
    RUINLocalFontErrorRegistration
};

static NSObject *sLock;
static dispatch_once_t sLockOnce;
static dispatch_once_t sInstallOnce;
static NSString *sName;
static NSURL *sURL;
static NSMutableDictionary<NSString *, NSURL *> *sRegisteredURLs;
static unsigned long long sFileSize;
static BOOL sRegistered;
static NSString *sStatus = @"not_loaded";

static NSObject *RUINLocalFontLock(void) {
    dispatch_once(&sLockOnce, ^{ sLock = [NSObject new]; });
    return sLock;
}

static BOOL RUINLocalFontFail(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:RUINLocalFontErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

static NSURL *RUINLocalFontDirectory(BOOL create, NSError **error) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
        inDomains:NSUserDomainMask].firstObject;
    if (!support) {
        RUINLocalFontFail(error, RUINLocalFontErrorStorage, @"Application Support is unavailable.");
        return nil;
    }
    NSURL *directory = [[support URLByAppendingPathComponent:@"RUIN" isDirectory:YES]
        URLByAppendingPathComponent:@"Fonts" isDirectory:YES];
    if (create && ![NSFileManager.defaultManager createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    return directory;
}

static BOOL RUINValidateLocalFont(NSURL *url, NSString **postScriptName,
                                  unsigned long long *fileSize, NSError **error) {
    if (!url.isFileURL || !url.path.length)
        return RUINLocalFontFail(error, RUINLocalFontErrorInvalidURL, @"Choose a local font file.");

    NSString *extension = url.pathExtension.lowercaseString;
    if (![extension isEqualToString:@"otf"] && ![extension isEqualToString:@"ttf"])
        return RUINLocalFontFail(error, RUINLocalFontErrorUnsupportedType, @"Only OTF and TTF fonts are supported.");

    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *attributes = [files attributesOfItemAtPath:url.path error:error];
    if (!attributes) return NO;
    NSNumber *size = attributes[NSFileSize];
    if (![attributes[NSFileType] isEqualToString:NSFileTypeRegular] ||
        ![files isReadableFileAtPath:url.path] || !size) {
        return RUINLocalFontFail(error, RUINLocalFontErrorInvalidFile,
            @"The selected font must be a readable regular file.");
    }
    unsigned long long bytes = size.unsignedLongLongValue;
    if (bytes == 0)
        return RUINLocalFontFail(error, RUINLocalFontErrorInvalidFile, @"The selected font file is empty.");
    if (bytes > RUINLocalFontMaximumBytes)
        return RUINLocalFontFail(error, RUINLocalFontErrorTooLarge, @"The font file exceeds 32 MB.");

    CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
    if (!descriptors || CFArrayGetCount(descriptors) != 1) {
        if (descriptors) CFRelease(descriptors);
        return RUINLocalFontFail(error, RUINLocalFontErrorInvalidFont,
            @"The file must contain exactly one valid font.");
    }
    CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, 0);
    CFTypeRef nameValue = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);
    BOOL validName = nameValue && CFGetTypeID(nameValue) == CFStringGetTypeID() &&
        CFStringGetLength((CFStringRef)nameValue) > 0;
    if (validName && postScriptName) *postScriptName = [(__bridge NSString *)nameValue copy];
    if (nameValue) CFRelease(nameValue);
    CFRelease(descriptors);
    if (!validName)
        return RUINLocalFontFail(error, RUINLocalFontErrorInvalidFont, @"The font has no PostScript name.");

    if (fileSize) *fileSize = bytes;
    return YES;
}

static BOOL RUINRegisterLocalFont(NSURL *url, NSError **error) {
    CFErrorRef registrationError = NULL;
    BOOL registered = CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,
        kCTFontManagerScopeProcess, &registrationError);
    if (!registered) {
        if (error && registrationError) *error = CFBridgingRelease(registrationError);
        else if (registrationError) CFRelease(registrationError);
        if (error && !*error) RUINLocalFontFail(error, RUINLocalFontErrorRegistration,
            @"Core Text could not register the font.");
    }
    return registered;
}

static NSURL *RUINStoredLocalFontURL(NSDictionary *selection, NSURL *directory) {
    NSString *filename = selection[@"filename"];
    if (![filename isKindOfClass:NSString.class] || !filename.length ||
        ![filename.lastPathComponent isEqualToString:filename] || ![filename hasPrefix:@"font-"]) return nil;
    NSURL *url = [directory URLByAppendingPathComponent:filename isDirectory:NO];
    NSString *extension = url.pathExtension.lowercaseString;
    return ([extension isEqualToString:@"otf"] || [extension isEqualToString:@"ttf"]) ? url : nil;
}

static void RUINRemoveManagedFontsExcept(NSURL *directory, NSURL * _Nullable keepURL) {
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
        includingPropertiesForKeys:nil options:0 error:nil];
    for (NSURL *url in contents) {
        // Directory enumeration can canonicalize /var to /private/var. Both
        // URLs are immediate children here, so identify the saved file by name.
        if (keepURL && [url.lastPathComponent isEqualToString:keepURL.lastPathComponent]) continue;
        NSString *name = url.lastPathComponent;
        if ([name hasPrefix:@"font-"] || [name hasPrefix:@".staging-"])
            [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    }
}

void RUINInstallLocalFont(void) {
    dispatch_once(&sInstallOnce, ^{
        @synchronized (RUINLocalFontLock()) {
            sRegisteredURLs = [NSMutableDictionary dictionary];
            NSDictionary *selection = [NSUserDefaults.standardUserDefaults
                dictionaryForKey:RUINLocalFontDefaultsKey];
            NSURL *directory = RUINLocalFontDirectory(NO, nil);
            NSURL *url = directory ? RUINStoredLocalFontURL(selection, directory) : nil;
            NSString *storedName = selection[@"name"];
            NSString *validatedName = nil;
            unsigned long long bytes = 0;
            NSError *error = nil;
            if (url && [storedName isKindOfClass:NSString.class] &&
                RUINValidateLocalFont(url, &validatedName, &bytes, &error) &&
                [validatedName isEqualToString:storedName] && RUINRegisterLocalFont(url, &error)) {
                sName = validatedName;
                sURL = url;
                sFileSize = bytes;
                sRegistered = YES;
                sRegisteredURLs[validatedName] = url;
                sStatus = @"loaded";
                RUINRemoveManagedFontsExcept(directory, url);
            } else {
                sStatus = selection ? @"restore_failed" : @"default";
                if (directory) RUINRemoveManagedFontsExcept(directory, nil);
            }
        }
    });
}

BOOL RUINLocalFontIsRegistered(void) {
    RUINInstallLocalFont();
    @synchronized (RUINLocalFontLock()) { return sRegistered && sName != nil; }
}

NSString *RUINLocalFontName(void) {
    RUINInstallLocalFont();
    @synchronized (RUINLocalFontLock()) { return sName; }
}

BOOL RUINImportLocalFont(NSURL *url, NSError **error) {
    if (error) *error = nil;
    RUINInstallLocalFont();
    @synchronized (RUINLocalFontLock()) {
        BOOL scopedAccess = [url startAccessingSecurityScopedResource];
        NSURL *stagingURL = nil;
        NSURL *fontURL = nil;
        BOOL imported = NO;
        @try {
            NSString *sourceName = nil;
            if (!RUINValidateLocalFont(url, &sourceName, NULL, error)) return NO;

            NSError *storageError = nil;
            NSURL *directory = RUINLocalFontDirectory(YES, &storageError);
            if (!directory) {
                if (error) *error = storageError;
                return NO;
            }

            NSString *identifier = NSUUID.UUID.UUIDString;
            NSString *extension = url.pathExtension.lowercaseString;
            stagingURL = [directory URLByAppendingPathComponent:
                [NSString stringWithFormat:@".staging-%@.%@", identifier, extension]];
            fontURL = [directory URLByAppendingPathComponent:
                [NSString stringWithFormat:@"font-%@.%@", identifier, extension]];
            NSError *copyError = nil;
            if (![NSFileManager.defaultManager copyItemAtURL:url toURL:stagingURL error:&copyError]) {
                if (error) *error = copyError;
                return NO;
            }
            if (![NSFileManager.defaultManager moveItemAtURL:stagingURL toURL:fontURL error:&copyError]) {
                if (error) *error = copyError;
                return NO;
            }
            stagingURL = nil;

            NSString *copiedName = nil;
            unsigned long long copiedSize = 0;
            if (!RUINValidateLocalFont(fontURL, &copiedName, &copiedSize, error) ||
                ![sourceName isEqualToString:copiedName]) {
                if (error && !*error) RUINLocalFontFail(error, RUINLocalFontErrorInvalidFont,
                    @"The copied font did not pass validation.");
                return NO;
            }
            NSURL *selectedURL = fontURL;
            unsigned long long selectedSize = copiedSize;
            NSURL *cachedURL = sRegisteredURLs[copiedName];
            if (cachedURL) {
                NSString *cachedName = nil;
                unsigned long long cachedSize = 0;
                BOOL cachedIsOwned = [cachedURL.URLByDeletingLastPathComponent.URLByResolvingSymlinksInPath.path
                    isEqualToString:directory.URLByResolvingSymlinksInPath.path] &&
                    [cachedURL.lastPathComponent hasPrefix:@"font-"] &&
                    RUINValidateLocalFont(cachedURL, &cachedName, &cachedSize, NULL) &&
                    [cachedName isEqualToString:copiedName] && cachedSize == copiedSize;
                NSData *cachedData = cachedIsOwned ? [NSData dataWithContentsOfURL:cachedURL] : nil;
                NSData *copiedData = cachedData ? [NSData dataWithContentsOfURL:fontURL] : nil;
                if (!cachedData || ![cachedData isEqualToData:copiedData]) {
                    RUINLocalFontFail(error, RUINLocalFontErrorRegistration,
                        @"A different font with this PostScript name is already registered.");
                    return NO;
                }
                selectedURL = cachedURL;
                selectedSize = cachedSize;
                [NSFileManager.defaultManager removeItemAtURL:fontURL error:nil];
                fontURL = nil;
            } else {
                if (!RUINRegisterLocalFont(fontURL, error)) return NO;
                sRegisteredURLs[copiedName] = fontURL;
            }

            [NSUserDefaults.standardUserDefaults setObject:@{
                @"name":copiedName, @"filename":selectedURL.lastPathComponent
            }
                forKey:RUINLocalFontDefaultsKey];
            sName = copiedName;
            sURL = selectedURL;
            sFileSize = selectedSize;
            sRegistered = YES;
            sStatus = cachedURL ? @"reselected_registered" : @"imported";
            imported = YES;
            // Registered fonts remain on disk until next launch, when only the saved selection is loaded.
            return YES;
        } @finally {
            if (!imported) {
                if (stagingURL) [NSFileManager.defaultManager removeItemAtURL:stagingURL error:nil];
                if (fontURL) [NSFileManager.defaultManager removeItemAtURL:fontURL error:nil];
            }
            if (scopedAccess) [url stopAccessingSecurityScopedResource];
        }
    }
}

void RUINResetLocalFont(void) {
    RUINInstallLocalFont();
    @synchronized (RUINLocalFontLock()) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:RUINLocalFontDefaultsKey];
        sName = nil;
        sURL = nil;
        sFileSize = 0;
        sRegistered = NO;
        sStatus = @"default";
        // Keep process-registered font files until next launch; never unlink a live registration.
    }
}

UIFont *RUINLocalFontAtSize(CGFloat size) {
    if (!isfinite(size) || size <= 0) return nil;
    RUINInstallLocalFont();
    @synchronized (RUINLocalFontLock()) {
        if (!sRegistered || !sName) return nil;
        // UIKit creates the font and its normal glyph fallback. The Logos hook
        // excludes calls from RUIN and protects reentry while replacing a font.
        return [UIFont fontWithName:sName size:size];
    }
}

NSDictionary<NSString *, id> *RUINLocalFontDiagnostics(void) {
    RUINInstallLocalFont();
    @synchronized (RUINLocalFontLock()) {
        return @{
            @"status":sStatus ?: @"unknown",
            @"available":@(sName != nil && sRegistered),
            @"registered":@(sRegistered),
            @"postScriptName":sName ?: NSNull.null,
            @"fileExtension":sURL.pathExtension.lowercaseString ?: NSNull.null,
            @"fileSizeBytes":@(sFileSize),
            @"maximumFileSizeBytes":@(RUINLocalFontMaximumBytes)
        };
    }
}
