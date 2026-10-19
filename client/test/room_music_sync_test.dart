import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/room/room_models.dart';
import 'package:omioclink_client/room/room_music.dart';
import 'package:omioclink_client/room/room_music_sync.dart';
import 'package:omioclink_client/signaling/protocol.dart';

/// 记录「交给播放器」的动作（真实现是 `MusicPlayer.applyRoomState`）。
class _Recorder {
  final List<({String? entryId, int revision})> calls =
      <({String? entryId, int revision})>[];

  Future<void> call(MusicCurrent? current, {required int revision}) async {
    calls.add((entryId: current?.entryId, revision: revision));
  }
}

MusicEntry _entry(String entryId, {String title = '待播'}) => MusicEntry(
  entryId: entryId,
  source: 'test',
  songId: entryId,
  musicInfo: <String, dynamic>{'id': entryId},
  title: title,
  artist: '歌手',
  durationMs: 200000,
);

MusicSnapshot _snapshot(int revision, {String? currentId}) => MusicSnapshot(
  revision: revision,
  serverTimeMs: 1000,
  current: currentId == null
      ? null
      : MusicCurrent(
          entryId: currentId,
          source: 'test',
          songId: currentId,
          musicInfo: <String, dynamic>{'id': currentId},
          title: '在播 $currentId',
          artist: '歌手',
          durationMs: 200000,
          anchorServerMs: 1000,
        ),
  queue: <MusicEntry>[_entry('q$revision')],
);

void main() {
  late RoomMusicQueue queue;
  late _Recorder recorder;
  late RoomMusicSync sync;

  // 两个「会话」：只用对象身份区分，跟真实现里的 RoomSession 一样
  final sessionA = Object();
  final sessionB = Object();

  setUp(() {
    queue = RoomMusicQueue();
    recorder = _Recorder();
    sync = RoomMusicSync(queue: queue, applyToPlayer: recorder.call);
  });

  test('进房第一份快照：队列进服务端模式，当前曲交给播放器', () {
    final applied = sync.apply(
      sessionA,
      phase: RoomPhase.active,
      snapshot: _snapshot(3, currentId: 'e1'),
    );

    expect(applied, isTrue);
    expect(queue.serverDriven, isTrue);
    expect(queue.nowPlaying?.name, '在播 e1');
    expect(queue.queue.single.name, '待播');
    expect(recorder.calls.single.entryId, 'e1');
    expect(recorder.calls.single.revision, 3);
  });

  test('离开房间（leaving）后不再应用：别把刚停掉的歌重新放起来', () {
    sync.apply(
      sessionA,
      phase: RoomPhase.active,
      snapshot: _snapshot(3, currentId: 'e1'),
    );
    recorder.calls.clear();

    final applied = sync.apply(
      sessionA,
      phase: RoomPhase.leaving,
      snapshot: _snapshot(3, currentId: 'e1'),
    );

    expect(applied, isFalse);
    expect(recorder.calls, isEmpty, reason: '离开房间后播放器不该再被快照驱动');
  });

  test('房间被解散 / 被踢（closed、failed）同样不应用', () {
    for (final phase in <RoomPhase>[
      RoomPhase.idle,
      RoomPhase.connecting,
      RoomPhase.joining,
      RoomPhase.leaving,
      RoomPhase.closed,
      RoomPhase.failed,
    ]) {
      final applied = sync.apply(
        sessionA,
        phase: phase,
        snapshot: _snapshot(1, currentId: 'e1'),
      );
      expect(applied, isFalse, reason: '$phase 不该驱动播放器');
    }
    expect(recorder.calls, isEmpty);
    expect(queue.serverDriven, isFalse);
  });

  test('同一会话同一 revision 只应用一次', () {
    sync.apply(
      sessionA,
      phase: RoomPhase.active,
      snapshot: _snapshot(3, currentId: 'e1'),
    );
    recorder.calls.clear();

    final again = sync.apply(
      sessionA,
      phase: RoomPhase.active,
      snapshot: _snapshot(3, currentId: 'e1'),
    );

    expect(again, isFalse);
    expect(recorder.calls, isEmpty);

    // 新 revision 照常应用
    expect(
      sync.apply(
        sessionA,
        phase: RoomPhase.active,
        snapshot: _snapshot(4, currentId: 'e2'),
      ),
      isTrue,
    );
    expect(recorder.calls.single.entryId, 'e2');
  });

  test('重新进房（新会话）即使 revision 与上一轮相同也必须重放', () {
    sync.apply(
      sessionA,
      phase: RoomPhase.active,
      snapshot: _snapshot(3, currentId: 'e1'),
    );
    sync.forget();
    queue.reset();

    // 房间状态没变：服务端还是 revision 3
    final applied = sync.apply(
      sessionB,
      phase: RoomPhase.active,
      snapshot: _snapshot(3, currentId: 'e1'),
    );

    expect(
      applied,
      isTrue,
      reason: '裸 revision 去重会把新会话的第一份快照整份丢掉',
    );
    expect(
      queue.serverDriven,
      isTrue,
      reason: '队列必须回到服务端模式，否则点歌只进本地列表、发不到服务器',
    );
    expect(recorder.calls, hasLength(2));
  });

  test('没 forget() 但会话换了（进房失败后重建）也能重放', () {
    sync.apply(
      sessionA,
      phase: RoomPhase.active,
      snapshot: _snapshot(3, currentId: 'e1'),
    );

    final applied = sync.apply(
      sessionB,
      phase: RoomPhase.active,
      snapshot: _snapshot(3, currentId: 'e1'),
    );

    expect(applied, isTrue, reason: '去重键是（会话, revision），不是裸 revision');
  });

  test('房间还没人点歌（空快照）也要进服务端模式，否则第一首歌发不出去', () {
    final applied = sync.apply(
      sessionA,
      phase: RoomPhase.active,
      snapshot: const MusicSnapshot(revision: 0),
    );

    expect(applied, isTrue);
    expect(queue.serverDriven, isTrue);
    expect(queue.isEmpty, isTrue);
    expect(recorder.calls.single.entryId, isNull);
  });
}
