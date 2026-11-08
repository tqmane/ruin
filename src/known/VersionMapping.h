#pragma once

#import "KnownMappings.h"
#import "ThemeMappings.h"
#import "MessagingMappings.h"
#import "NativeTabMappings.h"

typedef struct RUINVersionMapping {
    RUINHostIdentity host;
    RUINThemeMappings themes;
    RUINMessagingMapping messaging;
    RUINNativeTabMapping nativeTabs;
} RUINVersionMapping;

extern const RUINVersionMapping RUINLINE26160;
extern const RUINVersionMapping RUINLINE26170;
