#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void InstallRuntimeInspector(void);
/** Coalesced in-process inspection, enabled only by the runtime-inspector flag; writes bounded appTabMetadata to ui-inspection.json. */
FOUNDATION_EXPORT void RUINRequestRuntimeSnapshot(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RuntimeInspectorDiagnostics(void);
/** Debug-only native theme package/return-PC metadata; no theme state is changed. */
FOUNDATION_EXPORT void RUINRecordThemePackageInspection(id package, NSString *phase);
FOUNDATION_EXPORT void RUINRecordNativeThemeFetchInspection(id request, id effectiveRequest, NSUInteger count);

NS_ASSUME_NONNULL_END
