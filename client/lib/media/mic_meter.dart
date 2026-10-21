import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_log.dart';
import 'media_models.dart';

/// 周期采样本地麦克风电平，并判定「是否在说话」。
///
/// 判定用**双阈值 + 保持时间**（滞回），否则电平在阈值附近抖动时绿灯会疯狂闪烁：
/// * 电平升到 [speechThreshold] 以上 → 立刻算说话，并把保持期推到 `now + holdDuration`；
/// * 电平落到 [releaseThreshold] 以下，且保持期已过 → 结束说话；
/// * 两者之间 → 维持当前状态（这段区间就是「滞回带」）。
///
/// 采样失败（拿不到电平，例如还没建连）时**保持上一次判定**，不把绿灯闪掉。
class MicLevelMeter extends ValueNotifier<MicLevel> {
  MicLevelMeter({
    required this.sampler,
    // 采样周期：200ms 足够跟得上说话起伏，而 100ms 时代每次都要 getStats + 通知，
    // 电平条动画几乎全天在跑（应用回不到空闲帧）。
    this.interval = const Duration(milliseconds: 200),
    this.speechThreshold = 0.02,
    this.releaseThreshold = 0.008,
    this.holdDuration = const Duration(milliseconds: 400),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       super(const MicLevel());

  /// 取一次原始电平（0..1）；返回 null 表示这次拿不到（不算「安静」）。
  final Future<double?> Function() sampler;

  /// 采样周期。电平条要跟得上说话，100ms 是流畅度与开销的折中。
  final Duration interval;

  /// 判定为说话的电平阈值。
  final double speechThreshold;

  /// 结束说话的电平阈值（必须小于 [speechThreshold]，构成滞回带）。
  final double releaseThreshold;

  /// 停止说话的最短保持时间。
  final Duration holdDuration;

  final DateTime Function() _clock;

  Timer? _timer;
  bool _busy = false;
  bool _capturing = false;
  String? _error;
  DateTime? _holdUntil;

  /// 麦克风轨道是否已就绪。
  bool get capturing => _capturing;

  /// 启动周期采样（重复调用无副作用）。
  void start() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 由引擎更新采集状态（轨道建立/释放、采集报错）。
  void updateCaptureState({required bool capturing, String? error}) {
    _capturing = capturing;
    _error = error;
    if (!capturing) {
      _holdUntil = null;
    }
    _publish(value.level, speaking: capturing && value.speaking);
  }

  /// 同步静音状态。静音时立即结束说话状态，不必等保持期。
  void setMuted(bool muted) {
    if (value.muted != muted) {
      value = value.copyWith(muted: muted);
    }
    if (muted) {
      _holdUntil = null;
      _publish(0, speaking: false);
      return;
    }
    _publish(value.level, speaking: value.speaking);
  }

  Future<void> _tick() async {
    // 上一次统计还没返回时不叠加：getStats 可能比采样周期慢
    if (_busy) {
      return;
    }
    _busy = true;
    try {
      final level = await sampler();
      ingest(level, at: _clock());
    } on Object catch (error) {
      AppLog.debug('读取麦克风电平失败：$error');
    } finally {
      _busy = false;
    }
  }

  /// 喂入一次采样结果。
  ///
  /// 抽成公开的纯函数入口，单测可以直接驱动它，不必依赖真实定时器与真实音频设备。
  void ingest(double? level, {required DateTime at}) {
    _publish(level, speaking: _decideSpeaking(level, at));
  }

  bool _decideSpeaking(double? level, DateTime at) {
    if (value.muted || !_capturing) {
      _holdUntil = null;
      return false;
    }
    if (level == null) {
      // 拿不到电平（还没建连等）：维持上一次判定，别把绿灯闪掉
      return value.speaking;
    }
    if (level >= speechThreshold) {
      _holdUntil = at.add(holdDuration);
      return true;
    }
    if (!value.speaking) {
      return false;
    }
    // 正在说话：只有真的安静下来且保持期已过才结束
    final until = _holdUntil;
    if (level < releaseThreshold && (until == null || !at.isBefore(until))) {
      _holdUntil = null;
      return false;
    }
    return true;
  }

  void _publish(double? level, {required bool speaking}) {
    // ValueNotifier 内部用 == 去重：电平没变（例如静音时）不会触发无谓重建
    value = MicLevel(
      level: (level ?? value.level).clamp(0.0, 1.0),
      speaking: speaking,
      muted: value.muted,
      capturing: _capturing,
      error: _error,
    );
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
