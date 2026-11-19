#!/bin/bash
# Measures how a real model declares the tone of its answers (ToneProtocol) through the production runner.
#   [PROVIDER=mlx|deepseek] [MODEL=Qwen3.5-2B-MLX-4bit] [SAMPLES=2] [CUES=1|0] [INSTRUCTION=<alternative wording>] [ONLY=comfort,fact,<prompt id>] [VOICE=1] OUT=<result.json> tools/companion-eval/run.sh
# `mlx` uses ~/Library/Caches/italk-bench-models/$MODEL (tools/agent-bench/fetch-model.py); `deepseek` reads MODEL_BASE_URL / MODEL_API_KEY /
# MODEL_ID from server/.env at run time and hands them to the test process through its environment (never printed, never written).
# Then: node tools/companion-eval/summarize.mjs docs/measurements/companion-cues-<date>.json <result.json> …
# macOS test bundles must not live under ~/Documents (TCC), so the build tree is ~/Library/Caches/italk-build/mac — delete it when done (AGENTS.md).
ROOT=/Users/almurat/Documents/ChatGPT/italk
: "${OUT:?set OUT=<result.json>}"
# xctest is launched by the system and TCC refuses it ~/Documents: everything it reads is copied to the cache folder first.
CACHE=$HOME/Library/Caches/italk-build/companion; mkdir -p "$CACHE"; cp "$ROOT/tools/companion-eval/prompts.json" "$CACHE/prompts.json"
cd $ROOT/Packages/LocalInference
vars=(TEST_RUNNER_ITALK_CUE_EVAL=1 "TEST_RUNNER_ITALK_CUE_PROVIDER=${PROVIDER:-mlx}" "TEST_RUNNER_ITALK_CUE_PROMPTS=$CACHE/prompts.json"
      "TEST_RUNNER_ITALK_CUE_SAMPLES=${SAMPLES:-2}" "TEST_RUNNER_ITALK_CUE_OUT=$OUT" "TEST_RUNNER_ITALK_CUE_ON=${CUES:-1}" "TEST_RUNNER_ITALK_CUE_VOICE=${VOICE:-0}")
[ "${PROVIDER:-mlx}" = "mlx" ] && vars+=("TEST_RUNNER_ITALK_MODEL_DIR=$HOME/Library/Caches/italk-bench-models/${MODEL:-Qwen3.5-2B-MLX-4bit}")
if [ "${PROVIDER:-mlx}" = "deepseek" ]; then
  # Only the three values the provider needs, passed in the test process's environment (never echoed, never written to a file).
  envget() { grep -E "^$1=" "$ROOT/server/.env" | head -1 | cut -d= -f2- | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }
  vars+=("TEST_RUNNER_ITALK_CUE_BASE_URL=$(envget MODEL_BASE_URL)" "TEST_RUNNER_ITALK_CUE_KEY=$(envget MODEL_API_KEY)" "TEST_RUNNER_ITALK_CUE_MODEL=$(envget MODEL_ID)")
fi
[ -n "${INSTRUCTION:-}" ] && vars+=("TEST_RUNNER_ITALK_CUE_INSTRUCTION=$INSTRUCTION")
[ -n "${ONLY:-}" ] && vars+=("TEST_RUNNER_ITALK_CUE_ONLY=$ONLY")
[ -n "${SEL:-}" ] && vars+=("TEST_RUNNER_ITALK_SELECTION=$SEL")
env "${vars[@]}" xcodebuild test -scheme LocalInference -destination 'platform=macOS' -configuration Release "-only-testing:MLXProviderTests/companionCuesWithRealModel()" \
  -derivedDataPath "${BENCH_DD:-$HOME/Library/Caches/italk-build/mac}" > "${OUT%.json}.log" 2>&1
grep -E "^CUE|error:|\*\* TEST" "${OUT%.json}.log" | tail -n 60
