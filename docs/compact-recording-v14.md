# Compact recording UI v14

Updated: 2026-10-27

- Composer order is text, microphone, send/stop. The microphone is immediately left
  of send, rather than at the leading edge of the field.
- Recording removes the original controls' glass effects, disables the attachment
  and keyboard controls, and hides composer content while retaining the active drag.
- The recording HUD is above the safe-area bar. Its wave background extends through
  the former input area; there is no replacement full-width recording text box.
- Cancel and Edit are compact glass capsules with a 104-point minimum width and a
  44-point minimum height. Cancel is visibly red even before selection.
- Recognition text sits above Edit, in a reserved 72-point semantic-font-scaled
  region, so longer recognition cannot push the drag targets around.
- Drag selection uses measured capsule rectangles with a small forgiving margin;
  dragging above Cancel still cancels. Release/send and draft/edit routing remain.

## Verification

Three focused iOS 26.5 tests passed in build/UI-v14-final26.xcresult: the compact
recording layout, all three press/drag/release outcomes, and streaming stability
with microphone/send/stop in the new order. An earlier run caught still-enabled
hidden controls; explicit disabling and hit-testing restrictions fixed that.

Final HUD layer placement and all three gesture routes passed again in dark mode:
build/UI-v14-recording-dark26.xcresult. The final physical-device build succeeded,
installed and launched on the paired iPhone. Gesture tests use deterministic
recognition text and do not verify actual microphone recognition.
