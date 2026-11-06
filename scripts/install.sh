#!/bin/bash
# Builds the app and installs it to ~/Applications on the startup disk.
# The app must not run from an external drive, or it would keep that drive busy.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x UnplugTray 2>/dev/null || true
rm -rf "$DEST/Unplug Tray.app"
ditto "build/Unplug Tray.app" "$DEST/Unplug Tray.app"
open "$DEST/Unplug Tray.app"
echo "Installed to $DEST/Unplug Tray.app"
