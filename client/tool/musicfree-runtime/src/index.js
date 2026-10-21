import * as cheerioNS from 'cheerio';
import CryptoJS from 'crypto-js';
import dayjs from 'dayjs';
import bigInt from 'big-integer';
import qs from 'qs';
import he from 'he';
import axios from 'axios';

import { createAdapter } from './http.js';
import { createStorage } from './storage.js';
import {
  bufferModule,
  createCookieJar,
  installBufferGlobals,
  installWebGlobals,
  webdavStub,
} from './shims.js';

// 与 MusicFree 一致：axios 默认 15 秒超时
axios.defaults.timeout = 15000;

function withDefault(mod) {
  if (mod && typeof mod === 'object') {
    try {
      mod.default = mod;
    } catch (e) {
      // 冻结对象就算了
    }
  }
  return mod;
}

function createAxiosInstance(jar) {
  const instance = axios.create({ timeout: 15000, adapter: createAdapter(jar) });
  instance.default = instance;
  instance.AxiosError = axios.AxiosError;
  instance.CancelToken = axios.CancelToken;
  instance.isCancel = axios.isCancel;
  instance.all = (list) => Promise.all(list);
  instance.spread = (callback) => (list) => callback.apply(null, list);
  return instance;
}

/// 插件经常 `console.log` 整个响应对象：`JSON.stringify` 是递归实现，
/// 层级一深就会把 QuickJS 的原生栈撑爆（Windows 事件里是 quickjs 桥 0xc00000fd，
/// 进程直接消失）。这里自己做一次有限步的序列化：限制深度 / 元素数 / 文本长度，
/// 并把循环引用标出来。
const LOG_MAX_DEPTH = 3;
const LOG_MAX_ITEMS = 20;
const LOG_MAX_TEXT = 2000;

function safeStringify(value) {
  const seen = [];
  const shortText = (text) =>
    text.length > LOG_MAX_TEXT ? `${text.slice(0, LOG_MAX_TEXT)}…` : text;
  const walk = (item, depth) => {
    if (item === null) {
      return 'null';
    }
    const type = typeof item;
    if (type === 'string') {
      return JSON.stringify(shortText(item));
    }
    if (type === 'number' || type === 'boolean' || type === 'bigint') {
      return String(item);
    }
    if (type === 'undefined') {
      return 'undefined';
    }
    if (type === 'function') {
      return '[Function]';
    }
    if (type === 'symbol') {
      return String(item);
    }
    if (item instanceof Error) {
      return JSON.stringify(shortText(`${item.name}: ${item.message}`));
    }
    if (seen.indexOf(item) >= 0) {
      return '[Circular]';
    }
    if (depth <= 0) {
      return Array.isArray(item) ? '[Array]' : '[Object]';
    }
    seen.push(item);
    let text;
    if (Array.isArray(item)) {
      const items = item
        .slice(0, LOG_MAX_ITEMS)
        .map((entry) => walk(entry, depth - 1));
      if (item.length > LOG_MAX_ITEMS) {
        items.push('…');
      }
      text = `[${items.join(',')}]`;
    } else {
      const keys = Object.keys(item);
      const items = keys
        .slice(0, LOG_MAX_ITEMS)
        .map((key) => `${JSON.stringify(key)}:${walk(item[key], depth - 1)}`);
      if (keys.length > LOG_MAX_ITEMS) {
        items.push('…');
      }
      text = `{${items.join(',')}}`;
    }
    seen.pop();
    return text;
  };
  try {
    return walk(value, LOG_MAX_DEPTH);
  } catch (e) {
    return '[unserializable]';
  }
}

function shortLogString(text) {
  return text.length > LOG_MAX_TEXT ? `${text.slice(0, LOG_MAX_TEXT)}…` : text;
}

function shortLogText(args) {
  const parts = [];
  for (let index = 0; index < args.length && index < LOG_MAX_ITEMS; index += 1) {
    const item = args[index];
    parts.push(
      typeof item === 'string' ? shortLogString(item) : safeStringify(item),
    );
  }
  return parts.join(' ');
}

function makeConsole(pluginKey) {
  const emit = (level) =>
    function emitLog(...args) {
      try {
        const message = shortLogText(args);
        sendMessage('mf.log', JSON.stringify({ plugin: pluginKey, level, message }));
      } catch (e) {
        // 打日志失败无所谓
      }
    };
  return {
    log: emit('log'),
    info: emit('info'),
    warn: emit('warn'),
    error: emit('error'),
    debug: emit('debug'),
    logger: emit('log'),
  };
}

function parseOptions(options) {
  if (!options) {
    return {};
  }
  if (typeof options === 'string') {
    try {
      return JSON.parse(options);
    } catch (e) {
      return {};
    }
  }
  return options;
}

