#import <Foundation/Foundation.h>
#import <Security/SecItem.h>
#import <stdatomic.h>

#import "fishhook.h"
// Imported C symbols intentionally use fishhook: Logos' internal backend does
// not support %hookf, and this jailed-compatible dylib has no Substrate runtime.
// Rebinding imports keeps executable text and the input IPA unchanged.

static NSString *const RUINOldAppAccessGroup = @"ZW4U99SQQ3.jp.naver.line";
static NSString *const RUINOldSharedAccessGroup = @"ZW4U99SQQ3.com.linecorp.trident.shared";

static OSStatus (*originalSecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*originalSecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*originalSecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*originalSecItemDelete)(CFDictionaryRef);
static NSDictionary<NSString *, NSString *> *accessGroupMap;
static atomic_uint_fast64_t mappedQueries;

static NSDictionary *RUINMappedAttributes(CFDictionaryRef attributes) {
    if (!attributes || !accessGroupMap) return nil;

    NSDictionary *dictionary = (__bridge NSDictionary *)attributes;
    id group = dictionary[(__bridge id)kSecAttrAccessGroup];
    if (![group isKindOfClass:NSString.class]) return nil;

    NSString *replacement = accessGroupMap[group];
    if (!replacement) return nil;

    NSMutableDictionary *mapped = [dictionary mutableCopy];
    mapped[(__bridge id)kSecAttrAccessGroup] = replacement;
    return mapped;
}

static OSStatus RUINSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!originalSecItemCopyMatching) return errSecNotAvailable;
    NSDictionary *mapped = RUINMappedAttributes(query);
    if (mapped) atomic_fetch_add_explicit(&mappedQueries, 1, memory_order_relaxed);
    return originalSecItemCopyMatching(mapped ? (__bridge CFDictionaryRef)mapped : query, result);
}

static OSStatus RUINSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!originalSecItemAdd) return errSecNotAvailable;
    NSDictionary *mapped = RUINMappedAttributes(attributes);
    if (mapped) atomic_fetch_add_explicit(&mappedQueries, 1, memory_order_relaxed);
    return originalSecItemAdd(mapped ? (__bridge CFDictionaryRef)mapped : attributes, result);
}

static OSStatus RUINSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (!originalSecItemUpdate) return errSecNotAvailable;
    NSDictionary *mappedQuery = RUINMappedAttributes(query);
    NSDictionary *mappedAttributes = RUINMappedAttributes(attributesToUpdate);
    if (mappedQuery || mappedAttributes) atomic_fetch_add_explicit(&mappedQueries, 1, memory_order_relaxed);
    return originalSecItemUpdate(mappedQuery ? (__bridge CFDictionaryRef)mappedQuery : query,
                                 mappedAttributes ? (__bridge CFDictionaryRef)mappedAttributes : attributesToUpdate);
}

static OSStatus RUINSecItemDelete(CFDictionaryRef query) {
    if (!originalSecItemDelete) return errSecNotAvailable;
    NSDictionary *mapped = RUINMappedAttributes(query);
    if (mapped) atomic_fetch_add_explicit(&mappedQueries, 1, memory_order_relaxed);
    return originalSecItemDelete(mapped ? (__bridge CFDictionaryRef)mapped : query);
}

