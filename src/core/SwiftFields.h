#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Reads an exact, dot-separated Swift Mirror path. Returns the final value as
 an Objective-C object with +1 ownership, or nil for invalid/missing paths.
 Paths are limited to 8 fields, 128 UTF-8 bytes per field, and 1024 bytes total.
 */
FOUNDATION_EXPORT id _Nullable RUINCopySwiftField(id _Nullable object,
                                                   const char * _Nullable fieldPath) NS_RETURNS_RETAINED;

/** Returns immediate stored-field names across the class hierarchy; no values. */
FOUNDATION_EXPORT NSArray<NSString *> * _Nullable RUINCopySwiftFieldNames(id _Nullable object) NS_RETURNS_RETAINED;

/** Reads the stored value's Swift type name before Objective-C boxing; no description call. */
FOUNDATION_EXPORT NSString * _Nullable RUINCopySwiftFieldTypeName(id _Nullable object,
    const char * _Nullable fieldPath) NS_RETURNS_RETAINED;
/** Immediate field names/types at a raw Swift path, without Objective-C boxing. Nil path inspects the root. */
FOUNDATION_EXPORT NSArray<NSDictionary *> * _Nullable RUINCopySwiftFieldInfo(id _Nullable object,
    const char * _Nullable fieldPath) NS_RETURNS_RETAINED;
/** Raw Swift Array element types/stored fields/presence only; no element boxing or values.
 Bounded to 64 elements, 48 fields per node, depth 2, 256 nodes and 2048 field records.
 App custom mirrors are opaque. Invalid paths return nil; partial results mark truncated.
 */
FOUNDATION_EXPORT NSDictionary * _Nullable RUINCopySwiftArrayMetadata(id _Nullable object,
    const char * _Nullable fieldPath) NS_RETURNS_RETAINED;
/** Returns the unwrapped Mirror display kind at a dot-separated path, or for the root when path is nil. */
FOUNDATION_EXPORT NSString * _Nullable RUINCopySwiftFieldKind(id _Nullable object,
    const char * _Nullable fieldPath) NS_RETURNS_RETAINED;
/** Returns the case name for a payloadless enum field (at most 128 UTF-8 bytes), or nil.
 Custom mirrors/descriptions are rejected; lazy storage is read without initialization.
 */
FOUNDATION_EXPORT NSString * _Nullable RUINCopySwiftEnumCaseName(id _Nullable object,
    const char * _Nullable fieldPath) NS_RETURNS_RETAINED;

// Exact ChatMarkAsReadController class and Mirror Bool field; locate the ivar
// through runtime metadata and check allocation bounds. Returns previous 0/1, -1 if rejected.
FOUNDATION_EXPORT int32_t RUINWriteReadControllerEnabled(id _Nullable object, int32_t enabled);

NS_ASSUME_NONNULL_END
