import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 应用数据根目录（日志、壁纸、音乐插件的落盘位置）。
///
/// 桌面沿用 `%LOCALAPPDATA%\OmiocLink`，便携运行时落在可执行文件旁；这条规则
/// 与 `windows/runner/utils.cpp` 里的原生崩溃处理器一致，不能单方面改。
///
/// 安卓上这两条都不成立：没有 `LOCALAPPDATA`，可执行文件所在目录只读，
/// 任何写入都会静默失败（日志、壁纸、插件缓存全部消失）。所以手机端改用
/// 应用私有目录，并在启动时一次性初始化——下面的 getter 保持同步，
/// 免得把 [LogFile] / [PluginPaths] 这些调用点都改成异步。
class AppPaths {
  AppPaths._();

  static String? _root;

  /// 启动时调一次（必须在 `runApp` 之前），之后 [root] 同步可用。
  static Future<void> init() async {
    if (_root != null) {
      return;
    }
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        _root = (await getApplicationSupportDirectory()).path;
        return;
      } on Object catch (error) {
        // 拿不到私有目录（极少见）：退回缓存目录，至少让本次运行有日志可看
        debugPrint('应用私有目录获取失败，退回临时目录：$error');
      }
      _root = Directory.systemTemp.path;
      return;
    }
    _root = _desktopRoot();
  }

  /// 数据根目录。没走 [init] 时按旧规则现算，行为与改动前一致。
  static String get root => _root ??= _desktopRoot();

  static String get logsDir => join('logs');

  static String get themeDir => join('theme');

  static String join(String name) => '$root${Platform.pathSeparator}$name';

  static String _desktopRoot() {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) {
      return '$local${Platform.pathSeparator}OmiocLink';
    }
    // macOS/Linux 没有 LOCALAPPDATA：用主目录下的隐藏目录（可写），
    // 可执行文件所在目录往往是只读的安装位置
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return '$home${Platform.pathSeparator}.omioclink';
    }
    return File(Platform.resolvedExecutable).parent.path;
  }
}
