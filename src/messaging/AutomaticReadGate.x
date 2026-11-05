%config(generator=internal);

#import "AutomaticReadGate.h"
#import "Features.h"
#import "SwiftFields.h"
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Independently verified native automatic guard, not a native function patch:
// ChatContext.markAsReadController.isEnabled (Swift Bool, field offset56).
// Evidence: build/current-native-read-evidence.json, guard0x104122fbc.
static NSHashTable *controllers;
static char originalEnabledKey;
static NSUInteger applied, restored, rejected;
static NSMutableDictionary *hookStatus;

static BOOL Compatible(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    return [info[@"RUINOriginalBundleIdentifier"] isEqual:RUINTargetBundleIdentifier] &&
        [info[@"CFBundleShortVersionString"] isEqual:RUINTargetVersion] &&
        [info[@"CFBundleVersion"] isEqual:RUINTargetBuild];
}
static void Apply(UIViewController *controller) {
    if (!NSThread.isMainThread || !Compatible()) return;
    [controllers addObject:controller];
    id context = RUINCopySwiftField(controller, "chatContext");
    Class contextClass = NSClassFromString(@"_TtC15LineMessagingUI11ChatContext");
    if (!context || object_getClass(context) != contextClass) { rejected++; return; }
    id gate = RUINCopySwiftField(context, "markAsReadController");
    if (!gate) { rejected++; return; }
    BOOL hold = [NSUserDefaults.standardUserDefaults boolForKey:RUINReadControlEnabledDefaultsKey];
    if (hold) {
        SEL selector = sel_registerName("chat");
        Method method = class_getInstanceMethod(object_getClass(controller), selector);
        if (method && !strcmp(method_getTypeEncoding(method), "@16@0:8")) {
            id chat = ((id (*)(id, SEL))objc_msgSend)(controller, selector);
            if ([chat isKindOfClass:NSManagedObject.class]) {
                NSManagedObjectContext *owner = [chat managedObjectContext];
                if (owner) {
                    __block BOOL policy = YES;
                    [owner performBlockAndWait:^{
                        if (RUINReadPolicyHasIdentity(chat)) policy = RUINShouldSuppressReadForChat(chat);
                    }];
                    hold = policy;
                }
            }
        }
    }
    NSNumber *saved = objc_getAssociatedObject(gate, &originalEnabledKey);
    if (hold) {
        int32_t previous = RUINWriteReadControllerEnabled(gate, 0);
        if (previous < 0) { rejected++; return; }
        if (!saved) objc_setAssociatedObject(gate, &originalEnabledKey, @(previous), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        applied++;
    } else if (saved) {
        if (RUINWriteReadControllerEnabled(gate, saved.intValue) < 0) { rejected++; return; }
        objc_setAssociatedObject(gate, &originalEnabledKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        restored++;
    }
}
void RUINRefreshAutomaticReadGate(void) {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ RUINRefreshAutomaticReadGate(); }); return; }
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
    Apply((id)self);
    %orig;
    Apply((id)self);
}
%end
%end

void RUINInstallAutomaticReadGate(void) {
    if (!Compatible()) return;
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
    return @{@"hooks":hookStatus ?: @{}, @"applied":@(applied), @"restored":@(restored), @"rejected":@(rejected),
        @"scope":@"automatic native chat UI guard only; explicit/manual paths and queued work unverified",
        @"field":@"ChatContext.markAsReadController.isEnabled", @"verifiedBoolOffset":@56, @"peerVerified":@NO};
}
