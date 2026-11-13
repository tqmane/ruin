%config(generator=internal);

#import "MessagingPrivateAPI.h"
#import "AutomaticReadGate.h"
#import "Features.h"
#import "../core/TargetMetadata.h"
#import "SwiftFields.h"
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#elif defined(RUIN_AUTOMATIC_READ_GATE_HOST_CHECK)
@interface UIViewController : NSObject
- (void)viewDidLoad;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewDidLayoutSubviews;
@end
@interface RUINAutomaticChatController : UIViewController <RUINMessagingChatOwner> @end
#endif
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>

// The native automatic guard is a named Swift Bool field. Resolve its
// runtime ivar metadata rather than depending on a version's field offset.
static NSHashTable *controllers;
static char originalEnabledKey;
static NSUInteger applied, restored;
static atomic_ulong rejected;
static NSMutableDictionary *hookStatus;
static char boundaryObservationKey, boundaryObservationContext, layoutCacheKey;
static atomic_ulong boundaryWillChanges;
static atomic_uint_fast64_t readGatePolicyGeneration = ATOMIC_VAR_INIT(1);

@interface RUINAutomaticReadLayoutCache : NSObject
@property(nonatomic, weak) id gate;
@property(nonatomic, weak) id chat;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL hold;
@property(nonatomic) BOOL hasChatGetter;
@end

@implementation RUINAutomaticReadLayoutCache
@end

static inline void RUINBumpReadGateGeneration(void) {
    atomic_fetch_add_explicit(&readGatePolicyGeneration, 1, memory_order_release);
}

static void HoldGate(id gate) {
    if (!NSThread.isMainThread || !gate) return;
    NSNumber *saved = objc_getAssociatedObject(gate, &originalEnabledKey);
    int32_t previous = RUINWriteReadControllerEnabled(gate, 0);
    if (previous < 0) { rejected++; return; }
    if (!saved) objc_setAssociatedObject(gate, &originalEnabledKey, @(previous), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    applied++;
}

static void RestoreGate(id gate) {
    if (!NSThread.isMainThread || !gate) return;
    NSNumber *saved = objc_getAssociatedObject(gate, &originalEnabledKey);
    if (!saved) return;
    if (RUINWriteReadControllerEnabled(gate, saved.intValue) < 0) { rejected++; return; }
    objc_setAssociatedObject(gate, &originalEnabledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    restored++;
}

@interface RUINAutomaticReadBoundaryObservation : NSObject
@property(atomic, strong) NSManagedObject *chat;
@property(atomic, weak) id gate;
@property(atomic, copy) NSString *identity;
@property(atomic, strong) NSNumber *receivedBoundary;
@property(atomic) BOOL boundaryChanging;
@property(atomic, strong) NSDictionary *revokedToken;
@property(atomic) BOOL observing;
- (void)invalidate;
@end

@implementation RUINAutomaticReadBoundaryObservation
- (void)invalidate {
    if (!self.observing) return;
    self.observing = NO;
    NSManagedObject *chat = self.chat;
    self.chat = nil;
    self.revokedToken = nil;
    @try { [chat removeObserver:self forKeyPath:@"lastReceivedMessageID" context:&boundaryObservationContext]; }
    @catch (__unused NSException *exception) { }
}
- (void)dealloc { [self invalidate]; }
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &boundaryObservationContext) {
        [super observeValueForKeyPath:path ofObject:object change:change context:context]; return;
    }
    NSManagedObject *chat = self.chat;
    if (!self.observing || object != chat) return;
    // Prior KVO runs before native did-change observers can admit a new UI read.
    // Queue only the gate write from a private context; main must not wait back
    // on that context while it is delivering native KVO notifications.
    if ([change[NSKeyValueChangeNotificationIsPriorKey] boolValue]) {
        self.boundaryChanging = YES;
        self.revokedToken = RUINRevokeReadAfterUserReply(chat);
        NSDictionary *policyToken = RUINCaptureReadOnReplyToken(chat);
        atomic_fetch_add(&boundaryWillChanges, 1);
        RUINBumpReadGateGeneration();
        if (policyToken.count) {
            __weak RUINAutomaticReadBoundaryObservation *weakObservation = self;
            id gate = self.gate;
            void (^rearm)(void) = ^{
                RUINAutomaticReadBoundaryObservation *current = weakObservation;
                if (current.observing && current.gate == gate && RUINReadOnReplyTokenNeedsRearm(policyToken)) HoldGate(gate);
            };
            if (NSThread.isMainThread) rearm(); else dispatch_async(dispatch_get_main_queue(), rearm);
        }
    } else {
        NSDictionary *token = self.revokedToken;
        self.revokedToken = nil;
        // Core Data can notify an unchanged value. Only that case may restore
        // the old allowance; a newer received boundary never inherits it.
        id newBoundary = change[NSKeyValueChangeNewKey];
        self.receivedBoundary = [newBoundary isKindOfClass:NSNumber.class] ? newBoundary : nil;
        self.boundaryChanging = NO;
        RUINBumpReadGateGeneration();
        if (token.count && [newBoundary isKindOfClass:NSNumber.class] &&
            [newBoundary longLongValue] == [token[@"boundary"] longLongValue] &&
            RUINAllowReadAfterUserReplyWithToken(chat, token)) RUINAllowAutomaticReadForReply(token);
    }
}
@end

