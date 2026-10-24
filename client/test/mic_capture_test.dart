import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:omioclink_client/media/media_models.dart';
import 'package:omioclink_client/media/mic_capture.dart';

StatsReport report(String type, Map<Object?, Object?> values) =>
    StatsReport('id-$type', type, 0, values);

void main() {
  group('extractLocalAudioLevel', () {
    test('从 media-source 读本地电平（Windows 上唯一带 audioLevel 的报告）', () {
      final level = extractLocalAudioLevel(<StatsReport>[
        report('media-source', <Object?, Object?>{
          'kind': 'audio',
          'audioLevel': 0.25,
        }),
      ]);
      expect(level, 0.25);
    });

    test('多份报告都有读数时取最大', () {
      final level = extractLocalAudioLevel(<StatsReport>[
        report('media-source', <Object?, Object?>{
          'kind': 'audio',
          'audioLevel': 0.2,
        }),
        report('outbound-rtp', <Object?, Object?>{
          'kind': 'audio',
          'audioLevel': 0.6,
        }),
      ]);
      expect(level, 0.6);
    });

    test('忽略 inbound-rtp：那是对方的声音，不是我在说话', () {
      final level = extractLocalAudioLevel(<StatsReport>[
        report('media-source', <Object?, Object?>{
          'kind': 'audio',
          'audioLevel': 0.1,
        }),
        report('inbound-rtp', <Object?, Object?>{
          'kind': 'audio',
          'audioLevel': 0.9,
        }),
      ]);
      expect(level, 0.1);
    });

    test('忽略视频报告', () {
      final level = extractLocalAudioLevel(<StatsReport>[
        report('media-source', <Object?, Object?>{
          'kind': 'video',
          'audioLevel': 0.9,
        }),
      ]);
      expect(level, isNull);
    });

    test('没有 audioLevel 字段时返回 null（拿不到 ≠ 安静）', () {
      expect(
        extractLocalAudioLevel(<StatsReport>[
          report('transport', <Object?, Object?>{'bytesSent': 0}),
        ]),
        isNull,
      );
      expect(
        extractLocalAudioLevel(<StatsReport>[
          report('media-source', <Object?, Object?>{'kind': 'audio'}),
        ]),
        isNull,
      );
    });

    test('读到 0 是有效读数，不能当成「拿不到」', () {
      expect(
        extractLocalAudioLevel(<StatsReport>[
          report('media-source', <Object?, Object?>{
            'kind': 'audio',
            'audioLevel': 0,
          }),
        ]),
        0,
      );
    });
  });

  group('microphoneConstraints', () {
    test('桌面端用 sourceId 选输入设备（那边的 deviceId 是播放设备）', () {
      final constraints = microphoneConstraints(
        deviceId: 'mic-1',
        desktop: true,
      );
      final audio = constraints['audio'] as Map<String, dynamic>;
      expect(audio['sourceId'], 'mic-1');
      expect(audio.containsKey('deviceId'), isFalse);
    });

    test('Web / 移动端沿用 deviceId', () {
      final constraints = microphoneConstraints(
        deviceId: 'mic-1',
        desktop: false,
      );
      final audio = constraints['audio'] as Map<String, dynamic>;
      expect(audio['deviceId'], 'mic-1');
      expect(audio.containsKey('sourceId'), isFalse);
    });

    test('不指定设备时跟随系统默认（不带设备约束）', () {
      final constraints = microphoneConstraints(desktop: true);
      final audio = constraints['audio'] as Map<String, dynamic>;
      expect(audio.containsKey('sourceId'), isFalse);
      expect(audio.containsKey('deviceId'), isFalse);
      expect(audio['echoCancellation'], isTrue);
      expect(audio['noiseSuppression'], isTrue);
      // 默认档（标准）关掉自动增益：它是「安静时底噪被抬高、开口又忽大忽小」的来源，
      // 本应用的麦克风音量本身已经调在系统录音设备上，不需要再叠一层自动增益
      expect(audio['autoGainControl'], isFalse);
    });

    test('空串等同于不指定', () {
      final constraints = microphoneConstraints(deviceId: '', desktop: true);
      final audio = constraints['audio'] as Map<String, dynamic>;
      expect(audio.containsKey('sourceId'), isFalse);
      expect(audio.containsKey('deviceId'), isFalse);
    });

    test('本应用没有摄像头视频，video 恒为 false', () {
      expect(microphoneConstraints(desktop: true)['video'], isFalse);
    });
  });

  group('resolveAudioInput', () {
    const micA = AudioDevice(deviceId: 'mic-a', label: '麦克风 A', isInput: true);

    test('枚举为空但此前见过设备：不判「没有麦克风」，退回系统默认继续采集', () {
      // Windows 上采集过一次之后再枚举音频设备会拿到空表（原生音频设备模块终止后
      // 不再列设备）。设备明明还在，按空表拒绝就是「第二次试麦/第二次进房必挂」
      // 的那个 bug——试麦→停止→进房正好走这条路径。
      final choice = resolveAudioInput(
        devices: const <AudioDevice>[],
        requested: micA.deviceId,
        seenDeviceBefore: true,
      );
      expect(choice.missing, isFalse);
      expect(choice.deviceId, isEmpty, reason: '拿不准具体设备时跟随系统默认最安全');
    });

    test('枚举为空且从没见过设备：仍然判定没有麦克风（防幽灵轨）', () {
      final choice = resolveAudioInput(
        devices: const <AudioDevice>[],
        requested: '',
        seenDeviceBefore: false,
      );
      expect(choice.missing, isTrue);
    });

    test('设备表正常时行为不变：选中的设备还在表里就用它', () {
      final choice = resolveAudioInput(
        devices: const <AudioDevice>[micA],
        requested: micA.deviceId,
        seenDeviceBefore: true,
      );
      expect(choice.missing, isFalse);
      expect(choice.deviceId, micA.deviceId);
    });

    test('枚举失败（null）时照旧沿用选择', () {
      final choice = resolveAudioInput(
        devices: null,
        requested: micA.deviceId,
      );
      expect(choice.missing, isFalse);
      expect(choice.deviceId, micA.deviceId);
    });
  });

  group('chooseAudioInput', () {
    const micA = AudioDevice(deviceId: 'mic-a', label: '麦克风 A', isInput: true);
    const micB = AudioDevice(deviceId: 'mic-b', label: '麦克风 B', isInput: true);

    test('设备表为空：判定为没有麦克风，必须放弃采集', () {
      // Windows 上这种机器调 getUserMedia 也能「成功」，但拿到的是没有采集
      // 端点的幽灵轨，推进连接就是卡死/闪退，所以这里必须拦住
      final choice = chooseAudioInput(
        devices: const <AudioDevice>[],
        requested: 'mic-a',
      );
      expect(choice.missing, isTrue);
      expect(choice.deviceId, isEmpty);
    });

    test('枚举失败（null）不算没有麦克风：原样沿用选择再试一次', () {
      final choice = chooseAudioInput(devices: null, requested: 'mic-a');
      expect(choice.missing, isFalse);
      expect(choice.deviceId, 'mic-a');
    });

    test('选中的设备还在：用它', () {
      final choice = chooseAudioInput(
        devices: const <AudioDevice>[micA, micB],
        requested: 'mic-b',
      );
      expect(choice.missing, isFalse);
      expect(choice.deviceId, 'mic-b');
    });

    test('选中的设备已经拔掉：退回系统默认，别拿选不中的 id 去采集', () {
      final choice = chooseAudioInput(
        devices: const <AudioDevice>[micA, micB],
        requested: 'mic-gone',
      );
      expect(choice.missing, isFalse);
      expect(choice.deviceId, isEmpty);
    });

    test('没选过设备（null / 空串）：跟随系统默认', () {
      expect(
        chooseAudioInput(
          devices: const <AudioDevice>[micA],
          requested: null,
        ).deviceId,
        isEmpty,
      );
      expect(
        chooseAudioInput(
          devices: const <AudioDevice>[micA],
          requested: '',
        ).deviceId,
        isEmpty,
      );
    });
  });
}
