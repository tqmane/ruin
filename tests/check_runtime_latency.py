#!/usr/bin/env python3
"""Exercise the production preference router and report scheduler with counted dependencies."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'src/core/Tweak.x').read_text()


def function(signature, source=SOURCE):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 0
    for end in range(opening, len(source)):
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
            if not depth:
                return source[start:end + 1]
    raise AssertionError(signature)


STATUS = function('static NSDictionary *RUINRuntimeStatus(void)')
REPORT = function('void RUINRefreshRuntimeReport(void)')
ROUTER = function('void RUINRefreshSettingsFeature(NSString *key)')
GATE = function('NSDictionary *RUINAutomaticReadGateDiagnostics(void)',
                (ROOT / 'src/messaging/AutomaticReadGate.x').read_text())
HISTORY_FLAGS = function('void RUINInstallMessageHistory(void)',
                         (ROOT / 'src/messaging/MessageHistory.x').read_text()).split('    if (!supported) return;')[0]
keys = sorted(set(re.findall(r'\bRUIN\w+(?:DefaultsKey|MessagesKey|ReadUsersKey)\b', ROUTER)))
dependencies = sorted(set(re.findall(r'\b(RUIN(?:Install|Refresh)\w+)\(', ROUTER)) - {
    'RUINRefreshSettingsFeature', 'RUINRefreshRuntimeReport'})
SHIM = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
static NSString * const RUINVersion = @"fixture";
static NSString *root;
static NSMutableArray<NSString *> *calls;
static unsigned captures, full, pushes, current;
static atomic_uint ioCalls;
static atomic_bool retainEnabled, readersEnabled;
static NSMutableDictionary *hookStatus;
static NSUInteger applied, restored;
static atomic_uint_fast64_t rejected, boundaryWillChanges;
static BOOL RUINTargetMetadataMatchesInfo(NSDictionary *info) { (void)info; return YES; }
static NSArray *FixtureDirectories(NSSearchPathDirectory d, NSSearchPathDomainMask m, BOOL expand) {
    assert(d == NSCachesDirectory && m == NSUserDomainMask && expand && !NSThread.isMainThread);
    atomic_fetch_add(&ioCalls,1); return @[root];
}
static NSDictionary *RUINReplyDiagnostics(void) { assert(NSThread.isMainThread); captures++; return @{@"value":@(current)}; }
static NSDictionary *RUINRuntimeDiagnostics(void) { assert(NSThread.isMainThread); full++; return @{@"scope":@"full"}; }
static void RUINRefreshPushDiagnostics(void) { pushes++; }
void RUINRefreshRuntimeReport(void);
void RUINRefreshSettingsFeature(NSString *key);
#define NSSearchPathForDirectoriesInDomains FixtureDirectories
'''
CHECK = r'''
static void CheckKey(NSString *key, NSArray *expected) {
    [calls removeAllObjects]; RUINRefreshSettingsFeature(key); assert([calls isEqual:expected]);
}
int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc==3); root=@(argv[2]); calls=[NSMutableArray array];
    if (!strcmp(argv[1],"routes")) {
        CheckKey(RUINClearViewedUnreadBadgesDefaultsKey,(@[@"RUINInstallLocalUnreadBadges"]));
        CheckKey(RUINLegacyHomeEnabledDefaultsKey,(@[@"RUINInstallLegacyHome"]));
        CheckKey(RUINMarkReadOnReplyDefaultsKey,(@[@"RUINInstallFeatures",@"RUINInstallReadBoundary",@"RUINInstallReadOnReply",@"RUINRefreshAutomaticReadGate",@"RUINInstallNativeChatControls",@"RUINInstallLocalUnreadBadges"]));
        CheckKey(RUINLocalNamesByIdentityDefaultsKey,(@[@"RUINInstallFeatures",@"RUINInstallReadBoundary",@"RUINInstallReadOnReply",@"RUINRefreshAutomaticReadGate",@"RUINInstallNativeChatControls",@"RUINInstallLocalUnreadBadges"]));
        CheckKey(RUINLegacyMessagingEnabledDefaultsKey,(@[@"RUINInstallLegacyMessagingConfiguration",@"RUINInstallClientVersionAdvertisement",@"RUINInstallNativeMuteSend"]));
        CheckKey(RUINLocalLYPEnabledDefaultsKey,(@[@"RUINInstallLocalAppearance"]));
        CheckKey(RUINLocalNotificationsEnabledDefaultsKey,(@[@"RUINInstallLocalNotifications"]));
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setVolatileDomain:@{RUINKeepUnsentMessagesKey:@YES, RUINTrackReadUsersKey:@NO} forName:NSArgumentDomain];
        CheckKey(RUINKeepUnsentMessagesKey,(@[@"RUINInstallMessageHistory",@"RUINInstallUnsendRetention",@"RUINInstallRetainedMedia",@"RUINRefreshUnsendMarkerUI"]));
        assert(atomic_load(&retainEnabled) && !atomic_load(&readersEnabled));
        [defaults setVolatileDomain:@{RUINKeepUnsentMessagesKey:@NO, RUINTrackReadUsersKey:@YES} forName:NSArgumentDomain];
        CheckKey(RUINKeepUnsentMessagesKey,(@[@"RUINInstallMessageHistory",@"RUINInstallUnsendRetention",@"RUINInstallRetainedMedia",@"RUINRefreshUnsendMarkerUI"]));
        assert(!atomic_load(&retainEnabled) && atomic_load(&readersEnabled));
        CheckKey(RUINTrackReadUsersKey,(@[@"RUINInstallMessageHistory",@"RUINInstallReadUsersEvents"]));
        CheckKey(RUINConfirmSendEnabledDefaultsKey,(@[@"RUINInstallConfirmations"]));
        CheckKey(RUINConfirmSendMinimumGroupMemberCountDefaultsKey,(@[@"RUINInstallConfirmations"]));
        CheckKey(RUINBypassAgeVerificationDefaultsKey,(@[@"RUINInstallAgeVerification"]));
        CheckKey(RUINCopyStickerGIFEnabledDefaultsKey,(@[@"RUINInstallMenuExtras"]));
        CheckKey(RUINHideAgentIBarDefaultsKey,(@[@"RUINRefreshInterfaceFeatures"]));
        CheckKey(RUINHideShoppingTabDefaultsKey,@[]); CheckKey(RUINStartupTabDefaultsKey,@[]);
        CheckKey(@"future.preference",(@[@"RUINRefreshSettingsFeatures"])); CheckKey(nil,@[]);
        puts("PASS production preference router: isolated families, immediate read policy, restart-only tabs, unknown-key fallback");
        return 0;
    }
    hookStatus=[@{@"fixture":@"initial"} mutableCopy];
    NSDictionary *gate=RUINAutomaticReadGateDiagnostics();
    hookStatus[@"fixture"]=@"changed";
    assert([gate[@"hooks"][@"fixture"] isEqual:@"initial"]);
    unsetenv("RUIN_ENABLE_RUNTIME_INSPECTOR");
    BOOL inspect = !strcmp(argv[1],"inspect");
    if (inspect) setenv("RUIN_ENABLE_RUNTIME_INSPECTOR","1",1);
    current=1;for(unsigned i=0;i<100;i++)RUINRefreshRuntimeReport();current=2;
    assert(!captures && !full && !pushes && !atomic_load(&ioCalls));
    NSString *file=[root stringByAppendingPathComponent:@"RUIN/runtime.json"];
    for(unsigned i=0;i<300 && ![NSFileManager.defaultManager fileExistsAtPath:file];i++)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    NSData *data=[NSData dataWithContentsOfFile:file];assert(data);
    NSDictionary *result=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];assert(result);
    assert(atomic_load(&ioCalls)==1);
    if(inspect)assert(full==1 && pushes==1 && !captures && [result[@"scope"] isEqual:@"full"]);
    else assert(!full && !pushes && captures==1 && [result[@"scope"] isEqual:@"status"] && [result[@"replyObserver"][@"value"] intValue]==2);
    printf("PASS production report %s: 100 requests coalesced, latest counters, no synchronous inspection or file IO\n",argv[1]);
}return 0;}
'''


def main():
    constants = '\n'.join(f'static NSString * const {name} = @"{name}";' for name in keys)
    stubs = '\n'.join(f'static void {name}(void) {{ assert(NSThread.isMainThread); [calls addObject:@"{name}"]; }}'
                      for name in dependencies if name != 'RUINInstallMessageHistory')
    history = HISTORY_FLAGS.replace('void RUINInstallMessageHistory(void) {',
        'static void RUINInstallMessageHistory(void) { [calls addObject:@"RUINInstallMessageHistory"];') + '}\n'
    with tempfile.TemporaryDirectory(prefix='ruin-runtime-latency-') as temp:
        folder=Path(temp);source=folder/'check.m';executable=folder/'check'
        source.write_text(SHIM+constants+'\n'+stubs+'\n'+history+GATE+'\n'+STATUS+'\n'+REPORT+'\n'+ROUTER+'\n'+CHECK)
        subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror',str(source),'-framework','Foundation','-o',str(executable)],check=True)
        for mode in ('routes','status','inspect'):
            subprocess.run([str(executable),mode,str(folder/mode)],check=True,timeout=10)
    settings=(ROOT/'src/interface/RUINSettings.m').read_text()
    assert 'RUINRefreshSettingsFeatures()' not in settings
    assert 'RUINRefreshSettingsFeature(key)' in settings


if __name__ == '__main__':
    main()
