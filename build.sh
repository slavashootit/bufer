#!/bin/bash
# Build Bufer.app from the Swift package, install it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Bufer"

APP=build/Bufer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Bufer"
cp Info.plist "$APP/Contents/Info.plist"

# A stable signing identity keeps the Accessibility permission across rebuilds.
# Ad-hoc signing changes the signature every build, so macOS silently drops it.
# Order: $BUFER_SIGN_IDENTITY, an "Apple Development" cert, a self-signed "Bufer Dev" cert.
IDENTITY="${BUFER_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ && !found { print $2; found = 1 }' || true)"
fi
if [ -z "$IDENTITY" ] && security find-certificate -c "Bufer Dev" >/dev/null 2>&1; then
    IDENTITY="Bufer Dev"
fi
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc: after each rebuild re-add Bufer in Accessibility settings."
    echo "To fix for good, create a 'Bufer Dev' code signing certificate (see README)."
fi

# Quit the running copy and wait until it is gone, otherwise `open` fails with -600.
pkill -x Bufer 2>/dev/null || true
for _ in $(seq 1 50); do
    pgrep -x Bufer >/dev/null || break
    sleep 0.1
done

# Install where the app already lives: /Applications if it was moved there, else ~/Applications.
if [ -d /Applications/Bufer.app ]; then
    DEST=/Applications
else
    DEST="$HOME/Applications"
fi
mkdir -p "$DEST"
rm -rf "$DEST/Bufer.app"
cp -R "$APP" "$DEST/"
open "$DEST/Bufer.app" || { sleep 1; open "$DEST/Bufer.app"; }
echo "Installed: $DEST/Bufer.app"
