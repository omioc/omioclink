import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

import '../core/app_log.dart';
import '../core/system_proxy.dart';
import 'plugin_models.dart';
import 'plugin_paths.dart';

/// 插件执行失败（解析失败、超时、方法抛错……）。
class MusicFreeException implements Exception {
  const MusicFreeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _LoadedEntry {
  _LoadedEntry({required this.plugin});

  MusicFreePlugin plugin;
  final Map<String, Timer> timers = <String, Timer>{};

  void cancelTimers() {
    for (final timer in timers.values) {
      timer.cancel();
    }
    timers.clear();
  }
}

/// MusicFree 插件宿主。
///
/// 与 MusicFree 的 `PluginManager` 对齐：**一个 JS 运行时托管多个插件实例**，
/// 插件通过 `require(...)` 拿到 axios / cheerio / crypto-js 等模块，
/// 宿主负责把 HTTP、storage、cookie、定时器桥接回 Dart。
class MusicFreeHost {
  MusicFreeHost({
    http.Client? httpClient,
    PluginPaths? paths,
    String? bundleSource,
    this.appVersion = '1.0.0',
    this.lang = 'zh-CN',
  }) : _http = httpClient ?? _clientWithProxy(SystemProxy.address),
       _paths = paths ?? PluginPaths(),
       _injectedBundle = bundleSource;

  final http.Client _http;
  final PluginPaths _paths;
  final String appVersion;
  final String lang;

  final String? _injectedBundle;
  String? _cachedBundle;

  JavascriptRuntime? _js;
  final Map<String, _LoadedEntry> _entries = <String, _LoadedEntry>{};
  bool _disposed = false;
  /// 正在落盘的插件写入（storage / cookie）。调用结束前等它们写完，
  /// 免得「点了按钮立刻重启」时数据还在半路上。
  ///
  /// 注意：**HTTP 请求不进这个集合**。以前连请求一起等，等于让每次插件调用
  /// 都陪跑别人的网络往返（最多 2 秒），聚合搜索的「转圈」有一半来自这里。
  final Set<Future<void>> _pending = <Future<void>>{};

  /// 回投 JS 的串行队列（HTTP 响应 / 定时器）。
  ///
  /// 真实聚合插件一次搜索会并发十几个请求，响应几乎同时回来；如果每次都直接
  /// `evaluate`，会和多份 promise 的轮询交叠在一起，QuickJS 桥在那种情况下会
  /// 栈溢出（native `0xc00000fd`，进程直接消失）。这里把它们排成一条队逐个进引擎。
  Future<void> _jsQueue = Future<void>.value();

  void _enqueueJs(void Function() action) {
    _jsQueue = _jsQueue.then((_) async {
      if (_disposed) {
        return;
      }
      // 让出一拍：先让正在进行的那次 promise 轮询结束，再进引擎
      await Future<void>.delayed(Duration.zero);
      if (_disposed) {
        return;
      }
      try {
        action();
      } on Object catch (error) {
        AppLog.warn('JS 回调失败', error: error);
      }
    });
  }
  void _track(Future<void> task) {
    _pending.add(task);
    // 收尾失败不该变成「未处理的异步错误」：真正的失败由调用方自己处理。
    task.whenComplete(() => _pending.remove(task)).catchError((Object _) {});
  }

  /// 等待所有桥接任务完成（最多等 [timeout]）。
  Future<void> flushPending({Duration timeout = const Duration(seconds: 2)}) async {
    while (_pending.isNotEmpty) {
      try {
        await Future.wait<void>(_pending.toList(growable: false)).timeout(timeout);
      } on Object {
        return;
      }
    }
  }

  /// 与洛雪宿主同一策略：音源接口常被按 SNI 阻断，检测到系统代理就走代理。
  static http.Client _clientWithProxy(String? proxy) {
    final client = HttpClient();
    if (proxy != null && proxy.isNotEmpty) {
      client.findProxy = (uri) => 'PROXY $proxy';
      AppLog.info('插件请求走系统代理 $proxy');
    }
    return IOClient(client);
  }

