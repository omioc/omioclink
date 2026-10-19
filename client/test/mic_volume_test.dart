import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/core/app_log.dart';
import 'package:omioclink_client/core/log_file.dart';
import 'package:omioclink_client/media/mic_volume.dart';
import 'package:omioclink_client/media/mic_volume_controller.dart';

/// 假端口：只记录调用，绝不碰真实设备。
class _FakeMicVolume implements MicVolumePort {
  _FakeMicVolume({this.supported = true, this.writeResult = true});

  @override
  bool supported;

  @override
  String? lastError;

  /// 每次 [writeVolume] 的入参（0.0~1.0），按调用顺序。
  final List<double> writes = <double>[];

  /// [readVolume] 要返回的值。
  double? readValue;

  /// [writeVolume] 是否成功；false 时顺带写一条中文 [lastError]。
  bool writeResult;

  int disposes = 0;

  @override
  double? readVolume() => readValue;

  @override
  bool writeVolume(double value) {
    writes.add(value);
    if (!writeResult) {
      lastError = '设置音量失败（HRESULT 0x80004005）';
    }
    return writeResult;
  }

  @override
  void dispose() => disposes++;
}

void main() {
  group('MicVolumeController（假端口）', () {
    late _FakeMicVolume port;
    late List<double> saved;
    late MicVolumeController controller;
    late int notifications;

    setUp(() {
      port = _FakeMicVolume();
      saved = <double>[];
      controller = MicVolumeController(
        port: port,
        load: () async => null,
        save: (value) async => saved.add(value),
      );
      notifications = 0;
      controller.addListener(() => notifications++);
    });

    tearDown(() => controller.dispose());

    test('setVolume(42) 归一化成 0.42 下发，并持久化 42', () async {
      await controller.setVolume(42);

      expect(port.writes, <double>[0.42], reason: '0~100 的 42 应换算成 0.0~1.0 的 0.42');
      expect(controller.volume, 42);
      expect(saved, <double>[42], reason: '持久化的是 0~100 的百分数');
      expect(controller.notice, isNull);
      expect(controller.supported, isTrue);
      expect(notifications, greaterThan(0), reason: '先更新 volume 再下发，界面能立刻跟手');
    });

    test('越界取值钳制到 0~100', () async {
      await controller.setVolume(-10);
      expect(controller.volume, 0);
      expect(port.writes.last, 0.0);
      expect(saved.last, 0);

      await controller.setVolume(300);
      expect(controller.volume, 100);
      expect(port.writes.last, 1.0);
      expect(saved.last, 100);
    });

    test('load() 读到持久值 30 就用 0.30 下发', () async {
      final loaded = MicVolumeController(
        port: port,
        load: () async => 30,
        save: (value) async => saved.add(value),
      );
      addTearDown(loaded.dispose);

      await loaded.load();

      expect(loaded.volume, 30);
      expect(port.writes, <double>[0.30]);
      expect(loaded.notice, isNull);
    });

    test('load() 读不到持久值时按 100 下发', () async {
      await controller.load();

      expect(controller.volume, 100);
      expect(port.writes, <double>[1.0]);
    });

    test('端口不支持：supported=false、notice 非空、setVolume 不抛且仍持久化', () async {
      final unsupported = _FakeMicVolume(supported: false)
        ..lastError = '没有找到可用的录音设备';
      final control = MicVolumeController(
        port: unsupported,
        load: () async => 55,
        save: (value) async => saved.add(value),
      );
      addTearDown(control.dispose);

      expect(control.supported, isFalse);
      expect(control.notice, isNotNull, reason: '界面要知道「为什么调不了」');
      expect(control.notice, contains('录音设备'));

      await control.load();
      expect(control.volume, 55, reason: '调不动也要把持久值显示出来');

      await control.setVolume(66);
      expect(control.volume, 66);
      expect(saved.last, 66, reason: '不支持时也要记下用户的选择');
      expect(unsupported.writes, isEmpty, reason: '不支持就不该下发');
      expect(control.notice, contains('录音设备'));
    });

    test('下发失败：notice 有原因、日志有记录、不抛', () async {
      final failing = _FakeMicVolume(writeResult: false);
      final control = MicVolumeController(
        port: failing,
        load: () async => 100,
        save: (value) async => saved.add(value),
      );
      addTearDown(control.dispose);

      final directory = Directory.systemTemp.createTempSync('mic_volume_test');
      final logFile = LogFile.open(directory: directory.path);
      expect(logFile, isNotNull);
      String? logText;
      try {
        AppLog.attachFile(logFile);
        await control.setVolume(40);

        expect(control.volume, 40);
        expect(control.notice, isNotNull);
        expect(control.notice, contains('HRESULT'));
        expect(saved, <double>[40], reason: '失败也要持久化用户的选择');
      } finally {
        AppLog.attachFile(null);
        logText = File(logFile!.path).readAsStringSync();
        logFile.close();
        directory.deleteSync(recursive: true);
      }

      // 事后核对要用：日志里必须有「麦克风音量」、具体数值和失败原因
      expect(logText, contains('麦克风音量'));
      expect(logText, contains('40%'));
      expect(logText, contains('失败'));
      expect(logText, contains('0x80004005'));
    });

    test('reapply() 按当前值重新下发', () async {
      await controller.setVolume(25);
      expect(port.writes, <double>[0.25]);

      await controller.reapply();
      expect(port.writes, <double>[0.25, 0.25]);
    });

    test('dispose() 会释放端口，且重复调用安全', () {
      controller.dispose();
      controller.dispose();
      expect(port.disposes, 1, reason: '端口只该释放一次');
    });
  });

  group('NullMicVolume', () {
    test('读写都失败但绝不抛', () {
      final port = NullMicVolume();
      expect(port.supported, isFalse);
      expect(port.lastError, isNotNull);
      expect(port.readVolume(), isNull);
      expect(port.writeVolume(0.5), isFalse);
      port.dispose();
      port.dispose();
    });
  });

  // 真实读回：采集用例的时候先探一次，本机没有录音设备就明确 skip，
  // 不能让它静默「通过」——那样看起来实测过了，其实什么都没验。
  final realPort = createMicVolumePort();
  final skipReason = realPort.supported ? null : '本机无录音设备、未实测';

  test('真实读回：默认录音设备音量可写可读', () {
    final port = realPort;
    final original = port.readVolume();
    if (original == null) {
      debugPrint('[mic-volume] 读不到当前录音设备音量（${port.lastError}）');
      printOnFailure('读不到当前录音设备音量、未实测');
      markTestSkipped('读不到当前录音设备音量、未实测');
      return;
    }
    debugPrint('[mic-volume] 原始音量读回 = $original');
    // 兜底恢复：后面哪条断言挂了，也把机器音量还原，别留在改过的值上。
    addTearDown(() {
      port.writeVolume(original);
      port.dispose();
    });

    expect(port.writeVolume(0.42), isTrue, reason: '写 0.42 失败（${port.lastError}）');
    final read42 = port.readVolume();
    debugPrint('[mic-volume] 写入 0.42 后读回 = $read42');
    expect(read42, isNotNull, reason: '写入后读不到音量（${port.lastError}）');
    expect(
      (read42! - 0.42).abs(),
      lessThanOrEqualTo(0.02),
      reason: '写入 0.42 后读回 $read42，误差超过 0.02',
    );

    expect(port.writeVolume(0.67), isTrue, reason: '写 0.67 失败（${port.lastError}）');
    final read67 = port.readVolume();
    debugPrint('[mic-volume] 写入 0.67 后读回 = $read67');
    expect(read67, isNotNull, reason: '写入后读不到音量（${port.lastError}）');
    expect(
      (read67! - 0.67).abs(),
      lessThanOrEqualTo(0.02),
      reason: '写入 0.67 后读回 $read67，误差超过 0.02',
    );

    expect(port.writeVolume(original), isTrue, reason: '恢复原值失败（${port.lastError}）');
    final restored = port.readVolume();
    debugPrint('[mic-volume] 恢复 $original 后读回 = $restored');
    expect(restored, isNotNull, reason: '恢复后读不到音量（${port.lastError}）');
    expect(
      (restored! - original).abs(),
      lessThanOrEqualTo(0.02),
      reason: '恢复原值后读回 $restored，与原始 $original 相差超过 0.02',
    );
  }, skip: skipReason);
}
