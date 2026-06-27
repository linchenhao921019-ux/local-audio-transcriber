#!/usr/bin/env bash
set -euo pipefail

REPO="${GITHUB_REPOSITORY:-linchenhao921019-ux/local-audio-transcriber}"
APP_NAME="本地音频转录"
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_FILES=(
  README.md
  RELEASE_VERSION
  build_mac_app.sh
  create_dmg.sh
  sync_to_github.sh
)

cd "$TOOL_DIR"

next_backup_tag() {
  local today base base_re existing max_suffix tag suffix
  today="$(date +%Y.%m.%d)"
  base="v$today"
  base_re="${base//./\\.}"
  existing="$(
    {
      git tag --list "$base*"
      git ls-remote --tags origin "refs/tags/$base*" 2>/dev/null | awk '{print $2}' | sed 's#refs/tags/##; s#\\^{}$##'
    } | sort -u
  )"

  if ! printf '%s\n' "$existing" | grep -Fxq "$base"; then
    printf '%s\n' "$base"
    return
  fi

  max_suffix=0
  while IFS= read -r tag; do
    if [[ "$tag" =~ ^${base_re}\.([0-9]{2})$ ]]; then
      suffix="${BASH_REMATCH[1]}"
      if (( 10#$suffix > max_suffix )); then
        max_suffix=$((10#$suffix))
      fi
    fi
  done <<< "$existing"

  printf '%s.%02d\n' "$base" "$((max_suffix + 1))"
}

TAG="${1:-$(next_backup_tag)}"
if [[ "$TAG" != v* ]]; then
  TAG="v$TAG"
fi
APP_VERSION="${TAG#v}"
COMMIT_MESSAGE="${2:-release $TAG local audio transcriber}"
DMG_NAME="${DMG_NAME:-$TAG.dmg}"
DMG="$TOOL_DIR/dist/$DMG_NAME"
printf '%s\n' "$APP_VERSION" > "$TOOL_DIR/RELEASE_VERSION"

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

Backup version generated from upload date. If multiple backups are uploaded on the same day, the suffix increments as .01, .02, and so on."

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
