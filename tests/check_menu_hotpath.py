#!/usr/bin/env python3
"""Count dependencies of real menu resolver/dismissal hooks; no LINE or device.

The seams count native proof, Swift fields and Core Data-bound key resolution.
Negative controls restore the expensive edges in memory, never in app source.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

SHIM = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static NSUInteger proofs, fields, keyReads, databaseWaits, originals, attaches, escapes, delays;
static NSUInteger observations, readerQueries, loaderQueries, presentations;
static BOOL proofReady, synchronousEscape, refuseEscape;
static atomic_bool sReadUntilMenuAvailable;
static atomic_bool sReadUsersBindingVerified;
static atomic_uint_fast64_t sReadUntilAvailabilityChecks, sMenuContextResolutions, sMessageKeyResolutions;
static atomic_uint_fast64_t sMenuPresentationGeneration, sMenuPresentationsQueued;
static char sMenuDismissedActionAssociationKey;
static NSMutableArray<dispatch_block_t> *pending;
static void FixtureEnqueue(dispatch_queue_t queue, dispatch_block_t block) {
    CHECK(queue == dispatch_get_main_queue()); [pending addObject:[block copy]];
}
static void __attribute__((unused)) FixtureAfter(dispatch_time_t time, dispatch_queue_t queue, dispatch_block_t block) {
    (void)time; delays++; FixtureEnqueue(queue,block);
}
static void Drain(void) {
    unsigned budget = 100;
    while (pending.count) {
        CHECK(budget--); dispatch_block_t block = pending.firstObject;
        [pending removeObjectAtIndex:0]; block();
    }
}
#define dispatch_async FixtureEnqueue
#define dispatch_after FixtureAfter
@class UIWindow, UIWindowScene, UIViewController, UICollectionView, UICollectionViewCell, UICollectionViewLayout;
@interface UIResponder : NSObject
@property(nonatomic, strong) UIResponder *nextResponder;
@end
@implementation UIResponder @end
@interface UIView : UIResponder
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, copy) NSArray<UIView *> *subviews;
@property(nonatomic) BOOL hidden;
@property(nonatomic) CGFloat alpha;
@property(nonatomic) CGRect bounds, fixtureRect;
@property(nonatomic, strong) UIView *fixturePlaceholder;
@property(nonatomic, weak) UIView *fixtureContainer;
- (CGPoint)convertPoint:(CGPoint)point toView:(UIView *)view;
- (CGPoint)convertPoint:(CGPoint)point fromView:(UIView *)view;
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view;
- (BOOL)accessibilityPerformEscape;
@end
@interface UIWindow : UIView
@property(nonatomic, strong) UIWindowScene *windowScene;
- (CGPoint)convertPoint:(CGPoint)point toWindow:(UIWindow *)window;
- (CGRect)convertRect:(CGRect)rect toWindow:(UIWindow *)window;
@end
@interface UIWindowScene : NSObject
@property(nonatomic) NSInteger activationState;
@property(nonatomic, copy) NSArray<UIWindow *> *windows;
@end
@implementation UIWindowScene @end
@interface FixtureContainer : UIView
- (void)didMoveToWindow;
@end
@implementation FixtureContainer
- (void)didMoveToWindow { originals++; }
@end
@implementation UIView
- (instancetype)init { if ((self=[super init])) { _alpha=1; _subviews=@[]; _bounds=CGRectMake(0,0,10,10); _fixtureRect=_bounds; } return self; }
- (CGPoint)convertPoint:(CGPoint)point toView:(UIView *)view { (void)view; return point; }
- (CGPoint)convertPoint:(CGPoint)point fromView:(UIView *)view { (void)view; return point; }
- (CGRect)convertRect:(CGRect)rect toView:(UIView *)view { (void)rect; (void)view; return self.fixtureRect; }
- (BOOL)accessibilityPerformEscape {
    escapes++;
    if (refuseEscape) return NO;
    if (synchronousEscape) {
        self.fixtureContainer.window = nil;
        [(FixtureContainer *)self.fixtureContainer didMoveToWindow];
    }
    return YES;
}
@end
@implementation UIWindow
- (CGPoint)convertPoint:(CGPoint)point toWindow:(UIWindow *)window { (void)window; return point; }
- (CGRect)convertRect:(CGRect)rect toWindow:(UIWindow *)window { (void)window; return rect; }
@end
@interface UIViewController : UIResponder
@property(nonatomic, strong) UIView *viewIfLoaded;
@property(nonatomic, strong) UIViewController *presentedViewController;
@end
@implementation UIViewController @end
@interface UICollectionViewCell : UIView
@property(nonatomic, copy) NSDictionary *fixtureKey;
@end
@implementation UICollectionViewCell @end
@interface UICollectionView : UIView
@property(nonatomic, strong) NSIndexPath *fixtureIndex;
@property(nonatomic, strong) UICollectionViewCell *fixtureCell;
- (NSIndexPath *)indexPathForItemAtPoint:(CGPoint)point;
- (NSIndexPath *)indexPathForCell:(UICollectionViewCell *)cell;
- (UICollectionViewCell *)cellForItemAtIndexPath:(NSIndexPath *)path;
@end
@implementation UICollectionView
- (NSIndexPath *)indexPathForItemAtPoint:(CGPoint)point { (void)point; return self.fixtureIndex; }
- (NSIndexPath *)indexPathForCell:(UICollectionViewCell *)cell { return cell == self.fixtureCell ? self.fixtureIndex : nil; }
- (UICollectionViewCell *)cellForItemAtIndexPath:(NSIndexPath *)path { return [path isEqual:self.fixtureIndex] ? self.fixtureCell : nil; }
@end
enum { UIApplicationStateActive, UIApplicationStateBackground, UISceneActivationStateForegroundActive=0 };
@interface UIApplication : NSObject
@property(nonatomic) NSInteger applicationState;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static UIApplication *app; if (!app) app=[self new]; return app; }
@end
static NSString *const RUINTrackReadUsersKey=@"read", *const RUINKeepUnsentMessagesKey=@"keep";
static NSString *const RUINCopyStickerGIFEnabledDefaultsKey=@"gif";
@interface FixtureDefaults : NSObject
+ (instancetype)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)key;
@end
@implementation FixtureDefaults
+ (instancetype)standardUserDefaults { static FixtureDefaults *d; if (!d) d=[self new]; return d; }
- (BOOL)boolForKey:(NSString *)key { return [key isEqual:@"read"]; }
@end
static BOOL RUINReadUntilAvailable(void) { proofs++; return proofReady; }
static BOOL RUINMenuExtrasPreferenceEnabled(NSString *key) { (void)key; return NO; }
static id RUINCopySwiftField(id value, const char *name) {
    fields++; CHECK(!strcmp(name,"targetPlaceholderView")); return [(UIView *)value fixturePlaceholder];
}
static NSDictionary *RUINMenuExtrasMessageKeyForCell(UICollectionViewCell *cell) {
    atomic_fetch_add(&sMessageKeyResolutions,1);
    keyReads++; databaseWaits++; return cell.window ? cell.fixtureKey : nil;
}
static NSURL *RUINMenuExtrasAnimatedStickerFileURLForCell(UICollectionViewCell *cell) { (void)cell; return nil; }
static NSArray *RUINRetainedMediaItems(NSDictionary *key) { (void)key; return @[]; }
static void RUINMenuExtrasAttachEntries(UIView *container) { CHECK(container.window); attaches++; }
static void RUINMenuExtrasScheduleInspection(void) {}
typedef void (^RUINReaderLoadCompletion)(NSArray *, NSError *);
typedef void (^RUINReaderLoader)(RUINReaderLoadCompletion);
static NSDictionary *expectedKey;
static UIViewController *expectedController;
static void RUINObserveNativeReadPositionsForMessageKey(NSDictionary *key, id chat) { (void)chat; CHECK([key isEqual:expectedKey]); observations++; }
static NSArray *RUINReadUsersForMessageKey(NSDictionary *key) { CHECK([key isEqual:expectedKey]); readerQueries++; return @[]; }
static RUINReaderLoader RUINMenuExtrasReadRangeLoader(NSDictionary *key, id chat) { (void)chat; CHECK([key isEqual:expectedKey]); loaderQueries++; return nil; }
static void RUINMenuExtrasPresentReaders(UIViewController *controller, NSArray *rows, RUINReaderLoader loader) {
    (void)rows; (void)loader; CHECK(controller == expectedController); presentations++;
}
'''

CHECKS = r'''
static NSDictionary *Key(NSString *store, NSString *message) {
    return @{@"store":store,@"kind":@"talk",@"chat":@"fixture-chat",@"message":message};
}
int main(void) { @autoreleasepool {
    pending=[NSMutableArray array];
    Class collectionClass=objc_allocateClassPair(UICollectionView.class,"_TtC17LineMessagingUIV218ChatCollectionView",0);
    Class controllerClass=objc_allocateClassPair(UIViewController.class,"_TtC15LineMessagingUI18ChatViewController",0);
    CHECK(collectionClass && controllerClass); objc_registerClassPair(collectionClass); objc_registerClassPair(controllerClass);
    %init(RUINMenuWindow, RUINMenuContainer=FixtureContainer.class);
    RUINMenuExtrasPrepareReadUntilAvailability(); CHECK(proofs == 1 && !atomic_load(&sReadUntilMenuAvailable));
    proofReady=YES; RUINMenuExtrasPrepareReadUntilAvailability(); CHECK(proofs == 2 && atomic_load(&sReadUntilMenuAvailable));
    for (unsigned i=0;i<100;i++) RUINMenuExtrasPrepareReadUntilAvailability();
    CHECK(proofs == 2); // A successful proof's lifetime pin stays owned by ReadUntil.m.
    UIWindowScene *scene=[UIWindowScene new]; UIWindow *window=[UIWindow new]; window.window=window;
    window.windowScene=scene; scene.windows=@[window];
    UIViewController *owner=[controllerClass new]; owner.viewIfLoaded=[UIView new]; owner.viewIfLoaded.window=window;
    expectedController=owner;
    UICollectionView *collection=[collectionClass new], *offAnchor=[collectionClass new];
    collection.window=offAnchor.window=window;
    collection.fixtureIndex=[NSIndexPath indexPathWithIndex:1]; offAnchor.fixtureIndex=[NSIndexPath indexPathWithIndex:2];
    UICollectionViewCell *cell=[UICollectionViewCell new], *other=[UICollectionViewCell new];
    cell.window=other.window=window; cell.nextResponder=other.nextResponder=owner;
    cell.fixtureKey=Key(@"store-a",@"41"); other.fixtureKey=Key(@"store-b",@"42");
    collection.fixtureCell=cell; offAnchor.fixtureCell=other; other.fixtureRect=CGRectMake(1000,1000,10,10);
    window.subviews=@[collection,offAnchor];
    FixtureContainer *container=[FixtureContainer new]; container.window=window;
    UIView *placeholder=[UIView new]; placeholder.window=window; container.fixturePlaceholder=placeholder;
    UIView *menu=[UIView new]; menu.window=window; menu.fixtureContainer=container;
    UICollectionView *grid=[UICollectionView new]; grid.window=window;
    [container didMoveToWindow]; CHECK(originals == 1 && attaches == 0 && pending.count == 1 && delays == 0);
    Drain(); CHECK(attaches == 1);
    RUINMenuExtrasContext *context=nil;
    for (unsigned i=0;i<100;i++) {
        context=RUINMenuExtrasResolveContext(container,grid);
        CHECK(context && context.includesReadUntil && [context.messageKey isEqual:cell.fixtureKey]);
        CHECK(FixtureDiagnosticAvailable());
    }
    CHECK(proofs == 2 && keyReads == 100 && databaseWaits == 100);
    CHECK(atomic_load(&sMenuContextResolutions) == 100);
    // Rejected geometry and controllers must not cross the Core Data boundary.
    owner.presentedViewController=[UIViewController new]; NSUInteger before=keyReads;
    CHECK(!RUINMenuExtrasResolveContext(container,grid) && keyReads == before);
    owner.presentedViewController=nil;
    other.fixtureRect=cell.fixtureRect;
    CHECK(!RUINMenuExtrasResolveContext(container,grid)); // Two eligible bindings stay ambiguous/fail closed.
    CHECK(keyReads == before+2); other.fixtureRect=CGRectMake(1000,1000,10,10);
    context=RUINMenuExtrasResolveContext(container,grid);
    expectedKey=context.messageKey;
    FixtureTapReaders(menu,context);
    CHECK(escapes == 1 && !pending.count && !presentations && !readerQueries && !loaderQueries);
    Drain(); CHECK(context.presentationScheduled && objc_getAssociatedObject(container,&sMenuDismissedActionAssociationKey));
    FixtureTapReaders(menu,context); CHECK(escapes == 1); // Same menu action is consumed once.
    container.window=nil; [container didMoveToWindow];
    CHECK(originals == 2 && pending.count == 1 && !presentations);
    RUINMenuExtrasCompleteDismissal(container); CHECK(pending.count == 1);
    Drain(); CHECK(presentations == 1 && observations == 1 && readerQueries == 1 && loaderQueries == 1 && !delays);
    // Reused cells, changed store namespaces and index paths cancel deferred work.
    for (unsigned variant=0;variant<3;variant++) {
        container.window=window; [container didMoveToWindow]; Drain();
        context=RUINMenuExtrasResolveContext(container,grid); expectedKey=context.messageKey;
        FixtureTapReaders(menu,context);
        NSDictionary *saved=cell.fixtureKey; NSIndexPath *savedIndex=collection.fixtureIndex;
        if (variant == 0) cell.fixtureKey=Key(@"store-a",@"99");
        if (variant == 1) cell.fixtureKey=Key(@"different-account-store",@"41");
        if (variant == 2) collection.fixtureIndex=[NSIndexPath indexPathWithIndex:99];
        container.window=nil; [container didMoveToWindow]; Drain();
        CHECK(presentations == 1 && readerQueries == 1);
        cell.fixtureKey=saved; collection.fixtureIndex=savedIndex;
    }
    // A genuinely fresh selection reads the reused cell again, never an old key.
    cell.fixtureKey=Key(@"store-a",@"100"); container.window=window; [container didMoveToWindow]; Drain();
    context=RUINMenuExtrasResolveContext(container,grid); CHECK([context.messageKey[@"message"] isEqual:@"100"]);
    expectedKey=context.messageKey; synchronousEscape=YES; before=originals;
    FixtureTapReaders(menu,context); CHECK(originals == before+1 && pending.count == 1);
    Drain(); CHECK(presentations == 2 && readerQueries == 2 && !delays); synchronousEscape=NO;
    // Reattach/new-menu generation cancels a queued handoff and old attach jobs.
    container.window=window; [container didMoveToWindow]; Drain();
    context=RUINMenuExtrasResolveContext(container,grid); expectedKey=context.messageKey;
    FixtureTapReaders(menu,context); container.window=nil; [container didMoveToWindow];
    container.window=window; [container didMoveToWindow]; Drain(); CHECK(presentations == 2);
    before=attaches;
    [container didMoveToWindow]; [container didMoveToWindow]; Drain(); CHECK(attaches == before+1);
    CHECK(proofs == 2 && !delays && atomic_load(&sReadUntilAvailabilityChecks) == 2);
    // A refused native escape releases only its still-attached pending action
    // next turn. Retrying the same selection can then use an animated dismissal.
    context=RUINMenuExtrasResolveContext(container,grid); expectedKey=context.messageKey;
    NSUInteger beforeEscapes=escapes, beforePresentations=presentations, beforeQueries=readerQueries;
    refuseEscape=YES; FixtureTapReaders(menu,context);
    CHECK(escapes == beforeEscapes+1 && context.presentationScheduled && pending.count == 1);
    CHECK(objc_getAssociatedObject(container,&sMenuDismissedActionAssociationKey));
    Drain();
    CHECK(container.window && !context.presentationScheduled);
    CHECK(!objc_getAssociatedObject(container,&sMenuDismissedActionAssociationKey));
    CHECK(presentations == beforePresentations && readerQueries == beforeQueries);
    refuseEscape=NO; FixtureTapReaders(menu,context);
    CHECK(escapes == beforeEscapes+2 && context.presentationScheduled);
    Drain(); CHECK(container.window && context.presentationScheduled);
    CHECK(objc_getAssociatedObject(container,&sMenuDismissedActionAssociationKey));
    CHECK(presentations == beforePresentations && readerQueries == beforeQueries);
    container.window=nil; [container didMoveToWindow]; Drain();
    CHECK(presentations == beforePresentations+1 && readerQueries == beforeQueries+1 && !delays);
    puts("PASS menu hotpath: cached proof, rejected-UI key bounds, once-only fresh selection, refused escape retries without cancelling accepted animation");
} return 0; }
'''


def extract(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


def main():
    source = (ROOT / "src/messaging/MenuExtras.x").read_text()
    availability = extract(source,"static void RUINMenuExtrasPrepareReadUntilAvailability(","static void RUINMenuExtrasSetError(")
    context = extract(source,"@interface RUINMenuExtrasContext :", "typedef NS_ENUM(NSInteger, RUINMenuExtrasHookStatus)")
    collect = extract(source,"static void RUINMenuExtrasCollectChatCollections(","static UIViewController *RUINMenuExtrasChatControllerForCell(")
    controller = extract(source,"static UIViewController *RUINMenuExtrasChatControllerForCell(UICollectionViewCell *cell, UIWindow *window)\n{",
                         "static RUINMenuExtrasContext *RUINMenuExtrasResolveContext(")
    resolver = extract(source,"static RUINMenuExtrasContext *RUINMenuExtrasResolveContext(","static void RUINMenuExtrasAttachEntries(")
    dismissal = extract(source,"static void RUINMenuExtrasCompleteDismissal(","static RUINReaderLoader RUINMenuExtrasReadRangeLoader(")
    window_hook = extract(source,"%group RUINMenuWindow", "static Method RUINMenuExtrasOwnMethod(")
    selection = extract(source,"%group RUINMenuSelection", "%group RUINMenuWindow")
    readers = selection[selection.rindex("    RUINMenuExtrasDismissForPresentation("):selection.rindex("\n}\n%end")]
    readers = readers.replace("(UIView *)self", "menu")
    tap = ('static void FixtureTapReaders(UIView *menu, RUINMenuExtrasContext *context) {\n'
           'NSDictionary *messageKey=context.messageKey; id nativeChat=[NSObject new];\n'
           'UIViewController *chatController=context.chatViewController;\n'+readers+'\n}\n')
    diagnostic = re.search(r'@"available": @\((.*?)\),', source[source.index('@"readUntil": @{'):], re.S)[1]
    diagnostic = 'static BOOL FixtureDiagnosticAvailable(void) { BOOL readUsersHooksInstalled=YES; return '+diagnostic+'; }\n'
    prefix = SHIM+context+availability+collect+controller+'\n#define NSUserDefaults FixtureDefaults\n'
    suffix = '\n#undef NSUserDefaults\n'+dismissal+tap+diagnostic+window_hook+CHECKS
    with tempfile.TemporaryDirectory(prefix="ruin-menu-hotpath-") as temporary:
        directory = Path(temporary)

        def build(name, resolver_body, suffix_body=suffix):
            logos=directory / (name+'.x'); generated=directory / (name+'.m'); executable=directory / name
            logos.write_text('%config(generator=internal);\n'+prefix+resolver_body+suffix_body)
            result=subprocess.run(['perl',str(ROOT / 'vendor/logos/bin/logos.pl'),'-c','warnings=error',str(logos)],
                check=True,capture_output=True,text=True)
            generated.write_text(result.stdout)
            subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-fblocks','-std=gnu11',
                '-Wall','-Wextra','-Werror',str(generated),'-framework','Foundation','-framework','CoreGraphics',
                '-o',str(executable)],check=True)
            return executable

        subprocess.run([str(build('menu',resolver))],check=True,timeout=10)
        regressions = {
            'repeated-proof': (resolver.replace('BOOL canReadUntil = atomic_load_explicit(&sReadUntilMenuAvailable, memory_order_acquire);',
                                               'BOOL canReadUntil = RUINReadUntilAvailable();'),suffix),
            'timer-presentation': (resolver,suffix.replace('if (action) dispatch_async(dispatch_get_main_queue(), action);',
                'if (action) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),action);')),
            'refused-escape-latch': (resolver,suffix.replace('if (!dismissed) dispatch_async(',
                'if (!dismissed && NO) dispatch_async(')),
            'accepted-animation-cancelled': (resolver,suffix.replace('if (!dismissed) dispatch_async(',
                'if (YES || !dismissed) dispatch_async(')),
        }
        key_lookup='        NSDictionary *messageKey = RUINMenuExtrasMessageKeyForCell(cell);\n        if (!messageKey.count) continue;\n'
        assert resolver.count(key_lookup)==1
        regressions['early-key-wait']=(resolver.replace(key_lookup,'').replace('        CGRect cellRect =',key_lookup+'        CGRect cellRect ='),suffix)
        for name,(body,tail) in regressions.items():
            assert body != resolver or tail != suffix
            result=subprocess.run([str(build(name,body,tail))],capture_output=True,text=True,timeout=10)
            assert result.returncode != 0 and 'FAIL' in result.stderr,(name,result)
            print('PASS negative control:',name,flush=True)

        includes=[part for folder in sorted((ROOT/'src').iterdir()) if folder.is_dir() for part in ('-I',str(folder))]
        known=ROOT/'src/known'
        sources=[ROOT/'src/messaging/ReadUntil.m',ROOT/'tests/check_read_until.m',
                 *[known/name for name in ('KnownMappings.m','BinaryVerifier.m','FeatureImage.m')],
                 *sorted((known/'versions').glob('*.m'))]
        executable=directory/'read-until'
        subprocess.run(['xcrun','--sdk','macosx','clang','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror',
            '-DRUIN_HOST_CHECK=1','-DRUIN_READ_UNTIL_HOST_CHECK=1',*includes,*map(str,sources),
            '-framework','Foundation','-framework','CoreData','-o',str(executable)],check=True)
        for variant in ('normal','native-owner','swift-root','chat-abi','mid-abi','service-abi'):
            subprocess.run([str(executable),variant],check=True,timeout=30)
        print('PASS actual ReadUntil owner/UUID/ABI/account/selected-ID gates unchanged')


if __name__ == '__main__':
    main()
