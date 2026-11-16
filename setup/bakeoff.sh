#!/bin/bash
# Run the test clip through every installed model; save transcripts + timings.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; W="$ROOT/.work"; M="$HOME/Library/Application Support/Scribe/Models"
OUT="$W/bakeoff"; mkdir -p "$OUT"
PROMPT="Yeh ek meeting ki recording hai. Hum Hindi aur English mix karke baat kar rahe hain, jaise Hinglish."
for m in "$M"/ggml-*.bin; do
  n=$(basename "$m" .bin)
  for lang in hi en; do
    s=$(date +%s)
    whisper-cli -m "$m" -f "$W/clip16k.wav" -l $lang -d 300000 --prompt "$PROMPT" -otxt -of "$OUT/$n-$lang" >"$OUT/$n-$lang.log" 2>&1
    echo "$n lang=$lang: $(( $(date +%s)-s ))s for 300s of audio" | tee -a "$OUT/timings.txt"
  done
done
