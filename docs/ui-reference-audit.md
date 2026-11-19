# Conversation interaction audit

Date: 2026-10-26. Current implementation target: 0.4.0 (4).

The user subsequently rejected the ceramic sphere. The authoritative design
article and corrected research are recorded in
[character-reference-study.md](character-reference-study.md). That study
supersedes the sphere-material direction below; the installed implementation
still contains the rejected renderer pending replacement.

## Revision 4: user-directed corrections

The user's IMG_1299.PNG and subsequent feedback supersede the revision 3 cloud
material and nested composer described below. Glass is a valid native material;
the rejected drawer's problem was its oversized rounded-card composition,
bleeding orb, oversized action, and weak empty state. Revision 4 uses a solid
navigation surface through the safe areas, bounded to 320 points, native List
rows, compact toolbar actions, and explicit empty and no-search-results states.
This archive stores individual approved turns, not invented conversation groups.

Additional references actually inspected:

| Source | Observation | Applied principle |
| --- | --- | --- |
| [Apple sidebars HIG](https://developer.apple.com/design/human-interface-guidelines/sidebars) | Native navigation hierarchy and sidebar behavior; glass itself is permitted. | Stable navigation surface, compact actions, readable rows. |
| [globulus/swiftui-side-menu](https://github.com/globulus/swiftui-side-menu) | MIT metadata and leading overlay/menu behavior. | Outside dismissal and bounded leading navigation; no source copied. |
| [exyte/Chat](https://github.com/exyte/Chat) | MIT metadata and composer/input layout structure. | Separate attachment action, content-driven input height; no dependency imported. |
| [Grok Bot official presentation](https://x.ai/bot) | Solid product backdrop and a physical character with a branded face. | Original faceless mist-silver ceramic sphere with studio light, graphite underside, and soft ground shadow. No eyes, logo, or assets reused. |

The header now has an avatar above the glass name chip, no disclosure chevron.
The avatar is the chat-to-voice action; the small sphere no longer competes with
send/microphone inside the composer. One persistent renderer moves between the
avatar and full-size voice presentation. A static brand mark fills the avatar
while the large sphere is present. Content briefly blurs during this transition;
header controls remain sharp. Reduced Motion uses a short fade without travel.

The input is one glass surface, with a separate attachment button. A vertical
TextField grows from one to eight lines (four for accessibility sizes or limited
height), then scrolls internally. A flexible maxHeight frame was removed after an
actual screenshot showed it stretching an empty draft. Long drafts expose an
expanded editor bound to the same text. Send remains reachable and 3000-character
validation is consistent between the counter, send button, and submit guard.

During an actual hold, the lower screen receives a feathered material wash with
slow blue/iris waves. Real capture level changes wave height. Up/left cancellation
changes it to rose, release fades it away, and the capture remains editable
dictation rather than automatic message submission. The decoration never handles
touches. Its timeline pauses when hidden, inactive, or Reduce Motion is enabled.

The earlier revision and research record follow for provenance; its nested-input
and cloud-material decisions are superseded by this section.

## Revision 3 record

The screen's job is to keep one conversation continuous while the user switches
between reading, typing, dictating, and speaking. NavigationStack, ScrollView,
and native safeAreaBar own layout and keyboard avoidance. The conversation drawer
is an explicit overlay because compact NavigationSplitView navigation would push
another screen instead of exposing the requested sidebar.

## Evidence and access limits

| Source | What was actually inspected | Decision |
| --- | --- | --- |
| [ChatGPT Voice official page](https://chatgpt.com/features/voice/) | Public embedded voice hero, including the cloud sphere and sidebar/settings controls. The separate public demo was viewed; a signed-in live microphone session was not run. | A quiet blue/white cloud field, without a physical shell or bright outline. |
| [ChatGPT voice documentation](https://help.openai.com/en/articles/20001274-chatgpt-voice) | Official distinction between conversation voice and editable dictation. | Dictation release returns editable text; mode changes keep the conversation. |
| [Refero Gemini gallery](https://refero.design/apps/search?app_id%5Bid%5D%5B%5D=153) | Public Gemini iOS screenshot previews in light/dark, voice selection and nested composer surfaces. Remaining screenshots require login. | Separate the outer controls container from the inset text well. Screenshots do not establish animation timing. |
| [Gemini Live official overview](https://gemini.google/overview/gemini-live/) | Official product description of text/voice continuity. | One conversation store across input modes. |
| [Page Flows ChatGPT](https://pageflows.com/ios-tag/all_values_flow/chat-gpt/) | Public listing; full flows require signup. | Discovery only. No claim of observing the protected recordings. |
| [Mobbin MCP](https://mobbin.com/mcp) | Public documentation describes screenshot and flow research through a connected account. No Mobbin or Refero plugin was returned by this host's plugin search. | Do not claim full-library access or silently install a connection. |
| [metasidd/Orb](https://github.com/metasidd/Orb) | Current MIT metadata, OrbView and WavyBlobView source: overlapping organic fields, masks and glow layers. | Organic motion and depth as principles; no library dependency or copied source. |
| [Siri27SiriAnimation](https://github.com/WillSuo-Github/Siri27SiriAnimation) | Current MIT metadata and Metal shader source. | Review of GPU procedural motion, not reuse of its dots/waves implementation. |
| [iOS 26 by Examples](https://github.com/artemnovichkov/iOS-26-by-Examples) | MIT metadata and native glass container/identity examples. | Native glass APIs for controls and the composer. |

This is targeted research of the chat, drawer, keyboard, and voice flows. It is
not a scrape of every app or a claim to have watched every protected animation.

## iOS 26 and 27

[Apple's ScrollEdgeEffectStyle.soft API](https://developer.apple.com/documentation/swiftui/scrolledgeeffectstyle/soft)
exists in the installed iOS 27 SDK with iOS 26 availability. Apple's framework
engineer also discusses changes and linked-SDK compatibility in
[this developer forum response](https://developer.apple.com/forums/thread/834059).
The product deliberately requests soft rather than automatic. Removing the
previous 94% opaque background lets the native top bar treat scrolled content.
The build uses the iOS 27 SDK with a minimum deployment target of iOS 26.

## Repair acceptance

| Reported gap | Repair | Acceptance check |
| --- | --- | --- |
| Back chevron opens history sheet | sidebar.left opens a leading drawer; close, outside tap, swipe and escape dismiss it | Physical hit geometry and UI test; no sheet presented |
| Solid header | Transparent header in native safeAreaBar; explicit soft scroll edges | Scrolled-content screenshots on iOS 26 and 27 |
| Single input outline | One native glass control container around an inset text well | Light/dark and keyboard screenshots |
| Keyboard only moves the composer | Outside tap and scroll dismissal; drawer/voice dismiss focus; text send keeps typing focus | Keyboard visibility and draft preservation checks |
| Hard mode change | Shared cloud geometry and microphone position with a spring; content/controls crossfade and move | Recorded transition plus retained two-message conversation |
| Outlined reflective sphere | Original GPU cloud field with feathered opacity; no stroke or rigid clipped shell | Actual rendered frames, light/dark and Reduce Motion |

The cloud uses bounded rendering cadence (18 fps idle, 30 fps active). It freezes
with Reduce Motion or inactive scenes; only the visible presentation renders.
Its clock is shared across compact and full presentations. Microphone amplitude
comes from actual capture. This is a visual renderer, not a change to the audio
tap or its isolation fix.
