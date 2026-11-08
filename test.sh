#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
BUILD_DIR="${YANDEX_LOADER_BUILD_DIR:-$PROJECT_DIR/.build}"
mkdir -p "$BUILD_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache"
swift build --package-path "$PROJECT_DIR" --disable-sandbox --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" --scratch-path "$BUILD_DIR" -c release
SPARKLE_FRAMEWORKS=("$BUILD_DIR"/artifacts/**/macos-*/Sparkle.framework(N/))
if (( ${#SPARKLE_FRAMEWORKS} != 1 )); then echo "Sparkle.framework не найден" >&2; exit 1; fi
SPARKLE_PARENT="${SPARKLE_FRAMEWORKS[1]:h}"
SOURCES=("$PROJECT_DIR"/Sources/YandexLoader/*.swift)
SOURCES=("${(@)SOURCES:#*/main.swift}")
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$BUILD_DIR/clang-cache" -F "$SPARKLE_PARENT" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_PARENT" "${SOURCES[@]}" "$PROJECT_DIR/Checks/LoaderChecks.swift" -o "$BUILD_DIR/LoaderChecks"
"$BUILD_DIR/LoaderChecks"
