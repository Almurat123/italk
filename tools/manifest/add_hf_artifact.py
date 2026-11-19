#!/usr/bin/env python3
"""Adds (or replaces) a Hugging Face hosted artifact in AgentRuntime's model-manifest.json.

Every file is pinned by size and SHA-256 taken from the Hugging Face API at one exact revision (LFS object ids are SHA-256; small
non-LFS files are downloaded and hashed here). The app verifies each downloaded file against these values, whichever mirror served it.

  add_hf_artifact.py --id moss-tts-nano-100m-coreml --repo aufklarer/MOSS-TTS-Nano-100M-CoreML --name "..." --include 'GlobalDecoder.mlmodelc/**' ...
"""
import argparse, fnmatch, hashlib, json, os, sys, urllib.request

MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Packages", "AgentRuntime", "Sources", "AgentRuntime", "Resources", "model-manifest.json")

def get(url, binary=False):
    req = urllib.request.Request(url, headers={"User-Agent": "iTalk-manifest/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    return data if binary else json.loads(data)

ap = argparse.ArgumentParser()
ap.add_argument("--id", required=True); ap.add_argument("--repo", required=True); ap.add_argument("--name", required=True)
ap.add_argument("--revision"); ap.add_argument("--include", action="append", required=True)
ap.add_argument("--license", required=True); ap.add_argument("--base-license", required=True)
ap.add_argument("--resident-bytes", type=int, required=True); ap.add_argument("--note", default="")
ap.add_argument("--role", default="speechSynthesis")
args = ap.parse_args()

rev = args.revision or get(f"https://huggingface.co/api/models/{args.repo}")["sha"]
tree = get(f"https://huggingface.co/api/models/{args.repo}/tree/{rev}?recursive=true")
files = []
for item in sorted(tree, key=lambda i: i["path"]):
    if item["type"] != "file" or not any(fnmatch.fnmatch(item["path"], pat) for pat in args.include): continue
    if "lfs" in item:
        sha, size = item["lfs"]["oid"], item["lfs"]["size"]
    else:
        data = get(f"https://huggingface.co/{args.repo}/resolve/{rev}/{item['path']}", binary=True)
        sha, size = hashlib.sha256(data).hexdigest(), len(data)
    files.append({"name": item["path"], "bytes": size, "sha256": sha})
if not files: sys.exit("no files matched")

verified = f"Pinned to revision {rev} on the Hugging Face API; LFS object SHA-256 and sizes are taken from it, small files were downloaded and hashed."
artifact = {
    "id": args.id, "displayName": args.name, "version": rev[:12], "role": args.role,
    "license": args.license, "baseModelLicense": args.base_license, "residentBytes": args.resident_bytes,
    "kvBytesPerToken": 0, "contextTokens": 0, "maxAutonomy": 0,
    "autonomySource": args.note or "speech model: not an agent. Memory figure is an estimate until measured on iPhone.",
    "sources": [
        {"id": "huggingface", "displayName": "Hugging Face", "region": "global", "trust": "verified",
         "layout": {"huggingFace": {"host": "huggingface.co", "repo": args.repo, "revision": rev}}, "verifiedNote": verified},
        {"id": "hf-mirror", "displayName": "hf-mirror.com", "region": "mainlandChina", "trust": "candidate",
         "layout": {"huggingFace": {"host": "hf-mirror.com", "repo": args.repo, "revision": rev}},
         "verifiedNote": "Candidate mirror of the same repository and revision; every file is still checked against the pinned SHA-256."},
    ],
    "files": files,
}
path = os.path.abspath(MANIFEST)
manifest = json.load(open(path, encoding="utf-8"))
manifest["artifacts"] = [a for a in manifest["artifacts"] if a["id"] != args.id] + [artifact]
manifest["manifestVersion"] = manifest["manifestVersion"].split(".")[0] + "." + str(int(manifest["manifestVersion"].split(".")[1]) + 1) if "." in manifest["manifestVersion"] else manifest["manifestVersion"]
json.dump(manifest, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2); open(path, "a").write("\n")
print(f"{args.id}: {len(files)} files, {sum(f['bytes'] for f in files)/1e6:.1f} MB at {rev}")
