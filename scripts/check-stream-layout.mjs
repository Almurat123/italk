import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

// CONTEXT MEMORY
// Updated: 2026-10-27
// Status: inferred
// Why: Accessibility clips an offscreen reply frame and can hide vertical rebounds.
// Debug Goal: Check actual scroll geometry during the deterministic no-manual-scroll stream.
// Search Tags: streaming bubble jitter actual scroll offset viewport stable
// Invariants:
// - This consumes only the DEBUG simulator geometry audit, never conversation content.
// - Keyboard viewport changes get a settling interval before monotonic checks resume.
// Failure Modes:
// - Treating a clipped accessibility frame at y=0 as proof of stable scrolling.
// - Mistaking the intentional keyboard-resize transition for a token rebound.
const path = process.argv[2];
assert(path, 'Pass ui-streaming-layout.json from the simulator fixture');
const samples = JSON.parse(readFileSync(path, 'utf8'));
let previous, stableSince = 0, checked = 0, maxRebound = 0, maxHeightShrink = 0;
for (const sample of samples) {
  if (previous) {
    if (Math.abs(sample.viewport - previous.viewport) > 0.5) stableSince = sample.elapsed;
    if (sample.elapsed >= stableSince + 1) {
      checked++;
      maxRebound = Math.max(maxRebound, previous.offset - sample.offset);
      maxHeightShrink = Math.max(maxHeightShrink, previous.height - sample.height);
    }
  }
  previous = sample;
}
const report = { samples: samples.length, checked, maxRebound, maxHeightShrink };
console.log(JSON.stringify(report, null, 2));
assert(checked >= 20, 'Insufficient settled streaming samples');
assert(maxRebound <= 2, 'Scroll offset moved backward during streaming');
assert(maxHeightShrink <= 2, 'Content height shrank during streaming');
