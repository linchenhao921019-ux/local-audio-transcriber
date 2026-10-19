#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$TOOL_DIR/dist.noindex/本地音频转录.app"

if ! /usr/bin/arch -arm64 /usr/bin/true >/dev/null 2>&1; then
  echo "This Mac app is Apple Silicon only. Install it on an Apple M-series Mac." >&2
  exit 1
fi

if [[ ! -d "$APP" ]]; then
  echo "App not found. Build it first:" >&2
  echo "  $TOOL_DIR/scripts/build_mac_app.sh" >&2
  exit 1
fi

# Remove both the current destination and the legacy name. They share one
# bundle identifier, so keeping both produces duplicate Spotlight results.
rm -rf "/Applications/本地音频转录.app" "/Applications/本地录音转录.app"
cp -R "$APP" /Applications/
echo "Installed: /Applications/本地音频转录.app"
