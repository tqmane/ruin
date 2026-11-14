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
@end
@interface RUINAutomaticChatController : UIViewController <RUINMessagingChatOwner> @end
#endif
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <string.h>

static NSHashTable *controllers;
static char controllerStateKey, originalEnabledKey;
static NSUInteger applied, restored;
static atomic_ulong rejected;
static NSMutableDictionary *hookStatus;
static char boundaryObservationContext;
static atomic_ulong boundaryWillChanges;

@class RUINAutomaticReadBoundaryObservation;
@interface RUINAutomaticReadGateState : NSObject {
@public
    atomic_uint_fast64_t generation;
    atomic_uint_fast64_t attachmentGeneration;
}
@property(nonatomic, strong) id context;
@property(nonatomic, strong) NSManagedObject *chat;
@property(nonatomic, strong) NSManagedObjectContext *ownerContext;
@property(nonatomic, weak) id gate;
@property(nonatomic) BOOL initialized;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL policyKnown;
@property(nonatomic) BOOL identityResolved;
@property(nonatomic) BOOL shouldSuppress;
@property(nonatomic) BOOL pending;
@property(nonatomic) uint64_t pendingGeneration;
@property(nonatomic, copy) NSDictionary *pendingReplyToken;
@property(atomic, strong) RUINAutomaticReadBoundaryObservation *observation;
@end

@implementation RUINAutomaticReadGateState
- (instancetype)init {
    self = [super init];
    if (self) {
        atomic_init(&generation, 1);
        atomic_init(&attachmentGeneration, 1);
    }
    return self;
}
@end

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
@property(atomic, weak) RUINAutomaticReadGateState *state;
@property(atomic, copy) NSString *identity;
@property(atomic, strong) NSNumber *receivedBoundary;
@property(atomic) uint64_t attachmentGeneration;
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
    RUINAutomaticReadGateState *state = self.state;
    NSManagedObject *chat = self.chat;
    if (!self.observing || !state || object != chat ||
        atomic_load(&state->attachmentGeneration) != self.attachmentGeneration) return;

    // Prior KVO runs before native did-change observers can admit a new UI read.
    // The managed-object policy stays on its owning context; only the gate write
    // is queued to main so it never waits back on this context.
    if ([change[NSKeyValueChangeNotificationIsPriorKey] boolValue]) {
        atomic_fetch_add(&state->generation, 1);
        self.boundaryChanging = YES;
        self.revokedToken = RUINRevokeReadAfterUserReply(chat);
        NSDictionary *policyToken = RUINCaptureReadOnReplyToken(chat);
        atomic_fetch_add(&boundaryWillChanges, 1);
        if (policyToken.count) {
            __weak RUINAutomaticReadBoundaryObservation *weakObservation = self;
            dispatch_block_t rearm = ^{
                RUINAutomaticReadBoundaryObservation *current = weakObservation;
                RUINAutomaticReadGateState *currentState = current.state;
                if (current.observing && currentState == state &&
                    current.attachmentGeneration == atomic_load(&currentState->attachmentGeneration) &&
                    current == currentState.observation && RUINReadOnReplyTokenNeedsRearm(policyToken)) {
                    currentState.policyKnown = YES;
                    currentState.identityResolved = YES;
                    currentState.shouldSuppress = YES;
                    currentState.pendingReplyToken = nil;
                    HoldGate(current.gate);
                }
            };
            if (NSThread.isMainThread) rearm(); else dispatch_async(dispatch_get_main_queue(), rearm);
        }
    } else {
        NSDictionary *token = self.revokedToken;
        self.revokedToken = nil;
        // An unchanged-value notification may preserve the exact old allowance;
        // a newer received boundary never inherits it.
        id newBoundary = change[NSKeyValueChangeNewKey];
        self.receivedBoundary = [newBoundary isKindOfClass:NSNumber.class] ? newBoundary : nil;
        self.boundaryChanging = NO;
        if (token.count && [newBoundary isKindOfClass:NSNumber.class] &&
            [newBoundary longLongValue] == [token[@"boundary"] longLongValue] &&
            RUINAllowReadAfterUserReplyWithToken(chat, token)) RUINAllowAutomaticReadForReply(token);
    }
}
@end

