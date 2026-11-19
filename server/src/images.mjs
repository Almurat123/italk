import { GatewayError } from './ledger.mjs';

// CONTEXT MEMORY
// Updated: 2026-10-25
// Status: mixed
// Why: Image uploads use bounded inline JPEGs, never provider-fetched URLs.
// Debug Goal: Reject malformed or unapproved uploads before reserving credits.
// Search Tags: image upload consent JPEG dimensions reserve credits
// Invariants:
// - At most three 900 KB JPEGs with dimensions at most 1280 pixels.
// - Prompts and image bytes are not persisted by the gateway.
// Failure Modes:
// - Unbounded base64 bodies exhaust memory before validation.
// - A renamed arbitrary file reaches the paid provider.
export function validateImages(value = []) {
  if (!Array.isArray(value) || value.length > 3) throw new GatewayError('invalid_images');
  return value.map(image => {
    if (!image || typeof image !== 'object' || Array.isArray(image) || Object.keys(image).some(k => !['mimeType', 'data'].includes(k)) || image.mimeType !== 'image/jpeg' || typeof image.data !== 'string' || image.data.length > 1_200_000 || image.data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(image.data)) throw new GatewayError('invalid_images');
    const bytes = Buffer.from(image.data, 'base64');
    if (bytes.length < 12 || bytes.length > 900_000 || bytes.readUInt16BE(0) !== 0xffd8 || bytes.readUInt16BE(bytes.length - 2) !== 0xffd9) throw new GatewayError('invalid_images');
    let offset = 2, dimensions = false;
    while (offset + 4 <= bytes.length) {
      if (bytes[offset++] !== 0xff) throw new GatewayError('invalid_images');
      while (bytes[offset] === 0xff) offset++;
      if (offset + 3 > bytes.length) throw new GatewayError('invalid_images');
      const marker = bytes[offset++];
      if (marker === 0xda || marker === 0xd9) break;
      const length = bytes.readUInt16BE(offset);
      if (length < 2 || offset + length > bytes.length) throw new GatewayError('invalid_images');
      if ([0xc0, 0xc1, 0xc2].includes(marker)) {
        if (length < 8) throw new GatewayError('invalid_images');
        const height = bytes.readUInt16BE(offset + 3), width = bytes.readUInt16BE(offset + 5);
        if (!width || !height || width > 1280 || height > 1280) throw new GatewayError('invalid_images');
        dimensions = true;
      }
      offset += length;
    }
    if (!dimensions) throw new GatewayError('invalid_images');
    return { mimeType: 'image/jpeg', data: image.data };
  });
}