void RUINInstallKeychainCompatibility(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        id teamValue = info[@"RUINSignedTeamIdentifier"];
        id bundleValue = info[@"RUINSignedBundleIdentifier"];
        id currentBundleValue = info[@"CFBundleIdentifier"];
        id applicationIDValue = info[@"RUINSigningApplicationIdentifier"];
        if (![teamValue isKindOfClass:NSString.class] || ![bundleValue isKindOfClass:NSString.class] ||
            ![currentBundleValue isEqual:bundleValue] || ![teamValue length] ||
            [teamValue containsString:@"."] || ![bundleValue length]) return;

        NSString *team = teamValue;
        NSString *bundle = bundleValue;
        NSString *applicationID = [NSString stringWithFormat:@"%@.%@", team, bundle];
        if (applicationIDValue) {
            NSString *prefix = [team stringByAppendingString:@"."];
            if (![applicationIDValue isKindOfClass:NSString.class] ||
                ![applicationIDValue hasPrefix:prefix] ||
                [applicationIDValue length] <= prefix.length ||
                [applicationIDValue containsString:@"*"]) return;
            applicationID = applicationIDValue;
        }
        accessGroupMap = @{
            RUINOldAppAccessGroup: applicationID,
            RUINOldSharedAccessGroup: [team stringByAppendingString:@".com.linecorp.trident.shared"]
        };

        struct rebinding rebindings[] = {
            {"SecItemCopyMatching", (void *)RUINSecItemCopyMatching, (void **)&originalSecItemCopyMatching},
            {"SecItemAdd", (void *)RUINSecItemAdd, (void **)&originalSecItemAdd},
            {"SecItemUpdate", (void *)RUINSecItemUpdate, (void **)&originalSecItemUpdate},
            {"SecItemDelete", (void *)RUINSecItemDelete, (void **)&originalSecItemDelete}
        };
        rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
    });
}

NSDictionary *RUINKeychainDiagnostics(void) {
    return @{@"mappedKeychainQueries": @(atomic_load_explicit(&mappedQueries, memory_order_relaxed))};
}

static BOOL RUINCopyMatches(CFDictionaryRef query, NSData *expected, OSStatus *status) {
    NSMutableDictionary *copyQuery = [(__bridge NSDictionary *)query mutableCopy];
    copyQuery[(__bridge id)kSecReturnData] = (__bridge id)kCFBooleanTrue;
    copyQuery[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

    CFTypeRef result = NULL;
    *status = SecItemCopyMatching((__bridge CFDictionaryRef)copyQuery, &result);
    BOOL matches = *status == errSecSuccess && result && CFGetTypeID(result) == CFDataGetTypeID() &&
                   CFEqual(result, (__bridge CFDataRef)expected);
    if (result) CFRelease(result);
    return matches;
}

NSDictionary *RUINKeychainSelfTest(void) {
    RUINInstallKeychainCompatibility();

    NSString *account = [@"RUINKeychainSelfTest-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSData *initialValue = [NSUUID.UUID.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
    NSData *updatedValue = [NSUUID.UUID.UUIDString dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.ruin.keychain-self-test",
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecAttrAccessGroup: RUINOldAppAccessGroup
    };
    NSMutableDictionary *attributes = [query mutableCopy];
    attributes[(__bridge id)kSecValueData] = initialValue;

    OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
    NSMutableDictionary *result = [@{@"addStatus": @(addStatus), @"passed": @NO} mutableCopy];
    if (addStatus != errSecSuccess) return result;

    OSStatus copyStatus = errSecNotAvailable;
    OSStatus updateStatus = errSecNotAvailable;
    OSStatus verifyStatus = errSecNotAvailable;
    OSStatus deleteStatus = errSecNotAvailable;
    BOOL initialValueMatched = NO;
    BOOL updatedValueMatched = NO;
    @try {
        initialValueMatched = RUINCopyMatches((__bridge CFDictionaryRef)query, initialValue, &copyStatus);
        NSDictionary *update = @{(__bridge id)kSecValueData: updatedValue};
        updateStatus = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
        updatedValueMatched = RUINCopyMatches((__bridge CFDictionaryRef)query, updatedValue, &verifyStatus);
    } @catch (__unused NSException *exception) {
    } @finally {
        deleteStatus = SecItemDelete((__bridge CFDictionaryRef)query);
    }

    BOOL passed = initialValueMatched && updatedValueMatched && addStatus == errSecSuccess &&
                  copyStatus == errSecSuccess && updateStatus == errSecSuccess &&
                  verifyStatus == errSecSuccess && deleteStatus == errSecSuccess;
    [result addEntriesFromDictionary:@{
        @"copyStatus": @(copyStatus),
        @"updateStatus": @(updateStatus),
        @"verifyStatus": @(verifyStatus),
        @"deleteStatus": @(deleteStatus),
        @"passed": @(passed)
    }];
    return result;
}

__attribute__((constructor)) static void RUINInstallKeychainAtLoad(void) {
    @autoreleasepool { RUINInstallKeychainCompatibility(); }
}
