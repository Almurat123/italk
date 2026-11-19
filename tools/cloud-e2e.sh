#!/bin/bash
# Runs the Swift client against the real gateway v2 (scripted model). Usage: tools/cloud-e2e.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/server"
node tools/fake-gateway.mjs > /tmp/fake-gateway.out 2>/tmp/fake-gateway.err &
GW=$!; trap 'kill $GW 2>/dev/null' EXIT
for i in $(seq 1 50); do [ -s /tmp/fake-gateway.out ] && break; sleep 0.2; done
PORT=$(python3 -c "import json;print(json.loads(open('/tmp/fake-gateway.out').readline())['port'])")
TOKEN=$(python3 -c "import json;print(json.loads(open('/tmp/fake-gateway.out').readline())['token'])")
cd "$ROOT/Packages/AgentRuntime"
ITALK_TEST_GATEWAY="http://127.0.0.1:$PORT" ITALK_TEST_TOKEN="$TOKEN" swift test --filter CloudDurability 2>&1 | grep -E "✔|✘|error:|Test run|issue"
