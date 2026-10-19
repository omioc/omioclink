import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/music_models.dart';
import 'package:omioclink_client/music/music_player.dart';
import 'package:omioclink_client/musicfree/musicfree_service.dart';
import 'package:omioclink_client/room/room_music.dart';
import 'package:shared_preferences/shared_preferences.dart';

MusicTrack _track(String id) => MusicTrack(platform: 'test', id: id, name: '歌$id');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('RoomMusicQueue.finishPlaying', () {
    test('放完后清掉「正在播放」：不再算已在队列，界面能回到空态', () {
      final queue = RoomMusicQueue();
      final track = _track('1');
      queue.enqueue(track);
      expect(queue.next()?.key, track.key);
      expect(queue.nowPlaying, isNotNull);
      expect(queue.contains(track), isTrue);

      var notified = 0;
      queue.addListener(() => notified++);

      queue.finishPlaying();

      expect(queue.nowPlaying, isNull);
      expect(queue.contains(track), isFalse, reason: '放完就能重新点同一首');
      expect(notified, 1);
      expect(queue.isEmpty, isTrue);
    });

    test('本来就没有「正在播放」时不重复通知', () {
      final queue = RoomMusicQueue();
      var notified = 0;
      queue.addListener(() => notified++);
      queue.finishPlaying();
      expect(notified, 0);
    });
  });

  group('MusicPlayer 最后一首放完', () {
    test('回到 idle 空态，并清掉队列里残留的「正在播放」', () async {
      final queue = RoomMusicQueue();
      final player = MusicPlayer(
        queue: queue,
        resolve: (track) async => throw StateError('本用例不该解析播放地址'),
      );
      addTearDown(player.dispose);

      final track = _track('last');
      queue.enqueue(track);
      // 模拟「这首正在播」：next() 把待播列表里唯一的这首挪进 nowPlaying
      expect(queue.next()?.key, track.key);
      expect(queue.isEmpty, isTrue, reason: '此时待播区已空，只剩正在播的那首');

      // 播放结束（media_kit 的 completed 回调）走的就是这条：_advance()
      await player.playNext();

      expect(player.current, isNull, reason: '底栏要回到空态而不是停在最后一首');
      expect(player.status, MusicPlayerStatus.idle);
      expect(queue.nowPlaying, isNull, reason: '「正在播放」要清掉');
      expect(
        queue.contains(track),
        isFalse,
        reason: '最后一首放完后不该还留着「已在队列」的勾',
      );
    });

    test('从没播过任何东西时点「下一首」也不会崩', () async {
      final queue = RoomMusicQueue();
      final player = MusicPlayer(
        queue: queue,
        resolve: (track) async => throw StateError('本用例不该解析播放地址'),
      );
      addTearDown(player.dispose);

      await player.playNext();

      expect(player.current, isNull);
      expect(player.status, MusicPlayerStatus.idle);
      expect(queue.nowPlaying, isNull);
    });
  });

  group('静音 / 恢复', () {
    MusicPlayer newPlayer() {
      final player = MusicPlayer(
        queue: RoomMusicQueue(),
        resolve: (_) => Completer<MusicFreeMediaSource>().future,
      );
      addTearDown(player.dispose);
      return player;
    }

    test('静音后再点一次回到静音前的音量，而不是 100%', () async {
      final player = newPlayer();
      await player.setVolume(37);

      await player.toggleMute();
      expect(player.volume, 0, reason: '第一次点击要静音');

      await player.toggleMute();
      expect(player.volume, 37, reason: '解除静音要还原成 37%，不能跳到 100%');
    });

    test('拖动滑块后的新音量同样成为恢复目标', () async {
      final player = newPlayer();
      await player.setVolume(80);
      await player.setVolume(15);
      await player.toggleMute();
      expect(player.volume, 0);
      await player.toggleMute();
      expect(player.volume, 15);
    });

    test('音量本来就是 0 时解除静音回落到 100%', () async {
      final player = newPlayer();
      await player.setVolume(0);
      await player.toggleMute();
      expect(player.volume, 100);
    });
  });

  group('歌词跟随播放位置', () {
    test('歌词按位置换句；没到第一句时是 -1', () async {
      final queue = RoomMusicQueue();
      final track = _track('lyric');
      queue.enqueue(track);
      expect(queue.next()?.key, track.key);
      final player = MusicPlayer(
        queue: queue,
        resolve: (_) => Completer<MusicFreeMediaSource>().future,
        loadLyric: (_) async => '[00:01.00]一\n[00:03.00]二\n',
      );
      addTearDown(player.dispose);

      // resolve 会一直挂着，这里不等它完成，只等歌词那一路
      unawaited(player.playCurrent());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(player.lyrics, hasLength(2));
      expect(player.lyricIndex, -1, reason: '位置 0 还没到第一句');

      player.debugSetPosition(const Duration(seconds: 2));
      expect(player.lyricIndex, 0);

      player.debugSetPosition(const Duration(seconds: 3));
      expect(player.lyricIndex, 1);
    });

    test('取不到歌词时列表为空，但播放状态不受影响', () async {
      final queue = RoomMusicQueue();
      final track = _track('no-lyric');
      queue.enqueue(track);
      queue.next();
      final player = MusicPlayer(
        queue: queue,
        resolve: (_) => Completer<MusicFreeMediaSource>().future,
        loadLyric: (_) async => throw StateError('歌词接口挂了'),
      );
      addTearDown(player.dispose);

      unawaited(player.playCurrent());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(player.lyrics, isEmpty);
      expect(player.lyricIndex, -1);
      expect(player.current?.key, track.key);
    });
  });

  group('离开房间要停播', () {
    test('stop() 回到空态：不再播放，队列也不再挂着「正在播放」', () async {
      final queue = RoomMusicQueue();
      final track = _track('stop-me');
      queue.enqueue(track);
      expect(queue.next()?.key, track.key);
      final player = MusicPlayer(
        queue: queue,
        resolve: (_) => Completer<MusicFreeMediaSource>().future,
        loadLyric: (_) async => '[00:01.00]一\n',
      );
      addTearDown(player.dispose);

      unawaited(player.playCurrent());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(player.current, isNotNull);
      expect(player.lyrics, isNotEmpty);

      await player.stop();

      expect(player.status, MusicPlayerStatus.idle, reason: '离开房间后不该还处于播放中');
      expect(player.current, isNull);
      expect(player.lyrics, isEmpty);
      expect(queue.nowPlaying, isNull, reason: '房间队列的「正在播放」要一起清掉');
    });

    test('重复 stop() 不会崩（离开房间 + 退出登录会连着调）', () async {
      final queue = RoomMusicQueue();
      final player = MusicPlayer(
        queue: queue,
        resolve: (_) => Completer<MusicFreeMediaSource>().future,
      );
      addTearDown(player.dispose);

      await player.stop();
      await player.stop();

      expect(player.status, MusicPlayerStatus.idle);
    });
  });
}
