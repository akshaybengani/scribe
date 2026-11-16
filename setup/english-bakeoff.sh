#!/bin/bash
# Usage: ./english-bakeoff.sh /path/to/english-call.m4a [seconds]
# Runs every English-capable local model on one recording and saves transcripts and timings
# to .work/english-bakeoff/. Optional second argument limits the audio to the first N seconds.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; W="$ROOT/.work"; M="$HOME/Library/Application Support/Scribe/Models"
OUT="$W/english-bakeoff"; mkdir -p "$OUT"
SRC="${1:?usage: english-bakeoff.sh audio-file [seconds]}"
SECS="${2:-}"
log() { echo "[$(date '+%T')] $*" | tee -a "$OUT/timings.txt"; }

if [ -n "$SECS" ]; then T=(-t "$SECS"); else T=(); fi
ffmpeg -y -loglevel error -i "$SRC" "${T[@]}" -ar 16000 -ac 1 "$OUT/clip.wav" || { echo "could not read $SRC"; exit 1; }
DUR=$(afinfo "$OUT/clip.wav" | awk '/estimated duration/ {print int($3)}')
log "audio: ${DUR}s"

for m in ggml-large-v3-f16 ggml-large-v3-turbo-q5_0 ggml-distil-large-v3 ggml-medium.en; do
  f="$M/$m.bin"; [ -f "$f" ] || { log "$m: model missing, skipped"; continue; }
  s=$(date +%s)
  whisper-cli -m "$f" -f "$OUT/clip.wav" -l en -bs 5 -mc 0 -sns --prompt "This is a recording of a business call in English." \
    -otxt -of "$OUT/$m" >"$OUT/$m.log" 2>&1 && log "$m: $(( $(date +%s)-s ))s" || log "$m: FAILED"
done

P="$W/venv-parakeet/bin/parakeet-mlx"
if [ -x "$P" ]; then
  s=$(date +%s)
  "$P" "$OUT/clip.wav" --model mlx-community/parakeet-tdt-0.6b-v2 --output-format txt --output-dir "$OUT" >"$OUT/parakeet.log" 2>&1 \
    && { mv "$OUT/clip.txt" "$OUT/parakeet-tdt-0.6b-v2.txt" 2>/dev/null; log "parakeet-tdt-0.6b-v2: $(( $(date +%s)-s ))s"; } || log "parakeet: FAILED (see parakeet.log)"
fi
log "done"