static BOOL ObserveBoundary(UIViewController *controller, NSManagedObject *chat, id gate, NSDictionary *token) {
    RUINAutomaticReadBoundaryObservation *old = objc_getAssociatedObject(controller, &boundaryObservationKey);
    if (old.observing && old.chat == chat && old.gate == gate) {
        if (!old.boundaryChanging) old.receivedBoundary = token[@"boundary"];
        return YES;
    }
    [old invalidate];
    RUINAutomaticReadBoundaryObservation *observation = [RUINAutomaticReadBoundaryObservation new];
    observation.chat = chat; observation.gate = gate; observation.identity = token[@"identity"];
    observation.receivedBoundary = token[@"boundary"];
    @try {
        [chat addObserver:observation forKeyPath:@"lastReceivedMessageID"
                  options:NSKeyValueObservingOptionPrior | NSKeyValueObservingOptionNew context:&boundaryObservationContext];
        observation.observing = YES;
        objc_setAssociatedObject(controller, &boundaryObservationKey, observation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    } @catch (__unused NSException *exception) {
        rejected++; return NO;
    }
}

static BOOL Compatible(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return RUINTargetMetadataMatchesInfo(info);
}
static void Apply(UIViewController *controller) {
    if (!NSThread.isMainThread || !Compatible()) return;
    uint64_t generation = atomic_load_explicit(&readGatePolicyGeneration, memory_order_acquire);
    [controllers addObject:controller];
    id context = RUINCopySwiftField(controller, "chatContext");
    static Class contextClass;
    static dispatch_once_t clsOnce;
    dispatch_once(&clsOnce, ^{ contextClass = NSClassFromString(@"_TtC15LineMessagingUI11ChatContext"); });
    if (!context || object_getClass(context) != contextClass) { rejected++; return; }
    id gate = RUINCopySwiftField(context, "markAsReadController");
    if (!gate) { rejected++; return; }
    BOOL hold = [NSUserDefaults.standardUserDefaults boolForKey:RUINReadControlEnabledDefaultsKey];
    __block BOOL observedBoundary = NO;
    id currentChat = nil;
    BOOL hasChatGetter = NO;
    SEL selector = sel_registerName("chat");
    Method method = class_getInstanceMethod(object_getClass(controller), selector);
    if (method && !strcmp(method_getTypeEncoding(method), "@16@0:8")) {
        hasChatGetter = YES;
        currentChat = [(id<RUINMessagingChatOwner>)controller chat];
    }
    if (hold && currentChat && [currentChat isKindOfClass:NSManagedObject.class]) {
        NSManagedObjectContext *owner = [currentChat managedObjectContext];
        if (owner) {
            __block BOOL policy = YES;
            [owner performBlockAndWait:^{
                if (RUINReadPolicyHasIdentity(currentChat)) {
                    NSDictionary *token = RUINCaptureReadOnReplyToken(currentChat);
                    if (token.count) observedBoundary = ObserveBoundary(controller, currentChat, gate, token);
                    policy = RUINShouldSuppressReadForChat(currentChat);
                    if (token.count && !observedBoundary) policy = YES;
                }
            }];
            hold = policy;
        }
    }
    if (!observedBoundary) {
        RUINAutomaticReadBoundaryObservation *old = objc_getAssociatedObject(controller, &boundaryObservationKey);
        [old invalidate];
        objc_setAssociatedObject(controller, &boundaryObservationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    RUINAutomaticReadLayoutCache *cache = objc_getAssociatedObject(controller, &layoutCacheKey);
    if (!cache) {
        cache = [RUINAutomaticReadLayoutCache new];
        objc_setAssociatedObject(controller, &layoutCacheKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cache.gate = gate;
    cache.chat = currentChat;
    cache.hasChatGetter = hasChatGetter;
    cache.hold = hold;
    cache.generation = generation;
    if (hold) {
        HoldGate(gate);
    } else RestoreGate(gate);
}

static void ApplyForLayout(UIViewController *controller) {
    if (!NSThread.isMainThread || !Compatible()) return;
    uint64_t generation = atomic_load_explicit(&readGatePolicyGeneration, memory_order_acquire);
    RUINAutomaticReadLayoutCache *cache = objc_getAssociatedObject(controller, &layoutCacheKey);
    id gate = cache.gate;
    if (cache && cache.generation == generation && gate) {
        id currentChat = cache.hasChatGetter ? [(id<RUINMessagingChatOwner>)controller chat] : nil;
        if (currentChat == cache.chat) {
            if (cache.hold) HoldGate(gate);
            else RestoreGate(gate);
            return;
        }
    }
    Apply(controller);
}

void RUINAllowAutomaticReadForReply(NSDictionary *token) {
    if (!NSThread.isMainThread) {
        NSDictionary *copied = [token copy];
        dispatch_async(dispatch_get_main_queue(), ^{ RUINAllowAutomaticReadForReply(copied); }); return;
    }
    if (!RUINReadOnReplyTokenIsAllowed(token)) return;
    RUINBumpReadGateGeneration();
    for (UIViewController *controller in controllers.allObjects) {
        RUINAutomaticReadBoundaryObservation *observation = objc_getAssociatedObject(controller, &boundaryObservationKey);
        if (observation.observing && !observation.boundaryChanging &&
            [observation.identity isEqual:token[@"identity"]] &&
            [observation.receivedBoundary isEqual:token[@"boundary"]]) RestoreGate(observation.gate);
    }
}
void RUINRefreshAutomaticReadGate(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ RUINRefreshAutomaticReadGate(); }); return; }
    RUINBumpReadGateGeneration();
    for (UIViewController *controller in controllers.allObjects) Apply(controller);
}
%group RUINAutomaticDidLoad
%hook RUINAutomaticChatController
- (void)viewDidLoad {
    Apply((id)self);
    %orig;
    Apply((id)self);
}
%end
%end

%group RUINAutomaticWillAppear
%hook RUINAutomaticChatController
- (void)viewWillAppear:(BOOL)animation {
    Apply((id)self);
    %orig;
    Apply((id)self);
}
%end
%end

%group RUINAutomaticDidAppear
%hook RUINAutomaticChatController
- (void)viewDidAppear:(BOOL)animation {
    Apply((id)self);
    %orig;
    Apply((id)self);
}
%end
%end

%group RUINAutomaticLayout
%hook RUINAutomaticChatController
- (void)viewDidLayoutSubviews {
    ApplyForLayout((id)self);
    %orig;
    ApplyForLayout((id)self);
}
%end
%end

void RUINInstallAutomaticReadGate(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ RUINInstallAutomaticReadGate(); }); return; }
    if (!Compatible()) return;
    static dispatch_once_t defaultsObserverOnce;
    dispatch_once(&defaultsObserverOnce, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
            object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
                RUINBumpReadGateGeneration();
            }];
    });
    if (!controllers) controllers = [NSHashTable weakObjectsHashTable];
    if (!hookStatus) hookStatus = [NSMutableDictionary dictionary];
    Class cls = NSClassFromString(@"_TtC15LineMessagingUI18ChatViewController");
    for (NSString *name in @[@"viewDidLoad", @"viewWillAppear:", @"viewDidAppear:", @"viewDidLayoutSubviews"]) {
        if ([hookStatus[name] isEqual:@"installed"]) continue;
        SEL selector = NSSelectorFromString(name);
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        BOOL animated = [name hasSuffix:@":"];
        const char *types = animated ? "v20@0:8B16" : "v16@0:8";
        if (!method || strcmp(method_getTypeEncoding(method), types)) { hookStatus[name] = @"unavailable_or_type_mismatch"; continue; }
        if (!method_getImplementation(method)) { hookStatus[name] = @"missing_implementation"; continue; }
        if ([name isEqual:@"viewDidLoad"]) { %init(RUINAutomaticDidLoad, RUINAutomaticChatController = cls); }
        else if ([name isEqual:@"viewWillAppear:"]) { %init(RUINAutomaticWillAppear, RUINAutomaticChatController = cls); }
        else if ([name isEqual:@"viewDidAppear:"]) { %init(RUINAutomaticDidAppear, RUINAutomaticChatController = cls); }
        else { %init(RUINAutomaticLayout, RUINAutomaticChatController = cls); }
        hookStatus[name] = @"installed";
    }
    RUINRefreshAutomaticReadGate();
}
NSDictionary *RUINAutomaticReadGateDiagnostics(void) {
    return @{@"hooks":hookStatus ?: @{}, @"applied":@(applied), @"restored":@(restored), @"rejected":@(atomic_load(&rejected)),
        @"receivedBoundaryWillChanges":@(atomic_load(&boundaryWillChanges)),
        @"scope":@"automatic native chat UI guard only; explicit/manual paths and queued work unverified",
        @"field":@"ChatContext.markAsReadController.isEnabled", @"fieldResolution":@"runtime_ivar", @"peerVerified":@NO};
}
