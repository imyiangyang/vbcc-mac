#!/usr/bin/env bash
# Local Release build for vbcc-mac.
#
# Produces a signed, notarized, stapled .dmg ready to attach to a GitHub Release.
#
# Required env:
#   ASC_API_KEY_ID    - App Store Connect API key id (e.g. 6S88N6HKT7)
#   ASC_ISSUER_ID     - App Store Connect issuer id (UUID)
#   ASC_API_KEY_PATH  - Path to AuthKey_<KEY_ID>.p8
#
# Optional env:
#   SIGNING_IDENTITY  - Codesign identity (default: "Developer ID Application: YANG LIU (DD2T6C8HT8)")
#   TEAM_ID           - Apple team id (default: DD2T6C8HT8)
#   OUTPUT_DIR        - Where to drop the .dmg (default: ./dist)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

: "${ASC_API_KEY_ID:?ASC_API_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
: "${ASC_API_KEY_PATH:=${HOME}/Documents/AuthKey_${ASC_API_KEY_ID}.p8}"

if [[ ! -f "$ASC_API_KEY_PATH" ]]; then
  echo "ASC_API_KEY_PATH not found: $ASC_API_KEY_PATH" >&2
  exit 1
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: YANG LIU (DD2T6C8HT8)}"
TEAM_ID="${TEAM_ID:-DD2T6C8HT8}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/dist}"

# Read MARKETING_VERSION from the project (first hit; all configs share one).
VERSION=$(awk -F' = ' '/MARKETING_VERSION =/ {gsub(/[ ;]/,"",$2); print $2; exit}' \
  vbcc-mac.xcodeproj/project.pbxproj)
if [[ -z "$VERSION" ]]; then
  echo "Could not read MARKETING_VERSION from pbxproj" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d -t vbcc-release.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

ARCHIVE_PATH="$WORK_DIR/vbcc-mac.xcarchive"
EXPORT_PATH="$WORK_DIR/export"
EXPORT_OPTIONS="$WORK_DIR/export-options.plist"
NOTARY_ZIP="$WORK_DIR/notary-submit.zip"

mkdir -p "$OUTPUT_DIR"

echo "==> Xcode version"
xcodebuild -version

echo "==> Archive (Release, $VERSION)"
xcodebuild archive \
  -project vbcc-mac.xcodeproj \
  -scheme vbcc-mac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"

echo "==> Export signed .app"
cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>signingStyle</key>
  <string>manual</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_PATH/vbcc-mac.app"
[[ -d "$APP_PATH" ]] || { echo "Exported .app missing: $APP_PATH" >&2; exit 1; }

echo "==> Notarize"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
  --key "$ASC_API_KEY_PATH" \
  --key-id "$ASC_API_KEY_ID" \
  --issuer "$ASC_ISSUER_ID" \
  --wait \
  --timeout 30m

echo "==> Staple"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

DMG_PATH="$OUTPUT_DIR/vbcc-mac-v${VERSION}.dmg"
rm -f "$DMG_PATH"

echo "==> Build .dmg"
create-dmg \
  --volname "vbcc-mac $VERSION" \
  --window-size 540 360 \
  --icon-size 96 \
  --icon "vbcc-mac.app" 140 170 \
  --app-drop-link 400 170 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$APP_PATH"

echo "==> Verify dmg signature/notarization"
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" || true
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo
echo "Done."
echo "  Version: $VERSION"
echo "  DMG:     $DMG_PATH"
echo
echo "Next steps:"
echo "  1. Smoke-test the .dmg on a clean Mac account."
echo "  2. git tag -a v${VERSION} -m \"v${VERSION}\" && git push origin v${VERSION}"
echo "  3. Upload \"$DMG_PATH\" to https://github.com/imyiangyang/vbcc-mac/releases/new"
