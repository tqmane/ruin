#!/usr/bin/env python3
"""Exercise the production storage installer across deferred identity readiness."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/check-sideload-startup'


def function(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 0
    for end in range(opening, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if not depth:
            return source[start:end + 1]
    raise AssertionError(signature)


SHIM = r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "TargetMetadata.h"
#include <assert.h>
#include <stdio.h>
static BOOL identityReady, metadataReady, installed, migrationReady;
static BOOL suitesInstalled, preferenceDomainsInstalled;
static NSUInteger identityCalls, preparations, groupHooks, suiteHooks, domainHooks, unsafeStorageCount;
static NSDictionary *groupMap, *resolvedGroupURLs;
static NSDictionary *requested;
@interface FixtureBundle : NSObject
+ (instancetype)mainBundle;
- (NSDictionary *)infoDictionary;
@end
@implementation FixtureBundle
+ (instancetype)mainBundle { static FixtureBundle *b; if (!b) b = [self new]; return b; }
- (NSDictionary *)infoDictionary { return metadataReady ? @{
    @"CFBundleIdentifier":@"jp.naver.line", @"CFBundleShortVersionString":@"26.17.0",
    @"CFBundleVersion":@"2026.1103.1841"} : @{}; }
@end
@interface FixtureFiles : NSObject
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)name;
@end
@implementation FixtureFiles
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)name { (void)name; return nil; }
@end
@interface FixtureDefaults : NSObject
- (instancetype)initWithSuiteName:(NSString *)name;
- (NSDictionary *)persistentDomainForName:(NSString *)name;
- (void)setPersistentDomain:(NSDictionary *)domain forName:(NSString *)name;
- (void)removePersistentDomainForName:(NSString *)name;
@end
@implementation FixtureDefaults
- (instancetype)initWithSuiteName:(NSString *)name { (void)name; return [super init]; }
- (NSDictionary *)persistentDomainForName:(NSString *)name { (void)name; return nil; }
- (void)setPersistentDomain:(NSDictionary *)domain forName:(NSString *)name { (void)domain; (void)name; }
- (void)removePersistentDomainForName:(NSString *)name { (void)name; }
@end
static void RUINInstallBundleIdentity(void) { identityCalls++; }
static NSDictionary *RUINBundleIdentityDiagnostics(void) {
    return @{@"status":identityReady ? @"installed" : @"mapping_unavailable"};
}
static NSDictionary *RUINActualMainBundleInfo(void) { return @{@"RUINAppGroupMap":requested}; }
// Only the storage-resolution and Logos-install boundaries are counted doubles.
// Real ownership/UUID/ABI policies remain covered by the existing host checks.
static void RUINPrepareStorageBindings(NSDictionary *map) {
    preparations++; assert([map isEqual:requested]); groupMap = map;
    NSMutableDictionary *urls = [NSMutableDictionary dictionary];
    for (NSString *name in RUINOriginalGroups()) urls[name] = NSNull.null;
    resolvedGroupURLs = urls;
}
#define NSBundle FixtureBundle
#define NSFileManager FixtureFiles
#define NSUserDefaults FixtureDefaults
'''

CHECK = r'''
int main(int argc, const char **argv) { @autoreleasepool {
    (void)argv;
    requested = argc > 1 ? @{@"group.com.linecorp.line":@"group.fixture.authorized"} : @{};
    RUINInstallCompatibility(); // Matches Sideload's early constructor call.
    assert(identityCalls == 1 && !installed && !preparations && !migrationReady);
    identityReady = YES;
    RUINInstallCompatibility(); // Identity is ready; logical metadata is not.
    assert(identityCalls == 2 && !installed && !preparations && !migrationReady);
    metadataReady = YES;
    RUINInstallCompatibility(); // A later constructor/login preflight may now install.
    assert(identityCalls == 3 && installed && migrationReady && preparations == 1 && groupHooks == 1);
    assert(suitesInstalled == (requested.count != 0));
    assert(preferenceDomainsInstalled == suitesInstalled);
    assert(suiteHooks == (requested.count ? 1 : 0) && domainHooks == suiteHooks);
    for (NSUInteger i = 0; i < 100; i++) RUINInstallCompatibility();
    assert(identityCalls == 3 && preparations == 1 && groupHooks == 1);
    puts("PASS storage installer retries identity/metadata misses; installs once; empty maps keep native preference domains");
} return 0; }
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    source = (ROOT / 'src/platform/Sideload.x').read_text()
    install = function(source, 'void RUINInstallCompatibility(void)')
    for group, counter in (('RUINAppGroupMapping', 'groupHooks'),
                           ('RUINPreferencesSuiteMapping', 'suiteHooks'),
                           ('RUINPreferencesDomainMapping', 'domainHooks')):
        directive = '%init(' + group + ');'
        assert install.count(directive) == 1
        install = install.replace(directive, counter + '++;')
    generated = OUT / 'check_sideload_startup.m'
    generated.write_text('#import <Foundation/Foundation.h>\n#import <objc/runtime.h>\n' +
        function(source, 'static NSArray<NSString *> *RUINOriginalGroups(void)') + '\n' +
        function(source, 'static BOOL RUINPreferencesDomainMethodsMatch(Class cls)') + '\n' +
        SHIM + '\n' + install + '\n' + CHECK)
    executable = OUT / 'check_sideload_startup'
    subprocess.run(['/usr/bin/xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks',
        '-Wall', '-Wextra', '-Werror', '-Isrc/core', '-Isrc/known', str(generated),
        '-framework', 'Foundation', '-o', str(executable)], cwd=ROOT, check=True)
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(executable)], check=True)
    for arguments in ([], ['mapped']):
        subprocess.run([str(executable), *arguments], check=True, timeout=20)


if __name__ == '__main__':
    main()