const STATIC_META_KEYS = [
  'platform',
  'version',
  'author',
  'description',
  'homepage',
  'srcUrl',
  'appVersion',
  'primaryKey',
  'defaultSearchType',
  'supportedSearchType',
  'cacheControl',
  'hints',
];

/**
 * 插件来自 MusicFree 桌面端（Electron 主进程），代码里直接用 URLSearchParams /
 * URL / TextEncoder / TextDecoder / atob / btoa / structuredClone 这些 Web 全局。
 * QuickJS 沙箱没有它们，必须在任何插件代码执行之前装好（已存在的不覆盖）。
 */
installWebGlobals(globalThis);
// Node 内置 Buffer：真实插件里 `Buffer.from(...).toString('base64')`、
// `Buffer.isBuffer(data)` 都直接依赖这个全局（见 shims.js 的兼容层说明）。
installBufferGlobals(globalThis);

// 一个 JS 运行时里托管多个插件实例（等价 MusicFree 主进程里的 Plugin 列表）
globalThis.__mfInstances = globalThis.__mfInstances || {};
globalThis.__mfRequires = globalThis.__mfRequires || {};
globalThis.__mfConsoles = globalThis.__mfConsoles || {};
globalThis.__mfEnvs = globalThis.__mfEnvs || {};

/**
 * 定时器：quickjs_engine 自带 setTimeout 但不返回 id、也没有 setInterval，
 * 这里统一改成 Dart 侧调度，语义与浏览器一致。
 */
globalThis.__mfTimerCallbacks = globalThis.__mfTimerCallbacks || {};
globalThis.__mfTimerSeq = globalThis.__mfTimerSeq || 0;

globalThis.__mfRunTimer = function mfRunTimer(id) {
  const callback = globalThis.__mfTimerCallbacks[id];
  if (typeof callback === 'function') {
    callback();
  }
};

globalThis.setTimeout = function mfSetTimeout(callback, delay) {
  globalThis.__mfTimerSeq += 1;
  const id = globalThis.__mfTimerSeq;
  globalThis.__mfTimerCallbacks[id] = callback;
  sendMessage('mf.timer', JSON.stringify({ id, delay: delay || 0, repeat: false }));
  return id;
};

globalThis.setInterval = function mfSetInterval(callback, delay) {
  globalThis.__mfTimerSeq += 1;
  const id = globalThis.__mfTimerSeq;
  globalThis.__mfTimerCallbacks[id] = callback;
  sendMessage('mf.timer', JSON.stringify({ id, delay: delay || 0, repeat: true }));
  return id;
};

const clearTimer = (id) => {
  delete globalThis.__mfTimerCallbacks[id];
  try {
    sendMessage('mf.clearTimer', JSON.stringify({ id }));
  } catch (e) {
    // pass
  }
};

globalThis.clearTimeout = clearTimer;
globalThis.clearInterval = clearTimer;