static RUINAutomaticReadGateState *StateForController(UIViewController *controller) {
    RUINAutomaticReadGateState *state = objc_getAssociatedObject(controller, &controllerStateKey);
    if (!state) {
        state = [RUINAutomaticReadGateState new];
        objc_setAssociatedObject(controller, &controllerStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [controllers addObject:controller];
    return state;
}

static void InvalidateObservation(RUINAutomaticReadGateState *state) {
    RUINAutomaticReadBoundaryObservation *observation = state.observation;
    state.observation = nil;
    [observation invalidate];
}

static BOOL TokensMatch(NSDictionary *left, NSDictionary *right) {
    return [left[@"identity"] isKindOfClass:NSString.class] &&
        [left[@"identity"] isEqual:right[@"identity"]] &&
        [left[@"boundary"] isKindOfClass:NSNumber.class] &&
        [left[@"boundary"] isEqual:right[@"boundary"]] &&
        [left[@"generation"] isKindOfClass:NSNumber.class] &&
        [left[@"generation"] isEqual:right[@"generation"]];
}

static BOOL ObservationMatches(RUINAutomaticReadGateState *state, NSManagedObject *chat,
                               id gate, NSDictionary *token) {
    RUINAutomaticReadBoundaryObservation *observation = state.observation;
    return observation.observing && !observation.boundaryChanging && observation.state == state && observation.chat == chat &&
        observation.gate == gate && observation.attachmentGeneration == atomic_load(&state->attachmentGeneration) &&
        [observation.identity isEqual:token[@"identity"]] &&
        [observation.receivedBoundary isEqual:token[@"boundary"]];
}

// Called only from the managed object's owning queue.
static RUINAutomaticReadBoundaryObservation *ObserveBoundary(RUINAutomaticReadGateState *state,
        NSManagedObject *chat, id gate, NSDictionary *token, uint64_t attachmentGeneration) {
    if (atomic_load(&state->attachmentGeneration) != attachmentGeneration) return nil;
    RUINAutomaticReadBoundaryObservation *old = state.observation;
    if (old.observing && old.chat == chat && old.gate == gate &&
        [old.identity isEqual:token[@"identity"]] && old.attachmentGeneration == attachmentGeneration) {
        if (!old.boundaryChanging) old.receivedBoundary = token[@"boundary"];
        return old;
    }
    [old invalidate];
    RUINAutomaticReadBoundaryObservation *observation = [RUINAutomaticReadBoundaryObservation new];
    observation.chat = chat;
    observation.gate = gate;
    observation.state = state;
    observation.identity = token[@"identity"];
    observation.receivedBoundary = token[@"boundary"];
    observation.attachmentGeneration = attachmentGeneration;
    @try {
        [chat addObserver:observation forKeyPath:@"lastReceivedMessageID"
                  options:NSKeyValueObservingOptionPrior | NSKeyValueObservingOptionNew
                  context:&boundaryObservationContext];
        observation.observing = YES;
        if (atomic_load(&state->attachmentGeneration) != attachmentGeneration) {
            [observation invalidate];
            return nil;
        }
        state.observation = observation;
        return observation;
    } @catch (__unused NSException *exception) {
        rejected++;
        return nil;
    }
}

static void QueuePolicySnapshot(RUINAutomaticReadGateState *state,
        id context, NSManagedObject *chat, NSManagedObjectContext *owner, id gate) {
    uint64_t generation = atomic_load(&state->generation);
    uint64_t attachmentGeneration = atomic_load(&state->attachmentGeneration);
    if (state.pending && state.pendingGeneration == generation) return;
    state.pending = YES;
    state.pendingGeneration = generation;

    [owner performBlock:^{
        BOOL identityResolved = NO;
        __block BOOL shouldSuppress = YES;
        NSDictionary *token = @{};
        RUINAutomaticReadBoundaryObservation *observation = nil;
        @try {
            BOOL policySuppresses = RUINShouldSuppressReadForChat(chat);
            identityResolved = policySuppresses || RUINReadPolicyHasIdentity(chat);
            if (identityResolved) {
                shouldSuppress = policySuppresses;
                token = RUINCaptureReadOnReplyToken(chat);
                if (token.count) {
                    observation = ObserveBoundary(state, chat, gate, token, attachmentGeneration);
                    if (!observation) shouldSuppress = YES;
                }
            }
        } @catch (__unused NSException *exception) {
            identityResolved = NO;
            shouldSuppress = YES;
            token = @{};
            rejected++;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL attachmentCurrent = atomic_load(&state->attachmentGeneration) == attachmentGeneration;
            BOOL controllerCurrent = state.context == context && state.chat == chat &&
                state.ownerContext == owner && state.gate == gate;
            BOOL generationCurrent = atomic_load(&state->generation) == generation;
            if (state.pendingGeneration == generation) {
                state.pending = NO;
                state.pendingGeneration = 0;
            }
            if (!attachmentCurrent || !controllerCurrent) {
                if (!attachmentCurrent && state.observation == observation) InvalidateObservation(state);
                return;
            }

            NSDictionary *replyToken = state.pendingReplyToken;
            BOOL exactReplyAllowed = token.count && TokensMatch(replyToken, token) &&
                RUINReadOnReplyTokenIsAllowed(replyToken) && ObservationMatches(state, chat, gate, token);
            if (!generationCurrent) {
                if (exactReplyAllowed) {
                    state.pendingReplyToken = nil;
                    state.policyKnown = YES;
                    state.identityResolved = YES;
                    state.shouldSuppress = NO;
                    RestoreGate(gate);
                }
                return;
            }
            if (![NSUserDefaults.standardUserDefaults boolForKey:RUINReadControlEnabledDefaultsKey]) {
                state.policyKnown = NO;
                state.pendingReplyToken = nil;
                RestoreGate(gate);
                return;
            }

            if (token.count && !ObservationMatches(state, chat, gate, token)) shouldSuppress = YES;
            if (exactReplyAllowed) {
                shouldSuppress = NO;
                state.pendingReplyToken = nil;
            } else if (replyToken && !RUINReadOnReplyTokenIsAllowed(replyToken)) {
                state.pendingReplyToken = nil;
            }
            state.policyKnown = YES;
            state.identityResolved = identityResolved;
            state.shouldSuppress = shouldSuppress;
            if (shouldSuppress) HoldGate(gate); else RestoreGate(gate);
        });
    }];
}

static void Apply(UIViewController *controller, BOOL force) {
    if (!NSThread.isMainThread || !controller) return;
    RUINAutomaticReadGateState *state = StateForController(controller);
    BOOL enabled = [NSUserDefaults.standardUserDefaults boolForKey:RUINReadControlEnabledDefaultsKey];

    // An OFF transition needs no chat lookup: restore the saved native value and
    // invalidate every queued policy result before it can re-hide the gate.
    if (!enabled) {
        BOOL refresh = force || !state.initialized || state.enabled || state.pending;
        if (refresh) {
            atomic_fetch_add(&state->generation, 1);
            atomic_fetch_add(&state->attachmentGeneration, 1);
            state.pending = NO;
            state.pendingGeneration = 0;
            state.policyKnown = NO;
            state.identityResolved = NO;
            state.pendingReplyToken = nil;
            InvalidateObservation(state);
        }
        state.initialized = YES;
        state.enabled = NO;
        RestoreGate(state.gate);
        return;
    }

    id context = RUINCopySwiftField(controller, "chatContext");
    Class contextClass = NSClassFromString(@"_TtC15LineMessagingUI11ChatContext");
    BOOL contextValid = context && object_getClass(context) == contextClass;
    id gate = contextValid ? RUINCopySwiftField(context, "markAsReadController") : nil;
    NSManagedObject *chat = nil;
    Method chatMethod = class_getInstanceMethod(object_getClass(controller), sel_registerName("chat"));
    if (contextValid && gate && chatMethod && !strcmp(method_getTypeEncoding(chatMethod), "@16@0:8")) {
        id candidate = [(id<RUINMessagingChatOwner>)controller chat];
        if ([candidate isKindOfClass:NSManagedObject.class]) chat = candidate;
    }
    NSManagedObjectContext *owner = chat.managedObjectContext;
    BOOL changed = !state.initialized || state.context != context || state.chat != chat ||
        state.ownerContext != owner || state.gate != gate;
    BOOL refresh = force || changed || !state.enabled;

    if (changed && state.gate != gate) RestoreGate(state.gate);
    state.initialized = YES;
    state.enabled = YES;
    state.context = context;
    state.chat = chat;
    state.ownerContext = owner;
    state.gate = gate;

    if (refresh) {
        atomic_fetch_add(&state->generation, 1);
        atomic_fetch_add(&state->attachmentGeneration, 1);
        state.pending = NO;
        state.pendingGeneration = 0;
        state.policyKnown = NO;
        state.identityResolved = NO;
        state.pendingReplyToken = nil;
        InvalidateObservation(state);
    }

    // Keep unknown identities hidden until a queue-confined snapshot proves a
    // matching exception or reply allowance. This write is before native code.
    if (!state.policyKnown || state.shouldSuppress) HoldGate(gate);
    if (!chat || !owner) {
        if (refresh || !state.identityResolved) rejected++;
        return;
    }
    if (refresh || !state.policyKnown || !state.identityResolved)
        QueuePolicySnapshot(state, context, chat, owner, gate);
}

void RUINAllowAutomaticReadForReply(NSDictionary *token) {
    if (!NSThread.isMainThread) {
        NSDictionary *copied = [token copy];
        dispatch_async(dispatch_get_main_queue(), ^{ RUINAllowAutomaticReadForReply(copied); });
        return;
    }
    if (!RUINReadOnReplyTokenIsAllowed(token)) return;
    for (UIViewController *controller in controllers.allObjects) {
        RUINAutomaticReadGateState *state = objc_getAssociatedObject(controller, &controllerStateKey);
        if (!state || !state.enabled) continue;
        RUINAutomaticReadBoundaryObservation *observation = state.observation;
        BOOL matches = ObservationMatches(state, state.chat, state.gate, token);
        if (matches || state.pending) {
            atomic_fetch_add(&state->generation, 1);
            state.pendingReplyToken = [token copy];
            if (matches) {
                state.policyKnown = YES;
                state.identityResolved = YES;
                state.shouldSuppress = NO;
                RestoreGate(observation.gate);
            }
        }
    }
}

void RUINRefreshAutomaticReadGate(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINRefreshAutomaticReadGate(); });
        return;
    }
    for (UIViewController *controller in controllers.allObjects) Apply(controller, YES);
}

