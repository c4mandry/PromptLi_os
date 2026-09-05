#!/usr/bin/env bash
# Download the AIDO MVP model (IBM Granite 4.0 H 1B, Q4_K_M GGUF, ~700MB).
# Uses wget when available, otherwise curl. Apache-2.0 licensed model.
set -euo pipefail

MODEL_DIR="${AIDO_MODEL_DIR:-$HOME/.aido/models}"
MODEL_URL="https://huggingface.co/ibm-granite/granite-4.0-h-1b-GGUF/resolve/main/granite-4.0-h-1b-Q4_K_M.gguf"
DEST="$MODEL_DIR/granite.gguf"

mkdir -p "$MODEL_DIR"

if [[ -f "$DEST" ]]; then
    echo "Model already present: $DEST"
    exit 0
fi

echo "Downloading model (~700MB) to $DEST ..."
if command -v wget >/dev/null 2>&1; then
    wget -O "$DEST" "$MODEL_URL"
else
    curl -L -o "$DEST" "$MODEL_URL"
fi
echo "Done: $DEST"
echo "Now run: aido"
