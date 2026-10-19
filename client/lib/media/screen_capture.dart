import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/app_log.dart';
import 'media_models.dart';

/// 屏幕共享的采集约束。
///
/// 两个坑都收在这里：
/// * 桌面端（Windows / macOS）原生读的是 `video.deviceId.exact`。直接传字符串会被
///   当成「没有指定源」，一路回落到 0 号源——用户明明选了某个窗口，共享出去的却是
///   整个主屏（**实测于 Windows + flutter_webrtc 1.6.2**：选窗口拿到 1920×1080，
///   即整屏；用 `exact` 才是窗口自身的尺寸）。
/// * 帧率键名是 `mandatory.frameRate`（原生只认 double），不是 `maxFrameRate`：
///   后者原样落进媒体约束里，没有任何采集器读它。
Map<String, dynamic> screenShareConstraints({
  required String sourceId,
  required bool withSystemAudio,
  int maxHeight = 1080,
  int maxFps = 30,
}) {
  return <String, dynamic>{
    'audio': withSystemAudio
        ? <String, dynamic>{
            'mandatory': <String, dynamic>{'chromeMediaSource': 'desktop'},
          }
        : false,
    'video': <String, dynamic>{
      'deviceId': <String, dynamic>{'exact': sourceId},
      'mandatory': <String, dynamic>{
        'chromeMediaSource': 'desktop',
        'maxHeight': maxHeight,
        'frameRate': maxFps.toDouble(),
      },
    },
  };
}

/// 屏幕共享的画质档位。
///
/// 分辨率都跟着源的分辨率走（平台不允许「把超 1080p 的源压到 1080p」，见
/// [screenSendParameters] 的说明），档位之间差的是**帧率**，以及**带宽吃紧时保什么**。
///
/// 实测（1080p 高动态画面 + 本机 loopback，目标码率约 1.7 Mbps）：
/// * 保分辨率 → 1920×1080 但只有 **16~20fps**（游戏会卡成幻灯片）；
/// * 保帧率 → **54~55fps** 但掉到 480×270。
/// 两者不可兼得，所以高动态画面单独给一档让用户自己选。
enum ScreenShareQuality {
  /// 清晰：60fps，带宽不够时保分辨率。看文档、演示、静态界面。
  clear('清晰', 60, 8000000, RTCDegradationPreference.MAINTAIN_RESOLUTION),

  /// 游戏：60fps，带宽不够时保帧率、分辨率自适应。高动态画面优先流畅。
  game('游戏', 60, 10000000, RTCDegradationPreference.MAINTAIN_FRAMERATE),

  /// 流畅：30fps，保分辨率，上行带宽省一半。
  smooth('流畅', 30, 6000000, RTCDegradationPreference.MAINTAIN_RESOLUTION);

  const ScreenShareQuality(
    this.label,
    this.maxFps,
    this.maxBitrate,
    this.degradation,
  );

  /// 界面上的名字。
  final String label;

  /// 帧率上限。
  final int maxFps;

  /// 编码码率上限。**只是上限**，真实速率仍由带宽估计（BWE）决定
  /// （实测把上限从 8 Mbps 提到 16 Mbps 对上行走势没有影响）。
  final int maxBitrate;

  /// 带宽吃紧时的取舍：保分辨率还是保帧率。
  final RTCDegradationPreference degradation;

  /// 默认档：分辨率最稳，适合绝大多数共享场景。
  static const ScreenShareQuality fallback = ScreenShareQuality.clear;

  /// 采集时请求的分辨率上限（**只是请求**，见下）。
  static const int maxWidth = 1920;
  static const int maxHeight = 1080;

  /// 界面上的规格说明。
  ///
  /// 只写帧率不写分辨率：发出去的分辨率等于源的分辨率（不会低于 1080p，
  /// 超过 1080p 的源也不会被压下来），写成「1080p60」对超大源不准确。
  String get spec => '${maxFps}fps';

  /// 选中这档时的补充说明。
  String get detail => switch (this) {
    ScreenShareQuality.clear => '保分辨率，适合文档、演示、静态界面',
    ScreenShareQuality.game => '保帧率，高动态画面优先流畅（分辨率随带宽自适应）',
    ScreenShareQuality.smooth => '30fps，上行带宽省一半，保分辨率',
  };
}

/// 按档位生成屏幕共享的上行编码参数：**分辨率不许被自动缩小**（[ScreenShareQuality.game]
/// 是唯一例外，它主动选了「保帧率」，允许分辨率自适应）。
///
/// 两个坑（都实测过）：
/// * 默认的 `balanced` 降级策略在上行吃紧时先砍分辨率，实测直接把 1080p 掉到
///   480×270，共享出去的文字、表格全糊——所以要显式改掉策略；
/// * **没有「源超过 1080p 就压到 1080p」的档位**，因为这个平台做不到：采集约束
///   `maxHeight` 被 DXGI 采集完全忽略（请求 540 仍出 1920×1080）；编码参数
///   `scaleResolutionDownBy` 与 `maintain-resolution` 互斥（两种设置顺序都实测被忽略，
///   接收侧仍是 1920×1080），换成允许缩放的策略又会完全交给自适应。所以源超过 1080p
///   （4K 屏、超大窗口）时按原尺寸发送，代价是同样码率下更糊一些。
RTCRtpParameters screenSendParameters({
  ScreenShareQuality quality = ScreenShareQuality.fallback,
}) => RTCRtpParameters(
  encodings: <RTCRtpEncoding>[
    RTCRtpEncoding(
      maxBitrate: quality.maxBitrate,
      maxFramerate: quality.maxFps,
      scaleResolutionDownBy: 1.0,
    ),
  ],
  degradationPreference: quality.degradation,
);

