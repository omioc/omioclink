import 'package:flutter/foundation.dart';

/// 一名成员的实时电平。
class PeerLevel {
  const PeerLevel({
    this.level = 0,
    this.speaking = false,
    this.measured = false,
  });

  /// 0..1 的展示值（发送方已按 dBFS 映射，见 `MicLevel.display`）。
  final double level;

  /// 是否在说话。没建立 P2P 数据通道时，这个值来自服务端中继的 `member_state`。
  final bool speaking;

  /// 是否拿到了**真实电平**：
  /// * true —— 收到过对方的 P2P 电平广播；
  /// * false —— 只知道「在说话」这个布尔值（还没直连上），因此没有音量可画。
  final bool measured;

  PeerLevel copyWith({double? level, bool? speaking, bool? measured}) =>
      PeerLevel(
        level: level ?? this.level,
        speaking: speaking ?? this.speaking,
        measured: measured ?? this.measured,
      );

  @override
  bool operator ==(Object other) =>
      other is PeerLevel &&
      other.level == level &&
      other.speaking == speaking &&
      other.measured == measured;

  @override
  int get hashCode => Object.hash(level, speaking, measured);

  @override
  String toString() =>
      'PeerLevel(level=${level.toStringAsFixed(3)}, speaking=$speaking, '
      'measured=$measured)';
}

/// 房间里每个成员的实时电平表。
///
/// 单独做一个通知源，而不是挂在 `RoomSession.notifyListeners` 上：电平每 100ms 就
/// 变一次，走会话的通知会让整块界面（左中右三栏）每秒重建十次，纯粹是浪费。
/// 只有订阅了它的成员行会重建。
class PeerLevels extends ChangeNotifier {
  final Map<String, PeerLevel> _levels = <String, PeerLevel>{};

  /// 某个成员当前的电平；没有记录时返回全零（不会 null）。
  PeerLevel levelOf(String peerId) => _levels[peerId] ?? const PeerLevel();

  /// 本地麦克风的电平（自己）。
  void updateLocal(
    String peerId, {
    required double level,
    required bool speaking,
  }) =>
      _put(peerId, PeerLevel(level: level, speaking: speaking, measured: true));

  /// 收到某成员的 P2P 电平广播。
  void applyRemote(
    String peerId, {
    required double level,
    required bool speaking,
  }) =>
      _put(peerId, PeerLevel(level: level, speaking: speaking, measured: true));

  /// 只从服务端中继知道对方「在说话」——还没建立 P2P 数据通道时的降级信息。
  ///
  /// 不会覆盖已经收到的真实电平。
  void applySpeaking(String peerId, bool speaking) {
    final current = _levels[peerId];
    if (current == null) {
      _put(peerId, PeerLevel(speaking: speaking));
      return;
    }
    if (current.speaking == speaking) {
      return;
    }
    _put(peerId, current.copyWith(speaking: speaking));
  }

  void remove(String peerId) {
    if (_levels.remove(peerId) != null) {
      notifyListeners();
    }
  }

  void clear() {
    if (_levels.isEmpty) {
      return;
    }
    _levels.clear();
    notifyListeners();
  }

  void _put(String peerId, PeerLevel next) {
    if (_levels[peerId] == next) {
      return;
    }
    _levels[peerId] = next;
    notifyListeners();
  }
}
