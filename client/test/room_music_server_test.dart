import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/music_models.dart';
import 'package:omioclink_client/music/clock_sync.dart';
import 'package:omioclink_client/music/music_player.dart';
import 'package:omioclink_client/musicfree/musicfree_service.dart';
import 'package:omioclink_client/room/room_music.dart';
import 'package:omioclink_client/signaling/protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录「意图」的假出口：真实现是 `RoomSession`（发信令）。
class _FakeSink implements MusicCommandSink {
  final List<MusicEntryDraft> enqueued = <MusicEntryDraft>[];
  final List<String> removed = <String>[];
  final List<String?> skipped = <String?>[];
  final List<({String entryId, int revision})> eos =
      <({String entryId, int revision})>[];
  final List<String> modes = <String>[];
  int cleared = 0;

  /// 服务端是否支持一次点一批（测试里可以关掉，模拟老服务器）。
  @override
  bool supportsBatch = true;

  /// 每次 `enqueueBatch` 收到的整批：一批只算一条信令。
  final List<List<MusicEntryDraft>> batches = <List<MusicEntryDraft>>[];

  @override
  bool enqueue(MusicEntryDraft draft) {
    enqueued.add(draft);
    return true;
  }

  @override
  bool enqueueBatch(List<MusicEntryDraft> drafts) {
    batches.add(drafts);
    enqueued.addAll(drafts);
    return true;
  }

  @override
  void remove(String entryId) => removed.add(entryId);

  @override
  void skip({String? entryId}) => skipped.add(entryId);

  @override
  void clear() => cleared += 1;

  @override
  void reportEos({required String entryId, required int revision}) =>
      eos.add((entryId: entryId, revision: revision));

  @override
  void setMode(String mode) => modes.add(mode);
}

MusicEntry _entry(
  String entryId, {
  String by = 'peer-a',
  String name = '小明',
  String songId = '1',
}) => MusicEntry(
  entryId: entryId,
  source: 'test',
  songId: songId,
  musicInfo: <String, dynamic>{'id': songId},
  title: '歌$songId',
  artist: '歌手',
  durationMs: 210000,
  requestedBy: MusicRequester(peerId: by, displayName: name),
  requestedAtMs: 1,
);

MusicCurrent _current(
  String entryId, {
  String by = 'peer-a',
  String name = '小明',
  int anchorServerMs = 0,
  int anchorPositionMs = 0,
  int? durationMs = 210000,
}) => MusicCurrent(
  entryId: entryId,
  source: 'test',
  songId: '1',
  musicInfo: const <String, dynamic>{'id': '1'},
  title: '在播',
  artist: '歌手',
  durationMs: durationMs,
  requestedBy: MusicRequester(peerId: by, displayName: name),
  anchorServerMs: anchorServerMs,
  anchorPositionMs: anchorPositionMs,
);

