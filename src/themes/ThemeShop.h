#import <Foundation/Foundation.h>

@class UIViewController;

NS_ASSUME_NONNULL_BEGIN

/**
 User-initiated request to open LINE's native theme shop from a visible source
 in the existing navigation stack. Uses the fixed line://shop/theme URL through
 the current in-process AppDelegate bridge. No external URL fallback is used.
 Native route acceptance does not confirm that the shop loaded or a theme was
 downloaded/applied. Background callers are forwarded to the main queue.
 On the verified LINE build, installs a defaults-read adapter for the native
 theme capability effect and shared shop-router eligibility. The adapter checks
 the native caller chain and plaintext read mode; it does not write account state.
 */
FOUNDATION_EXPORT void RUINOpenThemeShop(UIViewController *source);
FOUNDATION_EXPORT void RUINOpenStickerShop(UIViewController *source);

/** Install the exact-build stylesheet persistence adapter at dylib startup. */
FOUNDATION_EXPORT void RUINInstallThemePersistenceAdapter(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RUINThemePersistenceDiagnostics(void);

/** Fixed capability/status codes and request counters; no account or product data. */
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RUINThemeShopDiagnostics(void);

NS_ASSUME_NONNULL_END
