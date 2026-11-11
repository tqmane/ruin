#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void RUINInstallRetainedMedia(void);
FOUNDATION_EXPORT void RUINInstallRetainedVideo(void);
FOUNDATION_EXPORT NSDictionary *RUINRetainedVideoDiagnostics(void);
// Prearchive locally downloaded media while the native object is still live.
FOUNDATION_EXPORT void RUINObserveRetainedMedia(id message, NSDictionary *messageKey);
// Resolved local URL from the same native video view model, bound by message ID.
FOUNDATION_EXPORT void RUINObserveRetainedVideoURL(id message, NSDictionary *messageKey, NSURL *URL);
// Call only at an independently recognized unsend boundary, before native
// cleanup. Opens local sources on the owning context, then copies off-queue.
FOUNDATION_EXPORT void RUINCaptureRetainedMedia(id message, NSDictionary *messageKey);
FOUNDATION_EXPORT NSArray<NSDictionary *> *RUINRetainedMediaItems(NSDictionary *messageKey);
FOUNDATION_EXPORT NSDictionary *RUINRetainedMediaDiagnostics(void);
FOUNDATION_EXPORT NSNotificationName const RUINRetainedMediaDidChangeNotification;
NS_ASSUME_NONNULL_END
