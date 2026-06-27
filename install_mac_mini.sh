#!/usr/bin/env bash
set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${CODEX_AUDIO_TRANSCRIBE_VENV:-$HOME/.codex/venvs/audio-transcriber}"

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip wheel "setuptools<81"
"$VENV_DIR/bin/python" -m pip install -r "$TOOL_DIR/requirements.txt"
"$VENV_DIR/bin/python" "$TOOL_DIR/patch_funasr_onnx.py"

cat <<EOF
Installed audio transcription environment:
  $VENV_DIR

Run:
  "$TOOL_DIR/transcribe" /path/to/recording.m4a
EOF
