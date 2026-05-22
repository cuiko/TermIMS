#!/usr/bin/env bash
# Build the SPM target, then assemble a TermIMS.app bundle in build/.
# Mirrors notchnotes' Scripts/package-app.sh layout: SPM builds the binary,
# this script wraps it with Info.plist + an .icns generated from
# Resources/AppIcon.png, and ad-hoc signs the result.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/TermIMS.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SOURCE_ICON="$ROOT_DIR/Resources/AppIcon.png"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/release/TermIMS" "$MACOS_DIR/TermIMS"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

if [[ -f "$SOURCE_ICON" ]]; then
  TMP_DIR="$(mktemp -d)"
  ICONSET_DIR="$TMP_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"
  sips -z 16 16     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png"     >/dev/null
  sips -z 32 32     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png"  >/dev/null
  sips -z 32 32     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png"     >/dev/null
  sips -z 64 64     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png"  >/dev/null
  sips -z 128 128   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png"   >/dev/null
  sips -z 256 256   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png"   >/dev/null
  sips -z 512 512   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png"   >/dev/null
  sips -z 1024 1024 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
  rm -rf "$TMP_DIR"
fi

codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null
echo "Built → $APP_DIR"
