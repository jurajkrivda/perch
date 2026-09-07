#!/usr/bin/env bash
set -euo pipefail

# Uses the current dist/release DMG to generate an appcast with a signed update for
# GitHub Pages. The enclosure itself stays on the tagged GitHub Release.

APP_NAME="Perch"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/dist/release"
SITE_DIR="$ROOT_DIR/dist/site"
UPDATES_DIR="$SITE_DIR/updates"
DMG_PATH="$RELEASE_DIR/$APP_NAME.dmg"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
TEMPORARY_DOWNLOAD_URL_PREFIX="https://jurajkrivda.github.io/perch/updates/"

if [[ ! -f "$DMG_PATH" || ! -d "$APP_BUNDLE" ]]; then
  echo "error: release artifacts not found in $RELEASE_DIR. Run ./script/build_dmg.sh first." >&2
  exit 1
fi

TOOLS_DIR="$("$ROOT_DIR/script/sparkle_tools.sh")"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"

# The GitHub release workflow is authoritative and reconstructs its feed from
# published Releases. Keep this local verification output fresh so a pre-free
# appcast can never be reused accidentally.
rm -rf "$SITE_DIR"
mkdir -p "$UPDATES_DIR"
cp "$DMG_PATH" "$UPDATES_DIR/$APP_NAME-$APP_VERSION.dmg"

# Sparkle 2.9 supports Markdown notes. Keep one source for local verification
# and the published GitHub Release instead of maintaining duplicate HTML.
NOTES_MD="$ROOT_DIR/docs/release-notes-$APP_VERSION.md"
if [[ -f "$NOTES_MD" ]]; then
  cp "$NOTES_MD" "$UPDATES_DIR/$APP_NAME-$APP_VERSION.md"
else
  echo "error: release notes missing at $NOTES_MD" >&2
  exit 1
fi

if ! "$TOOLS_DIR/bin/generate_appcast" \
  --download-url-prefix "$TEMPORARY_DOWNLOAD_URL_PREFIX" \
  --embed-release-notes \
  --maximum-versions 0 \
  --maximum-deltas 0 \
  -o "$SITE_DIR/appcast.xml" \
  "$UPDATES_DIR"; then
  cat >&2 <<'EOF'
error: generate_appcast failed. If it reported a missing signing key, run the
one-time setup first:

  "$(./script/sparkle_tools.sh)/bin/generate_keys"
EOF
  exit 1
fi

TEMPORARY_DOWNLOAD_URL="${TEMPORARY_DOWNLOAD_URL_PREFIX}${APP_NAME}-${APP_VERSION}.dmg"
RELEASE_DOWNLOAD_URL="https://github.com/jurajkrivda/perch/releases/download/v${APP_VERSION}/${APP_NAME}.dmg"
PAGES_URL="$TEMPORARY_DOWNLOAD_URL" RELEASE_URL="$RELEASE_DOWNLOAD_URL" perl -0pi -e \
  's/\Q$ENV{PAGES_URL}\E/$ENV{RELEASE_URL}/g' "$SITE_DIR/appcast.xml"

if ! grep -Fq "$RELEASE_DOWNLOAD_URL" "$SITE_DIR/appcast.xml"; then
  echo "error: generated appcast is missing the tagged GitHub Release URL" >&2
  exit 1
fi

# generate_appcast (Sparkle 2.x) emits sparkle:version as a sibling element of
# <enclosure> (e.g. <sparkle:version>2</sparkle:version>), not as an attribute;
# match both forms in case a future/legacy generator uses the attribute style.
# grep exits 1 when there is no match at all (the common, non-duplicate case),
# which would otherwise trip `set -e` under pipefail, so it is guarded here.
DUPLICATE_BUILD_VERSIONS="$(grep -oE 'sparkle:version="[^"]*"|<sparkle:version>[^<]*</sparkle:version>' "$SITE_DIR/appcast.xml" | sort | uniq -d)" || true
if [[ -n "$DUPLICATE_BUILD_VERSIONS" ]]; then
  cat >&2 <<EOF
error: multiple update archives share the same CFBundleVersion:
$DUPLICATE_BUILD_VERSIONS
Sparkle compares CFBundleVersion; bump it in Perch/Info.plist before releasing.
EOF
  exit 1
fi

# The Pages deployment contains only the feed. GitHub Releases remains the
# single source for distributable binaries and their immutable version URLs.
rm -rf "$UPDATES_DIR"

echo "Appcast: $SITE_DIR/appcast.xml"
echo "Enclosure: $RELEASE_DOWNLOAD_URL"
