#!/usr/bin/env bash
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-linchenhao921019-ux/local-audio-transcriber}"
APP_NAME="本地音频转录"
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_VERSION="${RELEASE_VERSION:-$(tr -d '[:space:]' < "$TOOL_DIR/RELEASE_VERSION")}"
TAG="${1:-v$APP_VERSION}"
COMMIT_MESSAGE="${2:-release $TAG local audio transcriber}"
DMG_NAME="${DMG_NAME:-default.dmg}"
DMG="$TOOL_DIR/dist/$DMG_NAME"
SOURCE_FILES=(
  README.md
  RELEASE_VERSION
  build_mac_app.sh
  create_dmg.sh
  sync_to_github.sh
)

cd "$TOOL_DIR"

RELEASE_VERSION="$APP_VERSION" bash "$TOOL_DIR/build_mac_app.sh"
DMG_NAME="$DMG_NAME" bash "$TOOL_DIR/create_dmg.sh"

git add -- "${SOURCE_FILES[@]}"
if git diff --cached --quiet -- "${SOURCE_FILES[@]}"; then
  echo "No source changes to commit."
else
  git commit -m "$COMMIT_MESSAGE" -- "${SOURCE_FILES[@]}"
fi

git -c http.version=HTTP/1.1 push -u origin "$(git branch --show-current)"

if [[ -f "$DMG" ]]; then
  RELEASE_NOTES="Mac installer for $APP_NAME $TAG.

Includes the June 13-14 compatibility and installation fixes."

  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release edit "$TAG" \
      --repo "$REPO" \
      --title "$TAG" \
      --notes "$RELEASE_NOTES"
    gh release upload "$TAG" "$DMG" --repo "$REPO" --clobber
  else
    gh release create "$TAG" "$DMG" \
      --repo "$REPO" \
      --title "$TAG" \
      --notes "$RELEASE_NOTES"
  fi
fi

echo "Synced to https://github.com/$REPO"
