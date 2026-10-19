import '../core/app_log.dart';

/// 远端成员音频的播放设备端口。
///
/// 真实实现由 `MediaEngine` 提供（包住该成员收到的音频轨 + 渲染器），
/// 单测里换成记录调用的假实现——「按成员调音量」这件事的**状态机在
/// [PeerAudioMixer] 里**，所以能脱离 WebRTC 单测。
abstract interface class PeerAudioDevice {
  /// 音轨 `enabled`。libwebrtc 语义里这就是静音：false 时不再把音频送去播放。
  Future<void> setTrackEnabled(bool enabled);

  /// 渲染器是否绑定音频流（解绑 = 彻底不播，比单纯禁轨更「确定性」）。
  Future<void> setRendererBound(bool bound);

  /// 下发原生增益（0~2，>1 表示放大）。失败靠返回值传达，不要抛。
  Future<PeerGainAck> setGain(double gain);
}

/// 原生增益调用的结果（界面上不看，日志里要看得见「成功/错误码」）。
class PeerGainAck {
  const PeerGainAck.ok() : success = true, error = null;

  const PeerGainAck.failed(this.error) : success = false;

  final bool success;

  /// 失败原因（含平台错误码），成功时为 null。
  final String? error;

  @override
  String toString() => success ? 'ok' : '失败：${error ?? '未知错误'}';
}

/// 每个成员的远端音频状态机：把「音量倍率 + 本地静音」翻译成实际操作。
///
/// 三条音量通道里，这里只管**别人说话的音量**：
/// * `gain` 是 0~2 的倍率（100% = 1.0），越界会被钳制；
/// * `gain == 0` 或本地静音时走**确定性静音**：音轨 `enabled = false`
///   **并且**解绑渲染器，双保险，不依赖任何音量语义；
/// * 恢复（`gain > 0` 且未静音）时重新绑渲染器、开轨、下发增益。
///
/// 一个重要的时序细节：音量可以在**音轨到达之前**就设好（成员列表比 P2P 连接先出现），
/// 所以状态在这里独立保存，[attach] 时按已保存的值应用一次——这就是「迟到的音轨」。
class PeerAudioMixer {
  PeerAudioMixer();

  /// 默认增益（100%）。
  static const double defaultGain = 1.0;

  /// 增益下限：0 = 静音。
  static const double minGain = 0;

  /// 增益上限：200%。
  static const double maxGain = 2;

  /// 把任意输入收敛成合法增益（非数/NaN/无穷回落默认，越界钳制）。
  static double clampGain(double value) {
    if (value.isNaN || value.isInfinite) {
      return defaultGain;
    }
    return value.clamp(minGain, maxGain).toDouble();
  }

  final Map<String, _PeerAudioState> _states = <String, _PeerAudioState>{};

  /// 某成员当前的增益（没设过 = 100%）。
  double gainOf(String peerId) => _states[peerId]?.gain ?? defaultGain;

  /// 某成员当前是否处于「本地不听」状态（静音开关或音量 0）。
  bool isSilenced(String peerId) => _states[peerId]?.silenced ?? false;

  /// 设置成员音量（钳制到 [minGain]~[maxGain]），立即生效。
  Future<void> setGain(String peerId, double gain) async {
    final state = _states.putIfAbsent(peerId, _PeerAudioState.new);
    final next = clampGain(gain);
    if (state.gain == next) {
      return;
    }
    state.gain = next;
    await _apply(peerId, state);
  }

  /// 本地静音开关（与增益叠加：任一为静音即静音）。
  Future<void> setMuted(String peerId, bool muted) async {
    final state = _states.putIfAbsent(peerId, _PeerAudioState.new);
    if (state.muted == muted) {
      return;
    }
    state.muted = muted;
    await _apply(peerId, state);
  }

  /// 远端音频轨到达（或重连后重新到达）：记下设备，并按已保存的音量/静音应用一次。
  Future<void> attach(String peerId, PeerAudioDevice device) async {
    final state = _states.putIfAbsent(peerId, _PeerAudioState.new);
    state.device = device;
    // 新设备上一轮的开关状态是未知的，强制重新下发
    state.trackEnabled = null;
    state.rendererBound = null;
    state.appliedGain = null;
    await _apply(peerId, state);
  }

  /// 连接关闭（对端重连时还会再来一条音轨）：只解绑设备，**保留**音量/静音状态，
  /// 这样重连后的新音轨（[attach]）能立刻按之前设置的值播放。
  ///
  /// 设备侧正在被拆，这里不再回调它，避免往已释放的渲染器上写东西。
  void detach(String peerId) {
    final state = _states[peerId];
    if (state == null) {
      return;
    }
    state.device = null;
    state.trackEnabled = null;
    state.rendererBound = null;
    state.appliedGain = null;
  }

  /// 成员离开房间：连同音量状态一起丢掉，不残留任何影响。
  void forget(String peerId) {
    _states.remove(peerId);
  }

  /// 清空所有成员状态（离开房间时用）。
  void clear() {
    _states.clear();
  }

  Future<void> _apply(String peerId, _PeerAudioState state) async {
    final device = state.device;
    if (device == null) {
      // 音轨还没到：状态先记着，attach 时再落地
      return;
    }
    final silenced = state.silenced;
    try {
      if (silenced) {
        // 确定性静音：禁轨 + 解绑渲染器，两条路都断掉
        if (state.trackEnabled != false) {
          await device.setTrackEnabled(false);
          state.trackEnabled = false;
        }
        if (state.rendererBound != false) {
          await device.setRendererBound(false);
          state.rendererBound = false;
        }
        return;
      }
      if (state.rendererBound != true) {
        await device.setRendererBound(true);
        state.rendererBound = true;
      }
      if (state.trackEnabled != true) {
        await device.setTrackEnabled(true);
        state.trackEnabled = true;
      }
      if (state.appliedGain != state.gain) {
        final ack = await device.setGain(state.gain);
        if (ack.success) {
          state.appliedGain = state.gain;
        } else {
          AppLog.warn(
            '设置成员音量失败 peer=$peerId '
            '音量=${(state.gain * 100).round()}% ${ack.error ?? ''}',
          );
        }
      }
    } on Object catch (error) {
      AppLog.warn('应用成员音量失败 peer=$peerId', error: error);
    }
  }
}

class _PeerAudioState {
  double gain = PeerAudioMixer.defaultGain;
  bool muted = false;

  /// 已成功下发的原生增益（用于跳过重复调用）。
  double? appliedGain;
  bool? trackEnabled;
  bool? rendererBound;
  PeerAudioDevice? device;

  bool get silenced => muted || gain <= PeerAudioMixer.minGain;
}
