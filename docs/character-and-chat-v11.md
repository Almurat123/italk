# Character and conversation UI v11

Updated: 2026-10-27

This supersedes the header and limited-shape restrictions in expressive-character-v9.md.
The voice home layout stays intact; this revision changes the character renderer,
text-chat layout, native text interaction and history management.

## Character

- Rounded-square white eyes, blue liquid interior and glass-wrapped header avatar.
- 23 authored performances and eight morphable shapes: circle, squircle, rectangle,
  star, triangle, diamond, drop and cloud. Idle defaults to the circle.
- The chat header randomly picks a different idle performance every 3.2-5.8 seconds.
  Speaking still uses speech expression cues and authored acting sequences.
- Eye size and spacing respond continuously to avatar size and shape. Small header
  avatars and narrow star/triangle poses receive larger, readable eyes.
- A native CADisplayLink updates cached Core Animation layers. Liquid texture blur
  is prepared once, rather than recomputed by SwiftUI Canvas on every frame.
- Reduce Motion and inactive scenes pause autonomous motion. Liquid stays inside
  the character; the surrounding page does not change emotional color.

The renderer was measured on the paired iPhone before the final eye-size adjustment:

| Renderer callback cadence over 10 seconds | Canvas v9 | Layers v10 |
| --- | ---: | ---: |
| Updates/second | 26.67 | 54.74 |
| Median interval, ms | 33.78 | 16.66 |
| 95th percentile interval, ms | 51.70 | 17.09 |
| Intervals above 25 ms | 252 | 1 |

Raw measurements are in benchmarks/orb-canvas-v9-device-2026-10-26.json and
benchmarks/orb-layers-v10-device-2026-10-26.json. These are renderer callback
measurements, not displayed-screen FPS or simultaneous model-inference benchmarks.
The later locked-device launch did not produce a new eye-adjusted measurement.

## Chat and history

- Empty-chat suggestions are centered icon cards using the existing SuggestionEngine.
- New turns anchor at the top. A measured tail spacer also handles first-image turns.
- One coalesced follow task runs at most every 80 ms, without per-token animations.
  Manual scrolling, text selection and the sidebar suspend automatic following.
- The page remains stationary under a material scrim when the sidebar opens. Typed
  generation continues; actual voice sessions stop when opening history.
- Read-only native UITextViews provide real selection handles and native edit menus.
  Ancestor scroll content shapes must not intercept their touches.
- Menus include copy, copy all, selected/full readout, and user-message draft editing.
  Cutting a user selection copies it to the clipboard and loads the remaining text
  and images into a draft; the historical message is not silently rewritten.
- Readout uses the existing Apple speech output and can be stopped, without creating
  another history turn or automatically reopening the microphone.
- History uses a 32-point visible compose control with a 44-point hit target,
  explicit selection, filtered select-all, recent/oldest/title sorting, batch pin,
  archive/delete, and undo for the entire deleted batch.

## Collaboration and verification scope

Claude's model, storage, download and voice-pipeline work is preserved. One narrow
integration compile repair in NeuralVoice.swift separates two awaited actor calls;
Swift's synchronous boolean autoclosure cannot contain the second actor await.
No project regeneration, model replacement or database schema change was needed.

Simulator layout tests inject a DEBUG-only deterministic streaming provider through
the real AppModel and ephemeral conversation store. They exercise UI and storage
integration, not model quality, paid APIs or physical-device inference. No manual
screen recording was requested or run.

## Verification

- All four focused UI tests passed on iOS 26.5: first text/image top placement,
  native selection/copy/readout/cancellation, history title-sort/select-all/batch
  delete/undo/archive, and streaming continuation/manual scroll stability.
- Result: build/UI-chat-v11-final26.xcresult. Xcode's optional simulator diagnostic
  collection stalled after the successful suite; only that diagnostic subprocess
  was terminated to allow report finalization.
- Native selection handles and menu were visually inspected. Empty-chat suggestion
  cards were inspected in both light and dark appearances.
- The final physical-device build succeeded, installed on the paired iPhone, and
  launched in chat mode. The running iTalk process was verified afterward.
- Earlier character checks passed: expanded performances and real speech/cancel
  in build/UI-orb-v10-eyes26.xcresult. Header ambient animation uses the same renderer.
- Paid voice APIs, live local-model inference with this UI, sustained device frame
  presentation, full legacy UI suite, and every native menu overflow action have
  not been verified in this revision. The simulator fixture is not a model benchmark.
