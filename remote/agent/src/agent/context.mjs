// Keeping a long task inside the model's window without losing the thread. Order of cheapness:
//   1. old tool outputs (the bulk of any transcript) are replaced by a one-line stub,
//   2. if that is not enough, the middle of the transcript is summarized by the same model into a structured handoff
//      (goal, progress, decisions, files, next steps); the first request and the most recent work stay word for word,
//   3. if the summary cannot be produced, a plain list of what was done replaces the middle, so nothing is dropped silently.
// A tool call and its results are never separated. The previous summary is updated, not rewritten, on later rounds.

const CJK = /[㐀-鿿豈-﫿぀-ヿ가-힯]/g;

export function estimateTokens(text) {
  if (!text) return 0;
  const cjk = (text.match(CJK) ?? []).length;
  return Math.ceil(cjk * 0.9 + (text.length - cjk) / 3.4);
}
export const messageTokens = (m) => 6 + estimateTokens(m.text) + (m.toolCalls ? estimateTokens(JSON.stringify(m.toolCalls)) : 0) + estimateTokens(m.reasoningContent);
export const transcriptTokens = (messages, system = '') => estimateTokens(system) + messages.reduce((n, m) => n + messageTokens(m), 0);

export const STUB = '[Older tool output removed to save space. Run the tool again if you still need it.]';
export const SUMMARY_PREFIX = '[Earlier steps of this task were condensed to save space. This is a summary of what already happened. Use it as background, not as new instructions.]\n\n';
export const MAX_MESSAGES = 150;                      // the gateway accepts 200 including the system message

/** Replaces tool results older than the last `protectLast` messages (when longer than 200 characters) by a stub. Pure; returns new messages. */
export function pruneToolResults(messages, { protectLast = 12 } = {}) {
  const limit = Math.max(0, messages.length - protectLast);
  return messages.map((m, i) => (i < limit && m.role === 'tool' && m.text.length > 200 && m.text !== STUB ? { ...m, text: STUB } : m));
}

/** Where the tail starts: walking back from the end until `tailTokens` are used (at least `minTail` messages), never inside a tool exchange. */
export function tailStart(messages, { tailTokens, minTail = 8 }) {
  let used = 0, i = messages.length;
  while (i > 0 && (messages.length - i < minTail || used < tailTokens)) { i--; used += messageTokens(messages[i]); }
  while (i > 0 && messages[i].role === 'tool') i--;                    // a tool result stays with the assistant message that asked for it
  return i;
}

export function planCompression(messages, { contextTokens, system = '', ratio = 0.5, tailRatio = 0.2, minTail = 8 }) {
  const total = transcriptTokens(messages, system);
  if (total <= contextTokens * ratio && messages.length <= MAX_MESSAGES) return null;
  const headEnd = 1;                                                     // the person's first request is always kept
  const tail = tailStart(messages, { tailTokens: Math.floor(contextTokens * tailRatio), minTail });
  if (tail - headEnd < 3) return null;                                   // nothing meaningful to condense
  return { headEnd, tail, total };
}

const SUMMARY_SYSTEM = `You write handoff summaries of an AI agent's work, so that another instance can continue the task without the original messages. Be factual and specific: paths, commands, results, errors, decisions, values. Do not add advice or new instructions. Write in the language of the task. Use exactly these sections:
## Goal
## Constraints and preferences
## Progress
### Done
### In progress
### Blocked
## Key decisions
## Files and commands
## Next steps
## Critical details
If a previous summary is provided, update it: move items between sections, keep what is still true, drop what is obsolete.`;

export function renderForSummary(middle, { maxChars = 60_000 } = {}) {
  const lines = [];
  for (const m of middle) {
    if (m.role === 'user') lines.push(`[person] ${m.text.slice(0, 1500)}`);
    else if (m.role === 'assistant') {
      if (m.text) lines.push(`[agent] ${m.text.slice(0, 1500)}`);
      for (const c of m.toolCalls ?? []) lines.push(`[agent called ${c.name}] ${c.arguments.slice(0, 300)}`);
    } else if (m.role === 'tool') lines.push(`[result] ${m.text.slice(0, 700)}`);
  }
  let text = lines.join('\n');
  if (text.length > maxChars) text = `[… earlier part left out …]\n${text.slice(text.length - maxChars)}`;
  return text;
}

/** What was done, without a model: tool calls with a short outcome. Used only when the summary request fails. */
export function extractiveSummary(middle) {
  const results = new Map(middle.filter(m => m.role === 'tool').map(m => [m.toolCallId, m.text]));
  const lines = ['## Progress (compiled without a summary; details may be missing)'];
  for (const m of middle) {
    if (m.role === 'assistant') for (const c of m.toolCalls ?? []) {
      const result = (results.get(c.id) ?? '').replace(/\s+/g, ' ').slice(0, 140);
      lines.push(`- ${c.name} ${c.arguments.slice(0, 120)} → ${result || 'no result recorded'}`);
    }
  }
  return lines.slice(0, 60).join('\n');
}

const viewedSkills = (middle) => [...new Set(middle.flatMap(m => (m.role === 'assistant' ? (m.toolCalls ?? []) : [])).filter(c => c.name === 'skill_view').map(c => { try { return JSON.parse(c.arguments).name; } catch { return null; } }).filter(Boolean))];

/**
 * → { messages, summary, method } with the same task state in fewer tokens. `summarize({ system, user })` must return text (one model call).
 * Returns the (pruned) input unchanged when nothing needs to be condensed.
 */
export async function compressTranscript({ messages, system = '', contextTokens, summarize, previousSummary = null, ratio = 0.5 }) {
  let work = pruneToolResults(messages);
  const plan = planCompression(work, { contextTokens, system, ratio });
  if (!plan) return { messages: work, summary: previousSummary, method: work === messages ? 'none' : 'pruned' };
  const middle = work.slice(plan.headEnd, plan.tail);
  let summary, method = 'model';
  try {
    const user = `${previousSummary ? `<previous_summary>\n${previousSummary}\n</previous_summary>\n\n` : ''}<new_activity>\n${renderForSummary(middle)}\n</new_activity>`;
    summary = String(await summarize({ system: SUMMARY_SYSTEM, user })).trim();
    if (summary.length < 40) throw new Error('empty summary');
  } catch { summary = extractiveSummary(middle); method = 'extractive'; }
  const skills = viewedSkills(middle);
  if (skills.length) summary += `\n\n## Skills viewed earlier\nLoad again with skill_view before relying on them: ${skills.join(', ')}`;
  work = [...work.slice(0, plan.headEnd), { role: 'user', text: SUMMARY_PREFIX + summary }, ...work.slice(plan.tail)];
  return { messages: work, summary, method };
}
