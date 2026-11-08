#import <CoreData/CoreData.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL RUINIsRegisteredNativeThemeID(NSString *productID);

/// Installs the native context capture hook after target and method ABI checks.
FOUNDATION_EXPORT void RUINInstallNativeThemeRegistrationCapture(void);

/// YES once a writable native OwnedThemeProduct context in the current app's
/// Application Support directory has been captured. Packages use a separate
/// mapped app-group root.
FOUNDATION_EXPORT BOOL RUINNativeThemeRegistrationAvailable(void);

/// Opaque in-process account/store identity; contains no account identifier.
FOUNDATION_EXPORT id _Nullable RUINNativeThemeRegistrationScopeToken(void);

/// Returns the validated current-account package directory in LINE's mapped
/// app-group container. This is a URL lookup only; it creates no directory or
/// files. The directory is under `PrivateStore/<account>/Theme Packages/<UUID>`.
/// Completion runs on the registration worker queue.
FOUNDATION_EXPORT void RUINNativeThemeRegistrationPackageURL(
    NSString *productID,
    void (^completion)(NSURL * _Nullable packageURL, NSError * _Nullable error));

/// Upserts public theme metadata into the captured native store. Metadata keys:
/// productID (UUID string), name (1...256 characters), rawVersion (positive
/// integer NSNumber), versionString, imagePath (native public image path), and
/// optional productAvailability (NSNumber matching Theme 2's integer16 field).
/// `isNewRUINLocalTheme` grants local ownership only when a new row is inserted;
/// standard native rows retain their ownership, grant, and validity fields.
/// Local archive rows with a negative defaultOrder are not preinstalled grants.
/// Pass the package directory returned by RUINNativeThemeRegistrationPackageURL;
/// registration rejects it if the captured account changes during staging.
/// Completion runs on the registration worker queue after the writer save and
/// native-context merge attempt. A nonnil objectID and persistedMetadata mean
/// the writer committed the metadata, even if error reports that merging it
/// into the captured native context failed. A nil objectID means no write was
/// committed. A committed objectID does not mean the theme has been applied.
FOUNDATION_EXPORT void RUINRegisterNativeThemeMetadata(
    NSDictionary<NSString *, id> *metadata,
    BOOL isNewRUINLocalTheme,
    NSURL *stagedPackageURL,
    void (^completion)(NSManagedObjectID * _Nullable objectID,
                       NSDictionary<NSString *, id> * _Nullable persistedMetadata,
                       NSError * _Nullable error));

#if defined(RUIN_NATIVE_THEME_REGISTRATION_HOST_CHECK)
/// Test-only seam: capture an injected fixture context using production guards.
FOUNDATION_EXPORT BOOL RUINNativeThemeRegistrationCaptureContextForTesting(
    NSManagedObjectContext *context);
FOUNDATION_EXPORT void RUINNativeThemeRegistrationSetGroupContainerForTesting(
    NSURL * _Nullable containerURL);
/// The app's Application Support directory itself; nil simulates unavailability.
FOUNDATION_EXPORT void RUINNativeThemeRegistrationSetApplicationSupportForTesting(
    NSURL * _Nullable applicationSupportURL);
#endif

NS_ASSUME_NONNULL_END
