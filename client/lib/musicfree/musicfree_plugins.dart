import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../core/app_log.dart';
import 'musicfree_host.dart';
import 'plugin_models.dart';
import 'plugin_paths.dart';

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
    this.failed = const <String>[],
  });

  final List<String> urls;
  final String signature;

  /// 上一次没装成功的订阅地址。
  ///
  /// 存下来是为了「下次一定补上」：只看 `plugins.isEmpty` 的话，装了 3 个、
  /// 另外 2 个下载失败会永远停在半成品（手机上第一次同步撞上弱网就是这样）。
  final List<String> failed;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'urls': urls,
    'signature': signature,
    'failed': failed,
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
    for (final file in files) {
      try {
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
      } on Object catch (error) {
        AppLog.warn('加载插件失败 ${file.path}', error: error);
      }
    }
  }

  // ------------------------------------------------------------- 订阅同步
  /// 同步服务器下发的订阅 URL。
  ///
  /// * 签名（或 URL 列表）没变且本地已有插件 → 什么都不做；
  /// * 变了 → 先卸载本地全部插件，再按新 URL 全量安装；
  /// * 服务器下发空列表 → 清空本地插件。
  Future<SubscriptionSyncResult> syncSubscription({
    required List<String> urls,
    String? signature,
    bool force = false,
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
    final changed =
        force || saved.signature != effectiveSignature || !_sameList(saved.urls, clean);
    final failures = <String>[];
    var reinstalled = false;

    if (clean.isEmpty) {
      if (host.plugins.isNotEmpty) {
        await uninstallAll();
        reinstalled = true;
      }
      await _writeSubscription(_SubscriptionState(urls: clean, signature: effectiveSignature));
      return SubscriptionSyncResult(
        urls: clean,
        signature: effectiveSignature,
        reinstalled: reinstalled,
        failures: const <String>[],
      );
    }

    // 这一轮要装哪些地址：
    // * 订阅变了 / 强制刷新 / 本地一个插件都没有 → 全部；
    // * 否则只补上次没装上的那几个（`saved.failed`）。
    //   以前只看「插件列表是不是空的」：装了 3 个、另外 2 个下载失败就一直缺着，
    //   手机上第一次同步撞上弱网正是这种半成品状态，之后再也不会补。
    final retry = changed || host.plugins.isEmpty
        ? clean
        : saved.failed.where(clean.contains).toList(growable: false);

    if (changed) {
      await uninstallAll();
      reinstalled = true;
    } else if (retry.isNotEmpty) {
      reinstalled = true;
    }

    final failedUrls = <String>[];
    for (final url in retry) {
      try {
        await installFromRemote(url);
      } on Object catch (error) {
        AppLog.warn('订阅安装失败 $url', error: error);
        failedUrls.add(url);
        failures.add('$url：${error is MusicFreeException ? error.message : error}');
      }
    }
    await _writeSubscription(
      _SubscriptionState(
        urls: clean,
        signature: effectiveSignature,
        // 这次没装成功的记下来，下次同步接着补
        failed: failedUrls,
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
  Future<void> installFromRemote(String urlLike) async {
    final url = urlLike.trim();
    if (url.isEmpty) {
      return;
    }
    final isJson = Uri.tryParse(url)?.path.toLowerCase().endsWith('.json') ?? url.endsWith('.json');
    final body = await _fetch(_addRandomHash(url));
    if (!isJson) {
      await installCode(body, srcUrl: url);
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
      final pluginUrl = entry is Map ? entry['url']?.toString() ?? '' : entry?.toString() ?? '';
      if (pluginUrl.isEmpty) {
        continue;
      }
      try {
        final code = await _fetch(_addRandomHash(pluginUrl));
        await installCode(code, srcUrl: pluginUrl);
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

  /// 按源码安装一个插件；同 hash 静默忽略，同名旧版本被替换。
  Future<MusicFreePlugin> installCode(String code, {String srcUrl = ''}) async {
    await _loadPrefs();
    await paths.ensureReady();
    final hash = _hashOf(code);
    final existingByHash = host.byHash(hash);
    if (existingByHash != null) {
      return existingByHash;
    }
    final candidate = await host.loadPlugin(
      hash: hash,
      code: code,
      srcUrl: srcUrl,
      path: paths.pluginFile(hash),
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
        final failed = (decoded['failed'] as List? ?? const <dynamic>[])
            .map((item) => item.toString())
            .toList(growable: false);
        return _SubscriptionState(
          urls: urls,
          signature: decoded['signature']?.toString() ?? '',
          failed: failed,
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