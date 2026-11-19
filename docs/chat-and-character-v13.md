# Chat and character v13

Updated: 2026-10-27

Supersedes v11's random ambient character and eight-shape acting cycle.

## Product changes

- Only circle and rounded-square silhouettes are selected. Listening, thinking and
  speaking choose a stable phase pose; phrase emotion can adjust the expression.
  There is no timed pose deck or random header performance. Native layers morph
  from their current pose with continuous interpolation and preserve the liquid clock.
- Sidebar glass control text uses the primary color instead of the accent color.
- Holding speech hides the whole composer while retaining its mounted gesture.
  Release sends after recognition finalizes; upward drag into the visible edit zone
  produces a draft; dragging into/above the higher cancel zone discards capture.
  Actual screen-space zone geometry drives selection. Returning to the lower area
  restores send. Navigation/background cancels pending dictation delivery.
- Image consent and local-vision checks still apply to speech-plus-image sends.
- Sending clears the draft and attachments in a nonanimated transaction. The
  standalone stop row stays removed; microphone/send-or-stop share the composer.
- Keyboard avoidance already reduces the chat's proposed geometry height. Removing
  a second inset subtraction prevents the computed viewport from collapsing to zero.
  First messages keep their date spacing and do not receive a delayed second lift.
- Image placeholders use JPEG metadata aspect ratio from the first layout, avoiding
  a height change when decoding completes.

## Validation

- Six normal-project iOS 26.5 UI checks passed in build/UI-v13-verified26.xcresult:
  character phase preview, first text/image positioning, hold send/edit/cancel,
  sending with the keyboard preserved, sidebar search/context preview, and streaming
  width/vertical stability with inline stop.
- The final screen-space drag-zone adjustment passed again in
  build/UI-v13-release26.xcresult (all three actual press/drag/release paths).
- Send audit: composer stayed at y=475 with height=64; the first turn's y remained
  190.6667 throughout the fixture response. No second position was recorded.
  Raw data: benchmarks/chat-send-layout-v13-simulator-2026-10-27.json.
- Stream audit: 139 samples, 138 settled checks, zero backward scroll movement and
  zero content-height shrink. Raw data: benchmarks/chat-stream-layout-v13-simulator-2026-10-27.json.
- Native screenshots were inspected for sidebar primary text, first image placement,
  the edit draft, and the circle/rounded-square character.
- The final physical-device build succeeded and was installed on the paired iPhone.
  Automatic launch was denied because the phone was locked; final device startup
  and microphone/haptic interaction were not verified.

The simulator's audio graph initialization repeatedly timed out in NeuralSpeechOutput
before UI appeared. UI fixtures and character previews now skip that audio graph only
in DEBUG simulator runs. The normal iPhone path and Claude's audio implementation
are unchanged. The temporary v12 VoiceTimeline compiler overlay is no longer used.

Speech gesture checks inject a known recognition result through the real draft/send
callback. They do not verify microphone recognition quality, neural voice output,
emotion accuracy, real model generation or the physical feel of haptics. No manual
screen recording was performed.
