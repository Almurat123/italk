# Conversation UI implementation

Updated: 2026-10-26. Build: 0.2.0 (2).

This document records the first UI implementation. The 0.3.0 follow-up replaces
the history sheet, header background, composer, and orb renderer; see
[the interaction audit](ui-reference-audit.md) for its references and acceptance checks.

## References actually inspected

- [Muse from Meta, official App Store listing](https://apps.apple.com/us/app/muse-from-meta/id6760173601): visually inspected the official screenshots. Centered avatar/name, opposing message bubbles, and a compact bottom composer informed the layout. Logged-in Muse interactions were not tested.
- [Meta's Muse announcement](https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent): product context, not evidence of exact animation behavior.
- [Apple Messages guide](https://support.apple.com/en-gb/guide/iphone/iph82fb73ba3/26/ios/26): attachment entry to the left of the message field and sending from the composer. The custom header follows the contact-avatar/name hierarchy requested by the user.
- [ChatGPT voice documentation](https://help.openai.com/en/articles/20001274-chatgpt-voice): continuity between text and voice and a separate voice presentation.
- [metasidd/Orb](https://github.com/metasidd/Orb): MIT license verified through GitHub. A behavioral reference for an animated sphere. No source or assets copied; iTalk uses its own MeshGradient rendering and measured microphone levels.
- [iOS 26 by Examples](https://github.com/artemnovichkov/iOS-26-by-Examples): inspected native GlassEffectContainer and glassEffect examples. iTalk uses platform APIs rather than a custom blur substitute.
- [OpenAI image input guide](https://developers.openai.com/api/docs/guides/images-vision): inline image payload formats. Real provider compatibility remains an operator setup check.

## Gaps addressed

| Previous implementation | Current behavior | Verification |
| --- | --- | --- |
| Single assistant answer screen | Separate orb and text views over one conversation store | UI test sends two local queries and switches modes |
| Generic microphone interface | Measured sound level drives orb and dictation bars | Audio tap regression probe and physical build |
| No chat image flow | System Photos picker, bounded JPEG preview, explicit upload consent | Picker UI test and mocked gateway/provider tests |
| No press gesture state | Press to record, release to edit, slide up/left to cancel | Core gesture and release-before-ready tests |
| No contact-style brand header | Left history, centered iTalk avatar/name, right menu | Simulator screenshots |

Dictation returns editable text; release does not send a message. Sliding back into
the recording area restores the normal release action. The accessibility action
supports starting and finishing without a sustained gesture. Preparing the speech
model can outlast a press, so release is latched and processed when preparation
finishes. Background/interruption cancels capture. Moving between modes retains
messages but does not automatically start recording.

The sphere pauses for Reduce Motion and background scenes; hidden chat mode does
not render it. Text uses semantic system fonts and grows with Dynamic Type.
Image uploads require an image-capable configured model, account scope, and this
turn's consent. Invalid uploads are rejected before credit reservation. Billing
uses reported provider usage; the image estimate only reserves an upper budget.

This is a structural and interaction reference study. It does not claim pixel
parity with Muse, ChatGPT, or Messages, or copy their branding/assets.

## Verification

- Nine Core tests and eleven gateway tests passed, including gesture cancellation,
  release during preparation, image consent rejection, both image payload formats,
  and actual-usage settlement with a mocked provider.
- UI checks passed for the production audio tap on a background thread, local
  health permission denial, two-message chat and mode continuity, real Photos
  selection and preview, settings, and the accessibility text composer.
- Simulator screenshots were inspected in dark and light appearance. Maximum
  accessibility text revealed oversized chrome symbols; those symbols now keep
  their control size while readable content follows Dynamic Type.
- Signed iPhone build 0.2.0 (2) was installed and launched on the connected physical
  iPhone. No newer iTalk crash report appeared during launch checks. This does not
  replace physical speech testing; the user confirmed the earlier audio tap fix.
- Real cloud image recognition, provider-specific image costs, production
  payments, and Watch execution have not been verified.
