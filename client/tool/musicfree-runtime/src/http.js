import axios from 'axios';
import { decodeBase64 } from './base64.js';

/**
 * 插件 HTTP 桥：JS 侧只登记 ticket 并通过 sendMessage 通知 Dart，
 * Dart 完成请求后再 evaluate 回来调用 __mfHttpDone。
 * （与 MusicFree 的 axios 语义保持一致：返回的 data 交给 axios 的
 *   transformResponse 解析，因此这里必须给原始文本。）
 */
const pending = new Map();
let ticketSeq = 0;

function defaultValidateStatus(status) {
  return status >= 200 && status < 300;
}

function normalizeHeaders(headers) {
  let raw = headers;
  if (raw && typeof raw.toJSON === 'function') {
    raw = raw.toJSON();
  }
  const out = {};
  if (!raw || typeof raw !== 'object') {
    return out;
  }
  Object.keys(raw).forEach((key) => {
    const value = raw[key];
    if (value === undefined || value === null) {
      return;
    }
    out[key] = String(value);
  });
  return out;
}

function serializeBody(data) {
  if (data === undefined || data === null) {
    return null;
  }
  if (typeof data === 'string') {
    return { body: data };
  }
  if (typeof data === 'object' && typeof data.toString === 'function' && typeof data.append === 'function') {
    // URLSearchParams / FormData 一类：按 urlencoded 发出去
    return { body: data.toString() };
  }
  if (data instanceof Uint8Array || data instanceof ArrayBuffer) {
    return { bodyBase64: requireBase64(data) };
  }
  try {
    return { body: JSON.stringify(data) };
  } catch (e) {
    return { body: String(data) };
  }
}

function requireBase64(bytes) {
  // 延迟引用，避免与 base64.js 的导出互相干扰
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = '';
  for (let i = 0; i < view.length; i += 1) {
    binary += String.fromCharCode(view[i]);
  }
  const CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  for (let i = 0; i < binary.length; i += 3) {
    const b0 = binary.charCodeAt(i);
    const b1 = i + 1 < binary.length ? binary.charCodeAt(i + 1) : undefined;
    const b2 = i + 2 < binary.length ? binary.charCodeAt(i + 2) : undefined;
    out += CHARS[b0 >> 2];
    out += CHARS[((b0 & 0x03) << 4) | ((b1 ?? 0) >> 4)];
    out += b1 === undefined ? '=' : CHARS[((b1 & 0x0f) << 2) | ((b2 ?? 0) >> 6)];
    out += b2 === undefined ? '=' : CHARS[b2 & 0x3f];
  }
  return out;
}

function buildUrl(config) {
  try {
    if (typeof axios.getUri === 'function') {
      return axios.getUri(config);
    }
  } catch (e) {
    // 落到下面的手工拼接
  }
  let url = config.url || '';
  const base = config.baseURL;
  if (base && !/^([a-z][a-z\d+\-.]*:)?\/\//i.test(url)) {
    url = `${String(base).replace(/\/+$/, '')}/${url.replace(/^\/+/, '')}`;
  }
  const params = config.params;
  if (params && typeof params === 'object') {
    const search = [];
    Object.keys(params).forEach((key) => {
      const value = params[key];
      if (value === undefined || value === null) {
        return;
      }
      if (Array.isArray(value)) {
        value.forEach((item) => {
          search.push(`${encodeURIComponent(key)}=${encodeURIComponent(item)}`);
        });
      } else {
        search.push(`${encodeURIComponent(key)}=${encodeURIComponent(value)}`);
      }
    });
    if (search.length) {
      url += `${url.indexOf('?') === -1 ? '?' : '&'}${search.join('&')}`;
    }
  }
  return url;
}

function makeError(message, config, code) {
  const error = new Error(message);
  error.config = config;
  error.isAxiosError = true;
  error.code = code;
  return error;
}

/**
 * 创建 axios 适配器。jar 是该插件自己的 cookie 容器（MusicFree 用
 * Electron session，这里用等价的内存 jar，请求时自动带上 Cookie）。
 */
export function createAdapter(jar) {
  return function mfAdapter(config) {
    return new Promise((resolve, reject) => {
      let url;
      try {
        url = buildUrl(config);
      } catch (e) {
        reject(makeError(`请求地址无效：${e && e.message}`, config, 'ERR_INVALID_URL'));
        return;
      }
      if (!url) {
        reject(makeError('请求地址为空', config, 'ERR_INVALID_URL'));
        return;
      }
      const headers = normalizeHeaders(config.headers);
      const cookieHeader = jar ? jar.header(url) : '';
      if (cookieHeader) {
        const existing = Object.keys(headers).find((key) => key.toLowerCase() === 'cookie');
        if (existing) {
          headers[existing] = `${headers[existing]}; ${cookieHeader}`;
        } else {
          headers.cookie = cookieHeader;
        }
      }
      const body = serializeBody(config.data);
      const ticket = `h${(ticketSeq += 1)}`;
      pending.set(ticket, { resolve, reject, config, url });
      try {
        sendMessage(
          'mf.http',
          JSON.stringify({
            ticket,
            url,
            method: (config.method || 'get').toUpperCase(),
            headers,
            body: body?.body ?? null,
            bodyBase64: body?.bodyBase64 ?? null,
            timeout: config.timeout ?? 15000,
            responseType: config.responseType ?? '',
          }),
        );
      } catch (e) {
        pending.delete(ticket);
        reject(makeError(`请求派发失败：${e && e.message}`, config, 'ERR_BAD_REQUEST'));
      }
    });
  };
}

globalThis.__mfHttpDone = function mfHttpDone(ticket, errorMessage, payloadJson) {
  const entry = pending.get(ticket);
  if (!entry) {
    return;
  }
  pending.delete(ticket);
  const { resolve, reject, config, url } = entry;
  if (errorMessage) {
    reject(makeError(String(errorMessage), config, 'ERR_NETWORK'));
    return;
  }
  let payload;
  try {
    payload = typeof payloadJson === 'string' ? JSON.parse(payloadJson) : payloadJson;
  } catch (e) {
    reject(makeError('响应解析失败', config, 'ERR_BAD_RESPONSE'));
    return;
  }
  if (!payload) {
    reject(makeError('响应为空', config, 'ERR_BAD_RESPONSE'));
    return;
  }
  const status = Number(payload.status) || 0;
  const headers = payload.headers || {};
  let data;
  if (config.responseType === 'arraybuffer') {
    data = decodeBase64(payload.bodyBase64 || '');
  } else {
    data = payload.body ?? '';
  }
  const response = {
    data,
    status,
    statusText: payload.statusText || '',
    headers,
    config,
    request: { responseURL: url },
  };
  const validate = typeof config.validateStatus === 'function' ? config.validateStatus : defaultValidateStatus;
  if (validate(status)) {
    resolve(response);
    return;
  }
  const error = makeError(
    `Request failed with status code ${status}`,
    config,
    status >= 500 ? 'ERR_BAD_RESPONSE' : 'ERR_BAD_REQUEST',
  );
  error.response = response;
  error.status = status;
  reject(error);
};

export function pendingHttpCount() {
  return pending.size;
}
