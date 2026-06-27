#!/usr/bin/env bash
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="本地音频转录"
APP="$TOOL_DIR/dist/$APP_NAME.app"
DMG_DIR="$TOOL_DIR/dist"
DMG_NAME="${DMG_NAME:-default.dmg}"
DMG="$DMG_DIR/$DMG_NAME"
STAGING="$DMG_DIR/dmg-staging"

if [[ ! -d "$APP" ]]; then
  echo "App not found. Build it first:" >&2
  echo "  $TOOL_DIR/build_mac_app.sh" >&2
  exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
/usr/bin/ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

rm -rf "$STAGING"

echo "Created DMG:"
echo "  $DMG"
