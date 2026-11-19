# iTalk character reference study

Date: 2026-10-26
Status: capsule-eye renderer implemented; build and state checks passed.

## Current revision: official geometric character

The user rejected the cartoon face even after the solid-color correction and
explicitly requested the supplied Grok Bot appearance. Reopened the official
lifecycle demo, paused its tour and selected Idle, Working, Waiting, Blocked,
Thinking and Done. Also switched the website to dark mode. Idle
shows a nearly black circle with two inclined white capsule eyes, positioned
toward the upper right. Working changes their orientation; Waiting flattens
the eyes. Thinking becomes three dots, and Blocked becomes an exclamation mark.
Dark mode reverses the neutral character to white with black eyes.

Replaced the prior renderer rather than retaining its face rig. The native
`CapsuleOrb` draws only a solid circle and two white rounded strokes. There are
no pupils, eyebrows, mouth, hands, ground shadow, shell, or interior effects.
Rest uses the black lifecycle appearance (reversed in dark mode). Emotion can
change the uniform fill; 13 app states animate capsule position, tilt, opening,
curved eyes, body movement and lifecycle symbols. Thinking and failure morph
into the observed dots and exclamation mark. Color changes and expressions are
app mappings, not a claim of
pixel-identical recreation of every official animation frame. No external code
or graphics are embedded.

The renderer stays inside the existing SwiftUI Canvas/TimelineView; the screen
container, header transition and recording/audio state ownership are unchanged.
The page's job is to make current voice interaction state immediately readable.
Claude's concurrently added inference packages and project integration are kept.

This supersedes all earlier character videos and the concept art board below.

Validation: integrated iPhone build passed, preserving the concurrent model
integration. Three focused UI tests passed on iOS 26.5 in
`build/UI-capsule-final26.xcresult`: automatic changes, six emotion selections
and 13 performance states. A subsequent capsule geometry correction makes
closed eyes remain visible as short rounded strokes; its native ImageRenderer
light/dark contact sheets are in `build/previews/capsule-expression-sheet-*.png`.
Those sheets render the actual SwiftUI component, not generated concept art.
Final iPhone artifact was rebuilt after that correction. Its 13-state UI retest
passed in `build/UI-capsule-release26.xcresult`; inspected the actual iOS rest,
listening and thinking captures. Installed the final artifact on the paired
iPhone. Initial launch was denied because the phone was locked; this is not a
successful launch verification. Requested an unlock without changing device
security settings. The inference integration was not exercised by these tests.
The final iOS 26.5 dark screenshot confirms the white body and black capsule
eyes. The iOS 27 simulator install did not respond; stopped only this revision's
own pending simulator commands rather than disturbing Claude's simulator. Do
not count that as an iOS 27 runtime pass. Motion recording is saved as
`build/previews/capsule-orb-current.mp4` and shows the actual native preview;
it contains no synthesized emotional audio and is not an exact-frame match test.

## Previous revision: clean interior (rejected)

Reopened the official article on 2026-10-26 and inspected its final geometric
character gallery. The user rejected the intervening blue gradient and flowing
ribbons. `apps/iOS/VoiceOrbView.swift` now draws one uniform fill for the body
and both hands, without gradients, ribbons, texture, or a shell outline. Each
emotion changes the whole fill through a smooth transition. The page stays
neutral. That revision retained the cartoon face and hands, which the user
subsequently rejected. It is not the current implementation.

The reference guides simplicity and motion; no Grok artwork or source was copied.
This correction supersedes the textured material study in
`docs/art/character-performance-study-v1.png`.

Validation: simulator build and three focused UI checks passed on iOS 26.5:
12 performance selections, six emotion palettes, and automatic performance
changes. Result: `build/UI-solid-character26.xcresult`. Inspected captured rest
and listening frames to confirm uniform fill and matching hands. Physical-device
build also passed with the existing signing team; installed and launched on the
paired iPhone. Checked light and dark rendered frames on iOS 27. Recorded the
current native motion at `build/previews/solid-character-motion.mp4`. This is visual validation,
not a new end-to-end voice-provider test or a claim that prior unrelated UI
failures were repaired by a palette change.

## Corrected brief

