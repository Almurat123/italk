import { createHash } from 'node:crypto';

// A model that keeps issuing the same failing call burns the person's allowance and goes nowhere. Identical calls are counted per task;
// the third one is not executed and the model is told so in plain words. A tool that keeps failing gets a nudge to change approach.

const canonical = (value) => JSON.stringify(value, (_, v) => (v && typeof v === 'object' && !Array.isArray(v) ? Object.fromEntries(Object.keys(v).sort().map(k => [k, v[k]])) : v));

export class ToolGuard {
  constructor({ maxIdentical = 3, maxFailuresPerTool = 4 } = {}) { Object.assign(this, { maxIdentical, maxFailuresPerTool }); this.recent = []; this.failures = new Map(); }

  signature(name, args) { return createHash('sha256').update(`${name}\n${canonical(args)}`).digest('hex').slice(0, 16); }

  /** → { block: true, message } when this exact call was already made `maxIdentical - 1` times in a row. */
  before(name, args) {
    const sig = this.signature(name, args);
    let run = 0;
    for (let i = this.recent.length - 1; i >= 0 && this.recent[i] === sig; i--) run++;
    this.recent.push(sig); if (this.recent.length > 20) this.recent.shift();
    if (run >= this.maxIdentical - 1) return { block: true, message: `Not run: this exact ${name} call was already made ${run} times in a row. Repeating it will not give a different result. Try a different approach, or tell the person what is blocking you.` };
    return { block: false };
  }

  /** Called with each result; returns an extra sentence to append to the tool result when a tool keeps failing. */
  after(name, ok) {
    if (ok) { this.failures.set(name, 0); return null; }
    const n = (this.failures.get(name) ?? 0) + 1;
    this.failures.set(name, n);
    return n >= this.maxFailuresPerTool ? `\n(${name} has failed ${n} times in this task. Change the approach or explain to the person what is stopping you.)` : null;
  }
}