globalThis.__mfRuntime = {
  version: '1.0.0',

  /** 为某个插件创建 require（axios 实例、storage、cookie jar 都是插件私有的）。 */
  createRequire(options) {
    const opts = parseOptions(options);
    const pluginKey = opts.plugin || 'unknown';
    const jar = createCookieJar(pluginKey, opts.cookies || []);
    const storage = createStorage(pluginKey, opts.storage || {});
    const instance = createAxiosInstance(jar);

    const modules = {
      cheerio: withDefault(cheerioNS),
      'crypto-js': withDefault(CryptoJS),
      axios: instance,
      dayjs: withDefault(dayjs),
      'big-integer': withDefault(bigInt),
      qs: withDefault(qs),
      he: withDefault(he),
      '@react-native-cookies/cookies': withDefault(jar.api),
      // Node 内置模块：插件里 require('buffer') / require('node:buffer') 都能拿到 Buffer
      buffer: bufferModule,
      'node:buffer': bufferModule,
      webdav: webdavStub,
      'musicfree/storage': withDefault(storage),
    };

    globalThis.__mfConsoles[pluginKey] = makeConsole(pluginKey);

    const requireFn = function mfRequire(name) {
      const pkg = modules[name];
      if (pkg) {
        try {
          pkg.default = pkg;
        } catch (e) {
          // pass
        }
        return pkg;
      }
      return null;
    };
    globalThis.__mfRequires[pluginKey] = requireFn;
    return requireFn;
  },

  /** 按 MusicFree 的 Plugin 构造函数方式执行插件代码。 */
  loadPlugin(pluginKey, code, options) {
    const opts = parseOptions(options);
    const env = {
      getUserVariables: () => opts.userVariables || {},
      os: opts.os || 'win32',
      appVersion: opts.appVersion || '1.0.0',
      lang: opts.lang || 'zh-CN',
    };
    const processShim = {
      platform: opts.os || 'win32',
      version: opts.appVersion || '1.0.0',
      env,
      ensurePluginInitialized: Promise.resolve(),
    };
    const pluginModule = { exports: {}, loaded: false };
    const requireFn = globalThis.__mfRequires[pluginKey];
    const factory = Function(
      'require',
      '__musicfree_require',
      'module',
      'exports',
      'console',
      'env',
      'process',
      `'use strict';\n${code}`,
    );
    factory(
      requireFn,
      requireFn,
      pluginModule,
      pluginModule.exports,
      globalThis.__mfConsoles[pluginKey],
      env,
      processShim,
    );
    const exported = pluginModule.exports || {};
    const instance = exported.default ? exported.default : exported;
    if (Array.isArray(instance.userVariables)) {
      instance.userVariables = instance.userVariables.filter((item) => item && item.key);
    }
    instance._path = opts.path || '';
    globalThis.__mfInstances[pluginKey] = instance;
    globalThis.__mfEnvs[pluginKey] = env;
    pluginModule.loaded = true;
    return true;
  },

  /** 抽出「非函数属性 + 支持的方法名」，等价 MusicFree 的 IPluginDelegate。 */
  describe(pluginKey) {
    const instance = globalThis.__mfInstances[pluginKey];
    const supportedMethod = [];
    const meta = {};
    if (instance && typeof instance === 'object') {
      Object.keys(instance).forEach((key) => {
        if (key === '_path') {
          return;
        }
        const value = instance[key];
        if (typeof value === 'function') {
          supportedMethod.push(key);
          return;
        }
        if (STATIC_META_KEYS.indexOf(key) !== -1 || key === 'userVariables') {
          try {
            meta[key] = value === undefined ? null : JSON.parse(JSON.stringify(value));
          } catch (e) {
            // 不可序列化就跳过
          }
        }
      });
    }
    return JSON.stringify({ supportedMethod, meta });
  },

  /**
   * 一次性装载插件：createRequire → 执行源码 → describe。
   *
   * 以前这三步在 Dart 侧各是一次 evaluate（外加一次注入源码），装 N 个插件就是
   * 4N 次跨桥往返——每次都要切一次 JS 引擎，UI 线程被切得稀碎。合成一次只多带
   * 一段源码字符串，返回值就是 describe 的 JSON。
   */
  install(pluginKey, code, optionsJson, storageJson, cookiesJson) {
    // 源码走单独参数：调用方只转义一次，这里也不再 JSON.parse 整个 payload。
    // 以前同一份插件源码要被解析三次（外文字面量 → JSON.parse → Function 编译），
    // 大插件光这一项就要几秒。
    const options = parseOptions(optionsJson);
    let stage = '插件依赖初始化';
    try {
      this.createRequire({
        plugin: pluginKey,
        storage: parseOptions(storageJson) || {},
        cookies: parseOptions(cookiesJson) || [],
      });
      stage = '插件源码执行';
      this.loadPlugin(pluginKey, code, options);
      stage = '插件信息解析';
      return this.describe(pluginKey);
    } catch (error) {
      const detail = error && error.message ? error.message : String(error);
      throw new Error(`${stage}失败：${detail}`);
    }
  },

  /** 调用插件方法：payload 是参数数组（JSON 字符串）。 */
  invoke(pluginKey, method, payloadJson) {
    const instance = globalThis.__mfInstances[pluginKey];
    if (!instance || typeof instance[method] !== 'function') {
      return Promise.reject(new Error(`插件没有实现 ${method}`));
    }
    let args;
    try {
      args = typeof payloadJson === 'string' ? JSON.parse(payloadJson) : payloadJson || [];
    } catch (e) {
      return Promise.reject(new Error('参数不是合法 JSON'));
    }
    try {
      return Promise.resolve(instance[method].apply(instance, args));
    } catch (e) {
      return Promise.reject(e);
    }
  },

  /** Dart 侧统一走这个包装：永远 resolve 成 {ok, value|error} 的 JSON 字符串。 */
  invokeJson(pluginKey, method, payloadJson) {
    return globalThis.__mfRuntime.invoke(pluginKey, method, payloadJson).then(
      (value) => JSON.stringify({ ok: true, value: value === undefined ? null : value }),
      (error) => JSON.stringify({ ok: false, error: String((error && error.message) || error) }),
    );
  },

  unloadPlugin(pluginKey) {
    delete globalThis.__mfInstances[pluginKey];
    delete globalThis.__mfRequires[pluginKey];
    delete globalThis.__mfConsoles[pluginKey];
    delete globalThis.__mfEnvs[pluginKey];
  },
};