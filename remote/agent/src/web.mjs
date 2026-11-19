import dns from 'node:dns/promises';
import net from 'node:net';

// Fetching a public web page for the agent. A page is untrusted data and the request comes from the person's own computer, so the target
// must be a public address: nothing on this machine, nothing on the home network, nothing link-local (cloud metadata and routers live there).

export class WebError extends Error {}

const V4_BLOCKED = [[0, 0, 0, 0, 8], [10, 0, 0, 0, 8], [100, 64, 0, 0, 10], [127, 0, 0, 0, 8], [169, 254, 0, 0, 16], [172, 16, 0, 0, 12], [192, 0, 0, 0, 24], [192, 168, 0, 0, 16], [224, 0, 0, 0, 3]];
// 198.18.0.0/15 is deliberately not listed: DNS-rewriting proxies (Clash, Surge, …) answer every name with an address in it and forward the connection;
// without such a proxy the range is unroutable, so allowing it opens nothing.
const ipv4ToInt = (ip) => ip.split('.').reduce((n, part) => n * 256 + Number(part), 0);

export function isPrivateAddress(ip) {
  if (net.isIPv4(ip)) {
    const value = ipv4ToInt(ip);
    return V4_BLOCKED.some(([a, b, c, d, bits]) => { const base = ipv4ToInt(`${a}.${b}.${c}.${d}`), size = 2 ** (32 - bits); return value >= base && value < base + size; });
  }
  if (net.isIPv6(ip)) {
    const v = ip.toLowerCase();
    if (v === '::' || v === '::1' || v.startsWith('fe8') || v.startsWith('fe9') || v.startsWith('fea') || v.startsWith('feb') || v.startsWith('fc') || v.startsWith('fd') || v.startsWith('ff')) return true;
    const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(v);
    return mapped ? isPrivateAddress(mapped[1]) : false;
  }
  return true;
}

export async function assertPublicUrl(raw, { lookup = (host) => dns.lookup(host, { all: true }) } = {}) {
  let url;
  try { url = new URL(String(raw)); } catch { throw new WebError('That is not a valid URL.'); }
  if (!['http:', 'https:'].includes(url.protocol)) throw new WebError('Only http and https pages can be fetched.');
  if (url.username || url.password) throw new WebError('URLs with a user name or password are not fetched.');
  if (url.port && !['80', '443', '8080', '8443'].includes(url.port)) throw new WebError('That port is not allowed.');
  const host = url.hostname.replace(/^\[|\]$/g, '');
  if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local') || host.endsWith('.internal')) throw new WebError('Addresses on this computer or network are not fetched.');
  const addresses = net.isIP(host) ? [{ address: host }] : await lookup(host).catch(() => { throw new WebError(`Cannot find ${host}.`); });
  if (!addresses.length || addresses.some(a => isPrivateAddress(a.address))) throw new WebError('Addresses on this computer or network are not fetched.');
  return url;
}

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ndash: '–', mdash: '—', hellip: '…', copy: '©', laquo: '«', raquo: '»' };
const decode = (s) => s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (m, e) => {
  if (e[0] === '#') { const code = e[1].toLowerCase() === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10); return Number.isFinite(code) && code > 0 && code < 0x110000 ? String.fromCodePoint(code) : m; }
  return ENTITIES[e.toLowerCase()] ?? m;
});

export function htmlToText(html, { baseUrl } = {}) {
  const title = decode((/<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1] ?? '').replace(/\s+/g, ' ').trim());
  const links = [];
  const body = html.replace(/<!--[\s\S]*?-->/g, ' ').replace(/<(script|style|noscript|svg|head|template|iframe)\b[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<a\b[^>]*?href\s*=\s*["']([^"'#][^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi, (_, href, label) => {
      const text = decode(label.replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
      try { const u = new URL(href, baseUrl); if (/^https?:$/.test(u.protocol) && text && links.length < 20) links.push(`- ${text.slice(0, 80)}: ${u.href.slice(0, 200)}`); } catch {}
      return ` ${label} `;
    })
    .replace(/<\/(p|div|section|article|li|tr|h[1-6]|blockquote|pre|table|ul|ol)>/gi, '\n').replace(/<(br|hr)\s*\/?>/gi, '\n').replace(/<li\b[^>]*>/gi, '\n• ')
    .replace(/<[^>]+>/g, ' ');
  const text = decode(body).replace(/[ \t\f\v ]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  return `${title ? `Title: ${title}\n\n` : ''}${text}${links.length ? `\n\nLinks:\n${links.join('\n')}` : ''}`;
}

/** → { text, finalUrl, status, contentType, truncated }. Throws WebError with a sentence the person and the model can both read. */
export async function fetchPage(rawUrl, { signal, maxChars = 24_000, fetcher = fetch, lookup, maxRedirects = 5, timeoutMs = 20_000, maxBytes = 2_000_000 } = {}) {
  let url = await assertPublicUrl(rawUrl, { lookup });
  const deadline = AbortSignal.timeout(timeoutMs), both = signal ? AbortSignal.any([signal, deadline]) : deadline;
  for (let hop = 0; hop <= maxRedirects; hop++) {
    let response;
    try { response = await fetcher(url, { redirect: 'manual', signal: both, headers: { 'user-agent': 'iTalk-Agent/0.2 (+personal assistant)', accept: 'text/html,text/plain,application/json;q=0.9,*/*;q=0.1', 'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8' } }); }
    catch (error) { if (signal?.aborted) throw error; throw new WebError(deadline.aborted ? 'The page took too long to answer.' : 'Could not connect to that page.'); }
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const next = response.headers.get('location');
      if (!next) throw new WebError('The page redirected without saying where.');
      url = await assertPublicUrl(new URL(next, url).href, { lookup });
      continue;
    }
    const contentType = (response.headers.get('content-type') ?? '').toLowerCase();
    if (!response.ok) throw new WebError(`The page answered ${response.status}.`);
    if (!/^(text\/|application\/(json|xml|xhtml|ld\+json|rss|atom))/.test(contentType) && contentType !== '') throw new WebError(`This is not a text page (${contentType.split(';')[0]}).`);
    const reader = response.body.getReader(), chunks = []; let size = 0;
    while (size < maxBytes) { const { done, value } = await reader.read(); if (done) break; chunks.push(value); size += value.length; }
    try { await reader.cancel(); } catch {}
    const charset = /charset=([\w-]+)/.exec(contentType)?.[1] ?? 'utf-8';
    let raw; try { raw = new TextDecoder(charset).decode(Buffer.concat(chunks)); } catch { raw = new TextDecoder('utf-8').decode(Buffer.concat(chunks)); }
    const text = /html/.test(contentType) || /^\s*<(!doctype|html)/i.test(raw) ? htmlToText(raw, { baseUrl: url.href }) : raw.trim();
    const truncated = text.length > maxChars;
    return { text: truncated ? `${text.slice(0, maxChars)}\n… [${text.length - maxChars} more characters cut]` : text, finalUrl: url.href, status: response.status, contentType: contentType.split(';')[0], truncated };
  }
  throw new WebError('The page redirected too many times.');
}
