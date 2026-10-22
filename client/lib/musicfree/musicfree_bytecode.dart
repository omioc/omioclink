import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../core/app_log.dart';

/// QuickJS 字节码缓存（磁盘）。
///
/// 为什么要有它：MusicFree 插件是「一整份几 MB 的 JS 源码」，每次装载都要在
/// QuickJS 里重新做词法/语法分析。实测 2.96MB 的聚合插件编译一次 22 秒、
/// 577KB 的运行时 bundle 每个 worker 各要 6 秒。QuickJS 本身支持把编译结果
/// 序列化成字节码（见 packages/quickjs_engine_local 里补的桥），于是同一份源码
/// 只需要编译一次，之后所有 worker、所有启动都只是「读文件 + 反序列化」。
///
/// 失效策略：
/// * 键 = 源码的 sha256（插件文件本来就以它命名），源码一变键就变；
/// * 文件名带 `formatVersion`，桥/引擎/包装方式变了就 +1，旧文件自然不会被读到；
/// * 读出后反序列化失败（文件被截断、引擎升级）时由调用方删掉重编译。
class MusicFreeBytecodeCache {
  MusicFreeBytecodeCache({required this.dir});

  /// 缓存目录（`<数据根>/musicfree-data/bytecode`）。
  final String dir;

  /// 字节码格式版本：**改动 native 桥、QuickJS 版本或插件包装方式时必须 +1**，
  /// 否则老缓存会被读进新引擎（反序列化失败虽然会自愈，但那是一次白跑的编译）。
  static const int formatVersion = 1;

  static const String _pluginPrefix = 'plugin-';
  static const String _bundlePrefix = 'bundle-';
  static const String _suffix = '.qbc';

  static String _sha256(String text) =>
      crypto.sha256.convert(utf8.encode(text)).toString();

  /// 插件源码 → 缓存文件名。刻意用 sha256(源码) 而不是插件的 hash 参数：
  /// hash 是调用方给的（测试里干脆就是 'test-hash'），拿它当键会在
  /// 「同一个 key 换了内容」时读到别人的字节码。
  static String pluginKey(String code) =>
      'v$formatVersion-$_pluginPrefix${_sha256(code)}$_suffix';

  /// 运行时 bundle 源码 → 缓存文件名（与插件分开命名，清理时不会误删）。
  static String bundleKey(String source) =>
      'v$formatVersion-$_bundlePrefix${_sha256(source)}$_suffix';

  String _pathOf(String key) => '$dir${Platform.pathSeparator}$key';

  /// 读一份字节码；不存在或读失败都返回 null（调用方退回源码编译）。
  Future<Uint8List?> read(String key) async {
    final file = File(_pathOf(key));
    try {
      if (!file.existsSync()) {
        return null;
      }
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } on Object catch (error) {
      AppLog.debug('读取字节码缓存失败：$error');
      return null;
    }
  }

  /// 已知插件 hash（= sha256(源码)，也是 `musicfree-plugins/<hash>.js` 的文件名）
  /// 时直接用哈希算缓存名，不必再读一遍几 MB 的源码（卸载插件时就是这种情况）。
  static String pluginKeyForHash(String hash) =>
      'v$formatVersion-$_pluginPrefix$hash$_suffix';

  /// 落盘。失败不影响本次装载（本来就已经编译好了）。
  ///
  /// 先写临时文件再改名：worker 可能同时启动好几个，被别处读到半个文件就会
  /// 触发一次「反序列化失败 → 重新编译」，白跑几秒。
  Future<void> write(String key, Uint8List bytes) async {
    try {
      final target = File(_pathOf(key));
      final directory = Directory(dir);
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }
      final temp = File('${target.path}.$pid-${DateTime.now().microsecondsSinceEpoch}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      if (target.existsSync()) {
        await target.delete();
      }
      await temp.rename(target.path);
    } on Object catch (error) {
      AppLog.debug('写入字节码缓存失败：$error');
    }
  }

  /// 删掉一份失效的字节码（反序列化失败、或插件已卸载）。
  Future<void> remove(String key) async {
    try {
      final file = File(_pathOf(key));
      if (file.existsSync()) {
        await file.delete();
      }
    } on Object catch (error) {
      AppLog.debug('删除字节码缓存失败：$error');
    }
  }

  /// 清理过期字节码：已卸载/已更新的插件、旧格式版本的残留、写了一半的临时文件。
  ///
  /// [liveHashes] 是当前 `musicfree-plugins/<hash>.js` 的文件名集合。为什么值得清：
  /// QuickJS 的字节码把源码与调试信息一起序列化，一个插件的字节码几 MB（实测
  /// 2.96MB 的插件 → 12MB），插件每更新一次都会留下一份旧的。
  ///
  /// 当前版本号的 bundle 那份不动：它没有对应的插件文件，删了要重新编译 577KB。
  Future<int> prunePlugins(Set<String> liveHashes) async {
    final directory = Directory(dir);
    if (!directory.existsSync()) {
      return 0;
    }
    final currentPrefix = 'v$formatVersion-';
    final pluginPrefix = '$currentPrefix$_pluginPrefix';
    // 只清理「肯定已经不在写」的临时文件：写盘是「临时文件 + 改名」，正在写的那份
    // 可能只有几十毫秒的历史，误删会让一次改名失败（无害但脏）。
    final tempCutoff = DateTime.now().subtract(const Duration(hours: 1));
    var removed = 0;
    try {
      for (final entity in directory.listSync()) {
        if (entity is! File) {
          continue;
        }
        final name = entity.uri.pathSegments.isEmpty ? '' : entity.uri.pathSegments.last;
        var stale = false;
        if (name.endsWith('.tmp')) {
          stale = entity.statSync().modified.isBefore(tempCutoff);
        } else if (name.endsWith(_suffix)) {
          if (!name.startsWith(currentPrefix)) {
            // 旧格式版本（本进程读不了，留着只是占地方）
            stale = true;
          } else if (name.startsWith(pluginPrefix)) {
            final hash = name.substring(
              pluginPrefix.length,
              name.length - _suffix.length,
            );
            stale = !liveHashes.contains(hash);
          }
        }
        if (!stale) {
          continue;
        }
        try {
          await entity.delete();
          removed += 1;
        } on Object catch (error) {
          AppLog.debug('清理字节码失败 ${entity.path}：$error');
        }
      }
    } on Object catch (error) {
      AppLog.debug('遍历字节码缓存失败：$error');
    }
    return removed;
  }
}
