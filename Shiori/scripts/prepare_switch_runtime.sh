#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_APP="$1"
ICON_SOURCE="$2"
PLIST="$RUNTIME_APP/Contents/Info.plist"
MACOS_DIR="$RUNTIME_APP/Contents/MacOS"
ORIGINAL_EXECUTABLE="$(/usr/bin/plutil -extract CFBundleExecutable raw "$PLIST")"
# This adapter targets Ryujinx/Avalonia only. External launch scripts and other
# emulator implementations retain their own presentation policy.
if [[ "$ORIGINAL_EXECUTABLE" != "Ryujinx" && "$ORIGINAL_EXECUTABLE" != "ShioriSwitch" ]]; then
  echo "Dock adapter skipped for $ORIGINAL_EXECUTABLE"
  exit 0
fi
[[ -x "$MACOS_DIR/Ryujinx" ]]
clang -dynamiclib -fobjc-arc -framework AppKit -arch arm64 -arch x86_64 \
  -mmacosx-version-min=13.0 "$ROOT_DIR/Native/SwitchDock.m" \
  -o "$MACOS_DIR/libShioriSwitchDock.dylib"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  "$ROOT_DIR/Native/SwitchLauncher.c" -o "$MACOS_DIR/ShioriSwitch"
# Sign new nested code before CFBundleExecutable starts identifying the wrapper.
# The final release signer replaces these preliminary signatures.
codesign --force --sign - --timestamp=none "$MACOS_DIR/libShioriSwitchDock.dylib"
codesign --force --sign - --timestamp=none "$MACOS_DIR/ShioriSwitch"
cp "$ICON_SOURCE" "$RUNTIME_APP/Contents/Resources/Shiori.icns"
/usr/bin/python3 - "$PLIST" <<'PY'
import plistlib,sys
from pathlib import Path
p=Path(sys.argv[1]);d=plistlib.loads(p.read_bytes())
d.update(CFBundleExecutable='ShioriSwitch',CFBundleDisplayName='Shiori Switch',
         CFBundleName='Shiori Switch',CFBundleIconFile='Shiori.icns',
         LSUIElement=True,ShioriManagedSwitchRuntime=True)
p.write_bytes(plistlib.dumps(d))
PY
# The enclosing release signer signs these new Mach-O files and the bundle.
