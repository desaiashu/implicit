#!/usr/bin/env bash
#
# Download the Whisper model Implicit transcribes with, into rust-core/models/.
# Default is the English-only "small" model (~465 MB) — a good accuracy/speed
# balance, robust to music-mixed vocals. Override MODEL_URL / MODEL_FILE for a
# different size (e.g. ggml-medium.en.bin for more accuracy, ggml-base.en.bin
# for less CPU).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODELS_DIR="$ROOT/rust-core/models"

MODEL_FILE="${MODEL_FILE:-ggml-small.en.bin}"
MODEL_URL="${MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_FILE}}"

command -v curl >/dev/null || { echo "error: 'curl' is required" >&2; exit 1; }

mkdir -p "$MODELS_DIR"
DEST="$MODELS_DIR/$MODEL_FILE"

if [[ -f "$DEST" ]]; then
  echo "==> $MODEL_FILE already present ($(du -h "$DEST" | cut -f1))"
else
  echo "==> downloading $MODEL_FILE"
  curl -L --fail "$MODEL_URL" -o "$DEST.partial"
  mv "$DEST.partial" "$DEST"
  echo "    saved to $DEST"
fi

echo
echo "Done. Build and run with:  ./run.sh"
