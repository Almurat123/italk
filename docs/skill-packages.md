# Installing skills from other people

Status: implemented in `Packages/AgentRuntime/Sources/AgentRuntime/Skills` (parser, validator, installer, declared HTTPS tools) and covered by `swift test` (SkillPackageTests, SkillToolExecutionTests, SkillInstallerTests, InstalledSkillRunTests). The install sheet, import entry and secret fields in the app UI belong to the UI session; the API they call is `SkillRegistryCenter` (below).

## What a skill is
A skill is **data, never code**: nothing a third party ships can run on the phone.
- `SKILL.md` — front matter + instructions that teach the model how to use tools it already has (the same shape as Agent Skills / OpenClaw skills; unknown keys are ignored with a warning).
  ```
  ---
  name: 天气查询            (≤ 40 characters)
  description: 查询城市天气   (≤ 120; the line every model sees in the catalog)
  version: 1.0.0
  id: weather_lookup        (a-z 0-9 _, 3–32 characters; derived from an ASCII name when absent)
  author: Example Inc.
  category: travel          (productivity|communication|travel|health|home|learning|entertainment|developer|other)
  requires: calculate, get_current_datetime    (built-in tools the instructions rely on; missing ones disable the skill, with the reason shown)
  secrets: WEATHER_KEY      (API keys the person is asked for; ≤ 3)
  runtime: 1
  ---
  instructions (≤ 8,000 characters; zero-width / bidi / control characters are removed)
  ```
- `skill.json` (optional) — up to 8 tools, each one declared HTTPS call:
  ```json
  {"tools":[{"name":"forecast","description":"查询某个城市的天气预报","risk":"read",
    "parameters":{"city":{"type":"string","description":"城市名","required":true,"maxLength":40}},
    "http":{"method":"GET","url":"https://api.weather.net/v1/forecast?city={city}","headers":{"Accept":"application/json","X-API-Key":"{secret:WEATHER_KEY}"}}}]}
  ```
  Rules: https only; the host must be a literal public-looking name (no IP address, port, login, `localhost`, `.local`, `.internal`, …) and cannot contain placeholders; `{param}` only in path and query and only for declared parameters; values are always percent-encoded (JSON-escaped in a POST body), so a model value can never add a segment, a parameter or change the host; headers are limited to Accept, Accept-Language, Content-Type, Authorization, X-API-Key, X-Auth-Token, Api-Key and may reference only declared secrets as `{secret:NAME}`; a POST is never presented as a read; the declared risk can be read/modify/external (never "sensitive").
- `SKILL.sig` (optional) — `{"publisher","key":"<base64 Ed25519 public key>","signature":"<base64 over SHA-256(SKILL.md ‖ 0x00 ‖ skill.json)>"}`.

## Trust and what it changes
| Trust | Meaning | Effect |
| --- | --- | --- |
| builtIn | shipped with iTalk | — |
| user | the person marked an instructions-only skill as their own | not tainted |
| imported | file, link or paste, publisher unknown | instructions fenced + run tainted |
| verified | signed; the publisher key was pinned at install | same as imported, plus silent-looking updates only when nothing grew; a different key for the same publisher is refused |

A signature proves who published and that the bytes are unchanged, not that the content is harmless, so verified skills are still treated as third-party text.
- **Fencing:** a third-party skill's instructions enter the prompt wrapped in a fixed label saying they are reference material that cannot grant permissions or override the user or the rules.
- **Taint:** once a run has loaded such a skill, nothing it proposes afterwards is covered by a standing approval (`ApprovalPolicy` taint rule); every such call asks again, with the "this came after reading external content" warning.
- **Tools:** a GET of an approved host that uses no secret runs without a question (still tainted output, framed as data); everything else — any POST, anything with a secret, anything declared modify/external — asks every time. The privacy switch "第三方技能" turns all of them off at once.
- **Network policy:** the runtime builds the request itself from the declaration; the client refuses to leave the approved host (redirects included), reads at most ~64 KB, accepts only JSON/text, keeps no cookies, and strips hidden characters from what it returns. DNS-rebinding to a private address is not prevented (documented residual risk).

## Install, update, remove
`SkillRegistryCenter` (apps/iOS) → `SkillInstaller` (package):
- `previewInstall(.text(skillMD:toolsJSON:) | .folder(URL) | .url(URL), markAsMine:)` → `InstallPreview`: parsed manifest, trust, publisher + key fingerprint, **hosts** it can call, which hosts/tools/secrets are new, warnings, missing dependencies, whether the person must approve again. Nothing is stored.
- `install(preview, approvedHosts:, secrets:)` — the person's approval must cover exactly the hosts; files are written atomically under `Application Support/iTalk/Skills/<id>/<version>-<hash>/`; the previous version is kept for one rollback; secrets go to the Keychain, never to the model or logs.
- `checkForUpdates()` re-reads the places skills came from and returns previews; **nothing is applied automatically**. `rollbackInstalled(id)`, `removeInstalled(id)` (also revokes standing approvals and deletes secrets), `setSecret(skill:name:value:)`.
- Damaged or edited files fail the content-hash check at load and the skill is listed with the reason instead of running.
- Installed skills appear in the same list as built-in ones (`SkillInfo.source = .installed(trust)`, plus version, category, author, hosts, issue); the catalog and tools reach new runs immediately (`AgentRunner.updateCatalog`).

## Not done
Signed-publisher distribution (no key server/registry exists), zip/archives, executable plugins of any kind, skills that call the paired Mac, and a review UI (UI session).
