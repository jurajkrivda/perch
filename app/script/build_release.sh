#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-build}"
APP_NAME="Perch"
SCHEME="Perch"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/ReleaseDerivedData"
RELEASE_DIR="$ROOT_DIR/dist/release"
BUILT_APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
ZIP_PATH="$RELEASE_DIR/$APP_NAME.zip"
NOTARY_PROFILE="${PERCH_NOTARY_PROFILE:-}"

usage() {
  cat <<EOF
usage: $0 [build|notarize]

Environment:
  PERCH_CODESIGN_IDENTITY  Optional Developer ID Application identity.
  PERCH_NOTARY_PROFILE     Required for notarize mode; notarytool keychain profile.
EOF
}

if [[ "$MODE" == "--help" || "$MODE" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "$MODE" != "build" && "$MODE" != "notarize" ]]; then
  usage >&2
  exit 2
fi

if [[ ! -d "$ROOT_DIR/Perch.xcodeproj" ]]; then
  xcodegen generate --spec "$ROOT_DIR/project.yml"
fi

find_developer_id_identity() {
  if [[ -n "${PERCH_CODESIGN_IDENTITY:-}" ]]; then
    echo "$PERCH_CODESIGN_IDENTITY"
    return
  fi

  security find-identity -p codesigning -v 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p' \
    | head -n 1
}

team_identifier_from_identity() {
  sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\))$/\1/p' <<<"$1"
}

IDENTITY="$(find_developer_id_identity)"
if [[ -z "$IDENTITY" ]]; then
  cat >&2 <<EOF
error: no Developer ID Application signing identity found.

Install a Developer ID Application certificate, or set PERCH_CODESIGN_IDENTITY
to the full identity name shown by:

  security find-identity -p codesigning -v
EOF
  exit 1
fi

if [[ "$IDENTITY" != Developer\ ID\ Application:* ]]; then
  echo "error: production builds must use a Developer ID Application identity, got: $IDENTITY" >&2
  exit 1
fi

TEAM_ID="$(team_identifier_from_identity "$IDENTITY")"
if [[ -z "$TEAM_ID" ]]; then
  echo "error: unable to parse team identifier from signing identity: $IDENTITY" >&2
  exit 1
fi

if [[ "$MODE" == "notarize" && -z "$NOTARY_PROFILE" ]]; then
  cat >&2 <<EOF
error: PERCH_NOTARY_PROFILE is required for notarize mode.

Create it once with:

  xcrun notarytool store-credentials <profile-name> --apple-id <apple-id> --team-id $TEAM_ID --password <app-specific-password>
EOF
  exit 1
fi

rm -rf "$DERIVED_DATA_DIR" "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

xcodebuild \
  -project "$ROOT_DIR/Perch.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build

/usr/bin/ditto "$BUILT_APP_BUNDLE" "$APP_BUNDLE"

SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"
SPARKLE_INSTALLER="$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
SPARKLE_DOWNLOADER="$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
SPARKLE_AUTOUPDATE="$SPARKLE_VERSION_DIR/Autoupdate"
SPARKLE_UPDATER="$SPARKLE_VERSION_DIR/Updater.app"

for code_path in \
  "$SPARKLE_INSTALLER" \
  "$SPARKLE_DOWNLOADER" \
  "$SPARKLE_AUTOUPDATE" \
  "$SPARKLE_UPDATER" \
  "$SPARKLE_FRAMEWORK"; do
  if [[ ! -e "$code_path" ]]; then
    echo "error: expected Sparkle code is missing at $code_path" >&2
    exit 1
  fi
done

# Xcode's normal Embed & Sign phase re-signs Sparkle.framework but not the
# helper code nested inside it. Sparkle's distribution guidance requires these
# helpers to be signed from the inside out before notarization.
codesign --force --sign "$IDENTITY" --timestamp --options runtime \
  "$SPARKLE_INSTALLER"
codesign --force --sign "$IDENTITY" --timestamp --options runtime \
  --preserve-metadata=entitlements "$SPARKLE_DOWNLOADER"
codesign --force --sign "$IDENTITY" --timestamp --options runtime \
  "$SPARKLE_AUTOUPDATE"
codesign --force --sign "$IDENTITY" --timestamp --options runtime \
  "$SPARKLE_UPDATER"
codesign --force --sign "$IDENTITY" --timestamp --options runtime \
  "$SPARKLE_FRAMEWORK"
codesign --force --sign "$IDENTITY" --timestamp --options runtime \
  --entitlements "$ROOT_DIR/Perch/Perch.entitlements" "$APP_BUNDLE"

for code_path in \
  "$SPARKLE_INSTALLER" \
  "$SPARKLE_DOWNLOADER" \
  "$SPARKLE_AUTOUPDATE" \
  "$SPARKLE_UPDATER" \
  "$SPARKLE_FRAMEWORK" \
  "$APP_BUNDLE"; do
  signature_details="$(codesign -dvvv "$code_path" 2>&1)"
  if ! grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$signature_details" || \
     ! grep -q '^Timestamp=' <<<"$signature_details"; then
    echo "error: secure Developer ID signature is missing at $code_path" >&2
    exit 1
  fi
done

codesign --verify --strict --deep --verbose=4 "$APP_BUNDLE"

SPARKLE_LICENSE_PATH="$APP_BUNDLE/Contents/Resources/Sparkle-2.9.6-LICENSE.txt"
if [[ ! -f "$SPARKLE_LICENSE_PATH" ]]; then
  echo "error: bundled Sparkle license is missing at $SPARKLE_LICENSE_PATH" >&2
  exit 1
fi

ENTITLEMENTS_FILE="$(mktemp)"
trap 'rm -f "$ENTITLEMENTS_FILE"' EXIT
codesign -d --entitlements :- "$APP_BUNDLE" >"$ENTITLEMENTS_FILE" 2>/dev/null || true

if grep -q "com.apple.security.get-task-allow" "$ENTITLEMENTS_FILE"; then
  echo "error: release app contains get-task-allow entitlement" >&2
  exit 1
fi

/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

if [[ "$MODE" == "notarize" ]]; then
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  spctl -a -vv "$APP_BUNDLE"
else
  if ! spctl -a -vv "$APP_BUNDLE"; then
    echo "warning: Gatekeeper rejected the app; this is expected before successful notarization." >&2
  fi
fi

echo "Release app: $APP_BUNDLE"
echo "Release zip: $ZIP_PATH"