The user rejected the faceless silver sphere and supplied the authoritative
[Grok Bot design article](https://x.ai/news/designing-grok-bot).
The article's actual rendered characters use flat, solid geometric silhouettes,
expressive eyes, and a quiet neutral stage. They communicate identity and task
state through posture and motion. The previous ceramic-material interpretation
was incorrect. This study supersedes that direction in the revision 4 audit.

Preserve native glass for app controls. The character itself needs a recognizable
silhouette and face. An independent iTalk design should establish its own shape,
eye proportions, palette, and motion rather than modifying a branded asset.

## Inspected references

| Reference | Evidence inspected | Useful principle | Limits |
| --- | --- | --- | --- |
| [Grok Bot official design article](https://x.ai/news/designing-grok-bot) | Browser-rendered shape gallery; paused lifecycle tour; selected Idle and Working. | Small-scale recognition; eyes and body carry identity/state; quiet background. | Primary direction supplied by user, not an asset source. |
| [nasawz/GrokBot](https://github.com/nasawz/GrokBot) and [interactive web port](https://coiggahou2002.github.io/grokbot-web/) | GitHub README and BSD-3-Clause metadata; actual web playground changed from thinking to listening and invoked Blink. The playground exposes 25 expressions, 18 shapes, and 39 states. | Separate body, expression, gaze, blink, and state cadence. | Unofficial recreation of the same visual family, not an independent design. No code or point tables imported. |
| [Copilot Mico by Psyop](https://www.psyop.com/work/microsoft-ai-mico) | Creator's case study, rendered hero character, expression/motion process description. | Soft silhouette and restrained emotional response; a character with presence. | Fuller face and more material detail than Grok. Useful for motion and softness, not the default iTalk silhouette. No live Copilot session tested. |
| [Robot - expressions by Deborah Oliveira](https://rive.app/community/files/18720-35184-robot-expressions/) | Live Rive canvas; clicked Sad and observed eyes/mouth/body change. Page declares five expressions and CC BY. | State-driven face/posture; smooth expression changes; spatial movement instead of a loading-spinner substitute. | Full robot body and accessories add too much detail for a 36-point header avatar. Do not reuse the asset. |
| [Tilo by Manu Cabezas](https://contra.com/p/WNo2MA6O-buen-hogar-or-interactive-rive-mascot) | Creator's page and embedded video poster. Describes separate blink/breathing layers, gaze/head controls and blended state transitions. | One character system can support close-up/avatar and large presentation. | Full-body character, less similar in silhouette. Runtime state transitions were documented, not interactively verified. |
| [Expression Grid by erdemediz](https://www.rive.app/marketplace/24941-46557-expression-grid/) | Research agent inspected the author's static preview and CC BY declaration: flat expressions on solid red; creator describes separate eye/mouth/brow components. | Parameterized facial expression with no realistic material. | Static preview only; mouth/brow treatment is more exaggerated than the desired minimal character. |
| [Inflating blob by r.vd.winden](https://rive.app/community/files/8279-15838-inflating-blob/) | Creator's page and CC BY declaration; tags describe eyes, tracking and elastic shape. | Potential secondary reference for stretch/recovery. | Preview remained blank during inspection; do not claim its runtime motion was observed. |

## Implementation direction

- One original rounded silhouette, a solid body color, readable eyes and gentle
  deformation. Avoid the rejected metallic highlight, rigid shell, or cloud noise.
- Design and inspect both 36-point header size and approximately 280-point voice
  size. Preserve the same identity between them.
- Idle: occasional blink and subtle gaze. Listening: attentive orientation with
  bounded real-audio response. Thinking: distinct gaze/posture. Speaking: light
  body rhythm. Cancellation/error: brief, readable reaction and recovery.
- App phase drives the state. Decorative idle motion must not imply recording,
  model progress, emotion inference, or capabilities the app does not have.
- Keep one renderer/clock across mode changes, with background blur and a short
  settling transition. Reduced Motion freezes travel and uses restrained fades.

The original criteria above are now implemented by the native Canvas rig.
Visual acceptance remains the user's decision. Prior test results and failures
remain in their original result bundles; they do not establish current coverage.

## Local observation captures

Stored under `build/design-references/` (generated evidence, not app assets):

- `grok-official-shapes.png`
- `grokbot-interactive.png`
- `mico-psyop.png`
- `rive-robot.png`

Search fallback: Agent Reach's configured Exa server was unavailable. Public
web search, Jina Reader, GitHub CLI and browser observation supplied the evidence.
