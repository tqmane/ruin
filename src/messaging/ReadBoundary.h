#import <Foundation/Foundation.h>
// Structural pending-receipt filtering is independent of numeric mappings.
// A getter projection is allowed only for a verified pre-send comparison;
// confirmed post-success cursor updaters must leave the native getter intact.
FOUNDATION_EXPORT void RUINInstallReadBoundary(void);
FOUNDATION_EXPORT NSDictionary * _Nonnull RUINReadBoundaryDiagnostics(void);
#if defined(RUIN_BOUNDARY_HOST_CHECK)
struct RUINVersionMapping;
FOUNDATION_EXPORT void RUINBoundaryTestVersionMapping(const struct RUINVersionMapping * _Nullable mapping);
#endif
