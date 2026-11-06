#pragma once

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <TargetConditionals.h>

// Private selectors verified against LINE 26.16.0 / 2026.1006.1718. Callers
// retain their runtime encoding checks; these declarations give ARC and the
// compiler the message signatures without linking to LINE's private classes.
@protocol RUINMessagingChatOwner <NSObject>
- (id)chat;
@end

@protocol RUINMessagingMessageFields <NSObject>
- (id)chatObject;
- (id)contentMetadataDictionary;
- (id)plaintext;
@end

@protocol RUINMessagingOperationFields <NSObject>
- (long long)type;
- (long long)createdTime;
- (id)param1;
- (id)param2;
- (id)param3;
@end

@protocol RUINMessagingUserFields <NSObject>
- (id)mid;
- (id)midString;
- (id)displayUserName;
@end

@protocol RUINMessagingUnsendKeys <NSObject>
+ (id)UNSENT;
+ (id)SILENTLY_UNSENT;
@end

// These names are compile-time aliases, bound to the actual runtime Class in
// each guarded %init. No alias classes are registered in the target process.
@interface RUINReplyTalk : NSManagedObject <RUINMessagingMessageFields>
- (void)addNotificationOfSentMessage;
- (void)sendWithCompletionHandler:(id)completion;
@end
@interface RUINReplySquare : NSManagedObject <RUINMessagingMessageFields>
- (void)addNotificationOfSentMessage;
- (void)sendWithCompletionHandler:(id)completion;
@end
@interface RUINReadUsersOperation : NSObject <RUINMessagingOperationFields>
- (void)read:(id)protocol;
@end
@interface RUINHistoryMessage : NSManagedObject <RUINMessagingMessageFields> @end
@interface RUINHistorySquareMessage : NSManagedObject <RUINMessagingMessageFields> @end
@interface RUINHistoryReadRange : NSObject
- (void)read:(id)protocol;
- (id)ranges;
@end
@interface RUINUnsendParsedOperation : NSObject <RUINMessagingOperationFields> @end
@interface RUINUnsendDisplayedMessage : NSManagedObject <RUINMessagingMessageFields>
- (id)displayedText;
@end
@interface RUINRetainTalk : NSManagedObject <RUINMessagingMessageFields>
- (id)displayedText;
@end
@interface RUINRetainSquare : NSManagedObject <RUINMessagingMessageFields>
- (id)displayedText;
@end
@interface RUINRetainTransport : NSObject
- (void)setContentMetadata:(id)metadata;
- (void)read:(id)protocol;
@end
@interface RUINBoundaryExistingAccessor : NSManagedObject
- (long long)readUpToMessageIDSynced;
@end
@interface RUINBoundaryMissingAccessor : NSManagedObject
- (long long)readUpToMessageIDSynced;
@end

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>

@protocol RUINMessagingLegacyMenuController <NSObject>
+ (id)sharedMenuController;
- (BOOL)isMenuVisible;
- (id)menuItems;
@end
@protocol RUINMessagingLegacyMenuItem <NSObject>
- (SEL)action;
- (id)target;
@end

@interface RUINAutomaticChatController : UIViewController <RUINMessagingChatOwner> @end
@interface RUINMenuInteraction : NSObject
- (void)handleLongPressGesture:(id)gesture;
@end
@interface RUINMenuCallout : UIView
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section;
- (id)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath;
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath;
@end
@interface RUINMenuContainer : UIView @end
@interface RUINUnsendMarkerCell : UICollectionViewCell @end
#endif
