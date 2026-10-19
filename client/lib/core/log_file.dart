import 'dart:io';
import 'app_paths.dart';

/// 一行日志的文本（含可选错误与堆栈），纯函数，单测直接喂它。
///
/// 形如：
/// ```
/// 2026-10-13 22:31:04.123 [ERROR] omioclink: 平台未捕获异常 | Bad state: xxx
///     #0      Foo.bar (package:omioclink_client/foo.dart:12:3)
/// ```
/// 堆栈整段写下：出问题的那台机器上只有这份文件能说话，少一行都可能白跑一趟。
String formatLogLine({
  required DateTime at,
  required String level,
  required String name,
  required String message,
  Object? error,
  StackTrace? stackTrace,
}) {
  final buffer = StringBuffer()
    ..write(timestamp(at))
    ..write(' [')
    ..write(level)
    ..write('] ')
    ..write(name)
    ..write(': ')
    ..write(message);
  if (error != null) {
    buffer.write(' | $error');
  }
  final trace = stackTrace;
  if (trace != null) {
    for (final line in trace.toString().trimRight().split('\n')) {
      buffer
        ..write('\n')
        ..write('    ')
        ..write(line.trim());
    }
  }
  return buffer.toString();
}

/// `2026-10-13 22:31:04.123`（本地时间，毫秒对齐，便于和原生崩溃报告对时间）。
String timestamp(DateTime at) {
  return '${at.year}-${_pad(at.month)}-${_pad(at.day)} '
      '${_pad(at.hour)}:${_pad(at.minute)}:${_pad(at.second)}'
      '.${_padMillisecond(at.millisecond)}';
}

/// 文件名用的时间戳：`20261013-223104`（不含冒号，Windows 文件名不接受）。
String fileStamp(DateTime at) {
  return '${at.year}${_pad(at.month)}${_pad(at.day)}'
      '-${_pad(at.hour)}${_pad(at.minute)}${_pad(at.second)}';
}

String _pad(int value) => value < 10 ? '0$value' : '$value';

String _padMillisecond(int value) =>
    value < 10 ? '00$value' : (value < 100 ? '0$value' : '$value');

/// 落盘日志：`AppLog` 的每一行都会同时写进这里。
///
/// 为什么需要它：release 包里没有控制台、也没有接 `dart:developer` 的监听者，
/// 出问题（尤其是那种直接把进程带走的闪退）时现场什么都不剩。日志写到
/// `%LOCALAPPDATA%\OmiocLink\logs\client-<启动时间>.log`，**一次运行一个文件**，
/// 启动时清掉 7 天前的旧文件（含原生崩溃报告 `crash-*.log`）。
class LogFile {
  LogFile._(this.path, this._handle);

  /// 日志文件绝对路径（设置页会把它显示给用户）。
  final String path;

  final RandomAccessFile _handle;
  bool _closed = false;

  /// 日志文件名的前缀，`prune` 按它识别「我们的日志」。
  static const String filePrefix = 'client-';

  /// 原生崩溃报告（由 `windows/runner/utils.cpp` 写出）的前缀。
  static const String crashFilePrefix = 'crash-';

  /// 原生启动信息（同上）的前缀：记录了这台机器实际加载的 C++ 运行库。
  static const String nativeFilePrefix = 'native-';

  /// 打开本次运行的日志文件；打不开（权限、磁盘满）时返回 null，
  /// 日志自动退化为只走 `developer.log`——绝不能因此起不来。
  static LogFile? open({
    String? directory,
    Duration keep = const Duration(days: 7),
    DateTime? now,
  }) {
    try {
      final stamp = now ?? DateTime.now();
      final target = Directory(directory ?? defaultDirectory());
      target.createSync(recursive: true);
      prune(target, keep: keep, now: stamp);
      final file = File(
        '${target.path}${Platform.pathSeparator}$filePrefix${fileStamp(stamp)}.log',
      );
      return LogFile._(file.path, file.openSync(mode: FileMode.append));
    } on Object {
      return null;
    }
  }

  /// 日志目录：桌面是 `%LOCALAPPDATA%\OmiocLink\logs`（便携运行落在可执行文件旁），
  /// 手机是应用私有目录下的 `logs`。规则集中在 [AppPaths]，两边共用。
  ///
  /// **原生崩溃处理器用的是同一套规则**（见 `windows/runner/utils.cpp`），
  /// 两边改动时必须一起改，否则崩溃报告和日志会分散在两个目录里。
  static String defaultDirectory() => AppPaths.logsDir;

  /// 清掉过期日志（默认 7 天），免得目录无限增长。
  static void prune(
    Directory directory, {
    Duration keep = const Duration(days: 7),
    DateTime? now,
  }) {
    final deadline = (now ?? DateTime.now()).subtract(keep);
    try {
      for (final entity in directory.listSync()) {
        if (entity is! File) {
          continue;
        }
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.endsWith('.log')) {
          continue;
        }
        if (!name.startsWith(filePrefix) &&
            !name.startsWith(crashFilePrefix) &&
            !name.startsWith(nativeFilePrefix)) {
          continue;
        }
        if (entity.statSync().modified.isBefore(deadline)) {
          entity.deleteSync();
        }
      }
    } on Object {
      // 清理失败不影响写日志
    }
  }

  /// 追加一行。写失败只吞掉：日志坏了不能把业务带崩。
  void write(String text) {
    if (_closed) {
      return;
    }
    try {
      _handle.writeStringSync('$text\n');
    } on Object {
      // 磁盘满 / 句柄失效：忽略
    }
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      _handle.closeSync();
    } on Object {
      // 关闭失败无需处理
    }
  }
}
