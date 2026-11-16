#!/bin/bash
# Approved downloads for English-only call testing:
#   ggml-distil-large-v3.bin (~1.5 GB), ggml-medium.en.bin (~1.5 GB),
#   parakeet-mlx (Python package) + mlx-community/parakeet-tdt-0.6b-v2 (~2.5 GB).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; W="$ROOT/.work"; M="$HOME/Library/Application Support/Scribe/Models"
LOG="$W/english-models.log"; mkdir -p "$W" "$M"
log() { echo "[$(date '+%T')] $*" | tee -a "$LOG"; }

dl() { [ -f "$2" ] && { log "$(basename "$2") already present"; return 0; }
  curl -L --fail -C - --retry 5 --retry-delay 10 -o "$2.part" "$1" >>"$LOG" 2>&1 && mv "$2.part" "$2"; }

dl https://huggingface.co/distil-whisper/distil-large-v3-ggml/resolve/main/ggml-distil-large-v3.bin "$M/ggml-distil-large-v3.bin" && log "distil-large-v3 ok" || log "distil-large-v3 FAILED"
dl https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin "$M/ggml-medium.en.bin" && log "medium.en ok" || log "medium.en FAILED"

if [ ! -x "$W/venv-parakeet/bin/parakeet-mlx" ]; then
  log "installing parakeet-mlx"
  uv venv "$W/venv-parakeet" >>"$LOG" 2>&1 && uv pip install --python "$W/venv-parakeet/bin/python" parakeet-mlx huggingface_hub >>"$LOG" 2>&1 \
    && log "parakeet-mlx installed" || log "parakeet-mlx install FAILED"
fi
log "fetching parakeet model"
"$W/venv-parakeet/bin/python" -c "from huggingface_hub import snapshot_download; snapshot_download('mlx-community/parakeet-tdt-0.6b-v2')" >>"$LOG" 2>&1 \
  && log "parakeet model ok" || log "parakeet model FAILED"
log "done"
