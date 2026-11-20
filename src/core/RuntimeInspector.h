#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void InstallRuntimeInspector(void);
/** Coalesced in-process inspection, enabled only by the runtime-inspector flag; writes bounded appTabMetadata to ui-inspection.json. */
FOUNDATION_EXPORT void RUINRequestRuntimeSnapshot(void);
/** User-triggered composer inspection from RUIN Settings > Diagnostics; captures input-bar buttons and panel candidates (hidden views included) into RuntimeInspectorDiagnostics. */
FOUNDATION_EXPORT void RUINRunUIExtraction(void);
FOUNDATION_EXPORT void RUINInstallUIExtractionButton(void);
FOUNDATION_EXPORT void RUINRefreshUIExtractButton(void);
FOUNDATION_EXPORT NSString * const RUINUIExtractButtonEnabledDefaultsKey;
/** The most recent composer inspection captured by RUINRunUIExtraction, or nil. */
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable RUINComposerInspectionResult(void);
/** Installs the always-visible top-right UI inspection button; tapping it captures the live UI and opens the share sheet without persisting the result. */
FOUNDATION_EXPORT NSDictionary<NSString *, id> *RuntimeInspectorDiagnostics(void);
/** Debug-only native theme package/return-PC metadata; no theme state is changed. */
FOUNDATION_EXPORT void RUINRecordThemePackageInspection(id package, NSString *phase);
FOUNDATION_EXPORT void RUINRecordNativeThemeFetchInspection(id request, id effectiveRequest, NSUInteger count);

NS_ASSUME_NONNULL_END
