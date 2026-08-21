#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"
OUT_DIR="${LUMI_RELEASE_DIR:-$ROOT/dist}"
VERSION="${LUMI_VERSION:-4.0.0rc5}"
BUNDLE_ID="${LUMI_BUNDLE_ID:-app.lumi.desktop}"
SIGN_IDENTITY="${LUMI_CODESIGN_IDENTITY:--}"

mkdir -p "$OUT_DIR"
cd "$APP_DIR"

swift build -c release --product LumiDesktop
BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BIN_DIR/LumiDesktop"

if [[ ! -x "$BINARY" ]]; then
  echo "Release binary not found: $BINARY" >&2
  exit 1
fi

APP="$OUT_DIR/Lumi.app"
ZIP="$OUT_DIR/Lumi-macOS-$VERSION.zip"
rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/LumiDesktop"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Lumi</string>
  <key>CFBundleExecutable</key>
  <string>LumiDesktop</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Lumi</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>${GITHUB_RUN_NUMBER:-1}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "$APP"
echo "$ZIP"
