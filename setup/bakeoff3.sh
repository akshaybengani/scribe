#!/bin/bash
# Round 3, accuracy first (no time limit): full-precision models, beam search, no VAD.
# Approved downloads: ggml-large-v3.bin (~3 GB, f16), Qwen3-ASR-1.7B BF16 GGUF (~4 GB).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; W="$ROOT/.work"; M="$HOME/Library/Application Support/Scribe/Models"
OUT="$W/bakeoff3"; LOG="$OUT/run.log"; mkdir -p "$OUT"
log() { echo "[$(date '+%T')] $*" | tee -a "$LOG"; }

dl() { [ -f "$2" ] && return 0
  curl -L --fail -C - --retry 5 --retry-delay 10 -o "$2.part" "$1" >>"$LOG" 2>&1 && mv "$2.part" "$2"; }
log "downloads"
dl https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin "$M/ggml-large-v3-f16.bin" && log "large-v3 f16 ok" || log "large-v3 f16 FAILED"
uvx --from huggingface_hub hf download handy-computer/Qwen3-ASR-1.7B-gguf --include "*BF16*" --local-dir "$W/qwen" >>"$LOG" 2>&1 && log "qwen bf16 ok" || log "qwen bf16 FAILED"

PROMPT="Yeh ek meeting ki recording hai. Hum Hindi aur English mix karke baat kar rahe hain, jaise Hinglish."
m="$M/ggml-large-v3-f16.bin"
if [ -f "$m" ]; then
  for lang in hi en; do
    s=$(date +%s)
    whisper-cli -m "$m" -f "$W/clip5.wav" -l $lang -bs 5 -mc 0 -sns --prompt "$PROMPT" \
      -otxt -of "$OUT/large-v3-f16-beam5-$lang" >"$OUT/large-v3-f16-beam5-$lang.log" 2>&1
    log "large-v3 f16 beam5 lang=$lang: $(( $(date +%s)-s ))s for 300s of audio"
  done
fi
q=$(ls "$W"/qwen/*BF16*.gguf 2>/dev/null | head -1)
cli="$W/transcribe.cpp/build/bin/transcribe-cli"
if [ -n "$q" ] && [ -x "$cli" ]; then
  s=$(date +%s)
  "$cli" -m "$q" "$W/clip5.wav" >"$OUT/qwen3-asr-bf16.txt" 2>"$OUT/qwen3-asr-bf16.log"
  log "qwen3-asr bf16: $(( $(date +%s)-s ))s for 300s of audio"
fi
log "done"
