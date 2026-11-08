#pragma once
#include <stddef.h>
#include <stdint.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// Only for verified plain native code addresses and Clang function pointers
// using key_function_pointer/discriminator 0; not authenticated Swift/GOT slots.
static inline void *RUINNativeFunctionPointerForCall(uintptr_t rawAddress) {
    if (!rawAddress) return NULL;
#if __has_feature(ptrauth_calls)
    return ptrauth_sign_unauthenticated((void *)rawAddress, ptrauth_key_function_pointer, 0);
#else
    return (void *)rawAddress;
#endif
}

static inline uintptr_t RUINNativeFunctionPointerRaw(const void *functionPointer) {
    if (!functionPointer) return 0;
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip(functionPointer, ptrauth_key_function_pointer);
#else
    return (uintptr_t)functionPointer;
#endif
}
