// Server-Sent Events over a fetch body: yields one parsed JSON value per `data:` event (and the SSE `id` / `event` fields).

export async function* parseSSE(body, signal) {
  const reader = body.getReader(), decoder = new TextDecoder();
  let pending = '';
  const onAbort = () => { try { reader.cancel().catch(() => {}); } catch {} };
  signal?.addEventListener('abort', onAbort, { once: true });
  try {
    for (;;) {
      const { done, value } = await reader.read();
      pending += done ? decoder.decode() : decoder.decode(value, { stream: true });
      pending = pending.replace(/\r\n/g, '\n');
      if (pending.length > 1_000_000) throw Object.assign(new Error('event too large'), { code: 'provider_event_too_large' });
      let boundary;
      while ((boundary = pending.indexOf('\n\n')) >= 0) {
        const block = pending.slice(0, boundary); pending = pending.slice(boundary + 2);
        const lines = block.split('\n');
        const data = lines.filter(l => l.startsWith('data:')).map(l => l.slice(5).trimStart()).join('\n');
        if (!data || data === '[DONE]') continue;
        const id = lines.find(l => l.startsWith('id:'))?.slice(3).trim(), event = lines.find(l => l.startsWith('event:'))?.slice(6).trim();
        yield Object.assign(JSON.parse(data), { __sse: { id, event } });
      }
      if (done) break;
    }
  } finally { signal?.removeEventListener('abort', onAbort); try { reader.releaseLock(); } catch {} }
}
