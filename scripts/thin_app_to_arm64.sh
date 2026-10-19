#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${1:-}"

if [[ -z "$APP_DIR" || ! -d "$APP_DIR" ]]; then
  echo "Usage: $0 /path/to/App.app" >&2
  exit 1
fi

if ! command -v lipo >/dev/null 2>&1; then
  echo "lipo not found; install Xcode Command Line Tools first." >&2
  exit 1
fi

if ! /usr/bin/arch -arm64 /usr/bin/true >/dev/null 2>&1; then
  echo "This app is Apple Silicon only and must be processed on an arm64 Mac." >&2
  exit 1
fi

thinned=0
skipped=0

while IFS= read -r -d '' file_path; do
  if [[ -L "$file_path" ]]; then
    skipped=$((skipped + 1))
    continue
  fi

  archs="$(/usr/bin/lipo -archs "$file_path" 2>/dev/null || true)"
  if [[ "$archs" != *"arm64"* ]]; then
    continue
  fi

  if [[ "$archs" == *"x86_64"* || "$archs" == *"i386"* ]]; then
    mode="$(/usr/bin/stat -f "%Lp" "$file_path")"
    tmp_path="$(/usr/bin/mktemp "${file_path}.arm64.XXXXXX")"
    rm -f "$tmp_path"
    /usr/bin/lipo "$file_path" -thin arm64 -output "$tmp_path"
    /bin/mv "$tmp_path" "$file_path"
    /bin/chmod "$mode" "$file_path"
    thinned=$((thinned + 1))
  fi
done < <(/usr/bin/find "$APP_DIR" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -111 \) -print0)

echo "Arm64 thinning complete: $thinned file(s) thinned, $skipped symlink(s) skipped."
