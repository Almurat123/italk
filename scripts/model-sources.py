#!/usr/bin/env python3
"""Check iTalk model download sources against the pinned manifest, or build a dev import package.

Run on the network you want to test. For a mainland-China test, disable any proxy/VPN first; the script
prints the public IP country so the result can be trusted.

  python3 scripts/model-sources.py check            # small files: reachability + byte identity, all sources
  python3 scripts/model-sources.py check --full     # also download and hash the weights (~0.6 GB / ~1.7 GB)
  python3 scripts/model-sources.py package qwen3.5-0.8b-4bit OUT_DIR [--source huggingface]
      -> OUT_DIR/<id>/ with every file hash-verified, ready for "开发者：从“文件”导入模型文件夹".

Standard library only. Never marks a source verified by itself: copy the printed result into the manifest by hand.
"""
import hashlib, json, os, sys, time, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "Packages/AgentRuntime/Sources/AgentRuntime/Resources/model-manifest.json")


def source_url(src, art, name):
    layout = src["layout"]
    if "huggingFace" in layout:
        l = layout["huggingFace"]; return f"https://{l['host']}/{l['repo']}/resolve/{l['revision']}/{name}"
    if "modelScope" in layout:
        l = layout["modelScope"]; return f"https://www.modelscope.cn/models/{l['repo']}/resolve/{l['revision']}/{name}"
    base = layout["flat"]["base"].rstrip("/"); return f"{base}/{art['id']}/{art['version']}/{name}"


def fetch(url, dest=None, timeout=20):
    """Returns (status, final_url, sha256, size, seconds). Streams to dest when given."""
    start = time.time(); h = hashlib.sha256(); size = 0
    req = urllib.request.Request(url, headers={"User-Agent": "iTalk-model-check/1"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            out = open(dest, "wb") if dest else None
            while True:
                chunk = r.read(1 << 20)
                if not chunk: break
                h.update(chunk); size += len(chunk)
                if out: out.write(chunk)
            if out: out.close()
            return r.status, r.geturl(), h.hexdigest(), size, time.time() - start
    except urllib.error.HTTPError as e:
        return e.code, url, None, 0, time.time() - start
    except Exception as e:  # network failures are results, not crashes
        return f"{type(e).__name__}: {e}", url, None, 0, time.time() - start


def where():
    for url in ("https://myip.ipip.net", "https://ipinfo.io/country"):
        try:
            with urllib.request.urlopen(url, timeout=8) as r: return r.read().decode("utf-8", "replace").strip()
        except Exception: pass
    return "unknown"


def check(full):
    m = json.load(open(MANIFEST))
    proxies = {k: v for k, v in os.environ.items() if k.lower() in ("http_proxy", "https_proxy", "all_proxy")}
    print(f"manifest {m['manifestVersion']}  network: {where()}  proxy env: {proxies or 'none'}")
    for art in m["artifacts"]:
        print(f"\n== {art['id']} ({art['version']})")
        files = art["files"] if full else [f for f in art["files"] if f["bytes"] < 30_000_000]
        for src in art["sources"]:
            ok = bad = 0; notes = []
            for f in files:
                st, final, digest, size, secs = fetch(source_url(src, art, f["name"]), timeout=600 if full else 20)
                if digest == f["sha256"] and size == f["bytes"]: ok += 1
                else:
                    bad += 1; notes.append(f"{f['name']}: {st} host={urllib.parse.urlparse(final).netloc} size={size}")
            verdict = "IDENTICAL" if bad == 0 else ("UNREACHABLE/DIFFERENT" if ok == 0 else "PARTIAL")
            print(f"  [{src['trust']:9}] {src['id']:12} {verdict:22} {ok}/{len(files)} files match" + ("" if full else " (weights skipped; use --full)"))
            for n in notes[:4]: print("      " + n)


def package(art_id, out, source_id):
    m = json.load(open(MANIFEST))
    art = next(a for a in m["artifacts"] if a["id"] == art_id)
    src = next(s for s in art["sources"] if s["id"] == source_id)
    dest = os.path.join(out, art_id); os.makedirs(dest, exist_ok=True)
    for f in art["files"]:
        path = os.path.join(dest, f["name"])
        if os.path.exists(path) and os.path.getsize(path) == f["bytes"] and hashlib.sha256(open(path, "rb").read()).hexdigest() == f["sha256"]:
            print("ok (cached)", f["name"]); continue
        st, _, digest, size, secs = fetch(source_url(src, art, f["name"]), path, timeout=1800)
        if digest != f["sha256"] or size != f["bytes"]:
            os.remove(path); sys.exit(f"FAILED {f['name']}: status={st} size={size}; nothing to import")
        print(f"ok {f['name']} {size} bytes {secs:.0f}s")
    print(f"\npackage ready: {dest}\ncopy this folder to the iPhone (Files / AirDrop) and import it from the developer section.")


if __name__ == "__main__":
    import urllib.parse
    a = sys.argv[1:]
    if not a or a[0] not in ("check", "package"): sys.exit(__doc__)
    if a[0] == "check": check("--full" in a)
    else: package(a[1], a[2], a[a.index("--source") + 1] if "--source" in a else "huggingface")
