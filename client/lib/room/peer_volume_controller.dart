import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_log.dart';
import '../data/volume_store.dart';

/// 把「某成员该多大声」落到实际音轨上的端口。
///
/// 真实实现见 `MediaPortPeerAudioSink`（转给 `MediaPort` → `MediaEngine` 的音量状态机），
/// 单测里换成记录调用的假实现。
abstract interface class PeerAudioSink {
  /// 设置某成员的音量倍率（0~2）。0 由实现方转成确定性静音。
  Future<void> setPeerGain(String peerId, double gain);

  /// 本地静音开关（只影响本机听感）。
  Future<void> setPeerMuted(String peerId, bool muted);
}

/// 什么都不做的端口（房间外/测试里当默认值用）。
class NoopPeerAudioSink implements PeerAudioSink {
  const NoopPeerAudioSink();

  @override
  Future<void> setPeerGain(String peerId, double gain) async {}

  @override
  Future<void> setPeerMuted(String peerId, bool muted) async {}
}

/// 房间成员音量：**按成员的服务器身份（userId）记住**，只作用于本机听感。
///
/// 职责分工：
/// * 本类管「谁是多少」+ 持久化（`userId → 0~2`），以及 peerId ↔ userId 的对应；
/// * 真正的落地（钳制、迟到音轨、音量 0 的确定性静音）在 `PeerAudioMixer`（引擎层）；
/// * 服务器、信令、对方客户端一概不参与——音量纯本机行为。
///
/// 音量不随房间走：换个房间，同一个人还是我上次调的那个音量。
class PeerVolumeController extends ChangeNotifier {
  PeerVolumeController({this.sink = const NoopPeerAudioSink(), VolumeStore? store})
    : _store = store ?? VolumeStore();

  /// 落地端口：把音量交给引擎的音量状态机。
  final PeerAudioSink sink;

  /// 本机存储（成员音量：`userId → 0~2`）。
  final VolumeStore _store;

  /// `userId → 音量倍率`（0~2）。
  final Map<String, double> _byUser = <String, double>{};

  /// `peerId → userId`（peerId 是这一次会话里的传输身份，会变；userId 不会）。
  final Map<String, String> _peerToUser = <String, String>{};

  bool _loaded = false;
  bool _disposed = false;

  /// 是否已经从磁盘读过了（没读过时所有成员都按默认 100%）。
  bool get isLoaded => _loaded;

  /// 某成员当前的音量倍率（0~2，没设置过 = 1.0）。
  double volumeOf(int userId) =>
      _byUser['$userId'] ?? VolumeStore.defaultPeerVolume;

  /// 某成员当前的音量百分比（0~200，界面直接用）。
  double percentOf(int userId) => volumeOf(userId) * 100;

  /// 读出所有保存过的成员音量。
  ///
  /// 幂等：进房、重连都可以再调一次；已经绑定过的成员会立刻按读到的值重放一遍。
  Future<void> load() async {
    Map<String, double> saved;
    try {
      saved = await _store.loadPeerVolumes();
    } on Object catch (error) {
      // 存储坏了不是致命错误：全部回落默认，界面照常可用
      AppLog.warn('读取成员音量失败，按默认 100% 处理', error: error);
      saved = <String, double>{};
    }
    _byUser
      ..clear()
      ..addAll(saved);
    _loaded = true;
    for (final entry in _peerToUser.entries) {
      final volume = _byUser[entry.value];
      if (volume != null) {
        await sink.setPeerGain(entry.key, volume);
      }
    }
    _notify();
  }

  /// 绑定一名成员（进房 / 建连时调用）。
  ///
  /// 此刻远端音轨通常还没到，音量会先记在引擎的音量状态机里；
  /// 等音轨真正到达时由状态机按这个值生效。
  Future<void> bindPeer({required String peerId, required int userId}) async {
    _peerToUser[peerId] = '$userId';
    await sink.setPeerGain(peerId, volumeOf(userId));
  }

  /// 设置某成员音量。[volume] 是 0~2 的倍率，越界会被钳制。
  Future<void> setVolume({
    required String peerId,
    required int userId,
    required double volume,
  }) async {
    final next = VolumeStore.clampPeerVolume(volume);
    final key = '$userId';
    final changed = _byUser[key] != next;
    _byUser[key] = next;
    _peerToUser[peerId] = key;
    if (changed) {
      _notify();
      unawaited(_persist());
    }
    await sink.setPeerGain(peerId, next);
  }

  /// 滑块直接调它：百分比（0~200）版本。
  Future<void> setPercent({
    required String peerId,
    required int userId,
    required double percent,
  }) => setVolume(peerId: peerId, userId: userId, volume: percent / 100);

  /// 本地静音开关（与音量并联：音量 0 等价静音）。
  Future<void> setMuted(String peerId, bool muted) =>
      sink.setPeerMuted(peerId, muted);

  /// 成员真的离开了：忘掉这条 peerId 映射（保存过的 userId 音量继续留着）。
  void releasePeer(String peerId) {
    _peerToUser.remove(peerId);
  }

  /// 离开房间：清空运行时映射（持久化的偏好保留，下次进房继续用）。
  void clear() {
    _peerToUser.clear();
    _notify();
  }

  Future<void> _persist() async {
    try {
      await _store.savePeerVolumes(_byUser);
    } on Object catch (error) {
      AppLog.warn('保存成员音量失败', error: error);
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
