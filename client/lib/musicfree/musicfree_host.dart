import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

import '../core/app_log.dart';
import '../core/app_version.dart';
import '../core/platform.dart';
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
class MusicFreeEngine {
  MusicFreeEngine({
    http.Client? httpClient,
    PluginPaths? paths,
    String? bundleSource,
    this.appVersion = kAppVersion,
    this.lang = 'zh-CN',
    this.httpProxy,
    this.logSink,
  }) : _http = httpClient ?? _pluginClient(),
       _paths = paths ?? PluginPaths(),
       _injectedBundle = bundleSource;

  final http.Client _http;
  final PluginPaths _paths;
  final String appVersion;
  final String lang;

  final String? _injectedBundle;

  /// 把 HTTP 请求交回主 isolate 发出（worker 里没有可注入的 client）。
  final Future<http.Response> Function(http.Request, Duration)? httpProxy;

  /// 插件 console 日志的出口（worker 里 AppLog 落不到文件，只能回传主 isolate）。
  final void Function(String level, String message)? logSink;
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

  /// 插件请求的 HTTP 客户端。
  ///
  /// 这里**不设** `findProxy`：Dart 的 HttpClient 默认直连，代理交给用户的
  /// TUN/虚拟网卡在系统层接管（客户端不再自己探测系统代理）。
  static http.Client _pluginClient() => IOClient(HttpClient());

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
    final boot = Stopwatch()..start();
    final js = getJavascriptRuntime(xhr: false);
    AppLog.timing('插件.JS 运行时创建', boot.elapsed);
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
    final bundleWatch = Stopwatch()..start();
    final source = await _bundle();
    AppLog.timing('插件.bundle 读取', bundleWatch.elapsed);
    final created = Stopwatch()..start();
    final loaded = js.evaluate(source);
    // 这是每次进程启动最贵的一步（压缩后仍有 577KB JS 要编译），必须能看到数字
    AppLog.timing('插件.bundle 编译执行', created.elapsed);
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
    final options = <String, dynamic>{
      'plugin': hash,
      'path': path,
      'srcUrl': srcUrl,
      'os': 'win32',
      'appVersion': appVersion,
      'lang': lang,
      'userVariables': userVariables,
    };

    // 源码只转义一次：以前是 `jsonEncode(整个 payload)` 再塞进 evaluate，
    // JS 侧还要 JSON.parse 一遍 —— 同一份插件源码被解析三次、字面量体积接近翻倍。
    // 插件越大这笔越贵（实测大插件 5~25s），所以这里把 code 单独当参数传。
    final storageJson = jsonEncode(storage);
    final cookiesJson = jsonEncode(cookies);
    final optionsJson = jsonEncode(options);
    final installed = js.evaluate(
      '__mfRuntime.install(${jsonEncode(hash)}, ${jsonEncode(code)}, '
      '${jsonEncode(optionsJson)}, ${jsonEncode(storageJson)}, '
      '${jsonEncode(cookiesJson)})',
    );
    if (installed.isError) {
      _entries.remove(hash)?.cancelTimers();
      return MusicFreePlugin(
        hash: hash,
        platform: '未知插件',
        path: path,
        srcUrl: srcUrl,
        loadError: _brief(installed.stringResult),
      );
    }

