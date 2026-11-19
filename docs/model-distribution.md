# Model distribution (multi-source, mainland-China aware)

Status 2026-10-26. Code: `Packages/AgentRuntime/Sources/AgentRuntime/{ModelSources,RangeDownloader,ModelStore,ModelCatalog}.swift`,
manifest `Packages/AgentRuntime/Sources/AgentRuntime/Resources/model-manifest.json`, checker `scripts/model-sources.py`.

## Audit of the previous downloader
- One hard-coded Hugging Face URL per file. No alternative source, so a mainland user without VPN could not download at all.
- Resume used opaque `URLSession` resume data, which only works against the same URL. It could not continue from another host.
- No storage check during download, no launch-time check of an installed model, no retry policy.
- Integrity check (size + SHA-256 per file, atomic install) was correct. It is kept unchanged.

## Design
- **Manifest is the identity.** `model-manifest.json` (schema 1, `manifestVersion` 2026-10-26.1) lists every file of every artifact with byte size and SHA-256. Sources are only URL rules. A file is accepted only if its bytes match, whichever host served them. A similarly named repo with different bytes is rejected automatically.
- **Sources** (`ModelSource`): region `mainlandChina|global`, trust `verified|candidate`, layout `huggingFace(host, repo, revision)`, `modelScope(repo, revision)` or `flat(base)` (iTalk CDN: `<base>/<id>/<version>/<file>`).
- **Ordering** (`SourcePlanner`): iTalk CDN first when configured, then the preferred region, then verified before candidate, then probe latency. Region preference comes from device settings only (region `CN` or a China time zone); there is no IP lookup. Candidates are **allowed by default since manifest 2026-10-26.2**: they cannot install wrong bytes (per-file hash), and on the mainland test they were the only reachable sources. A Debug toggle restores verified-only. Before each download the app probes all sources (≈8 s, parallel); a source with different bytes is never used, and unreachable ones are dropped unless that would leave nothing.
- **Download** (`ModelStore.install(_:sources:)`): per file, try sources in order, 2 retries per source with 1 s / 3 s backoff. Bytes stream into `<file>.part` (`RangeDownloader`), so any later attempt from any source continues with `Range: bytes=N-`. A server that ignores Range restarts from 0. Wrong size or hash deletes the part and blacklists that source for the rest of the install. Free-space check before each file. Cancellation keeps the part, and the next tap resumes.
- **Launch check**: `validateInstalled` compares sizes. A damaged install is removed so the UI offers a fresh download. Full re-hash is available through `verify`. Installed models are excluded from iCloud backup.
- **No cloud fallback**: a failed download sets the state to failed and keeps partial bytes. Nothing switches to cloud inference.
- **Background**: iOS 26 `BGContinuedProcessingTask` (identifier `com.italk.assistant.model-download.*`, declared in Info.plist; no entitlement or extra key). The user-started download keeps running after leaving the app with a system progress UI. If iOS declines or expires it, the download pauses and resumes from the `.part` file. On 2026-10-26 the first device build crashed on tap: a wildcard-registered handler is not matched to concrete IDs on iOS 26, and `submit` raised NSInternalInconsistencyException (crash log pulled from the iPhone; matches Apple forum thread 799126). Fixed by registering each concrete ID right before submit and never submitting when registration fails. The fix is not yet confirmed on the device.
- **Region**: iTalk targets mainland China, so the app always uses mainland-first ordering (iTalk CDN when configured, then ModelScope / hf-mirror, then Hugging Face).
- **Developer import** (Debug builds only): Settings → 本地模型 → 开发者 → 从“文件”导入模型文件夹. Every file is size- and hash-checked like a download. Build the folder with `python3 scripts/model-sources.py package qwen3.5-0.8b-4bit OUT_DIR`.
- **Developer source check** (Debug builds): 检测下载源 hashes the smallest manifest file from every source on the phone's current network.

## Source status

| Source | Region | Trust | Evidence |
| --- | --- | --- | --- |
| huggingface.co @ pinned commit | global | verified | All 10 files of both models downloaded and hashed; the manifest hashes are these bytes. |
| hf-mirror.com @ same commit | mainlandChina | candidate | From a **US exit IP**: the 9 small files are byte-identical. For `model.safetensors` it answered `308 → huggingface.co`, so it may not serve weights itself. Not tested from a mainland network. |
| ModelScope `mlx-community/<repo>` @ master | mainlandChina | candidate | Not confirmed to exist. modelscope.cn TLS handshakes time out from the dev machine; web search found no listing. Not tested from a mainland network. |
| iTalk CDN | both | verified-by-construction | Not deployed. Enable by setting `ITalkModelCDN` in Info.plist; publish the manifest files byte-for-byte. |

**Conclusion today:** no source is verified to work from a mainland network without VPN. The acceptance target (download without VPN in mainland China) is **not met**. It needs one of:
1. A mainland test proving a mirror serves identical weights. Run `python3 scripts/model-sources.py check --full` on a Mac with the proxy off, or use the in-app 检测下载源 with the iPhone's VPN off. Then mark the source `verified` in the manifest with that evidence.
2. The iTalk CDN (recommended for production: mainland object storage plus CDN with ICP filing, serving the exact manifest files).

## First mainland measurement (user's iPhone 16 Pro Max, VPN off, 2026-10-26, in-app 检测下载源, 0.8B model)
| Source | Result |
| --- | --- |
| ModelScope | reachable 1317 ms, smallest file byte-identical, final host www.modelscope.cn |
| hf-mirror | reachable 1355 ms, smallest file byte-identical, final host hf-mirror.com |
| Hugging Face | unreachable, URLError -1001 (timeout) |

The first download attempt then failed with 「没有可用的下载源」: mirrors were excluded and HF was filtered out as unreachable, leaving an empty plan. Fixed in 2026-10-26.2 (above), with a regression test using these exact probe values. Weights from either mirror are still unconfirmed until a full download completes and passes the hash check.

## Test environment note
The development Mac routes all traffic through a local proxy (127.0.0.1:7890, TUN-like; even `--noproxy` exits in Dallas, US). No measurement in this document is from a mainland network.
