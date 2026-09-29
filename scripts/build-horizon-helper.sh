#!/bin/sh
set -e
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
BUNDLE="${1:-$ROOT/.local/development/BatchAutoStraighten.lrdevplugin}"
OUT="$BUNDLE/bin/horizon-helper"
CACHE="${TMPDIR:-/tmp}/batch-auto-straighten-swift-module-cache-$$"
mkdir -p "$CACHE"
mkdir -p "$(dirname "$OUT")"
cleanup() {
  rm -rf "$CACHE"
}
trap cleanup EXIT
cp "$ROOT/src/native/HorizonHelper.swift" "$CACHE/main.swift"
# Keep the supported OS floor stable when building on a newer macOS/Xcode.
xcrun swiftc -O -target "$(uname -m)-apple-macos26.0" -module-cache-path "$CACHE" \
  -o "$OUT" \
  "$CACHE/main.swift" "$ROOT/src/native/CameraRoll.swift" "$ROOT/src/native/CropPreview.swift"
chmod +x "$OUT"
echo "$OUT"
