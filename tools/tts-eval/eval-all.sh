#!/bin/bash
# Mac evaluation of candidate TTS engines on the same sentence set (see sentences.tsv). Results → $OUT/<label>/*.wav + times.tsv
HERE="$(cd "$(dirname "$0")" && pwd)"
run() { "$HERE/run.sh" "$@" > /dev/null 2>&1; echo "done $1 $(date +%H:%M:%S)"; }
SUBCMD=kokoro run kokoro-v1-xiaoxiao --language zh --voice zf_xiaoxiao
SUBCMD=kokoro run kokoro-v1-xiaoyi --language zh --voice zf_xiaoyi
run moss-nano-default --engine moss-nano
run qwen3-06-vivian --engine qwen3 --model customVoice --speaker vivian
run qwen3-06-serena --engine qwen3 --model customVoice --speaker serena
run magpie-zh --engine magpie-coreml --language chinese
