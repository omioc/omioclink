import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../core/app_log.dart';
import 'musicfree_host.dart';
import 'plugin_models.dart';
import 'plugin_paths.dart';
import 'musicfree_bytecode.dart';

/// 一次订阅同步的结果。
class SubscriptionSyncResult {
  const SubscriptionSyncResult({
    required this.urls,
    required this.signature,
    required this.reinstalled,
    required this.failures,
  });

  final List<String> urls;
  final String signature;

  /// 是否发生了「清空本地插件 + 全量重装」。
  final bool reinstalled;
  final List<String> failures;

  bool get hasFailures => failures.isNotEmpty;
}

class _SubscriptionState {
  const _SubscriptionState({
    this.urls = const <String>[],
    this.signature = '',
    this.owned = const <String, List<String>>{},
  });

  final List<String> urls;
  final String signature;

  /// 订阅地址 → 它装出来的插件 hash。
  ///
  /// 差集安装要能回答「这条订阅被删掉了，它带来的插件是谁」：插件自己的
  /// `srcUrl` 是单个插件地址（订阅是 .json 时更是对不上），只能由我们记录归属。
  final Map<String, List<String>> owned;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'urls': urls,
    'signature': signature,
    'owned': owned,
  };
}

class _Preferences {
  _Preferences({
    Map<String, int>? orders,
    Set<String>? disabled,
    Map<String, Map<String, String>>? userVariables,
  }) : orders = orders ?? <String, int>{},
       disabled = disabled ?? <String>{},
       userVariables = userVariables ?? <String, Map<String, String>>{};

  final Map<String, int> orders;
  final Set<String> disabled;
  final Map<String, Map<String, String>> userVariables;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'orders': orders,
    'disabled': disabled.toList(growable: false),
    'userVariables': userVariables,
  };

  static _Preferences fromJson(Map<String, dynamic> json) {
    final orders = <String, int>{};
    final rawOrders = json['orders'];
    if (rawOrders is Map) {
      rawOrders.forEach((key, value) {
        if (value is num) {
          orders[key.toString()] = value.toInt();
        }
      });
    }
    final disabled = <String>{};
    final rawDisabled = json['disabled'];
    if (rawDisabled is List) {
      for (final item in rawDisabled) {
        disabled.add(item.toString());
      }
    }
    final userVariables = <String, Map<String, String>>{};
    final rawVariables = json['userVariables'];
    if (rawVariables is Map) {
      rawVariables.forEach((key, value) {
        if (value is Map) {
          userVariables[key.toString()] = value.map(
            (innerKey, innerValue) => MapEntry(innerKey.toString(), innerValue?.toString() ?? ''),
          );
        }
      });
    }
    return _Preferences(
      orders: orders,
      disabled: disabled,
      userVariables: userVariables,
    );
  }
}

/// 插件安装/卸载/订阅同步。
///
/// 与 MusicFree `PluginManager` 对齐的几条硬规则：
/// * `hash = sha256(插件源码)`，同 hash 静默跳过；
/// * 同名插件只留一个，且默认拒绝「用旧版本覆盖新版本」；
/// * 订阅支持 `.js` 单插件与 `.json` 插件清单（`{ plugins: [{ url }] }`）；
/// * 拉取订阅/插件时追加随机 hash（等价 MusicFree 的 `addRandomHash`）。
class MusicFreePlugins {
  MusicFreePlugins({required this.host, PluginPaths? paths, http.Client? httpClient})
    : paths = paths ?? PluginPaths(),
      _http = httpClient ?? http.Client();

  final MusicFreeHost host;
  final PluginPaths paths;
  final http.Client _http;

  _Preferences _prefs = _Preferences();
  bool _prefsLoaded = false;

