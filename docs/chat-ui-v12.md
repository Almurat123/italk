# Chat UI v12

Updated: 2026-10-27

## Changes

- Removed the separately measured streaming tail spacer. The newest turn now owns
  a minimum viewport height, so short replies grow without resizing scroll content.
- Assistant text measures against a fixed column width. Only committed scroll
  content-height growth schedules automatic following, not each arriving token.
- Row updates do not inherit animations. Automatic scrolling cannot change the
  user's manual-follow preference through an unrelated idle phase callback.
- Microphone stays left inside the composer; send stays right and becomes stop
  during generation/readout. The standalone stop row was removed, keeping composer
  height stable when generation starts or finishes. Empty send has a disabled style.
- Sidebar search changes from filled to native interactive glass on focus. Sort and
  selection controls use small glass capsules. Compose has a 38-point visible glass
  background within its existing 44-point hit target.
- History context menus use a separate preview constrained by measured drawer width.
- App-window taps, long presses, and native slider/picker adjustment completion use
  medium impact feedback. Observers neither cancel nor delay touches. Ordinary
  scrolling does not emit impacts; hold-to-talk feedback is deduplicated.

## Parallel work boundary

Production changes are confined to AssistantView.swift, ChatComponents.swift,
ConversationSidebar.swift, OutsideKeyboardDismissal.swift and focused UI tests.
Claude's runtime, model, storage and voice-pipeline source files were not modified.

The integrated build currently encounters VoiceTimeline migration errors: AppModel
still accesses removed Date properties such as lastPartial, speechEnd and firstToken.
For UI-only validation, build/UIRevisionQA contains a compiler-overlay copy of the
timeline with compatibility fields. This is an ignored, disposable QA fixture; it
does not modify production source and must not be installed as a release build.
Its voice timings are not an integration/voice-pipeline verification.

## Checks

- Native haptic observer passes standalone iOS Simulator SDK type checking.
- Changed Swift UI and test sources pass syntax parsing.
- Five isolated UI regressions passed in build/UI-v12-isolated-fix26.xcresult:
  first text/image top placement, native selection/copy/readout/cancellation,
  history sorting/select-all/delete/undo/archive, focused search/bounded context
  preview, and streaming continuation/manual scrolling.
- Focused dark-mode search and lifted-history preview screenshots were inspected.
  Both the preview and action menu remain within the drawer boundary.
- The first automated streaming measurement incorrectly assumed a still-short
  reply at a token threshold; the model fixture had already grown past a viewport.
  The revised check tests the visible frame plus actual scroll geometry instead.
- The sixth focused regression passed in build/UI-v12-stream-audit26.xcresult:
  microphone left, send/stop right, common composer alignment, fixed reply width,
  no visible downward rebound, and stopping/restoring the send control.
- Actual scroll audit: 153 samples, 150 checked after viewport settling, maximum
  backward offset 0 points and maximum content-height shrink 0 points. Replay with
  `node scripts/check-stream-layout.mjs docs/benchmarks/chat-stream-layout-v12-simulator-2026-10-27.json`.
- The audit contains only elapsed time, viewport/content height and scroll offset.
  It is not a measurement of live model inference or rendered-screen frame rate.
- Light-mode composer was visually inspected. Physical haptic feel and a current
  production build/install remain unverified until the parallel voice migration
  compiles without the QA overlay.