    Map<String, dynamic> meta = <String, dynamic>{};
    List<String> supportedMethods = <String>[];
    try {
      final decoded = jsonDecode(_jsString(installed)) as Map<String, dynamic>;
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
    final text = '插件[$plugin] $message';
    final isWarn = level == 'error' || level == 'warn';
    final sink = logSink;
    if (sink != null) {
      // worker 里 AppLog 落不到文件：转发回主 isolate 再落盘
      sink(isWarn ? 'WARN' : 'DEBUG', text);
    } else if (isWarn) {
      AppLog.warn(text);
    } else {
      AppLog.debug(text);
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
    // HTTP 出口：worker isolate 里没有主 isolate 的 client（而且测试要注入
    // MockClient 观察派发出去的 URL），所以那边通过 [httpProxy] 把请求发回
    // 主 isolate，由同一个 client 真正发出去。
    final proxy = httpProxy;
    final http.Response response;
    if (proxy != null) {
      response = await proxy(request, timeout);
    } else {
      final streamed = await _http.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    }
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

// ---------------------------------------------------------------------------
// 主 isolate 侧的门面：JS 引擎整体跑在 worker isolate
// ---------------------------------------------------------------------------

/// `MusicFreeHost` 的公开门面：**JS 引擎与插件代码都在 worker isolate 里跑**。
///
/// 为什么要有这一层：`quickjs_engine` 的 `evaluate` 是**同步 FFI**，编译 577KB
/// 的运行时 bundle 和每份插件源码都发生在调用线程上。以前它在主 isolate，打开
/// 设置页 / 首次打开点歌台就会把整窗冻住几秒（用户看到的是「卡死」）。搬到
/// worker 之后主 isolate 只收发 JSON，界面不再被 JS 编译打断。
///
/// HTTP 仍由主 isolate 发出：插件请求要能被注入的 client（测试里的 MockClient）
/// 观察，而 client 无法跨 isolate，所以 worker 反过来请主 isolate 代发。
class MusicFreeHost {
  MusicFreeHost({
    http.Client? httpClient,
    PluginPaths? paths,
    String? bundleSource,
    this.appVersion = kAppVersion,
    this.lang = 'zh-CN',
    int? poolSize,
  }) : _http = httpClient ?? MusicFreeEngine._pluginClient(),
       _paths = paths ?? PluginPaths(),
       _injectedBundle = bundleSource,
       _poolSize = poolSize ?? _defaultPoolSize();

  /// 运行时 bundle 的资产路径（构建期产物，见 tool/build_musicfree_runtime.mjs）。
  static const String bundleAsset = MusicFreeEngine.bundleAsset;

  /// 默认并行度。
  ///
  /// QuickJS 是单线程，想并行编译只能多开运行时；但每份运行时都要自己编译一遍
  /// 577KB 的 bundle，内存与启动成本都乘上这个数。手机内存远比桌面紧，低端机
  /// 上 3 份运行时很容易被系统直接杀掉，所以移动端固定 2；桌面上核多的给 3。
  static int _defaultPoolSize() {
    if (isMobilePlatform) {
      return 2;
    }
    return Platform.numberOfProcessors >= 8 ? 3 : 2;
  }

  final http.Client _http;
  final PluginPaths _paths;
  final String? _injectedBundle;
  final String appVersion;
  final String lang;
  final int _poolSize;

  final List<_WorkerLink> _links = <_WorkerLink>[];
  final Map<int, _PendingCall> _pending = <int, _PendingCall>{};

  /// hash → 跑着它的 worker；值为 null 表示「已登记元数据、还没编译」。
  final Map<String, _WorkerLink?> _owner = <String, _WorkerLink?>{};
  final Map<String, MusicFreePlugin> _plugins = <String, MusicFreePlugin>{};

  /// 同一个插件被并发调用时只编译一次。
  final Map<String, Future<void>> _compiling = <String, Future<void>>{};
  final Map<String, dynamic> _metadata = <String, dynamic>{};

  bool _metadataLoaded = false;
  bool _disposed = false;
  int _nextId = 1;

  MusicFreePlugin? byHash(String hash) => _plugins[hash];

  List<MusicFreePlugin> get plugins => _plugins.values.toList(growable: false);

  bool get isReady => _links.any((link) => link.isReady);

  /// 只登记元数据、不编译：启动时用它把插件列表立刻铺出来。
  void registerMetadata(MusicFreePlugin plugin) =>
      _plugins[plugin.hash] = plugin;

  /// 把上次落盘的 `describe` 结果登记成「已登记未编译」；源码文件还在才算。
  Future<int> restoreMetadata() async {
    await _loadMetadata();
    var restored = 0;
    for (final entry in _metadata.entries) {
      if (_plugins.containsKey(entry.key)) {
        continue;
      }
      final raw = entry.value;
      if (raw is! Map) {
        continue;
      }
      final path = _paths.pluginFile(entry.key);
      if (!File(path).existsSync()) {
        continue;
      }
      final map = raw.cast<String, dynamic>();
      _plugins[entry.key] = MusicFreePlugin.fromJson(
        map,
        hash: entry.key,
        path: path,
        srcUrl: map['srcUrl']?.toString() ?? '',
      );
      restored += 1;
    }
    return restored;
  }

  /// 卸载时抹掉元数据，免得下次启动又「复活」一个已经不存在的插件。
  Future<void> forgetMetadata(String hash) async {
    _plugins.remove(hash);
    _owner.remove(hash);
    if (_metadata.remove(hash) == null) {
      return;
    }
    await _saveMetadata();
  }

  /// 后台把「登记了但还没编译」的插件逐个编译好。
  ///
  /// 一次只编译一个：并发只会让 worker 排队，还会拖慢用户真正在点的操作。
  Future<void> prefetch() async {
    for (final hash in _plugins.keys.toList(growable: false)) {
      if (_disposed) {
        return;
      }
      if (_owner[hash] != null) {
        continue;
      }
      try {
        await _ensureCompiled(hash);
      } on Object catch (error) {
        AppLog.debug('后台编译插件失败（$hash）：$error');
      }
    }
  }

  Future<MusicFreePlugin> loadPlugin({
    required String hash,
    required String code,
    String srcUrl = '',
    Map<String, String> userVariables = const <String, String>{},
    String path = '',
  }) async {
    final link = await _pickLink();
    final reply = await _call(link, <String, dynamic>{
      'op': 'load',
      'hash': hash,
      'code': code,
      'srcUrl': srcUrl,
      'userVariables': userVariables,
      'path': path,
    }, timeout: const Duration(seconds: 120));
    final plugin = MusicFreePlugin.fromJson(
      (reply['plugin'] as Map).cast<String, dynamic>(),
      hash: hash,
      path: path,
      srcUrl: srcUrl,
    );
    _plugins[hash] = plugin;
    _owner[hash] = link;
    link.hashes.add(hash);
    await _rememberMetadata(plugin);
    return plugin;
  }

  Future<dynamic> invoke(
    String hash,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 20),
    bool flushWrites = true,
  }) async {
    // 元数据复用之后，插件可能只是「登记过」还没编译：这里补上
    await _ensureCompiled(hash);
    final link = _owner[hash];
    if (link == null) {
      throw const MusicFreeException('插件还没有装载完成');
    }
    final reply = await _call(link, <String, dynamic>{
      'op': 'invoke',
      'hash': hash,
      'method': method,
      'args': args,
      'timeoutMs': timeout.inMilliseconds,
      'flushWrites': flushWrites,
    }, timeout: timeout + const Duration(seconds: 5));
    return reply['value'];
  }

  void unload(String hash) {
    final link = _owner.remove(hash);
    _plugins.remove(hash);
    link?.hashes.remove(hash);
    link?.to?.send(<String, dynamic>{'id': 0, 'op': 'unload', 'hash': hash});
  }

  Future<void> flushPending({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final ready = _links.where((link) => link.isReady).toList(growable: false);
    if (ready.isEmpty) {
      return;
    }
    await Future.wait<void>(<Future<void>>[
      for (final link in ready)
        _call(link, <String, dynamic>{
          'op': 'flush',
          'timeoutMs': timeout.inMilliseconds,
        }, timeout: timeout + const Duration(seconds: 2)).then<void>(
          (_) {},
          onError: (Object _) {},
        ),
    ]);
  }

  void dispose() {
    _disposed = true;
    for (final link in _links) {
      link.to?.send(<String, dynamic>{'id': 0, 'op': 'dispose'});
      link.from?.close();
      link.isolate?.kill(priority: Isolate.immediate);
    }
    _links.clear();
    _owner.clear();
    _plugins.clear();
    for (final call in _pending.values) {
      if (!call.completer.isCompleted) {
        call.completer.completeError(const MusicFreeException('插件宿主已释放'));
      }
    }
    _pending.clear();
  }

  // ------------------------------------------------------------------ 内部

  /// 第一次调用某个音源时才读盘 + 编译（元数据复用的关键一步）。
  Future<void> _ensureCompiled(String hash) {
    if (_owner[hash] != null) {
      return Future<void>.value();
    }
    final inflight = _compiling[hash];
    if (inflight != null) {
      return inflight;
    }
    final future = _compileFromDisk(hash);
    _compiling[hash] = future.whenComplete(() => _compiling.remove(hash));
    return _compiling[hash]!;
  }

  Future<void> _compileFromDisk(String hash) async {
    final path = _paths.pluginFile(hash);
    final file = File(path);
    if (!file.existsSync()) {
      throw MusicFreeException('插件源码不存在（$hash），请重新拉取订阅');
    }
    final code = await file.readAsString();
    final watch = Stopwatch()..start();
    final plugin = await loadPlugin(hash: hash, code: code, path: path);
    AppLog.timing('插件.按需编译 ${plugin.platform}', watch.elapsed);
  }

  Future<void> _rememberMetadata(MusicFreePlugin plugin) async {
    await _loadMetadata();
    _metadata[plugin.hash] = plugin.toJson();
    await _saveMetadata();
  }

  Future<void> _loadMetadata() async {
    if (_metadataLoaded) {
      return;
    }
    _metadataLoaded = true;
    final file = File(_paths.metadataFile);
    if (!file.existsSync()) {
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        _metadata.addAll(decoded.cast<String, dynamic>());
      }
    } on Object catch (error) {
      AppLog.warn('读取插件元数据缓存失败', error: error);
    }
  }

  Future<void> _saveMetadata() async {
    try {
      final file = File(_paths.metadataFile);
      final dir = file.parent;
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
      }
      await file.writeAsString(jsonEncode(_metadata));
    } on Object catch (error) {
      AppLog.debug('写插件元数据缓存失败：$error');
    }
  }

