#pragma once
#import <Foundation/Foundation.h>

// The selectors below were verified in LINE 26.16.0 / 2026.1006.1718.
// Protocol casts describe private ABI without defining or linking LINE classes;
// callers still validate the runtime class, selector and encoding before use.
@protocol RUINLINEManagedChatCalls <NSObject>
- (long long)lastReceivedMessageID;
- (BOOL)isOneOnOneChat;
- (NSInteger)memberCountExcludingMyself;
@end

@protocol RUINLINEManagedUserCalls <NSObject>
- (id)displayUserName;
@end

@protocol RUINLINEChatControllerCalls <NSObject>
- (id)chat;
@end

@protocol RUINLINEAppDelegateCalls <NSObject>
- (BOOL)openURLForObjC:(NSURL *)url;
- (id)lineTabBarControllerManager;
- (id)tabBarController;
@end

@protocol RUINLINEWelcomeCalls <NSObject>
- (void)loginButtonAction;
@end

@protocol RUINLINESecondaryLoginCalls <NSObject>
- (void)showQRCodeLoginButtonPressed;
@end
