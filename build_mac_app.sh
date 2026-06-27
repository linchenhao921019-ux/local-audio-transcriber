#!/usr/bin/env bash
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="本地音频转录"
DIST_DIR="$TOOL_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
APP_RES="$RESOURCES/app"
MODEL_SRC="$TOOL_DIR/modelscope_cache/iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-onnx"
MODEL_DST="$APP_RES/modelscope_cache/iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-onnx"
PUNC_SRC="$TOOL_DIR/modelscope_cache/damo/punc_ct-transformer_cn-en-common-vocab471067-large-onnx"
PUNC_DST="$APP_RES/modelscope_cache/damo/punc_ct-transformer_cn-en-common-vocab471067-large-onnx"
ICON_PNG="$TOOL_DIR/AppIcon.png"
ICON_ICNS="$TOOL_DIR/AppIcon.icns"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PIP_INDEX="${PIP_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
SWIFTC="${SWIFTC:-/usr/bin/swiftc}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
SWIFT_TARGET="${SWIFT_TARGET:-arm64-apple-macosx${DEPLOYMENT_TARGET}}"
APP_VERSION="${RELEASE_VERSION:-$(tr -d '[:space:]' < "$TOOL_DIR/RELEASE_VERSION")}"

if ! /usr/bin/arch -arm64 /usr/bin/true >/dev/null 2>&1; then
  echo "This Mac app is Apple Silicon only. Build it on an Apple M-series Mac." >&2
  exit 1
fi

if [[ "$(/usr/bin/arch -arm64 "$PYTHON_BIN" -c 'import platform; print(platform.machine())')" != "arm64" ]]; then
  echo "Python must be able to run as arm64 for this Apple Silicon-only build." >&2
  exit 1
fi

if [[ ! -f "$MODEL_SRC/model_quant.onnx" ]]; then
  echo "Missing local ONNX model: $MODEL_SRC/model_quant.onnx" >&2
  exit 1
fi

if [[ ! -f "$ICON_ICNS" || ! -f "$ICON_PNG" ]]; then
  /usr/bin/arch -arm64 "$PYTHON_BIN" "$TOOL_DIR/make_app_icon.py" --png "$ICON_PNG" --icns "$ICON_ICNS"
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$APP_RES" "$MODEL_DST"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.audio-transcriber.app</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>$DEPLOYMENT_TARGET</string>
  <key>LSArchitecturePriority</key>
  <array>
    <string>arm64</string>
  </array>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/local-audio-transcriber-clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/tmp/local-audio-transcriber-swift-cache}"
/usr/bin/arch -arm64 "$SWIFTC" \
  -target "$SWIFT_TARGET" \
  "$TOOL_DIR/NativeTranscriberApp.swift" \
  -o "$MACOS/$APP_NAME"

built_minos="$(/usr/bin/otool -l "$MACOS/$APP_NAME" | /usr/bin/awk '/LC_BUILD_VERSION/{in_build=1} in_build && /minos/{print $2; exit}')"
if [[ -n "$built_minos" && "$built_minos" != "$DEPLOYMENT_TARGET" ]]; then
  echo "Unexpected app deployment target: built minos $built_minos, expected $DEPLOYMENT_TARGET" >&2
  exit 1
fi

copy_file() {
  local src="$1"
  local dst="$2"
  cp "$TOOL_DIR/$src" "$APP_RES/$dst"
}

copy_file "local_transcriber_gui.py" "local_transcriber_gui.py"
copy_file "NativeTranscriberApp.swift" "NativeTranscriberApp.swift"
copy_file "transcribe_funasr_chunks.py" "transcribe_funasr_chunks.py"
copy_file "make_clip.py" "make_clip.py"
copy_file "build_transcript_doc.py" "build_transcript_doc.py"
copy_file "ollama_meeting_minutes.py" "ollama_meeting_minutes.py"
copy_file "audio_to_doc.py" "audio_to_doc.py"
copy_file "requirements.txt" "requirements.txt"
copy_file "patch_funasr_onnx.py" "patch_funasr_onnx.py"
copy_file "thin_app_to_arm64.sh" "thin_app_to_arm64.sh"
copy_file "make_app_icon.py" "make_app_icon.py"
copy_file "bundle_python_runtime.sh" "bundle_python_runtime.sh"

cp "$ICON_ICNS" "$RESOURCES/AppIcon.icns"
cp "$ICON_PNG" "$APP_RES/AppIcon.png"

cp "$MODEL_SRC"/am.mvn "$MODEL_DST/"
cp "$MODEL_SRC"/config.yaml "$MODEL_DST/"
cp "$MODEL_SRC"/tokens.json "$MODEL_DST/"
cp "$MODEL_SRC"/model_quant.onnx "$MODEL_DST/"
cp "$MODEL_SRC"/configuration.json "$MODEL_DST/" 2>/dev/null || true

if [[ -f "$PUNC_SRC/model_quant.onnx" ]]; then
  mkdir -p "$PUNC_DST"
  for file in config.yaml configuration.json jieba.c.dict jieba.hmm jieba_usr_dict model_quant.onnx README.md tokens.json; do
    [[ -f "$PUNC_SRC/$file" ]] && cp "$PUNC_SRC/$file" "$PUNC_DST/"
  done
fi

export ARCHFLAGS="-arch arm64"
/usr/bin/arch -arm64 "$PYTHON_BIN" -m venv "$RESOURCES/runtime"
/usr/bin/arch -arm64 "$RESOURCES/runtime/bin/python" -m pip install --upgrade pip wheel "setuptools<81" -i "$PIP_INDEX"
/usr/bin/arch -arm64 "$RESOURCES/runtime/bin/python" -m pip install -r "$APP_RES/requirements.txt" -i "$PIP_INDEX"
/usr/bin/arch -arm64 "$RESOURCES/runtime/bin/python" "$APP_RES/patch_funasr_onnx.py"
bash "$TOOL_DIR/bundle_python_runtime.sh" "$APP_DIR"
bash "$TOOL_DIR/thin_app_to_arm64.sh" "$APP_DIR"

while IFS= read -r -d '' file_path; do
  if /usr/bin/file -b "$file_path" | /usr/bin/grep -q "Mach-O"; then
    /bin/chmod u+w "$file_path" 2>/dev/null || true
    /usr/bin/codesign --force --sign - "$file_path"
  fi
done < <(/usr/bin/find "$MACOS" "$RESOURCES/runtime" "$RESOURCES/Python.framework" -type f \( -name "*.so" -o -name "*.dylib" -o -perm -111 \) -print0)

/usr/bin/codesign --force --deep --sign - "$APP_DIR"

echo "Built app:"
echo "  $APP_DIR"
echo
echo "Install with:"
echo "  cp -R \"$APP_DIR\" /Applications/"
