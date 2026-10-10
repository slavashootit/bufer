#!/bin/bash
# Build a universal (Apple Silicon + Intel) Bufer.app and pack it as dist/Bufer.dmg and dist/Bufer.zip.
# Usage: scripts/package.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-}"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Bufer"

rm -rf dist
APP=dist/Bufer.app
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Bufer"
cp Info.plist "$APP/Contents/Info.plist"
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

# Ad-hoc signature: required to run on Apple Silicon. Without an Apple Developer ID
# macOS asks once to confirm the first launch (see README).
codesign --force --sign - "$APP"

ditto -c -k --keepParent "$APP" dist/Bufer.zip

STAGE=dist/dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Bufer -srcfolder "$STAGE" -ov -format UDZO dist/Bufer.dmg
rm -rf "$STAGE"
echo "Packed: dist/Bufer.dmg, dist/Bufer.zip"
