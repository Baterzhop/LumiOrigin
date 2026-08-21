#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS packaging requires Darwin." >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
APP="$OUT/Lumi.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

pushd "$ROOT/apps/macos" >/dev/null
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
popd >/dev/null

cp "$BIN_DIR/LumiDesktop" "$APP/Contents/MacOS/LumiDesktop"
chmod 755 "$APP/Contents/MacOS/LumiDesktop"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>LumiDesktop</string>
  <key>CFBundleIdentifier</key><string>ai.lumi.desktop.alpha</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Lumi</string>
  <key>CFBundleDisplayName</key><string>Lumi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>4.0.0-alpha.6</string>
  <key>CFBundleVersion</key><string>406</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Alpha packages are ad-hoc signed for local testing. Distribution requires Developer ID + notarization.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$OUT"
rm -f "$OUT/Lumi-macOS-alpha.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Lumi-macOS-alpha.zip"

echo "$OUT/Lumi-macOS-alpha.zip"
