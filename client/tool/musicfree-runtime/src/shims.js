import { decodeBase64, encodeBase64 } from './base64.js';

/**
 * MusicFree 里几个「主进程能力」的等价/降级实现。
 *  - @react-native-cookies/cookies：Electron session cookie 的替身（内存 jar +
 *    落盘，请求时自动拼 Cookie 头，行为与 MusicFree 一致）。
 *  - webdav：MusicFree 里是可用的 npm 包（依赖 Node 内置模块），在 QuickJS
 *    里无法工作，这里给出同名 API 并明确报错，避免插件加载阶段就崩掉。
 *  - Web 全局（URLSearchParams / URL / TextEncoder / TextDecoder / atob / btoa /
 *    structuredClone）：见 installWebGlobals。
 *  - Buffer（Node 内置全局 + buffer 模块）：见文件末尾的 installBufferGlobals / bufferModule。
 *  - undici：cheerio 的 fromURL 才用，构建时替换成空实现。
 */
export function createCookieJar(pluginKey, snapshot) {
  const items = [];
  const byKey = Object.create(null);

  const keyOf = (domain, path, name) => `${domain}\u0000${path}\u0000${name}`;

  const remember = (cookie) => {
    if (!cookie || !cookie.name) {
      return;
    }
    const domain = String(cookie.domain || '').toLowerCase();
    const path = String(cookie.path || '/');
    const key = keyOf(domain, path, cookie.name);
    const record = {
      name: String(cookie.name),
      value: String(cookie.value ?? ''),
      domain,
      path,
      secure: !!cookie.secure,
      httpOnly: !!cookie.httpOnly,
      expires: cookie.expires ?? null,
    };
    byKey[key] = record;
    const index = items.findIndex((item) => item.key === key);
    if (index === -1) {
      items.push({ key, ...record });
    } else {
      items[index] = { key, ...record };
    }
  };

  (Array.isArray(snapshot) ? snapshot : []).forEach(remember);

  const persist = () => {
    try {
      sendMessage('mf.cookie', JSON.stringify({ plugin: pluginKey, cookies: items }));
    } catch (e) {
      // 落盘失败不影响请求
    }
  };

  const hostOf = (url) => {
    const match = /^[a-z][a-z\d+\-.]*:\/\/([^/?#]+)/i.exec(String(url || ''));
    return match ? match[1].toLowerCase().split(':')[0] : '';
  };

  const matches = (list, url) => {
    const host = hostOf(url);
    const path = (() => {
      const match = /^[a-z][a-z\d+\-.]*:\/\/[^/?#]+([^?#]*)/i.exec(String(url || ''));
      return match && match[1] ? match[1] : '/';
    })();
    return list.filter((cookie) => {
      const domain = cookie.domain || '';
      const domainOk = !domain || host === domain || host.endsWith(`.${domain}`);
      const pathOk = !cookie.path || path.startsWith(cookie.path);
      return domainOk && pathOk;
    });
  };

  const api = {
    async set(url, cookie) {
      try {
        const host = hostOf(url);
        const merged = { domain: host, path: '/', ...(cookie || {}) };
        remember(merged);
        persist();
        return true;
      } catch (e) {
        return false;
      }
    },
    async get(url) {
      const result = {};
      matches(items, url).forEach((cookie) => {
        result[cookie.name] = { ...cookie };
      });
      return result;
    },
    async flush() {
      persist();
      return undefined;
    },
    async clearAll() {
      items.length = 0;
      Object.keys(byKey).forEach((key) => delete byKey[key]);
      persist();
      return undefined;
    },
  };

  return {
    api,
    header(url) {
      return matches(items, url)
        .map((cookie) => `${cookie.name}=${cookie.value}`)
        .join('; ');
    },
  };
}

export const webdavStub = (() => {
  const unsupported = () => {
    throw new Error('当前客户端不支持插件使用 WebDAV（QuickJS 环境无 Node 内置模块）');
  };
  const stub = {
    createClient: unsupported,
    getDirectoryContents: unsupported,
    getFileContents: unsupported,
    putFileContents: unsupported,
    createDirectory: unsupported,
    deleteFile: unsupported,
    exists: unsupported,
  };
  stub.default = stub;
  return stub;
})();

export const undiciStub = {
  fetch: () => Promise.reject(new Error('undici.fetch 不可用')),
  default: null,
};

/* ------------------------------------------------------------------ *
 * Web / Node 全局对象补齐
 *
 * MusicFree 桌面端跑在 Electron 主进程（Node）里，插件可以直接用
 * URLSearchParams / URL / TextEncoder / TextDecoder / atob / btoa /
 * structuredClone；QuickJS 沙箱里没有这些，真实插件第一句就会
 * `ReferenceError: URLSearchParams is not defined`。
 * 下面这些实现只覆盖「真实插件里的常见用法」，不追求完整 WHATWG 规范，
 * 目标是让插件不抛 ReferenceError / TypeError。
 * ------------------------------------------------------------------ */

/** 落单代理（lone surrogate）会让 encodeURIComponent 抛 URIError，这里按 UTF-8 字节兜底。 */
function percentEncode(value) {
  const text = String(value);
  try {
    return encodeURIComponent(text);
  } catch (e) {
    const bytes = utf8Encode(text);
    let out = '';
    for (let i = 0; i < bytes.length; i += 1) {
      out += `%${(bytes[i] < 16 ? '0' : '')}${bytes[i].toString(16).toUpperCase()}`;
    }
    return out;
  }
}

/** URLSearchParams 的表单语义里 '+' 就是空格，解码前先还原。 */
function percentDecode(value) {
  const text = String(value).replace(/\+/g, ' ');
  try {
    return decodeURIComponent(text);
  } catch (e) {
    return text;
  }
}

/** UTF-8 编码：QuickJS 没有 TextEncoder，这里手写码表（返回 Uint8Array）。 */
export function utf8Encode(input) {
  const text = String(input === undefined || input === null ? '' : input);
  const bytes = [];
  for (let i = 0; i < text.length; i += 1) {
    let code = text.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff) {
      // 代理对：合法的两个合成为一个码点，落单的按 U+FFFD 处理
      const next = i + 1 < text.length ? text.charCodeAt(i + 1) : 0;
      if (next >= 0xdc00 && next <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
        i += 1;
      } else {
        code = 0xfffd;
      }
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      code = 0xfffd;
    }
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      bytes.push(
        0xf0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f),
      );
    }
  }
  return new Uint8Array(bytes);
}

