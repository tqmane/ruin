#import <Foundation/Foundation.h>

// Main queue only. Zero restores LINE's latest native badge verbatim.
FOUNDATION_EXPORT void RUINSetLocalUnreadTabBadgeCorrection(NSUInteger count);
FOUNDATION_EXPORT void RUINInstallLocalUnreadTabBadge(void);
FOUNDATION_EXPORT NSDictionary *RUINLocalUnreadTabBadgeDiagnostics(void);
