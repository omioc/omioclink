import 'dart:math';
import 'dart:typed_data';

/// 麦克风的实时状态：电平 + 是否在说话 + 采集是否可用。
///
/// 这是「麦克风是否有效」的唯一事实来源：界面上的绿灯、电平条、状态文案
/// 全部由它派生，避免各处各自判断音量而出现不一致。
class MicLevel {
  const MicLevel({
    this.level = 0,
    this.speaking = false,
    this.muted = false,
    this.capturing = false,
    this.error,
  });

  /// 原始线性电平 0..1（WebRTC 统计里的 `audioLevel`）。
  final double level;

  /// 是否判定为「正在说话」（带滞回，见 `MicLevelMeter`）。
  final bool speaking;

  final bool muted;

  /// 是否已拿到本地麦克风轨道。
  final bool capturing;

  /// 采集失败原因（无设备 / 无权限等），正常时为 null。
  final String? error;

  /// 麦克风本身是否可用：已采集且没有错误。与是否静音、是否有声音无关。
  bool get healthy => capturing && error == null;

  /// 界面展示用的 0..1 值：按 dBFS 映射（-60dB 记为 0），
  /// 否则小音量时条子几乎不动，看起来像坏的。
  double get display {
    if (level <= 0) {
      return 0;
    }
    final dbfs = 20 * (log(level) / ln10);
    return ((dbfs + 60) / 60).clamp(0.0, 1.0);
  }

  /// 状态文案（直接展示给用户）。
  String get statusText {
    final failure = error;
    if (failure != null) {
      return failure;
    }
    if (!capturing) {
      return '麦克风未启动';
    }
    if (muted) {
      return '已静音';
    }
    if (speaking) {
      return '正在说话';
    }
    return '麦克风正常 · 未检测到语音';
  }

  MicLevel copyWith({
    double? level,
    bool? speaking,
    bool? muted,
    bool? capturing,
    String? error,
    bool clearError = false,
  }) => MicLevel(
    level: level ?? this.level,
    speaking: speaking ?? this.speaking,
    muted: muted ?? this.muted,
    capturing: capturing ?? this.capturing,
    error: clearError ? null : (error ?? this.error),
  );

  @override
  bool operator ==(Object other) =>
      other is MicLevel &&
      other.level == level &&
      other.speaking == speaking &&
      other.muted == muted &&
      other.capturing == capturing &&
      other.error == error;

  @override
  int get hashCode => Object.hash(level, speaking, muted, capturing, error);

  @override
  String toString() =>
      'MicLevel(level=${level.toStringAsFixed(4)}, speaking=$speaking, '
      'muted=$muted, capturing=$capturing, error=$error)';
}

/// 屏幕/窗口捕获源。
class ScreenSource {
  const ScreenSource({
    required this.id,
    required this.name,
    required this.isWindow,
    this.thumbnail,
  });

  final String id;
  final String name;
  final bool isWindow;
  final Uint8List? thumbnail;

  /// 补上缩略图（枚举时原生不带图，见 `attachScreenThumbnails`）。
  ScreenSource withThumbnail(Uint8List? bytes) => ScreenSource(
    id: id,
    name: name,
    isWindow: isWindow,
    thumbnail: bytes,
  );
}

/// 音频输入 / 输出设备。
class AudioDevice {
  const AudioDevice({
    required this.deviceId,
    required this.label,
    required this.isInput,
  });

  final String deviceId;
  final String label;
  final bool isInput;

  String get displayName =>
      label.isNotEmpty ? label : (isInput ? '默认麦克风' : '默认扬声器');
}

/// 一条 P2P 连接的状态（对 flutter_webrtc 枚举的薄映射，UI 不直接依赖原生类型）。
enum PeerLinkState {
  idle,
  connecting,
  connected,
  disconnected,
  failed,
  closed;

  bool get isLive => this == PeerLinkState.connected;

  String get label => switch (this) {
    PeerLinkState.idle => '未连接',
    PeerLinkState.connecting => '连接中',
    PeerLinkState.connected => '已直连',
    PeerLinkState.disconnected => '连接中断',
    PeerLinkState.failed => '无法直连',
    PeerLinkState.closed => '已关闭',
  };
}

/// 单条连接的 getStats 摘要。
class PeerStatsSnapshot {
  const PeerStatsSnapshot({
    this.bytesSent,
    this.bytesReceived,
    this.localCandidateType,
    this.remoteCandidateType,
    this.roundTripTimeMs,
    this.packetsLost,
  });

  final int? bytesSent;
  final int? bytesReceived;

  /// host / srflx / relay / prflx —— 当前这条连接实际使用的候选类型。
  final String? localCandidateType;
  final String? remoteCandidateType;
  final double? roundTripTimeMs;
  final int? packetsLost;

  /// 把候选类型翻译成用户能看懂的连接路径描述。
  String get pathDescription {
    final local = localCandidateType;
    if (local == null) {
      return '尚未建立连接';
    }
    if (local == 'host') {
      return '局域网直连';
    }
    if (local == 'srflx' || local == 'prflx') {
      return '公网打洞直连';
    }
    if (local == 'relay') {
      return '中继转发（异常：服务器不应提供中继）';
    }
    return '连接方式：$local';
  }

  @override
  String toString() =>
      'PeerStatsSnapshot(sent=$bytesSent, recv=$bytesReceived, local=$localCandidateType, '
      'remote=$remoteCandidateType, rtt=$roundTripTimeMs, lost=$packetsLost)';
}

/// 由媒体层抛出、可直接展示给用户的错误。
class MediaException implements Exception {
  const MediaException(this.message, {this.code = 'media_error'});

  final String code;
  final String message;

  @override
  String toString() => message;
}
