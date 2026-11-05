#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Fetches only the selected, validated group using the active in-app session.
void RUINFetchReadRanges(NSDictionary *messageKey, id nativeChat, void (^completion)(NSError * _Nullable error));
NSDictionary *RUINReadRangeFetchDiagnostics(void);
NS_ASSUME_NONNULL_END
