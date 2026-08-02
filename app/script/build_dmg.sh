#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-build}"
APP_NAME="Perch"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/dist/release"
BUILD_DIR="$ROOT_DIR/build/dmg"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
DMG_PATH="$RELEASE_DIR/$APP_NAME.dmg"
RW_DMG_PATH="$BUILD_DIR/$APP_NAME-rw.dmg"
STAGING_DIR="$BUILD_DIR/staging"
NOTARY_PROFILE="${PERCH_NOTARY_PROFILE:-}"

usage() {
  cat <<EOF
usage: $0 [build|notarize]

Creates a distributable DMG containing Perch.app, an Applications shortcut,
and the project license notices.

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

find_developer_id_identity() {
  if [[ -n "${PERCH_CODESIGN_IDENTITY:-}" ]]; then
    echo "$PERCH_CODESIGN_IDENTITY"
    return
  fi

  security find-identity -p codesigning -v 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p' \
    | head -n 1
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
  echo "error: production DMGs must use a Developer ID Application identity, got: $IDENTITY" >&2
  exit 1
fi

if [[ "$MODE" == "notarize" && -z "$NOTARY_PROFILE" ]]; then
  cat >&2 <<EOF
error: PERCH_NOTARY_PROFILE is required for notarize mode.

Create it once with:

  xcrun notarytool store-credentials perch-notary --apple-id <apple-id> --team-id <team-id>
EOF
  exit 1
fi

"$ROOT_DIR/script/build_release.sh" "$MODE"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: release app not found at $APP_BUNDLE" >&2
  exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
VOLUME_NAME="$APP_NAME $APP_VERSION"
MOUNT_DIR="$(mktemp -d)"
MOUNT_DEVICE=""

cleanup() {
  if [[ -n "$MOUNT_DEVICE" ]]; then
    hdiutil detach "$MOUNT_DEVICE" -quiet || true
  fi
  rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

rm -rf "$BUILD_DIR"
mkdir -p "$STAGING_DIR" "$RELEASE_DIR"

if [[ ! -f "$REPOSITORY_ROOT/LICENSE" || ! -f "$REPOSITORY_ROOT/NOTICE" ]]; then
  echo "error: repository LICENSE or NOTICE is missing" >&2
  exit 1
fi

/usr/bin/ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
/usr/bin/ditto "$REPOSITORY_ROOT/LICENSE" "$STAGING_DIR/LICENSE"
/usr/bin/ditto "$REPOSITORY_ROOT/NOTICE" "$STAGING_DIR/NOTICE"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH" "$RW_DMG_PATH"

hdiutil create "$RW_DMG_PATH" \
  -volname "$VOLUME_NAME" \
  -fs HFS+ \
  -format UDRW \
  -srcfolder "$STAGING_DIR" \
  -ov

MOUNT_DEVICE="$(hdiutil attach "$RW_DMG_PATH" -mountpoint "$MOUNT_DIR" -nobrowse -noverify -noautoopen | awk '/Apple_HFS/ { print $1; exit }')"

if [[ -z "$MOUNT_DEVICE" ]]; then
  echo "error: unable to mount temporary DMG" >&2
  exit 1
fi

set +e
osascript <<EOF
set targetFolder to POSIX file "$MOUNT_DIR" as alias
tell application "Finder"
  open targetFolder
  delay 1
  try
    set current view of container window of targetFolder to icon view
    set toolbar visible of container window of targetFolder to false
    set statusbar visible of container window of targetFolder to false
    set the bounds of container window of targetFolder to {100, 100, 660, 500}
    set viewOptions to the icon view options of container window of targetFolder
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set position of item "$APP_NAME.app" of targetFolder to {165, 150}
    set position of item "Applications" of targetFolder to {405, 150}
    set position of item "LICENSE" of targetFolder to {165, 315}
    set position of item "NOTICE" of targetFolder to {405, 315}
    close container window of targetFolder
  end try
  update targetFolder
end tell
EOF
LAYOUT_STATUS=$?
set -e

if [[ "$LAYOUT_STATUS" -ne 0 ]]; then
  echo "warning: Finder layout customization failed; continuing with a valid DMG." >&2
fi

sync
hdiutil detach "$MOUNT_DEVICE" -quiet
MOUNT_DEVICE=""

hdiutil convert "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" \
  -ov

codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=4 "$DMG_PATH"
hdiutil verify "$DMG_PATH"

if [[ "$MODE" == "notarize" ]]; then
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"
else
  if ! spctl -a -vv -t open --context context:primary-signature "$DMG_PATH"; then
    echo "warning: Gatekeeper rejected the DMG; this is expected before successful notarization." >&2
  fi
fi

echo "Release DMG: $DMG_PATH"
