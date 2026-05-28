#!/usr/bin/env bash
#
# Build a Release configuration of Clip Board, sign it (Developer ID if available,
# else ad-hoc), and produce a zipped artifact ready for a GitHub Release.
#
# Usage:
#   ./scripts/release.sh                 # Build + sign (Developer ID if env is set)
#   ./scripts/release.sh --notarize      # Same + submit to Apple notary service
#
# Environment:
#   DEVELOPER_ID        e.g. "Developer ID Application: Jane Doe (TEAMID1234)"
#                       If unset, the build is ad-hoc signed (Gatekeeper will warn).
#   NOTARY_PROFILE      Name of a `xcrun notarytool store-credentials` profile.
#                       Required when --notarize is passed.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Clip Board.xcodeproj"
SCHEME="Clip Board"
CONFIG="Release"
APP_NAME="Clip Board.app"
OUT_DIR="$(pwd)/release"
ARCHIVE_PATH="$OUT_DIR/Clip-Board.xcarchive"
EXPORT_PATH="$OUT_DIR/export"
ZIP_PATH="$OUT_DIR/Clip-Board.zip"

# Locate Xcode (the user's xcode-select may point to Command Line Tools).
if [ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
else
  XCODEBUILD="xcodebuild"
fi

NOTARIZE=0
if [ "${1:-}" = "--notarize" ]; then
  NOTARIZE=1
  if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "ERROR: --notarize requires NOTARY_PROFILE in the environment." >&2
    echo "       Set it up once with: xcrun notarytool store-credentials" >&2
    exit 1
  fi
fi

# Clean any prior output, but leave DerivedData alone.
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "==> Building archive ($CONFIG)..."
"$XCODEBUILD" \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  CONFIGURATION_BUILD_DIR="$(pwd)" \
  archive >/dev/null

echo "==> Exporting app..."
mkdir -p "$EXPORT_PATH"
# Copy the .app out of the archive (we already have it at the project root from
# CONFIGURATION_BUILD_DIR, but the archive copy is the authoritative one).
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME" "$EXPORT_PATH/"

# Sign if a Developer ID is available; otherwise the build's existing ad-hoc
# signature stays in place.
if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "==> Signing with: $DEVELOPER_ID"
  codesign --force --deep --options runtime --timestamp \
    --sign "$DEVELOPER_ID" "$EXPORT_PATH/$APP_NAME"
  codesign --verify --deep --strict --verbose=2 "$EXPORT_PATH/$APP_NAME"
else
  echo "==> No DEVELOPER_ID set; leaving ad-hoc signature."
fi

echo "==> Zipping..."
ditto -c -k --keepParent "$EXPORT_PATH/$APP_NAME" "$ZIP_PATH"
echo "    -> $ZIP_PATH"

if [ "$NOTARIZE" = "1" ]; then
  echo "==> Submitting to notary service ($NOTARY_PROFILE)..."
  xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "==> Stapling..."
  xcrun stapler staple "$EXPORT_PATH/$APP_NAME"
  # Rezip after stapling so the artifact carries the staple.
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$EXPORT_PATH/$APP_NAME" "$ZIP_PATH"
fi

echo
echo "Release ready:"
echo "  App:  $EXPORT_PATH/$APP_NAME"
echo "  Zip:  $ZIP_PATH"
