#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${LUMI_RELEASE_DIR:-$ROOT/dist}"
VERSION="${LUMI_VERSION:-4.0.0rc5}"
SIGN_IDENTITY="${LUMI_CODESIGN_IDENTITY:-}"
NOTARY_PROFILE="${LUMI_NOTARY_PROFILE:-}"
APP="$OUT_DIR/Lumi.app"
ZIP="$OUT_DIR/Lumi-macOS-$VERSION.zip"
CHECKSUM="$ZIP.sha256"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Apple notarization must run on macOS." >&2
  exit 2
fi
if [[ -z "$SIGN_IDENTITY" || "$SIGN_IDENTITY" == "-" ]]; then
  echo "Set LUMI_CODESIGN_IDENTITY to a valid Developer ID Application identity." >&2
  exit 2
fi
if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Set LUMI_NOTARY_PROFILE to a notarytool Keychain profile created with 'xcrun notarytool store-credentials'." >&2
  exit 2
fi
for tool in xcrun codesign spctl ditto shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool not found: $tool" >&2; exit 2; }
done

export LUMI_CODESIGN_IDENTITY="$SIGN_IDENTITY"
export LUMI_VERSION="$VERSION"
export LUMI_RELEASE_DIR="$OUT_DIR"
bash "$ROOT/scripts/build_macos_app.sh"

codesign --verify --deep --strict --verbose=2 "$APP"

# notarytool accepts the ZIP as the upload container. Credentials stay in the
# macOS Keychain profile and are never placed in process arguments or repository files.
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Repackage after stapling so the distributed archive contains the ticket.
rm -f "$ZIP" "$CHECKSUM"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(
  cd "$OUT_DIR"
  shasum -a 256 "$(basename "$ZIP")" > "$(basename "$CHECKSUM")"
  shasum -a 256 -c "$(basename "$CHECKSUM")"
)

printf 'Notarized app: %s\n' "$APP"
printf 'Release archive: %s\n' "$ZIP"
printf 'Checksum: %s\n' "$CHECKSUM"