/** 把 decode 的入参统一成字节视图（Uint8Array / ArrayBuffer / TypedArray / 普通数组都认）。 */
function toByteView(input) {
  if (input === undefined || input === null) {
    return new Uint8Array(0);
  }
  if (input instanceof Uint8Array) {
    return input;
  }
  if (input instanceof ArrayBuffer) {
    return new Uint8Array(input);
  }
  if (typeof ArrayBuffer.isView === 'function' && ArrayBuffer.isView(input)) {
    return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  }
  if (typeof input === 'object' && input._bytes instanceof Uint8Array) {
    // 本文件的 Buffer 兼容层（new TextDecoder().decode(buf) 这种写法）
    return input._bytes;
  }
  if (typeof input === 'string') {
    // 少见，但宽容一点：字符串再编码一次
    return utf8Encode(input);
  }
  return new Uint8Array(input);
}

/** UTF-8 解码：手写码表，非法序列按 U+FFFD 兜底（与浏览器一致）。 */
export function utf8Decode(input, stripBom = true) {
  const bytes = toByteView(input);
  let index = 0;
  if (stripBom && bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    index = 3;
  }
  let out = '';
  while (index < bytes.length) {
    const first = bytes[index];
    if (first < 0x80) {
      out += String.fromCharCode(first);
      index += 1;
      continue;
    }
    let need = 0;
    let code = 0;
    if (first >= 0xc2 && first <= 0xdf) {
      need = 1;
      code = first & 0x1f;
    } else if (first >= 0xe0 && first <= 0xef) {
      need = 2;
      code = first & 0x0f;
    } else if (first >= 0xf0 && first <= 0xf4) {
      need = 3;
      code = first & 0x07;
    } else {
      out += '\ufffd';
      index += 1;
      continue;
    }
    let cursor = index + 1;
    let ok = true;
    for (let k = 0; k < need; k += 1) {
      const byte = cursor < bytes.length ? bytes[cursor] : -1;
      if (byte < 0 || (byte & 0xc0) !== 0x80) {
        ok = false;
        break;
      }
      code = (code << 6) | (byte & 0x3f);
      cursor += 1;
    }
    if (!ok) {
      out += '\ufffd';
      index += 1;
      continue;
    }
    index = cursor;
    if (code > 0xffff) {
      const rest = code - 0x10000;
      out += String.fromCharCode(0xd800 + (rest >> 10), 0xdc00 + (rest & 0x3ff));
    } else {
      out += String.fromCharCode(code);
    }
  }
  return out;
}

/** 迭代器：keys / values / entries 都是可迭代对象（for...of 与展开都能用）。 */
function makeIterator(items) {
  let index = 0;
  const iterator = {
    next() {
      if (index >= items.length) {
        return { value: undefined, done: true };
      }
      const value = items[index];
      index += 1;
      return { value, done: false };
    },
  };
  iterator[Symbol.iterator] = () => iterator;
  return iterator;
}

/** 按 `a=1&b=2` 解析成 [name, value] 数组（首部 '?' 忽略）。 */
function parseSearchPairs(text) {
  const pairs = [];
  let input = String(text === undefined || text === null ? '' : text);
  if (input.charAt(0) === '?') {
    input = input.slice(1);
  }
  if (!input) {
    return pairs;
  }
  input.split('&').forEach((chunk) => {
    if (!chunk) {
      return;
    }
    const eq = chunk.indexOf('=');
    const name = eq === -1 ? chunk : chunk.slice(0, eq);
    const value = eq === -1 ? '' : chunk.slice(eq + 1);
    pairs.push([percentDecode(name), percentDecode(value)]);
  });
  return pairs;
}

/**
 * URLSearchParams：构造支持 string / record / URLSearchParams / iterable of pairs，
 * toString() 用 encodeURIComponent 编码（空格是 %20，不是 '+'）。
 */
class URLSearchParams {
  constructor(init) {
    this._list = [];
    this._reset(init);
  }

