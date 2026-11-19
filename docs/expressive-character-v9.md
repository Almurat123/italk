# Expressive character v9

Updated: 2026-10-26

Supersedes the stable-circle/capsule-eye restrictions in [v8](liquid-character-v8.md), following the user's new direction.

## Product and visual contract

The character communicates iTalk's current listening and speaking intent. The existing conversation page owns layout and navigation; this revision changes its avatar styling and character renderer, not its information architecture.

- Default eyes are upright white rounded squares rather than paired diagonal capsules.
- The header avatar has no Liquid Glass enclosure; the iTalk name below retains its glass capsule.
- Idle returns to a blue circle. Active acting may morph it into a soft squircle or subtly tapered rounded shape.
- Happy, reassuring, sad, curious and serious performances change eyes, shape, palette and liquid together.
- No repeating vertical bounce or word-triggered vertical translation. Meter input is smoothed before reaching the fluid or shape.
- Pose and RGB palette transitions converge from their currently displayed values, so rapid phrase changes do not jump to an old target.
- Liquid stays clipped inside the current shape. Eyes are drawn after blur layers. Reduced Motion pauses autonomous motion but preserves legible state changes.

## Speech synchronization

`SpeechExpressionPlan` analyzes the normalized text actually sent to the device speech provider. It uses deterministic local phrase rules for the assistant's own expression, not user emotion recognition or a new AI emotion model. Clauses use UTF-16 offsets, so emoji do not move subsequent expressions out of sync. Emotion carries over commas and resets at sentence boundaries unless another cue supplies an intent.

`SpeechOutput` publishes expression cues on real AVSpeechSynthesizer utterance-start and speech-range callbacks. Plans are bound to current utterance identities and cleared before cancellation. AppModel checks turn generation and speaking phase before applying them. Existing selected voice, supported style presets, local-model hooks and conversation storage were preserved.

No fake mouth, fabricated phoneme alignment or claim of human-quality emotional audio is added. Apple's system speech still has limited prosody controls. Cloud playback has no word timestamps in the current API, so it continues to use overall delivery metadata and actual playback level; precise per-clause cloud alignment is not claimed.

## Verification

- AssistantCore: all 26 tests passed, including phrase transitions, comma carry, negation examples, UTF-16 emoji offsets and invalid-range fallback.
- iOS 26.5: three focused UI tests passed: 6 emotion palettes, 13 performances, and a new real-speech test observing happy -> calm -> serious before cancellation. Cancellation left the word counter unchanged.
- After the final RGB interpolation change, the real-speech/cancellation UI test passed again: `build/UI-expression-v9-final26.xcresult`.
- Built simulator and physical-device targets successfully. Installed and launched the final build on the paired iPhone.
- Inspected native character screenshots and light/dark conversation headers under `build/previews/expression-v9-final/`.
- No video was recorded, per the user's instruction.
- No frame-time/energy benchmark, exhaustive sentiment evaluation, live cloud emotion synthesis or latest iOS 27 simulator pass was performed. Physical-device end-to-end conversation animation still requires manual experience; install/launch alone does not verify that interaction.

Only Codex's UI/speech integration and AssistantCore expression files were edited. Claude-owned model/runtime, downloads, conversations and project-generation files were not changed.
