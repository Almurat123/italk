// Text that reaches the model from outside the conversation (project instruction files, skills, web pages) is data. These checks do not
// make it trustworthy; they catch the obvious attempts early and tell the person, and everything that survives is still only read as data.

const INVISIBLE = /[​-‏‪-‮⁠-⁤⁦-⁩﻿]/;
const RULES = [
  [/ignore\s+(?:all\s+|any\s+|the\s+)?(?:previous|prior|above|earlier|preceding)\s+(?:instructions?|prompts?|rules|messages)/i, 'tries to override earlier instructions'],
  [/disregard\s+(?:all\s+|any\s+|the\s+)?(?:previous|prior|above|earlier|system)/i, 'tries to override earlier instructions'],
  [/(?:忽略|无视|不要理会|忘掉)[^。\n]{0,12}(?:以上|之前|前面|上述|先前)[^。\n]{0,8}(?:指令|提示|规则|要求|说明)/, 'tries to override earlier instructions'],
  [/(?:reveal|print|show|repeat|output|leak)\s+(?:your\s+|the\s+)?(?:system|hidden|initial|secret)\s+(?:prompt|instructions?)/i, 'asks for the hidden instructions'],
  [/you\s+are\s+now\s+(?:in\s+)?(?:developer|dan|jailbreak|unrestricted|god)\s*mode/i, 'tries to change the assistant\'s role'],
  [/(?:send|post|upload|exfiltrate|email|leak|transmit)\s[^\n]{0,80}(?:password|passwd|token|secret|api[_ -]?key|ssh[_ -]?key|credential|\.env|keychain)/i, 'asks to send secrets somewhere'],
  [/curl[^\n|]*\|\s*(?:ba|z)?sh\b/i, 'pipes a download into a shell'],
  [/<!--[\s\S]{0,600}?(?:ignore|instruction|system prompt|assistant)[\s\S]{0,600}?-->/i, 'hides instructions in a comment'],
];

export function scanForInjection(text) {
  const reasons = new Set();
  if (typeof text !== 'string') return { flagged: false, reasons: [] };
  if (INVISIBLE.test(text)) reasons.add('contains invisible control characters');
  for (const [pattern, why] of RULES) if (pattern.test(text)) reasons.add(why);
  return { flagged: reasons.size > 0, reasons: [...reasons] };
}

/** Head and tail are kept (70 % / 20 %), the middle is replaced by a marker. */
export function truncateMiddle(text, limit) {
  if (text.length <= limit) return text;
  const head = Math.floor(limit * 0.7), tail = Math.floor(limit * 0.2);
  return `${text.slice(0, head)}\n\n[… ${text.length - head - tail} characters left out …]\n\n${text.slice(text.length - tail)}`;
}
