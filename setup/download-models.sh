#!/bin/bash
# One-time setup for Scribe: the whisper.cpp engine, a baseline model, and the
# conversion tooling for Hinglish fine-tunes. Run by hand: ./setup/download-models.sh
# Needs Homebrew and uv (brew install uv). The app never runs this script; it and
# its siblings are the only parts of the project that touch the internet.
#
# Steps are independent: a failure in one is logged and the rest continue.
# No network at start => exit without finishing, so you can run it again later.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 NONINTERACTIVE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.work"
MODELS="$HOME/Library/Application Support/Scribe/Models"
LOG="$WORK/setup.log"
mkdir -p "$WORK" "$MODELS"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

log "=== setup start ==="
if ! curl -fsSI --max-time 15 https://huggingface.co >/dev/null 2>&1; then
  log "No internet / huggingface.co unreachable. Will retry at the next scheduled run."
  exit 0
fi
osascript -e 'display notification "Downloading whisper.cpp and models" with title "Scribe setup started"' >/dev/null 2>&1 || true

# 1. Engine -------------------------------------------------------------------
if command -v whisper-cli >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1; then
  log "[1] whisper-cli and ffmpeg already installed"
else
  log "[1] brew install whisper-cpp ffmpeg"
  brew install whisper-cpp ffmpeg >>"$LOG" 2>&1 && log "[1] ok" || log "[1] FAILED (see log)"
fi

# 2. Baseline model: Whisper large-v3, 5-bit quantised (about 1.1 GB) ------------
BASE="$MODELS/ggml-large-v3-q5_0.bin"
if [ -f "$BASE" ]; then
  log "[2] large-v3-q5_0 already present"
else
  log "[2] downloading ggml-large-v3-q5_0.bin"
  curl -L --fail -C - --retry 5 --retry-delay 10 \
    -o "$BASE.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin" >>"$LOG" 2>&1 \
    && mv "$BASE.part" "$BASE" && log "[2] ok" || log "[2] FAILED (see log)"
fi

# 3. Hinglish fine-tunes (HF safetensors) ---------------------------------------
HF="$WORK/hf"
mkdir -p "$HF"
hf_get() { # repo dir
  uvx --from huggingface_hub hf download "$1" --local-dir "$2" >>"$LOG" 2>&1
}
if [ ! -f "$HF/shunya/config.json" ]; then
  log "[3a] downloading shunyalabs/zero-stt-hinglish"
  hf_get shunyalabs/zero-stt-hinglish "$HF/shunya" \
    || { log "[3a] retry with shunya-labs/hinglish-whisper-medium"; hf_get shunya-labs/hinglish-whisper-medium "$HF/shunya"; } \
    && log "[3a] ok" || log "[3a] FAILED (see log)"
fi
if [ ! -f "$HF/trelis/config.json" ]; then
  log "[3b] downloading Trelis/whisper-hinglish-preview"
  hf_get Trelis/whisper-hinglish-preview "$HF/trelis" && log "[3b] ok" || log "[3b] FAILED (see log)"
fi

# 4. Convert safetensors -> ggml with whisper.cpp's own script ----------------------
if [ ! -d "$WORK/whisper.cpp" ]; then
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$WORK/whisper.cpp" >>"$LOG" 2>&1 || log "[4] clone whisper.cpp FAILED"
fi
if [ ! -d "$WORK/whisper-openai" ]; then
  git clone --depth 1 https://github.com/openai/whisper "$WORK/whisper-openai" >>"$LOG" 2>&1 || log "[4] clone openai/whisper FAILED"
fi
if [ ! -d "$WORK/venv" ]; then
  log "[4] creating conversion venv (torch, transformers)"
  uv venv "$WORK/venv" >>"$LOG" 2>&1 \
    && uv pip install --python "$WORK/venv/bin/python" torch transformers numpy >>"$LOG" 2>&1 \
    && log "[4] venv ok" || log "[4] venv FAILED (see log)"
fi
convert() { # name
  local out="$MODELS/ggml-$1-f16.bin" tmp="$WORK/convert-$1"
  [ -f "$out" ] && { log "[4] $1 already converted"; return; }
  [ -f "$HF/$1/config.json" ] || { log "[4] $1 not downloaded, skipping"; return; }
  mkdir -p "$tmp"
  log "[4] converting $1"
  "$WORK/venv/bin/python" "$WORK/whisper.cpp/models/convert-h5-to-ggml.py" \
      "$HF/$1" "$WORK/whisper-openai" "$tmp" >>"$LOG" 2>&1 \
    && mv "$tmp/ggml-model.bin" "$out" && log "[4] $1 ok" || log "[4] $1 FAILED (see log; may not convert cleanly)"
}
convert shunya
convert trelis

# Done: list results and notify.
log "Models folder:"; ls -lh "$MODELS" | tee -a "$LOG"
osascript -e 'display notification "Finished. See .work/setup.log in the repo" with title "Scribe setup done"' >/dev/null 2>&1 || true
log "=== setup finished ==="