  /// 挑一个 worker：优先空闲的；不够就按需扩充，最多 [_poolSize] 个。
  Future<_WorkerLink> _pickLink() async {
    for (final link in _links) {
      if (link.isReady && link.inFlight == 0) {
        return link;
      }
    }
    if (_links.length < _poolSize) {
      final link = _WorkerLink(_links.length);
      _links.add(link);
      await _start(link);
      return link;
    }
    final ready = _links.where((link) => link.isReady).toList(growable: false);
    if (ready.isEmpty) {
      await _start(_links.first);
      return _links.first;
    }
    ready.sort((a, b) => a.inFlight.compareTo(b.inFlight));
    return ready.first;
  }

  Future<void> _start(_WorkerLink link) async {
    if (link.isReady) {
      return;
    }
    final starting = link.starting;
    if (starting != null) {
      await starting.future;
      return;
    }
    final completer = Completer<void>();
    link.starting = completer;
    final watch = Stopwatch()..start();
    try {
      // bundle 在 spawn 前读好：worker 里没有 rootBundle / AppPaths
      final source = _injectedBundle ?? await rootBundle.loadString(bundleAsset);
      final from = ReceivePort();
      link.from = from;
      from.listen(
        (dynamic message) => _onMessage(link, message),
        onDone: () => _onWorkerGone(link),
      );
      link.isolate = await Isolate.spawn(
        musicFreeWorkerMain,
        <Object?>[
          from.sendPort,
          <String, dynamic>{
            'bundle': source,
            'root': _paths.root,
            'appVersion': appVersion,
            'lang': lang,
          },
        ],
        debugName: 'musicfree-worker-${link.index}',
      );
      await completer.future;
      AppLog.timing('插件.worker#${link.index} 就绪（含 bundle 编译）', watch.elapsed);
    } on Object {
      link.starting = null;
      rethrow;
    }
  }

