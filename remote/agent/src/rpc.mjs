// Newline-delimited JSON-RPC 2.0 over a child process's stdio (used for ACP).
export class RpcPeer {
  constructor(child, { onRequest = async () => { throw Object.assign(new Error('method not found'), { rpcCode: -32601 }); }, onNotification = () => {}, onClose = () => {} } = {}) {
    this.child = child; this.nextId = 1; this.pending = new Map(); this.onRequest = onRequest; this.onNotification = onNotification; this.closed = false;
    let buf = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1); if (line) this.#handle(line); } });
    child.on('close', (code) => { this.closed = true; for (const p of this.pending.values()) p.reject(Object.assign(new Error('The agent process ended.'), { code: 'agent_exited' })); this.pending.clear(); onClose(code); });
    child.on('error', (e) => { this.closed = true; for (const p of this.pending.values()) p.reject(e); this.pending.clear(); onClose(null, e); });
    child.stdin.on('error', () => {});
  }
  #write(obj) { if (!this.closed) this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...obj }) + '\n'); }
  request(method, params, { timeoutMs } = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = timeoutMs ? setTimeout(() => { this.pending.delete(id); reject(Object.assign(new Error(`${method} timed out`), { code: 'agent_timeout' })); }, timeoutMs) : null;
      this.pending.set(id, { resolve: (v) => { clearTimeout(timer); resolve(v); }, reject: (e) => { clearTimeout(timer); reject(e); } });
      this.#write({ id, method, params });
    });
  }
  notify(method, params) { this.#write({ method, params }); }
  async #handle(line) {
    let msg; try { msg = JSON.parse(line); } catch { return; }
    if (msg.method && msg.id !== undefined) {
      try { this.#write({ id: msg.id, result: (await this.onRequest(msg.method, msg.params)) ?? null }); }
      catch (error) { this.#write({ id: msg.id, error: { code: error.rpcCode ?? -32000, message: String(error.message ?? error) } }); }
    } else if (msg.method) this.onNotification(msg.method, msg.params);
    else if (msg.id !== undefined) {
      const p = this.pending.get(msg.id); if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(Object.assign(new Error(msg.error.message ?? 'error'), { code: 'agent_error', rpc: msg.error })); else p.resolve(msg.result);
    }
  }
}
