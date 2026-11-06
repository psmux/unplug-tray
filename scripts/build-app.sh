#!/bin/bash
# Builds "build/Unplug Tray.app" (universal, ad hoc signed unless SIGN_IDENTITY is set).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/UnplugTray"

APP="build/Unplug Tray.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/UnplugTray"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
