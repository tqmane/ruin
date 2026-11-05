#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Imports one saved, structurally validated .linetheme catalog record into
 LINE's account-bound Theme Packages directory and native theme registry.

 Completion runs on the main queue. `result` is nonnil exactly when the native
 writer returned an object ID, including when a later context merge reports an
 error. A nil result means the database write was not committed.
 Result keys: committed (YES), objectID, packageURL, and metadata.
 */
FOUNDATION_EXPORT void RUINImportDownloadedTheme(
    NSDictionary<NSString *, id> *record,
    void (^completion)(NSDictionary<NSString *, id> * _Nullable result,
                       NSError * _Nullable error));

NS_ASSUME_NONNULL_END
