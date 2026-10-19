import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

/// 内联的「假插件」：形态对齐 MusicFree 真实插件，方法里分别用到
/// URLSearchParams / URL / TextEncoder / TextDecoder / atob / btoa /
/// structuredClone，并把结果返回给 Dart 侧断言。
///
/// 说明：源码里的中文一律写成 \uXXXX 转义，避免注入时受文件编码影响。
const String _webGlobalsProbePlugin = r'''
const BASE = "https://music.example.com";

function getTouristToken() {
  return Promise.resolve("tourist-token");
}

// 真实插件（某音乐 API）里 postRaw 就是这么拼 form body 的，
// 之前这里直接 ReferenceError: URLSearchParams is not defined
function postRaw(path, params) {
  const body = new URLSearchParams(params).toString();
  return Promise.resolve({ path: path, body: body });
}

async function request(path, params) {
  const token = await getTouristToken();
  const merged = Object.assign({}, params, { token: token });
  return await postRaw(path, merged);
}

module.exports = {
  platform: "web-globals-probe",
  version: "1.0.0",
  author: "probe",
  primaryKey: ["id"],
  supportedSearchType: ["music"],

  probeUrls() {
    const params = new URLSearchParams({ a: "1", b: "\u4F60\u597D" });
    params.append("c", "x y");
    const sorted = new URLSearchParams("b=2&a=1");
    sorted.sort();
    const abs = new URL("https://a.com/x?q=1#h");
    const rel = new URL("/p?x=2", "https://b.com:8443/z");
    abs.searchParams.set("q", "9");
    return {
      record: params.toString(),
      size: params.size,
      tag: Object.prototype.toString.call(params),
      keys: Array.from(params.keys()),
      sorted: sorted.toString(),
      host: abs.host,
      hostname: abs.hostname,
      pathname: abs.pathname,
      origin: abs.origin,
      hash: abs.hash,
      q: abs.searchParams.get("q"),
      mutated: abs.toString(),
      relative: rel.toString(),
      protocol: rel.protocol,
      port: rel.port,
    };
  },

  probeCodec() {
    const text = "\u4E2D\u6587abc";
    const bytes = new TextEncoder().encode(text);
    const back = new TextDecoder("utf-8").decode(bytes);
    const source = { list: [1, 2], nested: { a: "b" } };
    const cloned = structuredClone(source);
    cloned.nested.a = "changed";
    return {
      roundtrip: back,
      byteLength: bytes.length,
      isUint8: bytes instanceof Uint8Array,
      btoa: btoa("hi"),
      atob: atob("aGk="),
      cloneType: typeof structuredClone,
      sourceNested: source.nested.a,
      clonedNested: cloned.nested.a,
      sameRef: cloned === source,
    };
  },

  // Node 内置 Buffer（MusicFree 跑在 Node 里，插件直接用它做 base64 / hex 往返）。
  // 期望值全部按 Node 的真实行为写死。
  probeBuffer() {
    const bufferMod = require("buffer");
    const nodeBufferMod = require("node:buffer");
    const source = Buffer.from([97, 98, 99]);
    const copied = Buffer.alloc(3);
    const copiedCount = source.copy(copied, 1, 0, 2);
    const written = Buffer.alloc(4);
    const writtenCount = written.write("ab");
    return {
      cnLength: Buffer.from("\u4E2D\u6587abc").length,
      hex: Buffer.from("abc").toString("hex"),
      base64: Buffer.from("abc", "utf8").toString("base64"),
      base64Back: Buffer.from("YWJj", "base64").toString("utf8"),
      concat: Buffer.concat([Buffer.from("ab"), Buffer.from("cd")]).toString("utf8"),
      concatLength: Buffer.concat([Buffer.from("ab"), Buffer.from("c")], 5).length,
      isBufferAlloc: Buffer.isBuffer(Buffer.alloc(2)),
      isBufferArray: Buffer.isBuffer([1, 2]),
      isBufferUint8: Buffer.isBuffer(new Uint8Array(2)),
      requireSameClass: bufferMod.Buffer === Buffer,
      requireNodeSameClass: nodeBufferMod.Buffer === Buffer,
      moduleHasBuffer: bufferMod.hasBuffer !== false && typeof bufferMod.Buffer === "function",
      byteLength: Buffer.byteLength("\u4E2D\u6587"),
      latin1: Buffer.from("hi", "latin1").toString("latin1"),
      fill: Buffer.alloc(3).fill("ab").toString(),
      slice: Buffer.from("abcdef").slice(1, 3).toString(),
      subarray: Buffer.from("abcdef").subarray(2).toString(),
      equals: Buffer.from("ab").equals(Buffer.from("ab")),
      notEquals: Buffer.from("ab").equals(Buffer.from("ac")),
      json: JSON.stringify(Buffer.from("ab")),
      writeCount: writtenCount,
      copiedText: copied.toString("latin1"),
      copyCount: copiedCount,
      fromUint8: Buffer.from(new TextEncoder().encode("ab")).toString(),
      decodeBuffer: new TextDecoder().decode(Buffer.from("\u4E2D\u6587")),
      isArrayBufferView: Buffer.alloc(2).buffer instanceof ArrayBuffer,
    };
  },

  async search(query, page, type) {
    const raw = await request("/api/search", { keyword: query, page: String(page) });
    return {
      isEnd: true,
      data: [
        {
          id: "1",
          title: query,
          type: type,
          body: raw.body,
          url: new URL(BASE + raw.path).toString(),
        },
      ],
    };
  },
};
''';

