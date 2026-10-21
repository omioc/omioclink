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


  /// 记一条耗时打点：`启动.窗口就绪：123ms`。
  ///
  /// 启动链路优化只能靠数据说话（仓库里不引性能分析包），统一走这里，
  /// 排查时 grep 日志里的 `ms` 就能拼出时间线。正式发布也保留：日志量很小。
  static void timing(String scene, Duration elapsed) {
    info('$scene：${elapsed.inMilliseconds}ms');
    // 打点立刻落盘：这些行是事后复盘唯一的依据，不能留在缓冲区里
    _file?.flush();
  }

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
    // WARN/ERROR 立刻刷盘：其它级别是缓冲写的，万一后面界面卡死或进程被带走，
    // 缓冲区里的行就永远丢了 —— 出问题的那几行恰恰最需要留下。
    if (severity >= 900) {
      _file?.flush();
    }
  }
}
