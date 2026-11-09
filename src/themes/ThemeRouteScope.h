#ifndef RUIN_THEME_ROUTE_SCOPE_H
#define RUIN_THEME_ROUTE_SCOPE_H

#include <stdint.h>

#if !defined(__BLOCKS__)
#error "ThemeRouteScope requires Clang block support"
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t (^RUINThemeTaskScopeBody)(void);

int32_t RUINThemeTaskScopeWithValue(
    int32_t kind,
    RUINThemeTaskScopeBody body __attribute__((noescape))
);

int32_t RUINThemeTaskScopeWithRequest(
    int32_t kind,
    uint64_t requestID,
    RUINThemeTaskScopeBody body __attribute__((noescape))
);

int32_t RUINThemeTaskScopeCurrentKind(void);
uint64_t RUINThemeTaskScopeCurrentRequestID(void);

#ifdef __cplusplus
}
#endif

#endif
