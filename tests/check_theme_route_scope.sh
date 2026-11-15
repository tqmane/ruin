#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/theme-route-scope-tests"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$OUT"

xcrun --sdk macosx clang -isysroot "$MACOS_SDK" -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -I"$ROOT/src/themes" -c "$ROOT/tests/check_theme_route_scope.m" \
    -o "$OUT/check_theme_route_scope-host.o"
xcrun swiftc -parse-as-library -module-name ThemeRouteScopeHostTest \
    "$ROOT/src/themes/ThemeRouteScope.swift" "$ROOT/tests/check_theme_route_scope.swift" \
    "$OUT/check_theme_route_scope-host.o" -o "$OUT/check_theme_route_scope-host"
codesign --force --sign - "$OUT/check_theme_route_scope-host"
"$OUT/check_theme_route_scope-host"

for ARCH in arm64 arm64e; do
    xcrun --sdk iphoneos swiftc -sdk "$IOS_SDK" -target "$ARCH-apple-ios18.0" \
        -parse-as-library -whole-module-optimization -O -module-name RUINRuntime \
        -emit-object "$ROOT/src/themes/ThemeRouteScope.swift" \
        -o "$OUT/ThemeRouteScope-$ARCH.o"
done

echo "PASS: host fixture and iOS arm64/arm64e objects in $OUT"
