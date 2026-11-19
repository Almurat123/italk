# Liquid character v8

Updated: 2026-10-26

## Selected direction

The user approved [blue cloud concept 01 with white capsule eyes](art/gradient-eyes-v8-20261026/01-sky-cloud-white-eyes.png).
The character's job is to make listening and speaking feel attentive, with a clean face and living liquid inside one shape.
This is the visual direction for iTalk's existing voice surface and header avatar; navigation, layout and native containers stay as they are.

## Visual contract

- Stable circular silhouette in every phase; no dots or exclamation replacement.
- Pure white capsule eyes in the large blue upper-right region, above the cloud.
- Soft blue-white currents remain inside the circle. No outline, external halo, particles, background animation or glass shell.
- Eye expression and fluid motion render separately, so blur never affects the eyes.
- Subtle emotion tints stay in the blue family; eye contrast remains white in both themes.

## Implementation

`apps/iOS/VoiceOrbView.swift` uses the existing Canvas and TimelineView. Native cubic paths, gradients and bounded blur layers draw broad cloud currents, a folding wave and a return flow. This is procedural rendering, not playback of the generated raster image.

Idle motion is slow. Listening responds to the actual input meter. Speaking responds to playback level and existing word events. Meter values are smoothed. Flow phase is integrated with bounded frame deltas; changing state does not reset it or multiply elapsed time by a new rate. The outer circle never stretches. Small expression transforms apply to the eyes only.

Reduced Motion pauses fluid and blinking; inactive scenes pause the timeline. Static brand avatars reuse the renderer without a running timeline. Existing header-to-hero motion and the audio capture implementation are unchanged.

Only the renderer and its debug preview descriptions were edited. Claude-owned model, conversation, download and project integration files were preserved.

## Verification

- iOS 26.5 simulator build succeeded with `ONLY_ACTIVE_ARCH=YES ARCHS=arm64`; the project's MLX dependencies do not support the attempted x86_64 simulator build.
- Three focused UI tests passed with zero failures: lifecycle states, emotion palettes and autoplay. Result: `build/UI-liquid-v8-26.xcresult`.
- Light and dark voice screens were captured and visually inspected under `build/previews/liquid-v8/`.
- Actual runtime recording: `build/previews/liquid-v8/liquid-orb-preview.mp4`, a 14-second light-mode excerpt. The cloud-only crop changes between seconds 3 and 12 (SSIM 0.960704), independently of eye blinking.
- Physical-device build succeeded using the existing development team, and installation and launch succeeded on the paired iPhone.
- Native Reduce Motion behavior, physical microphone-driven appearance, energy use and frame-time performance were not measured in this pass. Latest iOS 27 simulator runtime was not checked. Voice-provider emotion synthesis remains a separate integration.

The procedural result preserves the selected composition but is not a pixel-exact reconstruction of the generated concept image.
