# Remote integration research

Updated: 2026-10-27

This is an integration assessment, not an implemented or audited remote service.
The user reassigned runtime and desktop integration to Codex on 2026-10-27.
The UI must use the actual runtime contract. No upstream code has been copied
into iTalk.

## Candidates inspected

| Project | Revision inspected | License | Relevant evidence | Fit and limits |
| --- | --- | --- | --- | --- |
| OpenClaw | `3a3246e7c1389c03e933e1f15805306945b1df1c` | MIT | [Device signature payload](https://github.com/openclaw/openclaw/blob/3a3246e7c1389c03e933e1f15805306945b1df1c/packages/gateway-client/src/device-auth.ts), [gateway auth](https://github.com/openclaw/openclaw/blob/3a3246e7c1389c03e933e1f15805306945b1df1c/docs/gateway/protocol/auth.md), [iOS pairing](https://github.com/openclaw/openclaw/blob/3a3246e7c1389c03e933e1f15805306945b1df1c/docs/channels/pairing.md) | Strong candidate for interoperability with an existing single-user gateway. Its gateway is not a hostile multi-tenant isolation boundary; the official hosted push relay is restricted to its official app distribution. |
| Hermes Agent | `11a75355a4c5540154597c7ea23cbc2a933539f5` | MIT | [Session store](https://github.com/NousResearch/hermes-agent/blob/11a75355a4c5540154597c7ea23cbc2a933539f5/gateway/session.py), [pairing store](https://github.com/NousResearch/hermes-agent/blob/11a75355a4c5540154597c7ea23cbc2a933539f5/gateway/pairing.py), [session behavior](https://github.com/NousResearch/hermes-agent/blob/11a75355a4c5540154597c7ea23cbc2a933539f5/website/docs/user-guide/sessions.md) | Useful reference for server-owned sessions and SQLite persistence. Its platform/DM pairing flow is not evidence of an iTalk phone-to-computer QR pairing implementation. |

The OpenClaw device payload binds device ID, client, role, scopes, timestamp,
token and server nonce; its v3 payload also binds platform and device family.
The documented gateway protocol requires challenge validation and explicit
device approval. A QR code alone is not an authenticated connection. LAN and
remote access need independently validated encrypted transport; never expose a
gateway without authentication. Its [security policy](https://github.com/openclaw/openclaw/blob/3a3246e7c1389c03e933e1f15805306945b1df1c/SECURITY.md)
explicitly excludes isolation between hostile tenants.

The inspected [OpenClawKit package](https://github.com/openclaw/openclaw/blob/3a3246e7c1389c03e933e1f15805306945b1df1c/apps/shared/OpenClawKit/Package.swift)
is nested inside the repository and uses a build plugin that invokes a Node
protocol generator from the repository root. Its gateway channel and node
session include reconnect, challenge, routing-generation and idempotency logic;
copying just the wire format would omit those safeguards. Adopting the package
requires a reproducible source distribution including the root generator and
its dependencies, a pinned revision, and compatibility testing. It is not yet
linked into the iTalk Xcode project.
At the inspected revision, the root package requires Node `>=24.22.1 <25` or
`>=26.12.1` and pnpm 12.15.0; the local Node used by the iTalk service is
22.23.0. A separate bundled Node 24.22.1 is available on this Mac and meets the
version range without changing the service runtime; the generator also requires
root protocol sources, `esbuild`, and a verified pnpm setup. Availability of a
compatible executable does not by itself establish a reproducible client build.

Hermes `SessionStore` combines SQLite-backed session routing, transcript and
recovery components. Its pairing store uses separate pending/approved records,
expiry, locking and restrictive file permissions. Those source observations do
not prove compatibility with OpenClaw, complete task replay, or support on any
particular device. Verify those through integration tests before claiming them.

## Integration decisions still required

- Pin an upstream release/commit and verify API stability, third-party license
  notices, trademark usage, desktop platform support and upgrade ownership.
- Establish a mutually agreed runtime contract for identity, pairing approval,
  trust storage, scope display, credential rotation/revocation and reconnect.
- Define which computer actions and Skills are actually exposed and authorized;
  keep destructive actions behind the runtime's explicit approval mechanism.
- Ensure accepted tasks belong to the remote runtime rather than the iPhone
  connection. Define durable identifiers, ordered state updates and replay
  before claiming reconnection or completion after interruptions.
- A managed public service requires its own account/tenant isolation and relay
  operations; neither a self-hosted personal gateway nor a public repository
  alone supplies an iTalk subscription, usage ledger or secure hosted relay.
- Verify QR pairing and rejection, TLS and identity failure, revocation,
  reconnect, task execution and result replay on each supported desktop OS and
  a real iPhone. No such end-to-end verification has been performed yet.
