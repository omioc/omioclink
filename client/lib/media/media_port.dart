import 'package:flutter/foundation.dart';

import 'media_engine.dart';
import 'media_models.dart';
import 'share_policy.dart';
import '../signaling/protocol.dart';
import '../room/peer_volume_controller.dart';

/// `RoomSession` 对媒体层的依赖端口。
///
/// 房间编排只依赖这个端口，因此可以在纯 Dart 单测里注入内存实现，
/// 不需要真的起 PeerConnection；`flutter_webrtc` 的一切细节都被挡在 [MediaEngine] 内。
abstract interface class MediaPort {
  /// 媒体事件回调（本地 SDP / 候选 / 连接状态 / 数据通道）。
  set callbacks(MediaEngineCallbacks? value);
  MediaEngineCallbacks? get callbacks;

  /// 本地麦克风的实时状态（电平 + 是否在说话）。
  ///
  /// 房间层监听它，把「我在说话」通过信令同步给其他成员。
  ValueListenable<MicLevel> get micLevel;

  /// 用服务器下发的 STUN 列表刷新 ICE 配置。
  void updateIceServers(List<String> servers);

  Future<void> startLocalAudio({String? deviceId});
  Future<void> stopLocalAudio();
  Future<void> setMicrophoneMuted(bool muted);
  Future<void> setSpeakerEnabled(bool enabled);
  Future<void> switchAudioInput(String deviceId);
  Future<void> switchAudioOutput(String deviceId);

  Future<void> startScreenShare({
    String? sourceId,
    bool withSystemAudio = false,
    SharePolicy policy = SharePolicy.fallback,
  });

  /// 本地是否正在采集屏幕。
  ///
  /// 「我对服务器上报的共享状态」与界面都以它为准：服务端的记录可能落后于本地
  /// （见 `RoomSession` 里对共享状态的纠偏），真正的事实只有本机有没有在采。
  bool get isScreenSharing;
  Future<void> stopScreenShare();

  Future<void> ensurePeer(
    String peerId, {
    required bool polite,
    bool createDataChannel = false,
  });
  Future<void> negotiate(String peerId, {bool iceRestart = false});
  Future<void> handleRemoteOffer(String peerId, String sdp);
  Future<void> handleRemoteAnswer(String peerId, String sdp);
  Future<void> handleRemoteCandidate(
    String peerId,
    IceCandidatePayload? candidate,
  );
  Future<void> restartIce(String peerId);
  Future<void> closePeer(String peerId);
  Future<void> closeAllPeers();

  /// 本地屏蔽 / 恢复某成员的声音（只影响本机播放，对方无感知）。
  Future<void> setPeerAudioMuted(String peerId, bool muted);

  /// 设置某成员在本机的音量（0~2，100% = 1.0；0 即静音）。
  ///
  /// 与 [setPeerAudioMuted] 并联：任一为「静音」就静音，恢复后按音量倍率播放。
  Future<void> setPeerAudioVolume(String peerId, double gain);

  /// 向所有已连通的数据通道广播文本（P2P 聊天），返回成功写入的通道数。
  int broadcastData(String payload);

  Future<PeerStatsSnapshot?> statsFor(String peerId);

  Future<void> dispose();
}

/// 把 [MediaEngine] 适配为 [MediaPort]。
class EngineMediaPort implements MediaPort {
  EngineMediaPort(this.engine);

  final MediaEngine engine;

  @override
  MediaEngineCallbacks? get callbacks => engine.callbacks;

  @override
  set callbacks(MediaEngineCallbacks? value) => engine.callbacks = value;

  @override
  ValueListenable<MicLevel> get micLevel => engine.micLevel;

  @override
  void updateIceServers(List<String> servers) =>
      engine.updateIceServers(servers);

  @override
  Future<void> startLocalAudio({String? deviceId}) =>
      engine.startLocalAudio(deviceId: deviceId);

  @override
  Future<void> stopLocalAudio() => engine.stopLocalAudio();

  @override
  Future<void> setMicrophoneMuted(bool muted) =>
      engine.setMicrophoneMuted(muted);

  @override
  Future<void> setSpeakerEnabled(bool enabled) =>
      engine.setSpeakerEnabled(enabled);

  @override
  Future<void> switchAudioInput(String deviceId) =>
      engine.switchAudioInput(deviceId);

  @override
  Future<void> switchAudioOutput(String deviceId) =>
      engine.switchAudioOutput(deviceId);

  @override
  Future<void> startScreenShare({
    String? sourceId,
    bool withSystemAudio = false,
    SharePolicy policy = SharePolicy.fallback,
  }) => engine.startScreenShare(
    sourceId: sourceId,
    withSystemAudio: withSystemAudio,
    policy: policy,
  );

  @override
  Future<void> stopScreenShare() => engine.stopScreenShare();

  @override
  bool get isScreenSharing => engine.isScreenSharing;

  @override
  Future<void> ensurePeer(
    String peerId, {
    required bool polite,
    bool createDataChannel = false,
  }) => engine.ensurePeer(
    peerId,
    polite: polite,
    createDataChannel: createDataChannel,
  );

  @override
  Future<void> negotiate(String peerId, {bool iceRestart = false}) =>
      engine.negotiate(peerId, iceRestart: iceRestart);

  @override
  Future<void> handleRemoteOffer(String peerId, String sdp) =>
      engine.handleRemoteOffer(peerId, sdp);

  @override
  Future<void> handleRemoteAnswer(String peerId, String sdp) =>
      engine.handleRemoteAnswer(peerId, sdp);

  @override
  Future<void> handleRemoteCandidate(
    String peerId,
    IceCandidatePayload? candidate,
  ) => engine.handleRemoteCandidate(peerId, candidate);

  @override
  Future<void> restartIce(String peerId) => engine.restartIce(peerId);

  @override
  Future<void> closePeer(String peerId) => engine.closePeer(peerId);

  @override
  Future<void> closeAllPeers() => engine.closeAllPeers();

  @override
  Future<void> setPeerAudioMuted(String peerId, bool muted) =>
      engine.setPeerAudioMuted(peerId, muted);

  @override
  Future<void> setPeerAudioVolume(String peerId, double gain) =>
      engine.setPeerAudioVolume(peerId, gain);

  @override
  int broadcastData(String payload) => engine.broadcastData(payload);

  @override
  Future<PeerStatsSnapshot?> statsFor(String peerId) => engine.statsFor(peerId);

  @override
  Future<void> dispose() => engine.dispose();
}

/// 把 [MediaPort] 适配成 `PeerVolumeController` 需要的音量端口。
class MediaPortPeerAudioSink implements PeerAudioSink {
  const MediaPortPeerAudioSink(this._port);

  final MediaPort _port;

  @override
  Future<void> setPeerGain(String peerId, double gain) =>
      _port.setPeerAudioVolume(peerId, gain);

  @override
  Future<void> setPeerMuted(String peerId, bool muted) =>
      _port.setPeerAudioMuted(peerId, muted);
}
