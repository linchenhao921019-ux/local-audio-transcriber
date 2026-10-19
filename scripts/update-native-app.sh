#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-/Applications/本地音频转录.app}"
if pgrep -f "^$APP/Contents/MacOS/" >/dev/null; then
  echo "请先等待转录结束并退出本地音频转录，再运行更新。" >&2
  exit 1
fi
test -d "$APP/Contents/Resources/Python.framework"
STAGE="$(mktemp -d /tmp/transcriber-update.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
xcrun swiftc -target arm64-apple-macosx15.0 "$ROOT/app/NativeTranscriberApp.swift" -o "$STAGE/本地音频转录"
BACKUP="$HOME/Library/Application Support/本地音频转录/更新前代码"
mkdir -p "$BACKUP"
cp "$APP/Contents/MacOS/本地音频转录" "$BACKUP/本地音频转录"
cp "$STAGE/本地音频转录" "$APP/Contents/MacOS/本地音频转录"
cp "$ROOT/app/NativeTranscriberApp.swift" "$APP/Contents/Resources/app/NativeTranscriberApp.swift"
cp "$ROOT/src/knowledge_library.py" "$APP/Contents/Resources/app/knowledge_library.py"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "已更新：${APP}（保留现有模型和 Python 运行环境，不复制媒体文件）"
