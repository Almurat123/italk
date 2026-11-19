import { GatewayError } from './ledger.mjs';

export const deliveryEmotions = new Set(['neutral', 'happy', 'calm', 'sad', 'curious', 'serious']);
const providerEmotion = { happy: 'happy', calm: 'calm', sad: 'sad', curious: 'surprised', serious: 'calm' };

export class VoiceProvider {
  constructor(config, fetcher = fetch) { this.config = config; this.fetcher = fetcher; }
  get configured() { return Boolean(this.config?.apiKey && this.config?.model && this.config?.voiceId); }
  // CONTEXT MEMORY
  // Updated: 2026-10-26
  // Status: mixed
  // Why: Emotional delivery needs a model's emotion control, not a local pitch adjustment.
  // Debug Goal: Return bounded audio and provider-reported billable characters without logging text.
  // Search Tags: MiniMax speech emotion usage_characters hex voice relay
  // Invariants:
  // - Neutral omits emotion; auto and neutral are not provider enum values.
  // - Credentials and voice identity are operator-owned.
  // - Failed, partial, or unmetered responses are not returned as successful speech.
  // Failure Modes:
  // - Using word_count instead of usage_characters silently changes billing.
  // - Following a returned audio URL introduces an SSRF path.
  async synthesize({ text, emotion, signal }) {
    if (!this.configured) throw new GatewayError('voice_not_configured', 503);
    if (!deliveryEmotions.has(emotion)) throw new GatewayError('invalid_emotion');
    const response = await this.fetcher(`${this.config.baseURL}/t2a_v2`, {
      method: 'POST', redirect: 'error', signal,
      headers: { authorization: `Bearer ${this.config.apiKey}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        model: this.config.model, text, stream: false, output_format: 'hex', language_boost: 'Chinese',
        voice_setting: { voice_id: this.config.voiceId, speed: emotion === 'calm' || emotion === 'sad' ? 0.92 : 1,
          vol: 1, pitch: 0, ...(providerEmotion[emotion] ? { emotion: providerEmotion[emotion] } : {}) },
        audio_setting: { sample_rate: 32000, bitrate: 96000, format: 'mp3', channel: 1 }
      })
    });
    if (!response.ok || !response.body) throw new GatewayError('voice_provider_failed', 502);
    const reader = response.body.getReader(), chunks = [];
    let size = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > 16_100_000) { await reader.cancel(); throw new GatewayError('voice_audio_too_large', 502); }
        chunks.push(value);
      }
    } finally { reader.releaseLock(); }
    let result;
    try { result = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
    catch { throw new GatewayError('voice_provider_failed', 502); }
    const hex = result.data?.audio, characters = result.extra_info?.usage_characters;
    if (result.base_resp?.status_code !== 0 || result.data?.status !== 2 || typeof hex !== 'string' ||
        hex.length < 8 || hex.length > 16_000_000 || hex.length % 2 || !/^[0-9a-f]+$/i.test(hex) ||
        !Number.isSafeInteger(characters) || characters <= 0 || characters > 100_000 ||
        (result.extra_info.audio_format && result.extra_info.audio_format !== 'mp3') || result.extra_info.usage_voice_count > 0) {
      throw new GatewayError('voice_usage_or_audio_invalid', 502);
    }
    const audio = Buffer.from(hex, 'hex');
    if (audio.subarray(0, 3).toString('ascii') !== 'ID3' && !(audio[0] === 0xff && (audio[1] & 0xe0) === 0xe0)) throw new GatewayError('voice_audio_invalid', 502);
    return { audio, characters };
  }
}

export class DeliveryPrefix {
  pending = ''; decided = false;
  push(text, final = false) {
    if (this.decided) return text ? [{ type: 'delta', text }] : [];
    this.pending += text;
    const match = /^\[emotion:(neutral|happy|calm|sad|curious|serious)\]\s*/.exec(this.pending);
    if (match && !final && this.pending.length === match[0].length && !this.pending.includes('\n')) return [];
    if (match) {
      this.decided = true;
      const rest = this.pending.slice(match[0].length); this.pending = '';
      return [{ type: 'delivery', emotion: match[1] }, ...(rest ? [{ type: 'delta', text: rest }] : [])];
    }
    if (!final && this.pending.length < 64 && ('[emotion:'.startsWith(this.pending) || this.pending.startsWith('[emotion:'))) return [];
    this.decided = true;
    const rest = this.pending.replace(/^\[emotion:[^\]\n]{0,40}\]\s*/, ''); this.pending = '';
    return [{ type: 'delivery', emotion: 'neutral' }, ...(rest ? [{ type: 'delta', text: rest }] : [])];
  }
}
