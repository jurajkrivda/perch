#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Perch"
BUNDLE_ID="com.jurajkrivda.perch"
SCHEME="Perch"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/build/DerivedData"
BUILT_APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/Debug/$APP_NAME.app"
DIST_DIR="$ROOT_DIR/dist/debug"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ENTITLEMENTS="$ROOT_DIR/Perch/Perch.entitlements"

if [[ ! -d "$ROOT_DIR/Perch.xcodeproj" ]]; then
  xcodegen generate --spec "$ROOT_DIR/project.yml"
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$ROOT_DIR/Perch.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  build

stage_app() {
  rm -rf "$APP_BUNDLE"
  mkdir -p "$DIST_DIR"
  /usr/bin/ditto "$BUILT_APP_BUNDLE" "$APP_BUNDLE"
}

find_codesign_identity() {
  if [[ -n "${PERCH_CODESIGN_IDENTITY:-}" ]]; then
    echo "$PERCH_CODESIGN_IDENTITY"
    return
  fi

  security find-identity -p codesigning -v 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: Juraj Krivda.*\)".*/\1/p' \
    | head -n 1
}

sign_app_if_possible() {
  local identity
  identity="$(find_codesign_identity)"

  if [[ -z "$identity" ]]; then
    echo "warning: no Apple Development signing identity found; leaving $APP_NAME ad-hoc signed" >&2
    return
  fi

  /usr/bin/codesign \
    --force \
    --deep \
    --sign "$identity" \
    --entitlements "$ENTITLEMENTS" \
    --timestamp=none \
    "$APP_BUNDLE"
}

stage_app
sign_app_if_possible

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
