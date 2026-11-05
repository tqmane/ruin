#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Diagnostic-only enqueue before LINE initializes its persisted read-range queue.
void RUINPrepareNativeReadRangeProbe(void);
NSDictionary *RUINNativeReadRangeSyncDiagnostics(void);
// Opt-in RPC capability metadata only; never records headers or payload values.
void RUINObserveNativeReadRangeRequest(NSURLSession *session, NSURLRequest *request);
// Process-memory context only. Caller must scope and revalidate the active account.
NSDictionary * _Nullable RUINCopyNativeReadRangeHTTPContext(void);
NS_ASSUME_NONNULL_END
