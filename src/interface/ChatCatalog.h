#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void RUINInstallChatCatalog(void);
FOUNDATION_EXPORT NSString *RUINChatCatalogAccount(void);
/** Returns copied DTOs on the main queue; unresolved names are omitted. */
FOUNDATION_EXPORT void RUINLoadChatCatalog(void (^completion)(NSArray<NSDictionary *> *items, NSString *account));
FOUNDATION_EXPORT NSDictionary *RUINChatCatalogDiagnostics(void);

NS_ASSUME_NONNULL_END
