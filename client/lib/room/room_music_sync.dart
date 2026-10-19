import 'dart:async';

import '../signaling/protocol.dart';
import 'room_models.dart';
import 'room_music.dart';

/// 房间点歌快照 → 本机队列与播放器的那道闸门。
///
/// 只有这一处决定「这份 `music_state` 要不要真的放出来」，两条边界都是踩过的坑：
///
/// 1. **离开房间之后不能再应用**。`AppState.leaveRoom()` 先 `stop()` 停声音，
///    再 `session.leave()`；而 `leave()` 改 phase 会 notify。如果那时快照还在，
///    闸门会把刚停掉的那首歌重新解析、起播——现象就是「人已经离开房间，歌还在响」。
/// 2. **重新进房必须重放**。服务端的 `revision` 是每个房间各自从 0 开始的，
///    换一个会话（甚至换个房间）完全可能又收到同一个数字；只按数字去重会把
///    新会话的第一份快照整份丢掉，队列停在本地模式，点歌就再也发不到服务器。
///
/// 所以去重的键是 **(会话身份, revision)**，而不是裸的 revision。
class RoomMusicSync {
  RoomMusicSync({required this.queue, required this.applyToPlayer});

  final RoomMusicQueue queue;

  /// 把「当前曲 + revision」交给播放器（`MusicPlayer.applyRoomState`）。
  final Future<void> Function(MusicCurrent? current, {required int revision})
  applyToPlayer;

  /// 上一次应用快照的会话：换成新会话就一定要重放。
  Object? _session;

  /// 上一次已应用的 revision（只对 `_session` 有效）。
  int _appliedRevision = -1;

  /// 当前记着的会话（测试与日志用）。
  Object? get session => _session;

  /// 应用一份快照。返回 true 表示这次真的交给了播放器。
  ///
  /// [phase] 不是 `active`（进房中 / 离开中 / 已结束）时一律不动播放器。
  bool apply(Object session, {required RoomPhase phase, MusicSnapshot? snapshot}) {
    if (!identical(_session, session)) {
      // 新会话：上一轮的 revision 与新会话无关，直接作废
      _session = session;
      _appliedRevision = -1;
    }
    if (phase != RoomPhase.active) {
      return false;
    }
    if (snapshot == null || snapshot.revision == _appliedRevision) {
      return false;
    }
    _appliedRevision = snapshot.revision;
    queue.applySnapshot(snapshot);
    unawaited(applyToPlayer(snapshot.current, revision: snapshot.revision));
    return true;
  }

  /// 离开房间 / 房间结束：下一次无论 revision 是多少都重放。
  void forget() {
    _session = null;
    _appliedRevision = -1;
  }
}
