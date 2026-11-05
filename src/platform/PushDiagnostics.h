#import <Foundation/Foundation.h>

// Read-only notification status. Does not request permission or register a token.
void RUINRefreshPushDiagnostics(void);
NSDictionary *RUINPushDiagnostics(void);
