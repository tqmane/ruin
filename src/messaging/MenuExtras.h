#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const RUINCopyStickerGIFEnabledDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINCopyMIDEnabledDefaultsKey;
FOUNDATION_EXPORT NSString * const RUINSearchMIDEnabledDefaultsKey;

FOUNDATION_EXPORT void RUINInstallMenuExtras(void);
FOUNDATION_EXPORT NSDictionary *RUINMenuExtrasDiagnostics(void);

/** Call on main while a message long-press menu is visible. Returns runtime class, field-name,
    protocol, selector, and type-encoding metadata only; never reads UI text or object contents. */
FOUNDATION_EXPORT NSDictionary *RUINMenuExtrasRuntimeMenuSignatures(void);

/** Call only from an explicitly selected UI action. Reads a local animated image then. */
FOUNDATION_EXPORT BOOL RUINMenuExtrasCopyAnimatedGIFFromLocalFileURL(NSURL *URL,
                                                                    NSError * _Nullable * _Nullable error);

/** Call only from an explicitly selected UI action. Reads ManagedUser.midString then. */
FOUNDATION_EXPORT BOOL RUINMenuExtrasCopyMIDFromManagedUser(id managedUser,
                                                            NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
