#include "ThemeRouteScope.h"

int32_t RUINThemeRouteScopeHostBridgeCheck(void)
{
    for (int32_t kind = 1; kind <= 3; kind++) {
        __block int32_t calls = 0;
        int32_t expected = 1000 + kind;
        int32_t result = RUINThemeTaskScopeWithValue(kind, ^int32_t{
            calls++;
            return RUINThemeTaskScopeCurrentKind() == kind &&
                           RUINThemeTaskScopeCurrentRequestID() == 0
                       ? expected
                       : -1;
        });
        if (result != expected || calls != 1 || RUINThemeTaskScopeCurrentKind() != 0 ||
            RUINThemeTaskScopeCurrentRequestID() != 0)
            return 1;

        __block int32_t requestCalls = 0;
        uint64_t requestID = UINT64_C(0x1234000000000000) + (uint64_t)kind;
        int32_t requestResult = RUINThemeTaskScopeWithRequest(kind, requestID, ^int32_t{
            requestCalls++;
            return RUINThemeTaskScopeCurrentKind() == kind &&
                           RUINThemeTaskScopeCurrentRequestID() == requestID
                       ? expected
                       : -1;
        });
        if (requestResult != expected || requestCalls != 1 ||
            RUINThemeTaskScopeCurrentKind() != 0 || RUINThemeTaskScopeCurrentRequestID() != 0)
            return 2;
    }

    const struct {
        int32_t kind;
        uint64_t requestID;
    } invalidScopes[] = {{99, 7}, {2, 0}, {0, 0}};
    for (unsigned long i = 0; i < sizeof(invalidScopes) / sizeof(invalidScopes[0]); i++) {
        __block int32_t calls = 0;
        int32_t result = RUINThemeTaskScopeWithRequest(
            invalidScopes[i].kind, invalidScopes[i].requestID, ^int32_t{
                calls++;
                return RUINThemeTaskScopeCurrentKind() == 0 &&
                               RUINThemeTaskScopeCurrentRequestID() == 0
                           ? -1234567
                           : 1;
            });
        if (result != -1234567 || calls != 1 || RUINThemeTaskScopeCurrentKind() != 0 ||
            RUINThemeTaskScopeCurrentRequestID() != 0)
            return 3;
    }

    __block int32_t outerCalls = 0;
    __block int32_t innerCalls = 0;
    int32_t nested = RUINThemeTaskScopeWithRequest(1, 111, ^int32_t{
        outerCalls++;
        int32_t inner = RUINThemeTaskScopeWithRequest(2, 222, ^int32_t{
            innerCalls++;
            return RUINThemeTaskScopeCurrentKind() == 2 &&
                           RUINThemeTaskScopeCurrentRequestID() == 222
                       ? 73
                       : -73;
        });
        int32_t kindOnly = RUINThemeTaskScopeWithValue(3, ^int32_t{
            return RUINThemeTaskScopeCurrentKind() == 3 &&
                           RUINThemeTaskScopeCurrentRequestID() == 0
                       ? 74
                       : -74;
        });
        return inner == 73 && kindOnly == 74 &&
                       RUINThemeTaskScopeCurrentKind() == 1 &&
                       RUINThemeTaskScopeCurrentRequestID() == 111
                   ? 75
                   : -75;
    });
    if (nested != 75 || outerCalls != 1 || innerCalls != 1 ||
        RUINThemeTaskScopeCurrentKind() != 0 || RUINThemeTaskScopeCurrentRequestID() != 0)
        return 4;

    return 0;
}
