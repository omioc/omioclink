import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/data/models.dart';
import 'package:omioclink_client/data/music_models.dart';
import 'package:omioclink_client/data/server_endpoint.dart';
import 'package:omioclink_client/room/room_music.dart';
import 'package:omioclink_client/room/room_session.dart';
import 'package:omioclink_client/signaling/signaling_client.dart';

import 'room_session_test.dart' show FakeMediaPort, roomStatePayload;
import 'signaling_client_test.dart' show FakeTransport, helloPayload, pump;

MusicTrack _track(String id, {String platform = 'wy'}) =>
    MusicTrack(platform: platform, id: id, name: '歌$id');

const _endpoint = ServerEndpoint(host: '127.0.0.1', port: 21077);
const _me = User(id: 7, username: 'alice', displayName: '小明');

void main() {
  group('RoomMusicQueue', () {
    test('入队后能取到，且会通知订阅者', () {
      final queue = RoomMusicQueue();
      var notified = 0;
      queue.addListener(() => notified++);

      expect(queue.enqueue(_track('1')), isTrue);
      expect(queue.length, 1);
      expect(queue.queue.single.name, '歌1');
      expect(notified, 1);

      queue.dispose();
    });

    test('同一首歌不重复入队（含正在播放的那首）', () {
      final queue = RoomMusicQueue();
      expect(queue.enqueue(_track('1')), isTrue);
      expect(queue.enqueue(_track('1')), isFalse);
      expect(queue.length, 1);

      // 出队成为「正在播放」后，同一首仍然算已在队列里
      expect(queue.next()?.id, '1');
      expect(queue.contains(_track('1')), isTrue);
      expect(queue.enqueue(_track('1')), isFalse);
    });

    test('不同平台上的同 id 不算同一首', () {
      final queue = RoomMusicQueue();
      expect(queue.enqueue(_track('1', platform: 'wy')), isTrue);
      expect(queue.enqueue(_track('1', platform: 'kw')), isTrue);
      expect(queue.length, 2);
    });

    test('队列满了就拒绝新歌', () {
      final queue = RoomMusicQueue(capacity: 2);
      expect(queue.enqueue(_track('1')), isTrue);
      expect(queue.enqueue(_track('2')), isTrue);
      expect(queue.isFull, isTrue);
      expect(queue.enqueue(_track('3')), isFalse);
      expect(queue.length, 2);
    });

    test('enqueueAll 跳过重复并在满队列时停下', () async {
      final queue = RoomMusicQueue(capacity: 3);
      queue.enqueue(_track('1'));

      final added = await queue.enqueueAll(<MusicTrack>[
        _track('1'),
        _track('2'),
        _track('3'),
        _track('4'),
      ]);

      expect(added, 2);
      expect(
        queue.queue.map((item) => item.id).toList(),
        <String>['1', '2', '3'],
      );
    });

    test('next 依次出队，空了返回 null；remove / clear / reset 各自生效', () async {
      final queue = RoomMusicQueue();
      // 默认列表循环会一直续下去；这条用例只看「出队」本身，用顺序播放
      queue.setMode(PlaybackMode.sequential);
      await queue.enqueueAll(<MusicTrack>[_track('1'), _track('2'), _track('3')]);

      // 按 MusicTrack 移除（队列自己知道 key 是 platform:id）
      queue.remove(_track('2'));
      expect(queue.queue.map((item) => item.id).toList(), <String>['1', '3']);
      queue.remove(_track('2'));

      expect(queue.next()?.id, '1');
      expect(queue.nowPlaying?.id, '1');
      expect(queue.queue.map((item) => item.id).toList(), <String>['3']);

      expect(queue.next()?.id, '3');
      expect(queue.isEmpty, isTrue);
      // 队列空了再点下一首：当前曲也一并清掉（回到「没有播放中」）
      expect(queue.next(), isNull);
      expect(queue.nowPlaying, isNull);

      queue.enqueue(_track('9'));
      queue.clear();
      expect(queue.isEmpty, isTrue);

      queue.enqueue(_track('8'));
      queue.reset();
      expect(queue.isEmpty, isTrue);
    });

    test('本地模式：默认列表循环，播完一轮重新排一遍', () async {
      final queue = RoomMusicQueue();
      expect(queue.mode, PlaybackMode.repeatAll);
      await queue.enqueueAll(<MusicTrack>[_track('1'), _track('2')]);

      expect(queue.next()?.id, '1');
      expect(queue.next()?.id, '2');
      // 一轮播完：列表循环把这一轮按原顺序重新排进来
      expect(queue.next()?.id, '1');
      expect(queue.next()?.id, '2');
    });

    test('本地模式：顺序播放播完就停', () async {
      final queue = RoomMusicQueue();
      queue.setMode(PlaybackMode.sequential);
      await queue.enqueueAll(<MusicTrack>[_track('1'), _track('2')]);

      expect(queue.next()?.id, '1');
      expect(queue.next()?.id, '2');
      expect(queue.next(), isNull);
    });

    test('本地模式：随机播放把三首各挑一次', () async {
      final queue = RoomMusicQueue();
      queue.setMode(PlaybackMode.shuffle);
      await queue.enqueueAll(<MusicTrack>[_track('1'), _track('2'), _track('3')]);

      final played = <String>{};
      for (var index = 0; index < 3; index += 1) {
        final track = queue.next();
        expect(track, isNotNull);
        played.add(track!.id);
      }
      expect(played, hasLength(3));
    });

    test('模式按钮按固定顺序轮换，转完一圈回到列表循环', () {
      final queue = RoomMusicQueue();
      final seen = <String>[queue.mode];
      for (var index = 0; index < PlaybackMode.cycle.length - 1; index += 1) {
        queue.setMode(queue.nextMode);
        seen.add(queue.mode);
      }
      expect(seen, PlaybackMode.cycle);

      queue.setMode(queue.nextMode);
      expect(queue.mode, PlaybackMode.repeatAll);
    });
  });

  group('RoomSession 集成', () {
    test('离开房间会清空播放队列', () async {
      final media = FakeMediaPort();
      final transports = <FakeTransport>[];
      final signaling = SignalingClient(
        endpoint: _endpoint,
        accessToken: 'token',
        random: Random(7),
        transportFactory: (uri) {
          final transport = FakeTransport(uri);
          transports.add(transport);
          return transport;
        },
      );
      final session = RoomSession(
        signaling: signaling,
        media: media,
        currentUser: _me,
        statsInterval: const Duration(hours: 1),
      );

      final joinFuture = session.join(roomId: 'BX4K9K');
      await pump();
      transports.first.emit(helloPayload());
      await pump();
      transports.first.emit(roomStatePayload());
      await joinFuture;
      await pump();

      session.music.enqueue(_track('1'));
      session.music.enqueue(_track('2'));
      expect(session.music.length, 2);

      await session.leave();
      expect(session.music.isEmpty, isTrue);
      expect(session.music.nowPlaying, isNull);

      session.dispose();
      await signaling.dispose();
    });
  });
}
