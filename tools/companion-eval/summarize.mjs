#!/usr/bin/env node
// Summarizes CompanionCueEvalTests output (one JSON per model/run) into the numbers that go to docs/measurements/.
//   node tools/companion-eval/summarize.mjs <out.json> <result.json> [<result.json> …]
import { readFileSync, writeFileSync } from 'node:fs';

const INTENTS = ['curious', 'focused', 'explaining', 'encouraging', 'comforting', 'playful', 'celebrating', 'apologetic', 'cautious', 'uncertain'];
const TAG_LIKE = /[\[［【〔]\s*(tone|语气)\s*[:：=]/i;                  // anything that looks like an attempt at the protocol
const LEAK = /(tone|语气)\s*[:：=]\s*[A-Za-z_\-]+|[\[［【〔]\s*(tone|语气)/i;   // protocol text still visible after the runner's filter
const MENTION = /语气标注|标注语气|tone 标注|tone标注|\[tone/i;

const pct = (a, b) => (b === 0 ? null : Math.round((a / b) * 1000) / 10);
const mean = xs => (xs.length ? Math.round((xs.reduce((s, x) => s + x, 0) / xs.length) * 100) / 100 : null);

function summarize(file) {
  const data = JSON.parse(readFileSync(file, 'utf8'));
  // Rows that did not complete, and rows where the model wrote tool-call markup as plain text (this harness sends no tool schemas to a
  // cloud model, so a tool-hungry prompt can produce markup instead of an answer), say nothing about tone and are excluded.
  const MARKUP = /DSML|<tool_call>|<function=/i;
  const rows = data.rows.filter(r => r.state === 'completed' && !MARKUP.test(r.raw));
  const failed = data.rows.filter(r => r.state !== 'completed').length;
  const toolMarkup = data.rows.filter(r => r.state === 'completed' && MARKUP.test(r.raw)).length;
  const labels = r => r.segments.map(s => s.label).filter(l => INTENTS.includes(l));
  const byCategory = {};
  for (const r of rows) (byCategory[r.category] ??= []).push(r);

  const categories = {};
  for (const [name, rs] of Object.entries(byCategory)) {
    const tagged = rs.filter(r => labels(r).length > 0);
    const accept = rs[0].accept ?? [];
    const agree = tagged.filter(r => labels(r).every(l => accept.includes(l)));
    categories[name] = {
      n: rs.length,
      taggedRatePct: pct(tagged.length, rs.length),
      // Among tagged answers: every declared tone is one a reasonable reply may carry. (Not defined for facts: any tag there is an over-tag.)
      agreementPct: accept.length ? pct(agree.length, tagged.length) : null,
      labels: Object.fromEntries(INTENTS.map(i => [i, rs.reduce((n, r) => n + labels(r).filter(l => l === i).length, 0)]).filter(([, n]) => n > 0)),
      meanCompletionTokens: mean(rs.map(r => r.completionTokens)),
      meanSeconds: mean(rs.map(r => r.seconds)),
    };
  }
  const facts = rows.filter(r => r.category === 'fact');
  const expressive = rows.filter(r => r.category !== 'fact');
  const attempted = rows.filter(r => TAG_LIKE.test(r.raw));
  const leaked = rows.filter(r => LEAK.test(r.clean));
  const parsed = rows.filter(r => labels(r).length > 0);
  return {
    model: data.model, cuesOn: data.cuesOn, samplesPerPrompt: data.samples, date: data.date,
    rows: data.rows.length, completed: rows.length, notCompleted: failed, excludedToolMarkup: toolMarkup,
    // How often the model wrote the protocol at all, and how often the runner could use it.
    attemptedRatePct: pct(attempted.length, rows.length),
    usableRatePct: pct(parsed.length, rows.length),
    expressiveTaggedPct: pct(expressive.filter(r => labels(r).length > 0).length, expressive.length),
    factOverTagPct: pct(facts.filter(r => labels(r).length > 0).length, facts.length),
    agreementPct: pct(expressive.filter(r => labels(r).length > 0 && labels(r).every(l => (r.accept ?? []).includes(l))).length,
                      expressive.filter(r => labels(r).length > 0).length),
    // Protocol text still visible in what the person would see/hear after the filter.
    leakRatePct: pct(leaked.length, rows.length), leakedIds: leaked.map(r => `${r.id}#${r.sample}`),
    mentionRatePct: pct(rows.filter(r => MENTION.test(r.clean)).length, rows.length),
    meanCompletionTokens: mean(rows.map(r => r.completionTokens)), meanPromptTokens: mean(rows.map(r => r.promptTokens)),
    meanSeconds: mean(rows.map(r => r.seconds)),
    categories,
    examples: rows.filter(r => labels(r).length > 0).slice(0, 8).map(r => ({ id: r.id, tags: labels(r), text: r.clean.slice(0, 80) })),
    misses: rows.filter(r => r.category !== 'fact' && labels(r).length === 0).slice(0, 6).map(r => ({ id: r.id, text: r.clean.slice(0, 80) })),
  };
}

const [out, ...files] = process.argv.slice(2);
if (!out || files.length === 0) { console.error('usage: summarize.mjs <out.json> <result.json>…'); process.exit(2); }
const summaries = files.map(summarize);
writeFileSync(out, JSON.stringify({ generated: new Date().toISOString(), note: 'Constructed prompts (tools/companion-eval/prompts.json); tags are model-declared; agreement = every declared tone is in the accepted set for the category.', summaries }, null, 1) + '\n');
for (const s of summaries) {
  console.log(`${s.model} cues=${s.cuesOn ? 'on' : 'off'}: analysed ${s.completed}/${s.rows} (${s.notCompleted} not completed, ${s.excludedToolMarkup} tool markup); tagged(expressive) ${s.expressiveTaggedPct}%  agreement ${s.agreementPct}%  fact over-tag ${s.factOverTagPct}%  leak ${s.leakRatePct}%  mention ${s.mentionRatePct}%  tokens ${s.meanCompletionTokens}  ${s.meanSeconds}s`);
}
