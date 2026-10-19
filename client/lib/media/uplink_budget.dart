import 'dart:math' as math;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'share_policy.dart';

/// 屏幕共享可用的上行总预算（bps）。
///
/// 30 Mbps 的硬上限里留 2 Mbps 给麦克风、RTP 头和 BWE 探测 padding：稳态贴着上限
/// 打，先撞到的是路由器缓冲和网卡队列，而不是编码器。
const int kDefaultScreenUplinkBudgetBps = 28000000;

/// 预算再怎么削也留一个能编码的下限，免得除零与负数把分配器带崩。
const int _minBudgetBps = 500000;

/// 单路屏幕视频的编码目标。
///
/// 由 [allocateScreenPlan] 逐成员算出，[screenSendParameters] 把它翻译成
/// `RTCRtpParameters` 交给 `sender.setParameters`。
class ScreenTarget {
  const ScreenTarget({
    required this.maxBitrate,
    required this.minBitrate,
    required this.maxFramerate,
    required this.scaleResolutionDownBy,
    required this.degradation,
    required this.targetWidth,
    required this.targetHeight,
    this.active = true,
  });

  /// 码率上限（bps）。
  final int maxBitrate;

  /// 码率下限（bps）。
  ///
  /// 只设上限抬不动实速——实测把上限从 8 Mbps 提到 16 Mbps，上行走势没有任何变化
  /// （见 `screen_capture.dart` 里的说明）。必须同时逼住编码器，它才真的会花出去。
  final int minBitrate;

  /// 帧率上限。
  final int maxFramerate;

  /// 编码前的缩放倍数（1.0 = 按源分辨率发）。
  final double scaleResolutionDownBy;

  /// 带宽吃紧时保谁。
  final RTCDegradationPreference degradation;

  /// 缩放之后实际发出去的宽高（源更窄时不放大，此时等于源宽高）。
  final int targetWidth;
  final int targetHeight;

  /// 是否继续发送。本期恒为 true，留给「没在看的人停发」这一步。
  final bool active;

  /// 是否按源分辨率发送（没有降分辨率）。
  bool get keepsSourceResolution => scaleResolutionDownBy <= 1.0;

  /// 日志、诊断面板用的一行摘要。
  String get label =>
      '$targetWidth×$targetHeight@${maxFramerate}fps '
      '${(maxBitrate / 1000000).toStringAsFixed(1)}Mbps';
}

/// 分配器的输入。
class ScreenBudgetInput {
  const ScreenBudgetInput({
    required this.policy,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.peerIds,
    this.budgetBps = kDefaultScreenUplinkBudgetBps,
    this.primaryPeerId,
  });

  /// 用户选的档位。
  final SharePolicy policy;

  /// 可用的上行总预算（bps）。
  final int budgetBps;

  /// 采集源的分辨率（DXGI 给多少就是多少，它不认采集约束里的 maxHeight）。
  final int sourceWidth;
  final int sourceHeight;

  /// 房间内其他成员（观众），不含自己。分配结果按这个顺序逐项给出。
  final List<String> peerIds;

  /// 主看人：拿双倍权重。
  ///
  /// 本期恒为 null——观众侧还没上报「谁在全屏看」。接上之后这一位拿原画，其余人
  /// 平分剩下的预算（3 个观众 + 主看人 = 2K60 一路 + 1080p60 两路）。
  final String? primaryPeerId;
}

/// 一档编码目标的模板。
///
/// [longEdge] 是目标长边（null = 不缩放，直接用源分辨率），[framerate] 是帧率。
/// [needKbps] 是「良好观感」所需的码率，[floorKbps] 是「低于这个就不选这一档」的地板。
class _Tier {
  const _Tier({
    this.longEdge,
    required this.framerate,
    required this.needKbps,
    required this.floorKbps,
  });

  final int? longEdge;
  final int framerate;
  final int needKbps;
  final int floorKbps;
}

// 三个档位的候选表，**按优先级从上到下**：分配器取第一个地板够得着的。
//
// 数字是初值，按「至少 H.264 这一档的编码效率」估的，需要实测后回填：同一分辨率
// 帧率下，VP8 大约要多花 50%，AV1 大约能省 30%（`getStats` 里的 `编码=` 能看到
// 实际协商到的是哪一个）。校准方法见规划里的验收标准。
//
// 帧率一列全部 ≥30：投屏游戏是主场景，掉到 30 以下就不可接受了。

const List<_Tier> _fpsFirstTiers = <_Tier>[
  _Tier(framerate: 60, needKbps: 16000, floorKbps: 10000),
  _Tier(longEdge: 1920, framerate: 60, needKbps: 8500, floorKbps: 5500),
  _Tier(longEdge: 1280, framerate: 60, needKbps: 4000, floorKbps: 2500),
];

const List<_Tier> _resolutionFirstTiers = <_Tier>[
  _Tier(framerate: 60, needKbps: 15000, floorKbps: 10000),
  _Tier(framerate: 30, needKbps: 6000, floorKbps: 3500),
  _Tier(longEdge: 1920, framerate: 60, needKbps: 8000, floorKbps: 5000),
  _Tier(longEdge: 1920, framerate: 30, needKbps: 2500, floorKbps: 1800),
];

