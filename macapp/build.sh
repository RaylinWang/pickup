#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Pickup"
APP_BUNDLE="build/${APP_NAME}.app"

echo "▶ swift build --configuration release"
swift build --configuration release --arch arm64

BIN_PATH=".build/release/${APP_NAME}"
[ -f "$BIN_PATH" ] || { echo "binary not found at $BIN_PATH"; exit 1; }

echo "▶ packaging ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
cp "$BIN_PATH" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Info.plist "${APP_BUNDLE}/Contents/Info.plist"

mkdir -p "${APP_BUNDLE}/Contents/Resources/sessiontracker-cli"
cp ../cli.py ../db.py "${APP_BUNDLE}/Contents/Resources/sessiontracker-cli/"
rm -rf "${APP_BUNDLE}/Contents/Resources/sessiontracker-cli/adapters"
cp -R ../adapters "${APP_BUNDLE}/Contents/Resources/sessiontracker-cli/adapters"
find "${APP_BUNDLE}/Contents/Resources/sessiontracker-cli" -name "__pycache__" -type d -prune -exec rm -rf {} +

if [ -f AppIcon.icns ]; then
    cp AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    echo "✓ embedded AppIcon.icns"
fi

# ad-hoc sign so TCC sees a stable cdhash across rebuilds with the same source.
codesign --force --deep --sign - "${APP_BUNDLE}" >/dev/null 2>&1 || true

echo "✓ built: $(pwd)/${APP_BUNDLE}"
echo ""
echo "to install:"
echo "  pkill -x ${APP_NAME} 2>/dev/null"
echo "  rm -rf /Applications/${APP_NAME}.app"
echo "  cp -R ${APP_BUNDLE} /Applications/"
echo "  open /Applications/${APP_NAME}.app"
