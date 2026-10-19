import 'dart:io';
import '../core/app_paths.dart';

/// 插件与插件数据的落盘位置。
///
/// 与日志同一套约定：`%LOCALAPPDATA%\OmiocLink`，没有该环境变量时退回用户主目录。
class PluginPaths {
  PluginPaths({String? root}) : root = root ?? _defaultRoot();

  final String root;

  static String _defaultRoot() => AppPaths.root;

  String get pluginDir => '$root${Platform.pathSeparator}musicfree-plugins';

  String get dataDir => '$root${Platform.pathSeparator}musicfree-data';

  String get storageDir => '$dataDir${Platform.pathSeparator}storage';

  String get cookieDir => '$dataDir${Platform.pathSeparator}cookies';

  /// 插件结果的本地缓存（搜索页 / 榜单标签），见 `MusicFreeCache`。
  String get cacheDir => '$dataDir${Platform.pathSeparator}cache';

  /// 订阅 URL 与其签名的落盘文件。
  String get subscriptionFile =>
      '$root${Platform.pathSeparator}musicfree-subscription.json';

  /// 插件本地偏好（顺序、启用状态、userVariables）。
  String get preferenceFile =>
      '$root${Platform.pathSeparator}musicfree-preferences.json';

  String pluginFile(String hash) => '$pluginDir${Platform.pathSeparator}$hash.js';

  String storageFile(String hash) => '$storageDir${Platform.pathSeparator}$hash.json';

  String cookieFile(String hash) => '$cookieDir${Platform.pathSeparator}$hash.json';

  Future<void> ensureReady() async {
    for (final dir in <String>[pluginDir, storageDir, cookieDir, cacheDir]) {
      final target = Directory(dir);
      if (!target.existsSync()) {
        await target.create(recursive: true);
      }
    }
  }
}