  void _onMessage(_WorkerLink link, dynamic message) {
    if (message is SendPort) {
      link.to = message;
      final starting = link.starting;
      link.starting = null;
      if (starting != null && !starting.isCompleted) {
        starting.complete();
      }
      return;
    }
    if (message is! Map) {
      return;
    }
    final map = message.cast<String, dynamic>();
    final logLevel = map['log'];
    if (logLevel is String) {
      final text = '${map['message'] ?? ''}';
      if (logLevel == 'WARN') {
        AppLog.warn(text);
      } else {
        AppLog.debug(text);
      }
      return;
    }
    if (map['http'] == true) {
      unawaited(_serveHttp(map));
      return;
    }
    final id = map['id'];
    if (id is! int) {
      return;
    }
    final call = _pending.remove(id);
    if (call == null || call.completer.isCompleted) {
      return;
    }
    call.link.inFlight -= 1;
    if (map['ok'] == true) {
      call.completer.complete(map);
    } else {
      call.completer.completeError(
        MusicFreeException(map['error']?.toString() ?? '插件调用失败'),
      );
    }
  }

  /// worker 挂了：把它的插件标成「未编译」，下次调用会从磁盘重新装。
  void _onWorkerGone(_WorkerLink link) {
    link.to = null;
    final starting = link.starting;
    link.starting = null;
    if (starting != null && !starting.isCompleted) {
      starting.completeError(const MusicFreeException('插件 worker 启动失败'));
    }
    for (final hash in link.hashes.toList(growable: false)) {
      if (identical(_owner[hash], link)) {
        _owner[hash] = null;
      }
    }
    link.hashes.clear();
  }

