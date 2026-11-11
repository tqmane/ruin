#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void RUINInstallNativeMuteSend(void);
// Also called by the early configuration installer, before native menu models are created.
FOUNDATION_EXPORT void RUINInstallNativeMuteSettingAdapter(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RUINNativeMuteSendDiagnostics(void);

NS_ASSUME_NONNULL_END