/// 向原生要缩略图的请求参数。
///
/// 原生读的是 `sourceId` 与 `thumbnailSize`（后者目前被忽略，见下），
/// 缺任一个都会直接回 `Bad Arguments`。
Map<String, dynamic> desktopSourceThumbnailRequest({
  required String sourceId,
  int width = 320,
  int height = 180,
}) {
  return <String, dynamic>{
    'sourceId': sourceId,
    'thumbnailSize': <String, dynamic>{'width': width, 'height': height},
  };
}

/// 给缺缩略图的源逐个补图（拿不到的保持 null，界面显示占位图标）。
///
/// 为什么需要它：桌面端的 `getSources` **只返回 id 与标题、不带缩略图**
/// （Windows 与 macOS 的原生实现都是如此），图要再走一次
/// `getDesktopSourceThumbnail` 让原生现截一帧。原生会忽略请求里的尺寸，返回源自身
/// 分辨率的图（Windows 上是 JPEG，主屏约 100~250 KB），所以界面渲染时要靠
/// `cacheWidth` 缩小解码，别按原图铺。
///
/// 为什么要分轮重试：原生刚枚举完时窗口源还截不出图，**同一个请求在枚举返回的瞬间
/// 只有 1/10 有图，等约 100ms 再取就是 10/10**（实测于 Windows + flutter_webrtc
/// 1.6.2，连续 6 次枚举曲线一致：0ms → 1/10、50ms → 4/10、100ms → 10/10）。
/// 所以这里隔一小会儿把没拿到的再取一轮，而不是把失败直接当成「这个源没有图」。
///
/// [fetch] 是唯一的外部依赖（由 `MediaEngine` 接到方法通道上），单测可注入假实现。
/// [timeout] 是整个过程的总预算：个别源卡住或一直不出图时，用已有的结果打开选择器；
/// 在途请求自己会结束，结果被丢弃即可。
Future<List<ScreenSource>> attachScreenThumbnails(
  List<ScreenSource> sources, {
  required Future<Uint8List?> Function(String sourceId) fetch,
  Duration timeout = const Duration(seconds: 4),
  Duration retryDelay = const Duration(milliseconds: 150),
  int attempts = 3,
}) async {
  if (sources.isEmpty || sources.every((source) => source.thumbnail != null)) {
    return sources;
  }
  final deadline = DateTime.now().add(timeout);
  var filled = sources;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    filled = await _fetchMissingThumbnails(filled, fetch, deadline);
    if (filled.every((source) => source.thumbnail != null)) {
      break;
    }
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) {
      break;
    }
    await Future<void>.delayed(retryDelay < left ? retryDelay : left);
  }
  return filled;
}

/// 取一轮：只对还没有图的源发请求。
///
/// 串行而不是并发——原生那侧本来就是一张张现截（并发只是让它们挤在平台线程的队列
/// 里），串行反而能保住「一张卡住不影响其它」：每张只等剩余的预算，超时就跳过它。
Future<List<ScreenSource>> _fetchMissingThumbnails(
  List<ScreenSource> sources,
  Future<Uint8List?> Function(String sourceId) fetch,
  DateTime deadline,
) async {
  final result = <ScreenSource>[];
  for (final source in sources) {
    if (source.thumbnail != null) {
      result.add(source);
      continue;
    }
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) {
      result.add(source);
      continue;
    }
    try {
      final bytes = await _fetchWithin(fetch, source.id, left);
      result.add(
        bytes == null || bytes.isEmpty ? source : source.withThumbnail(bytes),
      );
    } on Object catch (error) {
      AppLog.debug('获取缩略图失败 id=${source.id}：$error');
      result.add(source);
    }
  }
  return result;
}

/// 单张取图的预算：到点返回 null，卡住的那次调用不会把选择器一起拖住。
///
/// 这里不用 `Future.timeout`：它的 `onTimeout` 参数在运行时会按**接收者的类型实参**
/// 校验（`Future<Uint8List>` 配 `() => null` 直接抛 TypeError），而 `fetch` 的返回
/// 类型是调用方决定的。自己起 Timer 补一个 null 更稳。
Future<Uint8List?> _fetchWithin(
  Future<Uint8List?> Function(String sourceId) fetch,
  String sourceId,
  Duration budget,
) async {
  final completer = Completer<Uint8List?>();
  final timer = Timer(budget, () {
    if (!completer.isCompleted) {
      completer.complete(null);
    }
  });
  unawaited(
    fetch(sourceId).then(
      (bytes) {
        if (!completer.isCompleted) {
          completer.complete(bytes);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) {
          completer.completeError(error, stack);
        }
      },
    ),
  );
  try {
    return await completer.future;
  } finally {
    timer.cancel();
  }
}
