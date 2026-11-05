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
/** Returns the unwrapped Mirror display kind at a dot-separated path, or for the root when path is nil. */
FOUNDATION_EXPORT NSString * _Nullable RUINCopySwiftFieldKind(id _Nullable object,
    const char * _Nullable fieldPath) NS_RETURNS_RETAINED;
/** Returns the case name for a payloadless enum field (at most 128 UTF-8 bytes), or nil. */
FOUNDATION_EXPORT NSString * _Nullable RUINCopySwiftEnumCaseName(id _Nullable object,
    const char * _Nullable fieldPath) NS_RETURNS_RETAINED;

// LINE26.16 only: exact ChatMarkAsReadController class, Mirror Bool field,
// runtime allocation/ivar and verified offset56. Returns previous 0/1, -1 if rejected.
FOUNDATION_EXPORT int32_t RUINWriteReadControllerEnabled(id _Nullable object, int32_t enabled);

NS_ASSUME_NONNULL_END
