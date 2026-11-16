#!/bin/bash
# Bake-off round 2: adds Whisper large-v3-turbo and Qwen3-ASR; Whisper runs use
# VAD + no text carry-over to stop repetition loops. Approved downloads only:
#   ggml-large-v3-turbo-q5_0.bin (~570 MB), ggml-silero-v5.1.2.bin (~1 MB),
#   Qwen3-ASR-1.7B Q5_K_M GGUF (~1.5 GB), cmake (brew), transcribe.cpp source.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 NONINTERACTIVE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; W="$ROOT/.work"; M="$HOME/Library/Application Support/Scribe/Models"
OUT="$W/bakeoff2"; LOG="$OUT/run.log"; mkdir -p "$OUT" "$W/vad" "$W/qwen"
log() { echo "[$(date '+%T')] $*" | tee -a "$LOG"; }

dl() { # url dest
  [ -f "$2" ] && return 0
  curl -L --fail -C - --retry 5 --retry-delay 10 -o "$2.part" "$1" >>"$LOG" 2>&1 && mv "$2.part" "$2"
}
log "downloads"
dl https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin "$M/ggml-large-v3-turbo-q5_0.bin" && log "turbo ok" || log "turbo FAILED"
dl https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin "$W/vad/silero.bin" && log "vad ok" || log "vad FAILED"
uvx --from huggingface_hub hf download handy-computer/Qwen3-ASR-1.7B-gguf --include "*Q5_K_M*" --local-dir "$W/qwen" >>"$LOG" 2>&1 && log "qwen model ok" || log "qwen model FAILED"

log "build transcribe.cpp"
command -v cmake >/dev/null || brew install cmake >>"$LOG" 2>&1
[ -d "$W/transcribe.cpp" ] || git clone --depth 1 https://github.com/handy-computer/transcribe.cpp "$W/transcribe.cpp" >>"$LOG" 2>&1
(cd "$W/transcribe.cpp" && cmake -B build >>"$LOG" 2>&1 && cmake --build build -j >>"$LOG" 2>&1) && log "build ok" || log "build FAILED"

ffmpeg -y -loglevel error -i "$W/clip16k.wav" -t 300 -ar 16000 -ac 1 "$W/clip5.wav"
PROMPT="Yeh ek meeting ki recording hai. Hum Hindi aur English mix karke baat kar rahe hain, jaise Hinglish."

for m in "$M"/ggml-large-v3-turbo-q5_0.bin "$M"/ggml-large-v3-q5_0.bin "$M"/ggml-shunya-f16.bin; do
  [ -f "$m" ] || continue
  n=$(basename "$m" .bin)
  for lang in hi en; do
    s=$(date +%s)
    whisper-cli -m "$m" -f "$W/clip5.wav" -l $lang --vad -vm "$W/vad/silero.bin" -mc 0 -sns \
      --prompt "$PROMPT" -otxt -of "$OUT/$n-$lang" >"$OUT/$n-$lang.log" 2>&1
    log "$n lang=$lang: $(( $(date +%s)-s ))s for 300s of audio"
  done
done

q=$(ls "$W"/qwen/*Q5_K_M*.gguf 2>/dev/null | head -1)
cli="$W/transcribe.cpp/build/bin/transcribe-cli"
if [ -n "$q" ] && [ -x "$cli" ]; then
  s=$(date +%s)
  "$cli" -m "$q" "$W/clip5.wav" >"$OUT/qwen3-asr.txt" 2>"$OUT/qwen3-asr.log"
  log "qwen3-asr: $(( $(date +%s)-s ))s for 300s of audio (exit $?)"
else
  log "qwen3-asr skipped (model or build missing)"
fi
log "done"