MusicTrack _track(String id) =>
    MusicTrack(platform: 'test', id: id, name: '歌$id');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('服务端模式：只由快照驱动', () {
    test('还没收到快照时是本地模式：点歌进本地队列，不发意图', () {
      final sink = _FakeSink();
      final queue = RoomMusicQueue()..bind(sink);

      expect(queue.serverDriven, isFalse);
      expect(queue.enqueue(_track('1')), isTrue);

      expect(queue.queue.single.name, '歌1');
      expect(queue.serverDriven, isFalse, reason: '没有快照前不该假装服务端驱动');
      expect(sink.enqueued, isEmpty, reason: '本地模式不该发 music_enqueue');
    });

    test('收到快照后视图跟着服务端走，点歌只发意图', () {
      final sink = _FakeSink();
      final queue = RoomMusicQueue()..bind(sink);
      queue.enqueue(_track('local'));

      queue.applySnapshot(
        MusicSnapshot(
          revision: 3,
          current: _current('e1'),
          queue: <MusicEntry>[_entry('e2')],
        ),
      );

      expect(queue.serverDriven, isTrue);
      expect(queue.revision, 3);
      expect(queue.nowPlaying?.name, '在播');
      expect(queue.queue.single.name, '歌1');
      expect(
        queue.contains(_track('local')),
        isFalse,
        reason: '服务端接管后，本地队列里那首就不该再被当成「已在队列」',
      );

      expect(queue.enqueue(_track('9')), isTrue);
      expect(sink.enqueued.single.songId, '9');
      expect(sink.enqueued.single.title, '歌9');
      expect(
        queue.queue.any((track) => track.name == '歌9'),
        isFalse,
        reason: '服务端模式不本地入队：等 music_state 回来再显示',
      );
    });

    test('旧 revision 的快照直接丢掉（界面不会倒退）', () {
      final queue = RoomMusicQueue();
      queue.applySnapshot(
        MusicSnapshot(
          revision: 7,
          current: _current('e7'),
          queue: <MusicEntry>[_entry('e8')],
        ),
      );

      queue.applySnapshot(
        MusicSnapshot(
          revision: 6,
          current: _current('e6'),
          queue: const <MusicEntry>[],
        ),
      );

      expect(queue.revision, 7);
      expect(queue.nowPlaying?.name, '在播');
      expect(queue.entries.single.entryId, 'e8');
    });

    test('空快照（房主清空）回到「队列还是空的」', () {
      final queue = RoomMusicQueue();
      queue.applySnapshot(
        MusicSnapshot(revision: 2, current: _current('e1')),
      );
      expect(queue.isEmpty, isFalse);

      queue.applySnapshot(const MusicSnapshot(revision: 3));

      expect(queue.isEmpty, isTrue);
      expect(queue.nowPlaying, isNull);
      expect(queue.current, isNull);
    });

    test('reset() 退出服务端模式并清掉身份（离房后不再按房主显示按钮）', () {
      final queue = RoomMusicQueue()..bind(_FakeSink());
      queue.setViewer(peerId: 'peer-me', isOwner: true);
      queue.applySnapshot(
        MusicSnapshot(revision: 5, current: _current('e1')),
      );

      queue.reset();

      expect(queue.serverDriven, isFalse);
      expect(queue.revision, -1);
      expect(queue.isOwner, isFalse);
      expect(queue.selfPeerId, isNull);
      expect(queue.canSkipCurrent, isTrue, reason: '本地模式不做权限拦截');
    });
  });

  group('权限：只露出点了会成功的按钮', () {
    RoomMusicQueue serverQueue({String? me, bool owner = false}) {
      final queue = RoomMusicQueue()..bind(_FakeSink());
      if (me != null) {
        queue.setViewer(peerId: me, isOwner: owner);
      }
      queue.applySnapshot(
        MusicSnapshot(
          revision: 1,
          current: _current('e1', by: 'peer-a', name: '小明'),
          queue: <MusicEntry>[
            _entry('e2', by: 'peer-me', name: '我'),
            _entry('e3', by: 'peer-b', name: '小红', songId: '3'),
          ],
        ),
      );
      return queue;
    }

    test('房主：能切歌、能删别人的、能清空', () {
      final queue = serverQueue(me: 'peer-me', owner: true);

      expect(queue.canSkipCurrent, isTrue);
      expect(queue.canRemoveEntry(queue.entries.last), isTrue);
      expect(queue.canClear, isTrue);
    });

    test('普通成员：只能删自己的，切不了别人的歌', () {
      final queue = serverQueue(me: 'peer-me');

      expect(queue.canSkipCurrent, isFalse, reason: '当前曲是小明点的');
      expect(queue.canRemoveEntry(queue.entries.first), isTrue);
      expect(queue.canRemoveEntry(queue.entries.last), isFalse);
      expect(queue.canClear, isFalse);
      expect(queue.isMine(queue.entries.first), isTrue);
      expect(queue.isMine(queue.entries.last), isFalse);
    });

    test('当前曲是我点的：普通成员也能切', () {
      final queue = RoomMusicQueue()..bind(_FakeSink());
      queue.setViewer(peerId: 'peer-me');
      queue.applySnapshot(
        MusicSnapshot(revision: 1, current: _current('e1', by: 'peer-me')),
      );

      expect(queue.canSkipCurrent, isTrue);
    });

    test('身份还没到（room_state 没回来）时不本地拦，交给服务端裁决', () {
      final queue = serverQueue();

      expect(queue.selfPeerId, isNull);
      expect(queue.canSkipCurrent, isTrue);
      expect(queue.canRemoveEntry(queue.entries.last), isTrue);
      expect(queue.canClear, isTrue);
    });
  });

  group('意图：服务端模式下都从 sink 走', () {
    test('remove 按 entryId 发，skipEntry 带的是被点的条目', () {
      final sink = _FakeSink();
      final queue = RoomMusicQueue()..bind(sink);
      queue.applySnapshot(
        MusicSnapshot(
          revision: 2,
          current: _current('e1'),
          queue: <MusicEntry>[_entry('e2'), _entry('e3', songId: '3')],
        ),
      );

      queue.remove(_track('3'));
      queue.skipEntry('e3');

      expect(sink.removed, <String>['e3']);
      expect(sink.skipped, <String?>['e3']);
    });

    test('skip() 切当前曲，带上它的 entryId', () {
      final sink = _FakeSink();
      final queue = RoomMusicQueue()..bind(sink);
      queue.applySnapshot(
        MusicSnapshot(revision: 2, current: _current('e1')),
      );

      queue.skip();

      expect(sink.skipped, <String?>['e1']);
    });

    test('上报 EOS 带当前条目与 revision（服务端据此幂等推进）', () {
      final sink = _FakeSink();
      final queue = RoomMusicQueue()..bind(sink);
      queue.applySnapshot(
        MusicSnapshot(revision: 9, current: _current('e1')),
      );

      queue.reportEos();
      queue.reportEos();

      expect(sink.eos, hasLength(2));
      expect(sink.eos.first.entryId, 'e1');
      expect(sink.eos.first.revision, 9);
    });

    test('clear 只发意图；没有当前曲时 reportEos 不发', () {
      final sink = _FakeSink();
      final queue = RoomMusicQueue()..bind(sink);
      queue.applySnapshot(const MusicSnapshot(revision: 1));

      queue.clear();
      queue.reportEos();

      expect(sink.cleared, 1);
      expect(sink.eos, isEmpty);
    });

    test('批量点歌最多发 88 条，而且一批只发一条信令', () async {
      final sink = _FakeSink();
      final queue = RoomMusicQueue()..bind(sink);
      queue.applySnapshot(const MusicSnapshot(revision: 1));

      // 服务端每人最多 88 首：多出来的不再发，省得换来一串被拒的提示
      final added = await queue.enqueueAll(
        List<MusicTrack>.generate(90, (index) => _track('$index')),
      );

      expect(added, 88);
      // 「全部加入」必须一次到位：整批算一次请求，不会触发 2 秒冷却
      expect(sink.batches, hasLength(1));
      expect(sink.batches.single, hasLength(88));
    });

    test('批量点歌会扣掉自己已经占的名额', () async {
      final sink = _FakeSink();
      final queue = RoomMusicQueue()..bind(sink);
      queue.setViewer(peerId: 'peer-me');
      queue.applySnapshot(
        MusicSnapshot(
          revision: 1,
          queue: <MusicEntry>[_entry('e1', by: 'peer-me', songId: '9')],
        ),
      );

      final added = await queue.enqueueAll(
        List<MusicTrack>.generate(90, (index) => _track('$index')),
      );

      expect(queue.mineCount, 1);
      expect(added, 87); // 88 减掉自己已占的 1 首
    });

    test('老服务器不支持批量时退回逐条发，按冷却节奏排', () async {
      final sink = _FakeSink()..supportsBatch = false;
      final queue = RoomMusicQueue(
        enqueueInterval: const Duration(milliseconds: 20),
      )..bind(sink);
      queue.applySnapshot(const MusicSnapshot(revision: 1));

      final watch = Stopwatch()..start();
      final added = await queue.enqueueAll(<MusicTrack>[
        _track('1'),
        _track('2'),
        _track('3'),
      ]);
      watch.stop();

      expect(added, 3);
      expect(sink.batches, isEmpty);
      expect(
        sink.enqueued.map((draft) => draft.songId).toList(),
        <String>['1', '2', '3'],
      );
      // 第 2、3 条各等满一个间隔：3 条至少两段
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 40)),
      );
    });

    test('解绑会打断正在逐条发的批量点歌', () async {
      final sink = _FakeSink()..supportsBatch = false;
      final queue = RoomMusicQueue(
        enqueueInterval: const Duration(milliseconds: 20),
      )..bind(sink);
      queue.applySnapshot(const MusicSnapshot(revision: 1));

      final batch = queue.enqueueAll(
        List<MusicTrack>.generate(10, (index) => _track('$index')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      queue.unbind(sink);

      final added = await batch;
      expect(added, lessThan(10));
      expect(sink.enqueued, hasLength(added));
    });

    test('播放模式跟着服务端快照走，切换只发意图', () {
      final sink = _FakeSink();
      final queue = RoomMusicQueue()..bind(sink);
      queue.applySnapshot(const MusicSnapshot(revision: 1, mode: 'repeat_one'));

      expect(queue.mode, 'repeat_one');
      expect(queue.nextMode, 'sequential');

      // 服务端模式：本地先不变，等服务端广播回来才算数
      queue.setMode(queue.nextMode);
      expect(sink.modes, <String>['sequential']);
      expect(queue.mode, 'repeat_one');

      queue.applySnapshot(const MusicSnapshot(revision: 2, mode: 'sequential'));
      expect(queue.mode, 'sequential');
    });

    test('服务端拒绝的原因能取走一次', () {
      final queue = RoomMusicQueue();
      expect(queue.consumeError(), isNull);

      queue.noteError('只有房主可以清空队列');

      expect(queue.lastError, '只有房主可以清空队列');
      expect(queue.consumeError(), '只有房主可以清空队列');
      expect(queue.consumeError(), isNull);
    });

    test('信令没发出去（断线）要提示，而不是假装点歌成功', () {
      final queue = RoomMusicQueue()..bind(_DroppingSink());
      queue.applySnapshot(const MusicSnapshot(revision: 1));

      expect(queue.enqueue(_track('1')), isTrue);

      expect(queue.consumeError(), contains('连接已断开'));
    });
  });

  group('MusicPlayer 服务端模式', () {
    /// 解析永远挂着：单测里没有 libmpv，走到 `open()` 就会炸。
    MusicPlayer newPlayer({
      RoomMusicQueue? queue,
      ClockSync? clock,
      void Function()? onSkipRoom,
    }) {
      final gate = Completer<MusicFreeMediaSource>();
      final player = MusicPlayer(
        queue: queue ?? RoomMusicQueue(),
        resolve: (_) => gate.future,
        clock: clock,
        onSkipRoom: onSkipRoom,
      );
      addTearDown(player.dispose);
      return player;
    }

    test('换条目：解析并停在「加载中」，同一条目重复下发不重复解析', () async {
      var resolves = 0;
      final gate = Completer<MusicFreeMediaSource>();
      final player = MusicPlayer(
        queue: RoomMusicQueue(),
        resolve: (_) {
          resolves += 1;
          return gate.future;
        },
      );
      addTearDown(player.dispose);

      unawaited(player.applyRoomState(_current('e1'), revision: 4));
      await Future<void>.delayed(Duration.zero);

      expect(player.serverDriven, isTrue);
      expect(player.current?.name, '在播');
      expect(player.status, MusicPlayerStatus.resolving);
      expect(resolves, 1);

      unawaited(player.applyRoomState(_current('e1'), revision: 5));
      await Future<void>.delayed(Duration.zero);

      expect(resolves, 1, reason: '同一条目只该解析一次，否则每次心跳都重开播放器');
    });

    test('快照没有当前曲：停播回到空态', () async {
      final player = newPlayer();
      unawaited(player.applyRoomState(_current('e1'), revision: 1));
      await Future<void>.delayed(Duration.zero);
      expect(player.current, isNotNull);

      await player.applyRoomState(null, revision: 2);

      expect(player.serverDriven, isFalse);
      expect(player.current, isNull);
      expect(player.status, MusicPlayerStatus.idle);
    });

    test('playNext 在服务端模式只发切歌，不自己把队列出空', () async {
      var skipped = 0;
      final queue = RoomMusicQueue();
      final player = MusicPlayer(
        queue: queue,
        resolve: (_) => Completer<MusicFreeMediaSource>().future,
        onSkipRoom: () => skipped += 1,
      );
      addTearDown(player.dispose);

      unawaited(player.applyRoomState(_current('e1'), revision: 1));
      await Future<void>.delayed(Duration.zero);

      await player.playNext();

      expect(skipped, 1);
      expect(queue.isEmpty, isTrue, reason: '本地不该动服务端的队列');
    });

    test('stop()（离开房间）会把播放器摘出服务端模式', () async {
      final player = newPlayer();
      unawaited(player.applyRoomState(_current('e1'), revision: 1));
      await Future<void>.delayed(Duration.zero);
      expect(player.serverDriven, isTrue);

      await player.stop();

      expect(player.serverDriven, isFalse);
      expect(player.status, MusicPlayerStatus.idle);
    });

    test('锚点换算：没到点要预滚，过点从对应位置起播，超时长夹在末尾', () {
      final clock = ClockSync();
      final now = DateTime.now().millisecondsSinceEpoch;
      // RTT 为 0 的样本：offset 精确等于 40 秒
      clock.addSample(t0: now, serverTimeMs: now + 40000, t1: now);
      final player = newPlayer(clock: clock);

      final serverNow = clock.serverNowMs();
      expect(
        player.debugAnchorWaitMs(_current('e1', anchorServerMs: serverNow + 3000)),
        inInclusiveRange(2500, 3100),
        reason: '还在预滚期：要等锚点到了再出声',
      );

      final late = _current(
        'e1',
        anchorServerMs: serverNow - 2000,
        anchorPositionMs: 500,
      );
      expect(
        player.debugExpectedPositionMs(late),
        inInclusiveRange(2400, 2600),
        reason: '迟到两秒：要从锚点位置 +2000ms 起播，别从头放',
      );

      final ended = _current(
        'e1',
        anchorServerMs: serverNow - 10000,
        durationMs: 1000,
      );
      expect(
        player.debugExpectedPositionMs(ended),
        1000,
        reason: '已经超过了时长：夹在末尾，不能 seek 到歌后面',
      );
    });

    test('停过之后同一条目要重新起播（重新进房拿到的往往还是它）', () async {
      var resolves = 0;
      final gate = Completer<MusicFreeMediaSource>();
      final player = MusicPlayer(
        queue: RoomMusicQueue(),
        resolve: (_) {
          resolves += 1;
          return gate.future;
        },
      );
      addTearDown(player.dispose);

      unawaited(player.applyRoomState(_current('e1'), revision: 1));
      await Future<void>.delayed(Duration.zero);
      expect(resolves, 1);

      await player.stop();
      expect(player.serverDriven, isFalse);

      // 重新进房：服务端快照里还是同一条目
      unawaited(player.applyRoomState(_current('e1'), revision: 1));
      await Future<void>.delayed(Duration.zero);

      expect(
        resolves,
        2,
        reason: '停过之后同一条目也要重新起播，否则重新进房就一直没声音',
      );
    });

    test('首个点歌只解析一次：本地自动起播要让位给锚点', () async {
      var resolves = 0;
      final queue = RoomMusicQueue();
      final player = MusicPlayer(
        queue: queue,
        resolve: (_) {
          resolves += 1;
          return Completer<MusicFreeMediaSource>().future;
        },
      );
      addTearDown(player.dispose);

      // 快照一到，队列会同步通知出去；那一刻播放器还空着。本地自动起播若在这时插手，
      // 就会和随后按锚点起播的 applyRoomState 抢同一个媒体：各 open 一遍、各解析一次。
      queue.applySnapshot(MusicSnapshot(revision: 1, current: _current('e1')));

      unawaited(player.playCurrent());
      await Future<void>.delayed(Duration.zero);

      expect(resolves, 0, reason: '服务端模式不该由本地路径解析并起播');
      expect(player.current, isNull, reason: '起播交给 applyRoomState 按锚点来');

      // 锚点那一路照旧起播：整首歌只解析一次
      unawaited(player.applyRoomState(_current('e1'), revision: 1));
      await Future<void>.delayed(Duration.zero);

      expect(
        resolves,
        1,
        reason: '解析两次就是 open 两次：听感上先放一两秒，再回到开头重播',
      );
    });
  });
}

/// 信令发不出去（已断线）的出口：`enqueue` 返回 false。
class _DroppingSink implements MusicCommandSink {
  @override
  bool get supportsBatch => true;

  @override
  bool enqueue(MusicEntryDraft draft) => false;

  @override
  bool enqueueBatch(List<MusicEntryDraft> drafts) => false;

  @override
  void setMode(String mode) {}

  @override
  void remove(String entryId) {}

  @override
  void skip({String? entryId}) {}

  @override
  void clear() {}

  @override
  void reportEos({required String entryId, required int revision}) {}
}