  /** 内部用：从字符串/记录/可迭代对象重置（URL 的 search setter 也走这里）。 */
  _reset(init) {
    const list = [];
    const append = (name, value) => {
      list.push([String(name), String(value)]);
    };
    if (init === undefined || init === null) {
      this._list = list;
      return;
    }
    if (typeof init === 'string') {
      this._list = parseSearchPairs(init);
      return;
    }
    if (init instanceof URLSearchParams) {
      init._list.forEach((pair) => append(pair[0], pair[1]));
      this._list = list;
      return;
    }
    const iteratorFn = typeof init === 'object' ? init[Symbol.iterator] : undefined;
    if (typeof iteratorFn === 'function') {
      const iterator = iteratorFn.call(init);
      let step = iterator.next();
      while (!step.done) {
        const pair = step.value;
        if (pair !== undefined && pair !== null) {
          append(pair[0], pair.length > 1 ? pair[1] : '');
        }
        step = iterator.next();
      }
      this._list = list;
      return;
    }
    if (typeof init === 'object') {
      Object.keys(init).forEach((key) => append(key, init[key]));
    }
    this._list = list;
  }

  get size() {
    return this._list.length;
  }

  append(name, value) {
    this._list.push([String(name), String(value)]);
  }

  set(name, value) {
    const key = String(name);
    const text = String(value);
    let first = -1;
    for (let i = 0; i < this._list.length; i += 1) {
      if (this._list[i][0] === key) {
        first = i;
        break;
      }
    }
    if (first === -1) {
      this._list.push([key, text]);
      return;
    }
    this._list[first] = [key, text];
    // 同名后面的条目按规范删掉
    this._list = this._list.filter((pair, index) => index <= first || pair[0] !== key);
  }

  get(name) {
    const key = String(name);
    const found = this._list.filter((pair) => pair[0] === key)[0];
    return found ? found[1] : null;
  }

  getAll(name) {
    const key = String(name);
    return this._list.filter((pair) => pair[0] === key).map((pair) => pair[1]);
  }

  has(name, value) {
    const key = String(name);
    if (value === undefined) {
      return this._list.some((pair) => pair[0] === key);
    }
    const text = String(value);
    return this._list.some((pair) => pair[0] === key && pair[1] === text);
  }

  delete(name, value) {
    const key = String(name);
    if (value === undefined) {
      this._list = this._list.filter((pair) => pair[0] !== key);
      return;
    }
    const text = String(value);
    this._list = this._list.filter((pair) => !(pair[0] === key && pair[1] === text));
  }

  /** 让 Object.prototype.toString.call(params) 是 [object URLSearchParams]：
   *  axios 一类的库靠这个 tag 判断「是不是 URLSearchParams」，
   *  否则会被当成普通对象再 JSON 序列化一次。 */
  get [Symbol.toStringTag]() {
    return 'URLSearchParams';
  }

  sort() {
    // 名字按字符串升序，同名保持原有顺序（对应规范的稳定排序）
    const indexed = this._list.map((pair, index) => ({ pair, index }));
    indexed.sort((a, b) => {
      if (a.pair[0] < b.pair[0]) {
        return -1;
      }
      if (a.pair[0] > b.pair[0]) {
        return 1;
      }
      return a.index - b.index;
    });
    this._list = indexed.map((item) => item.pair);
  }

  forEach(callback, thisArg) {
    this._list.forEach((pair) => {
      callback.call(thisArg, pair[1], pair[0], this);
    });
  }

  keys() {
    return makeIterator(this._list.map((pair) => pair[0]));
  }

  values() {
    return makeIterator(this._list.map((pair) => pair[1]));
  }

  entries() {
    return makeIterator(this._list.map((pair) => [pair[0], pair[1]]));
  }

  [Symbol.iterator]() {
    return this.entries();
  }

  toString() {
    return this._list
      .map((pair) => `${percentEncode(pair[0])}=${percentEncode(pair[1])}`)
      .join('&');
  }
}

/* ------------------------------ URL ------------------------------ */

