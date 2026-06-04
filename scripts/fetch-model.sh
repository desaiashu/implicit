#!/usr/bin/env bash
#
# Fetch a sherpa-onnx streaming keyword-spotting model and stage it under
# rust-core/models/ with the canonical filenames swearcore::kws expects
# (encoder.onnx / decoder.onnx / joiner.onnx / tokens.txt).
#
# Default model: the English Zipformer KWS model (GigaSpeech, ~3.3M params).
# It's a *streaming keyword spotter*, not full ASR — exactly what we want for
# "spot these words now" at low latency. Override MODEL_URL for another one.
#
# It also generates `keywords.txt` from the plain word list (scripts/swears.txt):
# sherpa-onnx needs each keyword tokenised with the model's own BPE/token table.
# That needs a small Python tokeniser, so the script sets up a private virtualenv
# (scripts/.venv) the first time. Re-run after editing swears.txt.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODELS_DIR="$ROOT/rust-core/models"
WORDLIST="$HERE/swears.txt"

MODEL_NAME="sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01"
MODEL_URL="${MODEL_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/${MODEL_NAME}.tar.bz2}"

for tool in curl tar; do
  command -v "$tool" >/dev/null || { echo "error: '$tool' is required" >&2; exit 1; }
done

mkdir -p "$MODELS_DIR"
cd "$MODELS_DIR"

if [[ ! -d "$MODEL_NAME" ]]; then
  echo "==> downloading $MODEL_NAME"
  curl -L --fail "$MODEL_URL" -o "${MODEL_NAME}.tar.bz2"
  echo "==> extracting"
  tar xjf "${MODEL_NAME}.tar.bz2"
  rm -f "${MODEL_NAME}.tar.bz2"
fi

# Link the (long, epoch-stamped) model files to the canonical names kws.rs reads.
link_one() {
  local pattern="$1" canonical="$2"
  local match
  match="$(find "$MODEL_NAME" -maxdepth 1 -name "$pattern" | sort | head -n1)"
  [[ -n "$match" ]] || { echo "error: no file matching '$pattern' in $MODEL_NAME" >&2; exit 1; }
  ln -sf "$(basename "$MODEL_NAME")/$(basename "$match")" "$canonical"
  echo "    $canonical -> $match"
}

echo "==> linking canonical names in $MODELS_DIR"
link_one 'encoder*.onnx' encoder.onnx
link_one 'decoder*.onnx' decoder.onnx
link_one 'joiner*.onnx'  joiner.onnx
link_one 'tokens.txt'    tokens.txt

# Generate keywords.txt from the plain word list. The keyword spotter matches
# exact token sequences, and the GigaSpeech vocabulary is UPPERCASE — so we
# uppercase each word before tokenising (lowercase words tokenise to OOV and get
# silently dropped). The tokeniser is sherpa-onnx's Python helper; we set up a
# private virtualenv so a fresh clone Just Works.
BPE="$MODELS_DIR/$MODEL_NAME/bpe.model"
VENV="$HERE/.venv"
if command -v python3 >/dev/null; then
  if ! "$VENV/bin/python" -c 'import sherpa_onnx, sentencepiece, pypinyin' 2>/dev/null; then
    echo "==> setting up tokeniser venv (one time)"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip >/dev/null
    "$VENV/bin/pip" install --quiet sherpa-onnx sentencepiece pypinyin
  fi
  echo "==> tokenising $(basename "$WORDLIST") -> keywords.txt"
  "$VENV/bin/python" - "$MODELS_DIR/tokens.txt" "$BPE" "$WORDLIST" "$MODELS_DIR/keywords.txt" <<'PY'
import sys, sherpa_onnx
tokens, bpe, wordlist, out = sys.argv[1:5]
words = [w.strip() for w in open(wordlist) if w.strip() and not w.strip().startswith("#")]
encoded = sherpa_onnx.text2token([w.upper() for w in words], tokens=tokens,
                                 tokens_type="bpe", bpe_model=bpe)
written = 0
with open(out, "w") as f:
    for word, toks in zip(words, encoded):
        if not toks:
            print(f"    WARN: no tokens for {word!r} — skipping", file=sys.stderr); continue
        f.write(" ".join(toks) + " @" + word + "\n"); written += 1
print(f"    wrote {written}/{len(words)} keywords")
PY
else
  echo "==> NOTE: python3 not found — install it and re-run to generate keywords.txt" >&2
fi

echo
echo "Done. Point the app at it with:"
echo "  export SWEAR_KWS_DIR=\"$MODELS_DIR\""
