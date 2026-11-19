#!/bin/bash
# usage: run.sh <engine-label> <speech speak args...>   → out/<label>/<id>.wav + out/<label>/times.tsv
# Measures wall time (model already cached after the first call) and audio duration; RTF = wall / audio.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SPEECH=${SPEECH:-/private/tmp/claude-501/-Users-almurat-Documents-ChatGPT-italk/dcfc7f81-115f-4776-a864-4abd1636dda5/scratchpad/speech-swift/.build/release/speech}
OUT=${OUT:-/private/tmp/claude-501/-Users-almurat-Documents-ChatGPT-italk/dcfc7f81-115f-4776-a864-4abd1636dda5/scratchpad/tts-eval}
label=$1; shift
mkdir -p "$OUT/$label"; : > "$OUT/$label/times.tsv"
while IFS=$'\t' read -r id text; do
  [ -z "$id" ] && continue
  start=$(python3 -c 'import time;print(time.time())')
  "$SPEECH" ${SUBCMD:-speak} "$@" "$text" -o "$OUT/$label/$id.wav" > "$OUT/$label/$id.log" 2>&1
  rc=$?
  end=$(python3 -c 'import time;print(time.time())')
  dur=$(afinfo "$OUT/$label/$id.wav" 2>/dev/null | awk '/estimated duration/ {print $3}')
  printf "%s\t%s\t%.2f\t%s\t%s\n" "$label" "$id" "$(echo "$end - $start" | bc -l)" "${dur:-0}" "$rc" >> "$OUT/$label/times.tsv"
done < "$HERE/sentences.tsv"
cat "$OUT/$label/times.tsv"
