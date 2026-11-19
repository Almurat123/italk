#!/bin/bash
# usage: [CUES=0 turns the tone instruction off for an A/B run] [ONLY=<scenario id>] [SEL=guided|native] [TAG=-name] bench.sh <model dir name> [samples] [think 0/1]  →  $BENCH_OUT/bench-<model>-think<T><TAG>.{log,json}
# Models come from ~/Library/Caches/italk-bench-models (tools/agent-bench/fetch-model.py).
# macOS test bundles must NOT live under ~/Documents: xctest is launched by the system, not by this shell, and TCC then refuses it the folder ("executable couldn't be located").
# So this one tree lives in ~/Library/Caches/italk-build/mac — delete it when the benchmark work is done (AGENTS.md: no forgotten build trees).
S=${BENCH_OUT:-/private/tmp/claude-501/-Users-almurat-Documents-ChatGPT-italk/dcfc7f81-115f-4776-a864-4abd1636dda5/scratchpad}
ROOT=/Users/almurat/Documents/ChatGPT/italk
cd $ROOT/Packages/LocalInference
M=$1; N=${2:-3}; T=${3:-0}; TAG=${TAG:-}
vars=(TEST_RUNNER_ITALK_BENCH=1 "TEST_RUNNER_ITALK_MODEL_DIR=$HOME/Library/Caches/italk-bench-models/$M" "TEST_RUNNER_ITALK_BENCH_SAMPLES=$N" "TEST_RUNNER_ITALK_THINK=$T"
      "TEST_RUNNER_ITALK_SELECTION=${SEL:-}" "TEST_RUNNER_ITALK_CUES=${CUES:-}" "TEST_RUNNER_ITALK_BENCH_OUT=$S/bench-$M-think$T$TAG.json")
[ -n "${ONLY:-}" ] && vars+=("TEST_RUNNER_ITALK_BENCH_ONLY=$ONLY")
env "${vars[@]}" xcodebuild test -scheme LocalInference -destination 'platform=macOS' -configuration Release "-only-testing:MLXProviderTests/agentBenchWithRealModel()" \
  -derivedDataPath "${BENCH_DD:-$HOME/Library/Caches/italk-build/mac}" > "$S/bench-$M-think$T$TAG.log" 2>&1
grep -E "^BENCH|error:|\*\* TEST" "$S/bench-$M-think$T$TAG.log"
