import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:omioclink_client/media/media_models.dart';
import 'package:omioclink_client/media/screen_capture.dart';
import 'package:omioclink_client/media/uplink_budget.dart';

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
  group('screenSendParameters', () {
    ScreenTarget target({
      int maxBitrate = 8000000,
      int minBitrate = 4000000,
      int maxFramerate = 60,
      double scaleResolutionDownBy = 1.0,
      RTCDegradationPreference degradation =
          RTCDegradationPreference.MAINTAIN_RESOLUTION,
    }) => ScreenTarget(
      maxBitrate: maxBitrate,
      minBitrate: minBitrate,
      maxFramerate: maxFramerate,
      scaleResolutionDownBy: scaleResolutionDownBy,
      degradation: degradation,
      targetWidth: 2560,
      targetHeight: 1440,
    );

    test('上限与下限一起下发：只给上限抬不动实速（已有实测结论）', () {
      final parameters = screenSendParameters(target: target());
      final encoding = parameters.encodings!.single;
      expect(encoding.maxBitrate, 8000000);
      expect(encoding.minBitrate, 4000000);
      // 原生的反序列化只认这串字符串，别写成枚举名
      expect(parameters.toMap()['degradationPreference'], 'maintain-resolution');
    });

    test('下限必须真的进到原生收的 map 里（只在 Dart 侧赋值等于没设）', () {
      final map = screenSendParameters(target: target()).encodings!.single.toMap();
      expect(map['minBitrate'], 4000000);
      expect(map['maxBitrate'], 8000000);
    });

    test('帧率、缩放、降级策略跟着目标走', () {
      final parameters = screenSendParameters(
        target: target(
          maxFramerate: 30,
          scaleResolutionDownBy: 2560 / 1920,
          degradation: RTCDegradationPreference.MAINTAIN_FRAMERATE,
        ),
      );
      final encoding = parameters.encodings!.single;
      expect(encoding.maxFramerate, 30);
      expect(encoding.scaleResolutionDownBy, closeTo(2560 / 1920, 1e-9));
      expect(parameters.toMap()['degradationPreference'], 'maintain-framerate');
    });

    test('按源分辨率发的档位不缩放：源多大就发多大', () {
      final encoding = screenSendParameters(target: target()).encodings!.single;
      expect(encoding.scaleResolutionDownBy, 1.0);
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

    test('不再限制分辨率：输出规格交给分配器，采集恒按源尺寸拿', () {
      final video = videoOf(
        screenShareConstraints(sourceId: '0', withSystemAudio: false),
      );
      final mandatory = video['mandatory'] as Map<dynamic, dynamic>;
      // DXGI 本来就忽略 maxHeight（请求 540 仍出 1920×1080），留着只会误导
      expect(mandatory.containsKey('maxHeight'), isFalse);
      // 采集必须给到 60fps，否则分辨率优先档想临时提帧时没有帧可取
      expect(mandatory['frameRate'], 60.0);
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