%group RUINAutomaticDidLoad
%hook RUINAutomaticChatController
- (void)viewDidLoad {
    Apply((id)self, NO);
    %orig;
    Apply((id)self, NO);
}
%end
%end

%group RUINAutomaticWillAppear
%hook RUINAutomaticChatController
- (void)viewWillAppear:(BOOL)animation {
    Apply((id)self, NO);
    %orig;
    Apply((id)self, NO);
}
%end
%end

%group RUINAutomaticDidAppear
%hook RUINAutomaticChatController
- (void)viewDidAppear:(BOOL)animation {
    Apply((id)self, NO);
    %orig;
    Apply((id)self, NO);
}
%end
%end

void RUINInstallAutomaticReadGate(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ RUINInstallAutomaticReadGate(); });
        return;
    }
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    if (!RUINTargetMetadataMatchesInfo(info)) return;
    if (!controllers) controllers = [NSHashTable weakObjectsHashTable];
    if (!hookStatus) hookStatus = [NSMutableDictionary dictionary];
    Class cls = NSClassFromString(@"_TtC15LineMessagingUI18ChatViewController");
    for (NSString *name in @[@"viewDidLoad", @"viewWillAppear:", @"viewDidAppear:"]) {
        if ([hookStatus[name] isEqual:@"installed"]) continue;
        SEL selector = NSSelectorFromString(name);
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        BOOL animated = [name hasSuffix:@":"];
        const char *types = animated ? "v20@0:8B16" : "v16@0:8";
        if (!method || strcmp(method_getTypeEncoding(method), types)) {
            hookStatus[name] = @"unavailable_or_type_mismatch";
            continue;
        }
        if (!method_getImplementation(method)) { hookStatus[name] = @"missing_implementation"; continue; }
        if ([name isEqual:@"viewDidLoad"]) { %init(RUINAutomaticDidLoad, RUINAutomaticChatController = cls); }
        else if ([name isEqual:@"viewWillAppear:"]) { %init(RUINAutomaticWillAppear, RUINAutomaticChatController = cls); }
        else { %init(RUINAutomaticDidAppear, RUINAutomaticChatController = cls); }
        hookStatus[name] = @"installed";
    }
    RUINRefreshAutomaticReadGate();
}

NSDictionary *RUINAutomaticReadGateDiagnostics(void) {
    return @{@"hooks":[hookStatus copy] ?: @{}, @"applied":@(applied), @"restored":@(restored),
        @"rejected":@(atomic_load(&rejected)), @"receivedBoundaryWillChanges":@(atomic_load(&boundaryWillChanges)),
        @"scope":@"automatic native chat UI guard only; explicit/manual paths are unchanged",
        @"field":@"ChatContext.markAsReadController.isEnabled", @"fieldResolution":@"runtime_ivar", @"peerVerified":@NO};
}