const SCHEME_PATTERN = /^[a-zA-Z][a-zA-Z0-9+\-.]*:/;
const ABSOLUTE_PATTERN = /^([a-zA-Z][a-zA-Z0-9+\-.]*:)\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#[\s\S]*)?$/;
const REFERENCE_PATTERN = /^([^?#]*)(\?[^#]*)?(#[\s\S]*)?$/;
const SPECIAL_SCHEMES = ['http:', 'https:', 'ws:', 'wss:', 'ftp:', 'file:'];

/** 拆 authority：user:pass@host:port，IPv6 的 [::1]:8080 也能认。 */
function parseAuthority(text) {
  let rest = String(text === undefined || text === null ? '' : text);
  let username = '';
  let password = '';
  const at = rest.lastIndexOf('@');
  if (at !== -1) {
    const userinfo = rest.slice(0, at);
    rest = rest.slice(at + 1);
    const colon = userinfo.indexOf(':');
    username = colon === -1 ? userinfo : userinfo.slice(0, colon);
    password = colon === -1 ? '' : userinfo.slice(colon + 1);
  }
  let hostname = rest;
  let port = '';
  if (rest.charAt(0) === '[') {
    const close = rest.indexOf(']');
    const stop = close === -1 ? rest.length : close;
    hostname = rest.slice(0, stop + 1);
    const tail = rest.slice(stop + 1);
    port = tail.charAt(0) === ':' ? tail.slice(1) : '';
  } else {
    const colon = rest.lastIndexOf(':');
    if (colon !== -1) {
      hostname = rest.slice(0, colon);
      port = rest.slice(colon + 1);
    }
  }
  return { username, password, hostname: hostname.toLowerCase(), port: String(port || '') };
}

/** 解析绝对地址；不是 `scheme://authority/...` 形态就返回 null。 */
function parseAbsoluteUrl(text) {
  const match = ABSOLUTE_PATTERN.exec(String(text === undefined || text === null ? '' : text));
  if (!match) {
    return null;
  }
  const authority = parseAuthority(match[2]);
  return {
    protocol: match[1].toLowerCase(),
    username: authority.username,
    password: authority.password,
    hostname: authority.hostname,
    port: authority.port,
    pathname: match[3] || '/',
    search: match[4] && match[4] !== '?' ? match[4] : '',
    hash: match[5] && match[5] !== '#' ? match[5] : '',
  };
}

/** 归一化路径：处理 '.' / '..'，保留结尾斜杠。 */
function normalizePath(path) {
  const input = String(path === undefined || path === null ? '' : path) || '/';
  const trailing = /(\/|\/\.|\/\.\.)$/.test(input);
  const out = [];
  input.split('/').forEach((segment, index) => {
    if (segment === '' || segment === '.') {
      if (index === 0) {
        out.push('');
      }
      return;
    }
    if (segment === '..') {
      if (out.length > 1) {
        out.pop();
      }
      return;
    }
    out.push(segment);
  });
  let result = out.join('/');
  if (result.charAt(0) !== '/') {
    result = `/${result}`;
  }
  if (trailing && result.charAt(result.length - 1) !== '/') {
    result += '/';
  }
  return result || '/';
}

function normalizeSearch(text) {
  const value = String(text === undefined || text === null ? '' : text);
  if (!value || value === '?') {
    return '';
  }
  return value.charAt(0) === '?' ? value : `?${value}`;
}

/** 简化版 RFC 3986 地址解析：把相对地址拼到 base 上。 */
function resolveUrl(input, base) {
  const raw = String(input === undefined || input === null ? '' : input);
  if (SCHEME_PATTERN.test(raw)) {
    return raw;
  }
  if (base === undefined || base === null) {
    throw new TypeError(`Invalid URL: ${raw}`);
  }
  const baseText =
    typeof base === 'object' && typeof base.href === 'string' ? base.href : String(base);
  const baseParts = parseAbsoluteUrl(baseText);
  if (!baseParts) {
    throw new TypeError(`Invalid base URL: ${baseText}`);
  }
  const baseHost = `${baseParts.hostname}${baseParts.port ? `:${baseParts.port}` : ''}`;
  const match = REFERENCE_PATTERN.exec(raw);
  const refPath = match[1];
  const refQuery = match[2];
  const refHash = match[3] || '';
  let pathname;
  if (refPath === '') {
    pathname = baseParts.pathname;
  } else if (refPath.charAt(0) === '/') {
    pathname = normalizePath(refPath);
  } else {
    const slash = baseParts.pathname.lastIndexOf('/');
    const dir = slash === -1 ? '/' : baseParts.pathname.slice(0, slash + 1);
    pathname = normalizePath(`${dir}${refPath}`);
  }
  let search = '';
  if (refQuery !== undefined) {
    search = normalizeSearch(refQuery);
  } else if (refPath === '') {
    search = baseParts.search;
  }
  return `${baseParts.protocol}//${baseHost}${pathname}${search}${refHash}`;
}

/**
 * URL：支持 `new URL(abs)` 与 `new URL('/path?x=1', 'https://a.com')` 两种形态；
 * search / hash 的 setter 是简版实现，只保证 toString() / href 取到最新值。
 */
class URL {
  constructor(input, base) {
    const parts = parseAbsoluteUrl(resolveUrl(input, base));
    if (!parts) {
      throw new TypeError(`Invalid URL: ${input}`);
    }
    this._parts = parts;
    this._params = new URLSearchParams(parts.search);
  }

  get href() {
    return this._compose();
  }

  set href(value) {
    const parts = parseAbsoluteUrl(resolveUrl(value));
    if (!parts) {
      throw new TypeError(`Invalid URL: ${value}`);
    }
    this._parts = parts;
    this._params._reset(parts.search);
  }

  get origin() {
    if (SPECIAL_SCHEMES.indexOf(this._parts.protocol) === -1 || !this._parts.hostname) {
      return 'null';
    }
    return `${this._parts.protocol}//${this.host}`;
  }

  get protocol() {
    return this._parts.protocol;
  }

  set protocol(value) {
    const text = String(value === undefined || value === null ? '' : value).toLowerCase();
    if (!text) {
      return;
    }
    this._parts.protocol = text.charAt(text.length - 1) === ':' ? text : `${text}:`;
  }

  get host() {
    return `${this._parts.hostname}${this._parts.port ? `:${this._parts.port}` : ''}`;
  }

  set host(value) {
    const parsed = parseAuthority(value);
    this._parts.hostname = parsed.hostname;
    this._parts.port = parsed.port;
  }

  get hostname() {
    return this._parts.hostname;
  }

  set hostname(value) {
    this._parts.hostname = String(value === undefined || value === null ? '' : value).toLowerCase();
  }

  get port() {
    return this._parts.port;
  }

  set port(value) {
    this._parts.port = String(value === undefined || value === null ? '' : value);
  }

  get pathname() {
    return this._parts.pathname;
  }

  set pathname(value) {
    this._parts.pathname = normalizePath(value);
  }

  get search() {
    return this._syncSearch();
  }

  set search(value) {
    this._params._reset(normalizeSearch(value));
    this._syncSearch();
  }

  get hash() {
    return this._parts.hash;
  }

  set hash(value) {
    const text = String(value === undefined || value === null ? '' : value);
    if (!text || text === '#') {
      this._parts.hash = '';
      return;
    }
    this._parts.hash = text.charAt(0) === '#' ? text : `#${text}`;
  }

  get username() {
    return this._parts.username;
  }

  get password() {
    return this._parts.password;
  }

  get searchParams() {
    return this._params;
  }

  toString() {
    return this._compose();
  }

  toJSON() {
    return this._compose();
  }

  /** 与浏览器一致：Object.prototype.toString.call(url) === '[object URL]'。 */
  get [Symbol.toStringTag]() {
    return 'URL';
  }

  /** searchParams 改动后要回写 search（插件常见用法：url.searchParams.set(...) 后取 toString）。 */
  _syncSearch() {
    const text = this._params.toString();
    this._parts.search = text ? `?${text}` : '';
    return this._parts.search;
  }

  _compose() {
    const parts = this._parts;
    const search = this._syncSearch();
    const userinfo =
      parts.username || parts.password
        ? `${parts.username}${parts.password ? `:${parts.password}` : ''}@`
        : '';
    return `${parts.protocol}//${userinfo}${this.host}${parts.pathname}${search}${parts.hash}`;
  }
}

/* --------------------------- TextEncoder --------------------------- */

class TextEncoder {
  constructor() {
    this.encoding = 'utf-8';
  }

  encode(input) {
    return utf8Encode(input === undefined ? '' : input);
  }
}

class TextDecoder {
  constructor(label, options) {
    // 只实现 UTF-8；其它编码标签（gbk 之类）按 UTF-8 尽力解码，不抛错
    const normalized = String(label === undefined || label === null ? 'utf-8' : label).toLowerCase();
    this.encoding =
      normalized === 'utf8' || normalized === 'utf-8' || normalized === 'unicode-1-1-utf-8'
        ? 'utf-8'
        : normalized;
    this.fatal = !!(options && options.fatal);
    this.ignoreBOM = !!(options && options.ignoreBOM);
  }

  decode(input) {
    return utf8Decode(input, !this.ignoreBOM);
  }
}

/* -------------------------- base64 / 克隆 -------------------------- */

/** base64 -> latin1 字符串（与浏览器的 atob 一致）。 */
export function atob(input) {
  const bytes = decodeBase64(String(input === undefined || input === null ? '' : input));
  let out = '';
  for (let i = 0; i < bytes.length; i += 1) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

/** latin1 字符串 -> base64（与浏览器的 btoa 一致，超出 0xff 直接报错）。 */
export function btoa(input) {
  const text = String(input === undefined || input === null ? '' : input);
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i += 1) {
    const code = text.charCodeAt(i);
    if (code > 0xff) {
      throw new TypeError('btoa 只支持 latin1 字符');
    }
    bytes[i] = code;
  }
  return encodeBase64(bytes);
}

/**
 * structuredClone 的近似实现：走 JSON 往返。
 * 只覆盖普通对象 / 数组 / 基础类型；Date、Map、Set、TypedArray、循环引用都会失真，
 * 够应付插件里「深拷贝一份参数」这类常见写法。
 */
export function structuredClone(value) {
  const text = JSON.stringify(value);
  if (text === undefined) {
    return value;
  }
  return JSON.parse(text);
}

/**
 * 把上面这些全局装到 target（默认 globalThis）上；已存在的实现不覆盖，
 * 宿主或引擎自己提供时以它为准。
 */
export function installWebGlobals(target = globalThis) {
  if (!target) {
    return target;
  }
  const install = (name, value) => {
    if (target[name] !== undefined && target[name] !== null) {
      return;
    }
    try {
      target[name] = value;
    } catch (e) {
      // 只读全局装不上就算了
    }
  };
  install('URLSearchParams', URLSearchParams);
  install('URL', URL);
  install('TextEncoder', TextEncoder);
  install('TextDecoder', TextDecoder);
  install('atob', atob);
  install('btoa', btoa);
  install('structuredClone', structuredClone);
  return target;
}

/* ------------------------------------------------------------------ *
 * Node Buffer 兼容层
 *
 * MusicFree 桌面端跑在 Electron 主进程里，`Buffer` 是 Node 内置的全局对象，
 * 插件（以及它们内联的纯 JS 工具、pako / crypto-js 之类依赖的调用方）会直接写：
 *     Buffer.from(text, 'base64').toString('utf8')
 *     Buffer.concat([a, b]).toString('hex')
 *     if (Buffer.isBuffer(data)) { ... }
 * QuickJS 沙箱里既没有全局 Buffer，`require('buffer')` 也拿不到，
 * 结果就是 ReferenceError 或「null 上取属性」，真实插件在 search 阶段直接炸。
 *
 * 这里是**兼容层**，不是完整实现，取舍如下：
 *  - 字节用内部 `Uint8Array`（this._bytes）承载，**不**继承 Uint8Array：
 *    QuickJS 里对 typed array 做子类化风险很大（构造器拿不到内部槽、
 *    ArrayBuffer.prototype.slice 之类的内建方法容易踩坑）。
 *  - 编码只实现 utf8 / hex / base64 / base64url / latin1(binary) / ascii，
 *    其它标签（ucs2 / utf16le / gbk …）一律按 utf8 处理，不抛 unknown encoding。
 *  - 因为不是真 typed array，`buf[0]` 这种下标读写不支持，
 *    需要时用 `buf.at(i)` / `buf.toString(enc)`。byteOffset / byteLength / buffer
 *    三个属性照常透出，插件里 `buf.buffer instanceof ArrayBuffer` 的写法仍然成立。
 *  - 不做 `readUInt32BE` 一类的数值读写，也不支持 `new Buffer(size)`。
 *  - base64 复用同文件的 encodeBase64 / decodeBase64（与 atob/btoa 同源）。
 * ------------------------------------------------------------------ */

/** 内部令牌：把「内部构造」和用户可见的 `new Buffer()` 分开（Node 里后者已废弃）。 */
const BUFFER_TOKEN = {};

const BUFFER_ENCODINGS = [
  'utf8',
  'utf-8',
  'hex',
  'base64',
  'base64url',
  'latin1',
  'binary',
  'ascii',
];

/** 编码名归一化：别名 -> 五种实现之一；未知编码按 utf8 兜底（不抛错，宽容优先）。 */
function normalizeEncoding(encoding) {
  const text = String(encoding === undefined || encoding === null ? 'utf8' : encoding)
    .trim()
    .toLowerCase()
    .replace(/_/g, '-');
  if (text === '' || text === 'utf8' || text === 'utf-8') {
    return 'utf8';
  }
  if (text === 'latin1' || text === 'binary') {
    return 'latin1';
  }
  if (text === 'ascii' || text === 'hex' || text === 'base64' || text === 'base64url') {
    return text;
  }
  return 'utf8';
}

/** 字符串 -> 字节（Uint8Array）。 */
function encodeString(input, encoding) {
  const text = String(input === undefined || input === null ? '' : input);
  const enc = normalizeEncoding(encoding);
  if (enc === 'utf8') {
    return utf8Encode(text);
  }
  if (enc === 'latin1' || enc === 'ascii') {
    // latin1 一个字符一个字节；ascii 与 Node 一致按 7 位截断
    const mask = enc === 'ascii' ? 0x7f : 0xff;
    const bytes = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i += 1) {
      bytes[i] = text.charCodeAt(i) & mask;
    }
    return bytes;
  }
  if (enc === 'hex') {
    // 与 Node 一致：奇数个字符时最后一个半字节丢弃，非法字符直接忽略
    const clean = text.replace(/[^0-9a-fA-F]/g, '');
    const bytes = new Uint8Array(Math.floor(clean.length / 2));
    for (let i = 0; i < bytes.length; i += 1) {
      bytes[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
    }
    return bytes;
  }
  const normalized = enc === 'base64url' ? text.replace(/-/g, '+').replace(/_/g, '/') : text;
  return decodeBase64(normalized);
}

/** 字节（Uint8Array）-> 字符串。 */
function decodeBytes(bytes, encoding) {
  const enc = normalizeEncoding(encoding);
  if (enc === 'utf8') {
    // Node 的 toString('utf8') 不剥 BOM，这里保持一致
    return utf8Decode(bytes, false);
  }
  if (enc === 'latin1' || enc === 'ascii') {
    const mask = enc === 'ascii' ? 0x7f : 0xff;
    let out = '';
    for (let i = 0; i < bytes.length; i += 1) {
      out += String.fromCharCode(bytes[i] & mask);
    }
    return out;
  }
  if (enc === 'hex') {
    let out = '';
    for (let i = 0; i < bytes.length; i += 1) {
      out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
    }
    return out;
  }
  const text = encodeBase64(bytes);
  if (enc === 'base64url') {
    return text.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  return text;
}

/** 复制一份字节（显式拷贝，避免不同视图共享内存）。 */
function copyByteView(bytes) {
  const out = new Uint8Array(bytes.length);
  for (let i = 0; i < bytes.length; i += 1) {
    out[i] = bytes[i];
  }
  return out;
}

/** 把任意「像字节」的入参统一成 Uint8Array 视图；认不出来返回 null。
 *  注意：Buffer 走分支返回内部视图（不复制），调用方按只读使用。 */
function asByteView(value) {
  if (value instanceof Buffer) {
    return value._bytes;
  }
  if (value instanceof Uint8Array) {
    return value;
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  if (typeof ArrayBuffer.isView === 'function' && ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  if (Array.isArray(value)) {
    const bytes = new Uint8Array(value.length);
    for (let i = 0; i < bytes.length; i += 1) {
      bytes[i] = Number(value[i]) & 0xff;
    }
    return bytes;
  }
  return null;
}

/**
 * 最小可用的 Buffer。实例方法只覆盖真实插件会用到的那些：
 * toString / toJSON / equals / slice / subarray / write / copy / fill / at。
 */
class Buffer {
  constructor(token, bytes) {
    if (token !== BUFFER_TOKEN) {
      throw new TypeError('Buffer 是兼容层实现，请用 Buffer.from / Buffer.alloc / Buffer.concat');
    }
    this._bytes = bytes;
  }

  get length() {
    return this._bytes.length;
  }

  get byteLength() {
    return this._bytes.byteLength;
  }

  get byteOffset() {
    return this._bytes.byteOffset;
  }

  /** 真 Node Buffer 是 Uint8Array：插件里有 `buf.buffer instanceof ArrayBuffer` 的写法。 */
  get buffer() {
    return this._bytes.buffer;
  }

  /** 取 [start, end) 的字节**视图**（slice / subarray 共享内存，与 Node 一致）。 */
  _view(start, end) {
    const total = this._bytes.length;
    let from = start === undefined || start === null ? 0 : Math.trunc(Number(start)) || 0;
    if (from < 0) {
      from = Math.max(total + from, 0);
    }
    if (from > total) {
      from = total;
    }
    let to = end === undefined || end === null ? total : Math.trunc(Number(end)) || 0;
    if (to < 0) {
      to = Math.max(total + to, 0);
    }
    if (to > total) {
      to = total;
    }
    if (to < from) {
      to = from;
    }
    return this._bytes.subarray(from, to);
  }

  toString(encoding, start, end) {
    return decodeBytes(this._view(start, end), encoding);
  }

  toJSON() {
    const length = this._bytes.length;
    const data = new Array(length);
    for (let i = 0; i < length; i += 1) {
      data[i] = this._bytes[i];
    }
    return { type: 'Buffer', data };
  }

  /** 字节级比较；入参不是字节容器时返回 false（Node 会抛错，这里宽容一些）。 */
  equals(other) {
    const bytes = asByteView(other);
    if (!bytes || bytes.length !== this._bytes.length) {
      return false;
    }
    for (let i = 0; i < bytes.length; i += 1) {
      if (bytes[i] !== this._bytes[i]) {
        return false;
      }
    }
    return true;
  }

  /** 兼容层没有下标读写，补一个 at()（负索引从尾部算）。 */
  at(index) {
    const total = this._bytes.length;
    const offset = Math.trunc(Number(index)) || 0;
    const position = offset < 0 ? total + offset : offset;
    if (position < 0 || position >= total) {
      return undefined;
    }
    return this._bytes[position];
  }

  slice(start, end) {
    return new Buffer(BUFFER_TOKEN, this._view(start, end));
  }

  subarray(start, end) {
    return new Buffer(BUFFER_TOKEN, this._view(start, end));
  }

  /** write(str, offset?, length?, encoding?)：返回写入的字节数。 */
  write(string, offset, length, encoding) {
    let start = 0;
    let limit;
    let enc = encoding;
    if (typeof offset === 'string') {
      enc = offset;
    } else if (offset !== undefined && offset !== null) {
      start = Math.max(0, Math.trunc(Number(offset)) || 0);
      if (typeof length === 'string') {
        enc = length;
      } else if (length !== undefined && length !== null) {
        limit = Math.max(0, Math.trunc(Number(length)) || 0);
      }
    }
    const bytes = encodeString(string, enc);
    let room = Math.max(0, this._bytes.length - start);
    if (limit !== undefined) {
      room = Math.min(room, limit);
    }
    const count = Math.min(bytes.length, room);
    for (let i = 0; i < count; i += 1) {
      this._bytes[start + i] = bytes[i];
    }
    return count;
  }

  /** copy(target, targetStart?, sourceStart?, sourceEnd?)：返回复制的字节数。 */
  copy(target, targetStart, sourceStart, sourceEnd) {
    const dest = asByteView(target);
    if (!dest) {
      throw new TypeError('Buffer.copy 的目标必须是 Buffer / Uint8Array');
    }
    const source = this._view(sourceStart, sourceEnd);
    const start =
      targetStart === undefined || targetStart === null
        ? 0
        : Math.max(0, Math.trunc(Number(targetStart)) || 0);
    const count = Math.max(0, Math.min(source.length, dest.length - start));
    for (let i = 0; i < count; i += 1) {
      dest[start + i] = source[i];
    }
    return count;
  }

  /** fill(value, start?, end?, encoding?)：value 可以是数字 / 字符串 / Buffer。 */
  fill(value, start, end, encoding) {
    let from = start;
    let to = end;
    let enc = encoding;
    if (typeof start === 'string') {
      enc = start;
      from = undefined;
      to = undefined;
    }
    const view = this._view(from, to);
    const pattern = asByteView(value);
    if (pattern && pattern.length > 0) {
      // 字符串 / Buffer：按模式循环填充（与 Node 一致）
      for (let i = 0; i < view.length; i += 1) {
        view[i] = pattern[i % pattern.length];
      }
      return this;
    }
    if (pattern) {
      // 空字符串 / 空 Buffer：Node 视作填 0
      for (let i = 0; i < view.length; i += 1) {
        view[i] = 0;
      }
      return this;
    }
    if (typeof value === 'string') {
      const bytes = encodeString(value, enc);
      for (let i = 0; i < view.length; i += 1) {
        view[i] = bytes.length ? bytes[i % bytes.length] : 0;
      }
      return this;
    }
    const byte = Number(value) & 0xff;
    for (let i = 0; i < view.length; i += 1) {
      view[i] = byte;
    }
    return this;
  }

  /* ------------------------- 静态构造 ------------------------- */

  static from(value, encodingOrOffset, length) {
    if (typeof value === 'string') {
      return new Buffer(BUFFER_TOKEN, encodeString(value, encodingOrOffset));
    }
    if (value instanceof Buffer) {
      return new Buffer(BUFFER_TOKEN, copyByteView(value._bytes));
    }
    if (value instanceof ArrayBuffer) {
      // 与 Node 一致：ArrayBuffer 入参共享内存（可带 byteOffset / length）
      const offset =
        encodingOrOffset === undefined || encodingOrOffset === null
          ? 0
          : Math.max(0, Math.trunc(Number(encodingOrOffset)) || 0);
      const rest = Math.max(0, value.byteLength - offset);
      const size =
        length === undefined || length === null
          ? rest
          : Math.max(0, Math.min(rest, Math.trunc(Number(length)) || 0));
      return new Buffer(BUFFER_TOKEN, new Uint8Array(value, offset, size));
    }
    if (value && typeof value === 'object') {
      if (typeof ArrayBuffer.isView === 'function' && ArrayBuffer.isView(value)) {
        // TypedArray / DataView：复制字节（Node 对 TypedArray 也是复制）
        return new Buffer(
          BUFFER_TOKEN,
          copyByteView(new Uint8Array(value.buffer, value.byteOffset, value.byteLength)),
        );
      }
      if (typeof value.length === 'number') {
        // 普通数组 / 类数组：逐项 & 0xff（Node 同款截断语义）
        const bytes = new Uint8Array(value.length);
        for (let i = 0; i < bytes.length; i += 1) {
          bytes[i] = Number(value[i]) & 0xff;
        }
        return new Buffer(BUFFER_TOKEN, bytes);
      }
    }
    throw new TypeError('Buffer.from 只接受 string / Buffer / ArrayBuffer / TypedArray / Array');
  }

  static alloc(size, fillValue, encoding) {
    const total = Math.max(0, Math.trunc(Number(size)) || 0);
    const buffer = new Buffer(BUFFER_TOKEN, new Uint8Array(total));
    if (fillValue !== undefined && fillValue !== null && fillValue !== 0) {
      buffer.fill(fillValue, 0, total, encoding);
    }
    return buffer;
  }

  /** allocUnsafe 在 QuickJS 里没有「未初始化内存」的概念，直接给零填充的 Buffer。 */
  static allocUnsafe(size) {
    return Buffer.alloc(size);
  }

  static isBuffer(value) {
    return value instanceof Buffer;
  }

  static concat(list, totalLength) {
    const items = Array.isArray(list) ? list : [];
    const views = [];
    let sum = 0;
    for (let i = 0; i < items.length; i += 1) {
      const view = asByteView(items[i]);
      if (view) {
        views.push(view);
        sum += view.length;
      }
    }
    const total =
      totalLength === undefined || totalLength === null
        ? sum
        : Math.max(0, Math.trunc(Number(totalLength)) || 0);
    const out = new Uint8Array(total);
    let cursor = 0;
    for (let i = 0; i < views.length && cursor < total; i += 1) {
      const view = views[i];
      const count = Math.min(view.length, total - cursor);
      for (let k = 0; k < count; k += 1) {
        out[cursor + k] = view[k];
      }
      cursor += count;
    }
    return new Buffer(BUFFER_TOKEN, out);
  }

  static byteLength(value, encoding) {
    if (typeof value === 'string') {
      return encodeString(value, encoding).length;
    }
    const bytes = asByteView(value);
    if (bytes) {
      return bytes.length;
    }
    throw new TypeError('Buffer.byteLength 只接受 string / Buffer / TypedArray / ArrayBuffer');
  }

  static isEncoding(encoding) {
    const text = String(encoding === undefined || encoding === null ? '' : encoding)
      .trim()
      .toLowerCase()
      .replace(/_/g, '-');
    return BUFFER_ENCODINGS.indexOf(text) !== -1;
  }

  /** 字节序比较：a < b 返回 -1，相等 0，a > b 返回 1。 */
  static compare(a, b) {
    const left = asByteView(a) || new Uint8Array(0);
    const right = asByteView(b) || new Uint8Array(0);
    const length = Math.min(left.length, right.length);
    for (let i = 0; i < length; i += 1) {
      if (left[i] !== right[i]) {
        return left[i] < right[i] ? -1 : 1;
      }
    }
    if (left.length === right.length) {
      return 0;
    }
    return left.length < right.length ? -1 : 1;
  }
}

/** `require('buffer')` / `require('node:buffer')` 的返回值（默认导出也指向自己）。 */
export const bufferModule = (() => {
  const mod = {
    Buffer,
    SlowBuffer: Buffer,
    kMaxLength: 0x7fffffff,
    INSPECT_MAX_BYTES: 50,
  };
  mod.default = mod;
  return mod;
})();

/**
 * 把 Buffer 装到 target（默认 globalThis）上。这里**不**像 installWebGlobals
 * 那样「已存在就跳过」：沙箱里本来就没有 Buffer，宿主即便注入过第三方实现，
 * 也要保证 globalThis.Buffer 和 require('buffer').Buffer 是同一个类，
 * 否则 `Buffer.isBuffer(x)` 这类判断会跨实现失效。
 */
export function installBufferGlobals(target = globalThis) {
  if (!target) {
    return target;
  }
  try {
    target.Buffer = Buffer;
  } catch (e) {
    // 只读全局装不上就算了
  }
  return target;
}