const List<_Tier> _balancedTiers = <_Tier>[
  _Tier(framerate: 60, needKbps: 13000, floorKbps: 10000),
  _Tier(framerate: 30, needKbps: 8000, floorKbps: 4500),
  _Tier(longEdge: 1920, framerate: 60, needKbps: 7000, floorKbps: 4500),
  _Tier(longEdge: 1920, framerate: 30, needKbps: 3000, floorKbps: 2000),
];

/// 按档位与观众数，把上行预算切成每一路的具体编码参数。
///
/// 纯函数：不碰 PeerConnection、不读时钟，同样的输入永远得到同样的输出，因此可以
/// 在纯 Dart 单测里跑完整的观众数矩阵。
///
/// 权重规则：
/// * 有 [ScreenBudgetInput.primaryPeerId] 时，主看人占 2 份、其余各 1 份；
/// * 没有主看人时人人 1 份（均分）。
///
/// 任何情况下 `Σ maxBitrate ≤ budgetBps`，且分辨率不低于 720p、帧率不低于 30fps。
Map<String, ScreenTarget> allocateScreenPlan(ScreenBudgetInput input) {
  final peers = input.peerIds;
  if (peers.isEmpty) {
    return const <String, ScreenTarget>{};
  }

  final budget = input.budgetBps < _minBudgetBps ? _minBudgetBps : input.budgetBps;
  final primary = input.primaryPeerId;
  final hasPrimary = primary != null && peers.contains(primary);
  final units = hasPrimary ? peers.length + 1 : peers.length;
  final perUnit = budget ~/ units;

  final tiers = _tiersFor(input.policy);
  final degradation = _degradationFor(input.policy);

  final plan = <String, ScreenTarget>{};
  for (final peerId in peers) {
    final share = hasPrimary && peerId == primary ? perUnit * 2 : perUnit;
    plan[peerId] = _targetFor(
      tier: _pickTier(tiers, share),
      shareBps: share,
      degradation: degradation,
      input: input,
    );
  }
  return plan;
}

/// 取第一个地板够得着的档位。
///
/// 连最低一档都够不到时（观众多到极端），退到地板最低的那档：宁可糊，也不把分辨率
/// 或帧率打到地板以下——那才是投屏游戏真正不能接受的。
_Tier _pickTier(List<_Tier> tiers, int shareBps) {
  for (final tier in tiers) {
    if (shareBps >= tier.floorKbps * 1000) {
      return tier;
    }
  }
  return tiers.reduce((a, b) => a.floorKbps <= b.floorKbps ? a : b);
}

ScreenTarget _targetFor({
  required _Tier tier,
  required int shareBps,
  required RTCDegradationPreference degradation,
  required ScreenBudgetInput input,
}) {
  final sourceLongEdge = math.max(input.sourceWidth, input.sourceHeight);
  final tierLongEdge = tier.longEdge == null
      ? sourceLongEdge
      : math.min(tier.longEdge!, sourceLongEdge);
  // tierLongEdge 恒 ≤ 源长边，所以 scale 恒 ≥ 1.0：分配器只降不升，绝不放大画面。
  final scale = sourceLongEdge / tierLongEdge;

  final needBps = tier.needKbps * 1000;
  // 上限取「分到的额度」与「需求 1.5 倍」的较小者：一个人看时给到需求就很够，
  // 再往上给只会让编码器把比特扔进无意义的量化精度里。
  final maxBitrate = math.min(shareBps, needBps * 3 ~/ 2);
  final minBitrate = math.min(maxBitrate, needBps * 3 ~/ 5);

  return ScreenTarget(
    maxBitrate: maxBitrate,
    minBitrate: minBitrate,
    maxFramerate: tier.framerate,
    scaleResolutionDownBy: scale,
    degradation: degradation,
    targetWidth: (input.sourceWidth / scale).round(),
    targetHeight: (input.sourceHeight / scale).round(),
  );
}

List<_Tier> _tiersFor(SharePolicy policy) => switch (policy) {
  SharePolicy.fpsFirst => _fpsFirstTiers,
  SharePolicy.resolutionFirst => _resolutionFirstTiers,
  SharePolicy.balanced => _balancedTiers,
};

/// 带宽吃紧时先牺牲谁。
///
/// 均衡档先按「保分辨率」给——它只在预算真的不够时才降帧率，而预算由
/// [allocateScreenPlan] 按地板保证过，正常不会触发。真正的自动取舍留给
/// `ScreenPolicyGovernor`（按画面内容在两种极端之间显式切换）。
RTCDegradationPreference _degradationFor(SharePolicy policy) => switch (policy) {
  SharePolicy.fpsFirst => RTCDegradationPreference.MAINTAIN_FRAMERATE,
  SharePolicy.resolutionFirst => RTCDegradationPreference.MAINTAIN_RESOLUTION,
  SharePolicy.balanced => RTCDegradationPreference.MAINTAIN_RESOLUTION,
};
