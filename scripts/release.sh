#!/usr/bin/env bash
#
# Build a Release configuration of Clip Board, sign it (Developer ID if available,
# else ad-hoc), optionally notarize + staple, and produce a verified, checksummed
# artifact ready for a GitHub Release / Homebrew cask.
#
# This builds the DIRECT edition (unsandboxed, with auto-paste). The Mac App Store
# edition is sandboxed and is archived from Xcode via the "Clip Board (App Store)"
# scheme (Archive -> Distribute -> App Store Connect), not by this script.
#
# The script refuses to emit a build that fails verification: a Developer ID
# build must pass codesign --strict, carry a non-adhoc Team signature, and keep
# the sandbox OFF with network entitlements OFF (the security promise in
# README.md / SECURITY.md). A --notarize build must additionally pass Gatekeeper
# assessment as "Notarized Developer ID".
#
# Usage:
#   ./scripts/release.sh                 # Build + sign (Developer ID auto-detected)
#   ./scripts/release.sh --notarize      # Same + submit to Apple notary + staple
#
# Environment:
#   DEVELOPER_ID        e.g. "Developer ID Application: Jane Doe (TEAMID1234)".
#                       If unset, the first "Developer ID Application" identity in
#                       the keychain is used. If none exists, the build is ad-hoc
#                       signed (Gatekeeper will warn; --notarize is refused).
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
APP="$EXPORT_PATH/$APP_NAME"
ZIP_PATH="$OUT_DIR/Clip-Board.zip"
ENTITLEMENTS_SRC="Clip Board/Clip Board.entitlements"

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
    echo "       Set it up once with:" >&2
    echo "         xcrun notarytool store-credentials clip-board \\" >&2
    echo "           --apple-id you@example.com --team-id PT666QK286 --password <app-specific-pw>" >&2
    exit 1
  fi
fi

# Auto-detect a Developer ID Application identity if the caller didn't pin one.
if [ -z "${DEVELOPER_ID:-}" ]; then
  DEVELOPER_ID="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')"
fi

if [ "$NOTARIZE" = "1" ] && [ -z "$DEVELOPER_ID" ]; then
  echo "ERROR: --notarize needs a Developer ID Application identity, but none was" >&2
  echo "       found. Apple will not notarize an ad-hoc signed build." >&2
  exit 1
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
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME" "$EXPORT_PATH/"

# Sign if a Developer ID is available; otherwise the build's existing ad-hoc
# signature stays in place. Hardened runtime + secure timestamp are required for
# notarization and are harmless otherwise.
if [ -n "$DEVELOPER_ID" ]; then
  echo "==> Signing with: $DEVELOPER_ID"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS_SRC" \
    --sign "$DEVELOPER_ID" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "==> No Developer ID identity found; leaving ad-hoc signature."
fi

echo "==> Zipping..."
ditto -c -k --keepParent "$APP" "$ZIP_PATH"

if [ "$NOTARIZE" = "1" ]; then
  echo "==> Submitting to notary service ($NOTARY_PROFILE)..."
  SUBMIT_OUT="$(xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
  echo "$SUBMIT_OUT"
  if ! echo "$SUBMIT_OUT" | grep -q "status: Accepted"; then
    SUBMISSION_ID="$(echo "$SUBMIT_OUT" | awk '/id:/{print $2; exit}')"
    echo "ERROR: notarization not Accepted. Fetching log..." >&2
    [ -n "$SUBMISSION_ID" ] && xcrun notarytool log "$SUBMISSION_ID" \
      --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
  fi

  echo "==> Stapling..."
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  # Rezip after stapling so the artifact carries the ticket.
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP" "$ZIP_PATH"
fi

# --- Verification gates: refuse to ship a build that fails any of these. -------
fail() { echo "VERIFY FAIL: $1" >&2; exit 1; }

if [ -n "$DEVELOPER_ID" ]; then
  echo "==> Verifying signature, entitlements, and Gatekeeper..."
  codesign --verify --deep --strict --verbose=2 "$APP" || fail "codesign --strict"

  SIG_INFO="$(codesign -dvv "$APP" 2>&1)"
  echo "$SIG_INFO" | grep -q "Signature=adhoc" && fail "signature is ad-hoc"
  echo "$SIG_INFO" | grep -q "TeamIdentifier=not set" && fail "TeamIdentifier not set"

  # The security promise: sandbox OFF, no network entitlements. Operationalized
  # so a misconfigured entitlements file can never reach a release.
  ENTS="$(mktemp)"; trap 'rm -f "$ENTS"' EXIT
  codesign -d --entitlements - --xml "$APP" >"$ENTS" 2>/dev/null \
    || codesign -d --entitlements - "$APP" >"$ENTS" 2>/dev/null || true
  check_false() {
    local key="$1" val
    val="$(plutil -extract "$key" raw "$ENTS" 2>/dev/null || echo absent)"
    [ "$val" = "true" ] && fail "$key is true (expected false/absent)"
    echo "    $key = $val"
  }
  check_false com.apple.security.app-sandbox
  check_false com.apple.security.network.client
  check_false com.apple.security.network.server

  if [ "$NOTARIZE" = "1" ]; then
    spctl -a -vvv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" \
      || fail "Gatekeeper did not accept as Notarized Developer ID"
    echo "    Gatekeeper: accepted (Notarized Developer ID)"
  fi

  # Linked libraries should be Apple system frameworks only (the audit claim).
  if otool -L "$APP/Contents/MacOS/Clip Board" | tail -n +2 \
      | grep -vqE "/(System|usr)/lib"; then
    echo "    WARN: non-system linkage detected; review otool -L output." >&2
  fi
fi

# SHA-256 for the GitHub release notes and the Homebrew cask `sha256` field.
( cd "$OUT_DIR" && shasum -a 256 "Clip-Board.zip" > "Clip-Board.zip.sha256" )

echo
echo "Release ready:"
echo "  App:    $APP"
echo "  Zip:    $ZIP_PATH"
echo "  SHA256: $(awk '{print $1}' "$OUT_DIR/Clip-Board.zip.sha256")"
[ "$NOTARIZE" = "1" ] && echo "  State:  signed + notarized + stapled" \
                      || echo "  State:  signed (NOT notarized — run with --notarize)"
