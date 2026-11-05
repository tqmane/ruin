#import <Foundation/Foundation.h>

@class UIViewController;

NS_ASSUME_NONNULL_BEGIN

/**
 Presents a native page sheet. Each row accepts readerID, readAtMilliseconds,
 observedAtMilliseconds, and timeSource (server_event/range/observed/unknown).
 Zero/missing dates stay unknown. Only server_event/range can label a read date;
 observedAtMilliseconds is labeled 確認日時. Uses the device timezone, shown explicitly.
 Names come only from the current chat's cached ManagedUser store. No MID is shown.
 */
FOUNDATION_EXPORT void RUINPresentReadersSheet(UIViewController *source,
                                              NSArray<NSDictionary *> *readers);

/// Optional, user-tapped row action, on main queue. No automatic profile lookup.
/// The callback receives the sheet controller and internal readerID, never displayed.
typedef void (^RUINReaderProfileAction)(UIViewController *sheet, NSString *readerID);
typedef void (^RUINReaderLoadCompletion)(NSArray<NSDictionary *> *readers, NSError * _Nullable error);
typedef void (^RUINReaderLoader)(RUINReaderLoadCompletion completion);
FOUNDATION_EXPORT void RUINPresentReadersSheetWithProfileAction(UIViewController *source,
    NSArray<NSDictionary *> *readers, RUINReaderProfileAction _Nullable profileAction);
FOUNDATION_EXPORT void RUINPresentReadersSheetWithLoader(UIViewController *source,
    NSArray<NSDictionary *> *readers, RUINReaderLoader _Nullable loader,
    RUINReaderProfileAction _Nullable profileAction);

/// Availability/counters only: no reader IDs, names, dates, or field values.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RUINReadersSheetDiagnostics(void);

NS_ASSUME_NONNULL_END
