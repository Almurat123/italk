#!/usr/bin/env python3
"""Downloads a benchmark model listed in the app's manifest into ~/Library/Caches/italk-bench-models/<name>/ (outside the repo), verifying every file's size and SHA-256.

usage: fetch-model.py qwen3.5-2b-4bit [qwen3.5-0.8b-4bit …]
The Mac runs the agent benchmark (tools/agent-bench/bench.sh) from this cache; weights never go into the repo, build/ or a scratchpad (AGENTS.md).
"""
import hashlib, json, os, subprocess, sys
manifest = json.load(open(os.path.join(os.path.dirname(__file__), '../../Packages/AgentRuntime/Sources/AgentRuntime/Resources/model-manifest.json')))['artifacts']
cache = os.path.expanduser('~/Library/Caches/italk-bench-models')
for wanted in sys.argv[1:]:
    art = next(a for a in manifest if a['id'] == wanted)
    hosts = [s['layout']['huggingFace'] for s in art['sources'] if 'huggingFace' in s['layout']]       # huggingface.co first, then the mirror
    src = hosts[0]
    dest = os.path.join(cache, src['repo'].split('/')[-1]); os.makedirs(dest, exist_ok=True)
    for f in art['files']:
        path = os.path.join(dest, f['name'])
        def good():
            return os.path.exists(path) and os.path.getsize(path) == f['bytes'] and hashlib.sha256(open(path, 'rb').read()).hexdigest() == f['sha256']
        for attempt in range(12):
            if good(): break
            h = hosts[attempt % len(hosts)]
            url = f"https://{h['host']}/{h['repo']}/resolve/{h['revision']}/{f['name']}"
            # A stalled connection (the proxy sometimes stops delivering) is abandoned after 30 s below 10 kB/s and resumed from the partial file.
            subprocess.run(['curl', '-fL', '--speed-limit', '10000', '--speed-time', '30', '-C', '-', '-o', path, url])
        assert good(), f"{f['name']}: size or hash mismatch"
    print('ready', dest)
