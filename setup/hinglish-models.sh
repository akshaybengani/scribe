#!/bin/bash
# Approved downloads: Oriserve/Whisper-Hindi2Hinglish-Apex (~1.6 GB), Trelis/tara (~3.1 GB),
# moorlee/qwen3-asr-0.6b-hinglish (~1.6 GB, the repo formerly Surajgameramp/srota).
# Whisper-family ones are converted to ggml for whisper.cpp. The Qwen one has no
# converter in transcribe.cpp, so it is only downloaded (runs later via Python qwen-asr).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; W="$ROOT/.work"; M="$HOME/Library/Application Support/Scribe/Models"
HF="$W/hf"; LOG="$W/hinglish-models.log"; mkdir -p "$HF"
log() { echo "[$(date '+%T')] $*" | tee -a "$LOG"; }

get() { # name repo
  [ -f "$HF/$1/config.json" ] && [ -n "$(ls "$HF/$1" | grep -E 'safetensors$')" ] && { log "$1 already downloaded"; return; }
  log "downloading $2"
  uvx --from huggingface_hub hf download "$2" --local-dir "$HF/$1" >>"$LOG" 2>&1 && log "$1 ok" || log "$1 FAILED"
}
get oriserve Oriserve/Whisper-Hindi2Hinglish-Apex
get tara Trelis/tara
get srota moorlee/qwen3-asr-0.6b-hinglish

convert() {
  local out="$M/ggml-$1-f16.bin" tmp="$W/convert-$1"
  [ -f "$out" ] && { log "$1 already converted"; return; }
  [ -f "$HF/$1/config.json" ] || { log "$1 missing, skip"; return; }
  mkdir -p "$tmp"; log "converting $1"
  "$W/venv/bin/python" "$W/whisper.cpp/models/convert-h5-to-ggml.py" "$HF/$1" "$W/whisper-openai" "$tmp" >>"$LOG" 2>&1 \
    && mv "$tmp/ggml-model.bin" "$out" && log "$1 converted" || log "$1 conversion FAILED (see log)"
}
convert oriserve
convert tara
log "done"