  /// 发一条请求并等 JSON 回复；worker 死亡/超时都抛 [MusicFreeException]。
  Future<Map<String, dynamic>> _call(
    _WorkerLink link,
    Map<String, dynamic> request, {
    required Duration timeout,
  }) async {
    if (_disposed) {
      throw const MusicFreeException('插件宿主已释放');
    }
    if (!link.isReady) {
      await _start(link);
    }
    final id = _nextId;
    _nextId += 1;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = _PendingCall(link, completer);
    link.inFlight += 1;
    link.to!.send(<String, dynamic>{'id': id, ...request});
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      link.inFlight -= 1;
      throw const MusicFreeException('插件宿主没有响应（worker 超时）');
    }
  }

  /// 替 worker 发一次插件请求（注入的 client 仍然有效）。
  Future<void> _serveHttp(Map<String, dynamic> map) async {
    final port = map['port'];
    if (port is! SendPort) {
      return;
    }
    try {
      final request = http.Request(
        map['method']?.toString() ?? 'GET',
        Uri.parse(map['url'].toString()),
      );
      final rawHeaders = map['headers'];
      if (rawHeaders is Map) {
        rawHeaders.forEach((key, value) {
          request.headers[key.toString()] = '$value';
        });
      }
      final bodyBase64 = map['bodyBase64']?.toString();
      if (bodyBase64 != null && bodyBase64.isNotEmpty) {
        request.bodyBytes = base64Decode(bodyBase64);
      }
      final timeout = Duration(
        milliseconds: (map['timeout'] as num?)?.toInt() ?? 15000,
      );
      final streamed = await _http.send(request).timeout(timeout);
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(timeout);
      final headers = <String, String>{};
      response.headers.forEach((key, value) => headers[key] = value);
      port.send(<String, dynamic>{
        'status': response.statusCode,
        'reason': response.reasonPhrase ?? '',
        'headers': headers,
        'bodyBase64': base64Encode(response.bodyBytes),
      });
    } on Object catch (error) {
      port.send(<String, dynamic>{'error': '$error'});
    }
  }
}

/// 一条 worker 连接（池子里的一格）。
class _WorkerLink {
  _WorkerLink(this.index);

  final int index;
  Isolate? isolate;
  ReceivePort? from;
  SendPort? to;
  Completer<void>? starting;

  /// 正在跑的请求数：挑 worker 时按它做负载均衡。
  int inFlight = 0;
  final Set<String> hashes = <String>{};

  bool get isReady => to != null;
}

/// 一次还没回来的 RPC。
class _PendingCall {
  _PendingCall(this.link, this.completer);

  final _WorkerLink link;
  final Completer<Map<String, dynamic>> completer;
}

/// worker isolate 入口：托管整份 [MusicFreeEngine]（JS 运行时 + 桥 + 插件实例）。
///
/// 这里碰不到 UI：没有 rootBundle、没有 AppPaths，所以 bundle 源码、数据目录、
/// 版本号都由主 isolate 在 spawn 时传进来；日志与 HTTP 都通过端口回主 isolate。
void musicFreeWorkerMain(List<Object?> args) {
  // 插件代码里什么都能发生：未捕获的异步异常以前会直接把 worker 弄死，
  // 界面表现就是「插件突然全没了，然后从头再装一遍」。用 zone 拦住它，
  // 只记一条日志继续服务（原生栈溢出 `0xc00000fd` 这一层拦不住，另说）。
  runZonedGuarded(
    () => _musicFreeWorkerBody(args),
    (error, stack) {
      final toMain = args.isNotEmpty ? args[0] : null;
      if (toMain is SendPort) {
        toMain.send(<String, dynamic>{
          'log': 'WARN',
          'message': '插件 worker 未捕获异常（已忽略，继续服务）：$error',
        });
      }
    },
  );
}

