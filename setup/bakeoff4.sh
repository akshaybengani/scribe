#!/bin/bash
# Round 4: remaining Whisper-family tests, accuracy first (beam 5, no VAD, no carry-over).
# Models: oriserve, tara (Hinglish fine-tunes), shunya (full precision, beam search).
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; W="$ROOT/.work"; M="$HOME/Library/Application Support/Scribe/Models"
OUT="$W/bakeoff4"; LOG="$OUT/run.log"; mkdir -p "$OUT"
log() { echo "[$(date '+%T')] $*" | tee -a "$LOG"; }
PROMPT="Yeh ek meeting ki recording hai. Hum Hindi aur English mix karke baat kar rahe hain, jaise Hinglish."
for n in oriserve tara shunya; do
  m="$M/ggml-$n-f16.bin"; [ -f "$m" ] || { log "$n: no ggml model, skipped"; continue; }
  for lang in hi en; do
    s=$(date +%s)
    whisper-cli -m "$m" -f "$W/clip5.wav" -l $lang -bs 5 -mc 0 -sns --prompt "$PROMPT" \
      -otxt -of "$OUT/$n-beam5-$lang" >"$OUT/$n-beam5-$lang.log" 2>&1 \
      && log "$n beam5 lang=$lang: $(( $(date +%s)-s ))s" || log "$n beam5 lang=$lang FAILED (see $n-beam5-$lang.log)"
  done
done
log "done"