  /// 按「用户排序 → 加载顺序」返回插件，并带上本地偏好。
  List<MusicFreePlugin> get plugins {
    final items = <MusicFreePlugin>[];
    var index = 0;
    for (final plugin in host.plugins) {
      items.add(
        plugin.copyWith(
          order: _prefs.orders[plugin.platform] ?? (1000 + index),
          enabled: !_prefs.disabled.contains(plugin.platform),
        ),
      );
      index += 1;
    }
    items.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      if (byOrder != 0) {
        return byOrder;
      }
      return a.platform.compareTo(b.platform);
    });
    return List<MusicFreePlugin>.unmodifiable(items);
  }

  List<MusicFreePlugin> get enabledPlugins =>
      plugins.where((plugin) => plugin.enabled && plugin.isUsable).toList(growable: false);

  Map<String, String> userVariablesOf(String platform) =>
      _prefs.userVariables[platform] ?? const <String, String>{};

  // --------------------------------------------------------------- 本地装载
  /// 扫描本地插件目录并按 MusicFree 的规则装载（hash 去重、失败不阻塞）。
  ///
  /// 顺序很重要：
  /// 1. **先用上次的 describe 结果把列表铺出来**（不编译 JS）——启动就能看到插件；
  /// 2. 只有「没有元数据」的（新装 / 更新过）才现场编译，最多 3 路并行（worker 池）；
  /// 3. 剩下「登记了但还没编译」的交给后台 `prefetch()` 慢慢编。
  Future<void> loadInstalled() async {
    await _loadPrefs();
    await paths.ensureReady();
    final dir = Directory(paths.pluginDir);
    if (!dir.existsSync()) {
      return;
    }
    final files = dir
        .listSync()
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.js'))
        .toList(growable: false);
    files.sort((a, b) => a.path.compareTo(b.path));

    // 顺手清掉「源码已不在磁盘上」的字节码：QuickJS 的字节码会把源码与调试信息
    // 一起序列化，一个插件几 MB，插件更新（换 hash）/ 卸载很容易攒出几百 MB。
    // 后台做即可，不影响本次装载。
    unawaited(
      MusicFreeBytecodeCache(dir: paths.bytecodeDir).prunePlugins(
        files
            .map((file) => file.path.split(Platform.pathSeparator).last)
            .where((name) => name.toLowerCase().endsWith('.js'))
            .map((name) => name.substring(0, name.length - 3))
            .toSet(),
      ),
    );

    // 1) 元数据复用：列表立刻可见，编译推迟到真正要用的时候
    final restored = await host.restoreMetadata();
    if (restored > 0) {
      AppLog.info('插件元数据复用 $restored 个（未编译，按需装载）');
    }

    // 2) 元数据缺失的（新装 / 更新过）必须编译一次才知道 describe
    final pending = <File>[];
    for (final file in files) {
      final name = file.path.split(Platform.pathSeparator).last;
      final hash = name.toLowerCase().endsWith('.js')
          ? name.substring(0, name.length - 3)
          : name;
      if (host.byHash(hash) != null) {
        continue;
      }
      pending.add(file);
    }
    if (pending.isNotEmpty) {
      final queue = List<File>.of(pending);
      Future<void> pump() async {
        while (queue.isNotEmpty) {
          final file = queue.removeAt(0);
          try {
            final watch = Stopwatch()..start();
            final code = await file.readAsString();
            final hash = _hashOf(code);
            if (host.byHash(hash) != null) {
              continue;
            }
            final plugin = await host.loadPlugin(
              hash: hash,
              code: code,
              path: file.path,
              userVariables: const <String, String>{},
            );
            await _applyUserVariables(plugin);
            AppLog.timing('插件.装载 ${plugin.platform}', watch.elapsed);
          } on Object catch (error) {
            AppLog.warn('加载插件失败 ${file.path}', error: error);
          }
        }
      }

      // worker 池会按需补到 3 个，QuickJS 各自并行编译
      final lanes = queue.length < 3 ? queue.length : 3;
      await Future.wait<void>(<Future<void>>[
        for (var i = 0; i < lanes; i += 1) pump(),
      ]);
    }

    // 3) 剩下的在后台慢慢编，不跟用户抢
    unawaited(host.prefetch());
  }

  // ------------------------------------------------------------- 订阅同步
  /// 同步服务器下发的订阅 URL。
  ///
  /// * URL 列表没变且本地已有插件 → 什么都不做（一条请求都不发）；
  /// * URL 变了 → 只装新增、只卸被移除的，其余沿用；
  /// * 服务器下发空列表 → **保留本地插件**（只提示，不删）。
  ///
  /// [onProgress] 每装上一个插件就回调一次，界面据此显示「已装载 x 个」，
  /// 不用等整轮结束才刷新。
  Future<SubscriptionSyncResult> syncSubscription({
    required List<String> urls,
    String? signature,
    bool force = false,
    void Function(String message)? onProgress,
  }) async {
    await _loadPrefs();
    final clean = urls
        .map((url) => url.trim())
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
    final effectiveSignature = (signature ?? '').trim().isNotEmpty
        ? signature!.trim()
        : signatureOf(clean);
    final saved = await _readSubscription();
    final failures = <String>[];
    var reinstalled = false;

    // 只有这三种情况才动磁盘/发请求，其余一条都不发：
    //   · 用户主动点「刷新订阅」（force）→ 清空重装；
    //   · 远端下发空列表 → 清空本地；
    //   · 远端 URL 列表变了 → 只装新增、只卸移除，没变的沿用。
    //
    // 以前只要签名变了就 `uninstallAll()` 再全量重装：明明本地插件还能用，也要
    // 重新下载、重新解析一遍；第一次同步和之后每次订阅微调都在付这笔钱。
    final sameList = _sameList(saved.urls, clean);
    // 「哪条订阅装出了哪些插件」要记下来：删订阅时才能精确卸掉它带来的那些
    // （插件自己的 srcUrl 是单个插件地址，订阅是 .json 时对不上）
    final owned = <String, List<String>>{
      for (final entry in saved.owned.entries) entry.key: List<String>.of(entry.value),
    };

    Future<void> installTracked(String url) async {
      final existing = host.plugins.map((plugin) => plugin.hash).toSet();
      await installFromRemote(url, onProgress: onProgress);
      owned[url] = host.plugins
          .map((plugin) => plugin.hash)
          .where((hash) => !existing.contains(hash))
          .toList(growable: false);
      onProgress?.call('已装载 ${host.plugins.length} 个插件');
    }

    // 并发装订阅：每个插件是「下载 → 在 worker 里编译」两段活，串成一条队列的话
    // N 个插件就是 N 次下载依次排队 + N 次编译依次排队。限 3 路并发让下载重叠，
    // 编译仍在 worker 内排队（JS 是单线程，快不了）。
    Future<void> installAll(List<String> urls) async {
      final pending = List<String>.of(urls);
      Future<void> pump() async {
        while (pending.isNotEmpty) {
          final url = pending.removeAt(0);
          try {
            await installTracked(url);
            reinstalled = true;
          } on Object catch (error) {
            AppLog.warn('订阅安装失败 $url', error: error);
            failures.add(
              '$url：${error is MusicFreeException ? error.message : error}',
            );
          }
        }
      }

      final lanes = urls.length < 3 ? urls.length : 3;
      await Future.wait<void>(<Future<void>>[
        for (var i = 0; i < lanes; i += 1) pump(),
      ]);
    }

    if (force) {
      await uninstallAll();
      owned.clear();
      reinstalled = true;
      onProgress?.call('正在按订阅重新装载 ${clean.length} 个来源…');
      await installAll(clean);
    } else if (clean.isEmpty) {
      // 服务器这次没下发订阅（或请求拿到空）：**绝不据此清空本地插件**。
      // 以前这里会 uninstallAll()，一次瞬时的空响应就把用户装好的插件全删了，
      // 界面表现就是「突然说没有插件，然后从头装一遍」。
      return SubscriptionSyncResult(
        urls: clean,
        signature: effectiveSignature,
        reinstalled: false,
        failures: const <String>['服务器没有下发订阅地址（本地插件已保留）'],
      );
    } else if (sameList) {
      // 订阅没变：本地装的就是这一套，直接返回（不下载、不卸载、不解析 JS）
      return SubscriptionSyncResult(
        urls: clean,
        signature: effectiveSignature,
        reinstalled: false,
        failures: const <String>[],
      );
    } else {
      for (final url in saved.urls.where((item) => !clean.contains(item))) {
        final hashes = owned.remove(url) ?? const <String>[];
        for (final hash in hashes) {
          final plugin = host.byHash(hash);
          if (plugin != null) {
            await _removePlugin(plugin);
          }
        }
        reinstalled = true;
      }
      await installAll(
        clean
            .where((item) => !saved.urls.contains(item))
            .toList(growable: false),
      );
    }


    await _writeSubscription(
      _SubscriptionState(
        urls: clean,
        signature: effectiveSignature,
        owned: owned,
      ),
    );
    return SubscriptionSyncResult(
      urls: clean,
      signature: effectiveSignature,
      reinstalled: reinstalled,
      failures: failures,
    );
  }
  /// 安装订阅（`.json` 插件清单或 `.js` 单插件）。
  ///
  /// [onProgress] 转发给每个插件的安装过程，让界面能边装边刷新。
  Future<void> installFromRemote(
    String urlLike, {
    void Function(String message)? onProgress,
  }) async {
    final url = urlLike.trim();
    if (url.isEmpty) {
      return;
    }
    final isJson =
        Uri.tryParse(url)?.path.toLowerCase().endsWith('.json') ??
        url.endsWith('.json');
    final fetchWatch = Stopwatch()..start();
    final body = await _fetch(_addRandomHash(url));
    AppLog.timing('插件.下载 ${_shortUrl(url)}', fetchWatch.elapsed);
    if (!isJson) {
      await installCode(body, srcUrl: url, onProgress: onProgress);
      return;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw MusicFreeException('订阅不是合法 JSON：${error.message}');
    }
    final list = decoded is Map ? decoded['plugins'] : null;
    if (list is! List) {
      throw const MusicFreeException('订阅里没有 plugins 列表');
    }
    final problems = <String>[];
    for (final entry in list) {
      final pluginUrl = entry is Map
          ? entry['url']?.toString() ?? ''
          : entry?.toString() ?? '';
      if (pluginUrl.isEmpty) {
        continue;
      }
      try {
        final code = await _fetch(_addRandomHash(pluginUrl));
        await installCode(code, srcUrl: pluginUrl, onProgress: onProgress);
      } on Object catch (error) {
        // 一个插件坏了不能拖累同一份订阅里的其它插件：先把剩下的装完，
        // 最后再把问题汇总抛出去（这个订阅地址会被记为失败，下次只补它）
        problems.add(error is MusicFreeException ? error.message : '$error');
      }
    }
    if (problems.isNotEmpty) {
      throw MusicFreeException(problems.join('；'));
    }
  }

  /// 打点里的地址要短：完整 URL 带 token，既刷屏又可能泄密。
  static String _shortUrl(String url) =>
      url.length <= 60 ? url : '${url.substring(0, 60)}…';

  /// 按源码安装一个插件；同 hash 静默忽略，同名旧版本被替换。
  Future<MusicFreePlugin> installCode(
    String code, {
    String srcUrl = '',
    void Function(String message)? onProgress,
  }) async {
    await _loadPrefs();
    await paths.ensureReady();
    final hash = _hashOf(code);
    final existingByHash = host.byHash(hash);
    if (existingByHash != null) {
      return existingByHash;
    }
    // 编译在 worker isolate 里跑（不再冻界面），但耗时仍是这一步的大头：
    // 单独计时，回答「为什么装插件这么慢」时有据可查。
    final compileWatch = Stopwatch()..start();
    final candidate = await host.loadPlugin(
      hash: hash,
      code: code,
      srcUrl: srcUrl,
      path: paths.pluginFile(hash),
    );
    AppLog.timing('插件.编译 ${candidate.platform.isEmpty ? hash : candidate.platform}',
        compileWatch.elapsed);
    onProgress?.call(
      '已装载 ${candidate.platform.isEmpty ? '插件' : candidate.platform}',
    );
    if (candidate.loadError != null || candidate.supportedMethods.isEmpty) {
      host.unload(hash);
      throw MusicFreeException('插件无法解析：${candidate.loadError ?? '没有实现任何方法'}');
    }
    final sameName = host.plugins
        .where((plugin) => plugin.platform == candidate.platform && plugin.hash != hash)
        .toList(growable: false);
    for (final old in sameName) {
      if (_compareVersion(old.version, candidate.version) > 0) {
        host.unload(hash);
        throw MusicFreeException(
          '已安装更新版本的插件（${old.version} 高于 ${candidate.version}）',
        );
      }
      await _removePlugin(old);
    }
    final file = File(paths.pluginFile(hash));
    await file.writeAsString(code);
    await _applyUserVariables(candidate);
    AppLog.info('已安装插件 ${candidate.platform} v${candidate.version}（$hash）');
    return host.byHash(hash) ?? candidate;
  }

  /// 卸载单个插件（删除源码文件，保留 storage / cookie）。
  Future<void> uninstall(String hash) async {
    final plugin = host.byHash(hash);
    if (plugin == null) {
      return;
    }
    await _removePlugin(plugin);
  }

  /// 卸载全部插件（URL 变更时用）。
  Future<void> uninstallAll() async {
    for (final plugin in host.plugins.toList(growable: false)) {
      await _removePlugin(plugin);
    }
  }

  /// 「更新全部」：按插件自带的 srcUrl 重新拉取安装。
  Future<List<String>> updateAll() async {
    final failures = <String>[];
    for (final plugin in host.plugins.toList(growable: false)) {
      final src = plugin.srcUrl;
      if (src.isEmpty) {
        continue;
      }
      try {
        await installFromRemote(src);
      } on Object catch (error) {
        failures.add('${plugin.platform}：${error is MusicFreeException ? error.message : error}');
      }
    }
    return failures;
  }

  // ------------------------------------------------------------------ 偏好
  Future<void> setEnabled(String hash, bool enabled) async {
    await _loadPrefs();
    final plugin = host.byHash(hash);
    if (plugin == null) {
      return;
    }
    if (enabled) {
      _prefs.disabled.remove(plugin.platform);
    } else {
      _prefs.disabled.add(plugin.platform);
    }
    await _writePrefs();
  }

  /// 上移 / 下移（delta = -1 / +1）。
  Future<void> move(String hash, int delta) async {
    await _loadPrefs();
    final ordered = plugins.toList(growable: true);
    final index = ordered.indexWhere((plugin) => plugin.hash == hash);
    if (index == -1) {
      return;
    }
    final target = index + delta;
    if (target < 0 || target >= ordered.length) {
      return;
    }
    final moved = ordered.removeAt(index);
    ordered.insert(target, moved);
    for (var i = 0; i < ordered.length; i += 1) {
      _prefs.orders[ordered[i].platform] = i;
    }
    await _writePrefs();
  }

  Future<void> saveUserVariables(String hash, Map<String, String> values) async {
    await _loadPrefs();
    final plugin = host.byHash(hash);
    if (plugin == null) {
      return;
    }
    _prefs.userVariables[plugin.platform] = Map<String, String>.of(values);
    await _writePrefs();
    await _reload(plugin.hash);
  }

  Future<void> _applyUserVariables(MusicFreePlugin plugin) async {
    final values = _prefs.userVariables[plugin.platform];
    if (values == null || values.isEmpty) {
      return;
    }
    final code = await File(plugin.path).readAsString();
    await host.loadPlugin(
      hash: plugin.hash,
      code: code,
      srcUrl: plugin.srcUrl,
      path: plugin.path,
      userVariables: values,
    );
  }

  Future<void> _reload(String hash) async {
    final plugin = host.byHash(hash);
    if (plugin == null) {
      return;
    }
    final file = File(plugin.path);
    if (!file.existsSync()) {
      return;
    }
    final code = await file.readAsString();
    await host.loadPlugin(
      hash: hash,
      code: code,
      srcUrl: plugin.srcUrl,
      path: plugin.path,
      userVariables: _prefs.userVariables[plugin.platform] ?? const <String, String>{},
    );
  }

  Future<void> _removePlugin(MusicFreePlugin plugin) async {
    host.unload(plugin.hash);
    // 元数据也要一起清：否则下次启动会从缓存里「复活」一个已经删掉的插件
    await host.forgetMetadata(plugin.hash);
    // 字节码同理：一个插件的字节码有好几 MB（QuickJS 会把源码与调试信息一起
    // 序列化），插件删了它就是纯粹的磁盘垃圾。文件名就是 sha256(源码)，不用读盘。
    unawaited(
      MusicFreeBytecodeCache(dir: paths.bytecodeDir)
          .remove(MusicFreeBytecodeCache.pluginKeyForHash(plugin.hash)),
    );
    final file = File(paths.pluginFile(plugin.hash));
    if (file.existsSync()) {
      try {
        await file.delete();
      } on Object catch (error) {
        AppLog.warn('删除插件文件失败 ${file.path}', error: error);
      }
    }
  }

  // ---------------------------------------------------------------- 工具
  static String signatureOf(List<String> urls) {
    return crypto.sha256.convert(utf8.encode(urls.join('\n'))).toString();
  }

  static String _hashOf(String code) =>
      crypto.sha256.convert(utf8.encode(code)).toString();

  /// 等价 MusicFree 的 `addRandomHash`：没有 `#` 时追加时间戳，绕开缓存。
  static String _addRandomHash(String url) {
    if (url.contains('#')) {
      return url;
    }
    return '$url#${DateTime.now().millisecondsSinceEpoch}';
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// 版本比较（等价 compare-versions 的常用语义：数字段逐个比，预发布低于正式版）。
  static int _compareVersion(String a, String b) {
    final left = _parseVersion(a);
    final right = _parseVersion(b);
    for (var i = 0; i < 3; i += 1) {
      final diff = left.numbers[i].compareTo(right.numbers[i]);
      if (diff != 0) {
        return diff > 0 ? 1 : -1;
      }
    }
    if (left.pre.isEmpty && right.pre.isEmpty) {
      return 0;
    }
    if (left.pre.isEmpty) {
      return 1;
    }
    if (right.pre.isEmpty) {
      return -1;
    }
    return left.pre.compareTo(right.pre).sign;
  }

  static ({List<int> numbers, String pre}) _parseVersion(String raw) {
    final text = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
    if (text.isEmpty) {
      return (numbers: <int>[0, 0, 0], pre: '');
    }
    final main = text.split(RegExp(r'[-+]')).first;
    final segments = main.split('.');
    final numbers = <int>[0, 0, 0];
    for (var i = 0; i < 3 && i < segments.length; i += 1) {
      numbers[i] = int.tryParse(RegExp(r'^\d+').stringMatch(segments[i]) ?? '') ?? 0;
    }
    final preMatch = RegExp(r'[-+](.+)$').firstMatch(text);
    return (numbers: numbers, pre: preMatch?.group(1) ?? '');
  }

  Future<String> _fetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw MusicFreeException('地址无效：$url');
    }
    final response = await _http
        .get(uri, headers: const <String, String>{'User-Agent': 'OmiocLink/1.0'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw MusicFreeException('下载失败（HTTP ${response.statusCode}）：$url');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  // ---------------------------------------------------------------- 持久化
  Future<void> _loadPrefs() async {
    if (_prefsLoaded) {
      return;
    }
    _prefsLoaded = true;
    final file = File(paths.preferenceFile);
    if (!file.existsSync()) {
      return;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        _prefs = _Preferences.fromJson(decoded);
      }
    } on Object catch (error) {
      AppLog.warn('读取插件偏好失败', error: error);
    }
  }

  Future<void> _writePrefs() async {
    await _writeFile(paths.preferenceFile, jsonEncode(_prefs.toJson()));
  }

  Future<_SubscriptionState> _readSubscription() async {
    final file = File(paths.subscriptionFile);
    if (!file.existsSync()) {
      return const _SubscriptionState();
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        final urls = (decoded['urls'] as List? ?? const <dynamic>[])
            .map((item) => item.toString())
            .toList(growable: false);
        // 老版本文件里有 `failed`（自动补装时代留下的），这里忽略：那套逻辑已删
        final owned = <String, List<String>>{};
        final rawOwned = decoded['owned'];
        if (rawOwned is Map) {
          rawOwned.forEach((key, value) {
            if (value is List) {
              owned[key.toString()] = value
                  .map((item) => item.toString())
                  .toList(growable: false);
            }
          });
        }
        return _SubscriptionState(
          urls: urls,
          signature: decoded['signature']?.toString() ?? '',
          owned: owned,
        );
      }
    } on Object catch (error) {
      AppLog.warn('读取订阅缓存失败', error: error);
    }
    return const _SubscriptionState();
  }

  Future<void> _writeSubscription(_SubscriptionState state) async {
    await _writeFile(paths.subscriptionFile, jsonEncode(state.toJson()));
  }

  Future<void> _writeFile(String path, String content) async {
    final file = File(path);
    final dir = file.parent;
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    await file.writeAsString(content);
  }
}