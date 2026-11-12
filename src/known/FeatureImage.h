#pragma once
#import "BinaryVerifier.h"

// Feature-local image proof. This does not relax the process-main verifier used
// by signing, storage or authentication adapters. Release after a failed install;
// keep the loader reference while a published witness can call into this image.
typedef struct {
    RUINMainExecutableImage image;
    uint32_t fileType;
    BOOL convertedExecutable;
    void *loaderReference;
} RUINFeatureImage;

FOUNDATION_EXPORT BOOL RUINResolveFeatureImage(const RUINHostIdentity *host,
    const void *originalImplementation, RUINFeatureImage *result);
FOUNDATION_EXPORT void RUINReleaseFeatureImage(RUINFeatureImage *image);
FOUNDATION_EXPORT BOOL RUINFeatureImageMatches(const RUINFeatureImage *image,
    const RUINHostIdentity *host);
FOUNDATION_EXPORT BOOL RUINReadFeatureImageBytes(const RUINFeatureImage *image,
    uintptr_t address, void *output, size_t length, const char *segmentName);
FOUNDATION_EXPORT BOOL RUINVerifyFeatureInstructions(const RUINFeatureImage *image,
    const RUINInstructionAnchor *anchors, size_t count);

// The runtime supplies both canonical paths from independent owners: the bundle
// executable and dladdr(original LINE implementation). Only an LC conversion
// shape may differ from the process executable path.
FOUNDATION_EXPORT BOOL RUINResolveFeatureImageFromCandidates(const RUINHostIdentity *host,
    const char *bundleExecutable, const char *processExecutable, const char *ownerExecutable,
    const struct mach_header_64 *ownerHeader, const RUINDyldImageCandidate *candidates,
    size_t count, RUINFeatureImage *result);
