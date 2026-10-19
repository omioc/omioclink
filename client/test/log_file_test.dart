import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_log.dart';
import 'package:omioclink_client/core/log_file.dart';

void main() {
  final at = DateTime(2026, 10, 13, 22, 31, 4, 123);

  test('时间戳：可读格式 + 文件名安全格式', () {
    expect(timestamp(at), '2026-10-13 22:31:04.123');
    expect(fileStamp(at), '20261013-223104');
  });

  test('日志行含时间、级别、来源与消息，错误和堆栈一并写下', () {
    final line = formatLogLine(
      at: at,
      level: 'ERROR',
      name: 'omioclink',
      message: '异步未捕获异常',
      error: StateError('boom'),
      stackTrace: StackTrace.fromString('#0 foo\n#1 bar'),
    );
    expect(
      line,
      startsWith('2026-10-13 22:31:04.123 [ERROR] omioclink: 异步未捕获异常'),
    );
    expect(line, contains('Bad state: boom'));
    expect(line, contains('#0 foo'));
    expect(line, contains('#1 bar'));
  });

  test('没有错误与堆栈时就只有一行', () {
    final line = formatLogLine(
      at: at,
      level: 'INFO',
      name: 'omioclink',
      message: '进入房间成功',
    );
    expect(line, '2026-10-13 22:31:04.123 [INFO] omioclink: 进入房间成功');
  });

  test('默认日志目录：%LOCALAPPDATA%\\OmiocLink\\logs（原生崩溃报告同一目录）', () {
    final directory = LogFile.defaultDirectory();
    expect(directory.endsWith('logs'), isTrue);
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null && local.isNotEmpty) {
      expect(
        directory,
        '$local${Platform.pathSeparator}OmiocLink${Platform.pathSeparator}logs',
      );
    }
  });

  group('LogFile', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('omioclink-log-test');
    });

    tearDown(() {
      try {
        directory.deleteSync(recursive: true);
      } on Object {
        // 临时目录清理失败不影响用例结论
      }
    });

    test('一次运行一个文件，逐行追加', () {
      final log = LogFile.open(directory: directory.path, now: at);
      expect(log, isNotNull, reason: '临时目录一定可写');
      final file = log!;
      expect(
        file.path.split(Platform.pathSeparator).last,
        'client-20261013-223104.log',
      );

      file.write('第一行');
      file.write('第二行');
      file.close();

      expect(File(file.path).readAsLinesSync(), <String>['第一行', '第二行']);
    });

    test('清理：过期日志删掉，新日志与无关文件留着', () {
      final stale = File(
        '${directory.path}${Platform.pathSeparator}client-20261001-090000.log',
      )..writeAsStringSync('过期');
      stale.setLastModifiedSync(at.subtract(const Duration(days: 8)));
      final fresh = File(
        '${directory.path}${Platform.pathSeparator}crash-20261013-100000-1234.log',
      )..writeAsStringSync('最近的崩溃报告');
      fresh.setLastModifiedSync(at.subtract(const Duration(days: 1)));
      final foreign = File(
        '${directory.path}${Platform.pathSeparator}别动我.txt',
      )..writeAsStringSync('别人的文件');
      foreign.setLastModifiedSync(at.subtract(const Duration(days: 30)));

      final log = LogFile.open(directory: directory.path, now: at);
      expect(log, isNotNull);
      log!.close();

      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(foreign.existsSync(), isTrue);
    });

    test('AppLog 挂上文件后每条日志都落盘', () {
      final log = LogFile.open(directory: directory.path, now: at);
      expect(log, isNotNull);
      final file = log!;
      AppLog.attachFile(file);
      addTearDown(() => AppLog.attachFile(null));

      AppLog.info('进入房间成功');
      AppLog.warn('麦克风不可用', error: StateError('boom'));
      file.close();

      final content = File(file.path).readAsStringSync();
      expect(content, contains('[INFO] omioclink: 进入房间成功'));
      expect(
        content,
        contains('[WARN] omioclink: 麦克风不可用 | Bad state: boom'),
      );
    });
  });
}
