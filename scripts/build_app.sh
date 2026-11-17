#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG="${1:-release}"
EXEC_NAME="GiveMyRamBack"
APP_DISPLAY_NAME="Give my ram back"
APP_BUNDLE="$ROOT_DIR/$APP_DISPLAY_NAME.app"

echo "Building $APP_DISPLAY_NAME ($CONFIG)..."
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN_PATH="$BIN_DIR/$EXEC_NAME"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "Error: executable not found at $BIN_PATH" >&2
    exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
ICNS_PATH="$TMP_DIR/AppIcon.icns"

echo "Generating AppIcon.icns..."
swift "$ROOT_DIR/scripts/generate_icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$EXEC_NAME"
cp "$ROOT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ICNS_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "Built bundle: $APP_BUNDLE"
