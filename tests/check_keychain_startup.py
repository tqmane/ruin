#!/usr/bin/env python3
"""Run the production keychain installer against isolated signing/OS responses."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'src/platform/Keychain.m').read_text()
start = source.index('void RUINInstallKeychainCompatibility(void) {')
end = source.index('\n#endif', start)
installer = source[start:end]
fixture = r'''
#define RUIN_KEYCHAIN_HOST_CHECK 1
#import "Keychain.m"
#import "fishhook.h"
#include <assert.h>
#include <stdio.h>
static NSString *const appGroup = @"FIXTURE.jp.naver.line";
static NSString *const sharedGroup = @"FIXTURE.com.linecorp.trident.shared";
static NSString *const wildcardGroup = @"J36T6YMF29.*";
static BOOL locked, persistFails, nativeAllowed, sharedAllowed, wildcardAllowed, identityReady = YES, corruptBinding;
static NSUInteger adds, deletes, saves, rebinds;
static NSDictionary *binding;
static OSStatus Add(CFDictionaryRef attrs, CFTypeRef *result) {
    (void)attrs; adds++;
    if (locked) return errSecInteractionNotAllowed;
    NSString *defaultResultGroup = wildcardAllowed ? wildcardGroup : appGroup;
    if (result) *result=CFRetain((__bridge CFTypeRef)@{(__bridge id)kSecAttrAccessGroup:defaultResultGroup});
    return errSecSuccess;
}
static OSStatus Delete(CFDictionaryRef query) { (void)query; deletes++; return errSecSuccess; }
static OSStatus Copy(CFDictionaryRef query, CFTypeRef *result) { (void)query;(void)result;return errSecSuccess; }
static OSStatus Update(CFDictionaryRef query, CFDictionaryRef attrs) { (void)query;(void)attrs;return errSecSuccess; }
static OSStatus (*originalSecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*originalSecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*originalSecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*originalSecItemDelete)(CFDictionaryRef);
#define RUINSecItemCopyMatching Copy
#define RUINSecItemAdd Add
#define RUINSecItemUpdate Update
#define RUINSecItemDelete Delete
#define SecItemAdd Add
#define SecItemDelete Delete
void RUINInstallBundleIdentity(void) {}
NSDictionary *RUINBundleIdentityDiagnostics(void) { return @{@"status": identityReady ? @"already_original" : @"not_requested"}; }
NSDictionary *RUINActualMainBundleInfo(void) { return @{}; }
static BOOL Eligible(NSString *status, NSDictionary *info) { (void)info;return [status isEqual:@"already_original"]; }
static RUINGroupPermission RUINProbeAccessGroupPermission(NSString *group) {
    if (locked) return RUINGroupPermissionUnknown;
    if (wildcardAllowed) return [group isEqual:wildcardGroup] ? RUINGroupPermissionAllowed : RUINGroupPermissionDenied;
    if ([group isEqual:appGroup] || (sharedAllowed && [group isEqual:sharedGroup]) ||
        (nativeAllowed && ([group isEqual:RUINOldAppAccessGroup] || [group isEqual:RUINOldSharedAccessGroup]))) return RUINGroupPermissionAllowed;
    return RUINGroupPermissionDenied;
}
static NSDictionary *RUINLoadNamespaceBinding(NSString *group, OSStatus *status) {
    assert([group isEqual:appGroup] || [group isEqual:sharedGroup] || [group isEqual:wildcardGroup]);
    if (corruptBinding) { corruptBinding = NO; *status = errSecDecode; return nil; }
    *status=binding ? errSecSuccess : errSecItemNotFound;return binding;
}
static BOOL RUINSaveNamespaceBinding(NSString *group, NSDictionary *mapping) {
    assert([group isEqual:appGroup] || [group isEqual:sharedGroup] || [group isEqual:wildcardGroup]);saves++;
    if (persistFails) return NO;
    binding=@{@"version":@1,@"groups":[mapping copy]};return YES;
}
static BOOL RUINUsesAuthenticatedImports(void) { return NO; }
static BOOL RUINResolveSecurityItemOperations(void) {
    originalSecItemCopyMatching=Copy;originalSecItemAdd=Add;originalSecItemUpdate=Update;originalSecItemDelete=Delete;return YES;
}
static const RUINVersionMapping *Mapping(void) { static RUINVersionMapping version;return &version; }
static BOOL Main(RUINMainExecutableImage *image) { memset(image,0,sizeof(*image));return YES; }
static BOOL Proof(const RUINVersionMapping *mapping,const RUINMainExecutableImage *image,BOOL auth) {(void)mapping;(void)image;(void)auth;return YES;}
static int Rebind(void *header,intptr_t slide,struct rebinding bindings[],size_t count) {
    (void)header;(void)slide;assert(count==4);assert(!strcmp(bindings[3].name,"SecItemDelete"));rebinds++;return 0;
}
#define RUINKeychainTargetEligible Eligible
#define RUINCurrentMapping Mapping
#define RUINResolveMainExecutableImage Main
#define RUINKeychainMainImageAllowsRebinding Proof
#define rebind_symbols_image Rebind
'''
checks = r'''
int main(int argc,const char **argv) { @autoreleasepool {
    assert(argc==2);NSString *mode=@(argv[1]);
    nativeAllowed=[mode isEqual:@"native"] || [mode isEqual:@"lc-owned"];
    sharedAllowed=[mode isEqual:@"shared"];
    wildcardAllowed=[mode isEqual:@"wildcard-group"];
    locked=[mode isEqual:@"locked"];
    persistFails=[mode isEqual:@"persist-failed"];
    identityReady=![mode isEqual:@"early-identity"];
    corruptBinding=[mode isEqual:@"decode-recovery"];
    if (wildcardAllowed) binding=@{@"version":@1,@"groups":@{RUINOldAppAccessGroup:wildcardGroup,RUINOldSharedAccessGroup:wildcardGroup}};
    if ([mode isEqual:@"foreign-binding"]) binding=@{@"version":@1,@"groups":@{RUINOldAppAccessGroup:@"OTHER.account",RUINOldSharedAccessGroup:@"OTHER.shared"}};
    RUINInstallKeychainCompatibility();
    if (locked || persistFails || !identityReady) {
        assert(!RUINKeychainCompatibilityReady() && !rebinds);
        locked=NO;persistFails=NO;identityReady=YES;
        RUINInstallKeychainCompatibility();
    }
    if ([mode isEqual:@"foreign-binding"]) {
        assert(!RUINKeychainCompatibilityReady() && !rebinds && !saves);
    } else {
        assert(RUINKeychainCompatibilityReady());
        assert(nativeAllowed ? !rebinds && !saves : rebinds==1 && namespaceBindingPersisted);
        if (!nativeAllowed) {
            NSString *expectedShared = wildcardAllowed ? wildcardGroup : (sharedAllowed ? sharedGroup : appGroup);
            NSString *expectedApp = wildcardAllowed ? wildcardGroup : appGroup;
            assert([binding[@"groups"][RUINOldSharedAccessGroup] isEqual:expectedShared]);
            assert([binding[@"groups"][RUINOldAppAccessGroup] isEqual:expectedApp]);
        }
        NSUInteger priorAdds=adds,priorRebinds=rebinds;
        RUINInstallKeychainCompatibility();
        assert(adds==priorAdds && rebinds==priorRebinds);
    }
    NSDictionary *diag = RUINKeychainDiagnostics();
    assert(diag[@"lastDefaultProbeStatus"] && diag[@"lastAppGroupProbeStatus"] &&
           diag[@"lastSharedGroupProbeStatus"] && diag[@"lastBindingLoadStatus"] &&
           diag[@"lastBindingSaveStatus"] && diag[@"lastBindingResetStatus"] &&
           diag[@"lastBindingRejectReason"] && diag[@"canResetBinding"]);
    if ([mode isEqual:@"foreign-binding"]) {
        assert([diag[@"lastBindingRejectReason"] isEqual:@"foreign_prefix:OTHER.account"]);
        assert([diag[@"canResetBinding"] boolValue]);
    }
    assert(deletes<=adds);printf("PASS production keychain startup: %s\n",argv[1]);
}return 0;}
'''
with tempfile.TemporaryDirectory(prefix='ruin-keychain-startup-') as tmp:
    tmp=Path(tmp);m=tmp/'check.m';m.write_text(fixture+'\n'+installer+'\n'+checks)
    common=[*sorted((ROOT/'src/known').glob('*.m')),*sorted((ROOT/'src/known/versions').glob('*.m'))]
    includes=[arg for folder in [*sorted((ROOT/'src').iterdir()),ROOT/'vendor/fishhook'] if folder.is_dir() for arg in ['-I',str(folder)]]
    subprocess.run(['xcrun','--sdk','macosx','clang','-DRUIN_HOST_CHECK=1','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-Wno-unused-function',*includes,str(m),*map(str,common),'-framework','Foundation','-framework','Security','-o',str(tmp/'check')],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(tmp/'check')],check=True)
    for scenario in ['default-only','shared','wildcard-group','native','lc-owned','locked','persist-failed','early-identity','decode-recovery','foreign-binding']:
        subprocess.run([str(tmp/'check'),scenario],check=True,timeout=10)