/// worker 的真实主体（被 [musicFreeWorkerMain] 的 zone 包住）。
void _musicFreeWorkerBody(List<Object?> args) {
  final toMain = args[0] as SendPort;
  final config = (args[1] as Map).cast<String, dynamic>();
  final engine = MusicFreeEngine(
    paths: PluginPaths(root: config['root']?.toString() ?? ''),
    bundleSource: config['bundle']?.toString() ?? '',
    appVersion: config['appVersion']?.toString() ?? kAppVersion,
    lang: config['lang']?.toString() ?? 'zh-CN',
    logSink: (level, message) =>
        toMain.send(<String, dynamic>{'log': level, 'message': message}),
    httpProxy: (request, timeout) => _workerHttp(toMain, request, timeout),
  );
  final requests = ReceivePort();
  toMain.send(requests.sendPort);
  requests.listen((message) async {
    if (message is! Map) {
      return;
    }
    final map = message.cast<String, dynamic>();
    final id = map['id'];
    if (id is! int || id == 0) {
      // id=0 是不需要回复的收尾指令
      if (map['op'] == 'unload') {
        engine.unload('${map['hash'] ?? ''}');
      } else if (map['op'] == 'dispose') {
        engine.dispose();
      }
      return;
    }
    try {
      switch (map['op']) {
        case 'load':
          final plugin = await engine.loadPlugin(
            hash: '${map['hash']}',
            code: '${map['code']}',
            srcUrl: map['srcUrl']?.toString() ?? '',
            userVariables:
                (map['userVariables'] as Map?)?.map(
                  (key, value) => MapEntry('$key', '$value'),
                ) ??
                const <String, String>{},
            path: map['path']?.toString() ?? '',
          );
          toMain.send(<String, dynamic>{
            'id': id,
            'ok': true,
            'plugin': plugin.toJson(),
          });
        case 'invoke':
          final value = await engine.invoke(
            '${map['hash']}',
            '${map['method']}',
            (map['args'] as List?)?.cast<Object?>() ?? const <Object?>[],
            timeout: Duration(
              milliseconds: (map['timeoutMs'] as num?)?.toInt() ?? 20000,
            ),
            flushWrites: map['flushWrites'] != false,
          );
          toMain.send(<String, dynamic>{'id': id, 'ok': true, 'value': value});
        case 'flush':
          await engine.flushPending(
            timeout: Duration(
              milliseconds: (map['timeoutMs'] as num?)?.toInt() ?? 2000,
            ),
          );
          toMain.send(<String, dynamic>{'id': id, 'ok': true});
        case 'unload':
          engine.unload('${map['hash']}');
          toMain.send(<String, dynamic>{'id': id, 'ok': true});
        case 'dispose':
          engine.dispose();
          toMain.send(<String, dynamic>{'id': id, 'ok': true});
        default:
          toMain.send(<String, dynamic>{
            'id': id,
            'ok': false,
            'error': '未知操作 ${map['op']}',
          });
      }
    } on Object catch (error) {
      toMain.send(<String, dynamic>{
        'id': id,
        'ok': false,
        'error': error is MusicFreeException ? error.message : '$error',
      });
    }
  });
}

/// worker → 主 isolate 的 HTTP 代发（请求体/响应体都用 base64，二进制也安全）。
Future<http.Response> _workerHttp(
  SendPort toMain,
  http.Request request,
  Duration timeout,
) async {
  final reply = ReceivePort();
  toMain.send(<String, dynamic>{
    'http': true,
    'port': reply.sendPort,
    'method': request.method,
    'url': request.url.toString(),
    'headers': request.headers,
    'bodyBase64': base64Encode(request.bodyBytes),
    'timeout': timeout.inMilliseconds,
  });
  final raw = await reply.first.timeout(
    timeout + const Duration(seconds: 5),
  );
  reply.close();
  final map = (raw as Map).cast<String, dynamic>();
  final error = map['error'];
  if (error != null) {
    throw MusicFreeException('插件请求失败：$error');
  }
  final headers = <String, String>{};
  final rawHeaders = map['headers'];
  if (rawHeaders is Map) {
    rawHeaders.forEach((key, value) => headers['$key'] = '$value');
  }
  return http.Response.bytes(
    base64Decode('${map['bodyBase64']}'),
    (map['status'] as num?)?.toInt() ?? 0,
    headers: headers,
    reasonPhrase: map['reason']?.toString(),
  );
}