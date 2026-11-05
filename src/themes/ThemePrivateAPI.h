#ifndef RUIN_THEME_PRIVATE_API_H
#define RUIN_THEME_PRIVATE_API_H

#import <Foundation/Foundation.h>

// Signatures verified against LINE 26.16.0 / 2026.1006.1718. Installation
// still checks the concrete runtime class and each selector's exact encoding.
@interface LineShopProductDetail : NSObject
- (id)type;
- (_Bool)isOwned;
- (_Bool)isGrantedByDefault;
- (_Bool)isAvailableForMyself;
- (int64_t)validUntil;
- (int)priceTier;
- (id)priceInLineCoin;
- (id)customDownloadButtonLabel;
- (void)read:(id)reader;
@end

@interface LineShopProductValidationResult : NSObject
- (_Bool)isValidated;
@end

// These names are Logos aliases; %init binds them to verified Swift classes.
@interface RUINThemeApplyClient : NSObject
- (void)didApplyPackage:(id)event;
- (void)didFailToApplyPackage:(id)event;
@end

@interface RUINThemeDefaultsStore : NSUserDefaults
@end

typedef void (^RUINNativeTaskCompletion)(NSData *, NSURLResponse *, NSError *);
typedef void (^RUINNativeDownloadTaskCompletion)(NSURL *, NSURLResponse *, NSError *);

@interface RUINThemeURLSession : NSURLSession
- (id)_dataTaskWithRequest:(NSURLRequest *)request delegate:(id)delegate;
- (id)_dataTaskWithURL:(NSURL *)URL delegate:(id)delegate;
- (id)_dataTaskWithRequest:(NSURLRequest *)request delegate:(id)delegate completionHandler:(RUINNativeTaskCompletion)completion;
- (id)_dataTaskWithURL:(NSURL *)URL delegate:(id)delegate completionHandler:(RUINNativeTaskCompletion)completion;
- (id)_downloadTaskWithRequest:(NSURLRequest *)request delegate:(id)delegate completionHandler:(RUINNativeDownloadTaskCompletion)completion;
- (id)_downloadTaskWithURL:(NSURL *)URL delegate:(id)delegate completionHandler:(RUINNativeDownloadTaskCompletion)completion;
@end

@protocol RUINThemeURLRouting <NSObject>
- (_Bool)openURLForObjC:(NSURL *)URL;
@end

@protocol RUINThemeResetAction <NSObject>
- (void)didTapResetButton;
@end

@protocol RUINThemeAccountLevelReading <NSObject>
+ (_Bool)isPrimary;
@end

#endif
