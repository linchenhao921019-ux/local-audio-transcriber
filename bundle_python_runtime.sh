#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${1:-}"
PYTHON_FRAMEWORK_SRC="${PYTHON_FRAMEWORK_SRC:-/Library/Frameworks/Python.framework/Versions/3.11}"

if [[ -z "$APP_DIR" || ! -d "$APP_DIR" ]]; then
  echo "Usage: $0 /path/to/App.app" >&2
  exit 1
fi

if [[ ! -x "$PYTHON_FRAMEWORK_SRC/bin/python3.11" || ! -f "$PYTHON_FRAMEWORK_SRC/Python" ]]; then
  echo "Python framework not found: $PYTHON_FRAMEWORK_SRC" >&2
  exit 1
fi

RESOURCES="$APP_DIR/Contents/Resources"
RUNTIME="$RESOURCES/runtime"
FRAMEWORK_ROOT="$RESOURCES/Python.framework"
FRAMEWORK_DST="$FRAMEWORK_ROOT/Versions/3.11"

rm -rf "$FRAMEWORK_ROOT"
mkdir -p "$FRAMEWORK_ROOT/Versions"
/usr/bin/ditto "$PYTHON_FRAMEWORK_SRC" "$FRAMEWORK_DST"
ln -sfn 3.11 "$FRAMEWORK_ROOT/Versions/Current"
ln -sfn Versions/Current/Python "$FRAMEWORK_ROOT/Python"

patch_dependency_paths() {
  local file_path="$1"
  local deps
  deps="$(/usr/bin/otool -L "$file_path" 2>/dev/null | /usr/bin/awk 'NR>1 {print $1}' | /usr/bin/grep "^$PYTHON_FRAMEWORK_SRC/" || true)"
  [[ -z "$deps" ]] && return 0

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    local rel="${dep#"$PYTHON_FRAMEWORK_SRC/"}"
    local dep_dst="$FRAMEWORK_DST/$rel"
    local new_ref
    new_ref="$("$PYTHON_FRAMEWORK_SRC/bin/python3.11" - "$file_path" "$dep_dst" <<'PY'
import os
import sys
source, target = sys.argv[1], sys.argv[2]
print("@loader_path/" + os.path.relpath(target, os.path.dirname(source)))
PY
)"
    /usr/bin/install_name_tool -change "$dep" "$new_ref" "$file_path" 2>/dev/null || true
  done <<< "$deps"
}

while IFS= read -r -d '' file_path; do
  patch_dependency_paths "$file_path"
done < <(/usr/bin/find "$FRAMEWORK_DST" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -111 \) -print0)

/usr/bin/install_name_tool -id "@rpath/Python.framework/Versions/3.11/Python" "$FRAMEWORK_DST/Python" 2>/dev/null || true
/usr/bin/install_name_tool -change "$PYTHON_FRAMEWORK_SRC/Python" "@executable_path/../Python" "$FRAMEWORK_DST/bin/python3.11" 2>/dev/null || true
/usr/bin/install_name_tool -change "$PYTHON_FRAMEWORK_SRC/Python" "@executable_path/../../../../Python" "$FRAMEWORK_DST/Resources/Python.app/Contents/MacOS/Python" 2>/dev/null || true

rm -f "$RUNTIME/bin/python" "$RUNTIME/bin/python3" "$RUNTIME/bin/python3.11"
cat > "$RUNTIME/bin/python" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
RESOURCES="$(cd "$(dirname "$0")/../.." && pwd)"
export PYTHONHOME="$RESOURCES/Python.framework/Versions/3.11"
export PYTHONPATH="$RESOURCES/runtime/lib/python3.11/site-packages${PYTHONPATH:+:$PYTHONPATH}"
exec "$RESOURCES/Python.framework/Versions/3.11/bin/python3.11" "$@"
EOF
chmod +x "$RUNTIME/bin/python"
ln -sfn python "$RUNTIME/bin/python3"
ln -sfn python "$RUNTIME/bin/python3.11"

cat > "$RUNTIME/pyvenv.cfg" <<EOF
home = ../Python.framework/Versions/3.11/bin
include-system-site-packages = false
version = 3.11
executable = ../Python.framework/Versions/3.11/bin/python3.11
command = bundled Python runtime
EOF

echo "Bundled Python framework:"
echo "  $FRAMEWORK_DST"
