import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/app_log.dart';

/// 插件结果的本地缓存：内存一层、磁盘一层。
///
/// MusicFree 的「秒出」有一半来自它一次只搜一个音源、回来一个显示一个，另一半
/// 来自插件自己把热数据存在 `localStorage` 里。这边补上客户端这一层：
///
/// * 同一个关键词再搜一次（切音质、来回切 tab、退出再进来）直接命中内存，不发请求；
/// * 重启之后仍然命中磁盘（默认 6 小时），慢音源也就不必再等一遍。
///
/// 只缓存**插件原始返回**（`Map`），命中后仍走原来的映射逻辑，字段不会丢。
class MusicFreeCache {
  MusicFreeCache({
    required this.dir,
    this.ttl = const Duration(hours: 6),
    this.maxEntries = 400,
  });

  /// 落盘目录（`PluginPaths.cacheDir`）。
  final String dir;

  /// 磁盘条目有效期。
  final Duration ttl;

  /// 磁盘条目上限，超了按最后访问时间删最旧的一半。
  final int maxEntries;

  /// 内存层上限（一次会话里足够，避免无限涨）。
  static const int _maxMemoryEntries = 160;

  final Map<String, _CacheEntry> _memory = <String, _CacheEntry>{};
  int _writes = 0;
  bool _pruned = false;

  /// 命中数 / 未命中数，方便日志里看缓存到底有没有用。
  int hits = 0;
  int misses = 0;

  /// 只查内存（同步，给「切 tab 重搜」这种高频路径用）。
  Map<String, dynamic>? readMemory(String key) {
    final entry = _memory[key];
    if (entry == null) {
      return null;
    }
    if (entry.expiresAt.isBefore(DateTime.now())) {
      _memory.remove(key);
      return null;
    }
    return entry.value;
  }

  /// 内存 → 磁盘。返回 `null` 表示真没有（或过期）。
  Future<Map<String, dynamic>?> read(String key) async {
    final cached = readMemory(key);
    if (cached != null) {
      hits += 1;
      return cached;
    }
    final file = File(_pathOf(key));
    if (!file.existsSync()) {
      misses += 1;
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        await _delete(file);
        misses += 1;
        return null;
      }
      final savedAt = (decoded['savedAt'] as num?)?.toInt() ?? 0;
      final saved = DateTime.fromMillisecondsSinceEpoch(savedAt);
      if (savedAt <= 0 || DateTime.now().difference(saved) > ttl) {
        await _delete(file);
        misses += 1;
        return null;
      }
      final value = decoded['value'];
      if (value is! Map) {
        await _delete(file);
        misses += 1;
        return null;
      }
      final map = value.map((k, v) => MapEntry(k.toString(), v));
      _remember(key, map, saved.add(ttl));
      hits += 1;
      return map;
    } on Object catch (error) {
      AppLog.debug('读缓存失败 $key：$error');
      await _delete(file);
      misses += 1;
      return null;
    }
  }

  /// 写内存 + 磁盘。磁盘写失败只记日志，不影响这次结果。
  Future<void> write(String key, Map<String, dynamic> value) async {
    _remember(key, value, DateTime.now().add(ttl));
    final file = File(_pathOf(key));
    try {
      if (!file.parent.existsSync()) {
        await file.parent.create(recursive: true);
      }
      // 先写临时文件再改名：并发读到半截文件的情况就不会发生。
      final tmp = File(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      await tmp.writeAsString(
        jsonEncode(<String, dynamic>{
          'key': key,
          'savedAt': DateTime.now().millisecondsSinceEpoch,
          'value': value,
        }),
      );
      await tmp.rename(file.path);
      _writes += 1;
      if (_writes % 64 == 0) {
        _fireAndForget(_prune());
      }
    } on Object catch (error) {
      AppLog.debug('写缓存失败 $key：$error');
    }
  }

  /// 插件换了一批（装/卸/更新）：旧结果全部作废。
  Future<void> clear() async {
    _memory.clear();
    final directory = Directory(dir);
    if (!directory.existsSync()) {
      return;
    }
    try {
      await for (final entity in directory.list()) {
        if (entity is File && entity.path.toLowerCase().endsWith('.json')) {
          await _delete(entity);
        }
      }
    } on Object catch (error) {
      AppLog.debug('清缓存失败：$error');
    }
  }

  void _remember(String key, Map<String, dynamic> value, DateTime expiresAt) {
    if (_memory.length >= _maxMemoryEntries && !_memory.containsKey(key)) {
      // 简单粗暴：丢掉最早插入的那几个，避免无限涨
      final oldest = _memory.keys.take(_memory.length - _maxMemoryEntries + 1).toList();
      for (final item in oldest) {
        _memory.remove(item);
      }
    }
    _memory[key] = _CacheEntry(value: value, expiresAt: expiresAt);
  }

  Future<void> _prune() async {
    if (_pruned) {
      return;
    }
    _pruned = true;
    try {
      final directory = Directory(dir);
      if (!directory.existsSync()) {
        return;
      }
      final files = directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.toLowerCase().endsWith('.json'))
          .toList();
      if (files.length <= maxEntries) {
        return;
      }
      files.sort(
        (a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()),
      );
      final remove = files.length - (maxEntries ~/ 2);
      for (var index = 0; index < remove && index < files.length; index += 1) {
        await _delete(files[index]);
      }
    } on Object catch (error) {
      AppLog.debug('裁剪缓存失败：$error');
    } finally {
      _pruned = false;
    }
  }

  String _pathOf(String key) {
    final digest = sha1.convert(utf8.encode(key)).toString();
    return '$dir${Platform.pathSeparator}$digest.json';
  }

  Future<void> _delete(File file) async {
    try {
      if (file.existsSync()) {
        await file.delete();
      }
    } on Object catch (error) {
      AppLog.debug('删除缓存文件失败：$error');
    }
  }
}

class _CacheEntry {
  const _CacheEntry({required this.value, required this.expiresAt});

  final Map<String, dynamic> value;
  final DateTime expiresAt;
}

/// 后台任务不需要被等待：失败只记日志。
void _fireAndForget(Future<void> future) {
  future.catchError((Object error) {
    AppLog.debug('缓存后台任务失败：$error');
  });
}
