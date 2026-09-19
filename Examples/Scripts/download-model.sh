#!/usr/bin/env bash
# Downloads the model `swift run live` uses by default (LFM2.5-230M, Q4_K_M, ~150 MB).
set -euo pipefail

models="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Models"
file="LFM2.5-230M-Q4_K_M.gguf"
mkdir -p "$models"
curl --fail --location --continue-at - --output "$models/$file" \
  "https://huggingface.co/LiquidAI/LFM2.5-230M-GGUF/resolve/main/$file"
echo "Saved $models/$file"
