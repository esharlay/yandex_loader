#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h}"
OUTPUT_DIR="${1:-${PROJECT_DIR:h}}"
BUILD_DIR="${YANDEX_LOADER_BUILD_DIR:-$PROJECT_DIR/.build}"
mkdir -p "$OUTPUT_DIR" "$BUILD_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache"
swift build --package-path "$PROJECT_DIR" --disable-sandbox --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security" --scratch-path "$BUILD_DIR" -c release
STAGE_DIR="$(mktemp -d "$BUILD_DIR/app-bundle.XXXXXX")"
APP="$STAGE_DIR/Yandex Loader.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/arm64-apple-macosx/release/YandexLoader" "$APP/Contents/MacOS/YandexLoader"
SPARKLE_FRAMEWORKS=("$BUILD_DIR"/artifacts/**/macos-*/Sparkle.framework(N/))
if (( ${#SPARKLE_FRAMEWORKS} != 1 )); then
    echo "Не найден однозначный путь к Sparkle.framework" >&2; exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "${SPARKLE_FRAMEWORKS[1]}" "$APP/Contents/Frameworks/Sparkle.framework"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.blueeggs.yandexloader</string>
<key>CFBundleName</key><string>Yandex Loader</string>
<key>CFBundleDisplayName</key><string>Yandex Loader</string>
<key>CFBundleExecutable</key><string>YandexLoader</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSDesktopFolderUsageDescription</key><string>Доступ нужен для просмотра и передачи ваших файлов с Рабочего стола.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Доступ нужен для просмотра и передачи ваших документов.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Доступ нужен для просмотра и передачи файлов из Загрузок.</string>
<key>NSRemovableVolumesUsageDescription</key><string>Доступ нужен для работы с файлами на подключённых дисках.</string>
<key>NSNetworkVolumesUsageDescription</key><string>Доступ нужен для работы с файлами на сетевых дисках.</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>Yandex OAuth</string><key>CFBundleURLSchemes</key><array><string>yandexloader</string></array></dict></array>
</dict></plist>
PLIST
python3 - "$PROJECT_DIR/Release.json" "$APP/Contents/Info.plist" <<'PY'
import base64, json, plistlib, re, sys
config = json.load(open(sys.argv[1]))
assert re.fullmatch(r'\d+\.\d+\.\d+', config['version']), 'Invalid release version'
assert config['build'].isdigit() and int(config['build']) > 0, 'Invalid build number'
assert len(base64.b64decode(config['publicKey'], validate=True)) == 32, 'Invalid update key'
assert config['feedURL'].startswith('https://'), 'HTTPS feed required'
with open(sys.argv[2], 'rb') as f: info = plistlib.load(f)
info.update(CFBundleShortVersionString=config['version'], CFBundleVersion=config['build'],
            SUFeedURL=config['feedURL'], SUPublicEDKey=config['publicKey'],
            SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False,
            SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
            SUEnableInstallerLauncherService=False, SUEnableDownloaderService=False,
            SUSendProfileInfo=False, SUScheduledCheckInterval=86400)
with open(sys.argv[2], 'wb') as f: plistlib.dump(info, f)
PY
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/"; fi
cp "$PROJECT_DIR/ThirdParty/Sparkle-LICENSE" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
OUTPUT_APP="$OUTPUT_DIR/Yandex Loader.app"
# Replace the bundle without rewriting the executable of a running copy.
if [ -d "$OUTPUT_APP" ]; then mv "$OUTPUT_APP" "$STAGE_DIR/previous.app"; fi
if mv "$APP" "$OUTPUT_APP"; then
    rm -rf "$STAGE_DIR"
else
    if [ -d "$STAGE_DIR/previous.app" ]; then mv "$STAGE_DIR/previous.app" "$OUTPUT_APP"; fi
    exit 1
fi
echo "Готово: $OUTPUT_APP"
