import 'package:flutter_test/flutter_test.dart';
import 'package:omioclink_client/music/clock_sync.dart';
import 'package:omioclink_client/signaling/protocol.dart';

/// 点歌同步的地基：时钟偏移估计 + 协议里的 music_state / music_* 消息。
void main() {
  group('ClockSync', () {
    test('保留 RTT 最小的样本，并据此换算服务器时间', () {
      final clock = ClockSync();
      // 抖动样本：RTT 120ms
      clock.addSample(t0: 1000, serverTimeMs: 5000, t1: 1120);
      // 好样本：RTT 20ms → offset = 5060 - (2000 + 2020) / 2 = 3050
      clock.addSample(t0: 2000, serverTimeMs: 5060, t1: 2020);

      expect(clock.bestRttMs, 20);
      expect(clock.offsetMs, 3050);
      expect(clock.hasSample, isTrue);
      expect(clock.toLocalMs(5060), 2010);
    });

    test('更差的样本不会覆盖已经拿到的好样本', () {
      final clock = ClockSync();
      clock.addSample(t0: 2000, serverTimeMs: 5060, t1: 2020);
      clock.addSample(t0: 3000, serverTimeMs: 9999, t1: 3300);

      expect(clock.bestRttMs, 20);
      expect(clock.offsetMs, 3050);
    });

    test('RTT 相等的样本保持第一次的结果（避免来回跳）', () {
      final clock = ClockSync();
      clock.addSample(t0: 1000, serverTimeMs: 2000, t1: 1100);
      clock.addSample(t0: 5000, serverTimeMs: 9000, t1: 5100);

      expect(clock.offsetMs, 2000 - (1000 + 1100) ~/ 2);
    });

    test('bootstrap 只在没有真样本时生效', () {
      final clock = ClockSync();
      clock.addBootstrapSample(serverTimeMs: 10_000, localNowMs: 9_000);
      expect(clock.offsetMs, 1000);
      expect(clock.hasSample, isFalse, reason: '粗估不算可信样本');

      clock.addSample(t0: 20_000, serverTimeMs: 20_010, t1: 20_020);
      expect(clock.hasSample, isTrue);
      expect(clock.offsetMs, 0);

      clock.addBootstrapSample(serverTimeMs: 99_999, localNowMs: 1);
      expect(clock.offsetMs, 0, reason: '已有真样本时忽略粗估');
    });

    test('reset 之后回到「没有样本」', () {
      final clock = ClockSync();
      clock.addSample(t0: 1, serverTimeMs: 100, t1: 11);
      clock.reset();

      expect(clock.hasSample, isFalse);
      expect(clock.offsetMs, 0);
      expect(clock.bestRttMs, isNull);
    });
  });

  group('协议：点歌队列', () {
    test('music_state 解析出当前曲、队列与锚点', () {
      final message = ServerMessage.fromJson(<String, dynamic>{
        'v': 1,
        'type': 'music_state',
        'revision': 7,
        'serverTimeMs': 1760000000123,
        'current': <String, dynamic>{
          'entryId': 'e2',
          'source': 'kugou',
          'songId': 'hash-9',
          'musicInfo': <String, dynamic>{'id': 'hash-9', 'hash': 'h9'},
          'title': '富士山下',
          'artist': '陈奕迅',
          'durationMs': 245000,
          'requestedBy': <String, dynamic>{
            'peerId': 'a1b2',
            'displayName': '阿杰',
          },
          'playing': true,
          'anchorServerMs': 1760000003000,
          'anchorPositionMs': 0,
        },
        'queue': <dynamic>[
          <String, dynamic>{
            'entryId': 'e3',
            'source': 'netease',
            'songId': '42',
            'musicInfo': <String, dynamic>{'id': '42'},
            'title': '下一首',
            'requestedBy': <String, dynamic>{
              'peerId': 'c3d4',
              'displayName': '小明',
            },
          },
        ],
      });

      expect(message, isA<MusicStateMessage>());
      final snapshot = (message as MusicStateMessage).snapshot;
      expect(snapshot.revision, 7);
      expect(snapshot.serverTimeMs, 1760000000123);

      final current = snapshot.current;
      expect(current, isNotNull);
      expect(current!.entryId, 'e2');
      expect(current.title, '富士山下');
      expect(current.durationMs, 245000);
      expect(current.requestedBy.displayName, '阿杰');
      expect(current.musicInfo['hash'], 'h9', reason: '音源原始字段要原样保留');
      expect(current.playing, isTrue);
      expect(current.anchorServerMs, 1760000003000);
      expect(current.anchorPositionMs, 0);

      expect(snapshot.queue, hasLength(1));
      expect(snapshot.queue.single.entryId, 'e3');
      expect(snapshot.queue.single.requestedBy.peerId, 'c3d4');
    });

    test('hello / pong 带服务器时钟，room_state 带队列快照', () {
      final hello = ServerMessage.fromJson(<String, dynamic>{
        'type': 'hello',
        'peerId': 'a1b2c3d4',
        'protocolVersion': 1,
        'heartbeatInterval': 30,
        'iceServers': <String>['stun:stun.example.com:3478'],
        'roomCapacity': 8,
        'serverTimeMs': 1760000000000,
        'musicEnabled': true,
        'server': <String, dynamic>{'name': 'OmiocLink', 'version': '0.1.0'},
        'user': <String, dynamic>{
          'id': 7,
          'username': 'alice',
          'displayName': '小明',
        },
      });
      expect(hello, isA<ServerHello>());
      expect((hello as ServerHello).serverTimeMs, 1760000000000);
      expect(hello.musicEnabled, isTrue);

      final pong = ServerMessage.fromJson(<String, dynamic>{
        'type': 'pong',
        't': 12.5,
        'serverTimeMs': 1760000000500,
      });
      expect(pong, isA<PongMessage>());
      expect((pong as PongMessage).serverTimeMs, 1760000000500);
      expect(pong.t, 12.5);

      final roomState = ServerMessage.fromJson(<String, dynamic>{
        'type': 'room_state',
        'room': <String, dynamic>{'roomId': 'abcd1234', 'name': '测试房间'},
        'selfPeerId': 'a1b2c3d4',
        'members': <dynamic>[],
        'music': <String, dynamic>{
          'revision': 0,
          'serverTimeMs': 1760000000000,
          'current': null,
          'queue': <dynamic>[],
        },
      });
      expect(roomState, isA<RoomStateMessage>());
      expect((roomState as RoomStateMessage).music.revision, 0);
      expect(roomState.music.current, isNull);
      expect(roomState.music.queue, isEmpty);
    });

    test('music_* 出站消息字段与服务端一致', () {
      expect(
        musicEnqueueMessage(
          source: 'kugou',
          songId: 'h9',
          musicInfo: <String, dynamic>{'id': 'h9'},
          title: '富士山下',
          artist: '陈奕迅',
          durationMs: 245000,
        ),
        <String, dynamic>{
          'v': 1,
          'type': 'music_enqueue',
          'source': 'kugou',
          'songId': 'h9',
          'musicInfo': <String, dynamic>{'id': 'h9'},
          'title': '富士山下',
          'artist': '陈奕迅',
          'durationMs': 245000,
        },
      );
      expect(musicRemoveMessage(entryId: 'e1')['type'], 'music_remove');
      expect(musicSkipMessage()['type'], 'music_skip');
      expect(musicSkipMessage(entryId: 'e1')['entryId'], 'e1');
      expect(musicClearMessage()['type'], 'music_clear');
      expect(
        musicEosMessage(entryId: 'e1', revision: 3),
        <String, dynamic>{
          'v': 1,
          'type': 'music_eos',
          'entryId': 'e1',
          'revision': 3,
        },
      );
    });
  });
}
