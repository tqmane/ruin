#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Fetches only the selected, validated group using the active in-app session.
// Readiness only: no network, diagnostics errors, or history writes. The native
// HTTP-context provider requires captured access/application headers and the
// active account. Fetch still revalidates identity when called and on response.
BOOL RUINCanFetchReadRanges(NSDictionary *messageKey, id _Nullable nativeChat);
void RUINFetchReadRanges(NSDictionary *messageKey, id nativeChat, void (^completion)(NSError * _Nullable error));
NSDictionary *RUINReadRangeFetchDiagnostics(void);
NS_ASSUME_NONNULL_END
