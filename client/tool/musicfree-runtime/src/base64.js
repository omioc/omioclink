// QuickJS 里没有 atob/btoa，这里自己实现（只用于二进制响应体的往返）。
const CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

const LOOKUP = (() => {
  const table = new Int16Array(256).fill(-1);
  for (let i = 0; i < CHARS.length; i += 1) {
    table[CHARS.charCodeAt(i)] = i;
  }
  table['='.charCodeAt(0)] = -2;
  return table;
})();

export function decodeBase64(input) {
  if (!input) {
    return new Uint8Array(0);
  }
  const clean = String(input).replace(/[^A-Za-z0-9+/=]/g, '');
  const padding = clean.endsWith('==') ? 2 : clean.endsWith('=') ? 1 : 0;
  const length = Math.max(0, Math.floor((clean.length * 3) / 4) - padding);
  const out = new Uint8Array(length);
  let buffer = 0;
  let bits = 0;
  let index = 0;
  for (let i = 0; i < clean.length; i += 1) {
    const value = LOOKUP[clean.charCodeAt(i)];
    if (value < 0) {
      continue;
    }
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[index] = (buffer >> bits) & 0xff;
      index += 1;
    }
  }
  return out.subarray(0, index);
}

export function encodeBase64(bytes) {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes ?? []);
  let out = '';
  for (let i = 0; i < view.length; i += 3) {
    const b0 = view[i];
    const b1 = i + 1 < view.length ? view[i + 1] : undefined;
    const b2 = i + 2 < view.length ? view[i + 2] : undefined;
    out += CHARS[b0 >> 2];
    out += CHARS[((b0 & 0x03) << 4) | ((b1 ?? 0) >> 4)];
    out += b1 === undefined ? '=' : CHARS[((b1 & 0x0f) << 2) | ((b2 ?? 0) >> 6)];
    out += b2 === undefined ? '=' : CHARS[b2 & 0x3f];
  }
  return out;
}