  static const String bundleAsset = 'assets/musicfree/runtime.bundle.js';

  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 OmiocLink/1.0';

  bool get isReady => _js != null;

  List<MusicFreePlugin> get plugins =>
      _entries.values.map((entry) => entry.plugin).toList(growable: false);

  MusicFreePlugin? byHash(String hash) => _entries[hash]?.plugin;

  Future<String> _bundle() async {
    final cached = _cachedBundle;
    if (cached != null) {
      return cached;
    }
    final injected = _injectedBundle;
    final text = injected ?? await rootBundle.loadString(bundleAsset);
    _cachedBundle = text;
    return text;
  }

  Future<void> _ensureBooted() async {
    if (_disposed) {
      throw const MusicFreeException('插件宿主已释放');
    }
    if (_js != null) {
      return;
    }
    await _paths.ensureReady();
    final js = getJavascriptRuntime(xhr: false);
    js.onMessage('mf.http', (dynamic args) {
      // 请求自己跑完就行，调用方不需要（也不应该）等它落盘。
      unawaited(_handleHttp(args));
      return null;
    });
    js.onMessage('mf.storage', (dynamic args) {
      _track(_handleStorage(args));
      return null;
    });
    js.onMessage('mf.cookie', (dynamic args) {
      _track(_handleCookie(args));
      return null;
    });
    js.onMessage('mf.log', (dynamic args) {
      _handleLog(args);
      return null;
    });
    js.onMessage('mf.timer', (dynamic args) {
      _handleTimer(js, args);
      return null;
    });
    js.onMessage('mf.clearTimer', (dynamic args) {
      _handleClearTimer(args);
      return null;
    });
    final loaded = js.evaluate(await _bundle());
    if (loaded.isError) {
      js.dispose();
      throw MusicFreeException('插件运行时加载失败：${loaded.stringResult}');
    }
    _js = js;
  }

