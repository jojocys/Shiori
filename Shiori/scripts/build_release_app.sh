#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
VERSION_MANIFEST="$ROOT_DIR/version.json"
APP_NAME="Shiori"
APP_DISPLAY_NAME="栞 Shiori"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_VERSION="${APP_VERSION:-$(/usr/bin/plutil -extract version raw "$VERSION_MANIFEST")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(/usr/bin/plutil -extract build raw "$VERSION_MANIFEST")}"
BUNDLE_ID="${BUNDLE_ID:-com.jojocys.shiori}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://jojocys.github.io/Shiori/appcast.xml}"
SPARKLE_PUBLIC_KEY_FILE="$ROOT_DIR/config/sparkle_public_key.txt"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$(tr -d '[:space:]' < "$SPARKLE_PUBLIC_KEY_FILE")}"
SPARKLE_FRAMEWORK_SOURCE="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
EMBEDDED_WINE_DIR="$RESOURCES_DIR/EmbeddedWine"
INSTALLERS_DIR="$RESOURCES_DIR/Installers"
EMBEDDED_EMULATOR_DIR="$RESOURCES_DIR/EmbeddedEmulator"
EMULATOR_SOURCE_APP="${EMBED_EMULATOR_APP_PATH:-}"
EXECUTABLE_NAME="$APP_NAME"
PACKAGE_BIN="$ROOT_DIR/.build/release/Shiori"
ICON_SOURCE="$ROOT_DIR/assets/Shiori.icns"
ICON_NAME="$APP_NAME.icns"
WINE_SOURCE_APP="${EMBED_WINE_APP_PATH:-}"
XQUARTZ_SOURCE_PKG="${EMBED_XQUARTZ_PKG_PATH:-}"

mkdir -p "$DIST_DIR"

if [[ -z "$APP_VERSION" || -z "$BUILD_NUMBER" || -z "$SPARKLE_PUBLIC_KEY" ]]; then
  echo "Version, build number, and Sparkle public key must not be empty." >&2
  exit 1
fi

if [[ -z "$WINE_SOURCE_APP" ]]; then
  for candidate in \
    "/Applications/Wine Stable.app" \
    "/Applications/Wine.app" \
    "$HOME/Applications/Wine Stable.app" \
    "$HOME/Applications/Wine.app"
  do
    if [[ -d "$candidate" ]]; then
      WINE_SOURCE_APP="$candidate"
      break
    fi
  done
fi

if [[ -z "$WINE_SOURCE_APP" || ! -d "$WINE_SOURCE_APP" ]]; then
  echo "Embedded Wine source app not found." >&2
  echo "Please install Wine first, or set EMBED_WINE_APP_PATH to your Wine.app path." >&2
  exit 1
fi

if [[ -z "$XQUARTZ_SOURCE_PKG" ]]; then
  for candidate in \
    "$HOME/Downloads/XQuartz.pkg" \
    "$HOME/Downloads/XQuartz-2.8.5.pkg" \
    "$HOME/Desktop/XQuartz-2.8.5.pkg" \
    "$HOME/Desktop/XQuartz.pkg"
  do
    if [[ -f "$candidate" ]]; then
      XQUARTZ_SOURCE_PKG="$candidate"
      break
    fi
  done
fi

if [[ -z "$XQUARTZ_SOURCE_PKG" ]]; then
  for candidate in /Volumes/*XQuartz*/*.pkg(N) /Volumes/*xquartz*/*.pkg(N); do
    if [[ -f "$candidate" ]]; then
      XQUARTZ_SOURCE_PKG="$candidate"
      break
    fi
  done
fi

if [[ -z "$XQUARTZ_SOURCE_PKG" || ! -f "$XQUARTZ_SOURCE_PKG" ]]; then
  echo "Embedded XQuartz package not found." >&2
  echo "Please put XQuartz .pkg in Downloads/Desktop, keep the XQuartz DMG mounted, or set EMBED_XQUARTZ_PKG_PATH to the pkg path." >&2
  exit 1
fi

echo "[0/7] Ensuring app icon..."
"$ROOT_DIR/scripts/generate_app_icon.sh"

echo "[1/7] Cleaning build products..."
(cd "$ROOT_DIR" && swift package clean)

