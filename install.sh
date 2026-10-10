#!/bin/bash
# Install or update Bufer from the latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/slavashootit/bufer/main/install.sh | bash
set -euo pipefail

URL="https://github.com/slavashootit/bufer/releases/latest/download/Bufer.zip"
DEST="/Applications"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Завантажую Bufer…"
curl -fsSL "$URL" -o "$TMP/Bufer.zip"
ditto -xk "$TMP/Bufer.zip" "$TMP"

if pgrep -x Bufer >/dev/null; then
    echo "→ Закриваю запущений Bufer…"
    pkill -x Bufer || true
    for _ in $(seq 1 50); do
        pgrep -x Bufer >/dev/null || break
        sleep 0.1
    done
fi

echo "→ Встановлюю в $DEST…"
rm -rf "$DEST/Bufer.app"
ditto "$TMP/Bufer.app" "$DEST/Bufer.app"
# Not signed with a paid Apple certificate: skip the "unidentified developer" prompt.
xattr -dr com.apple.quarantine "$DEST/Bufer.app" 2>/dev/null || true

open "$DEST/Bufer.app"
echo "✓ Готово. Дозволь Bufer доступ Accessibility, щоб клік вставляв запис одразу."
echo "  Історія: ⌘⇧V"