  /// 把插件源码载入运行时，返回插件声明（platform / version / supportedMethod…）。
  Future<MusicFreePlugin> loadPlugin({
    required String hash,
    required String code,
    String srcUrl = '',
    Map<String, String> userVariables = const <String, String>{},
    String path = '',
  }) async {
    await _ensureBooted();
    final js = _js!;
    _entries.remove(hash)?.cancelTimers();

    final storage = await _readStorage(hash);
    final cookies = await _readCookies(hash);
    final options = jsonEncode(<String, dynamic>{
      'plugin': hash,
      'path': path,
      'srcUrl': srcUrl,
      'os': 'win32',
      'appVersion': appVersion,
      'lang': lang,
      'userVariables': userVariables,
    });

    final created = js.evaluate(
      'globalThis.__mfRequire = __mfRuntime.createRequire('
      '${jsonEncode(jsonEncode(<String, dynamic>{'plugin': hash, 'storage': storage, 'cookies': cookies}))});',
    );
    if (created.isError) {
      throw MusicFreeException('插件依赖初始化失败：${created.stringResult}');
    }

    final codeResult = js.evaluate('globalThis.__mfPluginCode = ${jsonEncode(code)}');
    if (codeResult.isError) {
      throw MusicFreeException('插件源码注入失败：${codeResult.stringResult}');
    }

    final loaded = js.evaluate(
      '__mfRuntime.loadPlugin(${jsonEncode(hash)}, globalThis.__mfPluginCode, ${jsonEncode(options)})',
    );
    if (loaded.isError) {
      _entries.remove(hash)?.cancelTimers();
      return MusicFreePlugin(
        hash: hash,
        platform: '未知插件',
        path: path,
        srcUrl: srcUrl,
        loadError: '插件执行出错：${_brief(loaded.stringResult)}',
      );
    }

    final described = js.evaluate('__mfRuntime.describe(${jsonEncode(hash)})');
    if (described.isError) {
      _entries.remove(hash)?.cancelTimers();
      return MusicFreePlugin(
        hash: hash,
        platform: '未知插件',
        path: path,
        srcUrl: srcUrl,
        loadError: '插件信息解析失败：${_brief(described.stringResult)}',
      );
    }
    Map<String, dynamic> meta = <String, dynamic>{};
    List<String> supportedMethods = <String>[];
    try {
      final decoded = jsonDecode(_jsString(described)) as Map<String, dynamic>;
      meta = (decoded['meta'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      supportedMethods = (decoded['supportedMethod'] as List? ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false);
    } on Object catch (error) {
      AppLog.warn('插件信息解析失败 ${_brief('$error')}');
    }

    final platform = meta['platform']?.toString() ?? '';
    final userVariableList = (meta['userVariables'] as List? ?? const <dynamic>[])
        .map(PluginUserVariable.tryParse)
        .whereType<PluginUserVariable>()
        .toList(growable: false);
    final declaredSrcUrl = meta['srcUrl']?.toString() ?? '';

    final plugin = MusicFreePlugin(
      hash: hash,
      platform: platform.isEmpty ? '未命名插件' : platform,
      path: path,
      version: meta['version']?.toString() ?? '',
      author: meta['author']?.toString() ?? '',
      description: meta['description']?.toString() ?? '',
      homepage: meta['homepage']?.toString() ?? '',
      srcUrl: declaredSrcUrl.isNotEmpty ? declaredSrcUrl : srcUrl,
      appVersion: meta['appVersion']?.toString() ?? '',
      supportedMethods: supportedMethods,
      userVariables: userVariableList,
      hints: (meta['hints'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
      primaryKey: (meta['primaryKey'] as List? ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
      defaultSearchType: meta['defaultSearchType']?.toString() ?? 'music',
      supportedSearchType: (meta['supportedSearchType'] as List? ?? const <dynamic>[])
          .map((item) => item.toString())
          .toList(growable: false),
      cacheControl: meta['cacheControl']?.toString() ?? 'cache',
      loadError: platform.isEmpty ? '插件没有声明 platform，无法使用' : null,
    );
    _entries[hash] = _LoadedEntry(plugin: plugin);
    return plugin;
  }

  /// 调用插件方法；插件抛错/超时都会转成 [MusicFreeException]，由上层决定怎么提示。
  ///
  /// [timeout] 是**整次调用**的截止时间：超过就立刻判失败，不让界面干等
  /// （MusicFree 是一个音源一个音源地显示，慢音源根本不影响别人；这里靠截止时间
  /// 达到同样的「不拖后腿」效果）。
  Future<dynamic> invoke(
    String hash,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 20),
    bool flushWrites = true,
  }) async {
    await _ensureBooted();
    final js = _js!;
    final entry = _entries[hash];
    if (entry == null) {
      throw const MusicFreeException('插件未加载');
    }
    final code =
        '__mfRuntime.invokeJson(${jsonEncode(hash)}, ${jsonEncode(method)}, ${jsonEncode(jsonEncode(args))})';
    // 整次调用共用一个预算：evaluateAsync 与 handlePromise 各套一次同长度超时，
    // 实际墙钟会变成 2×timeout，跟「2 秒判失败」的承诺对不上。
    final watch = Stopwatch()..start();
    Duration remaining() {
      final left = timeout - watch.elapsed;
      return left.isNegative ? Duration.zero : left;
    }

    final JsEvalResult raw;
    try {
      raw = await js.evaluateAsync(code).timeout(remaining());
    } on TimeoutException {
      throw MusicFreeException(_timeoutText(timeout));
    } on Object catch (error) {
      // 不是超时：把真实原因（引擎/源码错误）透出去，别一律报「超时」。
      throw MusicFreeException('插件调用失败：${_brief('$error')}');
    }
    if (raw.isError) {
      throw MusicFreeException('插件调用失败：${_brief(raw.stringResult)}');
    }
    final JsEvalResult value;
    try {
      value = await js.handlePromise(raw).timeout(remaining());
    } on TimeoutException catch (error) {
      AppLog.debug('插件调用超时 $method（${timeout.inMilliseconds}ms）：${_brief('$error')}');
      throw MusicFreeException(_timeoutText(timeout));
    }
    final text = _jsString(value);
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw MusicFreeException('插件返回的不是合法 JSON：${_brief(text)}');
    }
    // 只等本地写入（storage / cookie），不等网络：请求收尾跟这次调用无关。
    if (flushWrites) {
      await flushPending(timeout: const Duration(milliseconds: 400));
    }
    if (decoded is Map && decoded['ok'] == true) {
      return decoded['value'];
    }
    final message = decoded is Map ? (decoded['error']?.toString() ?? '插件调用失败') : '插件调用失败';
    throw MusicFreeException(_brief(message));
  }

  static String _timeoutText(Duration timeout) {
    final seconds = timeout.inMilliseconds / 1000;
    final label = seconds == seconds.roundToDouble()
        ? seconds.round().toString()
        : seconds.toStringAsFixed(1);
    return '超时（$label 秒未返回）';
  }

  void unload(String hash) {
    final entry = _entries.remove(hash);
    entry?.cancelTimers();
    final js = _js;
    if (js != null && !_disposed) {
      try {
        js.evaluate('__mfRuntime.unloadPlugin(${jsonEncode(hash)})');
      } on Object catch (error) {
        AppLog.debug('卸载插件实例失败：$error');
      }
    }
  }

  void dispose() {
    _disposed = true;
    for (final entry in _entries.values) {
      entry.cancelTimers();
    }
    _entries.clear();
    _js?.dispose();
    _js = null;
  }

  // ------------------------------------------------------------------ 桥接
  static Map<String, dynamic> _asMap(dynamic raw) {
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry(key.toString(), value));
        }
      } on FormatException {
        return <String, dynamic>{};
      }
    }
    return <String, dynamic>{};
  }

  void _handleLog(dynamic args) {
    final map = _asMap(args);
    final plugin = map['plugin']?.toString() ?? '';
    final level = map['level']?.toString() ?? 'log';
    final message = map['message']?.toString() ?? '';
    if (level == 'error' || level == 'warn') {
      AppLog.warn('插件[$plugin] $message');
    } else {
      AppLog.debug('插件[$plugin] $message');
    }
  }

  Future<void> _handleStorage(dynamic args) async {
    final map = _asMap(args);
    final hash = map['plugin']?.toString() ?? '';
    final action = map['action']?.toString() ?? '';
    final key = map['key']?.toString() ?? '';
    if (hash.isEmpty || key.isEmpty) {
      return;
    }
    try {
      final current = await _readStorage(hash);
      if (action == 'set') {
        current[key] = map['value']?.toString() ?? '';
      } else if (action == 'delete') {
        current.remove(key);
      } else {
        return;
      }
      await _writeJson(_paths.storageFile(hash), current);
    } on Object catch (error) {
      AppLog.warn('插件 storage 落盘失败', error: error);
    }
  }

  Future<void> _handleCookie(dynamic args) async {
    final map = _asMap(args);
    final hash = map['plugin']?.toString() ?? '';
    final cookies = map['cookies'];
    if (hash.isEmpty || cookies is! List) {
      return;
    }
    try {
      await _writeJson(_paths.cookieFile(hash), cookies);
    } on Object catch (error) {
      AppLog.warn('插件 cookie 落盘失败', error: error);
    }
  }

  void _handleTimer(JavascriptRuntime js, dynamic args) {
    final map = _asMap(args);
    final id = (map['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) {
      return;
    }
    final delay = Duration(
      milliseconds: ((map['delay'] as num?)?.toInt() ?? 0).clamp(0, 600000),
    );
    final repeat = map['repeat'] == true;
    final entry = _entries.isEmpty ? null : _entries.values.first;
    entry?.timers.remove('$id')?.cancel();
    if (repeat) {
      entry?.timers['$id'] = Timer.periodic(
        delay == Duration.zero ? const Duration(milliseconds: 1) : delay,
        (_) => _fireTimer(js, id),
      );
    } else {
      entry?.timers['$id'] = Timer(delay, () {
        entry.timers.remove('$id');
        _fireTimer(js, id);
      });
    }
  }

  void _handleClearTimer(dynamic args) {
    final map = _asMap(args);
    final id = (map['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) {
      return;
    }
    for (final entry in _entries.values) {
      entry.timers.remove('$id')?.cancel();
    }
  }

  void _fireTimer(JavascriptRuntime js, int id) {
    _enqueueJs(() {
      if (_disposed || _js == null) {
        return;
      }
      js.evaluate('globalThis.__mfRunTimer($id)');
    });
  }

  Future<void> _handleHttp(dynamic args) async {
    final map = _asMap(args);
    final ticket = map['ticket']?.toString() ?? '';
    if (ticket.isEmpty) {
      return;
    }
    await _acquireRequestSlot();
    var released = false;
    void release() {
      if (released) {
        return;
      }
      released = true;
      _releaseRequestSlot();
    }

    // 兜底：万一有请求彻底卡死（连接挂在那里不返回），别让它永久占着名额。
    // 正常请求都在插件自己声明的超时内结束（见 [_performRequest] 的 15 秒默认值），
    // 名额随之自然回收；这里的 20 秒只是「避免名额永久丢失」的保险丝，不是常规提前放行。
    // 请求本身继续跑（能回来还能用），只是不再挡别人。
    final guard = Timer(_maxSlotHold, release);
    try {
      final response = await _performRequest(map);
      _deliverHttp(ticket, null, response);
    } on Object catch (error) {
      final host = Uri.tryParse(map['url'].toString())?.host;
      AppLog.warn('插件请求失败 ${host ?? ''}', error: error);
      _deliverHttp(
        ticket,
        host == null || host.isEmpty ? '$error' : '$error（连接 $host 失败）',
        null,
      );
    } finally {
      guard.cancel();
      release();
    }
  }

  /// 单个请求最多占多久的并发名额。
  static const Duration _maxSlotHold = Duration(seconds: 20);

  /// 同时在途的插件请求上限。
  ///
  /// 聚合类插件一次搜索会并发十几个请求；QuickJS 那边同时挂太多 promise
  /// 会把桥接栈撑爆（native `0xc00000fd`，进程直接消失），所以必须限流。
  /// 4 太紧：几十个音源一起搜时请求要排队，2 秒的截止时间里排不到就白等了，
  /// 8 是实测能留下结果又不至于把桥压塌的折中值（回投本身还有 [_enqueueJs] 串行）。
  static const int _maxConcurrentRequests = 8;
  int _activeRequests = 0;
  final List<void Function()> _requestWaiters = <void Function()>[];

  Future<void> _acquireRequestSlot() async {
    if (_activeRequests < _maxConcurrentRequests) {
      _activeRequests += 1;
      return;
    }
    final completer = Completer<void>();
    _requestWaiters.add(() {
      _activeRequests += 1;
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
    await completer.future;
  }

  void _releaseRequestSlot() {
    _activeRequests -= 1;
    if (_requestWaiters.isNotEmpty) {
      _requestWaiters.removeAt(0)();
    }
  }

  void _deliverHttp(String ticket, String? error, Map<String, dynamic>? payload) {
    // 一次聚合搜索会并发十几个请求，响应几乎同时回来；逐个回投，
    // 避免在多份 promise 同时轮询时把多次 evaluate 交叠（QuickJS 桥会栈溢出崩溃）。
    _enqueueJs(() {
      final js = _js;
      if (js == null || _disposed) {
        return;
      }
      final errorLiteral = error == null ? 'null' : jsonEncode(error);
      final payloadLiteral = payload == null
          ? 'null'
          : jsonEncode(jsonEncode(payload));
      final result = js.evaluate(
        '__mfHttpDone(${jsonEncode(ticket)}, $errorLiteral, $payloadLiteral)',
      );
      if (result.isError) {
        AppLog.warn('插件 HTTP 回调抛错', error: result.stringResult);
      }
    });
  }

  Future<Map<String, dynamic>> _performRequest(Map<String, dynamic> payload) async {
    final url = payload['url']?.toString() ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw const MusicFreeException('请求地址无效');
    }
    final method = (payload['method']?.toString() ?? 'GET').toUpperCase();
    final headers = <String, String>{};
    final rawHeaders = payload['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (value != null) {
          headers[key.toString()] = value.toString();
        }
      });
    }
    headers.putIfAbsent('User-Agent', () => _defaultUserAgent);
    final timeout = Duration(
      milliseconds: ((payload['timeout'] as num?)?.toInt() ?? 15000).clamp(1000, 30000),
    );
    final request = http.Request(method, uri);
    request.headers.addAll(headers);
    final bodyBase64 = payload['bodyBase64']?.toString();
    final body = payload['body']?.toString();
    if (bodyBase64 != null && bodyBase64.isNotEmpty) {
      request.bodyBytes = base64Decode(bodyBase64);
    } else if (body != null && method != 'GET' && method != 'HEAD') {
      request.body = body;
    }
    final streamed = await _http.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed).timeout(timeout);
    if (response.statusCode >= 400) {
      // 插件只会报「Request failed with status code 400」，看不出是哪个请求挂的；
      // 这里把状态码、方法与地址记下来（地址截断，避免把 token 全写进日志）。
      final shortUrl = url.length <= 200 ? url : '${url.substring(0, 200)}…';
      AppLog.warn('插件请求 ${response.statusCode} $method $shortUrl');
      AppLog.debug(
        '插件请求头：${headers.entries.map((entry) => '${entry.key}=${entry.value}').join('; ')}',
      );
    }
    final responseHeaders = <String, String>{};
    response.headers.forEach((key, value) {
      responseHeaders[key] = value;
    });
    final wantsBinary = payload['responseType']?.toString() == 'arraybuffer';
    return <String, dynamic>{
      'status': response.statusCode,
      'statusText': response.reasonPhrase ?? '',
      'headers': responseHeaders,
      if (!wantsBinary) 'body': utf8.decode(response.bodyBytes, allowMalformed: true),
      if (wantsBinary) 'bodyBase64': base64Encode(response.bodyBytes),
    };
  }

  // ------------------------------------------------------------- 本地文件
  Future<Map<String, String>> _readStorage(String hash) async {
    final file = File(_paths.storageFile(hash));
    if (!file.existsSync()) {
      return <String, String>{};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value?.toString() ?? ''));
      }
    } on Object catch (error) {
      AppLog.warn('读取插件 storage 失败', error: error);
    }
    return <String, String>{};
  }

  Future<List<dynamic>> _readCookies(String hash) async {
    final file = File(_paths.cookieFile(hash));
    if (!file.existsSync()) {
      return <dynamic>[];
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        return decoded;
      }
    } on Object catch (error) {
      AppLog.warn('读取插件 cookie 失败', error: error);
    }
    return <dynamic>[];
  }

  Future<void> _writeJson(String path, Object? value) async {
    final file = File(path);
    final dir = file.parent;
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    await file.writeAsString(jsonEncode(value));
  }

  static String _jsString(JsEvalResult result) {
    final text = result.stringResult;
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is String) {
          return decoded;
        }
      } on FormatException {
        return text;
      }
    }
    return text;
  }

  static String _brief(String text) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= 200) {
      return oneLine;
    }
    return '${oneLine.substring(0, 200)}…';
  }
}