/// MusicFree 运行时 bundle 的冒烟测试：确认随包分发的 JS 资源能在 QuickJS 中
/// 加载，并且 `require` 出来的模块行为与 MusicFree 一致。
void main() {
  late String source;

  setUpAll(() {
    final file = File('assets/musicfree/runtime.bundle.js');
    expect(file.existsSync(), isTrue, reason: '缺少 assets/musicfree/runtime.bundle.js');
    source = file.readAsStringSync();
  });

  JavascriptRuntime boot() {
    final js = getJavascriptRuntime(xhr: false);
    final loaded = js.evaluate(source);
    expect(loaded.isError, isFalse, reason: loaded.stringResult);
    final created = js.evaluate(
      r"""globalThis.__mfRequire = __mfRuntime.createRequire('{"plugin":"runtime-test"}')""",
    );
    expect(created.isError, isFalse, reason: created.stringResult);
    return js;
  }

  /// 求值并把结果按 JSON 解出来（flutter_js 的 stringResult 对字符串的处理
  /// 在「带引号 / 不带引号」之间摇摆，这里两种都兼容）。
  dynamic evalValue(JavascriptRuntime js, String expr) {
    final result = js.evaluate('JSON.stringify($expr)');
    expect(result.isError, isFalse, reason: result.stringResult);
    final text = result.stringResult;
    dynamic first;
    try {
      first = jsonDecode(text);
    } on FormatException {
      return text;
    }
    if (first is String) {
      try {
        return jsonDecode(first);
      } on FormatException {
        return first;
      }
    }
    return first;
  }

  /// 解析 JS 侧序列化出来的文本（一次或两次编码都兼容）。
  dynamic decodePayload(String text) {
    dynamic first;
    try {
      first = jsonDecode(text);
    } on FormatException {
      return text;
    }
    if (first is String) {
      try {
        return jsonDecode(first);
      } on FormatException {
        return first;
      }
    }
    return first;
  }

  /// 按 MusicFreeHost.loadPlugin 的方式把内联插件源码装进运行时。
  void loadInlinePlugin(JavascriptRuntime js, String key, String code) {
    final options = jsonEncode(<String, dynamic>{'plugin': key});
    final created = js.evaluate(
      'globalThis.__mfRequire = __mfRuntime.createRequire(${jsonEncode(options)})',
    );
    expect(created.isError, isFalse, reason: created.stringResult);
    final injected = js.evaluate('globalThis.__mfPluginCode = ${jsonEncode(code)}');
    expect(injected.isError, isFalse, reason: injected.stringResult);
    final loaded = js.evaluate(
      '__mfRuntime.loadPlugin(${jsonEncode(key)}, globalThis.__mfPluginCode, '
      '${jsonEncode(options)})',
    );
    expect(loaded.isError, isFalse, reason: loaded.stringResult);
  }

  /// 调用插件方法：走 invokeJson，用引擎自带的 handlePromise 等 Promise 落地。
  Future<dynamic> invokePlugin(
    JavascriptRuntime js,
    String key,
    String method, [
    List<Object?> args = const <Object?>[],
  ]) async {
    final raw = js.evaluate(
      '__mfRuntime.invokeJson(${jsonEncode(key)}, ${jsonEncode(method)}, '
      '${jsonEncode(jsonEncode(args))})',
    );
    expect(raw.isError, isFalse, reason: raw.stringResult);
    final resolved = await js.handlePromise(raw);
    final payload = decodePayload(resolved.stringResult);
    expect(payload, isA<Map<String, dynamic>>(), reason: resolved.stringResult);
    final map = payload as Map<String, dynamic>;
    expect(map['ok'], isTrue, reason: '插件抛错：${map['error']}');
    return map['value'];
  }

  test('bundle 暴露运行时 API', () {
    final js = boot();
    addTearDown(js.dispose);
    expect(evalValue(js, '__mfRuntime.version'), '1.0.0');
    expect(evalValue(js, 'typeof globalThis.__mfRuntime.createRequire'), 'function');
  });

  test('cheerio 能解析 HTML 并选择节点', () {
    final js = boot();
    addTearDown(js.dispose);
    final data = evalValue(js, '''
      (() => {
        const cheerio = globalThis.__mfRequire('cheerio');
        const \$ = cheerio.load('<div class="a"><span id="s">hi &amp; bye</span><a href="/x">link</a></div>');
        return {
          text: \$('.a span').text(),
          id: \$('#s').attr('id'),
          href: \$('a').attr('href'),
          count: \$('div span, div a').length,
        };
      })()
    ''') as Map<String, dynamic>;
    expect(data['text'], 'hi & bye');
    expect(data['id'], 's');
    expect(data['href'], '/x');
    expect(data['count'], 2);
  });

  test('crypto-js 与已知向量一致', () {
    final js = boot();
    addTearDown(js.dispose);
    final data = evalValue(js, '''
      (() => {
        const CryptoJS = globalThis.__mfRequire('crypto-js');
        return {
          md5: CryptoJS.MD5('abc').toString(),
          sha256: CryptoJS.SHA256('abc').toString(),
          hmac: CryptoJS.HmacSHA256('abc', 'key').toString(CryptoJS.enc.Hex),
        };
      })()
    ''') as Map<String, dynamic>;
    expect(data['md5'], '900150983cd24fb0d6963f7d28e17f72');
    expect(
      data['sha256'],
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      data['hmac'],
      '9c196e32dc0175f86f4b1cb89289d6619de6bee699e4c378e68309ed97a1a6ab',
    );
  });

  test('qs / he / dayjs / big-integer 可用', () {
    final js = boot();
    addTearDown(js.dispose);
    final data = evalValue(js, '''
      (() => {
        const qs = globalThis.__mfRequire('qs');
        const he = globalThis.__mfRequire('he');
        const dayjs = globalThis.__mfRequire('dayjs');
        const bigInt = globalThis.__mfRequire('big-integer');
        return {
          qs: qs.stringify({ a: 1, b: 'x y' }),
          he: he.decode('a &lt; b &amp; c'),
          day: dayjs('2024-01-02T03:04:05Z').format('YYYY/MM/DD'),
          big: bigInt('123456789012345678901234567890').add(1).toString(),
        };
      })()
    ''') as Map<String, dynamic>;
    expect(data['qs'], 'a=1&b=x%20y');
    expect(data['he'], 'a < b & c');
    expect(data['day'], '2024/01/02');
    expect(data['big'], '123456789012345678901234567891');
  });

  test('webdav / cookies / storage 模块存在且 API 形状一致', () {
    final js = boot();
    addTearDown(js.dispose);
    final data = evalValue(js, '''
      (() => {
        const webdav = globalThis.__mfRequire('webdav');
        const cookies = globalThis.__mfRequire('@react-native-cookies/cookies');
        const storage = globalThis.__mfRequire('musicfree/storage');
        return {
          webdav: typeof webdav.createClient,
          cookieGet: typeof cookies.get,
          cookieSet: typeof cookies.set,
          storageGet: typeof storage.getItem,
          storageSet: typeof storage.setItem,
          unknown: globalThis.__mfRequire('not-a-module'),
        };
      })()
    ''') as Map<String, dynamic>;
    expect(data['webdav'], 'function');
    expect(data['cookieGet'], 'function');
    expect(data['cookieSet'], 'function');
    expect(data['storageGet'], 'function');
    expect(data['storageSet'], 'function');
    expect(data['unknown'], isNull);
  });
  test('Web 全局：URLSearchParams / URL 可用', () async {
    final js = boot();
    addTearDown(js.dispose);
    loadInlinePlugin(js, 'web-globals', _webGlobalsProbePlugin);
    final data =
        await invokePlugin(js, 'web-globals', 'probeUrls') as Map<String, dynamic>;
    // record -> a=1&b=你好 用 encodeURIComponent 编码，空格是 %20
    expect(data['record'], 'a=1&b=%E4%BD%A0%E5%A5%BD&c=x%20y');
    expect(data['size'], 3);
    // axios 靠 Symbol.toStringTag 判断「是不是 URLSearchParams」
    expect(data['tag'], '[object URLSearchParams]');
    expect(data['keys'], <String>['a', 'b', 'c']);
    expect(data['sorted'], 'a=1&b=2');
    // new URL('https://a.com/x?q=1#h')
    expect(data['host'], 'a.com');
    expect(data['hostname'], 'a.com');
    expect(data['pathname'], '/x');
    expect(data['origin'], 'https://a.com');
    expect(data['hash'], '#h');
    // searchParams.set 之后 toString() 要跟着变
    expect(data['q'], '9');
    expect(data['mutated'], 'https://a.com/x?q=9#h');
    // 相对地址 + base
    expect(data['relative'], 'https://b.com:8443/p?x=2');
    expect(data['protocol'], 'https:');
    expect(data['port'], '8443');
  });

  test('Web 全局：TextEncoder / TextDecoder / atob+btoa / structuredClone 可用', () async {
    final js = boot();
    addTearDown(js.dispose);
    loadInlinePlugin(js, 'web-globals', _webGlobalsProbePlugin);
    final data =
        await invokePlugin(js, 'web-globals', 'probeCodec') as Map<String, dynamic>;
    // new TextDecoder().decode(new TextEncoder().encode('中文abc'))
    expect(data['roundtrip'], '\u4E2D\u6587abc');
    expect(data['byteLength'], 9);
    expect(data['isUint8'], isTrue);
    expect(data['btoa'], 'aGk=');
    expect(data['atob'], 'hi');
    expect(data['cloneType'], 'function');
    // 克隆体与源对象互不影响（近似深拷贝）
    expect(data['sourceNested'], 'b');
    expect(data['clonedNested'], 'changed');
    expect(data['sameRef'], isFalse);
  });

  test('真实插件形态：postRaw 用 URLSearchParams 拼 body 不再抛错', () async {
    final js = boot();
    addTearDown(js.dispose);
    loadInlinePlugin(js, 'web-globals', _webGlobalsProbePlugin);
    final result = await invokePlugin(js, 'web-globals', 'search', <Object?>[
      'abc',
      1,
      'music',
    ]) as Map<String, dynamic>;
    expect(result['isEnd'], isTrue);
    final item = (result['data'] as List).first as Map<String, dynamic>;
    expect(item['title'], 'abc');
    expect(item['type'], 'music');
    // ReferenceError: URLSearchParams is not defined -> 现在能正常拼出 body
    expect(item['body'], 'keyword=abc&page=1&token=tourist-token');
    expect(item['url'], 'https://music.example.com/api/search');
  });

  test('Buffer：全局 Buffer 覆盖 from / toString / concat / isBuffer 与各编码', () {
    final js = boot();
    addTearDown(js.dispose);
    final data = evalValue(js, r'''
      (() => {
        const cn = Buffer.from('\u4E2D\u6587abc');
        const copy = Buffer.alloc(3);
        const copied = Buffer.from([97, 98, 99]).copy(copy, 1, 0, 2);
        const written = Buffer.alloc(4);
        return {
          cnLength: cn.length,
          cnText: cn.toString('utf8'),
          hex: Buffer.from('abc').toString('hex'),
          base64: Buffer.from('abc', 'utf8').toString('base64'),
          base64Back: Buffer.from('YWJj', 'base64').toString('utf8'),
          concat: Buffer.concat([Buffer.from('ab'), Buffer.from('cd')]).toString('utf8'),
          concatTruncated: Buffer.concat([Buffer.from('ab'), Buffer.from('cd')], 3).toString('utf8'),
          isBuffer: Buffer.isBuffer(Buffer.alloc(2)),
          isBufferUint8: Buffer.isBuffer(new Uint8Array(2)),
          byteLength: Buffer.byteLength('\u4E2D\u6587'),
          latin1: Buffer.from('hi', 'binary').toString('latin1'),
          asciiMasked: Buffer.from('\u00FF', 'ascii').at(0),
          fromArray: Buffer.from([0x61, 0x62, 256]).toString('hex'),
          fromUint8: Buffer.from(new TextEncoder().encode('ab')).toString(),
          slice: Buffer.from('abcdef').slice(1, 3).toString(),
          subarray: Buffer.from('abcdef').subarray(2).toString(),
          json: JSON.stringify(Buffer.from('ab')),
          fill: Buffer.alloc(3).fill('ab').toString(),
          writeCount: written.write('ab'),
          written: written.toString('latin1'),
          copyCount: copied,
          copied: copy.toString('latin1'),
          equals: Buffer.from('ab').equals(Buffer.from('ab')),
          notEquals: Buffer.from('ab').equals(Buffer.from('ac')),
          decodeBuffer: new TextDecoder().decode(Buffer.from('\u4E2D\u6587')),
          isArrayBuffer: Buffer.alloc(2).buffer instanceof ArrayBuffer,
        };
      })()
    ''') as Map<String, dynamic>;
    expect(data['cnLength'], 9);
    expect(data['cnText'], '\u4E2D\u6587abc');
    expect(data['hex'], '616263');
    expect(data['base64'], 'YWJj');
    expect(data['base64Back'], 'abc');
    expect(data['concat'], 'abcd');
    expect(data['concatTruncated'], 'abc');
    expect(data['isBuffer'], isTrue);
    expect(data['isBufferUint8'], isFalse);
    expect(data['byteLength'], 6);
    expect(data['latin1'], 'hi');
    // ascii 与 Node 一致按 7 位截断
    expect(data['asciiMasked'], 0x7f);
    expect(data['fromArray'], '616200');
    expect(data['fromUint8'], 'ab');
    expect(data['slice'], 'bc');
    expect(data['subarray'], 'cdef');
    expect(data['json'], '{"type":"Buffer","data":[97,98]}');
    expect(data['fill'], 'aba');
    expect(data['writeCount'], 2);
    expect(data['written'], 'ab\u0000\u0000');
    expect(data['copyCount'], 2);
    expect(data['copied'], '\u0000ab');
    expect(data['equals'], isTrue);
    expect(data['notEquals'], isFalse);
    expect(data['decodeBuffer'], '\u4E2D\u6587');
    expect(data['isArrayBuffer'], isTrue);
  });

  test('Buffer：插件里 require("buffer") / require("node:buffer") 拿到同一个 Buffer', () async {
    final js = boot();
    addTearDown(js.dispose);
    loadInlinePlugin(js, 'web-globals', _webGlobalsProbePlugin);
    final data =
        await invokePlugin(js, 'web-globals', 'probeBuffer') as Map<String, dynamic>;
    expect(data['cnLength'], 9);
    expect(data['hex'], '616263');
    expect(data['base64'], 'YWJj');
    expect(data['base64Back'], 'abc');
    expect(data['concat'], 'abcd');
    expect(data['concatLength'], 5);
    expect(data['isBufferAlloc'], isTrue);
    expect(data['isBufferArray'], isFalse);
    expect(data['isBufferUint8'], isFalse);
    // createRequire 的 `pkg.default = pkg` 约定下仍然拿到同一个类
    expect(data['requireSameClass'], isTrue);
    expect(data['requireNodeSameClass'], isTrue);
    expect(data['moduleHasBuffer'], isTrue);
    expect(data['byteLength'], 6);
    expect(data['latin1'], 'hi');
    expect(data['fill'], 'aba');
    expect(data['slice'], 'bc');
    expect(data['subarray'], 'cdef');
    expect(data['equals'], isTrue);
    expect(data['notEquals'], isFalse);
    expect(data['json'], '{"type":"Buffer","data":[97,98]}');
    expect(data['writeCount'], 2);
    expect(data['copyCount'], 2);
    expect(data['copiedText'], '\u0000ab');
    expect(data['fromUint8'], 'ab');
    expect(data['decodeBuffer'], '\u4E2D\u6587');
    expect(data['isArrayBufferView'], isTrue);
  });
}