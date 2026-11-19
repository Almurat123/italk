import { randomUUID } from 'node:crypto';
import { CloudError } from './cloud.mjs';

// CONTEXT MEMORY
// Updated: 2026-11-02
// Status: inferred
// Why: Computer-hosted inference must not silently use a remote Ollama cloud model.
// Debug Goal: Detect and run only locally installed models over loopback.
// Search Tags: ollama loopback local model discovery cloud exclusion
// Invariants:
// - The endpoint is fixed to the local machine and redirects are refused.
// - Cloud aliases and model records with remote metadata are never offered or run.
// Failure Modes:
// - A remote Ollama model could be presented as private on-device inference.
const BASE = 'http://127.0.0.1:11434';
const isCloudName = name => /(?:[:@-]cloud)(?::|$)/i.test(name);
const isRemote = record => Boolean(record?.remote_model || record?.remote_host || record?.details?.remote_model || record?.details?.remote_host);

export class OllamaAccess {
  constructor({ fetcher = fetch } = {}) { this.fetcher = fetcher; }
  get configured() { return true; }
  describe() { return { configured: false }; }

  async verify() {
    try {
      const response = await this.fetcher(`${BASE}/api/tags`, { signal: AbortSignal.timeout(3000), redirect: 'error' });
      if (!response.ok) throw new Error('model list failed');
      const body = await response.json();
      const candidates = (Array.isArray(body.models) ? body.models : []).filter(m => typeof m.name === 'string' && !isCloudName(m.name) && !isRemote(m)).slice(0, 30);
      const details = await Promise.all(candidates.map(async model => {
        try {
          const result = await this.fetcher(`${BASE}/api/show`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ model: model.name }), signal: AbortSignal.timeout(3000), redirect: 'error' });
          if (!result.ok) return null;
          const detail = await result.json();
          if (isRemote(detail) || !Array.isArray(detail.capabilities) || !detail.capabilities.includes('completion')) return null;
          const meta = detail.model_info ?? {};
          const context = Object.entries(meta).find(([key, value]) => key.endsWith('.context_length') && Number.isSafeInteger(value))?.[1];
          return { id: model.name, name: model.name, developer: 'Ollama', contextTokens: context ?? null, supportsTools: detail.capabilities.includes('tools'), supportsImages: false, supportsReasoning: detail.capabilities.includes('thinking') };
        } catch { return null; }
      }));
      const models = details.filter(Boolean);
      return { ok: models.length > 0, code: models.length ? null : 'local_no_supported_models', models };
    } catch { return { ok: false, code: 'local_unavailable', models: [] }; }
  }
}

export class OllamaModelClient {
  constructor({ access, fetcher = fetch }) { this.access = access; this.fetcher = fetcher; }

  async step({ model, messages, tools, maxTokens, reasoningEffort = 'none', signal, onText, onReasoning }) {
    const verified = await this.access.verify();
    if (!verified.models.some(m => m.id === model)) throw new CloudError('local_model_unavailable', 'The selected local model is unavailable.');
    const calls = new Map();
    const translated = messages.map(message => {
      if (message.role === 'tool') return { role: 'tool', content: message.text ?? '', tool_name: calls.get(message.toolCallId) ?? '' };
      const out = { role: message.role, content: message.text ?? '' };
      if (message.role === 'assistant' && typeof message.reasoningContent === 'string') out.thinking = message.reasoningContent;
      if (message.toolCalls?.length) out.tool_calls = message.toolCalls.map(call => {
        calls.set(call.id, call.name);
        let args; try { args = JSON.parse(call.arguments); } catch { args = {}; }
        return { function: { name: call.name, arguments: args } };
      });
      return out;
    });
    let response;
    try {
      response = await this.fetcher(`${BASE}/api/chat`, { method: 'POST', headers: { 'content-type': 'application/json' }, redirect: 'error', signal,
        body: JSON.stringify({ model, messages: translated, tools: tools.map(t => ({ type: 'function', function: t })), stream: true, think: reasoningEffort !== 'none', options: { num_predict: maxTokens } }) });
    } catch (error) { if (signal?.aborted) throw error; throw new CloudError('local_unavailable', 'Cannot connect to the local model service.'); }
    if (!response.ok || !response.body) throw new CloudError('local_model_error', `The local model returned HTTP ${response.status}.`);
    let buffer = '', text = '', reasoning = '', usage = null, complete = false;
    const decoder = new TextDecoder();
    const toolCalls = [];
    const readLine = line => {
      if (!line.trim()) return;
      let part; try { part = JSON.parse(line); } catch { throw new CloudError('local_model_error', 'The local model returned invalid streaming data.'); }
      if (isRemote(part)) throw new CloudError('local_model_error', 'The model service reported a remote model; local execution stopped.');
      if (part.error) throw new CloudError('local_model_error', String(part.error).slice(0, 200));
      const message = part.message ?? {};
      if (typeof message.content === 'string') { text += message.content; onText?.(message.content); }
      if (typeof message.thinking === 'string') { reasoning += message.thinking; onReasoning?.(message.thinking); }
      for (const call of message.tool_calls ?? []) {
        if (typeof call?.function?.name !== 'string') continue;
        const args = call.function.arguments ?? {};
        toolCalls.push({ id: randomUUID(), name: call.function.name, arguments: typeof args === 'string' ? args : JSON.stringify(args) });
      }
      if (part.done) {
        complete = true;
        const counts = {};
        if (Number.isFinite(part.prompt_eval_count)) counts.inputTokens = part.prompt_eval_count;
        if (Number.isFinite(part.eval_count)) counts.outputTokens = part.eval_count;
        usage = Object.keys(counts).length ? counts : null;
      }
    };
    for await (const chunk of response.body) {
      buffer += decoder.decode(chunk, { stream: true });
      if (buffer.length > 2_000_000) throw new CloudError('local_model_error', 'The local model returned an oversized response.');
      let index; while ((index = buffer.indexOf('\n')) >= 0) { readLine(buffer.slice(0, index)); buffer = buffer.slice(index + 1); }
    }
    buffer += decoder.decode();
    if (buffer.trim()) readLine(buffer);
    if (!complete) throw new CloudError('local_stream_interrupted', 'The local model stopped before completing its response.');
    return { model, text, reasoning, toolCalls, usage, finish: toolCalls.length ? 'toolCalls' : 'stop' };
  }
}