echo "[2/7] Building release binary and Sparkle dependency..."
(cd "$ROOT_DIR" && swift build -c release)

if [[ ! -x "$PACKAGE_BIN" ]]; then
  echo "Release binary not found: $PACKAGE_BIN" >&2
  exit 1
fi

if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  echo "Sparkle.framework not found: $SPARKLE_FRAMEWORK_SOURCE" >&2
  exit 1
fi

echo "[3/7] Assembling .app bundle..."
/usr/bin/python3 "$ROOT_DIR/scripts/release.py" record-inputs "$DIST_DIR/build-inputs.json" "$WINE_SOURCE_APP" "$XQUARTZ_SOURCE_PKG" "$EMULATOR_SOURCE_APP"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR" "$EMBEDDED_WINE_DIR" "$INSTALLERS_DIR"
cp "$PACKAGE_BIN" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$ICON_SOURCE" "$RESOURCES_DIR/$ICON_NAME"
if [[ -d "$ROOT_DIR/Resources" ]]; then
  for localization_dir in "$ROOT_DIR"/Resources/*.lproj(N); do
    ditto "$localization_dir" "$RESOURCES_DIR/$(basename "$localization_dir")"
  done
fi
ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$EXECUTABLE_NAME"

echo "[4/7] Embedding Wine runtime..."
WINE_APP_NAME="$(basename "$WINE_SOURCE_APP")"
ditto "$WINE_SOURCE_APP" "$EMBEDDED_WINE_DIR/$WINE_APP_NAME"
if command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$EMBEDDED_WINE_DIR/$WINE_APP_NAME" >/dev/null 2>&1 || true
fi

echo "[5/7] Embedding XQuartz installer..."
cp "$XQUARTZ_SOURCE_PKG" "$INSTALLERS_DIR/XQuartz.pkg"
if command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$INSTALLERS_DIR/XQuartz.pkg" >/dev/null 2>&1 || true
fi

# 可选：内置 Switch 模拟器（由 EMBED_EMULATOR_APP_PATH 提供）。
# 注意：仅内置模拟器本体；绝不打包 prod.keys / 固件 / ROM（版权文件，由用户自备）。
if [[ -n "$EMULATOR_SOURCE_APP" && -d "$EMULATOR_SOURCE_APP" ]]; then
  echo "[5.5/7] Embedding Switch emulator..."
  mkdir -p "$EMBEDDED_EMULATOR_DIR"
  EMULATOR_APP_NAME="$(basename "$EMULATOR_SOURCE_APP")"
  ditto "$EMULATOR_SOURCE_APP" "$EMBEDDED_EMULATOR_DIR/$EMULATOR_APP_NAME"
  if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$EMBEDDED_EMULATOR_DIR/$EMULATOR_APP_NAME" >/dev/null 2>&1 || true
  fi
else
  echo "[5.5/7] EMBED_EMULATOR_APP_PATH 未设置，跳过内置模拟器。"
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string>
    <string>en</string>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>CFBundleIconFile</key>
  <string>$ICON_NAME</string>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <false/>
  <key>SUAllowsAutomaticUpdates</key>
  <false/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
</dict>
</plist>
PLIST

if [[ "$BUNDLE_ID" == "com.jojocys.shiori.update-test" ]]; then
  if [[ -z "${SHIORI_TEST_DATA_DIR:-}" ]]; then
    echo "Test bundle requires an isolated SHIORI_TEST_DATA_DIR." >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Add :ShioriTestingDataDirectory string $SHIORI_TEST_DATA_DIR" "$CONTENTS_DIR/Info.plist"
fi

echo "[6/7] Signing nested code and App..."
/usr/bin/python3 "$ROOT_DIR/scripts/release.py" sign-app "$APP_BUNDLE" --identity "$SIGNING_IDENTITY"
codesign --verify --deep --strict --verbose=1 "$APP_BUNDLE"

echo "[7/7] App ready; run make_dmg.sh to create the release package."
/usr/bin/python3 "$ROOT_DIR/scripts/release.py" verify-inputs "$DIST_DIR/build-inputs.json"
echo "App bundle: $APP_BUNDLE"
echo "Version: $APP_VERSION ($BUILD_NUMBER)"
echo "Bundle ID: $BUNDLE_ID"
echo "Sparkle feed: $SPARKLE_FEED_URL"
