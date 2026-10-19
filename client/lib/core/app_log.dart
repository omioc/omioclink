import 'dart:developer' as developer;
import 'dart:io';

import 'log_file.dart';

/// 统一日志出口：一手走 `developer.log`（`flutter run` / DevTools 里可见），
/// 一手落盘（[LogFile]，由 `main` 在启动时挂上）。
///
/// 为什么要落盘：release 包既没有控制台，也没有接 `developer.log` 的监听者，
/// 出问题（尤其是那种直接把进程带走的闪退）时现场什么都不剩——出了故障的
/// 那台机器上只有这份文件能说话，所以每条日志都要如实写下去。
abstract final class AppLog {
  static LogFile? _file;

  /// 挂上日志文件（`main` 启动时调用一次；传 null 表示只走 `developer.log`）。
  static void attachFile(LogFile? file) => _file = file;

  /// 当前日志文件路径；没有落盘时为 null（设置页会把它显示给用户）。
  static String? get filePath => _file?.path;

  static void debug(String message, {String name = 'omioclink'}) =>
      _log('DEBUG', message, name: name, severity: 500);

  static void info(String message, {String name = 'omioclink'}) =>
      _log('INFO', message, name: name, severity: 800);

  static void warn(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String name = 'omioclink',
  }) => _log(
    'WARN',
    message,
    name: name,
    severity: 900,
    error: error,
    stackTrace: stackTrace,
  );

  static void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String name = 'omioclink',
  }) => _log(
    'ERROR',
    message,
    name: name,
    severity: 1000,
    error: error,
    stackTrace: stackTrace,
  );

  /// 记录当前进程占用的物理内存（MB）。
  ///
  /// 有些「闪退」其实是内存吃满被系统带走的，事后看日志时这条能一眼分辨。
  static void memory(String scene) =>
      info('$scene：内存 ${(ProcessInfo.currentRss / (1024 * 1024)).round()}MB');

  static void _log(
    String level,
    String message, {
    required String name,
    required int severity,
    Object? error,
    StackTrace? stackTrace,
  }) {
    developer.log(
      message,
      name: name,
      level: severity,
      error: error,
      stackTrace: stackTrace,
    );
    _file?.write(
      formatLogLine(
        at: DateTime.now(),
        level: level,
        name: name,
        message: message,
        error: error,
        stackTrace: stackTrace,
      ),
    );
  }
}
