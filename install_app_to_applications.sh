#!/usr/bin/env bash
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$TOOL_DIR/dist/本地音频转录.app"

if ! /usr/bin/arch -arm64 /usr/bin/true >/dev/null 2>&1; then
  echo "This Mac app is Apple Silicon only. Install it on an Apple M-series Mac." >&2
  exit 1
fi

if [[ ! -d "$APP" ]]; then
  echo "App not found. Build it first:" >&2
  echo "  $TOOL_DIR/build_mac_app.sh" >&2
  exit 1
fi

rm -rf "/Applications/本地音频转录.app"
cp -R "$APP" /Applications/
echo "Installed: /Applications/本地音频转录.app"
