import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:omioclink_client/media/media_models.dart';
import 'package:omioclink_client/media/screen_capture.dart';

Uint8List bytes(int length) => Uint8List.fromList(List<int>.filled(length, 1));

ScreenSource source(
  String id, {
  bool isWindow = false,
  Uint8List? thumbnail,
}) => ScreenSource(
  id: id,
  name: '源 $id',
  isWindow: isWindow,
  thumbnail: thumbnail,
);

Map<dynamic, dynamic> videoOf(Map<String, dynamic> constraints) =>
    constraints['video'] as Map<dynamic, dynamic>;

void main() {
  group('ScreenShareQuality', () {
    test('三档：清晰/游戏都是 60fps，流畅 30fps，界面只标帧率', () {
      expect(ScreenShareQuality.clear.maxFps, 60);
      expect(ScreenShareQuality.clear.maxBitrate, 8000000);
      expect(ScreenShareQuality.game.maxFps, 60);
      expect(ScreenShareQuality.game.maxBitrate, 10000000);
      expect(ScreenShareQuality.smooth.maxFps, 30);
      expect(ScreenShareQuality.smooth.maxBitrate, 6000000);
      // 分辨率等于源的分辨率，标签里不写分辨率免得对超大源不准确
      expect(ScreenShareQuality.clear.spec, '60fps');
      expect(ScreenShareQuality.smooth.spec, '30fps');
      expect(ScreenShareQuality.maxHeight, 1080);
      expect(ScreenShareQuality.maxWidth, 1920);
      // 默认档是清晰
      expect(ScreenShareQuality.fallback, ScreenShareQuality.clear);
    });

    test('带宽吃紧时的取舍：只有游戏档保帧率', () {
      expect(
        ScreenShareQuality.clear.degradation,
        RTCDegradationPreference.MAINTAIN_RESOLUTION,
      );
      expect(
        ScreenShareQuality.smooth.degradation,
        RTCDegradationPreference.MAINTAIN_RESOLUTION,
      );
      expect(
        ScreenShareQuality.game.degradation,
        RTCDegradationPreference.MAINTAIN_FRAMERATE,
      );
      // 每档都要有给用户看的说明
      for (final quality in ScreenShareQuality.values) {
        expect(quality.detail, isNotEmpty);
        expect(quality.label, isNotEmpty);
      }
    });
  });

  group('screenSendParameters', () {
    test('默认（清晰）声明保分辨率：上行吃紧时宁可加重压缩也不缩小画面', () {
      final parameters = screenSendParameters();
      expect(
        parameters.degradationPreference,
        RTCDegradationPreference.MAINTAIN_RESOLUTION,
      );
      // 原生的反序列化只认这串字符串，别写成枚举名
      expect(
        parameters.toMap()['degradationPreference'],
        'maintain-resolution',
      );
    });

    test('参数跟着档位走：帧率、码率上限、降级策略', () {
      final game = screenSendParameters(quality: ScreenShareQuality.game);
      expect(game.encodings!.single.maxFramerate, 60);
      expect(game.encodings!.single.maxBitrate, 10000000);
      expect(game.toMap()['degradationPreference'], 'maintain-framerate');

      final smooth = screenSendParameters(quality: ScreenShareQuality.smooth);
      expect(smooth.encodings!.single.maxFramerate, 30);
      expect(smooth.encodings!.single.maxBitrate, 6000000);
      expect(smooth.toMap()['degradationPreference'], 'maintain-resolution');
    });

    test('不做缩放：源多大就发多大（平台做不到压到 1080p，见实现说明）', () {
      final encoding = screenSendParameters(
        quality: ScreenShareQuality.game,
      ).encodings!.single;
      expect(encoding.scaleResolutionDownBy, 1.0);
      expect(encoding.toMap()['scaleResolutionDownBy'], 1.0);
      // 只送需要的字段，别把 rid/ssrc 这类混进去
      final map = encoding.toMap();
      expect(map['active'], isTrue);
      expect(map.containsKey('rid'), isFalse);
      expect(map.containsKey('ssrc'), isFalse);
    });
  });

  group('screenShareConstraints', () {
    test('deviceId 用 exact 形式：传字符串会被原生当成没指定源', () {
      final video = videoOf(
        screenShareConstraints(sourceId: '460310', withSystemAudio: false),
      );
      expect(video['deviceId'], <String, dynamic>{'exact': '460310'});
      expect(video['deviceId'], isNot('460310'));
    });

    test('帧率走 mandatory.frameRate（原生只认这个键与小写 double）', () {
      final video = videoOf(
        screenShareConstraints(
          sourceId: '0',
          withSystemAudio: false,
          maxFps: 30,
        ),
      );
      final mandatory = video['mandatory'] as Map<dynamic, dynamic>;
      expect(mandatory['frameRate'], 30.0);
      expect(mandatory.containsKey('maxFrameRate'), isFalse);
      expect(mandatory['chromeMediaSource'], 'desktop');
    });

    test('不共享系统声音时 audio 为 false', () {
      final constraints = screenShareConstraints(
        sourceId: '0',
        withSystemAudio: false,
      );
      expect(constraints['audio'], isFalse);
    });

    test('共享系统声音时带上桌面回环的 audio 约束', () {
      final constraints = screenShareConstraints(
        sourceId: '0',
        withSystemAudio: true,
      );
      final audio = constraints['audio'] as Map<dynamic, dynamic>;
      final mandatory = audio['mandatory'] as Map<dynamic, dynamic>;
      expect(mandatory['chromeMediaSource'], 'desktop');
    });
  });

  group('desktopSourceThumbnailRequest', () {
    test('带 sourceId 与尺寸（原生缺任一个都会回 Bad Arguments）', () {
      expect(
        desktopSourceThumbnailRequest(sourceId: '0', width: 320, height: 180),
        <String, dynamic>{
          'sourceId': '0',
          'thumbnailSize': <String, dynamic>{'width': 320, 'height': 180},
        },
      );
    });
  });

  group('attachScreenThumbnails', () {
    test('给缺图的源逐个补图，已有的不重复取', () async {
      final fetched = <String>[];
      final result = await attachScreenThumbnails(
        <ScreenSource>[
          source('0', thumbnail: bytes(3)),
          source('460310', isWindow: true),
        ],
        fetch: (sourceId) async {
          fetched.add(sourceId);
          return bytes(5);
        },
      );

      expect(fetched, <String>['460310']);
      expect(result.first.thumbnail, bytes(3));
      expect(result.last.thumbnail, bytes(5));
      expect(result.last.isWindow, isTrue);
      expect(result.last.name, '源 460310');
    });

    test('全部带图时一次都不取', () async {
      var calls = 0;
      final result = await attachScreenThumbnails(
        <ScreenSource>[source('0', thumbnail: bytes(1))],
        fetch: (_) async {
          calls += 1;
          return bytes(1);
        },
      );

      expect(calls, 0);
      expect(result.single.thumbnail, bytes(1));
    });

    test('原生返回空数据或抛异常时保持无图（界面显示占位图标）', () async {
      final result = await attachScreenThumbnails(
        <ScreenSource>[source('0'), source('1')],
        fetch: (sourceId) async {
          if (sourceId == '0') {
            throw Exception('原生报错');
          }
          return Uint8List(0);
        },
        retryDelay: Duration.zero,
      );

      expect(result.every((item) => item.thumbnail == null), isTrue);
    });

    test('首轮还截不出图时再取一轮（枚举刚返回时窗口源就是这样）', () async {
      final calls = <String>[];
      final result = await attachScreenThumbnails(
        <ScreenSource>[source('0'), source('1', isWindow: true)],
        fetch: (sourceId) async {
          calls.add(sourceId);
          // 第一轮都还没有图，第二轮才出了图
          return calls.length <= 2 ? null : bytes(7);
        },
        retryDelay: Duration.zero,
      );

      expect(calls, <String>['0', '1', '0', '1']);
      expect(result.first.thumbnail, bytes(7));
      expect(result.last.thumbnail, bytes(7));
    });

    test('每轮只对还缺图的源发请求，已经拿到的不再问', () async {
      final calls = <String>[];
      await attachScreenThumbnails(
        <ScreenSource>[source('0'), source('1'), source('2')],
        fetch: (sourceId) async {
          calls.add(sourceId);
          // 只有 0 号第一轮失败
          return sourceId == '0' && calls.length <= 3 ? null : bytes(4);
        },
        retryDelay: Duration.zero,
        attempts: 2,
      );

      // 第二轮只取第一轮没成功的那个
      expect(calls, <String>['0', '1', '2', '0']);
    });

    test('一直拿不到时用尽轮次就收手', () async {
      var calls = 0;
      final result = await attachScreenThumbnails(
        <ScreenSource>[source('0')],
        fetch: (_) async {
          calls += 1;
          return null;
        },
        retryDelay: Duration.zero,
        attempts: 3,
      );

      expect(calls, 3);
      expect(result.single.thumbnail, isNull);
    });

    test('个别源卡住超时：用已有结果返回，不拖住选择器', () async {
      final pending = Completer<Uint8List?>();
      final result = await attachScreenThumbnails(
        <ScreenSource>[source('0', thumbnail: bytes(2)), source('1')],
        fetch: (_) => pending.future,
        timeout: const Duration(milliseconds: 30),
      );

      expect(result.first.thumbnail, bytes(2));
      expect(result.last.thumbnail, isNull);
    });

    test('空列表不做任何事', () async {
      var calls = 0;
      final result = await attachScreenThumbnails(
        const <ScreenSource>[],
        fetch: (_) async {
          calls += 1;
          return null;
        },
      );

      expect(calls, 0);
      expect(result, isEmpty);
    });
  });
}
