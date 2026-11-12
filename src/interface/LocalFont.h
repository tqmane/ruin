#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void RUINInstallLocalFont(void);
FOUNDATION_EXPORT BOOL RUINLocalFontIsRegistered(void);
FOUNDATION_EXPORT NSString * _Nullable RUINLocalFontName(void);
FOUNDATION_EXPORT BOOL RUINImportLocalFont(NSURL *url, NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void RUINResetLocalFont(void);
FOUNDATION_EXPORT UIFont * _Nullable RUINLocalFontAtSize(CGFloat size);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RUINLocalFontDiagnostics(void);

NS_ASSUME_NONNULL_END
